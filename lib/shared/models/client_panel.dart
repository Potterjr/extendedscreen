/// A tablet's native panel as its HELLO reports it: physical pixels in
/// landscape (the width is the long side) and its top refresh rate. The
/// fixed encode presets are sized from it, per tablet.
class ClientPanel {
  const ClientPanel(this.width, this.height, this.maxHz);

  final int width;
  final int height;
  final int maxHz;

  /// How it is kept in preferences: "width,height,maxHz".
  String encode() => '$width,$height,$maxHz';

  /// [encode]'s output back, or null for anything else.
  static ClientPanel? decode(String? text) {
    final parts = text?.split(',');
    if (parts == null || parts.length != 3) return null;
    final values = parts.map(int.tryParse).toList();
    if (values.any((v) => v == null || v <= 0)) return null;
    return ClientPanel(values[0]!, values[1]!, values[2]!);
  }

  @override
  bool operator ==(Object other) =>
      other is ClientPanel &&
      other.width == width &&
      other.height == height &&
      other.maxHz == maxHz;

  @override
  int get hashCode => Object.hash(width, height, maxHz);

  @override
  String toString() => '$width×$height@$maxHz';
}
