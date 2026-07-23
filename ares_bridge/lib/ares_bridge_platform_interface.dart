import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ares_bridge_method_channel.dart';

abstract class AresBridgePlatform extends PlatformInterface {
  /// Constructs a AresBridgePlatform.
  AresBridgePlatform() : super(token: _token);

  static final Object _token = Object();

  static AresBridgePlatform _instance = MethodChannelAresBridge();

  /// The default instance of [AresBridgePlatform] to use.
  ///
  /// Defaults to [MethodChannelAresBridge].
  static AresBridgePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AresBridgePlatform] when
  /// they register themselves.
  static set instance(AresBridgePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
