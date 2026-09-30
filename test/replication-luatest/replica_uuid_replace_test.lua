local t = require('luatest')
local server = require('luatest.server')

local g = t.group()

g.before_each(function(cg)
    cg.master = server:new({alias = 'master'})
    cg.master:start()
end)

g.after_each(function(cg)
    if cg.anon ~= nil then
        cg.anon:drop()
    end
    cg.master:drop()
end)

g.test_rollback_chain = function(cg)
    cg.master:exec(function()
        local uuid = require('uuid')
        local old = box.space._cluster:insert{2, uuid.str(), 'replica'}
        local intermediate_uuid = uuid.str()
        box.begin()
        box.space._cluster:update(2, {{'=', 2, intermediate_uuid}})
        local savepoint = box.savepoint()
        box.space._cluster:update(2, {{'=', 2, uuid.str()}})
        box.rollback_to_savepoint(savepoint)
        t.assert_equals(box.info.replication[2].uuid, intermediate_uuid)
        box.rollback()
        t.assert_equals(box.space._cluster:get{2}, old)
        t.assert_equals(box.info.replication[2].uuid, old[2])
        t.assert_equals(box.info.replication[2].name, old[3])
    end)
end

g.test_commit_chain = function(cg)
    cg.master:exec(function()
        local uuid = require('uuid')
        local old = box.space._cluster:insert{2, uuid.str(), 'replica'}
        for _, final_uuid in ipairs({old[2], uuid.str()}) do
            box.begin()
            box.space._cluster:update(2, {{'=', 2, uuid.str()}})
            box.space._cluster:update(2, {{'=', 2, final_uuid}})
            box.commit()
            t.assert_equals(box.info.replication[2].uuid, final_uuid)
            t.assert_equals(box.info.replication[2].name, old[3])
        end
        -- Both the old UUID and the name must be reusable.
        box.space._cluster:delete{2}
        box.space._cluster:insert(old)
        t.assert_equals(box.info.replication[2].uuid, old[2])
        t.assert_equals(box.info.replication[2].name, old[3])
    end)
end

g.test_rollback_to_anonymous_replica = function(cg)
    cg.anon = server:new({
        alias = 'anon',
        box_cfg = {
            replication = {cg.master.net_box_uri},
            replication_anon = true,
            read_only = true,
        },
    })
    cg.anon:start()
    local anon_uuid = tostring(cg.anon:get_instance_uuid())
    cg.master:exec(function(anon_uuid)
        local old = box.space._cluster:insert{2, require('uuid').str(),
                                             'replica'}
        t.helpers.retrying({}, function()
            t.assert_not_equals(box.info.replication_anon()[anon_uuid], nil)
        end)
        box.begin()
        box.space._cluster:update(2, {{'=', 2, anon_uuid}})
        box.rollback()
        t.assert_equals(box.space._cluster:get{2}, old)
        t.assert_equals(box.info.replication[2].uuid, old[2])
        t.assert_not_equals(box.info.replication_anon()[anon_uuid], nil)
    end, {anon_uuid})
end
