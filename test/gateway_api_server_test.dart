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
      commandPolicy: CommandPolicy(['echo', 'pwd']),
      port: 0,
      healthCallback: () async => const GatewayHealth(
        connected: true,
        connecting: false,
        activeProfile: 'test-profile',
      ),
      connectCallback: (request) async => GatewayConnectResult(
        connected: true,
        profile: request['profile']!.toString(),
      ),
      executeCallback: (command) async => GatewayCommandResult(
        stdout: 'ran: $command',
        stderr: '',
        exitCode: 0,
      ),
      disconnectCallback: () async {
        disconnected = true;
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

  test('rejects commands outside the allowlist', () async {
    final response = await send(
      'POST',
      '/execute',
      token: 'test-secret',
      body: {'command': 'rm -rf /'},
    );
    expect(response.statusCode, HttpStatus.forbidden);
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(body['error']['code'], 'command_not_allowed');
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
}
