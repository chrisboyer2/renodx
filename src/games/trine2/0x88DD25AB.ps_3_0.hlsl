#include "./shared.h"

float4 Dummy : register(c0);
float4 DummyTension : register(c3);

sampler2D RenderTargetDummy : register(s0);

static const float kFinalDecodeGamma = 2.f;
float4 main(float2 texcoord : TEXCOORD0) : COLOR {
  float4 o = tex2D(RenderTargetDummy, texcoord);

  // This feeds the RenoDX proxy path, so write an HDR-ready intermediate here
  // and let the swapchain proxy perform the final output conversion.
  if (RENODX_TONE_MAP_TYPE != 0.f) {
    float3 final_linear = renodx::color::gamma::DecodeSafe(max(0.f.xxx, o.rgb), kFinalDecodeGamma);
    // Keep this late fallback path conservative. The gameplay highlight recovery
    // now happens in 0x665CE1C2, so expanding this pass risks double-processing.
    o.rgb = renodx::draw::RenderIntermediatePass(final_linear);
  }
  return o;
}
