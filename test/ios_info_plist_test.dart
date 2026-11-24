import 'dart:io';

import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:flutter_test/flutter_test.dart';

/// The iOS app's container is the channel the Mac's pairing travels through
/// (devicectl writes it), so nothing else may be able to write into it: no
/// file sharing, no opening documents in place, no document types (Finder,
/// Files or AirDrop could otherwise plant a pairing).
void main() {
  final plist = File('ios/Runner/Info.plist');

  String keyed(String key) => '<key>$key</key>';

  test('Info.plist opens the container to nothing', () {
    final text = plist.readAsStringSync();
    for (final key in const [
      'UIFileSharingEnabled',
      'LSSupportsOpeningDocumentsInPlace',
      'CFBundleDocumentTypes',
    ]) {
      expect(text.contains(key), isFalse, reason: '$key must never be set');
    }
  });

  test('Info.plist is landscape-only and asks for the local network', () {
    final text = plist.readAsStringSync();
    expect(text.contains(keyed('NSLocalNetworkUsageDescription')), isTrue);
    expect(text.contains('UIInterfaceOrientationPortrait'), isFalse);
    for (final key in const [
      'UISupportedInterfaceOrientations~iphone',
      'UISupportedInterfaceOrientations~ipad',
      'CADisableMinimumFrameDurationOnPhone',
      'UIStatusBarHidden',
      'UIRequiresFullScreen',
    ]) {
      expect(text.contains(keyed(key)), isTrue, reason: '$key is missing');
    }
  });

  test('the Dart bundle id is the Xcode project\'s', () {
    final project =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
        .allMatches(project)
        .map((m) => m.group(1)!)
        .where((id) => !id.endsWith('.RunnerTests'))
        .toSet();
    expect(ids, {iosBundleId});
  });
}
