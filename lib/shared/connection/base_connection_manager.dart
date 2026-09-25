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
  // Nothing received for this long (3 missed heartbeats) means the link is
  // dead even if the socket still looks open — e.g. the tablet dialled while
  // the host app wasn't listening yet: adb's reverse tunnel accepted the
  // connection on the tablet but never delivered it, and without this check
  // both sides waited forever.
  static const _linkTimeout = Duration(seconds: 6);

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

  /// Reverse remote (Mac controls tablet), client only: the host has asked this
  /// tablet to share its screen and we're waiting for the user to start it (the
  /// MediaProjection consent must be triggered from the foreground). Drives the
  /// "Start screen sharing" button on the client home screen.
  final needsScreenShare = false.obs;

  /// Reverse remote, client only: the tablet is actively capturing + streaming.
  final isScreenSharing = false.obs;

  /// Client only: begin screen sharing (shows the consent prompt, then captures
  /// + streams). No-op on the host and in non-reverse modes.
  Future<void> startScreenShare() async {}

  /// Raw packet stream for consumers (DisplayController reads FRAME_DATA here).
  Stream<Packet> get packetStream => socket.packetStream;

  @protected
  StreamSubscription? packetSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _lastPingTs = 0; // timestamp of the most-recently sent ping
  DateTime _lastReceived = DateTime.now(); // any packet from the peer

  // True from a link failure until its retry fires — guards against handling
  // the same loss twice (a socket error is often followed by a close).
  bool _recovering = false;

  // Bumped by disconnect(). A connect() already in flight (typically parked
  // in "waiting for tablet") checks it after each await and bails out quietly,
  // so Cancel can't be undone by the attempt resuming afterwards.
  int _attempt = 0;
  @protected
  int get currentAttempt => _attempt;
  @protected
  bool isCancelled(int attempt) => attempt != _attempt;

  // Incremented per connect(), so a cancelled attempt that wakes up late can
  // tell whether a newer one has since taken over the shared socket/capture
  // (then it must leave them alone rather than "clean up" the new session).
  int _connectSeq = 0;
  @protected
  int beginConnect() => ++_connectSeq;
  @protected
  bool isLatestConnect(int seq) => seq == _connectSeq;

  /// Delay before retrying after a link failure. The client dials a host that
  /// may not be up yet; the host (a server) overrides this to retry sooner.
  @protected
  Duration get reconnectDelay => const Duration(seconds: 5);

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
    // Skipped while a link-failure retry is pending — it already covers this.
    if (state == AppLifecycleState.detached) {
      disconnect();
    } else if (state == AppLifecycleState.resumed &&
        !phase.value.isActive &&
        !_recovering) {
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
    _attempt++;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _recovering = false;
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

  /// Every failure path (socket error/close, or a connect attempt throwing)
  /// ends here. Stops this link's packet listener + heartbeat and closes the
  /// socket *before* retrying — retries used to run connect() on top of the
  /// half-alive session, stacking duplicate listeners/timers and (on the host)
  /// a second server socket while the tablet was already connected to the
  /// first, so setup packets like the refresh rate were never re-sent.
  @protected
  Future<void> handleLinkFailure() async {
    if (_recovering) return;
    _recovering = true;
    _heartbeatTimer?.cancel();
    await packetSub?.cancel();
    packetSub = null;
    await onLinkLost();
    await socket.disconnect();
    setPhase(ConnectionPhase.error);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      _recovering = false;
      connect();
    });
  }

  /// Role hook run by [handleLinkFailure] before the retry. Unlike
  /// [onTeardown] it must leave [activeDevice] set so the retry targets it.
  @protected
  Future<void> onLinkLost() async {}

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
    packetSub?.cancel();
    packetSub = socket.packetStream.listen(
      _handlePacket,
      onError: (e) {
        log.e('Packet stream error', e);
        handleLinkFailure();
      },
    );
  }

  void _handlePacket(Packet packet) {
    _lastReceived = DateTime.now();
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
    _heartbeatTimer?.cancel();
    _lastReceived = DateTime.now();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (DateTime.now().difference(_lastReceived) > _linkTimeout) {
        log.w('Nothing received for ${_linkTimeout.inSeconds}s — link is dead');
        handleLinkFailure();
        return;
      }
      final hb = PacketCodec.heartbeat();
      _lastPingTs = PacketCodec.heartbeatOriginTs(hb.payload);
      socket.send(hb);
    });
  }

  @protected
  void setPhase(ConnectionPhase p) {
    log.d('Connection phase → ${p.name}');
    phase.value = p;
  }
}
