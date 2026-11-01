import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_builder.dart';
import 'mieru_link.dart';
import 'secret_store.dart';
import 'vpn_controller.dart';

enum Flag { killSwitch, dnsProtection, blockIpv6, autostart, excludeRuApps, debug }

class AppState extends ChangeNotifier {
  AppState(this._prefs, this.vpn, this._secrets) {
    vpn.addListener(notifyListeners);
    killSwitch = _prefs.getBool('killSwitch') ?? true;
    dnsProtection = _prefs.getBool('dnsProtection') ?? true;
    blockIpv6 = _prefs.getBool('blockIpv6') ?? true;
    autostart = _prefs.getBool('autostart') ?? false;
    excludeRuApps = _prefs.getBool('excludeRuApps') ?? true;
    debugMode = _prefs.getBool('debug') ?? false;
  }

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final VpnController vpn;

  MieruProfile? profile;
  bool killSwitch = true;
  bool dnsProtection = true;
  bool blockIpv6 = true;
  bool autostart = false;
  bool excludeRuApps = true;
  bool debugMode = false;

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
      case Flag.dnsProtection:
        dnsProtection = value;
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
    final p = profile;
    if (p == null) return 'Сначала добавьте профиль';
    final st = vpn.status;
    if (st == VpnStatus.connecting || st == VpnStatus.disconnecting) return null;
    try {
      if (st == VpnStatus.on || st == VpnStatus.blocked) {
        await vpn.disconnect();
      } else {
        // Адрес сервера определяем ДО туннеля, чтобы исключить его из туннеля.
        final ips = await _resolve(p.server);
        final config = buildMihomoConfig(
          p,
          serverIps: ips,
          dnsProtection: dnsProtection,
          blockIpv6: blockIpv6,
          debug: debugMode,
        );
        await vpn.connect(config,
            killSwitch: killSwitch, excludeRuApps: excludeRuApps, debug: debugMode);
      }
    } on SocketException {
      return 'Не удалось определить адрес сервера. Проверьте интернет.';
    } catch (e) {
      return 'Не удалось подключиться: $e';
    }
    return null;
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
