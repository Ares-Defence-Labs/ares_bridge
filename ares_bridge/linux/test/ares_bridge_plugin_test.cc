#include <flutter_linux/flutter_linux.h>
#include <gtest/gtest.h>

#include "include/ares_bridge/ares_bridge_plugin.h"

namespace ares_bridge {
namespace test {

TEST(AresBridgePlugin, RegistrationSymbolIsAvailable) {
  EXPECT_NE(&ares_bridge_plugin_register_with_registrar, nullptr);
}

}  // namespace test
}  // namespace ares_bridge
