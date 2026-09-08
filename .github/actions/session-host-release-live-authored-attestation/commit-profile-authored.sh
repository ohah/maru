#!/bin/bash
set -euo pipefail

if [[ $# -ne 13 ]]; then
  exit 1
fi

select_outcome=$1
payload_outcome=$2
fence_outcome=$3
timing_required=$4
evidence_path=$5
timing_path=$6
evidence_bundle=$7
manifest_bundle=$8
timing_bundle=$9
checkpoint_exe=${10}
checkpoint_root=${11}
checkpoint_identity=${12}
output_file=${13}

commit() {
  "$checkpoint_exe" commit "$checkpoint_root" "$checkpoint_identity" authored_attestation "$1"
}

valid_path() {
  local value=$1
  [[ -n "$value" && "$value" = /* && "$value" != */ && "$value" != *//* &&
     "$value" != */./* && "$value" != */. && "$value" != */../* && "$value" != */.. &&
     ! "$value" =~ [[:cntrl:]] ]]
}

if [[ "$select_outcome:$payload_outcome:$fence_outcome" != success:success:success ]]; then
  commit failed
  exit 1
fi

if ! valid_path "$evidence_path" || ! valid_path "$evidence_bundle" || ! valid_path "$manifest_bundle"; then
  commit failed
  exit 1
fi
case "$timing_required" in
  false) [[ -z "$timing_path" && -z "$timing_bundle" ]] ;;
  true) valid_path "$timing_path" && valid_path "$timing_bundle" ;;
  *) false ;;
esac || {
  commit failed
  exit 1
}

commit succeeded
printf 'evidence-path=%s\ntiming-path=%s\nevidence-bundle-path=%s\nmanifest-bundle-path=%s\ntiming-bundle-path=%s\n' \
  "$evidence_path" "$timing_path" "$evidence_bundle" "$manifest_bundle" "$timing_bundle" >> "$output_file"
