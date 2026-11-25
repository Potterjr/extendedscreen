import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// macOS only — the reverse of [VideoDecoderChannel]: decodes the H.264/H.265
/// stream coming FROM the tablet (Mac-controls-tablet remote mode) via a Swift
/// VideoToolbox decompression session and shows it in the tablet's native
/// remote window ([initializeWindow], a session's path) or renders it into a
/// Flutter `Texture` ([initialize], the debug Loopback preview's).
///
/// [initialize] returns the texture id to hand to a `Texture` widget; NAL units
/// are fed over a binary channel to avoid `StandardMessageCodec` overhead on the
/// frame hot path. One decoder and texture per session (one per tablet, the
/// id its connection was given).
class RemoteVideoChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/remote_video');
  static const _nalChannel =
      BasicMessageChannel<ByteData?>('extended_screen/remote_nal', BinaryCodec());
  final _log = Get.find<LoggerService>();

  /// Invoked with the session whose native decoder needs a keyframe (it is
  /// fed pictures it has nothing to start from, or one failed to decode; at
  /// most once a second); the host relays this to that tablet as an IDR
  /// request.
  void Function(int session)? onRequestIdr;

  /// Invoked with the session whose native decoder could not be made, and
  /// the plugin's code for why (`DECODER_BUSY` or `DECODER_FAILED`, with
  /// VideoToolbox's status): that tablet's picture is not shown until
  /// [onDecoderReady].
  void Function(int session, String code)? onCodecError;

  /// Invoked with the session whose native decoder was made again, the
  /// first time after an [onCodecError].
  void Function(int session)? onDecoderReady;

  // Decoders that are no session's (the debug Loopback preview's): their
  // keyframe requests go to their own listener, never to [onRequestIdr],
  // and their failures and recoveries are only logged.
  final _idrListeners = <int, void Function()>{};

  /// [session]'s keyframe requests go to [onIdr] instead of [onRequestIdr],
  /// until [unlistenIdr].
  void listenIdr(int session, void Function() onIdr) =>
      _idrListeners[session] = onIdr;

  void unlistenIdr(int session) => _idrListeners.remove(session);

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler(_handleNative);
  }

  Future<Object?> _handleNative(MethodCall call) async {
    final args = call.arguments;
    final session = args is Map ? args['session'] : null;
    switch (call.method) {
      case 'onRequestIdr':
        if (session is int) {
          final listener = _idrListeners[session];
          if (listener != null) {
            listener();
          } else {
            onRequestIdr?.call(session);
          }
        }
      case 'onCodecError':
        _log.w('RemoteVideo codec error: $args');
        if (session is int && !_idrListeners.containsKey(session)) {
          final code = args is Map ? args['error'] : null;
          onCodecError?.call(session, code is String ? code : '');
        }
      case 'onDecoderReady':
        if (session is int) {
          if (_idrListeners.containsKey(session)) {
            _log.i('RemoteVideo decoder made again (session $session)');
          } else {
            onDecoderReady?.call(session);
          }
        }
    }
    return null;
  }

  /// Create [session]'s decoder + backing texture (replacing one it had).
  /// Returns the texture id; null if the native side failed to allocate one.
  Future<int?> initialize({
    required int session,
    required CodecType codec,
    required int width,
    required int height,
  }) async {
    try {
      final textureId = await _channel.invokeMethod<int>('initialize', {
        'session': session,
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'width': width,
        'height': height,
      });
      _log.i('RemoteVideo decoder ready (session $session, texture $textureId) '
          '${width}x$height');
      return textureId;
    } catch (e, st) {
      _log.e('RemoteVideo initialize failed', e, st);
      return null;
    }
  }

  /// Create [session]'s decoder for the native remote window whose id is
  /// [window] (replacing one it had): no texture, each decoded picture goes
  /// to that window's picture sink, looked up per frame, so a window opened
  /// later shows the next picture. True once the decoder exists; false when
  /// the native side could not make it.
  Future<bool> initializeWindow({
    required int session,
    required CodecType codec,
    required String window,
  }) async {
    try {
      final made = await _channel.invokeMethod<bool>('initializeWindow', {
        'session': session,
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'window': window,
      });
      _log.i('RemoteVideo decoder ready (session $session, window $window)');
      return made == true;
    } catch (e, st) {
      _log.e('RemoteVideo initializeWindow failed', e, st);
      return false;
    }
  }

  /// Show [session]'s last decoded picture once more on its window (a still
  /// tablet sends nothing new for a window opened on it). Whether a picture
  /// was shown: false with no window decoder, no picture yet or no window.
  Future<bool> replayLatest(int session) async {
    try {
      return await _channel
              .invokeMethod<bool>('replayLatest', {'session': session}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// Feed one encoded frame (Annex-B) to [session]'s decoder: one message,
  /// the session's id (4 bytes, big-endian) and then the frame.
  Future<void> feedNal(int session, List<int> nalBytes) async {
    final message = Uint8List(4 + nalBytes.length);
    ByteData.sublistView(message).setUint32(0, session);
    message.setRange(4, message.length, nalBytes);
    await _nalChannel.send(ByteData.sublistView(message));
  }

  Future<void> dispose({required int session}) async {
    try {
      await _channel.invokeMethod('dispose', {'session': session});
    } catch (_) {}
  }
}
