import Darwin
import Foundation
import IOUSBHost

/// Blocking byte stream used by the shared framed transfer session.
///
/// Android supplies IOUSBHost bulk pipes. iOS supplies a socket that has been
/// converted into a device tunnel by macOS usbmuxd. Keeping these byte streams
/// behind one interface guarantees both mobile platforms use the same framing,
/// checksum, acknowledgement, cancellation, and progress implementation.
protocol UsbSessionByteTransport: AnyObject {
  func send(_ data: Data) throws
  func receive(maxLength: Int, timeout: TimeInterval) throws -> Data?
  func close()
}

final class AndroidUsbPipeByteTransport: UsbSessionByteTransport {
  private static let outputRequestBytes = 64 * 1_024

  private let interface: IOUSBHostInterface
  private let inputPipe: IOUSBHostPipe
  private let outputPipe: IOUSBHostPipe
  private let stateLock = NSLock()
  private var closed = false

  init(
    interface: IOUSBHostInterface,
    inputPipe: IOUSBHostPipe,
    outputPipe: IOUSBHostPipe
  ) {
    self.interface = interface
    self.inputPipe = inputPipe
    self.outputPipe = outputPipe
  }

  func send(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + Self.outputRequestBytes)
      let buffer = NSMutableData(data: data.subdata(in: offset..<end))
      var transferred = 0
      do {
        try outputPipe.__sendIORequest(
          with: buffer,
          bytesTransferred: &transferred,
          completionTimeout: 5
        )
      } catch let error as NSError
        where error.code == Int(kIOReturnTimeout) && transferred > 0
      {
        NSLog(
          "[ares_bridge] USB output request timed out after %d/%d bytes; continuing",
          transferred,
          buffer.length
        )
      } catch {
        throw UsbHostError.transport(
          "USB output request failed: \(friendlyUsbTransportError(error))")
      }
      guard transferred > 0 else {
        throw UsbHostError.transport(
          "The Android USB output pipe stopped making progress.")
      }
      offset += transferred
    }
  }

  func receive(maxLength: Int, timeout: TimeInterval) throws -> Data? {
    let buffer = NSMutableData(length: maxLength)!
    var transferred = 0
    do {
      try inputPipe.__sendIORequest(
        with: buffer,
        bytesTransferred: &transferred,
        completionTimeout: timeout
      )
    } catch let error as NSError where error.code == Int(kIOReturnTimeout) {
      if transferred == 0 { return nil }
      NSLog(
        "[ares_bridge] USB input request timed out after %d bytes; continuing",
        transferred
      )
    } catch {
      throw UsbHostError.transport(
        "USB input request failed: \(friendlyUsbTransportError(error))")
    }
    guard transferred > 0 else {
      throw UsbHostError.transport("The Android USB input pipe closed.")
    }
    return Data(bytes: buffer.bytes, count: transferred)
  }

  func close() {
    let shouldClose = stateLock.withLock { () -> Bool in
      guard !closed else { return false }
      closed = true
      return true
    }
    guard shouldClose else { return }
    try? inputPipe.__abort(with: .asynchronous)
    try? outputPipe.__abort(with: .asynchronous)
    interface.destroy()
  }
}

final class UsbMuxSocketByteTransport: UsbSessionByteTransport {
  private let stateLock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) throws {
    guard descriptor >= 0 else {
      throw UsbHostError.transport("usbmuxd returned an invalid tunnel socket.")
    }
    self.descriptor = descriptor
    var enabled: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    )
  }

  func send(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let descriptor = try activeDescriptor()
      let sent = data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.send(
          descriptor,
          base.advanced(by: offset),
          data.count - offset,
          0
        )
      }
      if sent > 0 {
        offset += sent
        continue
      }
      if sent < 0 && errno == EINTR { continue }
      throw posixError("The iPhone USB tunnel could not send data")
    }
  }

  func receive(maxLength: Int, timeout: TimeInterval) throws -> Data? {
    let descriptor = try activeDescriptor()
    var pollDescriptor = pollfd(
      fd: descriptor,
      events: Int16(POLLIN),
      revents: 0
    )
    let timeoutMs = Int32(max(1, min(Double(Int32.max), timeout * 1_000)))
    let ready = Darwin.poll(&pollDescriptor, 1, timeoutMs)
    if ready == 0 { return nil }
    if ready < 0 {
      if errno == EINTR { return nil }
      throw posixError("The iPhone USB tunnel poll failed")
    }
    if pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
      throw UsbHostError.transport("The iPhone USB tunnel disconnected.")
    }

    var bytes = [UInt8](repeating: 0, count: maxLength)
    let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
    if count > 0 { return Data(bytes.prefix(count)) }
    if count < 0 && (errno == EINTR || errno == EAGAIN) { return nil }
    if count == 0 {
      throw UsbHostError.transport("The iPhone USB tunnel closed.")
    }
    throw posixError("The iPhone USB tunnel could not receive data")
  }

  func close() {
    let descriptor = stateLock.withLock { () -> Int32 in
      let current = self.descriptor
      self.descriptor = -1
      return current
    }
    guard descriptor >= 0 else { return }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }

  private func activeDescriptor() throws -> Int32 {
    try stateLock.withLock {
      guard descriptor >= 0 else {
        throw UsbHostError.transport("The iPhone USB tunnel is closed.")
      }
      return descriptor
    }
  }

  private func posixError(_ operation: String) -> UsbHostError {
    let message = String(cString: strerror(errno))
    return .transport("\(operation): \(message).")
  }
}

private func friendlyUsbTransportError(_ error: Error) -> String {
  let description = (error as? LocalizedError)?.errorDescription
    ?? error.localizedDescription
  let nativeError = error as NSError
  return "\(description) [\(nativeError.domain) \(nativeError.code)]"
}
