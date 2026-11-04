import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_builder.dart';
import 'mieru_link.dart';
import 'secret_store.dart';
import 'updater.dart';
import 'vpn_controller.dart';

enum Flag { killSwitch, adBlock, blockIpv6, excludeRuApps, debug }

class AppState extends ChangeNotifier {
  AppState(this._prefs, this.vpn, this._secrets, this._updates) {
    vpn.addListener(notifyListeners);
    killSwitch = _prefs.getBool('killSwitch') ?? true;
    adBlock = _prefs.getBool('adBlock') ?? false;
    blockIpv6 = _prefs.getBool('blockIpv6') ?? true;
    excludeRuApps = _prefs.getBool('excludeRuApps') ?? true;
    debugMode = _prefs.getBool('debug') ?? false;
  }

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final UpdateService _updates;
  final VpnController vpn;

  MieruProfile? profile;
  bool killSwitch = true;
  bool adBlock = false;
  bool blockIpv6 = true;
  bool excludeRuApps = true;
  bool debugMode = false;
  bool vpnOperationInProgress = false;
  List<Map<String, Object>> lastConnectionTimings = const [];

  /// Доступное обновление (null, если нет) и ход загрузки в процентах.
  UpdateInfo? update;
  int? updateProgress;
  bool updateChecking = false;
  String? updateCheckMessage;

  /// Сообщение для показа пользователю (например, ошибка установки обновления).
  String? notice;

  /// Загружает профиль из защищённого хранилища. Вызывается один раз при запуске.
  Future<void> load() async {
    await _prefs.remove('autostart');
    await _prefs.remove('lastBootCount');
    String? link;
    try {
      link = await _secrets.read('profile');
    } catch (_) {}

    // Перенос из старой версии, где профиль лежал в открытом виде.
    final legacy = _prefs.getString('profile');
    if (legacy != null) {
      if (link == null) {
        link = legacy;
        try {
          await _secrets.write('profile', legacy);
        } catch (_) {}
      }
      await _prefs.remove('profile');
    }

    if (link != null) {
      try {
        profile = MieruProfile.parse(link);
      } on LinkFormatException {
        try {
          await _secrets.delete('profile');
        } catch (_) {}
      }
    }
    notifyListeners();
    _updates.setErrorHandler((m) {
      updateProgress = null;
      notice = 'Не удалось установить обновление: $m';
      notifyListeners();
    });
    unawaited(checkForUpdate());
  }

  /// Проверяет обновления не чаще раза в 12 часов, если [force] не задан.
  Future<void> checkForUpdate({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _prefs.getInt('lastUpdateCheck') ?? 0;
    if (!force && now - last < 12 * 3600 * 1000) return;
    if (updateChecking || updateProgress != null) return;
    updateChecking = true;
    updateCheckMessage = null;
    notifyListeners();
    try {
      final found = await _updates.check();
      update = found;
      updateCheckMessage = found == null
          ? 'Установлена последняя версия'
          : 'Доступна версия ${found.version}';
      await _prefs.setInt('lastUpdateCheck', now);
    } catch (e) {
      updateCheckMessage = e is UnsupportedError
          ? e.message
          : 'Не удалось проверить обновления: $e';
    } finally {
      updateChecking = false;
      notifyListeners();
    }
  }

  /// Скачивает и устанавливает обновление. Возвращает текст ошибки или null.
  Future<String?> installUpdate() async {
    final info = update;
    if (info == null || updateProgress != null) return null;
    updateProgress = 0;
    notifyListeners();
    try {
      return await _updates.install(info, (p) {
        updateProgress = p;
        notifyListeners();
      });
    } catch (e) {
      return 'Не удалось установить обновление: $e';
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  /// Бросает [LinkFormatException], если ссылка не подходит.
  void importLink(String raw) {
    final parsed = MieruProfile.parse(raw);
    profile = parsed;
    _secrets.write('profile', parsed.link).catchError((Object _) {});
    notifyListeners();
  }

  Future<void> deleteProfile() async {
    final st = vpn.status;
    if (st == VpnStatus.on || st == VpnStatus.blocked) await vpn.disconnect();
    profile = null;
    try {
      await _secrets.delete('profile');
    } catch (_) {}
    await vpn.forgetSession();
    notifyListeners();
  }

  void setFlag(Flag flag, bool value) {
    switch (flag) {
      case Flag.killSwitch:
        killSwitch = value;
      case Flag.adBlock:
        adBlock = value;
      case Flag.blockIpv6:
        blockIpv6 = value;
      case Flag.excludeRuApps:
        excludeRuApps = value;
      case Flag.debug:
        debugMode = value;
    }
    _prefs.setBool(flag.name, value);
    notifyListeners();
  }

  /// Возвращает текст ошибки для показа пользователю или null, если всё прошло.
  Future<String?> toggle() async {
    if (vpnOperationInProgress) return null;
    final p = profile;
    if (p == null) return 'Сначала добавьте профиль';
    final st = vpn.status;
    if (st == VpnStatus.connecting || st == VpnStatus.disconnecting)
      return null;
    vpnOperationInProgress = true;
    notifyListeners();
    List<Map<String, Object>>? timings;
    String? stage;
    Stopwatch? stageClock;
    void finishStage() {
      timings!.add({
        'stage': stage!,
        'elapsed_ms': stageClock!.elapsedMilliseconds,
      });
      stageClock
        ..reset()
        ..start();
    }

    try {
      if (st == VpnStatus.on || st == VpnStatus.blocked) {
        await vpn.disconnect();
      } else {
        timings = [];
        stage = 'server_dns';
        stageClock = Stopwatch()..start();
        // Адрес сервера определяем ДО туннеля, чтобы исключить его из туннеля.
        final ips = await _resolve(p.server);
        finishStage();
        stage = 'local_dns';
        final localDns = await vpn.localDnsServers();
        finishStage();
        stage = 'config_build';
        final config = buildMihomoConfig(
          p,
          serverIps: ips,
          localDnsServers: localDns,
          adBlock: adBlock,
          blockIpv6: blockIpv6,
          debug: debugMode,
        );
        finishStage();
        stage = 'vpn_service_start';
        await vpn.connect(
          config,
          killSwitch: killSwitch,
          excludeRuApps: excludeRuApps,
          debug: debugMode,
        );
      }
      return null;
    } on SocketException {
      return 'Не удалось определить адрес сервера. Проверьте интернет.';
    } catch (e) {
      return 'Не удалось подключиться: $e';
    } finally {
      if (timings != null) {
        timings.add({
          'stage': stage!,
          'elapsed_ms': stageClock!.elapsedMilliseconds,
        });
        lastConnectionTimings = List.unmodifiable(
          timings.map((timing) => Map<String, Object>.unmodifiable(timing)),
        );
        unawaited(vpn.recordConnectionTimings(timings));
      }
      vpnOperationInProgress = false;
      notifyListeners();
    }
  }

  Future<List<String>> _resolve(String host) async {
    if (InternetAddress.tryParse(host) != null) return [host];
    final found = await InternetAddress.lookup(host);
    return found.map((a) => a.address).toSet().toList();
  }

  @override
  void dispose() {
    vpn.removeListener(notifyListeners);
    super.dispose();
  }
}
