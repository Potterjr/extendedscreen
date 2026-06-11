import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_pages.dart';
import 'package:extendedscreen/app/bindings/initial_binding.dart';
import 'package:extendedscreen/app/theme/app_theme.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class ExtendedScreenApp extends StatelessWidget {
  const ExtendedScreenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Extended Screen',
      theme: AppTheme.dark,
      initialBinding: InitialBinding(),
      initialRoute: AppPages.initial,
      getPages: AppPages.routes,
      translations: AppTranslations(),
      locale: Get.find<SettingsService>().locale,
      fallbackLocale: const Locale('en'),
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Obx(() {
          final show = Get.find<SettingsService>().showPerformanceOverlay.value;
          if (!show) return child!;
          return Stack(
            children: [
              child!,
              PerformanceOverlay.allEnabled(),
            ],
          );
        });
      },
    );
  }
}
