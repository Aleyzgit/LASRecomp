// HDR output on macOS (Video tab "HDR", off by default; runtime/nvn/hdr.m). The game's tonemap (one shader, found
// by the translator: maxwell/translate.c hdr_tonemap_sig) keeps its curve below a knee and rolls off to the display's
// peak above it; the frame's final image is also copied as a float image (extended sRGB encoding) at the game's copy
// into its window image, and the present pass writes linear values into an RGBA16Float, extended-range layer.
// Screenshots and the game's own captures keep the 8-bit window images.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// UI thread (the game's window loop, ~every frame): polls the display's headroom (about once a second) and switches
// the layer between SDR and HDR. window: the SDL window, layer: its CAMetalLayer.
void hdr_ui_update(void *window, void *layer);
void hdr_ui_leave(void *layer);  // back to the SDR layer (leaving the game: the start screen draws SDR)
void hdr_poll(void *window);     // UI thread: the display's headroom (the start screen's loop; hdr_ui_update does it too)
// The display's headroom: what it can show at most (potential, 1 = no HDR) and right now, in paper-white units.
// LARECOMP_HDR_HEADROOM=<x> (test): pretend the display has that much.
float hdr_headroom_potential(void);
float hdr_headroom_now(void);
bool hdr_display_capable(void);  // potential headroom > 1: the Video tab shows the settings
// Render thread: the layer gives HDR drawables (set from the UI thread; the tonemap and the copy follow it)
bool hdr_live(void);
float hdr_peak(void);  // the curve's peak this frame (x paper white, >= 1): the Peak brightness share, at most the
                       // display's headroom right now
// The tonemap draw's parameters (float4 at HDR_BUFFER_INDEX): peak, knee, (stops to half the headroom)^2, probe
void hdr_tonemap_params(float p[4]);
// LARECOMP_HDR_PROBE=1 (test): the tonemap's input range (a log2 histogram of max(r, g, b) after exposure), logged
// every 2 s. exposure: cb5[0] of the draw.
bool hdr_probe_on(void);
void *hdr_probe_buffer(void *device);  // id<MTLBuffer>, bound at fragment buffer 24
void hdr_probe_note(float exposure);

#ifdef __cplusplus
}
#endif
