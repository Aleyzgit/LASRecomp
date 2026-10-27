#include "game_font.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "platform.h"

static bool same_file_contents(FILE *a, FILE *b) {
    unsigned char x[16384], y[16384];
    for (;;) {
        size_t nx = fread(x, 1, sizeof x, a), ny = fread(y, 1, sizeof y, b);
        if (ferror(a) || ferror(b) || nx != ny || memcmp(x, y, nx)) return false;
        if (!nx) return true;
    }
}

bool game_font_import_file(const char *source, char *filename, size_t size, char *error, size_t error_size) {
    const char *base = source;
    for (const char *s = source; *s; s++) if (*s == '/' || *s == '\\') base = s + 1;
    if (!game_font_choice_valid(base) || !strcmp(base, "auto") || !strcmp(base, "system") || strlen(base) >= size) {
        snprintf(error, error_size, "Choose a .ttf, .ttc or .bfttf text font with a shorter filename.");
        return false;
    }
    char description[640], dest[300];
    if (!game_font_describe(source, description, sizeof description)) {
        snprintf(error, error_size, "This file is not a usable TrueType text font. CFF OpenType fonts are not supported.");
        return false;
    }
    snprintf(dest, sizeof dest, "fonts/%s", base);
    mkdir("fonts", 0755);
    FILE *in = fopen(source, "rb");
    if (!in) {
        snprintf(error, error_size, "The selected font could not be opened.");
        return false;
    }
    FILE *existing = fopen(dest, "rb");
    if (existing) {
        bool same = same_file_contents(in, existing);
        fclose(existing);
        fclose(in);
        if (same) { snprintf(filename, size, "%s", base); return true; }
        snprintf(error, error_size, "A different file named %s already exists in fonts/. Rename the new file before importing.", base);
        return false;
    }
    // Exclusive creation: even if another import races this one, its file cannot be truncated.
    FILE *out = fopen(dest, "wbx");
    if (!out) {
        fclose(in);
        snprintf(error, error_size, "The font could not be copied to fonts/: %s.", strerror(errno));
        return false;
    }
    unsigned char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = fread(buf, 1, sizeof buf, in)))
        if (fwrite(buf, 1, n, out) != n) { ok = false; break; }
    if (ferror(in)) ok = false;
    fclose(in);
    if (fclose(out)) ok = false;
    if (ok) ok = game_font_describe(dest, description, sizeof description);
    if (!ok) {
        unlink(dest);  // only the new partial file created above; source and pre-existing files are untouched
        snprintf(error, error_size, "The font could not be copied completely. The source file was kept.");
        return false;
    }
    snprintf(filename, size, "%s", base);
    return true;
}
