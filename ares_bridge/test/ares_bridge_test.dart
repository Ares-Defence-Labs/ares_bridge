import 'dart:async';

import 'package:ares_bridge/ares_bridge.dart';
import 'package:ares_bridge/ares_bridge_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAresBridgePlatform
    with MockPlatformInterfaceMixin
    implements AresBridgePlatform {
  final eventsController = StreamController<AresBridgeEvent>.broadcast();

  AresBridgeConfiguration? configuration;
  bool listening = false;
  String? cancelledTransferId;
  bool disposed = false;

  @override
  Stream<AresBridgeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize(AresBridgeConfiguration configuration) async {
    this.configuration = configuration;
  }

  @override
  Future<AresBridgeCapabilities> getCapabilities() async {
    return const AresBridgeCapabilities(
      platform: 'test',
      isSupported: true,
      supportsUsbHost: true,
      supportsUsbAccessory: true,
      supportsBidirectionalTransfer: true,
    );
  }

  @override
  Future<void> startListening() async {
    listening = true;
  }

  @override
  Future<void> stopListening() async {
    listening = false;
  }

  @override
  Future<String> sendFile(AresFileTransferRequest request) async {
    return 'transfer-${request.sourcePath}';
  }

  @override
  Future<List<String>> sendFiles(List<AresFileTransferRequest> requests) async {
    return <String>[
      for (var index = 0; index < requests.length; index++) 'transfer-$index',
    ];
  }

  @override
  Future<void> cancelTransfer(String transferId) async {
    cancelledTransferId = transferId;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await eventsController.close();
  }
}

void main() {
  late MockAresBridgePlatform platform;
  late AresBridge bridge;

  setUp(() {
    platform = MockAresBridgePlatform();
    bridge = AresBridge(platform: platform);
  });

  test('delegates lifecycle and file transfer methods', () async {
    const configuration = AresBridgeConfiguration(role: AresBridgeRole.usbHost);
    await bridge.initialize(configuration);
    await bridge.startListening();

    expect(platform.configuration, same(configuration));
    expect((await bridge.getCapabilities()).isSupported, isTrue);
    expect(platform.listening, isTrue);
    expect(
      await bridge.sendFile(AresFileTransferRequest(sourcePath: '/a.txt')),
      'transfer-/a.txt',
    );
    expect(
      await bridge.sendFiles(<AresFileTransferRequest>[
        AresFileTransferRequest(sourcePath: '/a.txt'),
        AresFileTransferRequest(sourcePath: '/b.txt'),
      ]),
      <String>['transfer-0', 'transfer-1'],
    );

    await bridge.cancelTransfer('transfer-0');
    await bridge.stopListening();
    expect(platform.cancelledTransferId, 'transfer-0');
    expect(platform.listening, isFalse);
  });

  test('filters typed event streams', () async {
    final connectionFuture = bridge.connectionEvents.first;
    final progressFuture = bridge.transferProgress.first;
    final receivedFuture = bridge.receivedFiles.first;

    platform.eventsController.add(
      AresConnectionEvent(
        state: AresConnectionState.active,
        localRole: AresBridgeRole.usbAccessory,
        timestamp: DateTime.utc(2026),
      ),
    );
    platform.eventsController.add(
      AresTransferProgress(
        transferId: 't1',
        direction: AresTransferDirection.incoming,
        stage: AresTransferStage.transferring,
        fileName: 'example.txt',
        bytesTransferred: 50,
        totalBytes: 100,
        timestamp: DateTime.utc(2026),
      ),
    );
    platform.eventsController.add(
      AresTransferCompleted(
        transferId: 't1',
        direction: AresTransferDirection.incoming,
        fileName: 'example.txt',
        bytesTransferred: 100,
        localPath: '/received/example.txt',
        timestamp: DateTime.utc(2026),
      ),
    );

    expect((await connectionFuture).isActive, isTrue);
    expect((await progressFuture).fraction, 0.5);
    expect((await receivedFuture).localPath, '/received/example.txt');
  });

  test('does not call the platform for an empty batch', () async {
    expect(await bridge.sendFiles(const <AresFileTransferRequest>[]), isEmpty);
  });

  test('rejects an empty transfer ID when cancelling', () {
    expect(() => bridge.cancelTransfer(''), throwsArgumentError);
  });
}
