#!/bin/sh
# 커밋된 wasm 이 지금 소스에서 나온 것인지 확인한다.
#
# 왜: `packages/core/wasm/maru-vt.wasm` 은 npm 에 실려 나가는 배포 산출물이라 저장소에
# 커밋한다(받는 쪽에 Zig 툴체인이 없다 — docs/maru-term-library.md §6). 그 대가로
# "소스만 고치고 재빌드를 잊는" 드리프트가 생길 수 있어, 방금 빌드한 것과 해시를 대조한다.
#
# 선행: `zig build wasm-lib` 가 두 자리에 모두 산출물을 놓는다(mise 가 depends 로 건다).
set -eu

FRESH="zig-out/bin/maru-vt.wasm"
SHIPPED="packages/core/wasm/maru-vt.wasm"

for f in "$FRESH" "$SHIPPED"; do
  if [ ! -f "$f" ]; then
    echo "check-wasm-sync: $f 가 없다 — 'zig build wasm-lib' 를 먼저 돌려라" >&2
    exit 1
  fi
done

fresh_hash=$(shasum -a 256 "$FRESH" | cut -d' ' -f1)
shipped_hash=$(shasum -a 256 "$SHIPPED" | cut -d' ' -f1)

if [ "$fresh_hash" != "$shipped_hash" ]; then
  echo "check-wasm-sync: 커밋된 wasm 이 소스와 어긋난다" >&2
  echo "  방금 빌드: $fresh_hash" >&2
  echo "  커밋된 것: $shipped_hash" >&2
  echo "  고치려면: zig build wasm-lib && git add packages/core/wasm/maru-vt.wasm" >&2
  exit 1
fi

echo "check-wasm-sync: OK ($fresh_hash)"
