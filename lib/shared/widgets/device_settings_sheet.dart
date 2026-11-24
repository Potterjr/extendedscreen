import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/models/device_profile.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Host: one device's own settings, opened from its card. Every row starts
/// on "as in Settings" (the app-wide value, shown in brackets); picking
/// another value saves it for this device alone (`device_profile.<key>`)
/// and, 350 ms after the last change, restarts this device only
/// ([BaseConnectionManager.reconnectSession]).
class DeviceSettingsSheet extends StatefulWidget {
  const DeviceSettingsSheet({super.key, required this.deviceKey, this.name});

  final String deviceKey;
  final String? name;

  /// Opens the sheet for [deviceKey].
  static Future<void> show(BuildContext context, String deviceKey,
          {String? name}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF111827),
        builder: (_) => DeviceSettingsSheet(deviceKey: deviceKey, name: name),
      );

  @override
  State<DeviceSettingsSheet> createState() => _DeviceSettingsSheetState();
}

class _DeviceSettingsSheetState extends State<DeviceSettingsSheet> {
  final _settings = Get.find<SettingsService>();
  late DeviceProfile _profile = _settings.deviceProfile(widget.deviceKey);
  Timer? _restart;

  static const _debounce = Duration(milliseconds: 350);

  @override
  void dispose() {
    // A change still waiting is applied now, not dropped with the sheet.
    if (_restart?.isActive ?? false) {
      _restart!.cancel();
      _applyNow();
    }
    super.dispose();
  }

  void _change(DeviceProfile next) {
    if (next == _profile) return;
    setState(() => _profile = next);
    unawaited(_settings.setDeviceProfile(widget.deviceKey, next));
    _restart?.cancel();
    _restart = Timer(_debounce, _applyNow);
  }

  void _applyNow() {
    if (!Get.isRegistered<BaseConnectionManager>()) return;
    unawaited(Get.find<BaseConnectionManager>()
        .reconnectSession(widget.deviceKey));
  }

  String _asInSettings(String value) =>
      'device_settings_default'.trParams({'value': value});

  @override
  Widget build(BuildContext context) {
    final presetNow = _settings.encodePreset.label;
    final codecNow = _codecLabel(_settings.codec);
    final modeNow = _modeLabel(_settings.displayMode);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'device_settings_title'
                  .trParams({'name': widget.name ?? widget.deviceKey}),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'device_settings_restarts'.tr,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
            ),
            const SizedBox(height: 12),
            _Row<EncodePreset>(
              key: const ValueKey('device/preset'),
              title: 'device_settings_preset'.tr,
              value: _profile.preset,
              defaultLabel: _asInSettings(presetNow),
              options: {for (final p in EncodePreset.values) p: p.label},
              onChanged: (v) => _change(_profile.copyWith(preset: () => v)),
            ),
            _Row<CodecType>(
              key: const ValueKey('device/codec'),
              title: 'settings_codec'.tr,
              value: _profile.codec,
              defaultLabel: _asInSettings(codecNow),
              options: {for (final c in CodecType.values) c: _codecLabel(c)},
              onChanged: (v) => _change(_profile.copyWith(codec: () => v)),
            ),
            _Row<DisplayMode>(
              key: const ValueKey('device/mode'),
              title: 'device_settings_display_mode'.tr,
              value: _profile.displayMode,
              defaultLabel: _asInSettings(modeNow),
              options: {for (final m in DisplayMode.values) m: _modeLabel(m)},
              onChanged: (v) =>
                  _change(_profile.copyWith(displayMode: () => v)),
            ),
            _Row<double>(
              key: const ValueKey('device/divisor'),
              title: 'device_settings_text_size'.tr,
              value: _profile.divisor,
              defaultLabel: _asInSettings(_divisorLabel(2)),
              options: {
                for (final d in DeviceProfile.divisors) d: _divisorLabel(d),
              },
              onChanged: (v) => _change(_profile.copyWith(divisor: () => v)),
            ),
            _Row<int>(
              key: const ValueKey('device/fps'),
              title: 'device_settings_max_fps'.tr,
              value: _profile.maxFps,
              defaultLabel: 'device_settings_no_limit'.tr,
              options: {for (final f in DeviceProfile.fpsCaps) f: '$f fps'},
              onChanged: (v) => _change(_profile.copyWith(maxFps: () => v)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('device/reset'),
                onPressed: _profile.isEmpty
                    ? null
                    : () => _change(const DeviceProfile()),
                child: Text('device_settings_reset'.tr),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _codecLabel(CodecType c) =>
      c == CodecType.h265 ? 'H.265' : 'H.264';

  static String _modeLabel(DisplayMode m) => m == DisplayMode.extend
      ? 'settings_mode_extend'.tr
      : 'settings_mode_mirror'.tr;

  static String _divisorLabel(double d) => switch (d) {
        2.0 => 'device_settings_text_sharp'.tr,
        2.5 => 'device_settings_text_larger'.tr,
        _ => 'device_settings_text_largest'.tr,
      };
}

/// One setting: "as in Settings" (null) or one of [options].
class _Row<T> extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    required this.value,
    required this.defaultLabel,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final T? value;
  final String defaultLabel;
  final Map<T, String> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
          DropdownButton<T?>(
            value: value,
            dropdownColor: const Color(0xFF1F2937),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem<T?>(value: null, child: Text(defaultLabel)),
              for (final MapEntry(:key, :value) in options.entries)
                DropdownMenuItem<T?>(value: key, child: Text(value)),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
