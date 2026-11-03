import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/app_state.dart';
import 'package:quiet_vpn/core/secret_store.dart';
import 'package:quiet_vpn/core/updater.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UpdateService implements UpdateService {
  UpdateInfo? result;
  Object? error;
  int checks = 0;

  @override
  Future<UpdateInfo?> check() async {
    checks++;
    if (error != null) throw error!;
    return result;
  }

  @override
  Future<String?> install(
    UpdateInfo info,
    void Function(int percent) onProgress,
  ) async =>
      null;

  @override
  void setErrorHandler(void Function(String message) handler) {}
}

void main() {
  late AppState app;
  late SharedPreferences prefs;
  late _UpdateService updates;
  late int lastCheck;

  setUp(() async {
    lastCheck = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({'lastUpdateCheck': lastCheck});
    prefs = await SharedPreferences.getInstance();
    updates = _UpdateService();
    app =
        AppState(prefs, FakeVpnController(), PrefsSecretStore(prefs), updates);
  });

  tearDown(() {
    app.dispose();
  });

  test('manual check bypasses the automatic check interval', () async {
    await app.checkForUpdate();
    expect(updates.checks, 0);

    updates.result =
        const UpdateInfo('1.0.0', 'https://example.com/app.apk', '');
    await app.checkForUpdate(force: true);

    expect(updates.checks, 1);
    expect(app.update?.version, '1.0.0');
    expect(app.updateCheckMessage, 'Доступна версия 1.0.0');
    expect(app.updateChecking, isFalse);
  });

  test('manual check reports when there is no update', () async {
    await app.checkForUpdate(force: true);

    expect(app.update, isNull);
    expect(app.updateCheckMessage, 'Установлена последняя версия');
  });

  test('failed check exposes the error and remains retryable', () async {
    updates.error = Exception('offline');

    await app.checkForUpdate(force: true);

    expect(app.updateCheckMessage, contains('offline'));
    expect(app.updateChecking, isFalse);
    expect(prefs.getInt('lastUpdateCheck'), lastCheck);
  });
}
