import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';

/// One tablet the Mac views and drives, as the remote view shows it: its
/// session, and what the view does with it. Everything here is that
/// session's own (its panel, its picture, its screen, its taps), never the
/// hub's focused one, so several tiles side by side stay apart.
class RemoteTile {
  RemoteTile(this.session, this._hub);

  final HostSession session;
  final HostConnectionManager _hub;

  String get key => session.key;

  /// The tablet's model, else its key.
  String get name => session.activeDevice.value?.model ?? key;

  /// The shape of this tablet's panel, for letterboxing its picture.
  double get aspectRatio {
    final panel = session.panel;
    return panel.width <= 0 || panel.height <= 0
        ? 16 / 10
        : panel.width / panel.height;
  }

  // Tells a tap from a drag by how far the pointer moved (normalized).
  static const _dragThreshold = 0.012;

  // Where each pointer that is down on this tile went down, by
  // `PointerEvent.pointer`.
  final _down = <int, Offset>{};

  static Offset _inside(double nx, double ny) =>
      Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));

  void onPointerDown(int pointer, double nx, double ny) =>
      _down[pointer] = _inside(nx, ny);

  /// The pointer came up at ([nx], [ny]) of this tile's picture (outside
  /// it after a drag: taken to the nearest edge): a tap, or a swipe from
  /// where it went down. A pointer that did not go down here sends nothing.
  void onPointerUp(int pointer, double nx, double ny) {
    final start = _down.remove(pointer);
    if (start == null) return;
    final end = _inside(nx, ny);
    if ((end - start).distance < _dragThreshold) {
      session.sendRemoteTap(end.dx, end.dy);
    } else {
      session.sendRemoteSwipe(start.dx, start.dy, end.dx, end.dy);
    }
  }

  void onPointerCancel(int pointer) => _down.remove(pointer);

  /// Turns this tablet's panel off, or back on. One call at a time: a
  /// press while one is under way (this button's, or the remembered choice
  /// being applied as the picture arrived) does nothing.
  Future<void> onToggleScreen() async {
    if (session.changingTabletScreen.value) return;
    final error =
        await session.setTabletScreenOff(!session.tabletScreenOff.value);
    if (error == null) return;
    Get.snackbar(
      'remote_tablet_screen_failed'.tr,
      // Which tablet, once there is more than one to mean.
      _hub.remoteSessions.length > 1 ? '$name: $error' : error,
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.all(16),
    );
  }

  /// Restarts this tablet's session alone (tear down, then connect to the
  /// same tablet). Recovers a stalled or black stream; the tablet shows its
  /// "Start screen sharing" button again afterwards. The view stays open.
  void onReconnect() {
    // As for Disconnect: the hub restarts by key, and a tile on its way
    // out must not restart the session that took its tablet's place.
    if (identical(_hub.sessions[key], session)) {
      unawaited(_hub.reconnectSession(key));
    }
  }

  /// Ends this tablet's session alone. The view closes with the last
  /// tablet it showed, as soon as the session is out of the hub's reach,
  /// not once its teardown is done (that can take seconds).
  void onDisconnect() {
    // Not when the hub already has another session for this tablet: this
    // tile is on its way out, and the press must not end the new one.
    if (identical(_hub.sessions[key], session)) {
      unawaited(_hub.disconnectSession(key, userStopped: false));
    }
    if (_hub.remoteSessions.isEmpty &&
        Get.currentRoute == AppRoutes.remoteHost) {
      // With anything this view put over itself (the screen toggle's
      // snackbar): a plain back would only close that.
      Get.back(closeOverlays: true);
    }
  }
}
