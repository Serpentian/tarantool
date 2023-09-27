local server = require('luatest.server')
local t = require('luatest')

local g = t.group("Upgrade to 3.0.0")

g.before_each(function(cg)
    cg.server = server:new({
        datadir = 'test/box-luatest/upgrade/2.11.0',
    })
    cg.server:start()
    cg.server:exec(function()
        t.assert_equals(box.space._schema:get{'version'}, {'version', 2, 11, 0})
    end)
end)

g.after_each(function(cg)
    cg.server:drop()
end)

g.test_new_replicaset_uuid_key = function(cg)
    cg.server:exec(function()
        box.schema.upgrade()
        local _schema = box.space._schema
        t.assert_equals(_schema:get{'cluster'}, nil)
        t.assert_equals(_schema:get{'replicaset_uuid'}.value,
                        box.info.replicaset.uuid)
    end)
end

g.test_noop_before_upgrade = function(cg)
    cg.server:exec(function()
            local cfg = {
                instance_name = 'instance',
                replicaset_name = 'replicaset',
                cluster_name = 'cluster',
            }

            -- It is allowed to set names on 2.11.0 schema, but this is NoOp.
            box.cfg(cfg)
            local info = box.info
            t.assert_equals(info.name, nil)
            t.assert_equals(info.replicaset.name, nil)
            t.assert_equals(info.cluster.name, nil)

            -- After schema upgrade names must be set one more time.
            box.schema.upgrade()
            box.cfg(cfg)
            info = box.info
            t.assert_equals(info.name, 'instance')
            t.assert_equals(info.replicaset.name, 'replicaset')
            t.assert_equals(info.cluster.name, 'cluster')
    end)
end
