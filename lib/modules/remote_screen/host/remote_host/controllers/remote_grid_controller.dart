import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_tile.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';

/// The Mac's view of the tablets it controls (reverse remote): one
/// [RemoteTile] for every such session the hub has, whatever its phase.
/// Each tile shows its session's decoded stream (a Flutter texture) and
/// turns clicks and drags on it into `adb shell input` taps and swipes on
/// that tablet.
class RemoteGridController extends GetxController {
  // Only reachable on the host, so the cast is safe.
  final HostConnectionManager _hub =
      Get.find<BaseConnectionManager>() as HostConnectionManager;

  /// The tiles, sorted by key. A tile lives as long as its session is the
  /// hub's: a new session for the same tablet gets a new tile.
  final tiles = <RemoteTile>[].obs;

  /// The key of the tile shown alone at full size, the others reduced to a
  /// strip of names. Null: every tile is shown.
  final expanded = RxnString();

  /// Scrolls the grid once it has more tiles than fit (five or more).
  final gridScroll = ScrollController();

  late final Worker _sessionsWorker;

  @override
  void onInit() {
    super.onInit();
    _sync();
    final arguments = Get.arguments;
    final focus = arguments is Map ? arguments['focus'] : null;
    if (focus is String) expand(focus);
    _sessionsWorker =
        ever<Map<String, HostSession>>(_hub.sessions, (_) => _sync());
  }

  /// Shows [key]'s tile alone. Only one of two or more: a lone tile fills
  /// the window as it is.
  void expand(String key) {
    if (tiles.length >= 2 && tiles.any((t) => t.key == key)) {
      expanded.value = key;
    }
  }

  void showAll() => expanded.value = null;

  /// The hub's sessions changed: a tile for each tablet the Mac controls
  /// now, the one it had if its session is still the same object.
  void _sync() {
    final next = [
      for (final session in _hub.remoteSessions)
        tiles.firstWhere((t) => identical(t.session, session),
            orElse: () => RemoteTile(session, _hub)),
    ];
    var same = next.length == tiles.length;
    for (var i = 0; same && i < next.length; i++) {
      same = identical(next[i], tiles[i]);
    }
    if (!same) tiles.assignAll(next);
    final key = expanded.value;
    if (key != null && (next.length < 2 || !next.any((t) => t.key == key))) {
      expanded.value = null;
    }
  }

  @override
  void onClose() {
    _sessionsWorker.dispose();
    gridScroll.dispose();
    super.onClose();
  }
}
