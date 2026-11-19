import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_controller.dart';
import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_view.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// The debug Loopback preview's tile, over a hub whose session is adopted
/// and moved by hand: nothing connects.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    final settings = SettingsService();
    await settings.init();
    Get.put(settings);
  });

  tearDown(Get.reset);

  testWidgets("a press on Start that the session's phase overtakes does "
      'nothing (it never lands as Stop)', (tester) async {
    Get.put(RemoteVideoChannel());
    final synth = Get.put(SyntheticTablets(1));
    final serial = synth.tablets.single.serial;
    final hub = HostConnectionManager(
      socket: SocketService(),
      adb: synth.adb,
      devicePollInterval: null,
    );
    Get.put<BaseConnectionManager>(hub);
    // Waiting to retry: the tile offers Start.
    final session = HostSession(
      key: serial,
      link: LinkType.usb,
      serial: serial,
      pipeline: hub.pipeline,
      adb: synth.adb,
      socket: SocketService(),
    )..phase.value = ConnectionPhase.error;
    hub.adopt(session);
    Get.put(LoopbackPreviewController());

    await tester.pumpWidget(const GetMaterialApp(home: LoopbackPreviewView()));
    expect(find.text('loopback_preview_start'), findsOneWidget);

    // Its retry fires before the finger comes up: the button now reads
    // Stop.
    final touch = await tester.startGesture(
      tester.getCenter(find.text('loopback_preview_start')),
    );
    session.phase.value = ConnectionPhase.detectingDevice;
    await tester.pump();
    expect(find.text('loopback_preview_stop'), findsOneWidget);
    await touch.up();
    await tester.pump();

    expect(hub.sessions[serial], same(session),
        reason: 'the press meant Start; it must not stop the session');

    await Get.delete<LoopbackPreviewController>();
    session.phase.value = ConnectionPhase.disconnected;
    await tester.pump();
  });
}
