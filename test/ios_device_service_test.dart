import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';

import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/platform/ios_device_service.dart';

/// IosDeviceService against devicectl stood in for: [_Devicectl] answers
/// each `xcrun devicectl` run from fixtures (test/fixtures/devicectl/, the
/// paths devicectl 642 writes) and plays the iPhone app's inbox. It also
/// answers `xcrun simctl` (test/fixtures/simctl/, `simctl list devices
/// booted -j` as Xcode 27 prints it) for the debug-only simulator path,
/// whose container is a real temp directory.

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/devicectl/$name').readAsStringSync())
        as Map<String, dynamic>;

const _phone = '00008160-000AAAAAAAAAAAAA';
const _sim = '37761CCA-C34D-4E63-B704-46E7D81A8130';

/// What simctl prints for `get_app_container` when the app is not installed
/// (exit 2), as measured.
const _notInstalledStderr =
    'An error was encountered processing the command '
    '(domain=NSPOSIXErrorDomain, code=2):\n'
    'The operation couldn’t be completed. No such file or directory\n'
    'No such file or directory\n';

class _Devicectl {
  _Devicectl({this.answer});

  /// The app's answer byte (1 stored, 2 refused) once it has the pairing;
  /// null: the app never answers (closed).
  int? answer;

  /// Answer for another payload than the one delivered (a stale result).
  bool staleAnswer = false;

  /// What each step returns instead of success.
  final failures = <String, Map<String, dynamic>>{};
  final timeouts = <String>{};
  bool noXcode = false;
  String? noUtility;

  final runs = <List<String>>[];
  Uint8List? copied;
  String? copiedMode;
  String? tempDir;

  // ── simctl ──
  /// `simctl list devices booted -j`'s output.
  String simList = '{"devices": {}}';

  /// The simulator app's data container; null: the app is not installed.
  String? container;
  final simTimeouts = <String>{};
  bool nudgeFails = false;
  final simRuns = <List<String>>[];
  final chmodded = <String>[];

  /// Called with the path chmod is given, before it runs.
  void Function(String path)? onChmod;

  /// What the simulator app found in its inbox when nudged, and its mode.
  Uint8List? taken;
  String? takenMode;

  Future<CommandResult> run(
      String exe, List<String> args, Duration timeout) async {
    if (exe == IosDeviceService.chmod) {
      chmodded.add(args.last);
      onChmod?.call(args.last);
      final r = await Process.run(exe, args);
      return CommandResult(r.exitCode, stderr: '${r.stderr}');
    }
    expect(exe, IosDeviceService.xcrun, reason: 'xcrun at its fixed path');
    if (noXcode) throw const ProcessException('/usr/bin/xcrun', [], 'gone', 2);
    if (noUtility != null) return CommandResult(72, stderr: noUtility!);
    if (args.first == 'simctl') return _simctl(args);
    runs.add(args);
    expect(args.first, 'devicectl');
    final json = args[args.indexOf('--json-output') + 1];
    final step = args.sublist(1, 3).join(' ');
    void write(Map<String, dynamic> doc) =>
        File(json).writeAsStringSync(jsonEncode(doc));
    if (args.length > 3 && args[3] == 'to') {
      final source = File(args[args.indexOf('--source') + 1]);
      tempDir = source.parent.path;
      expect(source.existsSync(), isTrue);
    }
    if (timeouts.contains(step)) {
      return const CommandResult(-1, timedOut: true);
    }
    final failure = failures[step];
    if (failure != null) {
      write(failure);
      return const CommandResult(1);
    }
    switch (step) {
      case 'list devices':
        write(_fixture('list_devices.json'));
      case 'device copy':
        final source = args[args.indexOf('--source') + 1];
        final destination = args[args.indexOf('--destination') + 1];
        if (args[3] == 'to') {
          final f = File(source);
          copied = f.readAsBytesSync();
          copiedMode = f.statSync().modeString();
        } else {
          final a = answer;
          if (a == null || copied == null) {
            write(_fixture('copy_failed.json'));
            return const CommandResult(1);
          }
          final hash = sha256
              .convert(staleAnswer ? [...copied!, 0] : copied!)
              .bytes
              .sublist(0, 8);
          File(destination).writeAsBytesSync([a, ...hash]);
        }
        write(_fixture('success.json'));
      default:
        write(_fixture('success.json'));
    }
    return const CommandResult(0);
  }

  CommandResult _simctl(List<String> args) {
    simRuns.add(args);
    if (simTimeouts.contains(args[1])) {
      return const CommandResult(-1, timedOut: true);
    }
    switch (args[1]) {
      case 'list':
        return CommandResult(0, stdout: simList);
      case 'get_app_container':
        final c = container;
        if (c == null) return const CommandResult(2, stderr: _notInstalledStderr);
        return CommandResult(0, stdout: '$c\n');
      case 'spawn':
        if (nudgeFails) {
          return const CommandResult(1, stderr: 'notifyutil: failed');
        }
        // The app, nudged: takes pairing.bin and answers for its bytes.
        final inbox = '$container/Library/Application Support/ESInbox';
        final pending = File('$inbox/pairing.bin');
        final a = answer;
        if (a != null && pending.existsSync()) {
          taken = pending.readAsBytesSync();
          takenMode = pending.statSync().modeString();
          pending.deleteSync();
          final hash = sha256
              .convert(staleAnswer ? [...taken!, 0] : taken!)
              .bytes
              .sublist(0, 8);
          File('$inbox/result').writeAsBytesSync([a, ...hash]);
        }
        return const CommandResult(0);
    }
    return const CommandResult(1, stderr: 'unknown simctl verb');
  }
}

void main() {
  final payload = Uint8List.fromList(
      [0xF6, 1, ...List.filled(16, 7), ...List.filled(32, 0xAB), 0]);

  IosDeviceService serviceWith(_Devicectl d) => IosDeviceService(
        run: d.run,
        resultTries: 2,
        resultDelay: Duration.zero,
      );

  group('list', () {
    test('reads the devicectl JSON paths and leaves simulators and other '
        'platforms out', () async {
      final devices = await serviceWith(_Devicectl()).list();
      expect(devices!.map((d) => d.udid), [
        _phone,
        '00008150-000CCCCCCCCCCCCC',
        '00008150-000DDDDDDDDDDDDD',
        '00008150-000EEEEEEEEEEEEE',
      ]);
      final phone = devices.first;
      expect(phone.name, "Owner's iPhone");
      expect(phone.model, 'iPhone 18 Pro Max');
      expect(phone.offerable, isTrue);
      expect(devices.map((d) => d.blocker), [
        null,
        IosDelivery.notWired,
        IosDelivery.notPaired,
        IosDelivery.devModeOff,
      ]);
    });

    test('null when devicectl cannot be asked', () async {
      expect(await serviceWith(_Devicectl()..noXcode = true).list(), isNull);
      final cli = _Devicectl()
        ..noUtility = 'xcrun: error: unable to find utility "devicectl"';
      final s = serviceWith(cli);
      expect(await s.list(), isNull);
      expect(s.lastDetail.value, contains('unable to find utility'));
    });

    test('a document without devices lists none', () {
      expect(IosDeviceService.parseDevices(null), isEmpty);
      expect(IosDeviceService.parseDevices({'result': {}}), isEmpty);
    });
  });

  group('deliverPairing', () {
    test('copies a 0600 file into the app container, nudges the app, and '
        'reads its answer for this payload', () async {
      final d = _Devicectl(answer: 1);
      final s = serviceWith(d);
      expect(await s.deliverPairing(_phone, payload: payload),
          IosDelivery.stored);

      expect(d.copied, payload);
      expect(d.copiedMode, 'rw-------');
      final copy = d.runs.firstWhere((r) => r[3] == 'to');
      expect(copy.sublist(0, 10), [
        'devicectl', 'device', 'copy', 'to',
        '--device', _phone,
        '--domain-type', 'appDataContainer',
        '--domain-identifier', iosBundleId,
      ]);
      expect(copy[copy.indexOf('--destination') + 1],
          'Library/Application Support/ESInbox/pairing.bin');
      final post = d.runs.firstWhere((r) => r[2] == 'notification');
      expect(post.sublist(0, 8), [
        'devicectl', 'device', 'notification', 'post',
        '--device', _phone,
        '--name', '$iosBundleId.inbox',
      ]);
      for (final r in d.runs) {
        expect(r, contains('--json-output'));
        expect(r, contains('--timeout'));
      }

      // The token appears in no argument, only in the file.
      final token = payload.sublist(18, 50);
      final forms = [base64.encode(token), base64Url.encode(token),
          token.map((b) => b.toRadixString(16).padLeft(2, '0')).join()];
      for (final arg in d.runs.expand((r) => r)) {
        for (final f in forms) {
          expect(arg.contains(f), isFalse);
        }
      }
      expect(Directory(d.tempDir!).existsSync(), isFalse,
          reason: 'the temp directory is removed');
    });

    test('a refusal is reported, and an answer to another delivery is not '
        'taken for this one', () async {
      expect(
          await serviceWith(_Devicectl(answer: 2))
              .deliverPairing(_phone, payload: payload),
          IosDelivery.refused);
      final stale = _Devicectl(answer: 1)..staleAnswer = true;
      expect(await serviceWith(stale).deliverPairing(_phone, payload: payload),
          IosDelivery.sent);
      expect(stale.runs.where((r) => r[3] == 'from'), hasLength(2),
          reason: 'read back resultTries times');
    });

    test('with the app closed it is sent, waiting in the inbox', () async {
      final d = _Devicectl();
      expect(await serviceWith(d).deliverPairing(_phone, payload: payload),
          IosDelivery.sent);
    });

    test('a failed copy is reported with its reason, and the file removed',
        () async {
      final d = _Devicectl(answer: 1)
        ..failures['device copy'] = _fixture('copy_failed.json');
      final s = serviceWith(d);
      expect(await s.deliverPairing(_phone, payload: payload),
          IosDelivery.failed);
      expect(s.lastDetail.value, contains('not installed'));
      expect(d.runs.where((r) => r[2] == 'notification'), isEmpty);
      expect(Directory(d.tempDir!).existsSync(), isFalse);
    });

    test('a timed-out copy fails, and the file is removed', () async {
      final d = _Devicectl(answer: 1)..timeouts.add('device copy');
      final s = serviceWith(d);
      expect(await s.deliverPairing(_phone, payload: payload),
          IosDelivery.failed);
      expect(s.lastDetail.value, contains('timed out'));
      expect(Directory(d.tempDir!).existsSync(), isFalse);
    });

    test('a failed nudge still delivers', () async {
      final d = _Devicectl(answer: 1)
        ..failures['device notification'] = _fixture('copy_failed.json');
      expect(await serviceWith(d).deliverPairing(_phone, payload: payload),
          IosDelivery.stored);
    });

    test('nothing is copied to a phone that is not cabled, trusting and in '
        'Developer Mode, or not listed', () async {
      final cases = {
        '00008150-000CCCCCCCCCCCCC': IosDelivery.notWired,
        '00008150-000DDDDDDDDDDDDD': IosDelivery.notPaired,
        '00008150-000EEEEEEEEEEEEE': IosDelivery.devModeOff,
        'NOT-THERE': IosDelivery.notWired,
      };
      for (final MapEntry(key: udid, value: expected) in cases.entries) {
        final d = _Devicectl(answer: 1);
        expect(await serviceWith(d).deliverPairing(udid, payload: payload),
            expected);
        expect(d.copied, isNull);
        expect(d.runs.map((r) => r[1]), ['list']);
      }
    });

    test('no Xcode', () async {
      expect(
          await serviceWith(_Devicectl()..noXcode = true)
              .deliverPairing(_phone, payload: payload),
          IosDelivery.noXcode);
    });
  });

  group('simulators (debug builds)', () {
    late Directory container;
    setUp(() {
      container = Directory.systemTemp.createTempSync('es-simcontainer-');
    });
    tearDown(() {
      if (container.existsSync()) container.deleteSync(recursive: true);
    });

    String inbox() => '${container.path}/Library/Application Support/ESInbox';

    _Devicectl simWith({int? answer}) => _Devicectl(answer: answer)
      ..simList = File('test/fixtures/simctl/list_booted.json')
          .readAsStringSync()
      ..container = container.path;

    test('list adds the booted, available iOS simulators after the devices',
        () async {
      final d = simWith();
      final devices = await serviceWith(d).list();
      expect(devices!.map((x) => x.udid), [
        _phone,
        '00008150-000CCCCCCCCCCCCC',
        '00008150-000DDDDDDDDDDDDD',
        '00008150-000EEEEEEEEEEEEE',
        _sim,
        'BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF',
      ]);
      final sim = devices[4];
      expect(sim.isSimulator, isTrue);
      expect(sim.name, 'ES iPhone 17 Pro Max');
      expect(sim.model, 'iPhone 17 Pro Max');
      expect(sim.runtime, 'iOS 26.5');
      expect(sim.offerable, isTrue);
      expect(sim.blocker, isNull);
      expect(devices[5].runtime, 'iOS 27.0');
      expect(devices.first.isSimulator, isFalse);
      expect(d.simRuns, [
        ['simctl', 'list', 'devices', 'booted', '-j'],
      ]);
    });

    test('a list without devicectl still has the simulators', () async {
      final d = simWith()
        ..failures['list devices'] = _fixture('copy_failed.json');
      final devices = await serviceWith(d).list();
      expect(devices!.map((x) => x.udid),
          [_sim, 'BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF']);
    });

    test('a shut-down simulator is not offerable', () {
      const off = IosDevice(
          udid: 'X',
          name: 'X',
          model: 'iPhone 17',
          isSimulator: true,
          simulatorState: 'Shutdown');
      expect(off.offerable, isFalse);
      expect(off.blocker, IosDelivery.notBooted);
      expect(IosDeviceService.parseSimulators(null), isEmpty);
      expect(IosDeviceService.parseSimulators({'devices': []}), isEmpty);
    });

    test('the container path is the first line simctl prints', () {
      const path = '/Users/someone/Library/Developer/CoreSimulator/Devices/'
          '$_sim/data/Containers/Data/Application/'
          '0A1B2C3D-0000-1111-2222-333344445555';
      expect(IosDeviceService.parseContainerPath('$path\n'), path);
      expect(IosDeviceService.parseContainerPath('  $path/\n'), path);
      expect(IosDeviceService.parseContainerPath(''), isNull);
      expect(IosDeviceService.parseContainerPath(_notInstalledStderr), isNull);
    });

    test('writes a 0600 pairing.bin into the container atomically, nudges '
        'the app inside the simulator, and reads its answer', () async {
      // A stale pairing.bin is replaced whole, never truncated in place.
      Directory(inbox()).createSync(recursive: true);
      File('${inbox()}/pairing.bin').writeAsBytesSync([9, 9, 9]);
      final d = simWith(answer: 1);
      String? tempPath;
      List<int>? pendingAtChmod;
      d.onChmod = (path) {
        tempPath = path;
        pendingAtChmod = File('${inbox()}/pairing.bin').readAsBytesSync();
      };
      final s = serviceWith(d);
      expect(await s.deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.stored);

      expect(d.taken, payload);
      expect(d.takenMode, 'rw-------');
      expect(File(tempPath!).parent.path, inbox(),
          reason: 'the temp file is beside pairing.bin, so the rename is '
              'atomic');
      expect(tempPath!.split('/').last, matches(RegExp(r'^\..*\.tmp$')));
      expect(pendingAtChmod, [9, 9, 9],
          reason: 'the old file is untouched until the rename');
      expect(Directory(inbox()).listSync().map((e) => e.path.split('/').last),
          unorderedEquals(['result']),
          reason: 'no temp file is left behind');

      expect(d.simRuns, [
        ['simctl', 'list', 'devices', 'booted', '-j'],
        ['simctl', 'get_app_container', _sim, iosBundleId, 'data'],
        ['simctl', 'spawn', _sim, 'notifyutil', '-p', '$iosBundleId.inbox'],
      ]);
      expect(d.runs, isEmpty, reason: 'no devicectl for a simulator');

      final token = payload.sublist(18, 50);
      final forms = [base64.encode(token), base64Url.encode(token),
          token.map((b) => b.toRadixString(16).padLeft(2, '0')).join()];
      for (final arg in [...d.simRuns.expand((r) => r), ...d.chmodded]) {
        for (final f in forms) {
          expect(arg.contains(f), isFalse);
        }
      }
    });

    test('a refusal is reported, and a result for another payload is not '
        'taken for this one', () async {
      expect(
          await serviceWith(simWith(answer: 2))
              .deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.refused);
      File('${inbox()}/result').deleteSync();
      final stale = simWith(answer: 1)..staleAnswer = true;
      expect(
          await serviceWith(stale)
              .deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.sent);
    });

    test('with the app closed it is sent, waiting in the inbox; a failed '
        'nudge is only logged', () async {
      final d = simWith(answer: 1)..nudgeFails = true;
      final s = serviceWith(d);
      expect(await s.deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.sent);
      expect(File('${inbox()}/pairing.bin').readAsBytesSync(), payload);
      expect(File('${inbox()}/pairing.bin').statSync().modeString(),
          'rw-------');
    });

    test('an app that is not installed is said so, and nothing is written',
        () async {
      final d = simWith(answer: 1)..container = null;
      final s = serviceWith(d);
      expect(await s.deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.notInstalled);
      expect(s.lastDetail.value, contains('not installed'));
      expect(d.simRuns.map((r) => r[1]), ['list', 'get_app_container']);
      expect(d.chmodded, isEmpty);
    });

    test('a simulator that is not booted gets nothing', () async {
      final d = simWith(answer: 1);
      expect(
          await serviceWith(d).deliverPairing(
              '66666666-7777-8888-9999-AAAAAAAAAAAA',
              payload: payload,
              simulator: true),
          IosDelivery.notBooted);
      expect(d.simRuns.map((r) => r[1]), ['list']);
    });

    test('a timed-out container lookup fails; no Xcode is noXcode', () async {
      final d = simWith(answer: 1)..simTimeouts.add('get_app_container');
      final s = serviceWith(d);
      expect(await s.deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.failed);
      expect(s.lastDetail.value, contains('timed out'));
      expect(
          await serviceWith(simWith()..noXcode = true)
              .deliverPairing(_sim, payload: payload, simulator: true),
          IosDelivery.noXcode);
    });
  });

  test('the app answer file: result byte and the payload hash', () {
    final h = sha256.convert(payload).bytes.sublist(0, 8);
    expect(IosDeviceService.parseResult([1, ...h], h), IosDelivery.stored);
    expect(IosDeviceService.parseResult([2, ...h], h), IosDelivery.refused);
    expect(IosDeviceService.parseResult([3, ...h], h), isNull);
    expect(IosDeviceService.parseResult([1, ...h.reversed], h), isNull);
    expect(IosDeviceService.parseResult([1], h), isNull);
  });

  test('the real runner ends a command at its timeout', () async {
    final watch = Stopwatch()..start();
    final r = await IosDeviceService.runCommand(
        '/bin/sleep', ['10'], const Duration(milliseconds: 200));
    expect(r.timedOut, isTrue);
    expect(r.exitCode, -1);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('the real runner reports a missing binary', () async {
    await expectLater(
        IosDeviceService.runCommand(
            '/nonexistent/xcrun', const [], const Duration(seconds: 1)),
        throwsA(isA<ProcessException>()));
  });

  test("offerPayload is the pairing adb delivers: this Mac's identity, its "
      'name and its addresses', () async {
    SharedPreferences.setMockInitialValues({});
    final pairing = WifiPairingService(
        generateCert: () async => (
              certPem: '-----BEGIN CERTIFICATE-----\nAAECAwQF\n'
                  '-----END CERTIFICATE-----',
              keyPem: 'key',
            ));
    final bytes = await pairing.offerPayload(
      lanAddresses: () async => [InternetAddress('192.168.1.20')],
      displayName: () async => 'Studio Mac',
    );
    final identity = await pairing.ensureIdentity();
    expect(
        bytes,
        WifiPairingService.buildPairingPayload(identity, 'Studio Mac',
            addresses: [InternetAddress('192.168.1.20')]));
    final host = WifiPairingService.parsePairingPayload(bytes)!;
    expect(host.name, 'Studio Mac');
    expect(host.addresses, ['192.168.1.20']);
    expect(host.certDer, [0, 1, 2, 3, 4, 5]);
  });
}
