# `src/platform/mobile`

iOS·Android **두 타깃의 공통분모**를 담는 폴더다. 계약은 [모바일 플랫폼](../../../docs/mobile-platform.md)이
단일 출처이고, config 스키마와 자리는 [모바일 config](../../../docs/mobile-config.md)가 소유한다.

| 파일 | 무엇 |
|---|---|
| `mobile_bridge.zig` | L4 모바일 어댑터의 **코어 쪽 절반** — 쓸 수 있는 크기를 논리 px로 받아 quad 목록을 돌려주고, 셀 판정(`maru_mobile_hit_cell`)도 여기서 한다 |
| `mobile_host_abi.h` | 모바일 host와 코어 사이 **C ABI 단일 출처**. `mobile_bridge.zig`의 export와 짝이다 |
| `mobile_config.zig` | 모바일 config 스키마와 파싱 — 데스크톱과 파일·스키마는 나누되 `schema.tryParse` 기계는 공유한다 |

**이 폴더에는 OS 호출이 없다.** 있으면 [`platform/ios`](../ios/)·[`platform/android`](../android/)로
내려야 한다 — 그 규칙이 "공통분모"를 폴더 이름이 아니라 **파일 내용으로 판정 가능**하게 만든다
(계약 §2). 창이 하나뿐이고, 좌표가 논리 px이고, 터치가 1급 입력이라는 점이 두 타깃의 공통이자
macOS와의 차이다. 반대로 GPU 백엔드는 공유하지 않는다(Metal↔Vulkan).

**ABI는 한쪽만 고칠 수 없다.** `mobile_bridge.zig`의 export와 `mobile_host_abi.h`의 구조체는
**필드 순서·타입을 함께** 바꾼다. 한쪽만 고치면 링크는 통과하고 동작만 어긋나서, 컴파일러가
잡아 주지 않는 결함이 된다.

빌드는 `build.zig`(`zig build mobile-lib-ios`·`mobile-lib-ios-sim`·`mobile-lib-android`)가,
기기 조작은 [모바일 하네스](../../../tools/mobile-poc/README.md)가 소유한다.
