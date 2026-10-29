import 'package:flutter/material.dart';

import 'app/proxima_app.dart';
import 'core/native_vpn_bridge.dart';
import 'core/proxima_account.dart';
import 'state/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(MethodChannelVpnBridge());
  final account = ProximaAccount();
  runApp(ProximaApp(controller: controller, account: account));
  controller.initialize();
  account.initialize();
}
