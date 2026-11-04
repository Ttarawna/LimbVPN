import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/app_state.dart';
import 'package:quiet_vpn/core/secret_store.dart';
import 'package:quiet_vpn/core/updater.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';
import 'package:quiet_vpn/ui/settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoggedVpnController extends FakeVpnController {
  @override
  bool get hasLog => true;
}

class _AppExclusionVpnController extends _LoggedVpnController {
  @override
  bool get hasAppExclusion => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the latest connection timings in diagnostics', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      prefs,
      _LoggedVpnController(),
      PrefsSecretStore(prefs),
      NoUpdateService(),
    )..lastConnectionTimings = const [
        {'stage': 'server_dns', 'elapsed_ms': 17},
        {'stage': 'vpn_service_start', 'elapsed_ms': 1234},
      ];
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsSheet(app: app)),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Замеры последнего подключения'),
      300,
    );

    expect(find.textContaining('DNS сервера: 17 мс'), findsOneWidget);
    expect(find.textContaining('Запуск VPN: 1234 мс'), findsOneWidget);
    expect(find.textContaining('Всего: 1251 мс'), findsOneWidget);
  });

  testWidgets('does not show the app exclusion list in advanced settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      prefs,
      _AppExclusionVpnController(),
      PrefsSecretStore(prefs),
      NoUpdateService(),
    );
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsSheet(app: app)),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Выбранные приложения без VPN'),
      300,
    );
    expect(find.text('Какие приложения без VPN'), findsNothing);
    expect(find.text('Выбранные приложения без VPN'), findsOneWidget);
  });
}
