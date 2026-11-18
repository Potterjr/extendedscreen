# Flutter's Gradle plugin adds this file to the release build's R8 rules.

# Started by the Mac through adb (`app_process`), never referenced from the
# app itself, so R8 would otherwise drop it (see ScreenPower.kt).
-keep class com.example.extendedscreen.tools.** { *; }
