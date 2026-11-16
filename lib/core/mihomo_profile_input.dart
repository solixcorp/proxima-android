import 'package:yaml/yaml.dart';

/// Input hints only. None of these results validates a Mihomo configuration
/// or guarantees that a legacy profile can be migrated.
enum MihomoProfileInputKind {
  nativeYaml,
  vlessLinks,
  legacyProximaCandidate,
  ambiguous,
}

class MihomoProfileInput {
  const MihomoProfileInput._(this.kind, this.content);

  final MihomoProfileInputKind kind;

  /// The original input, unchanged, including whitespace and comments.
  final String content;

  static MihomoProfileInput classify(String content) {
    MihomoProfileInput result(MihomoProfileInputKind kind) =>
        MihomoProfileInput._(kind, content);

    final lines = content.split(RegExp(r'\r\n|\n|\r'));
    final nonEmpty = lines.map((line) => line.trim()).where((line) => line.isNotEmpty);
    if (nonEmpty.isNotEmpty &&
        nonEmpty.every(
          (line) => RegExp(r'^vless://\S+$', caseSensitive: false).hasMatch(line),
        )) {
      return result(MihomoProfileInputKind.vlessLinks);
    }

    Object? document;
    try {
      document = loadYaml(content);
    } on YamlException {
      return result(MihomoProfileInputKind.ambiguous);
    }
    if (document is! YamlMap) {
      return result(MihomoProfileInputKind.ambiguous);
    }

    // The comment can also occur in a manually edited profile; do not treat
    // its presence as evidence that conversion will succeed.
    if (lines.any(
      (line) => line.trimLeft().startsWith('# proxima-vless-reality-link:'),
    )) {
      return result(MihomoProfileInputKind.legacyProximaCandidate);
    }

    // A mapping alone could be arbitrary YAML. Recognized top-level keys are
    // hints, not schema checks; unknown-only mappings remain ambiguous.
    const keys = {
      'proxies', 'proxy-providers', 'proxy-groups', 'rule-providers',
      'rules', 'mixed-port', 'port', 'socks-port', 'redir-port', 'tproxy-port',
      'allow-lan', 'mode', 'log-level', 'ipv6', 'dns', 'tun',
      'external-controller', 'profile', 'hosts', 'geodata-mode',
      'find-process-mode', 'unified-delay', 'tcp-concurrent', 'sniffer',
      'listeners', 'sub-rules',
    };
    if (document.keys.any(keys.contains)) {
      return result(MihomoProfileInputKind.nativeYaml);
    }
    return result(MihomoProfileInputKind.ambiguous);
  }
}
