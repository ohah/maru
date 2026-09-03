#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
prepare="$repo_root/tools/session-host/prepare-baseline-child.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/maru-baseline-child-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tmp=$(CDPATH= cd -- "$tmp" && pwd -P)

private_root() {
    mkdir -m 700 "$1"
}

stat_mode() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f %Lp "$1"
    else
        stat -c %a "$1"
    fi
}

root="$tmp/success"
private_root "$root"
sh "$prepare" default-false "$root/default-false" "$root/default-false.json"
[ "$(stat_mode "$root/default-false")" = 700 ]
[ -d "$root/default-false/.config/maru" ]
[ ! -e "$root/default-false/.config/maru/config" ]
[ ! -e "$root/default-false.json" ]

root="$tmp/signed"
private_root "$root"
sh "$prepare" signed-app-quit "$root/signed-app-quit" "$root/signed-app-quit.json"
[ "$(stat_mode "$root/signed-app-quit")" = 700 ]
[ "$(cat "$root/signed-app-quit/.config/maru/config")" = 'session.keep-alive-after-quit = true' ]
[ ! -e "$root/signed-app-quit.json" ]

root="$tmp/existing-output"
private_root "$root"
printf '%s\n' sentinel > "$root/default-false.json"
if sh "$prepare" default-false "$root/default-false" "$root/default-false.json"; then
    echo 'existing output was accepted' >&2
    exit 1
fi
[ "$(cat "$root/default-false.json")" = sentinel ]
[ ! -e "$root/default-false" ]

root="$tmp/existing-home"
private_root "$root"
mkdir -m 700 "$root/signed-app-quit"
printf '%s\n' sentinel > "$root/signed-app-quit/foreign"
if sh "$prepare" signed-app-quit "$root/signed-app-quit" "$root/signed-app-quit.json"; then
    echo 'existing home was accepted' >&2
    exit 1
fi
[ "$(cat "$root/signed-app-quit/foreign")" = sentinel ]

root="$tmp/alias"
private_root "$root"
if sh "$prepare" default-false "$root/default-false" "$root/default-false"; then
    echo 'HOME/output alias was accepted' >&2
    exit 1
fi
[ -z "$(find "$root" -mindepth 1 -print -quit)" ]

if sh "$prepare" default-false relative/default-false relative/default-false.json; then
    echo 'relative paths were accepted' >&2
    exit 1
fi
[ ! -e "$repo_root/relative" ]

if sh "$prepare" default-false "$tmp/missing/default-false"; then
    echo 'missing output option was accepted' >&2
    exit 1
fi

root="$tmp/public-root"
mkdir -m 755 "$root"
if sh "$prepare" default-false "$root/default-false" "$root/default-false.json"; then
    echo 'non-private root was accepted' >&2
    exit 1
fi
[ -z "$(find "$root" -mindepth 1 -print -quit)" ]

private_root "$tmp/real-root"
ln -s "$tmp/real-root" "$tmp/symlink-root"
if sh "$prepare" default-false "$tmp/symlink-root/default-false" "$tmp/symlink-root/default-false.json"; then
    echo 'symlink root was accepted' >&2
    exit 1
fi
[ -z "$(find "$tmp/real-root" -mindepth 1 -print -quit)" ]

root="$tmp/traversal"
private_root "$root"
if sh "$prepare" default-false "$root/child/../default-false" "$root/default-false.json"; then
    echo 'traversal path was accepted' >&2
    exit 1
fi
[ -z "$(find "$root" -mindepth 1 -print -quit)" ]

echo 'session-host baseline child path tests passed'
