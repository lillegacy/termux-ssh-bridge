import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/main.dart';

void main() {
  test('SSHProfile tolerates missing persisted fields', () {
    final profile = SSHProfile.fromJson({'id': 'profile-1'});

    expect(profile.id, 'profile-1');
    expect(profile.name, isEmpty);
    expect(profile.host, isEmpty);
    expect(profile.port, isEmpty);
    expect(profile.username, isEmpty);
    expect(profile.isValid, isFalse);
  });

  test('SSHProfile accepts a complete persisted profile', () {
    final profile = SSHProfile.fromJson({
      'id': 'profile-1',
      'name': 'Phone',
      'host': '127.0.0.1',
      'port': 8022,
      'username': 'termux',
    });

    expect(profile.port, '8022');
    expect(profile.isValid, isTrue);
  });
}
