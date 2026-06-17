import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/features/splash/bindings/splash_binding.dart';
import 'package:extendedscreen/shared/features/splash/views/splash_view.dart';
import 'package:extendedscreen/shared/features/launcher/bindings/launcher_binding.dart';
import 'package:extendedscreen/shared/features/launcher/views/launcher_view.dart';
import 'package:extendedscreen/shared/features/home/bindings/home_binding.dart';
import 'package:extendedscreen/shared/features/home/views/home_view.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/bindings/display_binding.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/views/display_view.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/bindings/remote_host_binding.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/views/remote_host_view.dart';
import 'package:extendedscreen/shared/features/settings/bindings/settings_binding.dart';
import 'package:extendedscreen/shared/features/settings/views/settings_view.dart';

abstract class AppPages {
  static const initial = AppRoutes.splash;

  static final routes = <GetPage>[
    GetPage(
      name: AppRoutes.splash,
      page: () => const SplashView(),
      binding: SplashBinding(),
    ),
    GetPage(
      name: AppRoutes.launcher,
      page: () => const LauncherView(),
      binding: LauncherBinding(),
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
      name: AppRoutes.remoteHost,
      page: () => const RemoteHostView(),
      binding: RemoteHostBinding(),
    ),
    GetPage(
      name: AppRoutes.settings,
      page: () => const SettingsView(),
      binding: SettingsBinding(),
    ),
  ];
}
