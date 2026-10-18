#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_shuffle : require
#extension GL_KHR_shader_subgroup_shuffle_relative : require
#extension GL_EXT_texture_shadow_lod : require
#define cbr(cb, off) cb[min((off) >> 4, uint(cb.length() - 1))][((off) >> 2) & 3u]
uint as_u(float x) { return floatBitsToUint(x); }
uint as_u(uint x) { return x; }
uint as_u(int x) { return uint(x); }
float as_f(uint x) { return uintBitsToFloat(x); }
float as_f(int x) { return intBitsToFloat(x); }
float as_f(float x) { return x; }
int as_i(uint x) { return int(x); }
int as_i(float x) { return floatBitsToInt(x); }
int sx8(uint v) { return bitfieldExtract(int(v), 0, 8); }
int sx8(int v) { return bitfieldExtract(v, 0, 8); }
int sx16(uint v) { return bitfieldExtract(int(v), 0, 16); }
int sx16(int v) { return bitfieldExtract(v, 0, 16); }
float saturate(float x) { return isnan(x) ? 0.0f : clamp(x, 0.0f, 1.0f); }
vec2 saturate(vec2 x) { return vec2(saturate(x.x), saturate(x.y)); }
float fmin(float a, float b) { return isnan(a) ? b : (isnan(b) ? a : min(a, b)); }
float fmax(float a, float b) { return isnan(a) ? b : (isnan(b) ? a : max(a, b)); }
uint clz(uint v) { return v == 0u ? 32u : uint(31 - findMSB(v)); }
uint popcount(uint v) { return uint(bitCount(v)); }
uint mulhi(uint a, uint b) { uint hi, lo; umulExtended(a, b, hi, lo); return hi; }
int mulhi(int a, int b) { int hi, lo; imulExtended(a, b, hi, lo); return hi; }
uint bfe_u(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return 0u; return bitfieldExtract(v, int(pos), int(min(len, 32u - pos))); }
uint bfe_s(uint v, uint ctl) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u) return 0u; if (pos >= 32u) return (int(v) < 0) ? 0xFFFFFFFFu : 0u; return uint(bitfieldExtract(int(v), int(pos), int(min(len, 32u - pos)))); }
uint bfi(uint ins, uint ctl, uint base) { uint pos = ctl & 0xFFu, len = (ctl >> 8) & 0xFFu; if (len == 0u || pos >= 32u) return base; return bitfieldInsert(base, ins, int(pos), int(min(len, 32u - pos))); }
float fswzadd(float a, float b, uint swz, uint lane) { uint m = (swz >> ((lane & 3u) * 2u)) & 3u; float ma = m == 1u ? -1.0f : (m == 3u ? 0.0f : 1.0f); float mb = m == 2u ? -1.0f : 1.0f; return a * ma + b * mb; }
uvec2 rsc(uvec2 c, vec4 s) { return (s.x == 1.0f && s.y == 1.0f) ? c : uvec2(floor((vec2(c) + 0.5f) * s.xy)); }
float h2f(uint h) { return unpackHalf2x16(h).x; }
vec2 unpack_h2(uint v) { return unpackHalf2x16(v); }
vec2 hx(uint v, uint swz) { if (swz == 1u) return vec2(uintBitsToFloat(v)); vec2 h = unpack_h2(v); return swz == 2u ? h.xx : (swz == 3u ? h.yy : h); }
uint hpack(vec2 r, uint merge, uint old) { if (merge == 1u) return floatBitsToUint(r.x); uint lo = packHalf2x16(vec2(r.x, 0.0f)), hi = packHalf2x16(vec2(r.y, 0.0f)); if (merge == 2u) return (old & 0xFFFF0000u) | lo; if (merge == 3u) return (old & 0xFFFFu) | (hi << 16); return lo | (hi << 16); }
uint prmt(uint a, uint b, uint sel) { uint r = 0u; for (uint i = 0u; i < 4u; i++) { uint s = (sel >> (i * 4u)) & 7u; uint bt = s < 4u ? (a >> (s * 8u)) & 0xFFu : (b >> ((s - 4u) * 8u)) & 0xFFu; r |= bt << (i * 8u); } return r; }
layout(std140, set = 1, binding = 2) uniform CB2 { uvec4 cb2[912]; };
layout(std140, set = 1, binding = 15) uniform CB15 { uvec4 cb15[3600]; };
layout(std140, set = 2, binding = 0) uniform GChunks { uvec4 gchunk[256]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer GW { uint w[]; };
void gmiss(uint c, uint i) { }
#define GMC(i) ((i) >> 22u)
#define GMO(i) ((i) & 0x3fffffu)
layout(push_constant) uniform GDirect { uvec4 gd[4]; };
layout(std430, set = 2, binding = 2) readonly buffer GDir0 { uint w[]; } gdir0_;
layout(std430, set = 2, binding = 3) readonly buffer GDir1 { uint w[]; } gdir1_;
layout(std430, set = 2, binding = 4) readonly buffer GDir2 { uint w[]; } gdir2_;
layout(std430, set = 2, binding = 5) readonly buffer GDir3 { uint w[]; } gdir3_;
uint GMR1(uint i) { uint o; o = i - gd[0].x; if (o < gd[0].y) { return gdir0_.w[o]; } o = i - gd[1].x; if (o < gd[1].y) { return gdir1_.w[o]; } o = i - gd[2].x; if (o < gd[2].y) { return gdir2_.w[o]; } o = i - gd[3].x; if (o < gd[3].y) { return gdir3_.w[o]; } uint c = GMC(i); o = GMO(i); uvec4 e = gchunk[c]; if (o < e.z) { GW p = GW((uint64_t(e.y) << 32) | uint64_t(e.x)); return p.w[o]; } gmiss(c, i); return 0u; }
uvec2 GMR2(uint i) { uint o; o = i - gd[0].x; if (o < gd[0].y) { return uvec2(gdir0_.w[o], gdir0_.w[o + 1u]); } o = i - gd[1].x; if (o < gd[1].y) { return uvec2(gdir1_.w[o], gdir1_.w[o + 1u]); } o = i - gd[2].x; if (o < gd[2].y) { return uvec2(gdir2_.w[o], gdir2_.w[o + 1u]); } o = i - gd[3].x; if (o < gd[3].y) { return uvec2(gdir3_.w[o], gdir3_.w[o + 1u]); } uint c = GMC(i); o = GMO(i); uvec4 e = gchunk[c]; if (o + 1u < e.z) { GW p = GW((uint64_t(e.y) << 32) | uint64_t(e.x)); return uvec2(p.w[o], p.w[o + 1u]); } gmiss(c, i); return uvec2(0u); }
uvec4 GMR4(uint i) { uint o; o = i - gd[0].x; if (o < gd[0].y) { return uvec4(gdir0_.w[o], gdir0_.w[o + 1u], gdir0_.w[o + 2u], gdir0_.w[o + 3u]); } o = i - gd[1].x; if (o < gd[1].y) { return uvec4(gdir1_.w[o], gdir1_.w[o + 1u], gdir1_.w[o + 2u], gdir1_.w[o + 3u]); } o = i - gd[2].x; if (o < gd[2].y) { return uvec4(gdir2_.w[o], gdir2_.w[o + 1u], gdir2_.w[o + 2u], gdir2_.w[o + 3u]); } o = i - gd[3].x; if (o < gd[3].y) { return uvec4(gdir3_.w[o], gdir3_.w[o + 1u], gdir3_.w[o + 2u], gdir3_.w[o + 3u]); } uint c = GMC(i); o = GMO(i); uvec4 e = gchunk[c]; if (o + 3u < e.z) { GW p = GW((uint64_t(e.y) << 32) | uint64_t(e.x)); return uvec4(p.w[o], p.w[o + 1u], p.w[o + 2u], p.w[o + 3u]); } gmiss(c, i); return uvec4(0u); }
#define GMR(i) GMR1(i)
layout(location = 0) out vec4 c0;
layout(location = 1) out vec4 c1;
layout(location = 2) out vec4 c2;
layout(location = 3) out vec4 c3;
layout(location = 4) out vec4 c4;
layout(location = 5) out vec4 c5;
layout(location = 6) out vec4 c6;
layout(location = 7) out vec4 c7;
void main() {
  uint r0 = 0u;
  uint r6 = 0u;
  uint r10 = 0u;
  uint r11 = 0u;
  uint r12 = 0u;
  uint r13 = 0u;
  uint r14 = 0u;
  uint r17 = 0u;
  uint r22 = 0u;
  uint r35 = 0u;
  uint r119 = 0u;
  uint r183 = 0u;
  uint r201 = 0u;
  uint r227 = 0u;
  bool p0 = false;
  bool p1 = false;
  bool p2 = false;
  bool p3 = false;
  bool p4 = false;
  bool p5 = false;
  bool p6 = false;
  do {
  if (!p6) {
    if (((r201 >> 0u) & 1u) != 0u) p0 = ((r17 >> 24u) & 1u) != 0u;
    if (((r201 >> 1u) & 1u) != 0u) p1 = ((r17 >> 25u) & 1u) != 0u;
    if (((r201 >> 2u) & 1u) != 0u) p2 = ((r17 >> 26u) & 1u) != 0u;
    if (((r201 >> 3u) & 1u) != 0u) p3 = ((r17 >> 27u) & 1u) != 0u;
    if (((r201 >> 4u) & 1u) != 0u) p4 = ((r17 >> 28u) & 1u) != 0u;
    if (((r201 >> 5u) & 1u) != 0u) p5 = ((r17 >> 29u) & 1u) != 0u;
    if (((r201 >> 6u) & 1u) != 0u) p6 = ((r17 >> 30u) & 1u) != 0u;
  }
  if (p6) {
    r14 = 0x47fb521du;
  }
  if (p5) {
    r227 = uint(mulhi(int(r183), int(cb15[3589][3])));
  }
  if (p4) {
    { uint64_t ga = (uint64_t(r0) + uint64_t(-5065724)) - 0x80000000ul; bool ok = ga < 0x10000000ul;
      { uvec2 t = ok ? GMR2(uint(ga >> 2)) : uvec2(0u);
        r10 = t[0];
        r11 = t[1];
      }
    }
  }
    r11 = as_u(h2f((r13 >> 16u) & 0xFFFFu));
    r13 = as_u((as_f(r13) * as_f(0x3878fb11u)));
    { uint pr = 0u;
      pr |= (p0 ? 1u : 0u) << 0u;
      pr |= (p1 ? 1u : 0u) << 1u;
      pr |= (p2 ? 1u : 0u) << 2u;
      pr |= (p3 ? 1u : 0u) << 3u;
      pr |= (p4 ? 1u : 0u) << 4u;
      pr |= (p5 ? 1u : 0u) << 5u;
      pr |= (p6 ? 1u : 0u) << 6u;
      uint m = (0x0000af78u & 0x7Fu) << 8u;
    }
    r119 = ((cb2[898][3] == 0u) ? r12 : r6);
    r22 = mulhi(r14, r35);
    break;
  } while (false);
  c0[0] = as_f(r0);
  c0[2] = 0;
  c0[3] = 0;
  c1[1] = 0;
  c1[2] = 0;
  c2[0] = 0;
  c2[3] = as_f(r6);
  c3[0] = 0;
  c3[1] = 0;
  c3[3] = 0;
  c4[0] = as_f(r10);
  c4[3] = as_f(r11);
  c5[2] = as_f(r12);
  c6[0] = as_f(r13);
  c6[2] = as_f(r14);
  c7[3] = 0;
  gl_FragDepth = as_f(r17);
}
