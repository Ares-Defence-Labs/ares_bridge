#ifndef FLUTTER_PLUGIN_ARES_BRIDGE_PLUGIN_H_
#define FLUTTER_PLUGIN_ARES_BRIDGE_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>

namespace ares_bridge {

class AresBridgePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  AresBridgePlugin();
  ~AresBridgePlugin() override;

  AresBridgePlugin(const AresBridgePlugin&) = delete;
  AresBridgePlugin& operator=(const AresBridgePlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetEventSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);

 private:
  void EmitConnection(const std::string& state,
                      const std::string& message = "");

  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  bool initialized_ = false;
  std::string local_role_ = "usbHost";
};

}  // namespace ares_bridge

#endif  // FLUTTER_PLUGIN_ARES_BRIDGE_PLUGIN_H_
