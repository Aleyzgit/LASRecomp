// The render thread: see rqueue.h.
//
// The game's GPU thread records command lists and submits them; translating them into Metal / Vulkan work took
// milliseconds of that thread's frame. Now nvnQueueSubmitCommands queues the list and returns, and this thread
// translates and submits it. Everything the translation reads (command memory, constant and vertex buffers,
// textures, descriptor pools) is memory the Switch GPU would read while executing the list, which the game keeps
// intact until the fence after it signals: a fence here means "translated and submitted" (rq_wait_item) and then
// "executed" (the backend's own wait on the submission that item ended with), so the game's memory discipline
// holds as it did. The present, the texture destruction (recorded lists hold host NvnTexture pointers) and movie
// frame uploads are queued too, so they keep their order against the lists.
//
// Back-pressure: a present waits until the previous present is done (the thread then always holds about a frame
// of work; latency stays one frame), and the queue has a fixed size. Waits by guest threads give up while the
// kernel stops them for a reboot (g_rt_unwind), as kernel waits do.
#include "rqueue.h"

#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

#include "../platform.h"
#include "../rt.h"

__thread uint64_t g_rq_wait_ns;
extern __thread uint64_t g_blocked_ns;  // kernel.c: idle time of the presenting thread (frame pacing)

enum { IT_EXEC, IT_PRESENT, IT_DESTROY, IT_UPLOAD, IT_FLUSH };
typedef struct {
    int kind;
    uint64_t handle;  // EXEC
    NvnTexture *tex;  // PRESENT / DESTROY / UPLOAD
    uint64_t frame;   // PRESENT
    int up_kind;      // UPLOAD
    void *data;
    uint32_t w, h, stride, uv_off;
} Item;

#define RQ_CAP 1024  // items queued at most (power of two)
#define RQ_HIST 4096
static Item items[RQ_CAP];
static uint64_t gpu_seq_of[RQ_HIST];  // per item number: the backend submission it ended with
static uint64_t q_enq, q_done, q_cur;  // items queued / finished / in progress (0: none)
static int presents_pending;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv_work = PTHREAD_COND_INITIALIZER, cv_done = PTHREAD_COND_INITIALIZER;
static pthread_t thread;
static bool started;
static int on = -1;

static void *run(void *arg);
static uint64_t render_cpu_ns;
uint64_t rq_render_cpu_ns(void) { return __atomic_load_n(&render_cpu_ns, __ATOMIC_RELAXED); }

bool rq_on(void) {
    if (on < 0) {
        const char *e = getenv("LARECOMP_RENDER_THREAD");
        on = !e || atoi(e) != 0;
        if (on) {
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, 16 << 20);
            if (pthread_create(&thread, &attr, run, NULL) != 0) {
                LOG("[rq] cannot start the render thread: running on the game thread\n");
                on = 0;
            } else {
                started = true;
            }
            pthread_attr_destroy(&attr);
        }
        LOG("[rq] render thread %s\n", on ? "on" : "off");
    }
    return on > 0;
}

// Wait on cv while !ready(); guest: give up while the kernel stops the threads. Caller holds the lock. A wait of
// 2 s and more is logged with the queue's state (a stuck render thread shows up instead of a silent hang).
static void wait_until(pthread_cond_t *cv, bool (*ready)(void), bool guest, const char *what) {
    uint64_t t0 = 0;
    bool warned = false;
    while (!ready()) {
        if (guest && g_rt_unwind) return;
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 50000000;
        if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(cv, &lock, &ts);
        if (!what) continue;
        uint64_t now = plat_now_ns();
        if (!t0) t0 = now;
        else if (!warned && now - t0 > 2000000000ull) {
            warned = true;
            static int n;
            if (n++ < 20)
                LOG("[rq] %s: waiting %llu ms (queued %llu, done %llu, running %llu, presents pending %d)\n", what,
                    (unsigned long long)((now - t0) / 1000000), (unsigned long long)q_enq, (unsigned long long)q_done,
                    (unsigned long long)q_cur, presents_pending);
        }
    }
}

static bool has_room(void) { return q_enq - q_done < RQ_CAP; }
static bool no_present(void) { return presents_pending == 0; }
static bool all_done(void) { return q_done == q_enq; }
static uint64_t want_q;
static bool item_done(void) { return q_done >= want_q; }

static uint64_t enqueue(const Item *it) {
    pthread_mutex_lock(&lock);
    uint64_t t0 = 0;
    if (!has_room()) { t0 = plat_now_ns(); wait_until(&cv_done, has_room, false, "queue full"); }
    if (it->kind == IT_PRESENT) {
        if (!t0) t0 = plat_now_ns();
        wait_until(&cv_done, no_present, true, "present");  // (a reboot: the present is dropped below)
        presents_pending++;
    }
    if (t0) g_blocked_ns += plat_now_ns() - t0;  // (the pacer: as nextDrawable's wait was)
    uint64_t q = ++q_enq;
    items[q % RQ_CAP] = *it;
    pthread_cond_signal(&cv_work);
    pthread_mutex_unlock(&lock);
    return q;
}

static bool has_work(void) { return q_done < q_enq; }

static void *run(void *arg) {
    (void)arg;
    plat_thread_guest(44);  // (the game's GPU thread's class: performance cores on a Mac)
    for (;;) {
        pthread_mutex_lock(&lock);
        wait_until(&cv_work, has_work, false, NULL);
        uint64_t q = q_done + 1;
        Item it = items[q % RQ_CAP];
        q_cur = q;
        pthread_mutex_unlock(&lock);
        void *pool = backend_pool_push();
        switch (it.kind) {
        case IT_EXEC: backend_execute(it.handle); break;
        case IT_PRESENT: backend_present_now(it.tex, it.frame); break;
        case IT_DESTROY: backend_texture_destroyed(it.tex); free(it.tex); break;
        case IT_UPLOAD: backend_upload_now(it.tex, it.up_kind, it.data, it.w, it.h, it.stride, it.uv_off); break;
        case IT_FLUSH: { extern void renderer_flush(void); renderer_flush(); break; }
        }
        backend_pool_pop(pool);
        uint64_t gs = renderer_submit_seq();
#ifndef _WIN32
        {   // (LARECOMP_LOG_PACE: this thread's CPU time, read by pace.c)
            struct timespec ts;
            if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0)
                __atomic_store_n(&render_cpu_ns, (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec, __ATOMIC_RELAXED);
        }
#endif
        pthread_mutex_lock(&lock);
        gpu_seq_of[q % RQ_HIST] = gs;
        if (it.kind == IT_PRESENT) presents_pending--;
        q_cur = 0;
        q_done = q;
        pthread_cond_broadcast(&cv_done);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

// ---- items

// Fences inside the list get their item number now: the game may wait on one before the thread reaches the list.
static void prescan(uint64_t handle, uint64_t q, int depth) {
    extern void nvn_sync_set_seq(uint64_t guest, uint64_t seq);
    uint64_t p = handle;
    for (int guard = 0; guard < 10000000; guard++) {
        const CmdRec *r = (const CmdRec *)(uintptr_t)p;
        switch (r->op) {
        case CMD_END: return;
        case CMD_JUMP: p = r->x[0]; continue;
        case CMD_CALL: {
            const uint64_t *h = (const uint64_t *)r->extra;
            for (uint64_t i = 0; i < r->x[0] && depth < 8; i++) prescan(h[i], q, depth + 1);
            break;
        }
        case CMD_FENCE_SYNC:
            if (r->x[1]) nvn_sync_set_seq(r->x[1], q);
            break;
        default: break;
        }
        p += r->size;
    }
}

static pthread_mutex_t submit_lock = PTHREAD_MUTEX_INITIALIZER;  // (the number a list gets is known before it's queued)
uint64_t rq_submit(uint64_t handle) {
    pthread_mutex_lock(&submit_lock);
    pthread_mutex_lock(&lock);
    uint64_t q = q_enq + 1;  // the number enqueue gives it: fences are set before the thread can run the list
    pthread_mutex_unlock(&lock);
    prescan(handle, q, 0);
    Item it = {.kind = IT_EXEC, .handle = handle};
    enqueue(&it);
    pthread_mutex_unlock(&submit_lock);
    return q;
}

void rq_present(NvnTexture *t, uint64_t frame) {
    Item it = {.kind = IT_PRESENT, .tex = t, .frame = frame};
    enqueue(&it);
}

void rq_destroy_texture(NvnTexture *t) {
    Item it = {.kind = IT_DESTROY, .tex = t};
    enqueue(&it);
}

void rq_upload(NvnTexture *t, int kind, void *data, uint32_t w, uint32_t h, uint32_t stride, uint32_t uv_off) {
    Item it = {.kind = IT_UPLOAD, .tex = t, .up_kind = kind, .data = data, .w = w, .h = h, .stride = stride, .uv_off = uv_off};
    enqueue(&it);
}

// ---- waiting

uint64_t rq_wait_item(uint64_t q) {
    uint64_t t0 = plat_now_ns(), gs;
    pthread_mutex_lock(&lock);
    if (q > q_enq) q = q_enq;
    want_q = q;
    wait_until(&cv_done, item_done, true, "fence");
    gs = q_done >= q ? gpu_seq_of[q % RQ_HIST] : renderer_submit_seq();  // (gave up: whatever is submitted)
    pthread_mutex_unlock(&lock);
    g_rq_wait_ns += plat_now_ns() - t0;
    return gs;
}

uint64_t rq_fence_seq(void) {
    pthread_mutex_lock(&lock);
    uint64_t q = q_enq;
    pthread_mutex_unlock(&lock);
    return q;
}

uint64_t rq_current_item(void) {
    if (!started || !pthread_equal(pthread_self(), thread)) return 0;
    return q_cur;
}

void rq_drain(void) {
    if (!on || !started) return;
    if (rq_current_item()) return;  // (the thread itself: a flush from inside an item)
    uint64_t t0 = plat_now_ns();
    pthread_mutex_lock(&lock);
    wait_until(&cv_done, all_done, false, "drain");
    pthread_mutex_unlock(&lock);
    g_rq_wait_ns += plat_now_ns() - t0;
}

void rq_flush(void) {
    Item it = {.kind = IT_FLUSH};
    enqueue(&it);
    rq_drain();
}
