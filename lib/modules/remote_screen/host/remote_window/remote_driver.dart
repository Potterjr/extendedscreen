import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';

/// What a pointer packet from a native remote window says happened.
enum RemotePointerKind { down, move, up, cancel }

/// One pointer packet from a native remote window
/// (`extended_screen/remote_window_input`, sent by `RemoteSurfaceView.swift`):
/// the left button on the picture, in the picture box's logical points
/// (origin at the top left of the aspect-fitted picture), the box's size,
/// Shift at the down, and the event's time ([eventUs], µs of the Mac's
/// uptime, the clock of `mach_absolute_time`).
///
/// Little-endian:
/// ```
/// u8  kind      0 down, 1 move, 2 up, 3 cancel
/// u8  flags     bit0 shift (meaningful at down)
/// u16 idLen
/// u8[idLen] id  UTF-8 device id
/// f32 x, f32 y  picture-box logical points
/// f32 boxW, f32 boxH
/// u64 eventUs
/// ```
class RemotePointer {
  const RemotePointer({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.boxW,
    required this.boxH,
    this.shift = false,
    this.eventUs = 0,
  });

  final String id;
  final RemotePointerKind kind;
  final double x;
  final double y;
  final double boxW;
  final double boxH;
  final bool shift;
  final int eventUs;

  Offset get at => Offset(x, y);
  Size get box => Size(boxW, boxH);

  /// [data] as a packet; null when it is not one (too short, an unknown
  /// kind, an id that is not UTF-8, a value that is not finite, an empty
  /// box).
  static RemotePointer? decode(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final kind = data.getUint8(0);
    if (kind >= RemotePointerKind.values.length) return null;
    final flags = data.getUint8(1);
    final idLen = data.getUint16(2, Endian.little);
    final need = 4 + idLen + 4 * 4 + 8;
    if (idLen == 0 || data.lengthInBytes < need) return null;
    final String id;
    try {
      id = utf8.decode(data.buffer.asUint8List(data.offsetInBytes + 4, idLen));
    } on FormatException {
      return null;
    }
    var o = 4 + idLen;
    double f32() {
      final v = data.getFloat32(o, Endian.little);
      o += 4;
      return v;
    }

    final x = f32();
    final y = f32();
    final boxW = f32();
    final boxH = f32();
    final eventUs = data.getUint64(o, Endian.little);
    if (![x, y, boxW, boxH].every((v) => v.isFinite)) return null;
    if (boxW <= 0 || boxH <= 0) return null;
    return RemotePointer(
      id: id,
      kind: RemotePointerKind.values[kind],
      x: x,
      y: y,
      boxW: boxW,
      boxH: boxH,
      shift: flags & 1 != 0,
      eventUs: eventUs,
    );
  }

  /// This packet's bytes, as Swift writes them (tests, and the format's
  /// reference).
  ByteData encode() {
    final idBytes = utf8.encode(id);
    final data = ByteData(4 + idBytes.length + 4 * 4 + 8);
    data.setUint8(0, kind.index);
    data.setUint8(1, shift ? 1 : 0);
    data.setUint16(2, idBytes.length, Endian.little);
    data.buffer.asUint8List(4, idBytes.length).setAll(0, idBytes);
    var o = 4 + idBytes.length;
    for (final v in [x, y, boxW, boxH]) {
      data.setFloat32(o, v, Endian.little);
      o += 4;
    }
    data.setUint64(o, eventUs, Endian.little);
    return data;
  }

  @override
  String toString() =>
      'RemotePointer($id ${kind.name} '
      '${x.toStringAsFixed(1)},${y.toStringAsFixed(1)} '
      'in ${boxW.toStringAsFixed(0)}x${boxH.toStringAsFixed(0)}'
      '${shift ? ' shift' : ''})';
}

/// What a native remote window drives: one device's session, its behaviour
/// and policy in Dart (`RemoteWindowChannel` routes the window's pointer
/// packets and actions to it by id). [IphoneRemoteWindow] is the first; the
/// reverse-remote view can be a second.
///
/// Its life is the window's: [start] once the window has opened, [dispose]
/// once it has closed (the red button, ⌘W, a close from Dart, the app
/// quitting), which ends the session the window showed, and only that one:
/// a newer session under the same id, or one that has already ended
/// elsewhere, is left alone. A driver may also ask for its own window to be
/// closed ([closeRequests]), when what it showed has gone.
///
/// Implementers extend it (rather than implement it) to inherit the
/// defaults of its optional members.
abstract class RemoteDriver {
  /// The device id the window is keyed by.
  String get id;

  /// The window's kind (`iphone`), which Swift receives on `open`.
  String get kind;

  /// The window's title.
  String get title;

  /// The picture's size in pixels when already known (the window starts
  /// locked to it); null otherwise.
  Size? get frameSize;

  /// The window's keyboard shortcuts: a key (`1` for ⌘1) to the action item
  /// it sends, which [action] then receives.
  Map<String, String> get shortcuts;

  /// The window's chrome as it changes, each a full snapshot with every
  /// string resolved, an equal one never twice in a row (from [start] until
  /// [dispose]; the channel sends each as `render`).
  Stream<RemoteViewModel> get renders;

  /// Asks for this driver's window to be closed: each event makes the
  /// channel close it (`RemoteWindowChannel.close`), which then disposes
  /// the driver as for any close. Listened to from the window's open until it closes;
  /// an event after that, or for a window the id no longer has, does
  /// nothing. None by default.
  Stream<void> get closeRequests => const Stream<void>.empty();

  /// A pointer packet for this window.
  void pointer(RemotePointer e);

  /// A toolbar item, a menu entry, the message's action, or a shortcut.
  void action(String item);

  /// Starts the session (the window has opened).
  Future<void> start();

  /// Ends the session (the window has closed). At most once matters: a
  /// second call does nothing.
  Future<void> dispose();
}
