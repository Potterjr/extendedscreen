import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/features/settings/controllers/settings_controller.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('settings_title'.tr,
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        controller: controller.scrollController,
        padding: const EdgeInsets.all(20),
        children: [
          // Language picker — available on both roles (a UI-level preference).
          _SectionHeader('settings_section_general'.tr),
          _SettingsCard(children: [
            Obx(() => _ChoiceRow(
                  label: 'settings_language'.tr,
                  value: AppTranslations.localeName(controller.localeCode.value),
                  onTap: () => _showLanguagePicker(context),
                )),
          ]),
          const SizedBox(height: 16),
          if (controller.isHost) ...[
            _SectionHeader('settings_section_display'.tr),
            _SettingsCard(children: [
              Obx(() => _SegmentRow(
                    label: 'settings_mode'.tr,
                    options: [
                      'settings_mode_extend'.tr,
                      'settings_mode_mirror'.tr,
                    ],
                    selected:
                        controller.mode.value == DisplayMode.extend ? 0 : 1,
                    enabled: !controller.isApplying.value,
                    onChanged: (i) => controller.setMode(
                        i == 0 ? DisplayMode.extend : DisplayMode.mirror),
                  )),
            ]),
            const SizedBox(height: 16),
            _SectionHeader('settings_section_performance'.tr),
            _SettingsCard(children: [
              Obx(() => _ChoiceRow(
                    label: 'settings_encode_preset'.tr,
                    value: controller.encodePreset.value.label,
                    enabled: !controller.isApplying.value,
                    onTap: () => _showPresetPicker(context),
                  )),
              Obx(() => controller.isApplying.value
                  ? Padding(
                      padding: const EdgeInsets.only(
                          left: 16, right: 16, bottom: 12),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF00C8FF)),
                          ),
                          const SizedBox(width: 10),
                          Text('settings_reconnecting_to_apply'.tr,
                              style: const TextStyle(
                                  color: Color(0xFF00C8FF), fontSize: 13)),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(
                          left: 16, right: 16, bottom: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'settings_perf_reconnect_note'.tr,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 12),
                        ),
                      ),
                    )),
              const Divider(height: 1, color: Colors.white12),
              Obx(() => _ToggleRow(
                    label: 'settings_performance_overlay'.tr,
                    value: controller.showPerformanceOverlay.value,
                    onChanged: (_) => controller.togglePerformanceOverlay(),
                  )),
              const Divider(height: 1, color: Colors.white12),
              Obx(() => _ToggleRow(
                    label: 'settings_show_hud'.tr,
                    value: controller.showHudOverlay.value,
                    onChanged: (_) => controller.toggleHudOverlay(),
                  )),
            ]),
            // Custom values — shown only when the Custom preset is selected.
            Obx(() => controller.encodePreset.value == EncodePreset.custom
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),
                      _SectionHeader('settings_section_custom'.tr),
                      _SettingsCard(children: [
                        Obx(() => _ChoiceRow(
                              label: 'settings_custom_values'.tr,
                              value: '${controller.customResolutionLabel} · '
                                  '${controller.customBitrateLabel} · '
                                  '${controller.customRefreshRate.value} Hz',
                              enabled: !controller.isApplying.value,
                              onTap: () => _showCustomValuesSheet(context),
                            )),
                      ]),
                    ],
                  )
                : const SizedBox.shrink()),
          ] else ...[
            _SectionHeader('settings_section_display'.tr),
            _SettingsCard(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'settings_client_display_note'.tr,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 16),
          _SectionHeader('settings_section_permissions'.tr,
              key: controller.permissionsKey),
          Obx(() {
            if (controller.isLoadingPerms.value) {
              return const _SettingsCard(children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFF00C8FF)),
                    ),
                  ),
                ),
              ]);
            }
            final perms = controller.permissions;
            if (perms.isEmpty) return const SizedBox.shrink();
            return _SettingsCard(
              children: [
                for (int i = 0; i < perms.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Colors.white12),
                  _PermissionRow(
                    item: perms[i],
                    onOpen: () => controller.openPermission(perms[i].key),
                  ),
                ],
                const Divider(height: 1, color: Colors.white12),
                InkWell(
                  onTap: controller.refreshPermissions,
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.refresh,
                            size: 14, color: Color(0xFF00C8FF)),
                        const SizedBox(width: 6),
                        Text('common_refresh'.tr,
                            style: const TextStyle(
                                color: Color(0xFF00C8FF), fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 16),
          _SectionHeader('settings_section_info'.tr),
          _SettingsCard(children: [
            _InfoRow(label: 'settings_transport'.tr, value: 'USB-C / ADB'),
            const Divider(height: 1, color: Colors.white12),
            Obx(() => _InfoRow(
                  label: 'settings_codec'.tr,
                  value: controller.codec.value == CodecType.h265
                      ? 'settings_codec_h265_hw'.tr
                      : 'settings_codec_h264_hw'.tr,
                )),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'settings_port'.tr, value: '7001'),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'settings_version'.tr, value: '1.0.0'),
            const Divider(height: 1, color: Colors.white12),
            Obx(() => _InfoRow(
                label: 'settings_target_device'.tr,
                value: controller.targetDeviceName)),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'settings_host'.tr, value: 'macOS 13+'),
          ]),
        ],
      ),
    );
  }

  void _showPresetPicker(BuildContext context) {
    Get.bottomSheet(
      _PresetPickerSheet(controller: controller),
      isScrollControlled: true,
    );
  }

  void _showLanguagePicker(BuildContext context) {
    final codes = AppTranslations.supportedLocales;
    Get.bottomSheet(
      _PickerSheet(
        title: 'settings_language'.tr,
        items: codes.map(AppTranslations.localeName).toList(),
        selected: codes.indexOf(controller.localeCode.value),
        onSelected: (i) => controller.setLocale(codes[i]),
      ),
    );
  }

  /// All three custom values (resolution, bitrate, refresh) in one sheet
  /// instead of three chained ones — each control applies immediately, and
  /// the controller's reconnect debounce collapses several quick changes into
  /// a single reconnect.
  void _showCustomValuesSheet(BuildContext context) {
    Get.bottomSheet(
      _CustomValuesSheet(controller: controller),
      isScrollControlled: true,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: children),
      );
}

class _SegmentRow extends StatelessWidget {
  final String label;
  final List<String> options;
  final int selected;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _SegmentRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            SegmentedButton<int>(
              segments: options
                  .asMap()
                  .entries
                  .map((e) =>
                      ButtonSegment(value: e.key, label: Text(e.value)))
                  .toList(),
              selected: {selected},
              onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
              style: SegmentedButton.styleFrom(
                backgroundColor: const Color(0xFF0A0E1A),
                selectedBackgroundColor: enabled
                    ? const Color(0xFF00C8FF)
                    : Colors.white24,
                selectedForegroundColor: Colors.black,
                foregroundColor: Colors.white60,
              ),
            ),
          ],
        ),
      );
}

class _ChoiceRow extends StatelessWidget {
  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onTap;

  const _ChoiceRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
              Text(value,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 15,
                  )),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right,
                  size: 18, color: Colors.white.withValues(alpha: 0.3)),
            ],
          ),
        ),
      );
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: const Color(0xFF00C8FF),
              activeTrackColor: const Color(0xFF00C8FF).withValues(alpha: 0.4),
            ),
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
            Text(value,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 15,
                )),
          ],
        ),
      );
}

/// Rich picker for encode presets — each option spells out resolution, bitrate
/// and refresh rate with a plain-language explanation, plus a legend that says
/// what each number means. The codec choice lives here too (one sheet instead
/// of two, since both are "how good/heavy is the stream" decisions).
class _PresetPickerSheet extends StatelessWidget {
  final SettingsController controller;
  const _PresetPickerSheet({required this.controller});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(16, 20, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Text('settings_encode_preset'.tr,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
          // Legend explaining the numbers.
          Text(
            'preset_picker_legend'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
          ),
          const SizedBox(height: 16),
          Obx(() => _CodecToggle(
                codec: controller.codec.value,
                onChanged: controller.setCodec,
              )),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 14),
          // Scroll the options so the sheet never overflows on small screens.
          Flexible(
            child: SingleChildScrollView(
              child: Obx(() => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final p in EncodePreset.values)
                        _PresetOption(
                          preset: p,
                          isSelected: p == controller.encodePreset.value,
                          resolutionLabel: p == EncodePreset.custom
                              ? controller.customResolutionLabel
                              : p.resolutionLabel,
                          bitrateLabel: p == EncodePreset.custom
                              ? controller.customBitrateLabel
                              : p.bitrateLabel,
                          refreshRate: p == EncodePreset.custom
                              ? controller.customRefreshRate.value
                              : p.refreshRate,
                          onTap: () {
                            controller.setEncodePreset(p);
                            Get.back();
                          },
                        ),
                    ],
                  )),
            ),
          ),
        ],
      ),
    );
  }
}

/// H.264 / H.265 segmented toggle with a short caption explaining the
/// trade-off, shown at the top of the encode-preset sheet.
class _CodecToggle extends StatelessWidget {
  final CodecType codec;
  final ValueChanged<CodecType> onChanged;
  const _CodecToggle({required this.codec, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('settings_codec'.tr,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            SegmentedButton<CodecType>(
              segments: [
                ButtonSegment(
                    value: CodecType.h264,
                    label: Text('settings_codec_h264'.tr)),
                ButtonSegment(
                    value: CodecType.h265,
                    label: Text('settings_codec_h265'.tr)),
              ],
              selected: {codec},
              onSelectionChanged: (s) => onChanged(s.first),
              style: SegmentedButton.styleFrom(
                backgroundColor: const Color(0xFF0A0E1A),
                selectedBackgroundColor: const Color(0xFF00C8FF),
                selectedForegroundColor: Colors.black,
                foregroundColor: Colors.white60,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          codec == CodecType.h265
              ? 'codec_picker_h265'.tr
              : 'codec_picker_h264'.tr,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
        ),
      ],
    );
  }
}

/// One sheet for all three custom values (resolution, bitrate, refresh) —
/// each group is a row of selectable chips; picking one applies immediately
/// (the controller's reconnect debounce collapses quick multi-field changes
/// into a single reconnect instead of one per field).
class _CustomValuesSheet extends StatelessWidget {
  final SettingsController controller;
  const _CustomValuesSheet({required this.controller});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(16, 20, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Text('settings_section_custom'.tr,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('settings_resolution'.tr,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Obx(() {
                    final res = controller.customResolutions;
                    return _ChipGroup(
                      options: res.map((r) => '${r.w}×${r.h}').toList(),
                      selected: res.indexWhere((r) =>
                          r.w == controller.customWidth.value &&
                          r.h == controller.customHeight.value),
                      onSelected: (i) =>
                          controller.setCustomResolution(res[i].w, res[i].h),
                    );
                  }),
                  _HelpText('settings_help_resolution'.tr),
                  const SizedBox(height: 12),
                  Text('settings_bitrate'.tr,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Obx(() => _ChipGroup(
                        options: controller.customBitrateOptions
                            .map((b) => '$b Mbps')
                            .toList(),
                        selected: controller.customBitrateOptions
                            .indexOf(controller.customBitrateMbps.value),
                        onSelected: (i) => controller.setCustomBitrate(
                            controller.customBitrateOptions[i]),
                      )),
                  _HelpText('settings_help_bitrate'.tr),
                  const SizedBox(height: 12),
                  Text('settings_refresh_rate'.tr,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Obx(() => _ChipGroup(
                        options: controller.customRefreshOptions
                            .map((r) => '$r Hz')
                            .toList(),
                        selected: controller.customRefreshOptions
                            .indexOf(controller.customRefreshRate.value),
                        onSelected: (i) => controller.setCustomRefreshRate(
                            controller.customRefreshOptions[i]),
                      )),
                  _HelpText('settings_help_refresh'.tr),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Row of compact selectable chips — used by the custom-values sheet so all
/// three fields can be picked without leaving it.
class _ChipGroup extends StatelessWidget {
  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelected;
  const _ChipGroup(
      {required this.options, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00C8FF);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (int i = 0; i < options.length; i++)
          Material(
            color: i == selected
                ? accent.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onSelected(i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: i == selected ? accent : Colors.white12,
                    width: i == selected ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    color: i == selected ? Colors.white : Colors.white60,
                    fontSize: 13,
                    fontWeight:
                        i == selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PresetOption extends StatelessWidget {
  final EncodePreset preset;
  final bool isSelected;
  final String resolutionLabel;
  final String bitrateLabel;
  final int refreshRate;
  final VoidCallback onTap;

  const _PresetOption({
    required this.preset,
    required this.isSelected,
    required this.resolutionLabel,
    required this.bitrateLabel,
    required this.refreshRate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00C8FF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isSelected
            ? accent.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? accent : Colors.white12,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(preset.label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text(preset.tagline,
                        style: TextStyle(
                            color: accent.withValues(alpha: 0.9),
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                    const Spacer(),
                    if (isSelected)
                      const Icon(Icons.check_circle, color: accent, size: 20),
                  ],
                ),
                const SizedBox(height: 8),
                // Spec chips.
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _SpecChip(icon: Icons.crop_free, label: resolutionLabel),
                    _SpecChip(icon: Icons.data_usage, label: bitrateLabel),
                    _SpecChip(icon: Icons.refresh, label: '$refreshRate Hz'),
                  ],
                ),
                const SizedBox(height: 10),
                Text(preset.description,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.35)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small grey explanatory caption shown under a custom setting row.
class _HelpText extends StatelessWidget {
  final String text;
  const _HelpText(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
            height: 1.4,
          ),
        ),
      );
}

class _SpecChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SpecChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white70),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PickerSheet extends StatelessWidget {
  final String title;
  final List<String> items;
  final int selected;
  final ValueChanged<int> onSelected;

  const _PickerSheet({
    required this.title,
    required this.items,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(top: 24, bottom: 8 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 16),
          // Scroll the list so long option sets never overflow the sheet.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...items.asMap().entries.map((e) => ListTile(
                        title: Text(e.value,
                            style: const TextStyle(color: Colors.white)),
                        trailing: e.key == selected
                            ? const Icon(Icons.check, color: Color(0xFF00C8FF))
                            : null,
                        onTap: () {
                          onSelected(e.key);
                          Get.back();
                        },
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final PermissionItem item;
  final VoidCallback onOpen;
  const _PermissionRow({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            item.isGranted ? Icons.check_circle : Icons.cancel,
            size: 20,
            color: item.isGranted ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
                Text(item.description,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12)),
              ],
            ),
          ),
          if (!item.isGranted)
            TextButton(
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF00C8FF),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('common_open'.tr,
                  style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
