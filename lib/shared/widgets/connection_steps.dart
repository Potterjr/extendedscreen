import 'package:flutter/material.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

enum _StepState { done, active, pending, error }

/// Client-side progress checklist showing how far the connection has advanced
/// toward being ready to display: connect → configure → ready.
class ConnectionSteps extends StatelessWidget {
  final ConnectionPhase phase;
  const ConnectionSteps({super.key, required this.phase});

  static const _steps = [
    (label: 'Connect to Mac host', detail: 'Linking over the USB-C tunnel'),
    (label: 'Configure display', detail: 'Negotiating codec & resolution'),
    (label: 'Ready to display', detail: 'Stream is live — tap Open View'),
  ];

  /// How many steps are fully completed for the current phase.
  int get _completed {
    switch (phase) {
      case ConnectionPhase.streaming:
      case ConnectionPhase.paused:
        return 3;
      case ConnectionPhase.configuring:
        return 1;
      default:
        return 0; // handshaking / connecting / disconnected / error
    }
  }

  _StepState _stateFor(int i, int completed) {
    if (i < completed) return _StepState.done;
    if (i > completed) return _StepState.pending;
    // i == completed: the step currently in progress.
    if (phase == ConnectionPhase.error) return _StepState.error;
    if (phase.isConnecting || completed > 0) return _StepState.active;
    return _StepState.pending; // disconnected, waiting to start
  }

  @override
  Widget build(BuildContext context) {
    final completed = _completed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _steps.length; i++)
            _StepRow(
              label: _steps[i].label,
              detail: _steps[i].detail,
              state: _stateFor(i, completed),
              isLast: i == _steps.length - 1,
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String label;
  final String detail;
  final _StepState state;
  final bool isLast;

  const _StepRow({
    required this.label,
    required this.detail,
    required this.state,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00C8FF);
    final color = switch (state) {
      _StepState.done => const Color(0xFF00E676),
      _StepState.active => accent,
      _StepState.error => Colors.redAccent,
      _StepState.pending => Colors.white24,
    };

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left rail: indicator + connector line.
          Column(
            children: [
              _Indicator(state: state, color: color),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: state == _StepState.done
                        ? const Color(0xFF00E676).withValues(alpha: 0.5)
                        : Colors.white12,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Padding(
            padding: EdgeInsets.only(top: 2, bottom: isLast ? 8 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: state == _StepState.pending
                        ? Colors.white38
                        : Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  final _StepState state;
  final Color color;
  const _Indicator({required this.state, required this.color});

  @override
  Widget build(BuildContext context) {
    const size = 24.0;
    if (state == _StepState.active) {
      return const SizedBox(
        width: size,
        height: size,
        child: Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF00C8FF)),
        ),
      );
    }
    final icon = switch (state) {
      _StepState.done => Icons.check_circle,
      _StepState.error => Icons.error,
      _ => Icons.circle_outlined,
    };
    return Icon(icon, color: color, size: size);
  }
}
