import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/shared/connection/client_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Keeps test output free of the pretty-printed connection log.
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

/// A host that is never there: every dial is refused at once, as when no
/// adb-reverse listener exists on 127.0.0.1:7001.
class _RefusingSocket extends SocketService {
  int dials = 0;
  int closes = 0;
  final _packets = StreamController<Packet>.broadcast();

  @override
  Stream<Packet> get packetStream => _packets.stream;

  @override
  Future<void> connect(String host, int port) async {
    dials++;
    throw const SocketException('Connection refused');
  }

  @override
  Future<void> disconnect() async => closes++;
}

/// A client whose link fails for good, with no retry (as a host session
/// the encoder has no room for does).
class _Client extends ClientConnectionManager {
  _Client({super.ios});

  // ignore: invalid_use_of_protected_member
  Future<void> failForGood() => handleLinkFailure(retry: false);

  /// Plays a session that reached `streaming` (no Mac needed).
  void goLive() => setPhase(ConnectionPhase.streaming);
}

/// Only [ClientConnectionManager.onTeardown] (via disconnect) touches it.
class _IdleCapture extends AndroidCaptureChannel {
  @override
  Future<void> stopCapture() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RefusingSocket socket;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put<LoggerService>(_QuietLogger());
    final settings = SettingsService();
    await settings.init();
    Get.put<SettingsService>(settings);
    socket = _RefusingSocket();
    Get.put<SocketService>(socket);
    // No Mac has handed over a USB session key: the tablet dials all the same.
    Get.put(UsbSessionService());
    Get.put<AndroidCaptureChannel>(_IdleCapture());
  });

  tearDown(Get.reset);

  testWidgets(
      'Connect tapped while a retry is pending fails into a fresh retry '
      'instead of sticking in handshaking', (tester) async {
    final cm = ClientConnectionManager();

    // Splash's autoConnect: the host isn't up, so the dial is refused and a
    // retry is armed (5 s on the client).
    await cm.connect();
    expect(socket.dials, 1);
    expect(cm.phase.value, ConnectionPhase.error);
    expect(cm.retryPending.value, isTrue);
    expect(cm.errorKey.value, 'error_waiting_for_host');

    // The user taps Connect on Home during that wait; it is refused too.
    await tester.pump(const Duration(seconds: 1));
    expect(socket.dials, 1);
    await cm.connect();
    expect(socket.dials, 2);
    expect(cm.phase.value, ConnectionPhase.error,
        reason: 'the manual attempt\'s failure must be handled, not swallowed');

    // The manual attempt replaced the pending retry rather than adding a
    // second one: nothing dials when the old timer would have fired (t=5 s)...
    await tester.pump(const Duration(milliseconds: 4500));
    expect(socket.dials, 2);

    // ...and its own retry fires 5 s after it failed (t=6 s), and fails back
    // into error with the next retry armed.
    await tester.pump(const Duration(milliseconds: 600));
    expect(socket.dials, 3);
    expect(cm.phase.value, ConnectionPhase.error);

    // Still retrying on the normal cadence.
    await tester.pump(const Duration(seconds: 5));
    expect(socket.dials, 4);
    expect(cm.phase.value, ConnectionPhase.error);

    // Cancel: drops the pending retry so no timer outlives the test.
    await cm.disconnect();
    expect(cm.phase.value, ConnectionPhase.disconnected);
    expect(cm.retryPending.value, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(socket.dials, 4);
  });

  testWidgets(
      'a failure with no retry arms nothing, and the resume rule leaves it '
      'alone until the next connect', (tester) async {
    final cm = _Client();

    await cm.failForGood();
    expect(cm.phase.value, ConnectionPhase.error);
    expect(cm.retryPending.value, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(socket.dials, 0);

    cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(socket.dials, 0, reason: 'nothing comes back by itself');

    // The user's own connect is a fresh start: its failure retries again.
    await cm.connect();
    expect(socket.dials, 1);
    expect(cm.retryPending.value, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(socket.dials, 2);

    await cm.disconnect();
    expect(cm.retryPending.value, isFalse);
  });

  group('iOS lifecycle', () {
    testWidgets('going to the background ends a live link at once with no '
        'retry, and coming back redials at once', (tester) async {
      final cm = _Client(ios: true);
      cm.goLive();

      cm.didChangeAppLifecycleState(AppLifecycleState.inactive);
      cm.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(cm.phase.value, ConnectionPhase.error);
      expect(cm.retryPending.value, isFalse);
      expect(socket.closes, 1, reason: 'the Mac hears it now, not in 6 s');
      cm.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(socket.dials, 0, reason: 'nothing dials from the background');
      expect(socket.closes, 1);

      cm.didChangeAppLifecycleState(AppLifecycleState.hidden);
      cm.didChangeAppLifecycleState(AppLifecycleState.inactive);
      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(socket.dials, 1);
      expect(cm.retryPending.value, isTrue,
          reason: 'back in front, the usual retries');

      await cm.disconnect();
    });

    testWidgets('a retry armed before going away is dropped', (tester) async {
      final cm = _Client(ios: true);
      await cm.connect();
      expect(socket.dials, 1);
      expect(cm.retryPending.value, isTrue);

      cm.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(cm.retryPending.value, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(socket.dials, 1);

      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(socket.dials, 2);

      await cm.disconnect();
    });

    testWidgets('resumed redials whatever the phase reads after a suspension',
        (tester) async {
      final cm = _Client(ios: true);
      cm.goLive();
      // The pause was heard, but the link still reads live (the handler's
      // teardown never ran before iOS suspended the app).
      cm.didChangeAppLifecycleState(AppLifecycleState.hidden);
      cm.goLive();
      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(socket.dials, 1);

      await cm.disconnect();
    });

    testWidgets('Control Centre (inactive and back) leaves a live link alone',
        (tester) async {
      final cm = _Client(ios: true);
      cm.goLive();
      cm.didChangeAppLifecycleState(AppLifecycleState.inactive);
      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(cm.phase.value, ConnectionPhase.streaming);
      expect(socket.closes, 0);
      expect(socket.dials, 0);

      await cm.disconnect();
    });

    testWidgets('a link the user stopped stays stopped', (tester) async {
      final cm = _Client(ios: true);
      await cm.disconnect();
      final closes = socket.closes;
      cm.didChangeAppLifecycleState(AppLifecycleState.paused);
      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 10));
      expect(cm.phase.value, ConnectionPhase.disconnected);
      expect(socket.dials, 0);
      expect(socket.closes, closes);
    });

    testWidgets('Android keeps streaming in the background', (tester) async {
      final cm = _Client(ios: false);
      cm.goLive();
      cm.didChangeAppLifecycleState(AppLifecycleState.hidden);
      cm.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      cm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(cm.phase.value, ConnectionPhase.streaming);
      expect(socket.closes, 0);
      expect(socket.dials, 0);

      await cm.disconnect();
    });
  });
}
