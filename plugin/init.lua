-- WezTerm Agent Status Plugin
-- Monitor Claude Code status via hook state files
local wezterm = require('wezterm')

local M = {}

-- Internal state
local state = {
    agent_states = {},  -- workspace_name -> { agent_type, status, last_update }
}

--[[ ============================================
     Configuration
     ============================================ ]]

local default_config = {
    update_interval = 5000,

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

local function read_hook_statuses(workspace, config)
    local hooks_config = config.hooks
    if not hooks_config then return nil end

    local state_dir = expand_home(hooks_config.state_dir or '~/.local/state/claude-wezterm')
    local ws_dir = state_dir .. '/' .. tostring(workspace)

    local handle = io.popen('ls -1 "' .. ws_dir .. '" 2>/dev/null')
    if not handle then return nil end
    local output = handle:read('*a')
    handle:close()
    if not output or output == '' then return nil end

    local sessions = {}
    for pane_name in output:gmatch('[^\n]+') do
        if pane_name ~= '' then
            local pane_dir = ws_dir .. '/' .. pane_name
            -- Each pane dir contains session files; pick highest priority status
            local pane_handle = io.popen('ls -1 "' .. pane_dir .. '" 2>/dev/null')
            if pane_handle then
                local pane_output = pane_handle:read('*a')
                pane_handle:close()
                if pane_output and pane_output ~= '' then
                    local best_status = nil
                    local best_priority = 0
                    for session_file in pane_output:gmatch('[^\n]+') do
                        if session_file ~= '' then
                            local fh = io.open(pane_dir .. '/' .. session_file, 'r')
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
                    if best_status then
                        table.insert(sessions, {
                            pane_id = pane_name,
                            status = best_status,
                        })
                    end
                end
            end
        end
    end

    if #sessions == 0 then return nil end
    return sessions
end

--[[ ============================================
     Core Plugin Logic
     ============================================ ]]

local function update_workspace_state(workspace, config)
    local sessions = read_hook_statuses(workspace, config)

    if not sessions then
        state.agent_states[workspace] = nil
        return nil
    end

    state.agent_states[workspace] = sessions
    return sessions
end

--[[ ============================================
     Workspace Status Query
     ============================================ ]]

local function get_workspace_statuses()
    -- Build a lookup of pane_id -> status from hook state
    local pane_status_map = {}
    for _, sessions in pairs(state.agent_states) do
        for _, s in ipairs(sessions) do
            pane_status_map[s.pane_id] = s.status
        end
    end

    local workspace_map = {}
    for _, mux_win in ipairs(wezterm.mux.all_windows()) do
        local ws = mux_win:get_workspace()
        if not workspace_map[ws] then
            workspace_map[ws] = {}
        end

        for _, mux_tab in ipairs(mux_win:tabs()) do
            local tab_title = mux_tab:get_title()
            for _, p in ipairs(mux_tab:panes()) do
                local pid = tostring(p:pane_id())
                table.insert(workspace_map[ws], {
                    pane_id = pid,
                    tab_name = tab_title,
                    status = pane_status_map[pid] or 'inactive',
                })
            end
        end
    end

    local result = {}
    for ws, panes in pairs(workspace_map) do
        table.insert(result, { workspace = ws, tabs = panes })
    end
    table.sort(result, function(a, b) return a.workspace < b.workspace end)

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
        local seen = {}
        for _, mux_win in ipairs(wezterm.mux.all_windows()) do
            local ws = mux_win:get_workspace()
            if not seen[ws] then
                seen[ws] = true
                update_workspace_state(ws, plugin_config)
            end
        end
    end)

    wezterm.log_info('[agent-status] Plugin applied to config')
end

M.get_workspace_statuses = get_workspace_statuses
M.get_config = get_config
M.set_config = set_config

-- Expose internals for testing
M._read_hook_statuses = read_hook_statuses
M._normalize_hook_status = normalize_hook_status

return M
