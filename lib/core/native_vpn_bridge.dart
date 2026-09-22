import 'package:flutter/services.dart';

import '../models/vpn_models.dart';

abstract interface class VpnBridge {
  Stream<VpnSnapshot> get snapshots;

  Future<VpnSnapshot> getSnapshot();
  Future<List<VpnProfile>> listProfiles();
  Future<String> readProfile(String id);
  Future<VpnProfile> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
  });
  Future<void> deleteProfile(String id);
  Future<void> selectProfile(String id);
  Future<String?> validateProfile(String content);
  Future<bool> requestVpnPermission();
  Future<void> startVpn(String profileId);
  Future<void> stopVpn();
  Future<VpnSettings> loadSettings();
  Future<void> saveSettings(VpnSettings settings);
  Future<ImportedProfile?> pickProfileFile();
  Future<bool> exportProfileFile({
    required String name,
    required String content,
  });
  Future<NetworkInfo> getNetworkInfo();
  Future<bool> requestQuickSettingsTile();
  Future<String> invokeCore(String method, [String data = '']);
  Future<Map<Object?, Object?>> coreInfo();
}

class MethodChannelVpnBridge implements VpnBridge {
  static const _methods = MethodChannel('proxima/vpn');
  static const _events = EventChannel('proxima/vpn/events');

  @override
  Stream<VpnSnapshot> get snapshots => _events.receiveBroadcastStream().map(
    (event) => VpnSnapshot.fromMap((event as Map).cast<Object?, Object?>()),
  );

  @override
  Future<VpnSnapshot> getSnapshot() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>('getState');
    return VpnSnapshot.fromMap(value ?? const {});
  }

  @override
  Future<List<VpnProfile>> listProfiles() async {
    final rows = await _methods.invokeListMethod<Object?>('listProfiles');
    return (rows ?? const [])
        .map((row) => VpnProfile.fromMap((row as Map).cast<Object?, Object?>()))
        .toList(growable: false);
  }

  @override
  Future<String> readProfile(String id) async {
    return await _methods.invokeMethod<String>('readProfile', {'id': id}) ?? '';
  }

  @override
  Future<VpnProfile> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
  }) async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      'saveProfile',
      {'id': id, 'name': name, 'sourceUrl': sourceUrl, 'content': content},
    );
    return VpnProfile.fromMap(value!);
  }

  @override
  Future<void> deleteProfile(String id) =>
      _methods.invokeMethod<void>('deleteProfile', {'id': id});

  @override
  Future<void> selectProfile(String id) =>
      _methods.invokeMethod<void>('selectProfile', {'id': id});

  @override
  Future<String?> validateProfile(String content) =>
      _methods.invokeMethod<String?>('validateProfile', {'content': content});

  @override
  Future<bool> requestVpnPermission() async {
    return await _methods.invokeMethod<bool>('requestVpnPermission') ?? false;
  }

  @override
  Future<void> startVpn(String profileId) =>
      _methods.invokeMethod<void>('startVpn', {'profileId': profileId});

  @override
  Future<void> stopVpn() => _methods.invokeMethod<void>('stopVpn');

  @override
  Future<VpnSettings> loadSettings() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      'loadSettings',
    );
    return VpnSettings.fromMap(value ?? const {});
  }

  @override
  Future<void> saveSettings(VpnSettings settings) =>
      _methods.invokeMethod<void>('saveSettings', settings.toMap());

  @override
  Future<ImportedProfile?> pickProfileFile() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      'pickProfileFile',
    );
    return value == null ? null : ImportedProfile.fromMap(value);
  }

  @override
  Future<bool> exportProfileFile({
    required String name,
    required String content,
  }) async {
    return await _methods.invokeMethod<bool>('exportProfileFile', {
          'name': name,
          'content': content,
        }) ??
        false;
  }

  @override
  Future<NetworkInfo> getNetworkInfo() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      'getNetworkInfo',
    );
    return NetworkInfo.fromMap(value ?? const {});
  }

  @override
  Future<bool> requestQuickSettingsTile() async {
    return await _methods.invokeMethod<bool>('requestQuickSettingsTile') ??
        false;
  }

  @override
  Future<String> invokeCore(String method, [String data = '']) async {
    return await _methods.invokeMethod<String>('coreAction', {
          'method': method,
          'data': data,
        }) ??
        '';
  }

  @override
  Future<Map<Object?, Object?>> coreInfo() async {
    return await _methods.invokeMapMethod<Object?, Object?>('coreInfo') ??
        const {};
  }
}
