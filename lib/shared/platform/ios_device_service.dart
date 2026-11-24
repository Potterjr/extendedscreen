import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';

/// What one run of a command gave back. [exitCode] is -1 when it could not
/// be started or was ended by the timeout ([timedOut]).
class CommandResult {
  const CommandResult(
    this.exitCode, {
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
  });
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// Runs [executable] with [args], ending it after [timeout]. Throws a
/// [ProcessException] when it cannot be started (no such binary).
typedef CommandRunner =
    Future<CommandResult> Function(
      String executable,
      List<String> args,
      Duration timeout,
    );

/// How a pairing handed to an iPhone through devicectl ended.
enum IosDelivery {
  /// Written to the app's inbox and the app nudged; no answer read back
  /// (the app is closed, or has not looked yet). It takes it when it next
  /// runs.
  sent,

  /// The app stored it (its answer, `ESInbox/result`, names this payload).
  stored,

  /// The app read it and would not store it: it knows this Mac's id with
  /// another certificate or token (Forget it on the iPhone), or could not
  /// read it.
  refused,

  /// No Xcode devicectl on this Mac (`/usr/bin/xcrun` missing, or only the
  /// Command Line Tools).
  noXcode,

  /// The iPhone has not paired with (trusted) this Mac.
  notPaired,

  /// Developer Mode is off on the iPhone.
  devModeOff,

  /// devicectl does not list the iPhone as cabled to this Mac.
  notWired,

  /// devicectl failed (see [IosDeviceService.lastDetail]): typically the
  /// app is not installed, or is not a development-signed build of
  /// [iosBundleId].
  failed,

  /// Simulator only: `simctl get_app_container` finds no [iosBundleId]
  /// installed on it.
  notInstalled,

  /// Simulator only: simctl does not list it as booted.
  notBooted,
}

/// One iOS device as `devicectl list devices` reports it, or (debug builds
/// only) one booted iOS simulator as `simctl list devices booted -j` does
/// ([isSimulator]).
class IosDevice {
  const IosDevice({
    required this.udid,
    required this.name,
    required this.model,
    this.transportType,
    this.pairingState,
    this.developerModeStatus,
    this.isSimulator = false,
    this.simulatorState,
    this.runtime,
  });

  /// What `--device` is given: `hardwareProperties.udid`, else the
  /// CoreDevice `identifier`.
  final String udid;

  /// The owner's name for it (`deviceProperties.name`), else [model].
  final String name;

  /// `hardwareProperties.marketingName` ("iPhone 18 Pro Max").
  final String model;

  /// `connectionProperties.transportType`: `wired`, `localNetwork`, ...
  final String? transportType;

  /// `connectionProperties.pairingState`: `paired`, `unpaired`, ...
  final String? pairingState;

  /// `deviceProperties.developerModeStatus`: `enabled`, `disabled`.
  final String? developerModeStatus;

  /// A simulator, paired by writing into its container on this Mac
  /// (no devicectl; the connection fields above are null).
  final bool isSimulator;

  /// Simulator only: simctl's `state` (`Booted`, `Shutdown`, ...).
  final String? simulatorState;

  /// Simulator only: its runtime as "iOS 26.5", from the runtime id.
  final String? runtime;

  bool get wired => transportType == 'wired';
  bool get paired => pairingState == 'paired';
  bool get developerMode => developerModeStatus == 'enabled';
  bool get booted => simulatorState == 'Booted';

  /// Only a cabled, trusting iPhone in Developer Mode, or a booted
  /// simulator, is offered a Pair.
  bool get offerable => isSimulator ? booted : wired && paired && developerMode;

  /// Why it is not [offerable], as an [IosDelivery]; null when it is.
  IosDelivery? get blocker {
    if (isSimulator) return booted ? null : IosDelivery.notBooted;
    if (!paired) return IosDelivery.notPaired;
    if (!developerMode) return IosDelivery.devModeOff;
    if (!wired) return IosDelivery.notWired;
    return null;
  }
}

/// Host (macOS): the iPhone's stand-in for adb. It lists the iOS devices
/// Xcode's CoreDevice sees and hands one a Wi-Fi pairing by writing the
/// unchanged pairing bytes ([WifiPairingService.offerPayload]) into the
/// iPhone app's own container, where only a Mac the phone trusts, with
/// Developer Mode on, can write, and only into a development-signed build
/// (docs/ios-client-design.md, *auth*). The app pulls them from Dart
/// (`WifiPairingChannel`, `PairingInboxPlugin.swift`).
///
/// It runs `/usr/bin/xcrun` at that fixed path, never resolved from `$PATH`
/// (the rule adb follows), always with `--json-output` to a temp file, and
/// ends any run after [timeout]. The token never appears in an argument:
/// devicectl copies a 0600 file from a fresh 0700 temp directory, removed
/// afterwards whatever happens.
///
/// Debug builds also list the booted iOS simulators ([listSimulators]) and
/// pair one by writing the same bytes straight into its data container on
/// this Mac, which `simctl get_app_container` names (docs/ios-client-design.md,
/// *ipad → testing without hardware*): no devicectl, no copy through a temp
/// directory, and still no token in an argument.
///
/// P0 spike: nothing calls it in a release build (the only caller is the
/// debug-only "iPhones (debug)" list in Settings → Wi-Fi).
class IosDeviceService extends GetxService {
  IosDeviceService({
    CommandRunner? run,
    WifiPairingService? pairing,
    this.timeout = const Duration(seconds: 20),
    this.resultTries = 3,
    this.resultDelay = const Duration(seconds: 1),
  }) : _run = run ?? runCommand,
       _pairingOverride = pairing;

  static const xcrun = '/usr/bin/xcrun';
  static const chmod = '/bin/chmod';

  /// Where in the app's data container the pairing goes, and where its
  /// answer comes back.
  static const inboxPath = 'Library/Application Support/ESInbox/pairing.bin';
  static const resultPath = 'Library/Application Support/ESInbox/result';

  /// The Darwin notification that nudges the app to look.
  static String get notificationName => '$iosBundleId.inbox';

  final CommandRunner _run;
  final WifiPairingService? _pairingOverride;
  final Duration timeout;

  /// How many times the app's answer is read back after a delivery, and how
  /// long to wait before each read.
  final int resultTries;
  final Duration resultDelay;

  /// What the last call learned beyond its answer: devicectl's error, or
  /// each step's time. For the debug list and the log.
  final lastDetail = RxnString();

  WifiPairingService get _pairing =>
      _pairingOverride ?? Get.find<WifiPairingService>();

  void _log(String line, {bool warn = false}) {
    if (!Get.isRegistered<LoggerService>()) return;
    final log = Get.find<LoggerService>();
    warn ? log.w('iOS: $line') : log.i('iOS: $line');
  }

  /// Every physical iOS device devicectl lists (its simulated ones left
  /// out), then in a debug build the booted iOS simulators simctl lists; null
  /// when neither could be asked ([lastDetail] says why, devicectl's reason
  /// first). Use [IosDevice.offerable] for the ones a pairing may go to.
  Future<List<IosDevice>?> list() async {
    lastDetail.value = null;
    final tmp = await Directory.systemTemp.createTemp('es-devicectl-');
    List<IosDevice>? devices;
    try {
      final json = '${tmp.path}/list.json';
      final r = await _devicectl(['list', 'devices'], json);
      if (r.delivery == null) devices = parseDevices(r.json);
    } finally {
      await _remove(tmp);
    }
    if (!kDebugMode) return devices;
    final sims = await listSimulators();
    if (devices == null && sims == null) return null;
    return [...?devices, ...?sims];
  }

  /// Debug builds: the booted iOS simulators (`simctl list devices booted
  /// -j`), or null when simctl could not be asked (it sets [lastDetail] only
  /// if nothing has yet).
  Future<List<IosDevice>?> listSimulators() async =>
      (await _listSimulators()).sims;

  Future<({List<IosDevice>? sims, IosDelivery? delivery})>
  _listSimulators() async {
    final r = await _simctl(['list', 'devices', 'booted', '-j']);
    if (r.delivery != null) return (sims: null, delivery: r.delivery);
    try {
      final doc = jsonDecode(r.stdout);
      return (
        sims: parseSimulators(doc is Map<String, dynamic> ? doc : null),
        delivery: null,
      );
    } on FormatException catch (e) {
      lastDetail.value ??= 'simctl list: ${e.message}';
      return (sims: null, delivery: IosDelivery.failed);
    }
  }

  /// The simulators in `simctl list devices -j`'s document: `devices` maps
  /// a runtime id (`com.apple.CoreSimulator.SimRuntime.iOS-26-5`) to its
  /// devices, each with `udid`, `name`, `state`, `isAvailable` and
  /// `deviceTypeIdentifier` (`…SimDeviceType.iPhone-17-Pro-Max`, the model).
  /// Only booted, available iOS ones are kept (no watchOS, tvOS, xrOS).
  static List<IosDevice> parseSimulators(Map<String, dynamic>? doc) {
    final runtimes = doc?['devices'];
    if (runtimes is! Map) return const [];
    final out = <IosDevice>[];
    for (final MapEntry(key: runtimeId, value: devices) in runtimes.entries) {
      if (runtimeId is! String || devices is! List) continue;
      final runtime = RegExp(
        r'SimRuntime\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$',
      ).firstMatch(runtimeId);
      if (runtime == null) continue;
      final version = [
        for (var g = 1; g <= 3; g++)
          if (runtime.group(g) != null) runtime.group(g)!,
      ].join('.');
      for (final d in devices) {
        if (d is! Map) continue;
        String? str(String k) {
          final v = d[k];
          return v is String && v.trim().isNotEmpty ? v.trim() : null;
        }

        final udid = str('udid');
        final state = str('state');
        if (udid == null || state != 'Booted') continue;
        if (d['isAvailable'] == false) continue;
        final type = str('deviceTypeIdentifier');
        final model = type == null
            ? 'iOS Simulator'
            : type.split('.').last.replaceAll('-', ' ');
        out.add(
          IosDevice(
            udid: udid,
            name: str('name') ?? model,
            model: model,
            isSimulator: true,
            simulatorState: state,
            runtime: 'iOS $version',
          ),
        );
      }
    }
    return out;
  }

  /// The devices in `devicectl list devices --json-output`'s document:
  /// `result.devices[]`, each read from `hardwareProperties.udid` (else
  /// `identifier`), `.marketingName`, `.reality`, `.platform`,
  /// `deviceProperties.name`, `.developerModeStatus`,
  /// `connectionProperties.transportType` and `.pairingState`. Simulated
  /// devices and other platforms (watchOS, tvOS, ...) are left out.
  static List<IosDevice> parseDevices(Map<String, dynamic>? doc) {
    final result = doc?['result'];
    final devices = result is Map ? result['devices'] : null;
    if (devices is! List) return const [];
    final out = <IosDevice>[];
    for (final d in devices) {
      if (d is! Map) continue;
      final hw = d['hardwareProperties'];
      final dp = d['deviceProperties'];
      final cp = d['connectionProperties'];
      String? str(Object? m, String k) {
        final v = m is Map ? m[k] : null;
        return v is String && v.trim().isNotEmpty ? v.trim() : null;
      }

      if (str(hw, 'reality') == 'simulated') continue;
      final platform = str(hw, 'platform');
      if (platform != null && platform != 'iOS' && platform != 'iPadOS') {
        continue;
      }
      final udid = str(hw, 'udid') ?? str(d, 'identifier');
      if (udid == null) continue;
      final model = str(hw, 'marketingName') ?? str(hw, 'productType') ?? 'iOS';
      out.add(
        IosDevice(
          udid: udid,
          name: str(dp, 'name') ?? model,
          model: model,
          transportType: str(cp, 'transportType'),
          pairingState: str(cp, 'pairingState'),
          developerModeStatus: str(dp, 'developerModeStatus'),
        ),
      );
    }
    return out;
  }

  /// Hands [udid]'s app this Mac's Wi-Fi pairing: checks devicectl lists it
  /// as wired, paired and in Developer Mode, writes the payload into the
  /// app's inbox, posts the nudge, then reads the app's answer back up to
  /// [resultTries] times. [payload] defaults to
  /// [WifiPairingService.offerPayload]; tests pass one. A [simulator]
  /// (debug builds only) goes through [_deliverToSimulator] instead.
  Future<IosDelivery> deliverPairing(
    String udid, {
    Uint8List? payload,
    bool simulator = false,
  }) async {
    if (simulator && kDebugMode) {
      return _deliverToSimulator(udid, payload: payload);
    }
    lastDetail.value = null;
    final watch = Stopwatch()..start();
    final steps = <String>[];
    void step(String name) =>
        steps.add('$name ${watch.elapsedMilliseconds} ms');

    final tmp = await Directory.systemTemp.createTemp('es-pair-');
    try {
      // 1. Is it there, and may it be written to?
      final listed = await _devicectl([
        'list',
        'devices',
      ], '${tmp.path}/l.json');
      step('list');
      if (listed.delivery != null) return _end(listed.delivery!, steps);
      final device = parseDevices(
        listed.json,
      ).where((d) => d.udid == udid).firstOrNull;
      if (device == null) {
        lastDetail.value = 'devicectl does not list $udid';
        return _end(IosDelivery.notWired, steps);
      }
      final blocker = device.blocker;
      if (blocker != null) return _end(blocker, steps);

      // 2. The bytes, in a file only this user can read.
      final bytes = payload ?? await _pairing.offerPayload();
      step('payload');
      await _run(chmod, ['700', tmp.path], timeout);
      final file = File('${tmp.path}/pairing.bin');
      await file.create();
      final mode = await _run(chmod, ['600', file.path], timeout);
      if (mode.exitCode != 0) {
        lastDetail.value = 'chmod failed: ${mode.stderr.trim()}';
        return _end(IosDelivery.failed, steps);
      }
      await file.writeAsBytes(bytes, flush: true);

      // 3. Into the app's container.
      final copied = await _devicectl([
        'device',
        'copy',
        'to',
        '--device',
        udid,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        iosBundleId,
        '--source',
        file.path,
        '--destination',
        inboxPath,
      ], '${tmp.path}/copy.json');
      step('copy');
      if (copied.delivery != null) return _end(copied.delivery!, steps);

      // 4. The nudge. Only a hint: the app also looks on launch, resume and
      // every 2 s while unpaired.
      final posted = await _devicectl([
        'device',
        'notification',
        'post',
        '--device',
        udid,
        '--name',
        notificationName,
      ], '${tmp.path}/post.json');
      step('notify');
      if (posted.delivery != null) {
        _log('the inbox nudge failed (${lastDetail.value})', warn: true);
      }

      // 5. The app's answer, if it is running.
      final mine = sha256.convert(bytes).bytes.sublist(0, 8);
      for (var i = 0; i < resultTries; i++) {
        await Future<void>.delayed(resultDelay);
        final out = File('${tmp.path}/result-$i');
        final read = await _devicectl([
          'device',
          'copy',
          'from',
          '--device',
          udid,
          '--domain-type',
          'appDataContainer',
          '--domain-identifier',
          iosBundleId,
          '--source',
          resultPath,
          '--destination',
          out.path,
        ], '${tmp.path}/from-$i.json');
        step('result $i');
        if (read.delivery == null && await out.exists()) {
          final answer = parseResult(await out.readAsBytes(), mine);
          if (answer != null) return _end(answer, steps);
        }
      }
      return _end(IosDelivery.sent, steps);
    } catch (e) {
      lastDetail.value = '$e';
      return _end(IosDelivery.failed, steps);
    } finally {
      await _remove(tmp);
    }
  }

  /// A simulator's pairing. It must be listed as booted. Its data
  /// container is what `simctl get_app_container` answers for [udid],
  /// [iosBundleId] and `data` (an error there: the app is not installed).
  /// The bytes are written to a 0600 temp name inside `ESInbox` and renamed
  /// to `pairing.bin`, so the app never takes a half-written file. `simctl
  /// spawn` runs `notifyutil -p` with [notificationName] inside it to nudge
  /// the app (a failure is only logged), and its `result` is read back from
  /// the container and judged as the device path does.
  Future<IosDelivery> _deliverToSimulator(
    String udid, {
    Uint8List? payload,
  }) async {
    lastDetail.value = null;
    final watch = Stopwatch()..start();
    final steps = <String>[];
    void step(String name) =>
        steps.add('$name ${watch.elapsedMilliseconds} ms');
    File? temp;
    try {
      // 1. Booted?
      final listed = await _listSimulators();
      step('list');
      final sims = listed.sims;
      if (sims == null) return _end(listed.delivery!, steps);
      if (!sims.any((d) => d.udid == udid && d.booted)) {
        lastDetail.value = 'simctl lists no booted simulator $udid';
        return _end(IosDelivery.notBooted, steps);
      }

      // 2. The app's data container.
      final found = await _simctl([
        'get_app_container',
        udid,
        iosBundleId,
        'data',
      ]);
      step('container');
      if (found.delivery != null) {
        // No such app on it: simctl answers ENOENT (exit 2, "No such file
        // or directory").
        final notThere =
            found.exitCode == 2 ||
            found.stderr.contains('No such file or directory');
        if (notThere && found.delivery == IosDelivery.failed) {
          lastDetail.value = '$iosBundleId is not installed on $udid';
          return _end(IosDelivery.notInstalled, steps);
        }
        return _end(found.delivery!, steps);
      }
      final container = parseContainerPath(found.stdout);
      if (container == null || !await Directory(container).exists()) {
        lastDetail.value = 'simctl gave no container (${found.stdout.trim()})';
        return _end(IosDelivery.failed, steps);
      }

      // 3. Into the inbox, atomically, readable by this user only.
      final bytes = payload ?? await _pairing.offerPayload();
      step('payload');
      final inbox = Directory('$container/${File(inboxPath).parent.path}');
      await inbox.create(recursive: true);
      final nonce = DateTime.now().microsecondsSinceEpoch;
      temp = File('${inbox.path}/.pairing.$pid.$nonce.tmp');
      await temp.create(exclusive: true);
      final mode = await _run(chmod, ['600', temp.path], timeout);
      if (mode.exitCode != 0) {
        lastDetail.value = 'chmod failed: ${mode.stderr.trim()}';
        return _end(IosDelivery.failed, steps);
      }
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename('$container/$inboxPath');
      temp = null;
      step('write');

      // 4. The nudge, inside the simulator.
      final posted = await _simctl([
        'spawn',
        udid,
        'notifyutil',
        '-p',
        notificationName,
      ]);
      step('notify');
      if (posted.delivery != null) {
        _log('the inbox nudge failed (${lastDetail.value})', warn: true);
        lastDetail.value = null;
      }

      // 5. The app's answer, if it is running.
      final mine = sha256.convert(bytes).bytes.sublist(0, 8);
      final result = File('$container/$resultPath');
      for (var i = 0; i < resultTries; i++) {
        await Future<void>.delayed(resultDelay);
        step('result $i');
        if (await result.exists()) {
          final answer = parseResult(await result.readAsBytes(), mine);
          if (answer != null) return _end(answer, steps);
        }
      }
      return _end(IosDelivery.sent, steps);
    } catch (e) {
      lastDetail.value = '$e';
      return _end(IosDelivery.failed, steps);
    } finally {
      if (temp != null) {
        try {
          await temp.delete();
        } catch (_) {}
      }
    }
  }

  /// `simctl get_app_container`'s answer: the container's absolute path on
  /// its first line. Null for anything else.
  static String? parseContainerPath(String stdout) {
    final line = stdout.trim().split('\n').first.trim();
    if (!line.startsWith('/') || line.contains('\u0000')) return null;
    return line.endsWith('/') && line.length > 1
        ? line.substring(0, line.length - 1)
        : line;
  }

  /// One `xcrun simctl` run. [delivery] is null when it exited 0, else what
  /// the failure means for a pairing; a failure's reason goes to
  /// [lastDetail] unless something is already there.
  Future<({String stdout, String stderr, int exitCode, IosDelivery? delivery})>
  _simctl(List<String> args) async {
    final CommandResult r;
    try {
      r = await _run(xcrun, ['simctl', ...args], timeout);
    } on ProcessException catch (e) {
      lastDetail.value ??= 'no $xcrun (${e.message})';
      return (
        stdout: '',
        stderr: '',
        exitCode: -1,
        delivery: IosDelivery.noXcode,
      );
    }
    IosDelivery? delivery;
    if (r.timedOut) {
      lastDetail.value ??= 'simctl ${args.first} timed out';
      delivery = IosDelivery.failed;
    } else if (r.exitCode != 0) {
      final err = r.stderr.trim();
      if (err.contains('unable to find utility') ||
          err.contains('invalid active developer path')) {
        lastDetail.value ??= err;
        delivery = IosDelivery.noXcode;
      } else {
        lastDetail.value ??= err.isNotEmpty
            ? err
            : 'simctl ${args.first} exited ${r.exitCode}';
        delivery = IosDelivery.failed;
      }
    }
    return (
      stdout: r.stdout,
      stderr: r.stderr,
      exitCode: r.exitCode,
      delivery: delivery,
    );
  }

  /// The app's answer file: a result byte (1 stored, 2 refused) and the
  /// first 8 bytes of the SHA-256 of the payload it answers. Null when it
  /// answers another delivery, or cannot be read.
  static IosDelivery? parseResult(List<int> file, List<int> payloadHash8) {
    if (file.length != 9) return null;
    for (var i = 0; i < 8; i++) {
      if (file[1 + i] != payloadHash8[i]) return null;
    }
    return switch (file[0]) {
      1 => IosDelivery.stored,
      2 => IosDelivery.refused,
      _ => null,
    };
  }

  IosDelivery _end(IosDelivery d, List<String> steps) {
    final timing = steps.join(', ');
    _log(
      'pairing ${d.name}${timing.isEmpty ? '' : ' ($timing)'}'
      '${d == IosDelivery.stored || d == IosDelivery.sent ? '' : ': ${lastDetail.value ?? ''}'}',
    );
    if (d == IosDelivery.stored || d == IosDelivery.sent) {
      lastDetail.value = timing;
    }
    return d;
  }

  /// One devicectl run with its JSON document. [delivery] is null when it
  /// succeeded, else what the failure means for a pairing.
  Future<({Map<String, dynamic>? json, IosDelivery? delivery})> _devicectl(
    List<String> args,
    String jsonPath,
  ) async {
    final CommandResult r;
    try {
      // devicectl's own timeout too, a little inside ours: killing xcrun
      // need not end the devicectl it started.
      final own = (timeout.inSeconds - 2).clamp(1, 600);
      r = await _run(xcrun, [
        'devicectl',
        ...args,
        '--timeout',
        '$own',
        '--json-output',
        jsonPath,
      ], timeout);
    } on ProcessException catch (e) {
      lastDetail.value = 'no $xcrun (${e.message})';
      return (json: null, delivery: IosDelivery.noXcode);
    }
    Map<String, dynamic>? doc;
    try {
      final f = File(jsonPath);
      if (await f.exists()) {
        final v = jsonDecode(await f.readAsString());
        if (v is Map<String, dynamic>) doc = v;
      }
    } catch (_) {}
    final info = doc?['info'];
    final outcome = info is Map ? info['outcome'] : null;
    if (r.exitCode == 0 && (outcome == null || outcome == 'success')) {
      return (json: doc, delivery: null);
    }
    if (r.timedOut) {
      lastDetail.value = 'devicectl ${args.take(3).join(' ')} timed out';
      return (json: doc, delivery: IosDelivery.failed);
    }
    // `xcrun: error: unable to find utility "devicectl"`: no Xcode, only
    // the Command Line Tools (or none).
    if (doc == null &&
        (r.stderr.contains('unable to find utility') ||
            r.stderr.contains('invalid active developer path'))) {
      lastDetail.value = r.stderr.trim();
      return (json: null, delivery: IosDelivery.noXcode);
    }
    final error = doc?['error'];
    final user = error is Map ? error['userInfo'] : null;
    final desc = user is Map ? user['NSLocalizedDescription'] : null;
    final text = desc is Map ? desc['string'] : desc;
    lastDetail.value = text is String
        ? text
        : (r.stderr.trim().isNotEmpty
              ? r.stderr.trim()
              : 'devicectl exited ${r.exitCode}');
    return (json: doc, delivery: IosDelivery.failed);
  }

  static Future<void> _remove(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// The real [CommandRunner]: starts [executable] (never through a shell),
  /// collects its output, and kills it after [timeout].
  static Future<CommandResult> runCommand(
    String executable,
    List<String> args,
    Duration timeout,
  ) async {
    final process = await Process.start(executable, args);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      code = -1;
    }
    final stdoutText = await out.timeout(
      const Duration(seconds: 1),
      onTimeout: () => '',
    );
    final stderrText = await err.timeout(
      const Duration(seconds: 1),
      onTimeout: () => '',
    );
    return CommandResult(
      code,
      stdout: stdoutText,
      stderr: stderrText,
      timedOut: timedOut,
    );
  }
}
