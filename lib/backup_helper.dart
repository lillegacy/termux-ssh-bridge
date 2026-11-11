import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BackupHelper {
  static const _secureStorage = FlutterSecureStorage();

  static String _crypt(String text, String secretKey) {
    if (secretKey.isEmpty) {
      throw ArgumentError.value(secretKey, 'secretKey', 'Cannot be empty.');
    }
    List<int> result = [];
    for (int i = 0; i < text.length; i++) {
      int charCode =
          text.codeUnitAt(i) ^ secretKey.codeUnitAt(i % secretKey.length);
      result.add(charCode);
    }
    return base64Encode(result);
  }

  static String decrypt(String encryptedBase64, String secretKey) {
    try {
      List<int> bytes = base64Decode(encryptedBase64);
      List<int> result = [];
      for (int i = 0; i < bytes.length; i++) {
        int charCode = bytes[i] ^ secretKey.codeUnitAt(i % secretKey.length);
        result.add(charCode);
      }
      return utf8.decode(result);
    } catch (_) {
      return '';
    }
  }

  static String _csvEscape(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  static Future<String?> exportEncryptedCsv({
    required List<dynamic> profiles,
    required List<Map<String, String>> macros,
    required String secretKey,
  }) async {
    try {
      if (secretKey.isEmpty) return null;
      final Directory downloadsDir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final filePath =
          '${downloadsDir.path}/termux_ssh_bridge_backup_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File(filePath);

      StringBuffer sb = StringBuffer();
      sb.writeln('type,id,name,host,port,username,password_or_cmd');

      for (var p in profiles) {
        final pass =
            await _secureStorage.read(key: 'ssh_password_${p.id}') ?? '';
        sb.writeln(
          'profile,${_csvEscape(p.id.toString())},${_csvEscape(p.name.toString())},'
          '${_csvEscape(p.host.toString())},${_csvEscape(p.port.toString())},'
          '${_csvEscape(p.username.toString())},${_csvEscape(_crypt(pass, secretKey))}',
        );
      }

      for (var m in macros) {
        final name = m['name'] ?? '';
        final command = m['cmd'] ?? '';
        sb.writeln(
          'macro, ,${_csvEscape(name)}, , , ,${_csvEscape(_crypt(command, secretKey))}',
        );
      }

      await file.writeAsString(sb.toString());
      return filePath;
    } catch (e) {
      return null;
    }
  }
}
