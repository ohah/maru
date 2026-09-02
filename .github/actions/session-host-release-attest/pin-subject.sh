#!/bin/bash
set -euo pipefail

observe() {
    local subject_path=$1
    local subject_name=$2
    [[ "$subject_path" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
    [[ "$subject_name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    [[ -f "$subject_path" && ! -L "$subject_path" ]] || return 1
    local canonical_dir canonical_name canonical
    canonical_dir=$(/usr/bin/dirname "$subject_path") || return 1
    canonical_name=$(/usr/bin/basename "$subject_path") || return 1
    canonical_dir=$(cd "$canonical_dir" && pwd -P) || return 1
    canonical="$canonical_dir/$canonical_name"
    [[ "$canonical" == "$subject_path" ]] || return 1
    [[ "$canonical_name" == "$subject_name" ]] || return 1
    local device inode size links sha256
    case $(/usr/bin/uname -s) in
        Darwin)
            read -r device inode size links <<< "$(/usr/bin/stat -f '%d %i %z %l' "$subject_path")" || return 1
            sha256=$(/usr/bin/shasum -a 256 "$subject_path" | /usr/bin/awk '{print $1}') || return 1
            ;;
        Linux)
            read -r device inode size links <<< "$(/usr/bin/stat -c '%d %i %s %h' "$subject_path")" || return 1
            sha256=$(/usr/bin/sha256sum "$subject_path" | /usr/bin/awk '{print $1}') || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && "$links" == 1 ]] || return 1
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$device" "$inode" "$size" "$links" "$sha256"
}

case ${1-} in
    pin)
        [[ $# -eq 3 ]]
        observation=$(observe "$2" "$3")
        device=$(printf '%s\n' "$observation" | /usr/bin/sed -n '1p')
        inode=$(printf '%s\n' "$observation" | /usr/bin/sed -n '2p')
        size=$(printf '%s\n' "$observation" | /usr/bin/sed -n '3p')
        links=$(printf '%s\n' "$observation" | /usr/bin/sed -n '4p')
        sha256=$(printf '%s\n' "$observation" | /usr/bin/sed -n '5p')
        [[ -n "$device" && -n "$inode" && -n "$size" && "$links" == 1 && -n "$sha256" ]]
        printf 'device=%s\ninode=%s\nsize=%s\nlinks=%s\nsha256=%s\n' "$device" "$inode" "$size" "$links" "$sha256"
        ;;
    verify)
        [[ $# -eq 8 ]]
        [[ "$4" =~ ^[0-9]+$ && "$5" =~ ^[0-9]+$ && "$6" =~ ^[0-9]+$ && "$7" == 1 && "$8" =~ ^[0-9a-f]{64}$ ]]
        observation=$(observe "$2" "$3")
        device=$(printf '%s\n' "$observation" | /usr/bin/sed -n '1p')
        inode=$(printf '%s\n' "$observation" | /usr/bin/sed -n '2p')
        size=$(printf '%s\n' "$observation" | /usr/bin/sed -n '3p')
        links=$(printf '%s\n' "$observation" | /usr/bin/sed -n '4p')
        sha256=$(printf '%s\n' "$observation" | /usr/bin/sed -n '5p')
        [[ "$device" == "$4" && "$inode" == "$5" && "$size" == "$6" && "$links" == "$7" && "$sha256" == "$8" ]]
        ;;
    *)
        exit 2
        ;;
esac
