import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// Shared connection orchestration for both roles. The concrete role lives in
/// [HostConnectionManager] (macOS — captures + streams) and
/// [ClientConnectionManager] (Android — decodes + renders), which are bound to
/// this type in `InitialBinding` so shared UI can depend on a single interface.
///
/// This base owns the bits that are identical on both sides: the connection
/// phase + latency observables, the packet loop with heartbeat handling, the
/// reconnect timer, and the input-send helpers. Role-specific behaviour is
/// exposed through the abstract [connect]/[autoConnect]/[changeMode] hooks and
/// the overridable [onRolePacket]/[onTeardown] callbacks.
abstract class BaseConnectionManager extends GetxService
    with WidgetsBindingObserver {
  @protected
  final socket = Get.find<SocketService>();
  @protected
  final log = Get.find<LoggerService>();
  @protected
  final settings = Get.find<SettingsService>();

  static const host = '127.0.0.1';
  static const port = 7001;
  static const heartbeatInterval = Duration(seconds: 2);

  /// True on the macOS host, false on the Android client.
  bool get isHost;

  final phase = ConnectionPhase.disconnected.obs;
  final errorMessage = ''.obs;
  final activeDevice = Rxn<DeviceModel>();
  final latencyMs = 0.obs;

  /// Refresh rate (Hz) of the stream the host is capturing. The host sets this
  /// to its own value; the client receives it via a `0xFB` control packet so
  /// its HUD reflects the host's actual rate (settings live only on the host).
  final refreshRateHz = 60.obs;

  /// Host only: ADB devices currently detected, for the picker UI. Always empty
  /// on the client.
  final availableDevices = <DeviceModel>[].obs;

  /// Raw packet stream for consumers (DisplayController reads FRAME_DATA here).
  Stream<Packet> get packetStream => socket.packetStream;

  @protected
  StreamSubscription? packetSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _lastPingTs = 0; // timestamp of the most-recently sent ping

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only disconnect on full process detach; hidden/paused keeps streaming.
    if (state == AppLifecycleState.detached) {
      disconnect();
    } else if (state == AppLifecycleState.resumed && !phase.value.isActive) {
      if (isHost) {
        // Host: reconnect only to an already-chosen device (never auto-grab a
        // device on a fresh launch).
        if (activeDevice.value != null) {
          connect(serial: activeDevice.value!.serial);
        }
      } else {
        // Client: always try to reconnect on resume (it dials the host and
        // retries until the server is up).
        connect();
      }
    }
  }

  // ─── Role entry-points (implemented by subclasses) ────────────────────────

  /// [serial] (host only) overrides which Android client to connect to;
  /// when null the last-used device (or the first detected) is chosen.
  Future<void> connect({String? serial});

  /// Entry-point auto-connect (called from splash).
  Future<void> autoConnect();

  /// Host populates the detected device list; no-op on the client.
  Future<void> refreshDevices() async {}

  /// Host → client: push the overlay/HUD toggle states (which render on the
  /// client but are edited on the host) so they stay in sync. No-op on client.
  void sendUiFlags() {}

  // ─── Shared lifecycle ─────────────────────────────────────────────────────

  /// Tear down the current link and reconnect to the same device. Used to apply
  /// performance/encoder changes (e.g. encode preset / codec) cleanly — the
  /// whole capture + handshake pipeline restarts with the new settings.
  Future<void> reconnect() async {
    if (!phase.value.isActive && activeDevice.value == null) return;
    final serial = activeDevice.value?.serial; // captured before disconnect clears it
    await disconnect();
    await connect(serial: isHost ? serial : null);
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    packetSub?.cancel();
    await onTeardown();
    await socket.disconnect();
    activeDevice.value = null;
    setPhase(ConnectionPhase.disconnected);
  }

  /// Role-specific cleanup run during [disconnect] (host stops capture and
  /// removes the adb-reverse tunnel; client releases nothing extra here).
  @protected
  Future<void> onTeardown() async {}

  // ─── Input send helpers (shared) ──────────────────────────────────────────

  void sendTouch(TouchEventModel event) {
    if (!phase.value.isActive) return;
    socket.send(PacketCodec.wrapTouch(event));
  }

  void sendMouse(MouseEventModel event) {
    if (!phase.value.isActive) return;
    socket.send(PacketCodec.wrapMouse(event));
  }

  void sendKey(KeyEventModel event) {
    if (!phase.value.isActive) return;
    socket.send(PacketCodec.wrapKey(event));
  }

  /// Client → host: ask for a fresh keyframe so the decoder can start cleanly.
  void requestIdr() {
    if (!phase.value.isActive) return;
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFF]),
    ));
  }

  // ─── Packet loop (shared heartbeat, role-specific delegate) ───────────────

  @protected
  void startPacketLoop() {
    packetSub = socket.packetStream.listen(
      _handlePacket,
      onError: (e) {
        log.e('Packet stream error', e);
        setPhase(ConnectionPhase.error);
        scheduleReconnect();
      },
    );
  }

  void _handlePacket(Packet packet) {
    if (packet.type == PacketType.heartbeat) {
      if (PacketCodec.heartbeatIsPong(packet.payload)) {
        // Only accept the pong that echoes OUR own last ping timestamp.
        // Ignores pongs that echo the peer's own pings (different clock).
        final originTs = PacketCodec.heartbeatOriginTs(packet.payload);
        if (originTs == _lastPingTs && originTs > 0) {
          final rttUs = DateTime.now().microsecondsSinceEpoch - originTs;
          latencyMs.value = (rttUs / 1000).round();
        }
      } else {
        // Incoming ping from peer — echo it back immediately.
        final pong = PacketCodec.heartbeatPong(packet.payload);
        if (pong != null) socket.send(pong);
      }
      return;
    }
    onRolePacket(packet);
  }

  /// Role-specific packet handling (host injects input / adopts config; client
  /// reacts to codec + reload control packets). FRAME_DATA on the client is
  /// consumed by DisplayController via [packetStream].
  @protected
  void onRolePacket(Packet packet) {}

  @protected
  void startHeartbeat() {
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      final hb = PacketCodec.heartbeat();
      _lastPingTs = PacketCodec.heartbeatOriginTs(hb.payload);
      socket.send(hb);
    });
  }

  @protected
  void scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () => connect());
  }

  @protected
  void setPhase(ConnectionPhase p) {
    log.d('Connection phase → ${p.name}');
    phase.value = p;
  }
}
