import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
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
