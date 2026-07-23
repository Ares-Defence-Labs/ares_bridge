import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ares_bridge_method_channel.dart';
import 'src/ares_bridge_models.dart';

abstract class AresBridgePlatform extends PlatformInterface {
  AresBridgePlatform() : super(token: _token);

  static final Object _token = Object();

  static AresBridgePlatform _instance = MethodChannelAresBridge();

  static AresBridgePlatform get instance => _instance;

  static set instance(AresBridgePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Stream<AresBridgeEvent> get events {
    throw UnimplementedError('events has not been implemented.');
  }

  Future<void> initialize(AresBridgeConfiguration configuration) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  Future<AresBridgeCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }

  Future<void> startListening() {
    throw UnimplementedError('startListening() has not been implemented.');
  }

  Future<void> stopListening() {
    throw UnimplementedError('stopListening() has not been implemented.');
  }

  Future<String> sendFile(AresFileTransferRequest request) {
    throw UnimplementedError('sendFile() has not been implemented.');
  }

  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) {
    throw UnimplementedError('sendFiles() has not been implemented.');
  }

  Future<void> cancelTransfer(String transferId) {
    throw UnimplementedError('cancelTransfer() has not been implemented.');
  }

  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
