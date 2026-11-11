import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum CloudCommandStatus { done, failed, rejected }

class CloudDeviceException implements Exception {
  const CloudDeviceException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class CloudDeviceCommand {
  const CloudDeviceCommand({required this.id, required this.command});

  final String id;
  final String command;

  @override
  bool operator ==(Object other) =>
      other is CloudDeviceCommand &&
      other.id == id &&
      other.command == command;

  @override
  int get hashCode => Object.hash(id, command);
}

class CloudDevicePairing {
  const CloudDevicePairing({
    required this.deviceId,
    required this.deviceKey,
    required this.name,
  });

  final String deviceId;
  final String deviceKey;
  final String name;
}

class CloudDeviceClient {
  CloudDeviceClient({
    required String baseUrl,
    required this.deviceKey,
    HttpClient? httpClient,
  })  : _baseUri = _parseBaseUri(baseUrl),
        _httpClient = httpClient ?? HttpClient();

  final Uri _baseUri;
  final String deviceKey;
  final HttpClient _httpClient;

  static Future<CloudDevicePairing> pair({
    required String baseUrl,
    required String code,
    required String name,
  }) async {
    final client = CloudDeviceClient(baseUrl: baseUrl, deviceKey: '');
    try {
      final response = await client._request(
        'POST',
        '/api/public/device/pair',
        body: {'code': code.trim().toUpperCase(), 'name': name.trim()},
        authenticated: false,
      );
      final deviceId = response['device_id'];
      final deviceKey = response['device_key'];
      final deviceName = response['name'];
      if (deviceId is! String ||
          deviceKey is! String ||
          !RegExp(r'^tdk_[a-f0-9]{64}$').hasMatch(deviceKey) ||
          deviceName is! String) {
        throw const FormatException('The pairing response is invalid.');
      }
      return CloudDevicePairing(
        deviceId: deviceId,
        deviceKey: deviceKey,
        name: deviceName,
      );
    } finally {
      client.close();
    }
  }

  Future<List<CloudDeviceCommand>> poll() async {
    final response = await _request(
      'GET',
      '/api/public/device/poll',
    );
    final commands = response['commands'];
    if (commands is! List) {
      throw const FormatException('The poll response has no commands list.');
    }

    return commands.map((value) {
      if (value is! Map<String, dynamic> ||
          value['id'] is! String ||
          value['command'] is! String) {
        throw const FormatException(
            'The poll response contains an invalid command.');
      }
      return CloudDeviceCommand(
        id: value['id'] as String,
        command: value['command'] as String,
      );
    }).toList();
  }

  Future<void> reportResult({
    required String commandId,
    required CloudCommandStatus status,
    required String output,
    int? exitCode,
  }) async {
    final boundedOutput = output.length <= 200000
        ? output
        : '${output.substring(0, 199960)}\n[output truncated]';
    await _request(
      'POST',
      '/api/public/device/result',
      body: {
        'command_id': commandId,
        'status': status.name,
        'output': boundedOutput,
        if (exitCode != null) 'exit_code': exitCode,
      },
    );
  }

  Future<void> unlink() async {
    await _request('POST', '/api/public/device/unlink');
  }

  void close() {
    _httpClient.close(force: true);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    final request = await _httpClient
        .openUrl(method, _baseUri.resolve(path))
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.acceptHeader, ContentType.json.mimeType)
      ..contentType = ContentType.json;
    if (authenticated) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $deviceKey',
      );
    }
    if (body != null) request.write(jsonEncode(body));

    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    dynamic decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const FormatException('The cloud service returned invalid JSON.');
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map<String, dynamic>
          ? decoded['message'] ?? decoded['error']
          : null;
      throw CloudDeviceException(
        response.statusCode,
        message is String
            ? message
            : 'Cloud request failed (${response.statusCode}).',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
          'The cloud service response must be a JSON object.');
    }
    return decoded;
  }

  static Uri _parseBaseUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException('Enter a valid webapp URL.');
    }

    final isLocalhost =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !isLocalhost) {
      throw const FormatException(
        'Cloud pairing requires HTTPS to protect the device key.',
      );
    }
    return uri;
  }
}
