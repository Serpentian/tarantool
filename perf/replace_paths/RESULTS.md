# Replace paths: raw IPROTO vs a stored function, and what vshard and crud add on top

Date: 2026-08-25. One local dev box, 16 cores. Tarantool
3.9.0-entrypoint-86 RelWithDebInfo (a build of this tree with the
`box_func_call_by_name` patch). Memtx, `wal_mode = write`, one
server process and one client process over TCP on localhost.

**Everything below was measured in a single session, one benchmark
at a time, with the same binary, the same tuple
(`{id, bucket_id, <32-byte string>}`), the same 100k key range and
the same client harness.** That is the only way these numbers may
be put side by side: run-to-run variance on this machine reaches
tens of percent.

Reproduce:

```sh
BENCH_FIBERS=50 perf/replace_paths/run.sh <tarantool-binary>          # this table
BENCH_FIBERS=50 <vshard>/test/perf/c_call/run.sh <tarantool-binary>   # vshard
BENCH_FIBERS=50 <crud>/test/perf/c_dml/run.sh   <tarantool-binary>    # crud
```

## 1. The baseline: how a replace is asked for

RPS / p50 µs, 10 s per row after a 2 s warmup.

| path | 10 fibers | 50 fibers |
|---|---|---|
| local loop, no IPROTO, no client | 448 902 | **513 135** |
| `IPROTO_REPLACE` (returns the tuple) | 117 397 / 74 | **277 675** / 134 |
| `IPROTO_CALL` → C func, returns nothing | 153 121 / 51 | **362 327** / 124 |
| `IPROTO_CALL` → C func, returns the tuple | 84 385 / 106 | 177 233 / 304 |
| `IPROTO_CALL` → Lua func, returns nothing | 114 354 / 92 | 127 985 / 355 |
| `IPROTO_CALL` → Lua func, returns the tuple | 96 842 / 86 | 91 490 / 488 |

Reads, same runs:

| path | 10 fibers | 50 fibers |
|---|---|---|
| `IPROTO_SELECT` (`space:get`) | 161 145 | 287 604 |
| `IPROTO_CALL` → C `box_index_get()` | 129 897 | **440 596** |
| `IPROTO_CALL` → Lua `space:get()` | 131 497 | 213 949 |

At 10 fibers the single client process is the bottleneck (the
rows cluster around 100–160k and even swap places between runs);
the 50-fiber column is the one to read.

What it says:

- The server itself can do ~513k replaces/s on this box. IPROTO
  costs about half of that: 278k.
- A C stored function is *not* a tax on the write path. Calling
  one that returns nothing is **1.3x faster than IPROTO_REPLACE**
  (362k vs 278k) — because IPROTO_REPLACE always ships the new
  tuple back and the call does not.
- Compared like for like (both returning the tuple), the call
  costs 1.6x: 177k vs 278k. Returning a tuple out of a stored
  function — `box_return_tuple()` → port → encode — is the single
  most expensive item on this list: 362k → 177k, a 2x drop.
- The same function in Lua costs another 1.4–2.8x on top of the C
  one (128k vs 362k with no return value), and it degrades with
  concurrency instead of scaling: 114k → 128k from 10 to 50
  fibers, against 153k → 362k for C.

## 2. Against vshard

vshard rows are `test/perf/c_call/run.sh` from the C-storage.call
prototype branch, same session, 50 fibers. "direct" is
`net.box:call('vshard.storage*.call', ...)` straight to the
storage, "router" goes through `vshard.router.call`. The vshard
bench functions return nothing, so the honest baseline for them is
the *noret* row.

| replace, 50 fibers | RPS | share of the 362k C-call baseline |
|---|---|---|
| baseline: `IPROTO_CALL` → C func, noret | 362 327 | 100% |
| vshard direct, C wrapper + C func | 160 078 | 44% |
| vshard direct, Lua wrapper + C func | 158 850 | 44% |
| vshard router, C wrapper + C func | 119 685 | 33% |
| vshard router, Lua wrapper + C func | 96 779 | 27% |
| vshard router, Lua wrapper + Lua func | 67 541 | 19% |

| get, 50 fibers | RPS | share of the 441k C-call baseline |
|---|---|---|
| baseline: `IPROTO_CALL` → C `box_index_get()` | 440 596 | 100% |
| vshard direct, C wrapper + C func | 238 307 | 54% |
| vshard direct, Lua wrapper + C func | 151 761 | 34% |
| vshard router, C wrapper + C func | 257 935 | 59% |
| vshard router, Lua wrapper + C func | 95 301 | 22% |

- Even fully in C, the vshard storage wrapper costs more than half
  of the raw call throughput on writes (362k → 160k storage-side).
  What it buys: bucket ref, mode/master check, the reply
  convention. The router hop takes another ~25%.
- The C wrapper is worth the most where Lua used to dominate: on
  reads through the router it is 2.7x the Lua wrapper (258k vs
  95k) and it brings the router path to within 6% of the storage-
  side *direct* number, i.e. the storage stops being the
  bottleneck at all.
- On writes at 50 fibers the two wrappers converge storage-side
  (160k vs 159k) — the WAL becomes the shared bound; the win shows
  up through the router (120k vs 97k) and in p50 (285 vs 254 µs
  direct, 412 vs 396 µs router).

## 3. Against crud

crud rows are `test/perf/c_dml/run.sh` from the C-DML prototype
branch, same session, 50 fibers, through `crud.replace`/`crud.get`
on a router. "old" is the pre-branch revision (the
`_crud.call_on_storage` trampoline in fast mode, no bucket refs at
all); "new C/C" is C storage functions under the C vshard wrapper.

| replace, 50 fibers | RPS | share of 362k | share of the 120k vshard router |
|---|---|---|---|
| baseline: `IPROTO_CALL` → C func, noret | 362 327 | 100% | — |
| vshard router, C wrapper + C func | 119 685 | 33% | 100% |
| crud old (trampoline, fast mode) | 44 661 | 12% | 37% |
| crud new, C funcs + C vshard | 42 880 | 12% | 36% |
| crud new, Lua funcs + C vshard | 33 199 | 9% | 28% |

| get, 50 fibers | RPS | share of 441k | share of the 258k vshard router |
|---|---|---|---|
| baseline: `IPROTO_CALL` → C `box_index_get()` | 440 596 | 100% | — |
| vshard router, C wrapper + C func | 257 935 | 59% | 100% |
| crud old (trampoline, fast mode) | 37 021 | 8% | 14% |
| crud new, C funcs + C vshard | 99 055 | 22% | 38% |
| crud new, Lua funcs + C vshard | 48 455 | 11% | 19% |

- crud is where the throughput actually goes. On reads the fully-C
  crud path is 2.7x the old trampoline (99k vs 37k) yet still only
  38% of what the bare vshard router call does under it, and 22%
  of a plain C stored function call.
- On writes crud is essentially flat against the old fast-mode
  path (43k vs 45k) — and that is *with* a real bucket ref taken on
  every request, which fast mode skipped entirely. The remaining
  cost is router-side: sharding key extraction, tuple flattening,
  the metadata/format round trip and the result decoding, none of
  which the C storage function touches.
- The layering, end to end, for a single replace at 50 fibers:
  513k local → 278k IPROTO_REPLACE → 362k / 177k a C stored
  function (without / with returning the tuple) → 160k vshard
  storage-side → 120k through the vshard router → 43k through
  crud. Every layer above the storage costs more than the storage
  operation itself.

## 4. Caveats

- One client process. Rows above ~150k RPS at 10 fibers, and above
  ~400k at 50, may be partially client-bound — treat them as lower
  bounds for the server.
- Workloads run sequentially inside one process, and the space
  grows during the run; single-digit percent deltas are noise.
- crud `insert+delete` (in its own table) does two round trips per
  iteration and is WAL-bound; it is not comparable to the rows
  here.
- The `local replace (no net)` row is measured by the server's own
  fibers via `bench_local_loop`, so it excludes the client
  entirely — it is the engine+WAL ceiling of this box, not an
  IPROTO number.
