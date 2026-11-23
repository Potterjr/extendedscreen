import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What the Mac asked adb to do with the tablet's panel.
class _Adb extends AdbService {
  final calls = <String>[];

  /// Answers a hold with this error (null: the panel went off).
  String? holdError;

  /// When set, a hold waits for it (adb taking its time).
  Completer<void>? holdDelay;

  @override
  Future<String?> holdTabletScreenOff({required String serial}) async {
    calls.add('hold $serial');
    await holdDelay?.future;
    return holdError;
  }

  @override
  Future<void> releaseTabletScreenOff({required String serial}) async =>
      calls.add('release $serial');

  @override
  Future<void> removeForward({required String serial, int? remotePort}) async {}

  /// The end of the tablet's input shell, which every teardown of a tablet
  /// the Mac controls asks for: not what these tests are about.
  @override
  Future<void> closeInputShell({required String serial}) async {}

  /// The taps and swipes the Mac sent the tablet.
  final input = <String>[];

  @override
  Future<void> inputTap(
          {required String serial, required int x, required int y}) async =>
      input.add('tap $serial $x $y');

  @override
  Future<void> inputSwipe({
    required String serial,
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int durationMs = 50,
  }) async =>
      input.add('swipe $serial $x1 $y1 $x2 $y2 $durationMs');
}

class _Capture extends ScreenCaptureChannel {
  @override
  Future<void> stopCapture({required int session}) async {}
  @override
  Future<void> removeVirtualDisplay({required int session}) async {}
}

class _Input extends InputInjectChannel {
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async {}
}

class _Remote extends RemoteVideoChannel {
  int fed = 0;
  @override
  Future<void> feedNal(int session, List<int> nalBytes) async => fed++;
  @override
  Future<void> dispose({required int session}) async {}
}

final _frame = Packet(
  type: PacketType.frameData,
  timestampUs: 0,
  payload: Uint8List.fromList([0, 0, 0, 1, 0x65]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late _Adb adb;
  late HostSession host;

  /// A live Mac-controls-tablet session over USB, as far as the host's
  /// state goes, without a socket.
  void live() {
    host.phase.value = ConnectionPhase.streaming;
    host.activeDevice.value =
        const DeviceModel(serial: 'TABLET', status: DeviceStatus.connected);
  }

  /// The tablet's session, made as [choice]; with none, as the selectors
  /// stand (Mac controls tablet, from the set-up).
  HostSession sessionAs(SessionChoice? choice) => HostSession(
        key: 'TABLET',
        link: LinkType.usb,
        serial: 'TABLET',
        choice: choice,
        pipeline: PipelineQueue(),
        socket: SocketService(),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    await settings.setSessionMode(SessionMode.remoteControl);
    await settings.setRemoteDirection(RemoteDirection.macControlsTab);
    adb = Get.put<AdbService>(_Adb()) as _Adb;
    Get.put<ScreenCaptureChannel>(_Capture());
    Get.put<InputInjectChannel>(_Input());
    Get.put<RemoteVideoChannel>(_Remote());
    host = sessionAs(null);
  });

  tearDown(Get.reset);

  test('nothing can go dark before the tablet sends its picture: its user '
      'still has to approve screen capture on it', () async {
    live();
    expect(await host.setTabletScreenOff(true), isNotNull);
    expect(adb.calls, isEmpty);
    expect(settings.tabletScreenOffFor('TABLET'), isFalse);
  });

  test('the toggle turns the panel off and on, and is remembered', () async {
    live();
    host.onRolePacket(_frame);
    expect(host.tabletStreaming.value, isTrue);
    expect(adb.calls, isEmpty, reason: 'not chosen yet');

    expect(await host.setTabletScreenOff(true), isNull);
    expect(host.tabletScreenOff.value, isTrue);
    expect(settings.tabletScreenOffFor('TABLET'), isTrue);

    expect(await host.setTabletScreenOff(false), isNull);
    expect(host.tabletScreenOff.value, isFalse);
    expect(settings.tabletScreenOffFor('TABLET'), isFalse);
    expect(adb.calls, ['hold TABLET', 'release TABLET']);
  });

  test('chosen last time, it goes dark again once the picture arrives, once',
      () async {
    await settings.setTabletScreenOffFor('TABLET', true);
    live();
    host.onRolePacket(_frame);
    await pumpEventQueue();
    host.onRolePacket(_frame);
    await pumpEventQueue();
    expect(adb.calls, ['hold TABLET']);
    expect(host.tabletScreenOff.value, isTrue);
    expect((Get.find<RemoteVideoChannel>() as _Remote).fed, 2);
  });

  test('the end of the session lights it again', () async {
    await settings.setTabletScreenOffFor('TABLET', true);
    live();
    host.onRolePacket(_frame);
    await pumpEventQueue();
    expect(host.tabletScreenOff.value, isTrue);

    await host.disconnect();
    expect(adb.calls.last, 'release TABLET');
    expect(host.tabletScreenOff.value, isFalse);
    expect(host.tabletStreaming.value, isFalse);
    expect(settings.tabletScreenOffFor('TABLET'), isTrue,
        reason: 'the choice stays for the next session');
  });

  test('a hold adb finishes after the session ended is let go at once',
      () async {
    live();
    host.onRolePacket(_frame);
    adb.holdDelay = Completer<void>();
    final turning = host.setTabletScreenOff(true);
    await pumpEventQueue();
    await host.disconnect();
    adb.holdDelay!.complete();
    expect(await turning, isNotNull);
    expect(adb.calls, ['hold TABLET', 'release TABLET', 'release TABLET']);
    expect(host.tabletScreenOff.value, isFalse);
  });

  test('a panel that came back on by itself shows as on', () async {
    live();
    host.onRolePacket(_frame);
    await host.setTabletScreenOff(true);
    host.onTabletScreenRestored('SOMEONE-ELSE');
    expect(host.tabletScreenOff.value, isTrue);
    host.onTabletScreenRestored('TABLET');
    expect(host.tabletScreenOff.value, isFalse);
  });

  test('a tablet that refuses (an older app build) leaves the panel on and '
      'says why', () async {
    live();
    host.onRolePacket(_frame);
    adb.holdError = 'error: ClassNotFoundException';
    expect(await host.setTabletScreenOff(true), contains('ClassNotFound'));
    expect(host.tabletScreenOff.value, isFalse);
    expect(settings.tabletScreenOffFor('TABLET'), isFalse,
        reason: 'what failed is not remembered for the next session');
    expect(host.changingTabletScreen.value, isFalse);
  });

  test('while the remembered choice is being applied the toggle waits: no '
      'second hold, and no answer before the first one has one', () async {
    await settings.setTabletScreenOffFor('TABLET', true);
    adb.holdDelay = Completer<void>();
    live();
    host.onRolePacket(_frame);
    await pumpEventQueue();
    expect(host.changingTabletScreen.value, isTrue);
    expect(await host.setTabletScreenOff(true), isNotNull);
    expect(await host.setTabletScreenOff(false), isNotNull);
    expect(adb.calls, ['hold TABLET']);
    expect(host.tabletScreenOff.value, isFalse);

    adb.holdDelay!.complete();
    await pumpEventQueue();
    expect(host.tabletScreenOff.value, isTrue);
    expect(host.changingTabletScreen.value, isFalse);
  });

  test('a picture that arrives before the session is live is darkened once '
      'it is', () async {
    await settings.setTabletScreenOffFor('TABLET', true);
    live();
    host.phase.value = ConnectionPhase.configuring;
    host.onRolePacket(_frame);
    await pumpEventQueue();
    expect(adb.calls, isEmpty, reason: 'not live yet');

    host.phase.value = ConnectionPhase.streaming;
    await pumpEventQueue();
    expect(adb.calls, ['hold TABLET']);
    expect(host.tabletScreenOff.value, isTrue);
  });

  test('a session that ends mid-hold frees the toggle for the next one',
      () async {
    live();
    host.onRolePacket(_frame);
    adb.holdDelay = Completer<void>();
    unawaited(host.setTabletScreenOff(true));
    await pumpEventQueue();
    await host.disconnect();
    expect(host.changingTabletScreen.value, isFalse);

    live();
    host.onRolePacket(_frame);
    adb.holdDelay!.complete();
    adb.holdDelay = null;
    await pumpEventQueue();
    expect(host.tabletScreenOff.value, isFalse,
        reason: "the old session's hold says nothing about this one");
    expect(await host.setTabletScreenOff(true), isNull);
    expect(host.tabletScreenOff.value, isTrue);
  });

  test('outside Mac-controls-tablet nothing is turned off', () async {
    // A session is what it was made to be: one made to extend.
    host = sessionAs(const SessionChoice(SessionMode.extendedScreen));
    // Whatever the selectors say, which is Mac controls tablet here.
    expect(settings.isReverseRemote, isTrue);
    live();
    host.tabletStreaming.value = true;
    expect(await host.setTabletScreenOff(true), isNotNull);
    expect(adb.calls, isEmpty);
  });

  test("the Mac's taps and swipes go to a tablet it controls, to its own "
      'device, and to no other kind of session', () async {
    live();
    final panel = host.panel;
    host.sendRemoteTap(0.5, 0.5);
    host.sendRemoteSwipe(0, 0, 1, 1);
    expect(adb.input, [
      'tap TABLET ${panel.width ~/ 2} ${panel.height ~/ 2}',
      'swipe TABLET 0 0 ${panel.width} ${panel.height} 50',
    ]);

    // An Extended screen takes its input from the tablet, and sends none.
    adb.input.clear();
    host = sessionAs(const SessionChoice(SessionMode.extendedScreen));
    live();
    host.sendRemoteTap(0.5, 0.5);
    host.sendRemoteSwipe(0, 0, 1, 1);
    expect(adb.input, isEmpty);

    // Nor does a tablet that drives the Mac.
    host = sessionAs(const SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac));
    live();
    host.sendRemoteTap(0.5, 0.5);
    host.sendRemoteSwipe(0, 0, 1, 1);
    expect(adb.input, isEmpty);
  });

  test('the choice is kept per tablet', () async {
    await settings.setTabletScreenOffFor('OTHER', true);
    expect(settings.tabletScreenOffFor('TABLET'), isFalse);
    expect(settings.tabletScreenOffFor('OTHER'), isTrue);
  });

  test('the choice made before it was kept per tablet becomes the last-used '
      "tablet's, and no other tablet inherits it later", () async {
    SharedPreferences.setMockInitialValues(
        {'tablet_screen_off': true, 'last_device': 'OLD'});
    final upgraded = SettingsService();
    await upgraded.init();
    expect(upgraded.tabletScreenOffFor('OLD'), isTrue);
    await upgraded.setLastDevice('NEW');
    expect(upgraded.tabletScreenOffFor('NEW'), isFalse);

    // And it happens once: turning OLD's screen back on is not undone.
    await upgraded.setTabletScreenOffFor('OLD', false);
    final again = SettingsService();
    await again.init();
    expect(again.tabletScreenOffFor('OLD'), isFalse);
  });

  test("the hub's toggle answers with what its session did, and a panel that "
      "came back on reaches that tablet's session", () async {
    final hub = HostConnectionManager(socket: SocketService());
    expect(adb.onTabletScreenRestored, isNotNull,
        reason: 'the hub, not a session, owns the callback');
    hub.adopt(host);
    live();
    host.onRolePacket(_frame);
    expect(await hub.setTabletScreenOff(true), isNull);
    expect(hub.tabletScreenOff.value, isTrue);
    adb.onTabletScreenRestored!('SOMEONE-ELSE');
    expect(hub.tabletScreenOff.value, isTrue);
    adb.onTabletScreenRestored!('TABLET');
    expect(host.tabletScreenOff.value, isFalse);
    expect(hub.tabletScreenOff.value, isFalse);
    expect(await hub.setTabletScreenOff(false), isNull);
  });
}
