import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// What the host learns of its encoder's capacity, as SettingsService keeps
/// it: per chip and codec, in Mpx/s (EncodeBudget's learned capacity).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsService> settingsWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final settings = SettingsService();
    await settings.init();
    return settings;
  }

  tearDown(Get.reset);

  test('the key names the chip and the codec', () {
    expect(SettingsService.encoderCapacityKey('Apple M3 Pro', CodecType.h265),
        'encoder_capacity.apple-m3-pro.h265');
    expect(SettingsService.encoderCapacityKey('Apple M3 Pro', CodecType.h264),
        'encoder_capacity.apple-m3-pro.h264');
    expect(
        SettingsService.encoderCapacityKey(
            ' Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz ', CodecType.h264),
        'encoder_capacity.intel-r-core-tm-i9-9880h-cpu-2-30ghz.h264');
    expect(SettingsService.encoderCapacityKey('', CodecType.h265), isNull);
    expect(SettingsService.encoderCapacityKey(' — ', CodecType.h265), isNull);
  });

  test('a learned capacity is saved per chip and codec, and forgotten', () async {
    final settings = await settingsWith({});
    expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h265), isNull);

    await settings.setEncoderCapacityFor('Apple M3 Pro', CodecType.h265, 772.25);
    expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h265), 772.25);
    expect(settings.encoderCapacityFor('Apple M3 Pro', CodecType.h264), isNull);
    expect(settings.encoderCapacityFor('Apple M4 Pro', CodecType.h265), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('encoder_capacity.apple-m3-pro.h265'), 772.25);

    // Another run reads it.
    Get.reset();
    final again = await settingsWith({
      'flutter.encoder_capacity.apple-m3-pro.h265': 772.25,
    });
    expect(again.encoderCapacityFor('Apple M3 Pro', CodecType.h265), 772.25);

    await again.setEncoderCapacityFor('Apple M3 Pro', CodecType.h265, null);
    expect(again.encoderCapacityFor('Apple M3 Pro', CodecType.h265), isNull);
    expect((await SharedPreferences.getInstance()).getKeys().where((k) => k.startsWith('encoder_capacity.')),
        isEmpty);
  });

  test('nothing is saved for an unknown chip, and nothing that is not a '
      'capacity is read back', () async {
    final settings = await settingsWith({
      'flutter.encoder_capacity.apple-m3.h264': -5.0,
      'flutter.encoder_capacity.apple-m3.h265': 1e12,
    });
    await settings.setEncoderCapacityFor('', CodecType.h265, 500);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getKeys().where((k) => k.startsWith('encoder_capacity.')).toSet(),
        {'encoder_capacity.apple-m3.h264', 'encoder_capacity.apple-m3.h265'});
    expect(settings.encoderCapacityFor('Apple M3', CodecType.h264), isNull);
    expect(settings.encoderCapacityFor('Apple M3', CodecType.h265), isNull);

    await settings.setEncoderCapacityFor('Apple M3', CodecType.h264, double.nan);
    expect(prefs.containsKey('encoder_capacity.apple-m3.h264'), isFalse);
  });
}
