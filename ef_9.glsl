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
layout(std140, set = 1, binding = 0) uniform CB0 { uvec4 cb0[1872]; };
layout(std140, set = 1, binding = 2) uniform CB2 { uvec4 cb2[1168]; };
layout(std140, set = 2, binding = 0) uniform GChunks { uvec4 gchunk[256]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer GW { uint w[]; };
layout(std430, set = 2, binding = 1) buffer GMiss { uint n[256]; uint w[256]; } gmiss_;
void gmiss(uint c, uint i) { atomicAdd(gmiss_.n[c], 1u); atomicMin(gmiss_.w[c], i); }
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
layout(std140, set = 1, binding = 19) uniform Tint { vec4 ltint[2]; };
layout(location = 0) out vec4 c0;
layout(early_fragment_tests) in;
void main() {
  uint r1 = 0u;
  uint r3 = 0u;
  uint r7 = 0u;
  uint r11 = 0u;
  uint r15 = 0u;
  uint r17 = 0u;
  uint r21 = 0u;
  uint r22 = 0u;
  uint r23 = 0u;
  uint r188 = 0u;
  uint r190 = 0u;
  uint r201 = 0u;
  uint r250 = 0u;
  uint r251 = 0u;
  uint r252 = 0u;
  uint r253 = 0u;
  bool p0 = false;
  bool p1 = false;
  bool p4 = false;
  bool p5 = false;
  bool p6 = false;
  uint cc = 0u; bool ccz = false, ccs = false;
  do {
    r22 = uint(abs(int(0x00027510u)));
    { uint ccv = uint(abs(int(0x00027510u))); ccz = ccv == 0u; ccs = int(ccv) < 0; }
  if (!p0) {
  }
  if (!p6) {
    r188 = as_u(saturate(((-abs(as_f(r23))) + (-abs(as_f(cb0[1860][2]))))));
  }
    r21 = ((0xfff85704u) >= 32u ? 0u : (r3 >> (0xfff85704u)));
    r15 = (r7 * 0x00030d0bu);
    { bool cmp = (r17 >= 0x00027c07u); bool pp = false;
      p1 = cmp != pp;
      p6 = !cmp != pp;
    }
  if (!p5) {
    { uint64_t ga = (uint64_t(r1) + uint64_t(3770791)) - 0x80000000ul; bool ok = ga < 0x10000000ul;
      { uvec4 t = ok ? GMR4(uint(ga >> 2)) : uvec4(0u);
        r250 = t[0];
        r251 = t[1];
        r252 = t[2];
        r253 = t[3];
      }
    }
  }
  if (!p6) {
    r7 = prmt(0u, cb2[1154][2], r190);
  }
  if (!p5) {
    { uint res = (~0x000430ffu);
      r201 = res;
      p4 = false; }
  }
    break;
  } while (false);
  c0[0] = 0;
  c0[1] = as_f(r1);
  c0[2] = 0;
  c0[3] = as_f(r3);
  if (ltint[0].w > 0.0f) { vec3 g = c0.rgb; float l = dot(g, vec3(0.299f, 0.587f, 0.114f));
    c0.rgb = mix(g, ltint[0].rgb * pow(l, ltint[1].w) + ltint[1].rgb * l, ltint[0].w); }
}
