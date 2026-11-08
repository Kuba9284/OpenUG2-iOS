/* main_menu -- the retail NFSU2 main menu (UI_Main.fng from FrontB.lzc), evaluated at run time over
 * the user's own game files: the authored screen, its icon strip (Career, Quick Race, ...), the
 * authored enter/exit animations, language strings and fonts. Nothing is drawn natively; when the
 * resources cannot be built main_menu_create() returns NULL and the caller keeps the placeholder menu.
 *
 * The item behaviour behind each icon is the host's: main_menu_update() reports the chosen entry
 * after the authored exit animation has played. */
#ifndef OPENUG2_MAIN_MENU_H
#define OPENUG2_MAIN_MENU_H
#include <SDL.h>

typedef enum {
    MM_NONE = 0,
    MM_CAREER, MM_QUICK_RACE, MM_GO_ONLINE, MM_LAN, MM_CUSTOMIZE_CAR, MM_PROFILE, MM_OPTIONS
} MainMenuChoice;

typedef struct MainMenu MainMenu;

/* Opens the front-end resources under `dataroot` and builds UI_Main.fng. NULL (reason on stderr) if
 * any of it is missing. Needs a current GL context. */
MainMenu *main_menu_create(const char *dataroot);
void main_menu_destroy(MainMenu *m);

/* Which entries the host can act on; others show the authored screen but do not leave it. */
void main_menu_set_available(MainMenu *m, MainMenuChoice c, int available);

/* Keyboard / controller (Left, Right, Return/A). */
void main_menu_event(MainMenu *m, const SDL_Event *e);
/* A tap or click at normalised window coordinates (0..1, top-left origin). */
void main_menu_tap(MainMenu *m, float nx, float ny, int win_w, int win_h);

/* Advances the screen; returns the chosen entry once, after the authored exit animation. */
MainMenuChoice main_menu_update(MainMenu *m, float seconds);
void main_menu_draw(MainMenu *m, int width, int height);
/* One-line state for logs. */
const char *main_menu_status(const MainMenu *m);

#endif
