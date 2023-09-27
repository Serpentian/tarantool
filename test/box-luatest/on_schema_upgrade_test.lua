local server = require('luatest.server')
local t = require('luatest')

local g = t.group('on_schema_upgrade')

g.before_all(function(cg)
    --
    -- It is allowed to set names on 2.11.0 schema, but this is NoOp.
    -- Test, that instance is able to start on 2.11 schema with names.
    --
    cg.box_cfg = {
        instance_name = 'instance',
        replicaset_name = 'replicaset',
        cluster_name = 'cluster',
    }
    cg.server = server:new({
        datadir = 'test/box-luatest/upgrade/2.11.0',
        box_cfg = cg.box_cfg
    })
    cg.server:start()
    cg.server:exec(function()
        local info = box.info
        t.assert_equals(info.name, nil)
        t.assert_equals(info.replicaset.name, nil)
        t.assert_equals(info.cluster.name, nil)
        t.assert_equals(box.space._schema:get{'version'}, {'version', 2, 11, 0})
    end)
end)

g.after_all(function(cg)
    cg.server:stop()
end)

g.test_on_schema_upgrade = function(cg)
    cg.server:exec(function(cfg)
        local mkversion = require('internal.mkversion')
        local function set_names_on_upgrade(old_version, new_version)
            local version_3 = mkversion(3, 0, 0)
            if (old_version < version_3 and new_version >= version_3) then
                box.cfg(cfg)
            end
        end

        -- It's allowed to execute DDL in this trigger
        box.internal.on_schema_upgrade(set_names_on_upgrade)
        box.schema.upgrade()

        local info = box.info
        t.assert_equals(info.name, cfg.instance_name)
        t.assert_equals(info.replicaset.name, cfg.replicaset_name)
        t.assert_equals(info.cluster.name, cfg.cluster_name)
    end, {cg.box_cfg})
end
