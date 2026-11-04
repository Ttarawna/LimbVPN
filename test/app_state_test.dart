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
  ) async => null;

  @override
  void setErrorHandler(void Function(String message) handler) {}
}

class _DeferredVpnController extends FakeVpnController {
  final dns = Completer<List<String>>();
  int connectCalls = 0;
  List<Map<String, Object>>? connectionTimings;

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

  @override
  Future<void> recordConnectionTimings(
    List<Map<String, Object>> timings,
  ) async {
    connectionTimings = timings;
  }
}

class _NoDnsVpnController extends FakeVpnController {
  int connectCalls = 0;

  @override
  Future<List<String>> localDnsServers() async =>
      throw StateError('local DNS unavailable');

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'locks VPN toggle during connection preparation and records timings',
    () async {
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
      await Future<void>.delayed(Duration.zero);
      expect(vpn.connectionTimings?.map((timing) => timing['stage']), [
        'server_dns',
        'local_dns',
        'config_build',
        'vpn_service_start',
      ]);
      expect(app.lastConnectionTimings.map((timing) => timing['stage']), [
        'server_dns',
        'local_dns',
        'config_build',
        'vpn_service_start',
      ]);
    },
  );

  test('does not connect when local DNS is unavailable', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vpn = _NoDnsVpnController();
    final app = AppState(prefs, vpn, PrefsSecretStore(prefs), _NoUpdates());
    addTearDown(app.dispose);
    app.importLink('mierus://user:pass@192.0.2.1?port=443&protocol=TCP');

    final error = await app.toggle();

    expect(error, contains('Не удалось подключиться'));
    expect(vpn.connectCalls, 0);
    expect(app.lastConnectionTimings.map((timing) => timing['stage']), [
      'server_dns',
      'local_dns',
    ]);
  });
}
