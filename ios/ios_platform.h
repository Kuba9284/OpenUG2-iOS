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
 * directory (valid for the life of the process; never NULL -- "." if the lookup failed). Does not start the log:
 * the launcher runs first (ios_launcher_run) and the log starts when Play is tapped (ios_platform_begin_log). */
const char *ios_platform_init(void);

/* The launcher (ios_launcher.m): a native two-tab screen shown before the engine starts. "Play" checks the NFSU2
 * files and starts the game, "Settings" holds Super Debug Mode and log sharing. Blocks until Play is tapped, then
 * returns 1 and writes the game data folder (Documents, or a folder inside it that holds TRACKS and CARS) to
 * root_out. Returns 0 if the launcher could not be shown (the caller carries on with Documents). */
int ios_launcher_run(const char *docs, char *root_out, size_t root_cap);

/* Starts logging: moves the last run's openug2.log to openug2-previous.log, sends stderr and stdout to a fresh
 * openug2.log, writes a header, installs the crash/lifecycle watchers and, in Super Debug Mode, dumps the
 * device environment and starts the heartbeat thread. Call once, right after the launcher. */
void ios_platform_begin_log(void);

/* Super Debug Mode (the Settings switch, persisted). When on, the engine logs far more: device and GL limits, a GL
 * self-test, every GL call's error status, a picture probe each few seconds, per-second statistics, lifecycle and
 * touch events. It costs frame rate; leave it off for normal play. */
int  ios_super_debug(void);
void ios_super_debug_set(int on);   /* the launcher's switch: saved, and in effect for this run */

/* Process memory in MB (resident set / still available before iOS ends the app); -1 if unknown. */
long ios_debug_resident_mb(void);
long ios_debug_avail_mb(void);

/* Super Debug: logs every UIWindow and the SDL view hierarchy (frames, hidden/alpha/opaque, whether the GL layer has
 * contents) and, if snapshot is nonzero, saves what UIKit itself composes for the SDL window to
 * Documents/openug2-uikit-snapshot.png and logs how much of it is non-black. Main thread only. */
void ios_debug_dump_windows(const char *tag, int snapshot);

/* Saves an RGBA8 pixel buffer as Documents/<name> (alpha forced opaque; flip_y for GL's bottom-up rows). */
void ios_debug_save_png(const char *name, const unsigned char *rgba, int w, int h, int flip_y);

/* Called once per presented frame so the heartbeat thread can tell a stalled render loop from a slow one. */
void ios_debug_note_frame(unsigned long long frame);

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
