/// A deny-list based command policy.
///
/// Phase 1 of the on-demand bridge replaces the old allow-list with a ban list:
/// the gateway runs the command unless it names a banned program or contains a
/// shell construct that the policy refuses to interpret.
///
/// The structural checks remain because the gateway hands the command to a
/// shell. Command substitution, redirection, newlines and control characters
/// are rejected outright; `;`, `&` and `|` are treated as segment separators so
/// every segment is checked individually.
class CommandPolicy {
  CommandPolicy(Iterable<String> bannedPatterns)
      : bannedPatterns = bannedPatterns
            .map(_normalizePattern)
            .where((value) => value.isNotEmpty)
            .toSet();

  /// Patterns shipped with the app. Kept intentionally short: the ban list is
  /// editable in the API tab, and the real protection is the bearer token plus
  /// the phone's own SSH credentials.
  static const List<String> defaultBannedPatterns = <String>[
    // Shells and indirection: these would let a caller bypass the ban list.
    'sh',
    'bash',
    'dash',
    'zsh',
    'ksh',
    'busybox',
    'eval',
    'exec',
    'command',
    'builtin',
    // Destructive file operations.
    'rm',
    'rmdir',
    'shred',
    'truncate',
    // Disk and partition tools.
    'dd',
    'mkfs',
    'fdisk',
    'parted',
    'gdisk',
    'cfdisk',
    'wipefs',
    'mkswap',
    'mount',
    'umount',
    // Privilege escalation.
    'su',
    'sudo',
    'doas',
    // System power control.
    'shutdown',
    'reboot',
    'poweroff',
    'halt',
    'init',
    // Recursive ownership/permission changes.
    'chown -R',
    'chmod -R 777',
    // Fork bomb.
    ':(){',
  ];

  final Set<String> bannedPatterns;

  static String _normalizePattern(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return '';
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  bool get isDenyList => true;

  /// Returns an empty list when the command may run.
  List<String> rejectedReasons(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return const ['Command is empty.'];

    final segments = _splitSegments(trimmed);
    if (segments == null) {
      return const [
        'Command substitution, redirection, newlines, and shell control characters are not allowed.',
      ];
    }
    if (segments.any((segment) => segment.trim().isEmpty)) {
      return const ['Command contains an empty shell segment.'];
    }

    for (final segment in segments) {
      final match = _bannedMatch(segment);
      if (match != null) {
        return ['"$match" is on the command ban list.'];
      }
    }
    return const [];
  }

  /// Convenience predicate for callers that only need a boolean.
  bool isAllowed(String command) => rejectedReasons(command).isEmpty;

  bool isBanned(String command) => !isAllowed(command);

  String? _bannedMatch(String segment) {
    final normalized =
        segment.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;

    final tokens = normalized.split(' ');
    final commandName = _basename(tokens.first);

    for (final pattern in bannedPatterns) {
      final isSubstringPattern = pattern.contains(' ') ||
          pattern.contains('(') ||
          pattern.contains('{');
      if (isSubstringPattern) {
        if (normalized.contains(pattern)) return pattern;
      } else if (commandName == pattern ||
          commandName.startsWith('$pattern.')) {
        // `mkfs` also covers `mkfs.ext4`, `mkfs.fat`, and similar variants.
        return pattern;
      }
    }
    return null;
  }

  String _basename(String token) {
    final slash = token.lastIndexOf('/');
    return slash >= 0 ? token.substring(slash + 1) : token;
  }

  /// Splits a command only at shell operators outside quoted arguments.
  ///
  /// Returns null for commands containing constructs that are intentionally not
  /// supported by the API policy: command/variable substitution, redirection,
  /// newlines, or other shell control characters.
  List<String>? _splitSegments(String command) {
    final segments = <String>[];
    final current = StringBuffer();
    var quote = '';
    var escaped = false;

    for (final codeUnit in command.codeUnits) {
      final character = String.fromCharCode(codeUnit);
      if (escaped) {
        current.write(character);
        escaped = false;
        continue;
      }
      if (character == r'\' && quote != "'") {
        current.write(character);
        escaped = true;
        continue;
      }
      if (quote.isNotEmpty) {
        current.write(character);
        if (character == quote) quote = '';
        continue;
      }
      if (character == "'" || character == '"') {
        quote = character;
        current.write(character);
        continue;
      }
      if (character == '`' ||
          character == r'$' ||
          character == '>' ||
          character == '<' ||
          character == '\n' ||
          character == '\r' ||
          codeUnit < 0x20) {
        return null;
      }
      if (character == ';' || character == '&' || character == '|') {
        segments.add(current.toString());
        current.clear();
        continue;
      }
      current.write(character);
    }

    if (escaped || quote.isNotEmpty) return null;
    segments.add(current.toString());
    return segments;
  }
}
