library;

import 'ares_bridge_platform_interface.dart';
import 'src/ares_bridge_models.dart';

export 'src/ares_bridge_models.dart';

/// Cross-platform API for discovering an Ares peer and transferring files.
///
/// The platform implementation owns the USB transport. This class deliberately
/// exposes transport-neutral events so the same application code can run on a
/// USB host (Windows or macOS) and a USB accessory (Android).
class AresBridge {
  AresBridge({AresBridgePlatform? platform})
    : _platform = platform ?? AresBridgePlatform.instance;

  final AresBridgePlatform _platform;

  /// Every event produced by the bridge.
  ///
  /// This is a broadcast stream. A native implementation must never report a
  /// transfer as completed until the received file has been flushed, closed,
  /// and (when available) checksum-verified.
  Stream<AresBridgeEvent> get events => _platform.events;

  /// Connection and peer-readiness changes.
  ///
  /// A USB host receives [AresConnectionState.peerReady] when the accessory
  /// announces that it is listening, followed by [AresConnectionState.active]
  /// once the protocol handshake and heartbeat are established.
  Stream<AresConnectionEvent> get connectionEvents =>
      events.where((event) => event is AresConnectionEvent).cast();

  /// Live progress for both incoming and outgoing transfers.
  Stream<AresTransferProgress> get transferProgress =>
      events.where((event) => event is AresTransferProgress).cast();

  /// Successful incoming and outgoing transfers.
  Stream<AresTransferCompleted> get completedTransfers =>
      events.where((event) => event is AresTransferCompleted).cast();

  /// Successfully received files only.
  ///
  /// This is the listener Android clients normally use to refresh their UI
  /// after a file sent from the desktop has become available locally.
  Stream<AresTransferCompleted> get receivedFiles => completedTransfers.where(
    (event) => event.direction == AresTransferDirection.incoming,
  );

  /// Failed incoming and outgoing transfers.
  Stream<AresTransferFailed> get failedTransfers =>
      events.where((event) => event is AresTransferFailed).cast();

  /// Configures the bridge before it starts listening or sending.
  Future<void> initialize([
    AresBridgeConfiguration configuration = const AresBridgeConfiguration(),
  ]) {
    return _platform.initialize(configuration);
  }

  /// Reports the USB roles and transfer features available on this platform.
  Future<AresBridgeCapabilities> getCapabilities() {
    return _platform.getCapabilities();
  }

  /// Starts listening for a peer using the role supplied to [initialize].
  Future<void> startListening() => _platform.startListening();

  /// Stops accepting new peers without disposing the bridge.
  Future<void> stopListening() => _platform.stopListening();

  /// Sends one local file and returns its transfer identifier.
  ///
  /// Completion is asynchronous and is reported through
  /// [completedTransfers]. Progress is reported through [transferProgress].
  Future<String> sendFile(AresFileTransferRequest request) {
    return _platform.sendFile(request);
  }

  /// Queues several files, such as paths received from desktop drag and drop.
  ///
  /// The returned identifiers correspond to [requests] by index.
  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) {
    if (requests.isEmpty) {
      return Future<List<String>>.value(const <String>[]);
    }
    return _platform.sendFiles(requests);
  }

  /// Cancels an active or queued transfer.
  Future<void> cancelTransfer(String transferId) {
    if (transferId.isEmpty) {
      throw ArgumentError.value(transferId, 'transferId', 'Must not be empty.');
    }
    return _platform.cancelTransfer(transferId);
  }

  /// Releases the native USB session and its resources.
  Future<void> dispose() => _platform.dispose();
}
