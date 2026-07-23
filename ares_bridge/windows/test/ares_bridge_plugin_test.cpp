#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "ares_bridge_plugin.h"

namespace ares_bridge {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(AresBridgePlugin, ReportsCapabilities) {
  AresBridgePlugin plugin;
  EncodableMap capabilities;
  plugin.HandleMethodCall(
      MethodCall("getCapabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&capabilities](const EncodableValue* result) {
            capabilities = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(
      std::get<std::string>(
          capabilities.at(EncodableValue("platform"))),
      "windows");
}

}  // namespace test
}  // namespace ares_bridge
