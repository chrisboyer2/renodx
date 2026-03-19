#include "./shared.h"

float4 CameraClipPlanes : register(c0);
float4 DOFProperties : register(c1);
float4 GlowSettings : register(c2);
float4 OffsetScale : register(c3);
float4 AdaptiveScreenBoundary : register(c4);
float4 ColorControls : register(c5);
float4 ColorControlsRgb : register(c6);

sampler2D RenderTargetTexture : register(s0);
sampler2D DeferredTexture1 : register(s1);
sampler2D GlowTexture : register(s2);
sampler2D OffsetTexture : register(s3);

static const float kOffsetBias = -0.498039216f;
static const float kDeferredAlphaScale = 0.00392156886f;
static const float kDofNearThreshold = 0.100000001f;
static const float kBlurStrengthScale = 1.25f;
static const float kBlurAxisScale = 0.600000024f;
static const float kBlurSampleWeight = 0.111111097f;
static const float3 kColorControlsLuma = float3(0.212500006f, 0.715399981f, 0.0720999986f);
static const float3 kOutputLuma = float3(0.298999995f, 0.587000012f, 0.114f);
static const float kSceneGamma = 2.f;
static const float kHighlightSafetyStart = 0.85f;

struct PS_IN {
  float4 texcoord : TEXCOORD0;
  float2 texcoord1 : TEXCOORD1;
  float4 texcoord2 : TEXCOORD2;
  float4 texcoord3 : TEXCOORD3;
};

float2 ClampSceneUv(float2 uv) {
  return min(max(AdaptiveScreenBoundary.xy, uv), AdaptiveScreenBoundary.zw);
}

float3 SampleSceneSquared(float2 uv) {
  // Clamp float-upgraded scene samples back to the vanilla nonnegative domain
  // before the original square/sqrt blur composite.
  float3 sample_rgb = max(0.f.xxx, tex2D(RenderTargetTexture, uv).rgb);
  return sample_rgb * sample_rgb;
}

float3 SampleComposite(float2 scene_uv, float blur_scale, float4 texcoord2, float4 texcoord3) {
  float2 blur_axis = blur_scale * texcoord2.xy;

  float3 accumulated =
      SampleSceneSquared(scene_uv + texcoord2.xy * blur_scale) +
      SampleSceneSquared(scene_uv) +
      SampleSceneSquared(scene_uv + texcoord2.zw * blur_scale) +
      SampleSceneSquared(scene_uv + texcoord3.xy * blur_scale) +
      SampleSceneSquared(scene_uv + texcoord3.zw * blur_scale) +
      SampleSceneSquared(scene_uv + blur_axis * float2(kBlurAxisScale, 0.f)) +
      SampleSceneSquared(scene_uv + blur_axis * float2(-kBlurAxisScale, 0.f)) +
      SampleSceneSquared(scene_uv + blur_axis * float2(0.f, kBlurAxisScale)) +
      SampleSceneSquared(scene_uv + blur_axis * float2(0.f, -kBlurAxisScale));

  return sqrt(accumulated * kBlurSampleWeight);
}

float3 CompressPeakHighlights(float3 linear_rgb) {
  float peak_ratio = max(1.f, RENODX_PEAK_WHITE_NITS / max(1.f, RENODX_DIFFUSE_WHITE_NITS));
  float rolloff_start = max(1.f, peak_ratio * kHighlightSafetyStart);
  float max_channel = max(linear_rgb.r, max(linear_rgb.g, linear_rgb.b));

  if (max_channel <= rolloff_start || peak_ratio <= rolloff_start) {
    return linear_rgb;
  }

  // Preserve recovered scene detail until it approaches display headroom, then
  // softly compress only the hottest peaks.
  float compressed_peak = renodx::tonemap::ExponentialRollOff(max_channel, rolloff_start, peak_ratio);
  return linear_rgb * (compressed_peak / max_channel);
}

float3 RecoverHighlightLuminance(float3 hdr_linear, float3 sdr_linear) {
  float hdr_luma = max(0.f, dot(hdr_linear, kColorControlsLuma));
  float sdr_luma = max(1e-4f, dot(sdr_linear, kColorControlsLuma));

  // Keep the SDR-domain color as the hue/chroma reference and recover only
  // additional luminance from the upgraded scene buffer.
  float3 luminance_recovered = max(0.f.xxx, sdr_linear * (hdr_luma / sdr_luma));
  return CompressPeakHighlights(luminance_recovered);
}

float4 main(PS_IN i) : COLOR {
  float4 o;

  // These auxiliaries were authored for UNORM render targets. Clamp them back
  // to the vanilla domain before using them so float-upgraded clones cannot
  // introduce extra UV skew or colored bloom fringing.
  float2 offset = saturate(tex2D(OffsetTexture, i.texcoord1).xy) + kOffsetBias;
  float2 scene_uv = ClampSceneUv(i.texcoord.xy + offset * OffsetScale.xy);
  float2 glow_uv = i.texcoord.zw + offset * OffsetScale.zw;

  float4 glow_sample = saturate(tex2D(GlowTexture, glow_uv));
  float4 deferred_sample = saturate(tex2D(DeferredTexture1, scene_uv));

  float deferred_depth = deferred_sample.z + deferred_sample.w * kDeferredAlphaScale;
  float dof_near_mask = (kDofNearThreshold - deferred_depth * CameraClipPlanes.y >= 0.f) ? 0.f : 1.f;
  float dof_far_mask = (deferred_depth * CameraClipPlanes.y - DOFProperties.x - DOFProperties.w >= 0.f) ? 0.f : 1.f;
  float glow_weight = (dof_near_mask * dof_far_mask <= 0.f) ? glow_sample.w : 0.f;

  float blur_scale = glow_weight * glow_weight * kBlurStrengthScale;
  float3 blurred_scene = SampleComposite(scene_uv, blur_scale, i.texcoord2, i.texcoord3);
  float3 blurred_scene_sdr = saturate(blurred_scene);
  float blurred_scene_luma = max(0.f, dot(blurred_scene, kColorControlsLuma));
  float blurred_scene_sdr_luma = max(1e-4f, dot(blurred_scene_sdr, kColorControlsLuma));
  float3 blurred_scene_recovered = blurred_scene_sdr * (blurred_scene_luma / blurred_scene_sdr_luma);
  float3 scene_headroom = max(0.f.xxx, blurred_scene_recovered - blurred_scene_sdr);
  float3 glow_blend = saturate(glow_sample.rgb * GlowSettings.z);
  // Keep the vanilla SDR-domain glow blend, then restore any recovered scene
  // headroom afterward.
  float3 composited_scene = lerp(blurred_scene_sdr, 1.f.xxx, glow_blend) + scene_headroom;

  float3 graded_scene = composited_scene * ColorControls.y;
  float graded_luma = dot(graded_scene, kColorControlsLuma);
  graded_scene = lerp(graded_luma.xxx, graded_scene, ColorControls.z);
  graded_scene = ColorControls.x * (graded_scene - 0.5f.xxx) + 0.5f.xxx;
  float3 graded_scene_hdr = max(0.f.xxx, graded_scene * ColorControlsRgb.xyz);
  float3 graded_scene_sdr = saturate(graded_scene_hdr);

  if (RENODX_TONE_MAP_TYPE != 0.f) {
    // Preserve the unclamped late-scene signal in RGB, but keep FXAA alpha on
    // the SDR luma that the original pass expects.
    float3 graded_scene_hdr_linear = renodx::color::gamma::DecodeSafe(graded_scene_hdr, kSceneGamma);
    float3 graded_scene_sdr_linear = renodx::color::gamma::DecodeSafe(graded_scene_sdr, kSceneGamma);
    o.rgb = renodx::color::gamma::EncodeSafe(
        RecoverHighlightLuminance(graded_scene_hdr_linear, graded_scene_sdr_linear),
        kSceneGamma);
  } else {
    o.rgb = graded_scene_sdr;
  }

  o.a = dot(graded_scene_sdr, kOutputLuma);
  return o;
}
