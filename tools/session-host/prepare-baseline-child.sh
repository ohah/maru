#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo 'usage: prepare-baseline-child.sh <default-false|signed-app-quit> <absolute-home> <absolute-output>' >&2
    exit 64
fi

kind=$1
home=$2
output=$3
case "$kind" in
    default-false)
        home_name=default-false
        output_name=default-false.json
        ;;
    signed-app-quit)
        home_name=signed-app-quit
        output_name=signed-app-quit.json
        ;;
    *)
        exit 64
        ;;
esac

valid_path() {
    path=$1
    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$path" in
        /|*/|*//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    case "$path" in
        *"
"*) return 1 ;;
    esac
    return 0
}

valid_path "$home" || exit 64
valid_path "$output" || exit 64
root=${home%/*}
[ "$home" = "$root/$home_name" ] || exit 64
[ "$output" = "$root/$output_name" ] || exit 64
[ "$home" != "$output" ] || exit 64

stat_uid() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f %u "$1"
    else
        stat -c %u "$1"
    fi
}

stat_mode() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f %Lp "$1"
    else
        stat -c %a "$1"
    fi
}

[ -d "$root" ] && [ ! -L "$root" ] || exit 73
[ "$(stat_uid "$root")" = "$(id -u)" ] || exit 73
[ "$(stat_mode "$root")" = 700 ] || exit 73
[ ! -e "$home" ] && [ ! -L "$home" ] || exit 73
[ ! -e "$output" ] && [ ! -L "$output" ] || exit 73

umask 077
mkdir -m 700 "$home"
mkdir -m 700 "$home/.config"
mkdir -m 700 "$home/.config/maru"
if [ "$kind" = signed-app-quit ]; then
    mkdir -m 700 "$home/captures"
    printf '%s\n' 'session.keep-alive-after-quit = true' > "$home/.config/maru/config"
fi
