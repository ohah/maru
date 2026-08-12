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
  iOS 는 선택의 여지도 없다 — 샌드박스가 `fork()`/`exec()` 를 금지한다([베이스](#6-베이스):
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

  **판단 근거는 유지보수다.** 모바일은 CI 에 안 붙으므로([계획](plans/mobile-platform.md)) Gradle·AGP·JDK 삼각 버전은
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

**셰이더와 폰트는 APK asset 으로 들어간다.** 개발 스크립트가 `adb push` 로 넣어 주는 자리
(`/data/local/tmp`)에 기대면 **그 스크립트를 안 돌린 기기에서는 앱이 검은 화면**이다 —
셰이더가 없으면 초기화가 실패한다. 폰트는 조용히 시스템 글꼴로 떨어져 §4 와 어긋난다.

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
| 플랫폼 → 코어 | 본문 셀 조회(논리 px) | `maru_mobile_hit_cell(x, y)` |
| 코어 → 플랫폼 | 아직 아틀라스에 없는 코드포인트 | `maru_mobile_missing_*` |
| 코어 → 플랫폼 | 마지막 실패 이름(읽은 쪽이 비운다) | `maru_mobile_last_error` / `_clear_error` |

**브리지는 스레드를 모른다.** 자물쇠는 스레드가 둘인 플랫폼이 갖는다. Android 는 IME 가
Java UI 스레드에서 오고 그리는 쪽은 NativeActivity 스레드라(실측 tid 14832 vs 14850) host 가
`pthread_mutex` 로 브리지 호출을 직렬화한다. iOS 는 UIKit 이 둘 다 main 에서 부르므로 없다 —
대칭이 깨진 게 아니라 사정이 다른 것이고, 그 차이는 각 host 파일 머리에 적는다.

### 3.1 포인터는 누가 해석하는가

**지금은 `ACTION_DOWN`·`touchesBegan` 만 받는다.** 뗀 시점을 모르니 탭과 롱프레스를 못 가르고,
이동을 모르니 드래그가 없고, 첫 포인터만 읽어 멀티터치가 없다. OS 가 못 주는 게 아니라 **안
받고 있는** 것이다.

**의미는 코어가, 느낌은 플랫폼이 갖는다.**

| 무엇 | 누가 | 왜 |
|---|---|---|
| hit-test, 탭↔롱프레스 판정, 텍스트 선택 드래그 | **코어** | 데스크톱과 같은 의미여야 한다(롱프레스는 우클릭 자리). 합성 이벤트로 **헤드리스 검증**이 되는데, 모바일은 CI 가 없어 이 값이 특히 크다 |
| 스크롤 관성·러버밴딩, 핀치 줌, 시스템 제스처 협조 | **플랫폼** | OS 느낌이라 직접 만들면 어색하고, 뒤로가기·엣지 스와이프와 충돌한다. 결과(Δ·scale)만 넘긴다 |

**버튼은 좌표로 실행하지 않는다.** chrome 이 이미 `UiActionId` + `snapshot_generation` 계약을
갖고 있고([chrome 상호작용 이관](chrome-interaction-migration.md)의 intent table), 모바일도
그 경로를 쓴다. 좌표나 인덱스를 들고 down→up 을 건너면 **그 사이에 화면이 바뀌었을 때 엉뚱한
명령이 실행된다** — 원격 세션 목록은 수시로 바뀌므로 실제로 일어나는 일이다. generation 이
다르면 `resolve` 가 null 을 내 그 누름은 무시된다(잘못 실행하느니 아무 일도 안 한다).

**`maru_mobile_hit_cell` 은 본문 전용으로 남는다.** "어느 셀을 만졌나" 는 터미널 의미(텍스트
선택)라 그 자리가 맞다. 탭·사이드바·아이콘까지 이 함수로 넓히면 위 계약을 우회하게 된다.

**폴백 아틀라스는 없다.** 기기 래스터가 실패하면 글리프 없이 뜬다 — 예전에 두던 "호스트가
만든 아틀라스를 읽는" 경로는 개발 스크립트가 넣어 준 파일에 기대는 것이라 **실제 앱에는 그
파일이 없었다**. 제품 폴백이 아니라 PoC 잔재였다.

**크기가 바뀌면 코어를 `resize` 한다 — 다시 만들지 않는다.** 새로 만들면 스크롤백과 화면
상태가 통째로 날아간다. 모바일에서는 **키보드를 올렸다 내리기만 해도** 창이 리사이즈되므로
그 차이가 크다.

**논리 좌표계로 되돌리는 자리는 플랫폼이 갖는다.** iOS 는 `UIScreen.scale` + `safeAreaInsets`,
Android 는 `AConfiguration_getDensity` + `getRootWindowInsets` 다. 실측으로 확인했다 — 같은
논리 좌표를 주면 두 플랫폼이 같은 셀을 답한다(물리 좌표는 200,300 과 525,753 으로 다르다).

## 3.2 프레임 주기

**30Hz(comfort)로 그린다 — 처음부터.** 터미널은 매 vsync 마다 새로 그릴 것이 없고, 모바일은
배터리·발열이 **사용자에게 보인다**. 데스크톱 maru 의 present 정책과 같은 값이다.

| | 어떻게 |
|---|---|
| iOS | `CADisplayLink.preferredFrameRateRange = 30` |
| Android | `AChoreographer` vsync 를 받아 **한 번 걸러** present(Vulkan 에는 하위 주기 모드가 없다) |

**두 플랫폼 다 자기 주기를 확인한다.** iOS 의 `preferredFrameRateRange` 는 **힌트라 무시될 수
있고**, Android 는 우리가 직접 세는 것이라 어긋날 수 있다. 그래서 둘 다 표시 클럭 간격의
중앙값을 재서 `MARU_PACE median_ms` 로 한 번 남긴다 — 30Hz 가 조용히 깨지면 그 줄로 드러난다.

**계측은 동작을 바꾸지 않는다.** 예전에는 60Hz 로 시작해 80프레임쯤 뒤 계측이 끝나면 30Hz 로
넘어갔다 — 측정의 부산물이 제품 동작이었고, iOS 엔 그 전환이 없어 두 플랫폼이 달랐다. 지금은
둘 다 처음부터 30Hz 이고 `MARU_PACE` 는 도는 주기를 재서 한 번 기록만 한다.

## 3.3 배경으로 나갈 때

**두 플랫폼이 하는 일이 다르다 — OS 가 요구하는 것이 다르기 때문이다.**

| | 나갈 때 | 돌아올 때 |
|---|---|---|
| iOS | `CADisplayLink` 를 **멈춘다**(`paused`). 배경에서 GPU 작업을 계속하면 앱이 종료될 수 있다 | 다시 돌린다. 레이어·텍스처는 UIKit 이 살려 둔다 |
| Android | 창 자체가 사라진다(`APP_CMD_TERM_WINDOW`) → **Vulkan 을 통째로 부순다** | `APP_CMD_INIT_WINDOW` 에서 다시 세운다 |

Android 가 더 무거운 이유는 창이 진짜로 없어지기 때문이다 — 스왑체인을 들고 있으면 죽은
surface 로 present 하게 된다. iOS 는 그 파괴가 필요 없고, **대신 그리기를 멈추지 않으면
안 된다**(한동안 iOS 만 아무것도 안 하고 있었다).

**재개해도 살아야 하는 것은 `g` 밖에 둔다**(Android). teardown 이 상태를 memset 하므로 안에
두면 재개할 때마다 초기화된다 — vsync 체인 소유 플래그가 그래서 왕복마다 체인을 쌓았다
(실측: 3회 왕복에 33.4ms → 16.7ms). 반대로 **새 네이티브 스레드는 체인이 없으므로**
`android_main` 시작 때 그 플래그를 0 으로 되돌린다.

## 4. 폰트

**동봉 폰트를 쓴다.** `assets/fonts/Jetendard`(OFL)는 영문과 한글을 한 파일에 담아 폴백이
필요 없다. 시스템 폰트는 플랫폼마다 글자가 갈리는 데다 라이선스상 옮길 수도 없다.

**래스터는 각 플랫폼 것을 쓴다**(iOS CoreText, Android `android.graphics.Paint` — NDK 에는
폰트 래스터가 없다). 같은 폰트를 쓰면 남는 차이는 안티에일리어싱뿐이고, 실측으로 **글자
위치·크기는 완전히 같다**(무게중심 밀림 0/64 셀, 평균 |Δ| 17.5/255).

**아틀라스는 자란다.** 고정 집합으로 두면 처음 보는 글자가 **조용히** 안 그려진다. 코어가
못 찾은 코드포인트를 모으고 플랫폼이 그 슬롯만 구워 올린다(부분 업데이트).

**용량은 코어가 소유한다**(`maru_mobile_atlas_rows/cols` — 32행 × 16열 = 512슬롯).
헤더 매크로로 두면 등록부보다 큰 슬롯을 약속하게 되고, 남는 슬롯은 등록이 안 된 채 매
프레임 다시 구워진다(실제로 등록부 256 vs 슬롯 512 로 어긋나 있었다). 미리 굽는 글자 수로 정하면
안 된다 — 남는 슬롯이 곧 성장의 상한이 되고, 한글은 수천 자라 금세 막힌다(실측: 여유가
15칸이라 15자에서 멈췄다). **축출은 아직 없다** — 512칸이 차면 새 글자가 안 그려진다.

## 5. 조용히 실패하지 않는다

모바일 host 는 화면 하나가 전부라, 무엇이 안 그려져도 **사용자에게는 그냥 이상한 화면**이다.
그래서 실패를 삼키지 않는다 — 코어 write, quad 버퍼 넘침, 코어 init, 아틀라스 만원은 전부
`maru_mobile_last_error` 에 남는다(`mobile_bridge.zig` 에 `catch {}` 가 0개다).

이 원칙이 없을 때 실제로 생긴 일: 입력이 512바이트에서 죽었는데 **로그가 같은 수를 계속
찍어** 죽은 줄 몰랐다. 그래서 `maru_mobile_input` 의 반환값도 내부 기록 길이가 아니라
**코어에 전달한 누적 바이트**다 — 안 늘면 안 닿은 것이다.

**오류는 읽은 쪽이 비운다.** build 가 프레임 시작마다 비우면 프레임 *사이*에 난 실패
(입력의 core write)가 아무도 읽기 전에 지워진다 — 이 원칙을 만든 바로 그 경로에서만 신호가
안 남는 셈이었다. host 는 매 프레임 읽고, 값이 있으면 로그하고 `maru_mobile_clear_error` 한다.

**고정 버퍼 위에 코어를 세우지 않는다.** `FixedBufferAllocator` 는 마지막 할당 말고는 free 가
no-op 이라 격자가 바뀔 때마다 옛 격자를 못 돌려받는다 — 512KB 로 **resize 7번**이면
OutOfMemory 였다(헤드리스 실측). 모바일은 **키보드를 올렸다 내리기만 해도** 리사이즈다.

**resize 가 실패하면 기록도 안 바꾼다.** 실패한 채 크기 기록만 새 값으로 덮으면 코어는 옛
크기인데 순회는 새 크기로 돌아 없는 셀을 읽는다. 순회 기준을 **코어가 들고 있는 크기**로
두어 갈릴 자리 자체를 없앤다.

**코어가 만드는 것은 쓰는 자리에서 함께 치운다.** 데스크톱은 매 프레임 답을 PTY 로 흘리고
셸 이벤트를 소비 후 비운다. 모바일은 코어에 쓰는 자리가 둘뿐이라(입력·최초 대본) 거기서
같이 치운다 — 안 치우면 셸 이벤트가 상한 4096 에 닿고 그 뒤로 **전부 드롭되며 overflow 가
영원히 선다**(프롬프트 사이클 2000회면 닿는다. 코어 주석이 "프레임마다 drain 되면 닿을 일이
없다" 고 전제하는 자리다).

**키는 아직 `core.encodeKey` 를 안 탄다.** 지금은 `\r`·`0x7F` 를 손으로 적어 넣는다 —
DECCKM·수정자·kitty 프로토콜이 전부 빠져 있다. 보조 키바를 만들기 **전에** 키 이벤트 ABI 가
필요하다(계획 M4a2).

**코어가 만든 답은 누가 치우는가.** 터미널 코어는 질의(DA·DSR·커서 위치)에 **답을 만든다**.
데스크톱은 그 답을 PTY 로 흘리고 버퍼를 비운다(`app/runtime.zig`·`app/pty_reader.zig`).
모바일에는 아직 흘려보낼 곳이 없어 안 치우면 쌓이기만 한다 — 질의 3000번에 15005바이트
(실측). 지금은 **버리되 조용히 버리지 않는다**(`response_dropped`). 원격 세션(M3)이 붙으면
그쪽으로 흘려보내야 한다.

**반환값이 계약이면 그 값이 참이어야 한다.** `maru_mobile_input` 은 "코어에 전달한 누적
바이트" 를 돌려준다고 적어 놓고, 코어가 아직 없거나 write 가 실패해도 그냥 더하고 있었다 —
그 값으로 입력이 죽었는지 판정하라고 해 놓고 값이 거짓말을 한 셈이다. 닿은 것만 센다.

**용량 상한은 코어가 답한다.** quad 버퍼 크기를 host 마다 손으로 적어 두면 어긋난다 —
실제로 iOS 는 필요할 때 늘리고 Android 는 4096 에서 **조용히 자르고** 있었다. 지금은 코어가
격자 상한(`max_cols`×`max_rows`)에서 계산해 `maru_mobile_max_quads()` 로 답하고, 두 host 가
그만큼 잡는다. 늘어난 상주 메모리는 약 1.4MB 로, 앱 PSS(약 57MB) 안에서 구분되지 않는다.

**GPU 자원은 device 보다 오래 살면 안 된다.** 업로드용 staging 버퍼를 안 지운 채
`vkDestroyDevice` 를 불렀더니 창 크기를 아홉 번 바꾸는 것만으로 드라이버 안에서 SIGSEGV 가
났다(툼스톤 `on_vkDestroyDevice_pre`). 실패 경로에서도 자식을 남기지 않는다.

이 계약들은 `tests/mobile_bridge_contract.zig` 가 지킨다 — 브리지가 OS 를 안 부르므로
시뮬레이터 없이 `zig build test` 에서 돈다.

**문자열은 UTF-8 경계에서 자른다.** 조합 중 문자열을 바이트 수로만 자르면 한글이 반토막
나고, 그리는 쪽이 그 문자열을 통째로 버려 **조합이 화면에서 사라진다**(멈춘 것처럼 보인다).

## 6. 베이스

**같은 구조의 제품이 이미 출시돼 있다.** libghostty(Zig 터미널 코어) + 네이티브 GPU 로
만든 iOS 터미널이 여럿이다(Metal 렌더링). 우리 구조가 외톨이가 아니라는 뜻이고, 자체
성능 측정 전까지는 이것이 가장 강한 근거다.

**그리고 그것들이 전부 SSH/Mosh 클라이언트다** — §1 의 "iOS 는 원격 전용" 이 우리만의
제약이 아니라 플랫폼이 강제하는 결론이라는 독립 증거다.

`GameActivity` 권장과 `NativeActivity` 의 텍스트 입력 한계는 Android 공식 문서가 소유한다.
모바일 GPU 가 draw call 오버헤드에 민감하다는 것은 Vulkan 공식 모바일 가이드가 소유한다.

## 7. 아직 안 따르고 있는 기존 계약

**새로 정할 것이 아니라 이행이 빠진 것들**이다. 데스크톱이 이미 계약으로 정해 뒀다.

| 계약 | 모바일 상태 |
|---|---|
| [chrome 상호작용 이관](chrome-interaction-migration.md) — interactive node 가 semantic descriptor 를 내고 플랫폼이 네이티브 접근성 요소로 투영한다 | **어댑터 없음.** GPU quad 뿐이라 VoiceOver·TalkBack 에게는 빈 화면이다 |
| [설정](configuration.md) — config 스키마·resolve 계약 | **config 를 안 읽는다.** `themeColors()` 가 값을 고정한다 — 폰트 크기 하나 못 바꾼다 |
| [배포](distribution.md) — 채널·서명·업데이트 | **모바일 스토어를 안 다룬다.** `AndroidManifest.xml` 의 `android:debuggable="true"` 는 개발용이라 배포 전에 반드시 뺀다 |

계획은 [M9~M11](plans/mobile-platform.md)이 소유한다.

## 8. 아직 정하지 않은 것

- **성능 예산.** 실기기가 있어야 잰다. 에뮬레이터 GPU 는 `llvmpipe` 소프트웨어 래스터라
  숫자가 의미 없다.
- **아틀라스 축출** 정책.
- **스크롤·선택·복사**와 터미널용 **보조 키바**(모바일 키보드에 `Esc`·`Ctrl`·화살표가 없다).
- **회전·태블릿** 레이아웃.
- **iOS IME preedit.** Android 는 정했다(§1 — shim 이 `setComposingText` 를 넘기고 코어가
  커서 자리에 흐리게 그린다). iOS 는 `UITextInput` 의 marked text 를 같은 자리에 태우면
  되지만 아직 안 했다.
- **원격 전송·인증**(§1 의 충돌). 이것이 정해지기 전에는 모바일이 세션에 붙지 못한다.
