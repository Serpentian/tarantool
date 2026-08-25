-- Server instance for the replace-path benchmark. Launched by
-- run.sh with LUA_CPATH pointing at this directory (bench_c.so).
local fio = require('fio')
local fiber = require('fiber')
local clock = require('clock')

local SPACE_ID = 777
local KEY_COUNT = 100000
local BUCKET_COUNT = 3000

box.cfg({
    listen = os.getenv('BENCH_LISTEN') or '127.0.0.1:3331',
    wal_mode = os.getenv('BENCH_WAL_MODE') or 'write',
    memtx_memory = 512 * 1024 * 1024,
    log_level = 4,
})

box.schema.user.create('bench', {password = 'bench', if_not_exists = true})
box.schema.user.grant('bench', 'super', nil, nil, {if_not_exists = true})

-- The very same space the vshard and the crud benchmarks use:
-- {id, bucket_id, payload}, a TREE primary index over id. There
-- is no sharding here, the bucket_id field is filled in just to
-- keep the tuples byte-identical.
box.schema.space.create('bench', {id = SPACE_ID, if_not_exists = true})
box.space.bench:format({
    {'id', 'unsigned'}, {'bucket_id', 'unsigned'}, {'payload', 'string'}})
box.space.bench:create_index('pk', {if_not_exists = true})

for _, name in ipairs({'bench_c.replace', 'bench_c.replace_noret',
                       'bench_c.get'}) do
    box.schema.func.create(name, {language = 'C', if_not_exists = true})
end

-- Lua twins of the C functions.
rawset(_G, 'bench_replace_lua', function(tuple)
    return box.space.bench:replace(tuple)
end)
rawset(_G, 'bench_replace_noret_lua', function(tuple)
    box.space.bench:replace(tuple)
end)
rawset(_G, 'bench_get_lua', function(id)
    return box.space.bench:get(id)
end)
rawset(_G, 'echo_lua', function(...)
    return ...
end)

-- The no-network ceiling: the same workload run by fibers of the
-- server itself, so the result is the pure engine + WAL cost with
-- neither IPROTO nor a client in the picture.
rawset(_G, 'bench_local_loop', function(nfibers, seconds, warmup)
    local payload = string.rep('x', 32)
    local count = 0
    local stop = false
    local fibers = {}
    for f = 1, nfibers do
        fibers[f] = fiber.new(function()
            local i = f * 1000003
            while not stop do
                i = i + 1
                box.space.bench:replace({i % KEY_COUNT,
                                         i % BUCKET_COUNT + 1, payload})
                count = count + 1
            end
        end)
        fibers[f]:set_joinable(true)
    end
    fiber.sleep(warmup)
    local c0 = count
    local t0 = clock.monotonic()
    fiber.sleep(seconds)
    local rps = (count - c0) / (clock.monotonic() - t0)
    stop = true
    for f = 1, nfibers do
        fibers[f]:join()
    end
    return {rps = rps}
end)

local f = fio.open('server.pid', {'O_CREAT', 'O_WRONLY', 'O_TRUNC'},
                   tonumber('644', 8))
f:write(tostring(box.info.pid))
f:close()
print('server is ready')
