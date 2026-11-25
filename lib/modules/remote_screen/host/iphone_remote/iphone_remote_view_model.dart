import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_controller.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_window/remote_view_model.dart';

/// What an iPhone's remote view shows around its picture, worked out from
/// the controller, the touch link and the capture channel alone: the
/// native window's `render` payload. Every string is resolved here
/// (`.tr` against the current locale); nothing else is read.
///
/// Toolbar items, left to right:
/// - `probe` (a `menu`, only with the probe on): `probe:tap`, `probe:swipe`;
/// - `gestures` (a `chip` with no text: the tooltip explains the mouse);
/// - `home` (⌘1), orange with its own tooltip once the phone refused it;
/// - `system:<i>` (⌘2 to ⌘5, an [IphoneSystemGesture] by index), orange
///   once refused, with a "needs a newer runner" tooltip when the link is up
///   but the runner lacks its verb;
/// - `touch` (a `chip`): where the touch link stands, green when ready,
///   with the drop count as its tooltip.
///
/// The banner (a runner that does not answer, or answers wrong, and a second
/// phone) lies over the picture; with no picture there is the message
/// instead (by [IphoneRemoteController.screenState], with Retry when the
/// phone is missing, the Camera permission was refused or the start failed).
abstract final class IphoneRemoteViewModel {
  /// The ⌘ digit of Home (null) and of each system gesture, as iPhone
  /// Mirroring has them (⌘1 Home, ⌘2 App Switcher, ⌘3 Spotlight, ⌘4 Control
  /// Center); ⌘5 Notification Center is ours.
  static const shortcutDigits = {
    null: '1',
    IphoneSystemGesture.switcher: '2',
    IphoneSystemGesture.spotlight: '3',
    IphoneSystemGesture.controlCenter: '4',
    IphoneSystemGesture.notifications: '5',
  };

  /// The action item of [g] (`system:<index>`).
  static String systemItem(IphoneSystemGesture g) => 'system:${g.index}';

  /// The SF Symbols of the items, as the window draws them.
  static const homeSymbol = 'house';
  static const gesturesSymbol = 'computermouse';
  static const probeSymbol = 'speedometer';
  static const touchReadySymbol = 'hand.tap';
  static const touchWaitingSymbol = 'arrow.triangle.2.circlepath';
  static const touchOffSymbol = 'hand.raised.slash';

  static String symbolFor(IphoneSystemGesture g) => switch (g) {
    IphoneSystemGesture.switcher => 'rectangle.stack',
    IphoneSystemGesture.spotlight => 'magnifyingglass',
    IphoneSystemGesture.controlCenter => 'switch.2',
    IphoneSystemGesture.notifications => 'bell',
  };

  static String labelFor(IphoneSystemGesture g) => switch (g) {
    IphoneSystemGesture.switcher => 'iphone_remote_switcher'.tr,
    IphoneSystemGesture.spotlight => 'iphone_remote_spotlight'.tr,
    IphoneSystemGesture.controlCenter => 'iphone_remote_control_center'.tr,
    IphoneSystemGesture.notifications => 'iphone_remote_notifications'.tr,
  };

  /// The touch chip's text for [state].
  static String touchLabel(IosTouchState state) => switch (state) {
    IosTouchState.ready => 'iphone_remote_touch_ready'.tr,
    IosTouchState.reconnecting => 'iphone_touch_reconnecting'.tr,
    IosTouchState.noRunner => 'iphone_touch_no_runner'.tr,
    IosTouchState.runnerRefused => 'iphone_touch_refused'.tr,
    IosTouchState.severalDevices => 'iphone_touch_several'.tr,
    IosTouchState.noDevice => 'iphone_touch_no_device'.tr,
    IosTouchState.idle => 'iphone_remote_touch_off'.tr,
  };

  /// [label] with its shortcut, as tooltips show it.
  static String withShortcut(String label, String digit) => '$label  ⌘$digit';

  /// Whether the picture is up: a frame has come.
  static bool hasPicture(IphoneRemoteController c, IosScreenChannel screen) =>
      screen.frameSize.value != null;

  /// The model of [c]'s view. [probe] shows the probe menu and overlay
  /// (the controller's own flag when null); [title] is the window's (the
  /// phone's name), else `iphone_remote_title`.
  static RemoteViewModel from(
    IphoneRemoteController c,
    IosTouchService touch,
    IosScreenChannel screen, {
    bool? probe,
    String? title,
  }) {
    final probeOn = probe ?? c.probeEnabled;
    final state = touch.state.value;
    final picture = hasPicture(c, screen);
    return RemoteViewModel(
      title: title == null || title.isEmpty ? 'iphone_remote_title'.tr : title,
      toolbar: [
        if (probeOn)
          RemoteToolbarItem(
            id: 'probe',
            kind: RemoteItemKind.menu,
            symbol: probeSymbol,
            tooltip: 'iphone_probe_menu'.tr,
            enabled: !c.scripting.value,
            menu: [
              for (final s in ProbeScript.values)
                RemoteMenuEntry(
                  id: 'probe:${s.name}',
                  label: switch (s) {
                    ProbeScript.tap => 'iphone_probe_run_tap',
                    ProbeScript.swipe => 'iphone_probe_run_swipe',
                  }.trParams({'n': '${IphoneRemoteController.probeTrials}'}),
                ),
            ],
          ),
        RemoteToolbarItem(
          id: 'gestures',
          kind: RemoteItemKind.chip,
          symbol: gesturesSymbol,
          tooltip: 'iphone_remote_gestures'.tr,
        ),
        _home(c),
        for (final g in IphoneSystemGesture.values) _system(c, state, g),
        _touchChip(state, touch.dropped.value),
      ],
      banner: picture ? _banner(state) : null,
      message: picture ? null : _message(c.screenState.value),
      overlay: probeOn ? _overlay(c) : null,
      more: 'remote_window_more'.tr,
    );
  }

  static RemoteToolbarItem _home(IphoneRemoteController c) {
    final failed = c.homeFailed.value;
    return RemoteToolbarItem(
      id: 'home',
      symbol: homeSymbol,
      shortcut: shortcutDigits[null],
      enabled: c.canHome,
      tint: failed ? RemoteTint.warn : RemoteTint.normal,
      tooltip: failed
          ? 'iphone_remote_home_failed'.tr
          : withShortcut('iphone_remote_home'.tr, shortcutDigits[null]!),
    );
  }

  static RemoteToolbarItem _system(
    IphoneRemoteController c,
    IosTouchState state,
    IphoneSystemGesture g,
  ) {
    final label = labelFor(g);
    final enabled = c.canSystem(g);
    final failed = c.systemFailed.contains(g) && enabled;
    final digit = shortcutDigits[g]!;
    return RemoteToolbarItem(
      id: systemItem(g),
      symbol: symbolFor(g),
      shortcut: digit,
      enabled: enabled,
      tint: failed ? RemoteTint.warn : RemoteTint.normal,
      tooltip: failed
          ? 'iphone_remote_gesture_failed'.trParams({'name': label})
          : state == IosTouchState.ready && !enabled
          ? 'iphone_remote_gesture_needs_runner'.trParams({'name': label})
          : withShortcut(label, digit),
    );
  }

  static RemoteToolbarItem _touchChip(IosTouchState state, int dropped) {
    final ready = state == IosTouchState.ready;
    return RemoteToolbarItem(
      id: 'touch',
      kind: RemoteItemKind.chip,
      symbol: ready
          ? touchReadySymbol
          : state == IosTouchState.reconnecting
          ? touchWaitingSymbol
          : touchOffSymbol,
      text: touchLabel(state),
      color: ready ? RemoteChipColor.green : RemoteChipColor.orange,
      tooltip: dropped == 0
          ? ''
          : 'iphone_touch_dropped'.trParams({'n': '$dropped'}),
    );
  }

  /// Only what the user has to act on is worth a word over the picture (a
  /// runner that does not answer, or answers wrong, and a second phone):
  /// before the first try, and while the phone is briefly off usbmuxd (it
  /// is, each time its capture starts: reconnecting, which the chip says),
  /// the runner may well be running.
  static String? _banner(IosTouchState state) => switch (state) {
    IosTouchState.noRunner => 'iphone_remote_runner_missing'.tr,
    IosTouchState.runnerRefused => 'iphone_remote_runner_refused'.tr,
    IosTouchState.severalDevices => 'iphone_remote_several'.tr,
    _ => null,
  };

  static RemoteMessage _message(IphoneScreenState state) => RemoteMessage(
    text: switch (state) {
      IphoneScreenState.noDevice => 'iphone_remote_no_device'.tr,
      IphoneScreenState.permissionDenied => 'iphone_remote_permission'.tr,
      IphoneScreenState.failed => 'iphone_remote_failed'.tr,
      _ => 'iphone_remote_waiting'.tr,
    },
    action: switch (state) {
      IphoneScreenState.noDevice ||
      IphoneScreenState.permissionDenied ||
      IphoneScreenState.failed => RemoteMenuEntry(
        id: 'retry',
        label: 'common_retry'.tr,
      ),
      _ => null,
    },
  );

  static String _ms(double? v) => v == null ? '–' : v.toStringAsFixed(0);

  static String _stats(ProbeSummary s) => 'iphone_probe_stats'.trParams({
    'n': '${s.count}',
    'p50': _ms(s.p50),
    'p90': _ms(s.p90),
  });

  /// The felt probe's p50/p90 over its last results, and the scripted run's.
  static List<String> _overlay(IphoneRemoteController c) {
    c.probeRevision.value;
    final script = c.script;
    final kind = c.scriptKind;
    return [
      '${'iphone_probe_felt'.tr} ${_stats(c.felt)}'
          ' · ${'iphone_probe_last'.tr} ${_ms(c.lastFeltMs.value)}',
      if (script != null && kind != null)
        '${kind == ProbeScript.tap ? 'atap' : 'aswipe'} '
            '${c.scripting.value ? 'iphone_probe_running'.trParams({'done': '${c.scriptDone}', 'n': '${IphoneRemoteController.probeTrials}'}) : ''} ${_stats(script)}',
    ];
  }
}
