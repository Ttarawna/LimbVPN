import 'package:flutter/foundation.dart';

/// blocked: ядро потеряно, туннель закрыт для трафика (kill switch), идёт восстановление.
enum VpnStatus { off, connecting, on, disconnecting, blocked }

class AppExclusionEntry {
  const AppExclusionEntry({
    required this.packageName,
    required this.label,
    required this.inRussianCatalog,
    required this.excluded,
  });

  final String packageName;
  final String label;
  final bool inRussianCatalog;
  final bool excluded;

  factory AppExclusionEntry.fromJson(Map<String, dynamic> json) {
    final packageName = json['package'] as String?;
    final label = json['label'] as String?;
    final inRussianCatalog = json['catalog'] as bool?;
    final excluded = json['excluded'] as bool?;
    if (packageName == null ||
        label == null ||
        inRussianCatalog == null ||
        excluded == null) {
      throw const FormatException('Некорректная запись приложения');
    }
    return AppExclusionEntry(
      packageName: packageName,
      label: label,
      inRussianCatalog: inRussianCatalog,
      excluded: excluded,
    );
  }
}

class AppExclusionInventory {
  const AppExclusionInventory({
    required this.scanCompleted,
    required this.apps,
  });

  final bool scanCompleted;
  final List<AppExclusionEntry> apps;
}

/// Единственная точка контакта интерфейса с ядром.
/// Настоящая реализация (Android VpnService, Windows-служба и т.д.) появится позже
/// и заменит FakeVpnController, интерфейс при этом не изменится.
abstract class VpnController extends ChangeNotifier {
  VpnStatus get status;
  DateTime? get since;

  /// Есть ли у платформы системный kill switch, который можно открыть из приложения.
  bool get hasSystemKillSwitch => false;

  /// Есть ли журнал ядра для диагностики.
  bool get hasLog => false;

  /// Умеет ли платформа исключать приложения из VPN.
  bool get hasAppExclusion => false;

  /// Список приложений, работающих вне VPN (по одному на строку).
  Future<String> readExcludedApps() async => '';

  Future<String> readLog() async => '';

  Future<AppExclusionInventory> readAppExclusionInventory() async =>
      const AppExclusionInventory(scanCompleted: true, apps: []);

  Future<AppExclusionInventory> scanInstalledApps(
    void Function(int completed, int total) onProgress,
  ) async =>
      const AppExclusionInventory(scanCompleted: true, apps: []);

  Future<void> saveExcludedApps(Set<String> packageNames) async {}

  Future<List<String>> localDnsServers() async => const ['127.0.0.1'];

  Future<void> recordConnectionTimings(
    List<Map<String, Object>> timings,
  ) async {}

  /// Открывает системные настройки VPN (на Android: «Блокировать соединения без VPN»).
  Future<void> openSystemVpnSettings() async {}

  /// Включена ли системная блокировка «без VPN». null, если неизвестно.
  Future<bool?> lockdownEnabled() async => null;

  /// Удаляет сохранённые параметры подключения.
  Future<void> forgetSession() async {}

  /// [config] — готовый YAML для Mihomo.
  /// [killSwitch] — блокировать зарубежный трафик при обрыве.
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  });
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
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  }) async {
    debugPrint(
      'Fake connect, config: ${config.length} символов, killSwitch=$killSwitch',
    );
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
