import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_policy.dart';

class GatewayHealth {
  const GatewayHealth({
    required this.connected,
    required this.connecting,
    this.activeProfile,
  });

  final bool connected;
  final bool connecting;
  final String? activeProfile;
}

class GatewayConnectResult {
  const GatewayConnectResult({
    required this.connected,
    required this.profile,
    this.message,
  });

  final bool connected;
  final String profile;
  final String? message;
}

class GatewayCommandResult {
  const GatewayCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

class GatewayApiException implements Exception {
  const GatewayApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

typedef GatewayHealthCallback = Future<GatewayHealth> Function();
typedef GatewayConnectCallback = Future<GatewayConnectResult> Function(
  Map<String, dynamic> request,
);
typedef GatewayExecuteCallback = Future<GatewayCommandResult> Function(
  String command,
);
typedef GatewayDisconnectCallback = Future<void> Function();

class GatewayApiServer {
  GatewayApiServer({
    required this.token,
    required this.commandPolicy,
    required this.healthCallback,
    required this.connectCallback,
    required this.executeCallback,
    required this.disconnectCallback,
    this.port = 8765,
    this.allowLan = false,
    this.maxBodyBytes = 1024 * 1024,
  });

  final String token;
  final CommandPolicy commandPolicy;
  final GatewayHealthCallback healthCallback;
  final GatewayConnectCallback connectCallback;
  final GatewayExecuteCallback executeCallback;
  final GatewayDisconnectCallback disconnectCallback;
  final int port;
  final bool allowLan;
  final int maxBodyBytes;

  HttpServer? _server;
  Uri? _baseUri;

  Uri? get baseUri => _baseUri;
  bool get isRunning => _server != null;

  Future<Uri> start() async {
    if (_server != null) return _baseUri!;

    final address =
        allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(address, port);
    _server = server;
    _baseUri = Uri(
      scheme: 'http',
      host: allowLan ? '0.0.0.0' : '127.0.0.1',
      port: server.port,
    );

    server.listen(
      _handleRequest,
      onError: (Object error) {
        stderr.writeln('Gateway API server error: ${error.runtimeType}');
      },
      cancelOnError: false,
    );
    return _baseUri!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _baseUri = null;
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Cache-Control', 'no-store');

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    try {
      if (!_isAuthorized(request)) {
        response.headers.set(
          'WWW-Authenticate',
          'Bearer realm="Termux SSH Gateway"',
        );
        _writeJson(response, HttpStatus.unauthorized, {
          'ok': false,
          'error': {
            'code': 'unauthorized',
            'message': 'A valid bearer token is required.',
          },
        });
        return;
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _handleHealth(response);
      } else if (request.method == 'POST' && path == '/connect') {
        await _handleConnect(request, response);
      } else if (request.method == 'POST' && path == '/execute') {
        await _handleExecute(request, response);
      } else if (request.method == 'POST' && path == '/disconnect') {
        await _handleDisconnect(response);
      } else {
        _writeJson(response, HttpStatus.notFound, {
          'ok': false,
          'error': {
            'code': 'not_found',
            'message': 'No API endpoint matches ${request.method} $path.',
          },
        });
      }
    } on GatewayApiException catch (error) {
      _writeJson(response, error.statusCode, {
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      });
    } catch (_) {
      _writeJson(response, HttpStatus.internalServerError, {
        'ok': false,
        'error': {
          'code': 'internal_error',
          'message': 'The gateway could not complete the request.',
        },
      });
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    final provided = header.substring('Bearer '.length).trim();
    return _constantTimeEquals(provided, token);
  }

  bool _constantTimeEquals(String left, String right) {
    var difference = left.length ^ right.length;
    final length = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<void> _handleHealth(HttpResponse response) async {
    final health = await healthCallback();
    _writeJson(response, HttpStatus.ok, {
      'ok': true,
      'status': 'ok',
      'sshConnected': health.connected,
      'sshConnecting': health.connecting,
      'activeProfile': health.activeProfile,
    });
  }

  Future<void> _handleConnect(
    HttpRequest request,
    HttpResponse response,
  ) async {
    final body = await _readJsonBody(request);
    final profile = body['profile']?.toString().trim() ?? '';
    if (profile.isEmpty) {
      throw const GatewayApiException(
        HttpStatus.badRequest,
        'invalid_request',
        'The "profile" field is required and must identify a stored profile.',
      );
    }

    final result = await connectCallback(body);
    _writeJson(response, HttpStatus.ok, {
      'ok': result.connected,
      'connected': result.connected,
      'profile': result.profile,
      if (result.message != null) 'message': result.message,
    });
  }

  Future<void> _handleExecute(
    HttpRequest request,
    HttpResponse response,
  ) async {
    final body = await _readJsonBody(request);
    final command = body['command']?.toString().trim() ?? '';
    if (command.isEmpty) {
      throw const GatewayApiException(
        HttpStatus.badRequest,
        'invalid_request',
        'The "command" field is required.',
      );
    }

    final reasons = commandPolicy.rejectedReasons(command);
    if (reasons.isNotEmpty) {
      throw GatewayApiException(
        HttpStatus.forbidden,
        'command_not_allowed',
        reasons.join(' '),
      );
    }

    final result = await executeCallback(command);
    _writeJson(response, HttpStatus.ok, {
      'ok': result.exitCode == 0,
      'stdout': result.stdout,
      'stderr': result.stderr,
      'exitCode': result.exitCode,
    });
  }

  Future<void> _handleDisconnect(HttpResponse response) async {
    await disconnectCallback();
    _writeJson(response, HttpStatus.ok, {
      'ok': true,
      'connected': false,
    });
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        throw const GatewayApiException(
          413,
          'body_too_large',
          'The JSON request body exceeds the allowed size.',
        );
      }
    }

    if (bytes.isEmpty) return <String, dynamic>{};

    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('JSON root must be an object.');
      }
      return decoded;
    } on FormatException {
      throw const GatewayApiException(
        HttpStatus.badRequest,
        'invalid_json',
        'The request body must contain a valid JSON object.',
      );
    }
  }

  void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(response.close());
  }
}
