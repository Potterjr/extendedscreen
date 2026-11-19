import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// macOS only — bridges to ScreenCaptureKit + VideoToolbox via Swift plugin.
///
/// Every capture belongs to a session: one per tablet, addressed by the id
/// its connection was given ([HostConnectionManager.nativeId]). Each session
/// has its own virtual display, stream and encoder on the native side, and
/// its encoded frames come back on [framesFor] alone.
class ScreenCaptureChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/screen_capture');
  static const _frames = EventChannel('extended_screen/frames');
  final _log = Get.find<LoggerService>();

  ScreenCaptureChannel() {
    // Native → Dart callbacks: the SCStream dying (error) or the Mac waking from
    // sleep both require rebuilding the capture pipeline. The ADB-reverse
    // socket survives sleep, so nothing else would trigger a restart.
    _channel.setMethodCallHandler(_handleNative);
  }

  /// Wired by [HostConnectionManager] to a capture rebuild. Fired with the
  /// session whose stream stopped with an error, or with null when the host
  /// woke from sleep (every session needs rebuilding then).
  void Function(int? session)? onCaptureRestartNeeded;

  /// Wired by [HostConnectionManager] to refresh the cached display bounds
  /// used for touch-coordinate mapping. Fired when the native side reports the
  /// display arrangement changed (e.g. a virtual display was repositioned in
  /// System Settings, or another session's display came or went) — cheaper
  /// than [onCaptureRestartNeeded] since the capture sessions themselves are
  /// unaffected, only their screen-space positions. Applies to every session.
  void Function()? onDisplayBoundsChanged;

  /// Wired by [HostConnectionManager] so the client learns the new rate (0xFB)
  /// when the "Max" preset's adaptive encoder of [session] steps its frame
  /// rate down or back up.
  void Function(int session, int fps)? onFrameRateChanged;

  Future<dynamic> _handleNative(MethodCall call) async {
    final args = call.arguments;
    final session = args is Map ? args['session'] : null;
    switch (call.method) {
      case 'onStreamStopped':
        _log.w('Native capture stopped (session $session): '
            '${args is Map ? args['error'] : args}');
        onCaptureRestartNeeded?.call(session is int ? session : null);
        break;
      case 'onCaptureNeedsRestart':
        _log.w('Native capture restart requested (wake)');
        onCaptureRestartNeeded?.call(null);
        break;
      case 'onDisplayBoundsChanged':
        onDisplayBoundsChanged?.call();
        break;
      case 'onFrameRateChanged':
        final fps = args is Map ? args['fps'] : null;
        if (session is int && fps is int) {
          _log.w('Adaptive encoder rate (session $session) → $fps fps');
          onFrameRateChanged?.call(session, fps);
        }
        break;
      default:
        break;
    }
    return null;
  }

  /// Every session's encoded frames, each behind its session's id (4 bytes,
  /// big-endian). One stream for the whole app: an EventChannel delivers to
  /// one Dart listener, so a second `receiveBroadcastStream` would steal the
  /// first one's frames.
  late final Stream<Uint8List> _allFrames = _frames
      .receiveBroadcastStream()
      .map((e) => e is Uint8List ? e : Uint8List.fromList(List<int>.from(e)));

  /// The Annex-B frames [session]'s encoder produces, its id taken off.
  Stream<Uint8List> framesFor(int session) => _allFrames
      .where((b) =>
          b.length > 4 &&
          ByteData.sublistView(b, 0, 4).getUint32(0) == session)
      .map((b) => Uint8List.sublistView(b, 4));

  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (e, st) {
      _log.e('requestPermission failed', e, st);
      return false;
    }
  }

  /// Starts [session]'s capture. Throws when it can't (no encoder: the error
  /// code says ENCODER_BUSY, NO_ENCODER or ENCODER_FAILED; no display).
  Future<void> startCapture(DisplayConfigModel config,
      {required int session}) async {
    final r = await _channel.invokeMethod<Map>(
        'startCapture', {...config.toMap(), 'session': session});
    _log.i('Screen capture started (session $session) '
        '${config.width}x${config.height}@${config.refreshRate}fps'
        '${r?['fellBack'] == true ? ' — Extend unavailable, mirroring the main display' : ''}'
        '${r != null && r['hardware'] == false ? ' — software encoder' : ''}');
  }

  /// Stops [session]'s capture. Returns once its encoder has stopped.
  Future<void> stopCapture({required int session}) async {
    try {
      await _channel.invokeMethod('stopCapture', {'session': session});
    } catch (_) {}
  }

  /// Forces [session]'s next encoded frame to be a keyframe (IDR).
  Future<void> requestIdr({required int session}) async {
    try {
      await _channel.invokeMethod('requestIdr', {'session': session});
    } catch (_) {}
  }

  /// Changes [session]'s running encoder's average bitrate (bits per second)
  /// without restarting it: the next frame it encodes is already held to the
  /// new rate. Used over Wi-Fi to fit the stream to the link
  /// (BitrateAdapter). The next startCapture uses its own bitrate again.
  Future<void> setBitrate(int bitsPerSecond, {required int session}) async {
    try {
      await _channel.invokeMethod(
          'setBitrate', {'bitrate': bitsPerSecond, 'session': session});
    } catch (_) {}
  }

  /// Gives [session] a virtual display (replacing its own previous one,
  /// never another session's). [serialNum] is how macOS tells displays apart
  /// and remembers their arrangement. Returns false when the display could
  /// not be made or its mode settings weren't applied; capture then falls
  /// back to the main display if it never shows up in ScreenCaptureKit.
  Future<bool> createVirtualDisplay(DisplayConfigModel config,
      {required int session,
      int serialNum = 1,
      String name = 'Extended Screen'}) async {
    final r = await _channel.invokeMethod<Map>('createVirtualDisplay', {
      'session': session,
      'width': config.width,
      'height': config.height,
      'refreshRate': config.refreshRate,
      'scaleFactor': config.scaleFactor,
      'serialNum': serialNum,
      'name': name,
    });
    return r != null && r['applied'] == true && (r['displayID'] ?? 0) != 0;
  }

  /// Releases [session]'s virtual display. Returns once macOS no longer
  /// lists it (at most about a second).
  Future<void> removeVirtualDisplay({required int session}) async {
    try {
      await _channel.invokeMethod('removeVirtualDisplay', {'session': session});
    } catch (_) {}
  }

  /// Stops and forgets [session] natively: its capture, encoder, virtual
  /// display and content rect. For a session that is gone for good (its id
  /// is never used again). Returns once all of that is gone.
  Future<void> disposeSession({required int session}) async {
    try {
      await _channel.invokeMethod('disposeSession', {'session': session});
    } catch (_) {}
  }

  /// Returns the screen-space bounds of the display [session] captures: its
  /// virtual display (extend mode), or the main display (mirror mode, or
  /// extend when the virtual display never appeared and capture fell back).
  /// Used to map tablet touch coords correctly.
  Future<Map<String, double>> getDisplayBounds({required int session}) async {
    try {
      final r = await _channel
          .invokeMethod<Map>('getVirtualDisplayBounds', {'session': session});
      if (r != null) {
        return {
          'x': (r['x'] as num).toDouble(),
          'y': (r['y'] as num).toDouble(),
          'w': (r['w'] as num).toDouble(),
          'h': (r['h'] as num).toDouble(),
        };
      }
    } catch (e, st) {
      _log.e('getDisplayBounds failed', e, st);
    }
    // Zero size signals failure; the caller falls back to the config size.
    return {'x': 0, 'y': 0, 'w': 0, 'h': 0};
  }
}
