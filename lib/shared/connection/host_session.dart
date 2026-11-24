import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/client_panel.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/packet_model.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
import 'package:extendedscreen/shared/models/touch_event_model.dart';
import 'package:extendedscreen/shared/platform/host_name.dart';
import 'package:extendedscreen/shared/protocol/annexb.dart';
import 'package:extendedscreen/shared/protocol/packet_codec.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/modules/extended_screen/host/screen_capture_channel.dart';
import 'package:extendedscreen/modules/extended_screen/host/input_inject_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_video_channel.dart';
import 'package:extendedscreen/shared/connection/adb_service.dart';
import 'package:extendedscreen/shared/connection/bitrate_adapter.dart';
import 'package:extendedscreen/shared/connection/encode_budget.dart';
import 'package:extendedscreen/shared/connection/pipeline_queue.dart';
import 'package:extendedscreen/shared/connection/usb_session_service.dart';
import 'package:extendedscreen/shared/connection/wifi_discovery_service.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';

/// One tablet's session on the HOST (macOS), as the hub
/// ([HostConnectionManager]) keeps one per tablet: its link to that tablet
/// and everything that runs for it. Over USB it binds a loopback port of its
/// own and has adb join the tablet's 127.0.0.1:7001 to it (adb reverse, from
/// the tablet's tcp:7001 to that port); it captures and encodes the screen via
/// ScreenCaptureKit/VideoToolbox and injects the touch/mouse/key events the
/// tablet sends. Stream settings are edited only on the host; the tablet's
/// HELLO reports its native panel size and top refresh rate, which the
/// session waits for (3 s timeout) before sizing and starting capture.
///
/// Over Wi-Fi ([LinkType.wifi]) there is no adb: the server listens on the
/// LAN with TLS, answers discovery probes, and treats the client as a
/// stranger until it presents the pairing token (see [WifiPairingService]).
///
/// Over USB the client is a stranger too, until it proves it holds the key
/// this attempt handed to the tablet app through adb (see
/// [UsbSessionService]): anything on the tablet can dial the tunnel, and
/// anything on this Mac the loopback server.
///
/// It keeps its own copy of the link's state machine (phase, attempts,
/// retry, heartbeat; [BaseConnectionManager]), so ending or failing one
/// tablet's session never touches another's. It is never registered with
/// Get, so it adds no app-lifecycle observer: the hub forwards what it
/// needs, along with the native plugins' callbacks for it
/// ([captureNeedsRestart], [frameRateChanged], [displayBoundsChanged],
/// [decoderWantsKeyframe], [decoderFailed], [decoderReady],
/// [captureMismatch], [captureMatched], [onTabletScreenRestored]).
///
/// With a [budget] its capture starts only once the budget has admitted it
/// (see [EncodeBudget]), at what the budget grants; without one (tests that
/// build a session alone) it captures what the preset asks for, as one
/// tablet always has.
class HostSession extends BaseConnectionManager {
  HostSession({
    required this.key,
    required this.link,
    this.serial,
    SessionChoice? choice,
    required PipelineQueue pipeline,
    TabletTunnels? tunnels,
    VirtualDisplays? displays,
    AdbService? adb,
    EncodeBudget? budget,
    int Function() cap = _oneTablet,
    this.vdSerial = 1,
    this.vdName = 'Extended Screen',
    this.beside = false,
    super.socket,
    super.port,
  }) : assert(link == LinkType.wifi || serial != null),
       assert(!beside || link == LinkType.wifi),
       choice = choice ?? Get.find<SettingsService>().nextChoice,
       _pipeline = pipeline,
       _tunnels = tunnels,
       _displays = displays,
       _adb = adb ?? Get.find<AdbService>(),
       _budget = budget,
       _cap = cap {
    _phaseWorker = ever<ConnectionPhase>(phase, (p) {
      if (p != ConnectionPhase.streaming) return;
      // Live again: the next failure is a first one.
      _failures = 0;
      // A capture left running from the last session can send its picture
      // before this one is live; the remembered choice waits for that too.
      _darkenTabletIfChosen();
    });
    budget?.addListener(_budgetChanged);
  }

  static int _oneTablet() => 1;

  /// The hub's name for this session: the adb serial over USB, 'wifi' for
  /// the one Wi-Fi session.
  final String key;

  /// How this session reaches its tablet. Fixed for its life.
  final LinkType link;

  /// The Wi-Fi session the hub runs beside its USB tablets (Listen on
  /// Wi-Fi): it waits for whichever paired device dials in, for as long as
  /// the toggle is on, and holds a place on the encoder only while that
  /// device is there. Its teardown gives that place up for good
  /// ([_releaseBudget]) rather than keeping it for the next attempt: the
  /// device it was for may be in a pocket, and the next to dial in is an
  /// ordinary admission. Fixed for its life; only over Wi-Fi.
  final bool beside;

  /// The peer of the current connection has proved itself ([peerTrusted]),
  /// as an observable: set when it does, cleared at teardown. The hub reads
  /// it to tell a [beside] session that only listens (anything on the LAN
  /// can finish a TLS handshake and keep it waiting) from one a device is
  /// on.
  final trusted = false.obs;

  /// The tablet's adb serial (USB), fixed for the session's life: its
  /// retries look for this device and no other. Null over Wi-Fi.
  final String? serial;

  /// What this session was made to be (its mode and, for remote control,
  /// which side drives), fixed for its life: every attempt, retry and
  /// reconnect runs as this, whatever the settings say by then. There is no
  /// setter: a tablet's mode changes by ending its session and making a new
  /// one for it (the hub's `changeMode`), so no session ever runs as two
  /// things and each teardown undoes what its own attempt built.
  ///
  /// The hub gives every session it makes one. A session built without one
  /// (tests) takes what Home's selectors say as it is made
  /// ([SettingsService.nextChoice]), and keeps that.
  final SessionChoice choice;

  /// This session's id in the native capture, input and decode plugins:
  /// its virtual display, stream, encoder, mouse state and remote decoder are
  /// kept under it, and its encoded frames come back tagged with it. Never
  /// reused within a run of the app, so a late callback for an old one
  /// finds nothing.
  final int nativeId = _nextNativeId++;
  static int _nextNativeId = 1;

  final PipelineQueue _pipeline;
  final TabletTunnels? _tunnels;
  final AdbService _adb;

  // Every session's virtual display, as the hub keeps track of them (see
  // [VirtualDisplays]); null for a session built alone.
  final VirtualDisplays? _displays;

  // Ordered rebuilds this session has asked for in a row because its first
  // frame showed another display ([captureMismatch]); a first frame that
  // shows its own clears it ([captureMatched]).
  int _wrongDisplayRebuilds = 0;
  static const _maxWrongDisplayRebuilds = 2;

  // What the capture last started was asked to show (its config's mode):
  // a first frame is judged as that capture's, whatever the settings say
  // by the time it arrives.
  DisplayMode? _capturedMode;
  late final Worker _phaseWorker;

  // The encoder every session shares, and how many tablets it may take at
  // once (the hub's rule, read at each admission).
  final EncodeBudget? _budget;
  final int Function() _cap;

  /// The serial number and name this session's virtual display is created
  /// with (Extend): macOS keeps a display's place on the desktop by its
  /// serial, and shows its name in System Settings. Fixed for the session's
  /// life ([SettingsService.vdSerialFor], [SettingsService.vdNameFor]).
  final int vdSerial;
  final String vdName;

  /// The encoder had no room for this tablet ([CaptureLimit]): the session
  /// is in `error` with no retry armed, until the next [connect] (the user's
  /// Retry) tries again.
  final refused = false.obs;

  /// What this session's capture got from the [EncodeBudget] while it runs:
  /// its encoded size, the rate the encoder runs at, and whether another
  /// tablet shares the encoder. Null with no capture (or no budget).
  final granted = Rxn<GrantedCapture>();

  /// What this session's capture start reported (the display it captures,
  /// whether Extend fell back to the main display) while that capture runs;
  /// null with none. The debug Loopback preview shows it.
  final captured = Rxn<CaptureStart>();

  /// Something about this session's capture its card should say, as a
  /// translation key: Extend fell back to mirroring
  /// (`error_extend_unavailable`), the capture may show another display
  /// (`error_extend_wrong_display`, or for a capture of the Mac's own
  /// screen `error_mirror_wrong_display`), a rebuild found the encoder full
  /// (`error_encode_limit`), or, for a tablet the Mac views, the Mac has no
  /// decoder for its picture (`error_remote_decoder`). Null when there is
  /// nothing to say; cleared by [connect], by a capture that starts and,
  /// the last one, by a decoder that is made again ([decoderReady]).
  final notice = RxnString();

  // The hub has ended this session ([retire]): it never connects again.
  bool _retired = false;

  /// The hub has ended this session for good ([retire]).
  bool get isRetired => _retired;

  /// Whether this session may still change its tablet's adb rule and screen
  /// hold: not once the hub has made a newer session for that tablet (an
  /// adb call of this one's that returns late must not undo the newer
  /// one's tunnel).
  bool _ownsTunnel(String serial) => _tunnels?.owns(serial, this) ?? true;

  /// Runs [operation] on [serial]'s adb rule in turn with every other
  /// session's for that tablet, in the order they were asked for.
  Future<T> _onTunnel<T>(String serial, Future<T> Function() operation) =>
      _tunnels?.run(serial, operation) ?? operation();

  /// What this session is (mode, direction, display mode), as of the start
  /// of its last connect attempt; before its first, what an attempt begun
  /// now would be.
  SessionSpec get spec => _spec ?? _specNow();
  SessionSpec? _spec;

  /// What an attempt begun now runs as: this session's [choice] on its link
  /// with the display mode set now.
  SessionSpec _specNow() =>
      SessionSpec.from(choice, link, displayMode: settings.displayMode);

  /// Whether this attempt's HELLO named a device that is not Android (an
  /// iPhone or iPad), which can only drive the Mac whatever its [choice].
  bool get isApple =>
      platform == helloPlatformIphone || platform == helloPlatformIpad;

  /// The mode and direction this session runs as ([spec]'s: what its
  /// [choice] comes to on its link), for the UI.
  SessionChoice get effectiveChoice => SessionChoice(spec.mode, spec.direction);

  /// The tablet's panel: what its HELLO reported this attempt, else what it
  /// reported last time, else the last panel any tablet reported.
  ClientPanel get panel =>
      _panel ?? settings.clientPanelFor(key) ?? settings.lastClientPanel;
  ClientPanel? _panel;

  /// The platform byte of this attempt's HELLO (`p[1]`:
  /// [helloPlatformAndroid], `0x03` iPhone, `0x04` iPad); null before it,
  /// for a HELLO too old to carry one, or for a value this build does not
  /// know (taken for Android, as before).
  int? platform;

  /// HELLO's platform byte for an Android client.
  static const helloPlatformAndroid = 0x02;

  /// HELLO's platform bytes for the iOS client on an iPhone and an iPad.
  static const helloPlatformIphone = 0x03;
  static const helloPlatformIpad = 0x04;

  /// The bitrate this session's capture was started at (its preset at its
  /// panel), which the Wi-Fi adaptation moves from.
  int _captureBitrate = 0;

  // The native plugins' callbacks reach this session through the hub, and
  // only between the start of its capture (or decoder) and its teardown:
  // a callback landing after that must not resurrect anything.
  bool _captureWired = false;
  bool _remoteWired = false;

  // The rate this session's encoder last reported (frameRateChanged) since
  // its capture start was sent; null until it reports one.
  int? _reportedFps;

  // Consecutive failures since the session was last live: how long the next
  // retry waits ([nextRetryDelay]).
  int _failures = 0;
  static final _jitter = math.Random();
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

  /// The first retry after a second, as always. Over USB, if that fails too,
  /// after 2, 5 and then every 10 s (each ±20%), until the session is live
  /// again: when adb restarts it drops every tablet's tunnel at once, and
  /// the retries must not all hit it together, each with its own `adb
  /// reverse`, once a second. Over Wi-Fi the Mac only listens again, and
  /// the tablet redials: always after a second.
  @override
  Duration nextRetryDelay() {
    final failures = _failures++;
    if (failures == 0 || link == LinkType.wifi) return reconnectDelay;
    const steps = [2, 5, 10];
    final seconds = steps[math.min(failures - 1, steps.length - 1)];
    return Duration(
        milliseconds: (seconds * 1000 * (0.8 + 0.4 * _jitter.nextDouble()))
            .round());
  }

  /// The hub is ending this session for good: from now on [connect] does
  /// nothing, whoever calls it (a retry timer, a resume), and its place on
  /// the encoder goes at once, so a tablet picked while this one's teardown
  /// still runs is not planned around it.
  void retire() {
    _retired = true;
    _releaseBudget();
  }

  /// Lets go of what the session holds outside itself once the hub has
  /// ended it for good (after its [disconnect]).
  void dispose() {
    _phaseWorker.dispose();
    _stopBitrateAdaptation();
    _releaseBudget();
    _budget?.removeListener(_budgetChanged);
    _displays?.removed(this);
    _captureWired = false;
    _remoteWired = false;
  }

  /// Texture id of the decoded tablet stream (reverse remote: Mac controls the
  /// tablet). Null unless a reverse-remote session is live; the remote-view
  /// widget renders a `Texture` from it.
  final remoteTextureId = Rxn<int>();

  /// Reverse remote: the tablet's picture has started to arrive this session
  /// (its user approved screen capture), so its panel may go dark now.
  final tabletStreaming = false.obs;

  /// Reverse remote: the tablet's panel is held off ([setTabletScreenOff]).
  final tabletScreenOff = false.obs;

  /// A [setTabletScreenOff] is under way, the user's or the remembered
  /// choice's: the toggle waits for it, and another call is refused.
  final changingTabletScreen = false.obs;

  /// Bumped by every [setTabletScreenOff] and by teardown: a call that finds
  /// it moved on after its await was superseded, and changes nothing.
  int _tabletScreenSeq = 0;

  // Actual display bounds (updated after capture starts in extend/mirror mode).
  Map<String, double> _displayBounds = {'x': 0, 'y': 0, 'w': 0, 'h': 0};

  StreamSubscription? _frameSub;

  // A capture rebuild is under way; [_restartAgain]: another was asked for
  // meanwhile and runs once it ends. That second request matters: a rebuild
  // started as the displays went to sleep (ScreenCaptureKit stops the stream
  // when they do) cannot work, and the wake's request may come while it is
  // still trying.
  bool _restarting = false;
  bool _restartAgain = false;

  // Bumped by every rebuilt capture start ([startPipelineOp]), and taken by
  // each restart request ([_restartRequestedGen]): a round finding it moved
  // on since the latest request was rebuilt after that request already (by
  // the hub's wake, which rebuilds every tablet), and has nothing to do.
  int _pipelineGen = 0;
  int _restartRequestedGen = 0;

  // Completed when the client's HELLO arrives (it carries the panel size the
  // capture resolution is derived from).
  Completer<void>? _helloReceived;

  bool get _wifiSession => link == LinkType.wifi;

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

  // Starting, restarting and stopping the media pipeline never overlap, for
  // this session or any other: each waits for the one before it
  // ([PipelineQueue]).
  Future<T> _exclusive<T>(Future<T> Function() operation) =>
      _pipeline.run(operation);

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

  /// Whether the encoder's bitrate is being fitted to the link right now
  /// (the tests' view of it, through the hub).
  bool get adaptingBitrate => _bitrateTimer?.isActive ?? false;

  /// How often the link's queue is looked at. Well inside
  /// [BitrateAdapter.window], so the smallest of several samples is judged.
  static const _bitrateSampleEvery = Duration(milliseconds: 50);

  /// Choosing what to connect is the hub's ([HostConnectionManager]).
  @override
  Future<void> autoConnect() async {}

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

  /// Connects this session's tablet ([serial] is ignored: the session's own
  /// is fixed). Only from `disconnected` or `error`, and not while a
  /// [disconnect] tears down (a [reconnect]'s, typically: its phase still
  /// reads `error` then, and the card offers Retry): the [reconnect] connects
  /// once that is done, and a connect started beside it would run as a
  /// second attempt on the same session.
  @override
  Future<void> connect({String? serial}) async {
    if (_retired ||
        isStopping ||
        phase.value.isConnecting ||
        phase.value.isActive) {
      return;
    }
    final attempt = currentAttempt;
    final seq = beginConnect();
    refused.value = false;
    notice.value = null;
    errorKey.value = null;
    final wifi = _wifiSession;
    _spec = _specNow();
    _panel = null;
    platform = null;
    _authedConnection = null;
    trusted.value = false;
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
        final listing = await _adb.listDevicesOrNull();
        if (isCancelled(attempt)) return;
        final devices = listing ?? const <DeviceModel>[];
        availableDevices.value = devices;
        // adb itself could not list: that says nothing about the tablet.
        if (listing == null) throw Exception('No ADB device detected');
        // This session's tablet and no other: a retry while it is unplugged
        // waits for it instead of taking whatever else is attached. Said
        // the same way when nothing at all is attached (it was the only
        // one), so the device poll retries it as soon as it is back.
        final device =
            devices.firstWhereOrNull((d) => d.serial == this.serial);
        if (device == null) {
          // Its place on the encoder stays, but holds no room for the
          // others while the tablet is not there ([EncodeBudget.suspend]).
          _budget?.suspend(nativeId);
          throw const LinkError('error_device_gone');
        }
        _budget?.resume(nativeId);
        activeDevice.value = device;
        log.i('Host: using device ${device.serial}');

        setPhase(ConnectionPhase.portForwarding);
        // A port of this session's own on the Mac, which adb joins the
        // tablet's 127.0.0.1:[linkPort] to: the port says which tablet
        // dialled (the key still proves it).
        await socket.startServer(BaseConnectionManager.host, 0,
            untrustedPayloadLimit: _untrustedPayloadLimit);
        if (isCancelled(attempt)) return abandon();
        final macPort = socket.serverPort;
        if (macPort == null) throw Exception('Port forwarding failed');
        tunnelled = device.serial;
        // Reverse tunnel: tablet tcp:7001 → this Mac's tcp:<macPort>. Once
        // per attempt (see below).
        final forwarded = await _onTunnel(
            device.serial,
            () => _adb.reverseForward(
                  serial: device.serial,
                  localPort: macPort,
                  remotePort: linkPort,
                ));
        if (isCancelled(attempt)) return abandon();
        if (!forwarded) throw Exception('Port forwarding failed');

        setPhase(ConnectionPhase.handshaking);
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
        log.w('Host: no HELLO from client — using last-known panel $panel');
      }
      if (isCancelled(attempt)) return abandon();

      // A tablet the Mac viewed can still be capturing its screen: the stop
      // its last session sent never arrived if that link was already dead,
      // and the tablet stops nothing by itself when a link drops. A session
      // in which the Mac views nothing says it again, once per attempt and
      // before the pipeline starts (so also when that start fails), or the
      // tablet would go on encoding and sending its screen beside this
      // session's own mode. With no capture running the tablet only takes
      // back its offer to start one.
      if (!spec.isReverseRemote) _sendStopCapture();

      // Start the media pipeline. Reverse-remote (Mac controls tablet) decodes
      // the tablet's stream; every other mode captures + encodes the Mac. Both
      // are non-fatal so the link stays up even if the pipeline can't start,
      // except for a tablet the encoder has no room for beside the others.
      try {
        await _exclusive(() => spec.isReverseRemote
            ? _startRemoteReceive(attempt)
            : _startCapture(attempt));
      } on CaptureLimit {
        rethrow;
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
        // last-used device. Its virtual display's serial is kept from now
        // on too, so the tablet keeps its place on the desktop next time,
        // and so is the mode it was picked for.
        if (device != null) {
          await settings.rememberDevice(device.serial,
              model: device.model, vdSerial: vdSerial, choice: choice);
          if (isCancelled(attempt)) return;
        }
        _usbSessionSeq = seq;
        unawaited(_offerWifiPairing(seq));
      }
      log.i('Host: link live (streaming)');
    } catch (e, st) {
      if (isCancelled(attempt)) return; // cancelled mid-attempt: no retry
      errorMessage.value = e.toString();
      errorKey.value = e is LinkError ? e.key : null;
      if (e is CaptureLimit) {
        // Retrying would only make and remove a virtual display, and take
        // the tunnel up and down, every few seconds for nothing: the session
        // ends (its teardown removes both) and waits for the user's Retry.
        // Its place on the encoder goes too: the user's Retry is a new
        // tablet's admission.
        log.w('Host: no room on the encoder for this tablet — not started');
        refused.value = true;
        _releaseBudget();
        await handleLinkFailure(retry: false);
        return;
      }
      log.e('Host connection failed', e, st);
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
  /// Nothing is offered on a Wi-Fi session, nor to a synthetic tablet
  /// (debug builds), which has no app to pair.
  Future<void> _offerWifiPairing(int seq) async {
    if (key.startsWith(syntheticSerialPrefix)) return;
    try {
      final payload = await _pairing.offerPayload();
      final device = activeDevice.value;
      if (!isLatestConnect(seq) ||
          _wifiSession ||
          !phase.value.isActive ||
          device == null) {
        return;
      }
      final delivery = await _adb.deliverWifiPairing(
        serial: device.serial,
        payload: payload,
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

  /// This Mac's Wi-Fi identity was discarded (Settings → Reset Wi-Fi
  /// pairing; the hub resets it, then tells every session).
  ///
  /// A Wi-Fi server that is up still presents the old certificate, and a
  /// tablet on it got in with the old token, so that session or wait ends and
  /// the host listens again with the new identity. A live USB session carries
  /// on, and its tablet is handed the new identity at once.
  Future<void> identityWasReset() async {
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
    if (tunnelled != null && _ownsTunnel(tunnelled)) {
      await _onTunnel(tunnelled,
          () => _adb.removeForward(serial: tunnelled, remotePort: linkPort));
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
  ///
  /// With a budget, the capture starts at what it grants, and throws
  /// [CaptureLimit] when it has no room for this tablet. A start that throws
  /// after it was admitted gives its share back but keeps its place
  /// ([EncodeBudget.reserve]): a failed start never holds the others down,
  /// and the next start (a wake's rebuild, a reconnect, a retry) is a
  /// return, never refused by the cap and planned before any newcomer.
  Future<void> _startCapture(int attempt) async {
    bool stale() => isCancelled(attempt);
    if (stale()) return;
    // From here the native wake/stream-stop callbacks the hub routes here
    // may rebuild the pipeline (a wake, or this session's stream stopping),
    // display rearrangements refresh the bounds, and the Max preset's rate
    // changes are announced (see the routing methods below).
    _captureWired = true;

    // Remote-control sessions always mirror the real desktop; extended-screen
    // honours the user's Extend/Mirror choice (both in [spec]).
    var config = settings.captureConfigFor(panel, spec);

    await _capture.requestPermission();
    await _input.requestAccessibility();
    if (stale()) return;

    // Admitted with no await since the check above: a teardown that has
    // begun bumped the attempt first, and one that begins later gives this
    // share up (keeping the place, or not) before its first await, so the
    // share is never left behind.
    final budget = _budget;
    var shared = false;
    if (budget != null) {
      shared = budget.hasOthers(nativeId);
      final grant = budget.admit(nativeId, config, cap: _cap());
      _pushCeilings(grant.othersChanged);
      config = grant.config;
      if (grant.reducedResolution) {
        log.w('Host: encoder shared — capturing at '
            '${config.encodedWidth}×${config.encodedHeight}');
      }
    }
    notice.value = null;
    try {
      await _startAdmitted(config, stale);
    } on PlatformException catch (e) {
      _displays?.startFailed(this);
      _reserveBudget();
      // Another tablet's encoder is what is in the way: this one can't run
      // beside it. Alone, an encoder that can't be had is the same failure
      // it always was (the link stays up with no picture).
      if (shared && (e.code == 'ENCODER_BUSY' || e.code == 'NO_ENCODER')) {
        throw const CaptureLimit();
      }
      rethrow;
    } catch (_) {
      _displays?.startFailed(this);
      _reserveBudget();
      rethrow;
    }
    // A start that returned early (its session ended) asks for no round
    // either; one that asked has nothing due any more.
    _displays?.startFailed(this);
  }

  /// The rest of [_startCapture], once [config] is what the budget granted.
  Future<void> _startAdmitted(
      DisplayConfigModel config, bool Function() stale) async {
    _captureBitrate = config.bitrate;
    _grant(config);

    if (config.mode == DisplayMode.extend) {
      // Said before it is made: with another session's display there, the
      // hub rebuilds them all in order, asked once the capture has started
      // on it (below) and run once this start is over.
      _displays?.adding(this);
      final display = await _capture.createVirtualDisplay(config,
          session: nativeId, serialNum: vdSerial, name: vdName);
      if (display.displayId == 0) {
        _displays?.removed(this);
        log.w('Host: virtual display not made — capture mirrors the main '
            'display');
        notice.value = 'error_extend_unavailable';
      } else if (!display.applied) {
        log.w('Host: virtual display settings not applied — capture falls '
            'back to the main display if it never appears');
      }
      if (stale()) return;
    }
    // The ceiling as it is now, not as it was at admission: another tablet
    // that left while the display was being made raised it, and the push
    // that told the encoder so would be overwritten by this start's own.
    // Read with no await before the call, so a later change follows it.
    final ceiling = _budget?.ceilings()[nativeId];
    if (ceiling != null) config = config.withFpsCeiling(ceiling);
    final fps = _grant(config);
    // A rate the encoder reports from here on (a ceiling raised during the
    // start) is newer than [fps], and is what the tablet is told.
    _reportedFps = null;
    _capturedMode = config.mode;
    final started = await _capture.startCapture(config, session: nativeId);
    if (stale()) return;
    captured.value = started;
    if (started.fellBack) {
      // The plugin let the display go: it never showed up.
      _displays?.removed(this);
      log.w('Host: Extend unavailable — mirroring display ${started.displayId}');
      notice.value = 'error_extend_unavailable';
    }
    // Its capture runs on the display it made: if that one was made beside
    // another's, the hub's ordered rebuild is asked for now (and runs once
    // this start is over). A start that threw or fell back asks nothing.
    _displays?.started(this);

    // Fetch the captured display's bounds so touch injection lands on the
    // screen the tablet shows.
    _displayBounds = await _capture.getDisplayBounds(session: nativeId);
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

    // Tell the client the capture refresh rate so its display mode + HUD
    // match: the encoder's own report if one came during the start.
    _announceRefreshRate(_reportedFps ?? fps);

    // Sync the overlay/HUD toggles so a fresh client matches the host.
    sendUiFlags();

    _streamHevc = config.codec == CodecType.h265;
    _resyncing = false;
    if (_wifiSession) _limitSendBufferFor(config.bitrate);

    // Forward each encoded NAL unit from native → socket as FRAME_DATA.
    _frameSub = _capture.framesFor(nativeId).listen(_forwardFrame);
    if (_wifiSession) _startBitrateAdaptation(config.bitrate);
  }

  /// The rate [config] starts at (its own, or lower while the encoder is
  /// shared), which [granted] says along with its size. Returns the rate.
  int _grant(DisplayConfigModel config) {
    final ceiling = config.fpsCeiling;
    final fps = ceiling == null
        ? config.refreshRate
        : math.min(config.refreshRate, ceiling);
    final budget = _budget;
    if (budget != null) {
      granted.value = GrantedCapture(
        width: config.encodedWidth,
        height: config.encodedHeight,
        fps: fps,
        shared: budget.hasOthers(nativeId),
      );
    }
    return fps;
  }

  /// Gives this session's place on the encoder up for good (the hub ended
  /// it, or the encoder refused it), and lets the others' encoders climb
  /// into the room it leaves; [captured] goes with it. Synchronous, so it
  /// can run before a teardown's first await.
  void _releaseBudget() {
    granted.value = null;
    captured.value = null;
    _pushCeilings(_budget?.release(nativeId) ?? const {});
  }

  /// This session's capture stopped (or never started) while the session
  /// goes on: its share of the encoder goes to the others at once, but it
  /// keeps its place for its next start ([EncodeBudget.reserve]), so a
  /// retry, a settings reconnect or a wake's rebuild is never refused by a
  /// lowered cap, nor beaten to the room by another tablet's admission.
  void _reserveBudget() {
    granted.value = null;
    captured.value = null;
    _pushCeilings(_budget?.reserve(nativeId) ?? const {});
  }

  /// Hands each session's new ceiling (by native id) to its running encoder:
  /// a live change, no new encoder and no keyframe. Each encoder reports the
  /// rate it lands on through onFrameRateChanged, which tells its tablet.
  void _pushCeilings(Map<int, int> ceilings) {
    for (final MapEntry(key: id, value: fps) in ceilings.entries) {
      unawaited(_capture.setFrameRateCeiling(fps, session: id));
    }
  }

  /// Another session joined or left the encoder: whether it is shared now.
  void _budgetChanged() {
    final g = granted.value;
    final budget = _budget;
    if (g == null || budget == null || !budget.contains(nativeId)) return;
    granted.value = g.copyWith(shared: budget.hasOthers(nativeId));
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
      _capture.setBitrate(next, session: nativeId);
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
          _capture.requestIdr(session: nativeId);
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
      64 * 1024, (streamBitrate.value ?? _captureBitrate) ~/ 8 * 3 ~/ 100);

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
    if (!phase.value.isActive || spec.isReverseRemote) return;
    _restartRequestedGen = _pipelineGen;
    if (_restarting) {
      _restartAgain = true;
      return;
    }
    _restarting = true;
    // Every round belongs to the session this was asked for: one that ends
    // meanwhile stops the rounds, and its successor is left alone.
    final attempt = currentAttempt;
    try {
      do {
        _restartAgain = false;
        try {
          await _exclusive(() async {
            // The session may have ended while this waited its turn.
            if (isCancelled(attempt) || !phase.value.isActive) return;
            // Or a rebuild started after the latest request (the hub's, for
            // a wake) has already done what it asked for.
            if (_pipelineGen != _restartRequestedGen) return;
            log.w('Host: rebuilding capture pipeline after wake/stream-stop');
            await stopPipelineOp();
            await startPipelineOp(attempt);
          });
        } catch (e, st) {
          rebuildFailed(e, st);
        }
      } while (_restartAgain && !isCancelled(attempt) && phase.value.isActive);
    } finally {
      _restarting = false;
      _restartAgain = false;
    }
  }

  /// Runs the rebuild a wake or a stopped stream asks for, as they do.
  @visibleForTesting
  Future<void> rebuildCapture() => _restartCapture();

  /// Whether a wake has a capture of this session's to rebuild: one started
  /// (and not torn down) in a live session that encodes on this Mac.
  bool get canRebuild =>
      _captureWired && phase.value.isActive && !spec.isReverseRemote;

  /// Whether this session's capture runs (or has just started, its connect
  /// about to go live) and is not being torn down.
  bool get _capturing =>
      _captureWired &&
      (phase.value.isActive || phase.value == ConnectionPhase.configuring);

  /// Whether the hub's rebuild of the display set makes this session's
  /// virtual display and capture again: an Extend capture with its own
  /// display, in a session the hub has not ended. One whose connect has
  /// just started its capture counts (it may be the one that joined).
  bool get rebuildsDisplay =>
      !_retired &&
      _capturing &&
      !spec.isReverseRemote &&
      (_displays?.holds(this) ?? false);

  /// Whether the hub's repair round makes this session's capture again: a
  /// capture of the main display (Mirror, which every remote-control
  /// session whose tablet drives the Mac is), in a session the hub has not
  /// ended. One whose connect has just started its capture counts: its
  /// first frame can arrive before it is live.
  bool get repairsMirror =>
      !_retired &&
      _capturing &&
      !spec.isReverseRemote &&
      _capturedMode == DisplayMode.mirror;

  /// The first half of a rebuild: this session's capture and virtual
  /// display go. Only from inside an operation already running on the
  /// pipeline queue (this session's rebuild, or the hub's for a wake, which
  /// stops every tablet before starting any); it never queues anything.
  Future<void> stopPipelineOp() async {
    // The new encoder starts at the preset's bitrate, and so does the
    // adaptation that _startCapture sets up for it.
    _stopBitrateAdaptation();
    await _frameSub?.cancel();
    _frameSub = null;
    await _capture.stopCapture(session: nativeId);
    await _capture.removeVirtualDisplay(session: nativeId);
    _displays?.removed(this);
  }

  /// The second half: the capture starts again for the session [attempt]
  /// (nothing if that one has ended), and the tablet gets a keyframe to
  /// begin from. Only from inside a queued operation, like [stopPipelineOp].
  Future<void> startPipelineOp(int attempt) async {
    if (isCancelled(attempt) || !(phase.value.isActive || _capturing)) {
      return;
    }
    // Before the first await: a request made from here on is about this
    // capture, and gets a round of its own.
    _pipelineGen++;
    await _startCapture(attempt);
    if (isCancelled(attempt)) return;
    await _capture.requestIdr(session: nativeId);
    log.i('Host: capture pipeline rebuilt');
  }

  /// A rebuild of this session's capture threw (on its own or in the hub's
  /// wake): logged, and when the encoder is what is missing, said on its
  /// card. The session stays up either way (its link is fine).
  void rebuildFailed(Object e, StackTrace st) {
    // Typically the displays are asleep: the wake asks again.
    log.e('Host: capture restart failed', e, st);
    // Or another tablet took the encoder meanwhile.
    if (e is CaptureLimit ||
        (e is PlatformException && e.code == 'ENCODER_BUSY')) {
      notice.value = 'error_encode_limit';
    }
  }

  // ─── Native callbacks, routed here by the hub ─────────────────────────────

  /// The Mac woke (with one session; with several the hub rebuilds them
  /// all itself), or this session's stream stopped with an error: rebuild
  /// the capture pipeline.
  void captureNeedsRestart() {
    if (_captureWired) _restartCapture();
  }

  /// USB: adb dropped this tablet's transport while this attempt waits for
  /// the tablet to dial in (the hub's listing missed it, or lists it under
  /// another transport id): the reverse rule went with the transport, so
  /// the tablet can never reach this attempt's port. The attempt starts
  /// again at once, setting the rule up anew, or finding the tablet gone
  /// (`error_device_gone`, retried as soon as it is listed again).
  void tunnelLost() {
    if (link != LinkType.usb || phase.value != ConnectionPhase.handshaking) {
      return;
    }
    log.w('Host: $key left adb while waiting for it to dial in — '
        'starting the attempt again');
    unawaited(restartLink());
  }

  /// Displays were rearranged (or another session's display came or went):
  /// re-fetch the bounds input is mapped through.
  void displayBoundsChanged() {
    if (_captureWired) _refreshDisplayBounds();
  }

  /// Max preset: this session's encoder changed its rate (down under load,
  /// back up once it recovers) — tell the tablet so its display mode + HUD
  /// follow (same 0xFB it gets at stream start).
  void frameRateChanged(int fps) {
    if (!_captureWired) return;
    _reportedFps = fps;
    _announceRefreshRate(fps);
    granted.value = granted.value?.copyWith(fps: fps);
  }

  /// This session's capture came out in another shape than the display it
  /// asked for on its first frame: it may be showing another display
  /// (Apple bug FB17797423).
  ///
  /// Extend (its own virtual display, which has the frame's shape, came
  /// out with bars): with another session's display there, the hub
  /// rebuilds the whole set in order, at most [_maxWrongDisplayRebuilds]
  /// times in a row for this session; after that, or alone (a display of
  /// another shape cannot be ours, but one alone has nothing to be confused
  /// with), it is only said, on its card.
  ///
  /// Mirror (the picture has not the main display's shape): while any
  /// virtual display exists, or a rebuild round that does not make this
  /// capture again has one down for a moment
  /// ([VirtualDisplays.besideDisplays]), the hub runs a repair round
  /// ([VirtualDisplays.requestMirrorRepair]): every display goes, this
  /// capture starts first, then the Extend ones. The same limit applies;
  /// past it, or with no virtual display to be mistaken for the Mac's
  /// screen, it is only said (`error_mirror_wrong_display`).
  void captureMismatch() {
    if (!_captureWired) return;
    final displays = _displays;
    // A round already asked for (this capture's own join included), or
    // under way and not yet past this session, makes this capture again:
    // it neither asks for another nor counts against the limit.
    if (displays != null && displays.willRestart(this)) {
      log.w('Host: $key may be showing another display — the round already '
          'due makes it again');
      return;
    }
    if (_capturedMode == DisplayMode.mirror) {
      if (displays != null &&
          displays.besideDisplays(this) &&
          _wrongDisplayRebuilds < _maxWrongDisplayRebuilds &&
          displays.requestMirrorRepair(this)) {
        _wrongDisplayRebuilds++;
        log.w('Host: $key may be showing a virtual display instead of the '
            "Mac's — taking every display down and starting it first "
            '($_wrongDisplayRebuilds of $_maxWrongDisplayRebuilds)');
        return;
      }
      notice.value = 'error_mirror_wrong_display';
      return;
    }
    if (displays != null &&
        displays.sharedWith(this) &&
        _wrongDisplayRebuilds < _maxWrongDisplayRebuilds &&
        displays.requestRebuild()) {
      _wrongDisplayRebuilds++;
      log.w('Host: $key may be showing another display — rebuilding every '
          'display in order ($_wrongDisplayRebuilds of '
          '$_maxWrongDisplayRebuilds)');
      return;
    }
    notice.value = 'error_extend_wrong_display';
  }

  /// This session's capture showed the display it asked for on its first
  /// frame (its own virtual display filling the frame, or a picture in the
  /// main display's shape): the next wrong one may be rebuilt again.
  void captureMatched() {
    if (_captureWired) _wrongDisplayRebuilds = 0;
  }

  /// The rounds this session has asked for in a row because its first
  /// frame showed another display (tests).
  @visibleForTesting
  int get wrongDisplayRebuilds => _wrongDisplayRebuilds;

  /// Reverse remote: this session's decoder is fed pictures it cannot
  /// decode; ask the tablet for a keyframe.
  void decoderWantsKeyframe() {
    if (_remoteWired) requestIdr();
  }

  /// The translation key [notice] holds while the Mac has no decoder for
  /// this tablet's picture.
  static const _noDecoderNotice = 'error_remote_decoder';

  /// Reverse remote: this session's decoder could not be made ([code] is
  /// the plugin's reason, another tablet's decoder holding the hardware
  /// one, typically). The link stays up and the tablet goes on sending;
  /// its card says so until [decoderReady].
  void decoderFailed(String code) {
    if (!_remoteWired) return;
    // The plugin says so again on every keyframe it cannot start from
    // (about one a second): logged once, until [decoderReady].
    if (notice.value != _noDecoderNotice) {
      log.w('Host: no decoder for $key\'s screen ($code)');
    }
    notice.value = _noDecoderNotice;
  }

  /// Reverse remote: this session's decoder was made again after
  /// [decoderFailed]. Whatever else the card says stays.
  void decoderReady() {
    if (_remoteWired && notice.value == _noDecoderNotice) notice.value = null;
  }

  /// Re-fetches the virtual/main display's screen-space bounds after the
  /// native side reports the display arrangement changed (e.g. the virtual
  /// display was dragged to a different position in System Settings →
  /// Displays). Touch/mouse injection maps normalized coordinates through
  /// these bounds, so a stale cache sends input to the display's old position.
  Future<void> _refreshDisplayBounds() async {
    if (!phase.value.isActive || spec.isReverseRemote) return;
    final bounds = await _capture.getDisplayBounds(session: nativeId);
    if ((bounds['w'] ?? 0) > 0 && (bounds['h'] ?? 0) > 0) {
      _displayBounds = bounds;
      log.i('Display bounds refreshed: $_displayBounds');
    }
  }

  /// Reverse remote (Mac controls tablet): the tablet captures + encodes its own
  /// screen, so the host decodes the incoming stream into a Flutter texture and
  /// injects input back via `adb shell input`. No ScreenCaptureKit here.
  ///
  /// [attempt] is the session this start belongs to, as for [_startCapture]:
  /// once it has ended, at the queue or while the decoder is being made,
  /// this does nothing more, and the teardown's queued stop, which runs
  /// right after it, lets go of the decoder.
  Future<void> _startRemoteReceive(int attempt) async {
    if (isCancelled(attempt)) return;
    // Tell the client to switch into capture mode.
    _sendSessionMode();

    // Stand up the decoder + texture sized to the tablet's native panel.
    // From here the decoder's keyframe requests (routed here by the hub)
    // become 0xFF to the tablet.
    _remoteWired = true;
    final p = panel;
    final texId = await _remote.initialize(
      session: nativeId,
      codec: settings.codec,
      width: p.width,
      height: p.height,
    );
    if (isCancelled(attempt)) return;
    remoteTextureId.value = texId;
    // No texture: nothing of this tablet can be shown. It is still asked
    // for its screen, so the session stays what the tablet was told it is.
    if (texId == null) notice.value = _noDecoderNotice;

    // Here the *tablet's* encoder does the work, and Max's native @ 120 Hz is
    // beyond it (its HEVC encoder manages well under 120 fps at 4K), so Max
    // falls back to Quality's native @ 60 Hz / 20 Mbps in this direction.
    final isMax = settings.encodePreset == EncodePreset.max;
    final fps = isMax ? 60 : settings.refreshRateFor(p);
    final bitrate = isMax ? 20000000 : settings.captureBitrateFor(p);
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
    // And a keyframe: a capture can outlive the last session (its 0xF7 never
    // arrived when the link dropped), and then the tablet only goes on with
    // pictures the new decoder cannot start from. Its periodic keyframes come
    // with its frames, so on a still screen the next can be a long way off
    // (measured: over a minute). A capture that is only starting begins with
    // one anyway. Sent here, not with requestIdr(): the session is not
    // streaming yet.
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xFF]),
    ));
    log.i('Host: reverse remote — decoding tablet stream (texture $texId)');
  }

  /// Reverse remote (USB): turns the tablet's panel off, or back on, while
  /// the tablet keeps running, so the Mac still sees and drives it
  /// ([AdbService.holdTabletScreenOff]). The choice is remembered once it has
  /// worked (on is remembered at once: it cannot be refused) and applied
  /// again when the next session's picture arrives. Returns null when done,
  /// else why not. One call at a time ([changingTabletScreen]).
  Future<String?> setTabletScreenOff(bool off) async {
    final serial = activeDevice.value?.serial;
    if (!spec.isReverseRemote ||
        _wifiSession ||
        !phase.value.isActive ||
        !tabletStreaming.value ||
        serial == null) {
      return 'no live Mac-controls-tablet session';
    }
    if (changingTabletScreen.value) return 'already turning the screen';
    changingTabletScreen.value = true;
    final seq = ++_tabletScreenSeq;
    final attempt = currentAttempt;
    try {
      if (!off) {
        tabletScreenOff.value = false;
        await settings.setTabletScreenOffFor(serial, false);
        await _adb.releaseTabletScreenOff(serial: serial);
        return null;
      }
      final error = await _adb.holdTabletScreenOff(serial: serial);
      // The session may have ended while adb worked: its teardown released
      // what was held then, not this.
      if (isCancelled(attempt) || seq != _tabletScreenSeq) {
        if (error == null) await _adb.releaseTabletScreenOff(serial: serial);
        return 'the session ended';
      }
      if (error != null) {
        log.w('Host: tablet screen not turned off: $error');
        return error;
      }
      tabletScreenOff.value = true;
      await settings.setTabletScreenOffFor(serial, true);
      return null;
    } finally {
      if (seq == _tabletScreenSeq) changingTabletScreen.value = false;
    }
  }

  /// The remembered choice, applied once this session's picture is coming
  /// (the panel had to be on for the capture prompt) and the session is live,
  /// whichever of the two comes last.
  void _darkenTabletIfChosen() {
    final serial = activeDevice.value?.serial;
    if (spec.isReverseRemote &&
        !_wifiSession &&
        serial != null &&
        settings.tabletScreenOffFor(serial) &&
        tabletStreaming.value &&
        phase.value.isActive &&
        !tabletScreenOff.value &&
        !changingTabletScreen.value) {
      unawaited(setTabletScreenOff(true));
    }
  }

  /// Reverse remote: the tablet [serial]'s panel came back on without being
  /// asked (its helper's lease ran out, the cable came out, the helper
  /// died). The hub routes [AdbService.onTabletScreenRestored] here.
  void onTabletScreenRestored(String serial) {
    if (serial == activeDevice.value?.serial) tabletScreenOff.value = false;
  }

  /// 0xF9 + sessionMode index + remoteDirection index.
  void _sendSessionMode() {
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([
        0xF9,
        spec.mode.index,
        // Over Wi-Fi this is always tablet-controls-Mac.
        spec.direction.index,
      ]),
    ));
  }

  /// 0xF7: the tablet stops capturing its screen for the Mac, and takes
  /// back its "Start screen sharing" offer. It does that whatever mode it
  /// was told, and with no capture running nothing else happens.
  void _sendStopCapture() {
    _sendToClient(Packet(
      type: PacketType.control,
      timestampUs: DateTime.now().microsecondsSinceEpoch,
      payload: Uint8List.fromList([0xF7]),
    ));
  }

  // ─── Reverse-remote input (Mac → tablet via adb) ──────────────────────────
  // The remote-view widget reports normalized coords; map them to the tablet's
  // device pixels and drive `adb shell input`.

  // The device the Mac's taps and swipes go to, or null when this session
  // sends none: it is not a tablet the Mac controls, has no adb device
  // (Wi-Fi), or the hub has ended it.
  String? get _remoteInputSerial =>
      spec.isReverseRemote && !_retired ? serial : null;

  /// A tap on this tablet at ([nx], [ny]) of its screen. Only a tablet the
  /// Mac controls takes any, on its own [serial], until the hub ends the
  /// session. The phase is not asked: the tap travels through adb, not the
  /// link, so a call made while the link reconnects lands too. The remote
  /// view makes one only for a pointer over this session's texture, though,
  /// and a lost link's teardown takes the texture away: in the app that is
  /// a press already down as the link went, and every press once the next
  /// attempt has made its decoder.
  void sendRemoteTap(double nx, double ny) {
    final serial = _remoteInputSerial;
    if (serial == null) return;
    final p = panel;
    _adb.inputTap(
      serial: serial,
      x: (nx * p.width).round(),
      y: (ny * p.height).round(),
    );
  }

  void sendRemoteSwipe(double nx1, double ny1, double nx2, double ny2,
      {int durationMs = 50}) {
    final serial = _remoteInputSerial;
    if (serial == null) return;
    final w = panel.width;
    final h = panel.height;
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
    _captureWired = false;
    _remoteWired = false;
    _stopBitrateAdaptation();
    // The others may climb into this one's share at once: its encoder stops
    // a moment later, behind the queue. It keeps its place for its next
    // attempt (a retry, a reconnect) unless the hub has ended it, or it is
    // the session beside the USB tablets, which holds one only while its
    // device is there ([beside]).
    if (_retired || beside) {
      _releaseBudget();
    } else {
      _reserveBudget();
    }
    // The responder is the Wi-Fi session's: a USB session's teardown must
    // not stop it under the session listening beside it.
    if (_wifiSession && Get.isRegistered<WifiDiscoveryService>()) {
      _discovery.stopResponder();
    }
    final reverse = spec.isReverseRemote;
    // Best-effort: tell the client to stop capturing before the socket
    // drops. On a link that is already dead it never arrives; the tablet's
    // next session says it again if the Mac views nothing in it (connect()).
    if (reverse) _sendStopCapture();
    // From here on nobody is authenticated, whoever the socket belongs to,
    // and this attempt's USB key opens nothing any more.
    _authedConnection = null;
    trusted.value = false;
    _usbKey = null;
    // Wake a connect() parked on the proof or the HELLO: its session is over,
    // and it must find that out now, not when its timeout fires seconds later
    // in the middle of the session that replaced it.
    _settle(_Proof.none);
    if (!(_helloReceived?.isCompleted ?? true)) _helloReceived!.complete();
    // The tablet's panel comes back on with the session's end (adb is still
    // there; and if it is not, the tablet's helper lights it by itself).
    tabletStreaming.value = false;
    tabletScreenOff.value = false;
    _tabletScreenSeq++;
    changingTabletScreen.value = false;
    // The shell the Mac's taps went through ends with the session, unless a
    // newer session for this tablet already has it. By the session's own
    // serial, which is where its taps went, and before anything is awaited:
    // a reconnect's first tap then opens a shell of its own.
    final own = serial;
    if (reverse && own != null && _ownsTunnel(own)) {
      unawaited(_adb.closeInputShell(serial: own));
    }
    final device = activeDevice.value?.serial;
    if (reverse && !_wifiSession && device != null && _ownsTunnel(device)) {
      await _adb.releaseTabletScreenOff(serial: device);
    }
    // A drag cut off by the link dropping never gets its up: release the
    // button, or every later injected move would post as a drag.
    await _input.releaseAll(session: nativeId);
    // Behind any start still in flight, so what it started is stopped too.
    await _exclusive(() async {
      // Again: a start that was mid-flight above may have set them since.
      _captureWired = false;
      _remoteWired = false;
      _stopBitrateAdaptation();
      await _frameSub?.cancel();
      _frameSub = null;
      if (reverse) {
        await _remote.dispose(session: nativeId);
        remoteTextureId.value = null;
      } else {
        await _capture.stopCapture(session: nativeId);
        await _capture.removeVirtualDisplay(session: nativeId);
        _displays?.removed(this);
      }
    });
    // A Wi-Fi session has no tunnel, and its "device" is an address.
    final tunnelled = activeDevice.value?.serial;
    if (!_wifiSession && tunnelled != null && _ownsTunnel(tunnelled)) {
      await _onTunnel(tunnelled,
          () => _adb.removeForward(serial: tunnelled, remotePort: linkPort));
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
    trusted.value = true;
  }


  void _settle(_Proof proof) {
    if (!(_proof?.isCompleted ?? true)) _proof!.complete(proof);
  }

  @override
  void onRolePacket(Packet packet) {
    switch (packet.type) {
      // Reverse remote: encoded frames coming FROM the tablet → decode them.
      case PacketType.frameData when spec.isReverseRemote:
        _remote.feedNal(nativeId, packet.payload);
        if (!tabletStreaming.value) {
          tabletStreaming.value = true;
          _darkenTabletIfChosen();
        }
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
        _capture.requestIdr(session: nativeId);
        break;

      default:
        break;
    }
  }

  /// Parse the client HELLO: [version, platform, panelW hi, panelW lo,
  /// panelH hi, panelH lo, panel max refresh Hz]. Older clients send fewer
  /// bytes — then the last-known values are kept.
  void _onHello(Uint8List p) {
    final known = panel;
    var w = known.width, h = known.height, hz = known.maxHz;
    if (p.length >= 6) {
      final pw = (p[2] << 8) | p[3];
      final ph = (p[4] << 8) | p[5];
      if (pw >= 320 && ph >= 240 && pw <= 8192 && ph <= 8192) {
        w = pw;
        h = ph;
        log.i('Host: client panel $w×$h');
      }
    }
    if (p.length >= 7 && p[6] >= 24) {
      hz = p[6];
      log.i('Host: client panel max refresh $hz Hz');
    }
    platform = p.length >= 2 && p[1] >= 0x02 && p[1] <= 0x04 ? p[1] : null;
    // An iPhone or iPad can only drive the Mac: the attempt's spec is taken
    // again with that clamp, before anything reads it for the pipeline
    // (everything mode-dependent waits for this HELLO). The display mode
    // stays the attempt's own.
    if (isApple) {
      _spec = SessionSpec.from(
        choice,
        link,
        displayMode: spec.displayMode,
        android: false,
      );
      // Over Wi-Fi nothing else names the device (adb gives a USB tablet
      // its model), and the cards would call it an Android tablet.
      final device = activeDevice.value;
      if (_wifiSession && device != null && device.model == null) {
        activeDevice.value = device.copyWith(
          model: platform == helloPlatformIphone ? 'iPhone' : 'iPad',
        );
      }
    }
    _panel = ClientPanel(w, h, hz);
    // Only an Android HELLO (or one too old to name a platform) becomes the
    // last panel any tablet reported, which a new tablet's first config and
    // Home's wouldFit fall back on: an iPhone's area (about 2496×1320) or
    // an iPad's window would be a poor guess for one.
    settings.setClientPanelFor(key, _panel!,
        global: platform == null || platform == helloPlatformAndroid);
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
      session: nativeId,
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
    if (m != null) _input.injectMouse(m, _displayBounds, session: nativeId);
  }

  void _injectKey(Packet packet) {
    final k = PacketCodec.decodeKey(packet.payload);
    if (k != null) _input.injectKey(k, session: nativeId);
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

/// Each tablet's adb reverse rule (its tcp:7001), as the sessions the hub
/// makes for that tablet, one after another, take turns at it. Changes to
/// one tablet's rule run one at a time, in the order they were asked for,
/// and only the newest session for the tablet may remove it or let go of
/// its screen hold: an older session whose adb call returns late (adb can
/// take seconds) ends without undoing what the newer one set up.
class TabletTunnels {
  final _queues = <String, PipelineQueue>{};
  final _owners = <String, Object>{};

  /// [owner] is now [serial]'s newest session.
  void claim(String serial, Object owner) => _owners[serial] = owner;

  bool owns(String serial, Object owner) =>
      !_owners.containsKey(serial) || identical(_owners[serial], owner);

  Future<T> run<T>(String serial, Future<T> Function() operation) =>
      (_queues[serial] ??= PipelineQueue()).run(operation);
}

/// The virtual displays this Mac has right now, by the session that made
/// each one (Extend). With several, macOS can hand a new capture stream
/// another session's display instead of the one it asked for, the most
/// recently added one, until every virtual display is gone (Apple bug
/// FB17797423; reproduced on macOS 27 by replugging one of two extending
/// tablets). So whenever a session makes its display while another
/// session's exists (a tablet joining, a retry after a lost link, a
/// reconnect, one session's own capture rebuild), [onRebuildNeeded] asks
/// the hub to take the whole set down and make it again in key order, once
/// that session's capture has started on its display ([started]): a start
/// the encoder refuses, or one that made no display or fell back to the
/// main display, asks for nothing, since nothing of it runs to be fixed. A
/// session whose first frame shows another display asks the same
/// ([requestRebuild]), unless a round already asked for (or under way) is
/// going to restart that capture anyway ([willRestart]). The displays that
/// rebuild makes ask for nothing ([rebuilding]), so it never feeds itself.
/// One display alone never asks.
///
/// A capture of the main display (Mirror) holds no display here, but the
/// same bug can hand its stream a virtual display. One whose first frame
/// has not the main display's shape asks for a repair round
/// ([requestMirrorRepair]) while any display is held, or is down only
/// until a round that leaves that capture alone makes it again
/// ([besideDisplays]): the whole set goes, that capture starts with none
/// there, and the Extend ones follow.
class VirtualDisplays {
  final _holders = <HostSession>{};

  // Sessions whose display was made beside another's and whose start has
  // not finished yet: each asks for the round once its capture has started
  // ([started]), and nothing if the start fails ([startFailed]).
  final _due = <HostSession>{};

  /// The hub's: whether a rebuild round already asked for, or under way and
  /// not yet past [session]'s start, makes [session]'s capture again.
  bool Function(HostSession session)? coveredByRound;

  /// The hub's: whether the rebuild round under way has taken down a
  /// virtual display it has not made again yet, without making
  /// [session]'s capture again itself.
  bool Function(HostSession session)? downForRound;

  /// The hub's: rebuild every Extend session's capture, the display set
  /// emptied first. Called from inside a queued operation (the start that
  /// makes the display), so it must not run the rebuild itself.
  void Function()? onRebuildNeeded;

  /// The hub's: [session]'s capture of the main display shows another
  /// display. The hub rebuilds every Extend session's capture and that one,
  /// the display set emptied first and that one started before any display
  /// is made again. Called from a native callback, never from inside a
  /// queued operation; the hub queues the round from a timer all the same.
  void Function(HostSession session)? onMirrorRepairNeeded;

  /// The hub's ordered rebuild is making the displays again: what it makes
  /// is the fix, not a change to fix.
  bool rebuilding = false;

  /// The sessions whose virtual display exists (or may: one whose creation
  /// threw), in no order.
  List<HostSession> get holders => List.of(_holders);

  bool holds(HostSession session) => _holders.contains(session);

  /// Whether another session than [session] has a virtual display.
  bool sharedWith(HostSession session) =>
      _holders.any((h) => !identical(h, session));

  /// Whether a virtual display that [session]'s capture of the main
  /// display may have been handed instead exists: another session holds
  /// one, or the hub's round has one down that it is about to make again
  /// while leaving [session]'s capture as it is (between a round's stops
  /// and its starts nobody holds any, [downForRound]).
  bool besideDisplays(HostSession session) =>
      sharedWith(session) || (downForRound?.call(session) ?? false);

  /// [session] is about to make its virtual display (replacing its own, if
  /// it has one). With another one there (and outside the hub's own
  /// rebuild), the ordered rebuild is due once this capture has started.
  void adding(HostSession session) {
    final crowded = sharedWith(session);
    _holders.add(session);
    if (crowded && !rebuilding) {
      _due.add(session);
    } else {
      _due.remove(session);
    }
  }

  /// [session]'s capture started on the display it made: asks for the
  /// ordered rebuild if that display was made beside another. Called from
  /// inside the queued start, so the round runs after it.
  void started(HostSession session) {
    if (_due.remove(session)) onRebuildNeeded?.call();
  }

  /// [session]'s start did not get its capture going on its own display
  /// (the encoder refused it, it was cancelled, or it fell back): it asks
  /// for no round.
  void startFailed(HostSession session) => _due.remove(session);

  /// [session]'s virtual display is gone (removed, never made, or released
  /// by the plugin when Extend fell back to the main display).
  void removed(HostSession session) {
    _holders.remove(session);
    _due.remove(session);
  }

  /// Whether [session]'s running capture is made again anyway: by the round
  /// its own start is about to ask for, or by one asked for or under way
  /// that has not restarted it yet. A first frame of such a capture that
  /// shows another display needs no round of its own.
  bool willRestart(HostSession session) =>
      _due.contains(session) || (coveredByRound?.call(session) ?? false);

  /// Asks for the ordered rebuild; false when nobody would run it.
  bool requestRebuild() {
    final rebuild = onRebuildNeeded;
    if (rebuild == null) return false;
    rebuild();
    return true;
  }

  /// Asks for the repair round for [session]'s capture of the main display
  /// (see the class comment); false when nobody would run it.
  bool requestMirrorRepair(HostSession session) {
    final repair = onMirrorRepairNeeded;
    if (repair == null) return false;
    repair(session);
    return true;
  }
}
