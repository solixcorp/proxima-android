import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/vpn_models.dart';
import '../state/bounded_http_body.dart';

/// Queries the IP seen on the app's current network path, without credentials.
Future<PublicIpInfo> probeCurrentPublicIp({
  Uri? endpoint,
  HttpClient Function()? clientFactory,
}) async {
  final uri = endpoint ?? Uri.parse('https://get.geojs.io/v1/ip.json');
  final client = (clientFactory ?? HttpClient.new)();
  const timeout = Duration(seconds: 10);
  client.connectionTimeout = timeout;
  try {
    Future<PublicIpInfo> fetch() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        cancelHttpBody(response);
        throw HttpException('IP 조회 서버 응답 ${response.statusCode}');
      }
      final bytes = await readBoundedHttpBody(
        response,
        maxBytes: 16 * 1024,
        idleTimeout: timeout,
        totalTimeout: timeout,
        sizeError: 'IP 조회 응답이 너무 큽니다.',
      );
      final data = jsonDecode(utf8.decode(bytes));
      final ip = data is Map ? data['ip'] : null;
      if (ip is! String ||
          InternetAddress.tryParse(ip) == null ||
          ip.contains('%')) {
        throw const FormatException('IP 조회 응답이 올바르지 않습니다.');
      }
      return PublicIpInfo(ip: ip);
    }

    return await fetch().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
