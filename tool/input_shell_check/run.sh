#!/bin/sh
# Checks AdbManagerPlugin's input shell (reverse-remote taps and swipes)
# against a fake adb: no device, no real adb, nothing of the app is run.
#
#   tool/input_shell_check/run.sh [path/to/AdbManagerPlugin.swift]
#
# The plugin has no unit tests (RunnerTests would start the app), so this
# takes the section between its "MARK: - Input shell" and "MARK: - ADB
# helpers" lines as it is, compiles it into harness.swift beside stand-ins
# for adbPath/adbRun/adbLogLine, and plays the scenarios in that file. The
# fake adb's `shell -T` is a local /bin/sh reading stdin, and its `input`
# sleeps for the cost in cost.<serial> and then notes the event in
# landed.log. Exit status 0 when every check holds. Takes about 20 s.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
plugin=${1:-"$here/../../macos/Runner/AdbManagerPlugin.swift"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

awk '/\/\/ MARK: - Input shell/ { on = 1 } /\/\/ MARK: - ADB helpers/ { on = 0 } on' \
    "$plugin" > "$work/section.swift"
if ! [ -s "$work/section.swift" ]; then
    echo "no input shell section found in $plugin" >&2
    exit 2
fi
awk -v part="$work/section.swift" '
    /\/\/%INPUT_SHELL%/ { while ((getline line < part) > 0) print line; next }
    { print }' "$here/harness.swift" > "$work/check.swift"

mkdir "$work/bin"
cat > "$work/adb" <<'ADB'
#!/bin/sh
# adb -s SERIAL shell -T              the device's sh, reading stdin
# adb -s SERIAL shell input ARGS...   one event
dir=$(dirname "$0")
[ "${1:-}" = "-s" ] && [ "${3:-}" = "shell" ] || exit 1
ES_SERIAL=$2
ES_DIR=$dir
PATH="$dir/bin:$PATH"
export ES_SERIAL ES_DIR PATH
shift 3
if [ "$#" -eq 1 ] && [ "$1" = "-T" ]; then
    echo "$ES_SERIAL" >> "$dir/shells.log"
    ES_VIA=shell
    export ES_VIA
    exec /bin/sh
fi
[ "${1:-}" = "input" ] || exit 1
shift
ES_VIA=oneoff
export ES_VIA
exec "$dir/bin/input" "$@"
ADB
cat > "$work/bin/input" <<'INPUT'
#!/bin/sh
# tap X Y | swipe X1 Y1 X2 Y2 MS. X (X1) 999 never comes back in time.
cost=$(cat "$ES_DIR/cost.$ES_SERIAL" 2>/dev/null || echo 0.02)
[ "$2" = "999" ] && cost=12
[ "$1" = "swipe" ] && sleep "$(echo "$6" | awk '{ print $1 / 1000 }')"
sleep "$cost"
echo "$ES_SERIAL $ES_VIA $*" >> "$ES_DIR/landed.log"
INPUT
chmod +x "$work/adb" "$work/bin/input"

swiftc "$work/check.swift" -o "$work/check"
# macOS looks a new script over the first time it runs, which takes a
# moment: not something to measure as the tablet's `input`.
"$work/adb" -s warm shell input tap 0 0
echo 'input tap 0 0' | "$work/adb" -s warm shell -T
"$work/check" "$work"
