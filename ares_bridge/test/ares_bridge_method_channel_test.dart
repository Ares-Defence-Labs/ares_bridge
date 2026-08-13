import 'package:ares_bridge/ares_bridge.dart';
import 'package:ares_bridge/ares_bridge_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannelAresBridge platform;
  const channel = MethodChannel('ares_bridge/methods');
  final calls = <MethodCall>[];

  setUp(() {
    platform = MethodChannelAresBridge();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getCapabilities' => <String, Object?>{
              'platform': 'test',
              'isSupported': true,
              'supportsUsbHost': true,
              'supportsUsbAccessory': false,
              'supportsBidirectionalTransfer': true,
              'reason': null,
            },
            'sendFile' => 'transfer-1',
            'sendFiles' => <String>['transfer-1', 'transfer-2'],
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('serializes configuration', () async {
    await platform.initialize(
      const AresBridgeConfiguration(
        role: AresBridgeRole.usbHost,
        localPeerId: 'mac-1',
        localPeerName: 'Dispatch Mac',
        incomingDirectory: '/incoming',
      ),
    );

    expect(calls.single.method, 'initialize');
    expect(calls.single.arguments, containsPair('protocolVersion', 1));
    expect(calls.single.arguments, containsPair('role', 'usbHost'));
    expect(calls.single.arguments, containsPair('localPeerId', 'mac-1'));
    expect(
      calls.single.arguments,
      containsPair('incomingDirectory', '/incoming'),
    );
    expect(calls.single.arguments, containsPair('chunkSizeBytes', 64 * 1024));
  });

  test('decodes native capabilities', () async {
    final capabilities = await platform.getCapabilities();

    expect(capabilities.platform, 'test');
    expect(capabilities.isSupported, isTrue);
    expect(capabilities.supportsUsbHost, isTrue);
    expect(capabilities.supportsUsbAccessory, isFalse);
  });

  test('serializes a file and returns its transfer ID', () async {
    final id = await platform.sendFile(
      AresFileTransferRequest(
        sourcePath: '/source/file.txt',
        destinationPath: 'documents/file.txt',
        metadata: const <String, String>{'origin': 'drag-drop'},
      ),
    );

    expect(id, 'transfer-1');
    expect(calls.single.method, 'sendFile');
    expect(
      calls.single.arguments,
      containsPair('sourcePath', '/source/file.txt'),
    );
  });

  test('decodes platform progress with ETA', () {
    final event = AresBridgeEvent.fromPlatformEvent(<String, Object?>{
      'type': 'transferProgress',
      'transferId': 'transfer-1',
      'direction': 'outgoing',
      'stage': 'transferring',
      'fileName': 'file.txt',
      'bytesTransferred': 512,
      'totalBytes': 1024,
      'bytesPerSecond': 256,
      'estimatedTimeRemainingMs': 2000,
      'timestampMs': 1767225600000,
    });

    expect(event, isA<AresTransferProgress>());
    final progress = event as AresTransferProgress;
    expect(progress.fraction, 0.5);
    expect(progress.estimatedTimeRemaining, const Duration(seconds: 2));
  });

  test('decodes the requested destination for an incoming file', () {
    final event = AresBridgeEvent.fromPlatformEvent(<String, Object?>{
      'type': 'transferCompleted',
      'transferId': 'transfer-2',
      'direction': 'incoming',
      'fileName': 'report.pdf',
      'bytesTransferred': 2048,
      'localPath': '/incoming/AresScan/Imports/report.pdf',
      'destinationPath': 'AresScan/Imports/report.pdf',
      'timestampMs': 1767225600000,
    });

    expect(event, isA<AresTransferCompleted>());
    expect(
      (event as AresTransferCompleted).destinationPath,
      'AresScan/Imports/report.pdf',
    );
  });

  test('rejects malformed platform events', () {
    expect(
      () => AresBridgeEvent.fromPlatformEvent(<String, Object?>{
        'type': 'unknown',
        'timestampMs': 0,
      }),
      throwsFormatException,
    );
  });
}
