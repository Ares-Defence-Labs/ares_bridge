import Flutter
import UIKit

public final class AresBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  /// Method-channel callbacks arrive on iOS's main thread. Keep all USB
  /// listener/session work off it so refreshes and transfers cannot freeze UI.
  private let methodQueue = DispatchQueue(
    label: "com.aresdefencelabs.aresbridge.ios.methods",
    qos: .userInitiated)
  private lazy var transport = IosUsbLoopbackServer { [weak self] event in
    self?.emit(event)
  }

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
    methodQueue.async { [weak self] in
      guard let self else { return }
      do {
        let response: Any?
        switch call.method {
      case "getCapabilities":
        response = [
          "platform": "ios",
          "isSupported": true,
          "supportsUsbHost": false,
          "supportsUsbAccessory": true,
          "supportsBidirectionalTransfer": true,
          "reason":
            "Requires a trusted physical USB connection and foreground USB Mode.",
        ]
      case "initialize":
        guard let arguments = call.arguments as? [String: Any] else {
          throw IosUsbError.invalidConfiguration(
            "initialize expects a configuration map.")
        }
        try transport.initialize(arguments: arguments)
        response = nil
      case "startListening":
        try transport.startListening()
        response = nil
      case "stopListening":
        transport.stop()
        response = nil
      case "sendFile":
        guard let request = call.arguments as? [String: Any] else {
          throw IosUsbError.invalidTransfer("sendFile expects a transfer map.")
        }
        response = try transport.sendFile(request)
      case "sendFiles":
        guard let requests = call.arguments as? [[String: Any]] else {
          throw IosUsbError.invalidTransfer("sendFiles expects transfer maps.")
        }
        response = try transport.sendFiles(requests)
      case "cancelTransfer":
        guard let arguments = call.arguments as? [String: Any],
              let transferId = arguments["transferId"] as? String,
              !transferId.isEmpty else {
          throw IosUsbError.invalidTransfer(
            "cancelTransfer requires a transferId.")
        }
        transport.cancelTransfer(transferId)
        response = nil
      case "dispose":
        transport.stop()
        response = nil
      default:
        response = FlutterMethodNotImplemented
        }
        DispatchQueue.main.async { result(response) }
      } catch {
        let platformError = self.flutterError(error)
        DispatchQueue.main.async { result(platformError) }
      }
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
    DispatchQueue.main.async { [weak self] in self?.eventSink?(platformEvent) }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    let code: String
    switch error {
    case IosUsbError.invalidConfiguration: code = "invalid_configuration"
    case IosUsbError.invalidTransfer: code = "invalid_transfer"
    case IosUsbError.notConnected: code = "not_connected"
    case IosUsbError.protocolViolation: code = "protocol_error"
    default: code = "usb_transport_error"
    }
    return FlutterError(
      code: code,
      message: (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription,
      details: nil
    )
  }
}
