import 'dart:convert';

import 'vless_reality_profile.dart';

/// Individual failures do not prevent other links in a subscription from parsing.
class ShareLinkError {
  const ShareLinkError(this.link, this.message);
  final String link;
  final String message;
}

class ShareLinkResult {
  const ShareLinkResult(this.proxies, this.errors);
  final List<Map<String, Object?>> proxies;
  final List<ShareLinkError> errors;
}

/// Converts share links to Mihomo proxy mappings.
class ShareLinkParsers {
  static const maxInputLength = 1024 * 1024;
  static const maxLinkLength = 16384;
  static final _links = RegExp(
    r'(?:ss|ssr|vmess|vless|trojan|hysteria|hysteria2|hy2|tuic|wireguard|socks|socks5|http)://[^\s<>"\x27]+',
    caseSensitive: false,
  );

  /// Decode a subscription envelope without filtering out any protocol.
  static String decodeSubscription(String input) {
    if (input.length > maxInputLength || input.contains('://')) return input;
    try {
      final compact = input.replaceAll(RegExp(r'\s'), '');
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(compact)),
      );
      return decoded.length <= maxInputLength ? decoded : input;
    } on FormatException {
      return input;
    }
  }

  /// Names are unique even when an existing label already ends in a suffix.
  /// Reserved Mihomo names are also suffixed, starting with ` 2`.
  static ShareLinkResult parseMany(String input) {
    if (input.length > maxInputLength) {
      return const ShareLinkResult([], [ShareLinkError('', '입력이 너무 큽니다.')]);
    }
    final proxies = <Map<String, Object?>>[];
    final errors = <ShareLinkError>[];
    final used = <String>{
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'COMPATIBLE',
      'PASS',
      'PASS-RULE',
    };
    for (final match in _links.allMatches(input)) {
      final link = match.group(0)!;
      try {
        final proxy = parse(link);
        final base = proxy['name'] as String;
        var name = base;
        var n = 2;
        while (used.contains(name)) {
          name = '$base ${n++}';
        }
        used.add(name);
        proxy['name'] = name;
        proxies.add(proxy);
      } on FormatException catch (e) {
        errors.add(ShareLinkError(link, e.message));
      }
    }
    return ShareLinkResult(proxies, errors);
  }

  static Map<String, Object?> parse(String link) {
    if (link.length > maxLinkLength) throw const FormatException('링크가 너무 깁니다.');
    final scheme = link.split('://').first.toLowerCase();
    if (scheme == 'ssr') return _ssr(link.substring(6));
    if (scheme == 'vmess') return _vmess(link.substring(8));
    if (scheme == 'vless') return _vless(link);
    if (scheme == 'ss') return _ss(link);
    final uri = Uri.parse(link);
    final type = switch (scheme) {
      'socks' || 'socks5' => 'socks5',
      'hy2' => 'hysteria2',
      _ => scheme,
    };
    if (!const {
      'trojan',
      'hysteria',
      'hysteria2',
      'tuic',
      'wireguard',
      'socks5',
      'http',
    }.contains(type)) {
      throw FormatException('지원하지 않는 링크: $scheme');
    }
    final q = _query(uri);
    // Uri.hasPort treats an explicit :0 as absent for unknown schemes.
    // Inspect the original authority so it cannot become the default port.
    final authority = link
        .substring(link.indexOf('://') + 3)
        .split(RegExp(r'[/#?]'))
        .first
        .split('@')
        .last;
    final explicitPort = RegExp(r'^(?:\[[^\]]+\]|[^:]+):(.*)$')
        .firstMatch(authority);
    final port = type == 'hysteria2' && explicitPort != null
        ? int.tryParse(explicitPort.group(1)!) ?? 0
        : uri.hasPort
        ? uri.port
        : (type == 'hysteria2' ? 443 : 0);
    final proxy = _base(
      type,
      uri.host,
      port,
      Uri.decodeComponent(uri.fragment),
    );
    final user = Uri.decodeComponent(uri.userInfo);
    switch (type) {
      case 'socks5':
      case 'http':
        _check(q, {});
        if (user.isNotEmpty) {
          final parts = _splitOnce(user, ':');
          proxy['username'] = parts.$1;
          proxy['password'] = parts.$2;
        }
        if (type == 'socks5') proxy['udp'] = true;
      case 'trojan':
        _required(user, 'password');
        proxy['password'] = user;
        proxy['udp'] = true;
        _stream(proxy, q, trojan: true);
      case 'hysteria':
        _check(q, {
          'auth',
          'auth_str',
          'peer',
          'sni',
          'alpn',
          'obfs',
          'protocol',
          'upmbps',
          'downmbps',
        });
        if (user.isNotEmpty) proxy['auth-str'] = user;
        _copy(q, proxy, {
          'auth': 'auth',
          'auth_str': 'auth-str',
          'peer': 'sni',
          'sni': 'sni',
          'alpn': 'alpn',
          'obfs': 'obfs',
          'protocol': 'protocol',
          'upmbps': 'up',
          'downmbps': 'down',
        });
        if (proxy['protocol'] != null &&
            !const {'udp', 'wechat-video'}.contains(proxy['protocol'])) {
          throw const FormatException(
            'hysteria protocol은 udp 또는 wechat-video만 허용됩니다.',
          );
        }
        _alpn(proxy);
      case 'hysteria2':
        _check(q, {'sni', 'alpn', 'obfs', 'obfs-password', 'up', 'down'});
        _required(user, 'password');
        proxy['password'] = user;
        _copy(q, proxy, {
          'sni': 'sni',
          'alpn': 'alpn',
          'obfs': 'obfs',
          'obfs-password': 'obfs-password',
          'up': 'up',
          'down': 'down',
        });
        if (proxy.containsKey('obfs') && proxy['obfs'] != 'salamander') {
          throw const FormatException('hysteria2 obfs는 salamander만 지원합니다.');
        }
        if (proxy['obfs'] == 'salamander') {
          _required(proxy['obfs-password'] as String? ?? '', 'obfs-password');
        }
        _alpn(proxy);
      case 'tuic':
        _check(q, {'sni', 'alpn', 'congestion_control', 'udp_relay_mode'});
        final parts = _splitOnce(user, ':');
        _uuid(parts.$1);
        _required(parts.$2, 'password');
        proxy.addAll({'uuid': parts.$1, 'password': parts.$2});
        _copy(q, proxy, {
          'sni': 'sni',
          'alpn': 'alpn',
          'congestion_control': 'congestion-controller',
          'udp_relay_mode': 'udp-relay-mode',
        });
        _alpn(proxy);
      case 'wireguard':
        _check(q, {
          'publickey',
          'presharedkey',
          'address',
          'reserved',
          'mtu',
          'keepalive',
        });
        _required(user, 'private-key');
        _required(q['publickey'] ?? '', 'publickey');
        _required(q['address'] ?? '', 'address');
        proxy.addAll({
          'private-key': user,
          'public-key': q['publickey'],
          'udp': true,
        });
        final addresses = q['address']!.split(',');
        for (final address in addresses) {
          final ip = address.split('/').first;
          proxy[ip.contains(':') ? 'ipv6' : 'ip'] = ip;
        }
        if (q.containsKey('presharedkey')) {
          proxy['pre-shared-key'] = q['presharedkey'];
        }
        for (final pair in {
          'mtu': 'mtu',
          'keepalive': 'persistent-keepalive',
        }.entries) {
          if (q.containsKey(pair.key)) {
            proxy[pair.value] = _number(q[pair.key]!, pair.key);
          }
        }
        if (q.containsKey('reserved')) {
          final values = q['reserved']!
              .split(',')
              .map((v) => _number(v, 'reserved'))
              .toList();
          if (values.length != 3 || values.any((v) => v > 255)) {
            throw const FormatException('reserved는 세 바이트여야 합니다.');
          }
          proxy['reserved'] = values;
        }
    }
    return proxy;
  }

  static Map<String, Object?> _ss(String link) {
    var uri = Uri.parse(link);
    if (uri.userInfo.isEmpty) {
      final body = link.substring(5).split('#').first.split('?').first;
      final decoded = _decode(body);
      final suffix = link.substring(5 + body.length);
      uri = Uri.parse('ss://$decoded$suffix');
    }
    var credentials = Uri.decodeComponent(uri.userInfo);
    if (!credentials.contains(':')) credentials = _decode(credentials);
    final parts = _splitOnce(credentials, ':');
    _required(parts.$1, 'cipher');
    _required(parts.$2, 'password');
    final p = _base(
      'ss',
      uri.host,
      uri.hasPort ? uri.port : 0,
      Uri.decodeComponent(uri.fragment),
    )..addAll({'cipher': parts.$1, 'password': parts.$2, 'udp': true});
    final q = _query(uri);
    _check(q, {'plugin'});
    if (q.containsKey('plugin')) {
      final bits = q['plugin']!.split(';');
      if (bits.first != 'obfs-local' &&
          bits.first != 'simple-obfs' &&
          bits.first != 'obfs') {
        throw const FormatException('SS는 in-process obfs plugin만 허용됩니다.');
      }
      final opts = <String, Object?>{};
      for (final bit in bits.skip(1)) {
        final part = _splitOnce(bit, '=');
        final key = switch (part.$1) {
          'obfs' => 'mode',
          'obfs-host' => 'host',
          _ => throw FormatException('허용되지 않는 plugin 옵션: ${part.$1}'),
        };
        opts[key] = part.$2;
      }
      if (!const {'http', 'tls'}.contains(opts['mode'])) {
        throw const FormatException('obfs mode는 http 또는 tls여야 합니다.');
      }
      p.addAll({'plugin': 'obfs', 'plugin-opts': opts});
    }
    return p;
  }

  static Map<String, Object?> _ssr(String body) {
    final decoded = _decode(body);
    final slash = decoded.indexOf('/?');
    final main = slash < 0 ? decoded : decoded.substring(0, slash);
    final pieces = main.split(':');
    if (pieces.length != 6) throw const FormatException('SSR 형식이 잘못되었습니다.');
    final q = slash < 0
        ? <String, String>{}
        : _query(Uri.parse('x://x/?${decoded.substring(slash + 2)}'));
    _check(q, {'obfsparam', 'protoparam', 'remarks', 'group'});
    final p =
        _base(
          'ssr',
          pieces[0],
          _number(pieces[1], 'port'),
          q.containsKey('remarks') ? _decode(q['remarks']!) : '',
        )..addAll({
          'protocol': pieces[2],
          'cipher': pieces[3],
          'obfs': pieces[4],
          'password': _decode(pieces[5]),
          'udp': true,
        });
    for (final key in ['protocol', 'cipher', 'obfs', 'password']) {
      _required(p[key] as String, key);
    }
    if (q.containsKey('obfsparam')) p['obfs-param'] = _decode(q['obfsparam']!);
    if (q.containsKey('protoparam')) {
      p['protocol-param'] = _decode(q['protoparam']!);
    }
    return p;
  }

  static Map<String, Object?> _vmess(String body) {
    final json = jsonDecode(_decode(body));
    if (json is! Map) throw const FormatException('VMess JSON 객체가 필요합니다.');
    String value(String key, [String fallback = '']) =>
        json[key]?.toString() ?? fallback;
    const allowed = {
      'v',
      'ps',
      'add',
      'port',
      'id',
      'aid',
      'scy',
      'net',
      'type',
      'host',
      'path',
      'tls',
      'sni',
      'alpn',
      'fp',
    };
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('허용되지 않는 VMess 옵션: $key');
      }
    }
    final id = value('id');
    _uuid(id);
    final p =
        _base(
          'vmess',
          value('add'),
          _number(value('port'), 'port'),
          value('ps'),
        )..addAll({
          'uuid': id,
          'alterId': _number(value('aid', '0'), 'aid'),
          'cipher': value('scy', 'auto'),
          'udp': true,
        });
    final tls = value('tls');
    if (tls.isNotEmpty && tls != 'tls') {
      throw FormatException('지원하지 않는 VMess TLS: $tls');
    }
    if (tls == 'tls') p['tls'] = true;
    if (value('sni').isNotEmpty) p['servername'] = value('sni');
    if (value('fp').isNotEmpty) p['client-fingerprint'] = value('fp');
    if (value('alpn').isNotEmpty) p['alpn'] = value('alpn').split(',');
    if (value('type').isNotEmpty && value('type') != 'none') {
      throw const FormatException('VMess header type은 지원하지 않습니다.');
    }
    _network(
      p,
      value('net', 'tcp'),
      value('path'),
      value('host'),
      value('path'),
    );
    return p;
  }

  static Map<String, Object?> _vless(String link) {
    final uri = Uri.parse(link);
    final q = _query(uri);
    _check(q, {
      'security',
      'pbk',
      'sid',
      'type',
      'path',
      'host',
      'serviceName',
      'sni',
      'fp',
      'flow',
      'encryption',
    });
    if (q.containsKey('encryption') && q['encryption'] != 'none') {
      throw const FormatException('VLESS encryption은 허용되지 않습니다.');
    }
    final v = VlessRealityProfile.parse(link);
    if (v.network == 'xhttp') {
      throw const FormatException('VLESS XHTTP는 엔진에서 허용되지 않습니다.');
    }
    final p = _base('vless', v.server, v.port, v.name)
      ..addAll({'uuid': v.uuid, 'udp': true, 'tls': v.security != 'none'});
    if (v.security != 'none') {
      p.addAll({
        'servername': v.serverName,
        'client-fingerprint': v.fingerprint,
      });
    }
    if (v.flow.isNotEmpty) p['flow'] = v.flow;
    if (v.security == 'reality') {
      p['reality-opts'] = {
        'public-key': v.publicKey,
        if (v.shortId.isNotEmpty) 'short-id': v.shortId,
      };
    }
    _network(p, v.network, v.path ?? '', v.host ?? '', v.serviceName ?? '');
    return p;
  }

  static void _stream(
    Map<String, Object?> p,
    Map<String, String> q, {
    required bool trojan,
  }) {
    _check(q, {
      'type',
      'security',
      'sni',
      'peer',
      'alpn',
      'fp',
      'path',
      'host',
      'serviceName',
    });
    if (q.containsKey('security') && q['security'] != 'tls') {
      throw const FormatException('Trojan은 TLS만 지원합니다.');
    }
    _copy(q, p, {
      'sni': 'sni',
      'peer': 'sni',
      'alpn': 'alpn',
      'fp': 'client-fingerprint',
    });
    _alpn(p);
    _network(
      p,
      q['type'] ?? 'tcp',
      q['path'] ?? '',
      q['host'] ?? '',
      q['serviceName'] ?? '',
    );
  }

  static void _network(
    Map<String, Object?> p,
    String net,
    String path,
    String host,
    String service,
  ) {
    if (net == 'raw') net = 'tcp';
    if (!const {'tcp', 'ws', 'grpc'}.contains(net)) {
      throw FormatException('전송 방식 $net은 지원하지 않습니다.');
    }
    p['network'] = net;
    if (net == 'ws') {
      p['ws-opts'] = {
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty) 'headers': {'Host': host},
      };
    }
    if (net == 'grpc' && service.isNotEmpty) {
      p['grpc-opts'] = {'grpc-service-name': service};
    }
  }

  static Map<String, Object?> _base(
    String type,
    String server,
    int port,
    String name,
  ) {
    _required(server, 'server');
    if (port < 1 || port > 65535) {
      throw const FormatException('유효한 단일 포트가 필요합니다 (포트 호핑 불가).');
    }
    return {
      'name': name.isEmpty ? '$type · $server' : name,
      'type': type,
      'server': server,
      'port': port,
    };
  }

  static Map<String, String> _query(Uri uri) {
    final result = <String, String>{};
    for (final entry in uri.queryParametersAll.entries) {
      if (entry.value.length != 1) throw FormatException('중복 옵션: ${entry.key}');
      result[entry.key] = entry.value.single;
    }
    return result;
  }

  static void _check(Map<String, String> q, Set<String> allowed) {
    for (final key in q.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('옵션 $key는 지원되지 않거나 엔진 admission에서 거부됩니다.');
      }
    }
  }

  static void _copy(
    Map<String, String> q,
    Map<String, Object?> p,
    Map<String, String> keys,
  ) {
    for (final entry in keys.entries) {
      if (q.containsKey(entry.key)) p[entry.value] = q[entry.key];
    }
  }

  static void _alpn(Map<String, Object?> p) {
    if (p['alpn'] case final String value) p['alpn'] = value.split(',');
  }

  static String _decode(String encoded) {
    if (encoded.length > maxLinkLength) {
      throw const FormatException('Base64 입력이 너무 깁니다.');
    }
    return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
  }

  static (String, String) _splitOnce(String value, String separator) {
    final at = value.indexOf(separator);
    if (at < 0) throw FormatException('$separator 구분자가 필요합니다.');
    return (value.substring(0, at), value.substring(at + 1));
  }

  static void _required(String value, String key) {
    if (value.isEmpty) throw FormatException('$key 값이 필요합니다.');
  }

  static int _number(String value, String key) {
    final number = int.tryParse(value);
    if (number == null || number < 0) {
      throw FormatException('$key 숫자가 잘못되었습니다.');
    }
    return number;
  }

  static void _uuid(String value) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value)) {
      throw const FormatException('UUID가 잘못되었습니다.');
    }
  }
}
