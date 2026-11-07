/* ios_launcher.m -- the native start screen: a "Play" tab that checks the NFSU2 files, and a "Settings" tab with
 * Super Debug Mode and log sharing. See ios_platform.h.
 *
 * It is plain UIKit and runs before SDL has created any window or GL context, so it still works when the engine's
 * renderer is what is broken. ios_launcher_run() puts its own UIWindow up on top of SDL's launch screen and spins the
 * main run loop until Play is tapped; then it takes the window down and returns to main(), which starts the engine. */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <stdio.h>
#include <sys/sysctl.h>

#include "ios_platform.h"

/* ------------------------------------------------------------------------------------------------------------- */
/* File checks                                                                                                    */
/* ------------------------------------------------------------------------------------------------------------- */

/* One expected item. "rel" is relative to the game folder; "A|B" accepts either; a trailing "/" means a folder. */
typedef struct { const char *title, *rel; } UG2Item;

/* Without these the engine cannot start the default free-roam world and car. */
static const UG2Item kRequired[] = {
    { "City stream",      "TRACKS/STREAML4RA.BUN" },
    { "City companion",   "TRACKS/L4RA.BUN" },
    { "Default car mesh", "CARS/HUMMER/GEOMETRY.BIN" },
    { "Default car tex",  "CARS/HUMMER/TEXTURES.BIN" },
};

/* The engine starts without some of these but misses menus, text, sound, traffic or road paths. */
static const UG2Item kRecommended[] = {
    { "Global A",         "GLOBAL/GLOBALA.BUN" },
    { "Global B",         "GLOBAL/GLOBALB.BUN|GLOBAL/GlobalB.lzc" },
    { "In-game common",   "GLOBAL/InGameCommon.bun" },
    { "HUD textures",     "GLOBAL/HUD_CustomTextures_ALL.bin" },
    { "Front end",        "FRONTEND/FrontB.lzc" },
    { "English text",     "LANGUAGES/English.bin" },
    { "Language textures","LANGUAGES/LanguageTextures.bin" },
    { "Engine sounds",    "SOUND/ENGINE/" },
    { "Road paths",       "TRACKS/ROUTESL4RF/Paths4602.bin" },
    { "Track map",        "TRACKS/TRACKMAP4000.BIN" },
    { "Wheel textures",   "CARS/WHEELS/TEXTURES.BIN" },
    { "Licence plates",   "CARS/PLATES/GEOMETRY.BIN" },
};

/* Walks rel under root matching every name case-insensitively (the files often arrive upper- or lower-cased). */
static NSString *ci_resolve(NSString *root, NSString *rel) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *cur = root;
    for (NSString *comp in [rel componentsSeparatedByString:@"/"]) {
        if (comp.length == 0) continue;
        NSString *direct = [cur stringByAppendingPathComponent:comp];
        if ([fm fileExistsAtPath:direct]) { cur = direct; continue; }
        NSString *hit = nil;
        for (NSString *n in [fm contentsOfDirectoryAtPath:cur error:nil]) {
            if ([n caseInsensitiveCompare:comp] == NSOrderedSame) { hit = n; break; }
        }
        if (!hit) return nil;
        cur = [cur stringByAppendingPathComponent:hit];
    }
    return cur;
}

static BOOL is_dir_at(NSString *path) {
    BOOL dir = NO;
    return path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir] && dir;
}

static NSString *size_text(unsigned long long b) {
    if (b >= (1ull << 30)) return [NSString stringWithFormat:@"%.2f GB", (double)b / (double)(1ull << 30)];
    if (b >= (1ull << 20)) return [NSString stringWithFormat:@"%.1f MB", (double)b / (double)(1ull << 20)];
    if (b >= 1024) return [NSString stringWithFormat:@"%.0f KB", (double)b / 1024.0];
    return [NSString stringWithFormat:@"%llu B", b];
}

/* Where the game folder is: Documents itself, or a folder inside it (up to two levels, e.g. Documents/NFSU2) that
 * holds both TRACKS and CARS. The first match wins; otherwise Documents, so the checks name what is missing there. */
static NSString *find_game_root(NSString *docs) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (ci_resolve(docs, @"TRACKS") && ci_resolve(docs, @"CARS")) return docs;
    for (NSString *a in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        NSString *pa = [docs stringByAppendingPathComponent:a];
        if (!is_dir_at(pa)) continue;
        if (ci_resolve(pa, @"TRACKS") && ci_resolve(pa, @"CARS")) return pa;
        for (NSString *b in [fm contentsOfDirectoryAtPath:pa error:nil]) {
            NSString *pb = [pa stringByAppendingPathComponent:b];
            if (is_dir_at(pb) && ci_resolve(pb, @"TRACKS") && ci_resolve(pb, @"CARS")) return pb;
        }
    }
    return docs;
}

@interface UG2Row : NSObject
@property (nonatomic, copy) NSString *title, *detail;
@property (nonatomic) BOOL ok;
@end
@implementation UG2Row
@end

/* The outcome of one scan of the files. */
@interface UG2Scan : NSObject
@property (nonatomic, copy) NSString *root;
@property (nonatomic, strong) NSMutableArray<UG2Row *> *required, *recommended, *library;
@property (nonatomic) NSInteger requiredMissing, recommendedMissing;
@end
@implementation UG2Scan
@end

static UG2Row *check_item(NSString *root, const UG2Item *it) {
    UG2Row *row = [[UG2Row alloc] init];
    row.title = [NSString stringWithUTF8String:it->title];
    NSString *rel = [NSString stringWithUTF8String:it->rel];
    NSArray<NSString *> *alts = [rel componentsSeparatedByString:@"|"];
    NSString *firstShown = alts.firstObject;
    for (NSString *alt in alts) {
        NSString *found = ci_resolve(root, alt);
        if (!found) continue;
        BOOL want_dir = [alt hasSuffix:@"/"];
        NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:found error:nil];
        if (want_dir) {
            if (!is_dir_at(found)) { row.ok = NO; row.detail = [alt stringByAppendingString:@"  (not a folder)"]; return row; }
            NSUInteger n = [NSFileManager.defaultManager contentsOfDirectoryAtPath:found error:nil].count;
            row.ok = n > 0;
            row.detail = [NSString stringWithFormat:@"%@  (%lu files)", alt, (unsigned long)n];
            return row;
        }
        unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
        if (sz == 0) { row.ok = NO; row.detail = [alt stringByAppendingString:@"  (empty file: copy it again)"]; return row; }
        row.ok = YES;
        NSString *shown = [found substringFromIndex:MIN(found.length, root.length + 1)];
        row.detail = [NSString stringWithFormat:@"%@  (%@)%@", shown, size_text(sz),
                      [shown isEqualToString:alt] ? @"" : @"  [letter case differs from the original]"];
        return row;
    }
    row.ok = NO;
    row.detail = [NSString stringWithFormat:@"missing: %@", firstShown];
    return row;
}

static UG2Scan *scan_files(NSString *docs) {
    UG2Scan *s = [[UG2Scan alloc] init];
    s.root = find_game_root(docs);
    s.required = [NSMutableArray array];
    s.recommended = [NSMutableArray array];
    s.library = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kRequired / sizeof kRequired[0]; i++) {
        UG2Row *r = check_item(s.root, &kRequired[i]);
        if (!r.ok) s.requiredMissing++;
        [s.required addObject:r];
    }
    for (size_t i = 0; i < sizeof kRecommended / sizeof kRecommended[0]; i++) {
        UG2Row *r = check_item(s.root, &kRecommended[i]);
        if (!r.ok) s.recommendedMissing++;
        [s.recommended addObject:r];
    }
    /* What is installed, for information: cars with geometry, and track streams. */
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *cars = ci_resolve(s.root, @"CARS"), *tracks = ci_resolve(s.root, @"TRACKS");
    NSMutableArray<NSString *> *carNames = [NSMutableArray array];
    for (NSString *c in [fm contentsOfDirectoryAtPath:cars ?: @"" error:nil]) {
        if (ci_resolve([cars stringByAppendingPathComponent:c], @"GEOMETRY.BIN") && ![c.uppercaseString isEqualToString:@"WHEELS"] &&
            ![c.uppercaseString isEqualToString:@"PLATES"]) [carNames addObject:c];
    }
    NSInteger streams = 0;
    for (NSString *t in [fm contentsOfDirectoryAtPath:tracks ?: @"" error:nil])
        if ([t.uppercaseString hasPrefix:@"STREAM"] && [t.uppercaseString hasSuffix:@".BUN"]) streams++;
    UG2Row *rc = [[UG2Row alloc] init];
    rc.title = @"Cars found";
    rc.ok = carNames.count > 0;
    rc.detail = carNames.count ? [NSString stringWithFormat:@"%lu  (%@%@)", (unsigned long)carNames.count,
                                  [[carNames subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, carNames.count))] componentsJoinedByString:@", "],
                                  carNames.count > 6 ? @", ..." : @""] : @"none";
    UG2Row *rt = [[UG2Row alloc] init];
    rt.title = @"Track streams found";
    rt.ok = streams > 0;
    rt.detail = [NSString stringWithFormat:@"%ld", (long)streams];
    [s.library addObject:rc];
    [s.library addObject:rt];
    return s;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Launcher state shared by the two tabs                                                                          */
/* ------------------------------------------------------------------------------------------------------------- */
static NSString *g_docs_path;
static NSString *g_chosen_root;
static BOOL g_done;

static NSString *log_path(NSString *name) { return [g_docs_path stringByAppendingPathComponent:name]; }

/* ------------------------------------------------------------------------------------------------------------- */
/* Play tab                                                                                                       */
/* ------------------------------------------------------------------------------------------------------------- */
@interface UG2PlayVC : UITableViewController
@property (nonatomic, strong) UG2Scan *scan;
@end

@implementation UG2PlayVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"Play";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Re-check" style:UIBarButtonItemStylePlain
                                                                            target:self action:@selector(recheck)];
    [self recheck];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self recheck];   /* files may have been copied in with the Files app meanwhile */
}

- (void)recheck {
    self.scan = scan_files(g_docs_path);
    [self.tableView reloadData];
}

- (BOOL)ready { return self.scan.requiredMissing == 0; }

- (void)play {
    if (![self ready]) return;
    if (self.scan.recommendedMissing > 0) {
        NSString *msg = [NSString stringWithFormat:@"%ld recommended files are missing. The game may start without menus, text or sound, or stop early. See the list under Recommended.",
                         (long)self.scan.recommendedMissing];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Some files are missing" message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Play anyway" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self start]; }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self start];
}

- (void)start {
    g_chosen_root = self.scan.root;
    g_done = YES;
}

/* sections: 0 status+play, 1 required, 2 recommended, 3 library */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
    case 0: return 3;
    case 1: return (NSInteger)self.scan.required.count;
    case 2: return (NSInteger)self.scan.recommended.count;
    default: return (NSInteger)self.scan.library.count;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
    case 0: return nil;
    case 1: return [NSString stringWithFormat:@"Required (%ld missing)", (long)self.scan.requiredMissing];
    case 2: return [NSString stringWithFormat:@"Recommended (%ld missing)", (long)self.scan.recommendedMissing];
    default: return @"Installed";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0 && ![self ready])
        return @"Copy the game's folders (TRACKS, CARS, GLOBAL, FRONTEND, LANGUAGES, SOUND ...) from your own NFSU2 install into this app's folder with the Files app, then tap Re-check. The game files are not included and are not downloaded.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        if (ip.row == 0) {
            BOOL ready = [self ready];
            cell.textLabel.text = ready ? @"▶  Play NFSU2" : @"▶  Play NFSU2 (files missing)";
            cell.textLabel.textColor = ready ? self.view.tintColor : UIColor.secondaryLabelColor;
            cell.textLabel.font = [UIFont boldSystemFontOfSize:20];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = ready ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        } else if (ip.row == 1) {
            cell.textLabel.text = @"Game folder";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n(tap to copy)", self.scan.root];
        } else {
            BOOL ready = [self ready];
            cell.textLabel.text = ready ? @"All required files found" : [NSString stringWithFormat:@"%ld required files missing", (long)self.scan.requiredMissing];
            cell.textLabel.textColor = ready ? UIColor.systemGreenColor : UIColor.systemRedColor;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Compatibility display %@, Super Debug Mode %@ (Settings tab)",
                                         ios_compat_display() ? @"ON" : @"off", ios_super_debug() ? @"ON" : @"off"];
        }
        return cell;
    }
    NSArray<UG2Row *> *rows = ip.section == 1 ? self.scan.required : ip.section == 2 ? self.scan.recommended : self.scan.library;
    UG2Row *r = rows[(NSUInteger)ip.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", r.ok ? @"✓" : @"✗", r.title];
    cell.textLabel.textColor = r.ok ? UIColor.labelColor : (ip.section == 1 ? UIColor.systemRedColor : UIColor.systemOrangeColor);
    cell.detailTextLabel.text = r.detail;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    if (ip.row == 0) [self play];
    if (ip.row == 1) {
        UIPasteboard.generalPasteboard.string = self.scan.root;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Path copied" message:self.scan.root preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

/* ------------------------------------------------------------------------------------------------------------- */
/* Settings tab                                                                                                   */
/* ------------------------------------------------------------------------------------------------------------- */
@interface UG2SettingsVC : UITableViewController
@end

@implementation UG2SettingsVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"Settings";
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

static NSString *machine_id(void) {
    char m[64] = "?";
    size_t n = sizeof m;
    sysctlbyname("hw.machine", m, &n, NULL, 0);
    return [NSString stringWithUTF8String:m];
}

static NSString *file_line(NSString *name) {
    NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:log_path(name) error:nil];
    if (!at) return @"not there yet";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterShortStyle;
    df.timeStyle = NSDateFormatterMediumStyle;
    return [NSString stringWithFormat:@"%@, %@", size_text([at[NSFileSize] unsignedLongLongValue]), [df stringFromDate:at[NSFileModificationDate]]];
}

/* sections: 0 display, 1 debug, 2 logs, 3 device, 4 about */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
    case 0: return 1;
    case 1: return 1;
    case 2: return 3;
    case 3: return 6;
    default: return 2;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
    case 0: return @"Display";
    case 1: return @"Debugging";
    case 2: return @"Logs";
    case 3: return @"This device";
    default: return @"About";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0)
        return @"Shows the game through a normal UIKit view instead of the OpenGL layer. Turn it on if the game screen stays black while the sound plays (seen on iOS 27 and inside LiveContainer). It copies every frame, so it costs some speed, and it caps the game at 60 fps.";
    if (s == 1)
        return @"Logs the device and OpenGL limits, runs a GL self-test on the screen, checks every OpenGL call for errors and names the one that fails, inspects the rendered picture, and records per-second statistics, memory and lifecycle events. It slows the game down; leave it off for normal play.";
    if (s == 2) return @"Each run writes Documents/openug2.log; the run before is kept as openug2-previous.log. Send the log after trying the game with Super Debug Mode on.";
    return nil;
}

- (void)debugSwitched:(UISwitch *)sw {
    ios_super_debug_set(sw.isOn);
}

- (void)compatSwitched:(UISwitch *)sw {
    ios_compat_display_set(sw.isOn);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.numberOfLines = 0;
    if (ip.section == 0) {
        cell.textLabel.text = @"Compatibility display";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = ios_compat_display() != 0;
        [sw addTarget:self action:@selector(compatSwitched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (ip.section == 1) {
        cell.textLabel.text = @"Super Debug Mode";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = ios_super_debug() != 0;
        [sw addTarget:self action:@selector(debugSwitched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (ip.section == 2) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = self.view.tintColor;
        if (ip.row == 0) { cell.textLabel.text = @"Share latest log"; cell.detailTextLabel.text = file_line(@"openug2.log"); }
        if (ip.row == 1) { cell.textLabel.text = @"Share previous log"; cell.detailTextLabel.text = file_line(@"openug2-previous.log"); }
        if (ip.row == 2) { cell.textLabel.text = @"Delete logs"; cell.textLabel.textColor = UIColor.systemRedColor; }
        return cell;
    }
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    UIScreen *sc = UIScreen.mainScreen;
    if (ip.section == 3) {
        switch (ip.row) {
        case 0: cell.textLabel.text = @"Model"; cell.detailTextLabel.text = machine_id(); break;
        case 1: cell.textLabel.text = @"iOS"; cell.detailTextLabel.text = UIDevice.currentDevice.systemVersion; break;
        case 2: cell.textLabel.text = @"Memory"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%llu MB (%ld MB available to the app)",
                                                                              (unsigned long long)(pi.physicalMemory >> 20), ios_debug_avail_mb()]; break;
        case 3: cell.textLabel.text = @"Screen"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f x %.0f pt @%.0fx, %ld Hz",
                                                                              sc.bounds.size.width, sc.bounds.size.height, (double)sc.scale, (long)sc.maximumFramesPerSecond]; break;
        case 4: cell.textLabel.text = @"Low Power Mode"; cell.detailTextLabel.text = pi.lowPowerModeEnabled ? @"ON (slows the game)" : @"off"; break;
        default: cell.textLabel.text = @"Thermal state"; cell.detailTextLabel.text = @[@"nominal", @"fair", @"serious", @"critical"][MIN((NSUInteger)3, (NSUInteger)pi.thermalState)]; break;
        }
        return cell;
    }
    if (ip.row == 0) { cell.textLabel.text = @"App"; cell.detailTextLabel.text = [NSString stringWithFormat:@"NFSU2 (OpenUG2 engine) v%@",
                                                                                   NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?"]; }
    else { cell.textLabel.text = @"Data folder"; cell.detailTextLabel.text = g_docs_path; }
    return cell;
}

- (void)shareLog:(NSString *)name from:(NSIndexPath *)ip {
    NSString *path = log_path(name);
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"No log yet" message:[name stringByAppendingString:@" does not exist. Play once first."]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    vc.popoverPresentationController.sourceView = cell ?: self.view;
    vc.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(0, 0, 1, 1);
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 2) return;
    if (ip.row == 0) [self shareLog:@"openug2.log" from:ip];
    if (ip.row == 1) [self shareLog:@"openug2-previous.log" from:ip];
    if (ip.row == 2) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete logs?" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [NSFileManager.defaultManager removeItemAtPath:log_path(@"openug2.log") error:nil];
            [NSFileManager.defaultManager removeItemAtPath:log_path(@"openug2-previous.log") error:nil];
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

/* ------------------------------------------------------------------------------------------------------------- */
/* Window                                                                                                         */
/* ------------------------------------------------------------------------------------------------------------- */
/* The app is landscape-only (Info.plist), so these only keep the launcher consistent with that. */
@interface UG2Tabs : UITabBarController
@end
@implementation UG2Tabs
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

int ios_launcher_run(const char *docs, char *root_out, size_t root_cap) {
    if (!docs || !root_out || !root_cap) return 0;
    @autoreleasepool {
        g_docs_path = [NSString stringWithUTF8String:docs];
        g_chosen_root = nil;
        g_done = NO;

        UINavigationController *play = [[UINavigationController alloc] initWithRootViewController:[[UG2PlayVC alloc] init]];
        play.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Play" image:nil tag:0];
        UINavigationController *settings = [[UINavigationController alloc] initWithRootViewController:[[UG2SettingsVC alloc] init]];
        settings.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:nil tag:1];
        UG2Tabs *tabs = [[UG2Tabs alloc] init];
        tabs.viewControllers = @[play, settings];

        UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        win.rootViewController = tabs;
        [win makeKeyAndVisible];

        /* Run the UI until Play: we are inside SDL's application-launch callback on the main thread, so the run loop is ours to turn. */
        while (!g_done) {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        /* Let a dismissing alert finish, then take the window down so SDL's window is the only one left. */
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        win.hidden = YES;
        win.rootViewController = nil;

        const char *root = g_chosen_root.fileSystemRepresentation;
        if (!root || strlen(root) >= root_cap) root = docs;
        strcpy(root_out, root);
    }
    return 1;
}
