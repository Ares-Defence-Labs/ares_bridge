import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ares_bridge_method_channel.dart';
import 'src/ares_bridge_models.dart';

/// Contract implemented by each Ares Bridge platform backend.
///
/// Applications normally use `AresBridge` rather than this class. Platform
/// packages and tests can extend it to provide another transport.
abstract class AresBridgePlatform extends PlatformInterface {
  /// Creates a platform implementation with the verification token.
  AresBridgePlatform() : super(token: _token);

  static final Object _token = Object();

  static AresBridgePlatform _instance = MethodChannelAresBridge();

  /// Registered backend used by new `AresBridge` instances.
  static AresBridgePlatform get instance => _instance;

  /// Replaces the registered backend after verifying its platform token.
  static set instance(AresBridgePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Broadcast stream containing all typed bridge events.
  Stream<AresBridgeEvent> get events {
    throw UnimplementedError('events has not been implemented.');
  }

  /// Applies [configuration] to the native transport.
  Future<void> initialize(AresBridgeConfiguration configuration) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Returns roles and features actually implemented by this backend.
  Future<AresBridgeCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }

  /// Requests listener startup; peer connection is reported on [events].
  Future<void> startListening() {
    throw UnimplementedError('startListening() has not been implemented.');
  }

  /// Stops listening and closes the current peer session.
  Future<void> stopListening() {
    throw UnimplementedError('stopListening() has not been implemented.');
  }

  /// Accepts one outgoing [request] and returns its transfer identifier.
  Future<String> sendFile(AresFileTransferRequest request) {
    throw UnimplementedError('sendFile() has not been implemented.');
  }

  /// Accepts multiple [requests] and returns IDs in the same order.
  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) {
    throw UnimplementedError('sendFiles() has not been implemented.');
  }

  /// Cancels the queued or active transfer identified by [transferId].
  Future<void> cancelTransfer(String transferId) {
    throw UnimplementedError('cancelTransfer() has not been implemented.');
  }

  /// Releases all resources owned by this backend.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
