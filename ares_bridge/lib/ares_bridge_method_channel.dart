import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ares_bridge_platform_interface.dart';

/// An implementation of [AresBridgePlatform] that uses method channels.
class MethodChannelAresBridge extends AresBridgePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('ares_bridge');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
