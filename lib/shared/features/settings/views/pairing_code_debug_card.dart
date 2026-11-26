import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/protocol/pairing_code.dart';

/// Settings → Wi-Fi on the Mac, debug builds only: copy this Mac's pairing
/// as a [PairingCode], to paste into a client that has neither adb nor
/// devicectl (the Windows client). The code holds the Mac's token, so it is
/// never shown on screen, only put on the clipboard, and Settings builds the
/// card only under `kDebugMode`. Roadmap §5.2's exchange replaces it.
class PairingCodeDebugCard extends StatefulWidget {
  const PairingCodeDebugCard({super.key, this.pairing, this.copy});

  /// Defaults to the registered one; tests pass theirs.
  final WifiPairingService? pairing;

  /// Where the code goes; the clipboard by default (tests pass theirs).
  final Future<void> Function(String code)? copy;

  @override
  State<PairingCodeDebugCard> createState() => _PairingCodeDebugCardState();
}

class _PairingCodeDebugCardState extends State<PairingCodeDebugCard> {
  bool _busy = false;
  bool? _copied;

  WifiPairingService? get _pairing =>
      widget.pairing ??
      (Get.isRegistered<WifiPairingService>()
          ? Get.find<WifiPairingService>()
          : null);

  Future<void> _copy() async {
    final pairing = _pairing;
    if (pairing == null || _busy) return;
    setState(() => _busy = true);
    var copied = false;
    try {
      final code = PairingCode.encode(await pairing.offerPayload());
      await (widget.copy ??
          (c) => Clipboard.setData(ClipboardData(text: c)))(code);
      copied = true;
    } catch (_) {
      // No identity could be made (openssl missing): nothing to hand over.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _copied = copied;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dim = Colors.white.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'settings_pairing_code_title'.tr,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  switch (_copied) {
                    true => 'settings_pairing_code_copied'.tr,
                    false => 'settings_pairing_code_failed'.tr,
                    null => 'settings_pairing_code_desc'.tr,
                  },
                  style: TextStyle(color: dim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: const ValueKey('pairing-code/copy'),
            onPressed: _busy ? null : _copy,
            child: Text('settings_pairing_code_copy'.tr),
          ),
        ],
      ),
    );
  }
}
