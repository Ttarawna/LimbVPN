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

class _AppScanVpnController extends FakeVpnController {
  int scanCalls = 0;
  int connectCalls = 0;
  final scanStarted = Completer<void>();
  final scanResult = Completer<AppExclusionInventory>();
  AppExclusionInventory inventory = const AppExclusionInventory(
    scanCompleted: false,
    apps: [],
  );

  @override
  bool get hasAppExclusion => true;

  @override
  Future<AppExclusionInventory> readAppExclusionInventory() async => inventory;

  @override
  Future<AppExclusionInventory> scanInstalledApps(
    void Function(int completed, int total) onProgress,
  ) {
    scanCalls++;
    onProgress(4, 12);
    if (!scanStarted.isCompleted) scanStarted.complete();
    return scanResult.future;
  }

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

  test(
    'scans on first app launch, reports progress, and not on VPN connect',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final vpn = _AppScanVpnController();
      final app = AppState(prefs, vpn, PrefsSecretStore(prefs), _NoUpdates());
      addTearDown(app.dispose);
      app.importLink('mierus://user:pass@192.0.2.1?port=443&protocol=TCP');

      await app.load();
      await vpn.scanStarted.future;
      expect(app.appScanInProgress, isTrue);
      expect(app.appScanCompletedCount, 4);
      expect(app.appScanTotalCount, 12);
      expect(await app.toggle(), 'Дождитесь завершения проверки приложений');
      expect(vpn.connectCalls, 0);

      const inventory = AppExclusionInventory(
        scanCompleted: true,
        apps: [
          AppExclusionEntry(
            packageName: 'com.vkontakte.android',
            label: 'VK',
            inRussianCatalog: true,
            excluded: true,
          ),
        ],
      );
      vpn.inventory = inventory;
      vpn.scanResult.complete(inventory);
      await Future<void>.delayed(Duration.zero);
      expect(app.appScanComplete, isTrue);
      expect(vpn.scanCalls, 1);

      expect(await app.toggle(), isNull);
      expect(vpn.connectCalls, 1);
      expect(vpn.scanCalls, 1);
    },
  );
}
