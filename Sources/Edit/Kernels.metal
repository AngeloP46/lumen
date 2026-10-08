#include <CoreImage/CoreImage.h>
using namespace metal;

// Lumen's fused per-pixel kernels. Everything here runs on the GPU inside Core Image.
// The working space is extended-linear Display P3. Layer encoding: e = (log2(Y / 0.18) + 8) / 16.

extern "C" { namespace coreimage {

// ------------------------------------------------------------------ helpers

inline float lmLum(float3 c) { return dot(c, float3(0.22897, 0.69174, 0.07929)); }
inline float lmStep(float e0, float e1, float x) {
    float t = clamp((x - e0) / max(e1 - e0, 1e-6), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
inline float lmEnc(float y) { return clamp((log2(max(y, 1e-5) / 0.18) + 8.0) / 16.0, 0.0, 1.0); }
inline float lmDec(float e) { return e * 16.0 - 8.0; }

inline float3 lmToLab(float3 c) {
    float l = 0.481327291 * c.r + 0.462067912 * c.g + 0.056495603 * c.b;
    float m = 0.228838101 * c.r + 0.653234400 * c.g + 0.117954413 * c.b;
    float s = 0.083986018 * c.r + 0.224272789 * c.g + 0.692220839 * c.b;
    l = pow(max(l, 0.0), 1.0 / 3.0); m = pow(max(m, 0.0), 1.0 / 3.0); s = pow(max(s, 0.0), 1.0 / 3.0);
    return float3(0.210454255 * l + 0.793617785 * m - 0.004072047 * s,
                  1.977998495 * l - 2.428592205 * m + 0.450593710 * s,
                  0.025904037 * l + 0.782771766 * m - 0.808675766 * s);
}
inline float3 lmFromLab(float3 v) {
    float l = v.x + 0.396337792 * v.y + 0.215803758 * v.z;
    float m = v.x - 0.105561342 * v.y - 0.063854175 * v.z;
    float s = v.x - 0.089484182 * v.y - 1.291485538 * v.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(3.128110530 * l - 2.257075019 * m + 0.129304789 * s,
                  -1.091128161 * l + 2.413266762 * m - 0.322168171 * s,
                  -0.026013650 * l - 0.508027649 * m + 1.533316682 * s);
}

inline float lmSrgbEnc(float v) {
    v = clamp(v, 0.0, 1.0);
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}
inline float lmSrgbDec(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

inline float lmHash(float2 p, float seed) {
    float3 p3 = fract(float3(p.x, p.y, seed) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z) * 2.0 - 1.0;
}
inline float lmNoise(float2 p, float seed) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = lmHash(i, seed), b = lmHash(i + float2(1, 0), seed);
    float c = lmHash(i + float2(0, 1), seed), d = lmHash(i + float2(1, 1), seed);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// ------------------------------------------------------------------ analysis layers

// R = encoded log luminance.
float4 lumenLogLum(sample_t s) {
    return float4(lmEnc(lmLum(max(s.rgb, 0.0))), 0.0, 0.0, 1.0);
}

// R = darkest channel (linear).
float4 lumenMinChannel(sample_t s) {
    float m = min(s.r, min(s.g, s.b));
    return float4(max(m, 0.0), 0.0, 0.0, 1.0);
}

// Packs the red channel of three images into RGB.
float4 lumenPack3(sample_t a, sample_t b, sample_t c) {
    return float4(a.r, b.r, c.r, 1.0);
}

// ------------------------------------------------------------------ the main develop kernel

// Tone part: everything up to and including the log-luminance tone delta (scene linear, may exceed 1).
inline float3 lmDevelopTone(float3 base, float4 L1, float4 L2, float3 chroma,
                            float4 pa, float4 pb, float4 pc, float4 pd, float4 pe,
                            float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float3 c = max(base, 0.0);

    // ---- accumulated parameters (global + local)
    float ev = g0.x + pa.x * 4.0;                // local exposure plane stores EV/4
    float contrast = g0.y + pa.y;
    float hl = g0.z + pa.z;
    float sh = g0.w + pb.x;
    float wh = g1.x + pb.y;
    float bk = g1.y + pb.z;
    float temp = g1.z + pc.x;
    float tint = g1.w + pc.y;
    float clar = g2.w + pd.x;
    float tex = g2.z + pd.y;
    float dz = g3.x + pd.z;
    float sharp = g3.y + pe.x;
    float nrL = clamp(g3.w + pe.y, 0.0, 1.5);
    float nrC = g4.x;

    float lpre = clamp(log2(max(lmLum(c), 1e-5) / 0.18), -8.0, 8.0);

    // ---- colour noise reduction: borrow smoothed chromaticity where it differs only slightly
    if (nrC > 0.0) {
        float y0 = max(lmLum(c), 1e-5);
        float yb = max(lmLum(chroma), 1e-5);
        float3 ch0 = c / y0;
        float3 chb = chroma / yb;
        float w = nrC * (1.0 - lmStep(0.05, 0.30, length(ch0 - chb)));
        c = mix(ch0, chb, w) * y0;
    }

    // ---- white balance (relative to as shot); luminance is preserved
    if (temp != 0.0 || tint != 0.0) {
        float y0 = lmLum(c);
        c *= float3(exp2(0.6 * temp), exp2(-0.4 * tint), exp2(-0.6 * temp));
        c *= y0 / max(lmLum(c), 1e-6);
    }

    // ---- exposure
    float expGain = exp2(ev);
    c *= expGain;

    // ---- dehaze (scene linear)
    if (dz != 0.0) {
        float darkNorm = max(g6.w, 1e-4);
        float d = clamp(L2.g / darkNorm, 0.0, 1.0);
        float3 air = g6.xyz * expGain;
        if (dz > 0.0) {
            float t = max(1.0 - 0.9 * min(dz, 1.0) * d, 0.18);
            c = max((c - air * (1.0 - t)) / t, 0.0);
        } else {
            float k = min(-dz, 1.0) * 0.6 * (0.35 + 0.65 * d);
            c = c + (air * 0.9 - c) * k;
        }
    }

    // ---- tone controls in log luminance
    float yNow = max(lmLum(c), 1e-6);
    float l1 = log2(yNow / 0.18);
    float shift = l1 - (lpre + ev);
    float baseLog = lmDec(L2.r) + ev + shift;
    float bb = mix(l1, baseLog, 0.75);
    float delta = 0.0;

    if (sh != 0.0 || hl != 0.0) {
        float ws = 1.0 - lmStep(-4.8, 0.3, bb);
        float whh = lmStep(-1.0, 2.8, bb);
        delta += sh * 1.7 * ws * sqrt(ws) + hl * 1.7 * whh;
    }
    if (wh != 0.0) delta += wh * 0.8 * lmStep(0.5, 3.0, l1);
    if (bk != 0.0) delta += bk * 0.8 * (1.0 - lmStep(-6.0, -1.5, l1));
    if (contrast != 0.0) delta += contrast * 0.22 * clamp(l1, -6.0, 4.0);

    if (clar != 0.0) {
        float det = clamp(lpre - lmDec(L1.b), -2.5, 2.5);
        float q = bb / 3.2;
        delta += clar * 0.6 * det * (0.35 + 0.65 * exp(-q * q));
    }
    float dt = lpre - lmDec(L1.g);
    if (tex != 0.0) {
        float tame = 1.0 - 0.6 * lmStep(0.4, 1.6, fabs(dt));
        delta += tex * 1.1 * clamp(dt, -1.0, 1.0) * tame;
    }
    if (sharp != 0.0) {
        float ds = lpre - lmDec(L1.r);
        float sm = g3.z;
        float mk = sm > 0.0 ? lmStep(sm * 0.25, sm * 0.25 + 0.15, fabs(ds)) : 1.0;
        delta += sharp * 1.0 * clamp(ds, -0.8, 0.8) * mk;
    }
    if (nrL > 0.0) {
        delta -= nrL * 0.9 * dt * (1.0 - lmStep(0.1, 0.5, fabs(dt)));
    }
    delta = clamp(delta, -4.0, 4.0);
    c *= exp2(delta);
    return c;
}

// Colour part: highlight shoulder, >1 desaturation, vibrance / saturation, final clamp.
inline float3 lmDevelopColor(float3 c, float vib, float sat) {
    // ---- highlight shoulder: identity below 0.85, rolls off towards 1; keeps hue by scaling
    float y = lmLum(c);
    if (y > 0.85) {
        float k = 0.85;
        float yo = k + (1.0 - k) * (1.0 - exp(-(y - k) / (1.0 - k)));
        c *= yo / y;
    }
    // channels still above 1: desaturate towards the luminance
    float mx = max(c.r, max(c.g, c.b));
    if (mx > 1.0) {
        float yy = lmLum(c);
        float t = clamp((mx - 1.0) / max(mx - yy, 1e-5), 0.0, 1.0);
        c = c + (float3(yy) - c) * t;
    }

    // ---- vibrance / saturation in OkLab
    if (vib != 0.0 || sat != 0.0) {
        float3 lab = lmToLab(c);
        float C = length(lab.yz);
        float h = atan2(lab.z, lab.y);
        float k = 1.0;
        if (vib != 0.0) {
            float low = 1.0 - clamp(C / 0.22, 0.0, 1.0);
            float skin = 1.0;
            if (vib > 0.0) {
                float q = (fmod(h - 0.85 + 3.14159265 + 6.2831853, 6.2831853) - 3.14159265) / 0.35;
                skin = 1.0 - 0.6 * exp(-q * q);
            }
            k *= max(1.0 + vib * low * low * skin * 1.2, 0.0);
        }
        k *= max(1.0 + sat, 0.0);
        lab.yz *= k;
        c = lmFromLab(lab);
    }
    return clamp(c, 0.0, 1.0);
}

inline float3 lmDevelop(float3 base, float4 L1, float4 L2, float3 chroma,
                        float4 pa, float4 pb, float4 pc, float4 pd, float4 pe,
                        float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float sat = g2.y + pc.z;
    return lmDevelopColor(lmDevelopTone(base, L1, L2, chroma, pa, pb, pc, pd, pe, g0, g1, g2, g3, g4, g6),
                          g2.x, sat);
}

float4 lumenMain(sample_t img, sample_t l1, sample_t l2, sample_t ch,
                 float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float4 z = float4(0.0);
    float3 c = lmDevelop(img.rgb, l1, l2, ch.rgb, z, z, z, z, z, g0, g1, g2, g3, g4, g6);
    return float4(c, 1.0);
}

float4 lumenMainLocal(sample_t img, sample_t l1, sample_t l2, sample_t ch,
                      sample_t pa, sample_t pb, sample_t pc, sample_t pd, sample_t pe,
                      float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float3 c = lmDevelop(img.rgb, l1, l2, ch.rgb, pa, pb, pc, pd, pe, g0, g1, g2, g3, g4, g6);
    return float4(c, 1.0);
}

// ------------------------------------------------------------------ finishing (after crop)

// g0 = (vignette amount, midpoint, feather, roundness)
// g1 = (width, height, grain amount, grain cell size)
// g2 = (grain roughness, output gamma-encoded? 1 : 0, seed, 0)
float4 lumenFinish(sample_t s, float4 g0, float4 g1, float4 g2, destination dest) {
    float3 c = max(s.rgb, 0.0);
    float2 size = g1.xy;
    float2 p = dest.coord();

    float va = g0.x;
    if (va != 0.0) {
        float2 uv = (p / size) * 2.0 - 1.0;
        float aspect = size.x / size.y;
        float sx = mix(1.0, aspect, g0.w);
        float2 q = uv * float2(sx, 1.0) / max(sx, 1.0);
        float d = length(q) / 1.41421356;
        float mid = g0.y;
        float t = lmStep(mid, mid + max(0.05, (1.0 - mid) * (0.2 + 0.8 * g0.z)), d);
        if (va < 0.0) c *= exp2(va * 2.0 * t);
        else c = c + (float3(1.0) - c) * (va * 0.5 * t);
    }

    float3 e = float3(lmSrgbEnc(c.r), lmSrgbEnc(c.g), lmSrgbEnc(c.b));

    float ga = g1.z;
    if (ga > 0.0) {
        float cell = max(g1.w, 0.5);
        float2 gp = p / cell;
        float n = lmNoise(gp, g2.z);
        n = n * (1.0 - g2.x * 0.5) + lmNoise(gp * 2.3, g2.z + 17.0) * g2.x * 0.7;
        float lum = dot(e, float3(0.2126, 0.7152, 0.0722));
        e += ga * 0.16 * n * (0.35 + 2.6 * lum * (1.0 - lum));
        e = clamp(e, 0.0, 1.0);
    }
    if (g2.y < 0.5) e = float3(lmSrgbDec(e.r), lmSrgbDec(e.g), lmSrgbDec(e.b));
    return float4(e, 1.0);
}

// Gamma-encoded -> linear (used after the 3D look table).
float4 lumenToLinear(sample_t s) {
    return float4(lmSrgbDec(s.r), lmSrgbDec(s.g), lmSrgbDec(s.b), 1.0);
}

// ------------------------------------------------------------------ local-adjustment planes

// acc + mask * v  (v.xyz)
float4 lumenAccum(sample_t acc, sample_t m, float4 v) {
    return float4(acc.rgb + m.r * v.xyz, 1.0);
}

// ------------------------------------------------------------------ masks

// p = (x0, y0, x1, y1) in pixels (y up). Full effect at p0, none at p1.
float4 lumenLinearMask(sample_t s, float4 p, float4 q, destination dest) {
    float2 a = p.xy, b = p.zw;
    float2 ab = b - a;
    float len2 = max(dot(ab, ab), 1e-3);
    float t = dot(dest.coord() - a, ab) / len2;
    float v = 1.0 - lmStep(0.0, 1.0, t);
    return float4(v, v, v, 1.0);
}

// p = (cx, cy, rx, ry) pixels; q = (cos, sin, feather, 0)
float4 lumenRadialMask(sample_t s, float4 p, float4 q, destination dest) {
    float2 d = dest.coord() - p.xy;
    float x = d.x * q.x + d.y * q.y;
    float y = -d.x * q.y + d.y * q.x;
    float r = length(float2(x / max(p.z, 1.0), y / max(p.w, 1.0)));
    float f = clamp(q.z, 0.02, 1.0);
    float v = 1.0 - lmStep(1.0 - f, 1.0, r);
    return float4(v, v, v, 1.0);
}

// p = (lo, hi, loFeather, hiFeather); q.x = exposure gain applied before measuring
float4 lumenLumMask(sample_t s, float4 p, float4 q) {
    float y = lmSrgbEnc(lmLum(max(s.rgb * q.x, 0.0)));
    float v = lmStep(p.x - max(p.z, 0.001), p.x, y) * (1.0 - lmStep(p.y, p.y + max(p.w, 0.001), y));
    if (p.x <= 0.001) v = (1.0 - lmStep(p.y, p.y + max(p.w, 0.001), y));
    if (p.y >= 0.999) v = lmStep(p.x - max(p.z, 0.001), p.x, y);
    return float4(v, v, v, 1.0);
}

// Colour range: up to four OkLab samples (L, a, b, valid). t = (tolerance, softness, 0, 0)
float4 lumenColorMask(sample_t s, float4 s0, float4 s1, float4 s2, float4 s3, float4 t, float4 q) {
    float3 lab = lmToLab(max(s.rgb * q.x, 0.0) / (1.0 + max(s.rgb * q.x, 0.0)));
    float best = 1e9;
    float4 ss[4] = { s0, s1, s2, s3 };
    for (int i = 0; i < 4; i++) {
        if (ss[i].w > 0.5) {
            float da = lab.y - ss[i].y, db = lab.z - ss[i].z, dl = lab.x - ss[i].x;
            best = min(best, sqrt(da * da + db * db + 0.2 * dl * dl));
        }
    }
    float tol = max(t.x, 0.005);
    float soft = clamp(t.y, 0.05, 1.0);
    float v = 1.0 - lmStep(tol * (1.0 - soft), tol, best);
    return float4(v, v, v, 1.0);
}

// Similarity to a reference OkLab colour (for edge-aware brushing). p = (L, a, b, tolerance)
float4 lumenSimilarMask(sample_t s, float4 p) {
    float3 c = max(s.rgb, 0.0);
    float3 lab = lmToLab(c / (1.0 + c));
    float da = lab.y - p.y, db = lab.z - p.z, dl = lab.x - p.x;
    float d = sqrt(da * da + db * db + 0.35 * dl * dl);
    float v = 1.0 - lmStep(p.w * 0.5, p.w, d);
    return float4(v, v, v, 1.0);
}

// op.x: 0 add (union), 1 subtract, 2 intersect
float4 lumenMaskCombine(sample_t a, sample_t b, float4 op) {
    float v;
    if (op.x < 0.5) v = a.r + b.r - a.r * b.r;
    else if (op.x < 1.5) v = a.r * (1.0 - b.r);
    else v = a.r * b.r;
    return float4(v, v, v, 1.0);
}

// p.x = invert, p.y = opacity
float4 lumenMaskFinish(sample_t m, float4 p) {
    float v = m.r;
    if (p.x > 0.5) v = 1.0 - v;
    v = clamp(v, 0.0, 1.0) * p.y;
    return float4(v, v, v, 1.0);
}

float4 lumenMaskMul(sample_t a, sample_t b) {
    float v = a.r * b.r;
    return float4(v, v, v, 1.0);
}

// Mask overlay: tints `s` towards colour.rgb by mask * colour.a
float4 lumenOverlay(sample_t s, sample_t m, float4 colour) {
    float k = clamp(m.r, 0.0, 1.0) * colour.a;
    return float4(mix(s.rgb, colour.rgb, k), 1.0);
}

}}
