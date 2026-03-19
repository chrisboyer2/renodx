/*
 * Copyright (C) 2026 Carlos Lopez
 * SPDX-License-Identifier: MIT
 */

#define ImTextureID ImU64

#define RENODX_MODS_SWAPCHAIN_VERSION 2

#define DEBUG_LEVEL_0

#include <algorithm>
#include <cmath>

#include <deps/imgui/imgui.h>
#include <include/reshade.hpp>

#include <embed/shaders.h>

#include "../../mods/shader.hpp"
#include "../../mods/swapchain.hpp"
#include "../../utils/device_proxy.hpp"
#include "../../utils/pipeline_layout.hpp"
#include "../../utils/resource.hpp"
#include "../../utils/shader.hpp"
#include "../../templates/settings.hpp"
#include "../../utils/settings.hpp"
#include "../../utils/swapchain.hpp"
#include "./shared.h"

namespace {

renodx::mods::shader::CustomShaders custom_shaders = {
    CustomShaderEntry(0xE257D67B),
    CustomShaderEntry(0x665CE1C2),
    CustomShaderEntry(0x88DD25AB),
};

ShaderInjectData shader_injection = {
    .peak_white_nits = 1000.f,
    .diffuse_white_nits = 203.f,
    .graphics_white_nits = 203.f,
    .color_grade_strength = 1.f,
    .tone_map_type = 3.f,
    .tone_map_exposure = 1.f,
    .tone_map_highlights = 1.f,
    .tone_map_shadows = 1.f,
    .tone_map_contrast = 1.f,
    .tone_map_saturation = 1.f,
    .tone_map_highlight_saturation = 1.f,
    .tone_map_blowout = 0.f,
    .tone_map_flare = 0.f,
    .tone_map_hue_correction = 1.f,
    .tone_map_hue_shift = 0.5f,
    .tone_map_working_color_space = 2.f,
    .tone_map_clamp_color_space = 0.f,
    .tone_map_clamp_peak = 0.f,
    .tone_map_hue_processor = 0.f,
    .tone_map_per_channel = 0.f,
    .gamma_correction = 0.f,
    .intermediate_scaling = 0.f,
    .intermediate_encoding = 2.f,
    .intermediate_color_space = 0.f,
    .swap_chain_decoding = 2.f,
    .swap_chain_gamma_correction = 0.f,
    .swap_chain_custom_color_space = 0.f,
    .swap_chain_clamp_color_space = -1.f,
    .swap_chain_encoding = 5.f,
    .swap_chain_encoding_color_space = 0.f,
    .custom_flip_uv_y = 0.f,
};

void SyncUiBrightness() {
  // Trine 2's stable UI path uses late vanilla sprite draws directly into the
  // upgraded swapchain target, so an independent UI nit control is misleading.
  shader_injection.graphics_white_nits = shader_injection.diffuse_white_nits;
}

void ApplyFixedTonemapConfig() {
  // Trine 2 uses a fixed late-scene recovery path, so keep the unused shared
  // tonemap controls pinned to neutral values.
  shader_injection.tone_map_type = 3.f;
  shader_injection.gamma_correction = 0.f;
  shader_injection.tone_map_per_channel = 0.f;
  shader_injection.tone_map_hue_processor = 0.f;
  shader_injection.tone_map_hue_correction = 1.f;
  shader_injection.tone_map_hue_shift = 0.5f;
  shader_injection.tone_map_clamp_color_space = 0.f;
  shader_injection.tone_map_clamp_peak = 0.f;
  shader_injection.color_grade_strength = 1.f;
  shader_injection.tone_map_exposure = 1.f;
  shader_injection.tone_map_highlights = 1.f;
  shader_injection.tone_map_shadows = 1.f;
  shader_injection.tone_map_contrast = 1.f;
  shader_injection.tone_map_saturation = 1.f;
  shader_injection.tone_map_highlight_saturation = 1.f;
  shader_injection.tone_map_blowout = 0.f;
  shader_injection.tone_map_flare = 0.f;
  shader_injection.tone_map_working_color_space = 2.f;
}

renodx::utils::settings::Settings CreateSettings() {
  auto created_settings = renodx::templates::settings::CreateDefaultSettings({
      {"ToneMapPeakNits",
       {
           .binding = &shader_injection.peak_white_nits,
           .tooltip = "Sets the display peak used by the RenoDX output path.",
       }},
      {"ToneMapGameNits",
       {
           .binding = &shader_injection.diffuse_white_nits,
           .tooltip = "Sets paper white for Trine 2's recovered scene and late UI path.",
      }},
  });

  created_settings.erase(
      std::remove_if(
          created_settings.begin(),
          created_settings.end(),
          [](const auto* setting) { return setting->key == "SettingsMode"; }),
      created_settings.end());

  for (auto* setting : created_settings) {
    if (setting->key == "ToneMapGameNits") {
      setting->on_change_value = [](float, float) { SyncUiBrightness(); };
    }
  }

  return created_settings;
}

renodx::utils::settings::Settings settings = CreateSettings();

bool initialized = false;
bool fired_on_init_swapchain = false;

void OnPresetOff() {
  shader_injection.tone_map_type = 0.f;
  renodx::utils::settings::UpdateSettings({
      {"ToneMapPeakNits", 203.f},
      {"ToneMapGameNits", 203.f},
  });
  SyncUiBrightness();
}

void OnInitSwapchain(reshade::api::swapchain* swapchain, bool resize) {
  if (resize || fired_on_init_swapchain) return;
  if (!renodx::utils::swapchain::IsDXGI(swapchain)) return;

  const float peak_nits = renodx::utils::swapchain::GetPeakNits(swapchain).value_or(1000.f);
  for (auto* setting : settings) {
    if (setting->key != "ToneMapPeakNits") continue;
    setting->default_value = std::round(peak_nits);
    setting->can_reset = true;
    break;
  }
  fired_on_init_swapchain = true;
}

void ConfigureIgnoredApis() {
  const auto ignored_apis = {
      reshade::api::device_api::d3d11,
      reshade::api::device_api::d3d12,
      reshade::api::device_api::vulkan,
  };

  renodx::utils::resource::ignored_device_apis = ignored_apis;
  renodx::utils::pipeline_layout::ignored_device_apis = ignored_apis;
  renodx::utils::shader::ignored_device_apis = ignored_apis;
  renodx::utils::swapchain::ignored_device_apis = ignored_apis;
  renodx::mods::shader::ignored_device_apis = ignored_apis;
  renodx::mods::swapchain::ignored_device_apis = ignored_apis;
}

void ConfigureSwapchainProxy() {
  renodx::mods::swapchain::expected_constant_buffer_index = 13;
  renodx::mods::swapchain::expected_constant_buffer_space = 50;
  renodx::mods::swapchain::force_borderless = false;
  renodx::mods::swapchain::prevent_full_screen = false;
  renodx::mods::swapchain::force_screen_tearing = false;
  renodx::mods::swapchain::set_color_space = false;
  renodx::mods::swapchain::use_device_proxy = true;
  renodx::mods::swapchain::use_resource_cloning = true;
  renodx::mods::swapchain::device_proxy_wait_idle_source = true;
  renodx::mods::swapchain::device_proxy_wait_idle_destination = true;
  renodx::utils::device_proxy::SetAllowTearing(false);
  renodx::utils::device_proxy::SetPresentSyncInterval(1u);
  renodx::mods::swapchain::swap_chain_proxy_vertex_shader = __swap_chain_proxy_vertex_shader_dx11;
  renodx::mods::swapchain::swap_chain_proxy_pixel_shader = __swap_chain_proxy_pixel_shader_dx11;

  renodx::mods::swapchain::swap_chain_upgrade_targets.push_back({
      .old_format = reshade::api::format::b8g8r8a8_unorm,
      .new_format = reshade::api::format::r16g16b16a16_float,
      .use_resource_view_cloning = true,
  });
  renodx::mods::swapchain::swap_chain_upgrade_targets.push_back({
      // The late scene color feeding 0x665CE1C2 is packed into a full-size
      // RGB10A2 render target before our shader sees it. Upgrade that target
      // so the recovered path can keep the original scene detail intact.
      .old_format = reshade::api::format::r10g10b10a2_unorm,
      .new_format = reshade::api::format::r16g16b16a16_float,
      .usage_include = reshade::api::resource_usage::render_target,
  });
  renodx::mods::swapchain::swap_chain_upgrade_targets.push_back({
      .old_format = reshade::api::format::r16g16b16a16_unorm,
      .new_format = reshade::api::format::r16g16b16a16_float,
      .ignore_size = true,
      .use_resource_view_cloning = true,
  });
}

void ConfigureShaderRuntime() {
  renodx::mods::shader::force_pipeline_cloning = true;
  renodx::mods::shader::allow_multiple_push_constants = true;
  renodx::mods::shader::constant_buffer_offset = 50 * 4;
  renodx::mods::shader::expected_constant_buffer_index = 13;
  renodx::mods::shader::expected_constant_buffer_space = 50;
}

}  // namespace

extern "C" __declspec(dllexport) constexpr const char* NAME = "RenoDX";
extern "C" __declspec(dllexport) constexpr const char* DESCRIPTION = "RenoDX (Trine 2)";

BOOL APIENTRY DllMain(HMODULE h_module, DWORD fdw_reason, LPVOID) {
  switch (fdw_reason) {
    case DLL_PROCESS_ATTACH:
      if (!reshade::register_addon(h_module)) return FALSE;
      reshade::register_event<reshade::addon_event::init_swapchain>(OnInitSwapchain);

      if (!initialized) {
        renodx::utils::settings::on_preset_changed_callbacks.emplace_back(&SyncUiBrightness);
        ConfigureShaderRuntime();
        ConfigureIgnoredApis();
        ConfigureSwapchainProxy();

        initialized = true;
      }
      break;
    case DLL_PROCESS_DETACH:
      reshade::unregister_event<reshade::addon_event::init_swapchain>(OnInitSwapchain);
      reshade::unregister_addon(h_module);
      break;
  }

  renodx::utils::settings::Use(fdw_reason, &settings, &OnPresetOff);
  if (fdw_reason == DLL_PROCESS_ATTACH) {
    ApplyFixedTonemapConfig();
    SyncUiBrightness();
  }
  renodx::mods::swapchain::Use(fdw_reason, &shader_injection);
  renodx::mods::shader::Use(fdw_reason, custom_shaders, &shader_injection);

  return TRUE;
}
