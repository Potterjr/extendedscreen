import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/shared/connection/client_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
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
  final _packets = StreamController<Packet>.broadcast();

  @override
  Stream<Packet> get packetStream => _packets.stream;

  @override
  Future<void> connect(String host, int port) async {
    dials++;
    throw const SocketException('Connection refused');
  }

  @override
  Future<void> disconnect() async {}
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
    await tester.pump(const Duration(seconds: 10));
    expect(socket.dials, 4);
  });
}
