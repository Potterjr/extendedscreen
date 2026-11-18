import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/socket_service.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/logger_service.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

/// A connect failure whose text is a translation key, so Home's error banner
/// shows it in the UI language instead of a raw exception string.
class LinkError implements Exception {
  final String key;
  const LinkError(this.key);

  @override
  String toString() => key.tr;
}

/// Shared connection orchestration for both roles. The concrete role lives in
/// [HostConnectionManager] (macOS — captures + streams) and
/// [ClientConnectionManager] (Android — decodes + renders), which are bound to
/// this type in `InitialBinding` so shared UI can depend on a single interface.
///
/// This base owns the bits that are identical on both sides: the connection
/// phase + latency observables, the packet loop with heartbeat handling, the
/// reconnect timer, and the input-send helpers. Role-specific behaviour is
/// exposed through the abstract [connect]/[autoConnect] hooks and the
/// overridable [onRolePacket]/[onTeardown]/[onLinkLost] callbacks.
abstract class BaseConnectionManager extends GetxService
    with WidgetsBindingObserver {
  /// [socket] and [port] default to the registered [SocketService] and
  /// [BaseConnectionManager.port]; tests pass their own to run a host and a
  /// client side by side on a free port.
  BaseConnectionManager({SocketService? socket, int? port})
      : socket = socket ?? Get.find<SocketService>(),
        linkPort = port ?? BaseConnectionManager.port;

  @protected
  final SocketService socket;

  /// The TCP port this manager listens on or dials.
  @protected
  final int linkPort;
  @protected
  final log = Get.find<LoggerService>();
  @protected
  final settings = Get.find<SettingsService>();

  /// USB link: both ends use this address, joined by `adb reverse`. Over
  /// Wi-Fi the host listens on every interface and the client dials the Mac's
  /// LAN address, on the same [port].
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

  /// Host only, Wi-Fi sessions only: the bitrate (bits/s) the encoder runs at
  /// right now, as fitted to the link (BitrateAdapter). Null otherwise.
  final streamBitrate = RxnInt();

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

  /// Packet stream for consumers (DisplayController reads FRAME_DATA here).
  /// Like everything else, it carries nothing from a peer that has not
  /// proved who it is ([peerTrusted]).
  Stream<Packet> get packetStream =>
      socket.packetStream.where((_) => peerTrusted);

  /// Whether the peer on the current connection has proved who it is: over
  /// Wi-Fi by certificate and pairing token, over USB by the session key adb
  /// delivered (`UsbSessionService`). Nothing is sent to a peer that has not,
  /// and nothing it sends is acted on. Both roles override this; it belongs
  /// to the connection ([SocketService.connectionId]), not to the session.
  @protected
  bool get peerTrusted => false;

  @protected
  StreamSubscription? packetSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _lastPingTs = 0; // timestamp of the most-recently sent ping
  DateTime _lastReceived = DateTime.now(); // any packet from the peer

  // True from a link failure until its retry fires (or a manual connect() in
  // the meantime starts one early, see [beginConnect]) — guards against
  // handling the same loss twice (a socket error is often followed by a close).
  bool _recovering = false;

  // Bumped by disconnect() and by handleLinkFailure(): either one ends the
  // session a connect() in flight was building. That attempt (typically
  // parked in "waiting for tablet", or on a timeout) checks it after each
  // await and bails out quietly, so Cancel can't be undone by the attempt
  // resuming afterwards, and an attempt whose link already failed can't wake
  // up later and fail a second time, tearing down the retry that replaced it.
  int _attempt = 0;
  @protected
  int get currentAttempt => _attempt;
  @protected
  bool isCancelled(int attempt) => attempt != _attempt;

  // Incremented per connect(), so a cancelled attempt that wakes up late can
  // tell whether a newer one has since taken over the shared socket/capture
  // (then it must leave them alone rather than "clean up" the new session).
  int _connectSeq = 0;

  /// Called by each connect() right after its phase guard, so only from
  /// `disconnected` or `error`. In `error`, [handleLinkFailure] has finished
  /// and armed its retry; a connect() now (the user tapping Connect on the
  /// tablet, or picking a device on the Mac) is that retry, run early. So drop
  /// the pending timer, and clear [_recovering] so this attempt's own failure
  /// is handled and arms the next retry. Otherwise the guard swallowed it,
  /// leaving the phase stuck at the attempt's connecting step with no retry.
  /// For the retry timer's own connect() both are no-ops.
  @protected
  int beginConnect() {
    _reconnectTimer?.cancel();
    _recovering = false;
    // A round trip measured on the previous link (USB, say) is not this
    // one's: the host's bitrate adaptation reads it as the network's own.
    latencyMs.value = 0;
    return ++_connectSeq;
  }
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
        // Host: reconnect only to an already-chosen device. Picking one
        // (connectIfUnambiguous) is for the launch and for Home, which also
        // runs it on resume once the permissions are checked.
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

  /// Host: connects without a tap when there is nothing to choose: over
  /// Wi-Fi (connecting only means starting to listen for the paired tablet),
  /// or over USB with exactly one physical device (emulators are ignored
  /// whenever a real device is present, and count only when they are all
  /// there is). Anything more ambiguous is left to the picker. Deliberately
  /// not keyed off the saved last-used serial: that's persisted on every
  /// connect *attempt*, so a reconnect-timer fallback can leave it pointing at
  /// the wrong device, and a wrong pick strands the host mid-handshake with
  /// no picker visible. Only when idle (`disconnected`), and not when a
  /// [disconnect] (the user's Cancel or Disconnect), a link failure or a
  /// restart came after [since] (a [currentAttempt] the caller took before
  /// its own awaits; by default, now). The caller checks the macOS
  /// permissions first. Nothing on the client, which always dials.
  Future<void> connectIfUnambiguous({int? since}) async {
    final attempt = since ?? _attempt;
    if (!isHost ||
        isCancelled(attempt) ||
        phase.value != ConnectionPhase.disconnected) {
      return;
    }
    if (settings.linkType == LinkType.wifi) {
      await connect();
      return;
    }
    await refreshDevices();
    // Something else may have started a connection meanwhile, or the user
    // may have stopped one.
    if (isCancelled(attempt) ||
        phase.value != ConnectionPhase.disconnected) {
      return;
    }
    final devices = availableDevices.toList();
    final physical =
        devices.where((d) => !d.serial.startsWith('emulator-')).toList();
    final candidates = physical.isNotEmpty ? physical : devices;
    if (candidates.length == 1) await connect(serial: candidates.first.serial);
  }

  /// Host → client: push the overlay/HUD toggle states (which render on the
  /// client but are edited on the host) so they stay in sync. No-op on client.
  void sendUiFlags() {}

  /// Host: discard this Mac's Wi-Fi identity, so every tablet has to pair
  /// again over USB. No-op on the client, which has no identity (it forgets
  /// a Mac with `WifiPairingService.forget`).
  Future<void> resetWifiIdentity() async {}

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
    _stopping++;
    try {
      _heartbeatTimer?.cancel();
      _reconnectTimer?.cancel();
      _recovering = false;
      packetSub?.cancel();
      await onTeardown();
      await socket.disconnect();
      activeDevice.value = null;
      setPhase(ConnectionPhase.disconnected);
    } finally {
      _stopping--;
    }
  }

  // disconnect() calls still tearing down. The phase only says `disconnected`
  // once they are done, so until then this is how [restartLink] knows the
  // link is being stopped, not lost.
  int _stopping = 0;

  /// Role-specific cleanup run during [disconnect] (host stops capture and
  /// removes the adb-reverse tunnel; client stops its keep-alive service and
  /// any reverse-remote screen capture). The host also runs it on link loss
  /// and when abandoning a cancelled connect attempt.
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
    // The session is over for any connect() still awaiting something in it.
    final failure = ++_attempt;
    _heartbeatTimer?.cancel();
    await packetSub?.cancel();
    packetSub = null;
    await onLinkLost();
    await socket.disconnect();
    // The awaits above can take a while (the host's teardown waits for a
    // capture start still in flight). A disconnect() in that time means the
    // user cancelled: it has already done everything this would, and must
    // not be followed by a retry that reconnects, or over Wi-Fi reopens the
    // listener, a second later.
    if (_attempt != failure) return;
    setPhase(ConnectionPhase.error);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      _recovering = false;
      connect();
    });
  }

  /// Role hook run by [handleLinkFailure] before the retry. Unlike
  /// [disconnect] it must leave [activeDevice] set so the retry targets it.
  @protected
  Future<void> onLinkLost() async {}

  /// Ends the link, or the attempt in flight, the way a lost link does, and
  /// connects again at once instead of after [reconnectDelay]. For when a
  /// role learns that a new attempt will get somewhere the current one
  /// cannot (the client: adb just delivered the key of a new USB session).
  @protected
  Future<void> restartLink() async {
    // A disconnect() is tearing down (the user pressed Disconnect, or a
    // redial is replacing the link): starting a link now would outlive it.
    // A restart already under way when it began is cancelled by its bump.
    if (_stopping > 0) return;
    final restart = ++_attempt;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _recovering = false;
    await packetSub?.cancel();
    packetSub = null;
    await onLinkLost();
    await socket.disconnect();
    // A disconnect() (the user cancelled), a lost link or another restart
    // came in during the awaits: what happens next is theirs to decide.
    if (_attempt != restart) return;
    // connect() only starts from `error` or `disconnected`, and sets its own
    // phase before anything can be drawn.
    setPhase(ConnectionPhase.error);
    await connect();
  }

  // ─── Input send helpers (shared) ──────────────────────────────────────────

  void sendTouch(TouchEventModel event) {
    if (!phase.value.isActive || !peerTrusted) return;
    socket.send(PacketCodec.wrapTouch(event));
  }

  void sendMouse(MouseEventModel event) {
    if (!phase.value.isActive || !peerTrusted) return;
    socket.send(PacketCodec.wrapMouse(event));
  }

  void sendKey(KeyEventModel event) {
    if (!phase.value.isActive || !peerTrusted) return;
    socket.send(PacketCodec.wrapKey(event));
  }

  /// Decoder side → encoder side: ask for a fresh keyframe so the decoder can
  /// start cleanly. Client → host normally; in reverse remote the host wires
  /// it as its decoder's IDR callback (host → client).
  void requestIdr() {
    if (!phase.value.isActive || !peerTrusted) return;
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
    if (!admitPacket(packet)) return;
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

  /// Whether [packet] may be looked at at all. Runs before anything else,
  /// heartbeats included. Both roles return false for everything a peer
  /// sends before it is [peerTrusted], after picking out the one packet that
  /// can make it so (the host: a Wi-Fi client's pairing token or a USB
  /// client's hello; the client: the Mac's answer to its USB hello).
  @protected
  bool admitPacket(Packet packet) => peerTrusted;

  /// Role-specific packet handling (host injects input / records the client's
  /// HELLO panel info; client reacts to the host's control packets, e.g.
  /// session mode, codec, refresh rate). FRAME_DATA on the client is consumed
  /// by DisplayController via [packetStream].
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
      // The socket can already belong to someone else (a server accepts the
      // next client as soon as one drops, before teardown has run).
      if (!peerTrusted) return;
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
