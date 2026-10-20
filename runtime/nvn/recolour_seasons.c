// Cosmetics: the overworld's Leaves and Grass colours (Cosmetics tab, shared palette), live; the Season row fills both
// (Spring = Default / Default, Autumn = Orange / Gold, Winter = White / White, Cherry blossom = Pink / Default). They
// recolour the greens of the overworld's foliage, keeping the shading (recolour.c).
//   Leaves: tree canopies (Tree_01, the river trees' leaves, the Mysterious Woods' trees, fallen leaves, the telephone
//   trees' crowns), palm leaves, bushes and plants (the liftable / cuttable bush Grass_01 - also an enemy's bush
//   disguise, so it still blends in -, field plants).
//   Grass: the ground's grass, tall grass Lawn_01, grass tufts.
// The leaves flying off cut grass and bushes (effect sheets grass_00 / grass_01 / cut_lawn_00) get the same colour as
// what was cut. Only greens move (a hue range): flowers, trunks, dirt, rocks keep theirs.
#include <string.h>

#include "../settings.h"
#include "recolour.h"

enum { S_TREE = 16, S_PALM, S_BUSH, S_GRASS };

static bool ends_alb(const char *t) { size_t n = strlen(t); return n > 4 && !strcmp(t + n - 4, "_alb"); }
static bool pre(const char *t, const char *p) { return !strncmp(t, p, strlen(p)); }

static int field(int source, const char *t) {  // Field.bntx (the overworld's textures) and the foliage actors
    (void)source;
    if (!ends_alb(t)) return 0;
    if (pre(t, "MI_Tree_01_") || pre(t, "MI_RiverTree_02_") || pre(t, "MI_MysteriousTree_01_") || pre(t, "MI_Leaf_01_") ||
        pre(t, "MI_d2_2d_ha_") || pre(t, "MI_TravellersTree_01_") || pre(t, "MI_BdTel"))
        return S_TREE;
    if (pre(t, "MI_PalmTree_02_")) return S_PALM;
    if (pre(t, "MI_Grass_01_") || pre(t, "MI_plants_01_") || pre(t, "MI_Osmunda_01_") || pre(t, "MI_LivelyWood_01_02_") ||
        pre(t, "MI_LivelyFlowers") || pre(t, "MI_FieldFlower") || pre(t, "MI_KCShutter_grass"))
        return S_BUSH;
    if (pre(t, "MI_f_grass_a_") || pre(t, "MI_f_grass_c_") || pre(t, "MI_f_g_grass_") || pre(t, "MI_f_b_grass_kr") ||
        pre(t, "MI_TP_grass_") || pre(t, "MI_Lawn_01_") || pre(t, "MI_BdRichard_grass_"))
        return S_GRASS;
    return 0;
}

static int effect(int source, const char *t) {  // the leaves of cut grass / bushes
    (void)source;
    if (!strcmp(t, "grass_00") || !strcmp(t, "cut_lawn_00")) return S_GRASS;
    if (!strcmp(t, "grass_01")) return S_BUSH;
    return 0;
}

static const RecolourSource k_sources[] = {
    {"region_common/map/Field.bntx", field},
    {"region_common/actor/ObjTree.bfres", field},
    {"region_common/actor/ObjGrass.bfres", field},
    {"region_common/actor/ObjLawn.bfres", field},
    {"region_common/actor/ObjPalmTree.bfres", field},
    {"region_common/actor/ObjMysteriousTree.bfres", field},
    {"region_common/effect/Common.ptcl", effect},
    {"region_common/effect/Player.ptcl", effect},
    {"region_common/effect/Object.ptcl", effect},
};

// The rows' colour is a target for the greens' typical colour as drawn (hue in degrees, saturation, value): leaves
// (140, 0.8, 0.58: the canopies are mostly in their own shade, so they're lifted more), grass (100, 0.65, 0.8). Only
// greens move: hues within ~72 degrees of the leaves' 140 (their shaded parts reach ~180) / ~61 of the grass' 100
// (the dirt paths, ~35, stay out); their own variety is kept at 35%, around that typical hue.
static bool tint(int cls, float t[8]) {
    uint32_t rgb;
    float sh, sf, vf;
    if (cls == S_GRASS) {
        if (!col_target(&g_settings.grass, COL_SLOT_GRASS, &rgb)) return false;
        col_mapping(100 / 360.0f, 0.65f, 0.8f, rgb, &sh, &sf, &vf);
        recolour_pack(t, sh, sf, vf, recolour_deg(100), 0.17f, 0.12f, 0.35f);
    } else {
        if (!col_target(&g_settings.leaves, COL_SLOT_LEAVES, &rgb)) return false;
        col_mapping(140 / 360.0f, 0.8f, 0.58f, rgb, &sh, &sf, &vf);
        recolour_pack(t, sh, sf, vf, recolour_deg(140), 0.2f, 0.12f, 0.35f);
    }
    return true;
}

const RecolourOption g_recolour_seasons = {"leaves / grass", k_sources, (int)(sizeof k_sources / sizeof *k_sources), S_TREE,
                                           S_GRASS, tint};
