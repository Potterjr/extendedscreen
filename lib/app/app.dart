import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'routes/app_pages.dart';
import 'bindings/initial_binding.dart';
import 'theme/app_theme.dart';
import '../core/services/settings_service.dart';

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
