import 'dart:math';

/// Tracks a single on-demand bridge session and its idle lifecycle.
///
/// Phase 1 rules:
/// * while commands keep arriving, the heartbeat stays fast (5s);
/// * after [idleAfter] without activity the session is idle and the heartbeat
///   eases off to 30s;
/// * after [disconnectAfter] without activity the SSH connection is closed.
class BridgeSession {
  BridgeSession({
    required this.profileId,
    required this.profileName,
    required this.connectedAt,
    this.idleAfter = const Duration(seconds: 30),
    this.disconnectAfter = const Duration(minutes: 30),
    String? id,
  })  : id = id ?? _newId(),
        _lastActivity = connectedAt;

  static const Duration activeHeartbeat = Duration(seconds: 5);
  static const Duration idleHeartbeat = Duration(seconds: 30);

  final String id;
  final String profileId;
  final String profileName;
  final DateTime connectedAt;
  final Duration idleAfter;
  final Duration disconnectAfter;

  DateTime _lastActivity;
  int _commandCount = 0;

  DateTime get lastActivity => _lastActivity;
  int get commandCount => _commandCount;

  void recordActivity(DateTime now) {
    _lastActivity = now;
    _commandCount++;
  }

  Duration idleFor(DateTime now) => now.difference(_lastActivity);

  bool isIdle(DateTime now) => idleFor(now) >= idleAfter;

  bool shouldAutoDisconnect(DateTime now) => idleFor(now) >= disconnectAfter;

  /// How often the client should check in while in the current state.
  Duration heartbeatInterval(DateTime now) =>
      isIdle(now) ? idleHeartbeat : activeHeartbeat;

  Map<String, Object?> toJson(DateTime now) => {
        'sessionId': id,
        'profile': profileName,
        'profileId': profileId,
        'connectedForSeconds': now.difference(connectedAt).inSeconds,
        'idleSeconds': idleFor(now).inSeconds,
        'idle': isIdle(now),
        'commandCount': _commandCount,
        'idleAfterSeconds': idleAfter.inSeconds,
        'disconnectAfterSeconds': disconnectAfter.inSeconds,
        'heartbeatSeconds': heartbeatInterval(now).inSeconds,
      };

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
