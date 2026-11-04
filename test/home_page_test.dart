import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/app_state.dart';
import 'package:quiet_vpn/core/secret_store.dart';
import 'package:quiet_vpn/core/updater.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';
import 'package:quiet_vpn/ui/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UpdateService implements UpdateService {
  int checks = 0;
  int installs = 0;

  @override
  Future<UpdateInfo?> check() async {
    checks++;
    return const UpdateInfo('1.0.0', 'https://example.com/app.apk', '');
  }

  @override
  Future<String?> install(
    UpdateInfo info,
    void Function(int percent) onProgress,
  ) async {
    installs++;
    return null;
  }

  @override
  void setErrorHandler(void Function(String message) handler) {}
}

class _PreparingVpnController extends FakeVpnController {
  final dnsServers = Completer<List<String>>();

  @override
  Future<List<String>> localDnsServers() => dnsServers.future;

  @override
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows connecting while DNS preparation is pending', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vpn = _PreparingVpnController();
    final app = AppState(
      prefs,
      vpn,
      PrefsSecretStore(prefs),
      _UpdateService(),
    );
    addTearDown(app.dispose);
    app.importLink('mierus://user:pass@192.0.2.1?port=443&protocol=TCP');

    await tester.pumpWidget(MaterialApp(home: HomePage(app: app)));
    final connection = app.toggle();
    await tester.pump();
    expect(find.text('Подключаю…'), findsOneWidget);

    vpn.dnsServers.complete(['192.0.2.53']);
    await connection;
    await tester.pump();
  });

  testWidgets('home screen checks for and installs app updates', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lastUpdateCheck': DateTime.now().millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final updates = _UpdateService();
    final app = AppState(
      prefs,
      FakeVpnController(),
      PrefsSecretStore(prefs),
      updates,
    );
    addTearDown(app.dispose);

    await tester.pumpWidget(MaterialApp(home: HomePage(app: app)));
    expect(find.text('Проверить обновления'), findsOneWidget);

    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
    expect(updates.checks, 1);
    expect(find.text('Доступна версия 1.0.0 · Обновить'), findsOneWidget);

    await tester.tap(find.text('Доступна версия 1.0.0 · Обновить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();

    expect(updates.installs, 1);
  });
}
