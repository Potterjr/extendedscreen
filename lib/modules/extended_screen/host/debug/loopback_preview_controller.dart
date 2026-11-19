import 'dart:async';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';

/// One synthetic tablet's tile: what reached its socket, decoded on this
/// Mac.
class LoopbackTile {
  LoopbackTile(this.index, this.tablet);

  final int index;
  final FakeTablet tablet;

  /// The id its decoder has in the remote-video plugin: far above any
  /// session's `nativeId` (those count from 1), so it never takes one's.
  int get decoderId => LoopbackPreviewController.decoderBase + index;

  /// The decoder's texture; null until one has been made.
  final textureId = Rxn<int>();

  /// The codec the Mac announced, and frames received over the last second.
  final codec = Rxn<CodecType>();
  final fps = 0.obs;

  int _frames = 0;
  StreamSubscription<Uint8List>? _sub;
  // The codec the decoder was made for; null with none. [_making]: one is
  // being made, and frames are dropped meanwhile (it asks for a keyframe
  // once it is there).
  CodecType? _decoderCodec;
  bool _making = false;
}

/// Debug only (`SYNTH_TABLETS`): decodes each synthetic tablet's stream on
/// the Mac, with the reverse-remote decoder ([RemoteVideoChannel]), so the
/// owner can see which display each stream really shows, and starts or
/// stops its session through the hub, as a pick on Home would (it counts
/// against the cap).
class LoopbackPreviewController extends GetxController {
  /// First decoder id; tile i decodes as `decoderBase + i`.
  static const decoderBase = 0x40000000;

  final hub = Get.find<BaseConnectionManager>() as HostConnectionManager;
  final _remote = Get.find<RemoteVideoChannel>();

  late final tiles = [
    for (final (i, t) in Get.find<SyntheticTablets>().tablets.indexed)
      LoopbackTile(i, t),
  ];

  Timer? _tick;
  bool _closed = false;

  @override
  void onInit() {
    super.onInit();
    for (final tile in tiles) {
      // The decoder's keyframe requests go to this tablet, which sends a
      // 0xFF to the Mac's encoder over its link, as the app's decoder does.
      _remote.listenIdr(tile.decoderId, tile.tablet.requestKeyframe);
      tile._sub = tile.tablet.frameStream.listen((f) => _onFrame(tile, f));
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final tile in tiles) {
        tile.fps.value = tile._frames;
        tile._frames = 0;
        tile.codec.value = tile.tablet.codec;
      }
    });
  }

  /// The session the hub holds for [tile]'s tablet, if any.
  HostSession? sessionOf(LoopbackTile tile) => hub.sessions[tile.tablet.serial];

  /// Starts [tile]'s session (not awaited: a connect returns only once the
  /// session is live).
  void start(LoopbackTile tile) =>
      unawaited(hub.connect(serial: tile.tablet.serial));

  void stop(LoopbackTile tile) =>
      unawaited(hub.disconnectSession(tile.tablet.serial));

  void _onFrame(LoopbackTile tile, Uint8List frame) {
    tile._frames++;
    if (tile._making) return;
    // The codec is announced (0xFC) before the first frame; a new one means
    // a decoder for it.
    final codec = tile.tablet.codec ?? CodecType.h264;
    if (tile._decoderCodec != codec) {
      unawaited(_makeDecoder(tile, codec));
      return;
    }
    unawaited(_remote.feedNal(tile.decoderId, frame));
  }

  Future<void> _makeDecoder(LoopbackTile tile, CodecType codec) async {
    tile._making = true;
    final panel = tile.tablet.panel;
    // Replaces the decoder this id had, if any.
    final texture = await _remote.initialize(
      session: tile.decoderId,
      codec: codec,
      width: panel.width,
      height: panel.height,
    );
    tile._making = false;
    if (_closed) {
      await _remote.dispose(session: tile.decoderId);
      return;
    }
    tile._decoderCodec = codec;
    tile.textureId.value = texture;
    // The frames dropped meanwhile left it nothing to start from.
    tile.tablet.requestKeyframe();
  }

  @override
  void onClose() {
    _closed = true;
    _tick?.cancel();
    for (final tile in tiles) {
      unawaited(tile._sub?.cancel());
      _remote.unlistenIdr(tile.decoderId);
      // A decoder still being made is disposed once it is there.
      if (tile._decoderCodec != null && !tile._making) {
        unawaited(_remote.dispose(session: tile.decoderId));
      }
    }
    super.onClose();
  }
}
