/* ios_platform.m -- see ios_platform.h */
#import <Foundation/Foundation.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

#include "ios_platform.h"

static char g_docs[1024];

const char *ios_platform_init(void) {
    /* Hints are read when the video subsystem starts, so they go in before SDL_Init. */
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");        /* hidden, swipe once to reveal */
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");             /* touches drive the on-screen controls only, not the mouse path */
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0");      /* else SDL lists the accelerometer as a pad */

    @autoreleasepool {
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        const char *p = dirs.count ? dirs[0].fileSystemRepresentation : NULL;
        if (p && strlen(p) < sizeof g_docs) strcpy(g_docs, p);
    }
    if (!g_docs[0]) { strcpy(g_docs, "."); return g_docs; }

    /* Settings, controls and any file the engine writes with a relative path land in Documents too. */
    if (chdir(g_docs) != 0) perror("openug2: chdir(Documents)");
    return g_docs;
}

int ios_platform_event(const SDL_Event *e) {
    if (e->type != SDL_APP_WILLENTERBACKGROUND) return 0;
    /* SDL delivers this on the UI thread right before iOS suspends us. Any GL call after it kills the app,
       so wait here -- inside the event handler, before the frame loop gets to draw again. */
    SDL_Event ev;
    while (SDL_WaitEvent(&ev)) {
        if (ev.type == SDL_APP_DIDENTERFOREGROUND || ev.type == SDL_QUIT || ev.type == SDL_APP_TERMINATING) {
            if (ev.type != SDL_APP_DIDENTERFOREGROUND) SDL_PushEvent(&ev);   /* let the loop see the quit */
            break;
        }
    }
    return 1;
}
