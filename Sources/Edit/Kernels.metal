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

inline float3 lmFromLab(float3 v) {
    float l = v.x + 0.396337792 * v.y + 0.215803758 * v.z;
    float m = v.x - 0.105561342 * v.y - 0.063854175 * v.z;
    float s = v.x - 0.089484182 * v.y - 1.291485538 * v.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(3.128110530 * l - 2.257075019 * m + 0.129304789 * s,
                  -1.091128161 * l + 2.413266762 * m - 0.322168171 * s,
                  -0.026013650 * l - 0.508027649 * m + 1.533316682 * s);
}

// One shared adjustment engine for all recipes, including migrated saved edits.
inline float lmCubeRoot(float x) { return sign(x) * pow(fabs(x), 1.0 / 3.0); }
inline float3 lmToLab(float3 c) {
    float l = lmCubeRoot(dot(c, float3(0.481327291, 0.462067912, 0.056495603)));
    float m = lmCubeRoot(dot(c, float3(0.228838101, 0.653234400, 0.117954413)));
    float s = lmCubeRoot(dot(c, float3(0.083986018, 0.224272789, 0.692220839)));
    return float3(0.210454255 * l + 0.793617785 * m - 0.004072047 * s,
                  1.977998495 * l - 2.428592205 * m + 0.450593710 * s,
                  0.025904037 * l + 0.782771766 * m - 0.808675766 * s);
}

inline float3 lmP3ToXYZ(float3 c) {
    return float3(dot(c, float3(0.4865709486, 0.2656676932, 0.1982172852)),
                  dot(c, float3(0.2289745641, 0.6917385218, 0.0792869141)),
                  dot(c, float3(0.0, 0.0451133819, 1.0439443689)));
}
inline float3 lmXYZToP3(float3 c) {
    return float3(dot(c, float3(2.4934969119, -0.9313836179, -0.4027107845)),
                  dot(c, float3(-0.8294889696, 1.7626640603, 0.0236246858)),
                  dot(c, float3(0.0358458302, -0.0761723893, 0.9568845240)));
}
inline float3 lmBradford(float3 c) {
    return float3(dot(c, float3(0.8951, 0.2664, -0.1614)),
                  dot(c, float3(-0.7502, 1.7135, 0.0367)),
                  dot(c, float3(0.0389, -0.0685, 1.0296)));
}
inline float3 lmBradfordInverse(float3 c) {
    return float3(dot(c, float3(0.9869929055, -0.1470542564, 0.1599626517)),
                  dot(c, float3(0.4323052697, 0.5183602715, 0.0492912282)),
                  dot(c, float3(-0.0085286646, 0.0400428217, 0.9684866958)));
}
// A relative adjustment to Apple's already-developed as-shot base, not a Kelvin RAW-WB control.
inline float3 lmWhiteBalance(float3 c, float temp, float tint) {
    if (temp == 0.0 && tint == 0.0) return c;
    float y = lmLum(c);
    float3 white = float3(exp2(0.6 * temp), exp2(-0.4 * tint), exp2(-0.6 * temp));
    white /= max(lmLum(white), 1e-6);
    float3 ratio = lmBradford(lmP3ToXYZ(white)) / lmBradford(lmP3ToXYZ(float3(1.0)));
    float3 out = lmXYZToP3(lmBradfordInverse(lmBradford(lmP3ToXYZ(c)) * ratio));
    return out * (y / max(lmLum(out), 1e-6));
}

inline bool lmInGamut(float3 c) { return all(c >= 0.0) && all(c <= 1.0); }
// Compress chroma along a constant OkLab hue/lightness ray, rather than clip RGB channels.
// The original chroma raises the knee so an arbitrarily small adjustment has no onset jump.
inline float3 lmGamut(float3 lab, float originalChroma) {
    lab.x = clamp(lab.x, 0.0, 1.0);
    float C = length(lab.yz);
    if (C < 1e-5 || lab.x <= 0.0 || lab.x >= 1.0) return float3(lab.x * lab.x * lab.x);
    float3 initialRGB = lmFromLab(lab);
    if (lmInGamut(initialRGB) && (C <= originalChroma || lmInGamut(lmFromLab(float3(lab.x, lab.yz * 1.25))))) {
        return initialRGB;                       // safely below the knee: no boundary search needed
    }
    float2 direction = lab.yz / C;
    float lo = 0.0, hi = 1.0;
    for (int i = 0; i < 12; ++i) {
        float mid = (lo + hi) * 0.5;
        if (lmInGamut(lmFromLab(float3(lab.x, direction * mid)))) lo = mid;
        else hi = mid;
    }
    float knee = max(0.8 * lo, min(originalChroma, lo));
    float width = lo - knee;
    float compressed = C;
    if (width < 1e-6) compressed = min(C, lo);
    else if (C > knee) compressed = knee + width * (1.0 - exp(-(C - knee) / width));
    return clamp(lmFromLab(float3(lab.x, direction * compressed)), 0.0, 1.0);
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

// Self-guided log-luminance analysis. Moments/coefficients are spatially averaged by Swift.
float4 lumenAnalysisPack(sample_t p) { return float4(p.r, p.r * p.r, 0.0, 1.0); }
float4 lumenAnalysisCoef(sample_t m, float4 p) {
    float variance = max(m.g - m.r * m.r, 0.0);
    float a = variance / (variance + max(p.x, 1e-6));
    return float4(a, m.r * (1.0 - a), 0.0, 1.0);
}
float4 lumenAnalysisApply(sample_t guide, sample_t ab) {
    return float4(ab.r * guide.r + ab.g, 0.0, 0.0, 1.0);
}

// ------------------------------------------------------------------ the main develop kernel

inline float3 lmDevelopTone(float3 base, float4 L1, float4 L2, float3 chroma,
                              float4 pa, float4 pb, float4 pc, float4 pd, float4 pe,
                              float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float3 c = max(base, 0.0);
    // Bound the summed global/mask parameters, not each mask separately: overlapping masks cannot
    // turn the safe individual maps into a different, nonmonotonic curve.
    float ev = clamp(g0.x + pa.x * 4.0, -10.0, 10.0);
    float contrast = clamp(g0.y + pa.y, -1.0, 1.0);
    float hl = clamp(g0.z + pa.z, -1.0, 1.0);
    float sh = clamp(g0.w + pb.x, -1.0, 1.0);
    float wh = clamp(g1.x + pb.y, -1.0, 1.0);
    float bk = clamp(g1.y + pb.z, -1.0, 1.0);
    float temp = clamp(g1.z + pc.x, -1.0, 1.0);
    float tint = clamp(g1.w + pc.y, -1.0, 1.0);
    float clar = clamp(g2.w + pd.x, -1.0, 1.0);
    float tex = clamp(g2.z + pd.y, -1.0, 1.0);
    float dz = clamp(g3.x + pd.z, -1.0, 1.0);
    float sharp = clamp(g3.y + pe.x, 0.0, 0.9);
    float nrL = clamp(g3.w + pe.y, 0.0, 1.0);
    float nrC = clamp(g4.x, 0.0, 1.0);
    float br = clamp(g4.y + pe.z, -1.0, 1.0);
    float lpre = clamp(log2(max(lmLum(c), 1e-5) / 0.18), -8.0, 8.0);

    if (nrC > 0.0) {
        float y0 = max(lmLum(c), 1e-5);
        float yb = max(lmLum(chroma), 1e-5);
        float3 ch0 = c / y0, chb = chroma / yb;
        // A bounded similarity heuristic, not a learned noise estimate: suppress borrowing across
        // luminance edges, while retaining some correction for chroma outliers the old hard gate rejected.
        float distance = length(ch0 - chb);
        float edge = 1.0 - lmStep(0.5, 2.0, fabs(log2(y0 / yb)));
        float w = nrC * edge / (1.0 + 4.0 * distance * distance);
        c = mix(ch0, chb, w) * y0;
    }
    c = lmWhiteBalance(c, temp, tint);
    float expGain = exp2(ev);
    c *= expGain;

    float detailReach = 1.0;
    if (dz != 0.0) {
        float d = clamp(L2.g / max(g6.w, 1e-4), 0.0, 1.0);
        // Air shares the image's adaptation, but its brightness is bounded after exposure. A few
        // HDR lamps must not make a -1 tick pour many stops of light into the entire photograph.
        float3 air = max(lmWhiteBalance(max(g6.xyz, 0.0), temp, tint), 0.0) * expGain;
        air /= max(1.0, max(air.r, max(air.g, air.b)));
        float amount = dz * dz;                 // fine control around zero; endpoints remain useful
        float yBefore = max(lmLum(c), 1e-6);
        if (dz > 0.0) {
            float transmission = max(1.0 - 0.85 * amount * d, 0.24);
            // Limit atmosphere removal before luminance goes negative. Preserve coloured channels
            // until the constant-hue gamut mapping, rather than independently crush them to black.
            transmission = max(transmission, 1.0 - 0.95 * yBefore / max(lmLum(air), 1e-6));
            c = (c - air * (1.0 - transmission)) / transmission;
        } else {
            float haze = amount * 0.5 * (0.15 + 0.85 * d);
            c = mix(c, air * 0.9, haze);
            detailReach = clamp((1.0 - haze) * yBefore / max(lmLum(c), 1e-6), 0.0, 1.0);
        }
    }

    // Detail is modified before tone mapping, so a compressed tone curve cannot turn a safe
    // smoothing amount into reversed texture. Split the texture residual into two scales; combine
    // Texture and ordinary NR as positive residual gains, never add two independent subtractions.
    float fine = lpre - lmDec(L1.r);
    float medium = lmDec(L1.r) - lmDec(L1.g);
    float textureDetail = fine + medium;
    float edgeGate = 1.0 - lmStep(0.4, 1.6, fabs(textureDetail));
    float textureAttenuation = max(-tex, 0.0) * 0.95 * edgeGate;
    float shadow = 1.0 - lmStep(-6.0, -2.0, lpre);
    float noiseScale = 1.0 + 0.75 * shadow;
    float noiseFine = nrL * 0.9 * (1.0 - lmStep(0.1 * noiseScale, 0.5 * noiseScale, fabs(fine)));
    float noiseMedium = nrL * 0.6 * (1.0 - lmStep(0.08 * noiseScale, 0.3 * noiseScale, fabs(medium)));
    float attenuationFine = 1.0 - (1.0 - textureAttenuation) * (1.0 - noiseFine);
    float attenuationMedium = 1.0 - (1.0 - textureAttenuation) * (1.0 - noiseMedium);
    float noiseGate = lmStep(-8.0, -3.0, lpre) * (1.0 - nrL * 0.7);
    float boost = max(tex, 0.0) * 1.1 * edgeGate * noiseGate;
    float detail = ((boost - attenuationFine) * clamp(fine, -1.5, 1.5)
                     + (boost - attenuationMedium) * clamp(medium, -1.5, 1.5)) * detailReach;
    if (clar != 0.0) {
        // Both sides of this band use the same medium-resolution guide. Fine texture/noise is
        // excluded before subtracting the broad base, rather than zero-clamping useful Clarity away.
        float broad = lmDec(L1.g) - lmDec(L1.b);
        float q = (lmDec(L1.g) + ev) / 4.5;
        // L2.r is the local encoded log-light range across the broad filter's full footprint.
        // Ordinary structure stays active; hard boundaries are protected from bright/dark halos.
        float edge = 1.0 - lmStep(1.5, 3.0, max(L2.r, 0.0) * 16.0);
        float midtone = 0.35 + 0.65 * exp(-q * q);
        // Positive strength can amplify the band; negative strength stays below one so it remains
        // a convex move towards the broad base, including at frequencies outside the regression fixture.
        float amount = clar > 0.0 ? clar * 1.5 : clar * 0.98;
        detail += amount * clamp(broad, -1.4, 1.4) * edge * midtone * detailReach;
    }
    if (sharp > 0.0) {
        float ds = lpre - lmDec(L1.r);
        float masking = clamp(g3.z, 0.0, 1.0);
        float mk = masking > 0.0 ? lmStep(masking * 0.25, masking * 0.25 + 0.15, fabs(ds)) : 1.0;
        float cleanGate = 1.0 - nrL * 0.8 * (1.0 - lmStep(0.08, 0.35, fabs(ds)));
        detail += sharp * clamp(ds, -0.8, 0.8) * mk * noiseGate * cleanGate * detailReach;
    }
    c *= exp2(clamp(detail, -2.0, 2.0));

    // Compose individually increasing maps on the evolving pixel luminance. Adding their
    // overlapping deltas at the original coordinate allowed combinations to reverse a ramp.
    // Each map has positive derivative for its bounded amount; their composition does too.
    float start = log2(max(lmLum(c), 1e-6) / 0.18);
    float l = start;
    if (sh != 0.0) {
        float ws = 1.0 - lmStep(-4.8, 0.3, l);
        l += sh * 1.7 * ws * sqrt(ws);
    }
    if (hl != 0.0) l += hl * 1.7 * lmStep(-1.0, 2.8, l);
    // Brightness continues to use each pixel's own level, protecting small bright patches.
    if (br != 0.0) l += br * lmStep(-7.5, -2.5, l) * (1.0 - lmStep(-0.5, 2.4, l));
    if (wh != 0.0) l += wh * 0.8 * lmStep(0.5, 3.0, l);
    if (bk != 0.0) l += bk * 0.8 * (1.0 - lmStep(-6.0, -1.5, l));
    if (contrast != 0.0) l += contrast * 0.22 * clamp(l, -6.0, 4.0);
    return c * exp2(clamp(l - start, -4.0, 4.0));
}

// Colour part: highlight shoulder, >1 desaturation, vibrance / saturation, final clamp.
inline float3 lmDevelopColor(float3 c, float vib, float sat) {
    // Luminance shoulder before perceptual colour work.
    float y = lmLum(c);
    if (y > 0.85) {
        float yo = 0.85 + 0.15 * (1.0 - exp(-(y - 0.85) / 0.15));
        c *= yo / y;
    }
    vib = clamp(vib, -1.0, 1.0);
    sat = clamp(sat, -1.0, 1.0);
    if (vib == 0.0 && sat == 0.0 && lmInGamut(c)) return c;
    float3 lab = lmToLab(c);
    float originalChroma = length(lab.yz);
    float gain = 1.0;
    if (vib != 0.0) {
        float low = 1.0 - clamp(originalChroma / 0.22, 0.0, 1.0);
        float skin = 1.0;
        if (vib > 0.0) {
            float h = atan2(lab.z, lab.y);
            float q = (fmod(h - 0.85 + 3.14159265 + 6.2831853, 6.2831853) - 3.14159265) / 0.35;
            skin = 1.0 - 0.6 * exp(-q * q);
        }
        gain *= max(1.0 + vib * low * low * skin * 1.2, 0.0);
    }
    lab.yz *= gain * max(1.0 + sat, 0.0);
    return lmGamut(lab, originalChroma);
}

inline float3 lmDevelop(float3 base, float4 L1, float4 L2, float3 chroma,
                        float4 pa, float4 pb, float4 pc, float4 pd, float4 pe,
                        float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6) {
    float sat = g2.y + pc.z;
    float3 tone = lmDevelopTone(base, L1, L2, chroma, pa, pb, pc, pd, pe, g0, g1, g2, g3, g4, g6);
    return lmDevelopColor(tone, g2.x, sat);
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

// ------------------------------------------------------------------ HDR gain

// Per-pixel gain g >= 1 = hdrY(y) / sdrY(y) from the pre-shoulder luminance (gh.x = H, the HDR ceiling).
inline float lmHdrGain(float y, float H) {
    float k = 0.85;
    if (y <= k) return 1.0;
    float sdrY = k + (1.0 - k) * (1.0 - exp(-(y - k) / (1.0 - k)));
    float hdrY = k + (H - k) * (1.0 - exp(-(y - k) / (H - k)));
    return max(hdrY / max(sdrY, 1e-6), 1.0);
}

float4 lumenGain(sample_t img, sample_t l1, sample_t l2, sample_t ch,
                 float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6, float4 gh) {
    float4 z = float4(0.0);
    float y = lmLum(lmDevelopTone(img.rgb, l1, l2, ch.rgb, z, z, z, z, z, g0, g1, g2, g3, g4, g6));
    float g = y > 0.0 ? lmHdrGain(y, max(gh.x, 1.001)) : 1.0;
    return float4(g, g, g, 1.0);
}

float4 lumenGainLocal(sample_t img, sample_t l1, sample_t l2, sample_t ch,
                      sample_t pa, sample_t pb, sample_t pc, sample_t pd, sample_t pe,
                      float4 g0, float4 g1, float4 g2, float4 g3, float4 g4, float4 g6, float4 gh) {
    float y = lmLum(lmDevelopTone(img.rgb, l1, l2, ch.rgb, pa, pb, pc, pd, pe, g0, g1, g2, g3, g4, g6));
    float g = y > 0.0 ? lmHdrGain(y, max(gh.x, 1.001)) : 1.0;
    return float4(g, g, g, 1.0);
}

// p.x = w (0...1): how much of the gain to show. No clamp: values above 1 are the HDR highlights.
float4 lumenApplyGain(sample_t sdr, sample_t gain, float4 p) {
    if (sdr.a <= 0.0) return float4(0.0);   // empty canvas stays empty (see lumenFinish)
    return float4(sdr.rgb * exp2(p.x * log2(max(gain.r, 1.0))), 1.0);
}

// ------------------------------------------------------------------ finishing (after crop)

// g0 = (vignette amount, midpoint, feather, roundness)
// g1 = (width, height, grain amount, grain cell size)
// g2 = (grain roughness, output gamma-encoded? 1 : 0, seed, 0)
float4 lumenFinish(sample_t s, float4 g0, float4 g1, float4 g2, destination dest) {
    // Outside a straightened or transformed photo the canvas is empty (transparent). It stays empty: made opaque black
    // here, the mask overlay painted it red and the clipping warning blue (owner's screenshots, 24 Oct).
    if (s.a <= 0.0) return float4(0.0);
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
    if (s.a <= 0.0) return float4(0.0);   // empty canvas stays empty (see lumenFinish)
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

// Relative depth behind the sharp band keeps growing all the way to the farthest plane.
float4 lumenLensRamp(sample_t d, sample_t subject, float4 p) {
    float edge = clamp(p.x + p.y, 0.0, 1.0);
    float radius = clamp((d.r - edge) / max(1.0 - edge, 0.001), 0.0, 1.0);
    radius *= 1.0 - clamp(subject.r, 0.0, 1.0);
    return float4(radius, radius, radius, 1.0);
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

// Clipping warning: channels at or above p.x (white) show red, everything at or below p.y (black) shows blue
float4 lumenClip(sample_t s, float4 p) {
    // Empty canvas is transparent, not clipped black photo content.
    if (s.a <= 0.0) return float4(0.0);
    float3 rgb = s.rgb / s.a;
    float mx = max(rgb.r, max(rgb.g, rgb.b));
    if (mx >= p.x) return float4(1.0, 0.08, 0.08, 1.0) * s.a;
    if (mx <= p.y) return float4(0.1, 0.4, 1.0, 1.0) * s.a;
    return s;
}

// Band of a grey value (depth mask): same shape as the luminance band. p = (low, high, low soft edge, high soft edge)
float4 lumenRangeMask(sample_t s, float4 p) {
    float y = s.r;
    // At the ends, feather moves inward into the valid depth domain instead of becoming a no-op.
    float lo = p.x <= 0.001 ? (p.z > 0.001 ? lmStep(0.0, p.z, y) : 1.0) : lmStep(p.x - max(p.z, 0.001), p.x, y);
    float hi = p.y >= 0.999 ? (p.w > 0.001 ? 1.0 - lmStep(1.0 - p.w, 1.0, y) : 1.0) : 1.0 - lmStep(p.y, p.y + max(p.w, 0.001), y);
    float v = lo * hi;
    return float4(v, v, v, 1.0);
}

float4 lumenLensRefinedRamp(sample_t d, sample_t selection, float4 p) {
    float radius = clamp((d.r - p.x) / max(1.0 - p.x, 0.001), 0.0, 1.0);
    radius = max(radius, 0.15) * selection.r;
    return float4(radius, radius, radius, 1.0);
}

// Lens Blur, lens-like: only pixels that are themselves blurred (the background) feed the blur, carried as
// premultiplied colour so blurring then dividing by alpha averages background only (no subject colour halo).
float4 lumenLensWeigh(sample_t s, sample_t m) {
    float w = clamp(m.r * 20.0, 0.0, 1.0);
    return float4(s.rgb * w, w);
}

// Picks between the sharp photo and three disc-blurred layers (1/3, 2/3, full radius) by the blur map.
float4 lumenLensCompose(sample_t s, sample_t m, sample_t b1, sample_t b2, sample_t b3) {
    float t = clamp(m.r, 0.0, 1.0) * 3.0;
    float3 l0 = s.rgb;
    float3 l1 = b1.a > 0.02 ? b1.rgb / b1.a : l0;
    float3 l2 = b2.a > 0.02 ? b2.rgb / b2.a : l1;
    float3 l3 = b3.a > 0.02 ? b3.rgb / b3.a : l2;
    float3 c = t < 1.0 ? mix(l0, l1, t) : (t < 2.0 ? mix(l1, l2, t - 1.0) : mix(l2, l3, t - 2.0));
    return float4(c, s.a);
}

// Edge refinement (guided filter, He et al.): the photo's brightness guides a soft mask onto the real edges.
// 1. pack guide I and mask p as (I, p, I*I) and (I*p); the caller box-blurs both. Alpha stays 1: Core Image treats
//    alpha as coverage (premultiplied), so it can't carry data.
float4 lumenGFPack(sample_t g, sample_t m, float4 which) {
    float i = lmSrgbEnc(lmLum(max(g.rgb, 0.0)));
    i = clamp(i, 0.0, 1.5);
    float p = clamp(m.r, 0.0, 1.0);
    if (which.x > 0.5) return float4(i * p, 0.0, 0.0, 1.0);
    return float4(i, p, i * i, 1.0);
}
// 2. per-window linear model p = a*I + b; e.x = epsilon (how strongly edges are followed)
float4 lumenGFCoef(sample_t m, sample_t mip, float4 e) {
    float varI = max(m.z - m.x * m.x, 0.0);
    float cov = mip.r - m.x * m.y;
    float a = cov / (varI + e.x);
    float b = m.y - a * m.x;
    return float4(a, b, 0.0, 1.0);
}
// 3. apply the (box-blurred) model to the full-detail guide
//    s = (low, 1 / span): masks are stretched a little so the filter's faint tails beside an edge drop out
float4 lumenGFApply(sample_t ab, sample_t g, float4 s) {
    float i = clamp(lmSrgbEnc(lmLum(max(g.rgb, 0.0))), 0.0, 1.5);
    float q = clamp((ab.x * i + ab.y - s.x) * s.y, 0.0, 1.0);
    return float4(q, q, q, 1.0);
}

// Sky seen through trees (2026-10-11, the owner's Photomator comparison). The scene model works on a 448 px copy,
// so gaps in the leaves are lost; these find them again by colour. Colours in OkLab, highlights clamped at white.
inline float3 lmSkyLab(float3 c) { return lmToLab(clamp(c, 0.0, 1.0)); }
// 1. the sky colour field's parts: weight = how surely a pixel is sky (soft step p.x..p.y on the sky mask);
//    p.z > 0.5 = the weight alone, else colour x weight (two images: alpha can't carry data)
float4 lumenSkyWeigh(sample_t img, sample_t w, float4 p) {
    float k = lmStep(p.x, p.y, w.r);
    if (p.z > 0.5) return float4(k, k, k, 1.0);
    return float4(lmSkyLab(img.rgb) * k, 1.0);
}
// 2. the leaves' colour field: tree area that is clearly darker than the sky around it (gaps must not count as leaves)
//    sn / sd = the sky colour field (colour sum, weight); p.z as above
float4 lumenLeafWeigh(sample_t img, sample_t t, sample_t sn, sample_t sd, float4 p) {
    float3 lab = lmSkyLab(img.rgb);
    float skyL = sn.r / max(sd.r, 1e-4);
    float k = clamp(t.r, 0.0, 1.0) * (1.0 - lmStep(skyL - 0.3, skyL - 0.12, lab.x));
    if (p.z > 0.5) return float4(k, k, k, 1.0);
    return float4(lab * k, 1.0);
}
// 3. in the trees near the sky each pixel joins whichever colour it is closer to, the sky's there or the leaves';
//    elsewhere the sky mask stays as it was. p = (margin, how much sky around counts as near, 0, 0)
float4 lumenSkyGaps(sample_t img, sample_t sky, sample_t t, sample_t sn, sample_t sd, sample_t fn, sample_t fd, float4 p) {
    float s = clamp(sky.r, 0.0, 1.0);
    float zone = clamp(t.r, 0.0, 1.0) * clamp(sd.r / p.y, 0.0, 1.0) * lmStep(0.0, 0.02, fd.r);
    if (zone <= 0.0) return float4(s, s, s, 1.0);
    float3 lab = lmSkyLab(img.rgb);
    float3 sc = sn.rgb / max(sd.r, 1e-4);
    float3 fc = fn.rgb / max(fd.r, 1e-4);
    float score = lmStep(-p.x, p.x, distance(lab, fc) - distance(lab, sc));
    float v = mix(s, score, zone);
    return float4(v, v, v, 1.0);
}

// Mask overlay: tints `s` towards colour.rgb by mask * colour.a. Only where there is picture: the empty canvas around a
// transformed or zoomed-out photo is transparent and stays so (owner's screenshot, 24 Oct: a Luminance mask on the
// shadows painted the whole empty canvas red, and the clipping warning drawn after it then made it blue). Premultiplied.
float4 lumenOverlay(sample_t s, sample_t m, float4 colour) {
    float k = clamp(m.r, 0.0, 1.0) * colour.a;
    return float4(mix(s.rgb, colour.rgb * s.a, k), s.a);
}

// Heal detail (2026-10-18, owner: big removals looked blurry): the model's fill at full size plus the fine texture
// (photo minus its blurred copy) from a matching spot next to the hole, inside the hole; the photo elsewhere.
// p.x = gain (the hole's surroundings' texture / the source's), p.y = the largest step kept (no copied edges: the
// first version pasted sharp lines into a soft, lens-blurred background).
float4 lumenHealDetail(sample_t base, sample_t real, sample_t tex, sample_t texBlur, sample_t m, float4 p) {
    float3 d = clamp((tex.rgb - texBlur.rgb) * p.x, -p.y, p.y);
    float k = clamp(m.r, 0.0, 1.0);
    return float4(clamp(mix(real.rgb, base.rgb + d, k), 0.0, 1.0), 1.0);
}

// The texture's strength: squared photo-minus-blurred, averaged later over an area.
float4 lumenHealEnergy(sample_t real, sample_t blurred) {
    float3 d = real.rgb - blurred.rgb;
    float e = dot(d, d) / 3.0;
    return float4(e, e, e, 1.0);
}

// AI Denoise (21 Oct): the noise the model took out (stored once, linear light, for HDR on and off) taken out of a
// decode by `amount`. The decode's alpha is kept.
float4 lumenNoiseRemove(sample_t img, sample_t noise, float amount) {
    return float4(img.rgb - noise.rgb * amount, img.a);
}

}}
