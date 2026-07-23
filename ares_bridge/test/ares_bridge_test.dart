import 'package:flutter_test/flutter_test.dart';
import 'package:ares_bridge/ares_bridge.dart';
import 'package:ares_bridge/ares_bridge_platform_interface.dart';
import 'package:ares_bridge/ares_bridge_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAresBridgePlatform
    with MockPlatformInterfaceMixin
    implements AresBridgePlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AresBridgePlatform initialPlatform = AresBridgePlatform.instance;

  test('$MethodChannelAresBridge is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAresBridge>());
  });

  test('getPlatformVersion', () async {
    AresBridge aresBridgePlugin = AresBridge();
    MockAresBridgePlatform fakePlatform = MockAresBridgePlatform();
    AresBridgePlatform.instance = fakePlatform;

    expect(await aresBridgePlugin.getPlatformVersion(), '42');
  });
}
