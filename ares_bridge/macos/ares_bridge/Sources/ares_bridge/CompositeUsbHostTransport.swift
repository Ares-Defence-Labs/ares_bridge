import Foundation

final class CompositeUsbHostTransport {
  typealias EventHandler = ([String: Any?]) -> Void

  private enum Source { case android, ios }

  private enum ArbitrationAction {
    case pause(Source)
    case resume(Source)
  }

  private let eventHandler: EventHandler
  private let stateLock = NSLock()
  private let arbitrationQueue = DispatchQueue(
    label: "usb.bridge.macos.transport-arbitration"
  )
  private var activeSource: Source?
  private var pendingSources: Set<Source> = []
  private var pausedSources: Set<Source> = []
  private var lastConnectionState: String?
  private var listening = false
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
    let shouldStart = stateLock.withLock { () -> Bool in
      guard !listening else { return false }
      listening = true
      return true
    }
    guard shouldStart else { return }
    do {
      try android.startListening()
      try ios.startListening()
    } catch {
      android.stop()
      ios.stop()
      stateLock.withLock { listening = false }
      throw error
    }
  }

  func stop() {
    stateLock.withLock {
      listening = false
      activeSource = nil
      pendingSources.removeAll()
      pausedSources.removeAll()
      lastConnectionState = nil
    }
    android.stop()
    ios.stop()
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
    if let selected = stateLock.withLock({ activeSource }) {
      return selected
    }
    if android.isConnected { return .android }
    if ios.isConnected { return .ios }
    return nil
  }

  private func handle(_ event: [String: Any?], from source: Source) {
    guard event["type"] as? String == "connection" else {
      let shouldEmit = stateLock.withLock {
        listening && activeSource == source
      }
      if shouldEmit { eventHandler(event) }
      return
    }
    guard let state = event["state"] as? String else { return }

    let decision = stateLock.withLock { () -> (Bool, ArbitrationAction?) in
      guard listening else { return (false, nil) }

      switch state {
      case "connecting", "peerReady":
        pendingSources.insert(source)
      case "active":
        pendingSources.insert(source)
        if let activeSource, activeSource != source {
          return (false, .pause(source))
        }
        activeSource = source
        let other: Source = source == .android ? .ios : .android
        return (true, .pause(other))
      case "failed", "disconnected":
        if activeSource == source {
          activeSource = nil
          pendingSources.remove(source)
          let other: Source = source == .android ? .ios : .android
          return (true, .resume(other))
        }
        pendingSources.remove(source)
        if activeSource != nil || !pendingSources.isEmpty {
          return (false, nil)
        }
      case "stopped":
        pendingSources.remove(source)
        if activeSource != nil || pausedSources.contains(source) {
          return (false, nil)
        }
      default:
        break
      }

      if let activeSource, activeSource != source { return (false, nil) }
      if state == lastConnectionState, state == "listening" || state == "stopped" {
        return (false, nil)
      }
      lastConnectionState = state
      return (true, nil)
    }
    if decision.0 { eventHandler(event) }
    if let action = decision.1 { perform(action) }
  }

  private func perform(_ action: ArbitrationAction) {
    let shouldSchedule = stateLock.withLock { () -> Bool in
      guard listening else { return false }
      switch action {
      case .pause(let source):
        return pausedSources.insert(source).inserted
      case .resume(let source):
        return pausedSources.remove(source) != nil
      }
    }
    guard shouldSchedule else { return }

    switch action {
    case .pause(.android): android.setFailureReportingEnabled(false)
    case .resume(.android): android.setFailureReportingEnabled(true)
    default: break
    }

    arbitrationQueue.async { [weak self] in
      guard let self else { return }
      switch action {
      case .pause(.android): self.android.stop()
      case .pause(.ios): self.ios.stop()
      case .resume(.android):
        do { try self.android.startListening() }
        catch { self.emitArbitrationFailure(error) }
      case .resume(.ios):
        do { try self.ios.startListening() }
        catch { self.emitArbitrationFailure(error) }
      }
    }
  }

  private func emitArbitrationFailure(_ error: Error) {
    let shouldEmit = stateLock.withLock { listening && activeSource == nil }
    guard shouldEmit else { return }
    eventHandler([
      "type": "connection",
      "state": "failed",
      "localRole": "usbHost",
      "message": (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription,
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1_000),
    ])
  }
}
