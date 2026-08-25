#!/bin/sh
# Build bench_c.so for the replace-path benchmark against an
# uninstalled tarantool source tree. Usage:
#   ./build.sh [path-to-tarantool-src]
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
TNT_DIR="${1:-$(cd "$DIR/../.." && pwd)}"
CC="${CC:-cc}"
$CC -shared -fPIC -fvisibility=hidden -std=gnu99 -Wall -Wextra -O2 -g \
    -I"$TNT_DIR/src" \
    -I"$TNT_DIR/src/lib/msgpuck" \
    -I"$TNT_DIR/third_party/luajit/src" \
    -o "$DIR/bench_c.so" \
    "$DIR/bench_c.c" \
    "$TNT_DIR/src/lib/msgpuck/libmsgpuck.a"
echo "built $DIR/bench_c.so"
