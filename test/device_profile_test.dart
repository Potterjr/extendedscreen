import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_profile.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/device_settings_sheet.dart';

/// A device's own settings: the profile model, what it does to the capture
/// config, how Settings keeps it, and the sheet that edits it.

class _Manager extends BaseConnectionManager {
  _Manager() : super(socket: SocketService());

  final reconnected = <String>[];

  @override
  bool get isHost => true;
  @override
  Future<void> connect({String? serial}) async {}
  @override
  Future<void> autoConnect() async {}
  @override
  Future<void> reconnectSession(String key) async => reconnected.add(key);
}

void main() {
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Get.put(LoggerService());
    settings = SettingsService();
    await settings.init();
    Get.put(settings);
  });

  tearDown(Get.reset);

  const ultra = ClientPanel(2960, 1848, 120);
  const odd = ClientPanel(2961, 1849, 60);

  group('configFor', () {
    test('divisor 2 and no cap is what every preset gave before, on an even '
        'and an odd panel: half the panel, the preset\'s own rate and bitrate '
        '(Custom: its own values, its scale from its width)', () {
      const custom = CustomPreset(width: 1920, bitrateMbps: 15, refreshRate: 90);
      for (final preset in EncodePreset.values) {
        for (final panel in [ultra, odd]) {
          final c = preset.configFor(panel,
              custom: custom, mode: DisplayMode.extend, codec: CodecType.h265);
          final isCustom = preset == EncodePreset.custom;
          expect(c.width, panel.width ~/ 2, reason: '$preset $panel');
          expect(c.height, panel.height ~/ 2, reason: '$preset $panel');
          expect(c.refreshRate,
              isCustom ? 90 : preset.refreshRateFor(panel),
              reason: '$preset $panel');
          expect(c.bitrate, isCustom ? 15000000 : preset.bitrateFor(panel),
              reason: '$preset $panel');
          expect(
              c.scaleFactor,
              isCustom
                  ? (1920 / (panel.width ~/ 2)).clamp(0.5, 2.0)
                  : preset.scaleFactor,
              reason: '$preset $panel');
        }
      }
    });

    test('a larger divisor makes a smaller desktop, a cap a lower rate, and '
        "Max's bitrate follows both, never under 8 Mbps", () {
      final full = EncodePreset.max.configFor(ultra,
          mode: DisplayMode.extend, codec: CodecType.h265);
      final third = EncodePreset.max.configFor(ultra,
          mode: DisplayMode.extend,
          codec: CodecType.h265,
          divisor: 3,
          fpsCap: 60);
      expect((third.width, third.height), (986, 616));
      expect(third.refreshRate, 60);
      expect(third.bitrate, lessThan(full.bitrate));
      expect(third.bitrate, greaterThanOrEqualTo(8000000));
      // A cap above the rate changes nothing.
      final quality = EncodePreset.quality.configFor(ultra,
          mode: DisplayMode.extend, codec: CodecType.h264, fpsCap: 120);
      expect(quality.refreshRate, 60);
    });
  });

  group('DeviceProfile', () {
    test('round-trips through JSON, and a value this build does not know is '
        'no value', () {
      const p = DeviceProfile(
          preset: EncodePreset.quality,
          codec: CodecType.h264,
          displayMode: DisplayMode.mirror,
          divisor: 2.5,
          maxFps: 90);
      expect(DeviceProfile.fromJson(p.toJson()), p);
      expect(
          DeviceProfile.fromJson(
              {'preset': 'ultra', 'divisor': 7, 'maxFps': 59, 'codec': 'h265'}),
          const DeviceProfile(codec: CodecType.h265));
      expect(const DeviceProfile().isEmpty, isTrue);
      // Well-formed JSON of the wrong types reads as nothing, never throws.
      expect(DeviceProfile.fromJson({'divisor': '3', 'maxFps': 90.4}),
          const DeviceProfile());
    });

    test('Settings keeps it per device, applies it over the app-wide values, '
        'and keeps none for a synthetic or anonymous key', () async {
      await settings.setDeviceProfile(
          'TAB', const DeviceProfile(codec: CodecType.h264, divisor: 3));
      expect(settings.deviceProfile('TAB').divisor, 3);
      expect(settings.codecFor('TAB'), CodecType.h264);
      expect(settings.codecFor('OTHER'), settings.codec);
      expect(settings.displayModeFor('TAB'), settings.displayMode);

      await settings.setDeviceProfile(
          'synth-1', const DeviceProfile(divisor: 3));
      await settings.setDeviceProfile(
          'wifi:conn1', const DeviceProfile(divisor: 3));
      expect(settings.deviceProfile('synth-1').isEmpty, isTrue);
      expect(settings.deviceProfile('wifi:conn1').isEmpty, isTrue);

      await settings.setDeviceProfile('TAB', const DeviceProfile());
      expect(settings.deviceProfile('TAB').isEmpty, isTrue);
    });
  });

  testWidgets('the sheet saves a change for that device and restarts it '
      'alone, once', (tester) async {
    final manager =
        Get.put<BaseConnectionManager>(_Manager(), permanent: true) as _Manager;
    await tester.pumpWidget(const GetMaterialApp(
        home: Scaffold(body: DeviceSettingsSheet(deviceKey: 'TAB'))));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('device/divisor')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('device_settings_text_largest').last);
    await tester.pumpAndSettle();
    expect(settings.deviceProfile('TAB').divisor, 3);
    await tester.pump(const Duration(milliseconds: 400));
    expect(manager.reconnected, ['TAB'], reason: 'once, this device only');

    await tester.tap(find.byKey(const ValueKey('device/reset')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.deviceProfile('TAB').isEmpty, isTrue);
    expect(manager.reconnected, ['TAB', 'TAB']);
  });
}
