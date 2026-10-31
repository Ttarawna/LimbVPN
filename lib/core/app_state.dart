import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_builder.dart';
import 'mieru_link.dart';
import 'vpn_controller.dart';

enum Flag { killSwitch, dnsProtection, blockIpv6, autostart }

class AppState extends ChangeNotifier {
  AppState(this._prefs, this.vpn) {
    vpn.addListener(notifyListeners);
    final saved = _prefs.getString('profile');
    if (saved != null) {
      try {
        profile = MieruProfile.parse(saved);
      } on LinkFormatException {
        _prefs.remove('profile');
      }
    }
    killSwitch = _prefs.getBool('killSwitch') ?? true;
    dnsProtection = _prefs.getBool('dnsProtection') ?? true;
    blockIpv6 = _prefs.getBool('blockIpv6') ?? true;
    autostart = _prefs.getBool('autostart') ?? false;
  }

  final SharedPreferences _prefs;
  final VpnController vpn;

  MieruProfile? profile;
  bool killSwitch = true;
  bool dnsProtection = true;
  bool blockIpv6 = true;
  bool autostart = false;

  /// Бросает [LinkFormatException], если ссылка не подходит.
  /// TODO: хранить пароль в защищённом хранилище (Keychain / Keystore), а не в prefs.
  void importLink(String raw) {
    profile = MieruProfile.parse(raw);
    _prefs.setString('profile', profile!.link);
    notifyListeners();
  }

  Future<void> deleteProfile() async {
    if (vpn.status == VpnStatus.on) await vpn.disconnect();
    profile = null;
    await _prefs.remove('profile');
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
      if (st == VpnStatus.on) {
        await vpn.disconnect();
      } else {
        // Адрес сервера определяем ДО туннеля, чтобы исключить его из туннеля.
        final ips = await _resolve(p.server);
        final config = buildMihomoConfig(
          p,
          serverIps: ips,
          dnsProtection: dnsProtection,
          blockIpv6: blockIpv6,
        );
        await vpn.connect(config, killSwitch: killSwitch);
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
