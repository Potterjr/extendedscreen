#!/bin/sh
# Checks RemoteVideoPlugin's RemoteDecoder (the Mac's decoder for a tablet's
# screen) outside the app: nothing of the app is run, no device is used.
#
#   tool/remote_decoder_check/run.sh [path/to/RemoteVideoPlugin.swift]
#
# The plugin has no unit tests (RunnerTests would start the app), so this
# compiles the plugin file with harness.swift appended, against the
# FlutterMacOS framework of the `flutter` on PATH, and feeds a decoder
# 320x240 H.264 keyframes from a software encoder. It plays a session that
# has died (a wake) by invalidating it: the keyframe that finds it dead has
# to be decoded all the same. Uses one small VideoToolbox decoder for a
# second or two. Exit status 0 when every check holds.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
plugin=${1:-"$here/../../macos/Runner/RemoteVideoPlugin.swift"}
flutter=$(command -v flutter) || { echo "flutter is not on PATH" >&2; exit 2; }
while [ -L "$flutter" ]; do
    target=$(readlink "$flutter")
    case $target in
        /*) flutter=$target ;;
        *) flutter=$(dirname "$flutter")/$target ;;
    esac
done
frameworks=$(cd "$(dirname "$flutter")" && pwd)/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64
if ! [ -d "$frameworks/FlutterMacOS.framework" ]; then
    echo "no FlutterMacOS.framework in $frameworks (run flutter precache --macos)" >&2
    exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat "$plugin" "$here/harness.swift" > "$work/check.swift"
swiftc -suppress-warnings -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    "$work/check.swift" -o "$work/check"
"$work/check"
