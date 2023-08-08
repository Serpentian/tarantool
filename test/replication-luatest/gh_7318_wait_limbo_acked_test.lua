local luatest = require('luatest')
local server = require('luatest.server')
local replica_set = require('luatest.replica_set')

-- This test covers box_wait_limbo_acked
local g = luatest.group('gh-7318-wait-limbo-acked')

g.before_all(function(g)
    g.replica_set = replica_set:new({})
    g.box_cfg = {
        -- No automatic resigning is needed
        -- election_fencing_mode = 'off',
        election_mode = 'off',
        replication_timeout = 0.1,
        replication_synchro_timeout = 0.01,
        replication = {
            server.build_listen_uri('server_1', g.replica_set.id),
            server.build_listen_uri('server_2', g.replica_set.id),
        },
    }

    g.server_1 = g.replica_set:build_and_add_server(
        {alias = 'server_1', box_cfg = g.box_cfg})

    g.server_2 = g.replica_set:build_and_add_server(
        {alias = 'server_2', box_cfg = g.box_cfg})

    g.replica_set:start()
    g.replica_set:wait_for_fullmesh()
    g.server_1:exec(function()
        box.ctl.promote()
        box.schema.space.create('sync', {is_sync = true}):create_index('pk')
    end)
    g.server_1:wait_for_downstream_to(g.server_2)
end)

g.after_all(function(g)
    g.replica_set:stop()
end)

--
-- Wait until the server sees synchro queue is empty or not
--
local function wait_limbo_is_empty(server, is_empty)
    server:exec(function(is_empty)
        luatest.helpers.retrying({}, function()
            local state = box.info.synchro.queue.len == 0
            if state ~= is_empty then
                error('Waiting for synchro queue state failed')
            end
        end)
    end, {is_empty})
end

local function set_errinj(server, value)
    server:exec(function(value)
        box.error.injection.set('ERRINJ_BOX_WAIT_LIMBO_ACKED_DELAY', value)
    end, {value})
end

local function promote_start(server)
    return server:exec(function()
        local f = require('fiber').new(box.ctl.promote)
        f:set_joinable(true)
        return f:id()
    end)
end

local function fiber_join(server, fid)
    return server:exec(function(fid)
        return require('fiber').find(fid):join()
    end, {fid})
end

local function box_cfg_update(servers, cfg)
    for _, server in ipairs(servers) do
        server:update_box_cfg(cfg)
    end
end

--
-- Increase quorum, while waiting for sync tx should end with error
--
g.test_empty_limbo = function(g)
    box_cfg_update(g.replica_set.servers, {replication_synchro_quorum = 3})
    g.server_2:update_box_cfg({replication_synchro_timeout = 60})

    -- Make limbo non empty, wait until server notices that
    local replace_fid = g.server_2:exec(function()
        box.ctl.promote()
        local sync = box.space.sync
        local f = require('fiber').create(sync.replace, sync, {1})
        f:set_joinable(true)
        return f:id()
    end)

    wait_limbo_is_empty(g.server_1, false)

    local expected_term = g.server_1:get_election_term() + 1
    set_errinj(g.server_1, true)
    local promote_fid = promote_start(g.server_1)

    -- Wait until promote reaches waiting for limbo_acked
    luatest.helpers.retrying({timeout = 15}, function()
        luatest.assert_not_equals(nil, g.server_1:grep_log(string.format(
           'RAFT: persisted state {term: %d}', expected_term)))
    end)

    -- while not g.server_1:grep_log(string.format(
    --     'RAFT: persisted state {term: %d}', expected_term)) do end

    -- Now update quorum in order to make limbo empty, get into box_wait_quorum
    -- set_errinj(g.server_1, false)
    -- box_cfg_update(g.replica_set.servers, {replication_synchro_quorum = 2})
    -- local _, err = fiber_join(g.server_2, replace_fid)
    -- luatest.assert_equals(err, {1})
    -- _, err = fiber_join(g.server_1, promote_fid)
    -- luatest.assert_equals(err, nil)
end
