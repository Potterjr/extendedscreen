import 'package:flutter/foundation.dart';

import 'package:extendedscreen/shared/platform/ios_app.dart';

/// This build is the Windows client: a Wi-Fi viewer of the Mac with a real
/// mouse (see `docs/windows-start.md`). Read through [defaultTargetPlatform],
/// so a test can play it with `debugDefaultTargetPlatformOverride`; in a
/// release build it is the real platform.
bool get runsOnWindows => defaultTargetPlatform == TargetPlatform.windows;

/// A client that only ever reaches the Mac over Wi-Fi: the iOS client and the
/// Windows client (neither has adb). Its link is forced to Wi-Fi and Home
/// shows no link selector.
bool get wifiOnlyClient => runsOnIos || runsOnWindows;
