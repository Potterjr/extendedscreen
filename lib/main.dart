import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/app.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The client is a second monitor — it only ever renders landscape (also
  // enforced by android:screenOrientation in the manifest, and on iOS by
  // Info.plist's supported orientations).
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  // Load settings before the app builds so the saved UI language is applied
  // on the first frame (GetMaterialApp reads SettingsService.locale at build).
  final settings = SettingsService();
  await settings.init();
  Get.put<SettingsService>(settings, permanent: true);
  runApp(const ExtendedScreenApp());
}
