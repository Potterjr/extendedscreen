abstract class AppRoutes {
  static const splash = '/';
  static const home = '/home';
  static const display = '/display';
  static const remoteHost = '/remote-host';
  static const settings = '/settings';

  /// Mac: an iPhone or iPad over USB, seen and driven.
  static const iphoneRemote = '/iphone-remote';

  /// Debug builds with synthetic tablets only (`SYNTH_TABLETS`).
  static const loopbackPreview = '/loopback-preview';
}
