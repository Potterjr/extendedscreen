import 'package:flutter/material.dart';
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
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
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

  group("a tile's label and picture follow its session's mode", () {
    const extended = SessionChoice(SessionMode.extendedScreen);
    const drivesMac = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.tabControlsMac);
    const macDrives = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);

    late SyntheticTablets synth;
    late HostConnectionManager hub;

    /// Four stand-in tablets and a hub that connects nothing.
    void rig() {
      Get.put(RemoteVideoChannel());
      synth = Get.put(SyntheticTablets(4));
      hub = HostConnectionManager(
        socket: SocketService(),
        adb: synth.adb,
        devicePollInterval: null,
      );
      Get.put<BaseConnectionManager>(hub);
    }

    /// Tablet [index]'s session, live as [choice], handed to the hub.
    HostSession live(int index, SessionChoice choice) {
      final serial = synth.tablets[index].serial;
      final session = HostSession(
        key: serial,
        link: LinkType.usb,
        serial: serial,
        choice: choice,
        pipeline: hub.pipeline,
        adb: synth.adb,
        socket: SocketService(),
      )..phase.value = ConnectionPhase.streaming;
      hub.adopt(session);
      return session;
    }

    /// The tile of tablet [index]: its Start or Stop button's column.
    Finder tile(int index) => find.ancestor(
          of: find.textContaining(synth.tablets[index].serial),
          matching: find.byType(Column),
        );

    Future<void> close(WidgetTester tester) async {
      await Get.delete<LoopbackPreviewController>();
      for (final session in hub.sessions.values.toList()) {
        session.phase.value = ConnectionPhase.disconnected;
      }
      await tester.pump();
    }

    testWidgets('each tile says the mode its own session runs in; a tablet '
        'with no session says none', (tester) async {
      tester.view.physicalSize = const Size(1700, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rig();
      live(0, extended);
      live(1, drivesMac);
      live(2, macDrives);
      Get.put(LoopbackPreviewController());
      await tester.pumpWidget(
          const GetMaterialApp(home: LoopbackPreviewView()));

      String label(int index) => tester
          .widgetList<Text>(
              find.descendant(of: tile(index), matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .firstWhere((t) => t.contains(' fps'));
      expect(label(0), startsWith('${extended.label}  ·  '));
      expect(label(1), startsWith('${drivesMac.label}  ·  '));
      expect(label(2), startsWith('${macDrives.label}  ·  '));
      // The three are told apart.
      expect({label(0), label(1), label(2)}, hasLength(3));
      expect(label(1), contains('remote_dir_tab_label'));
      expect(label(2), contains('remote_dir_mac_label'));
      // No session: the phase comes first, as before.
      expect(label(3), startsWith(ConnectionPhase.disconnected.label));
      expect(label(3), isNot(contains('session_')));
      // Every running tile offers Stop, the idle one Start: the label
      // changed nothing there.
      expect(find.text('loopback_preview_stop'), findsNWidgets(3));
      expect(find.text('loopback_preview_start'), findsOneWidget);

      await close(tester);
    });

    testWidgets('a tablet the Mac views says it has no picture, even with an '
        "earlier session's texture left; the others show their stream",
        (tester) async {
      tester.view.physicalSize = const Size(1700, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rig();
      live(0, extended);
      live(1, drivesMac);
      live(2, macDrives);
      final preview = Get.put(LoopbackPreviewController());
      // Decoders made for tablets 0 and 2 while each ran as a tablet the
      // Mac streams to.
      preview.tiles[0].textureId.value = 7;
      preview.tiles[2].textureId.value = 9;
      await tester.pumpWidget(
          const GetMaterialApp(home: LoopbackPreviewView()));

      Finder inTile(int index, Finder what) =>
          find.descendant(of: tile(index), matching: what);
      final reverseText = find.text('loopback_no_picture_reverse');
      final noStream = find.text('loopback_preview_no_stream');
      // The Mac views tablet 2: no stream of the Mac's to show.
      expect(inTile(2, reverseText), findsOneWidget);
      expect(inTile(2, find.byType(Texture)), findsNothing);
      expect(inTile(2, noStream), findsNothing);
      // Tablet 0 extends and has a picture; tablet 1 drives the Mac and
      // has none yet; tablet 3 has no session.
      expect(inTile(0, find.byType(Texture)), findsOneWidget);
      expect(inTile(1, noStream), findsOneWidget);
      expect(inTile(3, noStream), findsOneWidget);
      expect(reverseText, findsOneWidget);
      expect(
        tester.widget<Texture>(inTile(0, find.byType(Texture))).textureId,
        7,
      );

      // Its session gone from the hub, the tile is an idle one again, and
      // what its decoder last drew is its own to show.
      final gone = hub.sessions.remove(synth.tablets[2].serial)!;
      await tester.pump();
      expect(reverseText, findsNothing);
      expect(inTile(2, find.byType(Texture)), findsOneWidget);
      expect(inTile(2, find.text('loopback_preview_start')), findsOneWidget);

      gone.phase.value = ConnectionPhase.disconnected;
      await close(tester);
    });

    test('the text exists in English and Thai', () {
      final keys = AppTranslations().keys;
      for (final locale in ['en', 'th']) {
        expect(keys[locale]!['loopback_no_picture_reverse'], isNotEmpty,
            reason: locale);
      }
    });
  });
}
