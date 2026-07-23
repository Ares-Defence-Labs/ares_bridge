#include "include/ares_bridge/ares_bridge_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "ares_bridge_plugin.h"

void AresBridgePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  ares_bridge::AresBridgePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
