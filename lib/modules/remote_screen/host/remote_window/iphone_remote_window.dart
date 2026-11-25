import 'dart:async';
import 'dart:ui' show Size;

import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_view_model.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_driver.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// An iPhone's or iPad's native remote window: the [RemoteDriver] that wraps
/// [IphoneRemoteController] unchanged. The controller is put with the
/// device id as its tag when the window opens ([start]) and deleted when it
/// closes ([dispose]), whose `onClose` stops that device's capture and the
/// touch link: closing the window ends the session.
///
/// Pointer packets become the controller's `onPointer*` calls (the picture
/// box and Shift; the event's time goes
/// only to the probe). Action items: `home`, `system:<i>` (an
/// [IphoneSystemGesture] by index), `retry`, `probe:<script>` (a
/// [ProbeScript] by name). ⌘1 is Home and ⌘2 to ⌘5 the system gestures.
///
/// Its chrome is [IphoneRemoteViewModel], pushed as
/// [renders] while the window is open: worked out again a microtask after
/// any observable it read changed (the controller's, the touch link's, the
/// capture channel's, and the app's language, `SettingsService.localeCode`,
/// since `.tr` reads no observable), so several changes in one turn make
/// one snapshot, and one equal to the last is not sent again.
class IphoneRemoteWindow extends RemoteDriver {
  IphoneRemoteWindow(
    this.id, {
    this.title = '',
    IphoneRemoteController Function(String id)? create,
  }) : _create = create;

  @override
  final String id;

  @override
  final String title;

  @override
  String get kind => 'iphone';

  /// Makes the controller (tests pass one on their clock); by default the
  /// app's, with the native window as its sink.
  final IphoneRemoteController Function(String id)? _create;

  IphoneRemoteController? _controller;
  bool _disposed = false;

  final _renders = StreamController<RemoteViewModel>.broadcast(sync: true);

  /// Follows every observable the last model read (as an `Obx` does).
  RxNotifier<dynamic>? _observer;
  StreamSubscription<dynamic>? _observerSub;
  bool _renderDue = false;
  RemoteViewModel? _last;

  @override
  Stream<RemoteViewModel> get renders => _renders.stream;

  /// The last snapshot sent; null before the first.
  RemoteViewModel? get lastRender => _last;

  /// The controller while the window is open; null before [start] and after
  /// [dispose].
  IphoneRemoteController? get controller => _controller;

  @override
  Size? get frameSize => Get.isRegistered<IosScreenChannel>()
      ? Get.find<IosScreenChannel>().frameSizes[id]
      : null;

  @override
  Map<String, String> get shortcuts => {
    '1': 'home',
    for (var i = 0; i < IphoneSystemGesture.values.length; i++)
      '${i + 2}': 'system:$i',
  };

  @override
  Future<void> start() async {
    if (_controller != null || _disposed) return;
    final c = _create?.call(id) ?? IphoneRemoteController(deviceId: id);
    // The type named: inferred from [_controller] it would be the nullable
    // one, a different key that `Get.find` and `Get.delete` never see.
    _controller = Get.put<IphoneRemoteController>(c, tag: id);
    final observer = _observer = RxNotifier<dynamic>();
    _observerSub = observer.listen((_) => _renderSoon());
    _renderSoon();
  }

  /// One render a microtask from now, however many changes come before it.
  void _renderSoon() {
    if (_renderDue || _disposed) return;
    _renderDue = true;
    scheduleMicrotask(_render);
  }

  void _render() {
    _renderDue = false;
    final c = _controller;
    final observer = _observer;
    if (_disposed || c == null || c.isClosed || observer == null) return;
    final vm = RxInterface.notifyChildren(observer, () {
      // `.tr` reads `Get.locale`, no observable: the language is followed
      // through the setting that changes it.
      if (Get.isRegistered<SettingsService>()) {
        Get.find<SettingsService>().localeCode.value;
      }
      return IphoneRemoteViewModel.from(c, c.touch, c.screen, title: title);
    });
    if (vm.sameAs(_last)) return;
    _last = vm;
    _renders.add(vm);
  }

  @override
  void pointer(RemotePointer e) {
    final c = _controller;
    if (c == null || c.isClosed) return;
    switch (e.kind) {
      case RemotePointerKind.down:
        c.onPointerDown(e.at, e.box, shift: e.shift, eventUs: e.eventUs);
      case RemotePointerKind.move:
        c.onPointerMove(e.at);
      case RemotePointerKind.up:
        unawaited(c.onPointerUp(e.at));
      case RemotePointerKind.cancel:
        unawaited(c.onPointerCancel());
    }
  }

  @override
  void action(String item) {
    final c = _controller;
    if (c == null || c.isClosed) return;
    if (item == 'home') {
      unawaited(c.onHome());
    } else if (item == 'retry') {
      unawaited(c.retry());
    } else if (item.startsWith('system:')) {
      final i = int.tryParse(item.substring('system:'.length));
      if (i != null && i >= 0 && i < IphoneSystemGesture.values.length) {
        unawaited(c.onSystem(IphoneSystemGesture.values[i]));
      }
    } else if (item.startsWith('probe:')) {
      final script = ProbeScript.values.firstWhereOrNull(
        (s) => s.name == item.substring('probe:'.length),
      );
      if (script != null) unawaited(c.runProbe(script));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    unawaited(_observerSub?.cancel());
    _observerSub = null;
    _observer?.close();
    _observer = null;
    unawaited(_renders.close());
    if (_controller == null) return;
    _controller = null;
    // Its onClose stops this device's capture and the touch link.
    if (Get.isRegistered<IphoneRemoteController>(tag: id)) {
      Get.delete<IphoneRemoteController>(tag: id, force: true);
    }
  }
}
