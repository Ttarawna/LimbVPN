import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_builder.dart';
import 'mieru_link.dart';
import 'secret_store.dart';
import 'updater.dart';
import 'vpn_controller.dart';

enum Flag { killSwitch, adBlock, blockIpv6, autostart, excludeRuApps, debug }

class AppState extends ChangeNotifier {
  AppState(this._prefs, this.vpn, this._secrets, this._updates) {
    vpn.addListener(notifyListeners);
    killSwitch = _prefs.getBool('killSwitch') ?? true;
    adBlock = _prefs.getBool('adBlock') ?? false;
    blockIpv6 = _prefs.getBool('blockIpv6') ?? true;
    autostart = _prefs.getBool('autostart') ?? false;
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
  bool autostart = false;
  bool excludeRuApps = true;
  bool debugMode = false;
  bool vpnOperationInProgress = false;

  /// Доступное обновление (null, если нет) и ход загрузки в процентах.
  UpdateInfo? update;
  int? updateProgress;
  bool updateChecking = false;
  String? updateCheckMessage;

  /// Сообщение для показа пользователю (например, ошибка установки обновления).
  String? notice;

  /// Загружает профиль из защищённого хранилища. Вызывается один раз при запуске.
  Future<void> load() async {
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
    unawaited(vpn.setAutostart(autostart));
    notifyListeners();
    unawaited(_autostartFallback());
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

  /// Запасной путь автозапуска. Некоторые оболочки (например, у Xiaomi) не дают
  /// приложению запуститься при загрузке телефона. Тогда подключаемся при первом
  /// открытии приложения после перезагрузки.
  Future<void> _autostartFallback() async {
    if (!autostart || profile == null) return;
    final count = await vpn.bootCount();
    if (count == null) return;
    final last = _prefs.getInt('lastBootCount');
    await _prefs.setInt('lastBootCount', count);
    if (last == null || last == count) return; // перезагрузки не было
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (vpn.status == VpnStatus.off) await toggle();
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
      case Flag.autostart:
        autostart = value;
        unawaited(vpn.setAutostart(value));
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
    try {
      if (st == VpnStatus.on || st == VpnStatus.blocked) {
        await vpn.disconnect();
      } else {
        // Адрес сервера определяем ДО туннеля, чтобы исключить его из туннеля.
        final ips = await _resolve(p.server);
        final localDns = await vpn.localDnsServers();
        final config = buildMihomoConfig(
          p,
          serverIps: ips,
          localDnsServers: localDns,
          adBlock: adBlock,
          blockIpv6: blockIpv6,
          debug: debugMode,
        );
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
