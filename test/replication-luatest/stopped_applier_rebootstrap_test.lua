local fio = require('fio')
local replica_set = require('luatest.replica_set')
local server = require('luatest.server')
local t = require('luatest')

local g = t.group()
local g_wal = t.group('wal', t.helpers.matrix({
    rollback = {false, true},
    reconfigure = {'remove', 'replace'},
}))
local g_collision = t.group('collision', t.helpers.matrix({
    stopped = {false, true},
}))

local function assert_applier_stopped(cg, id)
    cg.master:exec(function(id)
        t.helpers.retrying({}, function()
            local upstream = box.info.replication[id].upstream
            t.assert_equals(upstream.status, 'stopped')
            t.assert_str_contains(upstream.message, 'Duplicate key exists')
        end)
    end, {id})
end

local function stop_master_applier(cg)
    local old_uuid = tostring(cg.replica:get_instance_uuid())
    local id = cg.replica:get_instance_id()
    cg.replica:exec(function()
        box.cfg{replication = {}}
    end)
    cg.master:exec(function(id)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.replication[id].downstream.status,
                            'stopped')
        end)
        box.space._schema:insert{'test'}
    end, {id})
    cg.replica:exec(function()
        box.cfg{read_only = false}
        box.space._schema:insert{'test'}
    end)
    assert_applier_stopped(cg, id)
    return old_uuid, id
end

local function start_cluster(cg)
    cg.replica_set = replica_set:new({})
    local replication = {
        server.build_listen_uri('master', cg.replica_set.id),
        server.build_listen_uri('replica', cg.replica_set.id),
    }
    for _, name in ipairs({'master', 'replica'}) do
        cg[name] = cg.replica_set:build_and_add_server({
            alias = name,
            box_cfg = {
                instance_name = name,
                read_only = name == 'replica',
                replication = replication,
            },
        })
    end
    cg.replica_set:start()
    cg.replica_set:wait_for_fullmesh()
end

local function drop_cluster(cg)
    if t.tarantool.is_debug_build() then
        cg.master:exec(function()
            box.error.injection.set('ERRINJ_WAL_WRITE', false)
            box.error.injection.set('ERRINJ_WAL_DELAY', false)
            box.error.injection.set('ERRINJ_APPLIER_SUBSCRIBE_DELAY', false)
        end)
    end
    cg.replica_set:drop()
end

for _, group in ipairs({g, g_wal, g_collision}) do
    group.before_each(start_cluster)
    group.after_each(drop_cluster)
end

g.test_rebootstrap = function(cg)
    local old_uuid, id = stop_master_applier(cg)
    cg.replica:drop()
    fio.rmtree(cg.replica.workdir)
    cg.replica:start()
    t.assert_not_equals(tostring(cg.replica:get_instance_uuid()), old_uuid)
    t.assert_equals(cg.replica:get_instance_id(), id)
    assert_applier_stopped(cg, id)
    cg.master:exec(function()
        box.space._schema:insert{'after_rebootstrap'}
    end)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.replica:exec(function()
        t.assert_equals(box.space._schema:get{'after_rebootstrap'}:totable(),
                        {'after_rebootstrap'})
    end)
    cg.master:exec(function()
        local replication = table.copy(box.cfg.replication)
        box.cfg{replication = {}}
        box.cfg{replication = replication}
    end)
    cg.replica_set:wait_for_fullmesh()
end

g.test_commit_chain = function(cg)
    local old_uuid, id = stop_master_applier(cg)
    cg.master:exec(function(old_uuid, id)
        local uuid = require('uuid')
        local message = box.info.replication[id].upstream.message
        local final_uuid = uuid.str()
        for _, new_uuid in ipairs({old_uuid, final_uuid}) do
            box.begin()
            box.space._cluster:update(id, {{'=', 2, uuid.str()}})
            box.space._cluster:update(id, {{'=', 2, new_uuid}})
            box.commit()
            t.assert_equals(box.info.replication[id].uuid, new_uuid)
            t.assert_equals(box.info.replication[id].upstream.message, message)
        end
        box.begin()
        box.space._cluster:update(id, {{'=', 2, uuid.str()}})
        box.space._cluster:insert{3, final_uuid, 'retained'}
        box.commit()
        t.assert_equals(box.info.replication[id].upstream, nil)
        t.assert_equals(box.info.replication[3].upstream.message, message)
    end, {old_uuid, id})
end

g.test_rollback = function(cg)
    local old_uuid, id = stop_master_applier(cg)
    cg.master:exec(function(old_uuid, id)
        local uuid = require('uuid')
        local old = box.space._cluster:get{id}
        local message = box.info.replication[id].upstream.message
        box.begin()
        box.space._cluster:update(id, {{'=', 2, uuid.str()}})
        local savepoint = box.savepoint()
        box.space._cluster:update(id, {{'=', 2, uuid.str()}})
        box.rollback_to_savepoint(savepoint)
        box.rollback()
        t.assert_equals(box.space._cluster:get{id}, old)
        t.assert_equals(box.info.replication[id].uuid, old_uuid)
        t.assert_equals(box.info.replication[id].name, 'replica')
        t.assert_equals(box.info.replication[id].upstream.message, message)
    end, {old_uuid, id})
    assert_applier_stopped(cg, id)
end

g.test_running_applier_prevents_replacement = function(cg)
    local id = cg.replica:get_instance_id()
    cg.replica:exec(function()
        box.cfg{replication = {}}
    end)
    local function assert_rejected(status)
        cg.master:exec(function(id, status)
            t.helpers.retrying({}, function()
                local info = box.info.replication[id]
                t.assert_equals(info.downstream.status, 'stopped')
                t.assert_equals(info.upstream.status, status)
            end)
            local old = box.space._cluster:get{id}
            t.assert_error_msg_contains('old replica is still here',
                box.space._cluster.update, box.space._cluster, id,
                {{'=', 2, require('uuid').str()}})
            t.assert_equals(box.space._cluster:get{id}, old)
        end, {id, status})
    end
    assert_rejected('follow')
    cg.replica:stop()
    assert_rejected('disconnected')
end

g.test_incoming_connection_prevents_replacement = function(cg)
    local _, id = stop_master_applier(cg)
    cg.replica:exec(function(uri)
        box.space._schema:delete{'test'}
        box.cfg{replication = {uri}}
    end, {cg.master.net_box_uri})
    cg.master:exec(function(id)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.replication[id].downstream.status,
                            'follow')
        end)
        t.assert_equals(box.info.replication[id].upstream.status, 'stopped')
        t.assert_error_msg_contains('old replica is still here',
            box.space._cluster.update, box.space._cluster, id,
            {{'=', 2, require('uuid').str()}})
    end, {id})
end

g_wal.test_reconfiguration_during_wal = function(cg)
    t.tarantool.skip_if_not_debug()
    local old_uuid, id = stop_master_applier(cg)
    cg.master:exec(function(old_uuid, id, rollback, reconfigure)
        local fiber = require('fiber')
        local new_uuid = require('uuid').str()
        local old = box.space._cluster:get{id}
        local replication = table.copy(box.cfg.replication)
        box.cfg{replication_sync_timeout = 0}
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
        local f = fiber.create(function()
            fiber.self():set_joinable(true)
            return pcall(box.space._cluster.update, box.space._cluster,
                         id, {{'=', 2, new_uuid}})
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.replication[id].uuid, new_uuid)
        end)
        box.cfg{replication = {}}
        if reconfigure == 'replace' then
            -- Keep the new applier alive without applying the conflicting row.
            box.error.injection.set('ERRINJ_APPLIER_SUBSCRIBE_DELAY', true)
            box.cfg{replication = replication}
        end
        box.error.injection.set('ERRINJ_WAL_WRITE', rollback)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        local joined, ok, err = f:join()
        box.error.injection.set('ERRINJ_WAL_WRITE', false)
        t.assert(joined)
        if rollback then
            t.assert_not(ok)
            t.assert_equals(err.code, box.error.WAL_IO)
            t.assert_equals(box.space._cluster:get{id}, old)
            t.assert_equals(box.info.replication[id].uuid, old_uuid)
            if reconfigure == 'replace' then
                t.helpers.retrying({}, function()
                    t.assert_equals(box.info.replication[id].upstream.status,
                                    'sync')
                end)
            else
                t.assert_equals(box.info.replication[id].upstream, nil)
            end
        else
            t.assert(ok)
            t.assert_equals(box.info.replication[id].uuid, new_uuid)
            t.assert_equals(box.info.replication[id].upstream, nil)
        end
        box.error.injection.set('ERRINJ_APPLIER_SUBSCRIBE_DELAY', false)
        box.cfg{replication = {}}
    end, {old_uuid, id, cg.params.rollback, cg.params.reconfigure})
end

g_collision.test_preserve_both_appliers = function(cg)
    local other = cg.replica_set:build_and_add_server({
        alias = 'other',
        box_cfg = {
            instance_name = 'other',
            replication = {
                cg.master.net_box_uri,
                cg.replica.net_box_uri,
                server.build_listen_uri('other', cg.replica_set.id),
            },
            read_only = true,
        },
    })
    other:start()
    local other_id = other:get_instance_id()
    other:exec(function()
        box.cfg{replication = {}}
    end)
    cg.master:exec(function(uris)
        box.cfg{replication = uris}
    end, {{cg.master.net_box_uri, cg.replica.net_box_uri, other.net_box_uri}})
    t.helpers.retrying({}, function()
        cg.master:assert_follows_upstream(other_id)
    end)
    local old_uuid, id = stop_master_applier(cg)
    if cg.params.stopped then
        other:exec(function()
            box.cfg{read_only = false}
            box.space._schema:insert{'test'}
        end)
        assert_applier_stopped(cg, other_id)
    end
    cg.master:exec(function(old_uuid, id, other_id)
        local old = box.space._cluster:get{id}
        local other = box.space._cluster:delete{other_id}
        local source = box.info.replication[id].upstream
        -- Register briefly to inspect the destination after rollback as well.
        box.begin()
        box.space._cluster:update(id, {{'=', 2, other[2]}})
        local destination = box.info.replication[id].upstream
        box.rollback()
        t.assert_equals(box.space._cluster:get{id}, old)
        t.assert_equals(box.info.replication[id].upstream.message,
                        source.message)
        box.space._cluster:insert(other)
        t.assert_equals(box.info.replication[other_id].upstream.peer,
                        destination.peer)
        box.space._cluster:delete{other_id}

        box.space._cluster:update(id, {{'=', 2, other[2]}})
        t.assert_equals(box.info.replication[id].upstream.peer,
                        destination.peer)
        t.assert_equals(box.info.replication[id].upstream.status,
                        destination.status)
        box.space._cluster:insert{other_id, old_uuid, 'retained'}
        local retained = box.info.replication[other_id].upstream
        t.assert_equals(retained.peer, source.peer)
        t.assert_equals(retained.message, source.message)
        t.assert_equals(retained.status, 'stopped')
    end, {old_uuid, id, other_id})
end
