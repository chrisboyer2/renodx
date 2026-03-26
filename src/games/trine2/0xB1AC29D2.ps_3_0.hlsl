#include "./common.hlsl"

float4 CAMERA_CLIP_PLANES : register(c0);
float4 DOF_PROPERTIES : register(c1);
float4 GLOW_SETTINGS : register(c2);
float4 OFFSET_SCALE : register(c3);
float4 ADAPTIVE_SCREEN_BOUNDARY : register(c4);
float4 SCREEN_SIZE : register(c5);
float4 COLOR_CONTROLS : register(c6);
float4 COLOR_CONTROLS_RGB : register(c7);

sampler2D RENDERTARGET_TEXTURE : register(s0);
sampler2D DEFERRED_TEXTURE1 : register(s1);
sampler2D GLOW_TEXTURE : register(s2);
sampler2D OFFSET_TEXTURE : register(s3);

static const float kOffsetBias = -0.498039216f;
static const float kDepthScale = 0.00392156886f;
static const float kDepthThreshold = 0.1f;

struct PS_IN {
  float4 texcoord : TEXCOORD0;
  float2 texcoord1 : TEXCOORD1;
};

float4 main(PS_IN i) : COLOR {
  float2 offset = tex2D(OFFSET_TEXTURE, i.texcoord1.xy).xy + kOffsetBias.xx;

  float2 scene_texcoord = offset * OFFSET_SCALE.xy + i.texcoord.xy;
  scene_texcoord = clamp(scene_texcoord, ADAPTIVE_SCREEN_BOUNDARY.xy, ADAPTIVE_SCREEN_BOUNDARY.zw);
  float2 glow_texcoord = offset * OFFSET_SCALE.zw + i.texcoord.zw;

  float4 glow_sample = tex2D(GLOW_TEXTURE, glow_texcoord);
  float4 deferred_sample = tex2D(DEFERRED_TEXTURE1, scene_texcoord);

  float deferred_depth = deferred_sample.z + deferred_sample.w * kDepthScale;
  float near_mask = deferred_depth * CAMERA_CLIP_PLANES.y <= kDepthThreshold ? 0.f : 1.f;
  float far_mask = deferred_depth * CAMERA_CLIP_PLANES.y - DOF_PROPERTIES.x - DOF_PROPERTIES.w >= 0.f ? 0.f : 1.f;
  float blur_mask = near_mask * far_mask;
  blur_mask = blur_mask <= 0.f ? glow_sample.w : 0.f;

  float blur_blend = saturate(blur_mask * blur_mask);
  float3 scene_color = max(0.f.xxx, tex2D(RENDERTARGET_TEXTURE, scene_texcoord).rgb);
  float3 blur_color = max(0.f.xxx, tex2D(RENDERTARGET_TEXTURE, scene_texcoord + SCREEN_SIZE.zw * 0.5f).rgb);
  float3 blurred_color = lerp(scene_color, blur_color, blur_blend);

  float3 glow_color = glow_sample.rgb * GLOW_SETTINGS.z;
  float3 composite_color = CompositeGlowToWhite(blurred_color, glow_color);
  return FinalizeSceneOutput(composite_color, COLOR_CONTROLS, COLOR_CONTROLS_RGB, scene_texcoord);
}
