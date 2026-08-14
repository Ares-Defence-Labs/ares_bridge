import Cocoa
import FlutterMacOS

public final class AresBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private lazy var transport = CompositeUsbHostTransport { [weak self] event in
    self?.emit(event)
  }

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
    do {
      switch call.method {
      case "getCapabilities":
        result([
          "platform": "macos",
          "isSupported": true,
          "supportsUsbHost": true,
          "supportsUsbAccessory": false,
          "supportsBidirectionalTransfer": true,
        ])
      case "initialize":
        guard let arguments = call.arguments as? [String: Any] else {
          throw UsbHostError.invalidConfiguration(
            "initialize expects a configuration map.")
        }
        try transport.initialize(arguments: arguments)
        result(nil)
      case "startListening":
        try transport.startListening()
        result(nil)
      case "stopListening":
        transport.stop()
        result(nil)
      case "sendFile":
        guard let request = call.arguments as? [String: Any] else {
          throw UsbHostError.invalidTransfer("sendFile expects a transfer map.")
        }
        result(try transport.sendFile(request))
      case "sendFiles":
        guard let requests = call.arguments as? [[String: Any]] else {
          throw UsbHostError.invalidTransfer("sendFiles expects transfer maps.")
        }
        result(try transport.sendFiles(requests))
      case "cancelTransfer":
        guard let arguments = call.arguments as? [String: Any],
              let transferId = arguments["transferId"] as? String,
              !transferId.isEmpty else {
          throw UsbHostError.invalidTransfer("cancelTransfer requires a transferId.")
        }
        transport.cancelTransfer(transferId)
        result(nil)
      case "dispose":
        transport.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(flutterError(error))
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

  private func emit(_ event: [String: Any?]) {
    let platformEvent = event.compactMapValues { $0 }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(platformEvent)
    }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    let code: String
    switch error {
    case UsbHostError.invalidConfiguration: code = "invalid_configuration"
    case UsbHostError.invalidTransfer: code = "invalid_transfer"
    case UsbHostError.notConnected: code = "not_connected"
    case UsbHostError.protocolViolation: code = "protocol_error"
    default: code = "usb_transport_error"
    }
    let message = (error as? LocalizedError)?.errorDescription
      ?? error.localizedDescription
    return FlutterError(code: code, message: message, details: nil)
  }
}
