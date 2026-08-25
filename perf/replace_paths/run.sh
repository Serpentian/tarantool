#!/bin/sh
# Benchmark of the replace paths: IPROTO_REPLACE vs a C stored
# function vs a Lua function doing the same box_replace().
# Usage: run.sh [path-to-tarantool]
set -e
TNT="${1:-tarantool}"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${BENCH_WORK:-/tmp/tnt_replace_bench}"

[ -f "$DIR/bench_c.so" ] || "$DIR/build.sh"

rm -rf "$WORK"
mkdir -p "$WORK/server" "$WORK/client"
export LUA_CPATH="$DIR/?.so;;"

echo "# tarantool: $($TNT --version | head -1)"
(cd "$WORK/server" && "$TNT" "$DIR/server.lua" > server.log 2>&1 &)
for i in $(seq 1 60); do
    [ -f "$WORK/server/server.pid" ] && break
    sleep 0.5
done
if ! [ -f "$WORK/server/server.pid" ]; then
    echo "the server failed to start:" >&2
    tail -20 "$WORK/server/server.log" >&2
    exit 1
fi
trap 'kill "$(cat "$WORK/server/server.pid")" 2>/dev/null; exit 0' EXIT

(cd "$WORK/client" && "$TNT" "$DIR/bench.lua" 2>/dev/null)
