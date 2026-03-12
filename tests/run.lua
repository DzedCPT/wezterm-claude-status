package.path = table.concat({
    './plugin/?.lua',
    './plugin/?/init.lua',
    package.path,
}, ';')

package.preload['wezterm'] = function()
    return require('tests.stub_wezterm')
end

local t = require('tests.harness')
local runner = t.new_runner()

-- Helper to create temp state files for hook tests
local function setup_hook_state(base_dir, pane_id, sessions)
    local pane_dir = base_dir .. '/' .. tostring(pane_id)
    os.execute('mkdir -p "' .. pane_dir .. '"')
    for session_id, status in pairs(sessions) do
        local f = io.open(pane_dir .. '/' .. session_id, 'w')
        f:write(status)
        f:close()
    end
    return pane_dir
end

local function cleanup_hook_state(base_dir)
    os.execute('rm -rf "' .. base_dir .. '"')
end

runner:test('read_hook_status returns nil when no state dir exists', function()
    local plugin = require('init')
    local config = { hooks = { state_dir = '/tmp/agent-deck-test-nonexistent-' .. os.time() } }
    t.eq(plugin._read_hook_status(999, config), nil)
end)

runner:test('read_hook_status returns nil when no state files for pane', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-empty-' .. os.time()
    os.execute('mkdir -p "' .. base .. '"')
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(999, config), nil)
    cleanup_hook_state(base)
end)

runner:test('read_hook_status returns nil when hooks config is absent', function()
    local plugin = require('init')
    t.eq(plugin._read_hook_status(1, {}), nil)
end)

runner:test('read_hook_status reads single working session', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-single-' .. os.time()
    setup_hook_state(base, 42, { ['session-abc'] = 'working' })
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(42, config), 'working')
    cleanup_hook_state(base)
end)

runner:test('read_hook_status reads single waiting session', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-waiting-' .. os.time()
    setup_hook_state(base, 10, { ['session-1'] = 'waiting' })
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(10, config), 'waiting')
    cleanup_hook_state(base)
end)

runner:test('read_hook_status maps ?? to waiting', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-question-' .. os.time()
    setup_hook_state(base, 5, { ['session-q'] = '??' })
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(5, config), 'waiting')
    cleanup_hook_state(base)
end)

runner:test('read_hook_status returns highest priority across sessions', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-multi-' .. os.time()
    setup_hook_state(base, 7, {
        ['session-1'] = 'working',
        ['session-2'] = 'idle',
        ['session-3'] = 'waiting',
    })
    local config = { hooks = { state_dir = base } }
    -- waiting > working > idle, so should return waiting
    t.eq(plugin._read_hook_status(7, config), 'waiting')
    cleanup_hook_state(base)
end)

runner:test('read_hook_status treats unknown status as idle', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-unknown-' .. os.time()
    setup_hook_state(base, 3, { ['session-x'] = 'something_else' })
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(3, config), 'idle')
    cleanup_hook_state(base)
end)

runner:test('read_hook_status working beats idle across sessions', function()
    local plugin = require('init')
    local base = '/tmp/agent-deck-test-workidle-' .. os.time()
    setup_hook_state(base, 8, {
        ['session-a'] = 'idle',
        ['session-b'] = 'working',
    })
    local config = { hooks = { state_dir = base } }
    t.eq(plugin._read_hook_status(8, config), 'working')
    cleanup_hook_state(base)
end)

runner:test('normalize_hook_status maps correctly', function()
    local plugin = require('init')
    t.eq(plugin._normalize_hook_status('working'), 'working')
    t.eq(plugin._normalize_hook_status('waiting'), 'waiting')
    t.eq(plugin._normalize_hook_status('??'), 'waiting')
    t.eq(plugin._normalize_hook_status('idle'), 'idle')
    t.eq(plugin._normalize_hook_status('unknown'), 'idle')
    t.eq(plugin._normalize_hook_status(nil), 'idle')
    t.eq(plugin._normalize_hook_status('  working  '), 'working')
end)

runner:run()
