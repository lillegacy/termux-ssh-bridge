import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/bridge_session.dart';

void main() {
  group('BridgeSession', () {
    final connectedAt = DateTime.utc(2026, 1, 1, 12, 0, 0);

    BridgeSession build() => BridgeSession(
          profileId: 'default',
          profileName: 'Phone',
          connectedAt: connectedAt,
          idleAfter: const Duration(seconds: 30),
          disconnectAfter: const Duration(minutes: 30),
        );

    test('starts active with a fast heartbeat', () {
      final session = build();
      final now = connectedAt.add(const Duration(seconds: 5));
      expect(session.isIdle(now), isFalse);
      expect(session.heartbeatInterval(now), BridgeSession.activeHeartbeat);
      expect(session.commandCount, 0);
    });

    test('becomes idle after 30 seconds without activity', () {
      final session = build();
      final now = connectedAt.add(const Duration(seconds: 31));
      expect(session.isIdle(now), isTrue);
      expect(session.heartbeatInterval(now), BridgeSession.idleHeartbeat);
      expect(session.shouldAutoDisconnect(now), isFalse);
    });

    test('activity resets the idle timer', () {
      final session = build();
      final activeAt = connectedAt.add(const Duration(seconds: 25));
      session.recordActivity(activeAt);
      expect(session.commandCount, 1);
      expect(
          session.isIdle(activeAt.add(const Duration(seconds: 20))), isFalse);
      expect(session.lastActivity, activeAt);
    });

    test('requests auto-disconnect after 30 minutes of inactivity', () {
      final session = build();
      expect(
        session
            .shouldAutoDisconnect(connectedAt.add(const Duration(minutes: 29))),
        isFalse,
      );
      expect(
        session
            .shouldAutoDisconnect(connectedAt.add(const Duration(minutes: 30))),
        isTrue,
      );
    });

    test('serializes status for the gateway', () {
      final session = build();
      final json = session.toJson(connectedAt.add(const Duration(seconds: 10)));
      expect(json['sessionId'], session.id);
      expect(json['profile'], 'Phone');
      expect(json['idle'], isFalse);
      expect(json['idleAfterSeconds'], 30);
      expect(json['disconnectAfterSeconds'], 1800);
      expect(json['heartbeatSeconds'], 5);
    });

    test('generates distinct session ids', () {
      expect(build().id, isNot(build().id));
      expect(build().id, hasLength(32));
    });
  });
}
