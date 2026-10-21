// Frame pacing, shared by the Metal (metal.m) and Vulkan (vulkan/device.c) presents: each presented frame calls
// pace_frame() on the presenting thread, and the backends pass the game's timing counters through pace_end_counter().
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../game_addresses.h"
#include "../rt.h"
#include "pace.h"

// The game advances its world one fixed step per frame in its 60 fps mode, and two steps per frame in its 30 fps mode
// (measured: Link walks twice as far per frame there) - so a 60-mode frame that takes 20 ms plays in slow motion, while
// the 30 mode plays at full speed. The game picks the mode itself every frame (its frame controller f_700000c910, from
// 0x700000ca44): the extra vsyncs it waits next become those its last frame missed, one fewer when that frame's CPU time
// and GPU time (its timing counters) were both under its limits (13.33 / 14.17 ms), kept between a least and a most
// (0 and 1, on the game manager). One missed vsync takes it to 30, and one quick frame - or one that came a vsync early
// after a late one - back to 60: no hysteresis. Our frames can be slow for reasons its GPU time doesn't show (command
// translation, a slower CPU), and a machine near the edge flipped 60 / 30 every few frames (a Steam Deck at 1x: 35-45
// fps, issue #40), also while the counters below reported slow frames.
// So each presented frame's busy time is measured (present to present, minus the time the presenting thread was
// blocked in kernel waits, sleeps and the window's image: idle); when frames don't fit 60 (12 of the last 60 over
// 16.2 ms, and the median frame within ~3 ms of that: a few hitches or spikes in frames that otherwise fit don't count),
// the game is held in its 30 fps mode: its least extra vsyncs becomes 1, and the counters report a frame of at least
// PACE_SLOW_NS as before (its own dynamic resolution, which read them too, is off: tools/patches.py GAME_DYNRES_SITE).
// Its 30 fps mode is two world steps a frame (+0x4e0 counts the extra one down) and a present interval of 2 (+0x4e1 + 1,
// to nvnWindowSetPresentInterval). On the Switch the display waits out that interval; here nothing did, so a held
// frame that fit in one vsync was still shown after one: the game asked for interval 2 the whole hold, yet a Steam
// Deck's held frames were half 16.7 ms apart (35-45 fps, issue #40) and a Mac's with headroom 9 in 10. So while held,
// the presenting thread waits out the interval itself (hold_cadence): two vsyncs a frame.
// It can't flip back on a quick frame then; we let it go back on headroom, by what a frame would cost at 60: the game
// thread's busy time less its second world step, or the render thread's CPU time for the frame when that's more (at 30
// a render-bound machine's game thread barely waits for it: its busy time alone would look like headroom):
//   clear: under 11 ms on average and none of the last 60 over 14.5 ms, 60 frames in a row (2 s at 30) times the
//     backoff up to 4x (a light scene after a heavy one doesn't wait long);
//   enough: the median under 13.5 ms and at most 4 of the last 60 over 16.2 ms, 150 frames in a row (5 s at 30) times
//     the backoff.
// Backoff (issues #70, #40): a machine right at the edge (a handheld on a low power profile) gains headroom at 30 fps
// just by cooling down, goes back to 60, and doesn't fit again a few seconds later - 60 / 30 flicker. Falling back
// within 20 s of going back doubles the wait (up to 16x: 80 s for "enough"); a minute at 60 resets it.
// LARECOMP_PACE=0: off (the game's own choice, flips and all).
#define PACE_SLOW_NS 20000000ull
extern __thread uint64_t g_blocked_ns;  // kernel.c: this thread's time blocked in waits / sleeps
static bool pace_slow;
static uint64_t stat_pace_over;

// Holds the game in its 30 fps mode (see above): the least number of extra vsyncs its frame controller may choose
// (game manager +0x4e2, normally 0) is 1 while slow, the game's own value again after. Re-asserted every frame while held.
// Returns whether the game is held (not when it allows no 30 fps mode itself: its most, +0x4e3, is 0).
#define FW_MIN_EXTRA_VSYNCS 0x4e2  // (+0x4e3: the most, 1 - its 30 fps mode; +0x4e0 / +0x4e1: the current choice)
static bool hold_30(bool on) {
    static bool held;
    static uint8_t saved;
    uint64_t fw = *(volatile uint64_t *)(uintptr_t)GA_GAME_MGR;
    if (!fw) return held = false;  // (between boots / before the game set up)
    volatile uint8_t *min = (volatile uint8_t *)(uintptr_t)(fw + FW_MIN_EXTRA_VSYNCS), *max = min + 1;
    if (on && *max >= 1) {
        if (!held) saved = *min, held = true;
        *min = 1;
    } else if (held) {
        *min = saved, held = false;
    }
    return held;
}

// The held 30 fps mode's present interval (see above): called last in each frame's pace_frame, after its present. The
// game then waits for the next vsync (a frame that took 20 ms is shown 33 ms after the one before it: the wait is
// for the next vsync, not one already passed). Held, a frame that started after vsync S may not let the game start
// the next one before S + 2: if vsync S + 1 hasn't come yet, wait for it here. (The time counts as blocked: idle.)
extern volatile uint64_t g_vsync_count, g_vsync_ns;  // runtime/hle/vi.c
static void hold_cadence(bool held) {
    static uint64_t v_exit;  // the vsync count when the game last went on from here (its next frame: from the vsync after)
    if (held && v_exit) {
        uint64_t target = v_exit + 2, t0 = plat_now_ns(), n;
        // (bounded: a stalled vsync timer must not stall the game - two vsyncs and a bit at most)
        for (;;) {
            uint64_t vt = __atomic_load_n(&g_vsync_ns, __ATOMIC_ACQUIRE);  // (first: the count is then at least its vsync's,
            n = __atomic_load_n(&g_vsync_count, __ATOMIC_ACQUIRE);          // so a vsync in between only wakes us early)
            if (n >= target || plat_now_ns() - t0 > 40000000ull) break;
            uint64_t at = vt + (target - n) * 16666667ull + 250000ull;
            uint64_t now = plat_now_ns();
            plat_sleep_until_ns(at > now + 100000ull ? at : now + 100000ull);
        }
        g_blocked_ns += plat_now_ns() - t0;
    }
    v_exit = __atomic_load_n(&g_vsync_count, __ATOMIC_ACQUIRE);
}

static float median60(const float *v) {
    float s[60];
    memcpy(s, v, sizeof s);
    for (int i = 1; i < 60; i++)  // (insertion sort: 60 floats a frame)
        for (int j = i; j > 0 && s[j - 1] > s[j]; j--) { float t = s[j]; s[j] = s[j - 1], s[j - 1] = t; }
    return (s[29] + s[30]) / 2;
}

bool pace_is_slow(void) { return pace_slow; }
uint64_t pace_frames_over(void) {
    uint64_t n = stat_pace_over;
    stat_pace_over = 0;
    return n;
}

// LARECOMP_SPIKE_MS=<ms> [LARECOMP_SPIKE_EVERY=<frames>, default 60]: the presenting (game) thread sleeps that long
// every that many frames from frame 2700 on (in play after a scripted load): a CPU-side hitch with the GPU idle
// (dynamic resolution tests).
static void spike_test(void) {
    static long ms = -1, every, frame;
    if (ms < 0) {
        ms = getenv("LARECOMP_SPIKE_MS") ? atol(getenv("LARECOMP_SPIKE_MS")) : 0;
        every = getenv("LARECOMP_SPIKE_EVERY") ? atol(getenv("LARECOMP_SPIKE_EVERY")) : 60;
        if (every < 1) every = 60;
    }
    if (ms > 0 && ++frame > 2700 && frame % every == 0) plat_sleep_until_ns(plat_now_ns() + (uint64_t)ms * 1000000);
}

void pace_frame(void) {
    spike_test();
    static int on = -1;
    if (on < 0) { const char *e = getenv("LARECOMP_PACE"); on = !e || atoi(e) != 0; }
    static uint64_t last, last_wait;
    static uint8_t over[60];
    static float recent[60];  // the last 60 frames' cost (ms at 60 fps)
    static int idx, nover, calm, clear, backoff = 1;
    static uint64_t back_at;  // when frame pacing last went back to 60 (0: not yet)
    static double avg;  // cost (ms at 60 fps), moving average (~20 frames)
    static uint64_t last_tcpu, last_rcpu;
    extern uint64_t rq_render_cpu_ns(void);  // rqueue.c: the render thread's CPU time so far (0: no render thread)
    uint64_t now = plat_now_ns(), w = g_blocked_ns, tcpu = plat_thread_cpu_ns(), rcpu = rq_render_cpu_ns();
    uint64_t p = now - last, wt = w - last_wait, tc = tcpu - last_tcpu, rc = rcpu - last_rcpu;
    bool first = !last;
    last = now, last_wait = w, last_tcpu = tcpu, last_rcpu = rcpu;
    if (first || p > 100000000ull) { hold_cadence(hold_30(pace_slow && on)); return; }  // (loading, a hitch: not a pace)
    double busy = (p > wt ? p - wt : 0) / 1e6;
    // What the frame would cost at 60 fps: a frame of the game's 30 fps mode (two vsyncs or more) runs its world twice,
    // and the second step - about half this thread's CPU time then (measured: 3.0 -> 6.0 ms, 4.9 -> 9.3 ms) - is work
    // a 60 fps frame doesn't have. Without that, the 30 fps mode's frames looked 3-5 ms slower than they would be at 60
    // and the way back needed far more headroom than it should.
    double step2 = tc / 2e6 < busy / 2 ? tc / 2e6 : busy / 2;  // (at most half: a coarse thread clock can't take it all)
    double cost = p > 25000000ull ? busy - step2 : busy;
    // Held, the render thread has two vsyncs a frame and the game thread hardly waits for it: its CPU time for the frame
    // is what the frame would cost it at 60. (Not when free: there waiting for it is already in the busy time, and a
    // period can hold more or less than one frame of its work.)
    if (pace_slow && rc / 1e6 > cost && rc < 60000000ull) cost = rc / 1e6;
    avg = avg ? avg + (cost - avg) * 0.05 : cost;
    static int log = -1;  // LARECOMP_LOG_PACE=1: each frame's period, vsync wait and busy time
    if (log < 0) log = getenv("LARECOMP_LOG_PACE") != NULL;
    extern __thread uint64_t g_rq_wait_ns;  // rqueue.c: waits for the render thread (translation), counted as busy
    static uint64_t last_rq;
    uint64_t rqw = g_rq_wait_ns - last_rq;
    last_rq = g_rq_wait_ns;
    if (log) {  // (plus this thread's CPU time per frame and the render thread's: work, independent of waits; and where
                // this thread's frame went in the renderer's frontend - rqueue.h)
        extern __thread uint64_t g_rq_lock_ns, g_submit_ns, g_gpu_wait_ns, g_present_ns, g_hooks_ns;
        static uint64_t last_cpu, l_lock, l_sub, l_gpu, l_pres, l_hooks;
        uint64_t cpu = plat_thread_cpu_ns();
        LOG("[pace] period %.2f blocked %.2f busy %.2f cost %.2f ms (queue wait %.2f, cpu %.2f, render cpu %.2f, gpu wait %.2f, submit %.2f, "
            "present %.2f, hooks %.2f, lock %.2f)\n", p / 1e6, wt / 1e6, busy, cost, rqw / 1e6, last_cpu ? (cpu - last_cpu) / 1e6 : 0.0,
            rc / 1e6, (g_gpu_wait_ns - l_gpu) / 1e6, (g_submit_ns - l_sub) / 1e6,
            (g_present_ns - l_pres) / 1e6, (g_hooks_ns - l_hooks) / 1e6, (g_rq_lock_ns - l_lock) / 1e6);
        last_cpu = cpu;
        l_lock = g_rq_lock_ns, l_sub = g_submit_ns, l_gpu = g_gpu_wait_ns, l_pres = g_present_ns, l_hooks = g_hooks_ns;
    }
    int o = cost > 16.2;
    stat_pace_over += o;
    nover += o - over[idx];
    over[idx] = (uint8_t)o;
    recent[idx] = (float)cost;
    idx = (idx + 1) % 60;
    if (!on) return;  // (measured and counted all the same: LARECOMP_LOG_PACE, the stats)
    float med = median60(recent);
    if (!pace_slow && back_at && backoff > 1 && now - back_at > 60000000000ull) {
        backoff = 1;
        LOG("[pace] a minute at 60: headroom needed back to normal\n");
    }
    if (!pace_slow && nover >= 12 && med >= 13.0f) {
        pace_slow = true, calm = clear = 0;
        if (back_at && now - back_at < 20000000000ull && backoff < 16) backoff *= 2;  // (flickering: wait longer)
        LOG("[pace] frames don't fit 60 fps (%d of the last 60 over 16.2 ms busy, median %.1f): holding the game's 30 fps mode%s\n",
            nover, med, backoff > 1 ? " (backing off)" : "");
    } else if (pace_slow) {
        float peak = 0;
        for (int i = 0; i < 60; i++) peak = recent[i] > peak ? recent[i] : peak;
        clear = avg < 11.0 && peak < 14.5f ? clear + 1 : 0;
        calm = med < 13.5f && nover <= 4 ? calm + 1 : 0;
        int clear_n = 60 * (backoff < 4 ? backoff : 4);
        if (clear >= clear_n || calm >= 150 * backoff) {
            LOG("[pace] %d frames with %s headroom (%.1f ms a frame at 60 on average, median %.1f, at most %.1f): back to "
                "the game's own choice\n", clear >= clear_n ? clear : calm, clear >= clear_n ? "clear" : "enough", avg, med, peak);
            pace_slow = false, nover = 0, back_at = now;
            memset(over, 0, sizeof over);
            memset(recent, 0, sizeof recent);
        }
    }
    hold_cadence(hold_30(pace_slow));
}

uint64_t pace_end_counter(const uint64_t *start_entry, const uint64_t *entry, uint64_t value) {
    if (!pace_slow || !start_entry || (const uint8_t *)entry - (const uint8_t *)start_entry != 16) return value;
    uint64_t min = start_entry[1] + (uint64_t)((unsigned __int128)PACE_SLOW_NS * 384 / 625);
    return value < min ? min : value;
}
