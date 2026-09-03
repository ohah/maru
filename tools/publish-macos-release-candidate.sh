#!/bin/sh
# Publish the already verified universal product as one indivisible staging unit for
# session-host release evidence. This helper deliberately does not establish signing
# authority; its caller must finish codesign, notarization, and staple checks first.
set -eu

if [ "$#" -ne 4 ]; then
    echo 'usage: publish-macos-release-candidate.sh <Maru.app> <dmg> <version> <output-dir>' >&2
    exit 64
fi

app=$1
dmg=$2
version=$3
output_dir=$4

old_ifs=$IFS
set -f
IFS=.
set -- $version
IFS=$old_ifs
test "$#" -eq 3
for component in "$@"; do
    case "$component" in
        ''|*[!0-9]*) exit 65 ;;
    esac
    case "$component" in
        0) ;;
        0*) exit 65 ;;
    esac
done

app_executable="$app/Contents/MacOS/maru-macos-app"
test -d "$app"
test ! -L "$app"
test -f "$app_executable"
test ! -L "$app_executable"
test -x "$app_executable"
test -f "$dmg"
test ! -L "$dmg"

if [ -e "$output_dir" ]; then
    test -d "$output_dir"
    test ! -L "$output_dir"
else
    mkdir -p "$output_dir"
fi

final="$output_dir/session-host-candidate-$version"
test ! -e "$final"
test ! -L "$final"

stage=$(mktemp -d "$output_dir/.session-host-candidate-$version.XXXXXX")
published=0
cleanup() {
    if [ -n "$stage" ]; then
        rm -rf -- "$stage"
    fi
    if [ "$published" -eq 1 ]; then
        rm -rf -- "$final"
    fi
}
trap cleanup EXIT HUP INT TERM

/usr/bin/ditto "$app" "$stage/Maru.app"
cp "$dmg" "$stage/Maru-$version-universal.dmg"
cp "$app_executable" "$stage/maru-session-host-$version"
chmod 755 "$stage/maru-session-host-$version"

staged_executable="$stage/Maru.app/Contents/MacOS/maru-macos-app"
cmp "$app_executable" "$staged_executable"
cmp "$dmg" "$stage/Maru-$version-universal.dmg"
cmp "$staged_executable" "$stage/maru-session-host-$version"

mv "$stage" "$final"
stage=
published=1

# Re-open final pathnames so a bad or partial publication cannot be reported as usable.
test -d "$final/Maru.app"
test -f "$final/Maru-$version-universal.dmg"
test -x "$final/maru-session-host-$version"
cmp "$final/Maru.app/Contents/MacOS/maru-macos-app" "$final/maru-session-host-$version"
cmp "$dmg" "$final/Maru-$version-universal.dmg"

published=0
trap - EXIT HUP INT TERM
printf '%s\n' "$final"
