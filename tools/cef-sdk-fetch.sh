#!/bin/sh
# 웹 OSR sidecar 의 CEF SDK 를 받아 해시를 확인하고 캐시에 푼다(W1b, docs/plans/web-osr-backend.md).
#
# `zig fetch` 는 CEF 배포 형식인 .tar.bz2 를 못 푼다(실측 — `unknown file type`) — 그래서 스크립트다.
# CEF 는 프로젝트 규칙 「의존성」 예외 ③ 이라 이 스크립트는 opt-in 경로(`mise run web-sidecar*`)에서만 돈다.
#
# 사용: tools/cef-sdk-fetch.sh           마지막 줄에 SDK 디렉터리 경로를 찍는다
# 환경: MARU_CEF_CACHE    캐시 뿌리(기본 ~/Library/Caches/maru/cef)
#       MARU_CEF_ARCHIVE  이미 받은 .tar.bz2 — 받지 않고 이것을 쓴다(해시 확인은 똑같이 한다)
#
# 버전을 올릴 때: 아래 version 과 두 sha256 을 함께 바꾸고, 회귀 시험(계획 §4)을 다시 돈다.
# sha256 은 CEF 인덱스(sha1 만 준다)의 sha1 과 일치한 배포본으로 쟀다(2026-09-24).
set -eu

version="154.0.23+g062ebe4+chromium-154.0.8037.17"
case "$(uname -m)" in
  arm64) platform=macosarm64; sha256=5b9c248b30db8d41dd2cf5c6f920ef4991c60e514f863413db542d0448ddf777 ;;
  x86_64) platform=macosx64; sha256=021d769edaccf9b216316d763e39a7f879aa3d6cce5addcbcfab066ec2f3cc1f ;;
  *) echo "cef-sdk-fetch: 지원하지 않는 아키텍처 $(uname -m)" >&2; exit 1 ;;
esac

name="cef_binary_${version}_${platform}_minimal"
cache="${MARU_CEF_CACHE:-$HOME/Library/Caches/maru/cef}"
dest="$cache/$name"
if [ -f "$dest/.maru-verified" ]; then
  echo "$dest"
  exit 0
fi

mkdir -p "$cache"
work=$(mktemp -d "$cache/.fetch.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

archive="${MARU_CEF_ARCHIVE:-}"
if [ -z "$archive" ]; then
  archive="$work/sdk.tar.bz2"
  url="https://cef-builds.spotifycdn.com/$(printf %s "$name" | sed 's/+/%2B/g').tar.bz2"
  echo "cef-sdk-fetch: $url 받는 중(약 130MB)" >&2
  curl --fail --location --silent --show-error --output "$archive" "$url"
fi

actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
if [ "$actual" != "$sha256" ]; then
  echo "cef-sdk-fetch: sha256 불일치 — 기대 $sha256, 실제 $actual" >&2
  exit 1
fi

tar -xjf "$archive" -C "$work"
if [ ! -d "$work/$name/Release/Chromium Embedded Framework.framework" ]; then
  echo "cef-sdk-fetch: 풀린 배포본에 프레임워크가 없다" >&2
  exit 1
fi
rm -rf "$dest"
mv "$work/$name" "$dest"
touch "$dest/.maru-verified"
echo "$dest"
