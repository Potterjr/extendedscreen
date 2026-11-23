import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// What a started capture shows: [displayId] is the display captured,
/// [hardware] whether its encoder runs on the media engine, and [fellBack]
/// that Extend was asked for but the main display is captured instead (the
/// session's virtual display was never made, or never showed up).
class CaptureStart {
  final int displayId;
  final bool hardware;
  final bool fellBack;

  const CaptureStart({
    required this.displayId,
    this.hardware = true,
    this.fellBack = false,
  });

  factory CaptureStart.fromMap(Map? r) => CaptureStart(
        displayId: (r?['displayID'] as num?)?.toInt() ?? 0,
        hardware: r?['hardware'] != false,
        fellBack: r?['fellBack'] == true,
      );
}

/// What making a virtual display gave: its id (0 when none was made) and
/// whether its mode settings were applied.
class VirtualDisplayResult {
  final int displayId;
  final bool applied;

  const VirtualDisplayResult({required this.displayId, required this.applied});

  /// A display was made and took its settings.
  bool get ok => applied && displayId != 0;
}

/// This Mac, as the capture plugin sees it: [chip] the CPU brand string
/// ("Apple M3 Pro"; empty when unknown), [os] the macOS version.
class HostInfo {
  final String chip;
  final String os;

  const HostInfo({required this.chip, required this.os});
}

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
  /// woke from sleep (every session needs rebuilding then). [asleep] says
  /// the main display was asleep when the stream stopped: ScreenCaptureKit
  /// stops every stream as the displays sleep, and the wake recovers it.
  void Function(int? session, {bool asleep})? onCaptureRestartNeeded;

  /// [session]'s virtual display was terminated by macOS ([displayId] is
  /// the display it had). Only reported for now.
  void Function(int session, int displayId)? onVirtualDisplayTerminated;

  /// [session]'s capture came out in another shape than the display it
  /// asked for on its first frame: its own virtual display with bars
  /// (Extend), or a picture that has not the main display's shape (Mirror).
  /// The stream may be showing another display (Apple bug FB17797423).
  /// Reported once per start; the hub decides what to do (an ordered
  /// rebuild of every display, or a notice on the card).
  void Function(int session)? onCaptureMismatch;

  /// [session]'s capture showed the display it asked for on its first
  /// frame (the same check as [onCaptureMismatch], the other answer). Once
  /// per start.
  void Function(int session)? onCaptureMatched;

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

  /// Wired by [HostConnectionManager]: the "Max" preset's encoder of
  /// [session] could not keep up and is stepping down; [achieved] is the
  /// rate it managed meanwhile (frames a second). Called just before the
  /// [onFrameRateChanged] of that step, and only for an overload, never for
  /// a step-up or a ceiling.
  void Function(int session, double achieved)? onEncoderOverload;

  /// Wired by [HostConnectionManager]: once a second, the "Max" preset's
  /// encoder of [session] says how many frames a second came back encoded
  /// without error ([encoded]) and how many the screen delivered
  /// ([captured]; 0 while nothing on it changes). The hub takes a load as
  /// sustained only with this evidence.
  void Function(int session, double encoded, double captured)?
      onEncoderStats;

  Future<dynamic> _handleNative(MethodCall call) async {
    final args = call.arguments;
    final session = args is Map ? args['session'] : null;
    switch (call.method) {
      case 'onStreamStopped':
        final asleep = args is Map && args['asleep'] == true;
        _log.w('Native capture stopped (session $session'
            '${asleep ? ', displays asleep' : ''}): '
            '${args is Map ? args['error'] : args}');
        onCaptureRestartNeeded?.call(session is int ? session : null,
            asleep: asleep);
        break;
      case 'onCaptureNeedsRestart':
        _log.w('Native capture restart requested (wake)');
        onCaptureRestartNeeded?.call(null, asleep: false);
        break;
      case 'onVirtualDisplayTerminated':
        final display = args is Map ? args['displayID'] : null;
        _log.w('Virtual display $display terminated (session $session)');
        if (session is int) {
          onVirtualDisplayTerminated?.call(
              session, display is int ? display : 0);
        }
        break;
      case 'onCaptureMismatch':
        final rect = args is Map
            ? '${args['x']},${args['y']} ${args['w']}x${args['h']}'
            : '?';
        _log.w('Capture of session $session does not fill its frame '
            '($rect): it may be showing another display');
        if (session is int) onCaptureMismatch?.call(session);
        break;
      case 'onCaptureMatched':
        if (session is int) onCaptureMatched?.call(session);
        break;
      case 'onDisplayBoundsChanged':
        onDisplayBoundsChanged?.call();
        break;
      case 'onFrameRateChanged':
        final fps = args is Map ? args['fps'] : null;
        final achieved = args is Map ? args['achieved'] : null;
        if (session is int && fps is int) {
          _log.w('Adaptive encoder rate (session $session) → $fps fps'
              '${achieved is num ? ' (${achieved.round()} fps achieved)' : ''}');
          if (achieved is num) {
            onEncoderOverload?.call(session, achieved.toDouble());
          }
          onFrameRateChanged?.call(session, fps);
        }
        break;
      case 'onEncoderStats':
        final encoded = args is Map ? args['encoded'] : null;
        final captured = args is Map ? args['captured'] : null;
        if (session is int && encoded is num && captured is num) {
          onEncoderStats?.call(
              session, encoded.toDouble(), captured.toDouble());
        }
        break;
      default:
        break;
    }
    return null;
  }

  /// Each session's frames, by id, from its first [framesFor] until
  /// [disposeSession].
  final _routes = <int, StreamController<Uint8List>>{};

  /// Every session's encoded frames, each behind its session's id (4 bytes,
  /// big-endian), on one subscription for the whole app, started by the
  /// first [framesFor] and never cancelled. An EventChannel delivers to one
  /// Dart listener, so a second `receiveBroadcastStream` would steal the
  /// first one's frames; and cancelling the last listener stopped the native
  /// side's sink, so the frames that came before the next listen (a rebuilt
  /// encoder's first keyframe) were lost.
  StreamSubscription<dynamic>? _allFrames;

  void _demux(dynamic e) {
    final b = e is Uint8List ? e : Uint8List.fromList(List<int>.from(e));
    if (b.length <= 4) return;
    final route = _routes[ByteData.sublistView(b, 0, 4).getUint32(0)];
    // A session nobody has asked for (or one already disposed): dropped.
    route?.add(Uint8List.sublistView(b, 4));
  }

  /// The Annex-B frames [session]'s encoder produces, its id taken off.
  /// Listeners may come and go: frames that arrive while nobody listens
  /// are dropped, and the native stream runs on.
  Stream<Uint8List> framesFor(int session) {
    _allFrames ??= _frames.receiveBroadcastStream().listen(_demux,
        onError: (Object e) => _log.w('Frame stream error: $e'));
    return (_routes[session] ??= StreamController<Uint8List>.broadcast())
        .stream;
  }

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
  /// The config's [DisplayConfigModel.fpsCeiling] (sent only when set)
  /// holds the encode rate below its own while other tablets share the
  /// encoder; [setFrameRateCeiling] moves it later.
  Future<CaptureStart> startCapture(DisplayConfigModel config,
      {required int session}) async {
    final r = CaptureStart.fromMap(await _channel.invokeMethod<Map>(
        'startCapture', {...config.toMap(), 'session': session}));
    final fpsCeiling = config.fpsCeiling;
    final held = fpsCeiling != null && fpsCeiling < config.refreshRate;
    _log.i('Screen capture started (session $session) '
        '${config.width}x${config.height}@${config.refreshRate}fps'
        '${held ? ' (held to $fpsCeiling)' : ''}'
        '${r.fellBack ? ' — Extend unavailable, mirroring the main display' : ''}'
        '${r.hardware ? '' : ' — software encoder'}');
    return r;
  }

  /// Holds [session]'s running encoder to at most [fps], or lets it climb
  /// back towards its own rate, without a new encoder or a keyframe. The
  /// encoder reports the rate it lands on through [onFrameRateChanged].
  Future<void> setFrameRateCeiling(int fps, {required int session}) async {
    try {
      await _channel.invokeMethod(
          'setFrameRateCeiling', {'fps': fps, 'session': session});
    } catch (_) {}
  }

  /// This Mac's chip and macOS version; null when the plugin can't say.
  Future<HostInfo?> getHostInfo() async {
    try {
      final r = await _channel.invokeMethod<Map>('getHostInfo');
      if (r == null) return null;
      return HostInfo(
        chip: r['chip'] is String ? r['chip'] as String : '',
        os: r['os'] is String ? r['os'] as String : '',
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
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
  /// and remembers their arrangement. Not [VirtualDisplayResult.ok] when the
  /// display could not be made or its mode settings weren't applied; capture
  /// then falls back to the main display (and says so) if it has none or it
  /// never shows up in ScreenCaptureKit.
  Future<VirtualDisplayResult> createVirtualDisplay(DisplayConfigModel config,
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
    return VirtualDisplayResult(
      displayId: (r?['displayID'] as num?)?.toInt() ?? 0,
      applied: r?['applied'] == true,
    );
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
  /// is never used again). Returns once all of that is gone. Its frame
  /// stream ([framesFor]) is closed.
  Future<void> disposeSession({required int session}) async {
    _routes.remove(session)?.close();
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
