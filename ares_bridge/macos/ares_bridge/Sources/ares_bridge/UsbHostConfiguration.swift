import Foundation

struct UsbHostConfiguration {
  let localPeerId: String
  let localPeerName: String
  let incomingDirectory: String
  let overwritePolicy: String
  let chunkSizeBytes: Int
  let heartbeatIntervalMs: Int
  let peerTimeoutMs: Int

  init(arguments: [String: Any]) throws {
    let requestedRole = arguments["role"] as? String ?? "automatic"
    guard requestedRole != "usbAccessory" else {
      throw UsbHostError.invalidConfiguration(
        "macOS must use the USB host role.")
    }

    let heartbeat = (arguments["heartbeatIntervalMs"] as? NSNumber)?.intValue ?? 2_000
    let timeout = (arguments["peerTimeoutMs"] as? NSNumber)?.intValue ?? 8_000
    let chunkSize = (arguments["chunkSizeBytes"] as? NSNumber)?.intValue ?? 65_536
    guard heartbeat > 0, timeout > heartbeat, chunkSize > 0,
          chunkSize <= UsbWireProtocol.maxPayloadBytes else {
      throw UsbHostError.invalidConfiguration(
        "Invalid heartbeat, peer timeout, or chunk size.")
    }

    let defaultInbox = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("usb-bridge/incoming", isDirectory: true).path

    localPeerId = Self.nonEmpty(arguments["localPeerId"] as? String)
      ?? "mac-\(Host.current().localizedName ?? UUID().uuidString)"
    localPeerName = Self.nonEmpty(arguments["localPeerName"] as? String)
      ?? Host.current().localizedName
      ?? "Mac"
    incomingDirectory = Self.nonEmpty(arguments["incomingDirectory"] as? String)
      ?? defaultInbox
    overwritePolicy = arguments["overwritePolicy"] as? String ?? "rename"
    chunkSizeBytes = chunkSize
    heartbeatIntervalMs = heartbeat
    peerTimeoutMs = timeout
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
  }
}

enum UsbHostError: LocalizedError {
  case invalidConfiguration(String)
  case notConnected
  case invalidTransfer(String)
  case transport(String)
  case protocolViolation(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message),
         .invalidTransfer(let message),
         .transport(let message),
         .protocolViolation(let message):
      return message
    case .notConnected:
      return "No active USB peer."
    }
  }
}

enum UsbWireProtocol {
  static let magic: UInt32 = 0x4152_4553
  static let version: UInt8 = 1
  static let maxHeaderBytes = 1_048_576
  static let maxPayloadBytes = 16 * 1_048_576

  static let hello: UInt8 = 1
  static let ready: UInt8 = 2
  static let heartbeat: UInt8 = 3
  static let fileBegin: UInt8 = 16
  static let fileChunk: UInt8 = 17
  static let fileEnd: UInt8 = 18
  static let fileAcknowledgement: UInt8 = 19
  static let fileError: UInt8 = 20
  static let fileChunkAcknowledgement: UInt8 = 21
}
