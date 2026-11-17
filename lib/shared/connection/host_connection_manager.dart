import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/platform/host_name.dart';
import 'package:extendedscreen/shared/platform/permissions_channel.dart';
import 'package:extendedscreen/shared/protocol/annexb.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/bitrate_adapter.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';

/// HOST role (macOS): runs `adb reverse`, a TCP server, captures + encodes the
/// screen via ScreenCaptureKit/VideoToolbox, and injects the touch/mouse/key
/// events received from the tablet. Stream settings are edited only on the
/// host; the client's HELLO reports its native panel size and top refresh
/// rate, which the host waits for (3 s timeout) before sizing and starting
/// capture.
///
/// Over Wi-Fi ([LinkType.wifi]) there is no adb: the server listens on the
/// LAN with TLS, answers discovery probes, and treats the client as a
/// stranger until it presents the pairing token (see [WifiPairingService]).
///
/// Over USB the client is a stranger too, until it proves it holds the key
/// this attempt handed to the tablet app through adb (see
/// [UsbSessionService]): anything on the tablet can dial the tunnel, and
/// anything on this Mac the loopback server.
class HostConnectionManager extends BaseConnectionManager {
  HostConnectionManager({super.socket, super.port});

  final _adb = Get.find<AdbService>();
  WifiPairingService get _pairing => Get.find<WifiPairingService>();
  WifiDiscoveryService get _discovery => Get.find<WifiDiscoveryService>();
  ScreenCaptureChannel get _capture => Get.find<ScreenCaptureChannel>();
  InputInjectChannel get _input => Get.find<InputInjectChannel>();
  RemoteVideoChannel get _remote => Get.find<RemoteVideoChannel>();

  @override
  bool get isHost => true;

  // The host is the server — once torn down there's nothing to wait for, so
  // re-listen quickly and let the tablet's own retry find us.
  @override
  Duration get reconnectDelay => const Duration(seconds: 1);

  /// Texture id of the decoded tablet stream (reverse remote: Mac controls the
  /// tablet). Null unless a reverse-remote session is live; the remote-view
  /// widget renders a `Texture` from it.
  final remoteTextureId = Rxn<int>();

  // Actual display bounds (updated after capture starts in extend/mirror mode).
  Map<String, double> _displayBounds = {'x': 0, 'y': 0, 'w': 0, 'h': 0};

  StreamSubscription? _frameSub;

  // Guards against overlapping capture rebuilds (the display-wake and
  // system-wake notifications both fire on resume).
  bool _restarting = false;

  // Completed when the client's HELLO arrives (it carries the panel size the
  // capture resolution is derived from).
  Completer<void>? _helloReceived;

  // The link the current (or last) connect attempt uses. Fixed for the whole
  // session: Home only offers the selector while idle.
  bool _wifiSession = false;

  // Until the client has proved itself (over Wi-Fi with the pairing token,
  // over USB with the session key), [admitPacket] drops everything it sends
  // and [_sendToClient] sends it nothing, so neither an unpaired machine on
  // the network nor another app on the tablet can inject input or see the
  // screen.
  //
  // What is remembered is the connection that authenticated
  // ([SocketService.connectionId]), not a flag: the server accepts whoever
  // dials next as soon as a client drops, and that must never inherit the
  // previous client's standing, however teardown and accept interleave.
  WifiIdentity? _identity;
  int? _authedConnection;
  Completer<_Proof>? _proof;

  // USB only: what this attempt's client has to prove it holds. Made once
  // the adb tunnel is up, handed to the tablet app through adb and to
  // nothing else, and good for one session: cleared when a client proves it,
  // and at teardown.
  Uint8List? _usbKey;
  // When the tablet app last confirmed taking [_usbKey].
  DateTime _keyTakenAt = DateTime.fromMillisecondsSinceEpoch(0);

  // The most a client that has not proved itself may announce: its proof and
  // a HELLO are a few dozen bytes.
  static const _untrustedPayloadLimit = 1024;

  // Hellos made without the key that one USB attempt puts up with before it
  // fails. One is normal (the tablet app was opened after this Mac started
  // waiting); more means something else on the tablet keeps dialling.
  static const _maxKeylessHellos = 8;

  // The connect() that built the live USB session, so a pairing offered
  // later in it (after an identity reset) can tell the session is still that
  // one.
  int _usbSessionSeq = 0;

  @override
  bool get peerTrusted =>
      _authedConnection != null && _authedConnection == socket.connectionId;

  /// Every packet this host sends to the client goes through here.
  void _sendToClient(Packet packet) {
    if (peerTrusted) socket.send(packet);
  }

  // Starting, restarting and stopping the media pipeline never overlap: each
  // waits for the one before it. A session can end while its capture is still
  // starting (the tablet drops, the user cancels); the stop then runs right
  // after that start instead of beside it, so it always wins.
  Future<void> _pipelineTail = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _pipelineTail.then((_) => operation());
    _pipelineTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // Wi-Fi only: a frame was dropped because the link fell behind, and the
  // frames after it reference the dropped one. Nothing is sent until the next
  // keyframe.
  bool _resyncing = false;
  bool _streamHevc = false;
  DateTime _lastResyncIdr = DateTime.fromMillisecondsSinceEpoch(0);

  // Wi-Fi only: fits the encoder's bitrate to the link while a capture runs
  // (see [_startBitrateAdaptation]). Null when nothing is being adapted.
  BitrateAdapter? _bitrate;
  Timer? _bitrateTimer;
  final _bitrateClock = Stopwatch()..start();
  // The link's queue at its lowest since the last sample, read just before
  // each frame is written: the point of the frame cycle where a link that
  // keeps up has delivered everything. A timer alone samples one fixed phase
  // of that cycle (50 ms is a whole number of frames at 60 fps).
  int? _queueTrough;
  // Round trips the heartbeat measured lately, one a second, for the lowest:
  // what the link holds in flight with no queue at all.
  final _roundTrips = ListQueue<int>();

  /// Whether the encoder's bitrate is being fitted to the link right now.
  @visibleForTesting
  bool get adaptingBitrate => _bitrateTimer?.isActive ?? false;

  /// How often the link's queue is looked at. Well inside
  /// [BitrateAdapter.window], so the smallest of several samples is judged.
  static const _bitrateSampleEvery = Duration(milliseconds: 50);

  /// Splash entry point: loads the device list for the picker and, when
  /// Screen Recording and Accessibility are granted, connects if there is
  /// nothing to choose ([connectIfUnambiguous]), as Home does when it opens.
  /// Not left to Home: an app launched behind other windows (or at login, or
  /// hidden) is `hidden` to Flutter, which draws no frames then, so the Home
  /// route is not built and its controller does not run until the window is
  /// shown. Without permissions nothing starts; Home asks for them once it
  /// is on screen.
  @override
  Future<void> autoConnect() async {
    // A Cancel or Disconnect (or a retry) after this point owns what
    // happens next: adb can take seconds to answer its first call.
    final attempt = currentAttempt;
    // Over Wi-Fi nothing waits on adb: the list is only for the picker.
    final listing = refreshDevices();
    if (settings.linkType != LinkType.wifi) await listing;
    if (isCancelled(attempt)) return;
    if (!await PermissionsChannel().hostGranted()) return;
    await connectIfUnambiguous(since: attempt);
  }

  @override
  Future<void> refreshDevices() async {
    availableDevices.value = await _adb.listDevices();
  }

  @override
  void sendUiFlags() {
    if (!phase.value.isActive) return;
    // 0xFA + performanceOverlay(0/1) + showHud(0/1).
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xFA,
        settings.showPerformanceOverlay.value ? 1 : 0,
        settings.showHudOverlay.value ? 1 : 0,
      ]),
    ));
  }

  @override
  Future<void> connect({String? serial}) async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    final attempt = currentAttempt;
    final seq = beginConnect();
    final wifi = settings.linkType == LinkType.wifi;
    // A device left over from a session on the other link means nothing on
    // this one: over Wi-Fi it is an address, over USB an adb serial. Kept, a
    // USB retry right after a Wi-Fi failure would look for the address among
    // the adb devices and fall back to the first one instead of the last-used.
    if (wifi != _wifiSession) activeDevice.value = null;
    _wifiSession = wifi;
    _authedConnection = null;
    _usbKey = null;
    // The device whose adb tunnel this attempt set up (USB only), so a
    // cancelled attempt knows which one to remove.
    String? tunnelled;
    Future<void> abandon() => _abandon(tunnelled, seq);
    try {
      if (wifi) {
        // No device to detect and no port to forward: listen, then wait for
        // the tablet to find this Mac and dial in.
        setPhase(ConnectionPhase.handshaking);
        final WifiIdentity identity;
        try {
          identity = await _pairing.ensureIdentity();
        } catch (e, st) {
          log.e('Host: no Wi-Fi identity', e, st);
          throw const LinkError('error_wifi_identity');
        }
        if (isCancelled(attempt)) return abandon();
        _identity = identity;
        // Listening for the proof before a tablet can connect: the awaits
        // below (the responder reads the Computer Name from a process) leave
        // time for a tablet dialling a known address to finish TLS and send
        // its token, and a packet nobody listens for is gone for good.
        _helloReceived = Completer<void>();
        _proof = Completer<_Proof>();
        startPacketLoop();
        await socket.startSecureServer(linkPort, identity.serverContext());
        if (isCancelled(attempt)) return abandon();
        try {
          await _startDiscoveryResponder(identity, attempt);
        } catch (e) {
          // Not fatal: the tablet can still dial a typed address.
          log.w('Host: discovery responder not started ($e)');
        }
        if (isCancelled(attempt)) return abandon();
        log.i('Host: listening on Wi-Fi, waiting for the tablet…');
        await socket.waitForClient();
        if (isCancelled(attempt)) return abandon();
        activeDevice.value = DeviceModel(
          serial: socket.remoteAddress ?? LinkType.wifi.chipLabel,
          status: DeviceStatus.connected,
        );
      } else {
        setPhase(ConnectionPhase.detectingDevice);
        final devices = await _adb.listDevices();
        if (isCancelled(attempt)) return;
        availableDevices.value = devices;
        if (devices.isEmpty) throw Exception('No ADB device detected');

        // Pick the explicitly requested device, else the one this session was
        // already using (a link-failure retry), else the last-used one, else
        // first.
        final preferred =
            serial ?? activeDevice.value?.serial ?? settings.lastDeviceSerial;
        final device = preferred != null
            ? (devices.firstWhereOrNull((d) => d.serial == preferred) ??
                devices.first)
            : devices.first;
        activeDevice.value = device;
        log.i('Host: using device ${device.serial}');

        setPhase(ConnectionPhase.portForwarding);
        tunnelled = device.serial;
        // Reverse tunnel: device:7001 → host:7001, so the tablet can dial us.
        final forwarded = await _adb.reverseForward(
          serial: device.serial,
          localPort: linkPort,
          remotePort: linkPort,
        );
        if (isCancelled(attempt)) return abandon();
        if (!forwarded) throw Exception('Port forwarding failed');

        setPhase(ConnectionPhase.handshaking);
        await socket.startServer(BaseConnectionManager.host, linkPort,
            untrustedPayloadLimit: _untrustedPayloadLimit);
        if (isCancelled(attempt)) return abandon();
        // Only now, with this attempt's tunnel up: the tablet app dials as
        // soon as it has the key, and what it then reaches on its port 7001
        // is adb. Not awaited: the app can be here before adb has reported.
        final key = UsbSessionService.newKey();
        _usbKey = key;
        _keyTakenAt = DateTime.fromMillisecondsSinceEpoch(0);
        unawaited(_deliverSessionKey(device.serial, key));
        log.i('Host: waiting for tablet to connect…');
        await socket.waitForClient();
        if (isCancelled(attempt)) return abandon();
      }

      if (!wifi) {
        // Over Wi-Fi these have been waiting since before the server was up.
        _helloReceived = Completer<void>();
        _proof = Completer<_Proof>();
        startPacketLoop();
      }

      setPhase(ConnectionPhase.configuring);
      // Whoever connected is a stranger until it proves otherwise. Over Wi-Fi
      // the TLS handshake proved this Mac to the client, not the client to
      // this Mac: anything on the network can get this far. Over USB anything
      // on the tablet can dial the tunnel.
      var keylessHellos = 0;
      while (true) {
        final proof = await _proof!.future.timeout(const Duration(seconds: 3),
            onTimeout: () => _Proof.none);
        if (isCancelled(attempt)) return abandon();
        if (proof == _Proof.given) break;
        if (wifi) throw const LinkError('error_wifi_unpaired_client');
        // Silence, or anything but a hello: an older tablet build, or
        // something else on the tablet.
        final key = _usbKey;
        final device = tunnelled;
        if (proof == _Proof.none ||
            key == null ||
            device == null ||
            ++keylessHellos > _maxKeylessHellos) {
          throw const LinkError('error_usb_unverified_client');
        }
        // A hello made without this attempt's key. From the tablet app that
        // means the key has not reached it: it was opened after the key was
        // sent, or it dialled just before the key arrived. Turn this
        // connection away, hand the key over (again), and go on waiting: the
        // app dials anew as soon as it has it.
        socket.dropClient();
        _proof = Completer<_Proof>();
        setPhase(ConnectionPhase.handshaking);
        // Taken a moment ago: the dial and the delivery crossed.
        if (DateTime.now().difference(_keyTakenAt) >
            const Duration(seconds: 1)) {
          final delivery = await _deliverSessionKey(device, key);
          if (isCancelled(attempt)) {
            await abandon();
            return;
          }
          if (delivery != AdbDelivery.stored) {
            throw const LinkError('error_usb_key_not_delivered');
          }
        }
        await socket.waitForClient();
        if (isCancelled(attempt)) {
          await abandon();
          return;
        }
        setPhase(ConnectionPhase.configuring);
      }
      // Wait for the client's HELLO so the capture resolution matches its
      // panel; on timeout fall back to the last-known (persisted) panel.
      try {
        await _helloReceived!.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        log.w('Host: no HELLO from client — using last-known panel '
            '${settings.clientPanelWidth.value}×${settings.clientPanelHeight.value}');
      }
      if (isCancelled(attempt)) return abandon();

      // Start the media pipeline. Reverse-remote (Mac controls tablet) decodes
      // the tablet's stream; every other mode captures + encodes the Mac. Both
      // are non-fatal so the link stays up even if the pipeline can't start.
      try {
        await _exclusive(() => settings.isReverseRemote
            ? _startRemoteReceive()
            : _startCapture(attempt));
      } catch (e, st) {
        log.e('Host: media pipeline not started (permission?)', e, st);
      }
      if (isCancelled(attempt)) return abandon();

      setPhase(ConnectionPhase.streaming);
      startHeartbeat();
      if (!wifi) {
        final device = activeDevice.value;
        // Remember the device only once the link is actually live — saving it
        // on every attempt let a failed retry (e.g. falling back to an
        // emulator while the tablet was unplugged) overwrite the real
        // last-used device.
        if (device != null) {
          await settings.setLastDevice(device.serial);
          if (device.model != null && device.model!.isNotEmpty) {
            await settings.setLastDeviceName(device.model!);
          }
        }
        _usbSessionSeq = seq;
        unawaited(_offerWifiPairing(seq));
      }
      log.i('Host: link live (streaming)');
    } catch (e, st) {
      if (isCancelled(attempt)) return; // cancelled mid-attempt: no retry
      log.e('Host connection failed', e, st);
      errorMessage.value = e.toString();
      await handleLinkFailure();
    }
  }

  /// Answers discovery probes under the name the tablet shows for this Mac:
  /// its Computer Name ([macDisplayName]), not `Platform.localHostname`,
  /// which is whatever the current network calls the machine.
  ///
  /// [attempt] can end while the name is being read; then nothing is started
  /// (the caller's own check follows and abandons the attempt).
  Future<void> _startDiscoveryResponder(
      WifiIdentity identity, int attempt) async {
    final name = await macDisplayName();
    if (isCancelled(attempt)) return;
    await _discovery.startResponder(
      hostId: identity.hostId,
      name: name,
      tcpPort: linkPort,
    );
  }

  /// Hands [key] to the tablet app through adb, and to nothing else
  /// ([AdbService.deliverUsbSessionKey]).
  Future<AdbDelivery> _deliverSessionKey(String serial, Uint8List key) async {
    final delivery = await _adb.deliverUsbSessionKey(serial: serial, key: key);
    // adb can report after the session the key was for has begun, or ended.
    if (!identical(key, _usbKey)) return delivery;
    switch (delivery) {
      case AdbDelivery.stored:
        _keyTakenAt = DateTime.now();
        log.i('Host: USB session key delivered to the tablet through adb');
      case AdbDelivery.refused:
        log.w('Host: the tablet app refused the USB session key');
      case AdbDelivery.notDelivered:
        log.w('Host: the tablet did not take the USB session key (the app is '
            'not open, an older build, or adb failed)');
    }
    return delivery;
  }

  /// Every USB session hands the tablet what it needs to find and trust this
  /// Mac over Wi-Fi later. It goes through adb, to this app on the tablet
  /// ([AdbService.deliverWifiPairing]), and never on the socket: the pairing
  /// carries the token that lets its holder drive this Mac over Wi-Fi, a
  /// credential that outlives the session and has no business on a link.
  /// Nothing is offered on a Wi-Fi session.
  Future<void> _offerWifiPairing(int seq) async {
    try {
      final identity = await _pairing.ensureIdentity();
      // Where this Mac is right now, so the tablet can ask it directly later
      // (a broadcast does not cross into another subnet).
      final addresses = await WifiDiscoveryService.lanAddresses();
      // The Computer Name: what the tablet will show as the Mac it is paired
      // with.
      final name = await macDisplayName();
      final device = activeDevice.value;
      if (!isLatestConnect(seq) ||
          _wifiSession ||
          !phase.value.isActive ||
          device == null) {
        return;
      }
      final delivery = await _adb.deliverWifiPairing(
        serial: device.serial,
        payload: WifiPairingService.buildPairingPayload(identity, name,
            addresses: addresses),
      );
      switch (delivery) {
        case AdbDelivery.stored:
          log.i('Host: Wi-Fi pairing delivered to the tablet through adb');
        case AdbDelivery.refused:
          log.w('Host: the tablet refused the Wi-Fi pairing (it knows this '
              'Mac under another identity: forget it on the tablet)');
        case AdbDelivery.notDelivered:
          log.w('Host: the tablet did not take the Wi-Fi pairing (an older '
              'app build, or adb failed)');
      }
    } catch (e) {
      log.w('Host: Wi-Fi pairing not offered ($e)');
    }
  }

  /// Discards this Mac's Wi-Fi identity (Settings → Reset Wi-Fi pairing): no
  /// tablet paired so far can connect over Wi-Fi again until it has been
  /// connected over USB once more.
  ///
  /// A Wi-Fi server that is up still presents the old certificate, and a
  /// tablet on it got in with the old token, so that session or wait ends and
  /// the host listens again with the new identity. A live USB session carries
  /// on, and its tablet is handed the new identity at once.
  @override
  Future<void> resetWifiIdentity() async {
    await _pairing.resetIdentity();
    _identity = null;
    final p = phase.value;
    if (_wifiSession) {
      // In `error` the pending retry makes its own identity; idle, the next
      // connect does.
      if (p.isConnecting || p.isActive) {
        await disconnect();
        // Not awaited: over Wi-Fi a connect lasts until a tablet arrives.
        unawaited(connect());
      }
    } else if (p.isActive) {
      unawaited(_offerWifiPairing(_usbSessionSeq));
    }
  }

  /// Cancel landed while this attempt was mid-await: disconnect() already tore
  /// down what existed then, so undo whatever the attempt set up since (tunnel,
  /// server, capture). Every step is safe to repeat — but skip it entirely if
  /// the user already started a newer attempt, which now owns those resources.
  /// [tunnelled] is the device whose adb tunnel the attempt created, if any.
  ///
  /// Ownership is checked again after every await: a newer attempt can start
  /// while this one is still cleaning up (reconnect() is disconnect() followed
  /// at once by connect(), and over Wi-Fi the new attempt is listening within
  /// microtasks), and closing the socket then would close *its* listener.
  Future<void> _abandon(String? tunnelled, int seq) async {
    log.i('Host: connect attempt cancelled');
    if (!isLatestConnect(seq)) return;
    await onTeardown();
    if (!isLatestConnect(seq)) return;
    if (tunnelled != null) {
      await _adb.removeForward(serial: tunnelled);
      if (!isLatestConnect(seq)) return;
    }
    await socket.disconnect();
  }

  /// A lost link invalidates the whole session (capture, virtual display,
  /// adb tunnel), so rebuild from scratch rather than resume a half-alive one.
  @override
  Future<void> onLinkLost() => onTeardown();

  /// [attempt] is the session this start belongs to. That session can end at
  /// any await below; the teardown that ends it stops whatever was started,
  /// after this returns (see [_exclusive]), so all this has to do then is not
  /// go on: no further native calls, no packets, no frame subscription.
  Future<void> _startCapture(int attempt) async {
    bool stale() => isCancelled(attempt);
    if (stale()) return;
    // Let native wake/stream-stop callbacks rebuild the pipeline (see below).
    _capture.onCaptureRestartNeeded = _restartCapture;
    // Display rearrangement doesn't need a rebuild — just fresh bounds.
    _capture.onDisplayBoundsChanged = _refreshDisplayBounds;
    // Max preset: the encoder changed its rate (down under load, back up once
    // it recovers) — tell the tablet so its display mode + HUD follow (same
    // 0xFB it gets at stream start).
    _capture.onFrameRateChanged = _announceRefreshRate;

    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: settings.captureWidth,
      height: settings.captureHeight,
      scaleFactor: settings.captureScaleFactor,
      refreshRate: settings.refreshRate,
      bitrate: settings.captureBitrate,
      // Remote-control sessions always mirror the real desktop; extended-screen
      // honours the user's Extend/Mirror choice.
      mode: settings.effectiveDisplayMode,
      codec: settings.codec,
      adaptiveFps: settings.encodePreset == EncodePreset.max,
    );

    await _capture.requestPermission();
    await _input.requestAccessibility();
    if (stale()) return;

    if (config.mode == DisplayMode.extend) {
      if (!await _capture.createVirtualDisplay(config)) {
        log.w('Host: virtual display settings not applied — capture falls '
            'back to the main display if it never appears');
      }
      if (stale()) return;
    }
    await _capture.startCapture(config);
    if (stale()) return;

    // Fetch the captured display's bounds so touch injection lands on the
    // screen the tablet shows.
    _displayBounds = await _capture.getDisplayBounds();
    if (stale()) return;
    if ((_displayBounds['w'] ?? 0) <= 0 || (_displayBounds['h'] ?? 0) <= 0) {
      // Bounds query failed — fall back to the logical size we configured.
      _displayBounds = {
        'x': 0,
        'y': 0,
        'w': config.width.toDouble(),
        'h': config.height.toDouble(),
      };
    }
    log.i('Display bounds: $_displayBounds');

    // Announce the active session mode + direction so the client knows its role.
    _sendSessionMode();

    // Tell client which codec we're using so it can initialize the right decoder.
    // 0xFC + 0x00 = H264, 0xFC + 0x01 = H265/HEVC.
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFC, config.codec == CodecType.h265 ? 1 : 0]),
    ));

    // Tell the client the capture refresh rate so its display mode + HUD match.
    _announceRefreshRate(config.refreshRate);

    // Sync the overlay/HUD toggles so a fresh client matches the host.
    sendUiFlags();

    _streamHevc = config.codec == CodecType.h265;
    _resyncing = false;
    if (_wifiSession) _limitSendBufferFor(config.bitrate);

    // Forward each encoded NAL unit from native → socket as FRAME_DATA.
    _frameSub = _capture.frameStream.listen(_forwardFrame);
    if (_wifiSession) _startBitrateAdaptation(config.bitrate);
  }

  /// Wi-Fi: from now until the capture stops, the encoder's bitrate follows
  /// what the link carries ([BitrateAdapter]), starting at the preset's.
  void _startBitrateAdaptation(int presetBitrate) {
    _stopBitrateAdaptation();
    final adapter = _bitrate = BitrateAdapter(ceiling: presetBitrate);
    streamBitrate.value = adapter.bitrate;
    var ticks = 0;
    _bitrateTimer = Timer.periodic(_bitrateSampleEvery, (_) {
      if (!identical(adapter, _bitrate) || !peerTrusted) return;
      if (ticks++ % 20 == 0) _noteRoundTrip();
      final queued = socket.unackedBytes;
      final trough = _queueTrough;
      _queueTrough = null;
      final next = adapter.sample(
        nowUs: _bitrateClock.elapsedMicroseconds,
        queuedBytes: trough == null ? queued : math.min(trough, queued),
        deliveredBytes: socket.bytesSent - queued,
        inFlight: _inFlight,
      );
      if (next == null) return;
      log.i('Host: Wi-Fi link → encoder at ${next ~/ 1000} kbps');
      streamBitrate.value = next;
      _limitSendBufferFor(next);
      _capture.setBitrate(next);
    });
  }

  /// The kernel's send buffer, as 400 ms of stream at [bitrate]. Room for a
  /// keyframe (a quarter second of stream or so) on top of what is in
  /// flight: a buffer smaller than one keeps the keyframe waiting in this
  /// process past the congestion limit, and every keyframe on a link near
  /// the rate becomes refused frames. And no more than that: what the
  /// kernel holds is latency the adapter can no longer cut once at its
  /// floor, so the buffer follows the rate down. Without a cap it grows to
  /// megabytes and hides a slow link for seconds.
  void _limitSendBufferFor(int bitrate) => socket.limitSendBuffer(
      (bitrate / 8 * 0.4).round().clamp(64 * 1024, 2 * 1024 * 1024));

  /// Keeps the last 30 s of heartbeat round trips (one a second).
  void _noteRoundTrip() {
    final ms = latencyMs.value;
    if (ms <= 0) return;
    _roundTrips.addLast(ms);
    while (_roundTrips.length > 30) {
      _roundTrips.removeFirst();
    }
  }

  /// What a link that keeps up holds unacknowledged anyway: one round trip of
  /// stream. The heartbeat's lowest recent round trip, which is the network's
  /// without a queue (a queue delays the heartbeat too); 10 ms until one has
  /// been measured. Never more than 40 ms, more than any healthy Wi-Fi LAN
  /// needs: on a link that has been congested since the start every
  /// heartbeat waited behind the queue, and the queue must still be judged.
  Duration get _inFlight => Duration(
      milliseconds:
          _roundTrips.isEmpty ? 10 : math.min(_roundTrips.reduce(math.min), 40));

  /// Synchronous, so a teardown can call it before its first await: nothing
  /// may change the encoder's rate for a session that is ending.
  void _stopBitrateAdaptation() {
    _bitrateTimer?.cancel();
    _bitrateTimer = null;
    _bitrate = null;
    _queueTrough = null;
    _roundTrips.clear();
    streamBitrate.value = null;
  }

  /// Sends one encoded frame. Over USB that is all it does. Over Wi-Fi the
  /// socket refuses a frame when the link has fallen behind; from then on
  /// every frame is dropped until the link has drained and the encoder has
  /// produced a keyframe, so the tablet shows a short freeze instead of a
  /// picture that lags further and further.
  void _forwardFrame(Uint8List nal) {
    if (!peerTrusted) return;
    if (_resyncing) {
      // Drained means the kernel too, not only this process's queue: the
      // keyframe that resumes the picture is the largest frame there is, and
      // behind a full kernel buffer it waits past the congestion limit and
      // is refused in turn, again and again on a link near its capacity.
      if (socket.isCongested || socket.unackedBytes > _resumeBelow) return;
      if (!isKeyframeAccessUnit(nal, hevc: _streamHevc)) {
        final now = DateTime.now();
        if (now.difference(_lastResyncIdr) >
            const Duration(milliseconds: 500)) {
          _lastResyncIdr = now;
          _capture.requestIdr();
        }
        return;
      }
      _resyncing = false;
      log.i('Host: link caught up — resuming from a keyframe');
    }
    if (_bitrate != null) {
      final queued = socket.unackedBytes;
      final trough = _queueTrough;
      if (trough == null || queued < trough) _queueTrough = queued;
    }
    final sent = socket.sendFrame(Packet(
      type: PacketType.frameData,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: nal,
    ));
    if (!sent) {
      _resyncing = true;
      _bitrate?.frameRefused();
      log.w('Host: Wi-Fi link is behind — dropping frames until it catches up');
    }
  }

  /// What may still be unacknowledged when the picture resumes after a
  /// refusal: about 30 ms of stream, at least 64 KB.
  int get _resumeBelow => math.max(
      64 * 1024, (streamBitrate.value ?? settings.captureBitrate) ~/ 8 * 3 ~/ 100);

  /// 0xFB + refreshRate (Hz, single byte): the rate the host is encoding at.
  void _announceRefreshRate(int hz) {
    refreshRateHz.value = hz;
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFB, hz.clamp(0, 255)]),
    ));
  }

  /// Rebuilds the capture pipeline after the native side reports it died — the
  /// Mac woke from sleep (ScreenCaptureKit, the CGVirtualDisplay and the
  /// VideoToolbox session are all invalidated by a sleep/wake cycle) or the
  /// SCStream stopped with an error. The ADB-reverse socket survives sleep, so
  /// nothing else would recover — unless the link sat silent past the
  /// heartbeat's 6 s timeout, in which case the reconnect path rebuilds the
  /// whole session instead.
  Future<void> _restartCapture() async {
    if (_restarting) return;
    if (!phase.value.isActive || settings.isReverseRemote) return;
    _restarting = true;
    final attempt = currentAttempt;
    try {
      await _exclusive(() async {
        // The session may have ended while this waited its turn.
        if (isCancelled(attempt) || !phase.value.isActive) return;
        log.w('Host: rebuilding capture pipeline after wake/stream-stop');
        // The new encoder starts at the preset's bitrate, and so does the
        // adaptation that _startCapture sets up for it.
        _stopBitrateAdaptation();
        await _frameSub?.cancel();
        _frameSub = null;
        await _capture.stopCapture();
        await _capture.removeVirtualDisplay();
        await _startCapture(attempt);
        if (isCancelled(attempt)) return;
        await _capture.requestIdr();
        log.i('Host: capture pipeline rebuilt');
      });
    } catch (e, st) {
      log.e('Host: capture restart failed', e, st);
    } finally {
      _restarting = false;
    }
  }

  /// Re-fetches the virtual/main display's screen-space bounds after the
  /// native side reports the display arrangement changed (e.g. the virtual
  /// display was dragged to a different position in System Settings →
  /// Displays). Touch/mouse injection maps normalized coordinates through
  /// these bounds, so a stale cache sends input to the display's old position.
  Future<void> _refreshDisplayBounds() async {
    if (!phase.value.isActive || settings.isReverseRemote) return;
    final bounds = await _capture.getDisplayBounds();
    if ((bounds['w'] ?? 0) > 0 && (bounds['h'] ?? 0) > 0) {
      _displayBounds = bounds;
      log.i('Display bounds refreshed: $_displayBounds');
    }
  }

  /// Reverse remote (Mac controls tablet): the tablet captures + encodes its own
  /// screen, so the host decodes the incoming stream into a Flutter texture and
  /// injects input back via `adb shell input`. No ScreenCaptureKit here.
  Future<void> _startRemoteReceive() async {
    // Tell the client to switch into capture mode.
    _sendSessionMode();

    // Stand up the decoder + texture sized to the tablet's native panel.
    _remote.onRequestIdr = requestIdr; // base sends 0xFF → tablet re-IDRs
    final texId = await _remote.initialize(
      codec: settings.codec,
      width: settings.clientPanelWidth.value,
      height: settings.clientPanelHeight.value,
    );
    remoteTextureId.value = texId;

    // Here the *tablet's* encoder does the work, and Max's native @ 120 Hz is
    // beyond it (its HEVC encoder manages well under 120 fps at 4K), so Max
    // falls back to Quality's native @ 60 Hz / 20 Mbps in this direction.
    final isMax = settings.encodePreset == EncodePreset.max;
    final fps = isMax ? 60 : settings.refreshRate;
    final bitrate = isMax ? 20000000 : settings.captureBitrate;
    refreshRateHz.value = fps;

    // Instruct the client to begin capturing + encoding.
    // 0xF8 + codec + fps + bitrate(Mbps).
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xF8,
        settings.codec == CodecType.h265 ? 1 : 0,
        fps.clamp(0, 255),
        (bitrate ~/ 1000000).clamp(1, 255),
      ]),
    ));
    log.i('Host: reverse remote — decoding tablet stream (texture $texId)');
  }

  /// 0xF9 + sessionMode index + remoteDirection index.
  void _sendSessionMode() {
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xF9,
        settings.sessionMode.index,
        // Over Wi-Fi this is always tablet-controls-Mac.
        settings.effectiveRemoteDirection.index,
      ]),
    ));
  }

  // ─── Reverse-remote input (Mac → tablet via adb) ──────────────────────────
  // The remote-view widget reports normalized coords; map them to the tablet's
  // device pixels and drive `adb shell input`.

  void sendRemoteTap(double nx, double ny) {
    final serial = activeDevice.value?.serial;
    if (serial == null) return;
    _adb.inputTap(
      serial: serial,
      x: (nx * settings.clientPanelWidth.value).round(),
      y: (ny * settings.clientPanelHeight.value).round(),
    );
  }

  void sendRemoteSwipe(double nx1, double ny1, double nx2, double ny2,
      {int durationMs = 50}) {
    final serial = activeDevice.value?.serial;
    if (serial == null) return;
    final w = settings.clientPanelWidth.value;
    final h = settings.clientPanelHeight.value;
    _adb.inputSwipe(
      serial: serial,
      x1: (nx1 * w).round(),
      y1: (ny1 * h).round(),
      x2: (nx2 * w).round(),
      y2: (ny2 * h).round(),
      durationMs: durationMs,
    );
  }

  @override
  Future<void> onTeardown() async {
    // Stop native wake callbacks from resurrecting capture after a disconnect.
    // Cleared before the first await, so a callback landing mid-teardown is
    // ignored rather than restarting capture behind it.
    _capture.onCaptureRestartNeeded = null;
    _capture.onDisplayBoundsChanged = null;
    _capture.onFrameRateChanged = null;
    _stopBitrateAdaptation();
    if (Get.isRegistered<WifiDiscoveryService>()) _discovery.stopResponder();
    final reverse = settings.isReverseRemote;
    if (reverse) {
      // Best-effort: tell the client to stop capturing before the socket drops.
      _sendToClient(Packet(
        type: PacketType.control,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: Uint8List.fromList([0xF7]),
      ));
    }
    // From here on nobody is authenticated, whoever the socket belongs to,
    // and this attempt's USB key opens nothing any more.
    _authedConnection = null;
    _usbKey = null;
    // Wake a connect() parked on the proof or the HELLO: its session is over,
    // and it must find that out now, not when its timeout fires seconds later
    // in the middle of the session that replaced it.
    _settle(_Proof.none);
    if (!(_helloReceived?.isCompleted ?? true)) _helloReceived!.complete();
    // A drag cut off by the link dropping never gets its up: release the
    // button, or every later injected move would post as a drag.
    await _input.releaseAll();
    // Behind any start still in flight, so what it started is stopped too.
    await _exclusive(() async {
      // Again: a start that was mid-flight above may have set them since.
      _capture.onCaptureRestartNeeded = null;
      _capture.onDisplayBoundsChanged = null;
      _capture.onFrameRateChanged = null;
      _stopBitrateAdaptation();
      await _frameSub?.cancel();
      _frameSub = null;
      if (reverse) {
        await _remote.dispose();
        remoteTextureId.value = null;
      } else {
        await _capture.stopCapture();
        await _capture.removeVirtualDisplay();
      }
    });
    // A Wi-Fi session has no tunnel, and its "device" is an address.
    if (!_wifiSession && activeDevice.value != null) {
      await _adb.removeForward(serial: activeDevice.value!.serial);
    }
  }

  /// The gate every inbound packet passes before anything looks at it,
  /// heartbeats included. Nothing is admitted until this connection has
  /// proved itself: over Wi-Fi with the pairing token, over USB with a hello
  /// made with this attempt's session key.
  @override
  bool admitPacket(Packet packet) {
    if (peerTrusted) return true;
    // One packet decides, per connection: after it the client is either
    // trusted or about to be turned away.
    if (_proof?.isCompleted ?? true) return false;
    if (packet.type != PacketType.control || packet.payload.isEmpty) {
      return false;
    }
    final command = packet.payload[0];
    if (_wifiSession) {
      // 0xF5 — Tablet → Host: the pairing token. The only packet an
      // unauthenticated Wi-Fi client can get a reaction to.
      if (command != WifiPairingService.authCommand) return false;
      final paired =
          _identity?.tokenMatches(packet.payload.sublist(1)) ?? false;
      if (paired) {
        _trustConnection();
        // The tablet has found this Mac. Until the host listens again there
        // is nobody to answer, and no reason to keep a UDP port open.
        if (Get.isRegistered<WifiDiscoveryService>()) {
          _discovery.stopResponder();
        }
      }
      _settle(paired ? _Proof.given : _Proof.wrong);
    } else {
      // 0xF4 — Tablet → Host: the hello of a USB session. The only packet an
      // unproven USB client can get a reaction to.
      if (command != UsbSessionService.helloCommand) return false;
      final key = _usbKey;
      final nonce = key == null
          ? null
          : UsbSessionService.verifyHello(key, packet.payload);
      if (key != null && nonce != null) {
        // One session per key: a hello cannot be played back.
        _usbKey = null;
        _trustConnection();
        // 0xF3 — Host → Tablet: this Mac holds the key too. Sent only now,
        // so a client without the key learns nothing from this side.
        _sendToClient(Packet(
          type: PacketType.control,
          timestampUs: DateTime.now().microsecondsSinceEpoch,
          payload: UsbSessionService.buildAnswer(key, nonce),
        ));
      }
      _settle(nonce != null ? _Proof.given : _Proof.wrong);
    }
    return false;
  }

  void _trustConnection() {
    _authedConnection = socket.connectionId;
    socket.trustPeer();
  }

  void _settle(_Proof proof) {
    if (!(_proof?.isCompleted ?? true)) _proof!.complete(proof);
  }

  @override
  void onRolePacket(Packet packet) {
    switch (packet.type) {
      // Reverse remote: encoded frames coming FROM the tablet → decode them.
      case PacketType.frameData when settings.isReverseRemote:
        _remote.feedNal(packet.payload);
        break;

      // HELLO from the client: version + platform + native panel size.
      case PacketType.control
          when packet.payload.isNotEmpty && packet.payload[0] == 0x01:
        _onHello(packet.payload);
        break;

      // Host injects input received from the tablet.
      case PacketType.touchEvent:
        _injectTouch(packet);
        break;
      case PacketType.mouseEvent:
        _injectMouse(packet);
        break;
      case PacketType.keyEvent:
        _injectKey(packet);
        break;

      // 0xFF — Tablet → Host: request a fresh keyframe (IDR).
      case PacketType.control
          when packet.payload.isNotEmpty && packet.payload[0] == 0xFF:
        _capture.requestIdr();
        break;

      default:
        break;
    }
  }

  /// Parse the client HELLO: [version, platform, panelW hi, panelW lo,
  /// panelH hi, panelH lo, panel max refresh Hz]. Older clients send fewer
  /// bytes — then the last-known values are kept.
  void _onHello(Uint8List p) {
    if (p.length >= 6) {
      final w = (p[2] << 8) | p[3];
      final h = (p[4] << 8) | p[5];
      if (w >= 320 && h >= 240 && w <= 8192 && h <= 8192) {
        settings.setClientPanel(w, h);
        log.i('Host: client panel $w×$h');
      }
    }
    if (p.length >= 7 && p[6] >= 24) {
      settings.setClientMaxRefresh(p[6]);
      log.i('Host: client panel max refresh ${p[6]} Hz');
    }
    if (!(_helloReceived?.isCompleted ?? true)) _helloReceived!.complete();
  }

  // Without valid bounds, normalized coords can't be mapped to the screen.
  bool get _hasBounds => (_displayBounds['w'] ?? 0) > 0;

  void _injectTouch(Packet packet) {
    if (!_hasBounds) return;
    // Map a single primary pointer to a mouse move/click on macOS.
    final t = PacketCodec.decodeTouch(packet.payload);
    if (t == null || t.pointers.isEmpty) return;
    final p = t.pointers.first;
    final action = switch (t.action) {
      TouchAction.down => MouseAction.down,
      TouchAction.up => MouseAction.up,
      TouchAction.move => MouseAction.move,
      TouchAction.cancel => MouseAction.up,
    };
    _input.injectMouse(
      MouseEventModel(
        normalizedX: p.normalizedX,
        normalizedY: p.normalizedY,
        button: MouseButton.left,
        action: action,
        timestampUs: t.timestampUs,
      ),
      _displayBounds,
    );
  }

  void _injectMouse(Packet packet) {
    if (!_hasBounds) return;
    final m = PacketCodec.decodeMouse(packet.payload);
    if (m != null) _input.injectMouse(m, _displayBounds);
  }

  void _injectKey(Packet packet) {
    final k = PacketCodec.decodeKey(packet.payload);
    if (k != null) _input.injectKey(k);
  }
}

/// What a client that just connected did about proving itself.
enum _Proof {
  /// It holds the pairing token (Wi-Fi) or the session key (USB).
  given,

  /// It tried, with the wrong one. Over USB also a hello with none.
  wrong,

  /// Nothing within the time allowed, or the session ended first.
  none,
}
