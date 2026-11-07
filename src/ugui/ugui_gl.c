/* ugui_gl.c -- OpenGL backend for ugui canvases.
 *
 * One program draws every primitive: the fragment shader evaluates signed
 * distance functions (rounded boxes, rings, glows, quarter discs, spinner)
 * and samples the generated font atlas for text. GLES2 compatible: no
 * fixed function, no immediate mode, no VAOs. */
#include "../rhi_gl_state.h"   /* GL headers + shared CPU state tracker */

#include "ugui_gl.h"
#include "ugui_tex.h"
#include "ugui_tuning.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef OPENUG2_IOS
/* iOS diagnostics: drain and log GL errors at checkpoints through render_canvas (budgeted so a per-frame error cannot flood the log). */
static void ugchk(const char *tag) {
    static int budget = 24;
    if (budget <= 0) { glGetError(); return; }
    budget -= ug_gl_errors(tag);
}
#else
#define ugchk(tag) ((void)0)
#endif

static const char *VS =
    "attribute vec2 aPos;\n"
    "attribute vec2 aLocal;\n"
    "attribute vec4 aShape;\n"
    "attribute vec2 aMode;\n"
    "attribute vec4 aColor;\n"
    "uniform mat4 uProj;\n"
    "varying vec2 vL; varying vec4 vS; varying vec2 vM; varying vec4 vC;\n"
    "void main() {\n"
    "  gl_Position = uProj * vec4(aPos, 0.0, 1.0);\n"
    "  vL = aLocal; vS = aShape; vM = aMode; vC = aColor;\n"
    "}\n";

static const char *FS =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "varying vec2 vL; varying vec4 vS; varying vec2 vM; varying vec4 vC;\n"
    "uniform sampler2D uTex;\n"
    "uniform float uPx;\n"
    "float sdBox(vec2 p, vec2 b, float r) {\n"
    "  r = min(r, min(b.x, b.y));\n"
    "  vec2 d = abs(p) - (b - vec2(r));\n"
    "  return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;\n"
    "}\n"
    "void main() {\n"
    "  float m = vM.x;\n"
    "  if (m > 7.5) { gl_FragColor = texture2D(uTex, vL) * vC; return; }\n"
    "  float cov = 1.0;\n"
    "  float tx = texture2D(uTex, vL).a;\n"
    "  if (m < 0.5) {\n"
    "    cov = clamp(0.5 - sdBox(vL, vS.xy, vS.z) * uPx, 0.0, 1.0);\n"
    "  } else if (m < 1.5) {\n"
    "    float d = sdBox(vL, vS.xy, vS.z);\n"
    "    float r = abs(d + vS.w * 0.5) - vS.w * 0.5;\n"
    "    cov = clamp(0.5 - r * uPx, 0.0, 1.0);\n"
    "  } else if (m < 2.5) {\n"
    "    cov = tx;\n"
    "  } else if (m < 3.5) {\n"
    "    float k = length(vL / max(vS.xy, vec2(0.001)));\n"
    "    cov = 1.0 - smoothstep(0.0, 1.0, k);\n"
    "    cov = cov * cov;\n"
    "  } else if (m < 4.5) {\n"
    "    float d = sdBox(vL, vS.xy, vS.z);\n"
    "    float r = abs(d + vS.w * 0.5) - vS.w * 0.5;\n"
    "    float s = max(vM.y, 0.001);\n"
    "    cov = exp(-(max(r, 0.0) * max(r, 0.0)) / (s * s)) * 0.9;\n"
    "  } else if (m < 5.5) {\n"
    "    cov = 1.0;\n"
    "  } else if (m < 6.5) {\n"
    "    float d = sdBox(vL, vS.xy, vS.z);\n"
    "    float r = abs(d + vS.w * 0.5) - vS.w * 0.5;\n"
    "    float a = atan(vL.y, vL.x) / 6.2831853 + 0.5;\n"
    "    float behind = fract(vM.y - a);\n"
    "    cov = clamp(0.5 - r * uPx, 0.0, 1.0) * clamp(1.0 - behind * 1.1, 0.0, 1.0);\n"
    "  } else {\n"
    "    float d = length(vL - vec2(vS.x, vS.y)) - vS.z;\n"
    "    cov = clamp(0.5 - d * uPx, 0.0, 1.0) * step(abs(vL.x), vS.x) * step(abs(vL.y), vS.y);\n"
    "  }\n"
    "  gl_FragColor = vec4(vC.rgb, vC.a * cov);\n"
    "}\n";

struct UgGL {
    unsigned prog, vbo, tex;
    int uProj, uPx, uTex;
    size_t vbo_bytes;
    UgTexLib *lib;            /* library textures drawn by UG_M_IMAGE quads */
    unsigned *gltex; int ngltex;   /* GL names per library index; 0 = not uploaded, ~0 = failed */
};

void ug_gl_set_texlib(UgGL *g, UgTexLib *lib) { if (g) g->lib = lib; }

/* uploads library texture `idx` (0-based) once; returns the GL name or 0 */
static unsigned lib_texture(UgGL *g, int idx) {
    if (!g->lib || idx < 0 || idx >= g->lib->n) return 0;
    if (idx >= g->ngltex) {
        int nn = g->lib->n;
        unsigned *np = (unsigned *)realloc(g->gltex, sizeof(unsigned) * (size_t)nn);
        if (!np) return 0;
        memset(np + g->ngltex, 0, sizeof(unsigned) * (size_t)(nn - g->ngltex));
        g->gltex = np;
        g->ngltex = nn;
    }
    if (g->gltex[idx] == ~0u) return 0;
    if (g->gltex[idx]) return g->gltex[idx];
    const uint8_t *px = ug_texlib_pixels(g->lib, idx);
    if (!px) { g->gltex[idx] = ~0u; return 0; }
    const UgTexture *t = &g->lib->t[idx];
    unsigned name = 0;
    glGenTextures(1, &name);
    glBindTexture(GL_TEXTURE_2D, name);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    int w = t->w, h = t->h, level = 0;
    uint8_t *cur = NULL;
    const uint8_t *src = px;
    for (;;) {
        glTexImage2D(GL_TEXTURE_2D, level, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, src);
#if UG_TUNE_TEX_MIPMAPS
        if (w == 1 && h == 1) break;
        int nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1;
        uint8_t *nx = (uint8_t *)malloc((size_t)nw * (size_t)nh * 4);
        if (!nx) break;
        for (int y = 0; y < nh; y++)
            for (int x = 0; x < nw; x++) {
                int x0 = x * 2, y0 = y * 2, x1 = x0 + (w > 1), y1 = y0 + (h > 1);
                for (int ch = 0; ch < 4; ch++)
                    nx[((size_t)y * (size_t)nw + (size_t)x) * 4 + (size_t)ch] = (uint8_t)(
                        (src[((size_t)y0 * (size_t)w + (size_t)x0) * 4 + (size_t)ch] + src[((size_t)y0 * (size_t)w + (size_t)x1) * 4 + (size_t)ch] +
                         src[((size_t)y1 * (size_t)w + (size_t)x0) * 4 + (size_t)ch] + src[((size_t)y1 * (size_t)w + (size_t)x1) * 4 + (size_t)ch] + 2) / 4);
            }
        free(cur);
        cur = nx; src = cur; w = nw; h = nh; level++;
#else
        break;
#endif
    }
    free(cur);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, UG_TUNE_TEX_MIPMAPS ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    g->gltex[idx] = name;
    return name;
}

static unsigned compile(unsigned type, const char *src) {
    unsigned s = glCreateShader(type);
    glShaderSource(s, 1, &src, 0);
    glCompileShader(s);
    int ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof log, 0, log);
        fprintf(stderr, "ugui shader compile: %s\n", log);
    }
    return s;
}

int ug_gl_errors(const char *tag) {
    int n = 0;
    for (unsigned e; (e = glGetError()) != GL_NO_ERROR && n < 16; n++)
        fprintf(stderr, "ugui: GL error 0x%04x at %s\n", e, tag);
    return n;
}

UgGL *ug_gl_create(void) {
    UgGL *g = (UgGL *)calloc(1, sizeof *g);
    if (!g) return NULL;

    unsigned vs = compile(GL_VERTEX_SHADER, VS), fs = compile(GL_FRAGMENT_SHADER, FS);
    g->prog = glCreateProgram();
    glAttachShader(g->prog, vs);
    glAttachShader(g->prog, fs);
    glBindAttribLocation(g->prog, 0, "aPos");
    glBindAttribLocation(g->prog, 1, "aLocal");
    glBindAttribLocation(g->prog, 2, "aShape");
    glBindAttribLocation(g->prog, 3, "aMode");
    glBindAttribLocation(g->prog, 4, "aColor");
    glLinkProgram(g->prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    int ok = 0;
    glGetProgramiv(g->prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(g->prog, sizeof log, 0, log);
        fprintf(stderr, "ugui shader link: %s\n", log);
        glDeleteProgram(g->prog);
        free(g);
        return NULL;
    }
    g->uProj = glGetUniformLocation(g->prog, "uProj");
    g->uPx = glGetUniformLocation(g->prog, "uPx");
    g->uTex = glGetUniformLocation(g->prog, "uTex");

    glGenBuffers(1, &g->vbo);

    /* White texel supports specified untextured geometry, never font artwork. */
    glGenTextures(1,&g->tex); glBindTexture(GL_TEXTURE_2D,g->tex);
    const uint8_t white[4]={255,255,255,255};
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,white);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D,0);
    return g;
}

void ug_gl_destroy(UgGL *g) {
    if (!g) return;
    for (int i = 0; i < g->ngltex; i++)
        if (g->gltex[i] && g->gltex[i] != ~0u) glDeleteTextures(1, &g->gltex[i]);
    free(g->gltex);
    glDeleteTextures(1, &g->tex);
    glDeleteBuffers(1, &g->vbo);
    glDeleteProgram(g->prog);
    free(g);
}

static void render_canvas(UgGL *g, const UgCanvas *cv, int win_w, int win_h, int overlay) {
    if (!g || cv->n == 0 || win_w <= 0 || win_h <= 0) return;
    UgView v = ug_view_fit(win_w, win_h);
    ugchk("render_canvas: entry (raised before the menu draw)");

    /* Preserve every state this legacy GL/GLES2 renderer changes. */
    int prev_prog = 0, prev_buf = 0, prev_tex = 0, prev_tex0 = 0, prev_active = 0, prev_unpack = 0;
    int prev_vp[4], prev_scissor_box[4], prev_blend_factors[4], prev_equation[2];
    int prev_blend = gls_is_enabled(GL_BLEND), prev_depth = gls_is_enabled(GL_DEPTH_TEST);
    int prev_cull = gls_is_enabled(GL_CULL_FACE), prev_scissor = gls_is_enabled(GL_SCISSOR_TEST);
    gls_get_integerv(GL_CURRENT_PROGRAM, &prev_prog);
    gls_get_integerv(GL_VIEWPORT, prev_vp);
    gls_get_integerv(GL_BLEND_SRC_RGB, &prev_blend_factors[0]);
    gls_get_integerv(GL_BLEND_DST_RGB, &prev_blend_factors[1]);
    gls_get_integerv(GL_BLEND_SRC_ALPHA, &prev_blend_factors[2]);
    gls_get_integerv(GL_BLEND_DST_ALPHA, &prev_blend_factors[3]);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, &prev_equation[0]);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &prev_equation[1]);
    glGetIntegerv(GL_SCISSOR_BOX, prev_scissor_box);
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &prev_unpack);
    gls_get_integerv(GL_ACTIVE_TEXTURE, &prev_active);
    gls_get_integerv(GL_ARRAY_BUFFER_BINDING, &prev_buf);
    gls_get_integerv(GL_TEXTURE_BINDING_2D, &prev_tex);
    glActiveTexture(GL_TEXTURE0);gls_get_integerv(GL_TEXTURE_BINDING_2D, &prev_tex0);
    struct { GLint enabled, buffer, size, type, normalized, stride; void *pointer; } prev_attr[5];
    for (unsigned i = 0; i < 5; i++) {
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_ENABLED,&prev_attr[i].enabled);
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,&prev_attr[i].buffer);
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_SIZE,&prev_attr[i].size);
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_TYPE,&prev_attr[i].type);
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_NORMALIZED,&prev_attr[i].normalized);
        glGetVertexAttribiv(i,GL_VERTEX_ATTRIB_ARRAY_STRIDE,&prev_attr[i].stride);
        glGetVertexAttribPointerv(i,GL_VERTEX_ATTRIB_ARRAY_POINTER,&prev_attr[i].pointer);
    }

    ugchk("render_canvas: state queries");
    glViewport(overlay ? 0 : v.x0, overlay ? 0 : win_h - v.y0 - v.h,
               overlay ? win_w : v.w, overlay ? win_h : v.h);
    glScissor(overlay ? 0 : v.x0, overlay ? 0 : win_h - v.y0 - v.h,
              overlay ? win_w : v.w, overlay ? win_h : v.h);
    glEnable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);

    glUseProgram(g->prog);
    float proj[16] = {2.0f / UG_SCREEN_W, 0, 0, 0,
                      0, -2.0f / UG_SCREEN_H, 0, 0,
                      0, 0, 1, 0,
                      0, 0, 0, 1};
    if (overlay) { proj[0] = 2.0f * v.scale / win_w; proj[5] = -2.0f * v.scale / win_h; }
    glUniformMatrix4fv(g->uProj, 1, GL_FALSE, proj);
    glUniform1f(g->uPx, v.scale);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g->tex);
    glUniform1i(g->uTex, 0);
    ugchk("render_canvas: program and uniforms");

    glBindBuffer(GL_ARRAY_BUFFER, g->vbo);
    size_t bytes = sizeof(UgVertex) * (size_t)cv->n;
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)bytes, cv->v, GL_STREAM_DRAW);
    const GLsizei stride = (GLsizei)sizeof(UgVertex);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(UgVertex, x));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(UgVertex, lx));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(UgVertex, hw));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(UgVertex, mode));
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, (void *)offsetof(UgVertex, r));
    ugchk("render_canvas: vertex upload and attribs");
    /* draw in runs of equal texture: 0 = built-in atlas, k = library texture k-1 */
    for (int i = 0; i < cv->n;) {
        int tex = cv->v[i].tex, j = i + 1;
        while (j < cv->n && cv->v[j].tex == tex) j++;
        unsigned name = g->tex;
        if (tex > 0) name = lib_texture(g, tex - 1);
        if (name) {
            glBindTexture(GL_TEXTURE_2D, name);
            glDrawArrays(GL_TRIANGLES, i, j - i);
        }
        i = j;
    }

    ugchk("render_canvas: draws");
    for (unsigned i = 0; i < 5; i++) {
        glBindBuffer(GL_ARRAY_BUFFER,(unsigned)prev_attr[i].buffer);
        glVertexAttribPointer(i,prev_attr[i].size,(GLenum)prev_attr[i].type,
            (GLboolean)prev_attr[i].normalized,prev_attr[i].stride,prev_attr[i].pointer);
        if(prev_attr[i].enabled)glEnableVertexAttribArray(i);else glDisableVertexAttribArray(i);
    }
    glBindBuffer(GL_ARRAY_BUFFER, (unsigned)prev_buf);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D, (unsigned)prev_tex0);
    glActiveTexture((unsigned)prev_active);glBindTexture(GL_TEXTURE_2D, (unsigned)prev_tex);
    glPixelStorei(GL_UNPACK_ALIGNMENT,prev_unpack);
    glUseProgram((unsigned)prev_prog);
    glBlendFuncSeparate(prev_blend_factors[0],prev_blend_factors[1],prev_blend_factors[2],prev_blend_factors[3]);
    glBlendEquationSeparate(prev_equation[0],prev_equation[1]);
    glScissor(prev_scissor_box[0],prev_scissor_box[1],prev_scissor_box[2],prev_scissor_box[3]);
    if (!prev_blend) glDisable(GL_BLEND);
    if (prev_depth) glEnable(GL_DEPTH_TEST);
    if (prev_cull) glEnable(GL_CULL_FACE);
    if (!prev_scissor) glDisable(GL_SCISSOR_TEST);
    glViewport(prev_vp[0], prev_vp[1], prev_vp[2], prev_vp[3]);
    ugchk("render_canvas: state restore");
}

void ug_gl_render(UgGL *g, const UgCanvas *cv, int win_w, int win_h) {
    render_canvas(g, cv, win_w, win_h, 0);
}
void ug_gl_render_overlay(UgGL *g, const UgCanvas *cv, int win_w, int win_h) {
    render_canvas(g, cv, win_w, win_h, 1);
}
