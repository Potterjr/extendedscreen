import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';

/// Mac: native remote windows (`RemoteWindowPlugin.swift`), one per device
/// id (an iPhone's capture uniqueID). Swift owns the window and its picture
/// layer; Dart decides when one opens and what ends when it closes.
///
/// [open] is idempotent: a second open of an id that has a window focuses
/// it. One window per [kind] `iphone` at a time: opening another iPhone's
/// window closes the first (its `onClosed` runs at once). Closing a window
/// (the red button, ⌘W, [close], the app quitting) reaches Dart as `closed`,
/// which runs that window's `onClosed` and takes it out of [openIds]; a
/// `closed` for an id with no window here is ignored.
///
/// A window opened with [openDriver] is driven by its [RemoteDriver]: the
/// pointer packets Swift sends on [inputChannelName] (see [RemotePointer])
/// and its `action` messages go to that driver by id, and the driver is
/// started once the window has opened and disposed once it has closed.
/// A packet or action for an id with no open window (never opened, or
/// already closed) is ignored. Its [RemoteDriver.renders] go to Swift as
/// `render {id, vm}` (each a full snapshot, every string resolved in Dart)
/// for as long as that window is open, and each of its
/// [RemoteDriver.closeRequests] closes it, as [close] does.
///
/// Each open carries a token (`token`, new for every open), which Swift
/// keeps on the window and echoes in its `closed` and `frameSize`. A message
/// whose token is not the current window's is from a window Dart has already
/// let go of: [close] then [open] of the same id can meet the first window's
/// `closed` after the second open, and it must not end the new window.
class RemoteWindowChannel extends GetxService {
  RemoteWindowChannel({
    MethodChannel? channel,
    BasicMessageChannel<ByteData?>? input,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _input =
           input ?? const BasicMessageChannel(inputChannelName, BinaryCodec()) {
    _channel.setMethodCallHandler(_onCall);
    _input.setMessageHandler(_onInput);
  }

  static const channelName = 'extended_screen/remote_window';
  static const inputChannelName = 'extended_screen/remote_window_input';

  /// The kinds of which only one window may be open at a time.
  static const singleKinds = {'iphone'};

  final MethodChannel _channel;
  final BasicMessageChannel<ByteData?> _input;

  /// The ids whose window is open (Home reads it).
  final openIds = RxSet<String>();

  /// Each open window's picture size in pixels, as Swift last reported it
  /// (informational: the capture channel's own size stays the source).
  final frameSizes = RxMap<String, Size>();

  final _windows = <String, _Window>{};
  var _nextToken = 0;

  bool isOpen(String id) => openIds.contains(id);

  /// The driver of [id]'s open window; null with none, or for a window
  /// opened without one.
  RemoteDriver? driverOf(String id) => _windows[id]?.driver;

  /// Opens [driver]'s window, or focuses it when its id has one open
  /// already (that window keeps its own driver: [driver] is not started).
  /// The driver is started once the window has opened and disposed once it
  /// closes; nothing is started when it did not open.
  Future<bool> openDriver(RemoteDriver driver) async {
    if (_windows.containsKey(driver.id)) return focus(driver.id);
    final ok = await open(
      driver.id,
      kind: driver.kind,
      title: driver.title,
      frame: driver.frameSize,
      shortcuts: driver.shortcuts,
      driver: driver,
      onClosed: () => unawaited(driver.dispose()),
    );
    // Started only while this open's window is still there: a `closed`
    // (or a close) that overtook the answer has already let it go.
    final window = _windows[driver.id];
    if (ok && window != null && identical(window.driver, driver)) {
      // Listened to before the start, whose first snapshot follows it.
      window.renders = driver.renders.listen((vm) {
        if (identical(_windows[driver.id], window)) {
          unawaited(render(driver.id, vm));
        }
      });
      // The driver asking for its window to go: only this open's window,
      // never a later open of the same id.
      window.closeRequests = driver.closeRequests.listen((_) {
        if (identical(_windows[driver.id], window)) {
          unawaited(close(driver.id));
        }
      });
      await driver.start();
    }
    return ok;
  }

  /// Opens [id]'s window, or focuses it when it is open already. [onClosed]
  /// runs once, when that window closes. False when nothing opened (no
  /// plugin, or Swift refused).
  Future<bool> open(
    String id, {
    required String kind,
    String title = '',
    Size? frame,
    Map<String, String>? shortcuts,
    RemoteDriver? driver,
    void Function()? onClosed,
  }) async {
    if (_windows.containsKey(id)) return focus(id);
    if (singleKinds.contains(kind)) {
      for (final other in [..._windows.entries]) {
        if (other.value.kind == kind) await close(other.key);
      }
    }
    // Known before the call returns, so a `closed` that overtakes the
    // answer is not lost.
    final token = ++_nextToken;
    final window = _Window(kind, token, onClosed, driver);
    _windows[id] = window;
    openIds.add(id);
    bool ok;
    try {
      ok =
          await _channel.invokeMethod<bool>('open', {
            'id': id,
            'kind': kind,
            'title': title,
            'token': token,
            if (frame != null) 'frame': [frame.width, frame.height],
            'shortcuts': ?shortcuts,
          }) ??
          false;
    } on MissingPluginException {
      ok = false;
    } on PlatformException {
      ok = false;
    }
    // Only this open's window: a later open of the id may own it by now.
    if (!ok && identical(_windows[id], window)) _forget(id, notify: false);
    return ok;
  }

  /// Draws [vm] around [id]'s picture (a full snapshot). Nothing when it
  /// has no window here.
  Future<void> render(String id, RemoteViewModel vm) async {
    if (!_windows.containsKey(id)) return;
    try {
      await _channel.invokeMethod<void>('render', {'id': id, 'vm': vm.toMap()});
    } on MissingPluginException {
      // No plugin: nothing to draw on.
    } on PlatformException {
      // The window went meanwhile: its `closed` is on its way.
    }
  }

  /// Brings [id]'s window forward. False when it has none.
  Future<bool> focus(String id) async {
    final window = _windows[id];
    if (window == null) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('focus', {'id': id}) ?? false;
      // Swift no longer has it (a `closed` still on its way): forget it,
      // unless a later open of the id has replaced it meanwhile.
      if (!ok && identical(_windows[id], window)) _forget(id);
      return ok;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Closes [id]'s window. It is forgotten (and its `onClosed` run) at once;
  /// the `closed` Swift sends after it finds nothing left to do.
  Future<bool> close(String id) async {
    if (!_windows.containsKey(id)) return false;
    _forget(id);
    try {
      return await _channel.invokeMethod<bool>('close', {'id': id}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  void _forget(String id, {bool notify = true}) {
    final w = _windows.remove(id);
    unawaited(w?.renders?.cancel());
    unawaited(w?.closeRequests?.cancel());
    openIds.remove(id);
    frameSizes.remove(id);
    if (notify) w?.onClosed?.call();
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final a = call.arguments is Map ? call.arguments as Map : const {};
    final id = a['id'];
    if (id is! String) return null;
    final window = _windows[id];
    // Another window's message (one already closed here), or none of ours.
    if (window == null || a['token'] != window.token) return null;
    switch (call.method) {
      case 'closed':
        _forget(id);
      case 'action':
        final item = a['item'];
        if (item is String && item.isNotEmpty) window.driver?.action(item);
      case 'frameSize':
        final w = a['w'];
        final h = a['h'];
        if (w is num && h is num && w > 0 && h > 0) {
          frameSizes[id] = Size(w.toDouble(), h.toDouble());
        }
    }
    return null;
  }

  /// A pointer packet: to the driver of the window it names, if that window
  /// is open here.
  Future<ByteData?> _onInput(ByteData? data) async {
    final e = RemotePointer.decode(data);
    if (e == null) return null;
    _windows[e.id]?.driver?.pointer(e);
    return null;
  }
}

class _Window {
  _Window(this.kind, this.token, this.onClosed, this.driver);
  final String kind;
  final int token;
  final void Function()? onClosed;
  final RemoteDriver? driver;

  /// The driver's [RemoteDriver.renders], while the window is open.
  StreamSubscription<RemoteViewModel>? renders;

  /// The driver's [RemoteDriver.closeRequests], while the window is open.
  StreamSubscription<void>? closeRequests;
}
