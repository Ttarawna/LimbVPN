import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/mieru_service_manager.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('quiet/vpn');

  test('reads local DNS servers from Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'statusDetails') {
        return <String, Object?>{
          'state': 'off',
          'since': null,
          'revision': 0,
        };
      }
      expect(call.method, 'localDnsServers');
      return <String>['192.168.1.1'];
    });

    final controller = MieruServiceManager();
    try {
      expect(await controller.localDnsServers(), ['192.168.1.1']);
    } finally {
      controller.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('reads app scan results and forwards scan progress', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'statusDetails') {
        return <String, Object?>{
          'state': 'off',
          'since': null,
          'revision': 0,
        };
      }
      if (call.method == 'readAppExclusionInventory') {
        return '{"scanCompleted":true,"apps":[]}';
      }
      expect(call.method, 'scanInstalledApps');
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('appScanProgress', {'completed': 3, 'total': 9}),
        ),
        null,
      );
      return '{"scanCompleted":true,"apps":[{"package":"com.vkontakte.android",'
          '"label":"VK","catalog":true,"excluded":true}]}';
    });

    final controller = MieruServiceManager();
    addTearDown(() {
      controller.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    final cached = await controller.readAppExclusionInventory();
    expect(cached.scanCompleted, isTrue);
    final progress = <List<int>>[];
    final result = await controller.scanInstalledApps(
      (completed, total) => progress.add([completed, total]),
    );

    expect(progress, [
      [3, 9],
    ]);
    expect(result.apps.single.packageName, 'com.vkontakte.android');
    expect(result.apps.single.excluded, isTrue);
  });

  test(
    'refreshes service state and connection time when app resumes',
    () async {
      var status = <String, Object?>{
        'state': 'on',
        'since': 1700000000000,
        'revision': 2,
      };

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'statusDetails');
        return status;
      });

      final controller = MieruServiceManager();
      try {
        final connected = Completer<void>();
        controller.addListener(() {
          if (controller.status == VpnStatus.on && !connected.isCompleted) {
            connected.complete();
          }
        });
        await connected.future;
        expect(controller.status, VpnStatus.on);
        expect(
          controller.since,
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );

        status = {'state': 'blocked', 'since': null, 'revision': 4};
        final blocked = Completer<void>();
        controller.addListener(() {
          if (controller.status == VpnStatus.blocked && !blocked.isCompleted) {
            blocked.complete();
          }
        });
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await blocked.future;

        expect(controller.status, VpnStatus.blocked);
        status = {'state': 'on', 'since': 1700000000000, 'revision': 6};
        final reconnected = Completer<void>();
        controller.addListener(() {
          if (controller.status == VpnStatus.on && !reconnected.isCompleted) {
            reconnected.complete();
          }
        });
        await reconnected.future.timeout(const Duration(seconds: 3));
        expect(controller.status, VpnStatus.on);
      } finally {
        controller.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );

  test('ignores stale service state events', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final staleStatus = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'statusDetails') {
        return staleStatus.future;
      }
      return null;
    });

    final controller = MieruServiceManager();
    addTearDown(() {
      controller.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    Future<void> sendState(String state, int revision) async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('status', {
            'state': state,
            'revision': revision,
            'since': state == 'on' ? 1700000000000 : null,
          }),
        ),
        null,
      );
    }

    await sendState('on', 10);
    expect(controller.status, VpnStatus.on);
    staleStatus.complete({'state': 'off', 'since': null, 'revision': 8});
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VpnStatus.on);
    await sendState('off', 9);
    expect(controller.status, VpnStatus.on);
    await sendState('off', 11);
    expect(controller.status, VpnStatus.off);
  });
}
