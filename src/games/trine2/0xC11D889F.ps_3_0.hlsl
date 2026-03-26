#include "./common.hlsl"

float4 CAMERA_CLIP_PLANES : register(c0);
float4 DOF_PROPERTIES : register(c1);
float4 GLOW_SETTINGS : register(c2);
float4 OFFSET_SCALE : register(c3);
float4 ADAPTIVE_SCREEN_BOUNDARY : register(c4);
float4 COLOR_CONTROLS : register(c5);
float4 COLOR_CONTROLS_RGB : register(c6);

sampler2D RENDERTARGET_TEXTURE : register(s0);
sampler2D DEFERRED_TEXTURE1 : register(s1);
sampler2D GLOW_TEXTURE : register(s2);
sampler2D OFFSET_TEXTURE : register(s3);

static const float kOffsetBias = -0.498039216f;
static const float kDepthScale = 0.00392156886f;
static const float kDepthThreshold = 0.1f;
static const float kBlurScale = 1.25f;
static const float kAxisScale = 0.6f;
static const float kInvTapCount = 0.111111097f;

struct PS_IN {
  float4 texcoord : TEXCOORD0;
  float2 texcoord1 : TEXCOORD1;
  float4 texcoord2 : TEXCOORD2;
  float4 texcoord3 : TEXCOORD3;
};

float3 SampleScene(float2 texcoord) {
  return max(0.f.xxx, tex2D(RENDERTARGET_TEXTURE, texcoord).rgb);
}

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

  float3 glow_color = glow_sample.rgb * GLOW_SETTINGS.z;
  float blur_radius = blur_mask * blur_mask * kBlurScale;
  float2 axis = blur_radius * i.texcoord2.xy;

  float3 blurred_color = SampleScene(scene_texcoord + i.texcoord2.xy * blur_radius);
  blurred_color += SampleScene(scene_texcoord);
  blurred_color += SampleScene(scene_texcoord + i.texcoord2.zw * blur_radius);
  blurred_color += SampleScene(scene_texcoord + i.texcoord3.xy * blur_radius);
  blurred_color += SampleScene(scene_texcoord + i.texcoord3.zw * blur_radius);
  blurred_color += SampleScene(scene_texcoord + axis * float2(kAxisScale, 0.f));
  blurred_color += SampleScene(scene_texcoord + axis * float2(-kAxisScale, 0.f));
  blurred_color += SampleScene(scene_texcoord + axis * float2(0.f, kAxisScale));
  blurred_color += SampleScene(scene_texcoord + axis * float2(0.f, -kAxisScale));
  blurred_color *= kInvTapCount;

  float3 composite_color = CompositeGlowToWhite(blurred_color, glow_color);
  return FinalizeSceneOutput(composite_color, COLOR_CONTROLS, COLOR_CONTROLS_RGB, i.texcoord.xy);
}
