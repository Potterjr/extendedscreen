import 'dart:async';
import 'dart:io' show InternetAddress, InternetAddressType, TlsException;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/link_measure.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/platform/keepalive_channel.dart';
import 'package:extendedscreen/shared/protocol/client_hello.dart';
import 'package:extendedscreen/modules/remote_screen/client/android_capture_channel.dart';
import 'package:extendedscreen/modules/extended_screen/client/video_decoder_channel.dart';

/// CLIENT role (Android, and the iOS client: iPhone or iPad, Wi-Fi only):
/// dials into the adb-reverse tunnel or a paired Mac, reports its native
/// panel size + top refresh rate in the HELLO, then decodes + renders frames
/// (in DisplayController) and forwards touch input back to the host. The macOS
/// host is the control surface: stream settings are edited only there, and the
/// values this side needs arrive as control packets (see [onRolePacket]).
///
/// The one thing the tablet decides for itself is where to dial: the adb
/// tunnel ([LinkType.usb]) or a paired Mac on the network ([LinkType.wifi]).
///
/// Whatever answers is a stranger until it has proved it is the Mac: over
/// Wi-Fi with the certificate from the pairing, over USB by answering this
/// dial's hello with the session key adb delivered ([UsbSessionService]).
/// Until then nothing it sends is acted on or shown, and it is sent nothing
/// but that hello.
class ClientConnectionManager extends BaseConnectionManager {
  /// [ios] defaults to the platform ([runsOnIos]); tests pass it to play the
  /// iOS client's lifecycle on any host.
  ClientConnectionManager({super.socket, super.port, bool? ios})
      : ios = ios ?? runsOnIos;

  /// The iOS client: foreground only (see [didChangeAppLifecycleState]),
  /// HELLO platform `0x03`/`0x04`, no reverse capture.
  final bool ios;

  @override
  bool get isHost => false;

  /// Reverse remote's capturer. Registered on Android only: iOS can neither
  /// capture its screen for the Mac nor take the Mac's input, so there every
  /// reverse-remote path does nothing.
  AndroidCaptureChannel? get _capture =>
      Get.isRegistered<AndroidCaptureChannel>()
          ? Get.find<AndroidCaptureChannel>()
          : null;
  WifiPairingService get _pairing => Get.find<WifiPairingService>();
  WifiDiscoveryService get _discovery => Get.find<WifiDiscoveryService>();
  UsbSessionService get _usb => Get.find<UsbSessionService>();

  StreamSubscription? _captureFrameSub;

  // The connection whose other end proved it is the Mac
  // ([SocketService.connectionId]), not a flag: the next dial can be answered
  // by something else.
  int? _trustedConnection;

  @override
  bool get peerTrusted =>
      _trustedConnection != null && _trustedConnection == socket.connectionId;

  // USB: the key the current (or last) dial was made with, and the hello
  // that dial is waiting to have answered.
  Uint8List? _dialKey;
  ({Uint8List? key, Uint8List nonce, int connection, Completer<bool> done})?
      _awaitingAnswer;
  StreamSubscription<void>? _keySub;

  /// How long the Mac has to answer a USB hello. It needs no time to speak
  /// of (it holds the key before the tablet does); a Mac build from before
  /// the handshake never answers, and must be let go before it gives up
  /// waiting for the HELLO (3 s) and starts a capture for nobody.
  static const _answerTimeout = Duration(seconds: 2);

  // Capture params from the host's 0xF8, applied when the user taps "Start
  // screen sharing" (MediaProjection consent must be user-initiated from the
  // foreground, so we don't auto-prompt).
  CodecType? _pendingCodec;
  int _pendingFps = 60;
  int _pendingBitrateMbps = 12;

  /// The client always dials in (and retries until the host server is up).
  @override
  Future<void> autoConnect() async {
    await connect();
  }

  @override
  Future<void> connect({String? serial}) async {
    if (phase.value.isConnecting || phase.value.isActive) return;
    final attempt = currentAttempt;
    final seq = beginConnect();
    // Cancelled mid-await: drop the socket this attempt opened — unless a newer
    // attempt has started since and the socket is now its.
    Future<void> abandon() async {
      if (isLatestConnect(seq)) await socket.disconnect();
    }
    final wifi = settings.linkType == LinkType.wifi;
    _trustedConnection = null;
    try {
      setPhase(ConnectionPhase.handshaking);
      if (wifi) {
        final target = await _findWifiHost();
        if (isCancelled(attempt)) return abandon();
        // The pin: only a certificate a paired Mac handed over through adb
        // passes.
        await socket.connectSecure(
          target.address,
          target.port,
          trustCertificate: (der) => _pairing.hostForCert(der) != null,
        );
        if (isCancelled(attempt)) return abandon();
        final host = _pairing.hostForCert(socket.peerCertificateDer);
        if (host == null) throw const LinkError('error_wifi_untrusted');
        // The TLS handshake with a paired Mac's certificate is its proof.
        _trustedConnection = socket.connectionId;
        unawaited(_pairing.rememberAddress(host, target.address));
        startPacketLoop();
        // First packet of the session: prove this tablet was paired. The host
        // ignores everything else until it has seen this.
        socket.send(Packet(
          type: PacketType.control,
          timestampUs: DateTime.now().microsecondsSinceEpoch,
          payload: WifiPairingService.buildAuthPayload(host),
        ));
      } else {
        // A key that arrives from now on means a Mac has started a new
        // attempt: dial again with it at once (see [_onSessionKey]).
        _keySub ??= _usb.arrivals.listen((_) => _onSessionKey());
        // Read before dialling, and the only key this connection is ever
        // judged by: a key is for connections made after it arrived, which
        // reach adb because the Mac made it with its tunnel already up. A
        // connection from before could have been taken by an app that held
        // port 7001 at the time, and which would now pass everything on.
        final key = _usb.key;
        _dialKey = key;
        // Connects through the adb-reverse tunnel set up by the host, if
        // that is what is listening.
        await socket.connect(BaseConnectionManager.host, linkPort);
        if (isCancelled(attempt)) return abandon();
        socket.distrustPeer();
        final nonce = UsbSessionService.newNonce();
        final answered = Completer<bool>();
        _awaitingAnswer = (
          key: key,
          nonce: nonce,
          connection: socket.connectionId,
          done: answered,
        );
        startPacketLoop();
        // First packet of the session: prove this app holds the key, without
        // sending it. With no key yet it only tells a waiting Mac that the
        // app is here, and the Mac hands its key over through adb.
        socket.send(Packet(
          type: PacketType.control,
          timestampUs: DateTime.now().microsecondsSinceEpoch,
          payload: UsbSessionService.buildHello(key, nonce),
        ));
        final verified = await answered.future
            .timeout(_answerTimeout, onTimeout: () => false);
        if (isCancelled(attempt)) {
          await abandon();
          return;
        }
        // Fail closed: whatever is on the other end, it is not a Mac that
        // adb vouches for (or a Mac build from before this handshake).
        if (!verified) throw const LinkError('error_usb_unverified_host');
      }

      setPhase(ConnectionPhase.configuring);
      _maxRefreshHz ??= await Get.find<VideoDecoderChannel>().getMaxRefreshRate();
      if (isCancelled(attempt)) return abandon();
      _sendHandshake(_maxRefreshHz!);

      setPhase(ConnectionPhase.streaming);
      if (measureLink) _measure!.linkStarted();
      startHeartbeat();
      // Hold the process at foreground priority so backgrounding the tablet
      // (e.g. switching to a game) can't get us frozen + killed, dropping the
      // socket + decoder. Started here — while in the foreground — so Android's
      // background-FGS-start restriction doesn't reject it; it then survives the
      // app going to background.
      KeepAliveChannel.start();
      // Over Wi-Fi, keep the radio out of power saving while streaming; a USB
      // session lets go of a lock an earlier Wi-Fi session took.
      KeepAliveChannel.setLowLatencyWifi(wifi);
      log.i('Client: connected to host, streaming');
    } catch (e) {
      if (isCancelled(attempt)) return; // cancelled mid-attempt: no retry
      // Expected to fail until the host is up; retry quietly.
      log.w('Client connect failed (${e.runtimeType}); retrying…');
      errorKey.value = switch (e) {
        LinkError() => e.key,
        // The peer's certificate is not a paired Mac's (or the Mac made a new
        // identity): waiting won't fix that, pairing again over USB will.
        TlsException() => 'error_wifi_untrusted',
        _ => 'error_waiting_for_host',
      };
      errorMessage.value = errorKey.value!.tr;
      // Keep the keep-alive service running (default onLinkLost is a no-op) so
      // the retry still works while the app is in the background.
      await handleLinkFailure();
    }
  }

  /// adb delivered a USB session key: a Mac has its tunnel up and is
  /// waiting. Dial now instead of when the pending retry fires; and whatever
  /// this side was in the middle of belongs to an attempt the Mac has
  /// already given up, so it ends here.
  void _onSessionKey() {
    if (settings.linkType != LinkType.usb) return;
    final p = phase.value;
    // Stopped by the user: the key waits for their Connect.
    if (p == ConnectionPhase.disconnected) return;
    // The dial in flight, or the live session, was made with this very key
    // (the Mac hands it over again when a dial and a delivery cross).
    if ((p.isConnecting || p.isActive) &&
        UsbSessionService.sameKey(_usb.key, _dialKey)) {
      return;
    }
    unawaited(restartLink());
  }

  /// Lets go of a dial still waiting for the Mac's answer.
  void _dropAwaitedAnswer() {
    final awaited = _awaitingAnswer;
    _awaitingAnswer = null;
    if (awaited != null && !awaited.done.isCompleted) {
      awaited.done.complete(false);
    }
  }

  /// The gate every inbound packet passes before anything looks at it. Over
  /// Wi-Fi the Mac proved itself in the TLS handshake. Over USB nothing is
  /// admitted until it has answered this connection's hello.
  @override
  bool admitPacket(Packet packet) {
    if (peerTrusted) return true;
    // 0xF3 — Host → Tablet: the answer to the hello. The only packet an
    // unproven peer can get a reaction to, and it gets one try.
    final awaited = _awaitingAnswer;
    if (awaited != null &&
        awaited.connection == socket.connectionId &&
        packet.type == PacketType.control &&
        packet.payload.isNotEmpty &&
        packet.payload[0] == UsbSessionService.answerCommand) {
      final key = awaited.key;
      final verified = key != null &&
          UsbSessionService.verifyAnswer(key, awaited.nonce, packet.payload);
      if (verified) {
        _trustedConnection = socket.connectionId;
        socket.trustPeer();
      }
      _awaitingAnswer = null;
      if (!awaited.done.isCompleted) awaited.done.complete(verified);
    }
    return false;
  }

  /// The keep-alive service stays (see [connect]); a dial parked on the Mac's
  /// answer has to learn that its link is gone, and the low-latency Wi-Fi
  /// lock goes until a session streams again: the redialling can go on for
  /// hours in the background, and below Android 10 the lock applies there
  /// too.
  @override
  Future<void> onLinkLost() async {
    _dropAwaitedAnswer();
    await KeepAliveChannel.setLowLatencyWifi(false);
  }

  @override
  void onClose() {
    _keySub?.cancel();
    super.onClose();
  }

  /// Where to dial over Wi-Fi. A probe goes to the broadcast addresses and,
  /// directly, to every address a paired Mac might have: the one the user
  /// typed, the ones the Mac reported when it was paired, and where it last
  /// answered. The first paired Mac to reply wins, so a typed or remembered
  /// address that has gone stale does not hide a Mac that can be found.
  ///
  /// With no reply at all it still dials an address it knows (UDP can be
  /// filtered where TCP is not), a different one on each attempt, starting
  /// with what the user typed: one address that leads nowhere must not stand
  /// in front of the others for ever.
  Future<({String address, int port})> _findWifiHost() async {
    await _pairing.ready;
    final hosts = _pairing.pairedHosts.toList();
    if (hosts.isEmpty) throw const LinkError('error_wifi_not_paired');

    final typed = settings.wifiHostAddress;
    final known = <String>[
      if (typed.isNotEmpty) typed,
      for (final h in hosts)
        if (h.lastAddress case final last? when last.isNotEmpty) last,
      for (final h in hosts) ...h.addresses,
    ];
    bool isPaired(DiscoveredHost h) => _pairing.hostForId(h.hostId) != null;
    final found = await _discovery.probe(
      until: isPaired,
      directTargets: [
        for (final address in known.toSet())
          if (InternetAddress.tryParse(address) case final ip?
              when ip.type == InternetAddressType.IPv4)
            ip,
      ],
    );
    final match = found.firstWhereOrNull(isPaired);
    if (match != null) {
      return (address: match.address.address, port: match.tcpPort);
    }
    final candidates = known.toSet().toList();
    if (candidates.isEmpty) throw const LinkError('error_wifi_host_not_found');
    return (
      address: candidates[_blindDials++ % candidates.length],
      port: linkPort,
    );
  }

  // Counts the dials made without a discovery reply, to take the known
  // addresses in turn.
  int _blindDials = 0;

  // This panel's top refresh rate — fixed per device, so queried once.
  int? _maxRefreshHz;

  /// The size the last HELLO reported (physical px, landscape): the shape
  /// of the stream the Mac sends back, which the iOS display view fits its
  /// texture to. Null before the first HELLO.
  final helloSize = Rxn<Size>();

  void _sendHandshake(int maxRefreshHz) {
    // HELLO: command + platform byte (0x02 Android, 0x03 iPhone, 0x04 iPad)
    // + the size this client renders (uint16 BE width, uint16 BE height,
    // physical px, landscape) + the panel's top refresh rate (Hz). The host
    // derives its capture resolution and the Max preset's rate from these,
    // so any connected device gets a pixel- and refresh-matched stream.
    final hello = _helloPanel();
    helloSize.value =
        Size(hello.panel.w.toDouble(), hello.panel.h.toDouble());
    socket.send(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: ClientHello.payload(
        platform: hello.platform,
        width: hello.panel.w,
        height: hello.panel.h,
        maxRefreshHz: maxRefreshHz,
        // Who this is, so the Mac knows it again on Wi-Fi whatever its
        // address (a Mac from before the tail ignores it).
        installId: settings.installId,
        // What the Mac calls it on its card (no device model is at hand
        // without a plugin; a tablet sends none).
        name: switch (hello.platform) {
          ClientPlatform.iphone => 'iPhone',
          ClientPlatform.ipad => 'iPad',
          ClientPlatform.android => '',
        },
      ),
    ));
  }

  /// This client's kind and the size it reports ([ClientHello.panelSize]).
  /// Android: the whole display, not the Flutter view: outside immersive
  /// mode on Android 14 and earlier the view leaves out the navigation bar,
  /// so the first HELLO after launch reported a shorter panel than later
  /// ones. iOS: the safe area (see [ClientHello.panelSize]).
  ({ClientPlatform platform, ({int w, int h}) panel}) _helloPanel() {
    // Via the binding (the same dispatcher at runtime) so tests can set it.
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    Size? display;
    var displayPoints = Size.zero;
    try {
      display = view.display.size;
      displayPoints = display / view.display.devicePixelRatio;
    } catch (_) {
      // The engine hasn't reported this view's display; use the view.
    }
    if (displayPoints.isEmpty) {
      displayPoints = view.physicalSize / view.devicePixelRatio;
    }
    final platform = ios
        ? ClientHello.iosPlatformFor(displayPoints)
        : ClientPlatform.android;
    return (
      platform: platform,
      panel: ClientHello.panelSize(
        platform: platform,
        display: display,
        window: view.physicalSize,
        padding: EdgeInsets.fromViewPadding(view.padding, 1),
      ),
    );
  }

  /// The P0 measurements, only in an `ES_MEASURE` build.
  final LinkMeasure? _measure =
      measureLink ? LinkMeasure(sink: _measureSink) : null;

  static void _measureSink(String line) {
    if (runsOnIos) {
      IosSystemChannel.log(line);
    } else {
      // ignore: avoid_print
      print('[measure] $line');
    }
  }

  @override
  void onRoundTrip(int rttUs) {
    if (measureLink) _measure!.roundTrip(rttUs);
  }

  // ─── iOS: foreground only ─────────────────────────────────────────────────

  // Hidden or paused since the last resume.
  bool _wentAway = false;

  /// On iOS the app is suspended within seconds of leaving the foreground,
  /// and nothing keeps it running (Android has its keep-alive service). So:
  ///
  ///  - `hidden`/`paused`: end the link at once, the way a lost link ends,
  ///    with no retry ([BaseConnectionManager.handleLinkFailure] with `retry:
  ///    false`, and a retry already armed is dropped). Closing the socket
  ///    lets the Mac tear down now instead of after its 6 s heartbeat
  ///    timeout, and nothing dials from the background (where a dial would
  ///    freeze mid-way, or be denied Local Network access).
  ///  - `resumed` after that: [restartLink] at once, whatever the phase
  ///    reads, unless the user had stopped it (`disconnected`).
  ///  - `inactive` alone (Control Centre, a notification) ends nothing, and
  ///    the `resumed` that follows it leaves a live link alone.
  ///  - `detached`: the base rule ([disconnect]).
  ///
  /// Android keeps the base rule for everything: it streams on in the
  /// background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ios) {
      super.didChangeAppLifecycleState(state);
      return;
    }
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _wentAway = true;
        if (phase.value == ConnectionPhase.disconnected) return;
        cancelPendingRetry();
        unawaited(handleLinkFailure(retry: false));
      case AppLifecycleState.resumed:
        final wentAway = _wentAway;
        _wentAway = false;
        final p = phase.value;
        if (p == ConnectionPhase.disconnected) return;
        if (!wentAway && (p.isActive || p.isConnecting)) return;
        unawaited(restartLink());
      case AppLifecycleState.inactive:
        return;
      case AppLifecycleState.detached:
        super.didChangeAppLifecycleState(state);
    }
  }

  // ─── Reverse remote (Mac controls tablet): capture this device's screen ────

  /// User tapped "Start screen sharing" — apply the params the host sent.
  @override
  Future<void> startScreenShare() async {
    final codec = _pendingCodec;
    if (codec == null || _capture == null) return;
    await _startReverseCapture(
      codec: codec,
      fps: _pendingFps,
      bitrateMbps: _pendingBitrateMbps,
    );
  }

  Future<void> _startReverseCapture({
    required CodecType codec,
    required int fps,
    required int bitrateMbps,
  }) async {
    final capture = _capture;
    if (capture == null) return; // iOS: nothing to capture with
    if (_captureFrameSub != null) return; // already capturing
    final granted = await capture.requestProjection();
    if (!granted) {
      log.w('Client: screen-capture consent denied');
      return;
    }
    needsScreenShare.value = false;
    isScreenSharing.value = true;
    final panel = _helloPanel().panel;
    final config = DisplayConfigModel.defaultConfig.copyWith(
      width: panel.w,
      height: panel.h,
      refreshRate: fps,
      bitrate: bitrateMbps * 1000000,
      codec: codec,
    );
    await capture.startCapture(config);
    _captureFrameSub = capture.frameStream.listen((nal) {
      // A capture can outlive its session (see `0xF7`): this tablet's screen
      // goes to a Mac that has proved itself, or nowhere.
      if (!peerTrusted) return;
      socket.send(Packet(
        type: PacketType.frameData,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        payload: nal,
      ));
    });
    log.i('Client: reverse capture streaming to Mac');
  }

  Future<void> _stopReverseCapture() async {
    await _captureFrameSub?.cancel();
    _captureFrameSub = null;
    await _capture?.stopCapture();
    isScreenSharing.value = false;
  }

  @override
  Future<void> onTeardown() async {
    _trustedConnection = null;
    _dropAwaitedAnswer();
    await _stopReverseCapture();
    await KeepAliveChannel.stop();
    // Also let go on a lost link (onLinkLost); harmless when already done.
    await KeepAliveChannel.setLowLatencyWifi(false);
    needsScreenShare.value = false;
    _pendingCodec = null;
  }

  @override
  void onRolePacket(Packet packet) {
    // FRAME_DATA is DisplayController's (through packetStream); measured
    // here, in an ES_MEASURE build, as it arrives.
    if (measureLink && packet.type == PacketType.frameData) {
      _measure!.frame(packet.timestampUs);
      return;
    }
    if (packet.type != PacketType.control || packet.payload.isEmpty) return;
    final p = packet.payload;

    // 0xFE — Host → Tablet: reload, request IDR to resume decode. Legacy: the
    // host no longer sends it (after a capture restart it forces its own IDR).
    if (p[0] == 0xFE) {
      requestIdr();
      return;
    }

    // 0xF6 — a Wi-Fi pairing (certificate + token), as it used to travel on
    // the USB link. Never believed, on any link: over Wi-Fi it would let
    // whoever is on the other end re-pair the tablet, and "the USB link" is
    // only whatever answered on 127.0.0.1:7001, which is adb while a Mac has
    // its tunnel up and any app on this tablet the rest of the time. A
    // pairing arrives through adb itself (WifiPairingChannel).
    if (p[0] == WifiPairingService.pairingCommand) {
      log.w('Client: ignored a Wi-Fi pairing sent over the link');
      return;
    }

    // 0xF9 + mode + direction — Host → Tablet: active session mode. In the
    // Mac-controls-tablet direction the tablet becomes the capture source.
    if (p.length >= 2 && p[0] == 0xF9) {
      final mode = p[1] < SessionMode.values.length
          ? SessionMode.values[p[1]]
          : SessionMode.extendedScreen;
      settings.setSessionMode(mode);
      if (p.length >= 3 && p[2] < RemoteDirection.values.length) {
        settings.setRemoteDirection(RemoteDirection.values[p[2]]);
      }
      return;
    }

    // 0xF8 + codec + fps + bitrate(Mbps) — Host → Tablet: the Mac wants to view
    // this screen. Stash the params and surface the "Start screen sharing"
    // button; the user starts it so the consent prompt fires in the foreground.
    if (p.length >= 4 && p[0] == 0xF8) {
      // iOS never captures its screen for the Mac (the host never asks a
      // Wi-Fi client either).
      if (_capture == null) return;
      _pendingCodec = p[1] == 1 ? CodecType.h265 : CodecType.h264;
      _pendingFps = p[2];
      _pendingBitrateMbps = p[3];
      if (!isScreenSharing.value) needsScreenShare.value = true;
      return;
    }

    // 0xF7 — Host → Tablet: stop capturing (remote session ending).
    if (p[0] == 0xF7) {
      _stopReverseCapture();
      needsScreenShare.value = false;
      _pendingCodec = null;
      return;
    }

    // 0xFF — Host → Tablet: request a fresh keyframe from our encoder.
    if (p[0] == 0xFF) {
      _capture?.requestIdr();
      return;
    }

    // 0xFC + codec_byte — Host → Tablet: the codec the host encodes with. This
    // is its only handler: it just stores the codec. DisplayController builds
    // its decoder from that setting and watches it, rebuilding whenever it
    // differs from the codec the running decoder was built with — e.g. when
    // the display opened (on `streaming`, before this arrives) with the codec
    // persisted from an earlier session.
    if (p.length >= 2 && p[0] == 0xFC) {
      settings.setCodec(p[1] == 1 ? CodecType.h265 : CodecType.h264);
      return;
    }

    // 0xFB + refreshRate — Host → Tablet: stream refresh rate (Hz). Shown in
    // the HUD and followed by DisplayController, which sets the panel's mode.
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
