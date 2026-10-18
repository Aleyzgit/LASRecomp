// Output resolution, shared by the Metal and Vulkan backends (each calls output_scale() once per presented frame).
// Render targets the game sizes for the Switch's 1920x1080 screen are allocated at (sx, sy) times their size; the
// image is then drawn into (vx, vy, vw, vh) of the window. Video tab "Internal resolution" (g_settings.res_mode):
//   Match display  render at the window's own pixel size (default)
//   1x .. 4x       N times the Switch's docked image: 1080 lines x N (wide windows keep their shape: 32:9 at 2x =
//                  7680 x 2160); capped to the GPU's 16384-pixel texture limit
//   .75x / .50x / .25x  of Match display (scaled up to the window - with MetalFX on macOS when chosen)
//   Dynamic        Match display, lowered in steps while the GPU can't hold 60 fps and raised again when it can.
//                  The render targets stay allocated at the Match display size (ax, ay) and the frame is drawn into
//                  their top-left part at (sx, sy): no reallocation at a step, so no hitch (each step reallocated
//                  every screen-sized texture before: ~325 ms on an M3 Max, seconds at 4K on Vulkan, issue #100).
// Test overrides: LARECOMP_SCALE=<f> (render height = 1080 x f), LARECOMP_WIDE_TEST=<f> (forced shape),
// LARECOMP_DYN_TEST=<f> (Dynamic pinned at factor f of the allocation: shots at a fixed part).
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../settings.h"
#include "output_scale.h"

#define MAX_TEX 16384.0

// Dynamic resolution: a factor on the Match display scale, 0.5 .. 1 in 0.05 steps. Down quickly while over budget;
// up only after sustained headroom, and the wait before the next raise doubles each time a raise is undone within
// 10 s (hunting between two steps: 24-33 changes a minute in the field before).
// It reacts to the GPU only: a lower resolution doesn't help a frame the CPU / the game made slow (a level streaming
// in, a shader compiling: 100+ ms frames with the GPU nearly idle, which used to step it down on a fast GPU and, with
// the slow raises, keep it low for a minute). With GPU times (Metal's command buffers, Vulkan's timestamps) it goes by
// those alone. Without, by the frame times with the spikes left out: the mean of the half second's frames up to 3x their
// median (a frame missing one vsync, 33 ms, still counts: that's how a slow GPU shows at 60 Hz). Either way a spike
// neither steps it down nor, so, doubles the raise wait. LARECOMP_DYN_NO_GPU=1: ignore the GPU times (tests the
// frame-time path); LARECOMP_SPIKE_MS (pace.c): CPU-side spikes.
#define DYN_N 30  // frames per decision (~half a second)
static double g_dyn = 1.0;
static double g_dyn_gpu_sum, g_last_t, g_dyn_dt[DYN_N];
static int g_dyn_n, g_dyn_gpu_n, g_dyn_good;
static double g_dyn_cool_until, g_dyn_raise_wait = 3.0, g_dyn_raise_at;
static double g_dyn_last_raise = -100, g_dyn_last_lower = -100;

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void dyn_update(double now, double gpu_ms) {
    static int no_gpu = -1;
    if (no_gpu < 0) no_gpu = getenv("LARECOMP_DYN_NO_GPU") && atoi(getenv("LARECOMP_DYN_NO_GPU"));
    if (no_gpu) gpu_ms = -1;
    double dt = g_last_t > 0 ? (now - g_last_t) * 1000.0 : 16.7;
    g_last_t = now;
    if (dt > 250) return;  // (loading, menus, a stall: not the GPU's steady state)
    g_dyn_dt[g_dyn_n++] = dt;
    if (gpu_ms >= 0) { g_dyn_gpu_sum += gpu_ms; g_dyn_gpu_n++; }
    if (g_dyn_n < DYN_N) return;  // decide every ~half second
    // frame times: median, and the mean without the outliers (single CPU-side spikes)
    double sorted[DYN_N], kept = 0;
    memcpy(sorted, g_dyn_dt, sizeof sorted);
    qsort(sorted, DYN_N, sizeof *sorted, cmp_double);
    double med = (sorted[DYN_N / 2 - 1] + sorted[DYN_N / 2]) / 2;
    int nkept = 0;
    for (int i = 0; i < DYN_N; i++) if (sorted[i] <= 3 * med) { kept += sorted[i]; nkept++; }
    double avg_dt = kept / nkept, avg_gpu = g_dyn_gpu_n >= DYN_N / 2 ? g_dyn_gpu_sum / g_dyn_gpu_n : -1;
    int spikes = DYN_N - nkept;
    g_dyn_gpu_sum = 0;
    g_dyn_n = g_dyn_gpu_n = 0;
    if (now < g_dyn_cool_until) return;
    double prev = g_dyn;
    bool gpu = avg_gpu >= 0;
    bool slow = gpu ? avg_gpu > 14.5 : avg_dt > 17.4;
    if (slow) {
        g_dyn = fmax(0.5, g_dyn - ((gpu ? avg_gpu > 19 : avg_dt > 22) ? 0.1 : 0.05));
        g_dyn_good = 0;
        // the raise didn't hold (spikes can't undo one any more: they're not in the measure)
        if (now - g_dyn_last_raise < 10.0) g_dyn_raise_wait = fmin(g_dyn_raise_wait * 2, 60.0);
        g_dyn_last_lower = now;
        g_dyn_raise_at = now + g_dyn_raise_wait;
    } else if (g_dyn < 1.0) {
        g_dyn_good++;
        // headroom for a while (with GPU timing: clearly under budget; without: frames at 60), and not too soon after
        // the last step down
        bool room = (gpu ? avg_gpu < 10.5 : avg_dt < 16.9) && g_dyn_good >= 6 && now >= g_dyn_raise_at;
        if (room) { g_dyn = fmin(1.0, g_dyn + 0.05); g_dyn_good = 0; g_dyn_last_raise = now; g_dyn_raise_at = now + g_dyn_raise_wait; }
        else if (now - g_dyn_last_lower > 60.0 && g_dyn_raise_wait > 3.0) g_dyn_raise_wait = 3.0;  // (a minute of calm: forget the hunting)
    }
    g_dyn = round(g_dyn * 20) / 20;
    static int log = -1;  // LARECOMP_LOG_DYNRES=1: every decision, not only the steps
    if (log < 0) log = getenv("LARECOMP_LOG_DYNRES") != NULL;
    if (g_dyn != prev || log) {
        if (g_dyn != prev) g_dyn_cool_until = now + 1.0;
        LOG("[dynres] %.2f -> %.2f (frame %.1f ms, median %.1f, %d spike%s left out, gpu %.1f ms, next raise in %.0f s)\n", prev,
            g_dyn, avg_dt, med, spikes, spikes == 1 ? "" : "s", avg_gpu, fmax(0, g_dyn_raise_at - now));
    }
}

double output_scale_dynamic_factor(void) { return g_dyn; }

void output_scale(double dw, double dh, bool reshape_allowed, double now, double gpu_ms, OutScale *o) {
    double fit = fmin(dw / 1920.0, dh / 1080.0);
    static double forced = -1, wide_test = -1;
    if (forced < 0) forced = getenv("LARECOMP_SCALE") ? atof(getenv("LARECOMP_SCALE")) : 0;
    if (wide_test < 0) wide_test = getenv("LARECOMP_WIDE_TEST") ? atof(getenv("LARECOMP_WIDE_TEST")) : 0;
    double shape = wide_test > 0 ? wide_test : (dw / dh) / (16.0 / 9.0);
    bool reshape = reshape_allowed && fabs(shape - 1.0) > 0.005;
    if (!reshape) shape = 1.0;
    // render height in units of the Switch's 1080 lines
    double h, dyn = 1.0;
    int mode = g_settings.res_mode;
    if (forced > 0) h = forced;
    else if (mode >= 1 && mode <= 8) h = mode;
    else {
        h = reshape ? dh / 1080.0 : fit;  // Match display
        if (mode == RES_DYNAMIC) {
            static double pinned = -1;
            if (pinned < 0) pinned = getenv("LARECOMP_DYN_TEST") ? atof(getenv("LARECOMP_DYN_TEST")) : 0;
            if (pinned > 0) dyn = pinned;
            else { dyn_update(now, gpu_ms); dyn = g_dyn; }
        }
        else if (mode == RES_Q75) h *= 0.75;
        else if (mode == RES_Q25) h *= 0.25;
        else if (mode == RES_Q50) h *= 0.5;
    }
    h = fmax(h, 0.1);  // (.25x of a small window)
    double ax = h * shape, ay = h;
    double cap = fmin(MAX_TEX / (1920.0 * ax), MAX_TEX / (1080.0 * ay));
    if (cap < 1.0) { ax *= cap; ay *= cap; }
    o->ax = ax; o->ay = ay;
    o->sx = ax * dyn; o->sy = ay * dyn; o->shape = shape;
    // where the image goes in the window: fills it when reshaped, else a fitted 16:9 box
    if (reshape) { o->vw = dw; o->vh = dh; }
    else { o->vw = 1920.0 * fit; o->vh = 1080.0 * fit; }
    if (wide_test > 0) {
        double f2 = fmin(dw / (1920.0 * wide_test), dh / 1080.0);
        o->vw = 1920.0 * wide_test * f2; o->vh = 1080.0 * f2;
    }
    o->vx = (dw - o->vw) / 2; o->vy = (dh - o->vh) / 2;
}
