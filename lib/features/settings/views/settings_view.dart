import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/settings_controller.dart';
import '../../../core/models/display_config_model.dart';

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionHeader('Display'),
          _SettingsCard(children: [
            Obx(() => _SegmentRow(
                  label: 'Mode',
                  options: const ['Extend', 'Mirror'],
                  selected: controller.mode.value == DisplayMode.extend ? 0 : 1,
                  enabled: !controller.isApplying.value,
                  onChanged: (i) => controller
                      .setMode(i == 0 ? DisplayMode.extend : DisplayMode.mirror),
                )),
            Obx(() => controller.isApplying.value
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00C8FF),
                          ),
                        ),
                        SizedBox(width: 10),
                        Text('Applying…',
                            style: TextStyle(
                                color: Color(0xFF00C8FF), fontSize: 13)),
                      ],
                    ),
                  )
                : const SizedBox.shrink()),
          ]),
          if (GetPlatform.isAndroid) ...[
            const SizedBox(height: 16),
            _SectionHeader('Performance'),
            _SettingsCard(children: [
              Obx(() => _ChoiceRow(
                    label: 'Encode Preset',
                    value: controller.encodePreset.value.label,
                    enabled: !controller.isApplying.value,
                    onTap: () => _showPresetPicker(context),
                  )),
              const Divider(height: 1, color: Colors.white12),
              Obx(() => _ChoiceRow(
                    label: 'Frame Rate',
                    value: '${controller.fps.value} fps',
                    enabled: !controller.isApplying.value,
                    onTap: () => _showFpsPicker(context),
                  )),
              const Divider(height: 1, color: Colors.white12),
              Obx(() => _ToggleRow(
                    label: 'Performance Overlay',
                    value: controller.showPerformanceOverlay.value,
                    onChanged: (_) => controller.togglePerformanceOverlay(),
                  )),
              const Divider(height: 1, color: Colors.white12),
              Obx(() => _ToggleRow(
                    label: 'Show HUD (fps / latency / disconnect)',
                    value: controller.showHudOverlay.value,
                    onChanged: (_) => controller.toggleHudOverlay(),
                  )),
            ]),
          ],
          const SizedBox(height: 16),
          _SectionHeader('Permissions'),
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
                  child: const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh,
                            size: 14, color: Color(0xFF00C8FF)),
                        SizedBox(width: 6),
                        Text('Refresh',
                            style: TextStyle(
                                color: Color(0xFF00C8FF), fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 16),
          _SectionHeader('Connection'),
          _SettingsCard(children: [
            _InfoRow(label: 'Transport', value: 'USB-C / ADB'),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'Codec', value: 'H.264 Hardware'),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'Port', value: '7001'),
          ]),
          const SizedBox(height: 16),
          _SectionHeader('About'),
          _SettingsCard(children: [
            _InfoRow(label: 'Version', value: '1.0.0'),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'Target Device', value: 'Samsung Tab S10 Ultra'),
            const Divider(height: 1, color: Colors.white12),
            _InfoRow(label: 'Host', value: 'macOS 13+'),
          ]),
        ],
      ),
    );
  }

  void _showPresetPicker(BuildContext context) {
    final presets = EncodePreset.values;
    Get.bottomSheet(
      _PickerSheet(
        title: 'Encode Preset',
        items: presets.map((p) => '${p.label}  —  ${p.description}').toList(),
        selected: presets.indexOf(controller.encodePreset.value),
        onSelected: (i) => controller.setEncodePreset(presets[i]),
      ),
    );
  }

  void _showFpsPicker(BuildContext context) {
    Get.bottomSheet(
      _PickerSheet(
        title: 'Frame Rate',
        items: controller.fpsOptions.map((f) => '$f fps').toList(),
        selected: controller.fpsOptions.indexOf(controller.fps.value),
        onSelected: (i) => controller.setFps(controller.fpsOptions[i]),
      ),
    );
  }


}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

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
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24),
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
          const SizedBox(height: 8),
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
              child: const Text('Open', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
