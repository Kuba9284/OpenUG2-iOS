/* touch_ios.c -- see touch_ios.h */
#include "touch_ios.h"

#include <math.h>
#include <string.h>

#include "controls_bind.h"
#include "render_params.h"

/* ---- controls ---------------------------------------------------------------------------------------- */
enum {
    C_GAS, C_BRAKE, C_NITRO, C_HANDBRAKE, C_PAUSE, C_CAMERA, C_RESET, C_LOOK,   /* driving */
    C_UP, C_DOWN, C_LEFT, C_RIGHT, C_OK, C_BACK,                                /* pause menu */
    C_COUNT,
    C_STEER = -2, C_NONE = -1
};
enum { K_HELD, K_ACTION_KEY, K_RAW_KEY };   /* how a control reaches the game */

typedef struct {
    const char *label;
    int kind;
    int action;        /* CB_ACT_* for K_HELD / K_ACTION_KEY */
    int scancode;      /* SDL_SCANCODE_* for K_RAW_KEY */
    int menu;          /* shown only while the pause menu is open */
    float r, g, b;
} CtlDef;

static const CtlDef k_def[C_COUNT] = {
    [C_GAS]       = { "GAS",   K_HELD,       CB_ACT_THROTTLE,  0, 0, 0.25f, 0.85f, 0.35f },
    [C_BRAKE]     = { "BRK",   K_HELD,       CB_ACT_BRAKE,     0, 0, 0.90f, 0.25f, 0.25f },
    [C_NITRO]     = { "NOS",   K_HELD,       CB_ACT_NITROUS,   0, 0, 0.30f, 0.60f, 1.00f },
    [C_HANDBRAKE] = { "HB",    K_HELD,       CB_ACT_HANDBRAKE, 0, 0, 0.95f, 0.75f, 0.20f },
    [C_PAUSE]     = { "PAUSE", K_ACTION_KEY, CB_ACT_PAUSE,     0, 0, 0.80f, 0.80f, 0.80f },
    [C_CAMERA]    = { "CAM",   K_ACTION_KEY, CB_ACT_CAMERA,    0, 0, 0.80f, 0.80f, 0.80f },
    [C_RESET]     = { "RESET", K_ACTION_KEY, CB_ACT_RESET_CAR, 0, 0, 0.80f, 0.80f, 0.80f },
    [C_LOOK]      = { "LOOK",  K_HELD,       CB_ACT_LOOK_BACK, 0, 0, 0.80f, 0.80f, 0.80f },
    [C_UP]        = { "UP",    K_RAW_KEY, 0, SDL_SCANCODE_UP,     1, 0.80f, 0.80f, 0.80f },
    [C_DOWN]      = { "DN",    K_RAW_KEY, 0, SDL_SCANCODE_DOWN,   1, 0.80f, 0.80f, 0.80f },
    [C_LEFT]      = { "L",     K_RAW_KEY, 0, SDL_SCANCODE_LEFT,   1, 0.80f, 0.80f, 0.80f },
    [C_RIGHT]     = { "R",     K_RAW_KEY, 0, SDL_SCANCODE_RIGHT,  1, 0.80f, 0.80f, 0.80f },
    [C_OK]        = { "OK",    K_RAW_KEY, 0, SDL_SCANCODE_RETURN, 1, 0.25f, 0.85f, 0.35f },
    [C_BACK]      = { "BACK",  K_RAW_KEY, 0, SDL_SCANCODE_ESCAPE, 1, 0.90f, 0.25f, 0.25f },
};

/* Rectangles in normalised screen units, origin top-left (the same space as SDL touch coordinates). */
typedef struct { float x0, y0, x1, y1; } Rect;

static Rect g_rect[C_COUNT];
static Rect g_steer_zone;
static float g_aspect = 16.0f / 9.0f;   /* width / height of the drawable, updated by touch_draw */
static int   g_menu;                    /* pause menu open: show the D-pad layout */
static int   g_layout_valid;

/* A square of side s (in screen-HEIGHT units, so buttons stay square at any aspect) whose right edge is rm
   and bottom edge bm (also height units) in from the screen edges. */
static Rect from_right_bottom(float a, float rm, float bm, float s) {
    Rect r;
    r.x1 = 1.0f - rm / a;  r.x0 = r.x1 - s / a;
    r.y1 = 1.0f - bm;      r.y0 = r.y1 - s;
    return r;
}
static Rect from_left_bottom(float a, float lm, float bm, float s) {
    Rect r;
    r.x0 = lm / a;         r.x1 = r.x0 + s / a;
    r.y1 = 1.0f - bm;      r.y0 = r.y1 - s;
    return r;
}

static void layout(float a) {
    g_aspect = a;
    /* right-hand thumb: gas biggest and in the corner, brake beside it, nitro and handbrake above */
    g_rect[C_GAS]       = from_right_bottom(a, 0.05f, 0.06f, 0.36f);
    g_rect[C_BRAKE]     = from_right_bottom(a, 0.45f, 0.06f, 0.28f);
    g_rect[C_NITRO]     = from_right_bottom(a, 0.11f, 0.46f, 0.24f);
    g_rect[C_HANDBRAKE] = from_right_bottom(a, 0.48f, 0.38f, 0.22f);
    /* top row */
    g_rect[C_PAUSE]     = from_right_bottom(a, 0.03f, 0.83f, 0.14f);
    g_rect[C_CAMERA]    = from_right_bottom(a, 0.20f, 0.83f, 0.14f);
    g_rect[C_RESET]     = from_right_bottom(a, 0.37f, 0.83f, 0.14f);
    g_rect[C_LOOK]      = from_right_bottom(a, 0.54f, 0.83f, 0.14f);
    /* steering strip: left part of the lower screen */
    g_steer_zone.x0 = 0.03f; g_steer_zone.x1 = 0.40f;
    g_steer_zone.y0 = 0.30f; g_steer_zone.y1 = 1.00f;
    /* menu D-pad */
    g_rect[C_UP]    = from_left_bottom(a, 0.22f, 0.48f, 0.18f);
    g_rect[C_DOWN]  = from_left_bottom(a, 0.22f, 0.06f, 0.18f);
    g_rect[C_LEFT]  = from_left_bottom(a, 0.04f, 0.27f, 0.18f);
    g_rect[C_RIGHT] = from_left_bottom(a, 0.40f, 0.27f, 0.18f);
    g_rect[C_OK]    = from_right_bottom(a, 0.05f, 0.06f, 0.28f);
    g_rect[C_BACK]  = from_right_bottom(a, 0.37f, 0.06f, 0.20f);
    g_layout_valid = 1;
}

static int in_rect(const Rect *r, float x, float y) { return x >= r->x0 && x <= r->x1 && y >= r->y0 && y <= r->y1; }

/* ---- state ------------------------------------------------------------------------------------------- */
#define MAX_FINGERS 10
typedef struct { SDL_FingerID id; int active; int ctl; } Finger;

static const CxInput *g_cx;
static Finger g_finger[MAX_FINGERS];
static int    g_held[C_COUNT];
static int    g_pushed_sc[C_COUNT];   /* scancode whose KEYDOWN we sent for this control (so UP matches it) */
static float  g_steer;                /* +1 left .. -1 right */

void touch_init(const CxInput *cx) {
    g_cx = cx;
    memset(g_finger, 0, sizeof g_finger);
    memset(g_held, 0, sizeof g_held);
    memset(g_pushed_sc, 0, sizeof g_pushed_sc);
    g_steer = 0.0f;
    layout(g_aspect);
}

static void push_key(int scancode, int down) {
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    ev.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    ev.key.repeat = 0;
    ev.key.keysym.scancode = (SDL_Scancode)scancode;
    ev.key.keysym.sym = SDL_GetKeyFromScancode((SDL_Scancode)scancode);
    SDL_PushEvent(&ev);
}

/* The key the Controls screen binds to `action` (first of its two), or 0 if none. */
static int bound_scancode(int action) {
    int k[2];
    if (!g_cx) return 0;
    return cb_kb_keys(&g_cx->b.kb, action, k) > 0 ? k[0] : 0;
}

static void press(int ctl) {
    const CtlDef *d = &k_def[ctl];
    g_held[ctl] = 1;
    if (d->kind == K_HELD) return;
    int sc = d->kind == K_RAW_KEY ? d->scancode : bound_scancode(d->action);
    g_pushed_sc[ctl] = sc;
    if (sc) push_key(sc, 1);
}

static void release(int ctl) {
    if (!g_held[ctl]) return;
    g_held[ctl] = 0;
    if (k_def[ctl].kind != K_HELD && g_pushed_sc[ctl]) push_key(g_pushed_sc[ctl], 0);
    g_pushed_sc[ctl] = 0;
}

static void release_all(void) {
    for (int i = 0; i < C_COUNT; i++) release(i);
    memset(g_finger, 0, sizeof g_finger);
    g_steer = 0.0f;
}

static void set_steer_from_x(float x) {
    const float centre = 0.5f * (g_steer_zone.x0 + g_steer_zone.x1);
    const float half = 0.5f * (g_steer_zone.x1 - g_steer_zone.x0);
    float v = (centre - x) / half;                 /* +: finger left of centre = steer left */
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    const float dead = 0.06f;
    if (fabsf(v) < dead) { g_steer = 0.0f; return; }
    float m = (fabsf(v) - dead) / (1.0f - dead);   /* 0..1 outside the dead zone */
    g_steer = v < 0.0f ? -m : m;
}

static int hit_test(float x, float y) {
    for (int i = 0; i < C_COUNT; i++) {
        if ((k_def[i].menu != 0) != (g_menu != 0)) continue;
        if (in_rect(&g_rect[i], x, y)) return i;
    }
    if (!g_menu && in_rect(&g_steer_zone, x, y)) return C_STEER;
    return C_NONE;
}

static Finger *find_finger(SDL_FingerID id) {
    for (int i = 0; i < MAX_FINGERS; i++) if (g_finger[i].active && g_finger[i].id == id) return &g_finger[i];
    return NULL;
}

void touch_handle_event(const SDL_Event *e) {
    switch (e->type) {
    case SDL_FINGERDOWN: {
        Finger *f = NULL;
        for (int i = 0; i < MAX_FINGERS; i++) if (!g_finger[i].active) { f = &g_finger[i]; break; }
        if (!f) return;
        int ctl = hit_test(e->tfinger.x, e->tfinger.y);
        if (ctl == C_NONE) return;
        f->active = 1; f->id = e->tfinger.fingerId; f->ctl = ctl;
        if (ctl == C_STEER) set_steer_from_x(e->tfinger.x); else press(ctl);
        break;
    }
    case SDL_FINGERMOTION: {
        Finger *f = find_finger(e->tfinger.fingerId);
        if (f && f->ctl == C_STEER) set_steer_from_x(e->tfinger.x);
        break;
    }
    case SDL_FINGERUP: {
        Finger *f = find_finger(e->tfinger.fingerId);
        if (!f) return;
        if (f->ctl == C_STEER) g_steer = 0.0f; else release(f->ctl);
        f->active = 0;
        break;
    }
    case SDL_APP_WILLENTERBACKGROUND:
    case SDL_APP_DIDENTERBACKGROUND:
    case SDL_WINDOWEVENT:
        if (e->type != SDL_WINDOWEVENT || e->window.event == SDL_WINDOWEVENT_FOCUS_LOST) release_all();
        break;
    default: break;
    }
}

int touch_action_down(int action) {
    if (g_menu) return 0;
    for (int i = 0; i < C_COUNT; i++)
        if (k_def[i].kind == K_HELD && k_def[i].action == action && g_held[i]) return 1;
    return 0;
}

float touch_steer(void) { return g_menu ? 0.0f : g_steer; }

/* ---- drawing ----------------------------------------------------------------------------------------- */
static void draw_rect(const RProg *rp, GpuMesh *quad, const Rect *r, float cr, float cg, float cb, float alpha) {
    /* The overlay quad is the unit square [0,1]^2: scale to the rectangle and translate to its bottom-left
       corner, in clip space (x right, y up). */
    float M[16] = { 2.0f * (r->x1 - r->x0), 0, 0, 0,
                    0, 2.0f * (r->y1 - r->y0), 0, 0,
                    0, 0, 1, 0,
                    2.0f * r->x0 - 1.0f, 1.0f - 2.0f * r->y1, 0, 1 };
    ug2_copy(rp->p->uMVP, M, 16);
    ug2_vec3(rp->p->uColor, cr, cg, cb);
    rp->p->uAlpha = alpha;
    render_draw_gpumesh(quad);
}

static void draw_label(const RProg *rp, GpuMesh *quad, const Rect *r, const char *s, float alpha) {
    const size_t n = strlen(s);
    if (!n) return;
    const float bw = 2.0f * (r->x1 - r->x0);                 /* box width in clip units */
    float px = 0.65f * bw / (4.0f * (float)n);               /* label fills ~65% of the width */
    const float py_cap = 0.55f * 2.0f * (r->y1 - r->y0) / 5.0f;
    float py = px * g_aspect;                                /* square pixels: clip x and y units differ by aspect */
    if (py > py_cap) { py = py_cap; px = py / g_aspect; }
    const float cx = (r->x0 + r->x1) - 1.0f;                 /* box centre in clip space */
    const float cy = 1.0f - (r->y0 + r->y1);
    rp->p->uAlpha = alpha;
    ug2_vec3(rp->p->uColor, 1.0f, 1.0f, 1.0f);
    draw_text(quad, rp, s, cx - 0.5f * text_width(s, px) + 0.5f * px, cy + 1.6f * py, px, py);
}

void touch_draw(const RProg *rp, GpuMesh *quad, const UG2OverlayPipelines *ovp, int w, int h, int menu_open) {
    if (!rp || !quad || !ovp || w <= 0 || h <= 0) return;
    const float a = (float)w / (float)h;
    if (!g_layout_valid || fabsf(a - g_aspect) > 0.001f) layout(a);
    if ((menu_open != 0) != (g_menu != 0)) {   /* mode switch: nothing may stay held across it */
        release_all();
        g_menu = menu_open != 0;
    }

    RhiStateSnapshot saved;
    rhi_cmd_save_state(&saved);
    const float s_unlit = rp->p->uUnlit, s_tex = rp->p->uUseTex, s_soft = rp->p->uSoft, s_alpha = rp->p->uAlpha;
    float s_col[3], s_mvp[16];
    memcpy(s_col, rp->p->uColor, sizeof s_col);
    memcpy(s_mvp, rp->p->uMVP, sizeof s_mvp);

    rhi_cmd_bind_pipeline(ovp->screen_blend);
    rp->p->uUnlit = 1.0f; rp->p->uUseTex = 0.0f; rp->p->uSoft = 0.0f;

    for (int i = 0; i < C_COUNT; i++) {
        if ((k_def[i].menu != 0) != g_menu) continue;
        const CtlDef *d = &k_def[i];
        draw_rect(rp, quad, &g_rect[i], d->r, d->g, d->b, g_held[i] ? 0.60f : 0.28f);
        draw_label(rp, quad, &g_rect[i], d->label, g_held[i] ? 1.0f : 0.75f);
    }
    if (!g_menu) {   /* steering strip: a thin track across the zone and a knob that follows the finger */
        const float centre = 0.5f * (g_steer_zone.x0 + g_steer_zone.x1);
        const float half = 0.5f * (g_steer_zone.x1 - g_steer_zone.x0);
        Rect track = { g_steer_zone.x0, 0.865f, g_steer_zone.x1, 0.885f };
        draw_rect(rp, quad, &track, 1.0f, 1.0f, 1.0f, 0.22f);
        Rect mid = { centre - 0.002f, 0.835f, centre + 0.002f, 0.915f };
        draw_rect(rp, quad, &mid, 1.0f, 1.0f, 1.0f, 0.35f);
        const float ks = 0.13f;                              /* knob side, height units */
        const float kx = centre - g_steer * half;
        Rect knob = { kx - 0.5f * ks / g_aspect, 0.875f - 0.5f * ks, kx + 0.5f * ks / g_aspect, 0.875f + 0.5f * ks };
        draw_rect(rp, quad, &knob, 1.0f, 1.0f, 1.0f, g_steer != 0.0f ? 0.65f : 0.35f);
    }

    rp->p->uUnlit = s_unlit; rp->p->uUseTex = s_tex; rp->p->uSoft = s_soft; rp->p->uAlpha = s_alpha;
    memcpy(rp->p->uColor, s_col, sizeof s_col);
    memcpy(rp->p->uMVP, s_mvp, sizeof s_mvp);
    rhi_cmd_restore_state(&saved);
}
