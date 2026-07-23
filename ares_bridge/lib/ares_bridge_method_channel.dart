import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ares_bridge_platform_interface.dart';
import 'src/ares_bridge_models.dart';

/// Default platform implementation backed by Flutter channels.
class MethodChannelAresBridge extends AresBridgePlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('ares_bridge/methods');

  @visibleForTesting
  final eventChannel = const EventChannel('ares_bridge/events');

  late final Stream<AresBridgeEvent> _events = eventChannel
      .receiveBroadcastStream()
      .map(AresBridgeEvent.fromPlatformEvent);

  @override
  Stream<AresBridgeEvent> get events => _events;

  @override
  Future<void> initialize(AresBridgeConfiguration configuration) {
    return methodChannel.invokeMethod<void>(
      'initialize',
      configuration.toMap(),
    );
  }

  @override
  Future<AresBridgeCapabilities> getCapabilities() async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getCapabilities',
    );
    if (value == null) {
      throw const FormatException(
        'The platform did not return Ares bridge capabilities.',
      );
    }
    return AresBridgeCapabilities.fromMap(value);
  }

  @override
  Future<void> startListening() {
    return methodChannel.invokeMethod<void>('startListening');
  }

  @override
  Future<void> stopListening() {
    return methodChannel.invokeMethod<void>('stopListening');
  }

  @override
  Future<String> sendFile(AresFileTransferRequest request) async {
    final transferId = await methodChannel.invokeMethod<String>(
      'sendFile',
      request.toMap(),
    );
    if (transferId == null || transferId.isEmpty) {
      throw const FormatException(
        'The platform did not return a valid transfer ID.',
      );
    }
    return transferId;
  }

  @override
  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) async {
    final transferIds = await methodChannel.invokeListMethod<String>(
      'sendFiles',
      requests.map((request) => request.toMap()).toList(growable: false),
    );
    if (transferIds == null || transferIds.length != requests.length) {
      throw const FormatException(
        'The platform returned an invalid transfer ID list.',
      );
    }
    if (transferIds.any((id) => id.isEmpty)) {
      throw const FormatException(
        'The platform returned an empty transfer ID.',
      );
    }
    return List<String>.unmodifiable(transferIds);
  }

  @override
  Future<void> cancelTransfer(String transferId) {
    return methodChannel.invokeMethod<void>('cancelTransfer', <String, Object?>{
      'transferId': transferId,
    });
  }

  @override
  Future<void> dispose() {
    return methodChannel.invokeMethod<void>('dispose');
  }
}
