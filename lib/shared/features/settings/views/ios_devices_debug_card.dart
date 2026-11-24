import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/platform/ios_device_service.dart';

/// Settings → Wi-Fi → "iPhones (debug)": the P0 spike's way to pair an
/// iPhone (docs/ios-client-design.md, *phases → P0*). The iOS devices
/// devicectl lists, each with a Pair button while it is cabled, trusts this
/// Mac and has Developer Mode on, then the booted iOS simulators (labelled
/// "Simulator", Pair while booted), and what the last Pair answered.
///
/// Settings builds it only under `kDebugMode`, so no profile or release
/// build shows it or calls [IosDeviceService]. P2 replaces it with the
/// real iPhones list.
class IosDevicesDebugCard extends StatefulWidget {
  const IosDevicesDebugCard({super.key, this.service});

  /// Defaults to the registered one; tests pass theirs.
  final IosDeviceService? service;

  @override
  State<IosDevicesDebugCard> createState() => _IosDevicesDebugCardState();
}

class _IosDevicesDebugCardState extends State<IosDevicesDebugCard> {
  IosDeviceService? get _service =>
      widget.service ??
      (Get.isRegistered<IosDeviceService>()
          ? Get.find<IosDeviceService>()
          : null);

  List<IosDevice>? _devices;
  bool _listing = false;
  bool _listFailed = false;
  String? _pairing;
  final _answers = <String, IosDelivery>{};
  final _details = <String, String?>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final service = _service;
    if (service == null || _listing) return;
    setState(() => _listing = true);
    final devices = await service.list();
    if (!mounted) return;
    setState(() {
      _listing = false;
      _listFailed = devices == null;
      _devices = devices;
    });
  }

  Future<void> _pair(IosDevice device) async {
    final service = _service;
    if (service == null || _pairing != null) return;
    setState(() => _pairing = device.udid);
    final answer = await service.deliverPairing(
      device.udid,
      simulator: device.isSimulator,
    );
    if (!mounted) return;
    setState(() {
      _pairing = null;
      _answers[device.udid] = answer;
      _details[device.udid] = service.lastDetail.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dim = Colors.white.withValues(alpha: 0.45);
    final devices = _devices ?? const <IosDevice>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'settings_ios_debug_title'.tr,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'settings_ios_debug_desc'.tr,
                      style: TextStyle(color: dim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('ios-debug/refresh'),
                tooltip: 'common_refresh'.tr,
                onPressed: _listing ? null : _refresh,
                icon: _listing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.refresh, size: 20, color: dim),
              ),
            ],
          ),
          if (_listFailed)
            _line(
              'settings_ios_debug_unavailable'.tr,
              _service?.lastDetail.value,
              dim,
            )
          else if (_devices != null && devices.isEmpty)
            _line('settings_ios_debug_none'.tr, null, dim),
          for (final d in devices) _row(d, dim),
        ],
      ),
    );
  }

  Widget _line(String text, String? detail, Color dim) => Padding(
    padding: const EdgeInsets.only(top: 8, right: 8),
    child: Text(
      detail == null || detail.isEmpty ? text : '$text — $detail',
      style: TextStyle(color: dim, fontSize: 12),
    ),
  );

  /// "name · model" for a device; "name · Simulator iOS 26.5" for a
  /// simulator, whose name usually says its model already.
  static String _title(IosDevice d) {
    if (d.isSimulator) {
      final sim = 'settings_ios_simulator'.tr;
      return '${d.name} · ${d.runtime == null ? sim : '$sim ${d.runtime}'}';
    }
    return d.name == d.model ? d.model : '${d.name} · ${d.model}';
  }

  Widget _row(IosDevice d, Color dim) {
    final busy = _pairing == d.udid;
    final answer = _answers[d.udid];
    final blocker = d.blocker;
    final status = busy
        ? 'settings_ios_pairing'.tr
        : answer != null
        ? 'ios_delivery_${answer.name}'.tr
        : blocker != null
        ? 'ios_delivery_${blocker.name}'.tr
        : 'settings_ios_ready'.tr;
    final detail = busy ? null : _details[d.udid];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title(d),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                Text(
                  detail == null || detail.isEmpty
                      ? status
                      : '$status — $detail',
                  style: TextStyle(color: dim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey('ios-debug/pair/${d.udid}'),
            onPressed: d.offerable && _pairing == null ? () => _pair(d) : null,
            child: Text('settings_ios_pair'.tr),
          ),
        ],
      ),
    );
  }
}
