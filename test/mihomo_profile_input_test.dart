import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/mihomo_profile_input.dart';
import 'package:proxima/core/vless_reality_profile.dart';

void main() {
  const link =
      'vless://123e4567-e89b-42d3-a456-426614174000@example.com:443'
      '?security=none&type=tcp#Example';

  test('preserves native provider-only YAML exactly', () {
    const source = '# comment\r\nproxy-providers:\r\n  remote:\r\n'
        '    type: http\r\n    url: https://example.com/sub\r\n\r\n';
    final input = MihomoProfileInput.classify(source);
    expect(input.kind, MihomoProfileInputKind.nativeYaml);
    expect(input.content, source);
  });

  test('recognizes non-VLESS proxies without interpreting them', () {
    const source = 'proxies:\n  - {name: node, type: ss, server: host}\n';
    expect(MihomoProfileInput.classify(source).kind,
        MihomoProfileInputKind.nativeYaml);
  });

  test('recognizes link lists without parsing or modifying them', () {
    const source = '  $link\r\nVLESS://other@example.com:443\n';
    final input = MihomoProfileInput.classify(source);
    expect(input.kind, MihomoProfileInputKind.vlessLinks);
    expect(input.content, source);
  });

  test('marks generated legacy input as a candidate', () {
    final source = VlessRealityProfile.storedConfigFromInput(
      link,
      profileName: 'Example',
    );
    final input = MihomoProfileInput.classify(source);
    expect(input.kind, MihomoProfileInputKind.legacyProximaCandidate);
    expect(input.content, source);
  });

  test('leaves uncertain and malformed inputs ambiguous', () {
    for (final source in [
      '',
      'https://example.com/sub',
      'https://example.com/sub: value',
      'unknown-field: value',
      'proxies: [broken',
      '$link\nMATCH,DIRECT',
      '# proxima-vless-reality-link: abc\nproxies: [broken',
    ]) {
      final input = MihomoProfileInput.classify(source);
      expect(input.kind, MihomoProfileInputKind.ambiguous, reason: source);
      expect(input.content, source);
    }
  });
}
