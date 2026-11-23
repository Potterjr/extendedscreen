import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/known_device.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A launch of the app on the preferences as they stand.
  Future<SettingsService> launch() async {
    final s = SettingsService();
    await s.init();
    return s;
  }

  Future<Object?> raw(String key) async =>
      (await SharedPreferences.getInstance()).get(key);

  group('migration to known devices', () {
    test('the saved last-used device becomes known with serial 1', () async {
      SharedPreferences.setMockInitialValues({
        'last_device': 'R52XC02C9RT',
        'last_device_name': 'SM_X920',
      });
      final s = await launch();
      expect(s.knownDevices, hasLength(1));
      final d = s.knownDevice('R52XC02C9RT')!;
      expect(d.vdSerial, 1);
      expect(d.model, 'SM_X920');
      expect(s.vdSerialFor('R52XC02C9RT'), 1);
      expect(s.vdNameFor('R52XC02C9RT'), 'Extended Screen');
    });

    test('nothing is written when no device was ever used', () async {
      // lastDeviceSerial falls back to the build's DEVICE_SERIAL; that
      // tablet was never used here and must not take serial 1.
      SharedPreferences.setMockInitialValues({});
      final s = await launch();
      expect(s.lastDeviceSerial, isNotNull);
      expect(await raw('known_devices'), isNull);
      expect(s.knownDevices, isEmpty);
      expect(s.vdSerialFor(s.lastDeviceSerial!), isNot(1));
    });

    test('runs once', () async {
      SharedPreferences.setMockInitialValues({'last_device': 'OLD'});
      final s = await launch();
      await s.setLastDevice('NEWER');
      await launch();
      final again = await launch();
      expect(again.knownDevices.map((d) => d.serial), ['OLD']);
      expect(again.vdSerialFor('NEWER'), isNot(1));
    });
  });

  test('fnv1a32 matches the reference vectors', () {
    expect(SettingsService.fnv1a32(''), 0x811C9DC5);
    expect(SettingsService.fnv1a32('a'), 0xE40C292C);
    expect(SettingsService.fnv1a32('foobar'), 0xBF9CF968);
  });

  group('vdSerialFor', () {
    test('is stable, never 0 or 1, and above 0xFFFF', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await launch();
      for (final key in ['A', 'R52XC02C9RT', 'emulator-5554', '']) {
        final v = s.vdSerialFor(key);
        expect(v, s.vdSerialFor(key));
        expect(v, isNot(anyOf(0, 1)));
        expect(v & 0x10000, 0x10000);
        expect(v, lessThanOrEqualTo(0xFFFFFFFF));
      }
      expect(s.vdSerialFor('A'), SettingsService.fnv1a32('A') | 0x10000);
    });

    test('steps past taken and stored serials', () async {
      final natural = SettingsService.fnv1a32('B') | 0x10000;
      final next = ((natural + 1) & 0xFFFFFFFF) | 0x10000;
      SharedPreferences.setMockInitialValues({
        'known_devices': jsonEncode([
          {'serial': 'OTHER', 'vdSerial': natural},
        ]),
      });
      final s = await launch();
      expect(s.vdSerialFor('B'), next);
      expect(s.vdSerialFor('B', taken: {next}),
          ((next + 1) & 0xFFFFFFFF) | 0x10000);
      // A tablet's own stored serial wins, taken or not.
      expect(s.vdSerialFor('OTHER', taken: {natural}), natural);
    });

    test('a list that cannot be read is no list', () async {
      SharedPreferences.setMockInitialValues({'known_devices': '{not json'});
      final s = await launch();
      expect(s.knownDevices, isEmpty);
      expect(s.vdSerialFor('A'), SettingsService.fnv1a32('A') | 0x10000);
    });
  });

  group('rememberDevice', () {
    test('keeps the serial a tablet has and writes the last-used device',
        () async {
      SharedPreferences.setMockInitialValues({});
      final s = await launch();
      await s.rememberDevice('T1', model: 'SM_X920', vdSerial: 0x12345);
      await s.rememberDevice('T1', model: 'SM_X926', vdSerial: 0x54321);
      final d = s.knownDevice('T1')!;
      expect(d.vdSerial, 0x12345);
      expect(d.model, 'SM_X926');
      expect(s.lastDeviceSerial, 'T1');
      expect(s.lastDeviceName, 'SM_X926');
      expect(s.vdSerialFor('T1'), 0x12345);
      expect(s.vdNameFor('T1'), 'Extended Screen – SM X926');
    });

    test('keeps an install id', () async {
      SharedPreferences.setMockInitialValues({
        'known_devices': jsonEncode([
          {'serial': 'T1', 'vdSerial': 7, 'installId': 'abc'},
        ]),
      });
      final s = await launch();
      await s.rememberDevice('T1', model: 'Pixel', vdSerial: 9);
      expect(s.knownDevice('T1')!.installId, 'abc');
      expect(s.knownDevice('T1')!.vdSerial, 7);
    });

    test('vdNameFor: serial 1 keeps today\'s name; no model, no suffix',
        () async {
      SharedPreferences.setMockInitialValues({
        'last_device': 'MIGRATED',
        'last_device_name': 'SM_X920',
      });
      final s = await launch();
      expect(s.vdNameFor('MIGRATED'), 'Extended Screen');
      expect(s.vdNameFor('UNKNOWN'), 'Extended Screen');
      expect(s.vdNameFor('UNKNOWN', model: 'Lenovo_TB'),
          'Extended Screen – Lenovo TB');
    });
  });

  group('a tablet\'s remembered mode', () {
    const reverse = SessionChoice(
        SessionMode.remoteControl, RemoteDirection.macControlsTab);
    const tabDrives = SessionChoice(SessionMode.remoteControl);
    const extended = SessionChoice(SessionMode.extendedScreen);

    // A launch that reads the store again, not the cache the last
    // SettingsService wrote through.
    Future<SettingsService> relaunch() {
      SharedPreferences.resetStatic();
      return launch();
    }

    test('an entry from before modes were kept reads with none', () async {
      const stored = [
        {'serial': 'T1', 'model': 'SM_X920', 'vdSerial': 1},
        {'serial': 'T2', 'vdSerial': 70001, 'installId': 'abc'},
      ];
      SharedPreferences.setMockInitialValues(
          {'known_devices': jsonEncode(stored)});
      final s = await launch();
      expect(s.knownDevices, hasLength(2));
      expect(s.knownDevice('T1')!.choice, isNull);
      expect(s.knownDevice('T2')!.choice, isNull);
      expect(s.knownChoice('T1'), isNull);
      expect(s.knownChoice('NOBODY'), isNull);
      // And goes back out as it came in.
      expect(jsonEncode(s.knownDevices.map((d) => d.toJson()).toList()),
          jsonEncode(stored));
    });

    test('toJson without a mode is what it was', () {
      expect(
          jsonEncode(const KnownDevice(
                  serial: 'T1',
                  model: 'SM_X920',
                  vdSerial: 5,
                  installId: 'abc')
              .toJson()),
          '{"serial":"T1","model":"SM_X920","vdSerial":5,"installId":"abc"}');
      expect(jsonEncode(const KnownDevice(serial: 'T1', vdSerial: 5).toJson()),
          '{"serial":"T1","vdSerial":5}');
    });

    test('a mode goes out as enum names and comes back', () {
      for (final choice in const [
        extended,
        tabDrives,
        reverse,
        // The direction an Extended screen carries is kept as picked.
        SessionChoice(
            SessionMode.extendedScreen, RemoteDirection.macControlsTab),
      ]) {
        final d = KnownDevice(
            serial: 'T1', model: 'SM_X920', vdSerial: 5, choice: choice);
        final json = d.toJson();
        expect(json['mode'], choice.mode.name);
        expect(json['direction'], choice.direction.name);
        final back = KnownDevice.fromJson(jsonDecode(jsonEncode(json)))!;
        expect(back.serial, 'T1');
        expect(back.model, 'SM_X920');
        expect(back.vdSerial, 5);
        expect(back.choice, choice);
      }
      expect(
          jsonEncode(const KnownDevice(serial: 'T1', vdSerial: 5, choice: reverse)
              .toJson()),
          '{"serial":"T1","vdSerial":5,'
          '"mode":"remoteControl","direction":"macControlsTab"}');
    });

    test('copyWith takes a mode and otherwise keeps it', () {
      const d = KnownDevice(serial: 'T1', vdSerial: 5, choice: reverse);
      expect(d.copyWith(model: 'Pixel').choice, reverse);
      expect(d.copyWith(choice: extended).choice, extended);
      expect(d.copyWith(choice: extended).vdSerial, 5);
      expect(const KnownDevice(serial: 'T1', vdSerial: 5).copyWith().choice,
          isNull);
    });

    test('a mode this build cannot read never costs the entry', () async {
      SharedPreferences.setMockInitialValues({
        'known_devices': jsonEncode([
          {
            'serial': 'T1',
            'model': 'SM_X920',
            'vdSerial': 1,
            'mode': 'bogus',
            'direction': 'macControlsTab',
          },
          {'serial': 'T2', 'vdSerial': 70001, 'mode': 7, 'direction': 3},
          {'serial': 'T3', 'vdSerial': 70002, 'mode': 'remoteControl'},
          {
            'serial': 'T4',
            'vdSerial': 70003,
            'mode': 'remoteControl',
            'direction': 'sideways',
          },
          {'serial': 'T5', 'vdSerial': 70004, 'direction': 'macControlsTab'},
        ]),
      });
      final s = await launch();
      expect(s.knownDevices.map((d) => d.serial),
          ['T1', 'T2', 'T3', 'T4', 'T5']);
      expect(s.knownDevice('T1')!.vdSerial, 1);
      expect(s.knownDevice('T1')!.model, 'SM_X920');
      expect(s.knownChoice('T1'), isNull);
      expect(s.vdSerialFor('T1'), 1);
      expect(s.knownDevice('T2')!.vdSerial, 70001);
      expect(s.knownChoice('T2'), isNull);
      // An unknown or missing direction is the default one.
      expect(s.knownChoice('T3'), tabDrives);
      expect(s.knownChoice('T4'), tabDrives);
      // A direction alone is no mode.
      expect(s.knownChoice('T5'), isNull);
    });

    test('a key this build does not know survives every rewrite', () async {
      // Every save writes the whole list, so what a later build keeps in an
      // entry must not be lost when another tablet goes live here.
      const stored = [
        {
          'serial': 'T1',
          'model': 'SM_X920',
          'vdSerial': 1,
          'mode': 'remoteControl',
          'direction': 'macControlsTab',
          'future': 1,
          'nested': {
            'a': [1, 'two'],
          },
        },
        {'serial': 'T2', 'vdSerial': 70001, 'later': 'x'},
      ];
      SharedPreferences.setMockInitialValues(
          {'known_devices': jsonEncode(stored)});
      final s = await launch();
      expect(s.knownChoice('T1'), reverse);
      // Read and written with nothing else done, it is what it was.
      expect(jsonEncode(s.knownDevices.map((d) => d.toJson()).toList()),
          jsonEncode(stored));

      Future<Map<String, dynamic>> entry(String serial) async {
        final list =
            jsonDecode((await raw('known_devices'))! as String) as List;
        return (list.firstWhere((e) => (e as Map)['serial'] == serial) as Map)
            .cast<String, dynamic>();
      }

      // Another tablet goes live, then a new one.
      await s.rememberDevice('T2', model: 'SM_X210', vdSerial: 9);
      await s.rememberDevice('T3', vdSerial: 0x12345, choice: extended);
      expect(await entry('T1'), stored[0]);
      expect(await entry('T2'), {...stored[1], 'model': 'SM_X210'});

      // Its own session goes live in another mode, and its mode is changed.
      await s.rememberDevice('T1',
          model: 'SM_X926', vdSerial: 99, choice: tabDrives);
      s.setKnownChoice('T2', reverse);
      await pumpEventQueue();
      expect(await entry('T1'), {
        ...stored[0],
        'model': 'SM_X926',
        'direction': 'tabControlsMac',
      });
      expect(await entry('T2'), {
        ...stored[1],
        'model': 'SM_X210',
        'mode': 'remoteControl',
        'direction': 'macControlsTab',
      });

      final again = await relaunch();
      expect(again.knownChoice('T1'), tabDrives);
      expect(again.knownChoice('T2'), reverse);
      expect(again.knownDevice('T1')!.toJson()['future'], 1);
      expect(again.knownDevice('T1')!.toJson()['nested'], {
        'a': [1, 'two'],
      });
      expect(again.knownDevice('T2')!.toJson()['later'], 'x');
    });

    test(
        'a mode this build cannot read goes back as it came, until one is '
        'saved over it', () async {
      const stored = [
        {'serial': 'T1', 'vdSerial': 1, 'mode': 'holo', 'direction': 'up'},
        {
          'serial': 'T2',
          'vdSerial': 70001,
          'mode': 'remoteControl',
          'direction': 'sideways',
        },
        {'serial': 'T3', 'vdSerial': 70002, 'mode': 'holo'},
        {'serial': 'T4', 'vdSerial': 70003},
      ];
      SharedPreferences.setMockInitialValues(
          {'known_devices': jsonEncode(stored)});
      final s = await launch();
      expect(s.knownChoice('T1'), isNull);
      expect(s.knownChoice('T2'), tabDrives);
      expect(s.knownChoice('T3'), isNull);

      // Another tablet's session goes live, one of them without a choice,
      // and another's mode is changed: the list is rewritten each time.
      await s.rememberDevice('T4', model: 'Pixel', vdSerial: 9);
      await s.rememberDevice('T1', model: 'SM_X920', vdSerial: 9);
      s.setKnownChoice('T4', extended);
      await pumpEventQueue();
      expect(jsonDecode((await raw('known_devices'))! as String), [
        {...stored[0], 'model': 'SM_X920'},
        stored[1],
        stored[2],
        {
          'serial': 'T4',
          'model': 'Pixel',
          'vdSerial': 70003,
          'mode': 'extendedScreen',
          'direction': 'tabControlsMac',
        },
      ]);
      var again = await relaunch();
      expect(again.knownChoice('T1'), isNull);
      expect(again.knownChoice('T2'), tabDrives);

      // A mode saved for the tablet itself replaces what could not be read,
      // the direction too.
      await again.rememberDevice('T1', vdSerial: 9, choice: reverse);
      again.setKnownChoice('T2', tabDrives);
      again.setKnownChoice('T3', extended);
      await pumpEventQueue();
      expect(
          (jsonDecode((await raw('known_devices'))! as String) as List)
              .take(3),
          [
            {
              'serial': 'T1',
              'model': 'SM_X920',
              'vdSerial': 1,
              'mode': 'remoteControl',
              'direction': 'macControlsTab',
            },
            {
              'serial': 'T2',
              'vdSerial': 70001,
              'mode': 'remoteControl',
              'direction': 'tabControlsMac',
            },
            {
              'serial': 'T3',
              'vdSerial': 70002,
              'mode': 'extendedScreen',
              'direction': 'tabControlsMac',
            },
          ]);
      again = await relaunch();
      expect(again.knownChoice('T1'), reverse);
      expect(again.knownChoice('T2'), tabDrives);
      expect(again.knownChoice('T3'), extended);
    });

    test('rememberDevice saves a mode and never touches the display serial',
        () async {
      SharedPreferences.setMockInitialValues({
        'known_devices': jsonEncode([
          {'serial': 'T1', 'vdSerial': 7, 'installId': 'abc'},
        ]),
      });
      final s = await launch();
      await s.rememberDevice('T1',
          model: 'SM_X920', vdSerial: 99, choice: reverse);
      expect(s.knownChoice('T1'), reverse);
      expect(s.knownDevice('T1')!.vdSerial, 7);
      expect(s.knownDevice('T1')!.installId, 'abc');
      expect(s.knownDevice('T1')!.model, 'SM_X920');
      expect(s.lastDeviceSerial, 'T1');

      // A later call without one keeps it.
      await s.rememberDevice('T1', model: 'SM_X926', vdSerial: 99);
      expect(s.knownChoice('T1'), reverse);
      expect(s.knownDevice('T1')!.model, 'SM_X926');
      expect(s.knownDevice('T1')!.vdSerial, 7);

      // And one with another replaces it.
      await s.rememberDevice('T1', vdSerial: 99, choice: extended);
      expect(s.knownChoice('T1'), extended);
      expect(s.knownDevice('T1')!.vdSerial, 7);
      expect(s.knownDevice('T1')!.model, 'SM_X926');

      // A new tablet takes the mode it went live in.
      await s.rememberDevice('T2', vdSerial: 0x12345, choice: tabDrives);
      expect(s.knownChoice('T2'), tabDrives);
      expect(s.knownDevice('T2')!.vdSerial, 0x12345);
      await s.rememberDevice('T3', vdSerial: 0x12346);
      expect(s.knownChoice('T3'), isNull);

      final again = await relaunch();
      expect(again.knownChoice('T1'), extended);
      expect(again.knownChoice('T2'), tabDrives);
      expect(again.knownChoice('T3'), isNull);
      expect(again.knownDevice('T1')!.vdSerial, 7);
    });

    test('setKnownChoice is read back at once and saved by itself', () async {
      SharedPreferences.setMockInitialValues({
        'known_devices': jsonEncode([
          {'serial': 'T1', 'model': 'SM_X920', 'vdSerial': 1},
          {'serial': 'T2', 'vdSerial': 70001, 'installId': 'abc'},
        ]),
      });
      final s = await launch();
      // No await: the caller reads it in the same synchronous step.
      s.setKnownChoice('T1', reverse);
      expect(s.knownChoice('T1'), reverse);
      expect(s.knownChoice('T2'), isNull);
      s.setKnownChoice('T1', tabDrives);
      s.setKnownChoice('T2', extended);
      expect(s.knownChoice('T1'), tabDrives);
      expect(s.knownChoice('T2'), extended);
      // Nothing else about either moved.
      expect(s.knownDevice('T1')!.vdSerial, 1);
      expect(s.knownDevice('T1')!.model, 'SM_X920');
      expect(s.knownDevice('T2')!.vdSerial, 70001);
      expect(s.knownDevice('T2')!.installId, 'abc');
      expect(s.knownDevices.map((d) => d.serial), ['T1', 'T2']);

      await pumpEventQueue();
      final again = await relaunch();
      expect(again.knownChoice('T1'), tabDrives);
      expect(again.knownChoice('T2'), extended);
      expect(again.knownDevice('T1')!.vdSerial, 1);
      expect(again.knownDevice('T2')!.installId, 'abc');
    });

    test('setKnownChoice writes nothing for a tablet that is not known',
        () async {
      final stored = jsonEncode([
        {'serial': 'T1', 'vdSerial': 7},
      ]);
      SharedPreferences.setMockInitialValues({'known_devices': stored});
      final s = await launch();
      s.setKnownChoice('STRANGER', reverse);
      s.setKnownChoice('synth-1', reverse);
      await pumpEventQueue();
      expect(s.knownChoice('STRANGER'), isNull);
      expect(s.knownChoice('synth-1'), isNull);
      expect(s.knownDevices.map((d) => d.serial), ['T1']);
      expect(await raw('known_devices'), stored);
      expect((await relaunch()).knownDevices.map((d) => d.serial), ['T1']);
    });

    test('a synthetic tablet\'s mode is never kept', () async {
      // Not even for an entry that should not be there.
      final stored = jsonEncode([
        {'serial': 'synth-1', 'vdSerial': 7},
      ]);
      SharedPreferences.setMockInitialValues({'known_devices': stored});
      final s = await launch();
      s.setKnownChoice('synth-1', reverse);
      await s.rememberDevice('synth-1', vdSerial: 7, choice: reverse);
      await pumpEventQueue();
      expect(s.knownChoice('synth-1'), isNull);
      expect(await raw('known_devices'), stored);

      SharedPreferences.setMockInitialValues({});
      final empty = await launch();
      empty.setKnownChoice('synth-1', reverse);
      await empty.rememberDevice('synth-1', vdSerial: 7, choice: reverse);
      await pumpEventQueue();
      expect(await raw('known_devices'), isNull);
    });
  });

  test('a synthetic tablet writes nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await launch();
    final before = s.lastClientPanel;
    const synth = 'synth-1';
    expect(SettingsService.isSyntheticKey(synth), isTrue);
    expect(SettingsService.isSyntheticKey('R52XC02C9RT'), isFalse);
    await s.setClientPanelFor(synth, const ClientPanel(1000, 600, 90));
    await s.rememberDevice(synth, model: 'Synthetic_tablet', vdSerial: 5);
    await s.setLastDevice(synth);
    await s.setTabletScreenOffFor(synth, true);
    expect(s.lastClientPanel, before);
    expect(s.clientPanelFor(synth), isNull);
    expect(s.knownDevices, isEmpty);
    expect(await raw('known_devices'), isNull);
    expect(await raw('last_device'), isNull);
    expect(await raw('last_device_name'), isNull);
    expect(s.tabletScreenOffFor(synth), isFalse);
  });

  group('max_tablets', () {
    test('is 4 when nothing is saved', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await launch()).maxTablets, 4);
    });

    test('is kept between 1 and 8', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await launch();
      await s.setMaxTablets(0);
      expect(s.maxTablets, 1);
      await s.setMaxTablets(20);
      expect(s.maxTablets, 8);
      await s.setMaxTablets(3);
      expect((await launch()).maxTablets, 3);
      SharedPreferences.setMockInitialValues({'max_tablets': 99});
      expect((await launch()).maxTablets, 8);
    });
  });

  group('captureConfigFor', () {
    const spec = SessionSpec(
      link: LinkType.usb,
      mode: SessionMode.extendedScreen,
      direction: RemoteDirection.tabControlsMac,
      displayMode: DisplayMode.mirror,
    );

    for (final panel in const [
      ClientPanel(2960, 1848, 120),
      ClientPanel(2560, 1600, 60),
    ]) {
      for (final preset in EncodePreset.values) {
        test('${preset.name} at $panel gives what the capture getters give',
            () async {
          SharedPreferences.setMockInitialValues({});
          final s = await launch();
          await s.setEncodePreset(preset);
          final c = s.captureConfigFor(panel, spec);
          expect(c.width, s.captureWidthFor(panel));
          expect(c.height, s.captureHeightFor(panel));
          expect(c.scaleFactor, s.captureScaleFactorFor(panel));
          expect(c.refreshRate, s.refreshRateFor(panel));
          expect(c.bitrate, s.captureBitrateFor(panel));
          expect(c.mode, DisplayMode.mirror);
          expect(c.codec, s.codec);
          expect(c.adaptiveFps, preset == EncodePreset.max);
          expect(c.fpsCeiling, isNull);
          expect(c.toMap().containsKey('fpsCeiling'), isFalse);
        });
      }
    }

    test('encoded size rounds down to even numbers, as the Swift side does',
        () {
      const c = DisplayConfigModel(
        width: 1480,
        height: 924,
        refreshRate: 60,
        scaleFactor: 1920.5 / 1480,
        mode: DisplayMode.extend,
        codec: CodecType.h265,
        bitrate: 1,
      );
      expect(c.encodedWidth, 1920);
      expect(c.encodedHeight, 1198);
      expect(c.encodedPixels, 1920 * 1198);
      expect(c.copyWith(fpsCeiling: 45).toMap()['fpsCeiling'], 45);
    });
  });

  test('withoutMdnsDuplicates hides the wireless entry of a listed tablet',
      () {
    DeviceModel d(String serial) =>
        DeviceModel(serial: serial, status: DeviceStatus.connected);
    final list = [
      d('R52XC02C9RT'),
      d('adb-R52XC02C9RT-Ab12Cd._adb-tls-connect._tcp'),
      d('adb-OTHER-9xYz._adb-tls-connect._tcp.'),
      d('emulator-5554'),
    ];
    expect(DeviceModel.withoutMdnsDuplicates(list).map((e) => e.serial), [
      'R52XC02C9RT',
      'adb-OTHER-9xYz._adb-tls-connect._tcp.',
      'emulator-5554',
    ]);
    expect(d('emulator-5554').isEmulator, isTrue);
    expect(d('R52XC02C9RT').isEmulator, isFalse);
    expect(d('synth-2').isSynthetic, isTrue);
  });
}
