import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/proxima_website.dart';

void main() {
  late HttpServer server;
  late Uri listUri;
  Object? payload;
  var status = HttpStatus.ok;

  setUp(() async {
    status = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listUri = Uri.parse(
      'http://${server.address.host}:${server.port}/api/list',
    );
    server.listen((request) async {
      expect(request.uri.path, '/api/list');
      expect(request.headers.value(HttpHeaders.cacheControlHeader), 'no-cache');
      request.response.statusCode = status;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('selects the first valid HTTPS domain from the live list', () async {
    payload = {
      'domains': [
        null,
        '',
        'http://unsafe.example',
        'first.example',
        'second.example',
      ],
    };
    expect(
      await fetchProximaWebsite(listUri: listUri, checkServer: (_) async => true),
      Uri.https('first.example'),
    );
  });

  test('fetches changed addresses again on the next request', () async {
    payload = {
      'domains': ['https://first.example'],
    };
    expect(
      await fetchProximaWebsite(listUri: listUri, checkServer: (_) async => true),
      Uri.https('first.example'),
    );
    payload = {
      'domains': ['https://changed.example'],
    };
    expect(
      await fetchProximaWebsite(listUri: listUri, checkServer: (_) async => true),
      Uri.https('changed.example'),
    );
  });

  test(
    'rejects malformed or empty lists and credential-bearing URLs',
    () async {
      for (final invalid in [
        <String, Object?>{},
        {'domains': <String>[]},
        {
          'domains': [
            'https://user:password@example.com',
            'http://example.com',
          ],
        },
      ]) {
        payload = invalid;
        await expectLater(
          fetchProximaWebsite(listUri: listUri),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects unsuccessful list responses', () async {
    status = HttpStatus.serviceUnavailable;
    payload = {
      'domains': ['example.com'],
    };
    await expectLater(
      fetchProximaWebsite(listUri: listUri),
      throwsA(isA<HttpException>()),
    );
  });

  test('skips unavailable domains and probes only valid origins', () async {
    payload = {
      'domains': [
        'https://user:secret@example.com',
        'https://example.com/not-an-origin',
        'offline.example',
        'unavailable.example',
        'healthy.example',
      ],
    };
    final checked = <Uri>[];
    final selected = await fetchProximaWebsite(
      listUri: listUri,
      checkServer: (uri) async {
        checked.add(uri);
        if (uri.host == 'offline.example') {
          throw const SocketException('offline');
        }
        return uri.host == 'healthy.example';
      },
    );
    expect(selected, Uri.https('healthy.example'));
    expect(checked.map((uri) => uri.host), [
      'offline.example', 'unavailable.example', 'healthy.example',
    ]);
  });

  test('does not fall back to a fixed host when all servers fail', () async {
    payload = {'domains': ['offline.example']};
    await expectLater(
      fetchProximaWebsite(
        listUri: listUri,
        checkServer: (_) async => false,
      ),
      throwsFormatException,
    );
  });
}
