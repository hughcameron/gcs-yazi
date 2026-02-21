--- gcs-browser: Browse, preview, and navigate Google Cloud Storage from yazi.
---
--- Subcommands (via keymap.toml):
---   (none)     - Browse GCS buckets / refresh current dir (gs)
---   copy       - Copy gs:// path of hovered file (cg)
---   download   - Download hovered file to ~/Downloads (gd)
---   exit       - Return to previous local directory (gq)
---
--- Auto features (via setup):
---   Header indicator: cloud gs://bucket/path/ (right side)
---   Auto-populate subdirectories on cd
---   File preview in preview pane
---
--- Requires: gcloud CLI (google-cloud-sdk)

local KEYS = "1234567890abcdefghijklmnopqrstuvwxyz"
local M = {}

local GCS_TMP = "/tmp/yazi-gcs"

-- Defaults; overridden by setup()
M._gcloud = "gcloud"
M._preview_bytes = 2048
M._download_dir = nil -- defaults to ~/Downloads

---------------------------------------------------------------------------
-- Sync helpers (run in yazi's main thread, can access cx)
---------------------------------------------------------------------------

local get_cwd = ya.sync(function()
	return cx.active.current.cwd
end)

local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	if h then return tostring(h.url) end
	return nil
end)

local store_prev_cwd = ya.sync(function(self, cwd)
	self._prev_cwd = cwd
end)

local get_prev_cwd = ya.sync(function(self)
	return self._prev_cwd
end)

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function gcloud(args)
	return Command(M._gcloud):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
end

local function parse_lines(stdout)
	local lines = {}
	for line in (stdout or ""):gmatch("[^\r\n]+") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if #trimmed > 0 then
			lines[#lines + 1] = trimmed
		end
	end
	return lines
end

--- Check if a path is inside the GCS temp directory.
local function is_gcs_dir(path)
	return #path > #GCS_TMP and path:sub(1, #GCS_TMP) == GCS_TMP
end

--- Derive gs:// directory path from local temp directory path.
--- /tmp/yazi-gcs/bucket-name/folder -> gs://bucket-name/folder/
local function to_gcs_path(local_path)
	local rel = local_path:sub(#GCS_TMP + 2) -- strip "/tmp/yazi-gcs/"
	local gs = "gs://" .. rel
	if gs:sub(-1) ~= "/" then
		gs = gs .. "/"
	end
	return gs
end

--- Derive gs:// file path (no trailing /).
--- /tmp/yazi-gcs/bucket-name/file.txt -> gs://bucket-name/file.txt
local function to_gcs_path_file(local_path)
	return "gs://" .. local_path:sub(#GCS_TMP + 2)
end

--- Check if a local directory already has contents.
local function dir_has_contents(path)
	local escaped = path:gsub("'", "'\\''")
	local out = Command("sh")
		:arg({ "-c", "ls -A '" .. escaped .. "' 2>/dev/null | head -1" })
		:stdout(Command.PIPED):output()
	return out and out.status.success and #(out.stdout or "") > 0
end

local function pick_bucket(buckets)
	if #buckets == 0 then return nil end
	if #buckets == 1 then return buckets[1] end

	local cands = {}
	for i, b in ipairs(buckets) do
		if i > #KEYS then break end
		local name = b:match("^gs://(.-)/?$") or b
		cands[#cands + 1] = { on = KEYS:sub(i, i), desc = name }
	end

	ya.sleep(0.1)
	local idx = ya.which({ cands = cands })
	if idx and idx >= 1 and idx <= #buckets then
		return buckets[idx]
	end
	return nil
end

--- Populate a local temp directory with one level of GCS listing.
--- Returns the parsed lines on success, nil on failure.
local function populate(local_dir, gs_path)
	ya.err("gcs-browser: populate " .. local_dir .. " <- " .. gs_path)
	local out = gcloud({ "storage", "ls", gs_path })

	if not out then
		ya.notify({ title = "GCS", content = "gcloud failed to run", timeout = 5, level = "error" })
		return nil
	end
	if not out.status.success then
		local msg = (out.stderr or ""):sub(1, 100):gsub("%s+$", "")
		ya.notify({ title = "GCS", content = msg, timeout = 5, level = "error" })
		return nil
	end

	local lines = parse_lines(out.stdout)
	if #lines == 0 then
		ya.notify({ title = "GCS", content = "Empty: " .. gs_path, timeout = 3, level = "warn" })
		return lines
	end

	local cmds = {}
	local count = 0
	for _, line in ipairs(lines) do
		local child = line:sub(#gs_path + 1)
		if #child > 0 then
			local is_dir = child:sub(-1) == "/"
			if is_dir then
				child = child:sub(1, -2)
			end

			local escaped = child:gsub("'", "'\\''")
			local full = local_dir .. "/" .. escaped

			if is_dir then
				cmds[#cmds + 1] = "mkdir -p '" .. full .. "'"
			else
				cmds[#cmds + 1] = "touch '" .. full .. "'"
			end
			count = count + 1
		end
	end

	if #cmds > 0 then
		Command("sh"):arg({ "-c", table.concat(cmds, " && ") }):output()
	end

	ya.err("gcs-browser: created " .. count .. " items in " .. local_dir)
	return lines
end

--- Look-ahead: populate immediate subdirectories so folder preview works.
--- Only populates subdirs that are still empty (skips already-populated ones).
local function lookahead(local_dir, gs_path, lines)
	for _, line in ipairs(lines) do
		if line:sub(-1) == "/" then
			local child = line:sub(#gs_path + 1, -2) -- strip parent prefix and trailing /
			if #child > 0 then
				local child_local = local_dir .. "/" .. child
				if not dir_has_contents(child_local) then
					populate(child_local, line)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Subcommands (dispatched from entry via keybinding arguments)
---------------------------------------------------------------------------

--- Copy gs:// path of hovered file to clipboard.
local function copy_gcs_path()
	local path = get_hovered()
	if not path or not is_gcs_dir(path) then
		ya.notify({ title = "GCS", content = "Not in GCS browser", timeout = 3, level = "warn" })
		return
	end

	-- Check if hovered item is a directory or file
	local escaped = path:gsub("'", "'\\''")
	local check = Command("sh"):arg({ "-c", "[ -d '" .. escaped .. "' ]" }):output()
	local gs_path
	if check and check.status.success then
		gs_path = to_gcs_path(path) -- directory: trailing /
	else
		gs_path = to_gcs_path_file(path) -- file: no trailing /
	end

	ya.clipboard(gs_path)
	ya.notify({ title = "Copied", content = gs_path, timeout = 3 })
end

--- Download hovered GCS file to download directory.
local function download_file()
	local path = get_hovered()
	if not path or not is_gcs_dir(path) then
		ya.notify({ title = "GCS", content = "Not a GCS file", timeout = 3, level = "warn" })
		return
	end

	-- Check if it's a directory
	local escaped = path:gsub("'", "'\\''")
	local check = Command("sh"):arg({ "-c", "[ -d '" .. escaped .. "' ]" }):output()
	if check and check.status.success then
		ya.notify({ title = "GCS", content = "Cannot download a directory", timeout = 3, level = "warn" })
		return
	end

	local gs_path = to_gcs_path_file(path)
	local dl_dir = M._download_dir or (os.getenv("HOME") .. "/Downloads")
	local filename = gs_path:match("([^/]+)$") or "download"

	ya.notify({ title = "GCS", content = "Downloading " .. filename .. "...", timeout = 3 })

	local out = gcloud({ "storage", "cp", gs_path, dl_dir .. "/" })
	if out and out.status.success then
		ya.notify({ title = "GCS", content = "Saved: " .. dl_dir .. "/" .. filename, timeout = 3 })
	else
		local msg = ((out and out.stderr) or "gcloud failed"):sub(1, 100)
		ya.notify({ title = "GCS", content = "Download failed: " .. msg, timeout = 5, level = "error" })
	end
end

--- Exit GCS browser and return to previous local directory.
local function exit_gcs()
	local prev = get_prev_cwd()
	if prev then
		ya.emit("cd", { Url(prev) })
		store_prev_cwd(nil)
		ya.notify({ title = "GCS", content = "Back to local fs", timeout = 2 })
	else
		ya.emit("cd", { Url(os.getenv("HOME") or "/") })
	end
end

---------------------------------------------------------------------------
-- setup(): Header indicator + auto-populate on cd
-- Called from init.lua: require("gcs-browser"):setup()
---------------------------------------------------------------------------

function M:setup(opts)
	opts = opts or {}

	-- Configurable gcloud path (default: "gcloud" from PATH)
	if opts.gcloud_path then
		M._gcloud = opts.gcloud_path
	end

	-- Configurable preview byte range (default: 800)
	if opts.preview_bytes then
		M._preview_bytes = opts.preview_bytes
	end

	-- Configurable download directory (default: ~/Downloads)
	if opts.download_dir then
		M._download_dir = opts.download_dir
	end

	-- Header: show cloud gs://bucket/path/ on the RIGHT side of the header bar
	-- Separated from the native path which stays on the left
	Header:children_add(function()
		local cwd = tostring(cx.active.current.cwd)
		if not is_gcs_dir(cwd) then return ui.Line({}) end
		return ui.Line { ui.Span(" \u{2601} " .. to_gcs_path(cwd)):style(ui.Style():fg("blue"):bold()) }
	end, 500, Header.RIGHT)

	-- Auto-populate GCS subdirectories on cd
	ps.sub("cd", function()
		local cwd = tostring(cx.active.current.cwd)
		if is_gcs_dir(cwd) then
			ya.emit("plugin", { self._id, ya.quote(cwd, true) })
		end
	end)
end

---------------------------------------------------------------------------
-- entry(): Main dispatcher
---------------------------------------------------------------------------

function M:entry(job)
	local args = job and job.args or {}

	-- Dispatch subcommands from keybindings
	if args[1] == "copy" then
		return copy_gcs_path()
	elseif args[1] == "download" then
		return download_file()
	elseif args[1] == "exit" then
		return exit_gcs()
	end

	-- Called from cd hook with a GCS path -> auto-populate
	if args[1] and is_gcs_dir(args[1]) then
		local auto_dir = args[1]

		-- Skip if directory already has contents (e.g. navigating back)
		if dir_has_contents(auto_dir) then return end

		ya.err("gcs-browser: auto-populate " .. auto_dir)
		ya.notify({ title = "GCS", content = "Loading...", timeout = 2 })
		local gs_path = to_gcs_path(auto_dir)
		local lines = populate(auto_dir, gs_path)
		if lines then
			ya.emit("cd", { Url(auto_dir) })
			-- Look-ahead: populate subdirectories for folder preview
			lookahead(auto_dir, gs_path, lines)
			ya.emit("cd", { Url(auto_dir) }) -- refresh after lookahead
		end
		return
	end

	-- Manual entry: either refresh (if in GCS) or fresh browse (if not)
	ya.err("gcs-browser: === entry ===")
	local cwd_url = get_cwd()
	local cwd = tostring(cwd_url)

	if is_gcs_dir(cwd) then
		-- Refresh current GCS directory
		local gs_path = to_gcs_path(cwd)
		ya.notify({ title = "GCS", content = "Refreshing " .. gs_path, timeout = 2 })

		local lines = populate(cwd, gs_path)
		if lines then
			ya.emit("cd", { Url(cwd) })
			lookahead(cwd, gs_path, lines)
			ya.emit("cd", { Url(cwd) }) -- refresh after lookahead
		end
		return
	end

	-- Fresh GCS browse — pick bucket
	store_prev_cwd(cwd) -- remember where we came from for gq

	local out = gcloud({ "storage", "ls" })
	if not out or not out.status.success then
		ya.notify({ title = "GCS", content = "gcloud failed", timeout = 5, level = "error" })
		return
	end

	local buckets = parse_lines(out.stdout)
	if #buckets == 0 then
		ya.notify({ title = "GCS", content = "No GCS buckets found", timeout = 5, level = "warn" })
		return
	end

	local bucket_path = pick_bucket(buckets)
	if not bucket_path then return end

	local bucket_name = bucket_path:match("^gs://(.-)/?$") or bucket_path
	local local_dir = GCS_TMP .. "/" .. bucket_name

	-- Clean slate for fresh browse
	Command("sh"):arg({ "-c", "rm -rf '" .. local_dir .. "' && mkdir -p '" .. local_dir .. "'" }):output()

	ya.notify({ title = "GCS", content = "Loading " .. bucket_path .. "...", timeout = 3 })
	local lines = populate(local_dir, bucket_path)
	if lines then
		ya.emit("cd", { Url(local_dir) })
		ya.notify({ title = "GCS", content = "Browsing: " .. bucket_path, timeout = 3 })
		-- Look-ahead: populate subdirectories for folder preview
		lookahead(local_dir, bucket_path, lines)
		ya.emit("cd", { Url(local_dir) }) -- refresh after lookahead
	end

	ya.err("gcs-browser: === done ===")
end

---------------------------------------------------------------------------
-- peek() / seek() — GCS file preview
---------------------------------------------------------------------------

function M:peek(job)
	local path = tostring(job.file.url)
	if not is_gcs_dir(path) then
		return require("code"):peek(job)
	end

	-- Show loading state immediately
	local gs_path = to_gcs_path_file(path)
	ya.preview_widget(job, { ui.Text("Loading " .. gs_path .. " ..."):area(job.area) })

	-- Fetch file content from GCS
	-- Try range first (efficient for large files); range is inclusive so use limit-1
	local limit = M._preview_bytes or 2048
	local out = Command(M._gcloud)
		:arg({ "storage", "cat", "-r", "0-" .. tostring(limit - 1), gs_path })
		:stdout(Command.PIPED):stderr(Command.PIPED):output()

	-- Range fails for files smaller than limit — fall back to full cat
	if not out or not out.status.success then
		out = Command(M._gcloud)
			:arg({ "storage", "cat", gs_path })
			:stdout(Command.PIPED):stderr(Command.PIPED):output()
	end

	if not out or not out.status.success then
		local msg = (out and out.stderr) or "gcloud failed"
		ya.preview_widget(job, { ui.Text("\u{26a0} " .. msg):area(job.area) })
		return
	end

	local content = out.stdout or ""
	if #content > limit then
		content = content:sub(1, limit)
	end
	ya.preview_widget(job, { ui.Text(content):area(job.area):wrap(ui.Wrap.YES) })
end

function M:seek(job)
	require("code"):seek(job)
end

return M
