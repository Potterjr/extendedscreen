import 'dart:typed_data';

enum PacketType {
  frameData(0x01),
  touchEvent(0x02),
  mouseEvent(0x03),
  keyEvent(0x04),
  control(0x05),
  ack(0x06),
  displayConfig(0x07),
  heartbeat(0x08);

  final int value;
  const PacketType(this.value);

  static PacketType fromByte(int byte) =>
      PacketType.values.firstWhere((t) => t.value == byte,
          orElse: () => PacketType.control);
}

class Packet {
  static const magic = 0x45585444; // 'EXTD'
  static const headerSize = 17; // 4 magic + 1 type + 4 length + 8 timestamp

  final PacketType type;
  final int timestampUs;
  final Uint8List payload;

  const Packet({
    required this.type,
    required this.timestampUs,
    required this.payload,
  });

  Uint8List serialize() {
    final out = Uint8List(headerSize + payload.length);
    final hdr = ByteData.view(out.buffer);
    hdr.setUint32(0, magic, Endian.big);
    hdr.setUint8(4, type.value);
    hdr.setUint32(5, payload.length, Endian.big);
    hdr.setInt64(9, timestampUs, Endian.big);
    out.setAll(headerSize, payload);
    return out;
  }

  static Packet? tryParse(Uint8List data) {
    if (data.length < headerSize) return null;
    final buf = ByteData.view(data.buffer, data.offsetInBytes);
    if (buf.getUint32(0, Endian.big) != magic) return null;
    final type = PacketType.fromByte(buf.getUint8(4));
    final length = buf.getUint32(5, Endian.big);
    final ts = buf.getInt64(9, Endian.big);
    if (data.length < headerSize + length) return null;
    final payload = data.sublist(headerSize, headerSize + length);
    return Packet(type: type, timestampUs: ts, payload: payload);
  }
}
