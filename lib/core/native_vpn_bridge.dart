import 'dart:convert';

import 'package:crypto/crypto.dart';
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
    SubscriptionInfo? subscriptionInfo,
    ProfileAdmissionSummary? admissionSummary,
  });
  Future<void> deleteProfile(String id);
  Future<void> selectProfile(String id);
  Future<Map<String, String>> loadProxySelections(String profileId);
  Future<void> saveProxySelection({
    required String profileId,
    required String group,
    required String proxy,
  });
  Future<String?> validateProfile(String content);
  Future<bool> requestVpnPermission();
  Future<void> startVpn(String profileId);
  Future<void> prepareMihomoConfiguration(
    String profileId,
    String yaml, {
    required String source,
    required VpnSettings settings,
  });
  Future<void> discardPreparedMihomoConfiguration(String profileId);
  Future<void> clearProxySelection(String profileId, String group);
  Future<void> stopVpn();

  /// Tunnel settings apply to the isolated Mihomo worker on the next connection.
  Future<VpnSettings> loadSettings();
  Future<void> saveSettings(VpnSettings settings);
  Future<ImportedProfile?> pickProfileFile();
  Future<bool> exportProfileFile({
    required String name,
    required String content,
  });
  Future<NetworkInfo> getNetworkInfo();
  Future<String> requestQuickSettingsTile();
  Future<bool> requestPinAppWidget();
  Future<String> invokeCore(String method, [String data = '']);
  Future<Map<Object?, Object?>> coreInfo();
}

/// Optional capability: bridges without Android external actions need not
/// implement it. Events are notifications; the method consumes the request.
abstract interface class ExternalConnectBridge {
  Stream<void> get externalConnectRequests;
  Future<bool> consumeExternalConnect();
}

class MethodChannelVpnBridge implements VpnBridge, ExternalConnectBridge {
  static const _methods = MethodChannel('proxima/vpn');
  static const _events = EventChannel('proxima/vpn/events');
  static const _externalActions = EventChannel('proxima/vpn/external_actions');

  @override
  Stream<void> get externalConnectRequests => _externalActions
      .receiveBroadcastStream()
      .where((event) => event == 'connect')
      .map((_) {});

  @override
  Future<bool> consumeExternalConnect() async =>
      await _methods.invokeMethod<bool>('consumeExternalConnect') ?? false;

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
    SubscriptionInfo? subscriptionInfo,
    ProfileAdmissionSummary? admissionSummary,
  }) async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      'saveProfile',
      {
        'id': id,
        'name': name,
        'sourceUrl': sourceUrl,
        'content': content,
        'subscriptionInfo': subscriptionInfo?.toMap(),
        'admissionSummary': admissionSummary?.toMap(),
      },
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
  Future<Map<String, String>> loadProxySelections(String profileId) async {
    final values = await _methods.invokeMapMethod<Object?, Object?>(
      'loadProxySelections',
      {'profileId': profileId},
    );
    return (values ?? const {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  @override
  Future<void> saveProxySelection({
    required String profileId,
    required String group,
    required String proxy,
  }) => _methods.invokeMethod<void>('saveProxySelection', {
    'profileId': profileId,
    'group': group,
    'proxy': proxy,
  });

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
  Future<void> clearProxySelection(String profileId, String group) =>
      _methods.invokeMethod<void>('clearProxySelection', {
        'profileId': profileId,
        'group': group,
      });

  @override
  Future<void> discardPreparedMihomoConfiguration(String profileId) =>
      _methods.invokeMethod<void>('discardPreparedMihomoConfiguration', {
        'profileId': profileId,
      });

  @override
  Future<void> prepareMihomoConfiguration(
    String profileId,
    String yaml, {
    required String source,
    required VpnSettings settings,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(yaml));
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Mihomo 실행 설정은 1바이트 이상 8MB 이하여야 합니다.');
    }
    final token = await _methods.invokeMethod<String>(
      'beginMihomoConfiguration',
      {
        'profileId': profileId,
        'size': bytes.length,
        'sourceSha256': sha256.convert(utf8.encode(source)).toString(),
        'settingsKey':
            '${settings.mtu}:${settings.ipv6}:${settings.mode.wireName}:mips',
      },
    );
    if (token == null) throw StateError('Mihomo 설정 사이드카를 생성하지 못했습니다.');
    try {
      // Platform channels are not Binder, but bounded chunks also avoid a large
      // main-thread message/allocation. Worker Binder only ever receives an FD.
      for (var offset = 0; offset < bytes.length; offset += 64 * 1024) {
        final end = (offset + 64 * 1024).clamp(0, bytes.length);
        await _methods.invokeMethod<void>('appendMihomoConfiguration', {
          'token': token,
          'offset': offset,
          'bytes': Uint8List.sublistView(bytes, offset, end),
        });
      }
      await _methods.invokeMethod<void>('finishMihomoConfiguration', {
        'token': token,
      });
    } catch (_) {
      await _methods.invokeMethod<void>('discardMihomoConfiguration', {
        'token': token,
      });
      rethrow;
    }
  }

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
  Future<String> requestQuickSettingsTile() async {
    return await _methods.invokeMethod<String>('requestQuickSettingsTile') ??
        'unavailable';
  }

  @override
  Future<bool> requestPinAppWidget() async {
    return await _methods.invokeMethod<bool>('requestPinAppWidget') ?? false;
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
