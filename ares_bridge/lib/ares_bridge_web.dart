import 'dart:async';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'ares_bridge_platform_interface.dart';
import 'src/ares_bridge_models.dart';

/// Web registration for the common Ares Bridge API.
///
/// Browsers do not expose a portable background Android Open Accessory
/// transport. The API remains available so applications can query capabilities
/// and present a useful message instead of failing plugin registration.
class AresBridgeWeb extends AresBridgePlatform {
  AresBridgeWeb();

  static void registerWith(Registrar registrar) {
    AresBridgePlatform.instance = AresBridgeWeb();
  }

  final StreamController<AresBridgeEvent> _events =
      StreamController<AresBridgeEvent>.broadcast();
  AresBridgeRole _role = AresBridgeRole.automatic;

  @override
  Stream<AresBridgeEvent> get events => _events.stream;

  @override
  Future<void> initialize(AresBridgeConfiguration configuration) async {
    _role = configuration.role;
  }

  @override
  Future<AresBridgeCapabilities> getCapabilities() async {
    return const AresBridgeCapabilities(
      platform: 'web',
      isSupported: false,
      supportsUsbHost: false,
      supportsUsbAccessory: false,
      supportsBidirectionalTransfer: false,
      reason:
          'A background Android Open Accessory connection is not portable '
          'across browsers.',
    );
  }

  @override
  Future<void> startListening() {
    _emitFailure();
    return Future<void>.error(_unsupported());
  }

  @override
  Future<void> stopListening() async {
    _events.add(
      AresConnectionEvent(
        state: AresConnectionState.stopped,
        localRole: _role,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Future<String> sendFile(AresFileTransferRequest request) {
    return Future<String>.error(_unsupported());
  }

  @override
  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) {
    return Future<List<String>>.error(_unsupported());
  }

  @override
  Future<void> cancelTransfer(String transferId) async {}

  @override
  Future<void> dispose() async {
    await _events.close();
  }

  void _emitFailure() {
    _events.add(
      AresConnectionEvent(
        state: AresConnectionState.failed,
        localRole: _role,
        message: _unsupported().message,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  UnsupportedError _unsupported() {
    return UnsupportedError(
      'Ares USB transfer is not supported by this web browser.',
    );
  }
}
