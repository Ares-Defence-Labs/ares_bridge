import 'dart:collection';

/// The USB role used by the local application.
///
/// Under Android Open Accessory, Windows/macOS normally use [usbHost] and the
/// Android device uses [usbAccessory].
enum AresBridgeRole {
  /// Let the native backend select its natural role.
  automatic,

  /// Own and initiate the USB connection, normally on desktop.
  usbHost,

  /// Participate as the connected accessory, normally on mobile.
  usbAccessory,
}

/// How an incoming file is handled when its destination already exists.
enum AresOverwritePolicy {
  /// Fail the incoming transfer if the destination exists.
  reject,

  /// Atomically replace the existing destination after verification.
  replace,

  /// Preserve the existing file and select a unique destination name.
  rename,
}

/// USB functionality exposed by the current platform backend.
final class AresBridgeCapabilities {
  /// Creates an immutable description of the current platform backend.
  const AresBridgeCapabilities({
    required this.platform,
    required this.isSupported,
    required this.supportsUsbHost,
    required this.supportsUsbAccessory,
    required this.supportsBidirectionalTransfer,
    this.reason,
  });

  /// Decodes the capabilities map returned by a native backend.
  ///
  /// Throws a [FormatException] when a required field is absent or has an
  /// unexpected type.
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

  /// Lowercase platform name reported by the backend, such as `android`.
  final String platform;

  /// Whether this backend currently provides a usable USB transport.
  final bool isSupported;

  /// Whether this device can initiate and own the USB connection.
  final bool supportsUsbHost;

  /// Whether this device can participate as a USB accessory.
  final bool supportsUsbAccessory;

  /// Whether files can be sent in both directions after connecting.
  final bool supportsBidirectionalTransfer;

  /// Human-readable explanation when [isSupported] is false.
  final String? reason;
}

/// Configuration shared by every platform implementation.
final class AresBridgeConfiguration {
  /// Creates bridge configuration.
  ///
  /// [chunkSizeBytes] must be positive. Native backends may impose a maximum
  /// chunk size and require [peerTimeout] to be longer than
  /// [heartbeatInterval].
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

  /// USB role requested for this device.
  ///
  /// With [AresBridgeRole.automatic], the backend selects its natural role:
  /// host on macOS and accessory on Android/iOS.
  final AresBridgeRole role;

  /// Stable application-level identity announced during the handshake.
  ///
  /// When null, the native backend generates or loads a platform-local ID.
  final String? localPeerId;

  /// Human-readable name announced to the connected peer.
  final String? localPeerName;

  /// Platform-local directory for received files.
  ///
  /// The current Android, macOS, and iOS backends expect a native filesystem
  /// path. When null, each backend uses its application-specific default.
  final String? incomingDirectory;

  /// Collision strategy used when an incoming destination already exists.
  final AresOverwritePolicy overwritePolicy;

  /// Maximum payload requested for each file-data frame.
  ///
  /// The default is 64 KiB. Protocol version 1 permits at most 16 MiB in an
  /// individual payload frame.
  final int chunkSizeBytes;

  /// Interval between keepalive heartbeats on an established session.
  final Duration heartbeatInterval;

  /// Time without a valid peer heartbeat before the session is disconnected.
  ///
  /// This must be greater than [heartbeatInterval].
  final Duration peerTimeout;

  /// Encodes this configuration for the platform channel.
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
  /// Creates an outgoing file request.
  ///
  /// Throws [ArgumentError] when [sourcePath] is empty or when a non-null
  /// [destinationPath] is empty. [metadata] is defensively copied and exposed
  /// as an unmodifiable map.
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
  ///
  /// Keep values small; metadata is control-plane information and is not a
  /// replacement for the file payload.
  final Map<String, String> metadata;

  /// Encodes this request for the platform channel.
  Map<String, Object?> toMap() => <String, Object?>{
    'sourcePath': sourcePath,
    'destinationPath': destinationPath,
    'metadata': metadata,
  };
}

/// Lifecycle state of the local listener and its current peer.
enum AresConnectionState {
  /// Listening has stopped or the bridge has been disposed.
  stopped,

  /// The local receiver is waiting for a peer.
  listening,

  /// The remote peer announced that its receiver is ready.
  peerReady,

  /// A physical transport is open and the handshake is in progress.
  connecting,

  /// The handshake has completed and peer heartbeats are current.
  active,

  /// A previously known peer is no longer active.
  disconnected,

  /// Connection setup or the active session failed.
  failed,
}

/// Whether a transfer is being received or sent by the local application.
enum AresTransferDirection {
  /// File bytes are arriving at this application.
  incoming,

  /// File bytes are leaving this application.
  outgoing,
}

/// Current phase of a file transfer.
enum AresTransferStage {
  /// Accepted locally but not yet negotiated with the peer.
  queued,

  /// Exchanging the file manifest and destination decision.
  negotiating,

  /// Transmitting or receiving file bytes.
  transferring,

  /// Checking byte counts and SHA-256 after the stream closes.
  verifying,
}

/// Base type for all broadcast events.
sealed class AresBridgeEvent {
  /// Creates the shared part of an Ares event.
  const AresBridgeEvent({required this.timestamp});

  /// UTC time at which the native backend created this event.
  final DateTime timestamp;

  /// Decodes a native method-channel event into its typed Dart representation.
  ///
  /// Throws [FormatException] for an unknown event type, missing field, or
  /// value with an unexpected type.
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

/// A listener, handshake, peer-readiness, or disconnection state change.
final class AresConnectionEvent extends AresBridgeEvent {
  /// Creates a connection event.
  const AresConnectionEvent({
    required this.state,
    required this.localRole,
    required super.timestamp,
    this.peerId,
    this.peerName,
    this.message,
  });

  /// Decodes a native connection event map.
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

  /// New connection state.
  final AresConnectionState state;

  /// Role selected for the local endpoint.
  final AresBridgeRole localRole;

  /// Stable application-level identity announced by the peer, when known.
  final String? peerId;

  /// Human-readable name announced by the peer, when known.
  final String? peerName;

  /// Optional diagnostic, normally present for [AresConnectionState.failed].
  final String? message;

  /// Whether [state] is [AresConnectionState.active].
  bool get isActive => state == AresConnectionState.active;
}

/// A snapshot of an incoming or outgoing transfer's progress.
final class AresTransferProgress extends AresBridgeEvent {
  /// Creates a transfer progress event.
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

  /// Decodes a native transfer progress event map.
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

  /// Identifier returned by `sendFile` or `sendFiles`, or assigned to an
  /// incoming transfer.
  final String transferId;

  /// Direction relative to this application.
  final AresTransferDirection direction;

  /// Current transfer phase.
  final AresTransferStage stage;

  /// Display name of the file, without relying on it as a safe destination.
  final String fileName;

  /// Number of payload bytes processed so far.
  final int bytesTransferred;

  /// Expected total payload size.
  final int totalBytes;

  /// Recent throughput estimate, or null before one is available.
  final double? bytesPerSecond;

  /// Estimated time to completion, or null when it cannot be estimated.
  final Duration? estimatedTimeRemaining;

  /// Normalized progress in the inclusive range 0–1.
  ///
  /// Returns zero when [totalBytes] is not positive.
  double get fraction {
    if (totalBytes <= 0) {
      return 0;
    }
    return (bytesTransferred / totalBytes).clamp(0, 1).toDouble();
  }
}

/// Terminal success for an incoming or outgoing transfer.
///
/// For incoming files, this event is emitted only after the destination is
/// flushed, closed, byte-count checked, and SHA-256 verified.
final class AresTransferCompleted extends AresBridgeEvent {
  /// Creates a transfer completion event.
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

  /// Decodes a native transfer completion event map.
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

  /// Identifier shared by all events for this transfer.
  final String transferId;

  /// Direction relative to this application.
  final AresTransferDirection direction;

  /// Display name of the transferred file.
  final String fileName;

  /// Total number of verified file bytes.
  final int bytesTransferred;

  /// Final path or content URI on this platform.
  final String? localPath;

  /// Receiver path acknowledged to the sender, when supplied by the backend.
  final String? remotePath;

  /// Relative destination requested by the sender for an incoming transfer.
  final String? destinationPath;

  /// Lowercase hexadecimal SHA-256 digest, when supplied by the backend.
  final String? sha256;
}

/// Terminal failure for an incoming or outgoing transfer.
final class AresTransferFailed extends AresBridgeEvent {
  /// Creates a transfer failure event.
  const AresTransferFailed({
    required this.transferId,
    required this.direction,
    required this.code,
    required this.message,
    required super.timestamp,
    this.fileName,
    this.recoverable = false,
  });

  /// Decodes a native transfer failure event map.
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

  /// Identifier shared by all events for this transfer.
  final String transferId;

  /// Direction relative to this application.
  final AresTransferDirection direction;

  /// Stable, machine-readable failure code.
  final String code;

  /// Human-readable failure description suitable for diagnostics.
  final String message;

  /// Display name of the affected file, when known.
  final String? fileName;

  /// Whether retrying without changing the request may succeed.
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
