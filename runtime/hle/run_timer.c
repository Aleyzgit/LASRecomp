// Run timer (Gameplay tab "Timer", drawn by runtime/ui/race_overlay.mm) and LiveSplit auto-splitting (runtime/livesplit.c).
//
// Game time: host time between the game thread's frames, counted while a run is going, Link is in play, no level
// transition is under way and our menu (F1) is closed. The game's own pause menu counts (as in races).
//   level transition  the game manager's flag at +0x510: set from the moment a level jump starts (a door, stairs, a
//                     warp...) through the fade-out, the load and the fade-in, until Link can move again (found
//                     2026-10-19: 1 for ~105 frames around every door / warp, 0 while playing; also 1 on the title
//                     screen and while a save is loading)
//   start             a new file named at the file select of a randomizer seed (runtime/hle/swkbd.c): its run starts
//                     when its gameplay does; or "Start timer" in the menu (any game)
//   end               the Wind Fish ending: the "Ending" level or the ending movie (runtime/hle/movie.c)
//   splits            each instrument obtained (live save +0x556C bits 7-14), then the ending
// Kept per save slot: savedataN.bin.timer (next to the save; a few "<body CRC> <microseconds> <state>" lines, newest
// first) written whenever the game writes the slot. A save that comes into play takes the time stored with its body
// CRC (save +0x5EC4), as runtime/hle/flags_ext.c matches its extra flags; a save read without one has no run.
// Only while Timer or LiveSplit is on.
#include "../game_addresses.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../livesplit.h"
#include "../rando.h"
#include "../settings.h"

extern int game_in_play(void);
extern const char *game_level_name(void);
extern bool menu_is_open(void);
extern uint64_t renderer_present_count(void);

#define BODY_CRC 0x5EC4
#define KEYITEMS (GA_LIVE_SAVE + 0x556C)  // key items: bits 7-14 the instruments
#define INSTRUMENTS(v) ((v) >> 7 & 0xFF)
#define GM_LEVEL_CHANGE 0x510              // game manager: a level transition is under way
#define MAX_RECS 8

enum { RUN_NONE = 0, RUN_GOING = 1, RUN_DONE = 2 };

static volatile uint64_t g_us;     // game time of the run, microseconds
static volatile int g_state;       // RUN_*
static volatile int g_counting;    // the clock is running right now
static volatile int g_restart;     // "Start timer" from the menu (render thread)
static int g_new_pending;          // a new file was named: its run starts with its gameplay
static volatile int g_movie_end;   // the ending movie opened
static uint64_t g_last_ns, g_sync_ns;
static uint32_t g_applied_crc;     // the live save body CRC whose time is in use (0: look again)
static int g_read_since;           // a save was read (file select) since then: an unknown save has no run
static uint32_t g_inst;            // instruments seen this run

typedef struct { uint32_t crc; uint64_t us; int state; } Rec;
typedef struct { char path[1024]; uint32_t crc; Rec rec; int has; } Slot;
static Slot g_slots[8];
static int g_nslots;
static pthread_mutex_t g_slot_lock = PTHREAD_MUTEX_INITIALIZER;  // (the slots: the save service's thread and the game's)

static bool enabled(void) { return g_settings.timer || g_settings.livesplit; }

RT_ON_RESET(run_timer_reset) {  // (reboot: the next game starts without a run)
    g_us = 0, g_state = RUN_NONE, g_counting = 0, g_new_pending = 0, g_movie_end = 0, g_restart = 0;
    g_applied_crc = 0, g_read_since = 0, g_nslots = 0, g_last_ns = 0;
}

static void fmt_time(uint64_t us, char *out, size_t n) {
    uint64_t ms = us / 1000;
    snprintf(out, n, "%llu:%02llu:%02llu.%03llu", (unsigned long long)(ms / 3600000), (unsigned long long)(ms / 60000 % 60),
             (unsigned long long)(ms / 1000 % 60), (unsigned long long)(ms % 1000));
}

static void ls_gametime(void) {
    char t[48], line[64];
    fmt_time(g_us, t, sizeof t);
    snprintf(line, sizeof line, "setgametime %s", t);
    livesplit_cmd(line);
}

// LiveSplit (re)connected: bring it to the run's state (network thread; reads only)
void run_timer_livesplit_sync(void (*send)(const char *line, void *ctx), void *ctx) {
    if (g_state != RUN_GOING) return;
    char t[48], line[64];
    fmt_time(g_us, t, sizeof t);
    snprintf(line, sizeof line, "setgametime %s", t);
    send("starttimer", ctx);
    send("initgametime", ctx);
    send(line, ctx);
    send(g_counting ? "unpausegametime" : "pausegametime", ctx);
}

static uint32_t instruments_now(void) { return INSTRUMENTS(LD32(KEYITEMS)); }

static void start_run(const char *why) {
    g_us = 0, g_state = RUN_GOING, g_counting = 0;
    g_inst = instruments_now();
    LOG("[timer] run started (%s)\n", why);
    livesplit_cmd("starttimer");
    livesplit_cmd("initgametime");
    ls_gametime();
    livesplit_cmd("pausegametime");
}

static void finish_run(const char *why) {
    g_state = RUN_DONE, g_counting = 0;
    char t[48];
    fmt_time(g_us, t, sizeof t);
    LOG("[timer] run finished (%s): %s\n", why, t);
    ls_gametime();
    livesplit_cmd("split");
    livesplit_cmd("pausegametime");
    // the credits: a race seed's spoiler log opens from now on (runtime/ui/rando_tab.mm)
    const char *dir = rando_seed_dir();
    if (dir) {
        char p[1100];
        snprintf(p, sizeof p, "%s/race_done", dir);
        FILE *f = fopen(p, "w");
        if (f) { fprintf(f, "%s\n", t); fclose(f); }
    }
}

// ---- per-slot records (savedataN.bin.timer)
static void save_path(const char *path, char *out, size_t n) {  // (a save being written is <file>.pending)
    size_t len = strlen(path);
    bool pending = len > 8 && !strcmp(path + len - 8, ".pending");
    snprintf(out, n, "%.*s", (int)(len - (pending ? 8 : 0)), path);
}

static int read_recs(const char *save, Rec *r) {
    char p[1200], line[128];
    snprintf(p, sizeof p, "%s.timer", save);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    int n = 0;
    while (n < MAX_RECS && fgets(line, sizeof line, f)) {
        unsigned crc;
        unsigned long long us;
        int st;
        if (line[0] == '#' || sscanf(line, "%x %llu %d", &crc, &us, &st) != 3 || st < RUN_NONE || st > RUN_DONE) continue;
        r[n++] = (Rec){crc, us, st};
    }
    fclose(f);
    return n;
}

static Slot *slot_for(const char *path) {
    for (int i = 0; i < g_nslots; i++)
        if (!strcmp(g_slots[i].path, path)) return &g_slots[i];
    if (g_nslots == 8) return NULL;
    Slot *s = &g_slots[g_nslots++];
    memset(s, 0, sizeof *s);
    strlcpy(s->path, path, sizeof s->path);
    return s;
}

// fs.c: a save file was read into guest memory (the file select reads every slot)
void run_timer_save_read(const char *path, uint64_t addr, int64_t off, int64_t size) {
    if (!enabled() || off != 0 || size < BODY_CRC + 4) return;
    char save[1100];
    save_path(path, save, sizeof save);
    Rec r[MAX_RECS];
    int n = read_recs(save, r);
    pthread_mutex_lock(&g_slot_lock);
    Slot *s = slot_for(save);
    if (s) {
        s->crc = *(const uint32_t *)(uintptr_t)(addr + BODY_CRC);
        s->has = 0;
        for (int i = 0; i < n && !s->has; i++)
            if (r[i].crc == s->crc) s->rec = r[i], s->has = 1;
        g_applied_crc = 0;  // (look again: the same save loaded again starts from its stored time)
        g_read_since = 1;
    }
    pthread_mutex_unlock(&g_slot_lock);
}

// fs.c: a save file was written from guest memory: the run's time goes with it
void run_timer_save_written(const char *path, uint64_t addr, int64_t off, int64_t size) {
    if (!enabled() || off != 0 || size < BODY_CRC + 4) return;
    char save[1100], p[1200], tmp[1300];
    save_path(path, save, sizeof save);
    Rec r[MAX_RECS + 1];
    int n = read_recs(save, r + 1);
    // (a new file being created: its run, from zero - loaded again before it's saved, the run is still on)
    int state = g_new_pending ? RUN_GOING : g_state;
    uint64_t us = g_new_pending ? 0 : g_us;
    if (state == RUN_NONE && !n) return;  // (no run, nothing stored before: no file)
    r[0] = (Rec){*(const uint32_t *)(uintptr_t)(addr + BODY_CRC), us, state};
    pthread_mutex_lock(&g_slot_lock);
    Slot *s = slot_for(save);
    if (s) s->crc = r[0].crc, s->rec = r[0], s->has = 1;
    pthread_mutex_unlock(&g_slot_lock);
    snprintf(p, sizeof p, "%s.timer", save);
    snprintf(tmp, sizeof tmp, "%s.tmp", p);
    FILE *f = fopen(tmp, "w");
    if (!f) { LOG("[timer] cannot write %s\n", tmp); return; }
    fprintf(f, "# LAS Recomp run timer: body CRC, game time (microseconds), state (0 none, 1 running, 2 finished)\n");
    int kept = 0;
    for (int i = 0; i <= n && kept < MAX_RECS; i++) {
        bool dup = false;
        for (int j = 0; j < i; j++) dup |= r[j].crc == r[i].crc;
        if (dup) continue;
        fprintf(f, "%08x %llu %d\n", r[i].crc, (unsigned long long)r[i].us, r[i].state);
        kept++;
    }
    bool ok = !fclose(f);
#ifdef _WIN32
    remove(p);  // (Windows' rename doesn't replace)
#endif
    if (!ok || rename(tmp, p)) { LOG("[timer] cannot write %s\n", p); remove(tmp); return; }
    LOG("[timer] %s: %llu us stored with the save\n", save, (unsigned long long)us);
}

// runtime/hle/swkbd.c: a name was entered - on a randomizer seed that's a new file, and its run
void run_timer_new_file(void) {
    if (!enabled() || !rando_seed_dir()) return;
    g_new_pending = 1;
    g_state = RUN_NONE, g_us = 0;
    LOG("[timer] new file: the run starts with its gameplay\n");
}

// runtime/hle/movie.c: the ending movie
void run_timer_ending_movie(void) { g_movie_end = 1; }

// The menu's "Start timer" (any thread): from zero, now
void run_timer_restart(void) { g_restart = 1; }

// race_overlay.mm / the menu: the run (state RUN_*, time in microseconds, counting right now)
int run_timer_state(uint64_t *us, bool *counting) {
    if (us) *us = g_us;
    if (counting) *counting = g_counting;
    return g_state;
}

// Game thread, once per frame (runtime/hle/input.c)
void run_timer_tick(void) {
    uint64_t now = plat_now_ns(), dt = g_last_ns && now > g_last_ns ? now - g_last_ns : 0;
    g_last_ns = now;
    if (!enabled()) { g_counting = 0; return; }
    if (g_settings.livesplit) livesplit_poke();  // (connects in the background, also before a run)
    // the save in play: the time stored with it
    uint32_t crc = LD32(GA_LIVE_SAVE + BODY_CRC);
    pthread_mutex_lock(&g_slot_lock);
    if (crc != g_applied_crc) {
        g_applied_crc = crc;
        Slot *s = NULL;
        bool from_file = false;  // (a save read from a slot: not the new file - its name entry was backed out of)
        for (int i = 0; i < g_nslots; i++) {
            if (g_slots[i].crc == crc && g_slots[i].has) s = &g_slots[i];
            from_file |= g_slots[i].crc == crc;
        }
        if (from_file && g_new_pending && g_read_since) g_new_pending = 0;
        if (s) {
            g_us = s->rec.us, g_state = s->rec.state, g_counting = 0;
            g_inst = instruments_now();
            LOG("[timer] save in play: %s (run %s, %llu us)\n", s->path,
                g_state == RUN_DONE ? "finished" : g_state ? "going" : "none", (unsigned long long)g_us);
            if (g_state == RUN_GOING) {
                livesplit_cmd("starttimer");
                livesplit_cmd("initgametime");
                ls_gametime();
                livesplit_cmd("pausegametime");
            }
        } else if (g_read_since && !g_new_pending && g_state != RUN_NONE) {
            g_us = 0, g_state = RUN_NONE, g_counting = 0;
            LOG("[timer] the save in play has no run\n");
        }
        g_read_since = 0;
    }
    pthread_mutex_unlock(&g_slot_lock);
    bool in_play = game_in_play() != 0;
    {  // (test) LARECOMP_TIMER_START=<frame>: "Start timer" once, in play from that presented frame on
        static int test_start = -1;
        if (test_start < 0) test_start = ENV("LARECOMP_TIMER_START") ? 1 : 0;
        if (test_start == 1 && in_play && renderer_present_count() >= (uint64_t)atoll(ENV("LARECOMP_TIMER_START")))
            test_start = 2, g_restart = 1;
    }
    if (g_restart) { g_restart = 0; if (in_play) start_run("menu"); }
    if (g_new_pending && in_play) { g_new_pending = 0; start_run("new file"); }
    if (g_state != RUN_GOING) { g_movie_end = 0; g_counting = 0; return; }
    // (test) LARECOMP_TIMER_TEST_END=<frame>: the ending at that presented frame
    bool test_end = ENV("LARECOMP_TIMER_TEST_END") && renderer_present_count() >= (uint64_t)atoll(ENV("LARECOMP_TIMER_TEST_END"));
    if (g_movie_end || (in_play && !strcmp(game_level_name(), "Ending")) || test_end) {
        finish_run(g_movie_end ? "ending movie" : test_end ? "test" : "Ending level");
        g_movie_end = 0;
        return;
    }
    // instruments: a split each
    uint32_t inst = instruments_now();
    if (in_play) {
        for (uint32_t b = inst & ~g_inst; b; b &= b - 1) {
            LOG("[timer] instrument %d at %llu us: split\n", __builtin_ctz(b) + 1, (unsigned long long)g_us);
            ls_gametime();
            livesplit_cmd("split");
        }
        g_inst = inst;
    }
    uint64_t gm = LD64(GA_GAME_MGR);
    bool transition = gm && LD32(gm + GM_LEVEL_CHANGE) != 0;
    bool counting = in_play && !transition && !menu_is_open();
    if (counting && g_counting) g_us += (dt < 500000000ull ? dt : 500000000ull) / 1000;  // (a stall: at most 0.5 s)
    if (counting != (bool)g_counting) {
        g_counting = counting;
        if (ENV("LARECOMP_TIMER_TRACE"))
            LOG("[timer] %s at %llu us (%s, level %s)\n", counting ? "counting" : "paused", (unsigned long long)g_us,
                !in_play ? "not in play" : transition ? "level transition" : counting ? "-" : "menu", game_level_name());
        ls_gametime();
        livesplit_cmd(counting ? "unpausegametime" : "pausegametime");
        g_sync_ns = now;
    } else if (counting && now - g_sync_ns > 5000000000ull) {  // (keep LiveSplit's game time in step)
        ls_gametime();
        g_sync_ns = now;
    }
}
