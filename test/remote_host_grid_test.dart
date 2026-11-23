import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/bindings/remote_host_binding.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_grid_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_tile.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/views/remote_host_view.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

import 'support/recording_remote_video.dart';

/// The remote view (`/remote-host`) as a grid of the tablets the Mac
/// controls. The sessions are made by hand and given to the hub, never
/// connected: live as far as their observables go, each with a texture id a
/// test made up. [SynthAdb] keeps the taps, swipes and screen holds the
/// tiles send, and the hub records what the tiles ask of it.

class _QuietLogger extends LoggerService {
  @override
  void d(String msg) {}
  @override
  void i(String msg) {}
  @override
  void w(String msg) {}
  @override
  void e(String msg, [Object? error, StackTrace? st]) {}
}

/// The Mac's hub, with what the remote view asks of it recorded. Ending a
/// session takes it out of [sessions] at once, as the hub does, and then
/// either waits for [teardown] or, with [real], ends it for real.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
      : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  final stops = <(String, bool)>[];
  final reconnects = <String>[];
  int disconnects = 0;

  /// While set, a session's end is not done until it completes.
  Completer<void>? teardown;

  /// The hub's own [disconnectSession] runs.
  bool real = false;

  @override
  Future<void> disconnectSession(String key, {bool userStopped = false}) {
    stops.add((key, userStopped));
    if (real) return super.disconnectSession(key, userStopped: userStopped);
    sessions.remove(key);
    return teardown?.future ?? Future<void>.value();
  }

  @override
  Future<void> reconnectSession(String key) async => reconnects.add(key);

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> autoConnect() async {}
}

class _Input extends InputInjectChannel {
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async {}
}

/// Every route popped, by name.
class _Pops extends NavigatorObserver {
  final names = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      names.add(route.settings.name);
}

const _reverse =
    SessionChoice(SessionMode.remoteControl, RemoteDirection.macControlsTab);
const _extended = SessionChoice(SessionMode.extendedScreen);

const _panelA = ClientPanel(2560, 1600, 60);
const _panelB = ClientPanel(2400, 1080, 60);

/// A panel no tile has: the last one "reported", so the app-wide panel.
const _lastPanel = ClientPanel(2000, 1500, 60);

/// What stands where a decoder's texture would: a box a test can find.
Widget _box(int textureId) => ColoredBox(
    key: ValueKey('texture/$textureId'), color: const Color(0xFF202020));

Finder _texture(int id) => find.byKey(ValueKey('texture/$id'));
Finder _key(String key) => find.byKey(ValueKey(key));
Finder _tile(HostSession s) => _key('tile/${s.key}/${s.nativeId}');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late SynthAdb adb;
  late _Hub hub;
  late _Pops pops;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    // Each tablet's own panel, then another as the last one reported: a
    // tile that read the app-wide panel would have the wrong shape.
    await settings.setClientPanelFor('A', _panelA);
    await settings.setClientPanelFor('B', _panelB);
    for (final key in ['C', 'D', 'E']) {
      await settings.setClientPanelFor(key, _panelA);
    }
    await settings.setClientPanelFor('LAST', _lastPanel);
    Get.put<InputInjectChannel>(_Input());
    Get.put<RemoteVideoChannel>(RecordingRemoteVideo());
    adb = SynthAdb(const []);
    Get.put<AdbService>(adb);
    hub = Get.put<BaseConnectionManager>(_Hub(adb)) as _Hub;
    pops = _Pops();
  });

  tearDown(Get.reset);

  /// A session for the tablet [key], made as [choice] and given to the
  /// hub: live, and for a tablet the Mac controls with [texture] as its
  /// decoder's texture and its picture arriving.
  HostSession session(String key,
      {SessionChoice choice = _reverse, int? texture, String? model}) {
    final s = HostSession(
      key: key,
      link: LinkType.usb,
      serial: key,
      choice: choice,
      pipeline: hub.pipeline,
      adb: adb,
      socket: SocketService(),
    )
      ..activeDevice.value = DeviceModel(
          serial: key, model: model, status: DeviceStatus.connected)
      ..phase.value = ConnectionPhase.streaming;
    if (choice.isReverse) {
      s.remoteTextureId.value = texture;
      s.tabletStreaming.value = texture != null;
    }
    hub.adopt(s);
    return s;
  }

  /// Tablets A (16:10, texture 101) and B (20:9, texture 102).
  (HostSession, HostSession) two() => (
        session('A', texture: 101, model: 'Tab_A'),
        session('B', texture: 102, model: 'Tab_B'),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The remote view, opened from a Home stand-in in a 1600×1000 window.
  Future<void> open(
    WidgetTester tester, {
    Object? arguments,
    RemoteTextureBuilder? texture = _box,
    Size window = const Size(1600, 1000),
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      translations: AppTranslations(),
      locale: locale,
      fallbackLocale: const Locale('en'),
      initialRoute: AppRoutes.home,
      navigatorObservers: [pops],
      getPages: [
        GetPage(
            name: AppRoutes.home,
            page: () => const Scaffold(body: Text('home'))),
        GetPage(
          name: AppRoutes.remoteHost,
          page: () => texture == null
              ? const RemoteHostView()
              : RemoteHostView(textureBuilder: texture),
          binding: RemoteHostBinding(),
        ),
      ],
    ));
    unawaited(Get.toNamed<void>(AppRoutes.remoteHost, arguments: arguments));
    await settle(tester);
    expect(Get.currentRoute, AppRoutes.remoteHost);
  }

  RemoteGridController grid() => Get.find<RemoteGridController>();

  group('a tile, without the view', () {
    test('a press and a release close together are a tap where the pointer '
        'came up, further apart a swipe; both stay inside the picture',
        () {
      final a = session('A', texture: 101);
      final tile = RemoteTile(a, hub);

      tile.onPointerDown(1, 0.25, 0.5);
      tile.onPointerUp(1, 0.255, 0.5);
      expect(adb.taps, [('A', (0.255 * 2560).round(), 800)]);
      expect(adb.swipes, isEmpty);

      tile.onPointerDown(2, 0.25, 0.5);
      tile.onPointerUp(2, 0.25, 0.52);
      expect(adb.swipes, [('A', 640, 800, 640, 832, 50)]);

      // Released outside the picture: taken to its nearest edge.
      tile.onPointerDown(3, 0.9, 0.9);
      tile.onPointerUp(3, 1.7, -0.4);
      expect(adb.swipes.last, ('A', 2304, 1440, 2560, 0, 50));
      expect(adb.taps, hasLength(1));
    });

    test('a release of a pointer that never went down on the tile, or '
        'whose press was cancelled or already released, sends nothing', () {
      final tile = RemoteTile(session('A', texture: 101), hub);

      tile.onPointerUp(7, 0.5, 0.5);
      tile.onPointerDown(8, 0.5, 0.5);
      tile.onPointerCancel(8);
      tile.onPointerUp(8, 0.5, 0.5);
      tile.onPointerDown(9, 0.5, 0.5);
      tile.onPointerUp(9, 0.5, 0.5);
      tile.onPointerUp(9, 0.5, 0.5);
      tile.onPointerCancel(10);

      expect(adb.taps, [('A', 1280, 800)], reason: "pointer 9's one tap");
      expect(adb.swipes, isEmpty);
    });

    test('a screen toggle pressed while one is under way does nothing',
        () async {
      final a = session('A', texture: 101);
      adb.panels.add('A');
      final tile = RemoteTile(a, hub);

      a.changingTabletScreen.value = true;
      await tile.onToggleScreen();
      expect(adb.holds, isEmpty);
      expect(a.tabletScreenOff.value, isFalse);

      a.changingTabletScreen.value = false;
      await tile.onToggleScreen();
      expect(adb.holds, ['A']);
      expect(a.tabletScreenOff.value, isTrue);
      await tile.onToggleScreen();
      expect(adb.releases, ['A']);
      expect(a.tabletScreenOff.value, isFalse);
    });

    test("its shape and its name are its own tablet's: the panel that "
        "tablet reported, its model, else its key; 16:10 with no panel at "
        'all', () {
      final a = RemoteTile(session('A', texture: 101, model: 'Tab_A'), hub);
      final b = RemoteTile(session('B', texture: 102), hub);
      expect(a.aspectRatio, closeTo(1.6, 1e-9));
      expect(b.aspectRatio, closeTo(2400 / 1080, 1e-9));
      expect(a.name, 'Tab_A');
      expect(b.name, 'B');
      expect(a.key, 'A');

      // A tablet that never reported one has the last any tablet did.
      final x = RemoteTile(session('X', texture: 109), hub);
      expect(x.aspectRatio, closeTo(2000 / 1500, 1e-9));
      settings.clientPanelHeight.value = 0;
      expect(x.aspectRatio, 16 / 10);
      expect(a.aspectRatio, closeTo(1.6, 1e-9), reason: 'its own, still');
    });
  });

  testWidgets('the grid builds with real textures: one per tablet the Mac '
      'controls', (tester) async {
    final (a, b) = two();
    await open(tester, texture: null);

    expect(tester.takeException(), isNull);
    final textures = tester.widgetList<Texture>(find.byType(Texture));
    expect(textures.map((t) => t.textureId), [101, 102]);
    expect(_tile(a), findsOneWidget);
    expect(_tile(b), findsOneWidget);
  });

  testWidgets("two tablets sit side by side, each picture in its own "
      "tablet's shape, and a click on one is a tap on that tablet alone, in "
      'its own pixels', (tester) async {
    final (a, b) = two();
    await open(tester);

    final boxA = tester.getRect(_texture(101));
    final boxB = tester.getRect(_texture(102));
    expect(boxA.width / boxA.height, closeTo(2560 / 1600, 0.01));
    expect(boxB.width / boxB.height, closeTo(2400 / 1080, 0.01));
    expect(boxA.right, lessThanOrEqualTo(boxB.left), reason: 'side by side');
    expect(boxA.center.dy, closeTo(boxB.center.dy, 0.5));
    // Neither is the shape of the last panel any tablet reported.
    expect(settings.lastClientPanel, _lastPanel);

    await tester.tapAt(boxA.center);
    expect(adb.taps, [('A', 1280, 800)]);
    expect(adb.swipes, isEmpty);

    await tester.tapAt(boxB.topLeft + const Offset(1, 1));
    expect(adb.taps.last.$1, 'B');
    expect(adb.taps, hasLength(2));
    expect(adb.taps.last.$2, lessThan(10));
    expect(adb.taps.last.$3, lessThan(10));
    // The names over them are their own.
    expect(find.text('Tab_A'), findsOneWidget);
    expect(find.text('Tab_B'), findsOneWidget);
    expect(a.nativeId, isNot(b.nativeId));
  });

  testWidgets('a drag that starts on one tablet and ends over the other is '
      "a swipe on the first, to its picture's edge; the other hears "
      'nothing', (tester) async {
    two();
    await open(tester);
    final boxA = tester.getRect(_texture(101));
    final boxB = tester.getRect(_texture(102));

    final gesture =
        await tester.startGesture(boxA.center, kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(boxB.center);
    await gesture.up();

    expect(adb.taps, isEmpty);
    expect(adb.swipes, [('A', 1280, 800, 2560, 800, 50)]);
  });

  testWidgets('two pointers down at once keep their own starts, and a '
      'press that is cancelled sends nothing', (tester) async {
    two();
    await open(tester);
    final boxA = tester.getRect(_texture(101));
    final boxB = tester.getRect(_texture(102));

    final cancelled = await tester.startGesture(boxA.center);
    await cancelled.moveBy(const Offset(120, 0));
    await cancelled.cancel();
    expect(adb.taps, isEmpty);
    expect(adb.swipes, isEmpty);

    // One finger on each tablet, lifted the other way round.
    final onA = await tester.startGesture(boxA.center, pointer: 21);
    final onB = await tester.startGesture(boxB.center, pointer: 22);
    await onA.moveBy(Offset(0, boxA.height / 4));
    await onA.up();
    await onB.up();
    expect(adb.swipes, [('A', 1280, 800, 1280, 1200, 50)]);
    expect(adb.taps, [('B', 1200, 540)]);
  });

  testWidgets("a tablet's screen toggle appears with its own picture, turns "
      'off that tablet alone, and a panel that came back on by itself '
      'clears only its own', (tester) async {
    final a = session('A', texture: 101)..tabletStreaming.value = false;
    final b = session('B', texture: 102);
    adb.panels.addAll(['A', 'B']);
    await open(tester);

    expect(_key('tile/A/screen'), findsNothing,
        reason: "A's user has not approved the capture yet");
    expect(_key('tile/B/screen'), findsOneWidget);
    // And A says so, while B shows its picture with nothing over it.
    expect(
        find.descendant(
            of: _tile(a), matching: find.textContaining('Waiting for')),
        findsOneWidget);
    expect(
        find.descendant(
            of: _tile(b), matching: find.textContaining('Waiting for')),
        findsNothing);

    a.tabletStreaming.value = true;
    await tester.pump();
    expect(_key('tile/A/screen'), findsOneWidget);
    expect(find.textContaining('Waiting for'), findsNothing);

    await tester.tap(_key('tile/A/screen'));
    await tester.pump();
    await tester.pump();
    expect(adb.holds, ['A']);
    expect(a.tabletScreenOff.value, isTrue);
    expect(b.tabletScreenOff.value, isFalse);
    expect(a.changingTabletScreen.value, isFalse);
    expect(_key('tile/A/screen/on'), findsOneWidget,
        reason: 'the next press would light it');
    expect(_key('tile/B/screen/off'), findsOneWidget);

    await tester.tap(_key('tile/B/screen'));
    await tester.pump();
    await tester.pump();
    expect(adb.holds, ['A', 'B']);
    expect(b.tabletScreenOff.value, isTrue);

    adb.restore('B');
    await tester.pump();
    expect(b.tabletScreenOff.value, isFalse);
    expect(a.tabletScreenOff.value, isTrue);
    expect(_key('tile/B/screen/off'), findsOneWidget);
    expect(_key('tile/A/screen/on'), findsOneWidget);
  });

  testWidgets("a toggle that fails says so, and names the tablet when there "
      'are several', (tester) async {
    final (a, _) = two();
    adb.panels.add('A');
    adb.holdErrors['A'] = 'no helper';
    await open(tester);

    await tester.tap(_key('tile/A/screen'));
    await tester.pump();
    await tester.pump();
    expect(a.tabletScreenOff.value, isFalse);
    expect(find.text("Couldn't turn the tablet's screen off"), findsOneWidget);
    expect(find.text('Tab_A: no helper'), findsOneWidget);
    // Let the snackbar go.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the last Disconnect closes the view even with the failed '
      "toggle's message still up", (tester) async {
    session('A', texture: 101);
    adb.panels.add('A');
    adb.holdErrors['A'] = 'no helper';
    await open(tester);

    await tester.tap(_key('tile/A/screen'));
    await tester.pump();
    await tester.pump();
    // One tablet: the message needs no name.
    expect(find.text('no helper'), findsOneWidget);
    expect(Get.isSnackbarOpen, isTrue);

    await tester.tap(_key('tile/A/disconnect'));
    expect(pops.names, [AppRoutes.remoteHost]);
    expect(hub.stops, [('A', false)]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(Get.currentRoute, AppRoutes.home);
  });

  testWidgets("a tile's Reconnect and Disconnect are its own tablet's: the "
      'other tablet, a tablet the Mac extends onto and the hub as a whole '
      'are left alone', (tester) async {
    final (a, b) = two();
    final c = session('C', choice: _extended);
    await open(tester);

    expect(find.byType(Texture), findsNothing);
    expect(_key('tile/C/disconnect'), findsNothing,
        reason: 'a tablet the Mac extends onto has no tile');
    expect(grid().tiles.map((t) => t.key), ['A', 'B']);

    await tester.tap(_key('tile/B/reconnect'));
    expect(hub.reconnects, ['B']);

    await tester.tap(_key('tile/A/disconnect'));
    expect(hub.stops, [('A', false)],
        reason: 'ended, not stopped: nothing is paused, as before');
    expect(hub.disconnects, 0);
    expect(hub.sessions.keys, ['B', 'C']);
    expect(hub.sessions['C'], same(c));
    expect(pops.names, isEmpty, reason: 'B is still shown');

    await tester.pump();
    expect(_tile(a), findsNothing);
    expect(_tile(b), findsOneWidget);
    expect(Get.currentRoute, AppRoutes.remoteHost);
  });

  testWidgets("the last tile's Disconnect closes the view at once, while "
      "its session's teardown still runs", (tester) async {
    session('A', texture: 101);
    final c = session('C', choice: _extended);
    hub.teardown = Completer<void>();
    await open(tester);

    await tester.tap(_key('tile/A/disconnect'));
    expect(hub.stops, [('A', false)]);
    expect(hub.teardown!.isCompleted, isFalse);
    expect(pops.names, [AppRoutes.remoteHost],
        reason: 'popped in the same step as the press');
    expect(hub.disconnects, 0);
    expect(hub.sessions.values, [c]);

    await settle(tester);
    expect(Get.currentRoute, AppRoutes.home);
    expect(find.text('home'), findsOneWidget);
    hub.teardown!.complete();
    await tester.pump();
    expect(pops.names, hasLength(1));
  });

  testWidgets("with the hub's own way of ending a session: the last tile's "
      'Disconnect closes the view before the teardown, ends that tablet '
      "and its input shell, and leaves the tablet the Mac extends onto",
      (tester) async {
    final a = session('A', texture: 101);
    final c = session('C', choice: _extended);
    hub.real = true;
    await open(tester);

    await tester.tap(_key('tile/A/disconnect'));
    expect(pops.names, [AppRoutes.remoteHost]);
    expect(hub.sessions.values, [c]);
    expect(hub.remoteSessions, isEmpty);

    expect(a.phase.value, ConnectionPhase.streaming,
        reason: 'its teardown has not finished: the view did not wait');
    await settle(tester);
    expect(Get.currentRoute, AppRoutes.home);
    // The teardown closes a real socket service: real time, not the fake
    // clock's.
    await tester.runAsync(() async {
      for (var i = 0;
          i < 200 && a.phase.value != ConnectionPhase.disconnected;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(adb.inputShellsClosed, ['A']);
    expect(a.phase.value, ConnectionPhase.disconnected);
    expect(c.phase.value, ConnectionPhase.streaming);
    expect(hub.disconnects, 0);
    // The other tablet is the hub's to end: it was never connected.
    hub.sessions.clear();
  });

  testWidgets('tablets ended from elsewhere leave an empty view that says '
      'so; nothing closes it but Back', (tester) async {
    two();
    await open(tester);
    expect(_key('grid/back'), findsOneWidget, reason: 'with tiles too');
    expect(find.text('No tablet is being controlled from this Mac'),
        findsNothing);

    hub.sessions.remove('A');
    hub.sessions.remove('B');
    await settle(tester);
    expect(find.text('No tablet is being controlled from this Mac'),
        findsOneWidget);
    expect(_texture(101), findsNothing);
    expect(pops.names, isEmpty);
    expect(Get.currentRoute, AppRoutes.remoteHost);

    await tester.tap(_key('grid/back'));
    expect(pops.names, [AppRoutes.remoteHost]);
    await settle(tester);
    expect(Get.currentRoute, AppRoutes.home);
  });

  testWidgets('opened with nothing to show, the view says so and Back '
      'leaves; a tablet that joins gets its tile', (tester) async {
    session('C', choice: _extended);
    await open(tester);
    expect(find.text('No tablet is being controlled from this Mac'),
        findsOneWidget);
    expect(_key('grid/back'), findsOneWidget);

    final a = session('A', texture: 101);
    await tester.pump();
    expect(_tile(a), findsOneWidget);
    expect(find.text('No tablet is being controlled from this Mac'),
        findsNothing);
  });

  testWidgets('one tablet fills the window under the one bar, as the view '
      'always did: its controls with their labels, nothing to expand, no '
      'strip', (tester) async {
    final a = session('A', texture: 101, model: 'Tab_A');
    await open(tester, arguments: {'focus': 'A'});

    expect(grid().expanded.value, isNull,
        reason: 'a lone tile is not expanded');
    expect(find.text('Show all'), findsNothing);
    expect(_key('grid/show_all'), findsNothing);
    expect(_key('tile/A/expand'), findsNothing);
    expect(find.byTooltip('Expand'), findsNothing);
    expect(_key('grid/back'), findsOneWidget);
    expect(find.text('Remote Control'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Tablet screen off'), findsOneWidget);
    expect(find.text('0ms'), findsOneWidget);

    // The picture takes the whole window's height, the bar floating on it.
    final box = tester.getRect(_texture(101));
    expect(box.height, closeTo(1000, 0.5));
    expect(box.width / box.height, closeTo(1.6, 0.01));
    expect(box.center.dx, closeTo(800, 0.5));

    await tester.tapAt(box.center);
    expect(adb.taps, [('A', 1280, 800)]);
    a.latencyMs.value = 7;
    await tester.pump();
    expect(find.text('7ms'), findsOneWidget, reason: "the session's own");

    await tester.tap(find.text('Reconnect'));
    expect(hub.reconnects, ['A']);
    expect(hub.disconnects, 0);
  });

  testWidgets("opened for one of two tablets, that one is shown alone with "
      "the other's name in a strip, which switches; Show all brings the "
      'grid back', (tester) async {
    final (a, b) = two();
    await open(tester, arguments: {'focus': 'B'});

    expect(grid().expanded.value, 'B');
    expect(_tile(b), findsOneWidget);
    expect(_tile(a), findsNothing);
    expect(_key('strip/A'), findsOneWidget);
    expect(_key('strip/B'), findsNothing);
    expect(find.text('Show all'), findsOneWidget);
    expect(_key('grid/back'), findsOneWidget);
    expect(_key('tile/B/expand'), findsNothing);
    // At full size its picture is the window's width, in its own shape,
    // and a click on it is still that tablet's.
    final box = tester.getRect(_texture(102));
    expect(box.width, closeTo(1600, 0.5));
    expect(box.width / box.height, closeTo(2400 / 1080, 0.01));
    await tester.tapAt(box.center);
    expect(adb.taps, [('B', 1200, 540)]);

    await tester.tap(_key('strip/A'));
    await tester.pump();
    expect(grid().expanded.value, 'A');
    expect(_tile(a), findsOneWidget);
    expect(_tile(b), findsNothing);
    expect(_key('strip/B'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(grid().expanded.value, isNull);
    expect(_tile(a), findsOneWidget);
    expect(_tile(b), findsOneWidget);
    expect(find.text('Show all'), findsNothing);

    // And a tile's own Expand does the same from the grid.
    await tester.tap(_key('tile/A/expand'));
    await tester.pump();
    expect(grid().expanded.value, 'A');
    expect(_tile(b), findsNothing);
  });

  testWidgets('an expanded tile goes back to the grid when its tablet '
      'goes, or when only one is left; a key that is no tile expands '
      'nothing', (tester) async {
    two();
    session('C', texture: 103, model: 'Tab_C');
    await open(tester, arguments: {'focus': 'NOBODY'});
    expect(grid().expanded.value, isNull);
    expect(find.byType(ColoredBox).evaluate().length, greaterThanOrEqualTo(3));

    grid().expand('B');
    await tester.pump();
    expect(_key('strip/A'), findsOneWidget);
    expect(_key('strip/C'), findsOneWidget);

    // Another tablet goes: B stays expanded.
    hub.sessions.remove('A');
    await tester.pump();
    expect(grid().expanded.value, 'B');
    expect(_key('strip/A'), findsNothing);
    expect(_key('strip/C'), findsOneWidget);

    // Down to one: it fills the window as a lone tile does.
    hub.sessions.remove('C');
    await tester.pump();
    expect(grid().expanded.value, isNull);
    expect(find.text('Show all'), findsNothing);
    expect(_texture(102), findsOneWidget);

    // Its own tablet going clears it too.
    session('A', texture: 101);
    await tester.pump();
    grid().expand('A');
    await tester.pump();
    expect(grid().expanded.value, 'A');
    hub.sessions.remove('A');
    await tester.pump();
    expect(grid().expanded.value, isNull);
  });

  testWidgets('three tablets take a 2×2 grid, the fourth place empty',
      (tester) async {
    two();
    session('C', texture: 103);
    await open(tester);

    final a = tester.getRect(_texture(101));
    final b = tester.getRect(_texture(102));
    final c = tester.getRect(_texture(103));
    expect(a.center.dx, lessThan(800));
    expect(b.center.dx, greaterThan(800));
    expect(c.center.dx, lessThan(800), reason: 'under A, at half the width');
    expect(c.center.dy, greaterThan(a.center.dy));
    expect(c.width, lessThanOrEqualTo(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('four tablets fit a small window with nothing cut off',
      (tester) async {
    two();
    session('C', texture: 103, model: 'A_rather_long_tablet_model_name');
    session('D', texture: 104, model: 'Another_long_tablet_model_name');
    await open(tester, window: const Size(800, 600));

    expect(tester.takeException(), isNull);
    for (final key in ['A', 'B', 'C', 'D']) {
      expect(_key('tile/$key/disconnect'), findsOneWidget);
      expect(_key('tile/$key/expand'), findsOneWidget);
      expect(_key('tile/$key/screen'), findsOneWidget);
    }
  });

  testWidgets('in a short window the tiles still say they are waiting for '
      'the tablet, smaller: three in the 2×2 grid, five in the scrolling '
      'one', (tester) async {
    final (a, b) = two();
    final c = session('C', texture: 103);
    for (final s in [a, b, c]) {
      s.tabletStreaming.value = false;
    }
    await open(tester, window: const Size(800, 420));

    expect(tester.takeException(), isNull);
    for (final s in [a, b, c]) {
      final text = find.descendant(
          of: _tile(s), matching: find.textContaining('Waiting for'));
      expect(text, findsOneWidget);
      // Inside its own tile, whole.
      final tile = tester.getRect(_tile(s));
      final box = tester.getRect(text);
      expect(tile.contains(box.topLeft), isTrue);
      expect(tile.contains(box.bottomRight), isTrue);
    }

    for (final key in ['D', 'E']) {
      session(key, texture: 104).tabletStreaming.value = false;
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(grid().gridScroll.hasClients, isTrue);
    expect(
        find.descendant(
            of: _tile(a), matching: find.textContaining('Waiting for')),
        findsOneWidget);

    // Drawn smaller here; with room for it the box is its usual size,
    // neither reduced nor enlarged.
    final spinner = find.descendant(
        of: _tile(a), matching: find.byType(CircularProgressIndicator));
    expect(tester.getRect(spinner).height, lessThan(40));
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    expect(tester.getRect(spinner).size, const Size(40, 40));
  });

  testWidgets('a tall tile narrower than its waiting text wraps the text '
      'at full size: the box is drawn smaller only where it is too tall',
      (tester) async {
    final (a, b) = two();
    for (final s in [a, b]) {
      s.tabletStreaming.value = false;
    }
    // Two tiles side by side, about 500 wide each and far taller than
    // the box: the text does not fit one line there.
    await open(tester, window: const Size(1000, 1000));

    expect(tester.takeException(), isNull);
    for (final s in [a, b]) {
      final tile = tester.getRect(_tile(s));
      final text = find.descendant(
          of: _tile(s), matching: find.textContaining('Waiting for'));
      final spinner = find.descendant(
          of: _tile(s), matching: find.byType(CircularProgressIndicator));
      expect(tester.getRect(spinner).size, const Size(40, 40),
          reason: 'not scaled down to keep the text on one line');
      final box = tester.getRect(text);
      expect(tile.contains(box.topLeft), isTrue);
      expect(tile.contains(box.bottomRight), isTrue);
      // On more than one line.
      final style = tester.widget<Text>(text).style!;
      expect(box.height, greaterThan(style.fontSize! * 2));
    }
  });

  testWidgets("in a narrow window a tile's controls shrink to fit its bar, "
      'and still work: two tiles, one expanded, one alone', (tester) async {
    final (a, b) = two();
    await open(tester, window: const Size(480, 400));

    expect(tester.takeException(), isNull);
    for (final key in ['A', 'B']) {
      for (final control in ['screen', 'reconnect', 'disconnect', 'expand']) {
        final rect = tester.getRect(_key('tile/$key/$control'));
        final tile = tester.getRect(_tile(key == 'A' ? a : b));
        expect(rect.left, greaterThanOrEqualTo(tile.left),
            reason: '$key/$control');
        expect(rect.right, lessThanOrEqualTo(tile.right),
            reason: '$key/$control');
      }
    }
    await tester.tap(_key('tile/B/reconnect'));
    expect(hub.reconnects, ['B']);

    // One expanded: its bar carries the labels. (Wider, because the
    // view's own bar, with Back, its title and Show all, does not shrink,
    // and the test font is about twice as wide as the app's.)
    tester.view.physicalSize = const Size(640, 400);
    grid().expand('A');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.getRect(_key('tile/A/disconnect')).right,
        lessThanOrEqualTo(640));
    await tester.tap(_key('tile/A/reconnect'));
    expect(hub.reconnects, ['B', 'A']);

    // One alone, its controls in the view's own bar.
    tester.view.physicalSize = const Size(480, 400);
    hub.sessions.remove('B');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_key('grid/show_all'), findsNothing);
    expect(tester.getRect(_key('tile/A/disconnect')).right,
        lessThanOrEqualTo(480));
    await tester.tap(_key('tile/A/disconnect'));
    expect(hub.stops, [('A', false)]);
  });

  testWidgets('five tablets scroll, but never by a press or a drag on a '
      "tile, which is that tablet's swipe: only the wheel and the scrollbar "
      'move the grid', (tester) async {
    two();
    for (final (i, key) in ['C', 'D', 'E'].indexed) {
      session(key, texture: 103 + i);
    }
    await open(tester);
    final scroll = grid().gridScroll;
    expect(scroll.hasClients, isTrue);
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(_texture(101), findsOneWidget);
    final boxA = tester.getRect(_texture(101));

    // A mouse drag up the tile, far enough to scroll anything that would.
    final mouse =
        await tester.startGesture(boxA.center, kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveBy(const Offset(0, -80));
    await mouse.moveBy(const Offset(0, -80));
    await mouse.up();
    await tester.pump();
    expect(scroll.offset, 0);
    expect(adb.swipes, hasLength(1));
    expect(adb.swipes.single.$1, 'A');
    expect(adb.taps, isEmpty);

    // A finger's drag (a touch screen, a stylus): the same.
    await tester.dragFrom(boxA.center, const Offset(0, -150));
    await tester.pump();
    expect(scroll.offset, 0);
    expect(adb.swipes, hasLength(2));
    expect(adb.swipes.last.$1, 'A');

    // The wheel, over a tile.
    final wheel = TestPointer(40, PointerDeviceKind.mouse)
      ..hover(boxA.center);
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(scroll.offset, closeTo(120, 0.5));
    expect(adb.swipes, hasLength(2), reason: 'a wheel turn is no swipe');
    expect(adb.taps, isEmpty);

    // A trackpad's two-finger scroll, which is no press either.
    final trackpad =
        await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await trackpad.panZoomStart(boxA.center);
    await trackpad.panZoomUpdate(boxA.center, pan: const Offset(0, -60));
    await trackpad.panZoomEnd();
    await tester.pump();
    expect(scroll.offset, greaterThan(120));
    expect(adb.swipes, hasLength(2));
    expect(adb.taps, isEmpty);

    // The scrollbar's thumb, dragged.
    final view = tester.getRect(find.byType(GridView));
    final before = scroll.offset;
    final thumb = await tester.startGesture(
        Offset(view.right - 4, view.top + view.height / 2));
    await thumb.moveBy(const Offset(0, 60));
    await tester.pump();
    await thumb.up();
    await tester.pump();
    expect(scroll.offset, greaterThan(before));
    expect(adb.swipes, hasLength(2));
    expect(adb.taps, isEmpty);
  });

  testWidgets('a tablet whose link is down says it is reconnecting, on its '
      'own tile; what its session noticed is said there too, translated',
      (tester) async {
    final (a, b) = two();
    await open(tester);
    expect(find.text('Reconnecting…'), findsNothing);
    final centre = tester.getRect(_texture(101)).center;
    // A press that is down on the picture as the link goes.
    final held = await tester.startGesture(centre);

    // As a lost link leaves it: no decoder, no picture, waiting to retry.
    a
      ..remoteTextureId.value = null
      ..tabletStreaming.value = false
      ..phase.value = ConnectionPhase.error;
    b.notice.value = 'error_remote_decoder';
    await tester.pump();

    // That press still comes up as its tap (through adb, which the lost
    // link does not stop), so no pointer is left down on the tile.
    await held.up();
    expect(adb.taps, [('A', 1280, 800)]);
    // With no picture there is nothing to click on: a tile takes the
    // pointer only over its texture.
    expect(_texture(101), findsNothing);
    await tester.tapAt(centre);
    await tester.dragFrom(centre, const Offset(60, 0));
    expect(adb.taps, hasLength(1));
    expect(adb.swipes, isEmpty);

    expect(
        find.descendant(of: _tile(a), matching: find.text('Reconnecting…')),
        findsOneWidget);
    expect(
        find.descendant(of: _tile(b), matching: find.text('Reconnecting…')),
        findsNothing);
    expect(_key('tile/A/screen'), findsNothing);
    expect(_key('tile/A/reconnect'), findsOneWidget);
    expect(_key('tile/A/disconnect'), findsOneWidget);
    expect(
        find.descendant(
            of: _tile(b),
            matching:
                find.text("This Mac couldn't decode this tablet's screen")),
        findsOneWidget);
    expect(find.textContaining('Waiting for'), findsNothing);

    // Connecting again: still nothing to click on until the next attempt
    // has made its decoder.
    a.phase.value = ConnectionPhase.configuring;
    await tester.pump();
    expect(find.text('Reconnecting…'), findsOneWidget);
    await tester.tapAt(centre);
    expect(adb.taps, hasLength(1));
    // The decoder is there while the link is still coming up: from here
    // the pointer reaches the tablet, its taps going through adb.
    a.remoteTextureId.value = 101;
    await tester.pump();
    expect(find.text('Reconnecting…'), findsOneWidget);
    await tester.tapAt(tester.getRect(_texture(101)).center);
    expect(adb.taps, [('A', 1280, 800), ('A', 1280, 800)]);

    // Live, its picture not arriving yet: the tile follows.
    a.phase.value = ConnectionPhase.streaming;
    await tester.pump();
    expect(find.text('Reconnecting…'), findsNothing);
    expect(
        find.descendant(
            of: _tile(a), matching: find.textContaining('Waiting for')),
        findsOneWidget,
        reason: 'the decoder is there, the picture not yet');
    await tester.tapAt(tester.getRect(_texture(101)).center);
    expect(adb.taps, hasLength(3));
    expect(adb.swipes, isEmpty);
  });

  testWidgets("a tablet whose decoder this Mac could not make says that and "
      "no more: it is not said to be waiting for the tablet; and what a "
      "session noticed, said over a picture, never takes the pointer",
      (tester) async {
    final (a, b) = two();
    await open(tester);
    const notice = "This Mac couldn't decode this tablet's screen";

    // As a start that got no decoder leaves a live session: no texture, no
    // picture, and the notice.
    b
      ..remoteTextureId.value = null
      ..tabletStreaming.value = false
      ..notice.value = 'error_remote_decoder';
    // And a decoder that failed with its picture still up.
    a.notice.value = 'error_remote_decoder';
    await tester.pump();

    expect(find.descendant(of: _tile(b), matching: find.text(notice)),
        findsOneWidget);
    expect(
        find.descendant(
            of: _tile(b), matching: find.textContaining('Waiting for')),
        findsNothing,
        reason: 'the fault is on the Mac: nothing to do on the tablet');
    expect(find.text('Reconnecting…'), findsNothing);
    expect(_texture(102), findsNothing);

    // A's picture is still there under its notice, and still takes the
    // Mac's pointer.
    expect(find.descendant(of: _tile(a), matching: find.text(notice)),
        findsOneWidget);
    await tester.tapAt(tester.getRect(_texture(101)).center);
    expect(adb.taps, [('A', 1280, 800)]);
    await tester.dragFrom(
        tester.getRect(_texture(101)).center, const Offset(60, 0));
    expect(adb.swipes, hasLength(1));
  });

  testWidgets('a new session for the same tablet is a new tile, and the '
      "old tile's Disconnect and Reconnect cannot reach it", (tester) async {
    final (a, _) = two();
    await open(tester);
    final old = grid().tiles.first;
    expect(old.session, same(a));

    final again = session('A', texture: 111);
    await tester.pump();
    expect(_tile(a), findsNothing);
    expect(_tile(again), findsOneWidget);
    expect(_texture(111), findsOneWidget);
    expect(grid().tiles.first, isNot(same(old)));
    expect(grid().tiles.first.session, same(again));
    expect(grid().tiles.last.key, 'B', reason: 'B keeps its tile');

    old.onDisconnect();
    expect(hub.stops, isEmpty);
    expect(hub.sessions['A'], same(again));
    old.onReconnect();
    expect(hub.reconnects, isEmpty);
    // The new tile's own still do.
    grid().tiles.first.onReconnect();
    expect(hub.reconnects, ['A']);
  });

  testWidgets('one tablet alone: a press held on its Disconnect or its '
      'Reconnect while a new session takes its place does nothing to the '
      'new one', (tester) async {
    final a = session('A', texture: 101);
    await open(tester);

    for (final control in ['disconnect', 'reconnect']) {
      final press =
          await tester.startGesture(tester.getCenter(_key('tile/A/$control')));
      final again = session('A', texture: 111);
      await tester.pump();
      expect(_tile(a), findsNothing);
      expect(_tile(again), findsOneWidget);
      await press.up();
      await tester.pump();
      expect(hub.stops, isEmpty, reason: control);
      expect(hub.reconnects, isEmpty, reason: control);
      expect(hub.sessions['A'], same(again));
      expect(pops.names, isEmpty);
    }

    // The buttons that took their place are the new session's.
    await tester.tap(_key('tile/A/reconnect'));
    expect(hub.reconnects, ['A']);
    await tester.tap(_key('tile/A/disconnect'));
    expect(hub.stops, [('A', false)]);
  });

  testWidgets('in Thai', (tester) async {
    two();
    await open(tester,
        arguments: {'focus': 'A'}, locale: const Locale('th'));
    expect(find.text('แสดงทั้งหมด'), findsOneWidget);
    grid().showAll();
    await tester.pump();
    expect(find.byTooltip('ขยาย'), findsNWidgets(2));

    hub.sessions['A']!.phase.value = ConnectionPhase.error;
    await tester.pump();
    expect(find.text('กำลังเชื่อมต่อใหม่…'), findsOneWidget);
    hub.sessions.clear();
    await tester.pump();
    expect(find.text('ไม่มีแท็บเล็ตที่ควบคุมจาก Mac นี้'), findsOneWidget);
  });
}
