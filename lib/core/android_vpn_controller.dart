import 'package:flutter/services.dart';

import 'vpn_controller.dart';

/// Настоящий контроллер для Android: общается с QuietVpnService через MethodChannel.
class AndroidVpnController extends VpnController {
  AndroidVpnController() {
    _channel.setMethodCallHandler(_onCall);
    _syncInitialState();
  }

  static const _channel = MethodChannel('quiet/vpn');

  VpnStatus _status = VpnStatus.off;
  DateTime? _since;

  @override
  VpnStatus get status => _status;

  @override
  DateTime? get since => _since;

  @override
  bool get hasSystemKillSwitch => true;

  @override
  bool get hasLog => true;

  @override
  Future<String> readLog() async =>
      await _channel.invokeMethod<String>('readLog') ?? '';

  Future<void> _syncInitialState() async {
    try {
      final s = await _channel.invokeMethod<String>('status');
      if (s == 'on') _set(VpnStatus.on);
    } catch (_) {}
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'status') {
      final s = call.arguments as String;
      if (s == 'on') {
        _set(VpnStatus.on);
      } else if (s == 'off' || s.startsWith('error:')) {
        _set(VpnStatus.off);
      }
    }
  }

  void _set(VpnStatus s) {
    if (s == VpnStatus.on && _status != VpnStatus.on) _since = DateTime.now();
    if (s == VpnStatus.off) _since = null;
    _status = s;
    notifyListeners();
  }

  @override
  Future<void> connect(String config, {required bool killSwitch}) async {
    _set(VpnStatus.connecting);
    try {
      final granted = await _channel.invokeMethod<bool>('prepare') ?? false;
      if (!granted) {
        throw 'Нужно разрешение на создание VPN-подключения';
      }
      await _channel.invokeMethod<void>('start', {'config': config});
    } on PlatformException catch (e) {
      _set(VpnStatus.off);
      throw e.message ?? 'Не удалось запустить ядро';
    } catch (_) {
      _set(VpnStatus.off);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _set(VpnStatus.disconnecting);
    await _channel.invokeMethod<void>('stop');
    // Состояние off придёт от службы.
  }

  @override
  Future<void> openSystemVpnSettings() async {
    await _channel.invokeMethod<void>('openVpnSettings');
  }
}
