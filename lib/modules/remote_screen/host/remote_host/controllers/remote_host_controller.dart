import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Host-side viewer for reverse remote (Mac controls tablet): renders the
/// decoded tablet stream (a Flutter texture) and turns clicks/drags into
/// `adb shell input` taps/swipes on the tablet.
class RemoteHostController extends GetxController {
  // Only reachable on the host, so the cast is safe.
  final HostConnectionManager _cm =
      Get.find<BaseConnectionManager>() as HostConnectionManager;
  final _settings = Get.find<SettingsService>();

  /// Live decoder texture id (null until the tablet stream is decoding).
  Rxn<int> get textureId => _cm.remoteTextureId;

  /// Aspect ratio of the tablet panel, for letterboxing the texture.
  double get aspectRatio {
    final w = _settings.clientPanelWidth.value;
    final h = _settings.clientPanelHeight.value;
    return (h <= 0) ? 16 / 10 : w / h;
  }

  // Distinguish a tap from a drag by how far the pointer moved (normalized).
  static const _dragThreshold = 0.012;
  Offset? _down;

  void onPointerDown(double nx, double ny) => _down = Offset(nx, ny);

  void onPointerUp(double nx, double ny) {
    final start = _down;
    _down = null;
    final end = Offset(nx.clamp(0, 1), ny.clamp(0, 1));
    if (start == null) {
      _cm.sendRemoteTap(end.dx, end.dy);
      return;
    }
    final moved = (end - start).distance;
    if (moved < _dragThreshold) {
      _cm.sendRemoteTap(end.dx, end.dy);
    } else {
      _cm.sendRemoteSwipe(start.dx, start.dy, end.dx, end.dy);
    }
  }

  /// Restart the remote session (tear down + reconnect to the same tablet).
  /// Recovers a stalled/black stream; the tablet re-shows its "Start screen
  /// sharing" button afterwards. Stays on this view through the reconnect.
  void onReconnect() => _cm.reconnect();

  void onDisconnect() {
    _cm.disconnect();
    Get.back();
  }
}
