import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/features/splash/bindings/splash_binding.dart';
import 'package:extendedscreen/features/splash/views/splash_view.dart';
import 'package:extendedscreen/features/home/bindings/home_binding.dart';
import 'package:extendedscreen/features/home/views/home_view.dart';
import 'package:extendedscreen/features/display/bindings/display_binding.dart';
import 'package:extendedscreen/features/display/views/display_view.dart';
import 'package:extendedscreen/features/settings/bindings/settings_binding.dart';
import 'package:extendedscreen/features/settings/views/settings_view.dart';

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
  ];
}
