import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// What became of something handed to adb for the tablet's app: a Wi-Fi
/// pairing or a USB session key. The numbers are the broadcast result codes
/// `WifiPairingReceiver.kt` sets.
enum AdbDelivery {
  /// The tablet's app took it.
  stored,

  /// The app got it and would not take it (a pairing: it knows this Mac's id
  /// with another certificate or token; either: it could not read the
  /// payload).
  refused,

  /// Nothing took it: a build without the receiver, the app not running, or
  /// adb failed.
  notDelivered;

  static AdbDelivery fromResultCode(int? code) => switch (code) {
        1 => stored,
        2 => refused,
        _ => notDelivered,
      };
}

class AdbService extends GetxService {
  static const _channel = MethodChannel('extended_screen/adb');
  final _log = Get.find<LoggerService>();

  /// The Android app's receiver for what this Mac hands it through adb (the
  /// manifest's `.plugins.WifiPairingReceiver`, which only the shell may send
  /// to), and its two actions: a Wi-Fi pairing, and a USB session key.
  static const pairingReceiver =
      'com.example.extendedscreen/.plugins.WifiPairingReceiver';
  static const pairingAction = 'com.example.extendedscreen.WIFI_PAIR';
  static const sessionAction = 'com.example.extendedscreen.USB_SESSION';

  /// Reverse remote: a tablet's panel came back on without being asked (its
  /// helper's lease ran out, the cable came out, the helper died). Called
  /// with the device's serial.
  void Function(String serial)? onTabletScreenRestored;

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTabletScreenRestored' && call.arguments is String) {
        onTabletScreenRestored?.call(call.arguments as String);
      }
      return null;
    });
  }

  /// Reverse remote: turns [serial]'s panel off while the tablet keeps
  /// running, so the Mac still sees and drives it: the app's own
  /// `ScreenPower` helper, run by adb with the shell's privileges, until
  /// [releaseTabletScreenOff] (see ScreenPower.kt and AdbManagerPlugin).
  /// Returns null once the panel is off, else what went wrong.
  Future<String?> holdTabletScreenOff({required String serial}) async {
    try {
      final off = await _channel
          .invokeMethod<bool>('holdTabletScreenOff', {'serial': serial});
      return off == true ? null : 'no answer from the tablet';
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  /// Lights [serial]'s panel again. Does nothing if it was not held off.
  Future<void> releaseTabletScreenOff({required String serial}) async {
    try {
      await _channel.invokeMethod('releaseTabletScreenOff', {'serial': serial});
    } catch (e) {
      _log.w('ADB: tablet screen not released: $e');
    }
  }

  /// Returns list of connected ADB devices; empty when adb could not be
  /// asked.
  Future<List<DeviceModel>> listDevices() async =>
      await listDevicesOrNull() ?? [];

  /// The connected ADB devices, or null when adb could not be asked (no
  /// binary, a failed or timed-out `adb devices`): unlike an empty list,
  /// that says nothing about which tablets are attached.
  Future<List<DeviceModel>?> listDevicesOrNull() async {
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('listDevices') ?? [];
      return result.map((d) {
        final map = Map<String, dynamic>.from(d as Map);
        final transport = map['transport'] as String?;
        return DeviceModel(
          serial: map['serial'] as String,
          model: map['model'] as String?,
          product: map['product'] as String?,
          transportId: transport == null || transport.isEmpty ? null : transport,
          status: DeviceStatus.connected,
        );
      }).toList();
    } on PlatformException catch (e) {
      // adb missing, failed or timed out: expected now and then, and asked
      // again by whoever polls.
      _log.w('ADB: devices not listed: ${e.message}');
      return null;
    } catch (e, st) {
      _log.e('ADB listDevices failed', e, st);
      return null;
    }
  }

  /// Sets up reverse port forwarding: Android tcp:remotePort → Mac tcp:localPort.
  Future<bool> reverseForward({
    required String serial,
    required int localPort,
    required int remotePort,
  }) async {
    try {
      await _channel.invokeMethod('reverseForward', {
        'serial': serial,
        'localPort': localPort,
        'remotePort': remotePort,
      });
      _log.i('ADB reverse forward $remotePort → $localPort');
      return true;
    } catch (e, st) {
      _log.e('ADB reverseForward failed', e, st);
      return false;
    }
  }

  /// Removes this app's reverse tunnel from [serial]: the rule for the
  /// tablet-side [remotePort], or every rule on it when that is not given.
  Future<void> removeForward({required String serial, int? remotePort}) async {
    try {
      await _channel.invokeMethod('removeForward', {
        'serial': serial,
        'remotePort': ?remotePort,
      });
    } catch (_) {}
  }

  // ─── Input injection (reverse remote: Mac controls the tablet) ────────────
  // Runs `input …` on the device. Coordinates are device pixels.
  // Fire-and-forget: a dropped tap shouldn't stall the control loop.
  //
  // Taps and swipes go through the tablet's input shell: one long-lived
  // `adb shell` per serial that AdbManagerPlugin opens at the first event
  // and feeds a line per event, in order, so an event costs no new adb
  // process ([closeInputShell] ends it). The plugin gets numbers only and
  // builds the line itself. Key events and text still take one
  // `adb shell input …` each.

  Future<void> inputTap({
    required String serial,
    required int x,
    required int y,
  }) =>
      _inputShell(serial, 'tap', [x, y]);

  Future<void> inputSwipe({
    required String serial,
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int durationMs = 50,
  }) =>
      _inputShell(serial, 'swipe', [x1, y1, x2, y2, durationMs]);

  /// Ends [serial]'s input shell, if it has one: its session is over. The
  /// next tap opens a new one.
  Future<void> closeInputShell({required String serial}) async {
    try {
      await _channel.invokeMethod('closeInputShell', {'serial': serial});
    } catch (e) {
      _log.w('ADB: input shell not closed: $e');
    }
  }

  Future<void> inputKeyevent({required String serial, required int keycode}) =>
      _shellInput(serial, ['keyevent', '$keycode']);

  /// Types literal text on the device (spaces must be escaped as %s for `input`).
  Future<void> inputText({required String serial, required String text}) =>
      _shellInput(serial, ['text', text.replaceAll(' ', '%s')]);

  // ─── Wi-Fi pairing ────────────────────────────────────────────────────────

  /// Hands a Wi-Fi pairing [payload] to this app on the device [serial], and
  /// to nothing else: `am broadcast` names the app's receiver, and the
  /// receiver only accepts the shell as sender. That is the proof the tablet
  /// needs that a pairing came from the Mac on the other end of the cable,
  /// and it keeps the token away from whatever else on the tablet has dialled
  /// the tunnel.
  ///
  /// The command reaches the device's shell on adb's stdin, so the token
  /// never shows up in this Mac's process list.
  Future<AdbDelivery> deliverWifiPairing({
    required String serial,
    required Uint8List payload,
  }) =>
      _broadcast(serial, pairingAction, payload);

  // ─── USB session key ──────────────────────────────────────────────────────

  /// Hands this USB attempt's [key] to this app on the device [serial], the
  /// same way and for the same reason as a Wi-Fi pairing: only the app's
  /// receiver gets it, and the app knows it came from adb. See
  /// [UsbSessionService].
  Future<AdbDelivery> deliverUsbSessionKey({
    required String serial,
    required Uint8List key,
  }) =>
      _broadcast(serial, sessionAction, UsbSessionService.buildDelivery(key));

  Future<AdbDelivery> _broadcast(
      String serial, String action, Uint8List payload) async {
    // base64url: letters, digits, `-`, `_` and `=`, nothing a shell reads.
    final script = "am broadcast -n $pairingReceiver -a $action "
        "--es payload '${base64Url.encode(payload)}'\n";
    try {
      final out = await _channel.invokeMethod<String>('shellScript', {
        'serial': serial,
        'script': script,
      });
      return AdbDelivery.fromResultCode(broadcastResultCode(out ?? ''));
    } catch (e) {
      _log.w('ADB broadcast ($action) failed: $e');
      return AdbDelivery.notDelivered;
    }
  }

  /// The result code in `am broadcast`'s output ("Broadcast completed:
  /// result=1"), or null when it reports none. With no receiver it is 0.
  static int? broadcastResultCode(String output) {
    final match =
        RegExp(r'Broadcast completed: result=(-?\d+)').firstMatch(output);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// One tap or swipe through [serial]'s input shell. Only when the plugin
  /// has no such shell at all (an older build of it) or adb could not take
  /// the event (`ADB_FAILED`) does it go the old way, as one
  /// `adb shell input …`; values the plugin refuses (`BAD_ARGS`: off any
  /// screen, a swipe longer than it allows) are dropped.
  Future<void> _inputShell(
      String serial, String command, List<int> values) async {
    try {
      await _channel.invokeMethod('inputShell', {
        'serial': serial,
        'command': command,
        'values': values,
      });
      return;
    } on MissingPluginException {
      // Fall back below.
    } on PlatformException catch (e) {
      if (e.code != 'ADB_FAILED') {
        _log.w('ADB input dropped ($command $values): ${e.code}');
        return;
      }
    } catch (e) {
      _log.w('ADB input failed: $e');
      return;
    }
    await _shellInput(serial, [command, for (final v in values) '$v']);
  }

  Future<void> _shellInput(String serial, List<String> args) async {
    try {
      await _channel.invokeMethod('shellInput', {
        'serial': serial,
        'args': args,
      });
    } catch (e) {
      _log.w('ADB input failed: $e');
    }
  }
}
