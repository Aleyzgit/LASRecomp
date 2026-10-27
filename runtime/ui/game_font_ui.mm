#include "game_font_ui.h"
#include "option_rows.h"
#include "imgui.h"
#include "../game_font.h"
extern "C" {
#include "../settings.h"
}
#include <SDL3/SDL.h>
#include <algorithm>
#include <dirent.h>
#include <stdio.h>
#include <mutex>
#include <map>
#include <sys/stat.h>
#include <string.h>
#include <string>
#include <vector>

static std::mutex picker_lock;
static bool picker_pending;
static std::string picked_file, picker_error;

static void SDLCALL picked_text_font(void *, const char *const *files, int) {
    std::lock_guard<std::mutex> lock(picker_lock);
    picker_pending = false;
    if (!files) picker_error = std::string("Could not open the font picker: ") + SDL_GetError();
    else if (files[0]) picked_file = files[0];
}

static void SDLCALL show_font_picker(void *) {
    static const SDL_DialogFileFilter filters[] = {{"TrueType text fonts", "ttf;ttc;bfttf"}};
    SDL_ShowOpenFileDialog(picked_text_font, NULL, SDL_GetKeyboardFocus(), filters, 1, NULL, false);
}

void game_font_row(void) {
    // The Recomp menu currently has English text only. Match that language; game languages are independent.
    static std::vector<std::string> files, labels, details;
    struct CachedFont { time_t modified; off_t size; std::string description; bool usable; };
    static std::map<std::string, CachedFont> cache;
    static Uint64 scanned;
    static std::string import_message;
    std::string source;
    bool busy;
    {
        std::lock_guard<std::mutex> lock(picker_lock);
        source.swap(picked_file);
        if (!picker_error.empty()) import_message.swap(picker_error), picker_error.clear();
        busy = picker_pending;
    }
    if (!source.empty()) {
        char filename[256], error[640];
        if (game_font_import_file(source.c_str(), filename, sizeof filename, error, sizeof error)) {
            snprintf(g_settings.game_font, sizeof g_settings.game_font, "%s", filename);
            settings_save();
            scanned = 0;
            labels.clear();
            import_message = std::string("Imported and selected: ") + filename +
                             ". Choose Quit > Title screen, then Play again; or restart LAS Recomp to use it.";
        } else import_message = error;
    }
    Uint64 now = SDL_GetTicks();
    if (labels.empty() || now - scanned > 1000) {
        scanned = now;
        files = {"auto", "system"};
        labels = {"Automatic", "System fonts"};
        details = {"", ""};
        std::vector<std::string> found;
        if (DIR *dir = opendir("fonts")) {
            while (dirent *e = readdir(dir))
                if (game_font_choice_valid(e->d_name) && strcmp(e->d_name, "auto") && strcmp(e->d_name, "system"))
                    found.emplace_back(e->d_name);
            closedir(dir);
        }
        std::sort(found.begin(), found.end());
        for (const std::string &file : found) {
            std::string path = "fonts/" + file;
            struct stat st;
            if (stat(path.c_str(), &st) || !S_ISREG(st.st_mode)) continue;
            auto entry = cache.find(file);
            if (entry == cache.end() || entry->second.modified != st.st_mtime || entry->second.size != st.st_size) {
                char description[512] = "";
                bool usable = game_font_describe(path.c_str(), description, sizeof description);
                cache[file] = {st.st_mtime, st.st_size, description, usable};
            }
            const CachedFont &info = cache.at(file);
            if (!info.usable) continue;
            files.push_back(file);
            details.push_back(info.description);
            std::string family = info.description;
            size_t end = family.find(" (");
            if (end != std::string::npos) family.resize(end);
            if (family == "Morisawa UD Shin Go Regular") family = "UD Shin Go";
            labels.push_back(family);
        }
    }
    std::vector<std::string> display = labels;
    std::vector<const char *> names;
    int selected = 0;
    for (size_t i = 0; i < files.size(); i++) {
        names.push_back(display[i].c_str());
        if (files[i] == g_settings.game_font) selected = (int)i;
    }
    bool missing = strcmp(g_settings.game_font, "auto") && strcmp(g_settings.game_font, "system") && !selected;
    if (missing) {
        selected = (int)names.size();
        names.push_back("Missing file");  // retain the saved filename; show the problem without overflowing the row
        opt_warn_next();
    }
    // Long families / filenames stay readable in the description; values must not overlap the row label.
    float max_width = ImGui::GetContentRegionAvail().x * 0.40f;
    for (size_t i = 0; i < display.size(); i++) {
        std::string &value = display[i];
        if (ImGui::CalcTextSize(value.c_str()).x <= max_width) continue;
        while (!value.empty() && ImGui::CalcTextSize((value + "...").c_str()).x > max_width) {
            do value.pop_back(); while (!value.empty() && ((unsigned char)value.back() & 0xc0) == 0x80);
            // Remove an incomplete leading byte too, when the last removed character was multibyte.
            if (!value.empty() && (unsigned char)value.back() >= 0xc0) value.pop_back();
        }
        value += "...";
        names[i] = value.c_str();
    }
    char active[640], detail[512] = "", desc[2400];
    game_font_loaded(active, sizeof active);
    if (missing) snprintf(detail, sizeof detail, "%s", g_settings.game_font);
    if (selected >= 2 && !missing)
        snprintf(detail, sizeof detail, "%s", details[selected].c_str());
#ifdef _WIN32
    const char *normal = "Yu Gothic (YuGothR.ttc), or Arial / DejaVu Sans if unavailable";
#elif defined(__APPLE__)
    const char *normal = "Hiragino Sans W4, or Arial / DejaVu Sans if unavailable";
#else
    const char *normal = "BIZ UDPGothic, or the installed system font / DejaVu Sans";
#endif
    snprintf(desc, sizeof desc,
             "Dialogue and game menus. Applies on the next game start: Quit > Title screen, then Play again; or restart LAS Recomp. "
             "The Recomp menu keeps its own font.\n\n"
             "%s%s%s%s%s%s\n\n"
             "Usual system substitute: %s. Chinese / Korean use their language's own fonts; Russian skips Japanese fonts.\n\n"
             "Automatic prefers imported Nintendo fonts. System fonts keeps imported files and uses substitutes. "
             "To choose a file, put it in fonts/. Button icons are kept.\n\n"
             "Original: Morisawa UD Shin Go Regular, nintendo_udsg-r_std_003.bfttf / .ttf "
             "(nintendo_udsgr_std_003 also works).",
             missing ? "Selected file missing or unusable; Automatic will be used.\n\n" : "",
             detail[0] ? "Selected: " : "", detail, detail[0] ? "\n\n" : "",
             active[0] ? "Loaded this game start: " : "The game has not loaded its fonts yet.", active,
             normal);
    if (getenv("LARECOMP_FONT") && *getenv("LARECOMP_FONT"))
        strncat(desc, "\n\nLARECOMP_FONT is set and takes priority over this setting.", sizeof desc - strlen(desc) - 1);
    if (opt_choice("Game text font", &selected, names.data(), (int)names.size(), 0, desc)) {
        if (selected < (int)files.size()) {
            snprintf(g_settings.game_font, sizeof g_settings.game_font, "%s", files[selected].c_str());
            settings_save();
        }
    }
    if (busy) opt_disable_next();
    std::string help = "1. Choose Import text font and select your .ttf, .ttc or .bfttf file.\n\n"
                       "2. LAS Recomp copies it into its fonts/ folder and selects it above. Your original file is kept.\n\n"
                       "3. Choose Quit > Title screen in the Recomp menu, then Play again; or restart LAS Recomp.\n\n"
                       "For the original Standard font, select nintendo_udsg-r_std_003.ttf / .bfttf "
                       "or nintendo_udsgr_std_003.ttf / .bfttf from your own files.\n\n"
                       "Alternatively, copy the file into the data folder's fonts/ yourself, then choose it above.";
    if (!import_message.empty()) help = import_message + "\n\n" + help;
    if (opt_button("Import text font...", help.c_str())) {
        {
            std::lock_guard<std::mutex> lock(picker_lock);
            picker_pending = true;
        }
        if (!SDL_RunOnMainThread(show_font_picker, NULL, false)) {
            std::lock_guard<std::mutex> lock(picker_lock);
            picker_pending = false;
            picker_error = std::string("Could not open the font picker: ") + SDL_GetError();
        }
    }

}
