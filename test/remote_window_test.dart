import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_window_channel.dart';

/// The native remote window's Dart side (`RemoteWindowChannel`) against a
/// mocked `extended_screen/remote_window` channel: open is idempotent and
/// focuses, `closed` removes the window, one iPhone window at a time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(RemoteWindowChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Set<String> swiftWindows;

  setUp(() {
    calls = [];
    swiftWindows = {};
    // Plays RemoteWindowPlugin: a window per id; `close` answers whether one
    // existed (its `closed` is sent by the test where it matters).
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final id = (call.arguments as Map)['id'] as String;
      switch (call.method) {
        case 'open':
          swiftWindows.add(id);
          return true;
        case 'focus':
          return swiftWindows.contains(id);
        case 'close':
          return swiftWindows.remove(id);
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Swift → Dart: [method] with [args], as the plugin sends it.
  Future<void> fromSwift(String method, Map<String, Object?> args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await messenger.handlePlatformMessage(
      RemoteWindowChannel.channelName,
      data,
      (_) {},
    );
  }

  /// The token of the last `open` Dart sent for [id] (what Swift echoes).
  Object? tokenOf(String id) => calls
      .lastWhere((c) => c.method == 'open' && (c.arguments as Map)['id'] == id)
      .arguments['token'];

  test(
    'open sends the id, kind, title, token and frame, and marks it open',
    () async {
      final w = RemoteWindowChannel(channel: channel);
      expect(
        await w.open(
          'dev-1',
          kind: 'iphone',
          title: 'iPhone',
          frame: const Size(1290, 2796),
        ),
        isTrue,
      );
      expect(calls.single.method, 'open');
      expect(calls.single.arguments, {
        'id': 'dev-1',
        'kind': 'iphone',
        'title': 'iPhone',
        'token': isA<int>(),
        'frame': [1290.0, 2796.0],
      });
      expect(w.isOpen('dev-1'), isTrue);
      expect(w.openIds, {'dev-1'});
    },
  );

  test('a second open of the same id focuses that window', () async {
    final w = RemoteWindowChannel(channel: channel);
    var closedRuns = 0;
    await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
    expect(await w.open('dev-1', kind: 'iphone'), isTrue);
    expect(calls.map((c) => c.method), ['open', 'focus']);
    expect(calls.last.arguments, {'id': 'dev-1'});
    expect(w.openIds, {'dev-1'});
    expect(closedRuns, 0);
  });

  test('closed removes the window and runs its onClosed once', () async {
    final w = RemoteWindowChannel(channel: channel);
    var closedRuns = 0;
    await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
    swiftWindows.remove('dev-1');
    await fromSwift('closed', {'id': 'dev-1', 'token': tokenOf('dev-1')});
    expect(w.isOpen('dev-1'), isFalse);
    expect(closedRuns, 1);

    // A late repeat changes nothing, and the next open makes a new window.
    await fromSwift('closed', {'id': 'dev-1', 'token': tokenOf('dev-1')});
    expect(closedRuns, 1);
    await w.open('dev-1', kind: 'iphone');
    expect(calls.map((c) => c.method), ['open', 'open']);
  });

  test('a closed for an id with no window is ignored', () async {
    final w = RemoteWindowChannel(channel: channel);
    var closedRuns = 0;
    await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
    await fromSwift('closed', {'id': 'dev-2'});
    await fromSwift('closed', {'nothing': 1});
    expect(w.openIds, {'dev-1'});
    expect(closedRuns, 0);
  });

  test(
    'close forgets the window at once and the closed after it is a no-op',
    () async {
      final w = RemoteWindowChannel(channel: channel);
      var closedRuns = 0;
      await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
      expect(await w.close('dev-1'), isTrue);
      expect(calls.last.method, 'close');
      expect(w.isOpen('dev-1'), isFalse);
      expect(closedRuns, 1);
      await fromSwift('closed', {'id': 'dev-1', 'token': tokenOf('dev-1')});
      expect(closedRuns, 1);
      expect(await w.close('dev-1'), isFalse);
    },
  );

  test(
    'a late closed of a window closed and opened again leaves the new one',
    () async {
      final w = RemoteWindowChannel(channel: channel);
      final closed = <String>[];
      await w.open(
        'dev-1',
        kind: 'iphone',
        onClosed: () => closed.add('first'),
      );
      final first = tokenOf('dev-1');
      // Dart closes and at once opens the same id again; Swift's `closed` for
      // the first window only arrives after the second open.
      expect(await w.close('dev-1'), isTrue);
      expect(
        await w.open(
          'dev-1',
          kind: 'iphone',
          onClosed: () => closed.add('second'),
        ),
        isTrue,
      );
      final second = tokenOf('dev-1');
      expect(second, isNot(first));
      await fromSwift('closed', {'id': 'dev-1', 'token': first});
      expect(w.isOpen('dev-1'), isTrue);
      expect(closed, ['first']);
      // Nor does the first window's late frame size reach the new one.
      await fromSwift('frameSize', {
        'id': 'dev-1',
        'token': first,
        'w': 5,
        'h': 5,
      });
      expect(w.frameSizes, isEmpty);

      // The new window's own closed still ends it.
      await fromSwift('closed', {'id': 'dev-1', 'token': second});
      expect(w.isOpen('dev-1'), isFalse);
      expect(closed, ['first', 'second']);
    },
  );

  test(
    'a closed or frameSize with no token or a foreign one is ignored',
    () async {
      final w = RemoteWindowChannel(channel: channel);
      var closedRuns = 0;
      await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
      await fromSwift('closed', {'id': 'dev-1'});
      await fromSwift('closed', {'id': 'dev-1', 'token': 'x'});
      await fromSwift('frameSize', {'id': 'dev-1', 'w': 10, 'h': 10});
      expect(w.isOpen('dev-1'), isTrue);
      expect(w.frameSizes, isEmpty);
      expect(closedRuns, 0);
    },
  );

  test('a focus answered after the window was closed and reopened keeps the '
      'new one', () async {
    final w = RemoteWindowChannel(channel: channel);
    final focusAnswer = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'focus') return focusAnswer.future;
      return true;
    });
    final closed = <String>[];
    await w.open('dev-1', kind: 'iphone', onClosed: () => closed.add('first'));
    final focusing = w.focus('dev-1');
    await w.close('dev-1');
    await w.open('dev-1', kind: 'iphone', onClosed: () => closed.add('second'));
    focusAnswer.complete(false); // about the first window
    expect(await focusing, isFalse);
    expect(w.isOpen('dev-1'), isTrue);
    expect(closed, ['first']);
  });

  test('a focus Swift no longer knows forgets the window', () async {
    final w = RemoteWindowChannel(channel: channel);
    var closedRuns = 0;
    await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++);
    swiftWindows.remove('dev-1'); // its closed is still on its way
    expect(await w.open('dev-1', kind: 'iphone'), isFalse);
    expect(w.isOpen('dev-1'), isFalse);
    expect(closedRuns, 1);
  });

  test(
    'one iPhone window at a time: another iPhone closes the first',
    () async {
      final w = RemoteWindowChannel(channel: channel);
      final closed = <String>[];
      await w.open(
        'dev-1',
        kind: 'iphone',
        onClosed: () => closed.add('dev-1'),
      );
      await w.open(
        'dev-2',
        kind: 'iphone',
        onClosed: () => closed.add('dev-2'),
      );
      expect(calls.map((c) => '${c.method} ${(c.arguments as Map)['id']}'), [
        'open dev-1',
        'close dev-1',
        'open dev-2',
      ]);
      expect(closed, ['dev-1']);
      expect(w.openIds, {'dev-2'});
    },
  );

  test('another kind leaves an iPhone window open', () async {
    final w = RemoteWindowChannel(channel: channel);
    await w.open('dev-1', kind: 'iphone');
    await w.open('tab-1', kind: 'tablet');
    expect(w.openIds, {'dev-1', 'tab-1'});
    expect(calls.map((c) => c.method), ['open', 'open']);
  });

  test('frameSize is kept for an open window only', () async {
    final w = RemoteWindowChannel(channel: channel);
    await w.open('dev-1', kind: 'iphone');
    await fromSwift('frameSize', {
      'id': 'dev-1',
      'token': tokenOf('dev-1'),
      'w': 2796,
      'h': 1290,
    });
    await fromSwift('frameSize', {'id': 'dev-2', 'w': 10, 'h': 10});
    expect(w.frameSizes, {'dev-1': const Size(2796, 1290)});
    await fromSwift('closed', {'id': 'dev-1', 'token': tokenOf('dev-1')});
    expect(w.frameSizes, isEmpty);
  });

  test('with no plugin nothing is open', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final w = RemoteWindowChannel(channel: channel);
    var closedRuns = 0;
    expect(
      await w.open('dev-1', kind: 'iphone', onClosed: () => closedRuns++),
      isFalse,
    );
    expect(w.isOpen('dev-1'), isFalse);
    expect(closedRuns, 0);
    expect(await w.focus('dev-1'), isFalse);
    expect(await w.close('dev-1'), isFalse);
  });

  // The window's Swift cannot be run here, so its one rule that a device
  // check found is held by its source: the picture must not run under the
  // titlebar, whose view takes every press in that strip as a window drag
  // (a phone's status bar could not be pulled or tapped).
  test('the remote window keeps its picture out of the titlebar', () {
    final source = File(
      'macos/Runner/RemoteWindowController.swift',
    ).readAsStringSync();
    final mask = RegExp(
      r'static let styleMask: NSWindow\.StyleMask = \[([^\]]*)\]',
    ).firstMatch(source);
    expect(mask, isNotNull, reason: 'styleMask declared once, as a literal');
    expect(mask!.group(1), isNot(contains('fullSizeContentView')));
    expect(mask.group(1), contains('.titled'));
    expect(source, contains('styleMask: Self.styleMask'));
    expect(
      RegExp(r'^[^/]*\.fullSizeContentView', multiLine: true).hasMatch(source),
      isFalse,
      reason: 'no code line adds .fullSizeContentView',
    );
  });

  // The titlebar accessory must never run into the traffic lights (the close
  // button is how the session ends): a chip's text is capped and cut, the
  // accessory is sized to the titlebar's free width on every render and
  // resize, folding to icon chips and then one menu, and the window's
  // minimum width keeps room for the folded toolbar.
  test('the remote window bounds its titlebar accessory', () {
    final source = File(
      'macos/Runner/RemoteWindowController.swift',
    ).readAsStringSync();
    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: signature);
      final end = source.indexOf('\n    }\n', start);
      return source.substring(start, end);
    }

    // The chip's text: capped, compressible below the cap, truncated.
    expect(source, contains('static let chipTextMaxWidth: CGFloat = 100'));
    expect(
      source,
      contains(
        'label.widthAnchor.constraint(lessThanOrEqualToConstant: '
        'Self.chipTextMaxWidth)',
      ),
    );
    expect(
      source,
      contains(
        'label.setContentCompressionResistancePriority(.defaultLow, '
        'for: .horizontal)',
      ),
    );
    // The fits, widest first, and the choice among them.
    expect(
      source,
      contains('enum Fit: Int, CaseIterable { case full, iconChips, folded }'),
    );
    // The accessory is fitted, never set to its full fittingSize, on render
    // and on resize, against the width right of the zoom button.
    expect(body('func render('), contains('fitToolbar()'));
    expect(body('func render('), isNot(contains('fittingSize')));
    expect(body('func windowDidResize('), contains('fitToolbar()'));
    expect(body('func apply(frameSize'), contains('fitToolbar()'));
    final fit = body('private func fitToolbar()');
    expect(fit, contains('window.frame.width - trafficLightsEnd()'));
    expect(fit, contains('toolbar.fit(into: available)'));
    expect(fit, contains('toolbar.minimumWidth + trafficLightsEnd()'));
    expect(
      body('private func trafficLightsEnd()'),
      contains('standardWindowButton(.zoomButton)'),
    );
    // The minimum content width holds the folded toolbar; apply(frameSize:)
    // no longer sets contentMinSize from the short side alone.
    final min = body('private func updateMinSize()');
    expect(min, contains('toolbarMinWidth / size.width'));
    expect(min, contains('window.contentMinSize = least'));
    expect(
      RegExp(r'contentMinSize = ').allMatches(source),
      hasLength(1),
      reason: 'only updateMinSize sets it',
    );
    // The folded menu's label comes from Dart (Swift holds no strings).
    expect(source, contains('more = vm["more"] as? String ?? ""'));
  });

  test('render sends the whole snapshot to an open window only', () async {
    final w = RemoteWindowChannel(channel: channel);
    const vm = RemoteViewModel(
      title: 'iPhone',
      toolbar: [RemoteToolbarItem(id: 'home', symbol: 'house', shortcut: '1')],
      message: RemoteMessage(
        text: 'Plug it in',
        action: RemoteMenuEntry(id: 'retry', label: 'Retry'),
      ),
    );
    await w.render('dev-1', vm);
    expect(calls, isEmpty, reason: 'no window yet');
    await w.open('dev-1', kind: 'iphone');
    await w.render('dev-1', vm);
    expect(calls.last.method, 'render');
    expect(calls.last.arguments, {
      'id': 'dev-1',
      'vm': {
        'title': 'iPhone',
        'toolbar': [
          {
            'id': 'home',
            'symbol': 'house',
            'tooltip': '',
            'enabled': true,
            'tint': 'normal',
            'kind': 'button',
            'shortcut': '1',
          },
        ],
        'message': {
          'text': 'Plug it in',
          'action': {'id': 'retry', 'label': 'Retry'},
        },
      },
    });
    expect(vm.sameAs(const RemoteViewModel(title: 'iPhone')), isFalse);
    await w.close('dev-1');
    calls.clear();
    await w.render('dev-1', vm);
    expect(calls, isEmpty, reason: 'closed');
  });

  test('symbol and passThrough are sent when set and tell snapshots apart', () {
    const plain = RemoteViewModel(
      title: 'Tab',
      message: RemoteMessage(text: 'Waiting'),
    );
    // The defaults add nothing to the map (the iPhone's renders unchanged).
    expect(plain.toMap(), {
      'title': 'Tab',
      'toolbar': <Object?>[],
      'message': {'text': 'Waiting'},
    });
    expect(plain.symbol, 'iphone');
    expect(plain.message!.passThrough, isFalse);
    expect(
      plain.sameAs(
        const RemoteViewModel(
          title: 'Tab',
          symbol: 'iphone',
          message: RemoteMessage(text: 'Waiting'),
        ),
      ),
      isTrue,
      reason: 'the default symbol given explicitly is the same snapshot',
    );

    const tablet = RemoteViewModel(
      title: 'Tab',
      symbol: 'ipad.landscape',
      message: RemoteMessage(
        text: 'Waiting',
        passThrough: true,
        action: RemoteMenuEntry(id: 'retry', label: 'Retry'),
      ),
    );
    expect(tablet.toMap(), {
      'title': 'Tab',
      'toolbar': <Object?>[],
      'message': {
        'text': 'Waiting',
        'action': {'id': 'retry', 'label': 'Retry'},
        'passThrough': true,
      },
      'symbol': 'ipad.landscape',
    });
    // Through the channel's codec, as Swift receives it.
    const codec = StandardMethodCodec();
    final back =
        codec
                .decodeMethodCall(
                  codec.encodeMethodCall(
                    MethodCall('render', {'id': 'x', 'vm': tablet.toMap()}),
                  ),
                )
                .arguments
            as Map;
    final vm = back['vm'] as Map;
    expect(vm['symbol'], 'ipad.landscape');
    expect((vm['message'] as Map)['passThrough'], isTrue);

    expect(tablet.sameAs(plain), isFalse);
    expect(
      tablet.sameAs(
        const RemoteViewModel(
          title: 'Tab',
          message: RemoteMessage(
            text: 'Waiting',
            passThrough: true,
            action: RemoteMenuEntry(id: 'retry', label: 'Retry'),
          ),
        ),
      ),
      isFalse,
      reason: 'the symbol counts',
    );
    expect(
      tablet.sameAs(
        const RemoteViewModel(
          title: 'Tab',
          symbol: 'ipad.landscape',
          message: RemoteMessage(
            text: 'Waiting',
            action: RemoteMenuEntry(id: 'retry', label: 'Retry'),
          ),
        ),
      ),
      isFalse,
      reason: 'passThrough counts',
    );
  });

  test('Swift reads symbol and passThrough from the snapshot', () {
    final source = File(
      'macos/Runner/RemoteWindowController.swift',
    ).readAsStringSync();
    expect(source, contains('vm["symbol"] as? String'));
    expect(source, contains('message?["passThrough"] as? Bool ?? false'));
  });

  group('closeRequests', () {
    test(
      'a driver asking to close closes its window and is disposed',
      () async {
        final w = RemoteWindowChannel(channel: channel);
        final d = _Driver('dev-1');
        expect(await w.openDriver(d), isTrue);
        expect(d.started, 1);
        final token = tokenOf('dev-1');
        calls.clear();

        d.requestClose();
        await pumpEventQueue();
        expect(calls.map((c) => c.method), ['close']);
        expect((calls.single.arguments as Map)['id'], 'dev-1');
        expect(w.isOpen('dev-1'), isFalse);
        expect(d.disposed, 1);
        expect(d.closeListened, isFalse, reason: 'unsubscribed on close');

        // Swift's `closed` for that window comes after: nothing more.
        await fromSwift('closed', {'id': 'dev-1', 'token': token});
        expect(d.disposed, 1);
      },
    );

    test('a driver with no requests keeps its window', () async {
      final w = RemoteWindowChannel(channel: channel);
      final d = _Driver('dev-1', closable: false);
      await w.openDriver(d);
      await pumpEventQueue();
      expect(w.isOpen('dev-1'), isTrue);
      expect(d.disposed, 0);
    });

    test('a closed window\'s late request leaves a new window of the id alone, '
        'as a late closed with its token does', () async {
      final w = RemoteWindowChannel(channel: channel);
      final first = _Driver('dev-1');
      await w.openDriver(first);
      final firstToken = tokenOf('dev-1');
      first.requestClose();
      await pumpEventQueue();
      expect(w.isOpen('dev-1'), isFalse);
      expect(first.disposed, 1);

      final second = _Driver('dev-1');
      await w.openDriver(second);
      expect(tokenOf('dev-1'), isNot(firstToken));
      calls.clear();

      // The first driver asks again, and Swift's `closed` for the first
      // window arrives late: neither touches the second.
      first.requestClose();
      await fromSwift('closed', {'id': 'dev-1', 'token': firstToken});
      await pumpEventQueue();
      expect(calls.where((c) => c.method == 'close'), isEmpty);
      expect(w.isOpen('dev-1'), isTrue);
      expect(identical(w.driverOf('dev-1'), second), isTrue);
      expect(second.disposed, 0);

      // The second's own request still closes it.
      second.requestClose();
      await pumpEventQueue();
      expect(w.isOpen('dev-1'), isFalse);
      expect(second.disposed, 1);
    });

    test('a request after the window closed from Swift does nothing', () async {
      final w = RemoteWindowChannel(channel: channel);
      final d = _Driver('dev-1');
      await w.openDriver(d);
      await fromSwift('closed', {'id': 'dev-1', 'token': tokenOf('dev-1')});
      expect(d.disposed, 1);
      calls.clear();
      d.requestClose();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });
}

/// A driver that records its life and can ask for its window to close.
class _Driver extends RemoteDriver {
  _Driver(this.id, {this.closable = true});

  @override
  final String id;

  final bool closable;

  int started = 0;
  int disposed = 0;

  final _close = StreamController<void>.broadcast(sync: true);
  final _renders = StreamController<RemoteViewModel>.broadcast();

  bool get closeListened => _close.hasListener;

  void requestClose() => _close.add(null);

  @override
  Stream<void> get closeRequests =>
      closable ? _close.stream : super.closeRequests;

  @override
  String get kind => 'tablet';

  @override
  String get title => id;

  @override
  Size? get frameSize => null;

  @override
  Map<String, String> get shortcuts => const {};

  @override
  Stream<RemoteViewModel> get renders => _renders.stream;

  @override
  void pointer(RemotePointer e) {}

  @override
  void action(String item) {}

  @override
  Future<void> start() async => started++;

  @override
  Future<void> dispose() async => disposed++;
}
