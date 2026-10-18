// Shader preparation (first launch): the game's shader variants are translated, compiled and built into pipelines
// before the game starts, so a first visit anywhere has no compile hitch or pop-in. The approach follows
// SuperMarioWonderRecomp's ahead-of-time shaders (github.com/BelmanteGu/SuperMarioWonderRecomp).
//
// What ships is only a list of variant records (runtime/nvn/shader_keys.txt): pipeline / compute state in NVN terms
// (formats, vertex layout, blend state, ...) plus each shader's identity as a one-way hash of its code bytes. No
// shader code ships in any form: the code is found by that hash in the player's own game files
// (romfs/region_common/shader/*.bfsha, BNSH containers), and each backend builds the variants on the player's
// machine through the same code its draws use. The objects are kept for the game, which finds them by content at
// first use (code addresses differ from run to run). Anything the list misses still compiles at first use
// (asynchronously, as before) and is logged as a first visit.
//
// LARECOMP_RECORD_KEYS=<file> (dev): every program / pipeline / compute variant the game builds is appended to <file>
// (one line each, deduplicated), e.g. during a shader tour (LARECOMP_SHADER_TOUR, runtime/ui/shader_tour.mm).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { SR_FLIP_Y = 1, SR_DEPTH_MINUS_ONE = 2, SR_FLIP_X = 4 };

typedef struct {
    char kind;               // 'G' graphics pipeline, 'C' compute program
    uint64_t vs, fs;         // code hashes (shader_code_hash); compute: vs
    uint8_t flags;           // SR_*: lower-left window origin, NVN depth mode [-1, 1], mirrored composite
    uint8_t nattrib, nstream, ncolor;
    uint32_t attrib[16];     // NVN vertex attribute state: format | stream << 8 | offset << 13
    uint32_t stream[16][2];  // vertex stream stride, divisor
    uint32_t color[8];       // render target texture formats (0: no target)
    uint32_t cview[8];       // render target view formats (0: the texture's own)
    uint32_t depth;          // depth / stencil target format (0: none)
    uint32_t samples;        // samples of the targets (1: single-sampled)
    uint32_t channel_mask;   // color write masks, 4 bits per target
    uint8_t blend_on;        // blending enabled, 1 bit per target
    uint8_t blend[8][8];     // NVN blend state per target (zero where blending is off)
    uint8_t a2c;             // alpha to coverage
    uint8_t topo;            // primitive class: 0 points, 1 lines, 2 triangles
    uint8_t poly_fill;       // filled polygons (0: lines)
    uint32_t local[3];       // compute: local size
} ShaderRec;

// The record's text form (one line, no newline) and back
void shader_rec_format(const ShaderRec *r, char *out, size_t n);
bool shader_rec_parse(const char *line, ShaderRec *r);

// One-way hash of a shader's code bytes: what identifies a shader in the records
uint64_t shader_code_hash(const uint8_t *code, size_t n);
struct NvnShaderStage;
uint64_t shader_stage_hash(const struct NvnShaderStage *s);  // its code up to the end of its constants; 0: unknown
uint8_t shader_topo_class(uint32_t mode);                     // NVN draw mode -> ShaderRec.topo

// (LARECOMP_RECORD_KEYS) note a variant the game builds; cheap when recording is off
bool shader_rec_recording(void);
void shader_rec_note(const ShaderRec *r);
