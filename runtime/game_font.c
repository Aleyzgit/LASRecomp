#include "game_font.h"
#include <string.h>
#include <ctype.h>
#include <strings.h>

bool game_font_choice_valid(const char *s) {
    if (!s || !*s) return false;
    if (!strcmp(s, "auto") || !strcmp(s, "system")) return true;
    size_t n = strlen(s);
    if (isspace((unsigned char)s[0]) || isspace((unsigned char)s[n - 1])) return false;
    for (size_t i = 0; i < n; i++) if ((unsigned char)s[i] < 32 || (unsigned char)s[i] == 127) return false;
    if (n >= 256 || strchr(s, '/') || strchr(s, '\\') || strchr(s, ':') ||
        strchr(s, '\n') || strchr(s, '\r') || strchr(s, '=')) return false;
    return (n > 4 && (!strcasecmp(s + n - 4, ".ttf") || !strcasecmp(s + n - 4, ".ttc"))) ||
           (n > 6 && !strcasecmp(s + n - 6, ".bfttf"));
}
