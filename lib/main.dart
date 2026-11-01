import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/android_vpn_controller.dart';
import 'core/app_state.dart';
import 'core/secret_store.dart';
import 'core/vpn_controller.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // На Android работает настоящее ядро, на остальных платформах пока имитация.
  final VpnController vpn =
      Platform.isAndroid ? AndroidVpnController() : FakeVpnController();
  final SecretStore secrets =
      Platform.isAndroid ? ChannelSecretStore() : PrefsSecretStore(prefs);
  final app = AppState(prefs, vpn, secrets);
  await app.load();
  runApp(LimbApp(app: app));
}

class LimbApp extends StatelessWidget {
  const LimbApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          brightness: b,
          colorSchemeSeed: const Color(0xFF1F7A6E),
        );
    return MaterialApp(
      title: 'Limb VPN',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: HomePage(app: app),
    );
  }
}
