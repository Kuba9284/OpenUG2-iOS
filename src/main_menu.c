/* main_menu.c -- see main_menu.h. The retail UI_Main.fng screen over the user's own front-end archive.
 *
 * The package carries the frame, the title text, the scroll arrows, the scroller thumb and a pool of
 * off-screen item buttons; the program supplies the icons, their order, the labels and the strip
 * motion (SPEC 6.4 / 15.9). The binding below follows tools/ugui_demo_orig.c, which the unit tests of
 * the UI runtime already exercise. */
#include "main_menu.h"
#include "pause_menu_layout.h"
#include "frontend/frontend.h"
#include "ugui/ugui_gl.h"
#include "ugui/ugui_assets.h"
#include "ugui/ugui_ui.h"
#include "ugui/ugui_scene.h"
#include "ugui/ugui_fng.h"
#include "ugui/ugui_tuning.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MM_POOL_MAX 24
#define MM_FAMILY "MAIN_ICON_"
#define MM_NOTICE_MS 1600.0f

typedef struct { const char *icon; MainMenuChoice choice; const char *label_keys[3]; const char *fallback; } MmItem;

/* Order of the PC main menu (SPEC 15.9): career, quick race, go online, LAN, customize car, profile management, options. */
static const MmItem MM_ITEMS[] = {
    {"MAIN_ICON_CAREER",        MM_CAREER,       {"UI_MAIN_CAREER", NULL, NULL}, "Career"},
    {"MAIN_ICON_QUICK_RACE",    MM_QUICK_RACE,   {"UI_MAIN_QUICK_RACE", NULL, NULL}, "Quick Race"},
    {"MAIN_ICON_GO_ONLINE",     MM_GO_ONLINE,    {"UI_MAIN_ONLINE", NULL, NULL}, "Go Online"},
    {"MAIN_ICON_LAN",           MM_LAN,          {"UI_MAIN_ONLINE_LAN", NULL, NULL}, "LAN"},
    {"MAIN_ICON_CUSTOMIZE_CAR", MM_CUSTOMIZE_CAR,{"UI_MAIN_CUSTOMIZE", NULL, NULL}, "Customize Car"},
    {"MAIN_ICON_PROFILE_MANAG", MM_PROFILE,      {"UI_MAIN_PROFILE_MANAGEMENT", "UI_MAIN_PROFILE", "UI_MAIN_PROFILE_MANAGER"}, "Profile Management"},
    {"MAIN_ICON_OPTIONS",       MM_OPTIONS,      {"UI_MAIN_OPTIONS", NULL, NULL}, "Options"},
};
#define MM_NITEMS ((int)(sizeof MM_ITEMS / sizeof MM_ITEMS[0]))

struct MainMenu {
    UgAssets assets;
    UgSkin skin;
    UgGL *gl;
    UgCanvas canvas;
    UgCtx ui;
    UgFngPackage pk;
    UgScene sc;
    int assets_open, parsed, loaded;
    float ui_ms;
    int enter_done; float enter_ms;
    int closing, exit_done; float close_t;
    MainMenuChoice chosen;
    int avail[MM_NITEMS + 1];
    /* strip binding */
    int pool[MM_POOL_MAX], npool;
    int slot, title, thumb, arrow_l, arrow_r;
    float slot_x, slot_y;
    int tex[MM_POOL_MAX];
    char label[MM_POOL_MAX][48];
    MainMenuChoice choice[MM_POOL_MAX];
    int n, sel;
    float pos;
    float notice_ms;
    int draw_failed;
    char status[256];
};

/* ---- helpers ----------------------------------------------------------------------------------- */

static int icase_eq(const char *a, const char *b) {
    for (; *a && *b; a++, b++) if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    return *a == *b;
}

static const char *res_name_of(const UgScene *sc, const UgNode *n) {
    int ri = n->obj->res_index;
    return (ri >= 0 && ri < sc->pk->nres) ? sc->pk->res[ri].name : "";
}

static int pkg_responds(const UgFngPackage *pk, uint32_t msg) {
    for (int i = 0; i < pk->nobj; i++)
        for (int r = 0; r < pk->obj[i].nresp; r++)
            if (pk->obj[i].resp[r].msg == msg) return 1;
    for (int r = 0; r < pk->npkg_resp; r++)
        if (pk->pkg_resp[r].msg == msg) return 1;
    return 0;
}

static void mm_status(MainMenu *m, const char *fmt, const char *what) { snprintf(m->status, sizeof m->status, fmt, what); }

/* Finds the objects the package leaves to the program (geometry only): the pool of off-screen item buttons,
 * the 118 x 59 slot, the "Option title" text, the scroller thumb and the two scroll-arrow badges. */
static int mm_detect(MainMenu *m) {
    const UgScene *sc = &m->sc;
    m->npool = 0;
    m->slot = m->title = m->thumb = m->arrow_l = m->arrow_r = -1;
    for (int i = 0; i < sc->n; i++) {
        const UgNode *n = &sc->nodes[i];
        const UgFngObject *o = n->obj;
        float w = fabsf(n->props.w[UG_P_SIZE]), h = fabsf(n->props.w[UG_P_SIZE + 1]);
        if (o->type == UG_OBJ_IMAGE && (o->flags & UG_OF_BUTTON) && (o->flags & UG_OF_NO_DIRFOCUS) && n->parent < 0 &&
            w >= 100 && w <= 130 && h >= 38 && h <= 64 && (n->wf > 240 || n->wf < -240 || n->we > 320 || n->we < -320)) {
            if (m->npool < MM_POOL_MAX) m->pool[m->npool++] = i;
        } else if (o->type == UG_OBJ_IMAGE && n->untextured && fabsf(w - 118) < 3 && fabsf(h - 59) < 3 &&
                   fabsf(n->we) < 8 && n->wf > -190 && n->wf < -100 && m->slot < 0) {
            m->slot = i;
            m->slot_x = n->we; m->slot_y = n->wf;
        } else if (o->type == UG_OBJ_TEXT && o->text && icase_eq(o->text, "Option title")) {
            m->title = i;
        } else if (o->type == UG_OBJ_IMAGE && strstr(res_name_of(sc, n), "Scroller_Tab")) {
            m->thumb = i;
        } else if (o->type == UG_OBJ_IMAGE && w >= 20 && w <= 40 && h >= 20 && h <= 40 &&
                   fabsf(fabsf(n->we) - UG_R_ARROW_CX) < 14 && fabsf(n->wf - UG_R_ARROW_CY) < 8) {
            if (n->we < 0 && m->arrow_l < 0) m->arrow_l = i;
            else if (n->we > 0 && m->arrow_r < 0) m->arrow_r = i;
        }
    }
    return m->npool >= 2 && m->slot >= 0;
}

static const char *mm_label(const MainMenu *m, const MmItem *it) {
    for (int k = 0; k < 3 && it->label_keys[k]; k++) {
        const char *t = m->assets.have_strings ? ug_strtab_get(&m->assets.strings, ug_hash_upper(it->label_keys[k])) : NULL;
        if (t && *t) return t;
    }
    return it->fallback;
}

/* The icons come from the install's own textures (MAIN_ICON_*). */
static int mm_bind_items(MainMenu *m) {
    int found[MM_POOL_MAX];
    int nf = ug_assets_textures_with_prefix(&m->assets, MM_FAMILY, found, MM_POOL_MAX);
    m->n = 0;
    for (int k = 0; k < MM_NITEMS && m->n < m->npool; k++) {
        int tex = 0;
        for (int j = 0; j < nf; j++)
            if (icase_eq(m->assets.tex.t[found[j] - 1].name, MM_ITEMS[k].icon)) { tex = found[j]; break; }
        if (!tex) { fprintf(stderr, "mainmenu: icon texture %s is not in the archive; entry skipped\n", MM_ITEMS[k].icon); continue; }
        m->tex[m->n] = tex;
        m->choice[m->n] = MM_ITEMS[k].choice;
        snprintf(m->label[m->n], sizeof m->label[m->n], "%s", mm_label(m, &MM_ITEMS[k]));
        m->n++;
    }
    fprintf(stderr, "mainmenu: %d MAIN_ICON_* textures found, %d entries bound, pool %d\n", nf, m->n, m->npool);
    return m->n >= 2;
}

/* Writes the strip state into the authored objects and re-lays out (SPEC 6.4). */
static void mm_apply(MainMenu *m, float dt) {
    UgScene *sc = &m->sc;
    if (dt > 0) {
        float k = 1.0f - powf(0.001f, dt / 260.0f);
        m->pos += ((float)m->sel - m->pos) * k;
        if (fabsf((float)m->sel - m->pos) < 0.002f) m->pos = (float)m->sel;
    }
    if (m->pos < 0) m->pos = 0;
    if (m->pos > (float)(m->n - 1)) m->pos = (float)(m->n - 1);
    int nearest = (int)floorf(m->pos + 0.5f);
    for (int k2 = 0; k2 < m->npool; k2++) {
        UgNode *n = &sc->nodes[m->pool[k2]];
        n->tex_override = k2 < m->n ? m->tex[k2] : 0;
        if (k2 >= m->n || k2 == nearest) {
            n->props.w[UG_P_COLOR + 3] = 0;
            ug_scene_set_world_pos(sc, m->pool[k2], -999.0f, 0);
            continue;
        }
        UgIconPlace p;
        ug_icon_place(m->pos, k2, m->slot_x, m->slot_y, &p);
        ug_scene_set_world_pos(sc, m->pool[k2], p.cx, p.cy);
        n->props.w[UG_P_SIZE] = p.w; n->props.w[UG_P_SIZE + 1] = p.h;
        n->props.w[UG_P_COLOR] = n->props.w[UG_P_COLOR + 1] = n->props.w[UG_P_COLOR + 2] = 255;
        n->props.w[UG_P_COLOR + 3] = 255.0f * p.alpha;
    }
    {
        UgNode *sl = &sc->nodes[m->slot];
        UgIconPlace p;
        ug_icon_place(m->pos, nearest, m->slot_x, m->slot_y, &p);
        sl->tex_override = m->tex[nearest];
        ug_scene_set_world_pos(sc, m->slot, p.cx, p.cy);
        sl->props.w[UG_P_SIZE] = p.w; sl->props.w[UG_P_SIZE + 1] = p.h;
        sl->props.w[UG_P_COLOR] = sl->props.w[UG_P_COLOR + 1] = sl->props.w[UG_P_COLOR + 2] = 255;
        sl->props.w[UG_P_COLOR + 3] = 255.0f * p.alpha;
    }
    if (m->title >= 0) sc->nodes[m->title].text_override = m->notice_ms > 0 ? "Not available yet" : m->label[m->sel];
    if (m->thumb >= 0) {
        UgNode *th = &sc->nodes[m->thumb];
        ug_scene_set_world_pos(sc, m->thumb, ug_icons_thumb_xf(m->n, m->pos), th->wf);
    }
    if (m->arrow_l >= 0) sc->nodes[m->arrow_l].app_hidden = m->sel <= 0;
    if (m->arrow_r >= 0) sc->nodes[m->arrow_r].app_hidden = m->sel >= m->n - 1;
    ug_scene_relayout(sc);
}

/* ---- lifetime ---------------------------------------------------------------------------------- */

void main_menu_destroy(MainMenu *m) {
    if (!m) return;
    if (m->loaded) ug_scene_free(&m->sc);
    if (m->parsed) ug_fng_free(&m->pk);
    ug_gl_destroy(m->gl);
    ug_cv_free(&m->canvas);
    if (m->assets_open) ug_assets_close(&m->assets);
    free(m);
}

MainMenu *main_menu_create(const char *dataroot) {
    MainMenu *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    ug_cv_init(&m->canvas);
    ug_ctx_init(&m->ui);
    m->assets.main_face = -1;
    for (int i = 0; i <= MM_NITEMS; i++) m->avail[i] = 0;
    m->assets_open = ug_assets_open(&m->assets, dataroot, NULL, m->status, sizeof m->status);
    if (!m->assets_open) { fprintf(stderr, "mainmenu: front-end resources unavailable (%s)\n", m->status); goto fail; }
    ug_skin_resolve(&m->skin, &m->assets);
    const UgFace *face = ug_assets_main_face(&m->assets);
    if (!face || face->tex <= 0) { mm_status(m, "%s", "main font unavailable"); goto fail_log; }
    const UgAssetPackage *pk = ug_assets_package(&m->assets, "UI_Main.fng");
    if (!pk) { mm_status(m, "%s", "UI_Main.fng is not in the front-end archive"); goto fail_log; }
    char err[160] = "";
    if (!ug_fng_parse(pk->data, pk->len, &m->pk, err, sizeof err)) {
        snprintf(m->status, sizeof m->status, "UI_Main.fng unreadable (%s)", err);
        goto fail_log;
    }
    m->parsed = 1;
    if (!ug_scene_init(&m->sc, &m->pk, m->assets.have_strings ? &m->assets.strings : NULL)) {
        mm_status(m, "%s", "scene allocation failed");
        goto fail_log;
    }
    m->loaded = 1;
    ug_scene_set_assets(&m->sc, &m->assets);
    m->sc.pc_build = 1;
    m->sc.hide_hint_text = 1;
    m->sc.console_strip = 0;
    ug_scene_update(&m->sc, 0);
    if (!mm_detect(m)) {
        snprintf(m->status, sizeof m->status, "UI_Main.fng: icon strip objects not found (pool %d, slot %d)", m->npool, m->slot);
        goto fail_log;
    }
    if (!mm_bind_items(m)) { mm_status(m, "%s", "MAIN_ICON_* textures missing"); goto fail_log; }
    m->gl = ug_gl_create();
    if (!m->gl) { mm_status(m, "%s", "UI renderer unavailable"); goto fail_log; }
    ug_gl_set_texlib(m->gl, &m->assets.tex);
    mm_apply(m, 0);
    fprintf(stderr, "mainmenu: UI_Main.fng ready (%d objects, %d missing textures, strings %s)\n",
            m->pk.nobj, ug_scene_missing_textures(&m->sc), m->assets.have_strings ? "yes" : "no");
    snprintf(m->status, sizeof m->status, "ready");
    return m;
fail_log:
    fprintf(stderr, "mainmenu: %s; using the placeholder menu\n", m->status);
fail:
    main_menu_destroy(m);
    return NULL;
}

void main_menu_set_available(MainMenu *m, MainMenuChoice c, int available) {
    if (m && c > 0 && c <= MM_NITEMS) m->avail[c] = available != 0;
}
const char *main_menu_status(const MainMenu *m) { return m ? m->status : "no main menu"; }

/* ---- input ------------------------------------------------------------------------------------- */

static void mm_step(MainMenu *m, int dir) {
    if (m->closing) return;
    int ni = m->sel + dir;
    if (ni < 0 || ni >= m->n) return;                         /* no wrap (4.5): the press is ignored */
    m->sel = ni;
    m->notice_ms = 0;
    ug_scene_input_msg(&m->sc, dir < 0 ? UG_MSG_LEFT : UG_MSG_RIGHT);   /* the package's own arrow blink */
}

static void mm_accept(MainMenu *m) {
    if (m->closing || !m->enter_done) return;
    MainMenuChoice c = m->choice[m->sel];
    if (!m->avail[c]) {
        fprintf(stderr, "mainmenu: \"%s\" chosen but not available yet\n", m->label[m->sel]);
        m->notice_ms = MM_NOTICE_MS;
        return;
    }
    fprintf(stderr, "mainmenu: \"%s\" chosen\n", m->label[m->sel]);
    m->chosen = c;
    m->closing = 1;
    m->close_t = 0;
    if (pkg_responds(&m->pk, UG_MSG_REQ_FORWARD)) ug_scene_post(&m->sc, UG_MSG_REQ_FORWARD, 0);   /* the authored exit */
    else m->close_t = UG_TUNE_EXIT_TIMEOUT_MS;
}

void main_menu_event(MainMenu *m, const SDL_Event *e) {
    if (!m) return;
    if (e->type == SDL_KEYDOWN && !e->key.repeat) {
        switch (e->key.keysym.sym) {
        case SDLK_LEFT: mm_step(m, -1); break;
        case SDLK_RIGHT: mm_step(m, +1); break;
        case SDLK_RETURN: case SDLK_KP_ENTER: case SDLK_SPACE: mm_accept(m); break;
        default: break;
        }
    } else if (e->type == SDL_CONTROLLERBUTTONDOWN) {
        switch (e->cbutton.button) {
        case SDL_CONTROLLER_BUTTON_DPAD_LEFT: mm_step(m, -1); break;
        case SDL_CONTROLLER_BUTTON_DPAD_RIGHT: mm_step(m, +1); break;
        case SDL_CONTROLLER_BUTTON_A: case SDL_CONTROLLER_BUTTON_START: mm_accept(m); break;
        default: break;
        }
    } else if (e->type == SDL_MOUSEWHEEL && e->wheel.y) {
        int d = e->wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -e->wheel.y : e->wheel.y;
        mm_step(m, d > 0 ? -1 : 1);
    }
}

static int mm_hit_item(const MainMenu *m, float x, float y) {
    for (int k = 0; k < m->n; k++) {
        UgIconPlace p;
        ug_icon_place(m->pos, k, m->slot_x, m->slot_y, &p);
        if (p.alpha < 0.5f) continue;
        if (ug_rect_hit(UG_RECT_C(p.cx, p.cy, p.w, p.h), x, y)) return k;
    }
    return -1;
}

void main_menu_tap(MainMenu *m, float nx, float ny, int win_w, int win_h) {
    if (!m || m->closing || win_w <= 0 || win_h <= 0) return;
    float x, y;
    pause_menu_to_virtual(pause_menu_transform(win_w, win_h), nx * win_w, ny * win_h, &x, &y);
    x -= 320; y -= 240;                                       /* the scene's centred coordinates */
    if (m->sel > 0 && ug_rect_hit(UG_RECT_C(-UG_R_ARROW_CX, UG_R_ARROW_CY, 44, 44), x, y)) { mm_step(m, -1); return; }
    if (m->sel < m->n - 1 && ug_rect_hit(UG_RECT_C(UG_R_ARROW_CX, UG_R_ARROW_CY, 44, 44), x, y)) { mm_step(m, +1); return; }
    int hit = mm_hit_item(m, x, y);
    if (hit < 0) return;
    if (hit != m->sel) { m->sel = hit; m->notice_ms = 0; ug_scene_input_msg(&m->sc, UG_MSG_RIGHT); }
    else mm_accept(m);
}

/* ---- update / draw ------------------------------------------------------------------------------ */

MainMenuChoice main_menu_update(MainMenu *m, float seconds) {
    if (!m || !m->loaded) return MM_NONE;
    float ms = seconds > 0 ? seconds * 1000.0f : 0.0f;
    if (ms > 100.0f) ms = 100.0f;
    m->ui_ms += ms;
    m->ui.time_ms = m->ui_ms;
    if (m->notice_ms > 0) m->notice_ms -= ms;
    ug_scene_update(&m->sc, ms);
    mm_apply(m, ms);
    uint32_t msg;
    while (ug_scene_poll_app(&m->sc, &msg)) {
        if (msg == UG_MSG_ENTER_DONE && !m->enter_done) { m->enter_done = 1; ug_scene_refocus(&m->sc); }
        else if (msg == UG_MSG_EXIT_DONE) m->exit_done = 1;
    }
    if (!m->enter_done) {                                     /* a package that never reports it must not lock input */
        m->enter_ms += ms;
        if (m->enter_ms > 1500.0f) m->enter_done = 1;
    }
    if (m->closing) {
        m->close_t += ms;
        if (m->exit_done || m->close_t >= UG_TUNE_EXIT_TIMEOUT_MS) {
            MainMenuChoice c = m->chosen;
            m->chosen = MM_NONE;
            m->closing = 0;
            return c;
        }
    }
    return MM_NONE;
}

void main_menu_draw(MainMenu *m, int width, int height) {
    if (!m || !m->loaded || !m->gl || m->draw_failed || width <= 0 || height <= 0) return;
    const UgFace *face = ug_text_face();
    const UgSkin *old = ug_kit_skin();
    UgSkin saved;
    if (old) saved = *old;
    ug_text_set_face(ug_assets_main_face(&m->assets));
    ug_kit_set_skin(&m->skin);
    UgCanvas *cv = &m->canvas;
    ug_cv_clear(cv);
    /* the 3D showcase stays behind: only a soft shade top and bottom so the authored art reads */
    ug_cv_gradient(cv, (UgRect){-1200, -240, 2400, 130}, UG_RGBA(0, 0, 0, 170), UG_RGBA(0, 0, 0, 170), UG_RGBA(0, 0, 0, 0), UG_RGBA(0, 0, 0, 0));
    ug_cv_gradient(cv, (UgRect){-1200, 70, 2400, 170}, UG_RGBA(0, 0, 0, 0), UG_RGBA(0, 0, 0, 0), UG_RGBA(0, 0, 0, 190), UG_RGBA(0, 0, 0, 190));
    ug_scene_draw(&m->sc, &m->ui, cv);
    if (ug_cv_visual_status(cv) == UG_VIS_OK) ug_gl_render_overlay(m->gl, cv, width, height);
    else { m->draw_failed = 1; fprintf(stderr, "mainmenu: UI_Main.fng could not be drawn (art or font missing)\n"); }
    ug_text_set_face(face);
    ug_kit_set_skin(old ? &saved : NULL);
}
