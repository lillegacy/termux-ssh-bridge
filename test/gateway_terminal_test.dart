import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/command_policy.dart';
import 'package:termux_ssh_bridge/gateway_api_server.dart';

class FakeTerminal implements GatewayTerminal {
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final writes = <List<int>>[];
  final resizes = <List<int>>[];
  bool closed = false;

  void emit(String text) => _output.add(utf8.encode(text));

  Future<void> finish() => _output.close();

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Stream<List<int>> get errors => _errors.stream;

  @override
  void write(List<int> data) => writes.add(data);

  @override
  void resize(int columns, int rows) => resizes.add([columns, rows]);

  @override
  void close() => closed = true;

  @override
  int? get exitCode => 0;

  @override
  Future<void> get done => _output.done;
}

void main() {
  late GatewayApiServer server;
  late FakeTerminal terminal;
  late HttpClient client;

  setUp(() async {
    terminal = FakeTerminal();
    server = GatewayApiServer(
      token: 'test-secret',
      commandPolicy: CommandPolicy(const []),
      port: 0,
      healthCallback: () async =>
          const GatewayHealth(connected: true, connecting: false),
      connectCallback: (request) async =>
          const GatewayConnectResult(connected: true, profile: 'test'),
      executeCallback: (command) async =>
          const GatewayCommandResult(stdout: '', stderr: '', exitCode: 0),
      disconnectCallback: () async {},
      terminalOpenCallback: (columns, rows) async => terminal,
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<String> requestTicket() async {
    final request = await client.postUrl(
      server.baseUri!.replace(path: '/bridge/terminal/ticket'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-secret');
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    return body['ticket'] as String;
  }

  Future<WebSocket> connect(String ticket) => WebSocket.connect(
        server.baseUri!
            .replace(
              scheme: 'ws',
              path: '/bridge/terminal',
              query: 'ticket=$ticket&cols=100&rows=40',
            )
            .toString(),
      );

  Future<dynamic> nextFrame(List<dynamic> frames) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (frames.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for a websocket frame.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return frames.removeAt(0);
  }

  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for the expected state.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('streams a PTY session over the websocket', () async {
    final socket = await connect(await requestTicket());
    final frames = <dynamic>[];
    socket.listen(frames.add);

    final ready = await nextFrame(frames);
    expect(jsonDecode(ready as String)['type'], 'ready');
    expect(jsonDecode(ready)['columns'], 100);
    expect(jsonDecode(ready)['rows'], 40);

    socket.add(jsonEncode({'type': 'input', 'data': 'ls\r'}));
    await waitUntil(() => terminal.writes.isNotEmpty);
    expect(utf8.decode(terminal.writes.first), 'ls\r');

    terminal.emit('hello\r\n');
    final output = await nextFrame(frames);
    expect(output, isA<List<int>>());
    expect(utf8.decode(output as List<int>), 'hello\r\n');

    socket.add(jsonEncode({'type': 'resize', 'cols': 120, 'rows': 40}));
    await waitUntil(() => terminal.resizes.isNotEmpty);
    expect(terminal.resizes.first, [120, 40]);

    socket.add(jsonEncode({'type': 'ping'}));
    final pong = await nextFrame(frames);
    expect(jsonDecode(pong as String)['type'], 'pong');

    await terminal.finish();
    final exit = await nextFrame(frames);
    expect(jsonDecode(exit as String)['type'], 'exit');
    await socket.close();
  });

  test('rejects an unknown ticket', () async {
    await expectLater(connect('bogus'), throwsA(isA<WebSocketException>()));
  });

  test('a ticket can only be used once', () async {
    final ticket = await requestTicket();
    final first = await connect(ticket);
    first.listen((_) {});
    await expectLater(connect(ticket), throwsA(isA<WebSocketException>()));
    await first.close();
  });
}
