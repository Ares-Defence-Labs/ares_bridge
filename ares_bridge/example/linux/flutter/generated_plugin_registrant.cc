//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ares_bridge/ares_bridge_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) ares_bridge_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AresBridgePlugin");
  ares_bridge_plugin_register_with_registrar(ares_bridge_registrar);
}
