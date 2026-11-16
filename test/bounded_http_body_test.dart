import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/state/bounded_http_body.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  final timers = <Timer>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/success':
          response.write('hello');
          await response.close();
        case '/stall':
          response.write('a');
          await response.flush();
        case '/trickle':
          response.write('a');
          await response.flush();
          timers.add(
            Timer.periodic(const Duration(milliseconds: 30), (timer) {
              response.write('a');
              response.flush().catchError((Object _) {
                timer.cancel();
              });
            }),
          );
        case '/large':
          response.add(Uint8List(8 * 1024 * 1024 + 1));
          await response.close();
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/success');
          response.write('a');
          await response.flush();
      }
    });
  });

  tearDown(() async {
    for (final timer in timers) {
      timer.cancel();
    }
    timers.clear();
    client.close(force: true);
    await server.close(force: true);
  });

  Future<HttpClientResponse> get(String path) async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    request.followRedirects = false;
    return request.close();
  }

  test('reads a complete body', () async {
    expect(
      utf8.decode(await readBoundedHttpBody(await get('/success'))),
      'hello',
    );
  });

  test('times out when body stalls after headers', () async {
    final response = await get('/stall');
    await expectLater(
      readBoundedHttpBody(
        response,
        idleTimeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('total deadline stops a body that keeps trickling', () async {
    final response = await get('/trickle');
    await expectLater(
      readBoundedHttpBody(
        response,
        idleTimeout: const Duration(milliseconds: 300),
        totalTimeout: const Duration(milliseconds: 160),
      ),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('deadline'),
        ),
      ),
    );
  });

  test('rejects a body over 8 MiB', () async {
    await expectLater(
      readBoundedHttpBody(await get('/large')),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'cancels a hanging redirect body before fetching its destination',
    () async {
      final response = await get('/redirect');
      expect(response.isRedirect, isTrue);
      cancelHttpBody(response);
      final next = await get(
        response.headers.value(HttpHeaders.locationHeader)!,
      );
      expect(utf8.decode(await readBoundedHttpBody(next)).toString(), 'hello');
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );
}
