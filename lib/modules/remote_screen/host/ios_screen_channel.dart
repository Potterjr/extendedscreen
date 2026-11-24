import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// A plugged-in iPhone's or iPad's capture device, as the Mac lists it.
class IosScreenDevice {
  const IosScreenDevice(this.id, this.name);
  final String id;
  final String name;
}

/// One felt-latency probe's answer (`onProbe {id, ms}`): the first capture
/// frame that differed from the picture shown when the probe was armed came
/// [ms] milliseconds after the arming call reached Swift (one clock, the
/// Mac's). [ms] is null when the probe gave up: nothing changed within 2 s,
/// a newer probe replaced it, or the capture stopped.
class ProbeResult {
  const ProbeResult(this.id, this.ms);
  final int id;
  final double? ms;

  bool get gaveUp => ms == null;

  /// The `onProbe` arguments, or null when they are not a probe's.
  static ProbeResult? parse(Object? arguments) {
    if (arguments is! Map) return null;
    final id = arguments['id'];
    final ms = arguments['ms'];
    if (id is! num) return null;
    return ProbeResult(
        id.toInt(), ms is num && ms.isFinite && ms >= 0 ? ms.toDouble() : null);
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
/// `IosScreenPlugin.swift` (AVFoundation's iOS screen capture into a
/// texture). Not connected to the hub: nothing of the Wi-Fi or adb links is
/// used, and nothing needs to run on the phone for the picture.
class IosScreenChannel extends GetxService {
  IosScreenChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'extended_screen/ios_screen';

  final MethodChannel _channel;

  /// The texture showing the phone's screen while a capture runs.
  final textureId = Rxn<int>();

  /// The size of the frames, in pixels (portrait or landscape as the phone
  /// is held); null until the first frame.
  final frameSize = Rxn<Size>();

  final _probes = StreamController<ProbeResult>.broadcast();

  /// The answers to [markProbe].
  Stream<ProbeResult> get probes => _probes.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onFrameSize':
        final a = call.arguments as Map;
        frameSize.value = Size((a['width'] as num).toDouble(),
            (a['height'] as num).toDouble());
      case 'onStopped':
        textureId.value = null;
        frameSize.value = null;
      case 'onProbe':
        final r = ProbeResult.parse(call.arguments);
        if (r != null && !_probes.isClosed) _probes.add(r);
    }
  }

  /// Arms felt-latency probe [id]: Swift takes the time as the call arrives
  /// and answers on [probes] once a capture frame differs from the one shown
  /// now. False when nothing was armed (no picture yet, no plugin).
  Future<bool> markProbe(int id) async {
    try {
      return await _channel.invokeMethod<bool>('markProbe', {'id': id}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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

  /// Starts showing [id]'s screen (the first device when null). Throws a
  /// [PlatformException] (`PERMISSION_DENIED`, `NO_DEVICE`, `START_FAILED`).
  Future<void> start([String? id]) async {
    frameSize.value = null;
    final r = await _channel.invokeMapMethod<String, dynamic>(
        'start', {'id': ?id});
    textureId.value = (r?['textureId'] as num?)?.toInt();
  }

  @override
  void onClose() {
    unawaited(_probes.close());
    super.onClose();
  }

  Future<void> stop() async {
    textureId.value = null;
    frameSize.value = null;
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }
}
