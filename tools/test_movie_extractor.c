// Exercise the production extractor with synthetic PCM, counting its own real FFmpeg packet allocations.
// No game files or decoder/GPU setup are needed. The caller supplies an empty scratch directory.
#include <assert.h>
#include <libavcodec/avcodec.h>
#include "../runtime/hle.h"

static unsigned packets;
static bool fail_packet;
static AVPacket *packet_alloc(void) {
    if (fail_packet) return NULL;
    AVPacket *p = av_packet_alloc();
    if (p) packets++;
    return p;
}
static void packet_free(AVPacket **p) {
    if (*p) { assert(packets); packets--; }
    av_packet_free(p);
}
#define av_packet_alloc packet_alloc
#define av_packet_free packet_free
#undef HLE_FUNC
#define HLE_FUNC(sym, fn) static void fn(Cpu *c)
#undef RT_ON_RESET
#define RT_ON_RESET(fn) static void fn(void)
#include "../runtime/hle/movie.c"

const char *g_romfs_dir;
Settings g_settings = {.movie_audio = true};
volatile int g_inject_plus;
uint64_t input_buttons_now(void) { return 0; }

static void open_source(Cpu *c, uint64_t object[2], const char *path) {
    c->x[0] = (uintptr_t)object;
    c->x[1] = 0;
    c->x[2] = (uintptr_t)path;
    ex_set_data_source(c);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    g_romfs_dir = argv[1];
    char path[1024];
    snprintf(path, sizeof path, "%s/extractor.wav", g_romfs_dir);
    uint32_t wave[15] = {0x46464952, 52, 0x45564157, 0x20746d66, 16, 0x00010001, 48000, 96000,
                         0x00100002, 0x61746164, 16, 0x00020001, 0x00040003, 0x00060005, 0x00080007};
    FILE *file = fopen(path, "wbx");
    assert(file && fwrite(wave, 1, sizeof wave, file) == sizeof wave);
    fclose(file);

    Extractor e = {0};
    uint64_t object[2] = {0, (uintptr_t)&e};
    Cpu c = {0};
    open_source(&c, object, "rom:/extractor.wav");
    assert(!c.x[0] && packets == 1 && e.fmt && e.pkt);
    movie_track(0, &e, true);
    c.x[0] = (uintptr_t)object;
    ex_dtor(&c);
    assert(!e.fmt && !e.pkt && packets == 0);

    for (int i = 0; i < 32; i++) {
        open_source(&c, object, "rom:/extractor.wav");
        assert(!c.x[0] && packets == 1 && e.ntracks == 1 && !e.selected && !e.have_pkt && !e.eof);
        c.x[0] = (uintptr_t)object; c.x[1] = 0;
        ex_select_track(&c); ex_fill(&e);
        assert(e.have_pkt && e.pkt->size == 16 && e.pkt->data[0] == 1);
    }
    open_source(&c, object, "rom:/missing.wav");
    assert(c.x[0] && !e.fmt && !e.pkt && !e.ntracks && !e.selected && packets == 0);
    ex_fill(&e);
    assert(e.eof && !e.have_pkt);
    open_source(&c, object, NULL);
    assert(c.x[0] && !e.fmt && !e.pkt);
    fail_packet = true;
    open_source(&c, object, "rom:/extractor.wav");
    assert(c.x[0] && !e.fmt && !e.pkt && packets == 0);
    fail_packet = false;
    open_source(&c, object, "rom:/extractor.wav");
    assert(!c.x[0] && packets == 1);
    movie_track(0, &e, true);
    movie_reset();
    assert(!e.fmt && !e.pkt && packets == 0);
    assert(remove(path) == 0);
    puts("PASS: extractor destruction, repeated sources, failed opens/allocation and reboot release all packets");
}
