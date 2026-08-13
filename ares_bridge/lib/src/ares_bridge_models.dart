import 'dart:collection';

/// The USB role used by the local application.
///
/// Under Android Open Accessory, Windows/macOS normally use [usbHost] and the
/// Android device uses [usbAccessory].
enum AresBridgeRole { automatic, usbHost, usbAccessory }

enum AresOverwritePolicy { reject, replace, rename }

/// USB functionality exposed by the current platform backend.
final class AresBridgeCapabilities {
  const AresBridgeCapabilities({
    required this.platform,
    required this.isSupported,
    required this.supportsUsbHost,
    required this.supportsUsbAccessory,
    required this.supportsBidirectionalTransfer,
    this.reason,
  });

  factory AresBridgeCapabilities.fromMap(Map<Object?, Object?> map) {
    return AresBridgeCapabilities(
      platform: _requiredString(map, 'platform'),
      isSupported: _requiredBool(map, 'isSupported'),
      supportsUsbHost: _requiredBool(map, 'supportsUsbHost'),
      supportsUsbAccessory: _requiredBool(map, 'supportsUsbAccessory'),
      supportsBidirectionalTransfer: _requiredBool(
        map,
        'supportsBidirectionalTransfer',
      ),
      reason: _optionalString(map, 'reason'),
    );
  }

  final String platform;
  final bool isSupported;
  final bool supportsUsbHost;
  final bool supportsUsbAccessory;
  final bool supportsBidirectionalTransfer;
  final String? reason;
}

/// Configuration shared by every platform implementation.
final class AresBridgeConfiguration {
  const AresBridgeConfiguration({
    this.role = AresBridgeRole.automatic,
    this.localPeerId,
    this.localPeerName,
    this.incomingDirectory,
    this.overwritePolicy = AresOverwritePolicy.rename,
    this.chunkSizeBytes = 64 * 1024,
    this.heartbeatInterval = const Duration(seconds: 2),
    this.peerTimeout = const Duration(seconds: 8),
  }) : assert(chunkSizeBytes > 0);

  final AresBridgeRole role;

  /// Stable application-level identity announced during the handshake.
  ///
  /// When null, the native backend generates or loads a platform-local ID.
  final String? localPeerId;

  /// Human-readable name announced to the connected peer.
  final String? localPeerName;

  /// Platform-local directory or document-tree URI for received files.
  ///
  /// On Android this may be a Storage Access Framework tree URI. When null, the
  /// platform implementation must use its configured application directory or
  /// request a destination before accepting a file.
  final String? incomingDirectory;

  final AresOverwritePolicy overwritePolicy;
  final int chunkSizeBytes;
  final Duration heartbeatInterval;
  final Duration peerTimeout;

  Map<String, Object?> toMap() => <String, Object?>{
    'protocolVersion': 1,
    'role': role.name,
    'localPeerId': localPeerId,
    'localPeerName': localPeerName,
    'incomingDirectory': incomingDirectory,
    'overwritePolicy': overwritePolicy.name,
    'chunkSizeBytes': chunkSizeBytes,
    'heartbeatIntervalMs': heartbeatInterval.inMilliseconds,
    'peerTimeoutMs': peerTimeout.inMilliseconds,
  };
}

/// Local file queued for transfer to the connected peer.
final class AresFileTransferRequest {
  AresFileTransferRequest({
    required this.sourcePath,
    this.destinationPath,
    Map<String, String> metadata = const <String, String>{},
  }) : metadata = UnmodifiableMapView<String, String>(
         Map<String, String>.of(metadata),
       ) {
    if (sourcePath.isEmpty) {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'Must not be empty.');
    }
    if (destinationPath != null && destinationPath!.isEmpty) {
      throw ArgumentError.value(
        destinationPath,
        'destinationPath',
        'Must be null or non-empty.',
      );
    }
  }

  /// Absolute path to the file on the sending platform.
  final String sourcePath;

  /// Optional path relative to the receiver's configured incoming directory.
  ///
  /// Native implementations must reject traversal outside that directory.
  final String? destinationPath;

  /// Small application-defined values sent with the file manifest.
  final Map<String, String> metadata;

  Map<String, Object?> toMap() => <String, Object?>{
    'sourcePath': sourcePath,
    'destinationPath': destinationPath,
    'metadata': metadata,
  };
}

enum AresConnectionState {
  stopped,
  listening,

  /// The remote peer announced that its receiver is ready.
  peerReady,
  connecting,

  /// The handshake has completed and peer heartbeats are current.
  active,
  disconnected,
  failed,
}

enum AresTransferDirection { incoming, outgoing }

enum AresTransferStage { queued, negotiating, transferring, verifying }

/// Base type for all broadcast events.
sealed class AresBridgeEvent {
  const AresBridgeEvent({required this.timestamp});

  final DateTime timestamp;

  factory AresBridgeEvent.fromPlatformEvent(Object? value) {
    if (value is! Map) {
      throw FormatException(
        'Expected an Ares event map, received ${value.runtimeType}.',
      );
    }
    final map = Map<Object?, Object?>.of(value);
    return switch (_requiredString(map, 'type')) {
      'connection' => AresConnectionEvent.fromMap(map),
      'transferProgress' => AresTransferProgress.fromMap(map),
      'transferCompleted' => AresTransferCompleted.fromMap(map),
      'transferFailed' => AresTransferFailed.fromMap(map),
      final type => throw FormatException('Unknown Ares event type: $type'),
    };
  }
}

final class AresConnectionEvent extends AresBridgeEvent {
  const AresConnectionEvent({
    required this.state,
    required this.localRole,
    required super.timestamp,
    this.peerId,
    this.peerName,
    this.message,
  });

  factory AresConnectionEvent.fromMap(Map<Object?, Object?> map) {
    return AresConnectionEvent(
      state: _enumByName(
        AresConnectionState.values,
        _requiredString(map, 'state'),
        'state',
      ),
      localRole: _enumByName(
        AresBridgeRole.values,
        _requiredString(map, 'localRole'),
        'localRole',
      ),
      peerId: _optionalString(map, 'peerId'),
      peerName: _optionalString(map, 'peerName'),
      message: _optionalString(map, 'message'),
      timestamp: _timestamp(map),
    );
  }

  final AresConnectionState state;
  final AresBridgeRole localRole;
  final String? peerId;
  final String? peerName;
  final String? message;

  bool get isActive => state == AresConnectionState.active;
}

final class AresTransferProgress extends AresBridgeEvent {
  const AresTransferProgress({
    required this.transferId,
    required this.direction,
    required this.stage,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    required super.timestamp,
    this.bytesPerSecond,
    this.estimatedTimeRemaining,
  });

  factory AresTransferProgress.fromMap(Map<Object?, Object?> map) {
    final etaMs = _optionalInt(map, 'estimatedTimeRemainingMs');
    return AresTransferProgress(
      transferId: _requiredString(map, 'transferId'),
      direction: _enumByName(
        AresTransferDirection.values,
        _requiredString(map, 'direction'),
        'direction',
      ),
      stage: _enumByName(
        AresTransferStage.values,
        _requiredString(map, 'stage'),
        'stage',
      ),
      fileName: _requiredString(map, 'fileName'),
      bytesTransferred: _requiredInt(map, 'bytesTransferred'),
      totalBytes: _requiredInt(map, 'totalBytes'),
      bytesPerSecond: _optionalDouble(map, 'bytesPerSecond'),
      estimatedTimeRemaining: etaMs == null
          ? null
          : Duration(milliseconds: etaMs),
      timestamp: _timestamp(map),
    );
  }

  final String transferId;
  final AresTransferDirection direction;
  final AresTransferStage stage;
  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final double? bytesPerSecond;
  final Duration? estimatedTimeRemaining;

  double get fraction {
    if (totalBytes <= 0) {
      return 0;
    }
    return (bytesTransferred / totalBytes).clamp(0, 1).toDouble();
  }
}

final class AresTransferCompleted extends AresBridgeEvent {
  const AresTransferCompleted({
    required this.transferId,
    required this.direction,
    required this.fileName,
    required this.bytesTransferred,
    required super.timestamp,
    this.localPath,
    this.remotePath,
    this.destinationPath,
    this.sha256,
  });

  factory AresTransferCompleted.fromMap(Map<Object?, Object?> map) {
    return AresTransferCompleted(
      transferId: _requiredString(map, 'transferId'),
      direction: _enumByName(
        AresTransferDirection.values,
        _requiredString(map, 'direction'),
        'direction',
      ),
      fileName: _requiredString(map, 'fileName'),
      bytesTransferred: _requiredInt(map, 'bytesTransferred'),
      localPath: _optionalString(map, 'localPath'),
      remotePath: _optionalString(map, 'remotePath'),
      destinationPath: _optionalString(map, 'destinationPath'),
      sha256: _optionalString(map, 'sha256'),
      timestamp: _timestamp(map),
    );
  }

  final String transferId;
  final AresTransferDirection direction;
  final String fileName;
  final int bytesTransferred;

  /// Final path or content URI on this platform.
  final String? localPath;

  final String? remotePath;

  /// Relative destination requested by the sender for an incoming transfer.
  final String? destinationPath;
  final String? sha256;
}

final class AresTransferFailed extends AresBridgeEvent {
  const AresTransferFailed({
    required this.transferId,
    required this.direction,
    required this.code,
    required this.message,
    required super.timestamp,
    this.fileName,
    this.recoverable = false,
  });

  factory AresTransferFailed.fromMap(Map<Object?, Object?> map) {
    return AresTransferFailed(
      transferId: _requiredString(map, 'transferId'),
      direction: _enumByName(
        AresTransferDirection.values,
        _requiredString(map, 'direction'),
        'direction',
      ),
      code: _requiredString(map, 'code'),
      message: _requiredString(map, 'message'),
      fileName: _optionalString(map, 'fileName'),
      recoverable: _optionalBool(map, 'recoverable') ?? false,
      timestamp: _timestamp(map),
    );
  }

  final String transferId;
  final AresTransferDirection direction;
  final String code;
  final String message;
  final String? fileName;
  final bool recoverable;
}

T _enumByName<T extends Enum>(Iterable<T> values, String name, String field) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('Invalid $field value: $name');
}

DateTime _timestamp(Map<Object?, Object?> map) {
  final timestampMs = _requiredInt(map, 'timestampMs');
  return DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
}

String _requiredString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException('Expected non-empty String "$key".');
}

String? _optionalString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('Expected String "$key".');
}

int _requiredInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected int "$key".');
}

int? _optionalInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw FormatException('Expected int "$key".');
}

double? _optionalDouble(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('Expected number "$key".');
}

bool? _optionalBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null || value is bool) {
    return value as bool?;
  }
  throw FormatException('Expected bool "$key".');
}

bool _requiredBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected bool "$key".');
}
