import 'package:get/get.dart';

/// App-wide string catalogue for GetX localization.
///
/// Two locales are supported: English (`en`) and Thai (`th`). Strings are
/// looked up with the `.tr` extension (`'home_open_view'.tr`) or, when a value
/// needs interpolation, `.trParams({'name': value})` against an `@name` token.
///
/// `fallbackLocale` in [GetMaterialApp] is `en`, so any key missing from `th`
/// falls back to its English value (and a missing key renders as the raw key).
class AppTranslations extends Translations {
  /// Locales the app offers in the language picker, in display order.
  static const supportedLocales = ['en', 'th'];

  /// Human-readable name for a locale code, shown in the picker.
  static String localeName(String code) => switch (code) {
        'th' => 'ไทย',
        _ => 'English',
      };

  @override
  Map<String, Map<String, String>> get keys => {
        'en': _en,
        'th': _th,
      };

  static const Map<String, String> _en = {
    // ── Common ──────────────────────────────────────────────────────────
    'common_connect': 'Connect',
    'common_disconnect': 'Disconnect',
    'common_cancel': 'Cancel',
    'common_reconnect': 'Reconnect',
    'common_connected': 'Connected',
    'common_open': 'Open',
    'common_refresh': 'Refresh',
    'common_back': 'Back',

    // ── App / brand ─────────────────────────────────────────────────────
    'app_name': 'Extended Screen',
    'app_subtitle': 'Android tablet • macOS',

    // ── Connection phases ───────────────────────────────────────────────
    'phase_disconnected': 'Disconnected',
    'phase_detecting_device': 'Detecting device…',
    'phase_adb_connecting': 'Connecting via ADB…',
    'phase_port_forwarding': 'Forwarding port…',
    'phase_handshaking': 'Handshaking…',
    'phase_configuring': 'Configuring display…',
    'phase_streaming': 'Streaming',
    'phase_paused': 'Paused',
    'phase_error': 'Error',
    'error_waiting_for_host': 'Waiting for Mac host…',
    'error_wifi_not_paired':
        'Not paired with a Mac yet. Connect once over USB first.',
    'error_wifi_host_not_found':
        'Looking for the Mac on this Wi-Fi… Check that it is on the same '
            'network and has pressed Connect.',
    'error_wifi_untrusted':
        'That is not the Mac this tablet was paired with. Connect once over '
            'USB to pair again.',
    'error_wifi_unpaired_client':
        'A device that is not paired with this Mac tried to connect.',
    'error_wifi_identity':
        'Could not create this Mac\'s Wi-Fi identity (openssl failed).',
    'error_usb_unverified_client':
        'The tablet connected but did not confirm this USB session. Update '
            'extendedscreen on the tablet so it matches this Mac.',
    'error_usb_key_not_delivered':
        'Could not hand this session\'s key to extendedscreen on the tablet '
            'through adb. Open the app on the tablet and make sure it is up '
            'to date.',
    'error_usb_unverified_host':
        'The Mac has not confirmed this USB session. Connect from the Mac '
            'app, and make sure extendedscreen is up to date on both devices.',

    // ── Link type ───────────────────────────────────────────────────────
    'link_usb_label': 'USB',
    'link_usb_desc': 'Through the cable. Lowest delay.',
    'link_wifi_label': 'Wi-Fi',
    'link_wifi_desc': 'No cable, same network. Pair over USB once.',
    'wifi_host_title': 'Wi-Fi link',
    'wifi_host_address': 'This Mac: @address  •  port @port',
    'wifi_host_no_network':
        'This Mac has no network address. Join a Wi-Fi network first.',
    'wifi_host_hint':
        'Press Connect above if this Mac is not waiting yet, then choose '
            'Wi-Fi on the tablet. A tablet can connect only after it has been '
            'connected to this Mac over USB once, which pairs them. A 5 GHz '
            'or 6 GHz network works best.',
    'wifi_client_title': 'Mac over Wi-Fi',
    'wifi_client_paired': 'Paired with @name',
    'wifi_client_not_paired':
        'Not paired yet. Switch to USB, connect to the Mac once, then come '
            'back to Wi-Fi.',
    'wifi_client_forget': 'Forget this Mac',
    'wifi_forget_title': 'Forget @name?',
    'wifi_forget_message':
        'This tablet will stop connecting to that Mac over Wi-Fi. To pair '
            'them again, connect to it over USB once.',
    'wifi_forget_confirm': 'Forget',
    'wifi_client_address_label': 'Mac address (optional)',
    'wifi_client_address_hint':
        'Found automatically. Fill in only if it is not, e.g. 192.168.1.20',
    'remote_dir_usb_only': 'USB only',

    // ── Session modes ───────────────────────────────────────────────────
    'session_extended_label': 'Extended Screen',
    'session_extended_desc': 'Use the tablet as a second monitor for your Mac.',
    'session_remote_label': 'Remote Control',
    'session_remote_desc':
        'Control your Mac\'s desktop from the tablet, like a remote session.',
    'remote_dir_title': 'Direction',
    'remote_dir_tab_label': 'Tablet → Mac',
    'remote_dir_tab_desc': 'Control the Mac from the tablet.',
    'remote_dir_mac_label': 'Mac → Tablet',
    'remote_dir_mac_desc': 'Control the tablet from the Mac.',
    'remote_host_waiting':
        'Waiting for the tablet…\nApprove the screen-capture prompt on the tablet.',
    'remote_tablet_screen_off': 'Tablet screen off',
    'remote_tablet_screen_on': 'Tablet screen on',
    'remote_tablet_screen_hint':
        'The tablet keeps running and you can still control it: only its screen goes dark.',
    'remote_tablet_screen_failed': "Couldn't turn the tablet's screen off",

    // ── Home ────────────────────────────────────────────────────────────
    'home_open_view': 'Open View',
    'home_open_remote': 'Open Remote View',
    'home_waiting_for_stream': 'Waiting for stream…',
    'home_start_share': 'Start screen sharing',
    'home_start_share_hint':
        'The Mac wants to view and control this tablet. Tap to start, then '
            'approve the screen-capture prompt.',
    'home_sharing': 'Sharing your screen',
    'home_sharing_hint':
        'The Mac can now see and control this tablet. Disconnect to stop.',

    // ── Connection card ─────────────────────────────────────────────────
    'conn_card_active_subtitle': '@link  •  @codec',
    'conn_card_plug_prompt': 'Plug tablet via USB-C cable',
    'conn_card_wifi_prompt': 'Mac and tablet on the same Wi-Fi',

    // ── Connection steps (client) ───────────────────────────────────────
    'step_connect_label': 'Connect to Mac host',
    'step_connect_detail': 'Linking over the USB-C tunnel',
    'step_connect_detail_wifi': 'Looking for the Mac on Wi-Fi',
    'step_configure_label': 'Configure display',
    'step_configure_detail': 'Negotiating codec & resolution',
    'step_ready_label': 'Ready to display',
    'step_ready_detail': 'Stream is live — tap Open View',

    // ── Device picker / info ────────────────────────────────────────────
    'device_android_client': 'Android client',
    'device_refresh_tooltip': 'Refresh devices',
    'device_none_detected': 'No device detected — plug in via USB-C',
    'device_default_name': 'Android tablet',

    // ── Latency chip ────────────────────────────────────────────────────
    'latency_value': '@ms ms latency',

    // ── Battery chip (client) ───────────────────────────────────────────
    'battery_charging_pct': 'Charging · @pct%',
    'battery_not_charging_pct': 'Not charging · @pct%',
    'battery_charging': 'Charging',
    'battery_not_charging': 'Not charging',

    // ── Display view ────────────────────────────────────────────────────
    'display_reconnecting': 'Reconnecting…',
    'display_reconnect_hint':
        'Waiting for the Mac. This happens after a settings change on the '
            'Mac, or if the cable was unplugged or the Wi-Fi dropped, the Mac '
            'went to sleep or the Mac app was quit.',
    'display_show_controls': 'Show controls',
    'display_surface_android_only': 'Display surface\n(Android only)',

    // ── Settings: sections ──────────────────────────────────────────────
    'settings_title': 'Settings',
    'settings_section_general': 'General',
    'settings_section_display': 'Display',
    'settings_section_input': 'Touch',
    'settings_section_performance': 'Performance',
    'settings_section_custom': 'Custom',
    'settings_section_wifi': 'Wi-Fi',
    'settings_section_permissions': 'Permissions',
    'settings_section_info': 'Info',

    // ── Settings: Wi-Fi pairing (host) ──────────────────────────────────
    'settings_wifi_reset': 'Reset Wi-Fi pairing',
    'settings_wifi_reset_desc':
        'Unpairs every tablet. Each one then has to connect over USB once '
            'before it can use Wi-Fi again.',
    'settings_wifi_reset_done':
        'Done. Connect each tablet over USB once to pair it again.',
    'wifi_reset_title': 'Reset Wi-Fi pairing?',
    'wifi_reset_message':
        'This Mac gets a new Wi-Fi identity. Every tablet paired with it '
            'stops connecting over Wi-Fi until it has been connected over USB '
            'once more, and a Wi-Fi session in progress ends.',
    'wifi_reset_confirm': 'Reset',

    // ── Settings: language ──────────────────────────────────────────────
    'settings_language': 'Language',

    // ── Settings: display ───────────────────────────────────────────────
    'settings_mode': 'Mode',
    'settings_mode_extend': 'Extend',
    'settings_mode_mirror': 'Mirror',
    'settings_client_display_note':
        'Display mode, encode preset and codec are configured on the Mac host. '
            'This device renders whatever the host streams.',

    // ── Settings: performance ───────────────────────────────────────────
    'settings_encode_preset': 'Encode Preset',
    'settings_codec': 'Codec',
    'settings_codec_h264': 'H.264 (AVC)',
    'settings_codec_h265': 'H.265 (HEVC)',
    'settings_reconnecting_to_apply': 'Reconnecting to apply…',
    'settings_perf_reconnect_note':
        'Changing performance settings reconnects the link.',
    'settings_performance_overlay': 'Performance Overlay',
    'settings_show_hud': 'Show HUD (fps / latency / battery)',
    'settings_keep_mac_cursor': 'Keep the Mac cursor in place',
    'settings_keep_mac_cursor_desc':
        'Taps and drags on the tablet borrow the cursor and give it back as '
            'your finger lifts; scrolling leaves it alone. Turn off to leave '
            'it where you touched.',

    // ── Settings: custom ────────────────────────────────────────────────
    'settings_custom_values': 'Custom Values',
    'settings_resolution': 'Resolution',
    'settings_bitrate': 'Bitrate',
    'settings_refresh_rate': 'Refresh Rate',
    'settings_help_resolution':
        'Higher (native panel resolution): sharper, more detail — crisp text '
            'and fine lines, but needs more bitrate and can lower the frame '
            'rate.\n'
            'Lower (e.g. 1280×800): softer and less detailed, but much lighter '
            'on bandwidth and easier to keep smooth.',
    'settings_help_bitrate':
        'Higher (e.g. 40 Mbps): cleaner image, fewer blocky artifacts in '
            'motion — but uses more USB bandwidth.\n'
            'Lower (e.g. 4 Mbps): saves bandwidth, but the picture can look '
            'blocky or smeared when things move fast.',
    'settings_help_refresh':
        'Higher (e.g. 120 Hz): smoother motion for scrolling, video and '
            'animation — but more demanding to encode and stream.\n'
            'Lower (e.g. 30 Hz): less smooth motion, but lighter and steadier '
            'on a slower link.',

    // ── Settings: permissions ───────────────────────────────────────────
    'perm_screen_recording': 'Screen Recording',
    'perm_screen_recording_desc': 'Required to capture the display content',
    'perm_accessibility': 'Accessibility',
    'perm_accessibility_desc': 'Required to inject touch and keyboard input',
    'perm_battery_optimization': 'Battery Optimization',
    'perm_battery_optimization_desc':
        'Exempt from battery optimization to keep streaming alive',
    'perm_display_over_apps': 'Display Over Other Apps',
    'perm_display_over_apps_desc': 'Allows the display overlay to render on top',
    'perm_required_title': 'Permissions needed',
    'perm_required_msg':
        'Grant Screen Recording and Accessibility before connecting.',

    // ── Settings: connection ────────────────────────────────────────────
    'settings_transport': 'Transport',
    'settings_codec_h264_hw': 'H.264 Hardware',
    'settings_codec_h265_hw': 'H.265 Hardware',
    'settings_port': 'Port',

    // ── Settings: about ─────────────────────────────────────────────────
    'settings_version': 'Version',
    'settings_target_device': 'Target Device',
    'settings_host': 'Host',

    // ── Preset picker ───────────────────────────────────────────────────
    'preset_picker_legend':
        'Resolution = sharpness · Bitrate = image quality & USB bandwidth · '
            'Hz = motion smoothness',
    'codec_picker_h264': 'H.264 (AVC)  —  widest compatibility',
    'codec_picker_h265': 'H.265 (HEVC)  —  better quality per bitrate',

    // ── Encode presets ──────────────────────────────────────────────────
    'preset_max_label': 'Max',
    'preset_max_tagline': 'Best your devices can do',
    'preset_max_desc':
        'Your tablet\'s full native resolution at its highest refresh rate. '
            'If this Mac can\'t keep up, the frame rate is lowered '
            'automatically so the picture stays smooth instead of lagging.',
    'preset_quality_label': 'Quality',
    'preset_balanced_label': 'Balanced',
    'preset_performance_label': 'Performance',
    'preset_custom_label': 'Custom',
    'preset_quality_tagline': 'Sharpest image',
    'preset_balanced_tagline': 'Best all-round',
    'preset_performance_tagline': 'Smoothest motion',
    'preset_custom_tagline': 'Your settings',
    'preset_quality_desc':
        'Full native resolution at a high bitrate. Text and fine detail look '
            'their crispest — best for reading, writing and design work. Uses '
            'the most USB bandwidth.',
    'preset_balanced_desc':
        'Full native resolution at a moderate bitrate. Keeps the picture sharp '
            'while using about half the data of Quality — the best choice for '
            'everyday use.',
    'preset_performance_desc':
        'Half the resolution but double the frame rate (120 Hz). Motion looks '
            'much smoother at the cost of fine sharpness — best for video, fast '
            'scrolling and animation.',
    'preset_custom_desc':
        'Set your own resolution, bitrate and refresh rate. For advanced '
            'tuning when the fixed presets do not fit.',
  };

  static const Map<String, String> _th = {
    // ── Common ──────────────────────────────────────────────────────────
    'common_connect': 'เชื่อมต่อ',
    'common_disconnect': 'ตัดการเชื่อมต่อ',
    'common_cancel': 'ยกเลิก',
    'common_reconnect': 'เชื่อมต่อใหม่',
    'common_connected': 'เชื่อมต่อแล้ว',
    'common_open': 'เปิด',
    'common_refresh': 'รีเฟรช',
    'common_back': 'กลับ',

    // ── App / brand ─────────────────────────────────────────────────────
    'app_name': 'Extended Screen',
    'app_subtitle': 'แท็บเล็ต Android • macOS',

    // ── Connection phases ───────────────────────────────────────────────
    'phase_disconnected': 'ยังไม่ได้เชื่อมต่อ',
    'phase_detecting_device': 'กำลังค้นหาอุปกรณ์…',
    'phase_adb_connecting': 'กำลังเชื่อมต่อผ่าน ADB…',
    'phase_port_forwarding': 'กำลังส่งต่อพอร์ต…',
    'phase_handshaking': 'กำลังจับมือสื่อสาร…',
    'phase_configuring': 'กำลังตั้งค่าการแสดงผล…',
    'phase_streaming': 'กำลังสตรีม',
    'phase_paused': 'หยุดชั่วคราว',
    'phase_error': 'เกิดข้อผิดพลาด',
    'error_waiting_for_host': 'กำลังรอโฮสต์ Mac…',
    'error_wifi_not_paired':
        'ยังไม่ได้จับคู่กับ Mac ให้เชื่อมต่อผ่าน USB หนึ่งครั้งก่อน',
    'error_wifi_host_not_found':
        'กำลังค้นหา Mac บน Wi-Fi นี้… ตรวจว่า Mac อยู่เครือข่ายเดียวกัน'
            'และกด "เชื่อมต่อ" แล้ว',
    'error_wifi_untrusted':
        'เครื่องนี้ไม่ใช่ Mac ที่แท็บเล็ตจับคู่ไว้ ให้เชื่อมต่อผ่าน USB '
            'หนึ่งครั้งเพื่อจับคู่ใหม่',
    'error_wifi_unpaired_client':
        'มีอุปกรณ์ที่ยังไม่ได้จับคู่กับ Mac เครื่องนี้พยายามเชื่อมต่อ',
    'error_wifi_identity':
        'สร้างข้อมูลยืนยันตัวตน Wi-Fi ของ Mac เครื่องนี้ไม่สำเร็จ (openssl ล้มเหลว)',
    'error_usb_unverified_client':
        'แท็บเล็ตเชื่อมต่อเข้ามาแต่ไม่ได้ยืนยันเซสชัน USB นี้ ให้อัปเดต '
            'extendedscreen บนแท็บเล็ตให้ตรงกับ Mac เครื่องนี้',
    'error_usb_key_not_delivered':
        'ส่งกุญแจของเซสชันนี้ให้ extendedscreen บนแท็บเล็ตผ่าน adb ไม่สำเร็จ '
            'ให้เปิดแอปบนแท็บเล็ตและตรวจว่าเป็นเวอร์ชันล่าสุด',
    'error_usb_unverified_host':
        'Mac ยังไม่ได้ยืนยันเซสชัน USB นี้ ให้กดเชื่อมต่อจากแอปบน Mac '
            'และตรวจว่า extendedscreen เป็นเวอร์ชันล่าสุดทั้งสองเครื่อง',

    // ── Link type ───────────────────────────────────────────────────────
    'link_usb_label': 'USB',
    'link_usb_desc': 'ผ่านสาย ดีเลย์ต่ำที่สุด',
    'link_wifi_label': 'Wi-Fi',
    'link_wifi_desc': 'ไร้สาย เครือข่ายเดียวกัน จับคู่ผ่าน USB หนึ่งครั้ง',
    'wifi_host_title': 'การเชื่อมต่อ Wi-Fi',
    'wifi_host_address': 'Mac เครื่องนี้: @address  •  พอร์ต @port',
    'wifi_host_no_network':
        'Mac เครื่องนี้ยังไม่มีที่อยู่เครือข่าย ให้เชื่อมต่อ Wi-Fi ก่อน',
    'wifi_host_hint':
        'กด "เชื่อมต่อ" ด้านบนหาก Mac ยังไม่ได้รออยู่ แล้วเลือก Wi-Fi บนแท็บเล็ต '
            'แท็บเล็ตจะเชื่อมต่อได้หลังจากเคยเชื่อมต่อกับ Mac เครื่องนี้ผ่าน USB '
            'หนึ่งครั้ง ซึ่งเป็นการจับคู่ แนะนำเครือข่าย 5 GHz หรือ 6 GHz',
    'wifi_client_title': 'Mac ผ่าน Wi-Fi',
    'wifi_client_paired': 'จับคู่กับ @name แล้ว',
    'wifi_client_not_paired':
        'ยังไม่ได้จับคู่ ให้สลับเป็น USB เชื่อมต่อกับ Mac หนึ่งครั้ง '
            'แล้วกลับมาเลือก Wi-Fi',
    'wifi_client_forget': 'เลิกจับคู่กับ Mac เครื่องนี้',
    'wifi_forget_title': 'เลิกจับคู่กับ @name หรือไม่',
    'wifi_forget_message':
        'แท็บเล็ตเครื่องนี้จะไม่เชื่อมต่อกับ Mac เครื่องนั้นผ่าน Wi-Fi อีก '
            'หากต้องการจับคู่ใหม่ ให้เชื่อมต่อผ่าน USB หนึ่งครั้ง',
    'wifi_forget_confirm': 'เลิกจับคู่',
    'wifi_client_address_label': 'ที่อยู่ของ Mac (ไม่บังคับ)',
    'wifi_client_address_hint':
        'ค้นหาให้อัตโนมัติ กรอกเฉพาะเมื่อหาไม่พบ เช่น 192.168.1.20',
    'remote_dir_usb_only': 'เฉพาะ USB',

    // ── Session modes ───────────────────────────────────────────────────
    'session_extended_label': 'จอเสริม',
    'session_extended_desc': 'ใช้แท็บเล็ตเป็นจอที่สองของ Mac',
    'session_remote_label': 'รีโมตคอนโทรล',
    'session_remote_desc': 'ควบคุมหน้าจอ Mac จากแท็บเล็ต เหมือนการรีโมต',
    'remote_dir_title': 'ทิศทาง',
    'remote_dir_tab_label': 'แท็บเล็ต → Mac',
    'remote_dir_tab_desc': 'คุม Mac จากแท็บเล็ต',
    'remote_dir_mac_label': 'Mac → แท็บเล็ต',
    'remote_dir_mac_desc': 'คุมแท็บเล็ตจาก Mac',
    'remote_host_waiting': 'กำลังรอแท็บเล็ต…\nกดอนุญาตการบันทึกหน้าจอบนแท็บเล็ต',
    'remote_tablet_screen_off': 'ปิดจอแท็บเล็ต',
    'remote_tablet_screen_on': 'เปิดจอแท็บเล็ต',
    'remote_tablet_screen_hint': 'แท็บเล็ตยังทำงานและคุมได้ตามปกติ แค่จอดับ',
    'remote_tablet_screen_failed': 'ปิดจอแท็บเล็ตไม่ได้',

    // ── Home ────────────────────────────────────────────────────────────
    'home_open_view': 'เปิดหน้าจอ',
    'home_open_remote': 'เปิดหน้าควบคุมระยะไกล',
    'home_waiting_for_stream': 'กำลังรอสัญญาณสตรีม…',
    'home_start_share': 'เริ่มแชร์หน้าจอ',
    'home_start_share_hint':
        'Mac ต้องการดูและควบคุมแท็บเล็ตเครื่องนี้ แตะเพื่อเริ่ม '
            'แล้วกดอนุญาตการบันทึกหน้าจอ',
    'home_sharing': 'กำลังแชร์หน้าจอ',
    'home_sharing_hint':
        'ตอนนี้ Mac เห็นและควบคุมแท็บเล็ตนี้ได้แล้ว ตัดการเชื่อมต่อเพื่อหยุด',

    // ── Connection card ─────────────────────────────────────────────────
    'conn_card_active_subtitle': '@link  •  @codec',
    'conn_card_plug_prompt': 'เสียบแท็บเล็ตด้วยสาย USB-C',
    'conn_card_wifi_prompt': 'Mac และแท็บเล็ตอยู่ Wi-Fi เดียวกัน',

    // ── Connection steps (client) ───────────────────────────────────────
    'step_connect_label': 'เชื่อมต่อกับโฮสต์ Mac',
    'step_connect_detail': 'กำลังเชื่อมผ่านอุโมงค์ USB-C',
    'step_connect_detail_wifi': 'กำลังค้นหา Mac บน Wi-Fi',
    'step_configure_label': 'ตั้งค่าการแสดงผล',
    'step_configure_detail': 'กำลังตกลงตัวแปลงสัญญาณและความละเอียด',
    'step_ready_label': 'พร้อมแสดงผล',
    'step_ready_detail': 'สตรีมพร้อมแล้ว — แตะ "เปิดหน้าจอ"',

    // ── Device picker / info ────────────────────────────────────────────
    'device_android_client': 'อุปกรณ์ Android',
    'device_refresh_tooltip': 'รีเฟรชอุปกรณ์',
    'device_none_detected': 'ไม่พบอุปกรณ์ — เสียบผ่าน USB-C',
    'device_default_name': 'แท็บเล็ต Android',

    // ── Latency chip ────────────────────────────────────────────────────
    'latency_value': 'ดีเลย์ @ms มิลลิวินาที',

    // ── Battery chip (client) ───────────────────────────────────────────
    'battery_charging_pct': 'กำลังชาร์จ · @pct%',
    'battery_not_charging_pct': 'ไม่ได้ชาร์จ · @pct%',
    'battery_charging': 'กำลังชาร์จ',
    'battery_not_charging': 'ไม่ได้ชาร์จ',

    // ── Display view ────────────────────────────────────────────────────
    'display_reconnecting': 'กำลังเชื่อมต่อใหม่…',
    'display_reconnect_hint':
        'กำลังรอ Mac อยู่ อาจเป็นเพราะเพิ่งเปลี่ยนการตั้งค่าบน Mac '
            'ถอดสายออกหรือ Wi-Fi หลุด Mac เข้าสู่โหมดพักเครื่อง '
            'หรือออกจากแอปบน Mac',
    'display_show_controls': 'แสดงแถบควบคุม',
    'display_surface_android_only': 'พื้นที่แสดงผล\n(เฉพาะ Android)',

    // ── Settings: sections ──────────────────────────────────────────────
    'settings_title': 'การตั้งค่า',
    'settings_section_general': 'ทั่วไป',
    'settings_section_display': 'การแสดงผล',
    'settings_section_input': 'การสัมผัส',
    'settings_section_performance': 'ประสิทธิภาพ',
    'settings_section_custom': 'กำหนดเอง',
    'settings_section_wifi': 'Wi-Fi',
    'settings_section_permissions': 'สิทธิ์การเข้าถึง',
    'settings_section_info': 'ข้อมูล',

    // ── Settings: Wi-Fi pairing (host) ──────────────────────────────────
    'settings_wifi_reset': 'รีเซ็ตการจับคู่ Wi-Fi',
    'settings_wifi_reset_desc':
        'ยกเลิกการจับคู่กับแท็บเล็ตทุกเครื่อง แต่ละเครื่องต้องเชื่อมต่อผ่าน USB '
            'หนึ่งครั้งก่อนจะใช้ Wi-Fi ได้อีก',
    'settings_wifi_reset_done':
        'รีเซ็ตแล้ว ให้เชื่อมต่อแท็บเล็ตแต่ละเครื่องผ่าน USB หนึ่งครั้งเพื่อจับคู่ใหม่',
    'wifi_reset_title': 'รีเซ็ตการจับคู่ Wi-Fi หรือไม่',
    'wifi_reset_message':
        'Mac เครื่องนี้จะได้ข้อมูลยืนยันตัวตน Wi-Fi ชุดใหม่ แท็บเล็ตทุกเครื่องที่จับคู่ไว้'
            'จะเชื่อมต่อผ่าน Wi-Fi ไม่ได้จนกว่าจะเชื่อมต่อผ่าน USB อีกหนึ่งครั้ง '
            'และการเชื่อมต่อ Wi-Fi ที่ใช้งานอยู่จะถูกตัด',
    'wifi_reset_confirm': 'รีเซ็ต',

    // ── Settings: language ──────────────────────────────────────────────
    'settings_language': 'ภาษา',

    // ── Settings: display ───────────────────────────────────────────────
    'settings_mode': 'โหมด',
    'settings_mode_extend': 'ขยายจอ',
    'settings_mode_mirror': 'สะท้อนจอ',
    'settings_client_display_note':
        'โหมดการแสดงผล พรีเซ็ตการเข้ารหัส และตัวแปลงสัญญาณ ตั้งค่าได้ที่โฮสต์ '
            'Mac เท่านั้น อุปกรณ์นี้จะแสดงผลตามที่โฮสต์สตรีมมาให้',

    // ── Settings: performance ───────────────────────────────────────────
    'settings_encode_preset': 'พรีเซ็ตการเข้ารหัส',
    'settings_codec': 'ตัวแปลงสัญญาณ',
    'settings_codec_h264': 'H.264 (AVC)',
    'settings_codec_h265': 'H.265 (HEVC)',
    'settings_reconnecting_to_apply': 'กำลังเชื่อมต่อใหม่เพื่อใช้การตั้งค่า…',
    'settings_perf_reconnect_note':
        'การเปลี่ยนการตั้งค่าประสิทธิภาพจะเชื่อมต่อลิงก์ใหม่',
    'settings_performance_overlay': 'โอเวอร์เลย์ประสิทธิภาพ',
    'settings_show_hud': 'แสดง HUD (fps / ดีเลย์ / แบตเตอรี่)',
    'settings_keep_mac_cursor': 'คงเคอร์เซอร์ของ Mac ไว้ที่เดิม',
    'settings_keep_mac_cursor_desc':
        'การแตะและลากบนแท็บเล็ตจะยืมเคอร์เซอร์ไปชั่วคราว แล้วคืนที่เดิมเมื่อยกนิ้ว '
            'ส่วนการเลื่อนจะไม่ขยับเคอร์เซอร์เลย ปิดไว้ถ้าอยากให้เคอร์เซอร์อยู่ตรงจุดที่แตะ',

    // ── Settings: custom ────────────────────────────────────────────────
    'settings_custom_values': 'ค่ากำหนดเอง',
    'settings_resolution': 'ความละเอียด',
    'settings_bitrate': 'บิตเรต',
    'settings_refresh_rate': 'อัตรารีเฟรช',
    'settings_help_resolution':
        'สูง (ความละเอียดเนทีฟของหน้าจอ): คมชัดและมีรายละเอียดมากขึ้น — '
            'ตัวอักษรและเส้นคม แต่ต้องใช้บิตเรตมากขึ้นและอาจทำให้เฟรมเรตลดลง\n'
            'ต่ำ (เช่น 1280×800): นุ่มนวลและรายละเอียดน้อยลง แต่ใช้แบนด์วิดท์น้อย '
            'และทำให้ลื่นไหลได้ง่ายกว่า',
    'settings_help_bitrate':
        'สูง (เช่น 40 Mbps): ภาพสะอาดขึ้น มีรอยหยักน้อยลงเวลาเคลื่อนไหว — '
            'แต่ใช้แบนด์วิดท์ USB มากขึ้น\n'
            'ต่ำ (เช่น 4 Mbps): ประหยัดแบนด์วิดท์ แต่ภาพอาจดูเป็นบล็อกหรือเบลอ '
            'เวลาเคลื่อนไหวเร็ว',
    'settings_help_refresh':
        'สูง (เช่น 120 Hz): การเคลื่อนไหวลื่นขึ้นเวลาเลื่อนหน้า วิดีโอ และ '
            'แอนิเมชัน — แต่หนักกว่าในการเข้ารหัสและสตรีม\n'
            'ต่ำ (เช่น 30 Hz): การเคลื่อนไหวลื่นน้อยลง แต่เบากว่าและเสถียรกว่า '
            'บนลิงก์ที่ช้า',

    // ── Settings: permissions ───────────────────────────────────────────
    'perm_screen_recording': 'การบันทึกหน้าจอ',
    'perm_screen_recording_desc': 'จำเป็นสำหรับการจับภาพเนื้อหาบนหน้าจอ',
    'perm_accessibility': 'การช่วยการเข้าถึง',
    'perm_accessibility_desc': 'จำเป็นสำหรับการส่งอินพุตสัมผัสและคีย์บอร์ด',
    'perm_battery_optimization': 'การปรับแต่งแบตเตอรี่',
    'perm_battery_optimization_desc':
        'ยกเว้นจากการปรับแต่งแบตเตอรี่เพื่อให้การสตรีมทำงานต่อเนื่อง',
    'perm_display_over_apps': 'แสดงทับแอปอื่น',
    'perm_display_over_apps_desc': 'อนุญาตให้โอเวอร์เลย์การแสดงผลแสดงทับด้านบน',
    'perm_required_title': 'ต้องเปิดสิทธิ์ก่อน',
    'perm_required_msg':
        'กรุณาเปิดสิทธิ์ "การบันทึกหน้าจอ" และ "การช่วยการเข้าถึง" ก่อนเชื่อมต่อ',

    // ── Settings: connection ────────────────────────────────────────────
    'settings_transport': 'การส่งข้อมูล',
    'settings_codec_h264_hw': 'H.264 ฮาร์ดแวร์',
    'settings_codec_h265_hw': 'H.265 ฮาร์ดแวร์',
    'settings_port': 'พอร์ต',

    // ── Settings: about ─────────────────────────────────────────────────
    'settings_version': 'เวอร์ชัน',
    'settings_target_device': 'อุปกรณ์เป้าหมาย',
    'settings_host': 'โฮสต์',

    // ── Preset picker ───────────────────────────────────────────────────
    'preset_picker_legend':
        'ความละเอียด = ความคมชัด · บิตเรต = คุณภาพภาพและแบนด์วิดท์ USB · '
            'Hz = ความลื่นไหลของการเคลื่อนไหว',
    'codec_picker_h264': 'H.264 (AVC)  —  รองรับกว้างที่สุด',
    'codec_picker_h265': 'H.265 (HEVC)  —  คุณภาพดีกว่าต่อบิตเรต',

    // ── Encode presets ──────────────────────────────────────────────────
    'preset_max_label': 'สูงสุด',
    'preset_max_tagline': 'เต็มสเปกอุปกรณ์',
    'preset_max_desc':
        'ความละเอียดเนทีฟเต็มจอของแท็บเล็ต ที่อัตรารีเฟรชสูงสุดที่รองรับ '
            'หาก Mac ประมวลผลไม่ทัน ระบบจะลดเฟรมเรตให้อัตโนมัติ '
            'เพื่อให้ภาพลื่นไหลแทนที่จะหน่วง',
    'preset_quality_label': 'คุณภาพ',
    'preset_balanced_label': 'สมดุล',
    'preset_performance_label': 'ประสิทธิภาพ',
    'preset_custom_label': 'กำหนดเอง',
    'preset_quality_tagline': 'ภาพคมชัดที่สุด',
    'preset_balanced_tagline': 'ดีรอบด้านที่สุด',
    'preset_performance_tagline': 'เคลื่อนไหวลื่นที่สุด',
    'preset_custom_tagline': 'การตั้งค่าของคุณ',
    'preset_quality_desc':
        'ความละเอียดเต็มแบบเนทีฟที่บิตเรตสูง ตัวอักษรและรายละเอียดเล็ก ๆ '
            'คมชัดที่สุด — เหมาะกับการอ่าน เขียน และงานออกแบบ ใช้แบนด์วิดท์ '
            'USB มากที่สุด',
    'preset_balanced_desc':
        'ความละเอียดเต็มแบบเนทีฟที่บิตเรตปานกลาง คงภาพให้คมชัดขณะใช้ข้อมูล '
            'ราวครึ่งหนึ่งของโหมดคุณภาพ — ตัวเลือกที่ดีที่สุดสำหรับใช้งานทั่วไป',
    'preset_performance_desc':
        'ความละเอียดครึ่งหนึ่งแต่เฟรมเรตเป็นสองเท่า (120 Hz) การเคลื่อนไหว '
            'ลื่นขึ้นมากโดยแลกกับความคมชัด — เหมาะกับวิดีโอ การเลื่อนหน้าเร็ว '
            'และแอนิเมชัน',
    'preset_custom_desc':
        'กำหนดความละเอียด บิตเรต และอัตรารีเฟรชเอง สำหรับการปรับแต่งขั้นสูง '
            'เมื่อพรีเซ็ตสำเร็จรูปไม่ตรงความต้องการ',
  };
}
