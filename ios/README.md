# OpenUG2 on iOS

An iOS front end for [OpenUG2](../README.md): SDL2 + OpenGL ES 2.0, on-screen touch controls, game data
from the app's Documents folder. **You supply your own copy of NFSU2** (OpenUG2 ships no EA assets).

> Status: untested on a device when this was written. It was syntax-checked against the iOS defines only.
> Expect to fix a few build errors on the first compile; the engine itself is an early prototype
> (driving, traffic and some races work; there is no full career).

## What you need
- A Mac (a Hackintosh is fine) with Xcode and its command line tools
- `brew install cmake xcodegen`
- An iPhone/iPad with iOS 13 or newer
- The NFSU2 files from your own DVD/install: the folders OpenUG2 reads (`TRACKS/`, `CARS/`, and the rest of
  the data directory the desktop build is pointed at)

## 1. Build the libraries (once)
```sh
cd ios
./build_deps.sh                         # device (arm64): SDL2 + libpng -> deps/out/iphoneos
SDK=iphonesimulator ./build_deps.sh     # optional, Apple-silicon simulator
```
SHA-256 comes from Apple's CommonCrypto (`compat/openssl/sha.h`), so there is no OpenSSL to build.

## 2. Generate the Xcode project and build
```sh
xcodegen generate
open OpenUG2.xcodeproj
```
In Xcode: select the **OpenUG2** target, **Signing & Capabilities**, choose your Team and change the bundle
identifier to something unique (a free Apple ID works). Pick your device and Run. The scheme builds
**Release** on purpose: the engine is far too slow unoptimised.

## 3. Put the game data on the device
The app's **Documents** folder is the data directory and the working directory (settings and key bindings
are written there too).
- Finder (macOS): select the iPhone, **Files** tab, drag your NFSU2 folders onto **OpenUG2**
- or the **Files** app: *On My iPhone > OpenUG2*

If the game files are missing, the app shows a dialog with the exact folder it is looking in (it also writes
`openug2.log` there). Under **LiveContainer** that folder is nested, e.g.
`LiveContainer/Documents/Data/Application/<guest GUID>/Documents`; use the path the dialog shows.

The default car and track are the engine's defaults (`CARS/HUMMER`, `TRACKS/STREAML4RA`), so those must be
present. The start menu offers **Free Roam** and **Race Select**.

## Controls
| Where | What |
|---|---|
| Left strip | Steering: slide your finger left/right of the strip's centre (analog) |
| Bottom right | **GAS** (big, corner), **BRK**, **NOS**, **HB** (handbrake) |
| Top row | **PAUSE**, **CAM**, **RESET**, **LOOK** (look back) |
| Menus (start + pause) | D-pad on the left, **OK** and **BACK** on the right |

The buttons send whatever keys the Controls screen has bound, so rebinding there still works. A Bluetooth
controller works too (SDL game controller support is on).

## Installing without Xcode on every refresh
A free Apple ID signs apps for **7 days** and allows 3 active sideloaded apps; that is an Apple rule, not
something this project can change. Options:

1. **Unsigned IPA + a sideloading tool.** `./make_ipa.sh` writes `build/OpenUG2-unsigned.ipa`. Install it
   with SideStore, AltStore or Sideloadly, which re-sign it with your own Apple ID.
   - SideStore refreshes in the background on the device itself after a one-time computer-assisted setup
     (it needs the LocalDevVPN app). Free accounts: 3 active apps (SideStore counts as one), 10 App IDs
     per week. See <https://docs.sidestore.io/docs/faq>.
   - AltStore Classic also works with a free Apple ID (3 active apps): <https://faq.altstore.io/altstore-classic/activating-apps>.
2. **Paid Apple Developer account ($99/year):** apps last 365 days and the 3-app limit goes away.
3. Plain Xcode with a free account: works, but you must re-run it every 7 days.

## Settings worth knowing
- `OPENUG2_IOS_HIGHDPI=1` (in `project.yml`): render at native Retina pixels. Default is points, because
  the world draws ~930 m of view and fill rate is the first limit on a phone.
- GL ES 2.0 is deprecated by Apple but still works (`GLES_SILENCE_DEPRECATION` is set). If a future iOS
  drops it, the fallback is ANGLE (GLES2 on top of Metal).
- Textures are CPU-decoded to RGBA: iOS GPUs have no S3TC, and the engine already has this fallback.
  Expect higher memory use than desktop.

## What changed in the engine
Everything is behind `#ifdef OPENUG2_IOS` / `OPENUG2_TOUCH`, so desktop builds are unchanged:
`src/main.c` (hooks), `src/controls_sdl.c` (two queries ask the touch layer), plus the new
`src/touch_ios.[ch]`, `ios/ios_platform.[hm]` and `ios/compat/`.
