import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/mieru_service_manager.dart';
import 'package:quiet_vpn/core/vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('quiet/vpn');

  test(
    'refreshes service state and connection time when app resumes',
    () async {
      var status = <String, Object?>{'state': 'on', 'since': 1700000000000};

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

        status = {'state': 'blocked', 'since': null};
        final blocked = Completer<void>();
        controller.addListener(() {
          if (controller.status == VpnStatus.blocked && !blocked.isCompleted) {
            blocked.complete();
          }
        });
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await blocked.future;

        expect(controller.status, VpnStatus.blocked);
      } finally {
        controller.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
