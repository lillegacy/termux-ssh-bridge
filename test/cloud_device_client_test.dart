import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/cloud_device_client.dart';

void main() {
  late HttpServer server;
  late List<Map<String, Object?>> requests;
  final deviceKey = 'tdk_${List<String>.filled(64, "a").join()}';

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'authorization': request.headers.value(HttpHeaders.authorizationHeader),
        'body': body.isEmpty ? null : jsonDecode(body),
      });

      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/public/device/pair') {
        request.response.write(jsonEncode({
          'device_id': 'device-id',
          'device_key': deviceKey,
          'name': 'Phone',
        }));
      } else if (request.uri.path == '/api/public/device/poll') {
        request.response.write(jsonEncode({
          'commands': [
            {'id': 'command-id', 'command': 'pwd'}
          ],
        }));
      } else {
        request.response.write(jsonEncode({'ok': true}));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  test('pairs using the one-time webapp code without sending a device key', () async {
    final paired = await CloudDeviceClient.pair(
      baseUrl: baseUrl(),
      code: 'abc123',
      name: 'Phone',
    );

    expect(paired.deviceId, 'device-id');
    expect(paired.deviceKey, deviceKey);
    expect(requests.single, {
      'method': 'POST',
      'path': '/api/public/device/pair',
      'authorization': null,
      'body': {'code': 'ABC123', 'name': 'Phone'},
    });
  });

  test('polls for commands with the saved device key', () async {
    final client = CloudDeviceClient(baseUrl: baseUrl(), deviceKey: deviceKey);
    addTearDown(client.close);

    final commands = await client.poll();

    expect(commands, [
      const CloudDeviceCommand(id: 'command-id', command: 'pwd'),
    ]);
    expect(requests.single['authorization'], 'Bearer $deviceKey');
  });

  test('reports command results in the cloud queue format', () async {
    final client = CloudDeviceClient(baseUrl: baseUrl(), deviceKey: deviceKey);
    addTearDown(client.close);

    await client.reportResult(
      commandId: 'command-id',
      status: CloudCommandStatus.rejected,
      output: 'Command is not allowed.',
    );

    expect(requests.single, {
      'method': 'POST',
      'path': '/api/public/device/result',
      'authorization': 'Bearer $deviceKey',
      'body': {
        'command_id': 'command-id',
        'status': 'rejected',
        'output': 'Command is not allowed.',
      },
    });
  });

  test('requires HTTPS for non-local cloud servers', () {
    expect(
      () => CloudDeviceClient(baseUrl: 'http://example.com', deviceKey: deviceKey),
      throwsFormatException,
    );
  });
}
