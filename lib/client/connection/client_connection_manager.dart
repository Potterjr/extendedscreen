import 'dart:typed_data';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';

/// CLIENT role (Android): dials into the adb-reverse tunnel, sends its desired
/// config in the HELLO, then decodes + renders frames (in DisplayController)
/// and forwards touch/keyboard input back to the host. The Android side is the
/// control surface, so settings changes here drive the host via [reconnect].
class ClientConnectionManager extends BaseConnectionManager {
  @override
  bool get isHost => false;

  /// The client always dials in (and retries until the host server is up).
  @override
  Future<void> autoConnect() async {
    await connect();
  }

  @override
  Future<void> connect({String? serial}) async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    try {
      setPhase(ConnectionPhase.handshaking);
      // Connects through the adb-reverse tunnel set up by the host.
      await socket.connect(BaseConnectionManager.host, BaseConnectionManager.port);

      setPhase(ConnectionPhase.configuring);
      _sendHandshake();

      startPacketLoop();

      setPhase(ConnectionPhase.streaming);
      startHeartbeat();
      log.i('Client: connected to host, streaming');
    } catch (e) {
      // Expected to fail until the host is up; retry quietly.
      log.w('Client connect failed (${e.runtimeType}); retrying…');
      errorMessage.value = 'Waiting for Mac host…';
      setPhase(ConnectionPhase.error);
      scheduleReconnect();
    }
  }

  void _sendHandshake() {
    // HELLO: version byte + platform byte (0x02 = Android client). The host
    // owns all config now, so the client no longer sends settings.
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0x01, 0x02]),
    ));
  }

  @override
  void onRolePacket(Packet packet) {
    if (packet.type != PacketType.control || packet.payload.isEmpty) return;
    final p = packet.payload;

    // 0xFE — Host → Tablet: capture restarted, request IDR to resume decode.
    if (p[0] == 0xFE) {
      requestIdr();
      return;
    }

    // 0xFC + codec_byte — Host → Tablet: codec changed, reinitialize decoder.
    if (p.length >= 2 && p[0] == 0xFC) {
      settings.setCodec(p[1] == 1 ? CodecType.h265 : CodecType.h264);
      return;
    }

    // 0xFB + refreshRate — Host → Tablet: capture refresh rate (Hz) for the HUD.
    if (p.length >= 2 && p[0] == 0xFB) {
      refreshRateHz.value = p[1];
      return;
    }

    // 0xFA + perfOverlay + showHud — Host → Tablet: sync overlay toggles which
    // render on the client but are edited on the host.
    if (p.length >= 3 && p[0] == 0xFA) {
      settings.setShowPerformanceOverlay(p[1] == 1);
      settings.setShowHudOverlay(p[2] == 1);
    }
  }
}
