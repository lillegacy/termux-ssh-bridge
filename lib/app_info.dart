/// Version injected at build time from `pubspec.yaml`:
///
/// ```
/// flutter build apk --dart-define=APP_VERSION=1.5.1+11
/// ```
///
/// Local builds that skip the define show `dev build`, which makes it obvious
/// that the APK did not come from the release workflow.
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// Human-readable label, e.g. `v1.5.1+11` or `dev build`.
String get appVersionLabel =>
    appVersion == 'dev' ? 'dev build' : 'v$appVersion';
