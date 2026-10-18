// Dynamic resolution's controller (runtime/nvn/output_scale.c) driven by a simulated GPU: no game files, no window.
// Build + run: tools/test_dynres.py (prints each case's factor path; exits non-zero when a case misbehaves).
// The GPU: the game's part G = (a + b f^2) x scene x noise at factor f (a: what doesn't scale with the resolution), the
// window step W (upscale / SMAA / menu: the window's size only). A frame takes G + W of GPU; with vsync and the
// frames waiting for the display (fifo, as on Windows' Intel driver) it lasts the next multiple of 16.7 ms, with
// mailbox max(16.7, G + W). Cases from an Intel UHD 770 (Field, Dynamic): G and W as measured at the factor it sat at.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../runtime/settings.h"
#include "../runtime/nvn/output_scale.h"

Settings g_settings = {.res_mode = RES_DYNAMIC};

static unsigned g_rng = 1;
static double rnd(void) { g_rng = g_rng * 1103515245u + 12345u; return ((g_rng >> 8) & 0xffff) / 65535.0; }

typedef struct {
    const char *name;
    double a, b, w;     // G = a + b f^2, W
    int fifo;           // frames wait for the display
    double light_at;    // > 0: the scene gets lighter (x0.6) from then on (s)
    double secs;
    double wobble;      // the scene's load swings +-this over 20 s (0: 3%; frame to frame +-2%: the floor's 30.6 fps)
} Case;

typedef struct { double f_end, fps_end; int changes_last60; double f_min_last60, f_max_last60; } Result;

static Result run(const Case *c) {
    g_rng = 7;
    double now = 1.0, f = output_scale_dynamic_factor(), g_prev = -1, w_prev = -1;
    double frames_end = 0, t_end = 0, last_f = f, f_min = 1, f_max = 0;
    int changes = 0;
    printf("%s\n  t=0s %.2f", c->name, f);
    int col = 0;
    while (now < c->secs) {
        OutScale o;
        output_scale(3840, 2160, false, now, g_prev, w_prev, &o);
        f = output_scale_dynamic_factor();
        if (f != last_f) {
            printf(" | %.0fs %.2f", now, f);
            if (++col % 8 == 0) printf("\n ");
            if (now > c->secs - 60) changes++;
            last_f = f;
        }
        if (now > c->secs - 60) { f_min = fmin(f_min, f); f_max = fmax(f_max, f); }
        double scene = (1 + (c->wobble > 0 ? c->wobble : 0.03) * sin(now * 2 * M_PI / 20)) * (c->light_at > 0 && now > c->light_at ? 0.6 : 1.0);
        double g = (c->a + c->b * f * f) * scene * (0.98 + 0.04 * rnd()), w = c->w * (0.99 + 0.02 * rnd());
        double gw = g + w, p = c->fifo ? ceil(gw / 16.667 - 1e-9) * 16.667 : gw;
        if (p < 16.667) p = 16.667;
        g_prev = g, w_prev = w;
        now += p / 1000;
        if (now > c->secs - 10) frames_end++, t_end += p / 1000;
    }
    Result r = {f, frames_end / t_end, changes, f_min, f_max};
    printf("\n  end: factor %.2f, %.1f fps over the last 10 s, %d change%s in the last 60 s (%.2f-%.2f)\n\n", r.f_end,
           r.fps_end, changes, changes == 1 ? "" : "s", f_min, f_max);
    return r;
}

static int g_fail;
static void check(int ok, const char *what) {
    if (!ok) { printf("FAIL: %s\n\n", what); g_fail = 1; }
}

int main(int argc, char **argv) {
    // (each case is its own process: the controller's state is static) argv[1]: the case's index
    static const Case cases[] = {
        // 4K window, bilinear: G 16.3 W 0.9 at 0.50 -> 30.6 fps (fifo halving)
        {"4K bilinear (G 16.3 + W 0.9 at 0.50, fifo)", 4.1, 48.8, 0.9, 1, 0, 180},
        // 4K, SMAA + FSR 1: G 13.1 W 20.2 at 0.50 -> 20 fps
        {"4K SMAA + FSR 1 (G 13.1 + W 20.2 at 0.50, fifo)", 3.3, 39.2, 20.2, 1, 0, 180},
        // 1080p, bilinear: G 10.9 W 0.2 at 0.65, hunting 0.65 <-> 0.75 before (the old raise needed G < 10.5, a step
        // down G + W > 14.5): G = 0.3 + 25.1 f^2 (10.9 at 0.65, 14.4 at 0.75), the load swinging +-5%
        {"1080p bilinear (G 10.9 + W 0.2 at 0.65, fifo)", 0.3, 25.1, 0.2, 1, 0, 180, 0.05},
        // 1080p, SMAA + FSR 1: G 9.1 W 8.1 at 0.50 -> 30 fps (G = 6.5 + 10.4 f^2: a large part that doesn't scale)
        {"1080p SMAA + FSR 1 (G 9.1 + W 8.1 at 0.50, fifo)", 6.5, 10.4, 8.1, 1, 0, 180},
        // control: the frames don't wait (mailbox): every step down is a faster frame, so down to the floor as before
        {"4K bilinear, mailbox (G 16.3 + W 0.9 at 0.50)", 4.1, 48.8, 0.9, 0, 0, 120},
        // the scene gets lighter (x0.6) at 90 s: 60 fps fits at the floor again
        {"4K bilinear, lighter scene from 90 s (fifo)", 4.1, 48.8, 0.9, 1, 90, 240},
        // pure f^2 GPU (nothing fixed): the most optimistic model for steps down
        {"4K bilinear, G all f^2 (G 16.3 at 0.50, fifo)", 0, 65.2, 0.9, 1, 0, 180},
        // a fast GPU: 4K at 1.0 fits (G 11 + W 1)
        {"fast GPU, 4K (G 11 + W 1 at 1.00)", 2, 9, 1, 1, 0, 60},
        // a busier scene: its load swings +-15%: it follows the scene, the hold stays
        {"4K bilinear, load swinging +-15% (fifo)", 4.1, 48.8, 0.9, 1, 0, 180, 0.15},
        // 1080p bilinear with the load swinging +-15%: steps with the scene, slowly (the raise wait doubles)
        {"1080p bilinear, load swinging +-15% (fifo)", 0.3, 25.1, 0.2, 1, 0, 180, 0.15},
    };
    int n = sizeof cases / sizeof *cases;
    if (argc < 2) { printf("%d\n", n); return 0; }
    int i = atoi(argv[1]);
    Result r = run(&cases[i]);
    switch (i) {
    case 0: check(r.f_end >= 0.55 && r.fps_end > 28 && r.changes_last60 <= 2, "4K bilinear: hold 30 fps above the floor"); break;
    case 1: check(r.f_end >= 0.55 && r.fps_end > 19 && r.changes_last60 <= 2, "4K FSR: hold 20 fps above the floor"); break;
    case 2: check(r.fps_end > 58 && r.changes_last60 == 0 && r.f_end >= 0.65, "1080p bilinear: settle at 60"); break;
    case 3: check(r.f_end >= 0.6 && r.fps_end > 28 && r.changes_last60 <= 2, "1080p FSR: hold 30 fps above the floor"); break;
    case 4: check(r.f_end == 0.5, "mailbox: the floor"); break;
    case 5: check(r.fps_end > 58, "lighter scene: back to 60"); break;
    case 6: check(r.f_end >= 0.55 && r.fps_end > 28 && r.changes_last60 <= 2, "4K bilinear f^2: hold 30 fps above the floor"); break;
    case 7: check(r.f_end == 1.0 && r.fps_end > 58, "fast GPU: full resolution"); break;
    case 8: check(r.f_min_last60 >= 0.55 && r.fps_end > 28 && r.changes_last60 <= 4, "4K bilinear +-15%: hold 30 fps"); break;
    case 9: check(r.fps_end > 58 && r.changes_last60 <= 4, "1080p bilinear +-15%: 60, few steps"); break;
    }
    return g_fail;
}
