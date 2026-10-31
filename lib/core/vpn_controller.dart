import 'package:flutter/foundation.dart';

enum VpnStatus { off, connecting, on, disconnecting }

/// Единственная точка контакта интерфейса с ядром.
/// Настоящая реализация (Android VpnService, Windows-служба и т.д.) появится позже
/// и заменит FakeVpnController, интерфейс при этом не изменится.
abstract class VpnController extends ChangeNotifier {
  VpnStatus get status;
  DateTime? get since;

  /// Есть ли у платформы системный kill switch, который можно открыть из приложения.
  bool get hasSystemKillSwitch => false;

  /// Открывает системные настройки VPN (на Android: «Блокировать соединения без VPN»).
  Future<void> openSystemVpnSettings() async {}

  /// [config] — готовый YAML для Mihomo.
  /// [killSwitch] — блокировать зарубежный трафик при обрыве.
  Future<void> connect(String config, {required bool killSwitch});
  Future<void> disconnect();
}

/// Имитация для разработки интерфейса: сети никакой нет.
class FakeVpnController extends VpnController {
  VpnStatus _status = VpnStatus.off;
  DateTime? _since;

  @override
  VpnStatus get status => _status;

  @override
  DateTime? get since => _since;

  @override
  Future<void> connect(String config, {required bool killSwitch}) async {
    debugPrint('Fake connect, config: ${config.length} символов, killSwitch=$killSwitch');
    _status = VpnStatus.connecting;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _status = VpnStatus.on;
    _since = DateTime.now();
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _status = VpnStatus.disconnecting;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _status = VpnStatus.off;
    _since = null;
    notifyListeners();
  }
}
