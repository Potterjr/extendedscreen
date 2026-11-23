import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_grid_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_tile.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

/// What draws a decoder's texture. A seam: a widget test has no texture
/// registry behind the ids it makes up.
typedef RemoteTextureBuilder = Widget Function(int textureId);

Widget _texture(int textureId) => Texture(textureId: textureId);

/// The Mac's view of the tablets it controls: one tile per tablet, each
/// with its own picture, pointer, screen toggle, Reconnect and Disconnect.
///
/// One tablet fills the window under a floating bar, as the view did when
/// it showed a single session. Two sit side by side, three or four in a
/// 2×2 grid, five or more in a two-column grid that scrolls. A tile can be
/// expanded to the whole window, the others reduced to a strip of names.
class RemoteHostView extends GetView<RemoteGridController> {
  const RemoteHostView({super.key, this.textureBuilder = _texture});

  final RemoteTextureBuilder textureBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Obx(() {
          final tiles = controller.tiles.toList();
          final expandedKey = controller.expanded.value;

          if (tiles.isEmpty) {
            return Column(
              children: [
                const _GridBar(),
                Expanded(
                  child: Center(
                    child: Text(
                      'remote_grid_empty'.tr,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ),
                ),
              ],
            );
          }

          if (tiles.length == 1) {
            final tile = tiles.single;
            return Stack(
              fit: StackFit.expand,
              children: [
                _TileView(
                  key: _tileKey(tile),
                  tile: tile,
                  textureBuilder: textureBuilder,
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: _GridBar(
                    children: [
                      // What is left of the bar, the controls at its
                      // right end and smaller when they need more.
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          // This bar is outside the tile's own keyed
                          // widget, so the controls carry the session's
                          // identity themselves: a new session for the
                          // same tablet gets new buttons, and a press
                          // held across the change does nothing.
                          child: _TileControls(
                            key: _controlsKey(tile),
                            tile: tile,
                            labelled: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          RemoteTile? expanded;
          for (final tile in tiles) {
            if (tile.key == expandedKey) expanded = tile;
          }
          if (expanded != null) {
            return Column(
              children: [
                _GridBar(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final tile in tiles)
                              if (tile != expanded)
                                TextButton(
                                  key: ValueKey('strip/${tile.key}'),
                                  onPressed: () => controller.expand(tile.key),
                                  style: TextButton.styleFrom(
                                      foregroundColor: Colors.white70),
                                  child: Text(tile.name),
                                ),
                          ],
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('grid/show_all'),
                      onPressed: controller.showAll,
                      icon: const Icon(Icons.grid_view, size: 16),
                      label: Text('remote_tile_show_all'.tr),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.white70),
                    ),
                  ],
                ),
                Expanded(
                  child: _TileView(
                    key: _tileKey(expanded),
                    tile: expanded,
                    textureBuilder: textureBuilder,
                    bar: _TileBarStyle.labelled,
                  ),
                ),
              ],
            );
          }

          Widget cell(RemoteTile tile) => _TileView(
                key: _tileKey(tile),
                tile: tile,
                textureBuilder: textureBuilder,
                bar: _TileBarStyle.compact,
                onExpand: () => controller.expand(tile.key),
              );

          final Widget grid;
          if (tiles.length <= 4) {
            // Two side by side; three or four in two rows of two.
            Widget row(List<RemoteTile> of) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final tile in of) Expanded(child: cell(tile)),
                    if (tiles.length > 2 && of.length < 2) const Spacer(),
                  ],
                );
            grid = tiles.length == 2
                ? row(tiles)
                : Column(
                    children: [
                      Expanded(child: row(tiles.sublist(0, 2))),
                      Expanded(child: row(tiles.sublist(2))),
                    ],
                  );
          } else {
            grid = _ScrollingGrid(
              controller: controller.gridScroll,
              children: [for (final tile in tiles) cell(tile)],
            );
          }
          return Column(
            children: [const _GridBar(), Expanded(child: grid)],
          );
        }),
      ),
    );
  }

  // A new session for the same tablet is another tile: nothing of the old
  // one's element is reused.
  static Key _tileKey(RemoteTile tile) =>
      ValueKey('tile/${tile.key}/${tile.session.nativeId}');

  static Key _controlsKey(RemoteTile tile) =>
      ValueKey('controls/${tile.key}/${tile.session.nativeId}');
}

/// The bar over the whole view: Back, in every state, and whatever the
/// layout adds beside it.
class _GridBar extends StatelessWidget {
  const _GridBar({this.children = const [Spacer()]});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('grid/back'),
            icon: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 18),
            onPressed: Get.back,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 12),
          Text(
            'session_remote_label'.tr,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// Five tiles or more: two columns, two rows to a window, the rest reached
/// by scrolling. A press or drag on a tile is that tablet's, so no pointer
/// drag scrolls the grid: only the scrollbar, a mouse wheel and a trackpad's
/// two-finger scroll do. The physics stay the default ones, because the
/// scrollbar and the wheel refuse a position whose physics take no user
/// offset; what is taken away is the drag, for every device but the
/// trackpad (whose scroll gesture is not a press).
class _ScrollingGrid extends StatelessWidget {
  const _ScrollingGrid({required this.controller, required this.children});

  final ScrollController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          dragDevices: const {PointerDeviceKind.trackpad},
        ),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: true,
          interactive: true,
          child: GridView(
            controller: controller,
            // Room for the scrollbar beside the right-hand tiles.
            padding: const EdgeInsets.only(right: 12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: box.maxHeight / 2,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

enum _TileBarStyle { none, compact, labelled }

/// One tablet: its bar (unless the view's own bar carries its controls)
/// over its picture.
class _TileView extends StatelessWidget {
  const _TileView({
    super.key,
    required this.tile,
    required this.textureBuilder,
    this.bar = _TileBarStyle.none,
    this.onExpand,
  });

  final RemoteTile tile;
  final RemoteTextureBuilder textureBuilder;
  final _TileBarStyle bar;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final picture = _TilePicture(tile: tile, textureBuilder: textureBuilder);
    if (bar == _TileBarStyle.none) return picture;
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(6, 0, 6, 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          // The controls at their own size while the bar has room for
          // them, the name in what is left; in a bar narrower than the
          // controls they are drawn smaller, never cut off.
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(
                  child: Obx(() => Text(
                        tile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      )),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: _TileControls(
                      tile: tile,
                      labelled: bar == _TileBarStyle.labelled,
                      onExpand: onExpand,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: picture),
      ],
    );
  }
}

/// A tile's picture, in its tablet's own shape, and what the Mac's pointer
/// does on it. Positions are taken against this picture's own box, so a
/// tile's size and place in the grid mean nothing to its tablet.
class _TilePicture extends StatelessWidget {
  const _TilePicture({required this.tile, required this.textureBuilder});

  final RemoteTile tile;
  final RemoteTextureBuilder textureBuilder;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final session = tile.session;
      final textureId = session.remoteTextureId.value;
      final streaming = session.tabletStreaming.value;
      final active = session.phase.value.isActive;
      final notice = session.notice.value;

      // Reconnecting while the link is down or coming up. Otherwise, with
      // nothing to say about the decoder, waiting for the tablet's user
      // until the picture is there.
      final Widget? status = !active
          ? _TileStatus(text: 'remote_tile_reconnecting'.tr)
          : notice == null && (textureId == null || !streaming)
              ? _TileStatus(text: 'remote_host_waiting'.tr)
              : null;

      return Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (textureId != null)
            Center(
              child: AspectRatio(
                aspectRatio: tile.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, box) => Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => tile.onPointerDown(
                      e.pointer,
                      e.localPosition.dx / box.maxWidth,
                      e.localPosition.dy / box.maxHeight,
                    ),
                    onPointerUp: (e) => tile.onPointerUp(
                      e.pointer,
                      e.localPosition.dx / box.maxWidth,
                      e.localPosition.dy / box.maxHeight,
                    ),
                    onPointerCancel: (e) => tile.onPointerCancel(e.pointer),
                    child: textureBuilder(textureId),
                  ),
                ),
              ),
            ),
          // Over the picture, never in the pointer's way: while there is
          // a texture (waiting for the tablet's user, or the link coming
          // back up once its decoder is made) the pointer still reaches
          // the tablet, through adb. A tile with no texture (link down,
          // retry pending) takes no pointer: there is nothing to aim at.
          //
          // At its own size where the tile has room, wrapped to the
          // tile's width; in a tile too short for it (a short window, the
          // grid's half-height rows) drawn smaller, never overflowing.
          if (status != null)
            IgnorePointer(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, box) => FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth),
                      child: status,
                    ),
                  ),
                ),
              ),
            ),
          if (notice != null)
            IgnorePointer(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    notice.tr,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amber, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _TileStatus extends StatelessWidget {
  const _TileStatus({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: Color(0xFF00C8FF)),
          ),
          const SizedBox(height: 18),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// A tile's own controls: its latency, its tablet's screen (once that
/// tablet's picture is arriving), Reconnect, Disconnect and, in a grid,
/// Expand. With labels where there is room for them (one tile at full
/// size), icons with tooltips in a grid.
class _TileControls extends StatelessWidget {
  const _TileControls({
    super.key,
    required this.tile,
    required this.labelled,
    this.onExpand,
  });

  final RemoteTile tile;
  final bool labelled;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final key = tile.key;
    return Obx(() {
      final session = tile.session;
      final off = session.tabletScreenOff.value;
      final changing = session.changingTabletScreen.value;
      final screenLabel =
          off ? 'remote_tablet_screen_on'.tr : 'remote_tablet_screen_off'.tr;
      final screenIcon = off ? Icons.light_mode : Icons.dark_mode;
      // Keyed by what a press would do, under the tile's own key: when the
      // panel's state changes under a finger (the tablet lit it by itself,
      // the remembered choice was applied), the button is another one and
      // the press does nothing.
      final screenKey = ValueKey('tile/$key/screen/${off ? 'on' : 'off'}');
      final onScreen = changing ? null : tile.onToggleScreen;

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session.tabletStreaming.value)
            KeyedSubtree(
              key: ValueKey('tile/$key/screen'),
              child: labelled
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'remote_tablet_screen_hint'.tr,
                        child: TextButton.icon(
                          key: screenKey,
                          onPressed: onScreen,
                          icon: Icon(screenIcon, size: 16),
                          label: Text(screenLabel),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white70),
                        ),
                      ),
                    )
                  : _IconAction(
                      key: screenKey,
                      icon: screenIcon,
                      tooltip: screenLabel,
                      onPressed: onScreen,
                    ),
            ),
          _Chip(icon: Icons.bolt, label: '${session.latencyMs.value}ms'),
          SizedBox(width: labelled ? 8 : 2),
          if (labelled) ...[
            TextButton.icon(
              key: ValueKey('tile/$key/reconnect'),
              onPressed: tile.onReconnect,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text('common_reconnect'.tr),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: ValueKey('tile/$key/disconnect'),
              onPressed: tile.onDisconnect,
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text('common_disconnect'.tr),
            ),
          ] else ...[
            _IconAction(
              key: ValueKey('tile/$key/reconnect'),
              icon: Icons.refresh,
              tooltip: 'common_reconnect'.tr,
              onPressed: tile.onReconnect,
            ),
            _IconAction(
              key: ValueKey('tile/$key/disconnect'),
              icon: Icons.link_off,
              tooltip: 'common_disconnect'.tr,
              color: Colors.redAccent,
              onPressed: tile.onDisconnect,
            ),
          ],
          if (onExpand != null)
            _IconAction(
              key: ValueKey('tile/$key/expand'),
              icon: Icons.open_in_full,
              tooltip: 'remote_tile_expand'.tr,
              onPressed: onExpand,
            ),
        ],
      );
    });
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = Colors.white70,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onPressed,
      color: color,
      disabledColor: Colors.white24,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white70),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
