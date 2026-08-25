-- Client-side benchmark of the three ways to perform a replace on
-- a remote tarantool: IPROTO_REPLACE, IPROTO_CALL of a C stored
-- function that does box_replace(), and IPROTO_CALL of the same
-- function written in Lua.
--
-- The harness (fiber count, sampling, output columns) is a copy of
-- the vshard/crud DML benchmarks, so the numbers of the three
-- repositories are directly comparable. The server must already
-- run (see run.sh).
local clock = require('clock')
local fiber = require('fiber')
local netbox = require('net.box')

local SPACE_ID = 777
local KEY_COUNT = 100000
local BUCKET_COUNT = 3000
local URI = os.getenv('BENCH_URI') or 'bench:bench@127.0.0.1:3331'

local FIBERS = tonumber(os.getenv('BENCH_FIBERS')) or 10
local DURATION = tonumber(os.getenv('BENCH_DURATION')) or 10
local WARMUP = tonumber(os.getenv('BENCH_WARMUP')) or 2
-- Sample every Nth request latency to keep the overhead low.
local SAMPLE = 16

local conn = netbox.connect(URI, {reconnect_after = 0.1})
local deadline = clock.monotonic() + 60
while not conn:is_connected() or conn.space.bench == nil do
    if clock.monotonic() > deadline then
        io.stderr:write('the server is not available\n')
        os.exit(1)
    end
    fiber.sleep(0.1)
    conn:reload_schema()
end

local payload = string.rep('x', 32)

local function tuple(i)
    return {i % KEY_COUNT, i % BUCKET_COUNT + 1, payload}
end

local workloads = {
    {
        name = 'iproto replace',
        call = function(i)
            return conn.space.bench:replace(tuple(i))
        end,
    },
    {
        name = 'call C replace',
        call = function(i)
            return conn:call('bench_c.replace', {SPACE_ID, tuple(i)})
        end,
    },
    {
        name = 'call C replace noret',
        call = function(i)
            return conn:call('bench_c.replace_noret', {SPACE_ID, tuple(i)})
        end,
    },
    {
        name = 'call Lua replace',
        call = function(i)
            return conn:call('bench_replace_lua', {tuple(i)})
        end,
    },
    {
        name = 'call Lua replace noret',
        call = function(i)
            return conn:call('bench_replace_noret_lua', {tuple(i)})
        end,
    },
    {
        name = 'iproto select (get)',
        call = function(i)
            return conn.space.bench:get(i % KEY_COUNT)
        end,
    },
    {
        name = 'call C get',
        call = function(i)
            return conn:call('bench_c.get', {SPACE_ID, i % KEY_COUNT})
        end,
    },
    {
        name = 'call Lua get',
        call = function(i)
            return conn:call('bench_get_lua', {i % KEY_COUNT})
        end,
    },
}

local function percentile(sorted, p)
    if #sorted == 0 then
        return 0
    end
    local idx = math.max(1, math.ceil(#sorted * p))
    return sorted[idx]
end

local function run_workload(w)
    local stop = false
    local measuring = false
    local counts = {}
    local errors = 0
    local lats = {}
    local fibers = {}
    for f = 1, FIBERS do
        counts[f] = 0
        fibers[f] = fiber.new(function()
            local i = f * 1000003
            while not stop do
                i = i + 1
                local sample = measuring and i % SAMPLE == 0
                local t0
                if sample then
                    t0 = clock.monotonic64()
                end
                local ok = pcall(w.call, i)
                if not ok then
                    errors = errors + 1
                elseif sample then
                    table.insert(lats,
                                 tonumber(clock.monotonic64() - t0) / 1e3)
                end
                counts[f] = counts[f] + 1
            end
        end)
        fibers[f]:set_joinable(true)
    end
    local function total()
        local s = 0
        for f = 1, FIBERS do
            s = s + counts[f]
        end
        return s
    end
    fiber.sleep(WARMUP)
    local c0 = total()
    lats = {}
    measuring = true
    local t0 = clock.monotonic()
    fiber.sleep(DURATION)
    local c1 = total()
    local elapsed = clock.monotonic() - t0
    stop = true
    for f = 1, FIBERS do
        fibers[f]:join()
    end
    table.sort(lats)
    return {
        rps = (c1 - c0) / elapsed,
        p50 = percentile(lats, 0.50),
        p95 = percentile(lats, 0.95),
        p99 = percentile(lats, 0.99),
        errors = errors,
    }
end

print(('# %s, fibers: %d, duration: %ds'):format(
      os.getenv('BENCH_LABEL') or 'tarantool replace paths', FIBERS, DURATION))
print(('%-24s %10s %9s %9s %9s %7s'):format(
      'workload', 'RPS', 'p50(us)', 'p95(us)', 'p99(us)', 'errors'))
for _, w in ipairs(workloads) do
    local r = run_workload(w)
    print(('%-24s %10.0f %9.1f %9.1f %9.1f %7d'):format(
          w.name, r.rps, r.p50, r.p95, r.p99, r.errors))
end

-- The ceiling: the same replaces executed by the server's own
-- fibers, without IPROTO and without a client.
local res = conn:call('bench_local_loop', {FIBERS, DURATION, WARMUP},
                      {timeout = DURATION + WARMUP + 30})
print(('%-24s %10.0f %9s %9s %9s %7d'):format(
      'local replace (no net)', res.rps or res[1].rps, '-', '-', '-', 0))
os.exit(0)
