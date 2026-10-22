#!/bin/sh
# Regenerates src/generated_shaders.h and src/generated_world_debug_shaders.h: the same output as the
# Makefile rules of those names (the desktop build makes them with xxd; macOS ships xxd too).
# Skips the work when both headers are newer than every shader, so incremental Xcode builds stay fast.
set -eu
cd "$(dirname "$0")/.."
command -v xxd >/dev/null 2>&1 || { echo "gen_headers: xxd not found" >&2; exit 1; }

up_to_date() {   # $1 = header, rest = inputs
    out=$1; shift
    [ -f "$out" ] || return 1
    for f in "$@"; do [ "$f" -nt "$out" ] && return 1; done
    return 0
}

SHADERS=$(ls src/shaders/*.vert src/shaders/*.frag | sort)

if ! up_to_date src/generated_world_debug_shaders.h src/world_debug_120.vert src/world_debug_120.frag; then
    {
        echo "/* AUTO-GENERATED from world_debug_120.vert/.frag by make -- do not edit */"
        xxd -i src/world_debug_120.vert
        xxd -i src/world_debug_120.frag
    } > src/generated_world_debug_shaders.h
fi

# shellcheck disable=SC2086
if ! up_to_date src/generated_shaders.h $SHADERS; then
    {
        echo "/* AUTO-GENERATED from src/shaders/ by make -- do not edit */"
        for f in $SHADERS; do xxd -i "$f" | sed 's/^unsigned/static const unsigned/'; done
    } > src/generated_shaders.h
fi
