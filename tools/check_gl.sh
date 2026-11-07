#!/bin/sh
# check_gl.sh — renderer-boundary gate (issue #14, P10): no GL API outside the
# GL backend. Fails if any src/ file that is not an allowed GL owner names a GL
# header, a gl* entry point, or a GL* type. Comments and string literals are
# stripped first, so GL mentioned in prose or diagnostics does not count.
#
# Allowed GL owners (the GL backend, plus the self-contained immediate-mode UI
# renderers that preserve the full GL context state themselves and have their
# own tests for it, like Dear ImGui -- they are not rhi.h clients):
#   rhi_gl.c / rhi_gl.h / rhi_gl_state.c / rhi_gl_state.h  the GL backend itself
#   rhi_gl_trace.h                                         its iOS Super Debug call tracer
#   debugui.cpp                                            Dear ImGui's GL2 backend
#   ugui/ugui_gl.c / ugui/ugui_gl.h                        the ugui library's GL backend
# Everything else -- the whole game renderer -- reaches the GPU only through rhi.h.
set -eu

root=${1:-src}
allow="rhi_gl.c rhi_gl.h rhi_gl_state.c rhi_gl_state.h rhi_gl_trace.h debugui.cpp ugui_gl.c ugui_gl.h"

fail=0
# -- find source files, skip the allowed owners by basename --
for f in $(find "$root" -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' \) | sort); do
    base=${f##*/}
    skip=0
    for a in $allow; do [ "$base" = "$a" ] && skip=1 && break; done
    [ "$skip" = 1 ] && continue

    # Comments stripped, strings kept: used for the #include check, since an
    # include path is written in quotes and must not be stripped as a string.
    nocomment=$(perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{//[^\n]*}{}g' "$f")
    # Comments AND string literals stripped: used for the gl*/GL* checks, so GL
    # named inside a string (a diagnostic, an embedded shader) does not count.
    code=$(printf '%s' "$nocomment" | perl -0777 -pe 's{"(\\.|[^"\\\n])*"}{""}g')

    inc=$(printf '%s\n' "$nocomment" | grep -nE \
        '#[[:space:]]*include[[:space:]]*[<"](GL/|GLES|OpenGL/|SDL_opengl)' || true)
    api=$(printf '%s\n' "$code" | grep -nE \
        '\bgl[A-Z][A-Za-z0-9]*[[:space:]]*\(|\b(GLuint|GLenum|GLint|GLfloat|GLboolean|GLsizei|GLvoid|GLchar|GLbitfield|GLclampf|GLubyte|GLushort|GLshort|GLdouble|GLintptr|GLsizeiptr|GLbyte|GLuint64|GLfixed)\b' \
        || true)

    hits=$(printf '%s\n%s' "$inc" "$api" | sed '/^$/d')
    if [ -n "$hits" ]; then
        fail=1
        echo "check-gl: GL API outside the backend in $f:"
        printf '%s\n' "$hits" | sed 's/^/    /'
    fi
done

if [ "$fail" != 0 ]; then
    echo "check-gl: FAILED — route the above through rhi.h, or add a documented owner to tools/check_gl.sh." >&2
    exit 1
fi
echo "check-gl: OK — no GL API outside the backend (src/)."
