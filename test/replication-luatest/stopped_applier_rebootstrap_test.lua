local fio = require('fio')
local replica_set = require('luatest.replica_set')
local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

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

g.before_each(function(cg)
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
end)

g.after_each(function(cg)
    cg.replica_set:drop()
end)

g.test_rebootstrap = function(cg)
    local old_uuid, id = stop_master_applier(cg)
    cg.replica:drop()
    fio.rmtree(cg.replica.workdir)
    cg.replica:start()
    t.assert_not_equals(tostring(cg.replica:get_instance_uuid()), old_uuid)
    t.assert_equals(cg.replica:get_instance_id(), id)
    cg.master:exec(function(id)
        t.assert_equals(box.info.replication[id].upstream, nil)
        box.space._schema:insert{'after_rebootstrap'}
    end, {id})
    cg.replica:wait_for_vclock_of(cg.master)
    cg.replica:exec(function()
        t.assert_equals(box.space._schema:get{'after_rebootstrap'}:totable(),
                        {'after_rebootstrap'})
    end)
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
