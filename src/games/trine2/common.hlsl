#include "./shared.h"

static const float3 kBt709Luma = float3(0.212500006f, 0.715399981f, 0.0720999986f);

float3 HermiteSplineRolloff(float3 hdr_color) {
  return lerp(
      renodx::tonemap::HermiteSplineLuminanceRolloff(hdr_color),
      renodx::tonemap::HermiteSplinePerChannelRolloff(hdr_color),
      RENODX_TONE_MAP_HUE_SHIFT);
}

float3 ToneMapPass(float3 hdr_color, float3 sdr_color, float3 hdr_color_tm, float2 texcoord) {
  float3 output_color;
  if (RENODX_TONE_MAP_TYPE == 0) {
    output_color = saturate(sdr_color);
  } else if (RENODX_TONE_MAP_TYPE == 2) {
    // Trine 2 does not have a trustworthy SDR reference for ACES upgrade.
    // Feed the scene HDR directly into the shared ACES pipeline instead.
    output_color = renodx::draw::ToneMapPass(hdr_color);
  } else {
    output_color = renodx::draw::ToneMapPass(hdr_color, sdr_color, hdr_color_tm);
  }
  return output_color;
}

float3 ApplyColorControls(float3 color, float4 color_controls, float4 color_controls_rgb) {
  float3 brightened_color = color * color_controls.y;
  float brightened_luma = dot(brightened_color, kBt709Luma);
  float3 saturated_color = lerp(brightened_luma.xxx, brightened_color, color_controls.z);
  float3 contrast_color = (saturated_color - 0.5f.xxx) * color_controls.x + 0.5f.xxx;
  return contrast_color * color_controls_rgb.rgb;
}

float3 CompositeGlowToWhite(float3 source_color, float3 glow_blend) {
  return lerp(max(0.f.xxx, source_color), 1.f.xxx, saturate(glow_blend));
}

float4 FinalizeSceneOutput(float3 composite_color, float4 color_controls, float4 color_controls_rgb, float2 texcoord) {
  float4 o;
  float3 hdr_color = max(0.f.xxx, ApplyColorControls(composite_color, color_controls, color_controls_rgb));
  float3 sdr_color = saturate(hdr_color);
  float3 hdr_color_tm = HermiteSplineRolloff(hdr_color);

  o.rgb = ToneMapPass(hdr_color, sdr_color, hdr_color_tm, texcoord);
  o.rgb = renodx::draw::RenderIntermediatePass(o.rgb);
  o.a = renodx::color::y::from::BT709(o.rgb);
  o.rgb = renodx::color::srgb::DecodeSafe(o.rgb);
  return o;
}
