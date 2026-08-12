# 모바일 플랫폼 구현 계획

계약은 [모바일 플랫폼](../mobile-platform.md)이 소유한다. 이 문서는 **진행**만 소유한다.

## 배경

PoC 로 "Zig 코어 + 네이티브 GPU 가 iOS/Android 에서 서는가" 를 실측했고 답은 예다
([측정 기록](../../tools/mobile-poc/README.md)). 그 과정에서 **바꿔야 할 것 둘**이 드러났다.

- quad 하나당 draw call 하나 — 모바일 타일 기반 GPU 에 특히 비싸다. 148 quad 는 괜찮지만
  80×40 터미널은 3200 draw call 이 된다.
- `NativeActivity` 는 IME 를 못 받는다 — 한글 조합이 필수라 `GameActivity` 여야 한다.

## 슬라이스

| 슬라이스 | 내용 | 상태 |
|---|---|---|
| M0 | 계약 문서 + 폴더 구조. PoC 코드를 `src/platform/{mobile,ios,android}` 로 옮긴다 | 완료 |
| M1 | **draw-list 배칭** — quad 당 draw call 을 인스턴스 드로우 한 번으로 | 완료 |
| M1.5 | **`build.zig` 타깃** — 제품 빌드를 셸 스크립트에서 회수한다 | 완료 |
| M2 | **Android `GameActivity` 이관** — `GameTextInput` 으로 IME 를 받는다 | 미착수 |
| M3 | 원격 세션 연결 — `session_host` 클라이언트를 모바일에 붙인다 | 미착수 |
| M4 | 스크롤·선택·복사 + 보조 키바 | 미착수 |
| M5 | 회전·태블릿 레이아웃 | 미착수 |
| M6 | 실기기 성능 예산 + 아틀라스 축출 | 미착수 |


## M0 — 폴더 구조

PoC 는 `tools/mobile-poc/` 에 앱 전체를 담고 있었다. 제품 코드는 `src/platform/` 으로 옮기고,
`tools/mobile-poc/` 는 **측정 하네스**로 남긴다(빌드 스크립트 + 측정 기록). 코드를 양쪽에 두지
않는다 — `run.sh` 가 `src/platform/` 을 빌드한다.

## M1 — 배칭

각 quad 를 push constant + `vkCmdDraw`/`drawPrimitives` 로 그리던 것을, **quad 배열을
버퍼에 한 번 올리고 인스턴스 드로우 한 번**으로 바꾼다. 셰이더는 push constant 대신 버퍼를
읽는다(Metal `[[instance_id]]`, Vulkan `gl_InstanceIndex`).

판정: 프레임당 draw call 수를 로그로 낸다. 148 quad 에서 **1** 이어야 한다.
실측: 두 플랫폼 모두 `MARU_DRAW calls=1 instances=148`, 화면은 이전과 동일.

Metal 은 `setVertexBytes:` 가 4KB 한계라 148 quad(9.5KB)도 못 실어 `MTLBuffer` 가 필요했다.
Vulkan 은 push constant 를 통째로 버리고 storage buffer + `gl_InstanceIndex` 로 갔다 —
quad 마다 다른 값을 한 번의 draw call 에 실을 수 없기 때문이다. 그 결과 **프래그먼트가
push constant 를 못 읽게 되어** 색·radius·kind 를 varying 으로 넘긴다.

**CI 에는 붙이지 않는다(사용자 결정).** 모바일 빌드는 Xcode·NDK·에뮬레이터가 필요해
러너 비용이 크고, 지금 단계에서 막아야 할 회귀가 없다. 검증은 로컬에서 `run.sh` 로 한다 —
필요해지면 그때 넣는다.

## M1.5 — build.zig

제품 코드를 셸 스크립트가 빌드하는 것은 정식 도입이 아니다. `build.zig` 가 모바일 타깃을
소유하고, `tools/mobile-poc/run.sh` 는 **기기 조작**(설치·실행·캡쳐·계측)만 남긴다.

```sh
zig build mobile-libs -Doptimize=ReleaseSafe   # 세 타깃 전부
zig build mobile-lib-ios-sim | mobile-lib-ios | mobile-lib-android
```

**Debug 는 iOS 에서 링크가 깨진다** — std 의 스택 트레이스가 시뮬레이터 SDK 에 없는
`_dyld_get_image_header_containing_address` 를 참조한다. `simple_panic` 이 ReleaseSafe 에서
그 경로를 걷어내고 **안전 검사는 그대로 산다**(PoC 때 기록한 내용이 그대로 확인됐다).

**대체된 초기 하네스는 지웠다.** `chrome-ios`/`chrome-android-app` 이 `ios`·`ios-app`·
`android`·`chrome-android` 가 하던 일을 포함한다 — 남겨 두면 어느 쪽이 진짜인지 흐려진다.
측정 **결과**(표·스크린샷)는 전부 남는다. 여섯 기능 판정기(`features-*`)는 다른 모드가
대체하지 않는 별도 측정이라 남긴다.

## M2 — GameActivity

`androidx.games:games-activity` 의 prefab C 소스와 `classes.jar` 를 쓴다. Java 코드가 생기므로
`hasCode="false"` 를 버리고 `d8` 로 dex 를 만든다.

판정: `adb shell input text` 로 넣은 한글이 **조합된 채로** 앱에 도달한다(`GameTextInput` 의
`stateChanged` 콜백). `NativeActivity` 의 keycode 표를 지운다.
