// Triforce hunt icons for our overlays (Items page counter, tracker): made at runtime from the player's own game files
// (nothing of the game ships). A piece = the map-memo triangle (MapMark_05^w) recoloured gold; the counter's icon =
// three of them stacked into a Triforce.
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#include "imgui.h"
#ifdef __APPLE__
#import <Metal/Metal.h>
#endif

extern "C" {
uint8_t *texpatch_ui_rgba(const char *name, int *w, int *h);  // runtime/nvn/texpatch.c
#ifdef __APPLE__
void *ui_metal_device(void);
#else
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);
#endif
}

struct Icon { ImTextureID id = (ImTextureID)0; int w = 0, h = 0; };

static ImTextureID upload(const std::vector<uint8_t> &rgba, int w, int h) {
#ifdef __APPLE__
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    if (!dev) return (ImTextureID)0;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba.data() bytesPerRow:w * 4];
    return (ImTextureID)(__bridge_retained void *)t;  // (kept for the session)
#else
    return (ImTextureID)vk_imgui_texture_rgba(rgba.data(), w, h);
#endif
}

// the triangle, cropped to its pixels and recoloured: a gold gradient (top bright) at its own brightness, alpha kept
static bool gold_triangle(std::vector<uint8_t> &out, int *ow, int *oh) {
    int w, h;
    uint8_t *src = texpatch_ui_rgba("MapMark_05^w", &w, &h);
    if (!src) return false;
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (src[(y * w + x) * 4 + 3] > 8) x0 = x < x0 ? x : x0, y0 = y < y0 ? y : y0, x1 = x > x1 ? x : x1, y1 = y > y1 ? y : y1;
    if (x1 < 0) { free(src); return false; }
    int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
    out.assign((size_t)cw * ch * 4, 0);
    for (int y = 0; y < ch; y++) {
        float g = 1.0f - 0.28f * y / (float)(ch > 1 ? ch - 1 : 1);
        for (int x = 0; x < cw; x++) {
            const uint8_t *p = src + ((y + y0) * w + x + x0) * 4;
            float v = fminf(1.0f, fmaxf(p[0], fmaxf(p[1], p[2])) / 255.0f * 1.05f);
            uint8_t *q = &out[((size_t)y * cw + x) * 4];
            q[0] = (uint8_t)(255 * 0.98f * g * v), q[1] = (uint8_t)(255 * 0.80f * g * v), q[2] = (uint8_t)(255 * 0.25f * g * v);
            q[3] = p[3];
        }
    }
    free(src);
    *ow = cw, *oh = ch;
    return true;
}

// LARECOMP_TRIFORCE_ICON_DUMP=<prefix> (test): the icons as made, raw RGBA8 (<prefix>_<w>x<h>_piece.rgba / _triforce)
static void dump(const char *what, const std::vector<uint8_t> &rgba, int w, int h) {
    const char *pre = getenv("LARECOMP_TRIFORCE_ICON_DUMP");
    if (!pre) return;
    char p[1024];
    snprintf(p, sizeof p, "%s_%dx%d_%s.rgba", pre, w, h, what);
    if (FILE *f = fopen(p, "wb")) { fwrite(rgba.data(), 1, rgba.size(), f); fclose(f); }
}

static void make(Icon &piece, Icon &triforce) {
    static bool tried;
    if (tried) return;
    tried = true;
    std::vector<uint8_t> t;
    int w, h;
    if (!gold_triangle(t, &w, &h)) return;
    piece.id = upload(t, w, h), piece.w = w, piece.h = h;
    dump("piece", t, w, h);
    int W = w * 2, H = h * 2;  // three triangles: one on top, two below
    std::vector<uint8_t> c((size_t)W * H * 4, 0);
    auto blit = [&](int ox, int oy) {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                const uint8_t *s = &t[((size_t)y * w + x) * 4];
                uint8_t *d = &c[((size_t)(y + oy) * W + x + ox) * 4];
                float a = s[3] / 255.0f, da = d[3] / 255.0f, oa = a + da * (1 - a);
                for (int k = 0; k < 3; k++) d[k] = oa > 0 ? (uint8_t)((s[k] * a + d[k] * da * (1 - a)) / oa) : 0;
                d[3] = (uint8_t)(oa * 255);
            }
    };
    blit(w / 2, 0), blit(0, h), blit(w, h);
    triforce.id = upload(c, W, H), triforce.w = W, triforce.h = H;
    dump("triforce", c, W, H);
}

static Icon g_piece, g_triforce;

// Draws the icon (a piece / the three-piece Triforce) fitted in a box of height `size` centred at c; false when the
// game files don't have it (the caller draws its own then)
bool triforce_icon_draw(ImDrawList *dl, ImVec2 c, float size, bool full, ImU32 tint) {
    make(g_piece, g_triforce);
    const Icon &i = full ? g_triforce : g_piece;
    if (!i.id) return false;
    float s = size / (float)(i.h > i.w ? i.h : i.w);
    ImVec2 half(i.w * s * 0.5f, i.h * s * 0.5f);
    dl->AddImage(i.id, ImVec2(c.x - half.x, c.y - half.y), ImVec2(c.x + half.x, c.y + half.y), ImVec2(0, 0), ImVec2(1, 1), tint);
    return true;
}
