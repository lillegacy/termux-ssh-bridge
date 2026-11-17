import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/command_policy.dart';
import 'package:termux_ssh_bridge/gateway_api_server.dart';

void main() {
  late GatewayApiServer server;
  late HttpClient client;
  var disconnected = false;

  setUp(() async {
    disconnected = false;
    server = GatewayApiServer(
      token: 'test-secret',
      commandPolicy: CommandPolicy(['rm', 'sudo', 'shutdown']),
      port: 0,
      healthCallback: () async => const GatewayHealth(
        connected: true,
        connecting: false,
        activeProfile: 'test-profile',
      ),
      connectCallback: (request) async => GatewayConnectResult(
        connected: true,
        profile: request['profile']!.toString(),
        pinRequired: true,
        session: const {
          'sessionId': 'abc',
          'idle': false,
          'heartbeatSeconds': 5,
        },
      ),
      executeCallback: (command) async => GatewayCommandResult(
        stdout: 'ran: $command',
        stderr: '',
        exitCode: 0,
      ),
      disconnectCallback: () async {
        disconnected = true;
      },
      bridgeStatusCallback: () async => const {
        'sessionId': 'abc',
        'idle': true,
        'heartbeatSeconds': 30,
      },
      terminalOpenCallback: (columns, rows) async {
        throw StateError('SSH terminals are not available in this test.');
      },
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async {
    final request = await client.openUrl(
      method,
      server.baseUri!.replace(path: path),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return request.close();
  }

  test('rejects requests without a bearer token', () async {
    final response = await send('GET', '/health');
    expect(response.statusCode, HttpStatus.unauthorized);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['error']['code'], 'unauthorized');
  });

  test('returns health state', () async {
    final response = await send('GET', '/health', token: 'test-secret');
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['sshConnected'], isTrue);
    expect(body['activeProfile'], 'test-profile');
  });

  test('connects using a stored profile identifier', () async {
    final response = await send(
      'POST',
      '/connect',
      token: 'test-secret',
      body: {'profile': 'test-profile'},
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['connected'], isTrue);
    expect(body['profile'], 'test-profile');
  });

  test('executes allowed commands and returns output', () async {
    final response = await send(
      'POST',
      '/execute',
      token: 'test-secret',
      body: {'command': 'echo hello'},
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['stdout'], 'ran: echo hello');
    expect(body['exitCode'], 0);
  });

  test('rejects banned commands', () async {
    final response = await send(
      'POST',
      '/execute',
      token: 'test-secret',
      body: {'command': 'rm -rf /'},
    );
    expect(response.statusCode, HttpStatus.forbidden);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['error']['code'], 'command_not_allowed');
    expect(body['error']['message'], contains('rm'));
  });

  test('disconnects the shared SSH connection', () async {
    final response = await send(
      'POST',
      '/disconnect',
      token: 'test-secret',
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(disconnected, isTrue);
  });

  test('bridge connect returns session details and pin requirement', () async {
    final response = await send(
      'POST',
      '/bridge/connect',
      token: 'test-secret',
      body: {'profile': 'test-profile', 'pin': '1234'},
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['connected'], isTrue);
    expect(body['pinRequired'], isTrue);
    expect(body['session']['sessionId'], 'abc');
  });

  test('bridge execute returns output plus session state', () async {
    final response = await send(
      'POST',
      '/bridge/execute',
      token: 'test-secret',
      body: {'command': 'echo hello'},
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['stdout'], 'ran: echo hello');
    expect(body['session']['idle'], isTrue);
  });

  test('bridge status reports the idle session', () async {
    final response = await send(
      'GET',
      '/bridge/status',
      token: 'test-secret',
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['connected'], isTrue);
    expect(body['session']['heartbeatSeconds'], 30);
  });

  test('bridge heartbeat works as a cheap keep-alive', () async {
    final response = await send(
      'POST',
      '/bridge/heartbeat',
      token: 'test-secret',
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['session']['sessionId'], 'abc');
  });

  test('terminal status reports availability', () async {
    final response = await send(
      'GET',
      '/bridge/terminal/status',
      token: 'test-secret',
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['available'], isTrue);
    expect(body['activeTerminals'], 0);
    expect(body['maxTerminals'], 4);
  });

  test('terminal ticket is issued to authorized clients', () async {
    final response = await send(
      'POST',
      '/bridge/terminal/ticket',
      token: 'test-secret',
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['ticket'], isA<String>());
    expect((body['ticket'] as String).isNotEmpty, isTrue);
    expect(body['expiresInSeconds'], 60);
  });

  test('terminal ticket requires the bearer token', () async {
    final response = await send('POST', '/bridge/terminal/ticket');
    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('terminal websocket requires an upgrade request', () async {
    final request = await client.getUrl(
      server.baseUri!.replace(path: '/bridge/terminal'),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['error']['code'], 'upgrade_required');
  });

  test('terminal websocket rejects an unknown ticket', () async {
    final request = await client.getUrl(
      server.baseUri!.replace(path: '/bridge/terminal', query: 'ticket=bogus'),
    );
    request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    request.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
    request.headers.set('Sec-WebSocket-Version', '13');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.unauthorized);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['error']['code'], 'invalid_ticket');
  });
}
