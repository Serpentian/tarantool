local t = require('luatest')
local server = require('luatest.server')
local cluster = require('test.luatest_helpers.cluster')

local g = t.group('gh-7590')

g.before_all(function(g)
    g.cluster = cluster:new({})
    g.master = g.cluster:build_and_add_server({alias = 'master'})
    g.replica = g.cluster:build_and_add_server({alias = 'replica', box_cfg = {
        replication = {
            server.build_listen_uri('master'),
        },
    }})

    g.cluster:start()
    g.master:exec(function()
        box.schema.create_space('test'):create_index('pk')
    end)

    g.replica:wait_for_vclock_of(g.master)
end)

g.after_all(function(g)
    g.cluster:stop()
end)

g.test_fail = function(g)
    g.replica:exec(function()
        -- Throw ClientError as soon as write
        -- request from the master was received.
        box.error.injection.set('ERRINJ_WAL_IO', true)
        -- Forbid to end the destruction of the applier from the thread.
        -- Simulate long cbus_call from the main thread to applier.
        box.error.injection.set('ERRINJ_APPLIER_DESTROY_DELAY', true);
    end)

    g.master:exec(function()
        -- Trigger writing to replica
        box.space.test:insert({1})
    end)

    t.helpers.retrying({timeout = 5}, function()
        if not g.replica:grep_log('applier destroy is delayed') then
            error("Applier destruction haven't started yet")
        end
    end)

    g.replica:exec(function()
        box.error.injection.set('ERRINJ_WAL_IO', false)
        box.error.injection.set('ERRINJ_APPLIER_DESTROY_DELAY', false)
        -- Simulate more then one instance dropping via replicaset_update.
        box.error.injection.set('ERRINJ_REPLICASET_UPDATE_DELAY', true)
        box.cfg({replication = {}})
    end)
end
