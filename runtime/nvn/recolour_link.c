// Cosmetics: Link's hair and shield colours (Cosmetics tab "Hair color" / "Shield color"), live: draws sampling his
// hair's colour map (Playerlink.bfres MI_hair_alb: hair only) or a shield's (MI_shieldA_alb, the first shield: only
// its blue face moves, the red emblem and the metal stay; MI_shieldB_alb, the Mirror Shield: its orange
// trim) get the chosen colour's hue, saturation and value, keeping the shading (recolour.c).
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../settings.h"
#include "recolour.h"

enum { C_HAIR = 1, C_SHIELD_A, C_SHIELD_B };

static int classify(int source, const char *t) {
    (void)source;
    if (!strcmp(t, "MI_hair_alb")) return C_HAIR;
    if (!strcmp(t, "MI_shieldA_alb")) return C_SHIELD_A;
    if (!strcmp(t, "MI_shieldB_alb")) return C_SHIELD_B;
    return 0;
}

static const RecolourSource k_sources[] = {{"region_common/actor/Playerlink.bfres", classify}};

// hue (degrees; < 0: keep), saturation and value factors - by g_hair_colours / g_shield_colours (Default, ..., Random)
static const float k_hair[N_HAIR_COLOURS][3] = {
    {0}, {45, 0.65f, 1.35f} /* Blond */, {25, 0.85f, 0.6f} /* Brown */, {-1, 0.3f, 0.3f} /* Black */,
    {-1, 0.06f, 1.45f} /* White */, {2, 1, 1} /* Red */, {215, 0.9f, 1} /* Blue */, {120, 0.85f, 0.95f} /* Green */,
    {330, 0.55f, 1.3f} /* Pink */, {275, 0.75f, 1} /* Purple */};
static const float k_shield[N_SHIELD_COLOURS][3] = {
    {0}, {0, 1, 0.95f} /* Red */, {125, 0.9f, 0.85f} /* Green */, {275, 0.85f, 0.9f} /* Purple */,
    {45, 1, 1.05f} /* Gold */, {-1, 0.25f, 0.3f} /* Black */, {-1, 0.08f, 1.15f} /* White */};

// "Random" (the last entry): one of the colours, picked again whenever the row is set to Random
static int resolve(int v, int n, int *pick) {
    if (v != n - 1) { *pick = 0; return v; }
    static unsigned seed;
    if (!seed) seed = (unsigned)time(NULL) ^ (unsigned)(uintptr_t)&seed;
    if (!*pick) { seed = seed * 1103515245u + 12345u; *pick = 1 + (int)((seed >> 16) % (unsigned)(n - 2)); }
    return *pick;
}

static bool tint(int cls, float t[8]) {
    static int hair_pick, shield_pick;
    int h = resolve(g_settings.hair, N_HAIR_COLOURS, &hair_pick);
    int s = resolve(g_settings.shield, N_SHIELD_COLOURS, &shield_pick);
    const float *c;
    float src, width, min_sat;
    if (cls == C_HAIR) {
        if (h <= 0 || h >= N_HAIR_COLOURS) return false;
        c = k_hair[h], src = 30, width = 0.5f, min_sat = 0;  // (the whole map is hair)
    } else {
        if (s <= 0 || s >= N_SHIELD_COLOURS) return false;
        c = k_shield[s];
        // (hues as drawn: the lit blue face reads teal, ~195 degrees; its map's blue is 211)
        if (cls == C_SHIELD_A) src = 195, width = 0.15f, min_sat = 0.25f;  // the blue face
        else src = 38, width = 0.08f, min_sat = 0.4f;                        // the Mirror Shield's orange
    }
    recolour_pack(t, c[0] < 0 ? 0 : recolour_deg(c[0] - src), c[1], c[2], recolour_deg(src), width, min_sat, 1);
    return true;
}

const RecolourOption g_recolour_link = {"hair / shield", k_sources, 1, C_HAIR, C_SHIELD_B, tint};
