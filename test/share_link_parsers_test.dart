import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/share_link_parsers.dart';

String b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

void main() {
  const id = '12345678-1234-1234-1234-123456789abc';
  test('SIP002 and SSR', () {
    final ss = ShareLinkParsers.parse(
      'ss://${b64('aes-128-gcm:secret')}@example.com:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.org#node',
    );
    expect(ss['plugin'], 'obfs');
    expect(ss['plugin-opts'], {'mode': 'http', 'host': 'example.org'});
    expect(ss['udp'], true);
    final ssr = ShareLinkParsers.parse(
      'ssr://${b64('example.com:443:origin:aes-128-cfb:plain:${b64('secret')}/?remarks=${b64('node')}')}',
    );
    expect(ssr['password'], 'secret');
    expect(ssr['name'], 'node');
  });

  test('VMess WS and gRPC', () {
    final vmess = {
      'v': '2',
      'ps': 'node',
      'add': 'example.com',
      'port': '443',
      'id': id,
      'aid': '0',
      'net': 'ws',
      'path': '/ws',
      'host': 'cdn.example',
      'tls': 'tls',
    };
    final proxy = ShareLinkParsers.parse('vmess://${b64(jsonEncode(vmess))}');
    expect(proxy['ws-opts'], {
      'path': '/ws',
      'headers': {'Host': 'cdn.example'},
    });
    vmess['net'] = 'grpc';
    expect(
      ShareLinkParsers.parse('vmess://${b64(jsonEncode(vmess))}')['grpc-opts'],
      {'grpc-service-name': '/ws'},
    );
  });

  test('VLESS uses existing parser but rejects unaudited XHTTP', () {
    final p = ShareLinkParsers.parse(
      'vless://$id@example.com:443?security=tls&type=ws&path=%2F#node',
    );
    expect(p['type'], 'vless');
    expect(p['udp'], true);
    expect(
      () => ShareLinkParsers.parse('vless://$id@example.com:443?type=xhttp'),
      throwsFormatException,
    );
  });

  test('Trojan, Hysteria, Hysteria2, TUIC, WireGuard and basic proxies', () {
    expect(
      ShareLinkParsers.parse(
        'trojan://secret@example.com:443?type=grpc&serviceName=svc',
      )['grpc-opts'],
      {'grpc-service-name': 'svc'},
    );
    expect(
      ShareLinkParsers.parse(
        'hysteria://example.com:443?auth=secret&protocol=udp',
      )['auth'],
      'secret',
    );
    final hy = ShareLinkParsers.parse(
      'hysteria2://secret@example.com:443?obfs=salamander&obfs-password=pw',
    );
    expect(hy['obfs'], 'salamander');
    // protocol_admission.go has no udp key for hysteria/hysteria2/tuic.
    expect(hy.containsKey('udp'), false);
    final tuic = ShareLinkParsers.parse(
      'tuic://$id:secret@example.com:443?congestion_control=bbr',
    );
    expect(tuic['congestion-controller'], 'bbr');
    expect(tuic.containsKey('udp'), false);
    final wg = ShareLinkParsers.parse(
      'wireguard://private@example.com:443?publickey=pub&address=10.0.0.2%2F32&keepalive=25',
    );
    expect(wg['ip'], '10.0.0.2');
    expect(wg['persistent-keepalive'], 25);
    expect(
      ShareLinkParsers.parse('socks://u:p@example.com:1080')['username'],
      'u',
    );
    expect(
      ShareLinkParsers.parse('http://u:p@example.com:8080')['password'],
      'p',
    );
  });

  test('admission rejects insecure, hopping, plugins and malformed inputs', () {
    // DIALERS.md: port hopping is not admitted; only simple obfs is admitted.
    for (final link in [
      'ss://bad!@example.com:443',
      'ss://${b64('aes-128-gcm:pw')}@example.com:443?plugin=v2ray-plugin',
      'hysteria2://pw@example.com:443?ports=443-500',
      'hysteria2://pw@example.com:443?insecure=1',
      'hy2://pw@example.com:443,444',
      'hysteria://example.com:443?protocol=faketcp',
      'vmess://not-base64!',
      'tuic://bad@example.com:443',
      'wireguard://private@example.com:443',
    ]) {
      expect(
        () => ShareLinkParsers.parse(link),
        throwsFormatException,
        reason: link,
      );
    }
  });

  test('Hysteria2 URI default port and percent-encoded credentials', () {
    for (final scheme in ['hy2', 'hysteria2']) {
      final proxy = ShareLinkParsers.parse(
        '$scheme://user%3Ap%40ss%2Fword@example.com/?sni=tls.example&obfs=salamander&obfs-password=a%2Bb%26c#My%20node',
      );
      expect(proxy['port'], 443);
      expect(proxy['password'], 'user:p@ss/word');
      expect(proxy['name'], 'My node');
      expect(proxy['sni'], 'tls.example');
      expect(proxy['obfs-password'], 'a+b&c');
    }
    expect(
      () => ShareLinkParsers.parse('hy2://pw@example.com:0'),
      throwsFormatException,
    );
  });

  test('mixed links return individual errors and collision-free names', () {
    final result = ShareLinkParsers.parseMany('''
socks://example.com:1080#node
socks://example.com:1080#node%202
socks://example.com:1080#node
vmess://bad!
''');
    expect(result.proxies.map((p) => p['name']), ['node', 'node 2', 'node 3']);
    expect(result.errors, hasLength(1));
  });
}
