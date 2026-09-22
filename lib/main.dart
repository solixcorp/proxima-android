import 'package:flutter/material.dart';

import 'app/proxima_app.dart';
import 'core/native_vpn_bridge.dart';
import 'state/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(MethodChannelVpnBridge());
  runApp(ProximaApp(controller: controller));
  controller.initialize();
}
