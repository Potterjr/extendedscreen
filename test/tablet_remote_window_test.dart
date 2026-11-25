import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/tablet_remote_window.dart';
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

/// A tablet's native remote window (reverse remote), its Dart side
/// ([TabletRemoteWindow]) against hand-made sessions given to the hub
/// (never connected: live as far as their observables go), [SynthAdb]
/// keeping the taps, swipes and screen holds, the decoders stood in for,
/// and for the window's life a mocked `extended_screen/remote_window`
/// channel.

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

/// The Mac's hub, with what the window asks of it recorded. Ending a
/// session takes it out of [sessions] at once, as the hub does.
class _Hub extends HostConnectionManager {
  _Hub(AdbService adb)
    : super(socket: SocketService(), adb: adb, devicePollInterval: null);

  final stops = <(String, bool)>[];
  final reconnects = <String>[];

  @override
  Future<void> disconnectSession(String key, {bool userStopped = false}) {
    stops.add((key, userStopped));
    sessions.remove(key);
    return Future<void>.value();
  }

  @override
  Future<void> reconnectSession(String key) async => reconnects.add(key);

  @override
  Future<void> autoConnect() async {}
}

class _Input extends InputInjectChannel {
  @override
  Future<void> setKeepCursor(bool enabled) async {}
  @override
  Future<void> releaseAll({required int session}) async {}
}

const _reverse = SessionChoice(
  SessionMode.remoteControl,
  RemoteDirection.macControlsTab,
);
const _extended = SessionChoice(SessionMode.extendedScreen);

const _panelA = ClientPanel(2560, 1600, 60);
const _panelB = ClientPanel(2400, 1080, 60);

/// A picture box of 800×500 points.
const _boxW = 800.0;
const _boxH = 500.0;

RemotePointer _p(
  RemotePointerKind kind,
  double nx,
  double ny, {
  String id = 'A',
}) => RemotePointer(
  id: id,
  kind: kind,
  x: nx * _boxW,
  y: ny * _boxH,
  boxW: _boxW,
  boxH: _boxH,
);

/// The toolbar item [id] of [vm], as Swift receives it; null with none.
Map<String, Object?>? _item(RemoteViewModel? vm, String id) {
  final item = vm?.item(id);
  return item?.toMap();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(RemoteWindowChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late SettingsService settings;
  late SynthAdb adb;
  late _Hub hub;
  late RecordingRemoteVideo video;
  late List<MethodCall> calls;
  late Set<String> swiftWindows;

  setUp(() async {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = const Locale('en');
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
    await settings.setClientPanelFor('A', _panelA);
    await settings.setClientPanelFor('B', _panelB);
    Get.put<InputInjectChannel>(_Input());
    video =
        Get.put<RemoteVideoChannel>(RecordingRemoteVideo())
            as RecordingRemoteVideo;
    adb = SynthAdb(const []);
    Get.put<AdbService>(adb);
    hub = Get.put<BaseConnectionManager>(_Hub(adb)) as _Hub;

    calls = [];
    swiftWindows = {};
    // Plays RemoteWindowPlugin: a window per id.
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final id = (call.arguments as Map)['id'] as String;
      switch (call.method) {
        case 'open':
          swiftWindows.add(id);
          return true;
        case 'focus':
          return swiftWindows.contains(id);
        case 'close':
          return swiftWindows.remove(id);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    Get.clearTranslations();
    Get.locale = null;
    Get.reset();
  });

  /// A session for the tablet [key], made as [choice] and given to the
  /// hub: live, its picture arriving unless [streaming] is false.
  HostSession session(
    String key, {
    SessionChoice choice = _reverse,
    bool streaming = true,
    String? model,
  }) {
    final s =
        HostSession(
            key: key,
            link: LinkType.usb,
            serial: key,
            choice: choice,
            pipeline: hub.pipeline,
            adb: adb,
            socket: SocketService(),
          )
          ..activeDevice.value = DeviceModel(
            serial: key,
            model: model,
            status: DeviceStatus.connected,
          )
          ..phase.value = ConnectionPhase.streaming
          ..tabletStreaming.value = streaming;
    hub.adopt(s);
    return s;
  }

  /// Swift → Dart: [method] with [args], as the plugin sends it.
  Future<void> fromSwift(String method, Map<String, Object?> args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await messenger.handlePlatformMessage(
      RemoteWindowChannel.channelName,
      data,
      (_) {},
    );
  }

  Object? tokenOf(String id) => calls
      .lastWhere((c) => c.method == 'open' && (c.arguments as Map)['id'] == id)
      .arguments['token'];

  /// Lets the render microtask and any close that follows run.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// [key]'s window, opened through the channel as the app opens it.
  Future<(TabletRemoteWindow, RemoteWindowChannel)> open(
    String key, {
    Duration failureFor = const Duration(seconds: 4),
  }) async {
    final windows = RemoteWindowChannel(channel: channel);
    final w = TabletRemoteWindow(key, failureFor: failureFor);
    expect(await windows.openDriver(w), isTrue);
    await settle();
    return (w, windows);
  }

  group('shape', () {
    test("a tablet window is keyed by the session's key, titled with its "
        "model (else its key), locked to its own panel and opens as kind "
        'tablet with the tablet symbol', () async {
      session('A', model: 'Tab_A');
      session('B');
      final (a, _) = await open('A');
      final (b, _) = await open('B');
      expect(a.kind, 'tablet');
      expect(RemoteWindowChannel.singleKinds, isNot(contains('tablet')));
      expect(a.title, 'Tab_A');
      expect(b.title, 'B');
      expect(a.frameSize, const Size(2560, 1600));
      expect(b.frameSize, const Size(2400, 1080));
      final openA = calls.firstWhere((c) => c.method == 'open').arguments;
      expect(openA['kind'], 'tablet');
      expect(openA['title'], 'Tab_A');
      expect(openA['frame'], [2560.0, 1600.0]);
      expect(a.lastRender!.toMap()['symbol'], 'ipad.landscape');
      expect(a.lastRender!.title, 'Tab_A');
      // Both open at once.
      expect(swiftWindows, {'A', 'B'});
      final renders = calls.where((c) => c.method == 'render').toList();
      expect(renders.map((c) => c.arguments['id']).toSet(), {'A', 'B'});
    });

    test('starting replays the last picture of the session it shows', () async {
      final a = session('A');
      await open('A');
      expect(video.replayed, [a.nativeId]);
    });
  });

  group('pointer', () {
    test('a release within the threshold of its press is a tap where it '
        'came up, at the threshold a swipe from the press; both '
        'normalised by the picture box and clamped to it', () async {
      session('A');
      final (w, _) = await open('A');

      w.pointer(_p(RemotePointerKind.down, 0.25, 0.5));
      w.pointer(_p(RemotePointerKind.move, 0.6, 0.9));
      w.pointer(_p(RemotePointerKind.up, 0.25 + 0.011, 0.5));
      expect(adb.taps, [('A', (0.261 * 2560).round(), 800)]);
      expect(adb.swipes, isEmpty);

      w.pointer(_p(RemotePointerKind.down, 0.25, 0.5));
      w.pointer(_p(RemotePointerKind.up, 0.25, 0.5 + 0.0125));
      expect(adb.swipes, [('A', 640, 800, 640, (0.5125 * 1600).round(), 50)]);

      // Released outside the picture: taken to its nearest edge.
      w.pointer(_p(RemotePointerKind.down, 0.9, 0.9));
      w.pointer(_p(RemotePointerKind.up, 1.7, -0.4));
      expect(adb.swipes.last, ('A', 2304, 1440, 2560, 0, 50));
      // A press outside it too.
      w.pointer(_p(RemotePointerKind.down, -0.5, 2));
      w.pointer(_p(RemotePointerKind.up, -0.1, 1.01));
      expect(adb.taps.last, ('A', 0, 1600));
      expect(adb.taps, hasLength(2));
      expect(adb.swipes, hasLength(2));
    });

    test(
      'a cancelled press, or a release with no press, sends nothing',
      () async {
        session('A');
        final (w, _) = await open('A');

        w.pointer(_p(RemotePointerKind.up, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.down, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.cancel, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.up, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.down, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.up, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.up, 0.5, 0.5));
        w.pointer(_p(RemotePointerKind.cancel, 0.5, 0.5));

        expect(adb.taps, [('A', 1280, 800)], reason: 'the one press');
        expect(adb.swipes, isEmpty);
      },
    );

    test('input goes only to a session the Mac controls that the hub has not '
        'retired', () async {
      final a = session('A');
      final w = TabletRemoteWindow('A');
      a.retire();
      w.pointer(_p(RemotePointerKind.down, 0.5, 0.5));
      w.pointer(_p(RemotePointerKind.up, 0.5, 0.5));

      session('B', choice: _extended);
      final b = TabletRemoteWindow('B');
      b.pointer(_p(RemotePointerKind.down, 0.5, 0.5, id: 'B'));
      b.pointer(_p(RemotePointerKind.up, 0.5, 0.5, id: 'B'));

      expect(adb.taps, isEmpty);
      expect(adb.swipes, isEmpty);
      await w.dispose();
      await b.dispose();
    });
  });

  group('screen toggle', () {
    test('it shows once the picture has come, says what a press would do, '
        'and is disabled while a change is under way, when a press does '
        'nothing', () async {
      final a = session('A', streaming: false);
      adb.panels.add('A');
      final (w, _) = await open('A');
      expect(_item(w.lastRender, 'screen'), isNull);
      expect(w.lastRender!.message!.text, startsWith('Waiting for'));

      a.tabletStreaming.value = true;
      await settle();
      expect(w.lastRender!.message, isNull);
      final off = _item(w.lastRender, 'screen')!;
      expect(off['enabled'], isTrue);
      expect(off['tooltip'], startsWith('Tablet screen off\n'));
      expect(off['tooltip'], endsWith('remote_tablet_screen_hint'.tr));

      a.changingTabletScreen.value = true;
      await settle();
      expect(_item(w.lastRender, 'screen')!['enabled'], isFalse);
      w.action('screen');
      await settle();
      expect(adb.holds, isEmpty);

      a.changingTabletScreen.value = false;
      w.action('screen');
      await settle();
      expect(adb.holds, ['A']);
      expect(a.tabletScreenOff.value, isTrue);
      expect(
        _item(w.lastRender, 'screen')!['tooltip'],
        startsWith('Tablet screen on\n'),
      );

      w.action('screen');
      await settle();
      expect(adb.releases, ['A']);
      expect(a.tabletScreenOff.value, isFalse);
    });

    test('a toggle that fails says so in the banner for a while, naming the '
        'tablet when there are several', () async {
      final a = session('A', model: 'Tab_A');
      adb.panels.add('A');
      adb.holdErrors['A'] = 'no helper';
      final (w, _) = await open(
        'A',
        failureFor: const Duration(milliseconds: 50),
      );

      w.action('screen');
      await settle();
      expect(a.tabletScreenOff.value, isFalse);
      expect(
        w.lastRender!.banner,
        "Couldn't turn the tablet's screen off: "
        'no helper',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(w.lastRender!.banner, isNull);

      session('B', model: 'Tab_B');
      w.action('screen');
      await settle();
      expect(
        w.lastRender!.banner,
        "Couldn't turn the tablet's screen off: "
        'Tab_A: no helper',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(w.lastRender!.banner, isNull);
    });
  });

  test("Reconnect restarts the tablet's own session; one for a session no "
      'longer shown does nothing', () async {
    session('A');
    session('B');
    final (w, _) = await open('A');
    w.action('reconnect');
    expect(hub.reconnects, ['A']);

    // A new session took the key: not this window's.
    hub.sessions['A'] = session('A');
    await settle();
    w.action('reconnect');
    expect(hub.reconnects, ['A']);
  });

  group('closing', () {
    test(
      "closing the window ends the tablet's session as the user's stop",
      () async {
        session('A');
        session('B');
        await open('A');
        swiftWindows.remove('A');
        await fromSwift('closed', {'id': 'A', 'token': tokenOf('A')});
        await settle();
        expect(hub.stops, [('A', true)]);
        expect(hub.sessions.keys, ['B']);
      },
    );

    test(
      'Disconnect ends it once as the user\'s stop and closes the window',
      () async {
        session('A');
        final (_, windows) = await open('A');
        windows.driverOf('A')!.action('disconnect');
        await settle();
        expect(hub.stops, [('A', true)]);
        expect(calls.last.method, 'close');
        expect(windows.isOpen('A'), isFalse);
        await fromSwift('closed', {'id': 'A', 'token': tokenOf('A')});
        await settle();
        expect(hub.stops, [('A', true)]);
      },
    );

    test(
      'closing after a new session took the key leaves the new one alone',
      () async {
        final old = session('A');
        final (w, windows) = await open('A');
        // The new session is put in place of the old in one step (a cap-1
        // replace, seen only once it is done).
        final fresh = HostSession(
          key: 'A',
          link: LinkType.usb,
          serial: 'A',
          choice: _reverse,
          pipeline: hub.pipeline,
          adb: adb,
          socket: SocketService(),
        )..phase.value = ConnectionPhase.streaming;
        expect(fresh.nativeId, isNot(old.nativeId));
        // Closed by the user before the driver heard of the change.
        swiftWindows.remove('A');
        hub.sessions['A'] = fresh;
        await fromSwift('closed', {'id': 'A', 'token': tokenOf('A')});
        await settle();
        expect(hub.stops, isEmpty);
        expect(hub.sessions['A'], same(fresh));
        expect(windows.isOpen('A'), isFalse);
        expect(w.session, isNull);
      },
    );

    test('a driver disposed with no close of its own ends only the session '
        'it recorded: none once another session holds the key', () async {
      session('A');
      final shown = TabletRemoteWindow('A');
      await shown.dispose();
      await shown.dispose();
      expect(hub.stops, [('A', true)], reason: 'once');

      final old = session('A');
      final stale = TabletRemoteWindow('A');
      expect(stale.shownNativeId, old.nativeId);
      session('A');
      await stale.dispose();
      expect(hub.stops, [('A', true)]);
    });

    test('a session ended elsewhere closes the window, with no second '
        'disconnect', () async {
      session('A');
      final (_, windows) = await open('A');
      // A card's Disconnect, a hub disconnect, a cap-1 replace.
      hub.sessions.remove('A');
      await settle();
      expect(calls.last.method, 'close');
      expect(calls.last.arguments, {'id': 'A'});
      expect(windows.isOpen('A'), isFalse);
      await fromSwift('closed', {'id': 'A', 'token': tokenOf('A')});
      await settle();
      expect(hub.stops, isEmpty);
    });

    test('a session in error keeps its window and says it is reconnecting '
        'over the last picture', () async {
      final a = session('A');
      final (w, windows) = await open('A');
      a
        ..tabletStreaming.value = false
        ..phase.value = ConnectionPhase.error;
      await settle();
      expect(windows.isOpen('A'), isTrue);
      expect(calls.where((c) => c.method == 'close'), isEmpty);
      final message = w.lastRender!.message!;
      expect(message.text, 'Reconnecting…');
      expect(message.passThrough, isTrue);
      expect(_item(w.lastRender, 'screen'), isNull);
      expect(_item(w.lastRender, 'reconnect'), isNotNull);
      expect(_item(w.lastRender, 'disconnect'), isNotNull);

      a.phase.value = ConnectionPhase.streaming;
      await settle();
      expect(w.lastRender!.message!.text, startsWith('Waiting for'));
      a.tabletStreaming.value = true;
      await settle();
      expect(w.lastRender!.message, isNull);
    });

    test("a decoder the Mac could not make is said in the banner, and the "
        'window does not wait for the tablet', () async {
      final a = session('A', streaming: false);
      final (w, _) = await open('A');
      a.notice.value = 'error_remote_decoder';
      await settle();
      expect(
        w.lastRender!.banner,
        "This Mac couldn't decode this tablet's screen",
      );
      expect(w.lastRender!.message, isNull);
    });
  });

  test('the latency chip follows the session, and an equal snapshot is not '
      'sent again', () async {
    final a = session('A');
    final (w, _) = await open('A');
    int renders() => calls.where((c) => c.method == 'render').length;
    final before = renders();
    a.latencyMs.value = 12;
    await settle();
    expect(_item(w.lastRender, 'latency')!['text'], '12 ms');
    expect(renders(), before + 1);
    a.latencyMs.value = 12;
    a.notice.value = null;
    await settle();
    expect(renders(), before + 1);
  });

  test('in Thai', () async {
    final a = session('A', streaming: false);
    final (w, _) = await open('A');
    expect(w.lastRender!.message!.text, startsWith('Waiting for'));

    // What SettingsService.setLocale does, without Get.updateLocale.
    Get.locale = const Locale('th');
    settings.localeCode.value = 'th';
    await settle();
    expect(w.lastRender!.message!.text, startsWith('กำลังรอแท็บเล็ต'));
    expect(_item(w.lastRender, 'reconnect')!['tooltip'], 'เชื่อมต่อใหม่');
    expect(_item(w.lastRender, 'disconnect')!['tooltip'], 'ตัดการเชื่อมต่อ');

    a.tabletStreaming.value = true;
    await settle();
    expect(
      _item(w.lastRender, 'screen')!['tooltip'],
      startsWith('ปิดจอแท็บเล็ต\n'),
    );
    a.phase.value = ConnectionPhase.error;
    await settle();
    expect(w.lastRender!.message!.text, 'กำลังเชื่อมต่อใหม่…');
  });
}
