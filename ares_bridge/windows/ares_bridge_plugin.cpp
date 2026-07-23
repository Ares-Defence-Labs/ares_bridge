#include "ares_bridge_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>

#include <chrono>
#include <map>
#include <memory>
#include <string>
#include <utility>

namespace ares_bridge {
namespace {

constexpr char kMethodsChannel[] = "ares_bridge/methods";
constexpr char kEventsChannel[] = "ares_bridge/events";

int64_t TimestampMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

const flutter::EncodableMap* AsMap(const flutter::EncodableValue* value) {
  return value == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(value);
}

std::string StringValue(const flutter::EncodableMap& map,
                        const std::string& key,
                        const std::string& fallback) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  if (iterator == map.end()) {
    return fallback;
  }
  const auto* value = std::get_if<std::string>(&iterator->second);
  return value == nullptr ? fallback : *value;
}

flutter::EncodableValue Capabilities() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("platform"), flutter::EncodableValue("windows")},
      {flutter::EncodableValue("isSupported"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("supportsUsbHost"),
       flutter::EncodableValue(true)},
      {flutter::EncodableValue("supportsUsbAccessory"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("supportsBidirectionalTransfer"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("reason"),
       flutter::EncodableValue(
           "The Windows AOA/WinUSB host transport has not been linked yet.")},
  });
}

}  // namespace

void AresBridgePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<AresBridgePlugin>();
  auto* plugin_pointer = plugin.get();

  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kMethodsChannel,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel->SetMethodCallHandler(
      [plugin_pointer](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), kEventsChannel,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [plugin_pointer](
              const flutter::EncodableValue* arguments,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin_pointer->SetEventSink(std::move(events));
            return nullptr;
          },
          [plugin_pointer](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin_pointer->SetEventSink(nullptr);
            return nullptr;
          }));

  registrar->AddPlugin(std::move(plugin));
}

AresBridgePlugin::AresBridgePlugin() = default;
AresBridgePlugin::~AresBridgePlugin() = default;

void AresBridgePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "getCapabilities") {
    result->Success(Capabilities());
    return;
  }
  if (method == "initialize") {
    const auto* arguments = AsMap(method_call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_argument",
                    "initialize expects a configuration map.");
      return;
    }
    const auto requested_role = StringValue(*arguments, "role", "automatic");
    if (requested_role == "usbAccessory") {
      result->Error(
          "unsupported_role",
          "Windows must be the USB host for Android Open Accessory.");
      return;
    }
    local_role_ = "usbHost";
    initialized_ = true;
    result->Success();
    return;
  }
  if (method == "startListening") {
    if (!initialized_) {
      result->Error("not_initialized",
                    "Call initialize before startListening.");
      return;
    }
    EmitConnection("listening");
    const std::string message =
        "The Windows AOA/WinUSB host transport has not been linked yet.";
    EmitConnection("failed", message);
    result->Error("transport_unavailable", message);
    return;
  }
  if (method == "stopListening" || method == "dispose") {
    EmitConnection("stopped");
    result->Success();
    return;
  }
  if (method == "sendFile" || method == "sendFiles") {
    result->Error("not_connected", "No active Ares USB peer.");
    return;
  }
  if (method == "cancelTransfer") {
    result->Success();
    return;
  }
  result->NotImplemented();
}

void AresBridgePlugin::SetEventSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  event_sink_ = std::move(sink);
}

void AresBridgePlugin::EmitConnection(const std::string& state,
                                      const std::string& message) {
  if (!event_sink_) {
    return;
  }
  flutter::EncodableMap event{
      {flutter::EncodableValue("type"),
       flutter::EncodableValue("connection")},
      {flutter::EncodableValue("state"), flutter::EncodableValue(state)},
      {flutter::EncodableValue("localRole"),
       flutter::EncodableValue(local_role_)},
      {flutter::EncodableValue("timestampMs"),
       flutter::EncodableValue(TimestampMs())},
  };
  if (!message.empty()) {
    event[flutter::EncodableValue("message")] =
        flutter::EncodableValue(message);
  }
  event_sink_->Success(flutter::EncodableValue(event));
}

}  // namespace ares_bridge
