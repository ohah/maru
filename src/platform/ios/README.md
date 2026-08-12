# `src/platform/ios`

iOS 전용 bridge를 담는 폴더다. 계약은 [모바일 플랫폼](../../../docs/mobile-platform.md)이
단일 출처다.

| 파일 | 무엇 |
|---|---|
| `ios_app_host.m` | UIKit host — 창·생명주기·터치·키보드, Metal 백엔드, CoreText 폰트 래스터 |

**두 모바일 타깃의 공통분모는 [`platform/mobile`](../mobile/)에 있다**(C ABI + Zig 브리지).
창이 하나뿐이고, 좌표가 논리 px이고, 터치가 1급 입력이라는 점이 iOS·Android의 공통이고
macOS와의 차이다. 반대로 GPU 백엔드는 공유하지 않는다(Metal↔Vulkan).

`platform/macos`와 Metal·CoreText를 공유할 수 있지만 아직 합치지 않았다 — macOS는 창이
여럿이고 좌표계가 달라, 지금 합치면 한쪽에 맞춘 경계가 된다.

빌드는 `build.zig`(`zig build mobile-lib-ios-sim`·`mobile-lib-ios`)가, 기기 조작은
[모바일 하네스](../../../tools/mobile-poc/README.md)가 소유한다.
