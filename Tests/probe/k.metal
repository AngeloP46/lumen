#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
    float4 probeKernel(sample_t s, float4 mul) {
        return float4(s.rgb * mul.rgb, 1.0);
    }
}}
