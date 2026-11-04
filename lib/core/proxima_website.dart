import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxima_user_agent.dart';

Future<Uri> fetchProximaWebsite({Uri? listUri}) async {
  final client = HttpClient();
  const timeout = Duration(seconds: 15);
  try {
    return await (() async {
      final request = await client.getUrl(
        listUri ?? Uri.parse('https://proxima1.lovable.app/api/list'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.userAgentHeader, await proximaUserAgent());
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('사이트 목록 요청 실패: ${response.statusCode}');
      }
      final Object? data = jsonDecode(
        await response.transform(utf8.decoder).join(),
      );
      if (data is Map<String, dynamic> && data['domains'] is List) {
        for (final domain in data['domains'] as List) {
          if (domain is! String || domain.trim().isEmpty) continue;
          final value = domain.trim();
          final uri = Uri.tryParse(
            value.contains('://') ? value : 'https://$value',
          );
          if (uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty) {
            return uri;
          }
        }
      }
      throw const FormatException('사이트 목록에 유효한 HTTPS 주소가 없습니다.');
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
