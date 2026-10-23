"""CPU / GPU overlap (exec.c): the deferred frame fence and the storage snapshot state machine. No GPU is needed.

Extracts overlap_defer (the SyncWait decision) and the snap_storage block from runtime/nvn/vulkan/exec.c by their
markers, compiles each with stubs, and checks the sequences the design relies on (LAS-reports/vk_overlap_design.md).
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'runtime/nvn/vulkan/exec.c').read_text()
defer = source[source.index('static uint64_t overlap_defer('):source.index('\nuint64_t renderer_fence_seq(')]
snap = source[source.index('#define SNAP_HALF'):source.index('// (debug) LARECOMP_LOG_BINDS=1:')]
assert 'static void snap_ring_import_tail(void);' in snap

defer_harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
''' + defer + r'''
// The game's frame loop: SyncWait on each frame's fence, each a new submission; `done` is what the GPU completed.
static uint64_t d;  // deferred_seq
int main(void) {
    // frame 1 submitted, nothing done: nothing was deferred before, so return at once and defer 1
    assert(overlap_defer(1, 0, &d) == 0 && d == 1);
    // frame 2 submitted, 1 not done yet: wait for 1, defer 2
    assert(overlap_defer(2, 0, &d) == 1 && d == 2);
    // frame 3, 2 done already (a fast GPU): no wait, nothing deferred any more
    assert(overlap_defer(3, 3, &d) == 0 && d == 0);
    // frame 4, nothing newer done: deferred
    assert(overlap_defer(4, 3, &d) == 0 && d == 4);
    // frame 5, 4 done meanwhile: no wait (4 was complete: a deferred fence already complete is never waited for)
    assert(overlap_defer(5, 4, &d) == 0 && d == 5);
    // the same fence again (the game waits twice): a real wait, nothing deferred after it
    assert(overlap_defer(5, 4, &d) == 5 && d == 0);
    // an older fence than the deferred one: waited for, the deferred one stays
    assert(overlap_defer(7, 5, &d) == 0 && d == 7);
    assert(overlap_defer(6, 5, &d) == 6 && d == 7);
    // the deferred one once done: cleared
    assert(overlap_defer(7, 7, &d) == 0 && d == 0);
    // a completed older fence while a newer one is deferred: the deferral stays (seq < prev)
    assert(overlap_defer(9, 7, &d) == 0 && d == 9);
    assert(overlap_defer(8, 8, &d) == 0 && d == 9);
    assert(overlap_defer(10, 8, &d) == 9 && d == 10);
    // at most two frames queued: with the GPU never finishing, each call waits for the previous frame
    d = 0;
    uint64_t done = 0;
    for (uint64_t f = 20; f < 40; f++) {
        uint64_t w = overlap_defer(f, done, &d);
        assert(w == (f == 20 ? 0 : f - 1) && d == f);
        if (w) done = w;  // (the wait completes it)
    }
    puts("PASS: overlap_defer - first fence, defer / wait-previous, done fences, repeats, older fences, two in flight");
}
'''

snap_harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { uint64_t addr, size; } Range;
static struct { Range sbuf[6][16]; } st;
static uint8_t *heap_mem;
#define HEAP_MAX (64ull << 20)
#define HEAP_BASE ((uint64_t)(uintptr_t)heap_mem)
#define LOG(...) fprintf(stderr, __VA_ARGS__)
static uint64_t heap_size = 16ull << 20;  // (the test ranges below sit under 8 MB; the ring follows at 16 MB)
static uint64_t kernel_heap_size(void) { return heap_size; }
static unsigned commits;
static void plat_commit(uint64_t addr, uint64_t size) { assert(addr == HEAP_BASE + heap_size && size == (16ull << 20)); commits++; }
static bool overlap_on(void) { return true; }
static uint64_t completed, pending = 1, issued, waited;
static uint64_t vk_completed_seq(void) { return completed; }
static uint64_t vk_pending_seq(void) { return pending; }
static uint64_t renderer_issued_seq(void) { return issued; }
static const char *wait_why;
static void vk_wait_seq(uint64_t seq) { assert(seq <= issued); waited = seq; completed = seq; }
static int pool_flags = 4;  // CPU_CACHED
int nvn_pool_flags_at(uint64_t addr) { (void)addr; return pool_flags; }
static uint64_t frame = 10;
uint64_t renderer_exec_frame(void) { return frame; }
static const char *level = "Field";
const char *game_level_name(void) { return level; }
static uint64_t stat_snap_bytes, stat_snap_copies;
''' + snap + r'''
static void snap_ring_import_tail(void) {}
static uint64_t ring_lo(void) { return HEAP_BASE + snap_base; }
static bool in_ring(uint64_t a) { return a >= ring_lo() && a < ring_lo() + SNAP_RING; }
static bool in_half(uint64_t a, int h) { return a >= ring_lo() + h * SNAP_HALF && a < ring_lo() + (h + 1) * SNAP_HALF; }
int main(void) {
    heap_mem = calloc(HEAP_MAX, 1);
    assert(heap_mem);
    uint64_t A = HEAP_BASE + 0x1000, B = HEAP_BASE + 0x20000, C = HEAP_BASE + 0x40000;
    uint8_t *a = heap_mem + 0x1000, *b = heap_mem + 0x20000;
    memset(a, 1, 32640); memset(b, 2, 2048); memset(heap_mem + 0x40000, 3, 4096);
    // decided on first use: the ring follows the heap (64 KB aligned), committed once
    assert(snap_ring_end() == heap_size + SNAP_RING && commits == 1 && snap_on());
    // 1. the probe: a first use binds a copy with the same bytes
    uint64_t c1 = snap_storage(A, 32640, true);
    assert(c1 != A && in_ring(c1) && !memcmp((void *)(uintptr_t)c1, a, 32640) && nrs == 1 && stat_snap_copies == 1);
    assert(snap_storage(A, 32640, true) == c1);  // (bound again this frame: the same copy)
    // 2. unchanged at the next use: IN PLACE from then on (the GPU-only skinning outputs)
    frame++;
    assert(snap_storage(A, 32640, true) == A && rs_tab[0].mode == RS_PLACE);
    frame++;
    a[100] = 9;  // (the GPU writes it on the Switch; here the probe said the CPU doesn't: stays in place, no hash)
    assert(snap_storage(A, 32640, true) == A);
    // 3. the light list: rewritten between frames -> COPY, a fresh copy whenever its data changes
    uint64_t c2 = snap_storage(B, 2048, true);
    assert(c2 != B && in_ring(c2) && rs_tab[1].mode == RS_PROBE);
    frame++;
    b[7] = 0x55;
    uint64_t c3 = snap_storage(B, 2048, true);
    assert(c3 != B && c3 != c2 && rs_tab[1].mode == RS_COPY && ((uint8_t *)(uintptr_t)c3)[7] == 0x55);
    assert(snap_storage(B, 2048, false) == c3);  // (a draw reading it this frame: the same copy)
    frame++;
    assert(snap_storage(B, 2048, true) == c3);   // unchanged: the copy (maybe GPU-modified) stays
    frame++;
    b[8] = 0x66;
    uint64_t c4 = snap_storage(B, 2048, true);
    assert(c4 != c3 && ((uint8_t *)(uintptr_t)c4)[8] == 0x66);
    // 4. a draw-only range (never a compute slot's) in place is moved to COPY when its data changes
    uint64_t c5 = snap_storage(C, 4096, false);
    assert(c5 != C);
    frame++;
    assert(snap_storage(C, 4096, false) == C && rs_tab[2].mode == RS_PLACE);
    frame++;
    heap_mem[0x40000 + 5] = 7;
    uint64_t c6 = snap_storage(C, 4096, false);
    assert(c6 != C && rs_tab[2].mode == RS_COPY);
    // 5. a new level: probed again
    frame++;
    level = "Dungeon";
    assert(snap_storage(A, 32640, true) != A && rs_tab[0].mode == RS_PROBE);
    frame++;
    assert(snap_storage(A, 32640, true) == A && rs_tab[0].mode == RS_PLACE);
    // 6. unused for 10 s: probed again
    frame += 601;
    assert(snap_storage(A, 32640, true) != A && rs_tab[0].mode == RS_PROBE);
    // 7. not snapshotted: static pools, ranges in or past the ring, too large, outside the heap
    pool_flags = 1;
    assert(snap_storage(B, 2048, true) == B);
    pool_flags = 4;
    assert(snap_storage(ring_lo(), 2048, true) == ring_lo());
    assert(snap_storage(HEAP_BASE + heap_size - 1024, 2048, true) == HEAP_BASE + heap_size - 1024);
    assert(snap_storage(A, SNAP_HALF / 2 + 256, true) == A);
    assert(snap_storage(A + 0x4000, SNAP_HALF / 2, true) != A + 0x4000);  // (the largest allowed: a half holds two)
    assert(snap_storage(HEAP_BASE - 4096, 2048, true) == HEAP_BASE - 4096);
    // 8. the halves: 1 MB copies fill half 0; the switch to half 1 needs no wait (never used); the switch back waits for
    //    the submission pending when half 0 was left, and an old copy is never bound again after a switch
    frame++;
    uint64_t big = SNAP_HALF / 8;
    uint8_t *d = heap_mem + (1ull << 20);
    uint64_t D = HEAP_BASE + (1ull << 20);
    memset(d, 4, big);
    snap_off = 0; snap_half = 0; snap_gen++;  // (a clean half 0)
    uint64_t keep = snap_storage(D, big, true);  // a COPY candidate: probe copy at the start of half 0
    assert(in_half(keep, 0));
    frame++;
    d[0] = 5;
    uint64_t keep2 = snap_storage(D, big, true);  // changed: COPY mode, a copy in half 0
    assert(in_half(keep2, 0) && rs_tab[nrs - 1].mode == RS_COPY);
    issued = 5; pending = 6; completed = 5; waited = 0;
    for (int i = 0; i < 6; i++) {  // 6 more fill half 0 (8 x 1 MB)
        uint64_t E = HEAP_BASE + (2ull << 20) + (uint64_t)i * 4096;
        assert(in_half(snap_storage(E, big, true), 0));
    }
    uint64_t F = HEAP_BASE + (3ull << 20);
    uint64_t f1 = snap_storage(F, big, true);  // the 9th: half 1, no wait, half 0's users noted as the pending submission
    assert(in_half(f1, 1) && !waited && snap_half == 1 && snap_half_seq[0] == 6);
    frame++;
    // the old COPY-mode entry, unchanged: its copy in half 0 is NOT bound again (generation): a new copy in half 1
    uint64_t keep3 = snap_storage(D, big, true);
    assert(keep3 != keep2 && in_half(keep3, 1));
    for (int i = 0; i < 6; i++) {
        uint64_t E = HEAP_BASE + (5ull << 20) + (uint64_t)i * 4096;
        assert(in_half(snap_storage(E, big, true), 1));
    }
    // half 1 is full. Switching back needs submission 6 done: it is only being recorded (issued 5): the bind falls
    // back to the original for this one draw, nothing waits, nothing is overwritten
    frame++;
    uint64_t G = HEAP_BASE + (7ull << 20);
    assert(snap_storage(G, big, true) == G && snap_half == 1 && !waited);
    // once submitted (issued 7, still not complete): the switch waits for 6, then takes half 0
    issued = 7; pending = 8;
    uint64_t g1 = snap_storage(G, big, true);
    assert(in_half(g1, 0) && waited == 6 && snap_half == 0 && snap_half_seq[1] == 8);
    // 9. the game grows its heap into the ring: off, everything in place from then on
    heap_size = snap_base + 4096;
    assert(snap_storage(A, 32640, true) == A && snap_state == 0 && snap_ring_end() == 0);
    // 10. a reboot decides again (heap not set up yet: not decided; then on)
    snap_reset();
    heap_size = 0;
    assert(!snap_on() && snap_state == -1);
    heap_size = 8ull << 20;
    assert(snap_on() && snap_base == (8ull << 20) && commits == 2 && nrs == 0);
    puts("PASS: snapshots - probe / in place / copy, level and idle re-probes, exclusions, the two halves and their waits, heap growth, reboot");
}
'''
with tempfile.TemporaryDirectory(prefix='vulkan-overlap-') as temporary:
    temporary = Path(temporary)
    for name, harness in (('defer', defer_harness), ('snap', snap_harness)):
        cfile = temporary / f'{name}.c'
        cfile.write_text(harness)
        exe = temporary / (f'{name}.exe' if os.name == 'nt' else name)
        subprocess.run(shlex.split(os.environ.get('CC', 'clang')) + ['-std=gnu11', '-O1', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                        str(cfile), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True, timeout=10)
