#include "./shared.h"

float4 GlowSettings : register(c0);
float4 CameraClipPlanes : register(c1);
float4 DOFProperties : register(c2);
float4 ScreenSize : register(c3);

sampler2D GlowHdrSourceTexture : register(s0);
sampler2D GlowSourceTexture : register(s1);
sampler2D DeferredTexture1 : register(s2);

static const float kBloomGatherScale = 0.25f;
static const float kBloomCenterWeight = 0.33f;
static const float kDeferredAlphaScale = 0.00392156886f;
static const float kFallbackDepth = -0.100000001f;

struct PS_IN {
  float4 texcoord : TEXCOORD0;
};

float4 main(PS_IN i) : COLOR {
  float2 scene_uv = i.texcoord.xy;
  float2 glow_uv = i.texcoord.zw;
  float2 glow_step = ScreenSize.zw;

  float3 glow_accum =
      tex2D(GlowHdrSourceTexture, glow_uv + glow_step).rgb +
      tex2D(GlowHdrSourceTexture, glow_uv + glow_step * float2(-1.f, 1.f)).rgb +
      tex2D(GlowHdrSourceTexture, glow_uv + glow_step * float2(1.f, -1.f)).rgb +
      tex2D(GlowHdrSourceTexture, glow_uv - glow_step).rgb;

  float3 glow_center = tex2D(GlowHdrSourceTexture, glow_uv).rgb;
  float3 glow_filtered = lerp(glow_accum * kBloomGatherScale, glow_center, kBloomCenterWeight);

  float glow_threshold = saturate(max(glow_filtered.r, max(glow_filtered.g, glow_filtered.b)) - GlowSettings.x);
  glow_filtered *= glow_threshold * GlowSettings.y;

  float4 deferred_sample = tex2D(DeferredTexture1, scene_uv);
  float deferred_depth = deferred_sample.z + deferred_sample.w * kDeferredAlphaScale;
  float clip_depth = deferred_depth * CameraClipPlanes.y;

  if (clip_depth + kDeferredAlphaScale < 0.f) {
    glow_filtered = (kFallbackDepth * CameraClipPlanes.y).xxx;
  }

  float alpha_depth = clip_depth - DOFProperties.x;
  float glow_alpha = 0.f;
  if (alpha_depth > 0.f) {
    glow_alpha = saturate(max(alpha_depth - DOFProperties.w, 0.f) * DOFProperties.z);
  }

  // GlowSourceTexture is authored into an SDR UNORM target in vanilla. Clamp
  // it back to that range before lerping toward white so float-upgraded clones
  // cannot produce negative channel fringes around bright lights.
  float3 glow_source = saturate(tex2D(GlowSourceTexture, scene_uv).rgb);

  float4 o;
  o.rgb = saturate(lerp(glow_source, 1.f.xxx, glow_filtered));
  o.a = glow_alpha;
  return o;
}
