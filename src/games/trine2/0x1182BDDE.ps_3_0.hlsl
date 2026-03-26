#include "./shared.h"

float4 GLOW_SETTINGS : register(c0);
float4 CAMERA_CLIP_PLANES : register(c1);
float4 DOF_PROPERTIES : register(c2);

sampler2D GLOW_HDR_SOURCE_TEXTURE : register(s0);
sampler2D GLOW_SOURCE_TEXTURE : register(s1);
sampler2D DEFERRED_TEXTURE1 : register(s2);

static const float kDepthScale = 0.00392156886f;
static const float kFallbackDepth = -0.1f;

struct PS_IN {
  float4 texcoord : TEXCOORD0;
};

float4 main(PS_IN i) : COLOR {
  float2 scene_texcoord = i.texcoord.xy;
  float2 glow_texcoord = i.texcoord.zw;

  float3 glow_filtered = tex2D(GLOW_HDR_SOURCE_TEXTURE, glow_texcoord).rgb;
  float glow_threshold = saturate(renodx::math::Max(glow_filtered) - GLOW_SETTINGS.x);
  glow_filtered *= glow_threshold * GLOW_SETTINGS.y;

  float4 deferred_sample = tex2D(DEFERRED_TEXTURE1, scene_texcoord);
  float deferred_depth = deferred_sample.z + deferred_sample.w * kDepthScale;
  float clip_depth = deferred_depth * CAMERA_CLIP_PLANES.y;

  if (clip_depth + kDepthScale < 0.f) {
    glow_filtered = (kFallbackDepth * CAMERA_CLIP_PLANES.y).xxx;
  }

  float alpha_depth = clip_depth - DOF_PROPERTIES.x;
  float glow_alpha = 0.f;
  if (alpha_depth > 0.f) {
    glow_alpha = saturate(max(alpha_depth - DOF_PROPERTIES.w, 0.f) * DOF_PROPERTIES.z);
  }

  float3 glow_source = saturate(tex2D(GLOW_SOURCE_TEXTURE, scene_texcoord).rgb);
  float3 glow_blend = saturate(glow_filtered);

  float4 o;
  o.rgb = lerp(glow_source, 1.f.xxx, glow_blend);
  o.a = glow_alpha;
  return o;
}
