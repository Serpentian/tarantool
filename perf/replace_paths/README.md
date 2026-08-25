# How to run the replace-paths benchmark

Answers one question: how many replaces per second a single
tarantool serves, depending on *how* the client asks for them —

| path | what happens on the server |
|---|---|
| `IPROTO_REPLACE` | the request goes straight to the space, no user code at all |
| `IPROTO_CALL` of a C function | `box_process_call` → the `_func` registry → `box_replace()`, no Lua |
| `IPROTO_CALL` of a Lua function | the same, but the body is `box.space.bench:replace()` in Lua |
| local loop | the server's own fibers replace in a loop — no IPROTO, no client |

It is the baseline for the vshard and the crud storage-side
benchmarks: same tuple, same key range, same client harness (fiber
count, latency sampling, output columns), so the three sets of
numbers can be put side by side. See `RESULTS.md`.

Unlike the tests in `perf/lua`, this one is shell-driven and needs
two processes (a server and a client), so it is not wired into
CMake/ctest — run it by hand.

## 1. Build the C module

```sh
perf/replace_paths/build.sh [path-to-tarantool-src]
```

The path defaults to this source tree; it is used for headers
(`src/module.h`, msgpuck, luajit) and for linking `libmsgpuck.a`
statically, so it need not be the tree the binary being measured
was built from. `run.sh` builds the module itself if it is
missing.

## 2. Run

```sh
perf/replace_paths/run.sh <tarantool-binary>
```

Use a release build (`RelWithDebInfo`); a Debug build is dominated
by assertions and its numbers mean nothing.

Environment:

| variable | default | meaning |
|---|---|---|
| `BENCH_FIBERS` | 10 | concurrent request fibers in the client |
| `BENCH_DURATION` | 10 | measured seconds per row |
| `BENCH_WARMUP` | 2 | warmup seconds before measuring |
| `BENCH_WORK` | `/tmp/tnt_replace_bench` | working directory of the two instances |
| `BENCH_WAL_MODE` | `write` | `wal_mode` of the server |

Example:

```sh
BENCH_FIBERS=50 BENCH_DURATION=20 \
    perf/replace_paths/run.sh ~/tarantool/src/tarantool
```

## 3. Reading the output

Columns: RPS, then p50/p95/p99 in microseconds, then the error
count (must be 0).

`IPROTO_REPLACE` always sends the new tuple back, while a stored
function returns only what it returns — hence two flavours of each
call row: the plain one returns the tuple (comparable to
`IPROTO_REPLACE`), the `noret` one returns nothing (comparable to
the vshard storage functions, which discard the result).

The client is a single process: rows above ~150k RPS may be
client-bound, so re-run with more fibers before concluding that
two paths are equally fast. Run-to-run variance on a loaded
machine reaches tens of percent — compare rows within one run.

## 4. Cleanup

`run.sh` kills the server on exit. After an interrupted run:

```sh
pkill -f 'replace_paths/server.lua'
rm -rf /tmp/tnt_replace_bench
```
