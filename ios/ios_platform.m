/* ios_platform.m -- see ios_platform.h */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <execinfo.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <os/proc.h>

#include "ios_platform.h"

static char g_docs[1024];
static void log_event(const SDL_Event *e);

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

void ios_platform_fatal(const char *title, const char *message) {
    fprintf(stderr, "FATAL: %s: %s\n", title, message);
    fflush(stderr);
    /* The alert is presented through SDL's UIKit video driver: make sure it is up (SDL_Init later is reference counted). */
    if (!SDL_WasInit(SDL_INIT_VIDEO)) SDL_InitSubSystem(SDL_INIT_VIDEO);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, title, message, NULL);
}

static int is_dir(const char *root, const char *name) {
    char p[1100];
    struct stat st;
    snprintf(p, sizeof p, "%s/%s", root, name);
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

int ios_platform_check_data(const char *root) {
    const int tracks = is_dir(root, "TRACKS"), cars = is_dir(root, "CARS");
    fprintf(stderr, "data check: %s  TRACKS=%s CARS=%s\n", root, tracks ? "ok" : "MISSING", cars ? "ok" : "MISSING");
    if (tracks && cars) return 1;
    char m[1600];
    snprintf(m, sizeof m,
             "The NFSU2 game files were not found, missing: %s%s%s.\n\n"
             "Copy the TRACKS and CARS folders (and the rest of the game's data folders, such as GLOBAL) from your own NFSU2 install into this folder, then reopen:\n\n%s",
             tracks ? "" : "TRACKS", (!tracks && !cars) ? " and " : "", cars ? "" : "CARS", root);
    ios_platform_fatal("NFSU2 data not found", m);
    return 0;
}

int ios_platform_event(const SDL_Event *e) {
    log_event(e);
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

/* ------------------------------------------------------------------------------------------------------------- */
/* Super Debug Mode, logging, crash and lifecycle watchers                                                        */
/* ------------------------------------------------------------------------------------------------------------- */
static NSString *const kSuperDebugKey = @"ug2.superDebug";
static int g_super_debug = -1;
static _Atomic unsigned long long g_note_frame;
static int g_log_fd = 2;
static CFAbsoluteTime g_t0;
static dispatch_source_t g_heartbeat;

int ios_super_debug(void) {
    if (g_super_debug < 0) g_super_debug = [[NSUserDefaults standardUserDefaults] boolForKey:kSuperDebugKey] ? 1 : 0;
    return g_super_debug;
}

void ios_super_debug_set(int on) {
    g_super_debug = on ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setBool:(on != 0) forKey:kSuperDebugKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

long ios_debug_resident_mb(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (long)(info.resident_size >> 20);
}

long ios_debug_avail_mb(void) {
    size_t b = os_proc_available_memory();   /* 0 = unsupported / failed */
    return b ? (long)(b >> 20) : -1;
}

void ios_debug_note_frame(unsigned long long frame) { atomic_store(&g_note_frame, frame + 1); }

static void crash_signal(int sig) {
    char m[64];
    int n = snprintf(m, sizeof m, "\nCRASH: fatal signal %d\n", sig);
    if (n > 0) (void)!write(g_log_fd, m, (size_t)n);
    void *bt[48];
    int depth = backtrace(bt, 48);
    backtrace_symbols_fd(bt, depth, g_log_fd);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void crash_exception(NSException *ex) {
    fprintf(stderr, "\nCRASH: uncaught exception %s: %s\n%s\n", ex.name.UTF8String, ex.reason.UTF8String,
            [[ex callStackSymbols] description].UTF8String);
    fflush(stderr);
}

static const char *sdl_event_name(Uint32 t) {
    switch (t) {
    case SDL_APP_TERMINATING: return "APP_TERMINATING";
    case SDL_APP_LOWMEMORY: return "APP_LOWMEMORY";
    case SDL_APP_WILLENTERBACKGROUND: return "APP_WILLENTERBACKGROUND";
    case SDL_APP_DIDENTERBACKGROUND: return "APP_DIDENTERBACKGROUND";
    case SDL_APP_WILLENTERFOREGROUND: return "APP_WILLENTERFOREGROUND";
    case SDL_APP_DIDENTERFOREGROUND: return "APP_DIDENTERFOREGROUND";
    case SDL_QUIT: return "QUIT";
    case SDL_DISPLAYEVENT: return "DISPLAYEVENT";
    default: return NULL;
    }
}

static const char *sdl_window_event_name(Uint8 w) {
    switch (w) {
    case SDL_WINDOWEVENT_SHOWN: return "shown";
    case SDL_WINDOWEVENT_HIDDEN: return "hidden";
    case SDL_WINDOWEVENT_EXPOSED: return "exposed";
    case SDL_WINDOWEVENT_MOVED: return "moved";
    case SDL_WINDOWEVENT_RESIZED: return "resized";
    case SDL_WINDOWEVENT_SIZE_CHANGED: return "size_changed";
    case SDL_WINDOWEVENT_MINIMIZED: return "minimized";
    case SDL_WINDOWEVENT_MAXIMIZED: return "maximized";
    case SDL_WINDOWEVENT_RESTORED: return "restored";
    case SDL_WINDOWEVENT_FOCUS_GAINED: return "focus_gained";
    case SDL_WINDOWEVENT_FOCUS_LOST: return "focus_lost";
    case SDL_WINDOWEVENT_CLOSE: return "close";
    default: return "other";
    }
}

/* Lifecycle events are always logged (an app that is suspended or low on memory explains a lot); the rest only in Super Debug Mode. */
static void log_event(const SDL_Event *e) {
    const char *name = sdl_event_name(e->type);
    const int lifecycle = name && e->type != SDL_DISPLAYEVENT;
    if (lifecycle) {
        fprintf(stderr, "EVENT t=%.2fs %s (resident %ld MB, available %ld MB)\n", CFAbsoluteTimeGetCurrent() - g_t0, name,
                ios_debug_resident_mb(), ios_debug_avail_mb());
        return;
    }
    if (!ios_super_debug()) return;
    static int touches;
    if (name) {
        fprintf(stderr, "EVENT t=%.2fs %s subtype %d data %d,%d\n", CFAbsoluteTimeGetCurrent() - g_t0, name,
                (int)e->display.event, (int)e->display.data1, (int)e->display.data2);
    } else if (e->type == SDL_WINDOWEVENT) {
        fprintf(stderr, "EVENT t=%.2fs WINDOW %s %d,%d\n", CFAbsoluteTimeGetCurrent() - g_t0,
                sdl_window_event_name(e->window.event), (int)e->window.data1, (int)e->window.data2);
    } else if ((e->type == SDL_FINGERDOWN || e->type == SDL_FINGERUP) && touches < 60) {
        touches++;
        fprintf(stderr, "EVENT t=%.2fs FINGER%s x=%.3f y=%.3f%s\n", CFAbsoluteTimeGetCurrent() - g_t0,
                e->type == SDL_FINGERDOWN ? "DOWN" : "UP", e->tfinger.x, e->tfinger.y,
                touches == 60 ? "   (further touches not logged)" : "");
    } else if (e->type == SDL_KEYDOWN && !e->key.repeat) {
        fprintf(stderr, "EVENT t=%.2fs KEYDOWN %s\n", CFAbsoluteTimeGetCurrent() - g_t0, SDL_GetKeyName(e->key.keysym.sym));
    }
}

static void dump_environment(void) {
    @autoreleasepool {
        char machine[64] = "?", model[64] = "?";
        size_t n = sizeof machine;
        sysctlbyname("hw.machine", machine, &n, NULL, 0);
        n = sizeof model;
        sysctlbyname("hw.model", model, &n, NULL, 0);
        NSProcessInfo *pi = NSProcessInfo.processInfo;
        UIScreen *sc = UIScreen.mainScreen;
        fprintf(stderr, "ENV device: %s (%s)  iOS %s  cores %lu active %lu  RAM %llu MB\n", machine, model,
                UIDevice.currentDevice.systemVersion.UTF8String, (unsigned long)pi.processorCount,
                (unsigned long)pi.activeProcessorCount, (unsigned long long)(pi.physicalMemory >> 20));
        fprintf(stderr, "ENV screen: %.0fx%.0f pt, scale %.2f, native scale %.2f, up to %ld fps\n", sc.bounds.size.width,
                sc.bounds.size.height, (double)sc.scale, (double)sc.nativeScale, (long)sc.maximumFramesPerSecond);
        fprintf(stderr, "ENV state: thermal %ld (0 nominal .. 3 critical), low-power mode %s, available memory %ld MB, resident %ld MB\n",
                (long)pi.thermalState, pi.lowPowerModeEnabled ? "ON" : "off", ios_debug_avail_mb(), ios_debug_resident_mb());
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        fprintf(stderr, "ENV app: %s  v%s (%s)  bundle %s\n", [info[@"CFBundleDisplayName"] UTF8String] ?: "?",
                [info[@"CFBundleShortVersionString"] UTF8String] ?: "?", [info[@"CFBundleVersion"] UTF8String] ?: "?",
                NSBundle.mainBundle.bundlePath.UTF8String);
        NSURL *docs = [NSURL fileURLWithPath:[NSString stringWithUTF8String:g_docs]];
        NSDictionary *v = [docs resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil];
        NSNumber *free_b = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
        if (free_b) fprintf(stderr, "ENV disk: %lld MB free for the app\n", free_b.longLongValue >> 20);
        /* Hosts such as LiveContainer leave their own variables behind: they explain odd paths and sandboxes. */
        for (NSString *k in [pi.environment.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([k hasPrefix:@"LC_"] || [k hasPrefix:@"LIVE"] || [k hasPrefix:@"DYLD_"] || [k hasPrefix:@"SIDESTORE"])
                fprintf(stderr, "ENV var: %s=%.200s\n", k.UTF8String, [pi.environment[k] UTF8String]);
        }
        fprintf(stderr, "ENV sdl: SDL %d.%d.%d, video driver %s\n", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL,
                SDL_GetCurrentVideoDriver() ?: "(not started)");
    }
}

static void start_heartbeat(void) {
    g_heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(g_heartbeat, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __block unsigned long long last = 0;
    dispatch_source_set_event_handler(g_heartbeat, ^{
        unsigned long long f = atomic_load(&g_note_frame);
        const double t = CFAbsoluteTimeGetCurrent() - g_t0;
        const long th = (long)NSProcessInfo.processInfo.thermalState;
        if (!f)
            fprintf(stderr, "HEARTBEAT t=%.0fs no frame presented yet (loading, or the render loop never started)  resident %ld MB, available %ld MB, thermal %ld\n",
                    t, ios_debug_resident_mb(), ios_debug_avail_mb(), th);
        else
            fprintf(stderr, "HEARTBEAT t=%.0fs frame %llu (+%llu in 2 s%s)  resident %ld MB, available %ld MB, thermal %ld\n", t, f - 1,
                    f - last, f == last ? " -- NO FRAMES: the loop is stalled" : "", ios_debug_resident_mb(), ios_debug_avail_mb(), th);
        last = f;
    });
    dispatch_resume(g_heartbeat);
}

void ios_platform_begin_log(void) {
    g_t0 = CFAbsoluteTimeGetCurrent();
    /* One run per file: the previous run's log is kept as openug2-previous.log (shareable from Settings). */
    rename("openug2.log", "openug2-previous.log");
    if (freopen("openug2.log", "a", stderr)) setvbuf(stderr, NULL, _IONBF, 0);
    if (freopen("openug2.log", "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
    g_log_fd = fileno(stderr);
    @autoreleasepool {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
        fprintf(stderr, "OpenUG2 iOS log, %s\n", [df stringFromDate:[NSDate date]].UTF8String);
        fprintf(stderr, "OpenUG2 iOS: Documents = %s\n", g_docs);
        fprintf(stderr, "Super Debug Mode: %s\n", ios_super_debug() ? "ON" : "off");

        signal(SIGSEGV, crash_signal); signal(SIGBUS, crash_signal); signal(SIGABRT, crash_signal);
        signal(SIGILL, crash_signal); signal(SIGFPE, crash_signal); signal(SIGTRAP, crash_signal);
        NSSetUncaughtExceptionHandler(&crash_exception);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            fprintf(stderr, "LIFECYCLE t=%.2fs iOS MEMORY WARNING (resident %ld MB, available %ld MB)\n", CFAbsoluteTimeGetCurrent() - g_t0,
                    ios_debug_resident_mb(), ios_debug_avail_mb());
        }];
        [nc addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            fprintf(stderr, "LIFECYCLE t=%.2fs thermal state now %ld\n", CFAbsoluteTimeGetCurrent() - g_t0, (long)NSProcessInfo.processInfo.thermalState);
        }];
    }
    if (ios_super_debug()) {
        dump_environment();
        start_heartbeat();
    }
}
