#!/bin/bash
set -euo pipefail

bundle_max_bytes=16777216

valid_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/+:-]+$ ]]
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]
}

canonical_path() {
    local path=$1
    local parent name canonical_parent
    parent=$(/usr/bin/dirname "$path") || return 1
    name=$(/usr/bin/basename "$path") || return 1
    canonical_parent=$(cd "$parent" && pwd -P) || return 1
    printf '%s/%s\n' "$canonical_parent" "$name"
}

directory_observation() {
    local path=$1
    valid_path "$path" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    [[ "$(canonical_path "$path")" == "$path" ]] || return 1
    local device inode owner mode
    case $(/usr/bin/uname -s) in
        Darwin)
            read -r device inode owner mode <<< "$(/usr/bin/stat -f '%d %i %u %Lp' "$path")" || return 1
            ;;
        Linux)
            read -r device inode owner mode <<< "$(/usr/bin/stat -c '%d %i %u %a' "$path")" || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$owner" == "$(/usr/bin/id -u)" && "$mode" == 700 ]] || return 1
    printf '%s\n%s\n%s\n%s\n' "$device" "$inode" "$owner" "$mode"
}

subject_observation() {
    local preparation=$1
    local path=$2
    local expected_name=$3
    valid_path "$path" || return 1
    valid_name "$expected_name" || return 1
    [[ "$expected_name" == baseline-evidence.json || "$expected_name" =~ ^Maru-[0-9]+\.[0-9]+\.[0-9]+-session-host-release\.json$ ]] || return 1
    [[ "$(/usr/bin/dirname "$path")" == "$preparation" ]] || return 1
    [[ "$(/usr/bin/basename "$path")" == "$expected_name" ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$(canonical_path "$path")" == "$path" ]] || return 1
    local device inode owner mode size links sha256
    case $(/usr/bin/uname -s) in
        Darwin)
            read -r device inode owner mode size links <<< "$(/usr/bin/stat -f '%d %i %u %Lp %z %l' "$path")" || return 1
            sha256=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}') || return 1
            ;;
        Linux)
            read -r device inode owner mode size links <<< "$(/usr/bin/stat -c '%d %i %u %a %s %h' "$path")" || return 1
            sha256=$(/usr/bin/sha256sum "$path" | /usr/bin/awk '{print $1}') || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$mode" == 600 && "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$links" == 1 ]] || return 1
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$device" "$inode" "$size" "$links" "$mode" "$sha256"
}

require_inventory() {
    local preparation=$1
    local evidence=$2
    local manifest=$3
    local entries
    shopt -s nullglob dotglob
    entries=("$preparation"/*)
    shopt -u nullglob dotglob
    [[ ${#entries[@]} -eq 2 ]] || return 1
    local evidence_seen=0
    local manifest_seen=0
    local entry
    for entry in "${entries[@]}"; do
        [[ "$entry" == "$evidence" ]] && evidence_seen=$((evidence_seen + 1))
        [[ "$entry" == "$manifest" ]] && manifest_seen=$((manifest_seen + 1))
    done
    [[ "$evidence_seen" -eq 1 && "$manifest_seen" -eq 1 ]]
}

bundle_observation() {
    local preparation=$1
    local path=$2
    valid_path "$path" || return 1
    case "$path" in
        "$preparation"/*) return 1 ;;
    esac
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$(canonical_path "$path")" == "$path" ]] || return 1
    local device inode owner size links
    case $(/usr/bin/uname -s) in
        Darwin) read -r device inode owner size links <<< "$(/usr/bin/stat -f '%d %i %u %z %l' "$path")" || return 1 ;;
        Linux) read -r device inode owner size links <<< "$(/usr/bin/stat -c '%d %i %u %s %h' "$path")" || return 1 ;;
        *) return 1 ;;
    esac
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$bundle_max_bytes" && "$links" == 1 ]] || return 1
    printf '%s\n%s\n' "$device" "$inode"
}

case ${1-} in
    pin)
        [[ $# -eq 6 ]] || exit 1
        preparation=$2
        evidence=$3
        evidence_name=$4
        manifest=$5
        manifest_name=$6
        [[ "$evidence_name" == baseline-evidence.json ]] || exit 1
        [[ "$manifest_name" =~ ^Maru-[0-9]+\.[0-9]+\.[0-9]+-session-host-release\.json$ ]] || exit 1
        directory=$(directory_observation "$preparation") || exit 1
        require_inventory "$preparation" "$evidence" "$manifest" || exit 1
        evidence_observation=$(subject_observation "$preparation" "$evidence" "$evidence_name") || exit 1
        manifest_observation=$(subject_observation "$preparation" "$manifest" "$manifest_name") || exit 1
        evidence_identity="$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '1p'):$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '2p')"
        manifest_identity="$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '1p'):$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '2p')"
        [[ "$evidence" != "$manifest" && "$evidence_identity" != "$manifest_identity" ]] || exit 1
        printf 'preparation_device=%s\npreparation_inode=%s\npreparation_owner=%s\npreparation_mode=%s\n' \
            "$(printf '%s\n' "$directory" | /usr/bin/sed -n '1p')" "$(printf '%s\n' "$directory" | /usr/bin/sed -n '2p')" \
            "$(printf '%s\n' "$directory" | /usr/bin/sed -n '3p')" "$(printf '%s\n' "$directory" | /usr/bin/sed -n '4p')"
        printf 'evidence_device=%s\nevidence_inode=%s\nevidence_size=%s\nevidence_links=%s\nevidence_mode=%s\nevidence_sha256=%s\n' \
            "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '1p')" "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '2p')" \
            "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '3p')" "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '4p')" \
            "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '5p')" "$(printf '%s\n' "$evidence_observation" | /usr/bin/sed -n '6p')"
        printf 'manifest_device=%s\nmanifest_inode=%s\nmanifest_size=%s\nmanifest_links=%s\nmanifest_mode=%s\nmanifest_sha256=%s\n' \
            "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '1p')" "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '2p')" \
            "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '3p')" "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '4p')" \
            "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '5p')" "$(printf '%s\n' "$manifest_observation" | /usr/bin/sed -n '6p')"
        ;;
    verify)
        [[ $# -eq 24 ]] || exit 1
        preparation=$2
        evidence=$3
        evidence_name=$4
        manifest=$5
        manifest_name=$6
        directory=$(directory_observation "$preparation") || exit 1
        require_inventory "$preparation" "$evidence" "$manifest" || exit 1
        evidence_observation=$(subject_observation "$preparation" "$evidence" "$evidence_name") || exit 1
        manifest_observation=$(subject_observation "$preparation" "$manifest" "$manifest_name") || exit 1
        [[ "$(printf '%s\n' "$directory" | /usr/bin/sed -n '1p')" == "$7" ]] || exit 1
        [[ "$(printf '%s\n' "$directory" | /usr/bin/sed -n '2p')" == "$8" ]] || exit 1
        [[ "$(printf '%s\n' "$directory" | /usr/bin/sed -n '3p')" == "$9" ]] || exit 1
        [[ "$(printf '%s\n' "$directory" | /usr/bin/sed -n '4p')" == "${10}" ]] || exit 1
        expected_evidence=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "${11}" "${12}" "${13}" "${14}" "${15}" "${16}")
        expected_manifest=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "${17}" "${18}" "${19}" "${20}" "${21}" "${22}")
        [[ "$evidence_observation" == "$expected_evidence" && "$manifest_observation" == "$expected_manifest" ]] || exit 1
        evidence_bundle=${23}
        manifest_bundle=${24}
        [[ "$evidence_bundle" != "$manifest_bundle" && "$evidence_bundle" != "$evidence" && "$evidence_bundle" != "$manifest" ]] || exit 1
        [[ "$manifest_bundle" != "$evidence" && "$manifest_bundle" != "$manifest" ]] || exit 1
        evidence_bundle_observation=$(bundle_observation "$preparation" "$evidence_bundle") || exit 1
        manifest_bundle_observation=$(bundle_observation "$preparation" "$manifest_bundle") || exit 1
        identities=(
            "${11}:${12}"
            "${17}:${18}"
            "$(printf '%s\n' "$evidence_bundle_observation" | /usr/bin/sed -n '1p'):$(printf '%s\n' "$evidence_bundle_observation" | /usr/bin/sed -n '2p')"
            "$(printf '%s\n' "$manifest_bundle_observation" | /usr/bin/sed -n '1p'):$(printf '%s\n' "$manifest_bundle_observation" | /usr/bin/sed -n '2p')"
        )
        for ((left = 0; left < ${#identities[@]}; left++)); do
            for ((right = left + 1; right < ${#identities[@]}; right++)); do
                [[ "${identities[$left]}" != "${identities[$right]}" ]] || exit 1
            done
        done
        printf 'evidence-bundle-path=%s\nmanifest-bundle-path=%s\n' "$evidence_bundle" "$manifest_bundle"
        ;;
    *)
        exit 2
        ;;
esac
