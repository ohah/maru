#!/bin/bash
set -euo pipefail

bundle_max_bytes=16777216

observe() {
    local pathname=$1 expected_name=$2 canonical_dir canonical_name canonical system
    [[ "$pathname" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
    [[ "$expected_name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    test -f "$pathname" && test ! -L "$pathname"
    canonical_dir=$(/usr/bin/dirname "$pathname")
    canonical_name=$(/usr/bin/basename "$pathname")
    canonical_dir=$(cd "$canonical_dir" && pwd -P)
    canonical="$canonical_dir/$canonical_name"
    test "$canonical" = "$pathname"
    test "$canonical_name" = "$expected_name"
    system=$(/usr/bin/uname -s)
    case "$system" in
        Darwin) set -- $(/usr/bin/stat -f '%d %i %z %l' "$pathname") ;;
        Linux) set -- $(/usr/bin/stat -c '%d %i %s %h' "$pathname") ;;
        *) return 1 ;;
    esac
    test "$#" -eq 4
    obs_device=$1
    obs_inode=$2
    obs_size=$3
    obs_links=$4
    test "$obs_links" = 1
    case "$system" in
        Darwin) obs_sha256=$(/usr/bin/shasum -a 256 "$pathname" | /usr/bin/awk '{print $1}') ;;
        Linux) obs_sha256=$(/usr/bin/sha256sum "$pathname" | /usr/bin/awk '{print $1}') ;;
    esac
    case "$obs_sha256" in *[!0-9a-f]*|'') return 1 ;; esac
    test "${#obs_sha256}" -eq 64
}

emit() {
    local prefix=$1
    printf '%s_device=%s\n' "$prefix" "$obs_device"
    printf '%s_inode=%s\n' "$prefix" "$obs_inode"
    printf '%s_size=%s\n' "$prefix" "$obs_size"
    printf '%s_links=%s\n' "$prefix" "$obs_links"
    printf '%s_sha256=%s\n' "$prefix" "$obs_sha256"
}

assert_snapshot() {
    local pathname=$1 name=$2 device=$3 inode=$4 size=$5 links=$6 sha256=$7
    observe "$pathname" "$name"
    test "$obs_device" = "$device"
    test "$obs_inode" = "$inode"
    test "$obs_size" = "$size"
    test "$obs_links" = "$links"
    test "$obs_sha256" = "$sha256"
}

command=${1-}
case "$command" in
    pin)
        test "$#" -eq 5
        dmg_path=$2; dmg_name=$3; frozen_path=$4; frozen_name=$5
        observe "$dmg_path" "$dmg_name"
        dmg_key="$obs_device:$obs_inode"
        dmg_device=$obs_device; dmg_inode=$obs_inode; dmg_size=$obs_size; dmg_links=$obs_links; dmg_sha256=$obs_sha256
        observe "$frozen_path" "$frozen_name"
        frozen_key="$obs_device:$obs_inode"
        test "$dmg_key" != "$frozen_key"
        frozen_device=$obs_device; frozen_inode=$obs_inode; frozen_size=$obs_size; frozen_links=$obs_links; frozen_sha256=$obs_sha256
        obs_device=$dmg_device; obs_inode=$dmg_inode; obs_size=$dmg_size; obs_links=$dmg_links; obs_sha256=$dmg_sha256
        emit dmg
        obs_device=$frozen_device; obs_inode=$frozen_inode; obs_size=$frozen_size; obs_links=$frozen_links; obs_sha256=$frozen_sha256
        emit frozen
        ;;
    verify)
        test "$#" -eq 17
        dmg_path=$2; dmg_name=$3; frozen_path=$4; frozen_name=$5
        assert_snapshot "$dmg_path" "$dmg_name" "$6" "$7" "$8" "$9" "${10}"
        dmg_key="$obs_device:$obs_inode"
        assert_snapshot "$frozen_path" "$frozen_name" "${11}" "${12}" "${13}" "${14}" "${15}"
        frozen_key="$obs_device:$obs_inode"
        test "$dmg_key" != "$frozen_key"
        dmg_bundle=${16}; frozen_bundle=${17}
        observe "$dmg_bundle" "${dmg_bundle##*/}"
        test "$obs_size" -gt 0 && test "$obs_size" -le "$bundle_max_bytes"
        dmg_bundle_key="$obs_device:$obs_inode"
        observe "$frozen_bundle" "${frozen_bundle##*/}"
        test "$obs_size" -gt 0 && test "$obs_size" -le "$bundle_max_bytes"
        frozen_bundle_key="$obs_device:$obs_inode"
        test "$dmg_key" != "$dmg_bundle_key"
        test "$dmg_key" != "$frozen_bundle_key"
        test "$frozen_key" != "$dmg_bundle_key"
        test "$frozen_key" != "$frozen_bundle_key"
        test "$dmg_bundle_key" != "$frozen_bundle_key"
        printf 'dmg-bundle-path=%s\n' "$dmg_bundle"
        printf 'frozen-bundle-path=%s\n' "$frozen_bundle"
        ;;
    *) exit 1 ;;
esac
