import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _maxMrsBytes = 64 * 1024 * 1024;
const _maxMrsEntries = 1000000;
const _maxMrsLabels = 4 * 1024 * 1024;
const _maxMrsDomainBytes = 4096;

/// Decodes a Zstandard-compressed Mihomo MRS v1 rule provider.
///
/// Domain entries preserve provider syntax: `example.com` is exact,
/// `.example.com` matches subdomains only, and `*` matches one label. A `+.`
/// rule is represented by its separate exact and suffix-only entries.
/// IP entries are CIDRs, with IPv4-mapped IPv6 endpoints unmapped to IPv4.
///
/// Malformed, unsupported, or oversized input throws [FormatException].
/// The header count is bounded but not compared to the output count: upstream
/// counts insertions before deduplication, wildcard expansion, and IP merging.
List<String> decodeMihomoMrs(List<int> bytes, {required String behavior}) {
  final expectedBehavior = switch (behavior) {
    'domain' => 0,
    'ipcidr' => 1,
    _ => throw FormatException('Unsupported MRS behavior: $behavior'),
  };
  if (bytes.length > _maxMrsBytes ||
      bytes.any((byte) => byte < 0 || byte > 255)) {
    throw const FormatException('Invalid or oversized MRS bytes');
  }
  final decoded = ZstdDecoder(maxWindowSize: _maxMrsBytes).decodeBytes(
    bytes,
    verify: true,
    throwOnError: true,
    maxOutputSize: _maxMrsBytes,
  );
  final reader = _MrsReader(decoded);
  if (reader.byte() != 77 ||
      reader.byte() != 82 ||
      reader.byte() != 83 ||
      reader.byte() != 1) {
    throw const FormatException('Invalid MRS v1 magic');
  }
  if (reader.byte() != expectedBehavior) {
    throw const FormatException('MRS behavior does not match provider');
  }
  reader.length(_maxMrsEntries);
  final extraLength = reader.length(_maxMrsBytes);
  reader.take(extraLength);
  if (reader.byte() != 1) {
    throw const FormatException('Unsupported MRS set version');
  }
  final result = expectedBehavior == 0
      ? _readDomains(reader)
      : _readIpRanges(reader);
  if (reader.remaining != 0) {
    throw const FormatException('Trailing MRS data');
  }
  return result;
}

List<String> _readDomains(_MrsReader reader) {
  final leaves = reader.take(reader.length((_maxMrsLabels + 64) ~/ 64) * 8);
  final bitmap = reader.take(reader.length((2 * _maxMrsLabels + 64) ~/ 64) * 8);
  final labels = reader.take(reader.length(_maxMrsLabels));
  final nodeCount = labels.length + 1;
  final bitCount = labels.length + nodeCount;
  if (labels.isEmpty ||
      leaves.length != ((nodeCount + 63) ~/ 64) * 8 ||
      bitmap.length != ((bitCount + 63) ~/ 64) * 8) {
    throw const FormatException('Invalid MRS domain bitmap lengths');
  }
  bool bit(Uint8List words, int index) =>
      (words[(index ~/ 64) * 8 + 7 - (index % 64 ~/ 8)] & (1 << (index % 8))) !=
      0;

  // LOUDS lists each node's outgoing edges as zero bits, then a one bit.
  // Edges (and their labels) are in breadth-first order; edge i leads to i+1.
  final starts = Uint32List(nodeCount + 1);
  var edge = 0;
  var position = 0;
  for (var node = 0; node < nodeCount; node++) {
    starts[node] = edge;
    var previousLabel = -1;
    while (position < bitCount && !bit(bitmap, position)) {
      if (edge >= labels.length ||
          edge + 1 <= node ||
          labels[edge] <= previousLabel) {
        throw const FormatException('Invalid MRS domain edges');
      }
      previousLabel = labels[edge++];
      position++;
    }
    if (position >= bitCount || (node > edge)) {
      throw const FormatException('Truncated or disconnected MRS domain trie');
    }
    position++;
    if (starts[node] == edge && !bit(leaves, node)) {
      throw const FormatException('Nonterminal MRS domain dead end');
    }
  }
  starts[nodeCount] = edge;
  if (edge != labels.length || position != bitCount || bit(leaves, 0)) {
    throw const FormatException('Invalid MRS domain trie');
  }
  for (var i = nodeCount; i < leaves.length * 8; i++) {
    if (bit(leaves, i)) {
      throw const FormatException('Invalid MRS leaf padding');
    }
  }
  for (var i = bitCount; i < bitmap.length * 8; i++) {
    if (bit(bitmap, i)) {
      throw const FormatException('Invalid MRS edge padding');
    }
  }

  final result = <String>[];
  final path = <int>[];
  final nodes = <int>[0];
  final cursors = <int>[starts[0]];
  var outputBytes = 0;
  // Iterative depth-first traversal avoids recursion on untrusted trie depth.
  while (nodes.isNotEmpty) {
    final node = nodes.last;
    final next = cursors.last;
    if (next == starts[node + 1]) {
      nodes.removeLast();
      cursors.removeLast();
      if (path.isNotEmpty) path.removeLast();
      continue;
    }
    cursors[cursors.length - 1]++;
    path.add(labels[next]);
    if (path.length > _maxMrsDomainBytes) {
      throw const FormatException('MRS domain exceeds length limit');
    }
    final child = next + 1;
    if (bit(leaves, child)) {
      // Mihomo reverses Unicode code points, not UTF-8 bytes. Its terminal
      // '+' is an internal suffix-only marker, not the provider '+.' shorthand.
      var reversed = utf8.decode(path);
      if (reversed.endsWith('+')) {
        reversed = reversed.substring(0, reversed.length - 1);
      }
      final domain = String.fromCharCodes(reversed.runes.toList().reversed);
      _validateDomain(domain);
      outputBytes += path.length;
      if (result.length >= _maxMrsEntries || outputBytes > _maxMrsBytes) {
        throw const FormatException('MRS domain output exceeds limit');
      }
      result.add(domain);
    }
    nodes.add(child);
    cursors.add(starts[child]);
  }
  return result;
}

void _validateDomain(String domain) {
  final parts = domain.split('.');
  if (domain.isEmpty ||
      domain.trim() != domain ||
      domain.contains('/') ||
      domain.contains('+') ||
      parts.skip(1).any((part) => part.isEmpty) ||
      parts.any((part) => part.contains('*') && part != '*')) {
    throw const FormatException('Invalid MRS domain pattern');
  }
}

List<String> _readIpRanges(_MrsReader reader) {
  final count = reader.length(_maxMrsEntries);
  if (count == 0 || count > reader.remaining ~/ 32) {
    throw const FormatException('Invalid MRS IP range count');
  }
  final result = <String>[];
  final mappedPrefix = BigInt.from(65535);
  for (var i = 0; i < count; i++) {
    BigInt address() {
      var value = BigInt.zero;
      for (final byte in reader.take(16)) {
        value = (value << 8) | BigInt.from(byte);
      }
      return value;
    }

    var first = address();
    var last = address();
    final firstMapped = first >> 32 == mappedPrefix;
    final lastMapped = last >> 32 == mappedPrefix;
    if (firstMapped != lastMapped || first > last) {
      throw const FormatException('Invalid MRS IP range endpoints');
    }
    final width = firstMapped ? 32 : 128;
    if (firstMapped) {
      final mask = (BigInt.one << 32) - BigInt.one;
      first &= mask;
      last &= mask;
    }
    while (first <= last) {
      final alignment = first == BigInt.zero
          ? width
          : (first & -first).bitLength - 1;
      final available = (last - first + BigInt.one).bitLength - 1;
      final hostBits = alignment < available ? alignment : available;
      if (result.length >= _maxMrsEntries) {
        throw const FormatException('MRS CIDR output exceeds limit');
      }
      result.add('${_formatIp(first, width)}/${width - hostBits}');
      first += BigInt.one << hostBits;
    }
  }
  return result;
}

String _formatIp(BigInt address, int width) {
  if (width == 32) {
    return [
      for (var shift = 24; shift >= 0; shift -= 8)
        ((address >> shift) & BigInt.from(255)).toInt(),
    ].join('.');
  }
  final groups = [
    for (var shift = 112; shift >= 0; shift -= 16)
      ((address >> shift) & BigInt.from(65535)).toInt(),
  ];
  var bestStart = -1;
  var bestLength = 1;
  for (var i = 0; i < groups.length;) {
    if (groups[i] != 0) {
      i++;
      continue;
    }
    final start = i;
    while (i < groups.length && groups[i] == 0) {
      i++;
    }
    if (i - start > bestLength) {
      bestStart = start;
      bestLength = i - start;
    }
  }
  final text = groups.map((group) => group.toRadixString(16)).toList();
  if (bestStart < 0) return text.join(':');
  return '${text.take(bestStart).join(':')}::'
      '${text.skip(bestStart + bestLength).join(':')}';
}

class _MrsReader {
  _MrsReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int get remaining => bytes.length - offset;

  int byte() => take(1)[0];

  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated MRS data');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return value;
  }

  // All lengths/counts are signed big-endian int64 on the wire. Our bounds
  // fit in 32 bits, so reject the high word before any allocation or narrowing.
  int length(int maximum) {
    final words = ByteData.sublistView(take(8));
    final value = words.getUint32(4);
    if (words.getUint32(0) != 0 || value > maximum) {
      throw const FormatException('Invalid or oversized MRS length/count');
    }
    return value;
  }
}
