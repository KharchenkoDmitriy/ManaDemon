#!/usr/bin/env bash
# Run a harness script against this checkout with a real Lua 5.1.
#
#   tools/run.sh tools/simcheck.lua [--curve]
#
# There is no Lua in this repo and none is assumed on the machine: the first
# run downloads and builds Lua 5.1.5 into tools/.lua (gitignored, ~10 seconds).
# 5.1 specifically, because that is what the TBC client runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA_DIR="$ROOT/tools/.lua"
LUA="$LUA_DIR/lua-5.1.5/src/lua"

if [ ! -x "$LUA" ]; then
    echo "building Lua 5.1.5 into tools/.lua ..." >&2
    mkdir -p "$LUA_DIR"
    ( cd "$LUA_DIR" \
      && curl -sSL -o lua.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz \
      && tar xzf lua.tar.gz \
      && cd lua-5.1.5 && make posix >/dev/null 2>&1 )
fi

SCRIPT="${1:?usage: tools/run.sh <script.lua> [args]}"
shift
exec "$LUA" "$ROOT/${SCRIPT#./}" "$ROOT" "$@"
