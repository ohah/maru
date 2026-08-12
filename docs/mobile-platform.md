# 모바일 플랫폼 (iOS · Android)

이 문서는 iOS·Android 어댑터(L4)의 계약을 정한다. 층 경계 자체는
[레이어링과 이식성 전략](layering-and-portability.md)이 단일 출처이고, 이 문서는 그 L4 자리에
모바일 두 타깃이 어떻게 들어가는지만 소유한다. 진행 상황은
[모바일 플랫폼 구현 계획](plans/mobile-platform.md)이 소유한다.

**베이스**: PoC 로 실측했다([측정 기록](../tools/mobile-poc/README.md)). 코어 컴파일·GPU
렌더·chrome 컴포넌트·터미널 격자·폰트 래스터·입력·터치·생명주기·present 페이싱을 두
플랫폼에서 확인했고, 여기 적힌 계약은 그 측정 위에 선다.

## 1. 확정 결정

- **모바일은 두 플랫폼 다 원격 전용이다(사용자 확정).** 로컬 PTY 를 아예 두지 않는다.
  iOS 는 선택의 여지도 없다 — 샌드박스가 `fork()`/`exec()` 를 금지한다([베이스](#5-베이스):
  출시된 iOS 터미널이 전부 SSH/Mosh 클라이언트인 것이 같은 결론이다). Android 는 기술적으로
  가능하지만 **일부러 안 한다**: 두 타깃이 같은 모양이 되고, 모바일에 셸 환경(툴체인·패키지)을
  싣는 일이 통째로 사라진다.

  **그래서 모바일 앱은 PC 세션의 원격 뷰어다.** [컨트롤 플레인](control-plane.md)이 선택이
  아니라 전제다. 실측: 모바일 정적 라이브러리에 maru 의 `pty` 심볼이 **0개**다(libc 의
  `_execve` 참조는 std 경로에서 오는 것이고 우리 셸 경로가 아니다).

  **이 결정이 컨트롤 플레인의 현재 계약과 충돌한다.** 지금 계약은 "wire 는 TCP/HTTP 를
  바인드하지 않는다" 이고 보안이 "같은 uid 안의 신뢰 차등" 이다 — peer-cred 는 기계를
  넘으면 존재하지 않는다. 원격 축(전송·인증·암호화)은 그 문서가 새로 소유해야 하고,
  정하기 전에는 모바일에서 붙일 수 없다([계획 M3](plans/mobile-platform.md)).
- **Android IME 는 자체 Java shim 이 받는다**(`NativeActivity` 유지). `NativeActivity` 만으로는
  소프트 키보드가 ASCII 물리 키 이벤트를 줄 때만 입력이 되고 **IME 를 못 받는다** — 한글
  조합이 필수인 터미널에서는 쓸 수 없다. 구글의 `GameActivity`/`GameTextInput` 이 그 자리를
  채우지만 **`AppCompatActivity` 를 상속해 AndroidX 의존 트리와 Gradle 을 끌고 온다**(실측:
  1.2.2~4.4.2 전 버전). 그래서 `InputConnection` 을 직접 받는 ~120줄 Java 로 간다.

  **한글 조합 알고리즘은 우리 것이 아니다.** IME 가 계산해 문자열로 주고, shim 은
  `setComposingText`(조합 중)·`commitText`(확정)를 JNI 로 넘기기만 한다. 같은 조건의
  터미널(Termux)이 `GameActivity` 없이 이 방식으로 선다.

  **판단 근거는 유지보수다.** 모바일은 CI 에 안 붙으므로(§6) Gradle·AGP·JDK 삼각 버전은
  **정기적으로 돌지 않으면 조용히 썩는다**. `javac` + `android.jar` + `d8` 은 의존이 없고
  안드로이드 SDK 의 하위 호환이 강하다. Gradle 은 Play 배포·App Bundle 처럼 실제로 필요해질
  때 도입한다 — 지금 넣으면 쓰지 않으면서 썩는다.

  **Kotlin 은 쓰지 않는다.** 구조가 같고(같은 콜백 두 개), 대가로 `kotlin-stdlib` 가 APK 에
  들어가며 `companion object` 의 JNI 심볼이 `@JvmStatic` 없이는 런타임에 죽는다. 이 120줄에는
  Kotlin 의 이점이 나올 자리가 없다.
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
    ios_app_host.m         UIKit host + Metal 백엔드 + CoreText 래스터
  android/
    android_app_host.c     NativeActivity host + Vulkan 백엔드 + JNI Paint 래스터
    MaruActivity.java      IME shim: 조합 중/확정 문자열을 JNI 로 넘긴다
    AndroidManifest.xml
    shaders/               SPIR-V 소스(chrome.vert·chrome.frag)
```

**host 파일 하나가 창·GPU·폰트를 다 갖는다.** 지금 규모(iOS 430줄·Android 977줄)에서는
나누는 것이 이득이 아니다 — 셋이 같은 상태(스왑체인·아틀라스·스케일)를 공유해서, 가르면 그 상태를
넘기는 배관이 코드보다 커진다. 커지면 그때 가른다.

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
| 플랫폼 → 코어 | 확정된 키 입력 바이트 | `maru_mobile_input(bytes, len)` |
| 플랫폼 → 코어 | 조합 중 문자열(IME preedit) | `maru_mobile_set_preedit(bytes, len)` |
| 플랫폼 → 코어 | 터치 지점(논리 px) | `maru_mobile_hit_cell(x, y)` |
| 코어 → 플랫폼 | 아직 아틀라스에 없는 코드포인트 | `maru_mobile_missing_*` |

**폴백 아틀라스는 없다.** 기기 래스터가 실패하면 글리프 없이 뜬다 — 예전에 두던 "호스트가
만든 아틀라스를 읽는" 경로는 개발 스크립트가 넣어 준 파일에 기대는 것이라 **실제 앱에는 그
파일이 없었다**. 제품 폴백이 아니라 PoC 잔재였다.

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
- **iOS IME preedit.** Android 는 정했다(§1 — shim 이 `setComposingText` 를 넘기고 코어가
  커서 자리에 흐리게 그린다). iOS 는 `UITextInput` 의 marked text 를 같은 자리에 태우면
  되지만 아직 안 했다.
- **원격 전송·인증**(§1 의 충돌). 이것이 정해지기 전에는 모바일이 세션에 붙지 못한다.
