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
    'common_connected': 'Connected',
    'common_open': 'Open',
    'common_refresh': 'Refresh',

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

    // ── Home ────────────────────────────────────────────────────────────
    'home_open_view': 'Open View',
    'home_waiting_for_stream': 'Waiting for stream…',

    // ── Connection card ─────────────────────────────────────────────────
    'conn_card_active_subtitle': 'USB-C  •  @codec',
    'conn_card_plug_prompt': 'Plug tablet via USB-C cable',

    // ── Connection steps (client) ───────────────────────────────────────
    'step_connect_label': 'Connect to Mac host',
    'step_connect_detail': 'Linking over the USB-C tunnel',
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

    // ── Display view ────────────────────────────────────────────────────
    'display_reconnecting': 'Reconnecting…',
    'display_applying_settings': 'Applying new settings from the host',
    'display_surface_android_only': 'Display surface\n(Android only)',

    // ── Settings: sections ──────────────────────────────────────────────
    'settings_title': 'Settings',
    'settings_section_general': 'General',
    'settings_section_display': 'Display',
    'settings_section_performance': 'Performance',
    'settings_section_custom': 'Custom',
    'settings_section_permissions': 'Permissions',
    'settings_section_connection': 'Connection',
    'settings_section_about': 'About',

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
    'settings_show_hud': 'Show HUD (fps / latency / disconnect)',

    // ── Settings: custom ────────────────────────────────────────────────
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
    'common_connected': 'เชื่อมต่อแล้ว',
    'common_open': 'เปิด',
    'common_refresh': 'รีเฟรช',

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

    // ── Home ────────────────────────────────────────────────────────────
    'home_open_view': 'เปิดหน้าจอ',
    'home_waiting_for_stream': 'กำลังรอสัญญาณสตรีม…',

    // ── Connection card ─────────────────────────────────────────────────
    'conn_card_active_subtitle': 'USB-C  •  @codec',
    'conn_card_plug_prompt': 'เสียบแท็บเล็ตด้วยสาย USB-C',

    // ── Connection steps (client) ───────────────────────────────────────
    'step_connect_label': 'เชื่อมต่อกับโฮสต์ Mac',
    'step_connect_detail': 'กำลังเชื่อมผ่านอุโมงค์ USB-C',
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

    // ── Display view ────────────────────────────────────────────────────
    'display_reconnecting': 'กำลังเชื่อมต่อใหม่…',
    'display_applying_settings': 'กำลังใช้การตั้งค่าใหม่จากโฮสต์',
    'display_surface_android_only': 'พื้นที่แสดงผล\n(เฉพาะ Android)',

    // ── Settings: sections ──────────────────────────────────────────────
    'settings_title': 'การตั้งค่า',
    'settings_section_general': 'ทั่วไป',
    'settings_section_display': 'การแสดงผล',
    'settings_section_performance': 'ประสิทธิภาพ',
    'settings_section_custom': 'กำหนดเอง',
    'settings_section_permissions': 'สิทธิ์การเข้าถึง',
    'settings_section_connection': 'การเชื่อมต่อ',
    'settings_section_about': 'เกี่ยวกับ',

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
    'settings_show_hud': 'แสดง HUD (fps / ดีเลย์ / ตัดการเชื่อมต่อ)',

    // ── Settings: custom ────────────────────────────────────────────────
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
