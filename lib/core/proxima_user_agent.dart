import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

String formatProximaUserAgent({
  required String appVersion,
  required String androidVersion,
}) => 'Proxima-Android/$appVersion (Android $androidVersion)';

Future<String> proximaUserAgent() async {
  var appVersion = '0.1.0';
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // Unit-test and unsupported-platform runners do not register the plugin.
  }
  var androidVersion = 'unknown';
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      androidVersion =
          (await DeviceInfoPlugin().androidInfo).version.release;
    } catch (_) {
      // Keep requests usable if device metadata is temporarily unavailable.
    }
  }
  return formatProximaUserAgent(
    appVersion: appVersion,
    androidVersion: androidVersion,
  );
}
