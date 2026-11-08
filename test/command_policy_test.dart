import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/command_policy.dart';

void main() {
  group('CommandPolicy', () {
    final policy = CommandPolicy(['ls', 'cat', 'git status']);

    test('allows an explicitly allowed command', () {
      expect(policy.isAllowed('ls -la'), isTrue);
      expect(policy.isAllowed('git status --short'), isTrue);
    });

    test('rejects commands outside the allowlist', () {
      expect(policy.isAllowed('rm -rf /'), isFalse);
      expect(policy.isAllowed('echo hello'), isFalse);
    });

    test('requires every compound segment to be allowed', () {
      expect(policy.isAllowed('ls && pwd'), isFalse);
      expect(policy.isAllowed('ls | cat'), isTrue);
      expect(policy.isAllowed('ls; rm -rf /'), isFalse);
    });

    test('rejects substitution and redirection', () {
      expect(policy.isAllowed(r'ls $(whoami)'), isFalse);
      expect(policy.isAllowed('ls > output.txt'), isFalse);
      expect(policy.isAllowed('cat < input.txt'), isFalse);
      expect(policy.isAllowed('ls `whoami`'), isFalse);
    });
  });
}
