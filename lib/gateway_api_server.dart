import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'command_policy.dart';

/// Handle over an interactive remote shell.
///
/// The gateway only needs a stream of output bytes plus write/resize/close, so
/// it does not depend on the SSH implementation and can be tested without an
/// SSH server.
abstract class GatewayTerminal {
  Stream<List<int>> get output;
  Stream<List<int>> get errors;
  void write(List<int> data);
  void resize(int columns, int rows);
  void close();
  int? get exitCode;
  Future<void> get done;
}

class GatewayHealth {
  const GatewayHealth({
    required this.connected,
    required this.connecting,
    this.activeProfile,
    this.bridge,
  });

  final bool connected;
  final bool connecting;
  final String? activeProfile;
  final Map<String, Object?>? bridge;
}

class GatewayConnectResult {
  const GatewayConnectResult({
    required this.connected,
    required this.profile,
    this.message,
    this.pinRequired = false,
    this.session,
  });

  final bool connected;
  final String profile;
  final String? message;
  final bool pinRequired;
  final Map<String, Object?>? session;
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
typedef GatewayStatusCallback = Future<Map<String, Object?>?> Function();
typedef GatewayTerminalOpenCallback = Future<GatewayTerminal> Function(
  int columns,
  int rows,
);

class GatewayApiServer {
  GatewayApiServer({
    required this.token,
    required this.commandPolicy,
    required this.healthCallback,
    required this.connectCallback,
    required this.executeCallback,
    required this.disconnectCallback,
    this.bridgeStatusCallback,
    this.terminalOpenCallback,
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
  final GatewayStatusCallback? bridgeStatusCallback;
  final GatewayTerminalOpenCallback? terminalOpenCallback;
  final int port;
  final bool allowLan;
  final int maxBodyBytes;

  HttpServer? _server;
  Uri? _baseUri;

  final Map<String, DateTime> _terminalTickets = {};
  int _activeTerminals = 0;

  static const _terminalTicketTtl = Duration(seconds: 60);
  static const _maxTerminalTickets = 32;
  static const _maxTerminals = 4;

  Uri? get baseUri => _baseUri;
  bool get isRunning => _server != null;
  int get activeTerminals => _activeTerminals;

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
      final path = request.uri.path;
      if (path == '/bridge/terminal') {
        await _handleTerminalRequest(request);
        return;
      }

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

      if (request.method == 'GET' && path == '/health') {
        await _handleHealth(response);
      } else if (request.method == 'POST' && path == '/connect') {
        await _handleConnect(request, response);
      } else if (request.method == 'POST' && path == '/execute') {
        await _handleExecute(request, response);
      } else if (request.method == 'POST' && path == '/disconnect') {
        await _handleDisconnect(response);
      } else if (request.method == 'POST' && path == '/bridge/connect') {
        await _handleConnect(request, response);
      } else if (request.method == 'POST' && path == '/bridge/execute') {
        await _handleExecute(request, response);
      } else if (request.method == 'POST' && path == '/bridge/disconnect') {
        await _handleDisconnect(response);
      } else if (request.method == 'GET' && path == '/bridge/status') {
        await _handleBridgeStatus(response);
      } else if (request.method == 'POST' && path == '/bridge/heartbeat') {
        await _handleBridgeStatus(response);
      } else if (request.method == 'POST' &&
          path == '/bridge/terminal/ticket') {
        _handleTerminalTicket(response);
      } else if (request.method == 'GET' && path == '/bridge/terminal/status') {
        _writeJson(response, HttpStatus.ok, {
          'ok': true,
          'activeTerminals': _activeTerminals,
          'maxTerminals': _maxTerminals,
          'available': terminalOpenCallback != null,
        });
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
      if (health.bridge != null) 'bridge': health.bridge,
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
      'pinRequired': result.pinRequired,
      if (result.message != null) 'message': result.message,
      if (result.session != null) 'session': result.session,
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
      if (bridgeStatusCallback != null)
        'session': await bridgeStatusCallback!(),
    });
  }

  Future<void> _handleDisconnect(HttpResponse response) async {
    await disconnectCallback();
    _writeJson(response, HttpStatus.ok, {
      'ok': true,
      'connected': false,
      'session': null,
    });
  }

  Future<void> _handleBridgeStatus(HttpResponse response) async {
    final session = await bridgeStatusCallback?.call();
    _writeJson(response, HttpStatus.ok, {
      'ok': true,
      'connected': session != null,
      'session': session,
    });
  }

  void _handleTerminalTicket(HttpResponse response) {
    if (terminalOpenCallback == null) {
      throw const GatewayApiException(
        HttpStatus.notImplemented,
        'terminal_unavailable',
        'This gateway build cannot open interactive terminals.',
      );
    }
    final ticket = _issueTerminalTicket();
    _writeJson(response, HttpStatus.ok, {
      'ok': true,
      'ticket': ticket,
      'expiresInSeconds': _terminalTicketTtl.inSeconds,
      'maxTerminals': _maxTerminals,
      'activeTerminals': _activeTerminals,
    });
  }

  String _issueTerminalTicket() {
    final now = DateTime.now();
    _terminalTickets.removeWhere((_, expiry) => !now.isBefore(expiry));
    while (_terminalTickets.length >= _maxTerminalTickets) {
      _terminalTickets.remove(_terminalTickets.keys.first);
    }
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final ticket = base64Url.encode(bytes).replaceAll('=', '');
    _terminalTickets[ticket] = now.add(_terminalTicketTtl);
    return ticket;
  }

  bool _consumeTerminalTicket(String ticket) {
    if (ticket.isEmpty) return false;
    final expiry = _terminalTickets.remove(ticket);
    if (expiry == null) return false;
    return DateTime.now().isBefore(expiry);
  }

  Future<void> _handleTerminalRequest(HttpRequest request) async {
    if (request.method != 'GET') {
      throw const GatewayApiException(
        HttpStatus.methodNotAllowed,
        'method_not_allowed',
        'The terminal endpoint only accepts WebSocket GET requests.',
      );
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      throw const GatewayApiException(
        HttpStatus.badRequest,
        'upgrade_required',
        'This endpoint only accepts WebSocket connections.',
      );
    }
    if (terminalOpenCallback == null) {
      throw const GatewayApiException(
        HttpStatus.notImplemented,
        'terminal_unavailable',
        'This gateway build cannot open interactive terminals.',
      );
    }
    if (!_consumeTerminalTicket(request.uri.queryParameters['ticket'] ?? '')) {
      throw const GatewayApiException(
        HttpStatus.unauthorized,
        'invalid_ticket',
        'Request a fresh terminal ticket before connecting.',
      );
    }
    if (_activeTerminals >= _maxTerminals) {
      throw const GatewayApiException(
        HttpStatus.tooManyRequests,
        'too_many_terminals',
        'The gateway already has the maximum number of open terminals.',
      );
    }

    final columns = _clampTerminalValue(
      request.uri.queryParameters['cols'],
      80,
      20,
      400,
    );
    final rows = _clampTerminalValue(
      request.uri.queryParameters['rows'],
      24,
      5,
      200,
    );

    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }

    _activeTerminals++;
    final GatewayTerminal session;
    try {
      session = await terminalOpenCallback!(columns, rows);
    } catch (error) {
      _activeTerminals--;
      await socket.close(
        WebSocketStatus.policyViolation,
        'Terminal could not be opened.',
      );
      return;
    }

    var closed = false;
    StreamSubscription<List<int>>? outputSubscription;
    StreamSubscription<List<int>>? errorSubscription;
    late final StreamSubscription<dynamic> socketSubscription;

    void send(Map<String, Object?> message) {
      if (closed || socket.readyState != WebSocket.open) return;
      socket.add(jsonEncode(message));
    }

    Future<void> finish() async {
      if (closed) return;
      closed = true;
      _activeTerminals--;
      await outputSubscription?.cancel();
      await errorSubscription?.cancel();
      try {
        await socketSubscription.cancel();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
    }

    void forward(List<int> data) {
      if (closed || socket.readyState != WebSocket.open) return;
      socket.add(data);
    }

    outputSubscription = session.output.listen(
      forward,
      onDone: () {
        send({'type': 'exit', 'code': session.exitCode});
        unawaited(finish());
      },
      onError: (Object error) {
        send({
          'type': 'error',
          'code': 'stream_failed',
          'message': 'The terminal stream failed: $error',
        });
        unawaited(finish());
      },
    );
    errorSubscription = session.errors.listen(
      forward,
      onError: (Object _) {},
    );

    socketSubscription = socket.listen(
      (dynamic event) {
        if (event is! String) {
          send({
            'type': 'error',
            'code': 'unsupported_frame',
            'message': 'Terminal input must be JSON text frames.',
          });
          return;
        }
        final message = _decodeTerminalMessage(event);
        if (message == null) {
          send({
            'type': 'error',
            'code': 'invalid_message',
            'message': 'Terminal messages must be JSON objects.',
          });
          return;
        }
        switch (message['type']) {
          case 'input':
            final data = message['data'];
            if (data is String && data.isNotEmpty) {
              session.write(utf8.encode(data));
            }
            break;
          case 'resize':
            session.resize(
              _clampTerminalValue(
                  message['cols']?.toString(), columns, 20, 400),
              _clampTerminalValue(message['rows']?.toString(), rows, 5, 200),
            );
            break;
          case 'ping':
            send({'type': 'pong'});
            break;
          default:
            send({
              'type': 'error',
              'code': 'unknown_message',
              'message': 'Unknown terminal message type.',
            });
        }
      },
      onDone: () {
        session.close();
        unawaited(finish());
      },
      onError: (Object _) {
        session.close();
        unawaited(finish());
      },
      cancelOnError: true,
    );

    send({
      'type': 'ready',
      'columns': columns,
      'rows': rows,
      'terminal': 'xterm-256color',
    });
  }

  Map<String, dynamic>? _decodeTerminalMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  int _clampTerminalValue(String? raw, int fallback, int min, int max) {
    final value = int.tryParse(raw ?? '') ?? fallback;
    if (value < min) return min;
    if (value > max) return max;
    return value;
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
    Map<String, Object?> body,
  ) {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(response.close());
  }
}
