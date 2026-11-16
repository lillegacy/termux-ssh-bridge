import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/command_policy.dart';

void main() {
  group('CommandPolicy (ban list)', () {
    final policy = CommandPolicy(const ['rm', 'sudo', 'mkfs', 'chown -R']);

    test('allows ordinary commands that are not banned', () {
      expect(policy.isAllowed('ls -la'), isTrue);
      expect(policy.isAllowed('git status --short'), isTrue);
      expect(policy.isAllowed('python3 -m http.server'), isTrue);
      expect(policy.isAllowed('tmux ls'), isTrue);
    });

    test('rejects banned commands anywhere in a compound command', () {
      expect(policy.isAllowed('rm -rf /'), isFalse);
      expect(policy.isAllowed('ls; rm -rf /'), isFalse);
      expect(policy.isAllowed('sudo ls'), isFalse);
      expect(policy.isAllowed('mkfs.ext4 /dev/block/x'), isFalse);
    });

    test('matches the command by basename so absolute paths are banned', () {
      expect(policy.isAllowed('/bin/rm -rf /'), isFalse);
      expect(policy.isAllowed('/usr/bin/sudo ls'), isFalse);
    });

    test('matches multi-word patterns as substrings', () {
      expect(policy.isAllowed('chown -R root:root /'), isFalse);
      expect(policy.isAllowed('chown root:root file'), isTrue);
    });

    test('does not ban a word that merely appears as an argument', () {
      expect(policy.isAllowed('echo rm'), isTrue);
      expect(policy.isAllowed('grep sudo notes.txt'), isTrue);
    });

    test('rejects substitution and redirection', () {
      expect(policy.isAllowed(r'ls $(whoami)'), isFalse);
      expect(policy.isAllowed('ls > output.txt'), isFalse);
      expect(policy.isAllowed('cat < input.txt'), isFalse);
      expect(policy.isAllowed('ls `whoami`'), isFalse);
      expect(policy.isAllowed(r'echo $PATH'), isFalse);
    });

    test('rejects shell control characters and newlines', () {
      expect(policy.isAllowed('git status\nrm -rf /'), isFalse);
      expect(policy.isAllowed('git status\r\nrm -rf /'), isFalse);
      expect(policy.isAllowed('git status\rm -rf /'), isFalse);
    });

    test('rejects empty segments', () {
      expect(policy.isAllowed('ls &&'), isFalse);
      expect(policy.isAllowed('; ls'), isFalse);
    });

    test('treats operators inside quoted arguments as literal text', () {
      expect(policy.isAllowed('cat "left && right"'), isTrue);
      expect(policy.isAllowed("cat 'left; right'"), isTrue);
    });

    test('reported reason names the banned pattern', () {
      final reasons = policy.rejectedReasons('rm -rf /');
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('rm'));
    });

    test('default ban list blocks shell indirection', () {
      final defaults = CommandPolicy(CommandPolicy.defaultBannedPatterns);
      expect(defaults.isAllowed('bash -c ls'), isFalse);
      expect(defaults.isAllowed('eval ls'), isFalse);
      expect(defaults.isAllowed('sh'), isFalse);
      expect(defaults.isAllowed('ls'), isTrue);
    });

    test('ignores comments and blank lines in the configured list', () {
      final withComments = CommandPolicy(const ['# note', '', '  rm  ']);
      expect(withComments.bannedPatterns, {'rm'});
    });
  });
}
