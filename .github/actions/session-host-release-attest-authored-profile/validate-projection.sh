#!/bin/bash
set -euo pipefail

[[ $# -eq 7 ]]
evidence_path=$1
evidence_name=$2
manifest_path=$3
manifest_name=$4
timing_required=$5
timing_path=$6
timing_name=$7

export LC_ALL=C

valid_scalar() {
    [[ -n "$1" && "$1" != *[[:cntrl:]]* ]] || return 1
}

valid_path() {
    valid_scalar "$1" || return 1
    [[ "$1" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
    [[ "$1" != */ && "$1" != *//* ]] || return 1
    case "/${1#/}/" in
        */./*|*/../*) return 1 ;;
    esac
}

valid_subject() {
    valid_path "$1" || return 1
    valid_scalar "$2" || return 1
    [[ "$2" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    [[ "${1##*/}" == "$2" ]] || return 1
}

related() {
    [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
}

valid_subject "$evidence_path" "$evidence_name" || exit 1
valid_subject "$manifest_path" "$manifest_name" || exit 1
[[ "$evidence_path" != "$manifest_path" ]] || exit 1
[[ "${evidence_path%/*}" == "${manifest_path%/*}" ]] || exit 1
[[ "$manifest_name" =~ ^Maru-[0-9]+\.[0-9]+\.[0-9]+-session-host-release\.json$ ]] || exit 1

case "$timing_required:$timing_path:$timing_name" in
    false::)
        [[ "$evidence_name" == baseline-evidence.json ]] || exit 1
        ;;
    true:?*:profile-upgrade-timing.json)
        [[ "$evidence_name" == upgrade-evidence.json ]] || exit 1
        valid_subject "$timing_path" "$timing_name" || exit 1
        [[ "$timing_path" != "$evidence_path" && "$timing_path" != "$manifest_path" ]] || exit 1
        ! related "${evidence_path%/*}" "$timing_path" || exit 1
        ;;
    *) exit 1 ;;
esac
