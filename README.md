# autosession-win.yazi

A [Yazi](https://github.com/sxyazi/yazi) autosession plugin: save tab state on exit, and restore it automatically on the next **empty launch** (i.e. no CLI args).

<details><summary><strong>Why this Windows fork?</strong></summary>

<p>[barbanevosa/autosession.yazi](https://github.com/barbanevosa/autosession.yazi) persist state via Yazi DDS static messages (a kind starting with `@`).</p>
<p>On Windows, this DDS persistence can be unreliable in practice (e.g. the `.dds` directory stays empty, and nothing is restored after restart).</p>

<p>This fork fixes the “tabs data not persisted/restored” problem by:</p>
<ul>
<li>Defaulting to **Lua file persistence** on Windows (stable across restarts)</li>
<li>Keeping DDS persistence as an optional mode (useful on non-Windows or if you want to force DDS)</li>
</ul>
</details>

## Features

- Save/restore:
    - Open tabs and their `cwd`
    - Per-tab view prefs: sort, linemode, hidden
    - Active tab
- Safe auto-restore: only triggers on an **empty launch** to avoid overwriting sessions created via CLI args.

> [!IMPORTANT]
> If you also use https://github.com/MasouShizuka/projects.yazi with “auto load on start” / “save before quit” enabled (e.g. `load_after_start` / `update_before_quit`), the two plugins may fight and overwrite each other.
> Use only one plugin for automatic persistence.

## Installation (git)

Windows:

```sh
git clone https://github.com/Sansui233/autosession-win.yazi.git %AppData%\yazi\config\plugins\autosession-win.yazi

Linux/macOS:

```sh
git clone https://github.com/Sansui233/autosession-win.yazi.git ~/.config/yazi/plugins/autosession-win.yazi
```

## Setup

In `init.lua`:

```lua
require("autosession-win"):setup({
    auto_restore = true,
})
```

In `keymap.toml`

```toml
[[mgr.prepend_keymap]]
on = ["q"]
run = "plugin autosession-win -- save-and-quit"
desc = "Save session and quit"
```

## Usage

- Press `q` (via your keymap) to save session and quit
- Start Yazi with no CLI args and `auto_restore=true` to auto-restore the last session

## Available setup options

All options are optional:

```lua
require("autosession-win"):setup({
    auto_restore = true, -- Auto-restore on empty launch (no CLI args). Default: false
    overwrite = true, -- Overwrite current tabs when restoring. Default: true
    save_on_quit = true, -- Save automatically on normal quit. Default: true
    save_method = "lua", -- "lua" (file) or "yazi" (DDS). Default: "lua" on Windows, "yazi" elsewhere

    -- File persistence (only for save_method = "lua")
    lua_save_path = "%APPDATA%/yazi/state/autosession.lua", -- Default: %APPDATA%/yazi/state/autosession.lua (Windows), ~/.local/state/yazi/autosession.lua (Unix)

    -- DDS persistence (only for save_method = "yazi")
    kind = "@autosession", -- DDS event kind (static message; must start with '@'). Default: "@autosession"
    broadcast = false, -- Also publish to other instances. Default: false
})
```

> `kind` / `broadcast` only apply when `save_method="yazi"`.

## Available commands

Invoke via `plugin <name> -- <command>`:

- `save-and-quit`: save session then quit
- `save`: save session
- `restore`: restore session
- `clear`: clear saved session

## License

MIT.
