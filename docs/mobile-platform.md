# 모바일 플랫폼 (iOS · Android)

이 문서는 iOS·Android 어댑터(L4)의 계약을 정한다. 층 경계 자체는
[레이어링과 이식성 전략](layering-and-portability.md)이 단일 출처이고, 이 문서는 그 L4 자리에
모바일 두 타깃이 어떻게 들어가는지만 소유한다. 진행 상황은
[모바일 플랫폼 구현 계획](plans/mobile-platform.md)이 소유한다.

**베이스**: PoC 로 실측했다([측정 기록](../tools/mobile-poc/README.md)). 코어 컴파일·GPU
렌더·chrome 컴포넌트·터미널 격자·폰트 래스터·입력·터치·생명주기·present 페이싱을 두
플랫폼에서 확인했고, 여기 적힌 계약은 그 측정 위에 선다.

## 1. 확정 결정

- **iOS 에 로컬 셸은 없다.** 샌드박스가 `fork()`/`exec()` 를 금지한다. iOS 는 **원격 세션
  전용**이고, 로컬 PTY 는 Android 에만 존재한다. 이것이 모바일 지원의 성격을 정한다 —
  iOS 앱은 PC 의 원격 뷰어이고 [컨트롤 플레인](control-plane.md)이 선택이 아니라 전제다.
  ([베이스](#5-베이스): 출시된 iOS 터미널이 전부 SSH/Mosh 클라이언트인 것이 같은 결론이다.)
- **Android host 는 `GameActivity` 다.** `NativeActivity` 는 소프트 키보드가 ASCII 물리 키
  이벤트를 줄 때만 입력이 되고 **IME 를 못 받는다** — 한글 조합이 필수인 터미널에서는 쓸 수
  없다. `GameActivity` 의 `GameTextInput` 이 그 자리를 채운다.
- **draw-list 는 배칭해 그린다.** quad 하나당 draw call 하나는 모바일 타일 기반 GPU 에서
  특히 비싸다. 데스크톱이 이미 vertex buffer 로 배칭하므로(`maru_metal_renderer.m`) 같은
  모양을 쓴다 — 새 경로를 만들지 않는다.
- **두 타깃의 공통분모는 `platform/mobile` 에 둔다.** 창이 하나뿐이고, 좌표가 논리 px 이고,
  터치가 1급 입력이라는 점이 iOS·Android 의 공통이고 macOS 와의 차이다. 반대로 GPU 백엔드는
  공유하지 않는다(Metal↔Vulkan).

## 2. 폴더 구조

```text
src/platform/
  mobile/                  두 모바일 타깃의 공통분모(OS 호출 없음)
    mobile_host_abi.h      플랫폼↔코어 C ABI(quad·입력·조회)
    mobile_bridge.zig      chrome→quad 투영, 아틀라스 등록부, 입력·hit-test
  ios/
    ios_app_host.m         UIKit host: 창·생명주기·터치·키보드
    ios_metal_renderer.m   Metal 백엔드(배칭)
    ios_text.m             CoreText 래스터 + 아틀라스 성장
  android/
    android_app_host.c     GameActivity host: 창·생명주기·입력·IME
    android_vulkan_renderer.c  Vulkan 백엔드(배칭)
    android_text.c         JNI Paint 래스터 + 아틀라스 성장
    AndroidManifest.xml
```

**`platform/mobile` 에는 OS 호출이 없다.** 있으면 `ios/`·`android/` 로 내려야 한다. 이
규칙이 "공통분모" 를 관찰 가능하게 만든다 — 지키는지 여부를 파일 내용으로 판정할 수 있다.

**Vulkan 백엔드를 Linux 와 공유할지는 아직 정하지 않는다.** Linux 백엔드가 생길 때
공통분모가 드러나므로, 그전에 추상 층을 만들면 하나뿐인 사용처에 맞춘 잘못된 경계가 된다.

## 3. 플랫폼↔코어 경계

**플랫폼은 배치를 모른다.** 화면의 쓸 수 있는 크기를 논리 px 로 넘기고 quad 목록을 받는다.
셀 판정도 코어가 한다 — 플랫폼은 점만 넘긴다.

| 방향 | 무엇 | 누가 |
|---|---|---|
| 플랫폼 → 코어 | 논리 크기(safe area 뺀 값) | `maru_mobile_build(w, h)` |
| 코어 → 플랫폼 | quad 목록(rect·색·radius·kind·아틀라스 셀) | `maru_mobile_quads()` |
| 플랫폼 → 코어 | 키 입력 바이트 | `maru_mobile_input(bytes, len)` |
| 플랫폼 → 코어 | 터치 지점(논리 px) | `maru_mobile_hit_cell(x, y)` |
| 코어 → 플랫폼 | 아직 아틀라스에 없는 코드포인트 | `maru_mobile_missing_*` |

**논리 좌표계로 되돌리는 자리는 플랫폼이 갖는다.** iOS 는 `UIScreen.scale` + `safeAreaInsets`,
Android 는 `AConfiguration_getDensity` + `getRootWindowInsets` 다. 실측으로 확인했다 — 같은
논리 좌표를 주면 두 플랫폼이 같은 셀을 답한다(물리 좌표는 200,300 과 525,753 으로 다르다).

## 4. 폰트

**동봉 폰트를 쓴다.** `assets/fonts/Jetendard`(OFL)는 영문과 한글을 한 파일에 담아 폴백이
필요 없다. 시스템 폰트는 플랫폼마다 글자가 갈리는 데다 라이선스상 옮길 수도 없다.

**래스터는 각 플랫폼 것을 쓴다**(iOS CoreText, Android `android.graphics.Paint` — NDK 에는
폰트 래스터가 없다). 같은 폰트를 쓰면 남는 차이는 안티에일리어싱뿐이고, 실측으로 **글자
위치·크기는 완전히 같다**(무게중심 밀림 0/64 셀, 평균 |Δ| 17.5/255).

**아틀라스는 자란다.** 고정 집합으로 두면 처음 보는 글자가 **조용히** 안 그려진다. 코어가
못 찾은 코드포인트를 모으고 플랫폼이 그 슬롯만 구워 올린다(부분 업데이트). 축출은 아직
없다 — 꽉 차면 멈춘다.

## 5. 베이스

**같은 구조의 제품이 이미 출시돼 있다.** libghostty(Zig 터미널 코어) + 네이티브 GPU 로
만든 iOS 터미널이 여럿이다(Metal 렌더링). 우리 구조가 외톨이가 아니라는 뜻이고, 자체
성능 측정 전까지는 이것이 가장 강한 근거다.

**그리고 그것들이 전부 SSH/Mosh 클라이언트다** — §1 의 "iOS 는 원격 전용" 이 우리만의
제약이 아니라 플랫폼이 강제하는 결론이라는 독립 증거다.

`GameActivity` 권장과 `NativeActivity` 의 텍스트 입력 한계는 Android 공식 문서가 소유한다.
모바일 GPU 가 draw call 오버헤드에 민감하다는 것은 Vulkan 공식 모바일 가이드가 소유한다.

## 6. 아직 정하지 않은 것

- **성능 예산.** 실기기가 있어야 잰다. 에뮬레이터 GPU 는 `llvmpipe` 소프트웨어 래스터라
  숫자가 의미 없다.
- **아틀라스 축출** 정책.
- **스크롤·선택·복사**와 터미널용 **보조 키바**(모바일 키보드에 `Esc`·`Ctrl`·화살표가 없다).
- **회전·태블릿** 레이아웃.
- **IME preedit**(조합 중 표시) — `GameTextInput`·`UITextInput` 의 marked text 를 어느 층이
  소유할지는 [키 입력과 단축키](key-input-and-shortcuts.md)의 IME 계약에 맞춰 정한다.
