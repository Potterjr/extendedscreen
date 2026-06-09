enum TouchAction { down, move, up, cancel }

class TouchPointerModel {
  final int pointerId;
  final double normalizedX;
  final double normalizedY;
  final double pressure;
  final double majorAxis;

  const TouchPointerModel({
    required this.pointerId,
    required this.normalizedX,
    required this.normalizedY,
    required this.pressure,
    required this.majorAxis,
  });
}

class TouchEventModel {
  final List<TouchPointerModel> pointers;
  final TouchAction action;
  final int timestampUs;
  final int displayId;

  const TouchEventModel({
    required this.pointers,
    required this.action,
    required this.timestampUs,
    required this.displayId,
  });
}

enum MouseAction { move, down, up, scroll }

enum MouseButton { none, left, right, middle }

class MouseEventModel {
  final double normalizedX;
  final double normalizedY;
  final MouseButton button;
  final MouseAction action;
  final double scrollDx;
  final double scrollDy;
  final int timestampUs;

  const MouseEventModel({
    required this.normalizedX,
    required this.normalizedY,
    required this.button,
    required this.action,
    this.scrollDx = 0,
    this.scrollDy = 0,
    required this.timestampUs,
  });
}

class KeyEventModel {
  final int keycode;
  final int modifiers;
  final bool isDown;
  final int timestampUs;

  const KeyEventModel({
    required this.keycode,
    required this.modifiers,
    required this.isDown,
    required this.timestampUs,
  });
}
