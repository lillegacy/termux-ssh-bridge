import 'package:flutter/services.dart';

/// Thin wrapper over the Android keep-alive foreground service.
///
/// The service does no work itself: Dart owns the SSH client, the gateway and
/// the timers. A foreground service only raises the process priority so Android
/// stops reclaiming the app while the screen is off.
class BridgeKeepAlive {
  static const MethodChannel _channel =
      MethodChannel('com.termuxsshbridge/keep_alive');

  static Future<void> start(String text) => _invoke('start', {'text': text});

  static Future<void> update(String text) => _invoke('update', {'text': text});

  static Future<void> stop() => _invoke('stop');

  static Future<void> requestNotificationPermission() =>
      _invoke('requestNotificationPermission');

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog. Returns true when the request was launched.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final result = await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not running on Android: nothing to keep alive.
    } on PlatformException {
      // Keeping the app alive is best effort; never surface it to the UI.
    }
  }
}
