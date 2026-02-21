# gcs-yazi

Browse, preview, and navigate Google Cloud Storage from [yazi](https://yazi-rs.github.io/).

Creates a temporary directory at `/tmp/yazi-gcs/` with placeholder files mirroring
the GCS bucket structure. Navigate with normal yazi keybindings — subdirectories
are auto-populated as you enter them.

## Features

| Key | Action |
|-----|--------|
| `gs` | Browse GCS buckets / refresh current directory |
| `cg` | Copy `gs://` path of hovered file to clipboard |
| `gd` | Download hovered file to `~/Downloads` |
| `gq` | Exit GCS browser, return to previous directory |

**Automatic:**
- **Header indicator** — shows `☁ gs://bucket/path/` on the right side of the header
- **Auto-populate** — entering a subdirectory fetches its contents from GCS
- **Look-ahead** — subdirectories are pre-populated so folder preview works
- **File preview** — preview pane shows the first N bytes of GCS objects (configurable)
- **Loading states** — "Loading..." shown in preview pane and notifications during fetch

## Requirements

- [yazi](https://yazi-rs.github.io/) 26.x+
- [gcloud CLI](https://cloud.google.com/sdk/gcloud) (`gcloud storage ls`, `gcloud storage cat`, `gcloud storage cp`)
- Authenticated: `gcloud auth login`

## Installation

```sh
ya pack -a hughcameron/gcs-yazi
```

## Configuration

### 1. init.lua

Add the setup call to `~/.config/yazi/init.lua`:

```lua
require("gcs-yazi"):setup()
```

With options:

```lua
require("gcs-yazi"):setup({
    -- Override gcloud path if not in PATH (default: "gcloud")
    gcloud_path = "/opt/homebrew/bin/gcloud",
    -- Bytes to fetch for file preview (default: 800)
    preview_bytes = 2048,
    -- Download directory (default: ~/Downloads)
    download_dir = os.getenv("HOME") .. "/Downloads",
})
```

### 2. yazi.toml

Register the previewer for GCS temp files in `~/.config/yazi/yazi.toml`:

```toml
[plugin]
prepend_previewers = [
    # ... your other previewers ...
    { url = "/tmp/yazi-gcs/**", run = "gcs-yazi" },
]
```

### 3. keymap.toml

Add keybindings to `~/.config/yazi/keymap.toml`:

```toml
# GCS bucket browser
[[mgr.prepend_keymap]]
on   = ["g", "s"]
run  = "plugin gcs-yazi"
desc = "Browse GCS buckets / refresh"

[[mgr.prepend_keymap]]
on   = ["c", "g"]
run  = "plugin gcs-yazi -- copy"
desc = "Copy gs:// path"

[[mgr.prepend_keymap]]
on   = ["g", "d"]
run  = "plugin gcs-yazi -- download"
desc = "Download GCS file to ~/Downloads"

[[mgr.prepend_keymap]]
on   = ["g", "q"]
run  = "plugin gcs-yazi -- exit"
desc = "Exit GCS browser"
```

## Usage

1. Press `gs` from any directory to browse GCS
2. If multiple buckets exist, pick one from the list
3. Navigate normally with `l` (enter) and `h` (back)
4. Subdirectories auto-populate as you enter them
5. Hover a file to see its content in the preview pane
6. Press `cg` to copy the `gs://` path of the hovered file
7. Press `gd` to download the hovered file to `~/Downloads`
8. Press `gs` to refresh the current GCS directory
9. Press `gq` to exit back to your previous local directory

## How it works

The plugin creates a temporary directory at `/tmp/yazi-gcs/<bucket>/` with empty
files and directories matching the GCS structure. This lets yazi treat it as a
normal filesystem while the plugin handles fetching content on demand.

- `entry()` — bucket picker, directory population, subcommand dispatch
- `setup()` — header indicator, `cd` event hook for auto-populate
- `peek()` — fetches first N bytes via `gcloud storage cat` for preview
- Look-ahead populate — pre-fetches subdirectory contents so folder preview works

## License

MIT
