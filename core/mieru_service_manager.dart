import 'dart:async';

import 'package:flutter/services.dart';

import 'package:quiet_vpn/core/vpn_controller.dart';

/// Coordinates Flutter VPN controls with the Android VPN service.
class MieruServiceManager extends VpnController {
  MieruServiceManager() {
    _channel.setMethodCallHandler(_onCall);
    unawaited(_syncInitialState());
  }

  static const _channel = MethodChannel('quiet/vpn');

  VpnStatus _status = VpnStatus.off;
  DateTime? _since;

  @override
  VpnStatus get status => _status;

  VpnStatus get currentState => _status;

  @override
  DateTime? get since => _since;

  @override
  bool get hasSystemKillSwitch => true;

  @override
  bool get hasLog => true;

  @override
  bool get hasAutostart => true;

  @override
  bool get hasAppExclusion => true;

  @override
  Future<int?> bootCount() async {
    try {
      final count = await _channel.invokeMethod<int>('bootCount');
      return count == null || count < 0 ? null : count;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> openAutostartSettings() async {
    try {
      await _channel.invokeMethod<void>('openAutostartSettings');
    } on PlatformException {
      return;
    }
  }

  @override
  Future<String> readExcludedApps() async =>
      await _channel.invokeMethod<String>('excludedApps') ?? '';

  @override
  Future<String> readLog() async =>
      await _channel.invokeMethod<String>('readLog') ?? '';

  Future<void> _syncInitialState() async {
    try {
      final state = await _channel.invokeMethod<String>('status');
      if (state == 'on') _set(VpnStatus.on);
      if (state == 'blocked') _set(VpnStatus.blocked);
    } on PlatformException {
      return;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'status' || call.arguments is! String) return;

    final state = call.arguments as String;
    if (state == 'on') {
      _set(VpnStatus.on);
    } else if (state == 'blocked') {
      _set(VpnStatus.blocked);
    } else if (state == 'off' || state.startsWith('error:')) {
      _set(VpnStatus.off);
    }
  }

  void _set(VpnStatus status) {
    if (status == VpnStatus.on && _status != VpnStatus.on) {
      _since = DateTime.now();
    }
    if (status == VpnStatus.off) _since = null;
    _status = status;
    notifyListeners();
  }

  @override
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  }) async {
    _set(VpnStatus.connecting);
    try {
      final granted = await _channel.invokeMethod<bool>('prepare') ?? false;
      if (!granted) {
        throw 'Нужно разрешение на создание VPN-подключения';
      }
      try {
        await _channel.invokeMethod<void>('askNotifications');
      } on PlatformException {
        // Notification permission is optional for establishing a VPN.
      }
      await _channel.invokeMethod<void>('startVpn', {
        'config': config,
        'excludeRu': excludeRuApps,
        'debug': debug,
        'killSwitch': killSwitch,
      }).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _set(VpnStatus.off);
      throw 'Служба VPN не ответила вовремя';
    } on PlatformException catch (error) {
      _set(VpnStatus.off);
      throw error.message ?? 'Не удалось запустить ядро';
    } catch (_) {
      _set(VpnStatus.off);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _set(VpnStatus.disconnecting);
    await _channel.invokeMethod<void>('stopVpn');
  }

  @override
  Future<bool?> lockdownEnabled() async {
    try {
      final state = await _channel.invokeMethod<String>('lockdown');
      if (state == '1') return true;
      if (state == '0') return false;
    } on PlatformException {
      return null;
    }
    return null;
  }

  @override
  Future<void> setAutostart(bool enabled) async {
    try {
      await _channel.invokeMethod<void>(
        'setAutostart',
        {'enabled': enabled},
      );
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> forgetSession() async {
    try {
      await _channel.invokeMethod<void>('forgetSession');
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> openSystemVpnSettings() async {
    await _channel.invokeMethod<void>('openVpnSettings');
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
