import Cocoa
import FlutterMacOS

public final class AresBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var initialized = false
  private var localRole = "usbHost"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AresBridgePlugin()
    let methods = FlutterMethodChannel(
      name: "ares_bridge/methods",
      binaryMessenger: registrar.messenger)
    let events = FlutterEventChannel(
      name: "ares_bridge/events",
      binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result([
        "platform": "macos",
        "isSupported": false,
        "supportsUsbHost": true,
        "supportsUsbAccessory": false,
        "supportsBidirectionalTransfer": false,
        "reason": "The macOS AOA/libusb host transport has not been linked yet.",
      ])
    case "initialize":
      guard let arguments = call.arguments as? [String: Any] else {
        result(error("invalid_argument", "initialize expects a configuration map."))
        return
      }
      let requestedRole = arguments["role"] as? String ?? "automatic"
      guard requestedRole != "usbAccessory" else {
        result(error("unsupported_role", "macOS must be the USB host for Android Open Accessory."))
        return
      }
      localRole = "usbHost"
      initialized = true
      result(nil)
    case "startListening":
      guard initialized else {
        result(error("not_initialized", "Call initialize before startListening."))
        return
      }
      emitConnection("listening")
      emitConnection(
        "failed",
        message: "The macOS AOA/libusb host transport has not been linked yet.")
      result(error(
        "transport_unavailable",
        "The macOS AOA/libusb host transport has not been linked yet."))
    case "stopListening", "dispose":
      emitConnection("stopped")
      result(nil)
    case "sendFile", "sendFiles":
      result(error("not_connected", "No active Ares USB peer."))
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
