import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/proxima_user_agent.dart';

void main() {
  test('formats the Android User-Agent', () {
    expect(
      formatProximaUserAgent(
        appVersion: '1.2.3',
        androidVersion: '15',
      ),
      'Proxima-Android/1.2.3 (Android 15)',
    );
  });
}
