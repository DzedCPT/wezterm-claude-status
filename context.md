# WezTerm Agent Deck — Current State

## What this plugin does

Monitors Claude Code status in WezTerm by reading state files written by a Claude Code hook script. Renders per-tab agent status icons in the right side of the WezTerm tab bar. Exposes a query API so users can build their own tab title rendering.

## Architecture

### Hook script → State files → Plugin reads → Renders

1. **Hook script** (`hooks/claude-code.sh`, installed at `~/.claude/hooks/wezterm-status.sh`):
   - Registered on all Claude Code lifecycle events (SessionStart, Stop, UserPromptSubmit, PreToolUse, PostToolUse, Notification, SessionEnd)
   - Reads JSON from stdin, writes a single status word to `~/.local/state/claude-wezterm/<pane_id>/<session_id>`
   - Status mapping: SessionStart/Stop → `idle`, UserPromptSubmit → `working`, permission_prompt → `waiting`, AskUserQuestion → `waiting`, SessionEnd → removes file
   - Cleans up files older than 24h

2. **Plugin** (`plugin/init.lua`, ~250 lines):
   - On every `update-status` event, iterates all panes, reads their hook state files via `io.popen('ls ...')` + `io.open`
   - Normalizes status: `working`/`waiting`/`idle` (and `??` → `waiting`)
   - If multiple sessions exist per pane, returns highest priority (waiting > working > idle)
   - Renders right status bar as `1.● ○ | 3.◔` (tab number + icon per agent pane)
   - No process detection, no text scanning, no notifications — hooks are the sole source of truth

3. **Hook module** (`plugin/hooks.lua`):
   - Standalone module with same logic as inlined in init.lua, used by tests

## Key files

| File | Purpose |
|---|---|
| `plugin/init.lua` | Main plugin — config, hook reading, state tracking, right status rendering, public API |
| `plugin/hooks.lua` | Standalone hooks module (used by tests) |
| `hooks/claude-code.sh` | Reference hook script shipped with the repo |
| `~/.claude/hooks/wezterm-status.sh` | User's installed hook script (same content as above) |
| `tests/run.lua` | 10 tests covering hook status reading |
| `tests/harness.lua` | Minimal test runner (eq, truthy, falsy assertions) |
| `tests/stub_wezterm.lua` | Mock wezterm module for tests |

### Files that exist but are now unused (candidates for cleanup)

| File | Was used for |
|---|---|
| `plugin/config.lua` | Standalone config module with validation — old tests imported it |
| `plugin/detector.lua` | Process-based agent detection — removed from init.lua |
| `plugin/status.lua` | Text scanning status detection — removed from init.lua |
| `plugin/renderer.lua` | Component-based rendering — removed from init.lua |
| `plugin/notifications.lua` | Notification sending — removed from init.lua |
| `plugin/components/init.lua` | Composable component system — removed from init.lua |

## User's WezTerm config (`~/Developer/dotfiles/wezterm/wezterm.lua`)

- Loads plugin via `dofile('/Users/jed/Developer/wezterm-agent-deck/plugin/init.lua')`
- Calls `agent_deck.apply_to_config(config, { tab_title = { enabled = false }, update_interval = 1000 })` — note: `tab_title` config key no longer exists in the plugin but is harmlessly merged
- Has its own `format-tab-title` handler (tmux-style `1:title` format)
- Uses Nord color scheme, `use_fancy_tab_bar = false`

## Public API

```lua
agent_deck.get_agent_state(pane_id)       -- { agent_type='claude', status='working'|'waiting'|'idle' } | nil
agent_deck.get_all_agent_states()         -- { pane_id -> state }
agent_deck.count_agents_by_status()       -- { working=N, waiting=N, idle=N, inactive=N }
agent_deck.get_status_icon(status)        -- icon string based on config (default: ● ◔ ○ ◌)
agent_deck.get_status_color(status)       -- color string based on config
agent_deck.get_config()                   -- current merged config
agent_deck.update_pane(pane)              -- manually trigger state update for a pane
```

## What was removed (and why)

- **Process-based agent detection**: Claude Code process often appears as `node` or `zsh`, making it unreliable. Hooks are authoritative.
- **Text scanning**: Pattern matching terminal output for "esc to interrupt", "(Y/n)", etc. Fragile and imprecise. Hooks replace this entirely.
- **Notifications**: Toast notifications and terminal-notifier support. Removed to reduce scope.
- **Tab title rendering**: Component-based system for rendering status dots in tab titles. Users can build their own using the query API.
- **Multi-agent support**: Config for opencode, gemini, codex, aider. Plugin is now Claude Code only.

## Known issues / TODO

- The README is outdated — still references text scanning, notifications, multi-agent support, custom rendering with tab_title config. Needs a full rewrite to match the simplified plugin.
- Stale sub-modules (`plugin/config.lua`, `plugin/detector.lua`, `plugin/status.lua`, `plugin/renderer.lua`, `plugin/notifications.lua`, `plugin/components/`) should be deleted.
- Old tests in `tests/run.lua` were removed but the old modules they tested still exist on disk.
- `update_interval = 1000` in user config but `default_config` has 5000 — the user prefers 1s polling.
- The right status currently shows idle agents too. User may want to filter those out.
- `io.popen('ls -1 ...')` for directory listing works but spawns a shell per pane per update cycle. Could be replaced with `lfs.dir()` if luafilesystem is available, or accept the overhead since state dirs are tiny.
