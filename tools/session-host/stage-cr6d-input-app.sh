#!/bin/sh
# CR6d uses product payload in a separate TCC identity. Never reset or modify
# the user's dev.maru.apphost permission or the product bundle itself.
set -eu

if [ "$#" -ne 2 ]; then
    echo 'usage: stage-cr6d-input-app.sh <product-app> <test-app>' >&2
    exit 2
fi
source_app=$1
target_app=$2
case ${HOME:-} in
    /*) ;;
    *) echo 'CR6d staging needs an absolute user home' >&2; exit 2 ;;
esac
if [ "$HOME" = / ] || [ "$target_app" != "$HOME/Applications/MaruCR6DInputSmoke.app" ]; then
    echo 'CR6d staging target is not the isolated test app' >&2
    exit 2
fi
if [ -L "$HOME/Applications" ]; then
    echo 'CR6d user Applications directory is a symlink' >&2
    exit 2
fi
mkdir -p "$HOME/Applications"
if [ ! -d "$source_app" ] || [ -L "$source_app" ]; then
    echo 'CR6d product app is missing or a symlink' >&2
    exit 2
fi
if [ -L "$target_app" ]; then
    echo 'CR6d test app target is a symlink' >&2
    exit 2
fi

codesign --verify --strict --deep "$source_app"
product_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
if [ "$product_id" != dev.maru.apphost ]; then
    echo 'CR6d source is not the product app' >&2
    exit 2
fi

stage_dir=$(mktemp -d "$HOME/Applications/.maru-cr6d-stage.XXXXXX")
case "$stage_dir" in
    "$HOME"/Applications/.maru-cr6d-stage.*) ;;
    *) echo 'CR6d staging directory escaped its test parent' >&2; exit 2 ;;
esac
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM
candidate_app=$stage_dir/MaruCR6DInputSmoke.app
/usr/bin/ditto "$source_app" "$candidate_app"
/usr/bin/diff -qr "$source_app" "$candidate_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.maru.apphost.cr6d-input-smoke' "$candidate_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Maru CR6D Test' "$candidate_app/Contents/Info.plist"
codesign --force --sign - "$candidate_app"
codesign --verify --strict --deep "$candidate_app"
candidate_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_app/Contents/Info.plist")
if [ "$candidate_id" != dev.maru.apphost.cr6d-input-smoke ]; then
    echo 'CR6d test app identity drifted' >&2
    exit 2
fi
/usr/bin/diff -qr "$source_app/Contents/Helpers" "$candidate_app/Contents/Helpers"
/usr/bin/diff -qr "$source_app/Contents/Resources" "$candidate_app/Contents/Resources"

if [ -d "$target_app" ] && /usr/bin/diff -qr "$candidate_app" "$target_app" >/dev/null; then
    codesign --verify --strict --deep "$target_app"
    swift tools/session-host/register-cr6d-input-app.swift "$target_app"
    exit 0
fi
if [ -e "$target_app" ] || [ -L "$target_app" ]; then
    old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")
    if [ "$old_id" != dev.maru.apphost.cr6d-input-smoke ]; then
        echo 'CR6d target is occupied by a different app' >&2
        exit 2
    fi
    rm -rf "$target_app"
fi
mv "$candidate_app" "$target_app"
codesign --verify --strict --deep "$target_app"
swift tools/session-host/register-cr6d-input-app.swift "$target_app"
