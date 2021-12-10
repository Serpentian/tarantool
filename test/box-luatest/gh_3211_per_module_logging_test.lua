local server = require('test.luatest_helpers.server')
local t = require('luatest')
local g = t.group()

local function module_name_is_in_logs(logs_module_name, level)
    t.helpers.retrying({timeout = 0.3, delay = 0.1}, function()
        local msg = logs_module_name .. " " .. level .. ">"
        t.assert(g.server:grep_log(msg))
    end)
end

local function configure_server_with_printing_module()
    g.server = server:new({alias = 'with_option',
                           box_cfg = {log_print_module_name=true}})
    g.server:start()
end

g.before_test("test_with_option", configure_server_with_printing_module)
g.after_test("test_with_option", function() g.server:drop() end)

g.test_with_option = function()
    g.server:exec(function()
        testmod = require('test.box-luatest.gh_3211_modules.testmod')
        testmod.make_logs()
    end)
    module_name_is_in_logs('testmod', "I")
end

g.before_test("test_without_option", function()
    g.server = server:new({alias = 'without_option'})
    g.server:start()
end)
g.after_test("test_without_option", function() g.server:drop() end)

g.test_without_option = function()
    t.xfail('Must fail because log_print_module_name=false by default')
    g.test_with_option()
end

g.before_test("test_is_local_for_each_module", configure_server_with_printing_module)
g.after_test("test_is_local_for_each_module", function() g.server:drop() end)

g.test_is_local_for_each_module = function()
    g.server:exec(function()
        testmod = require('test.box-luatest.gh_3211_modules.testmod')
        testmod3 = require('test.box-luatest.gh_3211_modules.testmod3')
        testmod3.make_logs()
        testmod.make_logs()
    end)
    module_name_is_in_logs('testmod', "I")
end

g.before_test("test_module_with_other_modules", configure_server_with_printing_module)
g.after_test("test_module_with_other_modules", function() g.server:drop() end)

g.test_module_with_other_modules = function()
    g.server:exec(function()
        testmod2 = require('test.box-luatest.gh_3211_modules.testmod2')
        testmod2.make_logs()
    end)
    module_name_is_in_logs('testmod2', "I")
    module_name_is_in_logs('testmod', "I")
end

g.before_test("test_expirationd", function()
    configure_server_with_printing_module()
    g.server:exec(function()
        local s = box.schema.space.create('test')
        s:format({
            {name = 'id',   type = 'unsigned'},
            {name = 'data', type = 'string'},
        })
        s:create_index('primary', {parts = {'id'}})
        box.schema.user.grant('guest', 'read,write', 'space', 'test')
        box.space.test:insert({1, "some data"})
    end)
end)
g.after_test("test_expirationd", function()
    g.server:exec(function()
        local s = box.space.test
        if s then
            s:drop()
        end
    end)
    g.server:drop()
end)

g.test_expirationd = function()
    g.server:exec(function()
        local t = require('luatest')
        local space = box.space.test
        local job_name = "clean_all"
        local status, expirationd = pcall(require,"expirationd")

        t.skip_if(not status, expirationd)

        local function is_expired(args, tuple)
            return true
        end

        local function delete_tuple(space_id, args, tuple)
            box.space[space_id]:delete{tuple[1]}
        end

        expirationd.start(job_name, space.id, is_expired, {
            process_expired_tuple = delete_tuple,
            args = nil,
            tuples_per_iteration = 50,
            full_scan_time = 3600
        })
    end)
    module_name_is_in_logs('expirationd', "I")
end
