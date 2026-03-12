-- WezTerm Agent Deck Plugin
-- Monitor Claude Code status via hook state files, render in WezTerm
local wezterm = require('wezterm')

local M = {}

-- Internal state
local state = {
    agent_states = {},  -- pane_id -> { agent_type, status, last_update }
}

--[[ ============================================
     Configuration
     ============================================ ]]

local default_config = {
    update_interval = 5000,

    right_status = {
        enabled = true,
    },

    colors = {
        working = 'green',
        waiting = 'yellow',
        idle = 'blue',
        inactive = 'gray',
    },

    icons = {
        style = 'unicode',
        unicode = {
            working = '●',
            waiting = '◔',
            idle = '○',
            inactive = '◌',
        },
        nerd = {
            working = '',
            waiting = '',
            idle = '',
            inactive = '',
        },
        emoji = {
            working = '🟢',
            waiting = '🟡',
            idle = '🔵',
            inactive = '⚪',
        },
    },

    hooks = {
        state_dir = '~/.local/state/claude-wezterm',
    },
}

local current_config = nil

local function deep_merge(t1, t2)
    local result = {}
    for k, v in pairs(t1) do
        if type(v) == 'table' and type(t2[k]) == 'table' then
            result[k] = deep_merge(v, t2[k])
        elseif t2[k] ~= nil then
            result[k] = t2[k]
        else
            result[k] = v
        end
    end
    for k, v in pairs(t2) do
        if result[k] == nil then
            result[k] = v
        end
    end
    return result
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local result = {}
    for k, v in pairs(t) do
        result[k] = deep_copy(v)
    end
    return result
end

local function set_config(opts)
    if not opts then
        current_config = deep_copy(default_config)
    else
        current_config = deep_merge(default_config, opts)
    end
end

local function get_config()
    if not current_config then
        current_config = deep_copy(default_config)
    end
    return current_config
end

local function get_status_color(status_name)
    local cfg = get_config()
    return cfg.colors[status_name] or cfg.colors.inactive
end

local function get_status_icon(status_name)
    local cfg = get_config()
    local icon_style = cfg.icons.style or 'unicode'
    local icons = cfg.icons[icon_style] or cfg.icons.unicode
    return icons[status_name] or icons.inactive
end

--[[ ============================================
     Hook-based Status Detection
     ============================================ ]]

local HOOK_STATUS_PRIORITY = { waiting = 3, working = 2, idle = 1 }

local function normalize_hook_status(raw)
    if not raw then return 'idle' end
    local trimmed = raw:match('^%s*(.-)%s*$') or ''
    if trimmed == 'working' then return 'working' end
    if trimmed == 'waiting' then return 'waiting' end
    if trimmed == '??' then return 'waiting' end
    return 'idle'
end

local function expand_home(path)
    if not path then return path end
    local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
    return path:gsub('^~', home)
end

local function read_hook_status(pane_id, config)
    local hooks_config = config.hooks
    if not hooks_config then return nil end

    local state_dir = expand_home(hooks_config.state_dir or '~/.local/state/claude-wezterm')
    local pane_dir = state_dir .. '/' .. tostring(pane_id)

    local handle = io.popen('ls -1 "' .. pane_dir .. '" 2>/dev/null')
    if not handle then return nil end
    local output = handle:read('*a')
    handle:close()
    if not output or output == '' then return nil end

    local best_status = nil
    local best_priority = 0

    for filename in output:gmatch('[^\n]+') do
        if filename ~= '' then
            local fh = io.open(pane_dir .. '/' .. filename, 'r')
            if fh then
                local content = fh:read('*a')
                fh:close()
                local hook_status = normalize_hook_status(content)
                local priority = HOOK_STATUS_PRIORITY[hook_status] or 0
                if priority > best_priority then
                    best_priority = priority
                    best_status = hook_status
                end
            end
        end
    end

    return best_status
end

--[[ ============================================
     Core Plugin Logic
     ============================================ ]]

local function get_agent_state(pane_id)
    return state.agent_states[pane_id]
end

local function update_pane_state(pane, config)
    local pane_id = pane:pane_id()
    local now = os.time() * 1000

    local new_status = read_hook_status(pane_id, config)

    if not new_status then
        -- No hook state files for this pane — not a tracked agent
        if state.agent_states[pane_id] then
            state.agent_states[pane_id] = nil
        end
        return nil
    end

    local current = state.agent_states[pane_id]
    if not current then
        current = { agent_type = 'claude', status = new_status, last_update = now }
        state.agent_states[pane_id] = current
        return current
    end

    current.status = new_status
    current.last_update = now
    return current
end

local function get_all_agent_states()
    return state.agent_states
end

local function count_agents_by_status()
    local counts = { working = 0, waiting = 0, idle = 0, inactive = 0 }
    for _, agent_state in pairs(state.agent_states) do
        local s = agent_state.status or 'inactive'
        counts[s] = (counts[s] or 0) + 1
    end
    return counts
end

--[[ ============================================
     Right Status Rendering
     ============================================ ]]

local function get_tab_statuses(window)
    local tab_statuses = {}
    for _, mux_tab in ipairs(window:mux_window():tabs()) do
        local pane_statuses = {}
        for _, p in ipairs(mux_tab:panes()) do
            local p_state = get_agent_state(p:pane_id())
            if p_state then
                table.insert(pane_statuses, p_state.status)
            end
        end
        if #pane_statuses > 0 then
            local tab_index = mux_tab:tab_id()
            local tabs = window:mux_window():tabs()
            for i, t in ipairs(tabs) do
                if t:tab_id() == mux_tab:tab_id() then
                    tab_index = i
                    break
                end
            end
            table.insert(tab_statuses, { index = tab_index, statuses = pane_statuses })
        end
    end
    return tab_statuses
end

local function render_right_status(tab_statuses)
    if #tab_statuses == 0 then return {} end

    local result = { { Text = ' ' } }
    for i, entry in ipairs(tab_statuses) do
        if i > 1 then
            table.insert(result, { Text = ' | ' })
        end
        local icons = {}
        for _, s in ipairs(entry.statuses) do
            table.insert(icons, get_status_icon(s))
        end
        table.insert(result, { Text = tostring(entry.index) .. '.' .. table.concat(icons, ' ') })
    end
    table.insert(result, { Text = ' ' })

    return result
end

--[[ ============================================
     Public API
     ============================================ ]]

function M.apply_to_config(config, opts)
    if opts then set_config(opts) end

    local plugin_config = get_config()
    config.status_update_interval = plugin_config.update_interval

    wezterm.on('update-status', function(window, pane)
        for _, mux_tab in ipairs(window:mux_window():tabs()) do
            for _, p in ipairs(mux_tab:panes()) do
                update_pane_state(p, plugin_config)
            end
        end

        if plugin_config.right_status.enabled then
            local tab_statuses = get_tab_statuses(window)
            local right_status = render_right_status(tab_statuses)

            if right_status and #right_status > 0 then
                window:set_right_status(wezterm.format(right_status))
            else
                window:set_right_status('')
            end
        end
    end)

    wezterm.log_info('[agent-deck] Plugin applied to config')
end

-- Query API: use in your own format-tab-title or update-status handlers
M.get_agent_state = get_agent_state           -- (pane_id) -> { agent_type, status } | nil
M.get_all_agent_states = get_all_agent_states -- () -> { pane_id -> { agent_type, status } }
M.count_agents_by_status = count_agents_by_status -- () -> { working=N, waiting=N, idle=N }
M.get_status_color = get_status_color         -- (status) -> color string
M.get_status_icon = get_status_icon           -- (status) -> icon string
M.get_config = get_config                     -- () -> config table
M.set_config = set_config                     -- (opts) -> nil
M.update_pane = function(pane)                -- (pane) -> state | nil
    return update_pane_state(pane, get_config())
end

-- Expose internals for testing
M._read_hook_status = read_hook_status       -- (pane_id, config) -> status | nil
M._normalize_hook_status = normalize_hook_status -- (raw) -> status string

return M
