import Foundation

final class CompositeUsbHostTransport {
  typealias EventHandler = ([String: Any?]) -> Void

  private enum Source { case android, ios }

  private let eventHandler: EventHandler
  private let stateLock = NSLock()
  private var activeSource: Source?
  private var lastConnectionState: String?
  private lazy var android = UsbHostTransport { [weak self] event in
    self?.handle(event, from: .android)
  }
  private lazy var ios = IosUsbMuxHostTransport { [weak self] event in
    self?.handle(event, from: .ios)
  }

  init(eventHandler: @escaping EventHandler) {
    self.eventHandler = eventHandler
  }

  func initialize(arguments: [String: Any]) throws {
    try android.initialize(arguments: arguments)
    try ios.initialize(arguments: arguments)
  }

  func startListening() throws {
    try android.startListening()
    try ios.startListening()
  }

  func stop() {
    android.stop()
    ios.stop()
    stateLock.withLock {
      activeSource = nil
      lastConnectionState = nil
    }
  }

  func sendFile(_ request: [String: Any]) throws -> String {
    switch connectedSource() {
    case .android: return try android.sendFile(request)
    case .ios: return try ios.sendFile(request)
    case nil: throw UsbHostError.notConnected
    }
  }

  func sendFiles(_ requests: [[String: Any]]) throws -> [String] {
    switch connectedSource() {
    case .android: return try android.sendFiles(requests)
    case .ios: return try ios.sendFiles(requests)
    case nil: throw UsbHostError.notConnected
    }
  }

  func cancelTransfer(_ transferId: String) {
    android.cancelTransfer(transferId)
    ios.cancelTransfer(transferId)
  }

  private func connectedSource() -> Source? {
    if android.isConnected { return .android }
    if ios.isConnected { return .ios }
    return stateLock.withLock { activeSource }
  }

  private func handle(_ event: [String: Any?], from source: Source) {
    guard event["type"] as? String == "connection",
          let state = event["state"] as? String else {
      eventHandler(event)
      return
    }

    let shouldEmit = stateLock.withLock { () -> Bool in
      if state == "active" { activeSource = source }
      if (state == "disconnected" || state == "failed"), activeSource == source {
        activeSource = nil
      }
      if let activeSource, activeSource != source { return false }
      if state == lastConnectionState, state == "listening" || state == "stopped" {
        return false
      }
      lastConnectionState = state
      return true
    }
    if shouldEmit { eventHandler(event) }
  }
}
