#!/bin/sh
set -eu

state=${FAKE_GH_STATE:?}
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/calls"

test "${1:-}" = release
command=${2:-}
tag=${3:-}

case "$command" in
    create)
        test ! -e "$state/exists" || exit 1
        test "$4" = --draft
        test "$5" = --verify-tag
        : > "$state/exists"
        printf 'true\n' > "$state/draft"
        if test "${FAKE_GH_PRELOAD_ASSET:-0}" = 1; then
            printf 'occupied\n' > "$state/asset"
            printf 'Maru-%s-universal.dmg\n' "${tag#v}" > "$state/asset_name"
        fi
        ;;
    upload)
        test -e "$state/exists"
        test ! -e "$state/asset" || exit 1
        cp "$4" "$state/asset"
        basename "$4" > "$state/asset_name"
        ;;
    view)
        test -e "$state/exists"
        test "$4" = --json
        test "$6" = --jq
        case "$7" in
            .isDraft) cat "$state/draft" ;;
            .assets\[\].name) test -e "$state/asset_name" && cat "$state/asset_name" ;;
            *) exit 2 ;;
        esac
        ;;
    download)
        test -e "$state/asset"
        test "$4" = --pattern
        test "$6" = --dir
        cp "$state/asset" "$7/$5"
        if test "${FAKE_GH_CORRUPT_DOWNLOAD:-0}" = 1; then
            printf 'corrupt\n' >> "$7/$5"
        fi
        ;;
    edit)
        test -e "$state/exists"
        test "$4" = --draft=false
        printf 'false\n' > "$state/draft"
        ;;
    *) exit 2 ;;
esac
