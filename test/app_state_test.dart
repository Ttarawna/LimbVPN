import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/app_state.dart';
import 'package:quiet_vpn/core/secret_store.dart';
import 'package:quiet_vpn/core/updater.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoUpdates implements UpdateService {
  @override
  Future<UpdateInfo?> check() async => null;

  @override
  Future<String?> install(
    UpdateInfo info,
    void Function(int percent) onProgress,
  ) async =>
      null;

  @override
  void setErrorHandler(void Function(String message) handler) {}
}

class _DeferredVpnController extends FakeVpnController {
  final dns = Completer<List<String>>();
  int connectCalls = 0;

  @override
  Future<List<String>> localDnsServers() => dns.future;

  @override
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  }) async {
    connectCalls++;
  }
}

class _BootVpnController extends FakeVpnController {
  int connectCalls = 0;
  bool failConnect = true;

  @override
  Future<int?> bootCount() async => 2;

  @override
  Future<List<String>> localDnsServers() async => ['192.0.2.53'];

  @override
  Future<void> connect(
    String config, {
    required bool killSwitch,
    bool excludeRuApps = false,
    bool debug = false,
  }) async {
    connectCalls++;
    if (failConnect) throw StateError('connection failed');
    await super.connect(
      config,
      killSwitch: killSwitch,
      excludeRuApps: excludeRuApps,
      debug: debug,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('locks VPN toggle during connection preparation', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vpn = _DeferredVpnController();
    final app = AppState(prefs, vpn, PrefsSecretStore(prefs), _NoUpdates());
    addTearDown(app.dispose);
    app.importLink('mierus://user:pass@192.0.2.1?port=443&protocol=TCP');

    final firstToggle = app.toggle();
    expect(app.vpnOperationInProgress, isTrue);
    expect(await app.toggle(), isNull);
    expect(vpn.connectCalls, 0);

    vpn.dns.complete(['192.0.2.53']);
    expect(await firstToggle, isNull);
    expect(vpn.connectCalls, 1);
    expect(app.vpnOperationInProgress, isFalse);
  });

  test('keeps boot fallback retryable after a failed connection', () async {
    SharedPreferences.setMockInitialValues({
      'autostart': true,
      'lastBootCount': 1,
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = PrefsSecretStore(prefs);
    await secrets.write(
      'profile',
      'mierus://user:password@192.0.2.1?port=443&protocol=TCP',
    );
    final vpn = _BootVpnController();
    final app = AppState(prefs, vpn, secrets, _NoUpdates());
    addTearDown(app.dispose);

    await app.load();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(vpn.connectCalls, 1);
    expect(prefs.getInt('lastBootCount'), 1);
  });

  test('records an initial boot-count baseline without reconnecting', () async {
    SharedPreferences.setMockInitialValues({'autostart': true});
    final prefs = await SharedPreferences.getInstance();
    final secrets = PrefsSecretStore(prefs);
    await secrets.write(
      'profile',
      'mierus://user:password@192.0.2.1?port=443&protocol=TCP',
    );
    final vpn = _BootVpnController();
    final app = AppState(prefs, vpn, secrets, _NoUpdates());
    addTearDown(app.dispose);

    await app.load();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(vpn.connectCalls, 0);
    expect(prefs.getInt('lastBootCount'), 2);
  });
}
