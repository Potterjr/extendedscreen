import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// A plugged-in iPhone's or iPad's capture device, as the Mac lists it.
class IosScreenDevice {
  const IosScreenDevice(this.id, this.name);
  final String id;
  final String name;
}

/// One felt-latency probe's answer (`onProbe {device, id, ms}`): on
/// [device]'s capture, the first frame that differed from the picture shown
/// when probe [id] was armed came [ms] milliseconds after its start (the
/// input event's time when the arming call carried one, else the call's
/// arrival in Swift; one clock, the Mac's). [ms] is null when the probe gave
/// up: nothing changed within 2 s, a newer probe on that capture replaced
/// it, or the capture stopped. [device] is null from a plugin that did not
/// say.
class ProbeResult {
  const ProbeResult(this.id, this.ms, {this.device});
  final int id;
  final double? ms;
  final String? device;

  bool get gaveUp => ms == null;

  /// The `onProbe` arguments, or null when they are not a probe's.
  static ProbeResult? parse(Object? arguments) {
    if (arguments is! Map) return null;
    final id = arguments['id'];
    final ms = arguments['ms'];
    final device = arguments['device'];
    if (id is! num) return null;
    return ProbeResult(
      id.toInt(),
      ms is num && ms.isFinite && ms >= 0 ? ms.toDouble() : null,
      device: device is String ? device : null,
    );
  }
}

/// The last [window] probe times, with their p50 and p90 (nearest rank).
class ProbeSummary {
  ProbeSummary({this.window = 50});
  final int window;
  final _values = <double>[];

  void add(double ms) {
    _values.add(ms);
    if (_values.length > window) _values.removeAt(0);
  }

  int get count => _values.length;
  List<double> get values => List.unmodifiable(_values);
  double? get p50 => percentile(_values, 0.5);
  double? get p90 => percentile(_values, 0.9);

  /// The nearest-rank [q] quantile of [values]; null when empty.
  static double? percentile(List<double> values, double q) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  @override
  String toString() => 'n=$count p50=${p50?.toStringAsFixed(1)} '
      'p90=${p90?.toStringAsFixed(1)}';
}

/// Mac: the screen of an iPhone or iPad over USB, through
/// `IosScreenPlugin.swift` (AVFoundation's iOS screen capture, shown in the
/// device's native remote window, `RemoteWindowChannel`, whose layer Swift
/// feeds from the capture queue). Not connected to the hub: nothing of the Wi-Fi or adb links is
/// used, and nothing needs to run on the phone for the picture.
///
/// One capture per device, keyed by the capture device's uniqueID (the `id`
/// of every call and callback): [frameSizes] holds each one's.
/// [frameSize] is the single-device view the iPhone controller reads: the
/// device [start]ed last ([current]).
/// A callback for any other device leaves them alone, and one for a device
/// this channel never started is ignored.
class IosScreenChannel extends GetxService {
  IosScreenChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'extended_screen/ios_screen';

  final MethodChannel _channel;

  /// The size of [current]'s frames, in pixels (portrait or landscape as
  /// the phone is held); null until the first frame.
  final frameSize = Rxn<Size>();

  /// Each running capture's frame size, by device id (from its first frame).
  final frameSizes = RxMap<String, Size>();

  /// The device [start]ed last, which [frameSize] follows;
  /// null before a start, and once it is stopped or has stopped.
  String? get current => _current;
  String? _current;

  /// Devices this channel has started (or is starting) and not stopped.
  final _known = <String>{};

  /// Of [_known], those whose start has answered: their capture runs.
  final _started = <String>{};

  /// Starts under way without a device id: until each answers which device
  /// it took, a callback for an unknown device may be its.
  int _unnamedStarts = 0;

  final _probes = StreamController<ProbeResult>.broadcast();

  /// The answers to [markProbe].
  Stream<ProbeResult> get probes => _probes.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    final a = call.arguments is Map ? call.arguments as Map : const {};
    final id = a['id'];
    switch (call.method) {
      case 'onFrameSize':
        if (id is! String || !_heard(id)) return;
        final size = Size(
          (a['width'] as num).toDouble(),
          (a['height'] as num).toDouble(),
        );
        frameSizes[id] = size;
        if (id == _current) frameSize.value = size;
      case 'onStopped':
        if (id is! String || !_known.contains(id)) return;
        _forget(id);
      case 'onProbe':
        final r = ProbeResult.parse(call.arguments);
        if (r != null && !_probes.isClosed) _probes.add(r);
    }
  }

  /// Whether a callback for [id] is one of this channel's captures (or may
  /// be: an unnamed start has not answered yet).
  bool _heard(String id) => _known.contains(id) || _unnamedStarts > 0;

  /// Whether [id]'s capture runs, or its start is under way: started here
  /// and not stopped since (nor stopped by itself, `onStopped`).
  bool isRunning(String id) => _known.contains(id);

  /// Points the single view at [id]'s capture (nothing when null).
  void _show(String? id) {
    _current = id;
    frameSize.value = id == null ? null : frameSizes[id];
  }

  void _forget(String id) {
    _known.remove(id);
    _started.remove(id);
    frameSizes.remove(id);
    if (id == _current) _show(null);
  }

  /// Arms felt-latency probe [id] (Dart's probe number) on [device]'s
  /// capture (the only one running when null). Its start is [t0Us] when
  /// given (an input event's time, µs of the Mac's uptime), else the moment
  /// the call reaches Swift; it answers on [probes] once a capture frame
  /// differs from the one shown now. False when nothing was armed (no
  /// picture yet, no such capture, no plugin).
  Future<bool> markProbe(int id, {String? device, int? t0Us}) async {
    try {
      return await _channel.invokeMethod<bool>('markProbe', {
            'device': ?device,
            'id': id,
            't0Us': ?t0Us,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Lets CoreMediaIO publish iOS screen-capture devices now, before the
  /// first [listDevices] (which would do it too): the devices appear a
  /// moment after it. Switching it on moves every attached iPhone or iPad
  /// into its QuickTime USB configuration, which takes each off usbmuxd for
  /// a moment, so it is done only when a phone's window opens or Home lists
  /// the phones. True when this call is what switched it on (so the phones
  /// may not be listed yet); false when it already was, or with no plugin.
  Future<bool> prepare() async {
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Writes [device]'s capture uniqueID (the only capture's when null) next
  /// to [udid] (the touch link's usbmux SerialNumber) in the unified log, so
  /// which one is which can be read off a real phone (category
  /// `ios_screen`). Nothing is assumed from it.
  Future<void> notePairing(String udid, {String? device}) async {
    try {
      await _channel.invokeMethod('notePairing', {
        'udid': udid,
        'device': ?device,
      });
    } on MissingPluginException {
      // No plugin: nothing to log.
    } on PlatformException {
      // Nothing to log.
    }
  }

  /// The iOS devices plugged in over USB. Empty when none (or no plugin).
  Future<List<IosScreenDevice>> listDevices() async {
    try {
      final list = await _channel.invokeListMethod<Map>('listDevices') ?? [];
      return [
        for (final d in list) IosScreenDevice('${d['id']}', '${d['name']}'),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Starts showing [id]'s screen (the first device when null) in its
  /// native window. It becomes [current]; another device's capture goes
  /// on. Throws a [PlatformException] (`PERMISSION_DENIED`, `NO_DEVICE`,
  /// `START_FAILED`, `CANCELLED`).
  Future<void> start(String? id) async {
    final before = _current;
    if (id != null) {
      _known.add(id);
      _current = id;
    } else {
      _unnamedStarts++;
    }
    frameSize.value = null;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('start', {
        'id': ?id,
      });
      final key = r?['id'] is String ? r!['id'] as String : id;
      // A plugin that did not say which device: nothing to keep.
      if (key == null) return;
      _known.add(key);
      _started.add(key);
      _current = key;
      frameSize.value = frameSizes[key];
    } on PlatformException {
      // The plugin left every running capture as it was: the single view
      // goes back to the one it showed, and a device that never ran is no
      // longer expected.
      if (id != null && !_started.contains(id)) _forget(id);
      _show(before != null && _started.contains(before) ? before : null);
      rethrow;
    } finally {
      if (id == null) _unnamedStarts--;
    }
  }

  @override
  void onClose() {
    unawaited(_probes.close());
    super.onClose();
  }

  /// Stops [id]'s capture; every capture when null.
  Future<void> stop([String? id]) async {
    if (id == null) {
      for (final k in [..._known]) {
        _forget(k);
      }
      _show(null);
    } else {
      _forget(id);
    }
    try {
      await _channel.invokeMethod('stop', {'id': ?id});
    } on MissingPluginException {
      // Nothing to stop.
    }
  }
}
