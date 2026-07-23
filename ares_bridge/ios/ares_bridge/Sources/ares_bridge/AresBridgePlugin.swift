import Flutter
import UIKit

public final class AresBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var localRole = "automatic"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AresBridgePlugin()
    let methods = FlutterMethodChannel(
      name: "ares_bridge/methods",
      binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(
      name: "ares_bridge/events",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result([
        "platform": "ios",
        "isSupported": false,
        "supportsUsbHost": false,
        "supportsUsbAccessory": false,
        "supportsBidirectionalTransfer": false,
        "reason": "iOS does not expose the Android Open Accessory raw USB transport.",
      ])
    case "initialize":
      if let arguments = call.arguments as? [String: Any] {
        localRole = arguments["role"] as? String ?? "automatic"
      }
      result(nil)
    case "startListening":
      emitConnection(
        "failed",
        message: "iOS does not expose the Android Open Accessory raw USB transport.")
      result(error(
        "unsupported_platform",
        "iOS does not expose the Android Open Accessory raw USB transport."))
    case "stopListening", "dispose":
      emitConnection("stopped")
      result(nil)
    case "sendFile", "sendFiles":
      result(error(
        "unsupported_platform",
        "Ares USB file transfer is unavailable on iOS."))
    case "cancelTransfer":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emitConnection(_ state: String, message: String? = nil) {
    var event: [String: Any] = [
      "type": "connection",
      "state": state,
      "localRole": localRole,
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let message {
      event["message"] = message
    }
    eventSink?(event)
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}
