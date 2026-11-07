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
        fprintf(stderr, "EVENT t=%.2fs %s subtype %d data %d\n", CFAbsoluteTimeGetCurrent() - g_t0, name,
                (int)e->display.event, (int)e->display.data1);
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
        fprintf(stderr, "Compatibility display: %s\n", ios_compat_display() ? "ON" : "off");

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

/* ---- what UIKit actually has on screen (Super Debug) ---- */
static void dump_view(UIView *v, int depth) {
    char pad[40];
    int n = depth * 2 < 38 ? depth * 2 : 38;
    memset(pad, ' ', (size_t)n);
    pad[n] = 0;
    fprintf(stderr, "UIKIT   %s%s frame (%.0f,%.0f %.0fx%.0f) hidden %d alpha %.2f opaque %d | layer %s opaque %d scale %.1f contents %s | bg %s\n", pad,
            NSStringFromClass(v.class).UTF8String, v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height, (int)v.hidden,
            (double)v.alpha, (int)v.opaque, NSStringFromClass(v.layer.class).UTF8String, (int)v.layer.opaque, (double)v.layer.contentsScale,
            v.layer.contents ? "yes" : "none", v.backgroundColor ? [[v.backgroundColor description] UTF8String] : "none");
    if (depth >= 4) return;
    NSUInteger i = 0;
    for (UIView *s in v.subviews) { if (i++ >= 8) break; dump_view(s, depth + 1); }
}

void ios_debug_save_png(const char *name, const unsigned char *rgba, int w, int h, int flip_y) {
    if (!rgba || w <= 0 || h <= 0) return;
    @autoreleasepool {
        size_t row = (size_t)w * 4;
        unsigned char *copy = (unsigned char *)malloc(row * (size_t)h);
        if (!copy) return;
        for (int y = 0; y < h; y++) {
            memcpy(copy + row * (size_t)y, rgba + row * (size_t)(flip_y ? h - 1 - y : y), row);
            for (int x = 0; x < w; x++) copy[row * (size_t)y + (size_t)x * 4 + 3] = 255;
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef cg = CGBitmapContextCreate(copy, (size_t)w, (size_t)h, 8, row, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGImageRef img = cg ? CGBitmapContextCreateImage(cg) : NULL;
        if (img) {
            UIImage *ui = [UIImage imageWithCGImage:img];
            NSData *png = UIImagePNGRepresentation(ui);
            NSString *path = [[NSString stringWithUTF8String:g_docs] stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
            fprintf(stderr, "SNAPSHOT saved %s (%dx%d): %s\n", name, w, h, [png writeToFile:path atomically:YES] ? "ok" : "FAILED");
            CGImageRelease(img);
        }
        if (cg) CGContextRelease(cg);
        CGColorSpaceRelease(cs);
        free(copy);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void ios_debug_dump_windows(const char *tag, int snapshot) {
    @autoreleasepool {
        UIApplication *app = UIApplication.sharedApplication;
        fprintf(stderr, "UIKIT [%s] app state %ld (0 active, 1 inactive, 2 background), connected scenes %lu, windows %lu\n", tag,
                (long)app.applicationState, (unsigned long)app.connectedScenes.count, (unsigned long)app.windows.count);
        for (UIScene *sc in app.connectedScenes)
            fprintf(stderr, "UIKIT   scene %s state %ld\n", NSStringFromClass(sc.class).UTF8String, (long)sc.activationState);
        UIWindow *sdlw = nil;
        for (UIWindow *w in app.windows) {
            fprintf(stderr, "UIKIT window %s frame (%.0f,%.0f %.0fx%.0f) hidden %d alpha %.2f level %.0f key %d scene %s root %s\n",
                    NSStringFromClass(w.class).UTF8String, w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height, (int)w.hidden,
                    (double)w.alpha, (double)w.windowLevel, (int)w.isKeyWindow, w.windowScene ? "yes" : "none",
                    w.rootViewController ? NSStringFromClass(w.rootViewController.class).UTF8String : "none");
            dump_view(w, 1);
            if (!sdlw && !w.hidden && [NSStringFromClass(w.class) rangeOfString:@"SDL"].location != NSNotFound) sdlw = w;
        }
        if (!snapshot) return;
        if (!sdlw) { fprintf(stderr, "UIKIT snapshot: no visible SDL window to capture\n"); return; }
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sdlw.bounds.size format:fmt];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [sdlw drawViewHierarchyInRect:sdlw.bounds afterScreenUpdates:NO];
        }];
        CGImageRef cg = img.CGImage;
        if (!cg) { fprintf(stderr, "UIKIT snapshot: no image\n"); return; }
        const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        unsigned char *px = (unsigned char *)calloc(w * h, 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(bc, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
        size_t nonblack = 0;
        for (size_t i = 0; i < w * h; i++) if (px[i * 4] > 8 || px[i * 4 + 1] > 8 || px[i * 4 + 2] > 8) nonblack++;
        fprintf(stderr, "UIKIT snapshot of the composed SDL window %zux%zu: non-black %.1f%% -> %s\n", w, h, 100.0 * (double)nonblack / (double)(w * h),
                nonblack == 0 ? "BLACK: UIKit is not showing the GL content" : "UIKit shows content");
        CGContextRelease(bc);
        CGColorSpaceRelease(cs);
        free(px);
        NSString *path = [[NSString stringWithUTF8String:g_docs] stringByAppendingPathComponent:@"openug2-uikit-snapshot.png"];
        fprintf(stderr, "SNAPSHOT saved openug2-uikit-snapshot.png: %s\n", [UIImagePNGRepresentation(img) writeToFile:path atomically:YES] ? "ok" : "FAILED");
    }
}
#pragma clang diagnostic pop

/* ---- compatibility display ---- */
static NSString *const kCompatKey = @"ug2.compatDisplay";
static int g_compat = -1;
static UIView *g_overlay;

int ios_compat_display(void) {
    if (g_compat < 0) {
        NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kCompatKey];
        g_compat = n ? (n.boolValue ? 1 : 0) : 1;   /* on unless the user turned it off */
    }
    return g_compat;
}

void ios_compat_display_set(int on) {
    g_compat = on ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setBool:(on != 0) forKey:kCompatKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static UIView *overlay_view(void) {
    if (g_overlay && g_overlay.window) return g_overlay;
    UIWindow *sdlw = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden && [NSStringFromClass(w.class) rangeOfString:@"SDL"].location != NSNotFound) { sdlw = w; break; }
    }
    if (!sdlw) return nil;
    UIView *ov = [[UIView alloc] initWithFrame:sdlw.bounds];
    ov.userInteractionEnabled = NO;   /* touches still reach SDL's view underneath */
    ov.opaque = YES;
    ov.backgroundColor = UIColor.blackColor;
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.layer.contentsGravity = kCAGravityResize;
    ov.layer.transform = CATransform3DMakeScale(1, -1, 1);   /* GL rows come bottom-up */
    [sdlw addSubview:ov];
    g_overlay = ov;
    fprintf(stderr, "COMPAT display: overlay view installed on %s (%.0fx%.0f)\n", NSStringFromClass(sdlw.class).UTF8String,
            sdlw.bounds.size.width, sdlw.bounds.size.height);
    return ov;
}
#pragma clang diagnostic pop

void ios_display_present(const unsigned char *rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return;
    @autoreleasepool {
        UIView *ov = overlay_view();
        if (!ov) return;
        static CGColorSpaceRef cs;
        if (!cs) cs = CGColorSpaceCreateDeviceRGB();
        CFDataRef data = CFDataCreate(NULL, rgba, (CFIndex)w * h * 4);   /* a copy: Core Animation reads it later */
        CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
        CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast, prov, NULL, false,
                                       kCGRenderingIntentDefault);
        if (img) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ov.layer.contents = (__bridge id)img;
            [CATransaction commit];
            [CATransaction flush];   /* the run loop that would commit this is not ours to wait for */
            CGImageRelease(img);
        }
        CGDataProviderRelease(prov);
        CFRelease(data);
    }
}
