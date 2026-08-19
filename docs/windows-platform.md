# Windows 플랫폼

Windows에서 maru를 띄우기 위한 계약의 단일 출처다. 레이어 경계는 [레이어링과 이식성](layering-and-portability.md),
PTY 계약은 [PTY 운영 모델](pty-operating-model.md), 셸 설정 키는 [셸과 환경](configuration-shell.md),
cwd 축의 2단 모델은 [소스 컨트롤 도크](editor-surface-dock.md) §3.5를 단일 출처로 둔다. 단계 진행은
[구현 계획](plans/windows-platform.md)이 소유한다(이 문서는 상태를 쓰지 않는다).

## 1. 확정 결정

- **Windows는 지원 대상이다.** macOS가 여전히 주 타깃이고, Windows는 그 다음이다.
- **어디서 작업하는지는 슬라이스에 따라 다르다.** 중립 레이어를 정리하는 앞 슬라이스(`SpawnRequest` 중립화,
  `main.zig` 컴파일)는 **`main`에서** 한다 — 이미 Windows 호스트에서 중립 테스트가 초록이라
  ([layering-and-portability.md](layering-and-portability.md) §4.1) 회귀가 보이고, 그 정리는 **Windows와
  무관하게 가치가 있다**(예: `zdotdir` 일반화는 zsh 전용 형태 때문에 막혀 있던 **fish** 통합을 푼다 —
  [configuration.md](configuration.md)가 "fish는 vendor `conf.d`로 깔끔히 주입할 수 있으나"라고 진단해 뒀다.
  **bash는 별개다** — 거기서 막힌 것은 필드 모양이 아니라 `login=true`로 띄워 `--rcfile`이 무시되는 것이라
  `login` 쪽 결정이 필요하다). L4를 통째로 새로 만드는 뒤 슬라이스(ConPTY·
  Win32 host)를 브랜치로 뺄지는 **그 시점에 판단한다.** [모바일](mobile-platform.md)이 선례다 — 장수 브랜치에서
  spike한 뒤 `main`으로 합류했다. 같은 L4 신규 타깃이라 같은 모양이 될 수 있다.
- **네이티브 Windows 셸이 1급이다.** WSL만 지원하는 것은 답이 아니다. PowerShell과 cmd에서도 동작해야 한다.
- **셸 통합은 비공개 API 없이 한다.** 자식 프로세스 환경에 통합을 주입하는 방식이며, 레지스트리·`AutoRun`·
  관리자 권한을 쓰지 않는다(§3).
- **GPU 백엔드는 이 문서가 정하지 않는다.** 4단계(창·렌더)에 가서 웹뷰 합성 모델과 **함께** 정한다 —
  둘이 사실상 같은 결정이기 때문이다([layering-and-portability.md](layering-and-portability.md) §4).
- **영속 세션 호스트는 범위 밖이다.** unix domain socket·fd 상속·동일 PID exec migration에 직결돼 있어
  Windows에서는 named pipe 기반 재설계가 선행이다. 별도 이니셔티브로 둔다.

## 2. 폴더 구조

```text
src/pty/
  windows.zig          ConPTY 백엔드 — session.zig의 PtySession 계약을 구현
src/platform/windows/
  (4단계에서) Win32 host — 창·입력·IME·클립보드
```

`src/pty/session.zig`가 이미 자리를 비워 두고 있다 — `PtySession`은 `builtin.os.tag` switch이고,
`UnsupportedPtySession`이 백엔드가 지켜야 할 표면을 시그니처로 들고 있다. Windows 백엔드는 그 switch에
`.windows` 갈래를 더한다.

**호스트에 제2 언어를 두지 않는다.** macOS가 Swift를 쓰는 이유는 AppKit이 Objective-C/Swift 전용이기
때문이고, 그래서 `app_host_abi.zig`(212개 `export fn`)라는 C ABI 경계가 필요했다. Windows에는 그 강제가
없으므로 **Zig 한 언어로 간다** — 언어 경계도, 그 경계를 넘기는 marshaling 레이어도 필요 없다. 두 L4의
모양이 달라지지만 L4는 정의상 타깃별 신규다. **ABI는 이식 이음매가 아니다** — 이음매는 renderer 중립 계약이다.

> **다만 "Win32는 다 C API"는 아니다.** 창·입력·IME(`user32`·`imm32`)는 평범한 C지만, **DirectWrite·
> D3D11/DXGI·DirectComposition은 COM**이다. Zig에서 COM은 vtable을 `extern struct`로 직접 놓으면 되지만
> 편의 계층이 없어 평범한 C 호출보다 손이 더 간다. **제2 언어가 필요하다는 뜻은 아니고**(C++ 불필요),
> W7의 비용을 "C 함수만 부르면 된다"로 과소평가하지 않기 위한 단서다.

### 2a. GPU 백엔드 — D3D11 + DXGI (결정)

Metal의 대응물은 **D3D11**이고 표시·프레임 페이싱은 **DXGI**가 맡는다. W7의 선행 결정 둘 중 하나였고, 이제
남은 것은 웹뷰 합성 모델뿐이다(§8).

**왜 D3D11인가.** ⑴ 이 렌더러가 필요로 하는 것이 그 세대에 다 있다 — 텍스처 아틀라스·인스턴스 드로우·상수
버퍼가 전부다. D3D12가 주는 것(명시적 동기화·커맨드 리스트 재사용·번들)은 이 워크로드가 쓰지 않을 능력인데
대신 리소스 수명·펜스 관리를 전부 앱이 지게 된다. ⑵ 드라이버 요구가 가장 낮다 — Windows 10/11에서 사실상
어디서나 돈다. ⑶ 프레임 페이싱이 같은 스택에 있다(`io-render-present.md`가 이미 "Win=DXGI/WaitForVBlank"로
적어 둔 것) — 백엔드와 present를 다른 API 가문으로 나누지 않는다. ⑷ WebView2 합성이 DirectComposition으로
가면 D3D11 스왑체인과 그대로 맞물린다.

**Vulkan은 왜 아닌가.** 모바일(Android)이 이미 Vulkan을 쓰므로 "하나로 합치자"가 후보였다. 그러나 Windows
데스크톱에서 Vulkan은 드라이버 편차와 설치 의존이 붙고, 위 ⑶·⑷의 이음매를 잃는다. L4는 정의상 타깃별
신규이므로(§2) 백엔드를 공유해서 얻을 것이 크지 않다 — 이음매는 renderer 중립 계약이지 GPU API가 아니다.

**대가**: COM vtable을 직접 놓아야 한다(위 단서). 그리고 `renderer`의 중립 계약이 Metal 한 구현에만 맞춰져
있지 않은지는 W7에서 실제로 두 번째 구현을 붙여 봐야 드러난다 — 그것이 이 슬라이스가 이식성 주장을 검증하는
방식이다.

### 2b. Win32 창과 메시지 펌프 — 이벤트를 잃지 않는 규율 (W7.1 결정, 실측 2026-08-17)

창은 `src/platform/windows/win32_window.zig` 하나가 소유한다. **호스트에 제2 언어를 두지 않는다**(§2) — macOS가
`app_host_abi.zig`라는 C ABI 경계를 둔 것은 AppKit이 Objective-C/Swift 전용이기 때문인데, Win32에는 그 강제가
없어 Zig에서 직접 부른다. 창이 하는 일은 셋뿐이다: 만들고, 펌프하고, OS 메시지를 **중립 이벤트**(`resized`·
`paint`·`close_requested`)로 바꿔 호출자에게 준다. 그리기·입력 해석·앱 정책은 여기 없다.

**표시 대상은 주입받는다.** `PresentTarget`이 그 자리이고 W7.2가 채운다. 웹뷰 합성 모델(§8)이 닿는 곳은
창 스타일과 스왑체인 생성 **두 지점뿐**이라, 창이 표시 대상을 만들지 않고 받는 모양만 지키면 전환 비용이
거기 머문다.

**`PeekMessage`는 메시지의 절반만 준다.** Win32 메시지에는 두 갈래가 있다. `PostMessage` 계열은 스레드 큐에
쌓여 `PeekMessageW`가 꺼내지만, `SendMessage` 계열은 **큐를 거치지 않고 `WndProc`을 곧장 부른다**.
`ShowWindow`·`SetWindowPos`·`DestroyWindow`가 `WM_SIZE`를 그렇게 보낸다. 즉 **우리가 `poll` 안에 있지 않을 때도
이벤트가 들어온다.** 그래서 `poll` 진입에서 큐를 통째로 비우면 그 이벤트가 사라진다 — 실측으로 겪었다:
`show()`가 만든 `WM_SIZE`가 첫 `poll`에 지워져 스모크가 `resized_events=0`을 냈다.

**규칙: 버퍼를 둘 두고 맞바꾼다.** `WndProc`은 언제나 `incoming`에 넣고, `poll`은 펌프를 끝낸 뒤 두 버퍼를
맞바꿔 `outgoing`을 돌려준다. 넘긴 버퍼에는 다음 `poll`까지 아무도 쓰지 않으므로, 호출자가 슬라이스를 순회하는
도중 `WndProc`이 이벤트를 더 올려도(순회 중 `requestClose`를 부르면 `DestroyWindow`가 `WM_SIZE`를 동기 전송한다)
재할당으로 무효화되지 않는다. 한 버퍼를 빌려주면 그 use-after-free를 API가 **초대한다** — 대조군에서 실제로
segfault가 났다.

**창 포인터는 `lpParam`으로 넘겨 `WM_NCCREATE`에서 붙인다.** `CreateWindowExW`는 반환하기 **전에**
`WM_NCCREATE`·`WM_CREATE`를 동기로 보낸다. 반환 뒤에 `GWLP_USERDATA`를 붙이면 그 구간의 `WndProc`이 창을
못 찾아 이벤트가 `dropped`에도 안 잡히고 사라진다 — 계약이 생성 구간에서만 조용히 깨진다. 이 스타일
(`WS_OVERLAPPEDWINDOW`, 비표시)에서는 반환 전 `WM_SIZE`가 오지 않아 지금은 드러나지 않지만, 구멍을 열어 둘
이유가 없다.

**창이 여럿이 되면 폴링 규약이 하나 더 필요하다.** `PeekMessageW(hwnd=null)`은 그 **스레드의** 메시지를 전부
꺼내 각자의 `WndProc`으로 보낸다 — 창 A의 `poll`이 창 B의 큐를 채운다. 동작은 맞지만 B를 아무도 `poll`하지
않으면 B의 이벤트가 무한히 쌓인다. 펌프를 창 밖으로 빼거나 모든 창을 매 프레임 `poll`하는 규약을 **W8에서**
정한다. 지금은 창이 하나다.

`WM_CLOSE`에서 **창을 닫지 않는다**. 호출자가 정책(세션 종료 확인 등)을 처리한 뒤 `requestClose`를 부른다 —
macOS의 `windowShouldClose` 분담과 같다. `WM_PAINT`에서도 **그리지 않는다**(`BeginPaint`/`EndPaint`조차 하지
않는다) — W7.2가 스왑체인으로 present하면 GDI 페인트 사이클과 섞이면 안 되고, 무효 영역 정리는
`DefWindowProcW`에 맡긴다. 배경 브러시도 주지 않는다(OS가 먼저 칠하면 매 프레임 전체를 그리는 W7.2와 깜빡인다).

**`user32`·`gdi32`는 명시적으로 링크해야 한다**(`build.zig`). 안 하면 `RegisterClassExW`가 0을 돌려주고
`GetLastError`도 0이라 원인이 안 보인다 — atom이 0에서 49824로 바뀌는 것으로 확인했다.

**실기 캡처** (Windows 10 Pro 19045, `maru win32-window-smoke`):

![W7.1 Win32 창 — 생성 직후와 외부 리사이즈](images/w7-1-win32-window.png)

창이 뜬 뒤 **외부에서** 960×600 → 640×400으로 줄이자 `resized_events` 1→2, `client_px` 944×561→624×361,
`cells_at_8x16` 118×35→78×22가 따라왔다 — 메시지 펌프부터 셀 격자 변환까지가 한 줄로 이어진다는 증거다.
클라이언트가 비어 있는 것은 정상이다(위 "배경 브러시를 주지 않는다").

**`ERROR_NOT_ENOUGH_MEMORY`(8)는 메모리가 아니라 데스크톱 힙이다.** 창 생성이 8로 실패하면 그 세션 전체가
창을 못 만드는 상태다(실측: 고아 프로세스 8,606개가 `SharedSection` 20MB를 채워 notepad조차 뜨지 않았다).
앱 버그로 오진하기 쉬워 스모크가 이 코드를 따로 안내한다.

**Zig의 게으른 분석이 테스트를 통째로 삼킨다.** `win32_window.zig`는 `main.zig`(root)만 import하는데, 테스트
빌드에는 `main()`이 없어 그 import를 아무도 참조하지 않고 **파일 안의 테스트가 수집조차 되지 않는다**(실측:
2,614개가 통과하는 동안 이 파일 테스트는 0개 돌았다). `main.zig`의 `test { _ = win32_window; }` 한 줄이 그
구멍을 막는다 — `check-targets`가 `main.zig`를 놓쳤던 것과 같은 부류다.

### 2c. D3D11 표시 경로와 COM 규약 (W7.2a 결정, 실측 2026-08-17)

표시 경로는 `src/platform/windows/d3d11_present.zig`가 소유하고 **"화면에 내보내는 것"만** 안다 — 디바이스를
만들고, 스왑체인을 잡고, 백버퍼를 지우고, present한다. 무엇을 그릴지(셀·아틀라스·셰이더)는 W7.2b가 이 위에
얹는다. 창(§2b)과 같은 이유로 갈랐다: 실패가 어느 층에서 났는지 한 층씩 확인할 수 있어야 한다.

**스왑체인은 HWND에 붙인다 — 그리고 합성 모델은 아직 정하지 않는다.** §8의 웹뷰 합성 결정은 열어 두고
`CreateSwapChainForHwnd`로 간다. W7.1이 그 결정을 두 지점(창 `dwExStyle`·스왑체인 생성)에 가둬 뒀으므로
전환이 설계대로 싸다. 다만 **W8이 다시 발견하지 않도록 결론을 적어 둔다**: HWND 오버레이로 웹뷰를 붙이면
WebView2가 자식 HWND가 되고 그 영역 위에는 우리 스왑체인이 그릴 수 없다(airspace). 그러면 macOS의
`터미널 < 웹뷰 < 오버레이` z-order가 뒤집혀 모달이 웹뷰 뒤로 숨는다. 그 순서를 지키려면 DirectComposition +
WebView2 visual hosting이어야 한다 — **W8의 선택지는 사실상 하나다.**

**COM을 Zig로 쓰는 규약** (이 저장소의 첫 COM 소비자다 — 이전엔 `IUnknown`도 `QueryInterface`도 없었다).
COM 객체는 첫 워드가 vtable 포인터인 구조체이고, vtable은 함수 포인터가 **정해진 순서로** 늘어선 것이다.
그 순서가 곧 ABI라 슬롯 하나를 빠뜨려도 **컴파일은 되고** 런타임에 엉뚱한 함수를 부른다. 그래서 둘을 지킨다:

| | 규칙 | 왜 |
|---|---|---|
| ⑴ | 부르지 않는 슬롯도 **자리를 채운다**(`*const anyopaque`) | 타입이 없으니 실수로 못 부른다 |
| ⑵ | 슬롯 번호를 **`@offsetOf`로 comptime에 못 박는다** | 위에 슬롯을 끼워 넣으면 그 자리에서 컴파일이 멈춘다. comptime이라 **Windows 러너 없이 세 타깃 전부** 이 게이트를 통과해야 한다 |

**실측으로 정해진 값 셋.**

- `AlphaMode`는 `UNSPECIFIED`여야 한다. `IGNORE`는 합성 스왑체인용이고, HWND에 주면
  `CreateSwapChainForHwnd`가 `DXGI_ERROR_INVALID_CALL`(0x887A0001)로 거절한다.
- **`MakeWindowAssociation(DXGI_MWA_NO_ALT_ENTER)`은 터미널에 필수다.** 스왑체인을 만들면 DXGI가 그 창의
  Alt+Enter를 후킹해 독점 전체화면을 토글한다 — Alt+Enter는 앱 키바인딩이라 그대로 두면 W7.4의 입력이 그
  키를 영영 못 받는다. 스왑체인을 만든 **뒤에** 불러야 연결이 잡힌다.
- 형식은 `B8G8R8A8_UNORM`, 스왑 효과는 `FLIP_DISCARD`, 버퍼 2장. BGRA인 이유는 합성기 기본 형식이라 present에
  변환이 끼지 않고, `NativeMetalCell`의 색이 이미 `0xAARRGGBB`(= BGRA 바이트 순서)라 W7.2b가 그대로 쓴다.

**하드웨어가 없으면 WARP로 선다.** 계획 문서가 "Windows는 WARP가 있어 GPU 없는 러너에서도 렌더 스모크를
돌릴 여지가 있다"고 적어 둔 그 여지를 코드가 실제로 연다. 어느 쪽으로 섰는지는 숨기지 않고 보고한다
(`driver=hardware|warp`) — WARP로 떨어진 줄 모르면 성능을 잘못 판정한다.

**창 투명도는 여기서 정해지지 않는다.** `AlphaMode`가 `UNSPECIFIED`라 합성기가 알파를 무시하고 창은
불투명하다. macOS의 `window_opacity_milli`에 해당하는 것은 스왑체인이 아니라 **합성 모델**(DirectComposition
또는 레이어드 윈도)이 정하므로, §8의 웹뷰 결정과 같은 자리에서 함께 열린다.

**실기 캡처** (Windows 10 Pro 19045, `maru d3d11-present-smoke`):

![W7.2a D3D11 present — GPU가 칠한 화면과 리사이즈](images/w7-2a-d3d11-present.png)

화면 중앙 픽셀이 요청한 `0xFF1E2430`과 정확히 같다. R/B가 뒤집혔다면 `#30241E`가 나왔을 것이므로 **채널
순서까지 화면으로 확인된다** — 이것이 이 슬라이스의 판정식이다(present가 "성공을 반환했다"만으로는 부족하다).

### 2d. 셀 인스턴스 드로우 (W7.2b 결정, 실측 2026-08-17)

셀을 그리는 것은 `src/platform/windows/d3d11_cells.zig`가 소유하고 **"셀 하나를 어떻게 화면에 그리는가"만**
안다 — 무엇이 셀인지(터미널 화면·사이드바·chrome)는 호출자가 정한다. 디바이스·스왑체인은 §2c가 만든 것을
**빌려 쓴다**(놓아 주지 않는다).

COM 타입·상수는 `d3d11.zig`(바인딩 층)가 소유한다. 표시 경로와 셀 파이프라인이 같은 인터페이스를 쓰므로
한쪽에 두면 다른 쪽이 그 파일을 통째로 import해야 하고, 그러면 경계가 이름만 남는다.

**블렌드 규약은 macOS와 같다 — 여기서 다시 정하지 않는다.** `renderer/metal_frame.zig`의
`NativeMetalCell`이 이미 못 박았다: 배경 알파가 `0xFF`면 셀을 그 색으로 채우고 글리프를 위에 섞고
(`mix(bg, fg, coverage)`), `0`이면 배경 없이 커버리지만 그려 테마 기본 배경(clear color)이 비친다. 두 백엔드가
같은 화면을 내야 하므로 이것이 픽셀 셰이더의 유일한 분기다.

**아틀라스는 `R8G8B8A8_UNORM`이고 커버리지는 알파에 있다.** `renderer/glyph_pixels.zig`의 `setPixel`이
픽셀당 **4바이트**를 쓰고 RGB를 흰색으로 채운다 — 덮임 정도는 알파다(`setPixelAlpha`가 부분 커버리지를 그렇게
넣는다). 처음에 `R8_UNORM`으로 잡았다가 그 픽셀 계약을 읽고 고쳤다. 색은 셀이 들고 오므로 아틀라스의 RGB는
쓰지 않는다.

**정점 버퍼가 없다.** 사각형 네 꼭짓점은 `SV_VertexID`에서 만든다(`vid & 1`이 x, `vid >> 1`이 y → triangle
strip 4개). 셀은 전부 축 정렬 사각형이라 정점을 올릴 이유가 없고, 슬롯 0에는 **인스턴스 데이터만** 간다.
첫 삼각형이 NDC에서 시계 방향이라 기본 컬링에 걸리지 않아 rasterizer state도 만들지 않는다.

**셰이더는 런타임에 컴파일한다.** `d3dcompiler_47.dll`을 `LoadLibraryA`로 **동적으로** 찾는다. 이유가 둘이다 —
⑴ 빌드가 Windows SDK(`fxc`)를 전제하지 않는다(이 저장소는 mise가 준 Zig 하나로 빌드된다), ⑵ DLL이 없을 때
로더 단계에서 조용히 죽는 대신 사람이 읽을 수 있게 실패한다. 그 DLL은 Windows 8.1부터 **OS 구성요소**다
(실측: `System32`에 10.0.19041.3636).

**실패는 반드시 코드를 남긴다.** 컴파일 오류는 컴파일러 메시지까지 그대로 보여 준다 — 대조군으로 확인했다:

```text
maru d3d11-cells-smoke: 셀 파이프라인을 세우지 못했습니다(ShaderCompileFailed, HRESULT 0x80004005)
  셰이더 컴파일러: maru_cells.hlsl(39,17-44): error X3088: Texture2D<float4> object does not have method 'NopeSample'
```

**`synthesizeGlyph`에 오프셋한 슬라이스를 넘기면 안 된다.** 그 함수는 `len >= height * bytes_per_row`를
요구하고, 위반하면 **빈 글리프로 조용히 degrade한다**. 넓은 아틀라스 중간을 가리키는 슬라이스는 꼬리가
모자라 전부 이 경로로 빠진다 — 실측으로 겪었다: 슬롯 28개가 "채워졌다"고 나오면서 덮인 픽셀은 0이었다.
슬롯마다 따로 그린 뒤 행 단위로 옮겨 붙인다. **그래서 스모크가 덮인 픽셀 수를 따로 세어 보고한다** — 안
세면 성공처럼 보인다.

**실기 캡처** (Windows 10 Pro 19045, `maru d3d11-cells-smoke`):

![W7.2b 셀 인스턴스 드로우 — 합성 글리프와 3배 확대](images/w7-2b-d3d11-cells.png)

판정은 화면에서 세 색이 **각각** 나오는지다: `#1E2430`(배경 알파 0 → clear가 비친다)·`#2E3A4E`(배경 채운
셀)·`#D8E0F0`(글리프 전경), 그리고 그 사이 부분 커버리지 블렌드. 하나라도 빠지면 규약의 한 갈래가 죽은
것이다. 첫 열은 슬롯 0(빈 글리프)이라 배경만 남아, UV 0 자리가 커버리지 0임을 함께 보여 준다.

### 2e. DirectWrite 글리프 래스터라이저와 폰트 티어 (W7.3 결정, 실측 2026-08-17)

`src/platform/windows/dwrite_font.zig`가 **"코드포인트 하나를 픽셀로 만드는 것"만** 안다. 아틀라스 슬롯
배치·캐시·eviction은 `renderer/glyph_atlas.zig`가, 픽셀을 GPU에 올리는 것은 §2d가 한다. 채우는 것은 중립
계약이 요구하는 **RGBA8 버퍼 하나**다 — RGB는 흰색, 커버리지는 알파(`renderer/glyph_pixels.zig`와 같은 규약).

**합성 글리프는 여기까지 오지 않는다.** box-drawing·block·braille·powerline은 `renderer.synthesizeGlyph`가
코드포인트에서 직접 만든다(폰트로 그리면 셀에 안 맞아 이음매가 생긴다). 호출자가 `synthesizeGlyph(...) orelse
<DirectWrite>` 순서를 지키므로, 이 파일은 **그 집합에 없는 글자만** 받는다.

**셀 격자는 폰트가 정한다.** 주 폰트의 `GetMetrics`(ascent·descent·lineGap)와 `'M'`의 advance에서 셀
픽셀 크기와 베이스라인을 유도하고 **올림**한다 — 내림하면 글리프가 반 픽셀 새어 옆 칸을 침범한다.
음수 `line_gap`인 폰트가 실제로 있어 최소 1을 함께 보장한다(0이면 아틀라스 슬롯이 0바이트가 된다).

유도 규칙은 **순수 함수**(`cellMetricsFrom`)가 소유하므로 DirectWrite 없이 모든 타깃에서 테스트된다. 그
테스트가 흉내 내는 값은 추측이 아니라 실측이다 — 스모크가 `design_units`로 그 값을 보고한다:

| Cascadia Mono | upem | ascent | descent | line_gap | `'M'` advance | → 18px에서 |
|---|---|---|---|---|---|---|
| 실측 | 2048 | 1900 | 480 | 0 | 1200 | 셀 **11×21**, 베이스라인 **17** |

**회색 안티앨리어싱은 ClearType 텍스처를 평균해서 얻는다.** `IDWriteGlyphRunAnalysis`가 주는 알파 텍스처는
`ALIASED_1x1`(안티앨리어싱 없음)과 `CLEARTYPE_3x1`(RGB 서브픽셀) 둘뿐이다. 터미널에 계단은 쓸 수 없고 우리
아틀라스는 채널 하나만 쓰므로, 3바이트를 평균해 회색 커버리지로 만든다. 대가: ClearType 분석은 RGB
스트라이프를 가정해 튜닝돼 있어 평균값이 "진짜 회색 AA"와 완전히 같지는 않다(화면으로 판정했다).

#### 폰트 티어 — §3.1a의 셸 티어와 같은 모양

**주 폰트**: config `font.family` → `Cascadia Mono` → `Consolas` → `Courier New`. Cascadia는 Windows
Terminal의 기본이고 터미널용으로 설계됐다. Consolas는 Vista부터 어디나 있고, Courier New는 **없을 수가 없다**.
config의 OS 접미 메커니즘(W2.5)이 일반적이라 `font.family.windows`는 이미 동작한다 — 여기서 정한 것은
**아무것도 설정하지 않았을 때의 내장 기본값**뿐이다.

**폴백**: config `font.fallback`(쉼표 구분) → `Malgun Gothic` → `Noto Sans KR` → `Microsoft YaHei` →
`Microsoft JhengHei` → `Yu Gothic` → `Segoe UI Emoji` → `Segoe UI Symbol`. 없는 폰트는 조용히 건너뛴다
(configuration.md가 정한 best-effort와 같은 규칙).

**폴백이 필수인 이유는 실측이다.** 고정폭 라틴 폰트에는 한글이 없다 — Cascadia Mono에서 한글 10자가 전부
`.notdef`였고 화면에 빈 칸으로 나왔다. macOS는 `kCTFontCascadeListAttribute`로 CoreText에 맡기지만
DirectWrite의 자동 cascade는 `IDWriteFactory2` 이후에만 있어 **목록을 우리가 든다.** 폴백을 켜자
`slots_blank`이 10에서 0으로 떨어졌다.

**글리프가 없으면 다음 face로 내려간다.** `GetGlyphIndices`가 0(`.notdef`)을 주면 다음 폴백에 묻고, 전부
없으면 0을 돌려준다 — 그것이 "그릴 수 없다"의 정직한 답이고 호출자가 빈 칸으로 둔다. face는
`max_faces`까지만 연다(무한히 열지 않는다).

**두 칸 글자는 두 칸 폭으로 그린다.** 한글·CJK는 `terminal.cellWidth`가 2를 주므로 아틀라스 슬롯도 두 칸
폭으로 잡고 화면에서도 셀 하나를 두 칸 폭으로 그린다. 한 칸에 밀어 넣으면 글자가 반으로 잘리고, 셀 둘로
쪼개면 UV를 반씩 잘라야 해 규약이 복잡해진다(`NativeMetalCell.width`도 폭을 셀이 드는 방식이다).

**실기 캡처** (Windows 10 Pro 19045, `maru dwrite-text-smoke`):

![W7.3 DirectWrite 글리프 — 라틴·한글·합성 글리프](images/w7-3-dwrite-text.png)

폴백이 있을 때와 없을 때(같은 코드, 주 폰트도 같다):

![W7.3 폰트 폴백 있음/없음 대비](images/w7-3-dwrite-fallback.png)

판정은 **셋을 갈라 세는 것**이다 — `slots_from_font`·`slots_synthesized`·`slots_blank`. 합쳐 세면 폰트 경로가
죽어도 합성 글리프가 수를 채워 성공처럼 보인다.

### 2f. 중립 프레임 계약을 Windows 백엔드가 만족시킨다 (W7.2c-1, 실측 2026-08-17)

렌더러가 요구하는 duck-typed 계약은 **둘**이다. 그 둘을 채우는 얇은 층이 `src/platform/windows/win32_text.zig`다:

| 계약 | 메서드 | 구현 |
|---|---|---|
| 셰이퍼 | `shape(DrawCell) ShapeResult` | `Shaper` — 코드포인트를 face·글리프로 고른다 |
| 래스터라이저 | `rasterize(GlyphRasterRequest) GlyphRasterResult` | `NeutralRasterizer` — 그 결정으로 픽셀을 만든다 |

DirectWrite 자체는 §2e(`dwrite_font.zig`)가 안다. 그렇게 갈라 두면 그 파일이 렌더러를 모르고(픽셀만 안다),
이 파일이 DirectWrite를 모른다(계약만 안다).

**`font_id` 매핑을 한 곳이 소유한다.** 셰이퍼가 `font_id`·`glyph_id`를 정하고 래스터라이저가 그 값을 받는다.
래스터라이저가 코드포인트로 **다시 풀면** 두 결정이 갈릴 수 있고, 증상은 "글자가 이상한 폰트로 나온다"로만
보인다. 그래서 `fontIdForFace`/`faceIndexFromFontId`가 같은 파일에 있고 순수 함수라 두 방향이 맞물리는지
테스트된다. 합성 글리프는 face가 아니라 코드포인트가 정체이므로 **겹치지 않는 번호**(1)를 받고, face는 2부터
센다 — 아틀라스 캐시 키가 둘을 갈라야 한다.

**합성이 먼저라는 순서를 두 곳이 똑같이 지킨다.** 셰이퍼도 래스터라이저도 `isSynthesizedCodepoint` /
`synthesizeGlyph`를 먼저 본다. 한쪽만 지키면 "셰이퍼는 합성이라 했는데 래스터라이저는 폰트로 그린다"가 된다.

#### 조립 코드를 복사하지 않는다 — 중립 이음매를 한 줄 늘렸다

플랫폼 호스트가 자기 래스터라이저를 쓰려면 `host.buildFrameAfterDrain`에 그 값을 넘길 자리가 필요했다.
그 함수 본문에는 **코어 락 규율**(`io-render-threading.md` — 코어 읽기는 락 아래, shaping은 락 밖)이 있어,
복사하면 규율이 두 곳으로 갈리고 한쪽만 고쳐지는 순간 조용히 깨진다. 그래서 W7.2c는 중립 레이어에
`host.buildFrameAfterDrainWithRasterizer`를 추가했고, 기존 함수는 그것을 `FakeGlyphRasterizer`로 부른다
(동작 무변). 프레임 조립은 여전히 `host.zig` 한 곳이 소유한다.

Windows 프레임 빌더(`win32_terminal.zig`)는 중립 `FrameLoop.tickWithFrameBuilder`에 꽂히는 값일 뿐이다 —
macOS `AppSession`이 CoreText 빌더를 꽂는 것과 같은 분담이다.

#### 판정은 셋을 갈라 세는 것이다

`maru win32-frame-smoke`는 **창을 띄우지 않는다.** §2a가 걸어 둔 질문("중립 렌더러 계약이 Metal 한 구현에만
맞춰져 있지 않은가")의 답은 그림이 아니라 **계약이 받아들이는가**로 나온다. 실측:

```text
maru.win32-frame-smoke.v1
font_family=Cascadia Mono
cell_px=11x21
frames_built=45
glyph_quads=86400
atlas_uploads=39
upload_non_clear_pixels=1881
fallback_glyphs=0  replacement_glyphs=0  raster_skipped=0
atlas_entries=39
```

`upload_non_clear_pixels`가 판정이다 — 슬롯을 39개 올렸는데 덮인 픽셀이 0이면 글자가 하나도 안 그려진
것이고, 슬롯 수만 세면 그것을 못 잡는다. W7.2b·W7.3에서 같은 함정을 두 번 겪었다.

**그래서 §2a의 답은 예다.** 중립 계약은 Metal 한 구현에 맞춰져 있지 않았다 — 셰이퍼·래스터라이저 계약을
Windows 값으로 채우자 프레임이 그대로 섰고, 고쳐야 했던 것은 계약이 아니라 이음매 한 줄(래스터라이저를
넘길 자리)이었다.

### 2g. 실제 터미널 화면 — 프레임을 픽셀로 (W7.2c-2, 실측 2026-08-17)

§2f가 세운 프레임(실제 PTY → Windows 셰이퍼 → DirectWrite)을 §2c·§2d가 세운 표시 경로에 흘려 넣는다.
그 사이를 잇는 것이 둘뿐이다.

**⑴ 아틀라스 부분 업로드.** 프레임마다 새 글리프만 `UpdateSubresource`로 그 사각형에 올린다(전체를 다시
올리지 않는다). `UpdateSubresource`는 범위를 검사하지 않아 넘치면 조용히 다른 자리를 덮으므로 —
아틀라스에서는 그것이 **"글자가 다른 글자로 나온다"** 로 보인다 — 텍스처 밖을 가리키면 그리지 않고 알린다.

**아틀라스가 커지면 텍스처를 다시 만든다.** 이전 글리프가 사라지는 것이 맞다: 중립 아틀라스는 텍스처를
키울 때 `atlas_full`로 **전체를 무효화하고 (0,0)부터 재배치**하므로(`renderer/glyph_atlas.zig`) 그 프레임의
글리프가 전부 새 업로드로 다시 온다. 즉 오래된 UV가 남아 엉뚱한 픽셀을 샘플하는 일이 없다. macOS 렌더러
doc은 이 자리를 "growable atlas를 지원하려면 producer가 전체 업로드를 다시 보내야 한다"고 보수적으로 적어
뒀는데, 무효화 규약을 보면 그럴 필요가 없다.

**⑵ 셀 투영.** `metal_frame`의 `NativeMetalCell`을 `d3d11_cells.Cell`로 옮긴다. **정책은 중립 쪽에서
받는다** — 커서 오버레이·패널 origin·배경 없는 셀 같은 것을 다시 만들면 두 백엔드가 같은 화면을 못 낸다.
여기서 바꾸는 것은 좌표계(`(origin, row, col)` → 픽셀 사각형)와 색 표현(픽셀 → 0~1 UV, `0xAARRGGBB` → RGBA)
뿐이다.

`foreground`는 `0x00RRGGBB`로 **알파가 없다.** 그대로 풀면 알파 0이 되고 셰이더의 `cov * fg.a`가 커버리지를
죽여 **글자가 아예 안 나온다.** 불투명으로 채워야 한다(순수 테스트가 이 회귀를 고정한다).

**창 크기가 바뀌면 터미널 격자도 바꾼다**(`resizeActiveSurface`). 스왑체인만 맞추면 셸이 옛 크기로 계속
출력해 줄이 어긋난다.

#### 셀 메트릭을 렌더러에 알려 주지 않으면 글리프가 잘린다 (실측)

`RendererState.init`의 `TextLayoutConfig`를 기본값(`.{}` — 전부 0)으로 두면 아틀라스가 슬롯 크기를 다른 값으로
추정한다. 그러면 베이스라인이 슬롯 아래로 내려가 **글리프가 아래에서 잘린다.** 폰트가 정한 값을 넘겨야 한다:

```zig
.text = .{
    .font_size_px = 18,
    .device_scale = 1,
    .cell_width_px = cell_w,        // grid advance(자간 반영)
    .glyph_cell_width_px = cell_w,  // 폰트 글리프 자연폭(자간 무관)
    .cell_height_px = cell_h,
},
```

**화면을 보고 잡았고, 숫자가 확인해 줬다** — `upload_non_clear_pixels`가 1881에서 **2643(+40%)** 으로 늘었다.
잘려 있던 부분이 그만큼이었다.

**실기 캡처** (Windows 10 Pro 19045, `maru win32-terminal-smoke`):

![W7.2c-2 실제 터미널 화면과 잘림 전/후](images/w7-2c-terminal.png)

실제 PowerShell 7.6.3 세션이 창에 그려진다 — 프롬프트·경로·SGR 색(`echo` 노랑, `exit` 초록)·출력·계속
프롬프트·블록 커서.

**커서를 켜야 커서 경로가 돈다.** `CellColors.cursor`의 기본값은 `null`이고 그 뜻은 "커서를 투영하지
않는다"다(아틀라스 픽셀을 그대로 검증하는 골든 스모크가 커서 블록에 흔들리지 않게 하려는 기본값이다).
터미널 화면에는 커서가 있어야 하므로 켠다 — 안 켜면 화면이 그럴듯해 보여도 **커서 오버레이 투영 경로가
한 번도 안 돈다.** 켠 순간 `cells_drawn`이 2485에서 2486으로, 정확히 셀 하나 늘었다.

```text
maru.win32-terminal-smoke.v1
font_family=Cascadia Mono   cell_px=11x21   terminal_size=89x28
frames_presented=220        cells_drawn_last=2486
atlas_px=1024x1024 resizes=0   atlas_region_uploads=39
upload_non_clear_pixels=2643
fallback_glyphs=0 replacement_glyphs=0 raster_skipped=0
swapchain_px=984x601 driver=hardware
```

### 2h. 키 입력과 ⌘ 매핑 (W7.4a 결정, 실측 2026-08-18)

창이 `WM_KEYDOWN`/`WM_CHAR`를 받아 **중립 `KeyEvent`**로 바꿔 올리고, 앱 동작이냐 셸 입력이냐는
`FrameLoop.handleKeyEvent`(중립 정책)가 정한다 — 창은 키바인딩을 알지 않는다. 변환 규칙은
`src/platform/windows/win32_keys.zig`가 **순수 함수로** 소유하므로 Windows 러너 없이 세 타깃 전부에서
테스트된다.

**문자는 `WM_CHAR`가, 그 밖은 `WM_KEYDOWN`이 준다.** VK 코드는 물리 키이지 문자가 아니므로 거기서 문자를
짐작하면 비영문 레이아웃(한글 두벌식·QWERTZ)이 깨진다 — 레이아웃·데드키 해석은 OS가 한다.
`keyFromVirtualKey`가 문자 키에 `null`을 주는 것이 그 규칙이다.

**Ctrl·Alt 조합만 `WM_KEYDOWN`에서 문자를 복원한다.** `WM_CHAR`는 그때 제어 바이트를 주는데
(`Ctrl+A` → 0x01) 우리는 "문자 `a` + control"이 필요하다 — 인코딩은 중립 `encodeKey`가 해야 한다.
복원은 `MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)`로 한다(OEM 키 `,` `=` `[`는 VK 값이 문자와 달라, 표를
직접 만들면 레이아웃마다 틀린다). 그리고 `WM_CHAR`는 Ctrl·Alt가 눌린 동안 **무시한다** — 안 그러면 같은
키가 두 번 입력된다.

**UTF-16 서로게이트 쌍을 합친다.** BMP 밖 문자(이모지)는 `WM_CHAR`가 **두 번** 온다. 합치지 않으면 중립
`charKeyFromCodepoint`가 lone surrogate를 거부해 글자가 조용히 사라진다.

**`WM_SYSKEYDOWN`을 `DefWindowProcW`에 넘기지 않는다**(Alt+F4는 예외). 넘기면 Alt 조합이 시스템 메뉴를
열고 삼켜진다.

#### ⌘ 를 무엇에 매핑하는가 — 판정은 `controlByte`다

macOS의 `Cmd`가 maru 바인딩의 주 모디파이어인데 Windows엔 그 키가 없다. **`Ctrl`을 그대로 주면 셸 키를
빼앗는다** — 실측: plain `Cmd+<글자>` 바인딩이 쓰는 12글자(`[ ] A D E F G K O S T W`)가 전부 C0 제어
바이트를 갖는 문자라, `Ctrl+D`(EOF)·`Ctrl+W`(단어 삭제)·`Ctrl+A`(줄 시작)를 잃는다. 그 열 개 없이는 셸에서
일을 할 수 없다.

그래서 규칙을 **중립 `terminal.input.controlByte`로 판정한다** — "셸이 이 문자를 Ctrl로 가져가는가"의
단일 출처이고, 우리가 목록을 만들지 않는다.

| Windows 물리 조합 | 중립 모디파이어 | 예 |
|---|---|---|
| `Ctrl+<c>`, `controlByte` 실패 | `command` | `Ctrl+,`(설정)·`Ctrl+0`~`9`(탭)·`Ctrl+=`(폰트) |
| `Ctrl+<c>`, `controlByte` 성공 | `control` | **셸로** — `Ctrl+C`·`Ctrl+D`·`Ctrl+W` |
| `Ctrl+Shift+<c>`, c가 밀려온 글자 | `command`(plain) | `Ctrl+Shift+T`=새 탭 — Windows Terminal 철자 |
| `Ctrl+Shift+<c>`, 그 밖 | `command`+`shift` | `Ctrl+Shift+P`=커맨드 팔레트 — VS Code 철자 |
| `Ctrl+Alt+<c>` | `command`+`shift` | 밀린 `Cmd+Shift+<c>`(새 워크스페이스·수직분할) |
| `Alt+<c>` | `option` | meta — `Alt+b`가 ESC b(단어 왼쪽) |
| 문자가 아닌 키 + `Ctrl` | `control` | `Ctrl+←`는 셸이 쓴다(`CSI 1;5D`) |

**어느 쪽에 `Ctrl+Shift`를 주는지는 Windows 관례를 따랐다**(사용자 결정). plain `Cmd+X`가 가져가므로
`Ctrl+Shift+T`가 새 탭, `Ctrl+Shift+D`가 분할이 되어 Windows Terminal과 **같은 철자가 같은 동작**을 한다.
밀린 `Cmd+Shift+X` 여섯(`[ ] D E G T`)은 `Ctrl+Alt+X`로 간다.

**밀려온 글자 집합을 손으로 박지 않는다.** `config.keybinding.default_app_bindings`·
`default_terminal_bindings`를 **comptime에 훑어** 유도한다 — 손으로 적은 목록은 바인딩이 늘거나 줄 때
반드시 어긋나고, 어긋나도 컴파일은 된다. 테스트가 그 유도를 검증한다("유도된 문자는 정의상 셸 충돌
문자여야 한다", "비어 있으면 유도가 깨진 것이다").

핵심 단언은 이것이다 — `Ctrl+<셸 문자>`는 반드시 `control`이어야 한다:

```zig
for ("acdefgkostw[]") |ch| {
    const m = translateModifiers(true, false, false, .{ .char = ch });
    try testing.expect(m.control);
    try testing.expect(!m.command);
}
```

`command`가 되면 앱 바인딩이 가로채 셸이 SIGINT·EOF·단어 삭제를 못 받는다.

**실기 캡처** (Windows 10 Pro 19045, `maru win32-terminal-smoke`):

![W7.4a 실제 타이핑 — 입력이 셸로 가고 출력이 돌아온다](images/w7-4a-keyboard.png)

`echo WIN-KEY-OK 한글도`를 타이핑하자 셸이 실행해 출력이 화면에 돌아왔다. `keys_to_shell=46`·
`bytes_to_shell=52`(한글이 3바이트라 키보다 바이트가 많다)·`shell_ended=false`(셸이 살아 있다)·
`fallback_glyphs`가 0에서 3678로(한글 폴백 경로가 실제로 돌았다).

**중복 입력이 없다는 것은 통제 측정으로 확인했다** — 3글자를 보내면 `keys_to_shell=3`이다. 그 측정을 하기
전에 두 번 헛짚었다: `MainWindowHandle`이 아직 0일 때 `PostMessage`가 조용히 실패했고(반환값을 버렸다),
터미널 스모크가 fixture 각본(`exit`으로 끝난다)을 보내 **셸이 죽은 뒤** 키가 도착했다. 후자는 스모크에서
각본을 없애 고쳤다 — 터미널 스모크는 사람이 타이핑하는 자리이고, 각본으로 끝내는 검증은
`win32-frame-smoke`(§2f)가 한다.

### 2i. IME 조합 미리보기 (W7.4c 결정, 실측 2026-08-18)

중립 계약이 이미 다 갖고 있다 — `surface.setPreeditLocked(bytes)`를 넣으면 `renderSnapshot()`이 조합
미리보기를 화면에 합성한다(`terminal/preedit.zig`의 `Overlay.compose`). 그래서 Windows가 미리보기 렌더를
따로 만들지 않는다.

**조합 미리보기만 가로채고 확정 문자는 `DefWindowProcW`에 맡긴다.** `WM_IME_COMPOSITION`에서 `GCS_COMPSTR`
(조합 중)만 읽고, `GCS_RESULTSTR`(확정)은 기본 처리가 `WM_CHAR`로 만들게 둔다 — 그러면 §2h의 문자 경로
하나가 확정을 받고, 확정 처리가 두 곳에 생기지 않는다.

**조합이 비어도 이벤트를 낸다.** 사용자가 조합을 지우면(`한`→`하`→빈 값) 화면의 미리보기가 사라져야 하고,
그것을 알리는 신호가 그 이벤트뿐이다.

**바이트를 이벤트에 싣지 않는다.** `preedit_changed`는 payload가 없고 호출자가 `window.preeditText()`를
읽는다. 조합은 **가장 최근 상태만** 뜻이 있고(중간 단계를 큐에 쌓아 재생할 이유가 없다), 슬라이스를 실으면
다음 조합이 그 버퍼를 덮어 이미 넘긴 이벤트가 무효화된다.

**변환·잘림 규칙은 순수 함수가 소유한다**(`win32_keys.compositionTextFromUtf16`). `ImmGetCompositionStringW`가
**문자 수가 아니라 바이트 수**를 돌려주는 것(UTF-16이라 2배)과 서로게이트 처리, 그리고 버퍼가 모자랄 때의
잘림이 실제로 틀리기 쉬운 자리다. 그래서 OS 호출만 남기고 규칙을 갈라 **모든 타깃에서** 테스트한다:

- `std.unicode.utf16LeToUtf8`을 그대로 쓰지 않는다 — 버퍼가 모자라면 **오류**를 내는데, 조합 문자열은
  사용자가 계속 늘릴 수 있어 **잘라서라도 보여 주는** 편이 맞다(미리보기가 짧아질 뿐 확정 문자는 온전하다).
  오류로 접으면 긴 조합에서 미리보기가 통째로 사라진다.
- 반쪽 글자를 쓰지 않는다 — 한 글자를 다 담을 수 없으면 그 글자를 안 쓴다(쓰면 UTF-8이 깨져 아래 계층이
  거부한다).
- 짝 없는 서로게이트는 **버린다** — 중립 계약이 lone surrogate를 거부하므로 흘려보내면 뒤에서 조용히 사라진다.

**실기 검증의 한계와 그 이유.** IME 메시지 배관은 확인됐다 — 합성 `WM_IME_COMPOSITION` 4개를 보내면
`preedit_updates=4`·`failures=0`이고, 아무것도 안 보낸 대조군은 `0/0`이다. 그러나 **실제 한글 조합을
프로그램적으로 만들 수 없다**: 이 창은 포그라운드를 잡지 못하고(Windows가 비-포그라운드 프로세스의 포커스
탈취를 막는다 — 실측으로 확인했다), 합성 메시지는 **실제 IME 컨텍스트**를 읽으므로 조합이 없으면 빈 값이다.
그래서 조합 문자열 읽기(`ImmGetCompositionStringW` 호출 자체)는 **사람이 창에 직접 타이핑해야** 검증된다.

**후보창 위치는 §2k(W7.4d)에서 붙었다.** 셀 좌표를 IME에 넘기는 일이라 픽셀↔셀 변환과 같은 계층이었다.

### 2j. 클립보드 — 플랫폼이 소유한다 (W7.4b 결정, 실측 2026-08-18)

**중립 레이어에 복사·붙여넣기 `Action`이 없다.** `config/action.zig`가 그 경계를 이미 그어 뒀다 —
"clipboard 쓰기(copy)는 NSPasteboard(OS) 소유라 Action이 아니다 — 경계: Zig는 selection, Swift는
clipboard". Windows도 같은 선을 지킨다: `win32_clipboard.zig`는 OS 클립보드만 알고, **무엇을** 복사할지
(선택 영역)는 중립 코어가 안다. macOS에서 Swift가 하던 자리를 Windows에서는 이 파일이 맡는다.

**중립 계층이 요청하는 것은 OSC 52다.** 셸이 `OSC 52`로 클립보드 읽기·쓰기를 요청하면 코어가 그것을
pending으로 들고 있고(`pendingClipboardWrite`·`clipboardReadPending`), 플랫폼이 정책을 확인한 뒤 배수한다.
코어가 OS를 직접 만지지 않는 것이 그 설계다.

**읽기 정책은 `osc52.read`이고 기본값이 `deny`다** — 원격/내부 프로그램의 로컬 클립보드 탈취를 막는
사용자 결정이다(`config/theme.zig`의 `Osc52Config`, 2026-06-20). 쓰기는 하드코딩 allow다. pending은
**정책과 무관하게 소비한다** — 안 그러면 매 tick 재트리거된다(macOS와 같은 규율).

**읽기 응답은 아직 안 만든다 — 그 인코더가 중립이 아니기 때문이다.** `ESC ] 52 ; <Pc> ; <base64> ST`를
만드는 `formatOsc52ReadResponse`가 **macOS `app_session.zig` 안에** 있다. Windows가 `allow`를 지원하려면
그것을 중립으로 들어올려야 하는데(`terminal/input_report.zig`의 `encodePasteWith` 옆이 제자리다), 그것은
이 슬라이스 밖의 설계 결정이라 사용자에게 보고하고 정한다. 기본값이 `deny`라 지금 기능 손실은 없다.

**`CF_UNICODETEXT` 하나만 쓴다.** `CF_TEXT`는 ANSI 코드페이지이고 이 기계의 ACP가 949라, UTF-8 바이트를
그대로 넣으면 비영문이 깨진다(§5.3에서 `_access`가 같은 함정을 밟았다). `CF_UNICODETEXT`는 UTF-16이고,
Windows가 필요하면 다른 형식으로 자동 합성해 준다.

**줄바꿈 규칙이 방향마다 다르다 — 왕복이 항등이 아니다.** 그것이 맞는 동작이다:

- **쓸 때 `\n`→`\r\n`.** Windows 클립보드 관례가 CRLF이고, `\n`만 넣으면 메모장 등에서 한 줄로 붙는다.
  이미 CRLF인 것을 두 번 바꾸지 않고(`\r\r\n`이 되면 빈 줄이 생긴다), 홀로 있는 CR에는 LF를 붙인다.
- **읽을 때 `\r\n`→`\r`.** 터미널에 CRLF를 그대로 보내면 셸이 **두 줄을 실행한 것으로** 본다 — 붙여넣기가
  의도치 않게 명령을 실행하는 고전적 사고다. 콘솔 입력의 Enter는 CR 하나다. 홀로 있는 LF도 CR로 바꾼다.

**성공한 `SetClipboardData` 뒤에 `GlobalFree`를 부르지 않는다.** 성공하면 그 메모리의 소유권이 시스템으로
넘어간다 — 해제하면 다른 앱이 붙여넣을 때 해제된 메모리를 읽는다. 실패했으면 소유권이 아직 우리에게 있으니
**우리가** 해제한다. 두 갈래가 모두 필요하다.

**길이는 NUL까지 세서 잰다.** `GlobalSize`는 할당 크기라 실제 문자열보다 클 수 있고, 그대로 쓰면 뒤쪽
쓰레기가 붙는다. `CF_UNICODETEXT`는 NUL 종단이 규약이다. 종단이 없는 잘못된 데이터에서 무한히 읽지 않도록
상한(8Mi 유닛)을 두되, **거기 닿으면 잘라서 주지 않고 `Unterminated`로 실패한다** — 명령의 앞부분만 셸에
붙는 것이 붙여넣기를 거절하는 것보다 위험하다(아래 `InvalidUtf16`과 같은 판단이다).

**깨진 UTF-16을 `OutOfMemory`로 부르지 않는다.** 다른 앱이 UTF-16을 쌍 중간에서 자르면 짝 없는
서로게이트가 실제로 온다. 그것을 메모리 부족이라고 보고하면 진단이 원인을 숨긴다(대조군에서 형식 문제가
`OutOfMemory` 세 개로 보였다). `InvalidUtf16`으로 올리고, **U+FFFD로 갈음하지 않는다** — 셸 명령줄에 깨진
문자를 절반만 밀어 넣는 것이 붙여넣기를 거절하는 것보다 위험하다.

**락 안에서 OS를 부르지 않는다.** 클립보드 호출은 다른 프로세스를 기다릴 수 있다(소유자가 지연 렌더링을
하면 블록된다). 그 사이 코어 락을 잡고 있으면 PTY 리더가 막힌다. pending 바이트를 락 안에서 복사해 두고,
OS 호출은 락 밖에서 한다.

**raw 클립보드 바이트를 셸에 보내지 않는다 — `encodePasteWith`를 반드시 거친다.** 중립 코어가 붙여넣기
규칙을 이미 갖고 있다: bracketed paste(DECSET 2004) 래핑, 개행 정규화, 그리고 **본문의 ESC·제어 바이트를
공백으로 치환**하는 것이다. 마지막 것이 보안 규칙이다 — 클립보드에 `\x1b[201~`이 들어 있으면 래핑 괄호를
일찍 닫고 뒤따르는 `\r` 종료 바이트가 "타이핑"으로 **실행된다**. macOS `term.submitPaste`와 같은 순서로
부른다: 판정과 `bracketedPasteEnabled()`만 락 안에서 읽고, 인코딩(할당·복사)은 락 밖에서 한다.

**보호 게이트를 통과하지 못하면 붙여넣지 않는다.** `pasteNeedsConfirmation`이 참이면 macOS는 확인 모달을
띄우는데 Windows엔 chrome이 아직 없다(W8). **모달이 없다고 보호를 건너뛰면 위험한 붙여넣기가 조용히
실행되므로**, 거절하고 `pastes_blocked`로 센다. 지금 스모크는 config 파일을 읽지 않아 스키마 기본값
(`paste_protection=true`, `bracketed_paste_is_safe=true`)을 쓴다 — 사용자 config 배선은 W7.5다.

**붙여넣기 화음은 두 개를 받는다** — `Ctrl+Shift+V`(Windows Terminal 관례)와 `Shift+Insert`(고전 관례).
평범한 `Ctrl+V`와 `Ctrl+C`는 **가로채지 않는다**: `Ctrl+C`는 SIGINT여야 하고, `Ctrl+V`는 셸이 쓴다(§2h의
`shellTakesControl`이 판정하는 것과 같은 이유).

**실측과 그 한계.** `win32-clipboard-smoke`가 창 없이 OS 왕복을 잰다 — 5개 경우(ascii·한글·이모지·개행·
이미 CRLF) 전부 통과, 300 KiB가 정확히 왕복(`big_roundtrip=307200`). 외부 작성자(.NET `Set-Clipboard`)가
넣은 값도 정확히 읽는다(한글 28바이트, CRLF→CR 13바이트). OSC 52 쓰기는 셸이 요청하게 만들어 실제 Windows
클립보드까지 확인했다 — 사전값 `SENTINEL-BEFORE`가 `CLIP-OSC-OK-한글`로 바뀌고 `clipboard_errors=0`이다.

두 가지는 이 스모크가 **판정하지 못한다**:

- **NUL 종단 규칙.** 우리가 쓰고 우리가 읽으면 `GlobalAlloc`이 요청한 크기를 정확히 돌려줘서 `GlobalSize`로
  길이를 재도 답이 같다 — 대조군으로 확인했다(바꿔도 5/5 통과). 그 규칙은 다른 앱이 패딩된 할당에 넣었을
  때만 의미가 있어, 외부 작성자 모드(`win32-clipboard-smoke <기대값>`)가 그 자리를 대신 지킨다.
- **붙여넣기 규칙은 화음 없이 잰다.** `win32-clipboard-smoke --paste-encode`가 지금 클립보드에 있는 것을
  `encodePasteWith`에 태워 본다. 악의적 클립보드(`safe\x1b[201~rm -rf ~\x1b[200~`, 24바이트)를 넣으면
  `wrapped=true`·`body_has_esc=false`로 나온다 — ESC가 공백으로 치환돼 인젝션이 죽었고, 바이트 수가
  24로 그대로인 것이 **제거가 아니라 치환**임을 보여 준다. 보호 게이트도 같이 잰다: 평범한 여러 줄은
  bracketed면 `needs=false`(래핑이 안전하게 만든다)인데, 인젝션이 들어 있으면 bracketed여도 `needs=true`다.
- **붙여넣기 화음의 실기 경로.** 합성 메시지로는 모디파이어를 실을 수 없다 — `PostMessageW`가 스레드 키
  상태 테이블을 갱신하지 않아 `GetKeyState(VK_SHIFT)`가 눌림을 못 본다(실측: `Shift+Insert`를 보내면
  평범한 Insert로 `\x1b[2~` 4바이트가 셸에 간다). 화음 판정은 순수 함수(`isPasteChord`)로 테스트하고,
  읽기 경로는 외부 작성자 모드로 따로 잰다. 둘을 잇는 한 줄은 사람이 창에 직접 눌러야 검증된다(§2i의
  실제 한글 조합과 같은 한계, 같은 이유).

**계수는 성공만 센다.** `osc52_writes`·`pastes`는 OS 호출과 셸 전송이 **실제로 성공했을 때만** 오른다.
실패를 세지 않으면 `osc52_writes=1`이 실패한 쓰기를 성공처럼 보고하고, 붙여넣기 전송이 실패했는데
`pastes`가 오르면 화면에 아무것도 안 붙었는데 성공으로 읽힌다. pending 바이트 복사(dupe)가 실패했을
때도 `clipboard_errors`를 올린다 — 안 그러면 요청이 **아무 흔적 없이** 사라진다(코어에서 이미 비운
뒤다). 이 이식이 §2c 이후로 계속 지켜 온 규율과 같은 것이다.

**클립보드 경합에 재시도를 넣지 않았다 — 재현되지 않는다.** `OpenClipboard`가 다른 프로세스에 밀려
실패할 수 있다는 것이 통념이라 재 봤는데, 다른 프로세스가 `OpenClipboard(NULL)`로 실제로 잡은 상태
(`OpenClipboard=True` 확인)에서도 우리 쓰기가 5/5 성공했다. 재현되지 않는 문제에 재시도 루프를 넣으면
검증되지 않은 코드가 남으므로 넣지 않고 여기 적어 둔다.

**복사(선택 영역 → 클립보드)는 §2k에서 붙었다.** 무엇을 복사할지가 선택 영역이라 마우스와 같은 계층이었다.

### 2k. 마우스 — 선택·스크롤·리포팅 (W7.4d 결정)

**중립 명령이 이미 다 있다.** `session/core_command.zig`가 `select_start`·`select_extend`·
`select_extend_or_collapse`·`select_word`·`select_line`·`select_clear`·`scroll`·`scroll_and_extend`·
`report_mouse`를 갖고 있고, **PTY 리더 스레드가 락 아래 원자적으로 적용한다**. 그래서 Windows가 하는 일은
Win32 메시지를 그 명령으로 **번역하는 것뿐**이고, 메인 스레드는 코어를 만지지 않는다.

이것이 §2h·§2i·§2j와 같은 결론이다 — 중립 계약은 이미 서 있고 플랫폼은 어댑터다.

**규칙을 새로 만들지 않는다 — macOS가 쓰는 관례를 그대로 읽어 왔다.** 아래 표의 근거는 전부
`platform/macos/app_session.zig`의 기존 판정이다. 마우스 관례를 두 플랫폼이 다르게 가지면 같은 코어가
다르게 반응한다.

| Win32 메시지 | 중립 `kind` | 명령 |
|---|---|---|
| `WM_LBUTTONDOWN` | 1 (down) | `select_start{row, col, block}` |
| `WM_MOUSEMOVE`(버튼 눌림) | 2 (drag) | `select_extend{row, col}` |
| `WM_LBUTTONUP` | 3 (up) | `select_extend_or_collapse{row, col}` |
| `WM_LBUTTONDBLCLK` | 4 | `select_word{row, col, separators}` |
| 같은 자리 3연타 | 5 | `select_line{row}` |
| `WM_MOUSEWHEEL` | — | `scroll{lines}` 또는 alt 화면이면 화살표 키 |

**모디파이어 비트는 중립 규약을 따른다** — 4=shift, 8=meta(alt), 16=ctrl, 32=command.

**⑴ shift·alt가 마우스 리포팅을 누른다.** 셸이 마우스를 잡고 있어도(`mouse_tracking != .none`) shift나
alt를 누르면 리포트하지 않고 **로컬 선택**을 한다. macOS의 판정이 그대로다:

```zig
if ((mods & 4) != 0 or (mods & 8) != 0) return; // shift·option은 셀렉션 override — 리포트 안 함
```

TUI가 마우스를 다 먹으면 사용자가 화면의 글자를 복사할 방법이 없어진다 — 그 탈출구다.

**⑵ alt는 동시에 블록 선택이다.** `select_start{.block = (mods & 8) != 0}`. 리포팅을 누르는 것과 같은 키가
사각 선택을 켠다.

**⑶ command(32) 비트를 리포트에서 마스킹한다.** `reportMouse`의 `cb = button + mods + motion`에서 32가
**SGR motion 비트와 겹친다** — 그대로 실으면 press가 motion으로 오인되거나 `cb`가 부풀어 리포트가 오염된다
(macOS가 회귀 가드로 막아 둔 자리다). Windows엔 command 키가 없어 지금은 32가 설 일이 없지만, §2h가
`Ctrl`을 `command`로 번역하므로 **마우스 경로에도 같은 위험이 있다** — 마스킹을 그대로 가져온다.

**⑷ 이동 리포트는 셀이 바뀔 때만 보낸다 — 드래그도 마찬가지다.** 버튼 없는 이동(hover)은 `any`
(DECSET 1003)일 때만, 드래그 중 이동은 `button`(1002)·`any`일 때만 받는다. 그리고 **어느 쪽이든 같은 셀로의
반복은 버린다** — `WM_MOUSEMOVE`는 픽셀마다 오는데 셀은 안 바뀐다. 드래그를 예외로 두면 창을 가로질러
끄는 동안 같은 리포트가 PTY에 쏟아진다(실측: 같은 셀 근처에서 이동 9번에 리포트 11 → 4).

**휠 좌표만 화면 기준으로 온다.** 다른 마우스 메시지는 클라이언트 기준인데 `WM_MOUSEWHEEL`만 화면
기준이다 — 창 쪽에서 `ScreenToClient`로 바꿔 **같은 규약으로** 올린다. 좌표를 버리고 (0,0)을 싣는 것은
답이 아니다: xterm 규약에서 휠 리포트도 셀 좌표를 싣고 앱이 그것으로 **어느 pane을 굴릴지** 정한다
(실측 대조군: 변환을 끄면 클라이언트 (55,105)가 셀 5,5 대신 8,10으로 — 창 원점만큼 밀린다).

**격자는 스왑체인이 아니라 코어에게 묻는다.** 픽셀 크기에서 유도하면 리사이즈 도중 코어가 아직 옛
크기일 때 **없는 셀로 clamp**된다. 트래킹 모드와 함께 한 번의 락에서 `core.size`를 읽는다.

**캡처를 뺏기면 드래그만 끝내고 선택은 건드리지 않는다.** `WM_CAPTURECHANGED`(Alt+Tab 등)에는 **버튼을
뗀 좌표가 없다.** 그것을 `left_up`으로 올리면 좌표 0,0이 실려 `select_extend_or_collapse{0,0}`이 되고
**선택이 좌상단까지 끌려간다** — 실측 대조군에서 짧은 8바이트 선택이 **381바이트**(화면 열 줄)로 불었다.
그래서 좌표 없는 `capture_lost`를 따로 둔다. 우리가 `ReleaseCapture`로 놓는 경우는 `capturing` 표시로
갈라 **up이 두 번 올라가지 않게** 한다(실측: 드래그 하나에 이벤트가 11이 아니라 12였다).

**⑸ alt 화면 + `alternate_scroll`(DECSET 1007)이면 휠이 화살표 키가 된다.** 그리고 그때 **선택을 해제한다**
— 프로그램이 화면을 다시 그리므로 남은 선택은 좌표가 어긋난 유령이다. 화살표는 **한 버퍼에 묶어** 보낸다:
줄마다 쓰면 빠른 플릭에서 PTY 버퍼가 차 나머지가 드랍된다.

**픽셀→셀은 격자 안으로 clamp한다.** 드래그 중 포인터가 창 밖으로 나가도 선택이 끊기면 안 되므로
(`SetCapture`로 창 밖 좌표가 계속 온다) 음수·초과 좌표를 가장자리 셀로 접는다. 순수 함수라 모든 타깃에서
테스트한다.

**휠 눈금 수를 OS에 묻되 규칙은 순수 함수가 갖는다.** `WM_MOUSEWHEEL`은 `WHEEL_DELTA`(120)의 배수를
주고 정밀 터치패드는 그보다 작은 값을 보낸다 — 나머지를 누적하지 않으면 **작은 스크롤이 통째로 버려진다**.
한 눈금이 몇 줄인지는 `SystemParametersInfoW(SPI_GETWHEELSCROLLLINES)`가 사용자 설정으로 답하고, 그 값과
누적기는 순수 함수의 **인자**다(OS-as-parameter — §2h·§2i와 같은 규율).

**눈금과 줄 수는 다른 것이다 — 섞으면 TUI가 배수만큼 튄다.** 마우스 리포팅은 xterm 규약상 **눈금당 한 번**
이고, `SPI_GETWHEELSCROLLLINES`는 **로컬 스크롤백**이 한 눈금에 몇 줄을 갈지 정하는 값이다. 누적기가 줄 수를
돌려주게 만들면 리포팅 쪽이 그 배수로 부푼다 — 실측 대조군에서 **한 눈금에 리포트 10건**이 큐에 들어갔다
(이 기계 설정이 10이다). 그러면 vim에서 한 번 굴릴 때 열 칸이 지나간다. 그래서 `feed`는 **눈금**을 돌려주고,
줄 수가 필요한 자리(로컬 스크롤·alt 화면 화살표)만 `linesForNotches`로 곱한다.

그리고 그 차이를 **계수가 구분할 수 있어야 한다.** 이벤트마다 1씩 올리는 `mouse_reports`로는 안쪽 루프가
한 번 돌든 열 번 돌든 같은 값이라, 큐에 실제로 들어간 수(`report_commands`)를 따로 센다 — 이 이식이 계속
경계해 온 "구분 못 하는 계수"다.

**더블·트리플 판정도 순수 함수다.** `GetDoubleClickTime()`(사용자 설정)과 `SM_CXDOUBLECLK` 슬롭을 인자로
받아 시간·거리로 가른다. 트리플 뒤에는 카운터를 되돌린다 — 안 하면 네 번째 클릭이 4연타가 되어 무엇도
아니게 된다.

**복사가 여기서 붙는다.** §2j가 남겨 둔 `isCopyChord`에 드디어 호출자가 생긴다 — `extractSelection`으로
선택 영역을 UTF-8로 꺼내 `win32_clipboard.write`에 넘긴다. 경계는 §2j 그대로다: **무엇을 복사할지는 중립
코어가, 클립보드는 플랫폼이** 안다.

**IME 후보창 위치도 여기다.** §2i가 미뤄 둔 자리다 — 커서 셀을 픽셀로 바꿔 IME에 주는 일이라
픽셀↔셀 변환과 같은 계층이다.

**`ImmSetCompositionWindow`와 `ImmSetCandidateWindow`를 둘 다 부른다.** IME마다 무엇을 보는지가 다르다 —
어떤 IME는 조합창 위치를 기준으로 후보를 배치하고, 어떤 IME는 `CANDIDATEFORM`을 직접 읽는다. 하나만
부르면 그쪽을 안 보는 IME에서 후보창이 **창 좌상단에 남는다**. 조합창은 **글자 자리**에(거기 조합 중인
글자가 그려진다), 후보창은 `CFS_EXCLUDE`로 **그 셀을 가리지 말라고** 준다 — 후보 목록이 지금 치는 글자를
덮으면 무엇을 고르는지 안 보인다.

**조합이 시작될 때가 아니라 커서가 움직일 때마다 갱신한다.** IME는 조합을 시작하는 **그 순간의** 위치를
쓰므로, 그 전에 최신값이 들어 있어야 한다. 조합 시작 이벤트에서 세팅하면 이미 늦다. 대신 **셀이 바뀔
때만** 부른다 — 매 프레임 IMM 컨텍스트를 여는 비용을 뺀다(실측: 600프레임에 13회).

`CANDIDATEFORM`(32B)·`COMPOSITIONFORM`(28B)은 크기와 오프셋을 comptime에 못 박는다 — §2c의 COM 규약과
같은 이유다. 어긋나도 **컴파일은 되고** 런타임에 후보창이 엉뚱한 자리에 뜬다(조용히 틀린다).

#### 마우스 리포팅이 안 오는 이유는 **인박스 conhost가 낡아서**다 (실측 2026-08-18)

**셸이 `DECSET 1000`을 켜도 우리 코어는 그것을 못 본다.** 측정이 그것을 정확히 갈랐다 — 같은 방법으로
보낸 세 개 중 **`1007`(alternate scroll)만 도착하고 `1000`(마우스 트래킹)·`1006`(SGR 형식)은 사라졌다**:

```text
core_modes: mouse_tracking=none mouse_format=x10 alt_active=false alternate_scroll=true
```

전달 경로가 멀쩡하다는 것을 `1007`이 증명하므로, 남은 설명은 하나다: **ConPTY가 마우스 모드를 삼킨다.**
이것은 알려진 한계이고 설계상 그렇다 — ConPTY는 `ReadConsoleInput`으로 `MOUSE_EVENT`를 받는 고전 콘솔
앱도 호스팅해야 해서 마우스를 **그냥 통과시킬 수 없고 번역해야** 한다. 그래서 모드를 자기가 먹는다
([microsoft/terminal#376](https://github.com/microsoft/terminal/issues/376), Terminal v1.9에서 ConPTY
쪽 마우스 지원 자체는 들어갔다).

**그런데 트리거는 DECSET이 아니다.** ConPTY가 터미널에 마우스 모드를 알려 주는 기능은 이미 있다 —
[microsoft/terminal#9970](https://github.com/microsoft/terminal/pull/9970)이 그것이고, 조건은 클라이언트가
**`SetConsoleMode(stdin, ENABLE_MOUSE_INPUT)`**을 부르는 것이다(VT를 stdout에 쓰는 것이 아니다). 그러면
ConPTY가 터미널에 `CSI ? 1002 h` + `CSI ? 1006 h`를 보낸다. 2021년 5월에 머지돼 Windows Terminal v1.9에
들어갔다.

**그 트리거로도 이 기계에서는 안 온다 — conhost 버전 때문이다.** 스크립트로 `ENABLE_MOUSE_INPUT`을
실제로 켜고(반환 `after=0x98 ok=True`) 측정했는데 `mouse_tracking=none` 그대로였다. 이 기계의 인박스
conhost는 **10.0.19041.4522**(Windows 10 19045)로, #9970(2021)보다 오래된 코드다.

**우리 파서 탓이 아니다.** `terminal/parser.zig`가 `1000`·`1002`·`1003`·`1006`을 모두 처리한다 — ConPTY가
보냈다면 받았을 것이다.

**`PSEUDOCONSOLE_PASSTHROUGH_MODE`(0x8)로도 안 된다.** flags를 `0`→`0x8`로 바꿔 같은 측정을 돌렸는데
그대로였다(실험 후 되돌렸다). 그 플래그는 §4의 EOF·쓰기 의미론 실측을 뒤흔들 수 있는 PTY 전역 변경이라
어차피 함부로 켤 자리가 아니다.

##### 해결책은 있다 — **새 ConPTY를 함께 배포한다**

`CreatePseudoConsole`을 kernel32에서 부르면 **`%SystemRoot%\System32\conhost.exe`**가 pty 호스트가 된다.
그래서 OS가 낡으면 방법이 없어 보이지만, Microsoft가 그 자리를 위해 **재배포 가능한 쌍**을 낸다 —
`Microsoft.Windows.Console.ConPTY` 패키지의 **`conpty.dll` + `OpenConsole.exe`**(MIT). 인박스 대신
`conpty.dll!CreatePseudoConsole`을 부르면 원하는 버전을 **핀으로 고정**할 수 있다. Windows Terminal이
자기 `OpenConsole.exe`를 들고 다니는 이유가 그것이고, WezTerm도 같은 쌍을 번들한다
([wezterm#7774](https://github.com/wezterm/wezterm/issues/7774)).

**둘을 반드시 쌍으로 올려야 한다** — `OpenConsole.exe`만 바꾸면 안 맞는다. 그리고 알려진 함정 하나:
`conpty.dll` 경로가 길면 `CreatePseudoConsole`이 죽는다
([#16860](https://github.com/microsoft/terminal/issues/16860)).

**Microsoft가 그렇게 하라고 말한다.** 인박스 conhost에 개별 수정을 백포트하는 대신 NuGet으로 배포하겠다는
것이 공식 방침이다([discussion #17608](https://github.com/microsoft/terminal/discussions/17608)) —
"terminal emulator authors ... to lock to specific versions and fully vet compatibility with them".
한계도 같이 적혀 있다: 사용자가 `cmd.exe`·`wsl.exe`를 **직접** 띄우면 그쪽은 여전히 시스템 conhost다.

**그리고 실제로 다들 그렇게 한다** — 이 개발 기계에서 확인한 것만:

| 제품 | 번들 위치 | 버전 |
|---|---|---|
| Warp | `Warp\conpty.dll` + `Warp\x64\OpenConsole.exe` | — |
| Zed | `Zed\conpty.dll` + `Zed\{arm64,x64}\OpenConsole.exe` | 1.22.250314001 |
| Android Studio(pty4j) | `lib\pty4j\win\x86-64\` 에 쌍 | — |

WezTerm도 `assets/windows/conhost`에 쌍을 둔다([wezterm#7774](https://github.com/wezterm/wezterm/issues/7774)).
`conpty.dll`을 루트에, `OpenConsole.exe`를 아키텍처 하위 폴더에 두는 배치가 공통이다.

##### 실측: 새 ConPTY 를 물리면 **고쳐진다** (2026-08-18)

권고를 믿지 않고 재 봤다. Zed 가 번들한 `conpty.dll`(1.22.250314001)을 동적 로드해
`CreatePseudoConsole`만 그쪽 것으로 바꾸고, 나머지는 전부 그대로 둔 A/B다:

| | `mouse_tracking` | `mouse_format` | 클릭이 간 곳 |
|---|---|---|---|
| 인박스 conhost 10.0.19041.4522 | `none` | `x10` | 로컬 선택(`reports=0 selections=1`) |
| 번들 `conpty.dll` 1.22.250314001 | **`any`** | **`sgr`** | **셸 리포트**(`reports=2 selections=0`) |

ConPTY 가 `CSI?1003h`(any-event — #9970 리뷰에서 1002 대신 이것을 쓰기로 한 그대로)와 `CSI?1006h`를
보냈고, **우리 코드는 한 줄도 안 바뀌었는데 라우팅이 바뀌었다.** §2k 의 리포팅 경로가 옳다는 것과, 남은
것이 배포 결정뿐이라는 것을 동시에 보인다.

##### 마지막 판정은 계수가 아니라 **반대편 앱이 받은 값**이다

우리 쪽 카운터는 "보냈다"만 말한다. 그래서 셸에서 `SetConsoleMode(ENABLE_MOUSE_INPUT)`을 켜고
`ReadConsoleInput`으로 **실제로 도착한 레코드**를 찍었다. 클라이언트 좌표 (66,105), 셀 11×21이므로
기대는 열 6·행 5다:

```text
MOUSE x=6 y=5  buttons=0x1         flags=0x0    ← 좌버튼 누름
MOUSE x=6 y=5  buttons=0x0         flags=0x0    ← 뗌
MOUSE x=0 y=0  buttons=0xFF800000  flags=0x4    ← MOUSE_WHEELED, 상위 워드 음수 = 아래로
```

셀이 정확하고 버튼·휠 방향이 맞는다. **vim·htop이 마우스를 받는다**는 뜻이고, 이 슬라이스에서 가장
강한 검증이다. (휠 레코드의 x·y가 0인 것은 ConPTY 의 변환이지 우리 계층이 아니다 — 우리는 셀을 실어
보냈다.)

**이것은 배포 결정이라 사용자에게 보고하고 정한다**(AGENTS.md 핵심 원칙) — 산출물에 Microsoft 바이너리
둘이 늘어난다. 넣는다면 모양은 정해져 있다: `conpty.dll`을 **동적 로드**해 있으면 쓰고 없으면 kernel32로
접는다(소스 빌드가 계속 돌아야 한다). §4의 spawn 절차·EOF 규약은 그대로다 — 같은 API의 새 구현이다.

**그때까지 리포팅 경로는 옳게 두되 잠들어 있다.** `report_mouse` 명령을 보내는 코드는 그대로 있고
`mouse_tracking != .none`에서만 깨어난다 — 지금 Windows에서는 그 조건이 안 서므로 마우스는 언제나 로컬
선택으로 간다(선택·스크롤은 늘 먹는다). 잃는 것은 vim·htop 같은 TUI의 마우스이고, **새 ConPTY를 얹으면
코드 변경 없이 켜진다**.

이 자리가 W7 전체에서 처음으로 **플랫폼 아래(PTY)가 중립 계약을 못 채운** 사례다 — §2h·§2i·§2j는 전부
"중립 계약은 이미 서 있고 플랫폼은 어댑터"였다.

### 2l. 사용자 config 를 실제로 읽는다 (W7.5 결정, 실측 2026-08-18)

W7.4a~W7.4d가 값을 **하드코딩**해 두고 "W7.5에서 진짜 설정에서 온다"고 적어 둔 자리 넷을 닫는다 —
`input.paste-protection`·`input.bracketed-paste-is-safe`·`input.right-click`·`input.word-separators`,
그리고 `osc52.read`와 키바인딩이다. 진입점은 `config.loader.loadDefault` 하나다.

**`Parsed`(arena)를 세션 내내 들고 있어야 한다.** 리졸버가 바인딩 슬라이스를, 코어가 문자열 값을 그
arena에서 **빌린다** — 먼저 해제하면 dangling이다. 이것이 `loadDefault`의 계약이고 macOS도 같다.

**검증에 실패하면 사용자 바인딩을 안 쓴다.** `KeyBindingResolver.validate()`가 중복·앱/터미널 충돌을
거부하면 빌트인으로 접고 그 사실을 알린다(`rejected=true`). 모호한 바인딩을 그대로 쓰면 **어떤 키가
어디로 갈지 매번 달라진다** — 조용히 하나를 고르는 것보다 접는 편이 낫다.

**"값이 도착했다"와 "동작이 바뀐다"는 다르다.** 스모크가 읽은 값을 찍되(`config_input`·`config_osc52_read`·
`config_bindings`), 판정은 **행동**으로 한다. 값만 찍으면 기본값과 같을 때 "읽었는데 기본값"과 "아예 안
읽었다"를 구분할 수 없다. 실측 A/B 둘:

| config | 우클릭 결과 |
|---|---|
| 없음(기본 `paste`) | `pastes=1 paste_bytes=21` |
| `input.right-click = menu` | `pastes=0`, `right_click_menus_todo=1` |

| config | 여러 줄 붙여넣기(개행 = 즉시 실행 트리거) |
|---|---|
| 없음(보호 켜짐) | `blocked=1 pastes=0` — "paste held: the content is risky" |
| `input.paste-protection = false` | `pastes=1 paste_bytes=17` |

두 번째가 **보안 설정이 실제로 게이트를 여닫는다**는 증거다. 값만 보고 넘어갔으면 못 봤을 자리다.

**바인딩도 개수가 아니라 발화로 잰다.** 모디파이어 없는 키(F5)를 골라 합성으로 눌렀다 — §2h의 한계
(합성 메시지에 모디파이어가 안 실린다)를 우회하는 자리다:

| config | F5 ×3 |
|---|---|
| 없음 | `keys_to_shell=3 bytes_to_shell=15` (F5 시퀀스가 셸로), `app_actions=0` |
| `keybind = f5 = new_tab` | `keys_to_shell=0`, **`app_actions=3`** |

**리졸버 조립은 `Parsed.keyBindingResolver()`가 소유한다** — 손으로 세 필드를 옮겨 담으면 바인딩 종류가
늘 때 그 자리만 빠진다(적대적 검증 4라운드가 잡았다: 같은 헬퍼가 이미 있는데 다시 조립하고 있었다).

`validate()`는 **불변식 확인이지 활성 폴백이 아니다.** 로더가 app·terminal·unbind를 같은 dedup 풀에서
만들어 chord가 구조적으로 충돌하지 않으므로(`loader.Parsed.terminal_bindings` doc) 지금 config 경로로는
안 밟힌다 — 그래도 부르는 이유는 그 불변식이 깨졌을 때 조용히 이상해지지 않게 하기 위해서고,
`rejected`가 0이 아니면 그것이 드러난다.

**잘못된 config에 죽지 않는다.** 범위 밖 `font.size`, 없는 enum 값, 모르는 키, 중복 바인딩을 한꺼번에
넣어도 `exit=0`·`diagnostics=5`이고 전부 기본값으로 접힌다.

**폰트도 config에서 온다 — config를 읽어 놓고 안 쓰던 자리였다.** 적대적 검증 1라운드가 잡았다:
래스터라이저를 여전히 `create(allocator, "", "", 18.0)`으로 만들고 있었다. `font.family`·`font.fallback`·
`font.size`를 넘기도록 고쳤고, **그래서 config 로드가 폰트 생성보다 앞에 온다.**

| config | 결과(이 기계) |
|---|---|
| 없음 | `font_family=Cascadia Mono` `cell_px=9x17` |
| `font.family = Consolas` + `font.size = 22` | `font_family=Consolas` `cell_px=13x26`, 격자 75×23 |

**"없음" 줄을 오해하면 안 된다 — 기본값은 빈 값이 아니다.** `config/theme.zig`가 `family = "JetBrains
Mono"`, `fallback = "Jetendard"`를 주고 `fontCandidates`는 **설정값을 맨 앞에** 놓는다. 그래서 config
파일이 없어도 JetBrains Mono를 먼저 찾고, 그 폰트가 이 기계에 없어서 티어의 Cascadia Mono로 내려간
것이다. "빈 값이라 티어가 골랐다"가 아니다 — JetBrains Mono가 설치된 기계에서는 그 줄이 달라진다.
`Jetendard`는 macOS 번들 한글 폰트라 Windows에서는 열리지 않고 폴백 사슬 앞에 무해하게 남는다.

**아직 안 배선한 것**(정직하게 적는다): 테마 색·팔레트·`max_scrollback` 같은 앱 수준 값은 이 스모크가
하드코딩한다. `shell.command`·`shell.windows-shell`도 소비자가 없다 — 스모크는
`resolveInteractiveShell()`(config를 안 읽는 진입점)로 셸을 고르므로, 정규화한 `shell.command`가
`CreateProcessW`까지 가지 않는다. `font.line-height`·`font.letter-spacing`도 §2e의 래스터라이저가
em 크기만 받아 소비자가 없다. 그것들의 소비자는 chrome·app 계층이라 W8과 함께 온다.
`dwrite-text-smoke`는 **일부러** 빈 이름을 넘긴다 — 티어가 실제로 고르는지 보는 스모크라 config가
끼면 그 판정이 흐려진다.


### 2m. ADE 표면 — 무엇이 이미 Windows 로 컴파일되고 무엇이 남았나 (W8 착수 실측, 2026-08-19)

**W8 을 "60k 줄 포팅" 으로 잡으면 틀린다.** 착수 전에 무엇이 실제로 플랫폼에 묶여 있는지 쟀고, 답이
계획을 크게 바꿨다.

| 층 | 어디 | Windows 상태 | 근거 |
|---|---|---|---|
| **chrome**(사이드바·탭·모달·팔레트·설정 GUI·파일 패널 뷰) | `src/chrome/` 77 파일 | **컴파일된다 — 그러나 게이트가 ADE 표면을 안 본다** | 아래 |
| **session**(파일 트리·에디터·git 명령·에이전트 관측) | `src/session/` | 같음 | 같음 |
| **파일 트리 읽기 백엔드** | `src/platform/macos/file_tree_backend.zig` | **안 된다** — `openat` 플래그 | 아래 |
| **파일 트리 변경 백엔드** | `src/platform/macos/file_tree_mutation_backend.zig` | **컴파일된다**(런타임 미검증) | 아래 |
| **git 백엔드** | `src/platform/macos/git_backend.zig` | **안 된다** — `std.c.pipe` 부터 | 아래 |
| **오케스트레이터** | `src/platform/macos/app_session.zig` (60,273 줄) | **모듈 자체가 macOS 전용** | `maru.zig` 에 없다 |

**백엔드 셋은 macOS 프레임워크를 하나도 안 쓴다.** `objc`·`Foundation`·`AppKit` 참조가 **0** 이다 —
순수 Zig + std 이고, 묶여 있는 것은 **POSIX 시스템 호출**뿐이다:

```text
file_tree_backend            14곳  fstatat·fstat·openat·fcntl (+ Stat·S·AT 상수)
file_tree_mutation_backend   12곳  renameat·fstatat·fstat
git_backend                  69곳  fork·execve·pipe·dup·environ·getcwd·nanosleep·open·close
```

`identityAt`·`identityOfFile` 은 이미 `if (comptime builtin.os.tag != .macos)` 갈래로
`std.Io.Dir.statFile`·`file.stat` 을 쓴다. 그래서 **변경 백엔드는 통과한다.** 읽기 백엔드가 걸리는
자리는 하나다 — `openValidatedFileTreeRow` 의 `std.posix.openat(…, .{ .ACCMODE = .RDONLY,
.NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)` 인데 Windows 에서 그 플래그 타입이
`void` 다(`error: type 'void' does not support struct initialization syntax`). git 백엔드는
`std.c.pipe(&pipe_fds)` 부터 걸린다(`*[2]c_int` vs `*[2]*anyopaque`).

### 2m.1 이 측정을 세 번 틀렸다 — 프로브를 먼저 검증한다

**세 번 다 "0 오류" 를 봤고, 세 번 다 공허했다.** 적대적 검증 5 회차가 그것을 잡았다.

| 프로브 | 결과 | 대조군(`std.c.fork()` 심기)이 잡았나 |
|---|---|---|
| `build-exe` + `comptime { refAllDecls(m) }` | 0 오류 | **못 잡음** — `refAllDecls` 는 **비재귀**라 최상위 이름만 닿는다 |
| `zig test --test-no-exec` (그 파일 자체 테스트) | 0 오류 | **못 잡음** — 테스트가 `openValidatedFileTreeRow` 를 안 부른다 |
| `zig test --test-no-exec` + **공개 표면을 `_ = &fn;` 로 명시 참조** | 오류 잡음 | **잡음** |

**그래서 규칙은 하나다 — 프로브에 고의로 깨지는 호출을 심어 그것이 잡히는 것을 본 뒤에만 그 프로브의
"0 오류" 를 믿는다.** `std.c.fork` 가 Windows 에서 `void` 라 호출이 **반드시** 컴파일 오류인 것이
이 대조군의 성질이다.

### 2m.3 파일 트리 백엔드 — 컴파일이 아니라 **세 자리**가 막고 있었다 (W8.1, 실측 2026-08-19)

"컴파일되는가" 만 봤을 때는 `openat` 하나로 보였다. 실제로 **돌려 보니** 막는 것이 셋이었고, 셋 다
성격이 다르다.

| # | 자리 | 증상 | 고친 것 |
|---|---|---|---|
| ⑴ | `openValidatedFileTreeRow` 의 `std.posix.openat` | Windows 에서 플래그 타입이 `void` — **컴파일 불가** | `openLeafNoFollow` 로 갈라, macOS 는 그대로 두고 그 외는 `Io.Dir.openFile(.follow_symlinks = false, .allow_directory = false)` |
| ⑵ | `openCanonicalDirectoryNoFollow` | `openDirAbsolute("/")` + `path[1..]` + `/` 로만 자르기 — Windows 에 그런 루트가 없고 `realPath` 는 native 를 준다. **`validateRootSnapshot` 이 늘 null** | `path_shape.rootPrefixLenFor(os_tag, …)`(신규·순수)로 루트 접두를 고르고 두 구분자로 자른다 |
| ⑶ | `validateRootSnapshotImpl` 의 `owned_path` | `realPath` 의 native 값을 그대로 들고 있어 중립 `/` 경로와의 비교가 어긋남. **정상 파일에도 null** | 입구 정규화(§5 규칙 1, 입구 Ⓑ = OS API) |

⑶ 이 특히 계약이 예고한 자리다 — §5 의 입구 Ⓑ("OS API")를 이 백엔드가 안 걸고 있었다.

> **적대적 검증이 ⑵ 를 고치다 낸 회귀를 잡았다.** 세그먼트를 `"/" ++ 역슬래시` 로 자르게 썼는데,
> **POSIX 에서 역슬래시는 파일 이름 글자**라 그런 이름이 든 디렉터리 하나가 두 칸으로 갈린다.
> W1.5 가 `pathWithin` 에서 낸 것과 **같은 부류를 또 낸 것**이다. 판정을
> `path_shape.separatorsFor(os_tag)` 하나로 모으고, "POSIX 에서 역슬래시 이름은 한 칸" 을 테스트가
> 못 박는다.
>
> **유출이 없다는 것도 따로 쟀다.** "링크로 바꿔치기하면 null" 만으로는 그 null 이 링크를 막아서인지
> 앞 단계에서 이미 걸려서인지 안 갈린다. 그래서 **루트 밖 파일의 identity 를 그대로 요구**해 본다 —
> 링크가 따라가지면 그 identity 와 일치해 capability 가 서고, 그것이 곧 유출이다. 서지 않는다.
> 같은 루트의 평범한 파일이 정상적으로 서는 것을 대조군으로 함께 본다.
>
> **identity 비교가 유일한 방벽이라는 것도 실측했다** — 그 한 줄을 지우면 두 테스트 중 하나가 즉시
> FAIL 한다. Windows 에서 `NOFOLLOW` 가 링크를 거부하지 않으므로, 그 비교를 "중복" 으로 보고 지우면
> 그 순간 루트 밖이 열린다.
>
> **링크를 못 만드는 기기에서는 이 검증이 없다 — 그 사실을 찍는다.** Windows 는 심볼릭 링크 생성에
> 개발자 모드나 관리자 권한이 필요하다. 그때 조용히 `SkipZigTest` 를 내면 "검증했다" 와 "검증할 수
> 없었다" 가 똑같이 초록이라, `[skip] symLink failed (<이유>) - symlink guard unverified on this host`
> 를 찍고 나간다(대조군으로 확인). SSH 스모크 스크립트가 세운 "SKIP 은 조용한 통과라 위험하다" 와
> 같은 규율이다.
>
> **핸들 누수도 Windows 쪽 대칭을 만들었다.** macOS 에는 `std.c.fcntl(F.GETFD)` 로 fd 를 세는 테스트가
> 있는데 Windows 에 그 축이 없어 같은 성질이 **한 번도 검증되지 않고 있었다**. `GetProcessHandleCount`
> 가 이 기기에서 흔들리지 않는 것을 먼저 재고(무작업 drift 0), 실패·성공 세 갈래를 200 회씩 돈다.
>
> **처음 쓴 판은 공허했다** — 존재하지 않는 경로로만 돌렸는데 그것은 `realPath` 에서 먼저 끝나
> **핸들을 열지도 않는다**. 실패 경로에서 안 닫도록 고의로 망가뜨려도 통과했다. macOS 대칭 테스트가
> 쓰는 두 갈래(`openCanonicalDirectoryNoFollow` 직접 호출 · `force_identity_failure`)로 바꾸고 나서야
> **두 갈래가 각각 독립적으로 FAIL** 하는 것을 확인했다. 5 회 연속 돌려 흔들리지 않는 것도 봤다
> (백엔드가 워커 스레드를 띄우므로 프로세스 전역 카운트가 튈 수 있어 따로 쟀다).
>
> **리프가 디렉터리인 경우는 두 호스트에서 이유가 다르다.** macOS 는 `openat(O_RDONLY)` 가 디렉터리를
> **열고** 그 뒤 identity 비교가 거른다. 그 외에는 `allow_directory = false` 가 **여는 단계에서**
> 끝낸다. 결과가 같으므로 호출자는 차이를 몰라도 되지만 한쪽만 바뀌면 갈리므로 테스트로 묶었다 —
> 대조군으로 `allow_directory` 를 되돌려도 identity 비교가 받고, **둘 다 지우면 뚫리는 것**을 봤다.
>
> **UNC 루트도 끝까지 돈다**(실측): `//localhost/D$/…/root` 에서 접두 14 를 고르고 그 아래를 한 칸씩
> 내려가 검증이 성공하며, 반환 경로도 정규화 형태다. `C:/`·`D:/`·`//localhost/C$` 를 실제로 여는 것도
> 따로 확인했다.

**`NOFOLLOW` 의 의미가 OS 마다 다르다 — 실측했다.** POSIX 는 링크를 만나면 open 자체가 실패하는데,
Windows 의 `openFile(.follow_symlinks = false)` 는 **링크 자신을 연다**(거부하지 않는다). 그래도 가드가
서는 이유는 그 핸들의 identity 가 기대값과 다르기 때문이다 — 실측: 링크 핸들 inode
`3377699722174903` vs 루트 밖 파일 `3940649675596210`. **그래서 identity 비교를 "NOFOLLOW 가 있으니
없어도 된다" 고 지우면 안 된다.** Windows 에서는 그 비교가 유일한 방벽이다.

**`std.fs.path.join` 을 중립 경로에 쓰면 안 된다.** Windows 에서 그것은 **native 구분자**로 잇는다 —
정규화한 `D:/…/tmp` 에 붙이면 역슬래시가 섞인 경로가 나오고, `pathWithinRoot` 가 그것을 루트 밖으로
본다(실측). 저장소에 `std.fs.path.join` 이 **107 곳** 있고 대부분은 테스트지만
`agent_session_archive_backend`·`app_session/file_panel` 처럼 **제품 자리도 있다.** 지금은 그 파일들이
macOS 전용이라 잠복이고, **W8 이 그것들을 배선할 때 함께 봐야 한다.**

**테스트가 macOS 호스트에서만 돌고 있었다.** 이 백엔드의 테스트는 `app_session` 모듈에 실려 있어
Windows 에서는 **하나도 안 돌았다** — 그 상태로 Windows 갈래를 고쳐 봐야 아무도 안 밟는다. 그래서
이 파일만 도는 테스트 산출물을 `build.zig` 가 **모든 호스트**에 매단다. 파일 위치가
`platform/macos/` 인 것은 이제 이름과 안 맞는다 — 옮기는 것은 소비자가 생기는 W8.2 와 함께 볼 일이다.

### 2m.4 파일 트리 데이터 경로가 Windows 에서 끝까지 흐른다 (W8.2 ⒜, 실측 2026-08-20)

W8.1 이 백엔드 한 겹(루트 검증·리프 열기)을 열었다. 그 위의 **중립 로직 전체**가 도는지는 별개 질문이라
`maru win32-file-tree-smoke` 로 잰다 — 루트 등록(`replaceExplicitRoots`) → 백엔드 스캔 →
`applySnapshotWithIdentity` → `buildRows`.

**그림보다 계약이 먼저다**(§2a 가 프레임으로 물었던 것과 같은 순서). 화면에 붙이기 전에 데이터가
끝까지 가는지를 본다.

```text
maru.win32-file-tree-smoke.v1
root=D:/ohah/maru/zig-out/maru-file-tree-smoke
scan_entries=4 rows=6 dirs=1 files=3
found: alpha=true beta=true hangul=true sub=true
```

**판정은 행 수가 아니라 내용이다.** 행이 몇 개인지만 세면 스캔이 빈 결과를 내도 초록으로 보인다 —
이 저장소가 여러 번 밟은 부류다. 그래서 fixture 이름이 실제로 행에 있는지를 본다. 대조군으로
확인했다: 스캔 결과를 트리에 안 넣으면 `rc=1`.

**fixture 에 비-ASCII 이름을 하나 섞는다.** 백엔드가 WTF-8 경로를 끝까지 나르는지가 이 슬라이스의
숨은 판정이고, 그것이 깨지면 한글 사용자 이름을 가진 기기에서 파일 패널이 통째로 빈다.

**적대적 검증이 이 슬라이스에서 결함 둘을 더 찾았다 — 스모크가 제품 흐름을 안 밟고 있었다.**
처음엔 평범한 `submit` 으로 짰는데, 제품(`file_panel.zig`)은 루트를 세울 때 `validateRootSnapshot`
으로 검증하고 그때 열린 **no-follow 디렉터리 능력을 첫 스캔에 넘긴다**(`submitValidatedRootScan`).
`submit` 은 하위 디렉터리를 펼칠 때 쓰는 **다른 길**이라 W8.1 이 고친 자리를 하나도 안 밟았다.
제품 흐름으로 다시 짜자 둘이 드러났다.

| # | 증상 | 원인 |
|---|---|---|
| ⑴ | 넘겨받은 디렉터리를 **순회할 수 없다**(`ScanFailed`) | `openCanonicalDirectoryNoFollow` 가 `.iterate` 없이 열어 Windows 에서 `FILE_LIST_DIRECTORY` 가 빠진다 — 실측: 없는 쪽은 **0 개에서 `AccessDenied`**, 켠 쪽은 정상. **마지막 칸만** 켠다(중간 칸에 list 까지 요구하면 traverse 만 허용된 상위에서 걷기가 막힌다) |
| ⑵ | `IdentityMismatch` 로 트리가 안 선다 | **Windows 의 디렉터리 순회는 inode 를 안 준다** — 실측: 모든 항목이 `entry.inode = 0`, `stat` 은 진짜 값. 스캔이 기록한 identity 가 전부 0 이라 나중에 잰 값과 반드시 어긋난다. identity 축은 TOCTOU 가드라 0 으로 채우면 가드가 무의미해진다 |

**⑵ 의 첫 수정은 맞지만 145 배 느렸다 — 적대적 검증이 그것을 잡았다.** 항목마다 `stat` 을 부르게
했는데, 1,000 항목 디렉터리에서 재 보니:

```text
순회만                    0.4 ms
순회 + 항목마다 stat     58.2 ms   ← 항목당 57.8 us
배치 file id             0.4 ms   ← 순회와 같다
```

디렉터리 상한이 4,096 이라 최악 **~237 ms** 다 — 펼치기가 눈에 보이게 멈춘다. Windows 는
`GetFileInformationByHandleEx(FileIdBothDirectoryInfo)` 가 **열거하면서 ID 를 함께** 주므로 그 비용이
사라진다. 스캔이 디렉터리마다 `이름 → 파일 ID` 표를 한 번 만들고 기존 순회가 조회한다.
**끝단 실측: 1,000 항목 스캔이 6.6 ms.**

**판정을 OS 가 아니라 값으로 한다.** `entry.inode != 0` 이면 그대로 쓰고(POSIX 는 여기서 끝난다),
표에 있으면 표를, 둘 다 없으면 그 항목만 `stat` 으로 채운다 — 표가 실패해도 **느릴 뿐 틀리지 않는다**
(대조군: 표를 강제로 비워도 스모크가 통과한다. identity 를 0 으로 만들면 rc=1).

둘 다 POSIX 에서는 원리적으로 안 드러난다(디렉터리 fd 하나, readdir 이 inode 를 준다).

**수정마다 지키는 것이 다르다 — 되돌림 대조군(돌연변이)으로 확인했다.** 오른쪽 두 칸이 이 표의 요점이다.

| 수정 | 되돌리면 빨개지는 것 | macOS·Linux CI 가 잡나 |
|---|---|---|
| W8.1 ⑴ 리프 열기 갈래 | 단위 테스트 | 예 |
| W8.1 ⑵ 루트 접두 **규칙**(`rootPrefixLenFor`) | 단위 테스트 (두 OS 갈래 모두) | **예** |
| W8.1 ⑵ 루트 접두 **배선**(백엔드가 그 규칙을 부르는가) | 단위 테스트 5 개 + 스모크 | **아니오** |
| W8.1 ⑶ 입구 정규화 | 단위 테스트 | 예 |
| W8.2 ⑴ `.iterate` | 스모크 (`ScanFailed`) | **아니오** |
| W8.2 ⑵ inode 채우기 | 스모크 (`IdentityMismatch`) + 단위 테스트 | **아니오** |

**"단위 테스트가 잡는다" 와 "CI 가 잡는다" 는 다른 말이다.** 이 저장소에는 Windows CI 러너가 없다(방침).
Windows 전용 결함을 되돌리면 **Windows 기기에서는** 빨개지지만 macOS·Linux 러너에서는 초록이다 —
그 돌연변이가 POSIX 에서는 무해하기 때문이다. 실측: 배선을 끊었더니 Windows 에서 단위 테스트 5 개가
빨개졌는데, 그 돌연변이(`경로[0] == '/'` 면 1)는 macOS 에서 `rootPrefixLenFor(.macos)` 와 **정확히 같은
값**이라 macOS 에서는 아무것도 안 잡힌다.

**그래서 규칙을 OS 파라미터로 빼는 규율이 값을 낸다**(§5 가 정한 것). 위 표에서 CI 가 잡는 칸은
전부 `os_tag` 를 인자로 받는 순수 규칙이다 — 두 갈래가 **macOS 러너에서 함께 돈다**. 반대로 CI 가 못
잡는 칸은 전부 "그 규칙을 실제로 부르는가"·"핸들을 어떤 권한으로 여는가" 처럼 **OS API 를 직접 밟는
자리**다. 이 경계가 곧 "무엇을 순수 함수로 뽑아야 하는가" 의 판정 기준이다.

남는 위험은 사라지지 않고 **자리만 옮겨진다** — 배선과 OS API 자리는 사람이 Windows 에서
`zig build win32-file-tree-smoke` 와 `zig build test` 를 돌려야 지켜진다. 이 문서가 그것을 적는 이유다.
스모크는 이 저장소의 다른 스모크와 같이 **build step 으로** 세웠다(처음엔 CLI 하위 명령으로만 뒀는데,
그러면 혼자만 안 도는 것을 발견할 방법이 없다 — 적대적 검증에서 `no step named` 로 직접 걸렸다).
Windows 아닌 호스트에서는 시끄럽게 건너뛴다.

> **대조군을 여섯 번 헛돌린 뒤에야 위 표가 나왔다.** 치환 패턴이 안 맞아 편집이 아예 안 됐거나,
> 빌드가 실패했는데 `>/dev/null 2>&1` 로 그것을 가리고 **낡은 바이너리를 읽었다**. 지금은 대조군마다
> **편집 반영(grep)·빌드 rc·바이너리 해시 변화** 셋을 확인하고, 하나라도 어긋나면 그 측정을 버린다.
> "대조군을 돌렸다" 는 그 셋을 본 뒤에만 할 수 있는 말이다.

**남은 것은 ⒝ 그리기다.** chrome 은 이미 Windows 로 컴파일되므로(§2m) 행을 프레임으로 낮추는 배선이
남았고, 그 앞에 `std.fs.path.join` 제품 자리 둘을 봐야 한다(§2m.3).


### 2m.5 이름 바꾸기가 만든 경로가 중립 층에서 "루트 밖" 으로 답한다 (W8.2 ⒝-0, 실측 2026-08-20)

⒜ 가 데이터 경로를 열었다. 그리기로 가기 전에 **경로를 조립하는 제품 자리**를 먼저 본다 — 섞인 구분자
위에 UI 를 얹으면 나중에 나오는 버그가 **그리기 문제로 보인다.**

`std.fs.path.join` 은 호스트 native 구분자를 넣는다. Windows 실측:

```text
join("D:/proj", "lib")  ->  "D:/proj\lib"      ← 한 문자열에 구분자가 둘
```

파일 트리에서 폴더 이름을 바꾸면 그 값이 `remapPath` 의 새 접두가 되어, 열려 있던 탭의 경로가 된다.
그 끝단을 재면:

```text
열린 탭의 새 경로       join(native)              '/'로 이음(대조군)
                        "D:/proj\lib/main.zig"    "D:/proj/lib/main.zig"
바뀐 폴더 안인가?       false                     true
프로젝트 루트 안인가?   false                     true
```

**크래시가 아니라 조용한 오답이다.** `pathWithin` 의 경계 판정이 `/` 만 세기 때문인데, 그 자리는 POSIX 에서
`p\q` 가 합법 파일명이라 `\` 를 경계로 셀 수 없다(W1.5 회귀가 그것이었다). 방향은 fail-closed 라 **보안
구멍은 아니고**, 이름 바꾸기가 망가진다.

**경로 주입은 아니다 — 확인했다.** `file_tree_mutation.validateName` 이 `/`·`\`·NUL·`.`·`..`·빈 값·비 UTF-8 을
이미 막으므로 이어 붙는 이름은 검증된 한 칸이다. 결함은 순수하게 잇는 방식 하나다.

**규칙으로 뽑는다 — `path_shape.joinNeutral`.** `os_tag` 를 안 받는다: 중립 층은 어느 호스트에서든 `/` 라
이 규칙에는 갈래가 없고, 그래서 macOS·Linux CI 가 이것을 **전부** 지킨다. 드라이브 루트(`C:/`)와 POSIX
루트(`/`)에서 이중 슬래시가 안 나오는지, 빈 부모를 거부하는지를 함께 못 박았다.

**그런데 규칙만으로는 부족하다 — 배선은 CI 에 안 보인다.** §2m.4 의 표가 가른 그대로다: "제품이 그 규칙을
실제로 부르는가" 는 되돌려도 POSIX 에서 초록이다(같은 코드가 macOS 에서는 `/` 를 낸다). 이번에는 그것을
**소스 스캔으로 CI 에 끌어왔다** — `tests/boundary/neutral_path_join.zig` 가 중립 층으로 가는 경로를
조립하는 파일에 `std.fs.path.join` 이 없는지 본다. 동작이 아니라 소스를 보므로 **호스트와 무관하다.**

| | Windows | macOS·Linux CI |
|---|---|---|
| 동작 테스트로 배선 잡기 | 잡는다 | **못 잡는다** |
| 소스 스캔으로 배선 잡기 | 잡는다 | **잡는다** |

이것이 이 포팅에서 Windows 전용 배선 결함이 CI 에 잡히는 첫 자리다. 다만 **소스 스캔은 만능이 아니다** —
`0 이면 통과` 라 스캐너가 아무것도 안 읽어도 초록이다(경로 오타·파일 이동). 그래서 같은 스캐너로 **반드시
있어야 하는 것**(`joinNeutral` 호출)을 함께 확인하는 대조군을 붙였고, 되돌림 대조군으로 게이트가 실제로
빨개지는 것을 확인했다.

**대상 목록을 무턱대고 넓히지 않는다.** OS API 에만 넘기는 경로는 native 여도 맞다 — 오히려 `cmd.exe` 는
native 를 요구한다(§4.2). 판정 근거는 "그 파일이 만든 경로가 중립 층 판정에 닿는가" 다.

**남은 자리는 원장에 적었다.** `agent_session_archive_backend.zig`·`agent_session_archive_scope_backend.zig`
가 같은 방식으로 `~/.claude/projects`·`~/.codex/sessions` 를 잇고 그 값이 에이전트 도크 목록으로 간다.
같은 결함이지만 그 표면은 **W8.5b** 몫이라 이번에 안 건드렸고, 경계 파일 주석이 그것을 원장으로 남긴다.
### 2m.2 게이트가 ADE 표면을 안 본다 (W8 이 먼저 메울 자리)

`check-targets` 는 `addProjectTest` 로 `maru.zig` 를 세 타깃에 컴파일한다 — 형태는 맞지만
**커버리지는 테스트가 참조하는 만큼**이다. 같은 대조군을 심어 쓸어 본 결과:

```text
덮임      chrome/draw.Rect.inset          (테스트가 실제로 부른다)
덮임      path_shape.relativeUnderRoot
안 덮임   chrome/components/archive_detail/view.view
안 덮임   chrome/components/session_dock/view.view
안 덮임   chrome/components/scm_dock/view.view
```

**하필 안 덮인 셋이 전부 ADE 표면이다**(에이전트 도크 상세·세션 도크·소스 컨트롤 도크). 명시 참조로
강제해 보면 셋 다 실제로는 Windows 에서 **컴파일된다** — 즉 코드는 지금 멀쩡하지만 **그것을 지키는
게이트가 없다.** W8 이 이 표면들을 건드리므로, 슬라이스보다 먼저 게이트를 넓히는 것이 순서다.

**닫았다 — W8.0.** `src/cross_target_surface.zig` 가 `maru.zig` 가 내보내는 **중립 모듈 21 개 전부**를
재귀로 훑어 주소를 잡고, `check-targets` 가 그것을 세 타깃으로 컴파일한다(처음엔 7 개만 훑어
`renderer`·`pty`·`app`·`cli`·`observability` 등 14 개가 빠져 있었다 — 적대적 검증이 잡았다).
깊이 상한은 조용한 `return` 이 아니라 `@compileError` 다: 실측 최대 깊이가 5 인데 상한을 6 으로
뒀더니 여유가 1 뿐이었고, 상한에 닿아 건너뛴 것과 검사한 것이 똑같이 초록으로 보였다.

**모듈 이름을 손으로 나열하지 않는다 — `maru.zig` 에서 유도한다.** 나열했더니 21 개 중 14 개가
빠져 있었다. 그리고 **훑은 선언 수에 하한을 둔다**(실측 2,937, 하한 2,000): 그것이 없으면
`refAllRecursive` 호출을 지워도 게이트가 초록이라 **조용히 무력화**된다.

**하한은 반드시 컴파일 타임이어야 한다.** `check-targets` 는 Run 없이 컴파일만 하므로 런타임
`std.testing.expect` 는 그 게이트에서 **한 번도 안 돈다** — 하한을 999999 로 올려도 초록이었다(실측).
`@compileError` 로 옮기고 나서야 "비우면 rc=1" 이 성립했다. 같은 대조군으로 확인했다: 도크 셋의 `view` 가
`안 덮임` → `덮임`. 표본을 넓혀 `session/file_tree`·`editor/document`·`chrome/settings`·
`config/serialize` 도 덮인다. 깊이 4(`editor_view.frame`·`scm_dock.build`)까지 닿는다.

**그래도 "전체" 는 아니다 — 두 구멍을 실측했다.**

| 구멍 | 덮이나 | 왜 | 지금 노출 |
|---|---|---|---|
| **제네릭 함수 본문** | **안 덮임** | 인스턴스화 없이는 본문 분석이 불가능하다 | 중립 표면에 16 개(chrome 3·session 9·config 4) |
| **비공개 + 미참조 함수** | **안 덮임** | `std.meta.declarations` 는 공개 선언만 준다 | 죽은 코드라 무해하지만 썩는다 |

타입 생성자형 제네릭은 소비자가 인스턴스화하며 분석되므로 실질 노출은 더 작다. 남는 위험은
`anytype` 을 받는 평범한 함수이고, 그런 것에는 **호출하는 테스트**가 이 게이트의 대체재다.

**walker 를 `maru.zig` 에 넣지 않는다.** 넣어 봤더니 호스트 `zig build test` 에서 `session_dock`·
`archive_detail`·`ui.button` 의 44 개가 한 번 더 돌았다(2983 → 3028) — 이미 `test-chrome-ui` 에서
도는 것들이라 순수한 중복이었다. 적대적 검증이 그것을 잡았고, 그래서 `check-targets` 안에서만
자기 루트로 선다.

> **컴파일된다 ≠ 돈다.** 변경 백엔드가 통과한 것도 컴파일까지다 — `renameat` 자리의 런타임 의미는
> 아직 안 봤다. W8.1 이 그것을 잰다.

즉 **디렉터리 위치만 macOS 다.** 앞 둘은 "루트를 한 번 열고 그 아래를 `*at` 로만 만진다"는 TOCTOU 규율
때문에 POSIX 를 쓰는 것이고, `std.Io.Dir` 이 같은 규율을 핸들 기준으로 준다(이미 일부는 그것을 쓴다 —
`submitValidatedRootScan(… dir: std.Io.Dir)`). `git_backend` 는 **손으로 쓴 프로세스 러너**라 성격이
다르다 — Windows 에서는 `CreateProcessW` + 파이프이고, 그것은 §4 의 ConPTY spawn 이 이미 밟은 자리다.

**`app_session.zig` 의 "AppKit" 참조 32 개는 거의 다 주석이다.** 실제 결합은 C ABI(`app_host_abi.zig`)를
통한 Swift 호스트이고, 그 파일이 하는 일은 **정책과 조립**(어떤 표면을 언제 열고, 프레임을 어떻게 만들고,
이벤트를 어디로 보내는가)이다. 그 정책은 플랫폼과 무관하다.

**그래서 W8 은 표면 단위로 자른다.** W7 이 세운 패턴 그대로다 — 중립 로직(chrome + session)을 Win32
호스트에 배선하고, 그 표면이 필요로 하는 백엔드만 Windows 로 만든다.

| 슬라이스 | 내용 | 선행 |
|---|---|---|
| **W8.0** | **게이트를 먼저 넓힌다** — `check-targets` 가 ADE 표면(chrome 도크 셋·백엔드 공개 표면)을 **명시 참조로 강제 분석**하게 한다. 안 하면 W8 의 나머지가 검증 없이 쌓인다(§2m.2) | 없음 |
| **W8.1** | **파일 트리 백엔드가 Windows 에서 돈다** — 완료. 아래 §2m.3 | W8.0 |
| **W8.2** | **파일 패널 표면** — ⒜ 데이터 경로(스캔→트리→행)를 Win32 에서 끝까지 흘린다(**완료**, §2m.4) ⒝ chrome 이 그것을 그린다(다음) | W8.1 |
| **W8.3** | **에디터 표면** — `session/editor/` 는 이미 중립이다. 배선과 입력 라우팅 | W8.2 |
| **W8.4** | **소스 컨트롤** — `git_backend` 의 Windows 프로세스 러너(`fork`/`execve`/`pipe` → `CreateProcessW` + 파이프). §4 의 spawn 절차를 재사용한다. **세 백엔드 중 유일하게 진짜 포팅이다** | W8.1 |
| **W8.5b** | **에이전트 도크** — `agent_*` 백엔드 셋 | W8.2 |
| **W8.6** | **웹 패널** — WebView2 + DirectComposition. **§8 의 합성 모델 결정이 선행이다** | 결정 대기 |

**웹 패널을 마지막에 두는 이유**는 그것만 미결 결정에 걸려 있기 때문이다 — 앞의 다섯을 막지 않는다.
## 3. 셸과 셸 통합

### 3.1 셸 티어

| 셸 | cwd | 프롬프트 마크 | 비고 |
|---|---|---|---|
| **PowerShell** (pwsh 7 / Windows PowerShell 5.1) | ✅ | ✅ (exit code 포함) | 네이티브 기본 |
| **cmd** | ✅ | 부분 — **exit code 불가** | §3.4 |
| **WSL** | ✅ (OSC 7) | ✅ | 터미널·통합은 그대로 오지만 **ADE 축 셋이 안 온다** — 아래 |
| git-bash · nu 등 | 통합 없으면 2단(§3.5)에 의존 | — | 뜨긴 뜬다 |

**WSL은 "공짜로 따라오지" 않는다(적대적 검증에서 드러남).** ConPTY 입장에서 `wsl.exe`는 그냥 자식이라
**터미널과 셸 통합(OSC 7·133)은 그대로 온다.** 그런데 **WSL2는 경량 VM**이라 그 안의 프로세스가 Windows
프로세스 목록에 나타나지 않는다(보이는 것은 중계 `wsl.exe` 하나뿐). 그래서 Windows 쪽에서 프로세스를 보는
축이 전부 무너진다:

| 축 | WSL2에서 |
|---|---|
| **에이전트 탐지**(§3.6) | ❌ `claude`·`codex`가 VM 안이라 안 보인다. maru는 이 판정을 **proc_name 폴링**으로 한다(`session_model.AgentKind` — *"pollAgentKinds가 ≈0.5s마다 proc_name으로 갱신"*)이므로, 사이드바 에이전트 목록·세션 도크·에이전트 상태가 **동작하지 않는다** |
| **cwd 2단**(§3.5) | ❌ PEB로 보이는 것은 `wsl.exe`의 **Windows 쪽 cwd**라 Linux 쪽 실제 cwd와 다르다. 1단(OSC 7)만 유효하다 |
| **경로 소비** | ⚠️ OSC 7이 주는 `/home/user/x`는 **Linux 경로**라 Windows 파일 API로 못 연다. 파일 탐색기·소스 컨트롤이 쓰려면 `\\wsl$\<distro>\…` 변환이 필요하다 |

ADE의 핵심이 에이전트 축이므로 이것은 작은 결함이 아니다. **해법은 아직 정하지 않았다**(§8).

### 3.1a 어떤 셸을 띄우는가 — 선택과 기본값

**사용자가 고르는 수단은 이미 있다.** `shell.command`/`shell.args`([configuration-shell.md](configuration-shell.md))가
그 자리이고, Windows에서도 같은 키가 그대로 동작한다(아래 "OS 분기" 논의는 그 키를 **대체**하는 것이 아니라
같은 파일을 두 OS에서 공유할 때의 override를 더할지의 문제다).

```conf
shell.command = C:\Program Files\PowerShell\7\pwsh.exe
shell.args    = -NoLogo
```

**없는 것은 기본값 결정 규칙이다.** `pty.resolveInteractiveShell()`(`src/pty/types.zig`)은 중립 파일에 있으면서
`MARU_INTERACTIVE_SHELL` → `SHELL` → `/bin/sh` 순으로 **POSIX만** 안다. Windows에는 `$SHELL`이 없고 `/bin/sh`도
없다. **이 함수가 OS별 갈래를 가져야 한다** — 중립 파일에 POSIX 기본값이 박혀 있는 것은 방금 고친
`monotonicMs`(§4.1 계열)와 같은 종류의 누수다.

**Windows 기본값은 PowerShell이다(사용자 확정).** `%COMSPEC%`(=거의 항상 `cmd.exe`)를 따르지 않는다 —
cmd는 `OSC 133 D`를 원리적으로 못 내고(§3.4) 통합이 가장 약한 셸이라, 그것이 기본이 되면 ADE 기능이 기본
상태에서 반쯤 꺼진 채 시작한다. 해석 순서:

```text
MARU_INTERACTIVE_SHELL  →  shell.command(config)  →  pwsh 7  →  Windows PowerShell 5.1  →  cmd
```

`MARU_INTERACTIVE_SHELL`은 maru 자체 변수라 OS 무관하게 1순위로 유지한다. 마지막 `cmd` 폴백은 PowerShell이
없는 기기에서도 터미널이 뜨게 하기 위한 것이다(§3.1의 cmd 티어 그대로 동작한다).

**config로 바꿀 수 있어야 한다(사용자 확정).** 수단이 셋이고, 구체적인 것이 이긴다.

```conf
# ① 종류만 고른다(Windows 전용 키)
shell.windows-shell   = cmd
# ② 경로를 못 박는다(OS별 override)
shell.command.windows = C:\Program Files\PowerShell\7\pwsh.exe
# ③ 모든 OS 공통(Windows에선 ②가 이긴다)
shell.command         = /bin/zsh
```

**OS 분기는 일반 메커니즘으로 넣었다(§8에서 결정 완료).** 한때 "셸만 일회성 키로 둘지, 일반 메커니즘으로
만들지"가 미결이었는데, 일반 메커니즘 쪽이 **오히려 코드가 적다** — 로더가 키에서 접미를 떼고 호스트가 아니면
그 줄을 건너뛰는 것이 전부다(값 파싱·검증·GUI는 기본 키와 완전히 같은 경로를 탄다). 일회성 키였다면 셸에만
해법이 생기고 `font.size`·`workspace.root` 같은 다음 충돌마다 키를 하나씩 더 파야 했다.

동작 규칙과 예시는 [configuration.md](configuration.md) "OS별 값"이 소유한다. 요점만: **OS 접미 키가 기본 키를
파일 순서와 무관하게 이기고**, 다른 OS 줄은 조용히 무시되며, 모르는 접미(`.freebsd`·오타 `.window`)는 접미가
아니라 키 이름의 일부라 "알 수 없는 키"로 잡힌다. VS Code가 같은 문제를
`terminal.integrated.defaultProfile.windows`/`.osx`/`.linux`로 푸는 것과 같은 모양이다.

**`shell.windows-shell`은 경로가 아니라 종류를 고른다**(`pwsh`|`powershell`|`cmd`, 기본 `pwsh`). 실제 경로가
기기마다 다르기 때문이다 — pwsh 7은 설치 여부가 갈리고 5.1은 `%SystemRoot%`에 매여 있다. 종류만 고르면 해석은
아래 티어가 하고, 경로를 못 박고 싶으면 `shell.command`(+`.windows`)를 쓴다.

> **PowerShell 을 둘로 가른다 — 실측이 요구했다(W8.1c, 사용자 확정).** 한때 `powershell` 하나가 "pwsh 7 →
> 5.1 중 있는 것" 을 뜻했다. 그런데 **둘은 같은 셸의 버전 차이가 아니라 매개변수 집합이 다른 별개
> 프로그램**이다 — `-i` 를 5.1 은 `-InputFormat` 축약으로 읽고 값을 요구해 **안 뜨고**, pwsh 7 은 통과한다.
> 하나로 묶어 두면 **같은 config 가 기기마다 다른 셸을 띄우고**, 그 차이가 동작 차이로 이어진다.
> (`shell.args` 사고가 정확히 그 모양이었다 — pwsh 7 이 있는 기기에서만 재서 "문제 없다" 고 판단했다.)
>
> **그래도 고정이 아니라 선호다.** 고른 쪽이 없으면 다른 쪽으로 내려간다 — 없는 것을 골랐다고 터미널이
> 안 뜨면 안 된다. 진짜로 못 박고 싶으면 `shell.command` 로 경로를 적는다. Windows Terminal 도 5.1 과 7 을
> 별도 프로필로 둔다.
>
> 기본값은 `pwsh` 다. 이름만 바뀌었고 **동작은 예전 기본과 같다**(pwsh 7 을 먼저 보고 없으면 5.1). 다른 OS에서는 읽히되 쓰이지
않는다 — 키를 OS별로 숨기면 dotfiles를 공유하는 사용자가 macOS에서 "알 수 없는 키" 경고를 받는다.

> **배선을 끝냈다 — W7.6b(2026-08-19).** 위 규칙은 W7 에 적혀 있었지만 **소비자가 없었다**: 로더가
> `shell.command`·`shell.windows-shell` 을 파싱·검증해 두기만 하고, Windows 진입점은 전부 인자 없는
> `resolveInteractiveShell()`(`.powershell` 고정)을 불렀다. 실측으로 확인한 증상 — config 가 `cmd` 를
> 지정했는데 띄워진 자식은 `pwsh.exe` 였다. **로더가 값을 받아 두는 것과 그 값이 쓰이는 것은 별개**라,
> 소비자가 없으면 설정은 조용히 없는 것과 같다.
>
> `pty.resolveShell(configured, kind)` 가 1순위 티어를 맡고(`configuredShellCandidate` 가 형식 판정 —
> `os_tag` 를 받아 두 갈래가 모든 타깃에서 돈다), `maru.windowsShellKindOf` 가 config 열거를 중립 pty
> 열거로 옮긴다(명시 `switch` — `@enumFromInt` 는 집합이 갈렸을 때 **조용히 다른 셸을 띄운다**).
> 스모크가 `config_shell: windows_shell=… command=… resolved=… spawned_args=… config_args=…` 한 줄을
> 찍어 설정과 결과를 나란히 둔다.
>
> **`shell.args` 도 배선했다 — 기본값을 OS 별로 갈랐다(W8.1b, 사용자 확정).** 한때 배선할 수 없었던
> 이유는 `ShellConfig.args` 의 기본이 `&.{"-i"}` 하나뿐이라 "사용자가 값을 줬는가" 를 길이로 판정할 수
> 없었기 때문이다. 그래서 `defaultShellArgsFor(os_tag)` 를 두고 **POSIX 는 `-i`, Windows 는 없음**으로
> 가른다 — 이 기본값이 답하는 질문이 *"이 OS 에서 대화형 셸이 필요로 하는 argv 는 무엇인가"* 이고 그
> 답이 OS 마다 다르다. 셸 자체(`resolveInteractiveShellFor`)와 경로(`shell.command.windows`)가 이미
> OS 로 갈리므로 `args` 만 OS 무관이던 것이 오히려 예외였다.
>
> **`-i` 를 Windows 에 넘기면 셸이 안 뜬다 — 실측했다.** PowerShell 5.1 에서 `-i` 는 `-InputFormat` 의
> **축약**이고 그 매개변수는 **값을 요구한다**:
>
> ```text
> powershell.exe -i                     exit=-196608, 사용법 출력 — 안 뜬다
> powershell.exe -i -Command '…'        같음
> powershell.exe -i Text -Command 'Y'   exit=0, Y — `-i` 가 InputFormat 이라는 증거
> ```
>
> pwsh 7 은 통과하고 cmd 는 무시한다. **하필 5.1 이 셸 사다리의 2 순위**라(§3.1a) pwsh 7 이 없는
> 기기에서는 터미널이 아예 안 열린다. 처음에 "둘 다 죽지는 않는다" 고 적었던 것은 **5.1 을 안 재서**
> 나온 판단이었다(적대적 검증이 잡았다).
>
> 리포트는 이제 `args=` 하나만 찍는다 — `spawned_args`·`config_args` 를 따로 찍던 것은 배선 전에
> 둘이 갈려 있던 동안의 진단이다.
>
> 배선하자마자 **§5 의 정규화가 spawn 에서 터졌다**(cmd 의 argv\[0\]). §5 규칙 1 의 뒤집힌 결정을 보라.

**탭별로 다른 셸을 여는 "프로필"은 이 계약 밖이다.** 지금 maru에는 그 개념이 없고(전역 `shell.command` 하나),
macOS도 마찬가지다. 즉 **Windows 고유 요구가 아니라 제품 기능**이므로 별도 이니셔티브로 둔다 — 다만 Windows는
한 기기에 cmd·PowerShell·WSL이 공존하는 것이 정상이라 **수요가 macOS보다 크다**는 점은 기록해 둔다.

### 3.2 cwd 보고 — Windows의 사실상 표준은 OSC 9;9다

**네이티브 Windows 셸에는 OSC 7이 아니라 `OSC 9 ; 9 ; <경로> ST`를 쓴다.** ConEmu가 정의하고 Windows
Terminal이 채택했으며, Microsoft가 셸 통합 문서에서 cmd·PowerShell용으로 직접 안내하는 형태다.

```text
OSC 7     ESC ] 7 ; file:///C:\Users\...  ESC \     URI인데 구분자가 백슬래시 — 어색하다
OSC 9;9   ESC ] 9 ; 9 ; C:\Users\...      ESC \     네이티브 경로를 그대로 나른다
```

OSC 7은 `file://` URI를 요구하는데 Windows 경로를 URI에 넣으면 구분자·드라이브 문자가 어색해진다. OSC 9;9는
설계상 네이티브 경로를 나르므로 그 모호성이 없다. **둘 다 지원한다** — WSL·유닉스 셸은 OSC 7, 네이티브
Windows 셸은 OSC 9;9다.

**따옴표 유무 두 형태가 모두 실재한다(W1 구현 중 확인).** ConEmu 원본 스펙은 경로를 감싸고, Microsoft가
안내하는 `PROMPT`는 감싸지 않는다. **둘 다 실제 셸에서 캡처했다**:

```text
ConEmu 스펙 (pwsh)   ESC ] 9 ; 9 ; "C:\Users\…\scratchpad" ESC \
Microsoft PROMPT     ESC ] 9 ; 9 ;  C:\Users\…\scratchpad  ESC \
```

그래서 파서는 **양끝이 짝일 때만** 따옴표를 벗긴다. Windows 파일명에 `"`가 올 수 없으므로 이 판정은
모호하지 않고, 한쪽만 있는 비정상 입력은 그대로 둔다.

**percent-decode하지 않는다.** OSC 7의 path는 URI라 디코드가 맞지만 9;9은 네이티브 경로라, 디코드하면
`C:\temp\100%done` 같은 정상 경로가 깨진다.

**구분자도 정규화하지 않는다.** 받은 그대로 보관한다 — §5의 순서 제약(절대경로 판정을 `[0]=='/'`에서 먼저
떼어낸 뒤에 정규화한다)을 지키기 위해서다.

### 3.2a OSC 9;9엔 authority가 없다 — **9;9은 host를 건드리지 않는다**

**결정(사용자 확정).** `OSC 9;9`은 **cwd만 갱신하고 `cwd_host`는 그대로 둔다**(아래 후보 C).

```zig
// 개념
dispatchCwd(body)      // OSC 7  — (host, path) 쌍을 함께 세운다
dispatchConEmuCwd(p)   // OSC 9;9 — path만 세운다. host는 손대지 않는다
```

이유는 셋이다.

1. **A(무조건 로컬)보다 엄격히 낫다.** 원격 Unix가 OSC 7으로 host를 세운 뒤 어떤 프로그램이 9;9을 보내는
   혼합 케이스에서, A는 host를 지워 **원격 세션을 로컬로 뒤집는다.** C는 원격을 유지한다.
2. **비용이 0이다.** 새 상태도, wire 변경도 없다.
3. **뒤를 막지 않는다.** 나중에 B(원격 세션에서 무시)나 E(3상)를 얹을 수 있다.

#### 받아들인 위험 (명시)

**"ssh 서버를 켜고 프롬프트 통합까지 설정한 원격 Windows"에 맨 `ssh`로 접속하면, 그 세션의 cwd가 로컬로
오인된다.** 그러면 [§9.4의 안전장치](ssh-integration.md)가 발동하지 않아 로컬에 같은 경로가 있을 경우
**남의 저장소를 보여 주고 stage/discard가 그 로컬 파일을 바꾼다.**

이 위험을 안고 가는 근거:

- **발생 조건이 좁다.** 원격 Windows에서 `sshd`를 켜야 하고(실측 n=1에서 `Stopped`/`Manual`), Microsoft가
  안내하는 `PROMPT` 통합을 **사용자가 직접 설정**해야 한다. 기본 상태의 원격 PowerShell은 9;9을 보내지 않는다.
- **새로 만든 구멍이 아니다.** 맨 `ssh`에서 원격을 알 수 없다는 것은 OSC 7에 대해 **이미 문서화된 한계**다
  (§9.4). 9;9은 그 한계의 실패 모드를 바꿀 뿐이다.
- **완전한 대안이 비싸다.** 유일하게 이걸 막는 E는 `handoff_codec`의 `tag = 90` **wire 스키마 변경**이라
  명시적 converter와 version bump가 따라온다([session-host-upgrade.md](session-host-upgrade.md)).

**재검토 트리거**: 이 오인이 **실제로 보고되면** E로 올라간다. 가설을 막으려고 검증된 코드에 미검증 동작을
더하지 않는다는 [ssh-integration.md](ssh-integration.md) §9.2의 판단과 같은 형태다.

**위험의 범위는 "원격이 Windows일 때"로 한정된다.** 원격이 macOS·Linux면 그 셸은 ConEmu 9;9을 보내지 않고
OSC 7(host 포함)을 보내거나 아무것도 안 보낸다 — 둘 다 기존 경로 그대로다. 즉 **Windows에서 macOS/Linux로
접속하는 흔한 경우는 이 결정으로 나빠지지 않는다.**

| Windows maru → | 원격이 보내는 것 | 판정 |
|---|---|---|
| `maru ssh` → macOS/Linux | OSC 7 + `${HOST}`(원격 rc 스니펫, [§9.5](ssh-integration.md)) | 원격 — 맞다 |
| 맨 `ssh` → macOS/Linux (원격에 자체 OSC 7 보고자 있음) | OSC 7 + host | 원격 — 맞다 |
| 맨 `ssh` → macOS/Linux (보고자 없음) | 없음 | cwd가 **ssh 이전 로컬 경로**에 머문다 — 오래됐지만 실재하는 로컬 경로라 데이터 위험은 없다(기존 한계) |
| 맨 `ssh` → **원격 Windows(통합 설정됨)** | **OSC 9;9** | **로컬로 오인** ← 위에서 받아들인 위험 |

**C가 host를 보존한다는 것의 부작용도 적어 둔다.** `ssh-end`(OSC 5379)는 `ssh_remote_dest`만 지우고
**`cwd_host`는 지우지 않는다** — 로컬 셸이 다음 프롬프트에서 보내는 OSC 7(host 비움)이 그 자리를 덮는다.
그 사이에 9;9이 오면 C는 옛 원격 host를 유지하므로 **원격으로 판정**된다. 이는 **보수적인 쪽**이라(도크가
잠깐 안 붙을 뿐 잘못된 저장소를 열지 않는다) 받아들인다. 다만 통합이 아예 없는 셸에서는 그 host를 지워 줄
OSC 7이 영영 오지 않아 **그 Term이 계속 원격으로 남을 수 있다** — 실제로 겪으면 `ssh-end`가 `cwd_host`도
지우도록 넓히는 것이 후속 수정이다.

---

아래는 이 결정에 이르는 검토 과정이다 — 결론만 적으면 다음 사람이 같은 오답을 다시 거친다.

#### 무엇이 걸려 있나

OSC 7은 `file://<host>/<path>`라 **host를 함께 나른다.** maru는 그것으로 로컬/원격을 가르고
(`TerminalCore.hostIsLocal`), 원격이면 [§9.4의 소비처를 전수로 닫는다](ssh-integration.md) — 새 탭 cwd 상속,
tombstone 복원 spawn, 링크 resolve, git 조회. 문서가 위험을 직설적으로 적어 뒀다:

> *"로컬에 같은 경로가 있으면 **남의 저장소를 원격인 척 보여 주고**, 거기서 **stage/discard 하면 보고 있지도
> 않은 로컬 파일이 바뀐다**"* — [editor-surface-dock.md](editor-surface-dock.md)

**OSC 9;9엔 그 필드가 없다.** 경로만 온다.

#### 빈 host는 "미상"이 아니다 — **"로컬이다"라는 주장**이다

이것이 검토에서 가장 중요한 사실이다. `hostIsLocal`의 첫 줄이 `if (host.len == 0) return true;`인데, 이는
소극적 기본값이 아니라 **maru 자기 셸 통합이 의도적으로 쓰는 신호**다. `_maru_osc7`은 **일부러 host를 비워
보낸다** — `${HOST}`를 실었더니 셸 시작 시점과 앱 조회 시점의 hostname 스냅샷이 갈려 **자기 세션을 원격으로
단정**했고, 로컬 저장소에서 소스 컨트롤이 "git 저장소가 아닙니다"를 띄웠다(2026-08-13 사용자 보고,
[ssh-integration.md](ssh-integration.md) §9.2).

따라서 **"빈 host = 미상"으로 재해석하는 안은 maru 자신의 로컬 통합을 깨뜨린다.**

#### 실제로 위험해지는 조합

기존 한계는 **안전하게** 실패한다:

```
맨 ssh → 원격 Unix, OSC 7 없음     cwd = ""          도크 비활성        안전
```

9;9이 그 실패를 **위험한 쪽으로** 뒤집는다:

```
맨 ssh → 원격 Windows, OSC 9;9      cwd = "C:\proj"   로컬 C:\proj 판정   위험
                                     host = (필드 없음)
```

**다만 이 조합의 빈도는 낮아 보인다(실측으로 낮춰 잡았다).** 처음에 "Windows엔 OpenSSH 서버가 기본
탑재"라고 적었으나 그것은 **클라이언트** 얘기다. 서버는 별개이고, 측정한 기기(n=1)에서 capability는
설치돼 있었지만 **`sshd` 서비스가 `Stopped`/`StartType=Manual`** 이었다 — 즉 ssh로 들어갈 수 있는 Windows
기기는 **누군가 명시적으로 켠** 기기다. 게다가 Microsoft가 안내하는 `PROMPT`는 **사용자가 직접 설정**하는
형태라, 기본 상태의 원격 PowerShell은 9;9을 보내지 않는다.

정리하면 위험은 **"ssh 서버를 켜고, 프롬프트 통합까지 설정한 원격 Windows"** 에서만 발생한다. 확률은 낮지만
**발생하면 결과가 데이터 손상**이라는 비대칭이 남는다.

#### 후보와 각각이 못 막는 것

| | 내용 | 못 막는 것 |
|---|---|---|
| **A** | 9;9을 항상 로컬로 본다(= 아무것도 안 함) | 위 위험 전부. **고르는 게 아니라 기본으로 그렇게 된다** |
| **B** | 알려진 원격 세션(`sshRemoteDest()`)에서 9;9을 무시 | **맨 `ssh`** — `shell-integration.ssh`가 **기본 `false`**라 평범한 `ssh`는 OSC 5379를 안 만든다. 즉 위험을 만드는 바로 그 경우를 못 막는다 |
| **C** | 9;9은 authority를 만들지 않는다(기존 host를 그대로 둔다) | **원격 Windows** 케이스. 그 셸은 OSC 7을 안 보내므로 보존할 원격 host가 애초에 없다. 다만 **원격 Unix가 OSC 7으로 host를 세운 뒤 어떤 프로그램이 9;9을 보내는** 혼합 케이스는 C가 옳게 막는다(A는 그때 host를 지워 로컬로 뒤집는다) — 즉 C는 불충분하지만 A보다 엄격히 낫고, **어느 안을 택하든 "9;9이 host를 지우지 않는다"는 규칙은 함께 가야 한다** |
| **D** | 빈 host를 "미상"으로 재해석 | **자기 통합을 깨뜨린다**(위) |
| **E** | 3상(로컬/원격/미상)을 새로 도입 | 비용 — `cwd_host`는 `handoff_codec.zig`에 **`tag = 90` wire 필드**라 스키마 변경이고, 명시적 converter + version bump가 따라온다([session-host-upgrade.md](session-host-upgrade.md)) |

**정직한 상태**: 값싸면서 완전한 안이 없다. 맨 `ssh` 세션에는 그 정보가 애초에 없다 — 그것은 OSC 7에 대해
이미 문서화된 한계이고, 9;9은 그 한계의 **실패 모드를 안전에서 위험으로** 바꾼다.

#### 구현자가 밟을 함정 둘

**① C는 "원자적 쌍" 불변식을 깨는 것이 아니다.** `dispatchCwd`의 주석이 경고하는 것은 *부분 실패*
(host 할당에 실패했는데 path만 갱신)이고, C는 **프로토콜이 path만 나르는 경우**를 다루는 별개 경로다.
그래도 결과적으로 "새 path + 옛 host" 쌍이 생기므로, 그 조합이 안전한지 확인해 두면:

| 직전 상태 | 9;9 도착 후 (C) | 판정 |
|---|---|---|
| host 없음(로컬) | host 없음 + 새 path | 로컬 — 맞다 |
| host=원격(OSC 7로 세워짐) | host=원격 + 새 path | 원격 — 맞다(A는 여기서 host를 지워 **로컬로 뒤집는다**) |
| host 없음 + 원격 Windows | host 없음 + 원격 path | **로컬로 오판** — 위에서 말한 잔여 위험 |

즉 C는 어떤 경우에도 A보다 나쁘지 않고, 두 번째 행에서 **엄격히 낫다**.

**② `title_generation` bump를 빠뜨리면 안 된다.** `dispatchCwd`는 cwd나 host가 바뀔 때만 bump하는데, 이
generation은 창 제목 재sync만이 아니라 **runtime observation refresh의 게이트**다. 9;9 경로에서 bump를 빼면
경로가 바뀌어도 관측이 갱신되지 않아 **폴더줄이 옛 값을 계속 그리고 cwd 상속·링크 스코프도 옛 판정에
머문다** — 같은 결함이 host 축에서 실제로 발생해 적대적 검증으로 잡힌 적이 있다(`osc.zig` 주석).

#### 검토에서 폐기한 논거

- ~~"`maru ssh`가 원격 접속의 주 경로라 B로 충분하다"~~ — **틀렸다.** `shell-integration.ssh`가 기본 `false`라
  라우팅이 안 걸린다. B가 커버하는 것은 `maru ssh`를 **직접 친** 세션과 opt-in을 켠 사용자뿐이다.
- ~~"D가 가장 정확하다"~~ — **틀렸다.** 빈 host에 이미 의미가 있다(위).

#### 남은 축 — 아직 재지 않은 것

결정 전에 재야 할 것이 있다: **원격 Windows 셸이 실제로 9;9을 얼마나 보내는가.** Microsoft 문서는 사용자가
`PROMPT`를 직접 설정하는 형태로 안내하므로, 기본 상태의 원격 Windows 서버가 9;9을 보낼지는 별개다. 이 값이
작으면 A + 문서화된 한계로 충분할 수 있고, 크면 E의 비용을 치를 근거가 된다.

> **코어가 이미 절반 알고 있다.** `src/terminal/osc.zig`의 `dispatchNotify9`는 OSC 9를 iTerm2 알림으로
> 처리하면서 ConEmu 서브커맨드(`<숫자>;…`)를 알림 오발사 방지용으로 **소비만** 한다. 주석이 `9;9`(cwd)를
> 이름으로 나열하고 `9;4`(progress)는 실제로 `agent_progress`에 보관하는데, **`9;9`만 분기가 없어 조용히
> 버려진다.** 이 계약은 `4;` 옆에 `9;` 갈래를 더해 기존 cwd 경로로 넘기는 것을 뜻한다. 이는 L1 터미널 코어
> 변경이라 **Windows와 독립적**이다 — ConEmu 시퀀스를 쓰는 프로그램은 macOS·WSL에도 있다.

### 3.3 통합 주입 — 환경변수로 한다

macOS가 zsh 통합을 `ZDOTDIR`로 주입하는 것과 같은 결이다. **레지스트리를 쓰지 않는다** — cmd의 유일한
전역 훅인 `HKCU\...\Command Processor\AutoRun`은 maru 밖에서 뜨는 모든 cmd에 걸려 침습적이다.

- **cmd**: `PROMPT` 환경변수에 OSC를 심는다. `$E`가 ESC로, `$P`가 현재 경로로 확장된다.
- **PowerShell**: `prompt` 함수를 **인라인 `-Command`로** 정의한다. **스크립트 파일(`.ps1`)로 하지 않는다** —
  `ExecutionPolicy`가 `AllSigned`·`Restricted`면 서명 없는 파일이 막혀 통합이 통째로 죽는다. **인라인
  `-Command`는 정책 적용 대상이 아니다**(실측으로 확인: 정책과 무관하게 OSC가 나왔다).
  - **`-NoExit`이 함께 있어야 한다.** `-Command`만 주면 그 명령을 실행하고 **셸이 곧바로 끝난다**(실측:
    ConPTY로 띄운 pwsh가 스스로 종료). 대화형 셸을 원하면 `-NoLogo -NoExit -Command <정의>` 형태다.
  - **사용자 프로필이 `prompt`를 정의해도 우리가 이긴다.** pwsh는 프로필을 먼저 로드하고 `-Command`를
    나중에 실행한다 — 임시 홈에 `function prompt { … }`를 심은 프로필을 두고 실측했다: 프로필이 실제로
    실행됐는데도(마커 출력 확인) 우리 프롬프트가 살아남고 OSC가 나왔다. macOS zsh 통합이 사용자 rc를
    `MARU_ZDOTDIR_PREV`로 이어 주는 것과 달리, 여기서는 **순서가 그 역할을 한다.**

> **실측 주의**: §6의 PowerShell 항목을 처음 잴 때 프로세스 스코프 정책이 `Bypass`였다(도구 환경 탓).
> 즉 그 측정은 **파일 방식이 기본 정책에서 된다는 것을 증명하지 않는다.** 인라인 방식만 정책 무관으로
> 확인됐고, 그래서 계약이 인라인을 요구한다.

**사용자 프롬프트를 덮지 않는다.** 부모의 `PROMPT`(없으면 `$P$G`)를 읽어 그 **앞에 OSC만 덧붙인다.**
`SpawnRequest.zdotdir`는 zsh 전용 이름이라, 셸 중립적인 "통합 주입 지점"으로 일반화한다(§4).

### 3.4 cmd의 한계 — exit code는 원리적으로 불가하다

cmd의 `PROMPT` 확장 코드에는 **직전 명령의 종료 코드가 없다.** 따라서 `OSC 133 D`에 실을 값이 없고,
sticky command(`scrollback.sticky-command`)처럼 종료 상태에 기대는 기능은 cmd에서 동작하지 않는다.
Microsoft 문서도 같은 한계를 명시한다. **우회하지 않고 문서화한다.**

### 3.5 cwd 2단 — 물어볼 공개 API가 없다

macOS는 OSC 7이 없을 때 `proc_pidinfo(PROC_PIDVNODEPATHINFO)`로 커널에 묻는다(2단). 그 함수는 **공개
문서화 API**(libproc)다. **Windows에는 대응하는 공개 API가 없다** — WMI `Win32_Process`에도 현재
디렉터리 속성이 없다. 유일한 경로는 `NtQueryInformationProcess`로 PEB를 얻어 `ReadProcessMemory`로
`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`를 읽는 것이고, 이는 **비문서화**다(Process Explorer가 쓰는 경로).

**그래서 2단은 선택이다.** §3.2·§3.3으로 네이티브 셸이 모두 1단을 갖게 되므로, 2단은 macOS에서와 같은
**보조 위상**(통합 없는 셸·재개 Term)으로 내려간다. 2단을 둘지는 아직 정하지 않았다(§8) — 레퍼런스도
갈린다: Ghostty는 커널을 전혀 묻지 않고 "모른다"를 표현 가능하게 두는 반면([editor-surface-dock.md](editor-surface-dock.md) §3.5),
Orca는 4단까지 내려간다.

**둔다면 반드시 fail-soft여야 한다.** 구조체 오프셋이 비문서화라 Windows 버전·WOW64에 따라 달라질 수 있다.
실패하면 조용히 1단만 쓴다.

**그리고 후행 구분자를 순진하게 자르면 안 된다.** PEB의 `CurrentDirectory.DosPath`는 **항상 후행 `\`를
포함**하는데, 드라이브 루트에서는 값 자체가 `C:\`(3바이트)라 그냥 자르면 **`C:`** 가 된다. Windows에서 `C:`는
"C 드라이브의 **현재** 디렉터리"라는 **다른 뜻의 드라이브 상대 경로**다(실측 확인). 트림은 **결과가 드라이브
루트가 되는 경우를 예외로** 둬야 한다. 비공개 API 사용의 선례는 있다 — macOS의 창 블러가
`CGSSetWindowBackgroundBlurRadius`(비공개 CGS)를 쓴다.

### 3.5a `maru ssh`는 이미 컴파일된다

Windows에서 `maru ssh`가 도는지는 별개 축이라 짚어 둔다. **제품 경로는 이미 Windows에서 컴파일된다** —
`src/maru.zig`가 `cli`를 포함하고 `zig build test`가 Windows에서 통과하므로(§6), `cli/ssh.zig`의 POSIX 사용은
테스트 헬퍼(`fork`/`pipe`/`dup2`)에 갇혀 있다는 뜻이다. 실행에 필요한 `ssh.exe`도 Windows에 기본 탑재된다
(OpenSSH **클라이언트**는 기본, 서버는 별개 — §3.2a).

**다만 런타임은 미검증이다.** 원격에 terminfo를 심는 경로는 원격 쪽 `tic`을 쓰므로 원격이 Unix면 그대로
동작할 것으로 보이지만, ControlMaster 옵션·경로 인용 등 Windows `ssh.exe`와의 세부는 재지 않았다. W4 이후에
실기로 확인한다.

### 3.6 에이전트 탐지

ADE의 핵심인 "이 pane에서 claude/codex가 도는가" 판정이다. macOS는 `proc_listpgrppids`로 포그라운드
프로세스 그룹을 훑는다. Windows에는 프로세스 그룹이 없으므로 **`CreateToolhelp32Snapshot`으로 전체
스냅샷을 뜨고 `th32ParentProcessID`로 자식 체인을 따라간다.** 공개 API다.

## 4. ConPTY 백엔드

**명세는 스텁이 아니라 "중립 레이어가 실제로 부르는 것의 합집합"이다.** 한때 이 절은
`UnsupportedPtySession`을 명세로 삼고 "17개 중 13개 필수"라고 적었는데, 그 기준으로는 W7.0이 닫은 두
결함이 **둘 다 안 잡혔다** — 스텁에도 같은 멤버가 없었기 때문이다. 기준을 바꿨다.

| | |
|---|---|
| **합집합**(중립 레이어가 `self.session.<name>`으로 부르는 것, 기계로 열거) | `childPid` `close` `commitPreparedOwnership` `deinit` `readChunk` `readEvent` `reapAfterEof` `reapIfExited` `resize` `revalidatePreparedOwnership` `signalWrite` `upgradeEligible` `waitIo` `writeInputNonBlocking` + `PreparedAdoption.materialize` |
| **백엔드 셋 모두** 이 합집합을 만족해야 한다 | macOS · Windows · `UnsupportedPtySession`(그 밖 전부) |
| **§3.5·§3.6이 결정**(거짓말하지 않는 스텁으로 둔다) | `processCwd` `foregroundProcessNames` `foregroundProcessGroup` `resourceSamples` |

**합집합 밖은 흉내 내지 않는다.** macOS 백엔드에는 `prepareExact`·`validateInheritedMaster`·
`MasterIdentity` 등이 더 있지만 그 소비자는 `platform/macos/session_host/**`뿐이라 다른 타깃에서는
컴파일되지 않는다. 안 쓰이는 짝퉁을 넣으면 "표면이 맞다"는 착각만 주고, 정작 macOS가 쓰는 이름은 여전히
없다 — W7.0이 처음에 `prepare`·`discard`·`revalidate`(중립 소비자 0개)를 넣고 `prepareExact`(실사용)를
빠뜨려 그 함정을 그대로 밟았고, 코드 리뷰가 잡았다.

구현은 `src/pty/windows.zig`이고, **OS 무관한 조립 규칙**(커맨드라인 인용·환경 블록 내용)은
`src/pty/windows_spawn.zig`가 따로 가진다. 가른 이유는 후자가 모든 타깃에서 컴파일되어 **macOS·Linux CI에서도
그 테스트가 돌기** 때문이다 — Windows 러너가 없는 이 저장소에서 그 규칙이 공허참이 되지 않게 하는 유일한
그물이다.

**`currentSize`는 커널에 되묻지 않는다.** macOS는 `TIOCGWINSZ`를 쓰지만 ConPTY에는 크기를 되묻는 공개 API가
없다. 되물을 이유도 없다 — pseudoconsole 크기를 바꾸는 주체는 우리뿐이고(자식은 `mode con`으로 읽기만 한다),
우리가 넘긴 COORD가 자식에게 그대로 간다는 것은 §6에서 확인했다. 그래서 마지막으로 세운 값을 돌려준다.

**중립 레이어가 부르는데 백엔드가 안 가진 표면은 없다.** 한때 둘이 있었고 지금은 없다. `UnsupportedPtySession`이 "표면 명세"이지만, app
레이어는 그보다 **넓은 집합**을 부른다. 그 차이가 Windows에서 컴파일되지 않아 조용히 잠복해 있었다.

| 무엇 | 무엇이 깨졌나(실측) | 어떻게 닫았나 |
|---|---|---|
| `live_pty.childPid()`가 `std.c.pid_t`를 냈다 | 그 별칭이 Windows에서 `HANDLE`(`*anyopaque`)로 풀려 백엔드의 `u32`(DWORD pid)와 안 맞았다 — `expected type '*anyopaque', found 'u32'` | 중립 별칭 **`pty.ChildPid`** 를 뒀다. POSIX에서는 `std.c.pid_t`와 **글자 그대로 같아** macOS 소비자(`session_host/**`의 `child_pid` 등)가 무변이고, Windows에서만 `u32`다 |
| `PreparedAdoption`·`upgradeEligible`·`revalidatePreparedOwnership`·`commitPreparedOwnership` | Windows 백엔드에 **없었다** — `struct 'pty.windows.PtySession' has no member named 'PreparedAdoption'` | **막되 시끄럽게 막는다**(W2의 `publishBrowserResult` 선례). `upgradeEligible`은 **항상 false**라 업그레이드 경로가 열리지 않고, `prepare`/`revalidate`는 `error.UnsupportedOnWindows`, 도달하면 안 되는 `commitPreparedOwnership`·`materialize`는 `@panic`이다 |

**exec-restore를 왜 이식하지 않았나.** macOS는 host가 자기 자신을 `execve`로 갈아끼우며 상속된 PTY master
**fd**를 새 이미지가 주워 계속 쓴다. Windows에는 `execve`가 없고(자기 교체가 아니라 새 프로세스 생성),
핸들 상속(`bInheritHandles`)은 되지만 ConPTY의 `HPCON` 소유 관계가 다르다. **별도 설계**이고 세션 호스트를
Windows로 옮길 때 함께 정한다. 지금 조용히 되는 척하면 이식하는 사람이 그 결정을 잊은 채 반쪽 동작을 얻는다.

**표면 대조는 스텁이 아니라 "app 레이어가 실제로 부르는 것의 합집합"을 기준으로 해야 한다** — 둘 다
`UnsupportedPtySession`과의 대조로는 안 잡혔다(그 스텁에도 같은 멤버가 없다). 그래서 그 합집합을
`app/live_pty.zig`의 테스트 *"중립 레이어가 요구하는 PTY 표면이 세 백엔드에 다 있다"* 가 **컴파일 시점에**
고정하고, `zig build check-targets`가 그것을 세 타깃(macOS·Linux·Windows)으로 **컴파일만** 해 본다.

> **`zig build test -Dtarget=…`는 게이트가 못 된다.** 그 명령은 컴파일 뒤 산출물을 **실행**하려 하고 외래
> 타깃 바이너리는 호스트에서 못 돈다 — 실측: 모든 컴파일이 깨끗해도 exit 1이다. 한동안 이 문서가 그것을
> 게이트라고 적었는데, 실제로는 사람이 컴파일 오류 줄만 눈으로 거른 것이었고 **CI에는 그 잡이 아예
> 없었다**(코드 리뷰가 잡았다). 그래서 Run을 만들지 않는 `check-targets`를 새로 두고 `mise run check`의
> 의존에 넣었다 — 이제 required check가 실제로 돌린다(콜드 17초, 캐시되면 0초).
>
> **무엇을 컴파일하는지가 중요하다.** 중립 모듈(`maru.zig`)만 돌리면 `main.zig`가 빠지는데, 거기가 W2의
> 호스트 게이트와 W8.5의 경로 정책이 사는 자리라 타깃별로 가장 잘 깨진다. 게다가 그것을 **테스트로**
> 컴파일하면 test 블록이 참조하는 것만 분석돼 `main()` 아래가 통째로 빠진다 — 둘 다 실측으로 확인했다
> (적대적 검증에서 잡았다). 그래서 타깃마다 **모듈 테스트 + 실행 파일** 둘을 컴파일한다.

**참조가 요점이지 타입 조회가 아니다.** `@typeInfo(...).return_type` 조회도 `@hasDecl`도 선언만 보고
**본문을 분석하지 않는다**(실측: 반환 타입이 틀린 함수도, 본문이 `@compileError`인 함수도 통과한다).
그런데 원래 결함은 **본문 오류**였다. 그래서 테스트는 함수 값을 `_ = &f`로 실제 참조한다 — `_ = f`는
분석을 강제하지 못한다. 대조군으로 별칭을 되돌리면 정확히 그 자리에서 깨진다 — POSIX 갈래를 깨 보면 `live_pty.zig`뿐 아니라
`session_host/runtime_manager.zig:362`까지 컴파일 오류가 난다. **"회귀 0"이 말뿐이 아니라 강제된다**는 뜻이다.

**백엔드는 셋이다** — macOS·Windows·`UnsupportedPtySession`(그 밖 전부). 합집합은 셋 **모두**가
만족해야 한다. W7.0에서 Windows에만 넣고 스텁을 빠뜨렸다가 **Linux CI에서 잡혔다**
(`struct 'pty.session.UnsupportedPtySession' has no member named 'PreparedAdoption'`) — 로컬에서
Windows 네이티브와 macOS 크로스컴파일만 돌려 본 탓이다. 이제 세 타깃을 다 돌린다.

합집합이 실제로 완전한지는 기계로 확인했다 — 중립 레이어가 `self.session.<name>`으로 부르는 이름 14개
(`childPid`·`close`·`commitPreparedOwnership`·`deinit`·`readChunk`·`readEvent`·`reapAfterEof`·`reapIfExited`·
`resize`·`revalidatePreparedOwnership`·`signalWrite`·`upgradeEligible`·`waitIo`·`writeInputNonBlocking`)가
Windows 백엔드에 **전부 있다**(빠진 것 0).

**`writeInputNonBlocking`의 반환값 의미가 fence 계약과 어긋난다.** `pty_reader`의 `drainedAtFence()`는
`enqueued_total == consumed_total`을 "admitted outbound가 **실제로 PTY에 써졌다**"는 경계로 쓰는데, 이
백엔드에서 그 경계는 최대 한 청크가 미결 write로 남아 있는 상태에서도 성립한다(§4.1의 "인수한 양"). 지금은
그 경계를 쓰는 것이 exec-upgrade 안전점뿐이고 그것은 macOS 전용이라 도달하지 않는다. `deinit`은 취소 전에
미결 write의 완료를 짧게 기다려 **조용한 입력 유실**만은 막는다. 세션 호스트가 Windows로 올 때 이 경계의
뜻을 다시 정해야 한다.

**`.signaled`는 이 백엔드에서 나오지 않는다.** Windows에 시그널이 없다. 255를 넘는 종료 코드(예: Ctrl+C의
`0xC000013A`)는 `.exited: u8`에 담기지 않으므로 `.unknown`으로 원값을 보존한다 — `u8`로 자르면 `0x3A`(58)라는
엉뚱한 "정상 종료"가 된다.

### 4.1 `waitIo`는 계약을 바꾸지 않는다 — 파이프를 바꾼다

`waitIo(want_write) !IoReady`는 macOS에서 `std.posix.poll(master_fd, wake_read_fd)`다. 파일 디스크립터를
poll하는 모양이라 Windows로 그대로 오지 않아 보이지만, **계약은 그대로 두고 파이프 종류만 바꾸면 된다.**

**`CreatePipe`를 쓰지 않는다.** 익명 파이프는 동기 전용이라 "데이터가 왔는지"를 기다릴 방법이 없다. 대신
**`CreateNamedPipeW` + `FILE_FLAG_OVERLAPPED`** 로 만들고 비동기 read를 걸어 두면 그 완료 이벤트를 기다릴 수 있다.

```text
macOS    poll(master_fd, wake_read_fd)
Windows  WaitForMultipleObjects(read_overlapped_event, wake_event)
```

**실측으로 확인했다**(§6): 비동기 `ReadFile`이 `ERROR_IO_PENDING`으로 등록되고, 상대가 쓰면 read 이벤트로,
`SetEvent`로는 wake 이벤트로 깨어나며, 조용하면 스핀 없이 timeout한다. **`CreatePseudoConsole`이 named pipe
핸들을 그대로 받는다**(`hr=S_OK`)는 것도 함께 확인했다.

자식의 출력이 실제로 그 파이프로 흐르는 end-to-end도 실측으로 닫혔다(§6).

따라서 `waitIo`·`IoReady`·`readChunk`·`writeInputNonBlocking`의 **시그니처는 바뀌지 않는다.** 호출자도
하나뿐이다(`src/app/pty_reader.zig`의 reader 루프).

**다만 write 쪽은 의미가 그대로 오지 않는다 — 백엔드가 흡수해야 한다.** 적대적 검증에서 드러났다:

| | POSIX | overlapped |
|---|---|---|
| 뜻 | `POLLOUT` = "지금 쓰면 안 막힌다" | "내가 건 write가 끝났다" |
| 부분 진행 | `write()`가 나간 바이트 수를 준다 | **없다** — 전량이 나갈 때까지 하나의 미완료 작업 |

실측(4 KiB 파이프 버퍼에 512 KiB write): 즉시 반환은 `ERROR_IO_PENDING`에 `written=0`이고, 완료 전
`GetOverlappedResult`는 `ERROR_IO_INCOMPLETE`에 `bytes=0`이라 **부분 진행을 볼 수 없다.** 상대가 8 KiB를
읽어도 미완료이고, 전량을 읽어야 완료된다.

reader 루프는 `out_head += writeInputNonBlocking(...)`으로 **부분 진행을 기록**하므로, Windows 백엔드는 셋 중
하나를 골라 그 차이를 메워야 했다 — ① 미결 write를 한 건만 두고 완료 전까지 `writable`을 보고하지 않기,
② 파이프 버퍼 이하로 잘라 쓰기, ③ writer 스레드 + 큐.

**W4의 결정: ① + 백엔드 스테이징 버퍼.** `writeInputNonBlocking`은 받은 바이트를 **자기 버퍼로 복사**한 뒤
그만큼을 반환하고, `waitIo`는 미결 write가 없을 때만 `writable`을 보고한다. 그래서 미결 write는 언제나
최대 한 건이고, 반환값의 뜻은 *"파이프로 나간 양"*이 아니라 **"백엔드가 책임을 넘겨받은 양"**이다.

**복사가 선택이 아닌 이유**: 호출자는 반환값만큼 head를 전진시킨 뒤 자기 버퍼를 압축(`copyForwards`)하거나
비운다. 미결 overlapped write가 그 버퍼를 가리키고 있으면 커널이 이미 재사용된 메모리를 읽는다. ②를 버린
것도 같은 이유다 — 크기를 줄여도 "완료 전"이라는 창은 남는다. ③은 스레드와 큐를 더할 뿐 이 복사를 없애
주지 않는다. **대가**는 미결 write의 실패를 다음 호출에서 본다는 것이고, 그 상황은 파이프가 끊긴 때라
어차피 세션이 끝난다.

**그 복사가 새 위험을 만든다 — writer가 둘이다.** 리더 루프의 `writeInputNonBlocking`과 **메인 스레드**의
`writeInput`(예: `app_session.zig`가 프롬프트에 form feed를 보내는 자리)이 함께 있다. macOS는 둘 다 같은 fd에
써서 커널이 직렬화하지만, Windows 백엔드는 스테이징 버퍼와 `OVERLAPPED`를 **하나** 공유하므로 겹치면 커널
자료구조가 깨진다. 그래서 쓰기 쪽만 `SRWLOCK`으로 잠그고 **대기하는 동안에는 잠금을 잡지 않는다**(수거와
발행만 한 임계 구역). 읽기 쪽은 리더 전용이라 잠글 것이 없다.

### 4.1b EOF와 `ClosePseudoConsole` — POSIX와 가장 크게 갈리는 자리 (실측, 2026-08-16)

POSIX에서는 자식이 죽으면 슬레이브가 닫혀 master가 EOF를 본다. **ConPTY는 그렇지 않다.**

| 잰 것 | 결과 |
|---|---|
| 자식 종료 후 파이프가 끊기는가 | **아니다.** 3초를 더 기다려도 EOF가 없다 — conhost가 pseudoconsole이 살아 있는 동안 쓰기 끝을 붙든다 |
| 그러면 EOF를 내는 것은 | `ClosePseudoConsole`. 닫은 직후 읽으면 곧바로 EOF다 |
| 밀린 출력을 **안 읽은 채** 닫으면 | `ClosePseudoConsole`이 **106,891 ms** 막힌다 |
| 우리 읽기 끝을 **먼저 닫고** 나서 닫으면 | 더 나쁘다 — **379,922 ms** |
| **다 배수한 뒤** 닫으면 | **15 ms**, 유실 0 |
| 배수와 닫기를 **동시에** 하면 | 출력을 잃는다 — 142,949 바이트 중 65,573만 도착 |

여기서 두 규율이 나온다.

1. **배수한 뒤에 닫는다.** `waitIo`가 자식 프로세스 핸들도 함께 기다린다. 자식이 죽으면 계속 배수하다가
   무입력 창(`drain_quiet_ms`)만큼 조용해지면 그때 pty를 닫고, 그 결과로 오는 **진짜 파이프 끊김**을 EOF로
   낸다. 조용해질 때까지 기다리므로 출력을 잃지 않고, 다 배수한 뒤라 닫기가 15 ms다.
2. **`ClosePseudoConsole`을 인라인으로 부르지 않는다.** 최악이 분 단위라 UI 스레드에서든 리더 스레드에서든
   부르면 그만큼 멈춘다. 항상 **분리된 짧은 스레드**에 넘기고, 그 스레드는 `hpc` 하나만 소유해 세션 수명과
   얽히지 않는다.

**"배수한 뒤에 닫는다"는 뒷정리에도 적용된다.** `deinit`은 파이프 두 끝을 직접 닫지 않고 **배수 스레드에
넘긴다** — 그 스레드가 남은 출력을 버리며 읽어 conhost를 풀어 준 뒤에 닫는다. 그냥 닫으면 위 표의 379 s
경로를 그대로 만든다(`close`가 이미 시작한 닫기가 아직 도는 중이기 때문이다). 실측으로 확인했다:

| 상황 | `close()` | `deinit()` |
|---|---|---|
| 대화형 셸, 출력을 배수함 | 0 ms | 0 ms |
| 대화형 셸, 배수 안 함 | 0 ms | 0 ms |
| **3,000줄 덤프를 하나도 안 읽음** | **250 ms**(유예 창) | **0 ms** |

즉 최악이 앱 스레드에서 사라지고 분리 스레드로만 남는다.

**`close()`는 pty를 직접 닫지 않는다.** POSIX의 `SIGHUP → SIGKILL(-pid)`에 대응하는 것은 ⑴ 위 규율대로 pty
닫기를 넘기고 ⑵ 유예 뒤 **job을 닫는 것**이다. Windows에는 프로세스 그룹이 없어 `kill(-pid)`에 대응하는
것이 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`뿐이다 — 이게 없으면 팬을 닫아도 셸의 손자들이 남는다. 그래서
자식은 `CREATE_SUSPENDED`로 만들어 job에 넣은 뒤 깨운다(먼저 달리게 두면 job에 들어가기 전에 손자를 만든다).

### 4.1a spawn 절차 — 순서가 계약이다 (실측, 2026-08-16)

ConPTY spawn은 API 호출 목록이 아니라 **순서**가 본질이다. 두 자리를 틀리면 자식이 pty에 붙지 않고 조용히
부모의 콘솔로 출력한다 — 실패가 에러 코드로 오지 않고 **잘못된 성공**으로 오므로 여기에 못박는다.

```text
1  CreatePipe(in_read, in_write) ; CreatePipe(out_read, out_write)
2  CreatePseudoConsole(size, in_read, out_write, 0, &hpc)      → hr must be S_OK
3  CloseHandle(in_read) ; CloseHandle(out_write)               ← ★ 반드시 4보다 먼저
4  InitializeProcThreadAttributeList(1) → UpdateProcThreadAttribute(0x20016, hpc)
5  si.StartupInfo.dwFlags   = STARTF_USESTDHANDLES             ← ★ 세 핸들 전부 NULL
   si.StartupInfo.hStdInput = hStdOutput = hStdError = NULL
6  CreateProcessW(…, bInheritHandles=FALSE, EXTENDED_STARTUPINFO_PRESENT, &si, &pi)
7  자식이 사는 동안: out_read를 읽고, in_write에 쓰고, ResizePseudoConsole(hpc, …)
8  ClosePseudoConsole(hpc) → 자식에게 EOF가 간다
```

- **★ 3번(닫기를 spawn 앞에)**: pseudoconsole이 이미 자기 사본을 갖고 있다. 우리 사본을 남긴 채 spawn하면
  자식이 붙지 않는다.
- **★ 5번(표준 핸들 비우기)**: `bInheritHandles=FALSE`만으로는 부족하다. 명시하지 않으면 자식이 부모의 표준
  핸들을 물려받아 pty를 무시한다(실측 — §6).
- **8번(닫는 순서)**: `ClosePseudoConsole`을 먼저 하면 밀린 출력이 버려질 수 있고, `ResizePseudoConsole`은
  그 뒤로 `0x80070006`이 된다. 배수 → 종료 확인 → 닫기 순으로 간다.

### 4.2 `SpawnRequest`에서 실제로 바꿀 것

**`command` + `args`는 그대로 둔다.** 중립 계약은 *"무엇을 어떤 인자로 띄울 것인가"*(의도)를 표현하고,
그것을 OS 형식으로 인코딩하는 것은 백엔드의 일이다 — macOS 백엔드가 `execve`의 `argv[]`로 바꾸듯,
Windows 백엔드가 `CreateProcessW`의 `lpCommandLine` 문자열로 조립한다. 계약을 문자열로 바꾸면 Windows의
인코딩 디테일이 중립 레이어로 새고, argv quoting(백슬래시-따옴표 규칙)이 계약에 얹힌다.

> `cmd.exe`가 표준 CRT argv 파싱을 쓰지 않는다는 점은 **백엔드가 조립할 때** 지켜야 할 사항이지 계약을
> 바꿀 이유가 아니다. config는 이미 따옴표를 지원하지 않는다([configuration-shell.md](configuration-shell.md)).

| 필드 | 어떻게 | 상태 |
|---|---|---|
| `command` + `args` | **그대로.** 조립은 백엔드 | 변경 없음 |
| `login: bool` | **중립 유지.** 이름이 메커니즘(`login(1)`)을 가리키므로 **의도**("사용자의 대화형 로그인 세션인가")로 재문서화하고, 메커니즘만 백엔드가 정한다 — macOS는 `login(1)` 래핑, Windows는 무동작 | 재문서화 완료 |
| `zdotdir` → **`shell_integration_dir`** → **`shell_integration`** | **일반화.** zsh라는 셸 이름이 새고 있었다 → "통합 자산 디렉터리"로, 다시 **메커니즘 축의 union**으로(§4.2a). 백엔드가 매핑한다(zsh·bash·WSL=`ZDOTDIR` 등 파일, PowerShell=인라인 `-Command`, cmd=`PROMPT`) | 이름 변경 완료. union 전환은 **W5** — **wire 키 `"zdotdir"`는 파일 갈래에 그대로 남는다**(§4.2a) |
| `term` | 백엔드가 의미를 정한다. 네이티브 Windows 셸엔 무의미하고 WSL·msys 프로그램에만 쓰인다 | 재문서화 완료 |

### 4.2a 통합 주입 seam — 갈리는 축은 OS가 아니라 **메커니즘**이다 (2026-08-16 결정)

`shell_integration_dir`은 *"통합 자산 파일이 놓인 디렉터리"*다. macOS에서 그것이 `ZDOTDIR`이 되고, zsh가
거기서 `.zshenv`(8,385바이트)를 읽어 OSC 133·OSC 7·편집키·`ssh` 래핑을 켠다. **파일이 있어야 성립하는
모양**이다.

그런데 §3.3이 정한 Windows 두 메커니즘은 파일을 만들지 않는다 — PowerShell은 인라인 `-Command`(파일을
쓰면 `ExecutionPolicy`가 막는다), cmd는 `PROMPT` 환경변수 값이다. **가리킬 디렉터리가 없다.**

**그래서 "Windows는 이 필드를 안 쓴다"로 가르면 틀린다.** Windows 호스트가 띄우는 셸에는 세 부류가 있다:

| 셸 | 메커니즘 | 자산 디렉터리 |
|---|---|---|
| PowerShell | 인라인 `-Command` | 없음 |
| cmd | `PROMPT` 환경변수 | 없음 |
| **WSL·git-bash·msys의 bash/zsh** | **rc 파일**(`ZDOTDIR` 등) | **있다** — 게스트 네임스페이스 경로 |

WSL은 ConPTY 입장에서 그냥 자식이라 **셸 통합이 그대로 온다**(§3.1). 즉 같은 Windows 백엔드가 파일 기반과
비-파일 기반을 **둘 다** 다룬다. 갈리는 축은 OS가 아니라 메커니즘이다.

**결정: 중립 계약이 그 축을 그대로 표현한다.**

```zig
pub const ShellIntegration = union(enum) {
    /// 파일 기반 — 이 디렉터리에 통합 자산이 있다(zsh `ZDOTDIR`, bash rc). WSL·git-bash도 여기다.
    assets_dir: []const u8,
    /// 파일 없는 주입 — 메커니즘은 백엔드가 고른다(PowerShell 인라인 `-Command`, cmd `PROMPT`).
    inline_injection,
};
```

**wire는 깨지지 않는다.** `assets_dir`은 기존 `"zdotdir"` 키를 **그대로** 쓰고, `inline_injection`만 새 키를
더한다. 그리고 세션 호스트 파서는 **모르는 키를 거부하지 않는다** — `spawnOptionalStringField`/`spawnBoolField`가
`obj.get(key) orelse <기본값>` 모양이라 없는 키는 기본값이 된다(코드로 확인). 그래서:

| 방향 | 결과 |
|---|---|
| 새 앱 → **옛 호스트** | 새 키를 못 보고 무시한다. Windows 네이티브 통합만 조용히 꺼지고 셸은 정상 기동(graceful) |
| 옛 앱 → 새 호스트 | 새 키가 없으니 기본값. macOS·WSL 경로는 **한 글자도 안 바뀐다** |

**버린 두 갈래와 이유**:

- **"non-null을 켜짐 신호로 재해석"** — 값의 **뜻을 바꾸는** 것이라, 위 표에서 유일하게 옛 호스트가 오해할
  수 있는 갈래다([session-host-upgrade.md](session-host-upgrade.md)가 tag를 자동 생성하지 않기로 한 이유와
  같은 자리). 게다가 "경로가 의미 없다"는 전제가 WSL에서 거짓이다.
- **"Windows는 이 필드를 안 쓴다"** — 같은 이유로 불가. WSL·git-bash가 Windows 호스트인데 파일 기반이다.

**나중에 PowerShell이 파일로 옮겨 가도** `assets_dir` 갈래로 바꾸기만 하면 된다 — 재해석을 택했다면 그때 필드
의미를 **또** 바꿔야 했다. macOS 스크립트가 8 KB인 것을 보면 그 날이 올 수 있다.

> **구현 시점**: 이 결정을 코드로 옮기려면 `SpawnRequest`와 그 RPC 짝(`server.zig`·`remote_runtime.zig`·
> `runtime_manager.zig`)을 함께 바꿔야 한다. **W5가 그 일을 한다.**

**wire tag가 필드 이름과 어떻게 갈리는지 실물로 확인해 둔다.** 직렬화는 익명 구조체 리터럴이라 **그 리터럴의
필드 이름이 곧 JSON 키**다 — 한 줄 안에서 왼쪽은 wire, 오른쪽은 Zig 필드다.

```zig
js.write(.{ … .zdotdir = request.shell_integration_dir, … });
//             ^^^^^^^^ wire tag(고정)   ^^^^^^^^^^^^^^^^^^^^ Zig 필드(바뀌었다)
```

일괄 치환하면 여기서 wire가 조용히 깨진다. 파싱 쪽도 같다 — `spawnOptionalStringField(p, "zdotdir")`가
문자열을 직접 쓴다.

**`login`을 지우면 안 되는 이유**: 호출자가 정하는 정책이고(`agent.zig`가 비대화형에 `false`, 대화형에 `true`),
**세션 호스트 RPC를 건너간다**(`server.zig`→`runtime_manager.zig`→`remote_runtime.zig`). 지우면 백엔드가
"사용자의 대화형 셸"과 "통제된 자식 프로세스"를 구별할 수 없고 프로토콜에서도 필드가 사라진다.

**제약 — wire tag는 건드리지 않는다.** `SpawnRequest`의 필드는 `RuntimeSpawnParams`를 거쳐 세션 호스트
RPC를 건너간다. 그 JSON 키(`"zdotdir"`·`"term"`·`"login"`)는 **손으로 적힌 wire tag**라 Zig 필드 이름과
독립이다([session-host-upgrade.md](session-host-upgrade.md)가 "tag를 자동 생성하지 않는다"로 못박은 이유가
이것이다 — 영속 호스트라 새 앱이 **옛 호스트**와 대화한다). **native 필드만 바꾸고 tag는 그대로 둔다.**
tag를 바꿔야 한다면 명시적 converter와 version bump가 따로 필요하다.

### 4.3 ConPTY를 함께 배포한다 — 인박스 conhost가 낡으면 기능이 없다 (W7.6 결정, 실측 2026-08-18)

**`CreatePseudoConsole`을 kernel32에서 부르면 pty 호스트는 `%SystemRoot%\System32\conhost.exe`다.**
그것이 OS와 함께 늙는다. 이 개발 기계는 conhost `10.0.19041.4522`인데, 클라이언트가 마우스를 켰을 때
터미널에 알려 주는 기능([microsoft/terminal#9970](https://github.com/microsoft/terminal/pull/9970), 2021)이
그보다 나중이라 **vim·htop이 마우스를 못 받았다**(§2k).

**Microsoft의 방침이 "앱이 새 버전을 들고 다녀라"다.** 인박스에 개별 수정을 백포트하지 않고 NuGet으로
배포하겠다고 못 박았다([discussion #17608](https://github.com/microsoft/terminal/discussions/17608)) —
"terminal emulator authors ... to lock to specific versions and fully vet compatibility with them".
Warp·Zed·Android Studio(pty4j)·WezTerm이 모두 같은 쌍을 번들한다.

`assets/windows/conpty/`에 `Microsoft.Windows.Console.ConPTY` `1.24.260710001`의 x64 쌍을 둔다
(MIT, Authenticode 서명 유효, 1.12 MB). 갱신 절차는 그 폴더의 `README.md`에 있다.

**배치가 계약이다.** NuGet 패키지의 `build/native/*.targets`가 정한 그대로 설치한다:

```
zig-out/bin/
  maru.exe
  conpty.dll          ← 실행 파일 옆
  x64/OpenConsole.exe ← 아키텍처 하위 폴더
```

**틀려도 실패하지 않는다** — `conpty.dll`은 `OpenConsole.exe`를 못 찾으면 시스템 `conhost.exe`로 조용히
되돌아간다. 그래서 `maru win32-terminal-smoke`가 **`conpty=bundled|system`을 찍는다**. 이 줄이 없으면
"배치가 틀린 것"과 "잘 된 것"을 구분할 방법이 없다(이 이식이 계속 경계해 온 "성공처럼 보이는 실패").

**`OpenConsole.exe`가 없으면 `conpty.dll`을 아예 안 쓴다.** 그것만으로는 옛 conhost 로 되돌아갈 뿐인데
`conpty=bundled`라고 보고하면 **거짓말이 된다.** 로드 전에 `x64\OpenConsole.exe` 존재를 확인해 없으면
사유와 함께 `system`으로 접는다 — 그래야 `bundled`가 "새 호스트가 실제로 돈다"를 뜻한다. 실측 3-way:

| 배치 | `conpty=` | `mouse_tracking` |
|---|---|---|
| 둘 다 있음 | `bundled` | `any` |
| `OpenConsole.exe`만 없음 | `system` + 사유 | `none` |
| `conpty.dll`만 없음 | `system` + 사유 | `none` |

가운데 줄이 이 가드의 존재 이유다 — 그 배치에서 마우스가 실제로 안 오는 것을 같이 쟀다.

**초기화를 락으로 감싼다.** 표면 둘이 동시에 spawn 하면 평범한 `bool` 플래그로는 경합이 난다: A가 플래그만
먼저 세우고 `LoadLibrary` 중일 때 B가 "이미 끝났다"고 보고 **kernel32로** HPCON 을 만든 뒤, A가 끝나
포인터를 채우면 **B의 HPCON 을 번들 `Close`가 닫는다**. 위에서 "섞이면 안 된다"고 한 사고가 정확히 그렇게
난다. 초기화가 끝나기 전에는 아무도 지나가지 못하게 한다.

**실행 파일 경로에 디렉터리가 없으면 포기한다.** 그대로 이으면 `conpty.dll`이라는 **상대 경로**가 되어
`LoadLibraryEx`가 CWD 를 뒤진다 — 바로 위에서 막았다고 한 하이재킹이 그 구멍으로 들어온다.

**이름으로 로드하지 않는다.** `LoadLibraryW("conpty.dll")`은 CWD·PATH를 뒤지므로 사용자가 어떤 폴더에서
실행하느냐에 따라 **남의 `conpty.dll`이 붙는다**(DLL 하이재킹). `GetModuleFileNameW`로 우리 실행 파일
경로를 얻어 그 옆의 **전체 경로**로만 연다.

**셋을 한 모듈에서 다 얻지 못하면 하나도 쓰지 않는다.** `Create`/`Close`/`Resize`를 섞으면 — kernel32의
`Close`로 번들이 만든 `HPCON`을 닫는 식 — 그 자리에서 안 터지고 나중에 이상하게 터진다. 공식 DLL은
`Conpty*` 이름과 함께 **kernel32와 같은 이름·시그니처**도 내보내므로 호출부는 그대로다.

**경로가 MAX_PATH를 넘으면 번들을 안 쓴다.** 긴 경로에서 `CreatePseudoConsole`이 죽는 알려진 결함이 있다
([#16860](https://github.com/microsoft/terminal/issues/16860)) — 기능 하나를 잃는 편이 죽는 것보다 낫다.

**파일이 없어도 빌드와 실행이 둘 다 돌아간다.** `build.zig`는 `assets/`가 없으면 설치 단계를 건너뛰고,
런타임은 kernel32로 접는다. 소스 체크아웃과 최소 배포가 계속 가능해야 하기 때문이다. 그리고 이 구조
덕에 **사용자가 더 새 `conpty.dll`을 실행 파일 옆에 덮으면 그것을 쓴다** — 우리 갱신을 안 기다려도 된다.

**실측 A/B**(같은 빌드, `conpty.dll`만 치웠다 넣었다):

| | `conpty=` | `mouse_tracking` | `mouse_format` | 클릭 |
|---|---|---|---|---|
| 번들 `1.24.260710001` | `bundled` | **`any`** | **`sgr`** | **셸 리포트**(`reports=2 selections=0`) |
| 인박스 `10.0.19041.4522` | `system` | `none` | `x10` | 로컬 선택(`reports=0 selections=1`) |

나머지는 같다(`keys_to_shell=20` 양쪽). **§2k의 리포팅 코드는 한 줄도 안 바뀌었다.**

**한계**: 사용자가 `cmd.exe`·`wsl.exe`를 **직접** 띄우면 그쪽은 여전히 시스템 conhost다(#17608에 그대로
적혀 있다). 우리가 spawn하는 셸에만 적용된다. 그리고 지금은 **x64만** 번들한다 — 빌드가
`x86_64-windows`만 겨냥하기 때문이고, arm64를 타깃에 넣을 때 같은 패키지의 arm64 쌍을 함께 넣는다.

## 5. 경로 구분자 — 입구에서 정규화한다

Windows에서 경로는 **모든 출처가 백슬래시로** 들어온다: OSC 9;9의 cwd, PEB의 `CurrentDirectory`(후행
구분자까지 붙는다), 프로세스 열거 결과.

[layering-and-portability.md](layering-and-portability.md) §4.1이 세운 규칙 — *"L2에서 구분자를 만들어
내는 자리는 항상 POSIX 구분자를 쓴다"* — 을 Windows에서는 **입구까지 확장한다**: 플랫폼이 코어로 넘기는
경로는 `/`로 정규화된 상태여야 한다. 안 하면 `file_tree`·`git_ops`·소스 컨트롤이 `/repo\docs` 문제를
그대로 다시 겪는다(그 버그는 이미 한 번 고쳤다).

**그런데 정규화만 하면 안 된다 — 중립 레이어가 "선두가 `/`인가"로 절대경로를 판정하고 있었다.** 적대적 검증과
후속 코드 리뷰에서 **여섯 자리**가 나왔고, 성격이 갈린다. 전부 W1.5에서 `src/path_shape.zig`로 옮겨 닫았다:

| 위치 | 옛 판정 | Windows 경로에서 | 성격 |
|---|---|---|---|
| `session/file_panel_bridge.zig` `normalizeAssetPath` | `raw[0]=='/'`→Absolute, 역슬래시→InvalidCharacter | **가드가 무력화된다** — 아래 | 가드 |
| `session/repo_path.zig` `isSafeRelative` | `path[0]=='/'`이면 절대로 보고 거부 | `C:/x`가 **상대 경로로 통과**했다 | 가드 |
| `session/git_write_command.zig` `validatePath` | 위와 같은 판정, `/`로만 세그먼트 분할 | `..\..\secret`이 `git add --` argv에 실렸다 — **읽기 쪽 쌍둥이만 고쳐 비대칭이 남아 있었다** | 가드 |
| `session/file_tree.zig`·`file_tree_mutation.zig` `pathWithin` | root 포함 판정이 `root=="/"` 특수 케이스를 둠 | 드라이브 루트(`C:/`)에 대응이 없었다 | 가드 |
| `file_tree_mutation.validateName`·`file_tree.validBasename` | 이름 한 칸에서 `/`와 NUL만 거부 | `..\..\evil.txt`가 **통째로 한 이름**이라 `..` 비교를 통과, join되면 루트 밖에 파일이 생겼다 | 가드 |
| `terminal/selection.zig` `filePathSpan` | 링크 감지가 `word[0]=='/'`로 절대경로 판정 | `C:\…`를 절대경로 링크로 못 잡았다(기능 결손) | **감지** |

**`normalizeAssetPath`가 특히 위험했다.** Windows 절대경로를 막고 있던 것은 `raw[0]=='/'`가 아니라
**역슬래시 거부**였다. 입구에서 `\`→`/`로 바꾸면 `C:\Windows\x`가 `C:/Windows/x`가 되어 세 검사(절대·역슬래시·
`..`)를 **전부 통과**하고 "상대 경로"로 받아들여진다. 자산 루트에 이어 붙어 존재하지 않는 경로가 되므로
당장 뚫리지는 않지만, **가드의 의도가 깨진다.**

**따라서 규칙을 둘로 나눈다.**

1. **구분자 정규화는 입구에서** 한다(`\`→`/`). L2가 받는 경로는 POSIX다
   ([layering-and-portability.md](layering-and-portability.md) §4.1). 도구는
   `path_shape.normalizeSeparatorsFor(os_tag, …)`이고 **Windows 기준일 때만 바꾼다** — POSIX에서 `\`는
   파일 이름 글자라 거기서 바꾸면 다른 파일을 가리킨다(W1.5에서 그 부류의 회귀를 한 번 냈다).
   실측: `$HOME`이 `C:\Users\me`일 때 terminfo 캐시가 `C:\Users\me/.cache/…`였고 정규화 후
   `C:/Users/me/.cache/…`가 된다.

   **입구는 셋이고 지금 걸린 것은 하나다.** ⓐ **환경변수**(`$HOME`·`$XDG_CACHE_HOME`) — W3에서 걸었다.
   ⓑ **OS API**(OSC 9;9 cwd·PEB `CurrentDirectory`·프로세스 열거) — 그 소비자가 W4·W7에서 생기므로 그때
   건다. ⓒ **config 파일** — **아직 안 걸렸다**(아래).

   > **닫혔다 — W7.5에서 ⑴(로더)로 정했다.** 근거는 이 규칙 자신이 "입구에서"라고 못 박은 것이다. ⑵
   > (소비처마다)는 같은 규칙을 흩어 놓아 **한쪽만 고쳐지는 부류**를 만든다 — 같은 슬라이스에서 고친
   > 루트 스트라이핑(§5.2 ⒝)이 정확히 그 사고였다.
   >
   > 경로 키가 세 자리에 흩어져 있어 표식을 스키마 1급으로 올렸다. `Meta.path_value`를 더하고
   > **`abs_path`가 그것을 함의**하게 했다 — 둘을 따로 적게 두면 한쪽만 붙이는 실수가 조용히 정규화를
   > 건너뛴다. 걸린 곳은 `shell.command`(함의)·`window.background-image`(신규 표식)·`workspace.root`
   > (명시 핸들러라 같은 헬퍼를 직접 부른다) 셋이다.
   >
   > POSIX 호스트에서는 무동작이다. 판정은 `path_shape.normalizeSeparatorsFor(os_tag, …)`가 소유하므로
   > 두 갈래가 모든 타깃에서 테스트된다. 경로가 **아닌** text 필드(`input.word-separators`)는 안 건드리는
   > 것도 테스트가 고정한다 — `\`를 값으로 쓰는 설정이 깨지면 안 된다.
   >
   > **UNC 가 깨지지 않는지 재 봤다 — 안 깨진다.** `\\server\share`의 앞 역슬래시는 구분자가 아니라
   > 접두 문법이라 정규화가 그것을 `//server/share`로 바꾸는데, Win32 가 그것을 받는지가 의심스러웠다.
   > 측정 결과 `GetFullPathNameW`·`GetFileAttributesW` 둘 다 받는다 — `//localhost/C$/Windows`가
   > `\\localhost\C$\Windows`로 정규화되고 존재 판정도 통과한다(드라이브 경로·혼합 경로도 같다).
   > 한때 여기서 **"OS 경계에서 native 로 되돌리는 변환을 두지 않는다"**고 정했다. 근거는 위 실측이었고
   > 실측 자체는 지금도 맞다 — 다만 **파일 API 만 봤다.** 아래가 그 문장을 대체한다.
   >
   > ### 되돌림은 예외가 아니라 **다른 층**이다 (W7.6b 결정, 실측 2026-08-19·20)
   >
   > **규칙 1 과 충돌하지 않는다.** 규칙 1 은 *"중립 레이어가 무엇을 보는가"* 이고, 되돌림은
   > *"OS 를 부를 때 무엇을 넘기는가"* 다. 두 문장이 같은 대상을 두고 싸우는 것처럼 보였던 것은
   > 그 부칙이 층을 안 나누고 "경계에 변환을 두지 않는다" 라고 적었기 때문이다.
   >
   > **계기.** `shell.command` 를 실제로 spawn 까지 배선하자(§3.1a) 정규화된 `C:/…` 가
   > `CreateProcessW` 의 `lpCommandLine` argv\[0\] 으로 갔고 **cmd.exe 가 자기 이름을 못 풀고 죽었다.**
   > cmd 는 커맨드라인을 CRT argv 규칙으로 파싱하지 않는다(§4.2) — 같은 이유의 다른 얼굴이다.
   > 변수를 하나씩 바꿔 가며, "살아 있는가" 가 아니라 `echo MARU-OK` 출력을 파이프로 읽어 **실제로
   > 도는가**로 잰 것:
   >
   > | 셸 | `argv[0]=C:\…`(native) | `argv[0]=C:/…`(정규화) |
   > |---|---|---|
   > | `cmd.exe` | `MARU-OK` | **exit=1 "지정된 경로를 찾을 수 없습니다"** |
   > | `pwsh 7` | `MARU-OK` | `MARU-OK` |
   > | `PowerShell 5.1` | `MARU-OK` | `MARU-OK` |
   >
   > `lpApplicationName`·`lpCurrentDirectory` 는 어느 쪽이든 `/` 를 받는다(따로 실측) — 깨지는 것은
   > **argv\[0\] 한 자리**이고 **cmd 하나**다.
   >
   > **이것은 우리 정규화 탓이 아니다.** `C:/Windows/System32/cmd.exe` 는 Windows 에서 완전히 정상인
   > 경로이고 사용자가 config 에 그렇게 적을 수 있다. 정규화를 아예 안 해도 그 사용자는 깨진다.
   > 즉 되돌림은 **우리가 만든 문제를 되돌리는 것이 아니라 사용자 입력의 다양성을 받는 자리**다.
   >
   > #### 선례 셋이 같은 것을 가리킨다
   >
   > | 근거 | 무엇을 하나 |
   > |---|---|
   > | **.NET `Process.Start`** (이 기기 실측) | 부모가 `C:/…/powershell.exe` 를 줘도 **자식이 보는 argv\[0\] 은 `C:\…`** 다 — 역슬래시로 준 경우와 바이트가 같다 |
   > | **VS Code `URI.fsPath`** | `URI.path` 는 **항상 `/`**(내부 표현), `fsPath` 가 OS 경계용이고 그 구현이 `if (isWindows) value = value.replace(/\//g, '\\')` 다 |
   > | **node-pty**(VS Code 터미널이 쓰는 ConPTY 층) | `argsToCommandLine` 이 `const argv = [file]` 로 **셸 경로를 그대로** argv\[0\] 에 넣는다 — 구분자를 안 바꾼다. 앞 계층(`fsPath`)이 이미 했다고 전제한다 |
   >
   > 사슬이 우리와 같다:
   >
   > ```text
   > VS Code   URI.path (/)      →  .fsPath (native)        →  node-pty (그대로)      →  CreateProcess
   > maru      중립 레이어 (/)    →  toNativeSeparatorsFor   →  buildCommandLine (그대로) →  CreateProcess
   > ```
   >
   > 차이는 **변환이 어디 사는가**뿐이다 — VS Code 는 URI 클래스 안, maru 는 spawn 호출부. 우리가 이
   > 자리를 직접 만난 이유는 ConPTY spawn 때문에 `lpCommandLine` 을 **손으로 조립**하기 때문이다.
   > 런타임(.NET·Node)을 쓰면 그 계층이 대신 해 주는 일을, 런타임이 없으니 우리가 한다.
   >
   > #### 조건 — 되돌림 자리는 **하나**다
   >
   > `pty/windows.zig` 의 spawn 이 유일하다. 늘리지 않는 것이 이 결정의 조건이고, 늘리고 싶어지면
   > 그것은 "그 값이 애초에 정규화 대상이 아니었다" 는 신호일 가능성이 높다 — 아래를 먼저 물어라.
   >
   > **`abs_path` 가 `path_value` 를 함의하는 것은 근거가 약하다(미결).** 두 표식은 다른 질문에 답한다 —
   > `abs_path` 는 *"절대경로여야 하는가"*(검증), `path_value` 는 *"L2 가 이 경로를 조작하는가"*(정규화).
   > `shell.command` 은 절대경로지만 **L2 가 조작하지 않는다**(소비자 넷이 전부 잇거나 비교하지 않고 OS 로
   > 넘긴다 — 실측). W7.5 가 "둘을 따로 적으면 한쪽만 붙이는 실수가 난다" 며 함의를 넣었는데 그 전제
   > (모든 `abs_path` 는 조작된다)가 틀렸다. 함의를 빼도 **spawn 되돌림은 그대로 필요하다**(위 "우리
   > 정규화 탓이 아니다"), 그래서 지금은 무해하다. 판단 근거가 `shell.command` 하나뿐이라
   > `window.background-image`·`workspace.root` 의 조작 여부를 실제로 확인하는 **W8.2 와 함께** 정리한다.
2. **"절대경로인가" 판정은 `[0]=='/'`를 쓰지 않는다.** 드라이브 절대(`X:`)와 UNC(`//`)를 명시적으로 함께
   판정한다. 정규화 이전에 역슬래시로 거르던 가드는 **정규화 이후에도 같은 것을 막도록 다시 쓴다.**

이 여섯 자리를 고치는 것은 W3와 별개 슬라이스(**W1.5**, 완료)였고, 순서상 **정규화를 도입하기 전에** 했다 —
반대로 했으면 `normalizeAssetPath`가 잠깐 느슨해진 창이 생겼다. 이제 W3가 정규화를 도입할 수 있다.

### 5.1 가드와 감지는 술어가 다르다 (W1.5 결정, 2026-08-15)

네 자리가 같은 증상을 보였지만 **묻는 질문이 다르다.** 그래서 `src/path_shape.zig`가 술어를 **둘** 내놓는다.

| | 가드 (`isAbsolute`) | 감지 (`isDetectableAbsoluteFor`) |
|---|---|---|
| 질문 | "이 문자열이 **어떤 OS에서든** 위험한가" | "이 문자열이 **그 OS에서** 실제로 열리는 경로인가" |
| 문자열을 고르는 쪽 | 공격자(적대적 저장소·이상한 git 출력·사용자 입력) | 그 OS의 파일시스템 |
| 틀렸을 때 | 루트 밖 파일이 읽히거나 쓰인다 | 열리지 않는 밑줄이 뜬다 |
| 그래서 | **OS 무관하게 넓게 거부** | **주어진 OS 기준으로 좁게 감지** |
| 쓰는 곳 | `repo_path`·`git_write_command`·`pathWithin`·`validateName`·`normalizeAssetPath` | `terminal/selection.zig` |

**감지가 OS를 인자로 받는 근거**: 밑줄 span은 **콘텐츠를 가진 쪽**이 만든다. 원격 세션도 host가
`selection.collectViewportLinks`로 span을 모아 client에 보낸다(로컬 hover와 같은 분류기). 지금 호출자는
호스트 OS만 넘기지만, 그 값이 **파라미터**라서 두 가지가 따라온다. ⑴ 테스트가 두 OS를 모두 돌 수 있다 —
CI에 Windows 러너가 없으므로(ubuntu-latest·macos-15), 컴파일 타임 분기였다면 Windows 단언이 통째로
**공허참**이 된다. ⑵ ssh 원격 OS를 반영할 때 소비자를 다시 배선하지 않아도 된다(아래).

VS Code도 같은 규칙을 런타임 값으로 구현한다 — `terminalLocalLinkDetector.ts`의
`detectLinks(text, this._processManager.os || OS)`는 클라이언트가 아니라 **백엔드/PTY의 OS**를 쓴다.

**호스트 OS ≠ 콘텐츠 OS인 경우(알려진 한계)**: `maru ssh`는 ssh를 **로컬 pty**에서 돌리므로 화면 내용은
원격 OS의 것인데 감지는 로컬 OS 기준으로 돈다. `TerminalCore.sshRemoteDest()`(OSC 5379)가 그 사실을 이미
추적하고 있으니 seam은 있다. 지금 그 값을 쓰지 않는 이유는 **plain ssh에서는 어차피 링크가 열리지 않기**
때문이다 — 파일이 로컬에 없어 존재 게이트가 막는다. 감지해 봐야 밑줄만 늘어난다. 반대로 host-backed 원격
세션(`runtime.link_at`)은 host가 자기 core로 resolve하므로 지금 구조가 맞다. 그러므로 이건 **결손이 아니라
비용-편익 판단**이었다. hover 존재검증이 들어온 지금(§5.1a) 그 판단은 **더 강해졌다** — plain ssh는 경로
scope가 애초에 꺼져 있고(`linkScopesForTerm`), 켠다 해도 로컬에 없는 파일이라 밑줄조차 뜨지 않는다.

**감지 술어가 `isAbsolute`보다 좁은 이유**(실측). 감지된 토큰은 `TerminalCore.resolveClickedPath`로 가고,
거기서 `std.fs.path.isAbsolute`가 거짓이면 **cwd에 join**된다. 감지가 그보다 넓으면 "밑줄은 뜨는데 엉뚱한
파일을 연다"가 된다. Windows에서 잰 불일치:

| 토큰 | `path_shape.isAbsolute` (가드) | `std.fs.path.isAbsolute` | 감지하는가 |
|---|---|---|---|
| `C:\x`·`C:/x` | true | true | **예** |
| `C:relative` | true | **false** | 아니오 — join되면 엉뚱한 경로 |
| `a:b` | true | **false** | 아니오 — 흔한 토큰이라 오탐 |
| `\foo\bar` | true | true지만 `resolve`가 **드라이브 없는** `\foo\bar` 산출 | 아니오 |
| `\\server\share`·`//server/share` (UNC) | true | true | **아니오 — 알려진 공백**(이스케이프 출력 오탐 위험, 터미널에서 드묾. VS Code도 `\\?\C:` 확장형만 다룬다) |

그래서 감지는 **드라이브 + 구분자**(`C:\`·`C:/`)만 본다. VS Code의 `winDrivePrefix`도 같은 모양이다.
UNC 배제는 **술어가 직접** 한다 — 한때 호출자의 `!startsWith("//")`가 `//server/share`를 막고 있어서 술어의
문서와 반환값이 어긋나 있었고, 두 번째 소비자가 문서만 읽고 부르면 규칙이 갈릴 자리였다.

**드라이브 문자를 A–Z로 제한하지 않는다.** Win32는 그런 제한을 두지 않는다 — `RtlDetermineDosPathNameType_U`를
모사하는 `std.fs.path.getWin32PathType`도 아무 코드포인트나 받아서 `1:/x`·`λ:\x`·`::/x`가 전부 절대다(실측).
**가드가 OS 파서보다 좁으면 그 차이가 그대로 우회로다** — 처음 구현은 `isAlphabetic`을 요구해서 `1:/Windows/x`가
`repo_path`를 상대경로로 통과했다. 그래서 문자 종류를 묻지 않고 첫 코드포인트 뒤가 `:`인지만 본다. 감지도 같은
파서를 쓴다(다른 파서를 쓰면 그 간극이 다시 우회로가 된다).

**남은 비대칭(알려진 것)**: Windows에서 `/foo/bar`는 계속 감지하는데, Win32에서 그것은 `\foo\bar`와 **같은
종류**(`.rooted`)라 위에서 `\foo\bar`를 뺀 이유가 그대로 적용된다(실측: 둘 다 `isAbsWin=true`, 둘 다
`resolve`가 드라이브 없는 `\foo\bar`를 낸다). 그럼에도 남긴 것은 Windows 터미널에 git-bash·MSYS·WSL 출력으로
POSIX 모양이 흔히 뜨기 때문이다. 대가는 그 링크의 `access`가 터미널의 cwd 드라이브가 아니라 **프로세스의 현재
드라이브**에 묶인다는 것이다. 좁히는 쪽이 나은지는 실기 Windows 세션에서 그 출력이 얼마나 흔한지를 보고 정한다.

**macOS가 왜 불변이어야 했는가**(당시 근거): hover 밑줄은 매-mouseMove 비용 때문에 **존재검증을 하지 않았고**
(존재검증은 클릭에서만), 그래서 **감지 단계가 유일한 방어선**이었다 — macOS에서 `C:\x`를 감지하면 "밑줄은 뜨는데
클릭하면 아무 일도 없는" 상태가 100% 확정된다. 이후 hover에도 존재검증을 넣었으므로(§5.1a) 방어선은 두 겹이
됐지만, OS 인자 규칙은 그대로 둔다 — 안 그러면 `C:\x` 모양이 실재하는 파일과 우연히 겹칠 때 macOS에서 열린다.

**실측 (2026-08-15, Windows 10.0.19045)** — 같은 PoC를 고치기 전/후로 돌린 결과:

| 화면 문자열 | 전 (hover / click) | 후 (hover / click) |
|---|---|---|
| `C:\…\scratchpad\poc_linkdetect.zig` (**실재**) | ✗ / ✗ | **○ / ○** |
| `C:\…\scratchpad` (**실재 디렉터리**) | ✗ / ✗ | **○ / ○** |
| `C:\Users\me\proj\main.zig` (없음) | ✗ / ✗ | ○ / ✗ |
| `/Users/me/proj/main.zig` (없음) | ○ / ✗ | ○ / ✗ (불변) |

마지막 줄이 중요하다 — **"밑줄 O / 열림 X"는 새 상태가 아니다.** 존재하지 않는 POSIX 절대경로가 오늘도 그렇다.
Windows 경로가 다른 점은 macOS에서 그것이 *우연*이 아니라 *확정*이라는 것뿐이고, 호스트 OS 분기가 그것을 없앤다.

**부수 실측**: `std.c.access(F_OK)`가 Windows에서 정상 동작한다(존재 `0`, 미존재 `-1`). 존재 게이트는 W7에서
그대로 산다.

**알려진 오탐 — 의도적으로 남긴다.** 실제 도구 출력 21종을 훑어 6건이 나왔다: `n:\t`(한 글자 라벨 +
이스케이프 탭), `y:\`·`x:/`·`0:/`(드라이브 루트), `::/x`·`-:/x`(비알파벳 드라이브). 반대로 걸러진 것:
`12:30:45`, `1:30`, `3:15/4`, `a:b`, `ERROR:`, `NOTE:\n`, `C:relative`, `\\.\pipe\maru`, `:\x`, `warning:`,
`-rw-r--r--`, `http://h:8080/p` — **드라이브가 코드포인트 하나여야 하고 뒤에 구분자가 와야 한다**는 제약이
대부분을 막는다.

남긴 이유가 셋이다. ⑴ **대칭** — POSIX 감지도 같은 등급의 오탐을 낸다(`/t`, sed의 `/foo/bar/`). Windows
쪽만 좁히면 "왜 `/t`는 밑줄이 뜨는데 `C:\t`는 안 뜨나"가 설명되지 않는다. ⑵ **이것들은 Win32가 실제로
절대경로로 보는 문자열이다**(실측: `isAbsoluteWindows("::/x") == true`). 감지가 틀린 게 아니라 그 모양이
드물 뿐이다. ⑶ 좁히면 감지가 가드와 다른 파서를 쓰게 되고, 그 간극이 위에서 닫은 우회로를 다시 연다.

실제 피해(엉뚱한 파일 열기)는 두 겹이 막는다 — **부분집합 불변식**(감지 ⊆ `std.fs.path.isAbsolute`, 이제
테스트가 단언한다)이 cwd 오join을 막고, **존재 게이트**가 클릭을 막는다. 밑줄만 뜨고 클릭하면 아무 일도 없다.
**근본 해결은 hover에도 stat을 두는 것**(VS Code 방식)이었고, **그걸 했다**(§5.1a) — 위 오탐 6건은 그 경로가
그 기계에 실제로 있을 때만 밑줄이 뜬다(보통은 `Y:`·`N:` 드라이브가 없어 즉시 떨어진다. `::/x`·`-:/x`는 유효한
드라이브 이름이 아니라 항상 떨어진다). 감지 규칙 자체는 위에 적은 세 이유로 그대로 둔다.

**다른 터미널** (동작만 비교 — clean-room): VS Code는 백엔드 OS로 파싱하고 밑줄 **전에** 존재검증까지 한다.
WezTerm은 맨 파일 경로 링크를 지원하지 않는다(정규식 `hyperlink_rules`만, [issue #6257](https://github.com/wezterm/wezterm/issues/6257) 열림).
iTerm2는 Semantic History가 macOS 전용이라 이 문제가 없다.

### 5.1a hover도 존재검증을 한다 (결정 완료)

밑줄이 뜨는데 클릭하면 아무 일도 없는 상태 — 위 "알려진 오탐"이 남긴 잔여물이자, Windows 이전부터 macOS에
있던 것이다 — 를 닫았다. hover가 `selection.urlAnchorAt`(**분류만**) 대신 `TerminalCore.openableLinkAnchorAt`
(추출 → `resolveClickedPath` → stat, **클릭과 같은 술어**)를 부른다. URL은 그대로 통과하고, 경로만 실재할 때
밑줄이 뜬다.

미루어 뒀던 이유가 "매-mouseMove 비용"이었으므로 그 비용을 쟀다. **처음 잰 것은 stat 한 겹이었고 그 숫자는
제품 비용을 대표하지 않았다** — 적대적 검증에서 잡아 다시 쟀다. 아래는 `openableLinkAnchorAt` **호출 전체**를
잰 값이다(Windows 10.0.19045, D: 로컬 SSD, 400회 평균):

| hover 1회 | 변경 전(`urlAnchorAt`) | 변경 후 | 120Hz 이동 간격(8333 µs) 대비 |
|---|---|---|---|
| 링크 아님 — **대부분의 마우스 이동** | 2.0 µs | **2.0 µs** | 0.02 % |
| URL | 3.8 µs | **38.0 µs** | 0.46 % |
| 실재 경로 | 11.6 µs | **114.7 µs** | 1.38 % |
| 없는 경로 | 14.0 µs | **118.1 µs** | 1.42 % |

**stat 자체는 그중 3 %뿐이다**(`GetFileAttributesW` 3.5 µs). 나머지는 토큰 수집(`extractUrlAt`)과 정규화
(`std.fs.path.resolve` 23.9 µs)다. 즉 이 슬라이스가 더한 비용은 "디스크를 만져서"가 아니라 "분류만 하던 것을
추출까지 하게 해서" 생긴다. 두 겹의 완화가 있다 — ⑴ **링크가 아닌 단어에서는 비용이 0**이다(`urlAnchorAt`이
먼저 null을 내고 할당도 0회), ⑵ **수식키를 누른 동안에만** 돈다(`urlModifierHeld` 게이트).

**느려지는 경우.** UNC 죽은 호스트 **755 ms**, 라우팅 불가 IP **11 s**. 그런데 `isDetectableAbsoluteFor`가
`\\`로 시작하는 토큰을 감지에서 이미 떨어뜨리므로 stat까지 **도달하지 않는다**. 원격 세션은 `linkScopesForTerm`이
네 경로 scope를 전부 끄므로 host 왕복(`collectViewportLinks`)에도 새 비용이 붙지 않는다.

**꼬리 지연(합성 최악).** 화면을 가득 채운 한 토큰(9 KB, 45줄)이 경로 모양이면 hover 1회가 **3.29 ms**다
(변경 전 0.84 ms). `wordBoundsAt`이 공백으로만 토큰을 가르기 때문이다. **실제 출력에서는 재현되지 않았다** —
minified JSON 한 줄(720 B) 137.5 µs·data URI 29.2 µs는 분류에서 걸러져 **변경 전과 차이가 0**이고, `/`를 품어
분류를 통과하는 JWT(155 B)도 131.4 µs다. 그래서 지금은 완화를 두지 않고 이 상한만 기록한다.

**두지 않은 완화(기록).** 같은 anchor 위에서 마우스가 흔들릴 때 매번 전부 다시 계산한다 — 실측상 그 반복의
**89 %**(93.8 µs)가 1-entry 캐시로 사라진다. 절대값이 이동 간격의 1.4 %라 지금은 복잡도를 사지 않았다.
느린 FS가 확인되면 여기가 첫 수단이다.

**남은 미지수**: 매핑돼 있으나 연결이 끊긴 네트워크 드라이브(`Y:` → 죽은 서버)는 재지 못했다. 그 경로는 로컬
드라이브 문자로 보이므로 감지를 통과한다.

**존재검증은 OS마다 다른 API를 쓴다 — 인코딩 계약이 다르기 때문이다.** POSIX는 `std.c.access(F_OK)`,
Windows는 **`GetFileAttributesW`(UTF-16)** 다. CRT의 `_access`는 바이트 경로를 UTF-8이 아니라 **ANSI
코드페이지**로 읽는다. 실측(이 기계 ACP=949) — 이름만 바꾼 디렉터리 넷을 만들어 물었다:

| 디렉터리 이름 | Win32(UTF-16) | CRT `_access` | 고치기 전 제품 밑줄 | 고친 뒤 |
|---|---|---|---|---|
| `maru-ascii-9e1f` | 있음 | 있음 | O | O |
| `maru-café-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-한글-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-日本-9e1f` | 있음 | **없음** | **X** | **O** |
| `maru-🙂-9e1f` | 있음 | **없음** | **X** | **O** |

즉 **비-ASCII 이름이 든 경로는 클릭해도 안 열리고 밑줄도 안 떴다.** 이것은 hover 슬라이스가 만든 결함이 아니라
`resolveClickedPath`가 처음부터 갖고 있던 것인데(클릭이 이미 그 경로를 썼다), hover가 같은 술어를 쓰게 되면서
노출이 커져 적대적 검증에서 잡혔다.

**교체가 다른 답을 바꾸지 않았다는 것은 코퍼스로 확인했다.** 일화 몇 개가 아니라 `src/` 아래 실제 경로를 훑어
같은 경로를 두 API에 물었다 — **600건 대조에서 갈린 건수 0**이고(실재 300건·같은 경로에 없는 접미를 붙인 300건),
제품 경로로도 실재 파일 120건 중 밑줄이 안 뜬 것이 0건이다. 손으로 고른 경계 사례(뒤에 붙은 점 `build.zig...`,
대문자 `BUILD.ZIG`, 와일드카드, 예약 장치 이름 `C:\NUL`)에서도 두 API가 같은 답을 낸다 — 그 셋의 동작은
Win32가 정하는 것이라 CRT를 거치든 아니든 같고, 따라서 **이 슬라이스가 바꾼 것이 아니다**(`C:\NUL`이 경로로
resolve되는 것은 이전부터 그랬다). 비용도 같은 자릿수다(3.5 µs 대 3.6 µs).

같은 종류의 노출이 다른 곳에도 있는지 훑었는데, 바이트 경로를 쓰는 `std.c.*` 호출은 전부
`platform/macos/**`(UTF-8이 맞는 곳)이거나 W2가 Windows에서 막아 둔 `install-cli`였다 — 클래스가 닫혔다.

불변식은 테스트 둘이 지킨다 — `src/terminal/core.zig`의 *"hover와 클릭이 같은 답을 낸다 — 존재검증까지"* 가
실재/부재 경로에서 두 답이 어긋나지 않는지 단언하고, *"존재검증은 비-ASCII 이름이 든 경로를 놓치지 않는다"* 가
위 표를 고정한다(뒤엣것은 임시 디렉터리를 실제로 만들어 확인하므로 **두 OS 모두에서 돈다** — Windows 러너가
없어도 macOS/Linux CI가 계약의 절반을 지킨다).

**뒤따르는 효과**: §5.2 ⒜의 `bare_relative`(⑴)를 켤 수 있게 됐다. 스트레스 코퍼스에서 실경로 8건 / 오탐 5건이
나왔는데, 그 5건이 전부 실재하지 않는 토큰이라 이제 밑줄이 뜨지 않는다.

### 5.2 W1.5가 닫지 않은 것 (실측으로 재현됨)

코드 리뷰에서 나와 **재현까지 확인했지만** 이 슬라이스에서 고치지 않은 것들이다. 성격이 달라 따로 다룬다.

**⒜ 상대 경로 링크는 Windows에서 여전히 안 잡힌다.** `filePathSpan`의 네 갈래 중 절대만 OS-인지로 만들었다.
나머지 셋은 `/`를 요구한다 — `home_path`는 `~/`, `dot_relative`는 `./`·`../`, `bare_relative`는 토큰에 `/`가
있을 것. 실측:

| 토큰 | 감지 | (대조) POSIX 형태 | 감지 |
|---|---|---|---|
| `.\build.zig` | ✗ | `./build.zig` | ○ |
| `..\lib\y.rb` | ✗ | `../lib/y.rb` | ○ |
| `src\main.zig` | ✗ | `src/main.zig` | ○ |
| `~\notes.md` | ✗ | `~/notes.md` | ○ |

MSBuild·cmd·PowerShell·zig 자신의 에러 출력이 다 이 모양이라 **절대 경로 하나만 밑줄이 뜨고 옆의 상대 경로는
전부 죽어 있다.** 절대보다 오히려 흔한 형태다.

여기서 멈춘 이유: `bare_relative`의 오탐 억제가 *"슬래시 필수 + 점 필수 + 첫 세그먼트 문자집합"*이라
역슬래시를 넣으면 **이스케이프 출력(`\n`·`\t`)과 정면충돌**한다. **별도 슬라이스(W5.5)**로 둔다.

**그 오탐 스윕을 했다 (2026-08-16). 결론: 갈래마다 답이 다르다.**

후보 규칙을 같은 집합(누적 약 35건 — 실제 msbuild·zig·PowerShell·node 출력 형태 + 정규식·이스케이프 조각)에
차례로 돌렸다. 각 후보는 앞 후보가 깨진 자리를 메우려고 만든 것이다.

| 후보 | 오탐 | 미검출 | 왜 버렸나 |
|---|---|---|---|
| `\`를 그냥 구분자로 | 10 | 0 | `a\nb.txt`·`col\tvalue.csv`·`.\d+\.\d+`가 전부 링크가 된다 |
| `\` 뒤 이스케이프 글자 억제 | 0 | 2 | 억제 목록이 **흔한 디렉터리 이름과 충돌**한다 — `lib\std\…`(`\s`)·`tests\a.…`(`\a`)를 잃는다 |
| 나머지에 점·구분자 필수 | 0 | 3 | **POSIX 회귀** — 지금 잡히는 `./configure`를 잃는다 |
| 역슬래시 접두에만 위 규칙 | 4 | 2 | 점을 품은 정규식(`.\d+\.\d+`)이 뚫는다. 게다가 무확장 형태(`.\src`·`.\build`)를 **9/9 전부** 잃어 POSIX 형태와 비대칭이 생긴다 |
| **세그먼트 규칙**(아래) | **0** | **0** | 채택 후보 |

**채택 규칙 — 오탐의 공통 모양은 하나였다: `\` 뒤가 *알파벳 한 글자*(+선택적 수량자)다.**
`\d`·`\w`·`\s`·`\S`·`\n`·`\d+`·`\s*`·`\d{2,4}`·`\p{L}`가 전부 그 모양이고, 진짜 경로 세그먼트는
`src`·`build`·`Makefile`처럼 두 글자 이상이다. 그래서 규칙은 **"세그먼트가 알파벳 한 글자이거나
알파벳+수량자면 거부"** 하나면 된다. POSIX 접두는 손대지 않아 회귀가 0이고,
`.\src`·`.\Makefile`·`.\file(1).txt`·`.\한글\파일.txt`가 전부 살아남는다.

> **처음엔 "정규식 클래스 글자 목록"이었다.** 구현 뒤 적대적 검증이 그 목록의 구멍을 **11개** 찾았다 —
> 16진(`x`+두 자리)·유니코드(`u`+네 자리)·`e`·`c`+글자·`k`+숫자·`Q`·`h`·`R`·`N`이 전부 통과했다. 목록을
> 늘리는 대신 조건을 "알파벳 한 글자"로 넓혔다: 오탐이 11→4로 줄고, 잃는 것은 한 글자 디렉터리 이름이
> 20자에서 26자로 늘어나는 것뿐이다. **임의로 고른 목록이 규칙으로 바뀐 것**이 진짜 이득이다.
> 남는 구멍(한 글자 뒤에 수량자가 아닌 것이 붙는 모양)은 `path_shape.isEscapeLikeSegment`의 doc에 적었다.

**그런데 이 규칙은 `bare_relative`에는 안 통한다**(실측: 4건 중 3건 오탐). 거기서는 이스케이프가 그럴듯한
첫 세그먼트 **뒤에** 오고(`a\nb.txt`·`col\tvalue.csv`) 나머지가 평범한 파일명 모양이라, 세그먼트만 봐서는
구별할 수 없다. 그래서 W5.5는 이렇게 갈린다:

| 갈래 | 상태 |
|---|---|
| `dot_relative`(`.\x`·`..\x`)·`home_path`(`~\x`) | **닫혔다.** 위 세그먼트 규칙으로 오탐 0·미검출 0, W5.5에서 구현했다 |
| `bare_relative`(`src\main.zig`) | **닫혔다.** 감지 단계에는 여전히 규칙이 없지만(아래) **존재 게이트**가 뒤를 받아 ⑴로 갔다 — 실측은 이 절 끝 |

**`bare_relative`에 규칙이 없는 이유는 구조다.** 후보를 더 세게 잡아 봐도(확장자 화이트리스트: 오탐 3/4)
안 갈린다. 세그먼트로 갈라 보면 왜인지가 그대로 보인다:

```text
src\main.zig      → [src][main.zig]      ← 잡아야 하는 것
line1\nline2.log  → [line1][nline2.log]  ← 막아야 하는 것
```

**모양이 같다.** 첫 세그먼트 길이도, 마지막 세그먼트의 확장자(`.log`·`.csv`·`.txt`는 전부 진짜 확장자)도
구별에 못 쓴다. 둘을 가르는 것은 "앞 문맥에서 이 `\n`이 이스케이프였는가"인데, 감지는 **토큰 하나만** 본다.
접두 갈래가 되는 이유도 여기서 나온다 — `.\`·`..\`·`~\`는 이스케이프가 만들 수 없는 시작 모양이다.

남은 갈래는 둘이었다. **⑴ Windows에서만 받고 오탐을 감수한다**(터미널에 찍힌 이스케이프 문자열이 밑줄 뜨고
클릭 가능해진다) **⑵ 지금처럼 POSIX 철자만 둔다**. W5.5는 ⑵ 상태로 끝냈다 — 규칙이 없는 쪽을 임의로
켜지 않는다.

**⑴로 갔다 (§5.1a 뒤).** 위 판단은 **감지가 마지막 방어선이던 때**의 것이다. hover에도 존재검증이 들어온
뒤(§5.1a) 물음이 바뀐다 — "규칙으로 가를 수 있는가"가 아니라 **"규칙 없이 받아도 밑줄이 뜨는 오탐이 남는가"** 다.
이전 세션이 실제 도구를 돌려 캡처해 둔 코퍼스(`zig` 빌드 에러·PowerShell·git·이스케이프 출력, 규칙보다 먼저
수집된 것)를 통째로 훑어 쟀다:

| | 값 |
|---|---|
| 훑은 토큰 | 369 |
| 지금 규칙(POSIX 철자만)으로 밑줄 | 16 |
| ⑴로 밑줄 | 19 |
| **새로 뜬 것** | **3 — `src\main.zig:10:5`, `src\pty\types.zig:372:11`, `.zig-cache\o\…\build.exe`** |
| **밑줄 뜬 오탐** | **0** |

새로 뜬 셋이 다 진짜 경로이고, 그중 하나가 **zig 컴파일 에러의 상대 경로**다 — 이 갈래에서 가장 값진 사례다.
이스케이프 출력(`line1\nline2.log`·`col\tvalue.csv`)은 감지는 통과하지만 그런 파일이 실재하지 않아 존재
게이트에서 떨어진다. **규칙이 가르지 못하는 것을 존재가 가른다.**

**분류가 지켜야 할 것 하나 — 접두 형태는 접두 갈래가 소유한다.** `.\`·`..\`·`~\`로 시작하는 토큰은 bare가
재판정하지 않는다. 안 그러면 `detectableRelativePrefixFor`가 이스케이프로 보고 거부한 `.\d+`가 이 갈래로
흘러들어 분류를 통과한다 — 기존 테스트 *"linkSpanInWord classifies extra schemes and file paths"* 가 구현
중에 정확히 그것을 잡았다. 감지 종류 우선순위표가 이미 `dot_relative`를 `bare_relative`보다 구체적이라고
정해 둔 것과 같은 규율이다.

**세그먼트 규칙(`isEscapeLikeSegment`)을 bare에도 거는 안은 실측으로 버렸다.** 처음엔 그쪽으로 구현했는데,
적대적 검증에서 `docs\x\y.md`가 죽는 것이 보여 둘을 코퍼스로 견줬다:

| | 세그먼트 규칙 | 접두 소유 규칙(채택) |
|---|---|---|
| 저장소 실제 상대 경로 539건 중 손실 | 0 | 0 |
| 위 캡처 코퍼스에서 잃는 진짜 경로 | **1** (`.zig-cache\o\…` — 한 글자 디렉터리) | 0 |
| 기존 테스트의 정규식 조각 4종 차단 | ○ | ○ |

**더 좁은 규칙으로 같은 것을 얻는다.** 남는 이스케이프(`line1\nline2.log`)는 어느 규칙으로도 감지에서 못
가르고, 존재 게이트가 가른다.

**POSIX 회귀 0**: `os_tag`가 Windows가 아니면 구분자 집합이 `/` 하나이고 접두 소유 규칙도 걸리지 않는다.
술어는 `path_shape.looksLikeBareRelativeFor`가 소유하고 **OS를 인자로** 받아 두 갈래가 모든 타깃에서
테스트된다.

> **측정의 한계**(구현 전 스윕 당시): 그때 수치는 규칙을 **재구현해** 잰 것이었다. 코퍼스도 손으로 모은
> 것이라 완전하지 않았다 — 실제로 이 스윕에서 두 번, **규칙을 만든 뒤에 사례를 고르는 편향** 때문에
> "오탐 0"이 나왔다가 다음 라운드에 깨졌다.
>
> **⑴을 구현할 때 그 둘을 갚았다.** 위 코퍼스 표는 ⒜ 출하되는 술어(`looksLikeBareRelativeFor`)를 직접 몰아
> 냈고, ⒝ 코퍼스는 **규칙보다 먼저** 실제 도구를 돌려 캡처해 둔 것이라 편향이 들어갈 자리가 없다. 규칙
> 후보 둘을 견준 표도 같은 코퍼스와 저장소 실제 경로 539건에서 나왔다.

**⒝ 루트 스트라이핑 두 곳이 구분자를 정확히 한 바이트로 가정한다.**
`platform/macos/file_tree_mutation_backend.zig:336`의 `parent_path[root.len + 1 ..]`와
`file_tree_backend.zig:354`의 같은 모양이다. 루트가 `/`일 때 `parent_path[2..]`가 되어 첫 세그먼트가 잘린다
(`/Users/x` → `sers/x`). **이 커밋 이전부터 있던 버그**이고 macOS 코드라 W1.5 범위 밖이지만, `pathWithin`이
받아들이는 "구분자로 끝나는 루트"의 집합이 `{/}`에서 `{/, C:/}`로 넓어졌으므로 **백엔드를 이식할 때 반드시
함께 고쳐야 한다**(W7). `endsWithSep`를 그대로 쓰면 된다.

**⒞ 가드가 합법 POSIX 파일명을 거부한다(의도된 대가).** `Q:answers.md`·`a:b.txt`처럼 `<코드포인트>:`로 시작하는
이름은 POSIX에서 합법인데 `isAbsolute`가 절대로 판정해 거부한다. Windows 파일명에는 `:`를 쓸 수 없으므로 이
대가는 POSIX 전용이다. 저장소에 그런 이름이 있으면 그 파일의 diff를 못 연다. 드라이브 상대(`C:x`)를 위험으로
보는 판단과 같은 뿌리이고, **정상 파일을 잃는 쪽보다 루트 밖을 읽는 쪽이 더 나쁘다**고 보아 이 방향을 택했다.
`path_shape.isAbsolute`의 doc 주석이 이 대가를 명시한다.

### 5.3 Windows 경로 레이아웃 — `%LOCALAPPDATA%\maru\` (W8.5 결정)

`src/main.zig`와 config 로더가 **여섯 자리**에서 사용자별 경로를 요구한다 — terminfo 캐시, 컨트롤 소켓
디렉터리, `maru ssh` control path, `install-cli` 위치, `trace anonymize`의 매칭 키, 그리고 config 파일.
전부 각자 `getenv("HOME")`을 불렀고, Windows는 `HOME`을 주지 않는다.

#### 무엇이 깨져 있었나 (실측, Windows 10.0.19045)

`maru terminfo --path`:

| 환경 | `HOME` | 결과 | 판정 |
|---|---|---|---|
| git-bash | MSYS가 넣고 Win32 형태로 변환해 전달 | `C:/Users/<user>/.cache/maru/terminfo` | 정상 — **그래서 이 결함이 가려져 있었다** |
| cmd.exe · PowerShell | 없음 | 안내 후 exit 1 | 기능이 죽는다 |
| `HOME=""` (빈 문자열) | `""` | **`/.cache/maru/terminfo`, exit 0** | **조용히 틀린다** |

세 번째 줄이 계획에 없던 것이다. `getenv`는 빈 값에도 non-null을 주므로 `orelse` 가드가 발화하지 않고,
드라이브 루트의 엉뚱한 경로가 **성공으로** 나간다. `resolveClickedPath`가 `~/` 확장에서 같은 함정을 절대
경로 검사로 이미 막고 있었는데 여기는 아니었다.

#### 결정 — 어느 진영인가

처음에는 "단일 레이아웃 유지(`$HOME/.cache`) + `%USERPROFILE%` 폴백"으로 갔다가, 선례를 조사하고 뒤집었다.

| 터미널 | Windows config | 근거 |
|---|---|---|
| **Warp** | `%LOCALAPPDATA%\warp\Warp\config\` (테마·탭 config만 `%APPDATA%`) | `directories` 크레이트 관례 — *"portable"은 Roaming, "machine-specific"은 Local*. macOS는 `~/.warp/`, Linux는 XDG — **OS마다 그 OS 관례**. `~/.warp/`는 Windows에서 **안 읽는다**고 명시 |
| **Alacritty** | `%APPDATA%lacritty\` **만** | Unix에서는 XDG 5단계를 보지만 Windows에서는 `$HOME/.config`를 아예 안 본다 |
| Windows Terminal | `%LOCALAPPDATA%\…\LocalState` | MSIX 샌드박스가 **강제**한다. Windows 전용 앱이라 이식성 고민이 없어 **선례로 치지 않는다** |
| **WezTerm** | `$HOME/.config/wezterm`·`~/.local/share/wezterm` | appdata를 **의도적으로 거부** — *"it works against the idea that the same configuration layout can be used on multiple operating systems"*, *"bootstrap my dotfiles from git on any OS"* |

**2:1로 플랫폼 네이티브**이고 WezTerm은 소수 입장임을 본인이 밝힌다.

**결정적인 것은 웹뷰다.** WebView2에는 WKWebView의 `nonPersistent()` 같은 인메모리 모드가 **없다** — user
data folder(쿠키·localStorage·IndexedDb·디스크 캐시)를 항상 디스크에 만든다. Microsoft의 Win32 지침은
*"You should specify the same folder where all other app data is stored"* 이고, 기본 위치(`<exe>.WebView2\`)는
설치 디렉터리가 보호돼 **쓰지 말라**고 한다. 즉 **maru의 데이터 base가 곧 수백 MB짜리 Chromium 프로필
위치**가 된다 — 숨은 `~/.cache`가 아니라 사용자가 찾을 수 있는 곳이어야 한다.

**그래서 Windows에서는 `%LOCALAPPDATA%\maru\` 아래로 모은다:**

| | 경로 |
|---|---|
| config | `%LOCALAPPDATA%\maru\config` |
| terminfo 캐시 | `%LOCALAPPDATA%\maru	erminfo` |
| 컨트롤 소켓 디렉터리 | `%LOCALAPPDATA%\maru\control` |
| (W8) WebView2 UDF | 같은 뿌리 아래 — W8이 이름을 정한다 |

Roaming(`%APPDATA%`)은 쓰지 않는다 — Warp도 `settings.toml`을 Local에 둔다(창 크기·경로 등 기계별 값이
섞인다). **탈출구는 남긴다**: `$MARU_CONFIG`와 `$XDG_CACHE_HOME`이 **모든 OS에서 최우선**이라, dotfiles로
설정을 옮기는 사용자는 예전 자리를 그대로 쓸 수 있다.

**지금이 옮기기 유일하게 싼 순간이다** — W7 전이라 Windows 사용자가 0명이다. 나중에 옮기면 실제 사용자
디렉터리를 마이그레이션해야 한다. 그래서 캐시만 먼저 옮기고 config를 미루는 대신 **레이아웃 전체를 한
슬라이스에서** 정했다.

**POSIX 회귀 0**: `os_tag`가 Windows가 아니면 `cacheBaseFor`가 null을 내고 호출자가 예전대로
`<home>/.cache`로 가며, `defaultConfigPathFor`도 `<home>/.config/maru/config`를 그대로 낸다.

#### 구현

판정은 **`src/user_paths.zig`** 하나가 소유한다(순수·`os_tag` 인자 — Windows 러너가 없어도 두 갈래가 모든
타깃에서 테스트된다). 환경변수 읽기는 호출자(`main.zig`·`config/loader.zig`·`cli/control_client.zig`·
`pty/macos.zig`)가 한다.

- `homeDirFor(os_tag, home, userprofile)` — 값이 **절대 경로**여야 홈으로 치고(빈 문자열·상대 경로 차단),
  Windows면 `%USERPROFILE%`로 폴백한다. POSIX에서는 폴백하지 않는다(거기서 `USERPROFILE`은 maru가 정의한
  적 없는 이름이라, 우연히 설정돼 있으면 의도치 않은 위치를 쓴다).
- `cacheBaseFor(os_tag, xdg_cache_home, localappdata)` — `cacheDirZ`·`controlDir`가 받는 base.
- `defaultConfigPathFor(...)` — config 파일 자리.

**해석기를 하나로 만들었다.** `terminfo_cache`의 셸 명령 넷이 예전에는 `${XDG_CACHE_HOME:-$HOME/.cache}`로
경로를 **다시 확장**했다. 규칙이 둘(Zig·셸)이라 base를 OS별로 바꾸는 순간 조용히 갈린다 — 실제로
`pty/macos.zig`가 `cacheDirZ`로 dir을 구해 놓고 셸에는 다시 확장시키는 중복이 있었다. 이제 Zig가 정한 값을
`shSingleQuote`로 인용해 **리터럴로** 넘긴다(경로에 공백·`$`·백틱이 있어도 안전하다).

#### 이 슬라이스가 닫지 않은 것

**`maru terminfo`의 셸 의존 — 무엇이 되고 무엇이 안 되는가.** `system()`은 Windows에서 `%COMSPEC%`
(= cmd.exe)로 간다(msvcrt). **프로세스를 어느 셸에서 띄웠든 그렇다** — 적대적 검증에서 git-bash로 띄워도
같다는 것을 확인했고, 그래서 처음 쓴 *"git-bash에서 실행하세요"* 안내를 지웠다(실측: cmd.exe가 `d='...'`를
명령 이름으로 읽어 `'d' is not recognized`).

| 서브커맨드 | Windows | 이유 |
|---|---|---|
| `--path` | **된다** | 순수 Zig — 셸을 안 쓴다 |
| `--clear` | `rm.exe`가 PATH에 있으면 된다 | 명령이 `rm -rf '<경로>'` **단일 외부 명령**이라 cmd.exe도 실행한다(git 설치본에 `rm.exe`가 있다) |
| `--status` | **판정 불가** | 프로브가 `TERMINFO=<dir> infocmp …` — `VAR=값 명령` 접두는 POSIX 문법이라 cmd.exe가 못 읽는다 |
| `--refresh` | **안 된다** | `d=...; rm -rf "$d"; …` 대입·확장이 POSIX 문법이다. 무엇을 설치해도 안 된다 |

세 번째 줄이 적대적 검증에서 나온 것이다. 프로브가 **항상 실패**하므로 예전 코드는 캐시가 실제로 컴파일돼
있어도 늘 `"아직 컴파일 안 됨"`이라고 **단언**했다 — 모르는 것을 아는 것처럼 말하는 쪽이 더 나쁘다. 지금은
`"상태: 알 수 없음"`이라고 답한다.

이 슬라이스가 한 것은 셋이다 — ⒜ `--refresh` 안내가 `tic`만 가리키던 것을 **원인(POSIX 셸 문법)** 을 짚게
고쳤고, ⒝ `--clear`가 `system()` 반환값을 **버리고** "삭제됨"을 exit 0으로 찍던 것을 고쳤으며(지우지 못했는데
지웠다고 말하고 있었다), ⒞ `--status`가 모르는 것을 단언하던 것을 고쳤다. `--refresh`를 Windows에서 실제로
돌리는 것은 `maru ssh`의 `/bin/sh` 문제와 **같은 결정**이라 W9에서 함께 정한다.

> **왜 인용을 검증해야 하는가 — 보안보다 먼저 "평범한 경로가 깨진다"다.** 예전에는 셸이
> `"${XDG_CACHE_HOME:-$HOME/.cache}"`를 **자기가 큰따옴표 안에서** 확장해 공백을 알아서 처리했다. 리터럴
> 주입으로 바꾸면서 그 책임이 코드로 왔다 — 인용이 틀리면 `C:\Users\John Smith\…`처럼 **이름에 공백이 든
> 사용자 전원**이 조용히 캐시를 잃는다(Windows에서 흔하다. `$`·`'`·백틱도 파일명에 쓸 수 있다). 주입 자체는
> 경로 출처가 대개 사용자 본인의 환경변수라 위협 모델이 약하지만, `maru ssh`가 이 terminfo를 원격으로
> 전파하고 CI·공유 에이전트에서는 env가 로컬 사용자 것이 아니다.
>
> **확인한 것.** 공백과 `$`가 든 경로(`/tmp/maru w85$real/…`)로 진짜 `sh` + 진짜 `tic`을 돌려 exit 0
> (`xterm-maru` 해석 성공)과 `.maru-version` 생성을 봤다. 주입 시도 8종(`'; touch …`, `` `touch …` ``,
> `$(touch …)`, 개행 삽입 등)은 진짜 `sh`에서 **한 건도 실행되지 않았다.** 예전 방식에서는 `$`가 든 캐시
> 경로 자체가 불가능했으므로 이건 개선이기도 하다.
>
> **처음 쓴 검증은 무효였다 — 그 기록을 남긴다.** 같은 공격을 `system()`으로 돌렸더니 "주입 0건"이 나왔는데,
> `system()`이 cmd.exe로 가서 POSIX 문법을 **해석조차 못 한** 것이었다. `touch`가 없어서가 아니다(git의
> `usr\bin`이 PATH에 있으면 cmd.exe도 `touch`를 돌린다 — 그 탐침이 정확히 그런 환경이었다). cmd.exe에 명령
> 치환이 없고, `;`가 구분자가 아니며, `&&`는 조건부라 왼쪽이 실패해 오른쪽이 안 돈 것뿐이다. **한 글자만
> 바꿔 cmd.exe의 무조건 구분자 `&`로 하면 같은 탐침이 침해를 보고한다**(실측: `d=X & touch <경로>` →
> 파일 생성됨). 실패할 수 없는 green 테스트는 없는 것보다 나쁘다 — 더 안 보게 만들기 때문이다.

**§7 격리 결정이 그대로 오지 않는다(W8 항목).** macOS는 비신뢰 브라우저 패널에
`WKWebsiteDataStore.nonPersistent()`를 써서 "쿠키·localStorage·캐시가 디스크에 안 남는다"를 보장하는데,
WebView2에는 대응물이 없다. UDF는 항상 생기고 지울 수 있을 뿐이다(`ClearBrowsingData` 또는 종료 시 UDF
삭제). W8이 그 자리를 정해야 한다.

## 6. 실측 (2026-08-15, Windows 10.0.19045, zig 0.16.0)

계약을 쓰기 전에 PoC로 확인한 것과 확인하지 못한 것을 정직하게 남긴다.

| 항목 | 결과 |
|---|---|
| cmd `PROMPT` 주입 | ✅ `ESC]9;9;C:\...ESC\` + `OSC 133 A/B/D` 캡처 |
| PowerShell `prompt` 오버라이드 | ✅ **pwsh 7.6.3**(전체 `OSC 133 D/A/B` + OSC 7)과 **Windows PowerShell 5.1.19041**(OSC 7) 양쪽에서 **인라인 `-Command`로** 캡처. 파일(`.ps1`) 방식의 정책 내성은 **미증명**이다 — 처음 측정이 프로세스 정책 `Bypass` 환경이었다(§3.3) |
| PEB cwd(2단) | ✅ 자기 프로세스 대조 일치, 남의 셸 프로세스도 읽힘. **드라이브 루트는 `C:\`로 와서 순진한 트림이 `C:`(드라이브 상대)를 만든다**(§3.5) |
| 프로세스 열거 | ✅ 5,328개 열거, `ppid` 체인으로 부모-자식 확인 |
| **`waitIo` 대응**(§4.1) | ✅ overlapped named pipe 비동기 read가 `ERROR_IO_PENDING`으로 등록되고, 상대 write는 read 이벤트로·`SetEvent`는 wake 이벤트로 깨우며, 조용하면 스핀 없이 `WAIT_TIMEOUT`. **`CreatePseudoConsole`이 named pipe 핸들을 받는다**(`hr=S_OK`) |
| **overlapped write 의미**(§4.1) | ⚠️ 4 KiB 버퍼에 512 KiB write → 즉시 `ERROR_IO_PENDING`에 `written=0`, 완료 전 `GetOverlappedResult`는 `ERROR_IO_INCOMPLETE`에 `bytes=0`이라 **부분 진행을 볼 수 없다**. 상대가 8 KiB를 읽어도 미완료, 전량(524,288 bytes)을 읽어야 완료. `POLLOUT`+부분쓰기와 의미가 달라 **백엔드가 흡수해야 한다** |
| **ConPTY 자식 attach**(§4.1) | ✅ **닫혔다**(2026-08-16). 자식 안에서 `cmd /c mode con`이 `줄: 37 / 열: 123` — `CreatePseudoConsole`에 넘긴 COORD 그대로다. 대화형 왕복 2회, `ResizePseudoConsole`은 **자식이 살아 있는 동안** S_OK, pwsh도 동일, 부모가 콘솔을 가진 경우도 동일 |
| **ConPTY EOF**(§4.1b) | ⚠️ 자식이 죽어도 파이프가 **안 끊긴다**. EOF를 내는 것은 `ClosePseudoConsole`이고, 그것은 밀린 출력을 안 읽었으면 **106,891 ms**(읽기 끝을 먼저 닫으면 **379,922 ms**) 막힌다. **다 배수한 뒤** 닫으면 **15 ms**에 유실 0. 동시에 하면 142,949 중 65,573만 도착 |
| **W4 백엔드 end-to-end** | ✅ `maru demo`·`app-pty-smoke`·`app-pty-loop-smoke`가 Windows에서 산출물을 낸다. `app-pty-interactive-loop-smoke`는 **pwsh 7**을 띄워 프레임 루프로 친 입력이 표식으로 돌아오고 셸이 `exited(code=0)`으로 끝난다 |
| **ConPTY의 핸들 누수** | ⚠️ **세션마다 커널 핸들 1개가 영구히 남는다**(30초를 기다려도 회수되지 않고 선형으로 누적). 원인을 순수 Win32로 층별 분리해 확인했다 — 파이프 4개 생성·해제만: **0**, job 생성·해제만: **0**, `CreatePseudoConsole`+`ClosePseudoConsole`을 더하면: **20회에 20개**. 즉 우리 코드가 아니라 **ConPTY API 자체**다. 팬을 여닫을 때마다 1개씩 늘어나므로 장시간 세션에서 서서히 쌓인다 |
| **PowerShell 통합 주입**(§3.3) | ✅ 인라인 `-Command`로 `prompt`를 정의하면 OSC 9;9·133;A가 나오고 `cd` 뒤 새 cwd가 정확히 보고된다. **`-NoExit`이 없으면 셸이 곧바로 끝난다.** 사용자 프로필이 `prompt`를 정의해도 우리가 이긴다(프로필 먼저, `-Command` 나중 — 임시 홈으로 실측) |
| **cmd 통합 주입**(§3.3) | ✅ `PROMPT` 환경변수만으로(인자 0개) 9;9·133;A가 나오고 `cd /d` 뒤 새 cwd가 보고된다. 사용자 프롬프트 뒤에 우리 OSC를 **앞에만** 덧붙이면 둘 다 살아남는다 |
| **셸 통합 주입 end-to-end**(W5) | ✅ 통합을 켜면 cmd가 `OSC 133;A` + `9;9;<cwd>` + `133;B`를, pwsh가 거기에 `133;D;<코드>`까지 낸다. **대조군**(통합 OFF)에서는 OSC가 하나도 안 나온다. 사용자 `PROMPT`도 보존된다 |
| **pwsh의 `$?` 포착 시점** | ⚠️ `prompt` 함수 안에서 `$?`를 **맨 앞에서** 읽어야 한다. 다른 문장 뒤에 읽으면 그 문장의 성공을 보고 `133;D`에 **0**이 실린다(실측: `cmd /c exit 3` 뒤인데 0). 고친 뒤 `exit 3` → `3`, `exit 0` → `0` |
| **한글(비-ASCII) 경로·환경** | ✅ 한글 cwd로 spawn하면 자식이 `D:\…\한글폴더\하위 디렉터리`를 그대로 본다(공백 포함). 한글 환경값도, 커맨드라인의 한글 인자도, pwsh가 내는 OSC 9;9 payload의 한글 경로도 그대로다(ACP·콘솔 CP 둘 다 949인 기기) |
| **`cmd /c <문자열>`의 따옴표** | ⚠️ 우리 인용기는 CRT 규칙대로 `"`를 `\"`로 이스케이프하는데 **cmd는 그 규칙을 모른다** — `cmd /c "type \"파일.txt\""`는 "지정된 경로를 찾을 수 없습니다"로 끝나고 따옴표를 뺀 형태는 정상이다. **제품 경로는 무관하다**(maru는 셸을 인자 없이 직접 띄운다). 데모·스모크 fixture만 이 형태를 쓰므로 "스크립트에 `\"`를 넣지 않는다"를 테스트로 강제한다 |
| **cmd의 한 줄 입력 상한** | ⚠️ 한 줄이 6,000바이트면 실행되고 **9,000바이트면 통째로 무시된다**(콘솔 줄 입력 상한). 백엔드는 20 KiB를 여러 줄로 나눠 주면 전량 전달한다 — 즉 **우리 쪽 한계가 아니라 cmd의 한계**다 |

**ConPTY를 "환경 탓"으로 적었던 것은 오판이었다 — 기록으로 남긴다.** 위 항목은 한때 "자식이 pty에 붙는 것만
미확인, 에이전트 샌드박스가 conhost 세션을 못 띄우기 때문"으로 적혀 있었다. 실제 원인은 **우리 코드 두 곳**이다.

| 무엇이 틀렸나 | 진짜 원인 | 어떻게 고치나 |
|---|---|---|
| 자식 출력이 pty가 아니라 **우리 stdout**으로 나갔다 | `bInheritHandles=FALSE`인데도 자식이 부모의 표준 핸들을 물려받았다. stdout을 파일로 돌리니 마커가 그 파일에 떨어져(16 bytes) 인과가 증명됐다 | `dwFlags`에 `STARTF_USESTDHANDLES`를 세우고 `hStdInput`/`hStdOutput`/`hStdError`를 **전부 NULL**로 둔다 = "물려받을 것이 없다" |
| 읽은 것이 conhost VT init 48바이트뿐이라 "안 붙었다"고 읽었다 | 한 번만 `ReadFile`하고 멈췄다 | `PeekNamedPipe`로 데드라인까지 폴링해 모은다 |
| `ResizePseudoConsole`이 `0x80070006`(잘못된 핸들) | `ClosePseudoConsole` **뒤에** 불렀다 | 자식이 살아 있는 동안 부른다 |

원인을 C로 다시 써서 같은 숫자가 나온 것(`attrSize=48`, `sizeof(STARTUPINFOEXW)=112`, `flags=0x80000`)을
"바인딩이 아니라 환경"의 근거로 삼았는데, **두 구현이 같은 실수를 공유했으므로 그 대조는 아무것도 가르지
못했다.** 교훈: 재현 대상이 같은 저자의 같은 가정을 담고 있으면 대조군이 아니다. 실제 대조군은 나중에 세운
"표준 핸들을 비우지 않은 판"이었고, 그것은 기대대로 실패하며 마커를 우리 stdout으로 흘렸다.

**부모에 콘솔이 있을 때**(=사용자가 터미널에서 `maru`를 띄우는 조건)도 이 환경에서 닫았다. `AllocConsole`과
`AttachConsole(ATTACH_PARENT_PROCESS)`은 둘 다 `err=5`로 막히지만, `CREATE_NEW_CONSOLE`로 자기 자신을 다시
띄우면 그 프로세스는 진짜 콘솔 소유자(`GetConsoleWindow() != null`, 버퍼 120x9001)이고 거기서 attach가
그대로 됐다.

## 7. 베이스

- **ConPTY**: Win32 공개 API(`CreatePseudoConsole`·`ResizePseudoConsole`·`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`).
- **OSC 9;9**: ConEmu가 정의한 공개 시퀀스. Windows Terminal이 채택하고 Microsoft가 셸 통합 문서로 안내한다.
  **동작만 비교했고 레퍼런스 코드 표현은 옮기지 않았다**([project-rules.md](project-rules.md) clean-room).
- **PEB cwd**: 비문서화 구조체. Process Explorer 계열이 같은 경로를 쓴다는 사실만 근거이고, 구현은 공개
  문서(`NtQueryInformationProcess`·`ReadProcessMemory`)와 자체 측정으로 만든다.
- **셸 티어와 통합 주입 형태**: macOS의 `ZDOTDIR` 주입을 Windows 셸에 옮긴 maru 독립 설계다.

## 8. 아직 정하지 않은 것

- **WSL 세션의 ADE 축 셋**(§3.1). 에이전트 탐지·cwd 2단·경로 소비가 VM 경계에서 끊긴다. 후보: ① 셸 통합이
  포그라운드 명령을 OSC로 보고하게 해 proc_name 폴링을 대체, ② `wsl.exe -e`로 주기적 조회(폴링마다 프로세스
  생성이라 비싸다), ③ WSL 세션은 에이전트 축을 끈다(degradation 명시). 경로는 `\\wsl$\` 변환이 별도 결정이다.
- **`publishBrowserResult`의 파일 권한.** `src/main.zig`가 `maru browser executeScript --out <경로>`의 결과를
  `Permissions.fromMode(0o600)`(소유자 전용)으로 쓴다. Windows에는 POSIX mode가 없고 **ACL**(누구에게 어떤
  동작을 허용/거부하는지의 항목 목록)이라 그 값을 그대로 옮길 수 없다.

  | | 내용 | 문제 |
  |---|---|---|
  | ① | ACL을 지정하지 않고 **부모 디렉터리 상속**에 맡긴다 | 이 파일은 `Dir.cwd()` 기준 **사용자가 `--out`으로 준 경로**라 어디 놓일지 모른다. 홈 아래면 대개 사용자 전용이지만 공유 폴더·네트워크 드라이브면 그 폴더 권한을 물려받는다 — **보장이 아니다** |
  | ② | 현재 사용자 SID만 허용하는 ACL을 **명시적으로 구성** | POSIX `0600`과 같은 보장(폴더 무관). 대가는 Windows 보안 API(`OpenProcessToken`·`InitializeAcl`·`AddAccessAllowedAce`·`SECURITY_ATTRIBUTES`) 유입 |

  **이 결정은 W2를 막지 않았다.** `publishBrowserResult`는 **컨트롤 소켓 왕복을 마친 뒤에만** 호출되는데,
  W2가 그 소켓을 "인스턴스 없음"으로 빠지게 했으므로 이 코드는 Windows에서 **도달 불가**다. 실제 권한 정책은
  아래 **컨트롤 플레인 transport**를 이식할 때 함께 정한다.

  **W2가 한 것은 "컴파일만 되게"가 아니라 명시적 차단이다.** Windows의 `Permissions`는 POSIX mode가 아니라
  ACL을 나르는 `FILE.ATTRIBUTE` enum이라 `fromMode`가 **아예 없어서**, 컴파일을 통과시키려면 `.default_file`을
  넣는 수밖에 없었다. 그런데 그 값은 "부모 디렉터리 ACL을 상속한다"는 뜻이고 — 이 파일은 사용자가 `--out`으로
  준 임의 경로라 — 위 표의 ①을 **결정한 적 없이 채택**하는 셈이 된다. 그래서 `error.UnsupportedOnWindows`로
  막았다. 컨트롤 플레인을 이식하는 사람이 이 결정을 잊으면 조용히 넓은 권한으로 쓰이는 대신 **여기서 시끄럽게
  실패한다.**
- **cwd 2단(PEB)을 둘 것인가**(§3.5). Ghostty는 안 두고 "모른다"를 표현하며, macOS maru는 둔다. Windows에서는
  비문서화 비용이 더해지므로 별도 판단이 필요하다.
- **웹뷰 합성 모델**. WebView2는 별도 HWND라 macOS의 `CALayer` subview 3겹 합성이 그대로 오지 않는다.
  DirectComposition으로 합성할지 HWND 오버레이로 갈지 — **W8로 미뤘다**(W7.2a 결정, §2c). W7.1이 그 결정을
  두 지점(창 `dwExStyle`·스왑체인 생성)에 가둬 뒀으므로 전환이 싸고, 지금 필요한 것은 터미널이라 더 단순한
  `CreateSwapChainForHwnd`로 갔다.

  **다만 답은 사실상 정해져 있다.** HWND 오버레이로 가면 WebView2가 자식 HWND가 되고 그 영역 위에는 우리
  스왑체인이 그릴 수 없다(airspace) — `터미널 < 웹뷰 < 오버레이` z-order가 뒤집혀 모달이 웹뷰 뒤로 숨는다.
  그 순서를 지키려면 DirectComposition + WebView2 visual hosting이다. W8은 이 결론을 다시 발견하지 말고
  **비용만 재면 된다**(COM 인터페이스 셋이 는다). **창 투명도도 같은 자리에서 열린다**(§2c).
  **GPU 백엔드는 정해졌다**(§2a) — 한때 이 항목과 묶여 있었으나 갈랐다.
- **`main.zig`의 컨트롤 플레인 transport**. unix domain socket을 named pipe로 옮기는 설계. 초기에는
  "인스턴스 없음"으로 graceful하게 빠지는 것으로 충분하다.
- ~~**hover 밑줄에도 존재검증을 둘 것인가**~~ → **둔다(결정 완료, §5.1a).** 재야 할 것으로 적어 둔 두 비용을
  실측했고 둘 다 예산 안이었다. 밑줄과 클릭이 이제 같은 술어를 쓴다.
- **exec-restore(라이브 host 업그레이드)를 Windows에서 어떻게 할 것인가.** macOS는 host가 자기 자신을
  `execve`로 갈아끼우며 상속된 PTY master **fd**를 새 이미지가 주워 계속 쓴다(`PreparedAdoption`). Windows에는
  `execve`가 없고(자기 교체가 아니라 새 프로세스 생성), 핸들 상속(`bInheritHandles`)은 되지만 ConPTY `HPCON`의
  소유 관계가 다르다. 지금은 **막되 시끄럽게** 두었다(§4) — `upgradeEligible`이 항상 false이고 `materialize`는
  `@panic`이다. 세션 호스트를 Windows로 옮길 때 함께 정한다. **`ChildPid`의 부호 규약도 그때 같이 정한다** —
  POSIX 소비자는 `-1`을 모호함 센티널로 쓰는데 Windows 갈래(`u32`)에는 그 관례가 없다(`pty/types.zig` doc).
- **배포**. 코드 서명·인스톨러·업데이트 경로는 [배포·업데이트 전략](distribution.md)이 macOS 기준으로
  쓰여 있다.

> **여기서 빠진 것 = 결정된 것.** `OSC 9;9`의 host는 §3.2a에서 결정됐고(9;9은 host를 건드리지 않는다), 그
> 결정이 안고 가는 잔여 위험과 재검토 트리거는 §3.2a "받아들인 위험"이 소유한다. **셸은 이제 전부 결정됐다** —
> 기본값은 PowerShell(§3.1a), 바꾸는 수단은 `shell.windows-shell`(종류)·`shell.command[.windows]`(경로),
> config의 OS 분기는 **일반 메커니즘**(키 접미)으로 넣었다. 그 셋의 우선순위와 규칙은 §3.1a와
> [configuration.md](configuration.md) "OS별 값"이 소유한다.
