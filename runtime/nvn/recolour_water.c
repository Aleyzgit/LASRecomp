// Cosmetics: the Water colour (Cosmetics tab, shared palette), live. It recolours the water surfaces, keeping their
// shading, ripples, highlights and transparency (recolour.c): the sea and its shore waves, rivers, ponds, the fairy
// fountains, the pools in caves and houses, and the dungeons' water (one colour everywhere: it is one water material).
// A water draw is told by its maps: the water normal / colour maps (MI_f_water_*: the overworld's, the caves' and
// houses' copies, Bottle Grotto's, the Wind Fish's Egg's), the 2D side-view water (fishing pond, boat, Manbo's cave),
// Catfish's Maw entrance pool and the distortion map every water surface samples (MI_f_indirect_a_01_nml: two
// versions, Field.bntx's and the Color Dungeon's, which the houses' and fountains' water shares); and the shore
// waves rolling onto the beaches, which are effects (Bg.ptcl wave_04 - 06). Only blues move (a hue window around the
// water's), so the foam, splashes and sparkles stay white and the floor seen through the water keeps its colour.
// Not the waterfalls (white, mostly foam) or the splash particles.
#include <string.h>

#include "../settings.h"
#include "recolour.h"

enum { W_WATER = 32, W_WAVE };

static bool pre(const char *t, const char *p) { return !strncmp(t, p, strlen(p)); }

static int water(int source, const char *t) {
    (void)source;
    if (pre(t, "MI_f_water_") || pre(t, "MI_f_wave_") || pre(t, "MI_2d_water_") || pre(t, "MI_FB_water_") ||
        pre(t, "MI_CatfishsMawEnter_water_01_") || !strcmp(t, "MI_f_indirect_a_01_nml"))
        return W_WATER;
    return 0;
}

static int effect(int source, const char *t) {  // the shore waves rolling onto the beaches (Bg.ptcl)
    (void)source;
    return pre(t, "wave_04") || pre(t, "wave_05") || pre(t, "wave_06") ? W_WAVE : 0;
}

// (the dungeons' texture files have the water maps' other versions; the 2D water and Catfish's Maw entrance pool are
// in their own models)
static const RecolourSource k_sources[] = {
    {"region_common/map/Field.bntx", water},
    {"region_common/map/Lv04AnglersTunnel.bntx", water},
    {"region_common/map/Lv05CatfishsMaw.bntx", water},
    {"region_common/map/Lv09WindFishsEgg.bntx", water},
    {"region_common/map/Lv10ClothesDungeon.bntx", water},
    {"region_common/map/CatfishsMawEnter_01A.bfres", water},
    {"region_common/map/FishingPond_01A.bfres", water},
    {"region_common/map/FishingBoat_01A.bfres", water},
    {"region_common/effect/Bg.ptcl", effect},
};

// The water as drawn is a deep cyan-blue: typical (195, 0.8, 0.7) (Martha's Bay, the dungeons' pools); the shallows
// lean cyan (~175), the deep sea blue (~215). Hues within ~65 degrees of 195 move, their variety kept at half (the
// shallows stay lighter than the deep water); the foam (saturation under ~0.15) stays white.
static bool tint(int cls, float t[8]) {
    uint32_t rgb;
    float sh, sf, vf;
    if (!col_target(&g_settings.water, COL_SLOT_WATER, &rgb)) return false;
    col_mapping(195 / 360.0f, 0.8f, 0.7f, rgb, &sh, &sf, &vf);
    recolour_pack(t, sh, sf, vf, recolour_deg(195), 0.18f, cls == W_WAVE ? 0.3f : 0.15f, 0.5f);
    return true;
}

const RecolourOption g_recolour_water = {"water", k_sources, (int)(sizeof k_sources / sizeof *k_sources), W_WATER,
                                         W_WAVE, tint};
