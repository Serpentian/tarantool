local t = require('luatest')
local server = require('luatest.server')
local cluster = require('test.luatest_helpers.cluster')

local g = t.group('gh-7590')

g.before_all(function(g)
    g.cluster = cluster:new({})

    g.box_cfg = {
        replication = {
            server.build_listen_uri('r1'),
            server.build_listen_uri('r2'),
        },
    }

    g.r1 = g.cluster:build_and_add_server({alias = 'r1', box_cfg = g.box_cfg})
    g.r2 = g.cluster:build_and_add_server({alias = 'r2', box_cfg = g.box_cfg})

    g.cluster:start()
    g.r1:exec(function()
        box.schema.create_space('test'):create_index('pk')
    end)

    g.r2:wait_for_vclock_of(g.r1)
end)

g.after_all(function(g)
    g.cluster:stop()
end)

g.test_fail = function(g)
    g.r2:exec(function()
        -- box.error.injection.set('ERRINJ_WAL_IO', true)
        box.error.injection.set('ERRINJ_APPLIER_STOP', 0)
        box.error.injection.set('ERRINJ_APPLIER_DESTROY_DELAY', true);
    end)

    g.r1:exec(function()
        box.space.test:insert({1})
    end)

    -- t.helpers.retrying({timeout = 5}, function()
    --     --if not g.r3:grep_log('applier destroy is delayed') then
    --     if not g.r3:grep_log('ER_WAL_IO') then
    --         error("Replica haven' got the error message yet")
    --     end
    -- end)

    g.r2:exec(function()
        local log = require('log')
        require('luatest').helpers.retrying({timeout = 15, delay = 0.01}, function()
            log.info('waiting')
            local errinj = box.error.injection.get('ERRINJ_APPLIER_STOP')
            if errinj ~= 2 then
                error("Applier haven't got the error message yet")
            end
        end)

        -- box.error.injection.set('ERRINJ_WAL_IO', false)
        log.info('Reconfigure: %d idx',
                 box.error.injection.get('ERRINJ_APPLIER_STOP'))
        box.error.injection.set('ERRINJ_APPLIER_STOP', -1)
        box.cfg({replication = {}})
        box.error.injection.set('ERRINJ_APPLIER_DESTROY_DELAY', false);
        require('fiber').yield()
    end)
end
