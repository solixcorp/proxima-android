import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/mihomo_rule_set.dart';

void main() {
  test('decodes a hand-encoded one-edge LOUDS trie', () {
    final raw = _header(0, 1)
      ..add(1)
      ..addAll(_u64(1))
      ..addAll(_u64(2))
      ..addAll(_u64(1))
      ..addAll(_u64(6))
      ..addAll(_u64(1))
      ..add(97);
    expect(decodeMihomoMrs(_compress(raw), behavior: 'domain'), ['a']);
  });

  test('preserves exact suffix-only and single-label wildcard patterns', () {
    const domains = [
      'exact.example',
      '.suffix.example',
      '*.wild.example',
      'sub.*.example',
      'both.example',
      '+.both.example',
      '+.*.mixed.example',
      '例子.测试',
      'emoji.😀.example',
      '*',
    ];
    final decoded = decodeMihomoMrs(
      _compress(_domains(domains, count: 100)),
      behavior: 'domain',
    );
    expect(
      decoded,
      unorderedEquals([
        'exact.example',
        '.suffix.example',
        '*.wild.example',
        'sub.*.example',
        'both.example',
        '.both.example',
        '*.mixed.example',
        '.*.mixed.example',
        '例子.测试',
        'emoji.😀.example',
        '*',
      ]),
    );
    expect(decoded, isNot(contains('suffix.example')));
    expect(decoded, isNot(contains('.exact.example')));
  });

  test('traverses branches and terminals across bitmap word boundaries', () {
    final domains = [
      'example',
      for (var i = 0; i < 130; i++) 'host$i.example',
      '${'a' * 300}.example',
    ];
    expect(
      decodeMihomoMrs(_compress(_domains(domains)), behavior: 'domain'),
      unorderedEquals(domains),
    );
  });

  test('skips bounded reserved header bytes', () {
    final raw = _domains(['example']);
    raw.replaceRange(13, 21, _u64(3));
    raw.insertAll(21, [0, 255, 7]);
    expect(decodeMihomoMrs(_compress(raw), behavior: 'domain'), ['example']);
  });

  test('decodes actual compressed blocks with a verified checksum', () {
    final domains = [for (var i = 0; i < 200; i++) 'node$i.example.com'];
    final raw = _domains(domains);
    final compressed = _compress(raw);
    expect(compressed.length, lessThan(raw.length));
    expect(
      decodeMihomoMrs(compressed, behavior: 'domain'),
      unorderedEquals(domains),
    );
    compressed[compressed.length - 1] ^= 1;
    expect(
      () => decodeMihomoMrs(compressed, behavior: 'domain'),
      throwsFormatException,
    );
  });

  test('converts mapped IPv4 and IPv6 inclusive ranges to exact CIDRs', () {
    final raw = _ranges([
      (_ipv4(192, 0, 2, 0), _ipv4(192, 0, 2, 255)),
      (_ipv4(198, 51, 100, 1), _ipv4(198, 51, 100, 6)),
      (
        _ip6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 0]),
        _ip6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 255]),
      ),
      (
        _ip6([0x2001, 0xdb8, 1, 0, 0, 0, 0, 1]),
        _ip6([0x2001, 0xdb8, 1, 0, 0, 0, 0, 6]),
      ),
    ], count: 100);
    expect(decodeMihomoMrs(_compress(raw), behavior: 'ipcidr'), [
      '192.0.2.0/24',
      '198.51.100.1/32',
      '198.51.100.2/31',
      '198.51.100.4/31',
      '198.51.100.6/32',
      '2001:db8::/120',
      '2001:db8:1::1/128',
      '2001:db8:1::2/127',
      '2001:db8:1::4/127',
      '2001:db8:1::6/128',
    ]);
  });

  test('handles address-space extremes and canonical IPv6 zero runs', () {
    final zero = List<int>.filled(16, 0);
    final maximum = List<int>.filled(16, 255);
    final raw = _ranges([
      (_ipv4(0, 0, 0, 0), _ipv4(255, 255, 255, 255)),
      (zero, maximum),
      (zero, zero),
      (maximum, maximum),
      (_ip6([0, 0, 1, 0, 0, 2, 3, 4]), _ip6([0, 0, 1, 0, 0, 2, 3, 4])),
      (_ip6([1, 2, 3, 4, 5, 6, 0, 0]), _ip6([1, 2, 3, 4, 5, 6, 0, 0])),
      (_ip6([1, 2, 3, 4, 5, 6, 7, 8]), _ip6([1, 2, 3, 4, 5, 6, 7, 8])),
    ]);
    expect(decodeMihomoMrs(_compress(raw), behavior: 'ipcidr'), [
      '0.0.0.0/0',
      '::/0',
      '::/128',
      'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128',
      '::1:0:0:2:3:4/128',
      '1:2:3:4:5:6::/128',
      '1:2:3:4:5:6:7:8/128',
    ]);
  });

  test('rejects mismatched unknown and unsupported behavior', () {
    final domain = _compress(_domains(['a']));
    final ip = _compress(_ranges([(_ipv4(1, 2, 3, 4), _ipv4(1, 2, 3, 4))]));
    for (final behavior in ['ipcidr', 'classical', 'DOMAIN', '']) {
      expect(
        () => decodeMihomoMrs(domain, behavior: behavior),
        throwsFormatException,
      );
    }
    expect(
      () => decodeMihomoMrs(ip, behavior: 'domain'),
      throwsFormatException,
    );
    final unknown = _domains(['a'])..[4] = 2;
    expect(
      () => decodeMihomoMrs(_compress(unknown), behavior: 'domain'),
      throwsFormatException,
    );
  });

  test('rejects magic version byte values and trailing data', () {
    for (final offset in [0, 1, 2, 3, 21]) {
      final raw = _domains(['a']);
      raw[offset] ^= 255;
      expect(
        () => decodeMihomoMrs(_compress(raw), behavior: 'domain'),
        throwsFormatException,
      );
    }
    for (final bytes in [
      <int>[],
      [256],
      [-1],
      _domains(['a']),
      [
        ..._compress(_domains(['a'])),
        0,
      ],
      _compress([
        ..._domains(['a']),
        0,
      ]),
    ]) {
      expect(
        () => decodeMihomoMrs(bytes, behavior: 'domain'),
        throwsFormatException,
      );
    }
  });

  test('rejects every truncated domain and IP payload prefix', () {
    final fixtures = [
      ('domain', _domains(['a', '+.example', '*.wild.example'])),
      ('ipcidr', _ranges([(_ipv4(192, 0, 2, 0), _ipv4(192, 0, 2, 255))])),
    ];
    for (final (behavior, raw) in fixtures) {
      for (var length = 0; length < raw.length; length++) {
        expect(
          () => decodeMihomoMrs(
            _compress(raw.sublist(0, length)),
            behavior: behavior,
          ),
          throwsFormatException,
        );
      }
      final compressed = _compress(raw);
      for (var length = 0; length < compressed.length; length++) {
        expect(
          () => decodeMihomoMrs(
            compressed.sublist(0, length),
            behavior: behavior,
          ),
          throwsFormatException,
        );
      }
    }
  });

  test('rejects negative oversized and impossible lengths and counts', () {
    for (final offset in [5, 13, 22, 38, 54]) {
      for (final value in [-1, 0x100000000, 0x7fffffffffffffff]) {
        final raw = _domains(['a']);
        raw.replaceRange(offset, offset + 8, _u64(value));
        expect(
          () => decodeMihomoMrs(_compress(raw), behavior: 'domain'),
          throwsFormatException,
        );
      }
    }
    final count = _domains(['a']);
    count.replaceRange(5, 13, _u64(1000001));
    final leaves = _domains(['a']);
    leaves.replaceRange(22, 30, _u64(0));
    final emptyIp = _ranges([]);
    final impossibleIp = _ranges([(_ipv4(1, 2, 3, 4), _ipv4(1, 2, 3, 4))]);
    impossibleIp.replaceRange(22, 30, _u64(1000000));
    for (final (behavior, raw) in [
      ('domain', count),
      ('domain', leaves),
      ('ipcidr', emptyIp),
      ('ipcidr', impossibleIp),
    ]) {
      expect(
        () => decodeMihomoMrs(_compress(raw), behavior: behavior),
        throwsFormatException,
      );
    }
  });

  test('rejects disconnected malformed and nonterminal domain tries', () {
    // Single-key 'a': leaf word starts at 30, bitmap at 46, label at 62.
    for (final (offset, value) in [
      (37, 0), // Nonterminal dead end.
      (37, 3), // Root terminal.
      (37, 6), // Leaf padding.
      (53, 3), // Root has no child, disconnected edge.
      (53, 2), // Missing final node separator.
      (53, 14), // Edge padding.
      (62, 255), // Invalid UTF-8.
      (62, 43), // Bare internal suffix marker.
    ]) {
      final raw = _domains(['a'])..[offset] = value;
      expect(
        () => decodeMihomoMrs(_compress(raw), behavior: 'domain'),
        throwsFormatException,
      );
    }
    final unsorted = _domains(['a', 'b']);
    final last = unsorted.length - 1;
    unsorted[last] = unsorted[last - 1];
    expect(
      () => decodeMihomoMrs(_compress(unsorted), behavior: 'domain'),
      throwsFormatException,
    );
  });

  test('rejects malformed domain patterns and excessive trie depth', () {
    for (final pattern in ['a..b', 'a.', 'a/b', 'a*b', 'a+b', ' a', 'a ']) {
      expect(
        () =>
            decodeMihomoMrs(_compress(_domains([pattern])), behavior: 'domain'),
        throwsFormatException,
      );
    }
    expect(
      () => decodeMihomoMrs(
        _compress(_domains(['a' * 4097])),
        behavior: 'domain',
      ),
      throwsFormatException,
    );
  });

  test('rejects reversed and mixed-family range endpoints', () {
    for (final endpoints in [
      (_ipv4(192, 0, 2, 2), _ipv4(192, 0, 2, 1)),
      (
        _ip6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 2]),
        _ip6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 1]),
      ),
      (_ipv4(192, 0, 2, 1), _ip6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 1])),
      (_ip6([0, 0, 0, 0, 0, 0, 0, 1]), _ipv4(192, 0, 2, 1)),
    ]) {
      expect(
        () => decodeMihomoMrs(
          _compress(_ranges([endpoints])),
          behavior: 'ipcidr',
        ),
        throwsFormatException,
      );
    }
  });

  test('rejects declared output and window sizes above 64 MiB', () {
    for (final frame in [
      // Single-segment frame declaring 64 MiB + 1 content bytes.
      [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 1, 0, 0, 4, 1, 0, 0],
      // Unknown content size with a 128 MiB window.
      [0x28, 0xb5, 0x2f, 0xfd, 0, 0x88, 1, 0, 0],
    ]) {
      expect(
        () => decodeMihomoMrs(frame, behavior: 'domain'),
        throwsFormatException,
      );
    }
  });

  test('bounds actual decompression when a frame omits content size', () {
    // Unknown-size frame, 64 MiB window, 513 RLE blocks of 128 KiB.
    final frame = <int>[0x28, 0xb5, 0x2f, 0xfd, 0, 0x80];
    for (var block = 0; block < 513; block++) {
      frame.addAll([block == 512 ? 3 : 2, 0, 16, 0]);
    }
    expect(
      () => decodeMihomoMrs(frame, behavior: 'domain'),
      throwsA(isA<ArchiveLimitException>()),
    );
  });
}

List<int> _u64(int value) =>
    (ByteData(8)..setInt64(0, value)).buffer.asUint8List();

List<int> _header(int behavior, int count) => [
  77,
  82,
  83,
  1,
  behavior,
  ..._u64(count),
  ..._u64(0),
];

Uint8List _compress(List<int> raw) =>
    ZstdEncoder().encodeBytes(raw, checksum: true);

List<int> _domains(List<String> patterns, {int? count}) {
  final root = _FixtureNode();
  for (final pattern in patterns) {
    final keys = pattern.startsWith('+.')
        ? [pattern.substring(2), pattern]
        : [pattern.startsWith('.') ? '+$pattern' : pattern];
    for (final key in keys) {
      final reversed = String.fromCharCodes(key.runes.toList().reversed);
      var node = root;
      for (final byte in utf8.encode(reversed)) {
        node = node.children.putIfAbsent(byte, _FixtureNode.new);
      }
      node.terminal = true;
    }
  }
  final queue = [root];
  final leaves = <int>[];
  final bitmap = <int>[];
  final labels = <int>[];
  for (var node = 0; node < queue.length; node++) {
    leaves.add(queue[node].terminal ? 1 : 0);
    final children = queue[node].children.keys.toList()..sort();
    for (final label in children) {
      labels.add(label);
      bitmap.add(0);
      queue.add(queue[node].children[label]!);
    }
    bitmap.add(1);
  }
  List<int> words(List<int> bits) {
    final bytes = Uint8List(((bits.length + 63) ~/ 64) * 8);
    for (var i = 0; i < bits.length; i++) {
      bytes[(i ~/ 64) * 8 + 7 - (i % 64 ~/ 8)] |= bits[i] << (i % 8);
    }
    return [..._u64(bytes.length ~/ 8), ...bytes];
  }

  return [
    ..._header(0, count ?? patterns.length),
    1,
    ...words(leaves),
    ...words(bitmap),
    ..._u64(labels.length),
    ...labels,
  ];
}

class _FixtureNode {
  bool terminal = false;
  final children = <int, _FixtureNode>{};
}

List<int> _ranges(List<(List<int>, List<int>)> ranges, {int? count}) => [
  ..._header(1, count ?? ranges.length),
  1,
  ..._u64(ranges.length),
  for (final (first, last) in ranges) ...[...first, ...last],
];

List<int> _ipv4(int a, int b, int c, int d) => [
  ...List<int>.filled(10, 0),
  255,
  255,
  a,
  b,
  c,
  d,
];

List<int> _ip6(List<int> groups) => [
  for (final group in groups) ...[group >> 8, group & 255],
];
