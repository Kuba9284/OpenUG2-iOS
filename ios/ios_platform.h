/* ios_platform.h -- the small iOS layer around the engine (compiled only for iOS, -DOPENUG2_IOS).
 *
 * The engine is a command-line program: it takes the NFSU2 data directory as an argument and keeps its
 * settings and output files in the working directory. An iOS app has neither, so this layer
 *   - points the data directory and the working directory at the app's Documents folder (visible in the
 *     Files app because the Info.plist enables file sharing -- copy the game's TRACKS/, CARS/, ... there);
 *   - sets the SDL hints that have to be set before SDL_Init (landscape only, hidden home indicator);
 *   - stops all GL work while the app is in the background (iOS terminates apps that draw there). */
#ifndef OPENUG2_IOS_PLATFORM_H
#define OPENUG2_IOS_PLATFORM_H

#include <SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call first thing in main(), before SDL_Init. Sets the SDL hints, chdir()s into Documents and returns that
 * directory (valid for the life of the process; never NULL -- "." if the lookup failed). */
const char *ios_platform_init(void);

/* Shows a blocking error dialog (and logs it). A phone has no console, so a failed start would otherwise look like
 * a black screen or a silent exit. Safe to call before or after SDL_Init. */
void ios_platform_fatal(const char *title, const char *message);

/* Returns 1 if the NFSU2 data folders (TRACKS, CARS) are present under root. Otherwise shows a dialog that names the
 * exact folder to copy them into, and returns 0: the caller should exit. Call first thing, before any loading. */
int ios_platform_check_data(const char *root);

/* Feed every SDL event through this. On SDL_APP_WILLENTERBACKGROUND it blocks until the app is foreground
 * again (or quits), so the render loop makes no GL call while backgrounded. Returns 1 if it blocked. */
int ios_platform_event(const SDL_Event *e);

#ifdef __cplusplus
}
#endif

/* Extra SDL_CreateWindow flags for iOS: full screen. Retina rendering is opt-in because the world draws
 * ~930 m of view and fill rate is the first thing a phone runs out of: build with
 * OPENUG2_IOS_HIGHDPI=1 to render at native pixels instead of points. */
#ifdef OPENUG2_IOS_HIGHDPI
#  define OPENUG2_EXTRA_WINDOW_FLAGS (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_BORDERLESS | SDL_WINDOW_ALLOW_HIGHDPI)
#else
#  define OPENUG2_EXTRA_WINDOW_FLAGS (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_BORDERLESS)
#endif

#endif
