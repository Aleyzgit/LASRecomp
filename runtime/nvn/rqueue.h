// The render thread (runtime/nvn/rqueue.c): command lists the game submits are translated and run by a thread of
// our own, so the game's GPU thread goes on with the next frame while this one translates. Off (every call below
// runs the backend directly on the calling thread): LARECOMP_RENDER_THREAD=0.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "nvn.h"

bool rq_on(void);

// Queue items (the game's threads). Item numbers count up from 1; a fence refers to the item that holds it.
uint64_t rq_submit(uint64_t handle);                     // a recorded command list (nvnQueueSubmitCommands)
void rq_present(NvnTexture *t, uint64_t frame);          // show t (the present pass, overlay, shots)
void rq_destroy_texture(NvnTexture *t);                  // backend_texture_destroyed + free(t), in queue order
enum { RQ_UPLOAD_RGBA, RQ_UPLOAD_NV12 };
void rq_upload(NvnTexture *t, int kind, void *data, uint32_t w, uint32_t h, uint32_t stride, uint32_t uv_off);  // takes data

// Waiting (any thread): everything up to item q is translated and submitted to the GPU; the returned value is the
// backend's submission number to wait on for the GPU side (renderer_wait_seq).
uint64_t rq_wait_item(uint64_t q);
uint64_t rq_fence_seq(void);  // the item a fence placed now belongs to (the last one queued)
uint64_t rq_current_item(void);  // on the render thread: the item being run; elsewhere 0
void rq_drain(void);   // every queued item done (QueueFinish; reboot)
void rq_flush(void);   // drain, then the backend's full flush, on the render thread (nvnSyncWait with LARECOMP_SYNC_FLUSH)

// (backends) called on the render thread
void backend_present_now(NvnTexture *t, uint64_t frame);
void backend_upload_now(NvnTexture *t, int kind, void *data, uint32_t w, uint32_t h, uint32_t stride, uint32_t uv_off);
uint64_t renderer_submit_seq(void);  // the backend's latest GPU submission number
void *backend_pool_push(void);       // (Metal) an autorelease pool around each item
void backend_pool_pop(void *p);

// (pace.c) this thread's time in rq_wait_item / rq_drain since start: the game thread waiting for translation
extern __thread uint64_t g_rq_wait_ns;
