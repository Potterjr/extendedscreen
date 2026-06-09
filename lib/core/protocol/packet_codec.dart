import 'dart:typed_data';
import '../models/packet_model.dart';
import '../models/touch_event_model.dart';

/// Encodes domain models → Packet payload bytes (simple binary encoding).
/// Replace with generated protobuf when proto files are added.
class PacketCodec {
  // Touch event → bytes
  static Uint8List encodeTouchEvent(TouchEventModel e) {
    final buf = BytesBuilder();
    buf.addByte(e.action.index);
    buf.addByte(e.pointers.length);
    for (final p in e.pointers) {
      _writeInt32(buf, p.pointerId);
      _writeFloat32(buf, p.normalizedX);
      _writeFloat32(buf, p.normalizedY);
      _writeFloat32(buf, p.pressure);
      _writeFloat32(buf, p.majorAxis);
    }
    _writeInt64(buf, e.timestampUs);
    _writeInt32(buf, e.displayId);
    return buf.toBytes();
  }

  // Mouse event → bytes
  static Uint8List encodeMouseEvent(MouseEventModel e) {
    final buf = BytesBuilder();
    buf.addByte(e.action.index);
    buf.addByte(e.button.index);
    _writeFloat32(buf, e.normalizedX);
    _writeFloat32(buf, e.normalizedY);
    _writeFloat32(buf, e.scrollDx);
    _writeFloat32(buf, e.scrollDy);
    _writeInt64(buf, e.timestampUs);
    return buf.toBytes();
  }

  // Key event → bytes
  static Uint8List encodeKeyEvent(KeyEventModel e) {
    final buf = BytesBuilder();
    _writeInt32(buf, e.keycode);
    _writeInt32(buf, e.modifiers);
    buf.addByte(e.isDown ? 1 : 0);
    _writeInt64(buf, e.timestampUs);
    return buf.toBytes();
  }

  static Packet wrapTouch(TouchEventModel e) => Packet(
        type: PacketType.touchEvent,
        timestampUs: e.timestampUs,
        payload: encodeTouchEvent(e),
      );

  static Packet wrapMouse(MouseEventModel e) => Packet(
        type: PacketType.mouseEvent,
        timestampUs: e.timestampUs,
        payload: encodeMouseEvent(e),
      );

  static Packet wrapKey(KeyEventModel e) => Packet(
        type: PacketType.keyEvent,
        timestampUs: e.timestampUs,
        payload: encodeKeyEvent(e),
      );

  // Heartbeat payload: 1-byte flags (0x00 = ping, 0x01 = pong) + 8-byte origin timestamp.
  static Packet heartbeat() {
    final ts = _nowUs();
    final payload = ByteData(9)
      ..setUint8(0, 0x00)
      ..setInt64(1, ts, Endian.big);
    return Packet(
      type: PacketType.heartbeat,
      timestampUs: ts,
      payload: payload.buffer.asUint8List(),
    );
  }

  /// Echo a received ping back as a pong (preserves origin timestamp).
  /// Returns null if the payload is too short to be a valid ping.
  static Packet? heartbeatPong(Uint8List pingPayload) {
    if (pingPayload.length < 9) return null;
    final pong = Uint8List.fromList(pingPayload);
    pong[0] = 0x01;
    return Packet(
      type: PacketType.heartbeat,
      timestampUs: _nowUs(),
      payload: pong,
    );
  }

  static bool heartbeatIsPong(Uint8List payload) =>
      payload.length >= 9 && payload[0] == 0x01;

  static int heartbeatOriginTs(Uint8List payload) =>
      payload.length >= 9
          ? ByteData.view(payload.buffer, payload.offsetInBytes + 1).getInt64(0, Endian.big)
          : 0;

  static int _nowUs() =>
      DateTime.now().microsecondsSinceEpoch;

  // ─── DECODE (host side reads input events from the tablet) ────────────────

  static TouchEventModel? decodeTouch(Uint8List data) {
    if (data.length < 2) return null;
    final d = ByteData.view(data.buffer, data.offsetInBytes);
    var o = 0;
    final action = TouchAction.values[d.getUint8(o++)];
    final count = d.getUint8(o++);
    final pointers = <TouchPointerModel>[];
    for (var i = 0; i < count; i++) {
      final id = d.getInt32(o, Endian.big); o += 4;
      final nx = d.getFloat32(o, Endian.big); o += 4;
      final ny = d.getFloat32(o, Endian.big); o += 4;
      final pr = d.getFloat32(o, Endian.big); o += 4;
      final ma = d.getFloat32(o, Endian.big); o += 4;
      pointers.add(TouchPointerModel(
        pointerId: id, normalizedX: nx, normalizedY: ny,
        pressure: pr, majorAxis: ma,
      ));
    }
    final ts = d.getInt64(o, Endian.big); o += 8;
    final displayId = d.getInt32(o, Endian.big);
    return TouchEventModel(
      pointers: pointers, action: action, timestampUs: ts, displayId: displayId);
  }

  static MouseEventModel? decodeMouse(Uint8List data) {
    if (data.length < 2) return null;
    final d = ByteData.view(data.buffer, data.offsetInBytes);
    var o = 0;
    final action = MouseAction.values[d.getUint8(o++)];
    final button = MouseButton.values[d.getUint8(o++)];
    final nx = d.getFloat32(o, Endian.big); o += 4;
    final ny = d.getFloat32(o, Endian.big); o += 4;
    final sdx = d.getFloat32(o, Endian.big); o += 4;
    final sdy = d.getFloat32(o, Endian.big); o += 4;
    final ts = d.getInt64(o, Endian.big);
    return MouseEventModel(
      normalizedX: nx, normalizedY: ny, button: button, action: action,
      scrollDx: sdx, scrollDy: sdy, timestampUs: ts);
  }

  static KeyEventModel? decodeKey(Uint8List data) {
    if (data.length < 9) return null;
    final d = ByteData.view(data.buffer, data.offsetInBytes);
    var o = 0;
    final keycode = d.getInt32(o, Endian.big); o += 4;
    final mods = d.getInt32(o, Endian.big); o += 4;
    final isDown = d.getUint8(o++) == 1;
    final ts = d.getInt64(o, Endian.big);
    return KeyEventModel(
      keycode: keycode, modifiers: mods, isDown: isDown, timestampUs: ts);
  }

  static void _writeInt32(BytesBuilder b, int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }

  static void _writeInt64(BytesBuilder b, int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }

  static void _writeFloat32(BytesBuilder b, double v) {
    final d = ByteData(4)..setFloat32(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }
}
