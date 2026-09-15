local fio = require('fio')
local msgpack = require('msgpack')
local replica_set = require('luatest.replica_set')
local server = require('luatest.server')
local socket = require('socket')
local t = require('luatest')
local uri_lib = require('uri')

local g = t.group('rebootstrap_upstreams')

local function start_replicaset(cg)
    cg.replica_set = replica_set:new({})
    local replication = {
        server.build_listen_uri('master', cg.replica_set.id),
        server.build_listen_uri('replica', cg.replica_set.id),
    }
    local box_cfg = {
        replication = replication,
        replication_timeout = 0.1,
        replication_connect_timeout = 10,
        replication_sync_timeout = 120,
        instance_name = 'master',
    }
    cg.master = cg.replica_set:build_and_add_server({
        alias = 'master', box_cfg = box_cfg,
    })
    box_cfg.instance_name = 'replica'
    box_cfg.read_only = true
    cg.replica = cg.replica_set:build_and_add_server({
        alias = 'replica', box_cfg = box_cfg,
    })
    cg.replica_set:start()
    cg.replica_set:wait_for_fullmesh()
    cg.master:exec(function()
        box.schema.space.create('test'):create_index('pk')
    end)
    cg.replica:wait_for_vclock_of(cg.master)
end

local function drop_replicaset(cg)
    if cg.socket ~= nil then
        cg.socket:close()
    end
    cg.replica_set:drop()
end

g.before_each(start_replicaset)
g.after_each(drop_replicaset)

local function get_upstream(instance, uuid)
    return instance:exec(function(uuid)
        for _, upstream in ipairs(box.info.replication_upstreams) do
            if upstream.uuid == uuid then
                return upstream
            end
        end
    end, {uuid})
end

local function stop_master_applier(cg)
    local old_uuid = tostring(cg.replica:get_instance_uuid())
    local old_id = cg.replica:get_instance_id()
    cg.replica:exec(function()
        box.cfg{replication = {}}
    end)
    cg.master:exec(function()
        box.space._schema:insert{'conflict'}
    end)
    cg.replica:exec(function()
        box.cfg{read_only = false}
        box.space._schema:insert{'conflict'}
    end)
    t.helpers.retrying({}, function()
        local upstream = get_upstream(cg.master, old_uuid)
        t.assert_equals(upstream.status, 'stopped')
        t.assert_str_contains(upstream.message, 'Duplicate key exists')
        cg.master:exec(function(old_id)
            t.assert_equals(box.info.replication[old_id].downstream.status,
                            'stopped')
        end, {old_id})
    end)
    return old_uuid, old_id
end

local function assert_retired_upstream(cg, uuid)
    local upstream = get_upstream(cg.master, uuid)
    t.assert_equals(upstream.status, 'stopped')
    t.assert_str_contains(upstream.message, 'Duplicate key exists')
    t.assert_equals(upstream.peer,
                    uri_lib.format(uri_lib.parse(cg.replica.net_box_uri)))
    t.assert_equals(upstream.id, nil)
    t.assert_equals(upstream.name, nil)
end

local function rebootstrap(cg, delete_registration)
    local old_uuid, old_id = stop_master_applier(cg)
    for i = 1, 2 do
        cg.replica:drop()
        if delete_registration then
            cg.master:exec(function(old_id)
                box.space._cluster:delete{old_id}
                t.assert_equals(box.info.replication[old_id], nil)
            end, {old_id})
            assert_retired_upstream(cg, old_uuid)
        end
        fio.rmtree(cg.replica.workdir)
        cg.replica:start()
        local new_uuid = tostring(cg.replica:get_instance_uuid())
        t.assert_not_equals(new_uuid, old_uuid)
        t.assert_equals(cg.replica:get_instance_id(), old_id)
        assert_retired_upstream(cg, old_uuid)
        cg.master:exec(function(old_id, new_uuid, value)
            t.assert_equals(box.info.replication[old_id].uuid, new_uuid)
            t.assert_equals(box.info.replication[old_id].name, 'replica')
            t.assert_equals(box.info.replication[old_id].upstream, nil)
            box.space.test:insert{value}
        end, {old_id, new_uuid, i})
        cg.replica:wait_for_vclock_of(cg.master)
        cg.replica:exec(function(value)
            t.assert_equals(box.space.test:get{value}:totable(), {value})
        end, {i})
    end
    cg.master:exec(function()
        local replication = box.cfg.replication
        box.cfg{replication = {}}
        t.assert_equals(box.info.replication_upstreams, {})
        box.cfg{replication = replication}
    end)
    cg.replica_set:wait_for_fullmesh()
    t.assert_equals(get_upstream(cg.master, old_uuid), nil)
    cg.replica:exec(function()
        box.cfg{read_only = false}
        box.space.test:insert{3}
    end)
    cg.master:wait_for_vclock_of(cg.replica)
    cg.master:exec(function()
        t.assert_equals(box.space.test:get{3}:totable(), {3})
    end)
end

g.test_rebootstrap = function(cg)
    rebootstrap(cg, false)
end

g.test_delete_then_rebootstrap = function(cg)
    rebootstrap(cg, true)
end

local function register(cg, delete_registration)
    local old_uuid, old_id = stop_master_applier(cg)
    cg.replica:stop()
    if delete_registration then
        cg.master:exec(function(old_id)
            box.space._cluster:delete{old_id}
        end, {old_id})
    end
    local new_uuid = require('uuid').str()
    local vclock = cg.master:get_vclock()
    vclock[0] = nil
    setmetatable(vclock, {__serialize = 'map'})
    local uri = uri_lib.parse(cg.master.net_box_uri)
    cg.socket = socket.tcp_connect(uri.host, uri.service)
    local timeout = 120
    t.assert_equals(#cg.socket:read(box.iproto.GREETING_SIZE, timeout),
                    box.iproto.GREETING_SIZE)
    local key = box.iproto.key
    local header = {
        [key.REQUEST_TYPE] = box.iproto.type.REGISTER,
        [key.SYNC] = 1,
    }
    local body = {
        [key.INSTANCE_UUID] = new_uuid,
        [key.INSTANCE_NAME] = 'replica',
        [key.VCLOCK] = vclock,
    }
    cg.socket:write(box.iproto.encode_packet(header, body))
    repeat
        local size_mp = cg.socket:read(5, timeout)
        t.assert_equals(#size_mp, 5)
        local size = msgpack.decode(size_mp)
        local response = cg.socket:read(size, timeout)
        t.assert_equals(#response, size)
        header, body = box.iproto.decode_packet(size_mp .. response)
        t.assert_lt(header[key.REQUEST_TYPE], box.iproto.type.TYPE_ERROR, body)
    until header[key.REQUEST_TYPE] == box.iproto.type.OK
    cg.socket:close()
    cg.socket = nil
    cg.master:exec(function(old_id, new_uuid)
        t.assert_equals(box.space._cluster:get(old_id):totable(),
                        {old_id, new_uuid, 'replica'})
        t.assert_equals(box.info.replication[old_id].upstream, nil)
    end, {old_id, new_uuid})
    assert_retired_upstream(cg, old_uuid)
end

g.test_register = function(cg)
    register(cg, false)
end

g.test_delete_then_register = function(cg)
    register(cg, true)
end

g.test_incoming_connection_blocks_rebootstrap = function(cg)
    local old_uuid, old_id = stop_master_applier(cg)
    cg.replica:exec(function(master_uri)
        box.cfg{replication_skip_conflict = true}
        box.cfg{replication = {master_uri}}
    end, {cg.master.net_box_uri})
    cg.replica:wait_for_vclock_of(cg.master)
    t.helpers.retrying({}, function()
        cg.master:exec(function(old_id)
            t.assert_equals(box.info.replication[old_id].downstream.status,
                            'follow')
        end, {old_id})
    end)
    cg.master:exec(function(old_id, old_uuid)
        local space = box.space._cluster
        t.assert_error_msg_contains('old replica is still here',
                                    space.update, space, old_id,
                                    {{'=', 2, require('uuid').str()}})
        t.assert_equals(space:get(old_id)[2], old_uuid)
        t.assert_equals(box.info.replication[old_id].name, 'replica')
        t.assert_equals(box.info.replication[old_id].upstream.status, 'stopped')
    end, {old_id, old_uuid})
end

g.test_destination_has_applier = function(cg)
    t.tarantool.skip_if_not_debug()
    local new_uri = server.build_listen_uri('replacement', cg.replica_set.id)
    cg.master:exec(function(new_uri)
        local replication = table.copy(box.cfg.replication)
        table.insert(replication, new_uri)
        box.cfg{replication_connect_quorum = 0,
                replication_connect_timeout = 0.01, replication = replication}
    end, {new_uri})
    t.helpers.retrying({}, function()
        cg.master:assert_follows_upstream(cg.replica:get_instance_id())
    end)
    local old_uuid, old_id = stop_master_applier(cg)
    cg.replica:stop()
    local new_uuid = require('uuid').str()
    cg.replacement = cg.replica_set:build_and_add_server({
        alias = 'replacement',
        box_cfg = {
            instance_uuid = new_uuid,
            instance_name = 'replica',
            bootstrap_strategy = 'legacy',
            read_only = true,
            replication = {cg.master.net_box_uri},
        },
    })
    cg.master:exec(function()
        box.error.injection.set('ERRINJ_ENGINE_JOIN_DELAY', true)
    end)
    cg.replacement:start({wait_until_ready = false})
    t.helpers.retrying({}, function()
        t.assert_equals(get_upstream(cg.master, new_uuid).status, 'loading')
    end)
    cg.master:exec(function(old_id, old_uuid, new_uuid)
        box.begin()
        box.space._cluster:update(old_id, {{'=', 2, new_uuid}})
        box.rollback()
        t.assert_equals(box.info.replication[old_id].uuid, old_uuid)
        t.assert_equals(box.info.replication[old_id].upstream.status, 'stopped')
        box.error.injection.set('ERRINJ_ENGINE_JOIN_DELAY', false)
    end, {old_id, old_uuid, new_uuid})
    cg.replacement:wait_until_ready()
    t.helpers.retrying({}, function()
        cg.master:assert_follows_upstream(old_id)
        cg.replacement:assert_follows_upstream(cg.master:get_instance_id())
    end)
    assert_retired_upstream(cg, old_uuid)
    local upstream = get_upstream(cg.master, new_uuid)
    t.assert_equals(upstream.id, old_id)
    t.assert_equals(upstream.name, 'replica')
    t.assert_equals(upstream.peer, uri_lib.format(uri_lib.parse(new_uri)))
end

g.test_upstream_info = function(cg)
    cg.master:exec(function(replica_id)
        local upstreams = box.info.replication_upstreams
        t.assert_equals(#upstreams, 2)
        for _, upstream in ipairs(upstreams) do
            local info = box.info.replication[upstream.id]
            t.assert_equals(upstream.uuid, info.uuid)
            t.assert_equals(upstream.name, info.name)
            if upstream.id == replica_id then
                upstream.uuid, upstream.id, upstream.name = nil, nil, nil
                t.assert_equals(upstream, info.upstream)
            else
                t.assert_equals(upstream.status, 'off')
            end
        end
    end, {cg.replica:get_instance_id()})
    local uri = server.build_listen_uri('missing', cg.replica_set.id)
    cg.master:exec(function(uri)
        local uri_lib = require('uri')
        box.cfg{replication_connect_quorum = 0,
                replication_connect_timeout = 0.01,
                replication = {'guest:secret@' .. uri}}
        t.helpers.retrying({}, function()
            local upstreams = box.info.replication_upstreams
            t.assert_equals(#upstreams, 1)
            local upstream = upstreams[1]
            t.assert_equals(upstream.status, 'disconnected')
            t.assert_equals(upstream.uuid, nil)
            t.assert_equals(upstream.id, nil)
            t.assert_equals(upstream.name, nil)
            t.assert_equals(upstream.peer,
                            uri_lib.format(uri_lib.parse('guest@' .. uri)))
            t.assert_type(upstream.message, 'string')
        end)
        box.cfg{replication = {}}
        t.assert_equals(box.info.replication_upstreams, {})
    end, {uri})
end

local g_rollback = t.group('registration_rollback', t.helpers.matrix({
    applier = {true, false},
    change = {'uuid', 'delete'},
    rollback = {'explicit', 'wal', 'savepoint'},
}))

g_rollback.before_each(start_replicaset)
g_rollback.after_each(drop_replicaset)

g_rollback.test_restore_registration = function(cg)
    if cg.params.rollback == 'wal' then
        t.tarantool.skip_if_not_debug()
    end
    local old_uuid, old_id = stop_master_applier(cg)
    cg.master:exec(function(old_id, old_uuid, params)
        if not params.applier then
            box.cfg{replication = {}}
        end
        local tuple = box.space._cluster:get(old_id):totable()
        box.begin()
        local savepoint = box.savepoint()
        if params.change == 'delete' then
            box.space._cluster:delete{old_id}
        else
            -- Revisit a UUID to check overlapping transaction references.
            for _, uuid in ipairs({require('uuid').str(), old_uuid,
                                   require('uuid').str()}) do
                box.space._cluster:update(old_id, {{'=', 2, uuid}})
            end
        end
        if params.rollback == 'explicit' then
            box.rollback()
        elseif params.rollback == 'savepoint' then
            box.rollback_to_savepoint(savepoint)
            box.commit()
        else
            box.error.injection.set('ERRINJ_WAL_IO', true)
            local ok, err = pcall(box.commit)
            box.error.injection.set('ERRINJ_WAL_IO', false)
            t.assert_not(ok)
            t.assert_equals(err.code, box.error.WAL_IO)
        end
        t.assert_equals(box.space._cluster:get(old_id):totable(), tuple)
        local info = box.info.replication[old_id]
        t.assert_equals(info.uuid, old_uuid)
        t.assert_equals(info.name, 'replica')
        if params.applier then
            t.assert_equals(info.upstream.status, 'stopped')
            t.assert_str_contains(info.upstream.message, 'Duplicate key exists')
        else
            t.assert_equals(info.upstream, nil)
        end
    end, {old_id, old_uuid, cg.params})
end
