#!/bin/sh
# 커밋된 wasm 이 지금 소스에서 나온 것인지 확인한다.
#
# 왜: `packages/core/wasm/maru-vt.wasm` 은 npm 에 실려 나가는 배포 산출물이라 저장소에
# 커밋한다(받는 쪽에 Zig 툴체인이 없다 — docs/maru-term-library.md §6). 그 대가로
# "소스만 고치고 재빌드를 잊는" 드리프트가 생길 수 있어 해시를 대조한다.
#
# **격리된 prefix 로 빌드한다.** `zig build wasm-lib` 는 산출물을 커밋 경로에도 놓으므로
# (build.zig 의 addInstallFile), 그냥 부르면 비교 대상을 먼저 덮어써 이 게이트가 **절대
# 실패할 수 없게** 된다. 실제로 그 상태로 한동안 통과했고 커밋된 바이너리가 소스와 어긋나
# 있었다. prefix 를 옮기면 install 경로도 그 아래로 따라가 저장소를 건드리지 않는다.
set -eu

SHIPPED="packages/core/wasm/maru-vt.wasm"
if [ ! -f "$SHIPPED" ]; then
  echo "check-wasm-sync: $SHIPPED 가 없다 — 'zig build wasm-lib' 를 먼저 돌려라" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
zig build wasm-lib --prefix "$TMP" >/dev/null

FRESH="$TMP/bin/maru-vt.wasm"
if [ ! -f "$FRESH" ]; then
  echo "check-wasm-sync: 격리 빌드가 산출물을 내지 않았다 ($FRESH)" >&2
  exit 1
fi

fresh_hash=$(shasum -a 256 "$FRESH" | cut -d' ' -f1)
shipped_hash=$(shasum -a 256 "$SHIPPED" | cut -d' ' -f1)

if [ "$fresh_hash" != "$shipped_hash" ]; then
  echo "check-wasm-sync: 커밋된 wasm 이 소스와 어긋난다" >&2
  echo "  소스에서 나온 것: $fresh_hash" >&2
  echo "  커밋된 것:        $shipped_hash" >&2
  echo "  고치려면: zig build wasm-lib && git add packages/core/wasm/maru-vt.wasm" >&2
  exit 1
fi

echo "check-wasm-sync: OK ($fresh_hash)"
