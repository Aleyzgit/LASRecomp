// Check tracker for randomizer seeds: it takes over the pause menu's Map page (tools/patches.py MAP_PAGE_SITE). The
// game's island art, zoom / scroll, explored fog, place names and Link marker stay; the game's own cursor and button
// bar are hidden (map_page_takeover) and our layer drives the page:
//   bullets  one small numbered bullet beside each of the game's place names ("Mabe Village"...): the area's open
//            checks under the filters, coloured by the best of them - green in logic now, purple trick logic only,
//            amber needs an item. Each check's place comes from the Field level's zone grid (tools/rando/tracker.py
//            field_areas); interiors count at their door. Names read as a player would ("Bush, Mabe Village (north)").
//            One icon per dungeon (found / total) at the overworld door that leads into it (dungeon entrance shuffle),
//            labelled by the dungeon reached there; room shuffle: a moved room's checks count for the dungeon it sits
//            in now (tools/rando/tracker.py)
//   list     A on a bullet: the area's checks in one list by status (open in logic, needs an item with the cheapest
//            missing items, trick logic, collected struck out); A on a row shows that check's spot, B goes back
//   filters  "In logic now" (on by default), "Hide checked" and one toggle per kind of check in the seed. Filters only
//            change the bullets, never a list. Game-styled: a line in the game's button row, a filter panel on Y
//   input    while it drives, the left stick / d-pad, A and Y never reach the game, B neither while a list, a shown
//            spot or the filters are up (runtime/hle/input.c -> tracker_map_input); the right stick still zooms /
//            scrolls the game's map; ZR hands the page back to the game's own map (warp points, pins). The mouse
//            works too. Outside rando (or with the tracker off) the Map page is vanilla
// Never shows what a check holds. Data: rando/<seed>/tracker.tsv (tools/rando/tracker.py). Reachability = LAS's
// fixpoint over its logic nodes from the live save's inventory (followers count once their location is reachable).
#include "../game_addresses.h"
#include <atomic>
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>

#include "imgui.h"
#include <SDL3/SDL_timer.h>

extern "C" {
#include "../hle.h"
#include "../rando.h"
#include "../settings.h"
uint64_t renderer_present_count(void);
int kernel_data_regions(uint64_t *addr, uint64_t *size, int max);
const char *souls_at(int i, int *kind, bool *owned);  // runtime/hle/souls.c
bool triforce_counts(int *have, int *needed);         // runtime/hle/triforce.c
}

#define SAVE (MAIN_BASE + 0x1CBB220)
#define EVENT_FLAGS (SAVE + 0x5DC0)

static volatile uint64_t g_map_frame, g_map_opened;
static volatile uint64_t g_map_obj;     // x0 of the map page update (main+0xe93800)
static volatile uint64_t g_draw_frame;  // the tracker layer was drawn (it drives the page while this is recent)
static void map_debug_dump(uint64_t f);
static void map_page_takeover(uint64_t obj);
extern "C" void rt_map_page_tick(Cpu *c) {
    uint64_t f = renderer_present_count();
    if (f - g_map_frame > 2) g_map_opened = f;  // (re)opened
    g_map_frame = f;
    g_map_obj = c->x[0];
    map_debug_dump(f);
    map_page_takeover(c->x[0]);
}
extern "C" uint64_t tracker_map_obj(void) { return g_map_obj; }  // (LARECOMP_PANE_SCAN addr 2)
extern "C" void rt_map_page_end(Cpu *c) { (void)c; map_page_takeover(g_map_obj); }  // (the update's epilogue)
// LARECOMP_MAP_DUMP=<frame>[,<frame>...]: save the map page object (0x4000 bytes) to build/mapobj_<frame>.bin (RE)
static void map_debug_dump(uint64_t f) {
    static char spec[256];
    static int init;
    if (!init) { init = 1; const char *e = getenv("LARECOMP_MAP_DUMP"); if (e) snprintf(spec, sizeof spec, "%s", e); }
    if (!spec[0]) return;
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s", spec);
    for (char *t = strtok(tmp, ","); t; t = strtok(NULL, ","))
        if ((uint64_t)atol(t) == f) {
            char path[64];
            snprintf(path, sizeof path, "build/mapobj_%llu.bin", (unsigned long long)f);
            FILE *o = fopen(path, "wb");
            if (o) {  // the object, then every valid pointer in its first 0x1000 bytes: [u32 off][u64 ptr][0x1000]
                fwrite((const void *)(uintptr_t)g_map_obj, 1, 0x4000, o);
                uint64_t ra[256], rs[256];
                int nr = kernel_data_regions(ra, rs, 256);
                for (uint32_t off = 0; off < 0x1000; off += 8) {
                    uint64_t p = *(uint64_t *)(uintptr_t)(g_map_obj + off);
                    bool ok = false;
                    for (int i = 0; i < nr && !ok; i++) ok = p >= ra[i] && p + 0x1000 <= ra[i] + rs[i];
                    if (!ok) continue;
                    fwrite(&off, 4, 1, o);
                    fwrite(&p, 8, 1, o);
                    fwrite((const void *)(uintptr_t)p, 1, 0x1000, o);
                }
                fclose(o);
            }
            LOG("[map] obj %llx dumped to %s\n", (unsigned long long)g_map_obj, path);
        }
}
extern "C" void input_note_rstick(int32_t ry) { (void)ry; }  // (runtime/hle/input.c; the zoom is read from the page)

// ---- data
namespace {  // file-local types (spoiler_view.mm also has a Node)
enum Op : int32_t { OP_AND = -1, OP_OR = -2, OP_NOT = -3 };  // >= 0: push token (id | count << 20)
struct Node { std::string name; int type; int id, region; std::vector<int32_t> cond, pit, heavy, trick; bool has_trick; };
enum Kind { K_CHEST, K_HEART, K_SHELL, K_BOSS, K_SHOP, K_OTHER, K_BUSH, K_DIG, K_POT, K_N };
struct Check {
    std::string name, area;
    float x, y;
    int group, flag, node, kind;
    std::string dungeon, dcell;  // the dungeon (D0..D8) and cell it sits in now (the dungeon view, phase 2)
    int place;                   // the game's place name it's in (T_MapName_NN), -1 = unknown / a dungeon's
    std::string title, spot;     // readable name ("Bush, Mabe Village (north)"), spot inside the place ("north-west")
};
struct Group { std::string label; float x, y; };
struct Room { std::string level, cell, room; float sx, sy; };  // shuffled dungeon cells (the dungeon view, phase 2)
enum { T_REGION, T_ITEM, T_ROOM, T_INTERACTION, T_ENEMY, T_TRICK, T_FOLLOWER };
enum St { ST_LOGIC, ST_TRICK, ST_NEEDS, ST_DONE };  // best first
}  // namespace

static const char *const kKindTok[K_N] = {"chest", "heart", "shell", "boss", "shop", "other", "bush", "dig", "pot"};
// filter bits: kinds 0..8, then the two switches
enum { F_IN_LOGIC = 1 << 16, F_HIDE_DONE = 1 << 17 };
static const int kDefaultFilters = F_IN_LOGIC | (1 << K_CHEST) | (1 << K_HEART) | (1 << K_SHELL) | (1 << K_BOSS) | (1 << K_SHOP) |
                                   (1 << K_OTHER);

static std::unordered_map<std::string, int> g_tok;
static std::vector<std::string> g_tok_names;
static std::vector<Node> g_nodes;
static std::vector<Check> g_checks;
static std::vector<Group> g_groups;
static std::vector<Room> g_rooms;
static std::vector<int> g_seed_settings, g_seed_off;
static std::unordered_map<std::string, int> g_flag_idx;  // flags.tsv (trade flags)
static int g_loaded = 0;
static bool g_kind_present[K_N];

static int tok(const std::string &s) {
    auto it = g_tok.find(s);
    if (it != g_tok.end()) return it->second;
    int id = (int)g_tok_names.size();
    g_tok[s] = id;
    g_tok_names.push_back(s);
    return id;
}

// condition -> RPN. Grammar: or := and ('|' and)*, and := not ('&' not)*, not := '!' not | '(' or ')' | token[:n]
struct Parser {
    const char *p;
    std::vector<int32_t> out;
    void ws() { while (*p == ' ') p++; }
    void prim() {
        ws();
        if (*p == '!') { p++; prim(); out.push_back(OP_NOT); return; }
        if (*p == '(') { p++; expr(); ws(); if (*p == ')') p++; return; }
        const char *s = p;
        while ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '[' || *p == ']') p++;
        std::string name(s, p - s);
        int count = 1;
        if (*p == ':') { p++; count = atoi(p); while (*p >= '0' && *p <= '9') p++; }
        if (name.empty()) { if (*p) p++; return; }
        out.push_back(tok(name) | (count << 20));
    }
    void conj() { prim(); for (ws(); *p == '&'; ws()) { p++; prim(); out.push_back(OP_AND); } }
    void expr() { conj(); for (ws(); *p == '|'; ws()) { p++; conj(); out.push_back(OP_OR); } }
};

static std::vector<int32_t> compile(const char *c) {
    if (!c || !strcmp(c, "-") || !*c) return {};
    Parser ps{c, {}};
    ps.expr();
    return ps.out;
}

static int kind_of_name(const std::string &n) {  // (a tracker.tsv from before kinds: by name)
    if (!n.compare(0, 5, "bush-")) return K_BUSH;
    if (!n.compare(0, 4, "dig-")) return K_DIG;
    if (!n.compare(0, 4, "pot-") || (n.size() > 7 && n[0] == 'D' && !n.compare(2, 5, "-pot-"))) return K_POT;
    return K_OTHER;
}

static void load(void) {
    g_loaded = -1;
    const char *dir = rando_seed_dir();
    if (!dir) return;
    char path[512];
    snprintf(path, sizeof path, "%s/tracker.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return;
    static char line[16384];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        std::vector<char *> c;
        for (char *s = line, *t; (t = strsep(&s, "\t"));) c.push_back(t);
        if (c[0][0] == 'S' && c.size() >= 2) g_seed_settings.push_back(tok(c[1]));
        else if (c[0][0] == 'F' && c.size() >= 2) g_seed_off.push_back(tok(c[1]));
        else if (c[0][0] == 'N' && c.size() >= 7) {
            static const char *types[] = {"region", "item", "room", "interaction", "enemy", "trick", "follower"};
            Node n;
            n.type = 0;
            for (int i = 0; i < 7; i++) if (!strcmp(c[1], types[i])) n.type = i;
            n.name = c[2];
            n.id = tok(c[2]);
            n.region = strcmp(c[3], "-") ? tok(c[3]) : -1;
            n.cond = compile(c[4]);
            n.pit = compile(c[5]);
            n.heavy = compile(c[6]);
            n.has_trick = c.size() >= 8 && strcmp(c[7], "-");
            if (n.has_trick) n.trick = compile(c[7]);
            g_nodes.push_back(std::move(n));
        } else if (c[0][0] == 'G' && c.size() >= 4) g_groups.push_back({c[1], (float)atof(c[2]), (float)atof(c[3])});
        else if (c[0][0] == 'C' && c.size() >= 6) {
            Check k;
            k.name = c[1];
            k.x = (float)atof(c[2]), k.y = (float)atof(c[3]);
            k.group = atoi(c[4]), k.flag = atoi(c[5]);
            k.node = tok(c[1]);
            k.kind = kind_of_name(k.name);
            if (c.size() >= 7)
                for (int i = 0; i < K_N; i++) if (!strcmp(c[6], kKindTok[i])) k.kind = i;
            if (c.size() >= 8 && strcmp(c[7], "-")) k.area = c[7];
            if (c.size() >= 10) {
                if (strcmp(c[8], "-")) k.dungeon = c[8];
                if (strcmp(c[9], "-")) k.dcell = c[9];
            }
            k.place = c.size() >= 11 ? atoi(c[10]) : -1;
            if (k.place > 20) k.place = -1;
            if (c.size() >= 12 && strcmp(c[11], "-")) k.title = c[11];
            if (c.size() >= 13 && strcmp(c[12], "-")) k.spot = c[12];
            g_kind_present[k.kind] = true;
            g_checks.push_back(std::move(k));
        } else if (c[0][0] == 'R' && c.size() >= 6)
            g_rooms.push_back({c[1], c[2], c[3], (float)atof(c[4]), (float)atof(c[5])});
    }
    fclose(f);
    snprintf(path, sizeof path, "%s/flags.tsv", dir);
    if ((f = fopen(path, "r"))) {
        char name[128];
        int idx;
        while (fscanf(f, "%127s %d", name, &idx) == 2) g_flag_idx[name] = idx;
        fclose(f);
    }
    g_loaded = 1;
    LOG("[tracker] %zu logic nodes, %zu checks, %zu dungeons, %zu dungeon cells\n", g_nodes.size(), g_checks.size(),
        g_groups.size(), g_rooms.size());
}

// ---- reachability
static std::vector<int> g_acc;        // count per token
static std::vector<int> g_acc_trick;  // (the same with every logic level up to glitched)

static void ui_reset(void);
static void index_reset(void);
RT_ON_RESET(tracker_reset) {  // (reboot: the next seed's tracker.tsv; the map page object was guest memory)
    g_tok.clear(), g_tok_names.clear(), g_nodes.clear(), g_checks.clear(), g_groups.clear(), g_rooms.clear();
    g_seed_settings.clear(), g_seed_off.clear(), g_flag_idx.clear(), g_acc.clear(), g_acc_trick.clear();
    memset(g_kind_present, 0, sizeof g_kind_present);
    g_loaded = 0;
    g_map_frame = g_map_opened = g_map_obj = g_draw_frame = 0;
    ui_reset();
    index_reset();
}
extern "C" bool flags_ext_get(int idx);  // runtime/hle/flags_ext.c (bushes, digs: 2048+)
static bool flag_set(int i) {
    if (i >= 2048) return flags_ext_get(i);
    return i >= 0 && (LD8(EVENT_FLAGS + (i >> 3)) >> (i & 7)) & 1;
}
static int &A(int id) {  // access count; tokens interned after sizing (e.g. "x[pit]") grow the table
    if (id >= (int)g_acc.size()) g_acc.resize(id + 64, 0);
    return g_acc[id];
}
static void give(const char *name, int n = 1) { if (n > 0) A(tok(name)) += n; }

static bool eval(const std::vector<int32_t> &rpn) {
    if (rpn.empty()) return true;
    bool st[256];
    int sp = 0;
    for (int32_t o : rpn) {
        if (o == OP_AND) { sp--; st[sp - 1] = st[sp - 1] && st[sp]; }
        else if (o == OP_OR) { sp--; st[sp - 1] = st[sp - 1] || st[sp]; }
        else if (o == OP_NOT) st[sp - 1] = !st[sp - 1];
        else if (sp < 256) { int id = o & 0xFFFFF, cnt = o >> 20; st[sp++] = id < (int)g_acc.size() && g_acc[id] >= cnt; }
    }
    return sp ? st[sp - 1] : true;
}

static void inventory(void) {
    uint32_t items = LD32(SAVE + 0x5568), keyitems = LD32(SAVE + 0x556C);
    uint8_t upg = LD8(SAVE + 0x555C), songs = LD8(SAVE + 0x555B);
    auto b = [](uint32_t v, int i) { return (int)((v >> i) & 1); };
    give("sword", b(items, 0) + (b(items, 0) && b(upg, 0)));
    give("shield", b(items, 1) + (b(items, 1) && b(upg, 1)));
    give("bracelet", b(items, 10) + (b(items, 10) && b(upg, 2)));
    static const struct { const char *n; int bit; } it[] = {{"bomb", 2}, {"bow", 3}, {"hookshot", 4}, {"boomerang", 5}, {"rod", 6},
                                                             {"shovel", 7}, {"powder", 8}, {"feather", 9}, {"boots", 11}, {"ocarina", 12}};
    for (auto &x : it) give(x.n, b(items, x.bit));
    give("bottle", b(items, 13) + b(items, 14) + b(items, 15));
    static const struct { const char *n; int bit; } ki[] = {
        {"flippers", 0}, {"medicine", 1}, {"tail-key", 2}, {"slime-key", 3}, {"angler-key", 4}, {"face-key", 5}, {"bird-key", 6},
        {"full-moon-cello", 7}, {"conch-horn", 8}, {"sea-lilys-bell", 9}, {"surf-harp", 10}, {"wind-marimba", 11},
        {"coral-triangle", 12}, {"evening-calm-organ", 13}, {"thunder-drum", 14}, {"mushroom", 15}};
    for (auto &x : ki) give(x.n, b(keyitems, x.bit));
    give("shell-sensor", LD8(SAVE + 0x556E) & 1);
    give("song-ballad", b(songs, 0));
    give("song-mambo", b(songs, 1));
    give("song-soul", b(songs, 2));
    give("red-tunic", b(upg, 6));
    give("blue-tunic", b(upg, 7));
    give("powder-capacity", b(upg, 3));
    give("bomb-capacity", b(upg, 4));
    give("arrow-capacity", b(upg, 5));
    give("golden-leaf", __builtin_popcount(LD8(SAVE + 0x5582) & 0x1F));
    give("seashell", __builtin_popcountll(LD64(SAVE + 0x5548) & ((1ull << 50) - 1)));
    static const struct { const char *tok, *flag; int slot; } trade[] = {
        {"yoshi-doll", "TradeYoshiDollGet", 1}, {"ribbon", "TradeRibbonGet", 2}, {"dog-food", "TradeDogFoodGet", 3},
        {"bananas", "TradeBananasGet", 4}, {"stick", "TradeStickGet", 5}, {"honeycomb", "TradeHoneycombGet", 6},
        {"pineapple", "TradePineappleGet", 7}, {"hibiscus", "TradeHibiscusGet", 8}, {"letter", "TradeLetterGet", 9},
        {"broom", "TradeBroomGet", 10}, {"fishing-hook", "TradeFishingHookGet", 11}, {"necklace", "TradeNecklaceGet", 12},
        {"mermaid-scale", "TradeMermaidsScaleGet", 13}, {"magnifying-lens", "", 14}};
    int held = LD8(SAVE + 0x555A);
    for (auto &t : trade) {
        auto f = g_flag_idx.find(t.flag);
        give(t.tok, held == t.slot || (f != g_flag_idx.end() && flag_set(f->second)));
    }
    static const struct { const char *tok, *flag; } pets[] = {  // pets found (runtime/hle/pets.c)
        {"rooster", "unused0427"}, {"marin-companion", "unused0428"}, {"ghost", "unused0429"}};
    for (auto &t : pets) {
        auto f = g_flag_idx.find(t.flag);
        give(t.tok, f != g_flag_idx.end() && flag_set(f->second));
    }
    for (int i = 0;; i++) {  // boss / mini-boss souls (runtime/hle/souls.c): token soul-<name, lower case, dashes>
        int kind;
        bool owned;
        const char *nm = souls_at(i, &kind, &owned);
        if (!nm) break;
        char t[48] = "soul-";
        for (size_t k = 5; *nm && k < sizeof t - 1; nm++, k++) t[k] = *nm == ' ' ? '-' : (char)tolower((unsigned char)*nm);
        give(t, owned);
    }
    static const char *dn[] = {"D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8"};
    for (int d = 0; d < 9; d++) {  // dungeon records: dungeon n = record 2(n-1), Color Dungeon = 18
        int rec = d < 8 ? 2 * d : 18;
        uint64_t p = SAVE + 0xE0 + 0x10ull * rec;
        char name[32];
        snprintf(name, sizeof name, "key-%s", d < 8 ? dn[d] : "D0");
        give(name, LD8(p));
        snprintf(name, sizeof name, "nightmare-key-%s", d < 8 ? dn[d] : "D0");
        give(name, (LD8(p + 1) >> 3) & 1);
    }
}

static void solve(bool trick) {
    g_acc.assign(g_tok_names.size() + 64, 0);
    for (int s : g_seed_settings) A(s) = 1;
    inventory();
    std::vector<char> done(g_nodes.size(), 0);
    for (bool grew = true; grew;) {
        grew = false;
        for (size_t i = 0; i < g_nodes.size(); i++) {
            Node &n = g_nodes[i];
            if (done[i]) continue;
            const std::vector<int32_t> &cond = trick && n.has_trick ? n.trick : n.cond;
            bool ok;
            if (n.type == T_ENEMY) {
                if (eval(cond)) {
                    done[i] = 1;
                    A(n.id) = 1;
                    A(tok(n.name + "[pit]")) = 1;
                    A(tok(n.name + "[heavy]")) = 1;
                    grew = true;
                    continue;
                }
                if (!n.pit.empty() && !A(tok(n.name + "[pit]")) && eval(n.pit)) { A(tok(n.name + "[pit]")) = 1; grew = true; }
                if (!n.heavy.empty() && !A(tok(n.name + "[heavy]")) && eval(n.heavy)) { A(tok(n.name + "[heavy]")) = 1; grew = true; }
                continue;
            }
            ok = (n.type != T_ITEM && n.type != T_FOLLOWER) || n.region < 0 || A(n.region) > 0;
            ok = ok && eval(cond);
            if (!ok) continue;
            done[i] = 1;
            A(n.id) = 1;
            if (n.type == T_FOLLOWER || n.name == "moblin-cave") give("bow-wow");
            if (n.name == "rooster-statue") give("rooster");
            grew = true;
        }
    }
}

// ---- "needs X": the cheapest way to a node from the current inventory = the fewest missing items. Each node's
// cost is a set of (item token, count) - AND merges, OR keeps the smaller - iterated to a fixed point over the
// seed's logic (the same conditions as solve(false), whose g_acc says what is reachable now: that costs nothing).
namespace {
struct Cost {
    bool inf = true;
    std::vector<int32_t> miss;  // token | count << 20, sorted by token
};
}  // namespace
static std::vector<Cost> g_cost;     // per token (nodes and derived tokens)
static std::vector<char> g_is_node;  // per token: a node or a derived token (x[pit], bow-wow...), not an item
static std::vector<char> g_is_off;   // per token: a seed setting that is off

static Cost c_and(const Cost &a, const Cost &b) {
    if (a.inf || b.inf) return Cost();
    Cost r;
    r.inf = false;
    size_t i = 0, j = 0;
    while (i < a.miss.size() || j < b.miss.size()) {
        int ta = i < a.miss.size() ? (a.miss[i] & 0xFFFFF) : INT32_MAX, tb = j < b.miss.size() ? (b.miss[j] & 0xFFFFF) : INT32_MAX;
        if (ta == tb) r.miss.push_back(std::max(a.miss[i], b.miss[j])), i++, j++;  // (same token: the larger count)
        else if (ta < tb) r.miss.push_back(a.miss[i++]);
        else r.miss.push_back(b.miss[j++]);
    }
    return r;
}
static bool c_better(const Cost &a, const Cost &b) {  // a strictly cheaper than b
    if (a.inf) return false;
    if (b.inf) return true;
    if (a.miss.size() != b.miss.size()) return a.miss.size() < b.miss.size();
    int ca = 0, cb = 0;
    for (int32_t m : a.miss) ca += m >> 20;
    for (int32_t m : b.miss) cb += m >> 20;
    return ca < cb;
}
static Cost c_or(const Cost &a, const Cost &b) { return c_better(b, a) ? b : a; }
static Cost c_zero(void) { Cost z; z.inf = false; return z; }

static void cost_grow(size_t n) {
    if (g_cost.size() >= n) return;
    g_cost.resize(n + 64), g_is_node.resize(n + 64, 0), g_is_off.resize(n + 64, 0);
}

static Cost cost_of(const std::vector<int32_t> &rpn) {
    if (rpn.empty()) return c_zero();
    std::vector<Cost> st;
    std::vector<char> tv;  // each sub-expression's truth now (for NOT)
    for (int32_t o : rpn) {
        if (o == OP_AND || o == OP_OR) {
            if (st.size() < 2) return Cost();
            Cost b = st.back();
            st.pop_back();
            char vb = tv.back();
            tv.pop_back();
            st.back() = o == OP_AND ? c_and(st.back(), b) : c_or(st.back(), b);
            tv.back() = o == OP_AND ? (tv.back() && vb) : (tv.back() || vb);
        } else if (o == OP_NOT) {
            if (st.empty()) return Cost();
            tv.back() = !tv.back();
            st.back() = tv.back() ? c_zero() : Cost();  // (a NOT is met now or never: settings, "not yet" states)
        } else {
            int id = o & 0xFFFFF, cnt = o >> 20;
            bool have = id < (int)g_acc.size() && g_acc[id] >= cnt;
            Cost z;
            if (have) z = c_zero();
            else if (id < (int)g_is_off.size() && g_is_off[id]) z = Cost();
            else if (id < (int)g_is_node.size() && g_is_node[id]) z = g_cost[id];
            else z = c_zero(), z.miss.push_back(o);  // an item not owned (or not enough of it)
            st.push_back(std::move(z));
            tv.push_back(have);
        }
    }
    return st.empty() ? Cost() : st.back();
}

static void solve_costs(void) {
    g_cost.clear(), g_is_node.clear(), g_is_off.clear();
    cost_grow(g_tok_names.size());
    for (int s : g_seed_off) g_is_off[s] = 1;
    int bowwow = tok("bow-wow"), rooster = tok("rooster");
    std::vector<int> pit(g_nodes.size(), -1), heavy(g_nodes.size(), -1);
    for (size_t i = 0; i < g_nodes.size(); i++)
        if (g_nodes[i].type == T_ENEMY) pit[i] = tok(g_nodes[i].name + "[pit]"), heavy[i] = tok(g_nodes[i].name + "[heavy]");
    cost_grow(g_tok_names.size());
    for (size_t i = 0; i < g_nodes.size(); i++) {
        g_is_node[g_nodes[i].id] = 1;
        if (pit[i] >= 0) g_is_node[pit[i]] = g_is_node[heavy[i]] = 1;
    }
    auto reached = [](int id) { return id < (int)g_acc.size() && g_acc[id] > 0; };
    for (size_t t = 0; t < g_cost.size(); t++)
        if (g_is_node[t] && reached((int)t)) g_cost[t] = c_zero();
    auto item_cost = [](int id) { Cost c = c_zero(); c.miss.push_back(id | 1 << 20); return c; };
    if (!reached(bowwow)) g_is_node[bowwow] = 1, g_cost[bowwow] = item_cost(bowwow);  // (found as an item, or the
    if (!reached(rooster)) g_is_node[rooster] = 1, g_cost[rooster] = item_cost(rooster);  // follower's location)
    for (int pass = 0; pass < 60; pass++) {
        bool changed = false;
        auto upd = [&](int id, const Cost &c) {
            if (c_better(c, g_cost[id])) { g_cost[id] = c; changed = true; }
        };
        for (size_t i = 0; i < g_nodes.size(); i++) {
            const Node &n = g_nodes[i];
            if (reached(n.id)) continue;
            Cost c = cost_of(n.cond);
            if ((n.type == T_ITEM || n.type == T_FOLLOWER) && n.region >= 0) c = c_and(g_cost[n.region], c);
            upd(n.id, c);
            if (n.type == T_ENEMY) {
                if (!n.pit.empty()) upd(pit[i], cost_of(n.pit));
                if (!n.heavy.empty()) upd(heavy[i], cost_of(n.heavy));
                upd(pit[i], c), upd(heavy[i], c);
            }
            if (!reached(bowwow) && (n.type == T_FOLLOWER || n.name == "moblin-cave")) upd(bowwow, c);
            if (!reached(rooster) && n.name == "rooster-statue") upd(rooster, c);
        }
        if (!changed) break;
    }
}

static std::string needs_text(int check);
static std::vector<int> g_status;  // per check
static void debug_dump(void) {
    if (!ENV("LARECOMP_LOG_TRACKER")) return;
    for (size_t i = 0; i < g_checks.size() && i < g_status.size(); i++)
        LOG("[tracker] %-28s %-6s st %d %s\n", g_checks[i].name.c_str(), g_checks[i].dungeon.c_str(), g_status[i],
            g_status[i] == 2 ? needs_text((int)i).c_str() : "");
    int nd = 0;
    for (auto &n : g_nodes) nd += A(n.id) > 0;
    LOG("[tracker] solved: %d/%zu nodes; mabe %d tarin %d sword %d\n", nd, g_nodes.size(), A(tok("mabe")),
        A(tok("tarin")), A(tok("sword")));
}

// ---- names
static std::string pretty(const std::string &n) {
    std::string s = n;
    for (char &ch : s) if (ch == '-') ch = ' ';
    if (!s.empty()) s[0] = (char)toupper(s[0]);
    return s;
}
static std::string item_name(int id, int cnt) {
    static const struct { const char *tok, *name; } names[] = {
        {"sword", "Sword"}, {"shield", "Shield"}, {"bracelet", "Power Bracelet"}, {"bomb", "Bombs"}, {"bow", "Bow"},
        {"hookshot", "Hookshot"}, {"boomerang", "Boomerang"}, {"rod", "Magic Rod"}, {"shovel", "Shovel"},
        {"powder", "Magic Powder"}, {"feather", "Roc's Feather"}, {"boots", "Pegasus Boots"}, {"ocarina", "Ocarina"},
        {"bottle", "Bottle"}, {"flippers", "Flippers"}, {"medicine", "Secret Medicine"}, {"tail-key", "Tail Key"},
        {"slime-key", "Slime Key"}, {"angler-key", "Angler Key"}, {"face-key", "Face Key"}, {"bird-key", "Bird Key"},
        {"full-moon-cello", "Full Moon Cello"}, {"conch-horn", "Conch Horn"}, {"sea-lilys-bell", "Sea Lily's Bell"},
        {"surf-harp", "Surf Harp"}, {"wind-marimba", "Wind Marimba"}, {"coral-triangle", "Coral Triangle"},
        {"evening-calm-organ", "Evening Calm Organ"}, {"thunder-drum", "Thunder Drum"}, {"mushroom", "Sleepy Mushroom"},
        {"shell-sensor", "Seashell Sensor"}, {"song-ballad", "Ballad of the Wind Fish"}, {"song-mambo", "Manbo's Mambo"},
        {"song-soul", "Frog's Song of Soul"}, {"red-tunic", "Red Tunic"}, {"blue-tunic", "Blue Tunic"},
        {"golden-leaf", "Golden Leaves"}, {"seashell", "Seashells"}, {"bow-wow", "BowWow"}, {"rooster", "Rooster"},
        {"marin-companion", "Marin"}, {"ghost", "Ghost"}, {"yoshi-doll", "Yoshi Doll"}, {"ribbon", "Ribbon"},
        {"dog-food", "Dog Food"}, {"bananas", "Bananas"}, {"stick", "Stick"}, {"honeycomb", "Honeycomb"},
        {"pineapple", "Pineapple"}, {"hibiscus", "Hibiscus"}, {"letter", "Letter"}, {"broom", "Broom"},
        {"fishing-hook", "Fishing Hook"}, {"necklace", "Necklace"}, {"mermaid-scale", "Mermaid's Scale"},
        {"magnifying-lens", "Magnifying Lens"}, {"powder-capacity", "Powder upgrade"}, {"bomb-capacity", "Bomb upgrade"},
        {"arrow-capacity", "Arrow upgrade"}};
    const std::string &t = g_tok_names[id];
    std::string s;
    for (auto &x : names) if (t == x.tok) s = x.name;
    if (s.empty() && !t.compare(0, 4, "key-")) s = t.substr(4) + " Small Keys";
    else if (s.empty() && !t.compare(0, 14, "nightmare-key-")) return t.substr(14) + " Nightmare Key";
    else if (s.empty() && !t.compare(0, 5, "soul-")) s = pretty(t.substr(5)) + " soul";
    else if (s.empty()) s = pretty(t);
    if (cnt > 1) {
        if (t == "sword" || t == "bracelet") return s + " L2";
        if (t == "shield") return "Mirror Shield";
        return std::to_string(cnt) + " " + s;  // (5 Seashells, 3 D4 Small Keys)
    }
    return s;
}
static std::string area_name(const std::string &a) {
    static const struct { const char *tok, *name; } names[] = {
        {"mabe", "Mabe Village"}, {"woods", "Mysterious Woods"}, {"koholint-prairie", "Ukuku Prairie"},
        {"beach", "Toronbo Shores"}, {"swamp", "Goponga Swamp"}, {"graveyard", "Cemetery"},
        {"animal-village", "Animal Village"}, {"desert", "Yarna Desert"}, {"kanalet", "Kanalet Castle"},
        {"bay", "Martha's Bay"}, {"rapids", "Rapids Ride"}, {"tail-cave", "Tail Cave"},
        {"bottle-grotto", "Bottle Grotto"}, {"key-cavern", "Key Cavern"}, {"angler-tunnel", "Angler's Tunnel"},
        {"catfish-maw", "Catfish's Maw"}, {"face-shrine", "Face Shrine"}, {"eagle-tower", "Eagle's Tower"},
        {"turtle-rock", "Turtle Rock"}, {"color-dungeon", "Color Dungeon"}};
    for (auto &x : names) if (a == x.tok) return x.name;
    return pretty(a);
}
static const char *dungeon_name(const std::string &label) {
    static const char *const n[] = {"Color Dungeon", "Tail Cave", "Bottle Grotto", "Key Cavern", "Angler's Tunnel",
                                    "Catfish's Maw", "Face Shrine", "Eagle's Tower", "Turtle Rock"};
    if (label.size() == 2 && label[0] == 'D' && label[1] >= '0' && label[1] <= '8') return n[label[1] - '0'];
    return label.c_str();
}

// ---- UI state (render thread) and input events (game thread -> render thread)
namespace {
enum Ev { EV_NAV = 1, EV_A, EV_B, EV_Y };
struct Target { int type, id; float x, y; };  // type 0 = screen badge, 1 = dungeon icon; x, y = default-view UI units
struct UiState {
    int sel_type = -1, sel_id = -1;  // the cursor's badge
    bool panel = false;              // a screen / dungeon panel is open
    int panel_type = 0, panel_id = 0, panel_row = 0;
    float panel_scroll = 0;
    bool filter_focus = false;  // the cursor is on the filter bar
    int spot = -1;              // A in the list: this check's spot is shown on the map (B: back to the list)
    int chip = 0;
    uint64_t last_solve = ~0ull;
};
}  // namespace
static UiState g_ui;
static std::atomic<bool> g_panel_open{false}, g_filter_open{false};
static std::atomic<bool> g_vanilla{false};  // ZR: the game's own map for now (warp points, pins); reset on reopening
static volatile uint64_t g_avail_frame;     // the tracker could drive the page (drawn, in either mode)
static std::atomic<uint32_t> g_evq[64];
static std::atomic<uint32_t> g_evw{0}, g_evr{0};
static void ui_reset(void) {
    g_ui = UiState();
    g_panel_open = false, g_filter_open = false, g_vanilla = false;
    g_avail_frame = 0;
    g_evr.store(g_evw.load());
}
static void ev_push(uint32_t ev) {  // EV_NAV carries a direction: angle in degrees (0 = right, 90 = up) << 8
    uint32_t w = g_evw.load();
    if (w - g_evr.load() >= 64) return;
    g_evq[w & 63] = ev;
    g_evw.store(w + 1);
}

static bool takeover_active(void) {
    uint64_t now = renderer_present_count();
    return !g_vanilla && g_draw_frame && now - g_draw_frame <= 3 && now - g_map_frame <= 2;
}

// Game thread (runtime/hle/input.c fill_state): while the tracker drives the Map page, the left stick / d-pad, A and Y
// are ours, B too while a panel or the filter bar is open (then it closes that, not the pause menu). ZR switches
// between the tracker and the game's own map (its cursor: warp points, pins) until the page is opened again.
extern "C" uint64_t tracker_map_input(uint64_t b, int32_t st[4]) {
    enum { BA = 1, BB = 2, BY = 8, BZR = 1 << 9 };
    const uint64_t dirs = 0xfull << 12 | 0xfull << 16;
    static uint64_t prev, hide, dir_next;
    static int dir_last = -1;
    uint64_t press = b & ~prev;
    prev = b;
    hide &= b;  // (released: the game may see it again)
    uint64_t now0 = renderer_present_count();
    if (g_avail_frame && now0 - g_avail_frame <= 3 && now0 - g_map_frame <= 2 && (press & BZR)) {
        g_vanilla = !g_vanilla;
        g_panel_open = false, g_filter_open = false;
        hide |= BZR;
    }
    if (!takeover_active()) { dir_last = -1; return b & ~hide; }
    uint64_t now = renderer_present_count();
    // direction: the stick's angle, else the d-pad's
    int ang = -1;
    float lx = (float)st[0], ly = (float)st[1];
    if (lx * lx + ly * ly > 16000.0f * 16000.0f) ang = ((int)lroundf(atan2f(ly, lx) * 57.29578f) + 360) % 360;
    else {
        int dx = (int)((b >> 14) & 1) - (int)((b >> 12) & 1), dy = (int)((b >> 13) & 1) - (int)((b >> 15) & 1);
        if (dx || dy) ang = ((int)lroundf(atan2f((float)dy, (float)dx) * 57.29578f) + 360) % 360;
    }
    if (ang < 0) dir_last = -1;
    else if (dir_last < 0 || abs(((ang - dir_last + 540) % 360) - 180) > 40) {  // a new direction: one step now
        dir_last = ang, dir_next = now + 18;
        ev_push(EV_NAV | (uint32_t)ang << 8);
    } else if (now >= dir_next) {  // held: repeat
        dir_next = now + 7;
        ev_push(EV_NAV | (uint32_t)ang << 8);
    }
    if (press & BA) ev_push(EV_A);
    if (press & BY) ev_push(EV_Y);
    if ((press & BB) && (g_panel_open || g_filter_open)) { ev_push(EV_B); hide |= BB; }
    st[0] = st[1] = 0;
    hide |= b & (BA | BY);
    return b & ~(dirs | BA | BY | hide);
}

// ---- the map page's layout panes (ui2d: name at +0xB0, translate +0x30/+0x34, flags at +0x58 with bit 0 = visible;
// found with LARECOMP_PANE_SCAN=<frame>:2):
//   L_MapCursor_00  the game's cursor with its place-name box   } hidden while the tracker drives: in the page's update
//   L_Operation_00  its button hints (Memories, Pin, Zoom...)   } epilogue (MAP_PAGE_END_SITE), restored on hand-back.
//   W_Cursor_00     the cursor's yellow corner brackets (3 such panes on the page; all are switched off)
//                   L_MapCursor_00 is moved off the page, the others switched off (found with LARECOMP_TRACKER_CYCLE)
//   T_MapName_NN    the place names on the island (datasheet UiFieldMapLocationName mId NN): our area bullets sit
//                   beside them; translate = position in the map core (origin = page centre, y up)
// The panes are found once per opening, breadth first over the page object's pointers.
enum { PANE_CURSOR, PANE_OPS, PANE_LABEL0, NPANES = PANE_LABEL0 + 21 };
static char g_pane_names[NPANES][24];
static uint64_t g_pane[NPANES];
static bool g_hidden[2];
static std::vector<uint64_t> g_brackets;  // W_Cursor_00 panes
static std::vector<char> g_brackets_hidden;
static float g_cursor_t[2];   // (the cursor's own translate, put back on hand-back)
static uint64_t g_panes_for;  // the page object they were found for

static void pane_names(void) {
    if (g_pane_names[0][0]) return;
    snprintf(g_pane_names[PANE_CURSOR], 24, "L_MapCursor_00");
    snprintf(g_pane_names[PANE_OPS], 24, "L_Operation_00");
    for (int i = 0; i < 21; i++) snprintf(g_pane_names[PANE_LABEL0 + i], 24, "T_MapName_%02d", i);
}

// breadth first from the page object over pointers into guest data (nearest first: the pane graph is large)
static void find_panes(uint64_t obj) {
    static uint64_t ra[256], rs[256];
    int nr = kernel_data_regions(ra, rs, 256);
    std::vector<uint64_t> cur{obj}, next;
    std::unordered_map<uint64_t, char> seen;
    seen[obj] = 1;
    for (int depth = 0; depth < 7 && !cur.empty() && seen.size() < 60000; depth++) {
        next.clear();
        for (uint64_t o : cur)
            for (uint32_t off = 0; off < 0x800; off += 8) {
                uint64_t p = LD64(o + off);
                bool ok = false;
                for (int i = 0; i < nr && !ok; i++) ok = p >= ra[i] && p + 0x800 > p && p + 0x800 <= ra[i] + rs[i];
                if (!ok || !seen.emplace(p, 1).second) continue;
                const char *nm = (const char *)(uintptr_t)(p + 0xB0);
                if (nm[0] == 'L' || nm[0] == 'T')
                    for (int k = 0; k < NPANES; k++)
                        if (!g_pane[k] && !strcmp(nm, g_pane_names[k])) g_pane[k] = p;
                if (nm[0] == 'W' && !strcmp(nm, "W_Cursor_00") && g_brackets.size() < 8 &&
                    std::find(g_brackets.begin(), g_brackets.end(), p) == g_brackets.end())
                    g_brackets.push_back(p), g_brackets_hidden.push_back(0);
                next.push_back(p);
            }
        bool all = g_brackets.size() >= 3;
        for (int k = 0; k < NPANES; k++) all &= g_pane[k] != 0;
        if (all) break;
        cur.swap(next);
    }
}
static bool pane_ok(int k) {
    uint64_t p = g_pane[k];
    return p && !strcmp((const char *)(uintptr_t)(p + 0xB0), g_pane_names[k]);
}

// LARECOMP_TRACKER_CYCLE=<pane>,<pane>,... (test): from 100 frames after the map opens, every 40 frames the next pane in
// the list is switched off (bit 0 of +0x58, every frame), to see which of the page's panes draws what
static void cycle_test(uint64_t obj) {
    static char buf[1024], *names[64];
    static int n = -1;
    if (n < 0) {
        n = 0;
        const char *e = getenv("LARECOMP_TRACKER_CYCLE");
        if (e) {
            snprintf(buf, sizeof buf, "%s", e);
            for (char *t = strtok(buf, ","); t && n < 64; t = strtok(NULL, ",")) names[n++] = t;
        }
    }
    if (!n) return;
    uint64_t f = renderer_present_count() - g_map_opened;
    if (f < 100) return;
    int i = (int)((f - 100) / 40);
    if (i >= n) return;
    static int found_for = -1;
    static std::vector<uint64_t> hits;
    if (found_for != i) {
        found_for = i, hits.clear();
        static uint64_t ra[256], rs[256];
        int nr = kernel_data_regions(ra, rs, 256);
        std::vector<uint64_t> cur{obj}, next;
        std::unordered_map<uint64_t, char> seen;
        for (int d = 0; d < 7 && !cur.empty() && seen.size() < 60000; d++, cur.swap(next)) {
            next.clear();
            for (uint64_t o : cur)
                for (uint32_t off = 0; off < 0x800; off += 8) {
                    uint64_t p = LD64(o + off);
                    bool ok = false;
                    for (int k = 0; k < nr && !ok; k++) ok = p >= ra[k] && p + 0x800 > p && p + 0x800 <= ra[k] + rs[k];
                    if (!ok || !seen.emplace(p, 1).second) continue;
                    if (!strcmp((const char *)(uintptr_t)(p + 0xB0), names[i])) hits.push_back(p), LOG("[tracker] cycle: %s at depth %d (%zu seen)\n", names[i], d, seen.size());
                    next.push_back(p);
                }
        }
        LOG("[tracker] cycle frame %llu: hiding %s (%zu panes)\n", (unsigned long long)renderer_present_count(), names[i], hits.size());
    }
    for (uint64_t p : hits) ST8(p + 0x58, LD8(p + 0x58) & ~1);
}

static bool takeover_active(void);
static void map_page_takeover(uint64_t obj) {
    if (!obj) return;
    cycle_test(obj);
    bool on = takeover_active();
    static int tries;
    static uint64_t tried_at;
    uint64_t now = renderer_present_count();
    if (g_panes_for != obj) tries = 0, tried_at = 0;
    bool missing = false;
    for (int k = 0; k < NPANES; k++) missing |= !g_pane[k];
    missing |= g_brackets.size() < 3;
    // (a new page object: find its panes; parts of the page are built after it opens, so look again a few times)
    if (on && (g_panes_for != obj || (missing && tries < 8 && now - tried_at >= 60))) {
        pane_names();
        if (g_panes_for != obj)
            memset(g_pane, 0, sizeof g_pane), memset(g_hidden, 0, sizeof g_hidden), g_brackets.clear(), g_brackets_hidden.clear();
        uint64_t t0 = SDL_GetTicksNS();
        find_panes(obj);
        g_panes_for = obj, tries++, tried_at = now;
        LOG("[tracker] pane search %.1f ms\n", (SDL_GetTicksNS() - t0) / 1e6);
        int labels = 0;
        for (int k = PANE_LABEL0; k < NPANES; k++) labels += g_pane[k] != 0;
        LOG("[tracker] map page %llx: cursor %llx, button bar %llx, %d place names, %zu brackets (try %d)\n",
            (unsigned long long)obj, (unsigned long long)g_pane[PANE_CURSOR], (unsigned long long)g_pane[PANE_OPS], labels,
            g_brackets.size(), tries);
    }
    if (g_panes_for != obj) return;
    if (pane_ok(PANE_CURSOR)) {
        float *t = (float *)(uintptr_t)(g_pane[PANE_CURSOR] + 0x30);
        if (on) {
            if (t[0] < 50000) g_cursor_t[0] = t[0], g_cursor_t[1] = t[1];
            t[0] = t[1] = 100000.0f;  // (off the page)
            g_hidden[0] = true;
        } else if (g_hidden[0]) t[0] = g_cursor_t[0], t[1] = g_cursor_t[1], g_hidden[0] = false;
    }
    for (size_t i = 0; i < g_brackets.size(); i++) {
        uint64_t p = g_brackets[i];
        if (strcmp((const char *)(uintptr_t)(p + 0xB0), "W_Cursor_00")) continue;
        uint8_t fl = LD8(p + 0x58);
        if (on && (fl & 1)) ST8(p + 0x58, fl & ~1), g_brackets_hidden[i] = 1;
        else if (!on && g_brackets_hidden[i]) ST8(p + 0x58, fl | 1), g_brackets_hidden[i] = 0;
    }
    if (pane_ok(PANE_OPS)) {
        uint64_t p = g_pane[PANE_OPS];
        uint8_t fl = LD8(p + 0x58);
        if (on && (fl & 1)) ST8(p + 0x58, fl & ~1), g_hidden[1] = true;
        else if (!on && g_hidden[1]) ST8(p + 0x58, fl | 1), g_hidden[1] = false;
    }
}

static int g_label_align[21];
// a place name's position (default view, 1280x720 UI units) and whether the game shows it; false = not found
static bool label_pos(int id, ImVec2 *p, bool *shown) {
    int k = PANE_LABEL0 + id;
    if (id < 0 || id >= 21 || !pane_ok(k)) return false;
    const float *t = (const float *)(uintptr_t)(g_pane[k] + 0x30);
    if (!(fabsf(t[0]) < 2000 && fabsf(t[1]) < 2000)) return false;
    *p = ImVec2(640 + t[0], 360 - t[1]);
    g_label_align[id] = LD8(g_pane[k] + 0x5B) % 3;  // (base position, x: 0 centre, 1 left edge, 2 right edge)
    *shown = (LD8(g_pane[k] + 0x58) & 1) && LD8(g_pane[k] + 0x5A) > 0;
    return true;
}

// ---- drawing
static bool map_page_shown(void) {
    uint64_t f = g_map_frame;
    return f && renderer_present_count() - f <= 2;
}

extern "C" bool tracker_overlay_wanted(void) {
    if (!rando_seed_dir() || !g_settings.tracker || !map_page_shown()) return false;
    if (!g_loaded) load();
    return g_loaded > 0;
}

// status colours (best first: in logic, trick logic, needs an item, collected) and their text
static const ImU32 kStCol[4] = {IM_COL32(0x3F, 0xBF, 0x7F, 255), IM_COL32(0xA5, 0x8A, 0xF0, 255), IM_COL32(0xF2, 0xA3, 0x3A, 255),
                                IM_COL32(0x6F, 0x7C, 0x82, 255)};
static const ImU32 kStFg[4] = {IM_COL32(0x06, 0x20, 0x0F, 255), IM_COL32(0x17, 0x0C, 0x33, 255), IM_COL32(0x2A, 0x17, 0x02, 255),
                               IM_COL32(0xE7, 0xEC, 0xEE, 255)};
#define C_BG IM_COL32(0x0E, 0x1C, 0x24, 242)
#define C_INK IM_COL32(0x0E, 0x1C, 0x24, 255)
#define C_CARD IM_COL32(0x14, 0x2B, 0x36, 250)
#define C_LINE IM_COL32(0x23, 0x40, 0x4D, 255)
#define C_TEXT IM_COL32(0xF4, 0xEB, 0xD0, 255)
#define C_DIM IM_COL32(0xB9, 0xC4, 0xC8, 255)
#define C_GOLD IM_COL32(0xE8, 0xB8, 0x4A, 255)

static int filters(void) { return g_settings.tracker_filters >= 0 ? g_settings.tracker_filters : kDefaultFilters; }
static void set_filters(int f) { g_settings.tracker_filters = f; settings_save(); }

static const char *kind_label(int k) {
    static const char *const l[K_N] = {"Chests", "Heart pieces", "Seashells", "Bosses", "Shops", "Other", "Bushes", "Digs", "Pots"};
    int kind;
    bool owned;
    if (k == K_BOSS && souls_at(0, &kind, &owned)) return "Souls";  // (boss / mini-boss fights: their souls)
    return l[k];
}
static const char *kind_one(int k) {
    static const char *const l[K_N] = {"Chest", "Heart piece", "Seashell", "Boss", "Shop", "Item", "Bush", "Dig", "Pot"};
    return l[k];
}

// per-frame model
namespace {
struct Row { int check, st; };
struct Badge { int open, total, done, best; float x, y; };  // best = the best status among the counted open checks
}  // namespace
static std::unordered_map<int, std::vector<int>> g_screen_checks;  // screen (row * 16 + col) -> its checks
static std::vector<std::vector<int>> g_group_checks;                // dungeon icon -> its checks
static std::vector<std::vector<int>> g_area_checks;                 // place name (T_MapName_NN) -> its checks
static bool g_indexed;
static void index_reset(void) { g_screen_checks.clear(), g_group_checks.clear(), g_status.clear(), g_indexed = false; }

static void build_index(void) {
    g_screen_checks.clear();
    g_group_checks.assign(g_groups.size(), {});
    for (int i = 0; i < (int)g_checks.size(); i++) {
        const Check &c = g_checks[i];
        if (c.group >= 0 && c.group < (int)g_groups.size()) { g_group_checks[c.group].push_back(i); continue; }
        int col = std::min(15, std::max(0, (int)c.x)), row = std::min(15, std::max(0, (int)c.y));
        g_screen_checks[row * 16 + col].push_back(i);
    }
    g_indexed = true;
}

static void update_status(void) {
    solve(true);
    g_acc_trick = g_acc;
    solve(false);
    solve_costs();
    g_status.assign(g_checks.size(), ST_NEEDS);
    for (size_t i = 0; i < g_checks.size(); i++) {
        const Check &c = g_checks[i];
        if (flag_set(c.flag)) g_status[i] = ST_DONE;
        else if (A(c.node) > 0) g_status[i] = ST_LOGIC;
        else if (c.node < (int)g_acc_trick.size() && g_acc_trick[c.node] > 0) g_status[i] = ST_TRICK;
    }
}

static std::string needs_text(int check) {
    int n = g_checks[check].node;
    if (n >= (int)g_cost.size() || g_cost[n].inf || g_cost[n].miss.empty()) return "out of logic";
    std::string s = "needs ";
    for (size_t i = 0; i < g_cost[n].miss.size(); i++) {
        int32_t m = g_cost[n].miss[i];
        if (i) s += " + ";
        s += item_name(m & 0xFFFFF, m >> 20);
    }
    return s;
}

static Badge badge_of(const std::vector<int> &list, int f) {
    Badge b{0, 0, 0, ST_DONE, 0, 0};
    for (int i : list) {
        if (!(f >> g_checks[i].kind & 1)) continue;
        b.total++;
        int st = g_status[i];
        if (st == ST_DONE) { b.done++; continue; }
        if ((f & F_IN_LOGIC) && st != ST_LOGIC) continue;
        b.open++;
        b.best = std::min(b.best, st);
    }
    return b;
}

static std::string screen_title(const std::vector<int> &list) {
    std::unordered_map<std::string, int> n;
    std::string best;
    int bn = 0;
    for (int i : list) {
        const std::string &a = g_checks[i].area;
        if (a.empty()) continue;
        if (++n[a] > bn) bn = n[a], best = a;
    }
    return best.empty() ? "Overworld" : area_name(best);
}

static ImVec2 text_size(ImFont *font, float fs, const char *t) { return font->CalcTextSizeA(fs, FLT_MAX, 0, t); }

// game-styled drawing: parchment panels (the map's own paper and brown ink), white prompt text with a shadow and
// round button glyphs (the pause menu's button row)
#define P_PARCH IM_COL32(0xF1, 0xE4, 0xC0, 246)
#define P_PARCH_LT IM_COL32(0xFA, 0xF2, 0xDC, 255)
#define P_PARCH_DK IM_COL32(0xE2, 0xCC, 0x96, 255)
#define P_BROWN IM_COL32(0x6B, 0x4A, 0x22, 255)
#define P_LINE IM_COL32(0xB8, 0x98, 0x60, 255)
#define P_GOLD IM_COL32(0xD9, 0x9A, 0x1E, 255)
#define P_INK IM_COL32(0x3B, 0x2A, 0x14, 255)
#define P_INK_DIM IM_COL32(0x6E, 0x58, 0x3A, 255)
#define P_INK_FADED IM_COL32(0x9C, 0x8A, 0x6C, 255)
#define P_GREEN IM_COL32(0x1F, 0x7A, 0x45, 255)
#define P_AMBER IM_COL32(0xA8, 0x5E, 0x06, 255)
#define P_PURPLE IM_COL32(0x5B, 0x3F, 0xB0, 255)
static void parchment(ImDrawList *dl, ImVec2 a, ImVec2 z, float u) {
    dl->AddRectFilled(ImVec2(a.x + 3 * u, a.y + 4 * u), ImVec2(z.x + 3 * u, z.y + 4 * u), IM_COL32(0, 0, 0, 70), 12 * u);
    dl->AddRectFilled(a, z, P_PARCH, 12 * u);
    dl->AddRect(a, z, P_BROWN, 12 * u, 0, 2.5f * u);
    dl->AddRect(ImVec2(a.x + 5 * u, a.y + 5 * u), ImVec2(z.x - 5 * u, z.y - 5 * u), P_LINE, 8 * u, 0, 1 * u);
}
static void shadow_text(ImDrawList *dl, ImFont *font, float fs, ImVec2 p, const char *t, float u) {
    dl->AddText(font, fs, ImVec2(p.x + 1.6f * u, p.y + 1.6f * u), IM_COL32(40, 25, 5, 170), t);
    dl->AddText(font, fs, p, IM_COL32(255, 255, 255, 255), t);
}
static float prompt_width(ImFont *font, float fs, const char *btn, const char *label) {
    float g = strlen(btn) > 1 ? fs * 1.45f : fs * 1.0f;
    return g + 6 + text_size(font, fs, label).x;
}
static float draw_prompt(ImDrawList *dl, ImFont *font, float fs, ImVec2 p, const char *btn, const char *label, float u) {
    float g = strlen(btn) > 1 ? fs * 1.45f : fs * 1.0f, r = fs * 0.5f;
    ImVec2 c(p.x + g * 0.5f, p.y + fs * 0.55f);
    if (strlen(btn) > 1) {
        dl->AddRectFilled(ImVec2(p.x, c.y - r), ImVec2(p.x + g, c.y + r), IM_COL32(40, 25, 5, 120), r);
        dl->AddRectFilled(ImVec2(p.x - 1, c.y - r - 1), ImVec2(p.x + g - 1, c.y + r - 1), IM_COL32(255, 255, 255, 255), r);
    } else {
        dl->AddCircleFilled(ImVec2(c.x + 1.5f * u, c.y + 1.5f * u), r, IM_COL32(40, 25, 5, 120));
        dl->AddCircleFilled(c, r, IM_COL32(255, 255, 255, 255));
    }
    float bs = fs * (strlen(btn) > 1 ? 0.62f : 0.72f);
    ImVec2 bt = text_size(font, bs, btn);
    dl->AddText(font, bs, ImVec2(c.x - bt.x * 0.5f - (strlen(btn) > 1 ? 1 : 0), c.y - bt.y * 0.5f), IM_COL32(60, 45, 25, 255), btn);
    shadow_text(dl, font, fs, ImVec2(p.x + g + 6 * u, p.y), label, u);
    return g + 6 * u + text_size(font, fs, label).x;
}

extern "C" void tracker_overlay_draw(ImVec2 display, ImFont *font) {
    uint64_t now = renderer_present_count();
    UiState &ui = g_ui;
    if (!g_indexed) build_index();
    bool reopened = now - g_map_opened < 2;
    if (reopened || ui.last_solve == ~0ull || now - ui.last_solve > 30) {  // re-solve when (re)opened, then every 0.5 s
        update_status();
        if (ui.last_solve == ~0ull) debug_dump();
        ui.last_solve = now;
    }
    if (reopened) ui.panel = false, ui.filter_focus = false, g_vanilla = false;  // (reopened: the map, no panel)
    g_avail_frame = now;
    // the game's UI is a centred 16:9 box; the island parchment spans (187,123)-(1096,630) of 1280x720 = 16x16 screens
    float bw = fminf(display.x, display.y * 16.0f / 9.0f), bh = bw * 9.0f / 16.0f;
    float ox = (display.x - bw) * 0.5f, oy = (display.y - bh) * 0.5f, u = bw / 1280.0f;
    // zoom / scroll: the map content pane N_MapCore_00 (map page object + 0x640) has local translate (+0x30, layout
    // units, y up, origin = screen centre) and scale (+0x48); at the default view they are (0,0) and 1
    float mtx = 0, mty = 0, msc = 1;
    if (uint64_t pane = g_map_obj ? LD64(g_map_obj + 0x640) : 0) {
        if (!memcmp((const void *)(uintptr_t)(pane + 0xB0), "N_MapCore", 9)) {
            mtx = *(float *)(uintptr_t)(pane + 0x30);
            mty = *(float *)(uintptr_t)(pane + 0x34);
            msc = *(float *)(uintptr_t)(pane + 0x48);
            if (!(msc > 0.1f && msc < 20)) { mtx = mty = 0; msc = 1; }
        }
    }
    auto ui_pt = [](float cx, float cy) { return ImVec2(187 + cx * (909.0f / 16), 123 + cy * (507.0f / 16)); };  // default view
    auto to_screen = [&](ImVec2 p) {
        float sx = 640 + mtx + msc * (p.x - 640);
        float sy = 360 - (mty + msc * (360 - p.y));
        return ImVec2(ox + sx * u, oy + sy * u);
    };
    auto R = [&](float x0, float y0, float x1, float y1) { return ImVec4(ox + x0 * u, oy + y0 * u, ox + x1 * u, oy + y1 * u); };
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    if (g_vanilla) {  // the game's own map: only a way back, left of the game's own button row
        draw_prompt(dl, font, 19 * u, ImVec2(ox + 64 * u, oy + 668 * u), "ZR", "Tracker", u);
        g_panel_open = false, g_filter_open = false;
        return;
    }
    g_draw_frame = now;
    ImGuiIO &io = ImGui::GetIO();
    ImVec2 mouse = io.MousePos;
    bool click = ImGui::IsMouseClicked(0), rclick = ImGui::IsMouseClicked(1);
    static ImVec2 last_mouse;
    bool mouse_moved = fabsf(mouse.x - last_mouse.x) + fabsf(mouse.y - last_mouse.y) > 2;
    last_mouse = mouse;
    int f = filters();
    float zs = msc > 1 ? fminf(msc, 1.5f) : 1.0f;  // (badges grow a little with the zoom)

    // ---- areas: the game's place names (T_MapName_NN). Each Field screen belongs to the nearest name on the island
    // (default view); a screen's checks (interiors at their door) count for its area
    static const char *const kLabel[21] = {"Kanalet Castle", "Rapids Ride", "Southern Face Shrine", "Animal Village",
                                           "Yarna Desert", "", "Martha's Bay", "Pothole Field", "", "", "Mabe Village",
                                           "Mysterious Forest", "Goponga Swamp", "Koholint Prairie", "Tabahl Wasteland",
                                           "Tal Tal Mountain Range", "Mt. Tamaranch", "Tal Tal Heights", "Toronbo Shores",
                                           "Ukuku Prairie", "Cemetery"};
    ImVec2 lp[21];
    bool lhave[21] = {}, lshown[21] = {};
    int nlabels = 0;
    // the game draws the names ~22 layout units tall: "Tal Tal Heights" is 135 wide
    float name_k = 135.0f / std::max(1.0f, text_size(font, 1, "Tal Tal Heights").x);
    float lw[21] = {};
    for (int i = 0; i < 21; i++)
        if (kLabel[i][0] && label_pos(i, &lp[i], &lshown[i])) {  // (lp: the name's centre)
            lhave[i] = true, nlabels++;
            lw[i] = name_k * text_size(font, 1, kLabel[i]).x;
            if (g_label_align[i] == 1) lp[i].x += lw[i] * 0.5f;
            else if (g_label_align[i] == 2) lp[i].x -= lw[i] * 0.5f;
        }
    std::vector<std::vector<int>> &area_checks = g_area_checks;
    area_checks.assign(21, {});
    bool by_place = false;  // (tracker.tsv names each check's place; older ones: the nearest name)
    for (auto &c : g_checks) by_place |= c.place >= 0;
    if (by_place) {
        for (auto &e : g_screen_checks)
            for (int k : e.second) if (g_checks[k].place >= 0) area_checks[g_checks[k].place].push_back(k);
    } else if (nlabels)
        for (auto &e : g_screen_checks) {
            ImVec2 c = ui_pt((e.first % 16) + 0.5f, (e.first / 16) + 0.5f);
            int best = -1;
            float bd = 1e9f;
            for (int i = 0; i < 21; i++)
                if (lhave[i]) {
                    float d = hypotf(lp[i].x - c.x, lp[i].y - c.y);
                    if (d < bd) bd = d, best = i;
                }
            for (int k : e.second) area_checks[best].push_back(k);
        }
    // ---- bullets beside the names and dungeon icons = the cursor's targets (areas first, then dungeons)
    const ImVec4 clip = R(60, 112, 1222, 640);
    std::vector<Target> targets;
    std::vector<Badge> badges;
    float br = 10.5f * u * zs;
    for (int i = 0; i < 21; i++) {
        if (!lhave[i] || area_checks[i].empty()) continue;
        Badge b = badge_of(area_checks[i], f);
        if (!b.total || !b.open) continue;  // (nothing open under the filters here)
        b.x = lp[i].x + lw[i] * 0.5f + 8 + 11.5f, b.y = lp[i].y;  // (beside the name: never over it)
        targets.push_back({0, i, b.x, b.y});
        badges.push_back(b);
    }
    std::vector<Badge> dbadges(g_groups.size());
    for (size_t g = 0; g < g_groups.size(); g++) {
        ImVec2 p = ui_pt(g_groups[g].x, g_groups[g].y);
        Badge b = badge_of(g_group_checks[g], (1 << K_N) - 1);  // (an icon counts all its checks)
        for (int i = 0; i < 21; i++)  // (over a place name: to the left of the name)
            if (lhave[i] && fabsf(p.x - lp[i].x) < lw[i] * 0.5f + 16 && fabsf(p.y - lp[i].y) < 11 + 16) p.x = lp[i].x - lw[i] * 0.5f - 18;
        b.x = p.x, b.y = p.y;
        dbadges[g] = b;
        targets.push_back({1, (int)g, p.x, p.y});
    }
    // the cursor: kept on its target; else the area nearest Link's screen (PlayerStatus +0x40, e.g. "11C" on the
    // Field) or the map's centre
    auto find_target = [&](int type, int id) -> int {
        for (size_t i = 0; i < targets.size(); i++) if (targets[i].type == type && targets[i].id == id) return (int)i;
        return -1;
    };
    int cur = find_target(ui.sel_type, ui.sel_id);
    if (cur < 0 && !targets.empty()) {
        ImVec2 want = ui_pt(8, 8);
        uint64_t ps = LD64(GA_PLAYER_STATUS_PTR);
        if (ps && !strcmp((const char *)(uintptr_t)ps, "Field")) {
            const char *r = (const char *)(uintptr_t)(ps + 0x40);
            if (isdigit((unsigned char)r[0]) && isdigit((unsigned char)r[1]) && r[2] >= 'A' && r[2] <= 'P')
                want = ui_pt(r[2] - 'A' + 0.5f, (r[0] - '0') * 10 + (r[1] - '0') - 0.5f);
        }
        float bd = 1e9f;
        for (size_t i = 0; i < targets.size(); i++) {
            float d = hypotf(targets[i].x - want.x, targets[i].y - want.y);
            if (d < bd) bd = d, cur = (int)i;
        }
        ui.sel_type = targets[cur].type, ui.sel_id = targets[cur].id;
    }

    // ---- the filters: the two switches, then one toggle per kind of check in the seed
    struct Chip { int bit; std::string label; };
    std::vector<Chip> chips;
    chips.push_back({F_IN_LOGIC, "In logic now"});
    chips.push_back({F_HIDE_DONE, "Hide checked"});
    for (int k = 0; k < K_N; k++) if (g_kind_present[k]) chips.push_back({1 << k, kind_label(k)});
    if (ui.chip >= (int)chips.size()) ui.chip = (int)chips.size() - 1;

    auto panel_list = [&](int type, int id) -> const std::vector<int> * {
        if (type == 0) return id >= 0 && id < 21 ? &area_checks[id] : nullptr;
        return id >= 0 && id < (int)g_group_checks.size() ? &g_group_checks[id] : nullptr;
    };
    auto title_of = [&](int type, int id) -> std::string {
        if (type == 0) return id >= 0 && id < 21 ? kLabel[id] : "";
        return std::string(dungeon_name(g_groups[id].label)) + " (" + g_groups[id].label + ")";
    };
    auto open_panel = [&](int type, int id) {
        ui.panel = true, ui.panel_type = type, ui.panel_id = id, ui.panel_row = 0, ui.panel_scroll = 0;
        ui.filter_focus = false, ui.spot = -1;
    };
    // the panel's rows: open in logic, needs an item, trick logic, collected (struck out, last)
    std::vector<Row> rows;
    auto build_rows = [&]() {
        rows.clear();
        const std::vector<int> *list = ui.panel || ui.spot >= 0 ? panel_list(ui.panel_type, ui.panel_id) : nullptr;
        if (!list) return;
        static const int order[4] = {0, 2, 1, 3};  // (by St: logic 0, trick 2, needs 1, done 3)
        for (int i : *list) rows.push_back({i, g_status[i]});
        std::stable_sort(rows.begin(), rows.end(), [](const Row &a, const Row &b) {
            return order[a.st] != order[b.st] ? order[a.st] < order[b.st] : g_checks[a.check].name < g_checks[b.check].name;
        });
    };
    build_rows();

    // ---- controller events
    for (uint32_t r = g_evr.load(); r != g_evw.load(); r = g_evr.load()) {
        uint32_t ev = g_evq[r & 63];
        g_evr.store(r + 1);
        int kind = ev & 0xff;
        if (kind == EV_NAV) {
            float a = (float)(ev >> 8) * 0.0174533f, dx = cosf(a), dy = -sinf(a);  // (UI y grows down)
            if (ui.spot >= 0) {
            } else if (ui.panel) {
                if (fabsf(dy) > fabsf(dx)) ui.panel_row += dy > 0 ? 1 : -1;
            } else if (ui.filter_focus) {
                if (fabsf(dy) > fabsf(dx)) ui.chip = (ui.chip + (dy > 0 ? 1 : (int)chips.size() - 1)) % (int)chips.size();
            } else if (cur >= 0) {
                // the nearest target in that direction: distance along it + twice the sideways offset, within ~65 deg
                // (then any target on that side)
                const Target &c = targets[cur];
                int best = -1;
                float bs = 1e9f;
                for (int pass = 0; pass < 2 && best < 0; pass++)
                    for (size_t i = 0; i < targets.size(); i++) {
                        if ((int)i == cur) continue;
                        float vx = targets[i].x - c.x, vy = targets[i].y - c.y;
                        float along = vx * dx + vy * dy, side = fabsf(vx * dy - vy * dx);
                        if (along <= 1 || (pass == 0 && side > along * 2.2f)) continue;
                        float s = along + (pass == 0 ? 2 : 4) * side;
                        if (s < bs) bs = s, best = (int)i;
                    }
                if (best >= 0) cur = best, ui.sel_type = targets[best].type, ui.sel_id = targets[best].id;
            }
        } else if (kind == EV_A) {
            if (ui.filter_focus) set_filters(f ^ chips[ui.chip].bit), f = filters();
            else if (ui.panel && ui.panel_row >= 0 && ui.panel_row < (int)rows.size()) ui.spot = rows[ui.panel_row].check, ui.panel = false;
            else if (!ui.panel && ui.spot < 0 && cur >= 0) open_panel(targets[cur].type, targets[cur].id), build_rows();
        } else if (kind == EV_B) {
            if (ui.spot >= 0) ui.spot = -1, ui.panel = true;  // (back to the list)
            else if (ui.panel) ui.panel = false;
            else ui.filter_focus = false;
        } else if (kind == EV_Y) {
            if (ui.spot < 0 && !ui.panel) ui.filter_focus = !ui.filter_focus;
        }
    }

    // ---- the map layer
    dl->PushClipRect(ImVec2(clip.x, clip.y), ImVec2(clip.z, clip.w), true);
    int hover = -1;
    for (size_t i = 0; i < badges.size(); i++) {
        const Badge &b = badges[i];
        ImVec2 p = to_screen(ImVec2(b.x, b.y));
        int st = b.best;
        dl->AddCircleFilled(ImVec2(p.x + 1.5f * u, p.y + 2 * u), br + 2 * u, IM_COL32(40, 25, 5, 90));
        dl->AddCircleFilled(p, br + 2 * u, P_BROWN);
        dl->AddCircleFilled(p, br, kStCol[st]);
        char txt[8];
        snprintf(txt, sizeof txt, "%d", b.open);
        float fs = (b.open > 9 ? 13.0f : 15.0f) * u * zs;
        ImVec2 ts = text_size(font, fs, txt);
        dl->AddText(font, fs, ImVec2(p.x - ts.x * 0.5f, p.y - ts.y * 0.5f), kStFg[st], txt);
        if (hypotf(mouse.x - p.x, mouse.y - p.y) < br * 1.4f) hover = (int)i;
    }
    for (size_t g = 0; g < g_groups.size(); g++) {
        const Badge &b = dbadges[g];
        ImVec2 p = to_screen(ImVec2(b.x, b.y));
        float s = 13 * u * zs;
        ImVec2 a(p.x - s, p.y - s), z(p.x + s, p.y + s);
        dl->AddRectFilled(ImVec2(a.x + 1.5f * u, a.y + 2 * u), ImVec2(z.x + 1.5f * u, z.y + 2 * u), IM_COL32(40, 25, 5, 90), 5 * u);
        dl->AddRectFilled(a, z, P_PARCH_LT, 5 * u);
        dl->AddRect(a, z, P_BROWN, 5 * u, 0, 2.2f * u);
        const std::string &lab = g_groups[g].label;
        const char *num = lab.size() == 2 && lab[0] == 'D' ? lab.c_str() + 1 : lab.c_str();
        float fs = 17 * u * zs;
        ImVec2 ts = text_size(font, fs, num);
        dl->AddText(font, fs, ImVec2(p.x - ts.x * 0.5f, p.y - ts.y * 0.5f), P_INK, num);
        if (b.open && (!(f & F_IN_LOGIC) || b.best == ST_LOGIC)) {  // the best open check inside
            dl->AddCircleFilled(ImVec2(z.x - 1 * u, a.y + 1 * u), 5.5f * u, P_BROWN);
            dl->AddCircleFilled(ImVec2(z.x - 1 * u, a.y + 1 * u), 4 * u, kStCol[b.best]);
        }
        char cnt[16];
        snprintf(cnt, sizeof cnt, "%d/%d", b.done, b.total);
        float cs = 12 * u;
        ImVec2 ct = text_size(font, cs, cnt);
        ImVec2 ca(p.x - ct.x * 0.5f - 4 * u, z.y + 1.5f * u);
        dl->AddRectFilled(ca, ImVec2(ca.x + ct.x + 8 * u, ca.y + ct.y + 1 * u), P_PARCH_LT, ct.y);
        dl->AddRect(ca, ImVec2(ca.x + ct.x + 8 * u, ca.y + ct.y + 1 * u), P_LINE, ct.y, 0, 1 * u);
        dl->AddText(font, cs, ImVec2(ca.x + 4 * u, ca.y), P_INK, cnt);
        if (mouse.x >= a.x && mouse.x <= z.x && mouse.y >= a.y && mouse.y <= z.y) hover = (int)(badges.size() + g);
    }
    if (cur >= 0 && !ui.filter_focus && ui.spot < 0) {  // the cursor
        ImVec2 p = to_screen(ImVec2(targets[cur].x, targets[cur].y));
        float pulse = 1.0f + 0.12f * sinf((float)now * 0.12f);
        if (targets[cur].type == 0) {
            dl->AddCircle(p, (br + 6 * u) * pulse, P_BROWN, 0, 5 * u);
            dl->AddCircle(p, (br + 6 * u) * pulse, IM_COL32(0xFF, 0xE0, 0x6A, 255), 0, 3 * u);
        } else {
            float s = (13 * u * zs + 6 * u) * pulse;
            dl->AddRect(ImVec2(p.x - s, p.y - s), ImVec2(p.x + s, p.y + s), P_BROWN, 7 * u, 0, 5 * u);
            dl->AddRect(ImVec2(p.x - s, p.y - s), ImVec2(p.x + s, p.y + s), IM_COL32(0xFF, 0xE0, 0x6A, 255), 7 * u, 0, 3 * u);
        }
    }
    if (ui.spot >= 0) {  // A in the list: that check's spot (its screen; a dungeon check: the dungeon's door)
        const Check &c = g_checks[ui.spot];
        ImVec2 p = to_screen(c.group >= 0 && c.group < (int)g_groups.size() ? ui_pt(g_groups[c.group].x, g_groups[c.group].y)
                                                                              : ui_pt(c.x, c.y));
        float rr = (16 + 4 * sinf((float)now * 0.15f)) * u * zs;
        dl->AddCircle(p, rr, P_BROWN, 0, 6 * u);
        dl->AddCircle(p, rr, IM_COL32(0xFF, 0xE0, 0x6A, 255), 0, 3.5f * u);
        dl->AddCircleFilled(p, 4 * u, kStCol[g_status[ui.spot]]);
    }
    dl->PopClipRect();
    bool mouse_on_ui = false;
    if (!ui.panel && ui.spot < 0 && hover >= 0 && mouse.x >= clip.x && mouse.x <= clip.z && mouse.y >= clip.y && mouse.y <= clip.w) {
        mouse_on_ui = true;  // hovering moves the cursor (when the mouse moved), a click opens
        if (mouse_moved || click) cur = hover, ui.sel_type = targets[hover].type, ui.sel_id = targets[hover].id, ui.filter_focus = false;
        if (click) open_panel(targets[hover].type, targets[hover].id), build_rows(), click = false;
    }

    // ---- counts: the cursor's target and the whole seed (the kinds shown)
    int n_sel[4] = {0, 0, 0, 0}, n_sel_all = 0;
    std::string sel_name;
    if (cur >= 0) {
        const std::vector<int> *list = panel_list(targets[cur].type, targets[cur].id);
        if (list) for (int i : *list) n_sel[g_status[i]]++, n_sel_all++;
        sel_name = title_of(targets[cur].type, targets[cur].id);
    }
    if (ui.spot >= 0) sel_name = g_checks[ui.spot].title.empty() ? pretty(g_checks[ui.spot].name) : g_checks[ui.spot].title, n_sel_all = 0;
    int run_logic = 0, run_done = 0, run_all = 0;
    for (size_t i = 0; i < g_checks.size(); i++) {
        if (!(f >> g_checks[i].kind & 1)) continue;
        run_all++;
        run_done += g_status[i] == ST_DONE;
        run_logic += g_status[i] == ST_LOGIC;
    }
    int tri_have = 0, tri_need = 0;
    bool tri = triforce_counts(&tri_have, &tri_need);
    float pfs = 19 * u;  // (the game's button prompts' size)

    // one filter row: a check box and its label (game-styled, on parchment); mouse toggles
    auto filter_row = [&](size_t i, ImVec2 a, float w, float h, float fs) {
        const Chip &c = chips[i];
        bool on = f & c.bit, focus = ui.filter_focus && (int)i == ui.chip;
        ImVec2 z(a.x + w, a.y + h);
        if (focus) {
            dl->AddRectFilled(a, z, P_PARCH_DK, 5 * u);
            dl->AddRect(a, z, P_GOLD, 5 * u, 0, 2 * u);
        }
        float bx = a.x + 8 * u, by = a.y + h * 0.5f, bs = h * 0.28f;
        dl->AddRectFilled(ImVec2(bx, by - bs), ImVec2(bx + 2 * bs, by + bs), P_PARCH_LT, 2 * u);
        dl->AddRect(ImVec2(bx, by - bs), ImVec2(bx + 2 * bs, by + bs), P_BROWN, 2 * u, 0, 1.5f * u);
        if (on) {  // a tick
            dl->AddLine(ImVec2(bx + bs * 0.4f, by), ImVec2(bx + bs * 0.9f, by + bs * 0.6f), P_GREEN, 2.4f * u);
            dl->AddLine(ImVec2(bx + bs * 0.9f, by + bs * 0.6f), ImVec2(bx + bs * 1.7f, by - bs * 0.7f), P_GREEN, 2.4f * u);
        }
        ImVec2 ts = text_size(font, fs, c.label.c_str());
        dl->AddText(font, fs, ImVec2(bx + 2 * bs + 8 * u, by - ts.y * 0.5f), P_INK, c.label.c_str());
        if (mouse.x >= a.x && mouse.x <= z.x && mouse.y >= a.y && mouse.y <= z.y) {
            mouse_on_ui = true;
            if (mouse_moved && ui.filter_focus) ui.chip = (int)i;
            if (click) set_filters(f ^ c.bit), f = filters(), click = false;
        }
    };
    const char *filter_word = (f & F_IN_LOGIC) ? "In logic now" : (f & F_HIDE_DONE) ? "Hide checked" : "Everything";

    // ---- one line where the game's own button prompts were (L_Operation_00, hidden): the cursor's area and the run's
    // totals on the left, the prompts on the right; Y opens a filter panel
    float y = oy + 668 * u;
    std::vector<std::pair<const char *, std::string>> pr;
    if (ui.panel) pr = {};
    else if (ui.spot >= 0) pr = {{"B", "Back to the list"}};
    else if (ui.filter_focus) pr = {{"A", "Toggle"}, {"Y", "Close"}};
    else pr = {{"Y", std::string("Filter: ") + filter_word}, {"A", "Open"}, {"ZR", "Game map"}};
    float pw = 0;
    for (auto &p : pr) pw += prompt_width(font, pfs, p.first, p.second.c_str()) + 22 * u;
    float px = ox + 1226 * u - pw;
    for (auto &p : pr) px += draw_prompt(dl, font, pfs, ImVec2(px, y), p.first, p.second.c_str(), u) + 22 * u;
    char info[200];
    int k = 0;
    if (ui.spot >= 0) {
        int st = g_status[ui.spot];
        std::string t = st == ST_LOGIC ? "in logic" : st == ST_TRICK ? "trick logic" : st == ST_NEEDS ? needs_text(ui.spot) : "collected";
        k = snprintf(info, sizeof info, "%s   %s     ", sel_name.c_str(), t.c_str());
    } else if (!sel_name.empty() && !ui.panel) {
        k = snprintf(info, sizeof info, "%s   %d in logic", sel_name.c_str(), n_sel[ST_LOGIC]);
        if (n_sel[ST_TRICK] && k < (int)sizeof info) k += snprintf(info + k, sizeof info - k, ", %d trick", n_sel[ST_TRICK]);
        if (n_sel[ST_NEEDS] && k < (int)sizeof info) k += snprintf(info + k, sizeof info - k, ", %d need an item", n_sel[ST_NEEDS]);
        if (k < (int)sizeof info) k += snprintf(info + k, sizeof info - k, ", %d/%d     ", n_sel[ST_DONE], n_sel_all);
    }
    if (k < (int)sizeof info) k += snprintf(info + k, sizeof info - k, "All: %d in logic, %d/%d", run_logic, run_done, run_all);
    if (tri && k < (int)sizeof info) snprintf(info + k, sizeof info - k, ", Triforce %d/%d", tri_have, tri_need);
    float x0 = ox + 64 * u, room = px - pw - x0 - 24 * u;
    (void)room;
    dl->PushClipRect(ImVec2(x0, y - 4 * u), ImVec2(ox + 1226 * u - pw - 16 * u, y + 40 * u), true);
    shadow_text(dl, font, pfs * 0.92f, ImVec2(x0, y + pfs * 0.04f), info, u);
    dl->PopClipRect();
    if (ui.filter_focus) {  // the filter panel, over the map
        float w = 300 * u, rh = 30 * u, h = 56 * u + rh * chips.size() + 14 * u;
        ImVec2 a(ox + 640 * u - w * 0.5f, oy + 380 * u - h * 0.5f), z(a.x + w, a.y + h);
        parchment(dl, a, z, u);
        if (mouse.x >= a.x && mouse.x <= z.x && mouse.y >= a.y && mouse.y <= z.y) mouse_on_ui = true;
        dl->AddText(font, 24 * u, ImVec2(a.x + 20 * u, a.y + 14 * u), P_INK, "Filters");
        for (size_t i = 0; i < chips.size(); i++) {
            if (i == 2) dl->AddLine(ImVec2(a.x + 18 * u, a.y + 52 * u + rh * 2 + 0.5f), ImVec2(z.x - 18 * u, a.y + 52 * u + rh * 2 + 0.5f), P_LINE, 1.2f * u);
            filter_row(i, ImVec2(a.x + 12 * u, a.y + 52 * u + rh * i + (i >= 2 ? 6 * u : 0)), w - 24 * u, rh - 2 * u, 18 * u);
        }
        if (click && !mouse_on_ui) ui.filter_focus = false;
    }

    // ---- the area panel (one list by status): parchment, gold border, brown ink, centred over the dimmed map
    if (ui.panel) {
        if (rows.empty() && !panel_list(ui.panel_type, ui.panel_id)) ui.panel = false;
        else {
            int done = 0;
            for (auto &r : rows) done += r.st == ST_DONE;
            std::string title = title_of(ui.panel_type, ui.panel_id);
            char sub[64], filt[64];
            snprintf(sub, sizeof sub, "%d / %d collected", done, (int)rows.size());
            snprintf(filt, sizeof filt, "Filter: %s", filter_word);
            ui.panel_row = std::max(0, std::min(ui.panel_row, (int)rows.size() - 1));
            dl->AddRectFilled(ImVec2(ox + 187 * u, oy + 123 * u), ImVec2(ox + 1096 * u, oy + 630 * u), IM_COL32(40, 25, 5, 110), 6 * u);  // (the map, dimmed)
            ImVec2 a(ox + 260 * u, oy + 120 * u), z(ox + 1020 * u, oy + 636 * u);
            dl->AddRectFilled(ImVec2(a.x + 4 * u, a.y + 6 * u), ImVec2(z.x + 4 * u, z.y + 6 * u), IM_COL32(0, 0, 0, 80), 16 * u);
            dl->AddRectFilled(ImVec2(a.x - 3 * u, a.y - 3 * u), ImVec2(z.x + 3 * u, z.y + 3 * u), IM_COL32(0x4A, 0x30, 0x20, 255), 18 * u);
            dl->AddRectFilled(a, z, IM_COL32(0xF3, 0xE6, 0xC6, 255), 16 * u);
            dl->AddRect(a, z, IM_COL32(0xC8, 0x9B, 0x3C, 255), 16 * u, 0, 4 * u);
            bool in_panel = mouse.x >= a.x && mouse.x <= z.x && mouse.y >= a.y && mouse.y <= z.y;
            float x = a.x + 34 * u, y = a.y + 22 * u;
            float fs_t = 32 * u, fs_s = 18 * u, fs_r = 17 * u, fs_w = 14 * u, fs_k = 13 * u;
            ImU32 ink = IM_COL32(0x3B, 0x26, 0x14, 255), ink2 = IM_COL32(0x6B, 0x4E, 0x2E, 255), gold = IM_COL32(0xC8, 0x9B, 0x3C, 255);
            dl->AddText(font, fs_t, ImVec2(x, y), ink, title.c_str());
            ImVec2 tt = text_size(font, fs_t, title.c_str());
            float base = y + tt.y * 0.78f;
            dl->AddText(font, fs_s, ImVec2(x + tt.x + 14 * u, base - text_size(font, fs_s, sub).y * 0.78f), ink2, sub);
            ImVec2 ft = text_size(font, fs_w, filt);
            dl->AddText(font, fs_w, ImVec2(z.x - 34 * u - ft.x, base - ft.y * 0.78f), ink2, filt);
            y += tt.y + 10 * u;
            dl->AddRectFilled(ImVec2(x, y), ImVec2(z.x - 34 * u, y + 2 * u), gold);
            y += 12 * u;
            float rh = 38 * u, top = y, bottom = z.y - 52 * u;
            int vis = std::max(1, (int)((bottom - top) / rh));
            if (ui.panel_row < (int)ui.panel_scroll) ui.panel_scroll = (float)ui.panel_row;
            if (ui.panel_row >= (int)ui.panel_scroll + vis) ui.panel_scroll = (float)(ui.panel_row - vis + 1);
            if (in_panel && io.MouseWheel != 0)
                ui.panel_scroll = std::max(0.0f, std::min((float)std::max(0, (int)rows.size() - vis), ui.panel_scroll - io.MouseWheel));
            static const ImU32 dot[4] = {IM_COL32(0x2E, 0x9B, 0x5F, 255), IM_COL32(0x7E, 0x5F, 0xD0, 255), IM_COL32(0xD9, 0x82, 0x1F, 255),
                                         IM_COL32(0x9A, 0x8A, 0x72, 255)};
            dl->PushClipRect(ImVec2(a.x, top - 4 * u), ImVec2(z.x, bottom), true);
            for (int i = (int)ui.panel_scroll; i < (int)rows.size() && i < (int)ui.panel_scroll + vis + 1; i++) {
                const Row &r = rows[i];
                const Check &c = g_checks[r.check];
                float ry = top + (i - ui.panel_scroll) * rh;
                ImVec2 ra(x - 6 * u, ry), rz(z.x - 28 * u, ry + rh - 6 * u);
                bool sel = i == ui.panel_row;
                dl->AddRectFilled(ra, rz, sel ? IM_COL32(0xFF, 0xF6, 0xDD, 255) : IM_COL32(0xEA, 0xD9, 0xB0, 255), 10 * u);
                if (sel) dl->AddRect(ra, rz, IM_COL32(0x4A, 0x30, 0x20, 255), 10 * u, 0, 3 * u);
                if (mouse.x >= ra.x && mouse.x <= rz.x && mouse.y >= ra.y && mouse.y <= rz.y) {
                    if (mouse_moved) ui.panel_row = i;
                    if (click) ui.panel_row = i, ui.spot = r.check, ui.panel = false, click = false;
                }
                float cy = (ra.y + rz.y) * 0.5f;
                dl->AddCircleFilled(ImVec2(ra.x + 20 * u, cy), 7 * u, dot[r.st]);
                std::string nm = c.title.empty() ? pretty(c.name) : c.title;
                ImU32 ncol = r.st == ST_DONE ? IM_COL32(0x8C, 0x7B, 0x62, 255) : ink;
                std::string where = !c.dcell.empty() ? "room " + c.dcell : !c.spot.empty() ? c.spot : c.area.empty() ? "" : area_name(c.area);
                std::string tag = r.st == ST_TRICK ? "trick logic" : r.st == ST_NEEDS ? needs_text(r.check) : "";
                ImVec2 tg = tag.empty() ? ImVec2(0, 0) : text_size(font, fs_k, tag.c_str());
                float tag_w = tag.empty() ? 0 : std::min(tg.x + 20 * u, 230 * u);
                float wx = rz.x - 14 * u - tag_w - (tag_w > 0 ? 12 * u : 0) - 160 * u;  // the spot column
                dl->PushClipRect(ImVec2(ra.x, ra.y), ImVec2(wx - 10 * u, rz.y), true);
                ImVec2 ns = text_size(font, fs_r, nm.c_str());
                dl->AddText(font, fs_r, ImVec2(ra.x + 36 * u, cy - ns.y * 0.5f), ncol, nm.c_str());
                if (r.st == ST_DONE) dl->AddLine(ImVec2(ra.x + 36 * u, cy + 1 * u), ImVec2(ra.x + 36 * u + ns.x, cy + 1 * u), ncol, 1.6f * u);
                dl->PopClipRect();
                dl->PushClipRect(ImVec2(wx, ra.y), ImVec2(wx + 156 * u, rz.y), true);
                dl->AddText(font, fs_w, ImVec2(wx, cy - text_size(font, fs_w, "X").y * 0.5f), ink2, where.c_str());
                dl->PopClipRect();
                if (!tag.empty()) {
                    while (tg.x + 20 * u > tag_w && tag.size() > 8) tag = tag.substr(0, tag.size() - 4) + "...", tg = text_size(font, fs_k, tag.c_str());
                    ImVec2 ta(rz.x - 14 * u - tag_w, cy - tg.y * 0.5f - 3 * u), tz(rz.x - 14 * u, cy + tg.y * 0.5f + 3 * u);
                    bool tr = r.st == ST_TRICK;
                    dl->AddRectFilled(ta, tz, tr ? IM_COL32(0xDE, 0xD3, 0xF4, 255) : IM_COL32(0xF2, 0xD2, 0x9B, 255), tz.y - ta.y);
                    dl->AddText(font, fs_k, ImVec2(ta.x + 10 * u, ta.y + 3 * u), tr ? IM_COL32(0x3E, 0x28, 0x7E, 255) : IM_COL32(0x6A, 0x3C, 0x05, 255),
                                tag.c_str());
                }
            }
            dl->PopClipRect();
            const char *foot = "Up / Down  choose      A  show on map      B  back";
            dl->AddText(font, 16 * u, ImVec2(x, z.y - 36 * u), IM_COL32(0x4A, 0x30, 0x20, 255), foot);
            if ((click && !in_panel) || rclick) ui.panel = false;
        }
    } else if (rclick && ui.spot >= 0) ui.spot = -1, ui.panel = true;
    else if (rclick && ui.filter_focus) ui.filter_focus = false;
    (void)mouse_on_ui;
    g_panel_open = ui.panel || ui.spot >= 0;  // (B is ours while the list or a shown spot is up)
    g_filter_open = ui.filter_focus;
}
