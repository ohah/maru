#!/bin/sh
set -eu

validate_version() {
    printf '%s\n' "$1" | awk '
        /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ { ok = 1 }
        END { exit ok ? 0 : 1 }
    ' || {
        echo "error: invalid release version: $1" >&2
        exit 1
    }
}

count_occurrences() {
    awk -v needle="$1" '
        {
            rest = $0
            while ((at = index(rest, needle)) != 0) {
                count++
                rest = substr(rest, at + length(needle))
            }
        }
        END { print count + 0 }
    ' "$2"
}

case "${1:-}" in
    render)
        test "$#" = 4 || { echo 'usage: render TEMPLATE OUTPUT VERSION' >&2; exit 2; }
        template=$2
        output=$3
        version=$4
        validate_version "$version"
        test "$(count_occurrences '@@MARU_VERSION@@' "$template")" = 1 || {
            echo 'error: plist template must contain exactly one @@MARU_VERSION@@' >&2
            exit 1
        }
        tmp="${output}.tmp.$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        sed "s/@@MARU_VERSION@@/$version/" "$template" > "$tmp"
        test "$(grep -c "<string>$version</string>" "$tmp")" = 1
        ! grep -q '@@MARU_VERSION@@' "$tmp"
        mv "$tmp" "$output"
        trap - EXIT HUP INT TERM
        ;;
    check-tag)
        test "$#" = 3 || { echo 'usage: check-tag VERSION TAG' >&2; exit 2; }
        version=$2
        tag=$3
        validate_version "$version"
        test "$tag" = "v$version" || {
            echo "error: release tag $tag does not match version v$version" >&2
            exit 1
        }
        ;;
    *)
        echo 'usage: render-macos-info-plist.sh render TEMPLATE OUTPUT VERSION | check-tag VERSION TAG' >&2
        exit 2
        ;;
esac
