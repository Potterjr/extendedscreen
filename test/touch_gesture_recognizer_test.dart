import 'package:extendedscreen/modules/extended_screen/client/display/controllers/touch_gesture_recognizer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _view = Size(1000, 500);

/// Drives a [TouchGestureRecognizer] with a fake clock and records every
/// callback it fires, in order.
class _Harness {
  _Harness(this.tester) {
    recognizer = TouchGestureRecognizer(
      onClick: (x, y) => log.add('click'),
      onMoveCursor: (x, y) => log.add('cursor'),
      onScroll: (dx, dy) => log.add('scroll'),
      onZoom: (dz) => log.add('zoom'),
      onDragStart: (x, y) => log.add('dragStart'),
      onDragMove: (x, y) {
        log.add('dragMove');
        lastDragMove = Offset(x, y);
      },
      onDragEnd: (x, y) {
        log.add('dragEnd');
        lastDragEnd = Offset(x, y);
      },
      onLongPressEngaged: () => log.add('longPress'),
      nowUs: () => nowUs,
    );
  }

  final WidgetTester tester;
  late final TouchGestureRecognizer recognizer;
  final List<String> log = [];
  int nowUs = 1000000;
  Offset? lastDragMove;
  Offset? lastDragEnd;

  int count(String event) => log.where((e) => e == event).length;

  /// Advances the fake clock and the test's timers together.
  Future<void> wait(int ms) async {
    nowUs += ms * 1000;
    await tester.pump(Duration(milliseconds: ms));
  }

  void down(int id, double x, double y) =>
      recognizer.down(id, Offset(x, y), _view);
  void move(int id, double x, double y) =>
      recognizer.move(id, Offset(x, y), _view);
  void up(int id, double x, double y) => recognizer.up(id, Offset(x, y), _view);

  /// Primary finger down, held past the long-press delay so the drag engages.
  Future<void> startDrag(int id, double x, double y) async {
    down(id, x, y);
    await wait(450);
    expect(count('dragStart'), 1);
  }

  /// One-finger swipe to the right, 30 px every 10 ms.
  Future<void> swipe(int id) async {
    down(id, 100, 100);
    for (var i = 1; i <= 5; i++) {
      await wait(10);
      move(id, 100 + 30.0 * i, 100);
    }
    expect(count('scroll'), 5);
  }
}

void main() {
  testWidgets('tap sends exactly one click and no drag', (tester) async {
    final h = _Harness(tester);
    h.down(1, 200, 100);
    await h.wait(50);
    h.up(1, 200, 100);
    await h.wait(600); // past the long-press delay
    expect(h.log, ['click']);
    h.recognizer.dispose();
    expect(h.log, ['click']);
  });

  testWidgets('long-press, drag, lift: one dragStart and one dragEnd', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.startDrag(1, 100, 100);
    h.move(1, 200, 100);
    await h.wait(16);
    h.move(1, 300, 250);
    await h.wait(16);
    h.up(1, 300, 250);
    expect(h.log, [
      'longPress',
      'dragStart',
      'dragMove',
      'dragMove',
      'dragEnd',
    ]);
    expect(h.lastDragEnd, const Offset(0.3, 0.5));

    // Neither disposing nor a later gesture sends a second mouse-up.
    h.recognizer.dispose();
    expect(h.count('dragEnd'), 1);
  });

  testWidgets(
    'second finger touching and lifting mid-drag does not strand the drag',
    (tester) async {
      final h = _Harness(tester);
      await h.startDrag(1, 100, 100);
      h.move(1, 150, 100);

      h.down(2, 600, 300); // palm or second finger brushes the glass
      h.move(2, 620, 300);
      h.up(2, 620, 300);
      expect(h.count('dragEnd'), 0);
      expect(h.count('zoom'), 0);

      // The drag keeps following the primary finger.
      h.move(1, 400, 200);
      expect(h.lastDragMove, const Offset(0.4, 0.4));

      h.up(1, 400, 200);
      expect(h.count('dragStart'), 1);
      expect(h.count('dragEnd'), 1);
      expect(h.lastDragEnd, const Offset(0.4, 0.4));

      h.recognizer.dispose();
      expect(h.count('dragEnd'), 1);
    },
  );

  testWidgets('second finger cancelled mid-drag does not strand the drag', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.startDrag(1, 100, 100);

    h.down(2, 600, 300);
    h.recognizer.cancel(2);
    expect(h.count('dragEnd'), 0);

    h.move(1, 500, 100);
    expect(h.lastDragMove, const Offset(0.5, 0.2));

    h.up(1, 500, 100);
    expect(h.count('dragEnd'), 1);
    h.recognizer.dispose();
    expect(h.count('dragEnd'), 1);
  });

  testWidgets('primary lifting before the extra finger ends the drag once', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.startDrag(1, 100, 100);
    h.down(2, 600, 300);

    h.up(1, 300, 100);
    expect(h.count('dragEnd'), 1);
    expect(h.lastDragEnd, const Offset(0.3, 0.2));

    // The leftover finger starts nothing and releases nothing.
    h.move(2, 700, 300);
    h.up(2, 700, 300);
    h.recognizer.dispose();
    expect(h.log, ['longPress', 'dragStart', 'dragEnd']);
  });

  testWidgets('cancelling the drag finger sends one dragEnd at its last spot', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.startDrag(1, 100, 100);
    h.move(1, 250, 100);
    h.recognizer.cancel(1);
    expect(h.count('dragEnd'), 1);
    expect(h.lastDragEnd, const Offset(0.25, 0.2));

    h.recognizer.dispose();
    expect(h.count('dragEnd'), 1);
  });

  testWidgets('disposing mid-drag releases the mouse button', (tester) async {
    final h = _Harness(tester);
    await h.startDrag(1, 100, 100);
    h.move(1, 800, 400);
    h.recognizer.dispose();
    expect(h.count('dragEnd'), 1);
    expect(h.lastDragEnd, const Offset(0.8, 0.8));
  });

  testWidgets('fast swipe released while moving starts a fling', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.swipe(1);
    await h.wait(5);
    h.up(1, 250, 100);
    final scrollsAtLift = h.count('scroll');

    await h.wait(100);
    expect(h.count('scroll'), greaterThan(scrollsAtLift));

    h.recognizer.dispose(); // stops the fling timer
  });

  testWidgets('swipe, pause, lift does not fling', (tester) async {
    final h = _Harness(tester);
    await h.swipe(1);
    await h.wait(300); // finger rests on the glass
    h.up(1, 250, 100);
    final scrollsAtLift = h.count('scroll');

    await h.wait(1000);
    expect(h.count('scroll'), scrollsAtLift);
    h.recognizer.dispose();
  });

  testWidgets('swipe, pause, lift-off micro-move, lift does not fling', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.swipe(1);
    await h.wait(300); // finger rests on the glass
    h.move(1, 251, 100); // 1 px jitter the panel reports just before lift
    await h.wait(4);
    h.up(1, 251, 100);
    final scrollsAtLift = h.count('scroll');

    await h.wait(1000);
    expect(h.count('scroll'), scrollsAtLift);
    h.recognizer.dispose();
  });

  testWidgets('swipe resumed after a pause still flings on a fast lift', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.swipe(1);
    await h.wait(300); // finger rests, then flicks again
    for (var i = 1; i <= 3; i++) {
      h.move(1, 250 + 30.0 * i, 100);
      await h.wait(10);
    }
    h.up(1, 340, 100);
    final scrollsAtLift = h.count('scroll');

    await h.wait(100);
    expect(h.count('scroll'), greaterThan(scrollsAtLift));
    h.recognizer.dispose();
  });

  testWidgets('lifting one finger of a pinch does not resume scrolling', (
    tester,
  ) async {
    final h = _Harness(tester);
    h.down(1, 400, 250);
    h.down(2, 600, 250);
    h.move(2, 700, 250);
    expect(h.count('zoom'), 1);

    h.up(2, 700, 250);
    h.move(1, 100, 250);
    h.move(1, 50, 250);
    h.up(1, 50, 250);
    await h.wait(600);
    expect(h.count('scroll'), 0);
    expect(h.count('click'), 0);
    expect(h.count('dragStart'), 0);
    h.recognizer.dispose();
  });
}
