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

    // Substitution and redirection are disabled for the minimal API surface.
    if (trimmed.contains('`') ||
        trimmed.contains('\${') ||
        trimmed.contains('>') ||
        trimmed.contains('<')) {
      return false;
    }

    final segments = trimmed.split(RegExp(r'\s*(?:&&|\|\||;|\|)\s*'));
    if (segments.any((segment) => segment.trim().isEmpty)) return false;

    return segments.every((segment) {
      final normalizedSegment = segment.trim().toLowerCase();
      return allowedPrefixes.any((prefix) {
        final normalized = prefix.toLowerCase();
        return normalizedSegment == normalized ||
            normalizedSegment.startsWith('$normalized ');
      });
    });
  }

  List<String> rejectedReasons(String command) {
    final reasons = <String>[];
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      reasons.add('Command is empty.');
      return reasons;
    }
    if (trimmed.contains('`') ||
        trimmed.contains('\${') ||
        trimmed.contains('>') ||
        trimmed.contains('<')) {
      reasons.add('Command substitution and redirection are not allowed.');
    }
    if (!isAllowed(trimmed)) {
      reasons.add(
        'Command is not covered by the configured allowlist. Every shell segment must match an allowed prefix.',
      );
    }
    return reasons;
  }
}
