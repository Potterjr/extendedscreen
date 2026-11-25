import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/features/splash/bindings/splash_binding.dart';
import 'package:extendedscreen/shared/features/splash/views/splash_view.dart';
import 'package:extendedscreen/shared/features/home/bindings/home_binding.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/bindings/display_binding.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/views/display_view.dart';
import 'package:extendedscreen/shared/features/settings/bindings/settings_binding.dart';
import 'package:extendedscreen/shared/features/settings/views/settings_view.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_controller.dart';
import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_view.dart';

abstract class AppPages {
  static const initial = AppRoutes.splash;

  static final routes = <GetPage>[
    GetPage(
      name: AppRoutes.splash,
      page: () => const SplashView(),
      binding: SplashBinding(),
    ),
    GetPage(
      name: AppRoutes.home,
      page: () => const HomeView(),
      binding: HomeBinding(),
    ),
    GetPage(
      name: AppRoutes.display,
      page: () => const DisplayView(),
      binding: DisplayBinding(),
    ),
    GetPage(
      name: AppRoutes.settings,
      page: () => const SettingsView(),
      binding: SettingsBinding(),
    ),
    // A const condition: only a debug build with synthetic tablets has it.
    if (synthTablets)
      GetPage(
        name: AppRoutes.loopbackPreview,
        page: () => const LoopbackPreviewView(),
        binding: BindingsBuilder.put(LoopbackPreviewController.new),
      ),
  ];
}
