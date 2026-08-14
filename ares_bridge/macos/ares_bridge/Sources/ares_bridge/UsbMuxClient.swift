import Darwin
import Foundation

struct UsbMuxDevice: Equatable {
  let deviceId: UInt32
  let serialNumber: String
  let connectionType: String

  var isUsb: Bool { connectionType.caseInsensitiveCompare("USB") == .orderedSame }
}

enum UsbMuxError: LocalizedError {
  case daemonUnavailable(String)
  case invalidResponse(String)
  case connectionRejected(Int)

  var errorDescription: String? {
    switch self {
    case .daemonUnavailable(let message), .invalidResponse(let message):
      return message
    case .connectionRejected(let code):
      return switch code {
      case 2: "The iPhone disconnected before the USB tunnel opened."
      case 3:
        "The iPhone is connected by USB, but AresScan+ is not listening. " +
        "Unlock the iPhone and keep USB Mode open."
      default: "macOS rejected the iPhone USB tunnel (code \(code))."
      }
    }
  }
}

/// Minimal client for the macOS usbmuxd plist protocol.
///
/// Only two operations are implemented: listing physically attached devices
/// and converting a daemon socket into a tunnel to the Ares listener port.
/// Network-attached devices are filtered before a connection is attempted.
final class UsbMuxClient {
  static let aresPort: UInt16 = 38_473

  private static let socketPath = "/var/run/usbmuxd"
  private static let plistMessage: UInt32 = 8
  private static let protocolVersion: UInt32 = 1
  private var nextTag: UInt32 = 1

  func usbDevices() throws -> [UsbMuxDevice] {
    let descriptor = try openDaemonSocket()
    defer { Darwin.close(descriptor) }
    let response = try request(
      [
        "MessageType": "ListDevices",
        "ClientVersionString": "AresBridge+ 1.0",
        "ProgName": "AresBridge+",
        "kLibUSBMuxVersion": 3,
      ],
      descriptor: descriptor
    )
    let rawDevices = response["DeviceList"] as? [[String: Any]] ?? []
    return rawDevices.compactMap { item in
      guard let id = (item["DeviceID"] as? NSNumber)?.uint32Value,
            let properties = item["Properties"] as? [String: Any],
            let serial = properties["SerialNumber"] as? String,
            let connectionType = properties["ConnectionType"] as? String
      else { return nil }
      return UsbMuxDevice(
        deviceId: id,
        serialNumber: serial,
        connectionType: connectionType
      )
    }.filter(\.isUsb)
  }

  /// Returns a socket that now carries raw bytes to the requested iPhone port.
  /// The caller owns the returned descriptor.
  func connect(_ device: UsbMuxDevice, port: UInt16 = aresPort) throws -> Int32 {
    guard device.isUsb else {
      throw UsbMuxError.invalidResponse(
        "A non-USB Apple device was rejected by the cable-only transport.")
    }
    let descriptor = try openDaemonSocket()
    do {
      let response = try request(
        [
          "MessageType": "Connect",
          "ClientVersionString": "AresBridge+ 1.0",
          "ProgName": "AresBridge+",
          "DeviceID": NSNumber(value: device.deviceId),
          // usbmuxd expects the port in network byte order inside the plist.
          "PortNumber": NSNumber(value: port.bigEndian),
          "kLibUSBMuxVersion": 3,
        ],
        descriptor: descriptor
      )
      let resultCode = (response["Number"] as? NSNumber)?.intValue ?? -1
      guard resultCode == 0 else {
        throw UsbMuxError.connectionRejected(resultCode)
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func request(
    _ payload: [String: Any],
    descriptor: Int32
  ) throws -> [String: Any] {
    let tag = nextTag
    nextTag &+= 1
    let body = try PropertyListSerialization.data(
      fromPropertyList: payload,
      format: .xml,
      options: 0
    )
    var packet = Data()
    packet.appendLittleEndian(UInt32(16 + body.count))
    packet.appendLittleEndian(Self.protocolVersion)
    packet.appendLittleEndian(Self.plistMessage)
    packet.appendLittleEndian(tag)
    packet.append(body)
    try writeAll(packet, descriptor: descriptor)

    let header = try readExactly(16, descriptor: descriptor)
    let length = Int(header.littleEndianUInt32(at: 0))
    let version = header.littleEndianUInt32(at: 4)
    let message = header.littleEndianUInt32(at: 8)
    let responseTag = header.littleEndianUInt32(at: 12)
    guard length >= 16, length <= 4 * 1_048_576,
          version == Self.protocolVersion,
          message == Self.plistMessage,
          responseTag == tag else {
      throw UsbMuxError.invalidResponse("usbmuxd returned an invalid header.")
    }
    let responseBody = try readExactly(length - 16, descriptor: descriptor)
    let object = try PropertyListSerialization.propertyList(
      from: responseBody,
      options: [],
      format: nil
    )
    guard let response = object as? [String: Any] else {
      throw UsbMuxError.invalidResponse("usbmuxd returned an invalid plist.")
    }
    return response
  }

  private func openDaemonSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw daemonError("create its client socket") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard Self.socketPath.utf8CString.count <= MemoryLayout.size(
      ofValue: address.sun_path
    ) else {
      Darwin.close(descriptor)
      throw UsbMuxError.daemonUnavailable("The usbmuxd socket path is invalid.")
    }
    Self.socketPath.withCString { source in
      withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
        _ = strcpy(destination, source)
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_un>.size)
        )
      }
    }
    guard connected == 0 else {
      let error = daemonError("connect to /var/run/usbmuxd")
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let sent = data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.send(
          descriptor,
          base.advanced(by: offset),
          data.count - offset,
          0
        )
      }
      if sent > 0 { offset += sent; continue }
      if sent < 0 && errno == EINTR { continue }
      throw daemonError("write a request")
    }
  }

  private func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      var pollDescriptor = pollfd(
        fd: descriptor,
        events: Int16(POLLIN),
        revents: 0
      )
      let ready = Darwin.poll(&pollDescriptor, 1, 2_000)
      guard ready > 0 else {
        throw daemonError("receive a response")
      }
      var buffer = [UInt8](repeating: 0, count: count - result.count)
      let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if received > 0 { result.append(contentsOf: buffer.prefix(received)); continue }
      if received < 0 && errno == EINTR { continue }
      throw daemonError("receive a response")
    }
    return result
  }

  private func daemonError(_ operation: String) -> UsbMuxError {
    .daemonUnavailable(
      "AresBridge+ could not \(operation): \(String(cString: strerror(errno))).")
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var encoded = value.littleEndian
    Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
  }

  func littleEndianUInt32(at offset: Int) -> UInt32 {
    self[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { value, item in
      value | (UInt32(item.element) << UInt32(item.offset * 8))
    }
  }
}
