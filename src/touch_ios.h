/* touch_ios.h -- on-screen touch controls for the iOS build (-DOPENUG2_TOUCH).
 *
 * Driving: a steering strip on the left (drag the finger left/right of the strip's centre: analog), and
 * GAS / BRK / NOS / HB buttons on the right, plus PAUSE / CAM / RESET / LOOK along the top. While the
 * pause menu is open the layout switches to a D-pad with OK / BACK that feeds the menu the same key events
 * a keyboard would. Multi-touch: every finger owns the control it landed on until it lifts.
 *
 * Integration (everything is behind #ifdef OPENUG2_TOUCH, so desktop builds are unchanged):
 *   touch_init(&g_cx)           after cx_init
 *   touch_handle_event(&e)      for every SDL event
 *   cx_action_down / cx_steer   (controls_sdl.c) ask touch_action_down / touch_steer
 *   touch_draw(...)             last thing drawn in the frame
 * Held actions (throttle, brake, handbrake, nitrous, look back) are read as state; pressed actions (pause,
 * camera, reset) are pushed as SDL key events using whatever key the Controls screen has bound to them. */
#ifndef OPENUG2_TOUCH_IOS_H
#define OPENUG2_TOUCH_IOS_H

#include <SDL.h>

#include "controls_sdl.h"
#include "render.h"
#include "rhi.h"

#ifdef __cplusplus
extern "C" {
#endif

void  touch_init(const CxInput *cx);
void  touch_handle_event(const SDL_Event *e);

/* Held-state queries for the driving code (CB_ACT_* from controls_bind.h). Always 0 while a menu is open. */
int   touch_action_down(int action);
/* Steering +1 (full left) .. -1 (full right), 0 when no finger is on the strip: same sign as cx_steer. */
float touch_steer(void);

/* Draws the controls for the current mode on top of the finished frame. w/h = drawable size in pixels. */
void  touch_draw(const RProg *rp, GpuMesh *quad, const UG2OverlayPipelines *ovp, int w, int h, int menu_open);

#ifdef __cplusplus
}
#endif

#endif
