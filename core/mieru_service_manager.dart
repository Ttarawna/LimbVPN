import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:quiet_vpn/core/vpn_controller.dart';

/// Coordinates Flutter VPN controls with the Android VPN service.
class MieruServiceManager extends VpnController with WidgetsBindingObserver {
  MieruServiceManager() {
    _channel.setMethodCallHandler(_onCall);
    WidgetsBinding.instance.addObserver(this);
    unawaited(refreshStatus());
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startStatusSync();
    }
  }

  static const _channel = MethodChannel('quiet/vpn');

  VpnStatus _status = VpnStatus.off;
  DateTime? _since;
  int _statusRevision = 0;
  int _serviceRevision = -1;
  Timer? _statusSyncTimer;

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

  @override
  Future<List<String>> localDnsServers() async {
    final servers = await _channel.invokeListMethod<String>('localDnsServers');
    if (servers == null || servers.isEmpty) {
      throw StateError('В активной сети не найден локальный DNS-резолвер');
    }
    return servers;
  }

  Future<void> refreshStatus() async {
    final revision = ++_statusRevision;
    try {
      final details = await _channel.invokeMapMethod<String, dynamic>(
        'statusDetails',
      );
      if (details == null || revision != _statusRevision) return;
      final state = details['state'];
      final serviceRevision = details['revision'];
      final sinceMillis = details['since'];
      if (state is! String || serviceRevision is! int) return;
      final since = sinceMillis is int
          ? DateTime.fromMillisecondsSinceEpoch(sinceMillis)
          : null;
      _applyServiceState(state, serviceRevision, since: since);
    } on PlatformException {
      return;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshStatus());
      _startStatusSync();
    } else {
      _statusSyncTimer?.cancel();
      _statusSyncTimer = null;
    }
  }

  void _startStatusSync() {
    if (_statusSyncTimer?.isActive == true) return;
    _statusSyncTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(refreshStatus()),
    );
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'status' || call.arguments is! Map) return;

    final details = call.arguments as Map;
    final state = details['state'];
    final serviceRevision = details['revision'];
    final sinceMillis = details['since'];
    if (state is! String || serviceRevision is! int) return;
    _statusRevision++;
    final since = sinceMillis is int
        ? DateTime.fromMillisecondsSinceEpoch(sinceMillis)
        : null;
    _applyServiceState(state, serviceRevision, since: since);
  }

  void _applyServiceState(String state, int revision, {DateTime? since}) {
    if (revision <= _serviceRevision) return;
    _serviceRevision = revision;
    _applyState(state, since: since);
  }

  void _applyState(String? state, {DateTime? since}) {
    switch (state) {
      case 'connecting':
        _set(VpnStatus.connecting);
      case 'disconnecting':
        _set(VpnStatus.disconnecting);
      case 'on':
        _set(VpnStatus.on, since: since);
      case 'blocked':
        _set(VpnStatus.blocked);
      case 'off':
        _set(VpnStatus.off);
      default:
        if (state?.startsWith('error:') == true) _set(VpnStatus.off);
    }
  }

  void _set(VpnStatus status, {DateTime? since}) {
    if (status == VpnStatus.on && _status != VpnStatus.on) {
      _since = since ?? DateTime.now();
    } else if (status == VpnStatus.on && since != null) {
      _since = since;
    }
    if (status == VpnStatus.off || status == VpnStatus.connecting)
      _since = null;
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
      await _channel
          .invokeMethod<void>('startVpn', {
            'config': config,
            'excludeRu': excludeRuApps,
            'debug': debug,
            'killSwitch': killSwitch,
          })
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      try {
        await _channel.invokeMethod<void>('stopVpn');
      } on PlatformException {
        // The service may already have stopped while the start request timed out.
      }
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
      await _channel.invokeMethod<void>('setAutostart', {'enabled': enabled});
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
    _statusSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
