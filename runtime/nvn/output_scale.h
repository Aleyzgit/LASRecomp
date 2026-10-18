// Output resolution (runtime/nvn/output_scale.c), shared by the Metal and Vulkan backends.
#pragma once
#include <stdbool.h>

typedef struct {
    double sx, sy;             // render scale (relative to the game's 1920x1080 sizes): what a frame is drawn at
    double ax, ay;             // allocation scale: the render targets' size (Dynamic renders into a part of them)
    double shape;              // window aspect / 16:9 when the camera is widened, else 1
    double vx, vy, vw, vh;     // where the image is drawn in the window (pixels)
} OutScale;

// dw x dh: the window's drawable size in pixels; now: seconds; gpu_ms: GPU time of the last frame (< 0: unknown)
void output_scale(double dw, double dh, bool reshape_allowed, double now, double gpu_ms, OutScale *o);
double output_scale_dynamic_factor(void);

// (Vulkan) where a frame's time went, noted once per frame before output_scale(); LARECOMP_LOG_DYNRES's [dynres] line
// shows the per-frame averages. ms over the frame: game = the game's submissions' GPU time, win = the window image's
// (from after its acquire wait), span = GPU time from the frame's first game work to its window submission's end
// (over `frames` frames that ended in it), CPU waits: frame slot's fence, acquire, present, other vk_wait_seq waits.
typedef struct {
    double game, win, span, frames, w_slot, w_acquire, w_present, w_other;
    bool win_counted;  // the window's GPU time is in what dynamic resolution goes by
} DynSplit;
void output_scale_note_split(const DynSplit *s);
