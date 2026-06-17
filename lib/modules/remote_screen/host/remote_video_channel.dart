import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// macOS only — the reverse of [VideoDecoderChannel]: decodes the H.264/H.265
/// stream coming FROM the tablet (Mac-controls-tablet remote mode) via a Swift
/// VideoToolbox decompression session and renders it into a Flutter `Texture`.
///
/// [initialize] returns the texture id to hand to a `Texture` widget; NAL units
/// are fed over a binary channel to avoid `StandardMessageCodec` overhead on the
/// frame hot path.
class RemoteVideoChannel extends GetxService {
  static const _channel = MethodChannel('extended_screen/remote_video');
  static const _nalChannel =
      BasicMessageChannel<ByteData?>('extended_screen/remote_nal', BinaryCodec());
  final _log = Get.find<LoggerService>();

  /// Invoked when the native decoder needs a keyframe (post-configure / error);
  /// the host relays this to the tablet as an IDR request.
  void Function()? onRequestIdr;

  /// Texture id of the live decoder output, or null before [initialize].
  int? textureId;

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRequestIdr':
          onRequestIdr?.call();
        case 'onCodecError':
          _log.w('RemoteVideo codec error: ${call.arguments}');
      }
      return null;
    });
  }

  /// Create the decoder + backing texture. Returns the texture id (also stored
  /// in [textureId]); null if the native side failed to allocate one.
  Future<int?> initialize({
    required CodecType codec,
    required int width,
    required int height,
  }) async {
    try {
      textureId = await _channel.invokeMethod<int>('initialize', {
        'codec': codec == CodecType.h265 ? 'h265' : 'h264',
        'width': width,
        'height': height,
      });
      _log.i('RemoteVideo decoder ready (texture $textureId) ${width}x$height');
      return textureId;
    } catch (e, st) {
      _log.e('RemoteVideo initialize failed', e, st);
      return null;
    }
  }

  /// Feed one raw NAL unit (Annex-B) to the decoder.
  Future<void> feedNal(List<int> nalBytes) async {
    final nal = nalBytes is Uint8List ? nalBytes : Uint8List.fromList(nalBytes);
    await _nalChannel.send(nal.buffer.asByteData());
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    textureId = null;
  }
}
