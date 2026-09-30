local t = require('luatest')
local server = require('luatest.server')

local g = t.group(nil, t.helpers.matrix({
    rollback = {'explicit', 'savepoint', 'wal'},
}))

g.before_each(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_each(function(cg)
    cg.server:drop()
end)

g.test_uuid_update_rollback = function(cg)
    if cg.params.rollback == 'wal' then
        t.tarantool.skip_if_not_debug()
    end
    cg.server:exec(function(rollback)
        local uuid = require('uuid')
        local old_uuid = uuid.str()
        local new_uuid = uuid.str()
        local tuple = box.space._cluster:insert{2, old_uuid, 'replica'}
        local function update_uuid()
            box.space._cluster:update(2, {{'=', 2, new_uuid}})
        end

        if rollback == 'wal' then
            box.error.injection.set('ERRINJ_WAL_WRITE', true)
            local ok, err = pcall(update_uuid)
            box.error.injection.set('ERRINJ_WAL_WRITE', false)
            t.assert_not(ok)
            t.assert_equals(err.code, box.error.WAL_IO)
        else
            box.begin()
            local savepoint = box.savepoint()
            update_uuid()
            t.assert_equals(box.info.replication[2].uuid, new_uuid)
            if rollback == 'savepoint' then
                box.rollback_to_savepoint(savepoint)
                box.commit()
            else
                box.rollback()
            end
        end

        t.assert_equals(box.space._cluster:get{2}, tuple)
        local info = box.info.replication[2]
        t.assert_equals(info.id, 2)
        t.assert_equals(info.uuid, old_uuid)
        t.assert_equals(info.name, 'replica')
        t.assert_equals(box.info.replication[box.info.id].uuid, box.info.uuid)
    end, {cg.params.rollback})
end
