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
| M2 | **Android IME** — 자체 Java shim 이 `InputConnection` 을 받는다 | 완료(일부 미검증) |
| M3a | **컨트롤 플레인 원격 축** — 전송·인증·암호화 계약(doc-first) | 미착수 |
| M3b | 모바일 클라이언트 부착 | 미착수 |
| M4 | 스크롤·선택·복사 + 보조 키바 | 미착수 |
| M5 | 회전·태블릿 레이아웃 | 미착수 |
| M6 | 실기기 성능 예산 + 아틀라스 축출 | 미착수 |
| ~~M7~~ | ~~CI 통합~~ — **안 한다**(아래) | 취소 |
| M8 | `features-ios` 를 앱으로 — `simctl spawn` 에서 멈춘다 | 미착수 |


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

## M2 — Android IME (자체 Java shim)

**`GameActivity` 를 시도했다가 되돌렸다.** 코드 이관과 빌드까지 통과했지만 실행에서
`ClassNotFoundException: androidx.appcompat.app.AppCompatActivity` 로 죽었다 — `GameActivity`
가 전 버전에서 `AppCompatActivity` 를 상속해 AndroidX 20여 개와 리소스 컴파일이 필요하고,
그건 Gradle 없이 손으로 조립할 수 없다. 계획할 때 못 본 비용이라 결정을 다시 했다
(근거는 [계약 §1](../mobile-platform.md#1-확정-결정)).

`NativeActivity` 를 유지하고 IME 만 자체 shim 으로 받는다.

```text
MaruActivity(NativeActivity)   투명 입력 View 를 얹고 소프트 키보드를 띄운다
  └ MaruInputView              onCheckIsTextEditor()=true → IME 가 입력 대상으로 인정
      └ MaruInputConn          setComposingText/commitText 를 JNI 로 넘긴다
```

### 검증된 것과 안 된 것

| | 상태 |
|---|---|
| shim 이 입력 대상으로 인정됨 | **OK** — 소프트 키보드가 뜬다 |
| `commitText` → 코어 | **OK** — 키를 눌러 `commit="a"` 도달 |
| preedit 렌더(커서 자리에 흐리게) | **OK** — 주입해서 확인 |
| IME 조합 → preedit 왕복 | **미검증**(아래) |

**조합을 실제로 흘려 보지 못했다.** 이 에뮬레이터에는 Gboard(LatinIME)뿐이고 한글 IME 가
없다. 영어 Gboard 는 이 입력 타입에서 `setComposingText` 없이 바로 `commitText` 를 부른다.
그래서 "IME 가 만든 조합 문자열이 preedit 으로 그려진다" 는 왕복은 **한글 키보드가 있는
기기에서 손으로 확인해야 한다**.

실측으로 잡은 것들:

  - `adb shell input text` 는 **IME 를 우회**한다(키 이벤트 주입). IME 경로 검증에 못 쓴다.
  - `BaseInputConnection(view, false)` 면 IME 가 "편집기가 아니다" 로 보고 조합 없이 바로
    확정한다 — `true` 여야 한다.
  - `NativeActivity` 는 `android.app.lib_name` 의 .so 를 **클래스로더 밖에서 dlopen** 한다.
    Java 쪽 `System.loadLibrary` 를 한 번 더 해야 JNI 이름 해석이 된다.
  - `d8` 8.2.2 가 **익명 내부 클래스에서 내부 오류로 죽는다**. 이름 있는 중첩 클래스만 쓴다.

## M3 — 원격 연결

**두 플랫폼 다 원격 전용이다**(사용자 확정). 로컬 PTY 를 안 둔다.

그런데 지금 컨트롤 플레인은 **명시적으로 로컬 전용**이다 — "wire 는 TCP/HTTP 를 바인드하지
않는다", 보안은 "같은 uid 안의 신뢰 차등"(peer-cred + 0700/0600). **peer-cred 는 기계를
넘으면 존재하지 않는다.** 그래서 M3 는 클라이언트를 붙이는 일이 아니라 **계약을 넓히는
일**이고, M3a(문서)가 먼저다.

정해야 할 것:

  - **전송**: 무엇을 타고 가는가(SSH 터널 · Tailscale 같은 mesh VPN · 자체 릴레이 ·
    Cloudflare Tunnel). 각각 비용·계정·인바운드 포트 요구가 다르다.
  - **인증**: peer-cred 를 대신할 것. 기기 페어링? 토큰? 공개키?
  - **암호화**: 전송이 이미 암호화하는가, 아니면 우리가 종단간으로 하는가.
  - **신뢰 등급**: 원격 클라이언트가 `browser.*` 같은 write 능력을 갖는가.

한 가지는 이미 실측했다 — `session_host` 클라이언트(23k줄)가 **iOS 타깃으로 그대로
컴파일된다**. 코어 쪽은 이식 가능하고, 막는 것은 전송·인증 계약뿐이다.

## 코드 리뷰 후속 (M2 뒤)

`/code-review high` 가 13건을 냈고 **상위 여섯이 제품 경로 결함**이었다. 10라운드 적대적
검증이 문서·구조 정합성에 치우쳐 **오래 돌 때 생기는 것**을 못 봤다 — 시뮬레이터에서 몇 초
띄워 스크린샷만 확인했으니 512바이트도, 재개 후 글리프 손실도 드러날 수가 없었다.

| 결함 | 상태 | 검증 |
|---|---|---|
| 입력이 512바이트에서 영구히 죽음 | 수정 | **재현→해소**(`total=512` 고정 → `total=1995`) |
| 아틀라스 여유 슬롯 15개 | 수정 | **재현→해소**(성장 27자, 384x1024) |
| 미스 목록 swap-remove 로 절반 건너뜀 | 수정 | 배치당 8·6자로 늘어남 |
| 재개 후 성장 글리프 소실 | 수정 | 원본 버퍼에도 기록(경로 검증은 미실시) |
| 제품이 `/data/local/tmp` 의존 | 수정 | **tmp 를 비우고 정상 기동 확인** |
| 단폭 셀 종횡비 | 수정 | 화면 대조 |
| teardown 이 자식을 안 지움 | 수정 | 코드 검토(누수 계측 미실시) |
| 스왑체인 재생성 없음 | 수정 | **재현 불가**(아래) |
| `chor_started` 잔존 · 100% CPU 스핀 | 수정 | 코드 검토 |
| quad 버퍼 넘침이 조용함 | 수정 | `last_error` 로 노출 |
| 미리 굽는 글자 집합 중복 | 수정 | 헤더 단일 출처 |
| push 전용 job 의 무의미한 draft 가드 | 수정 | — |

**스왑체인 재생성은 이 환경에서 재현하지 못했다.** `wm size` 로 표시 해상도를 바꿔도
`vkAcquireNextImageKHR` 이 계속 `VK_SUCCESS` 를 돌려주고, `vulkan_recreated`·새 `logical=`
로그가 하나도 안 나오는데 화면은 새 크기로 맞아 보인다 — **SurfaceFlinger 가 낡은 버퍼를
늘려 준 것**이다(그 둘이 동시에 참인 다른 설명이 없다). 액티비티가 portrait 고정이라
`wm size` 는 앱 surface 를 리사이즈하지 않고 디스플레이만 바꾼다.

그래서 두 겹으로 고쳤다: (1) `OUT_OF_DATE`/`SUBOPTIMAL` 을 받으면 다시 만든다(스펙 경로),
(2) **매 프레임 창 크기를 직접 비교**한다 — 드라이버가 안 알려 줘도 잡히도록. 실기기에서
회전으로 확인해야 한다.
