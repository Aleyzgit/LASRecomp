// HDR output on macOS: display headroom, the layer switch, the tonemap's parameters (runtime/nvn/hdr.h).
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <SDL3/SDL.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "../rt.h"
#include "../settings.h"
#include "hdr.h"

static _Atomic float g_pot = 1, g_now = 1;  // the display's headroom (UI thread polls)
static atomic_bool g_live;                  // the layer is in HDR mode
static float g_test_headroom = -1;          // LARECOMP_HDR_HEADROOM

static float test_headroom(void) {
    if (g_test_headroom < 0) {
        const char *e = getenv("LARECOMP_HDR_HEADROOM");
        g_test_headroom = e ? (float)atof(e) : 0;
    }
    return g_test_headroom;
}

float hdr_headroom_potential(void) { return test_headroom() > 0 ? test_headroom() : atomic_load(&g_pot); }
float hdr_headroom_now(void) { return test_headroom() > 0 ? test_headroom() : atomic_load(&g_now); }
bool hdr_display_capable(void) { return hdr_headroom_potential() > 1.01f; }
bool hdr_live(void) { return atomic_load(&g_live); }

float hdr_peak(void) {
    float p = 1 + (hdr_headroom_potential() - 1) * g_settings.hdr_peak / 100.0f;  // (Peak brightness: a share of it)
    float now = hdr_headroom_now();
    if (p > now) p = now;  // (above what the display shows right now: clipped there, so roll off to it instead)
    return p < 1 ? 1 : p;
}

// The curve above the game's (maxwell/translate.c, hdr_tonemap_sig): the game's up to the knee (the tonemap's input
// after exposure; 2 is where its curve gives 0.82 of white: the sky and the sea outdoors sit right there, the lit
// ground below), half of the headroom used HDR_HALF stops above it (fire, glints, effects).
#define HDR_KNEE 2.0f
#define HDR_HALF 2.0f

void hdr_tonemap_params(float p[4]) {
    p[0] = p[1] = p[2] = 0;
    p[3] = hdr_probe_on() ? 1 : 0;
    if (!hdr_live()) return;
    float peak = hdr_peak();
    if (peak <= 1.0f) return;  // (1: the game's own curve)
    static float test_peak = -1;  // LARECOMP_HDR_CURVE_PEAK=<x> (test): the curve's peak (1: the game's curve)
    if (test_peak < 0) test_peak = getenv("LARECOMP_HDR_CURVE_PEAK") ? (float)atof(getenv("LARECOMP_HDR_CURVE_PEAK")) : 0;
    p[0] = test_peak > 0 ? test_peak : peak;
    p[1] = HDR_KNEE;
    p[2] = HDR_HALF * HDR_HALF;
}

// ---- display
static NSScreen *window_screen(void *window) {
    NSWindow *w = (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties((SDL_Window *)window),
                                                              SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    return w.screen ? w.screen : NSScreen.mainScreen;
}

static void layer_set(CAMetalLayer *layer, bool hdr, NSScreen *screen) {
    static bool saved;
    static CGColorSpaceRef sdr_space;
    if (!saved) { saved = true; sdr_space = layer.colorspace ? CGColorSpaceRetain(layer.colorspace) : NULL; }
    if (hdr) {
        // the display's own primaries, linear and extended: the game's colours look as on the SDR layer (which has
        // no colour space: shown as the display's)
        CGColorSpaceRef base = screen.colorSpace.CGColorSpace;
        CGColorSpaceRef cs = base ? CGColorSpaceCreateExtendedLinearized(base) : NULL;
        if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        layer.pixelFormat = MTLPixelFormatRGBA16Float;
        layer.colorspace = cs;
        layer.wantsExtendedDynamicRangeContent = YES;
        CGColorSpaceRelease(cs);
    } else {
        layer.wantsExtendedDynamicRangeContent = NO;
        layer.colorspace = sdr_space;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    }
}

static NSScreen *g_screen;
void hdr_poll(void *window) {
    static double last;
    double now = SDL_GetTicks() / 1000.0;
    if (last && now - last < 1.0) return;
    last = now;
    g_screen = window_screen(window);
    atomic_store(&g_pot, (float)g_screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
    atomic_store(&g_now, (float)g_screen.maximumExtendedDynamicRangeColorComponentValue);
}

void hdr_ui_update(void *window, void *layer_) {
    CAMetalLayer *layer = (__bridge CAMetalLayer *)layer_;
    static NSScreen *screen;
    hdr_poll(window);
    if (g_screen != screen && atomic_load(&g_live)) layer_set(layer, true, g_screen);  // (another display: its colours)
    screen = g_screen;
    bool want = g_settings.hdr && hdr_display_capable();
    if (want != atomic_load(&g_live)) {
        layer_set(layer, want, screen);
        atomic_store(&g_live, want);
        LOG("[hdr] %s (headroom %.2f now, %.2f max)\n", want ? "on" : "off", hdr_headroom_now(), hdr_headroom_potential());
    }
}

void hdr_ui_leave(void *layer) {
    if (!atomic_load(&g_live)) return;
    atomic_store(&g_live, false);
    layer_set((__bridge CAMetalLayer *)layer, false, nil);
}

// ---- probe (test)
static int g_probe = -1;
bool hdr_probe_on(void) {
    if (g_probe < 0) g_probe = getenv("LARECOMP_HDR_PROBE") != NULL;
    return g_probe;
}

static id<MTLBuffer> g_probe_buf;
void *hdr_probe_buffer(void *device) {
    if (!g_probe_buf) {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
        g_probe_buf = [dev newBufferWithLength:66 * 4 options:MTLResourceStorageModeShared];
        memset(g_probe_buf.contents, 0, 66 * 4);
    }
    return (__bridge void *)g_probe_buf;
}

// bins: log2(x) in quarter steps from 2^-10 (bin 0) to 2^6 (bin 63)
static float bin_x(int b) { return exp2f(b / 4.0f - 10.0f); }

void hdr_probe_note(float exposure) {
    static double last;
    static float emin = 1e9f, emax = 0;
    if (exposure < emin) emin = exposure;
    if (exposure > emax) emax = exposure;
    double now = SDL_GetTicks() / 1000.0;
    if (!g_probe_buf || now - last < 2.0) return;
    last = now;
    uint32_t h[66];
    memcpy(h, g_probe_buf.contents, sizeof h);
    memset(g_probe_buf.contents, 0, sizeof h);
    uint64_t n = 0;
    for (int i = 0; i < 64; i++) n += h[i];
    if (!n) return;
    float q[5] = {0.5f, 0.9f, 0.99f, 0.999f, 0.9999f}, v[5] = {0};
    for (int k = 0; k < 5; k++) {
        uint64_t acc = 0, want = (uint64_t)(q[k] * n);
        for (int i = 0; i < 64; i++) { acc += h[i]; if (acc >= want) { v[k] = bin_x(i + 1); break; } }
    }
    uint64_t over1 = 0, over2 = 0;  // input > 1 / > 2 (where the game's curve gives 0.87 / 0.93 of white)
    for (int i = 40; i < 64; i++) over1 += h[i];
    for (int i = 44; i < 64; i++) over2 += h[i];
    float mx, raw;
    memcpy(&mx, &h[64], 4);
    memcpy(&raw, &h[65], 4);
    extern const char *game_level_name(void);
    extern uint64_t renderer_present_count(void);
    LOG("[hdr-probe] frame %llu level %s exposure %.3f-%.3f: p50 <%.3f p90 <%.3f p99 <%.3f p99.9 <%.3f p99.99 <%.3f max %.3f "
        "(scene %.3f), >1: %.3f%%, >2: %.3f%%\n", (unsigned long long)renderer_present_count(), game_level_name(), emin, emax,
        v[0], v[1], v[2], v[3], v[4], mx, raw, 100.0 * over1 / n, 100.0 * over2 / n);
    emin = 1e9f, emax = 0;
}
