// Game text fonts (nn::pl), independent of the Recomp menu's own font.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// A single file inside the data folder's fonts/, or the reserved choices auto / system.
bool game_font_choice_valid(const char *choice);
// Inspect without allocating guest memory; the family and filename for the menu.
bool game_font_describe(const char *path, char *out, size_t size);
// What this boot actually loaded for Standard, empty before the game starts.
void game_font_loaded(char *out, size_t size);
// Copy a valid text font into fonts/ and return its filename. Never overwrite a different file.
bool game_font_import_file(const char *source, char *filename, size_t size, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
