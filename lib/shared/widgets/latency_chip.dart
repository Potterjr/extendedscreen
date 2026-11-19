import 'package:flutter/material.dart';
import 'package:get/get.dart';

class LatencyChip extends StatelessWidget {
  final int latencyMs;

  /// Which link the second chip names.
  final bool wifi;

  /// The stream's bitrate in bits/s, shown with the link when known (the
  /// host over Wi-Fi, where it follows the link).
  final int? bitrate;

  const LatencyChip(
      {super.key, required this.latencyMs, this.wifi = false, this.bitrate});

  @override
  Widget build(BuildContext context) {
    final color = latencyMs < 30
        ? const Color(0xFF00E676)
        : latencyMs < 50
            ? const Color(0xFFFFB300)
            : Colors.redAccent;

    // Only as wide as the chips: a session card sets it in a Wrap beside
    // its frame rate.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                'latency_value'.trParams({'ms': '$latencyMs'}),
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(wifi ? Icons.wifi : Icons.usb,
                  size: 14, color: Colors.white.withValues(alpha: 0.5)),
              const SizedBox(width: 4),
              Text(
                [
                  wifi ? 'Wi-Fi' : 'USB-C',
                  if (bitrate != null)
                    '${(bitrate! / 1000000).toStringAsFixed(bitrate! < 10000000 ? 1 : 0)} Mbps',
                ].join(' · '),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
