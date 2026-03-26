#include "./shared.h"

float3 HermiteSplineRolloff(float3 hdr_color) {
  return lerp(
      renodx::tonemap::HermiteSplineLuminanceRolloff(hdr_color),
      renodx::tonemap::HermiteSplinePerChannelRolloff(hdr_color),
      RENODX_TONE_MAP_HUE_SHIFT);
}

float3 ToneMapPass(float3 hdr_color, float3 sdr_color, float3 hdr_color_tm, float2 texcoord) {
  float3 output_color;
  if (RENODX_TONE_MAP_TYPE == 0 || RENODX_TONE_MAP_TYPE == 2) {
    output_color = saturate(sdr_color);
  } else {
    output_color = renodx::draw::ToneMapPass(hdr_color, sdr_color, hdr_color_tm);
  }
  return output_color;
}
