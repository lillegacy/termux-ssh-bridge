class CommandPolicy {
  CommandPolicy(Iterable<String> allowedPrefixes)
      : allowedPrefixes = allowedPrefixes
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();

  final Set<String> allowedPrefixes;

  bool isAllowed(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return false;

    final segments = _splitSegments(trimmed);
    if (segments == null || segments.any((segment) => segment.trim().isEmpty)) {
      return false;
    }

    return segments.every((segment) {
      final normalizedSegment = segment.trim().toLowerCase();
      return allowedPrefixes.any((prefix) {
        final normalized = prefix.toLowerCase();
        return normalizedSegment == normalized ||
            normalizedSegment.startsWith('$normalized ');
      });
    });
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
      if (quote == "'") {
        current.write(character);
        if (character == "'") quote = '';
        continue;
      }
      if (quote == '"' && character == '"') {
        current.write(character);
        quote = '';
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

  List<String> rejectedReasons(String command) {
    final reasons = <String>[];
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      reasons.add('Command is empty.');
      return reasons;
    }
    if (_splitSegments(trimmed) == null) {
      reasons.add(
        'Command substitution, redirection, newlines, and shell control characters are not allowed.',
      );
    }
    if (!isAllowed(trimmed)) {
      reasons.add(
        'Command is not covered by the configured allowlist. Every shell segment must match an allowed prefix.',
      );
    }
    return reasons;
  }
}
