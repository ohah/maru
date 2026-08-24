#!/bin/sh
# macOS 제품 경로를 **다른 OS 에서 타입 검사**한다 — SDK 도 링크도 없이.
#
# ## 왜 있나
#
# Windows·Linux 의 `zig build` 는 `src/platform/macos/**` 를 **컴파일조차 하지 않는다.** 그래서 그
# 파일을 건드린 슬라이스는 로컬 게이트가 전부 초록인데 CI 가 빨간 일이 생긴다. 이 저장소에서 세 번
# 났다:
#
#   1. 상대 import 가 `file exists in modules 'maru' and 'root'` 를 냈다(§2m.39).
#   2. 함수를 옮기며 별칭을 안 넣어 **중간 커밋 둘이 파싱조차 안 됐다**(§2m.45).
#   3. 공유 함수의 인자를 `u32` 로 두었는데 macOS 호출부가 `usize` 를 넘겼다(§2m.46).
#
# `tools/ci/per-commit-boundaries.sh` 는 ⑵ 를 잡지만 `zig ast-check` 라 **파싱까지만** 본다 — ⑶ 처럼
# 타입이 어긋나는 것은 못 잡는다. 이 스크립트가 그 자리를 메운다.
#
# ## 무엇을 하나
#
# CI 의 `file explorer macOS product path` 잡이 컴파일하는 것과 **같은 루트**(`app_host_abi.zig`)를
# `-target aarch64-macos` 로 **의미 분석만** 돌린다(`--test-no-exec -fno-emit-bin`). 바이너리를 안 내니
# macOS SDK 도 프레임워크도 필요 없다 — `.m` 파일은 애초에 건드리지 않는다.
#
# ## 한계
#
# - **링크는 안 본다.** ObjC 심볼이 빠진 것은 진짜 macOS 러너만 잡는다.
# - `build_options` 를 여기서 흉내 낸다(아래). `build.zig` 가 옵션을 늘리면 이 스크립트가
#   `no member named ...` 로 **시끄럽게** 실패한다 — 조용히 통과하지 않으므로 그때 여기를 맞춘다.
# - Zig 는 **지연 분석**이라 아무도 안 부르는 코드는 안 본다. 그래서 루트를 `test` 로 잡는다
#   (테스트가 그 파일의 판정자들을 참조해 분석 범위가 넓어진다).
set -eu

cd "$(dirname "$0")/.."

zig="${ZIG:-zig}"
target="${MARU_MACOS_TYPECHECK_TARGET:-aarch64-macos}"

opts="$(mktemp -t maru-bo-XXXXXX)" || exit 1
trap 'rm -f "$opts"' EXIT
mv "$opts" "$opts.zig"
opts="$opts.zig"
# `build.zig` 의 `build_options_test_mod` 와 같은 필드들. 값은 안 본다 — 타입만 맞으면 된다.
cat >"$opts" <<'ZIG'
pub const version: []const u8 = "0.0.0-typecheck";
pub const mermaid_test_api: bool = true;
ZIG

echo "macOS 제품 경로를 $target 로 타입 검사한다(링크 없음)"
"$zig" test -fno-emit-bin --test-no-exec -target "$target" \
  --dep maru --dep build_options \
  -Mroot=src/platform/macos/app_host_abi.zig \
  --dep shutdown_wire_contract --dep maru_terminfo --dep config_doc_md \
  -Mmaru=src/maru.zig \
  -Mshutdown_wire_contract=src/shutdown_wire_contract.zig \
  -Mmaru_terminfo=terminfo/maru.terminfo \
  -Mconfig_doc_md=docs/configuration.md \
  -Mbuild_options="$opts" \
  -I src/platform/macos

echo "OK — macOS 제품 경로가 타입 검사를 통과한다"
