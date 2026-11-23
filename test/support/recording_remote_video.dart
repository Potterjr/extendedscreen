import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';

/// The Mac's decoders for the streams tablets send it (reverse remote),
/// stood in for: nothing is decoded. It keeps which decoders were made,
/// what each was fed and which were disposed, and plays the callbacks the
/// Swift plugin makes ([idr], [codecError], [ready]) through the channel's
/// own handler, so they take the path a real one takes (a session's
/// listener, else the hub's slot).
///
/// Register it with `Get.put<RemoteVideoChannel>(RecordingRemoteVideo())`
/// before the hub is made: `onInit` is what takes the channel's handler,
/// and the hub wires its slots when it is constructed.
class RecordingRemoteVideo extends RemoteVideoChannel {
  static const _channel = MethodChannel('extended_screen/remote_video');

  /// The texture id [initialize] answers for [session].
  static int textureFor(int session) => 100 + session;

  /// Every decoder made, in order.
  final made = <({int session, CodecType codec, int width, int height})>[];

  /// Sessions whose decoder cannot be made: [initialize] answers null.
  final failing = <int>{};

  /// How many frames each session's decoder was fed.
  final fed = <int, int>{};

  /// Every session whose decoder was disposed, in order.
  final disposed = <int>[];

  @override
  Future<int?> initialize({
    required int session,
    required CodecType codec,
    required int width,
    required int height,
  }) async {
    made.add((session: session, codec: codec, width: width, height: height));
    return failing.contains(session) ? null : textureFor(session);
  }

  @override
  Future<void> feedNal(int session, List<int> nalBytes) async {
    fed[session] = (fed[session] ?? 0) + 1;
  }

  @override
  Future<void> dispose({required int session}) async => disposed.add(session);

  /// [session]'s decoder asks for a keyframe, as Swift's `onRequestIdr`.
  Future<void> idr(int session) => _fromPlugin('onRequestIdr', session);

  /// [session]'s decoder could not be made or failed with [code], as Swift's
  /// `onCodecError` reports it (the code travels as `error`).
  Future<void> codecError(int session, String code) =>
      _fromPlugin('onCodecError', session, {'error': code});

  /// [session]'s decoder was made again after a [codecError], as Swift's
  /// `onDecoderReady`.
  Future<void> ready(int session) => _fromPlugin('onDecoderReady', session);

  Future<void> _fromPlugin(String method, int session,
      [Map<String, Object?> more = const {}]) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
          MethodCall(method, {'session': session, ...more})),
      (_) => done.complete(),
    );
    await done.future;
  }
}
