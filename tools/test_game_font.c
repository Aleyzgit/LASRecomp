// Production font loader, isolated heap and synthetic fonts (no game data).
#include <assert.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/hle/pl.c"

Settings g_settings = {.game_font = "auto"};
static const char *language = "en-US";
const char *settings_language(void) { return language; }
void *hle_alloc(uint64_t n) { return calloc(1, (size_t)n); }
void rt_fatal_msg(const char *fmt, ...) { (void)fmt; abort(); }
void rt_fatal_trace(void) { abort(); }
bool rt_resource(const char *a, const char *b, char *out, size_t n) {
    (void)a; (void)b;
    snprintf(out, n, "fallback.ttf");
    return true;
}

int main(int argc, char **argv) {
    assert(argc >= 3);
    snprintf(g_settings.game_font, sizeof g_settings.game_font, "%s", argv[1]);
    char description[640];
    assert(game_font_describe("fonts/custom.ttf", description, sizeof description));
    assert(strstr(description, "Custom fixture"));
    assert(game_font_describe("fonts/collection.ttc", description, sizeof description));
    assert(strstr(description, "Collection fixture"));
    assert(game_font_describe("fonts/packed.bfttf", description, sizeof description));
    assert(strstr(description, "Packed fixture"));
    assert(!game_font_describe("fonts/broken.ttf", description, sizeof description));
    assert(!game_font_describe("fonts/cff.ttf", description, sizeof description));
    assert(!game_font_describe("fonts/bad-cmap.ttf", description, sizeof description));
    assert(!game_font_describe("fonts/bad-collection.ttc", description, sizeof description));
    assert(!game_font_choice_valid("../outside.ttf"));
    assert(!game_font_choice_valid("C:\\outside.ttf"));
    assert(!game_font_choice_valid("invalid.otf"));
    assert(game_font_choice_valid("custom.ttf"));
    assert(game_font_choice_valid("custom.TTC"));
    assert(game_font_choice_valid("custom.bfttf"));
    if (argc > 3) language = argv[3];
    char filename[256], error[640];
    assert(game_font_import_file("incoming/imported.ttf", filename, sizeof filename, error, sizeof error));
    assert(!strcmp(filename, "imported.ttf"));
    assert(game_font_import_file("incoming/imported.ttf", filename, sizeof filename, error, sizeof error));
    assert(!game_font_import_file("incoming/custom.ttf", filename, sizeof filename, error, sizeof error));
    assert(strstr(error, "already exists"));
    assert(!game_font_import_file("fonts/cff.ttf", filename, sizeof filename, error, sizeof error));
    load_fonts();
    game_font_loaded(description, sizeof description);
    if (!strcmp(argv[2], "system")) assert(!strstr(description, "Imported fixture"));
    else assert(strstr(description, argv[2]));
    // The environment override wins, while a chosen text file leaves NintendoExt alone.
    if (!strcmp(argv[1], "custom.ttf") && !getenv("LARECOMP_FONT")) {
        assert(fonts[F_STD].size == fonts[F_KO].size);
        assert(fonts[F_EXT].size != fonts[F_STD].size);
    }
    pl_reset();
    game_font_loaded(description, sizeof description);
    assert(!description[0]);
    puts("font selection and reset OK");
}
