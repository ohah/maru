# Windows 플랫폼 구현 계획

계약은 [Windows 플랫폼](../windows-platform.md)이 단일 출처다. 이 문서는 **진행 상태**만 소유한다.

## 배경

중립 레이어(L1~L3)는 이미 Windows 호스트에서 컴파일되고 테스트가 **exit 0으로** 돈다(수치는
[layering-and-portability.md](../layering-and-portability.md) §4.1의 실측 기록이 단일 출처다 — 여기서
복제하지 않는다). 이 계획을 세울 때 빠진 것은 L4 전부였다: ConPTY 백엔드 0줄, Win32 호스트 0줄, 렌더러 0줄.

**그중 ConPTY 백엔드는 W4에서 섰다.** 지금 남은 L4는 Win32 호스트(W7)와 렌더러다. 헤드리스 세로
슬라이스는 W6까지로 닫혔으므로, 다음 슬라이스부터는 "창을 띄우기 전에 증명한다"가 아니라 **창을 띄우는
일** 자체가 남은 범위다.

순서의 기준은 [초기 세로 슬라이스](../initial-vertical-slice.md)가 macOS에서 쓴 것과 같다 —
**GUI 전에 헤드리스 경로를 먼저 증명한다.** W1~W5가 전부 헤드리스라 창·GPU 결정과 독립적으로 진행되고,
그 사이에 남은 결정(백엔드·웹뷰 합성)이 익는다.

## 슬라이스

| | 내용 | 상태 |
|---|---|---|
| W0 | 계약 문서(`windows-platform.md`) + 이 계획. 코드 0 | 완료 |
| W1 | **OSC 9;9 cwd** — `dispatchNotify9`에 `9;` 갈래를 더한다. **9;9은 host를 건드리지 않는다**(계약 §3.2a의 C — 최소 메커니즘은 정해졌다). L1이라 Windows와 독립이고 헤드리스로 검증된다. 잔여 위험은 §3.2a "받아들인 위험"으로 수용 확정 | 완료 |
| W1.5 | **절대경로 판정을 `[0]=='/'`에서 떼어낸다** — 새 최상위 유틸 `src/path_shape.zig`가 술어 둘을 낸다. **가드**(`isAbsolute`, OS 무관 거부): `normalizeAssetPath`·`repo_path`·`git_write_command`·`pathWithin`·`validateName`/`validBasename`. **감지**(`isDetectableAbsoluteFor`, OS를 **인자로**): `terminal/selection.zig`. 왜 갈리는지와 실측은 계약 §5.1. 계약 §5의 순서 제약상 **경로 정규화 도입보다 먼저** 해야 한다 | 완료 |
| W5.5 | **Windows 상대 경로 링크 감지** — `filePathSpan`의 `home_path`·`dot_relative`·`bare_relative` 세 갈래도 `\`를 받게 한다(`.\x`·`..\x`·`src\x`·`~\x`). 절대 갈래만 고친 W1.5의 후속이고 **더 흔한 형태**다. `dot_relative`·`home_path` 두 갈래를 **닫았다** — `path_shape.detectableRelativePrefixFor`가 OS를 인자로 받고, 규칙은 오탐 스윕이 찾은 세그먼트 조건 하나다(계약 §5.2 ⒜). POSIX 철자는 회귀 0. `bare_relative`도 **닫았다** — 감지에는 여전히 규칙이 없지만 hover 존재검증(계약 §5.1a)이 뒤를 받아 ⑴로 갔다. 독립 캡처 코퍼스 369 토큰에서 새로 밑줄이 뜬 것 3개, 셋 다 진짜 경로, **오탐 0**(계약 §5.2 ⒜) | 완료 |
| W2 | **`main.zig` Windows 컴파일·실행** — 실제로 링크를 막던 심볼은 셋(`socket`·`environ`·`symlink`)이었다. 전부 **호스트 게이트**(`hostGateReason(os_tag, feature)`)로 접는다: 컨트롤 소켓 → "인스턴스 없음"(계약 §8), `maru ssh` → W9 안내, `install-cli` → W10 안내. `publishBrowserResult`의 `fromMode(0o600)`은 Windows에 `Permissions.fromMode`가 없어 **`error.UnsupportedOnWindows`로 명시 차단**한다 — `.default_file`로 조용히 넘기면 ACL 결정(계약 §8)을 잊은 채 넓은 권한으로 쓰이기 때문이다. 게이트가 comptime이라 POSIX 본문이 의미 분석되지 않는 것이 링크를 뚫는 원리다. `src/main.zig` 테스트를 **모든 호스트**에서 걸도록 `build.zig` 게이트를 뗐다. 적대적 검증 후속: PTY 없는 호스트에서 `demo`·`app-pty-*`가 19줄 스택 트레이스를 뱉던 것을 `error.UnsupportedPlatform`을 잡아 2줄 안내로 바꾸고(`error.UnknownCommand` 선례와 같은 자리), bare `maru`가 `pty.backend_available`을 보고 미리 알리게 했다 | 완료 |
| W2.5 | **Windows 기본 셸 + config OS 분기** — `resolveInteractiveShellFor(kind)`가 OS 갈래를 갖는다(`MARU_INTERACTIVE_SHELL` → pwsh 7 → 5.1 → `%COMSPEC%` → cmd; 계약 §3.1a). 후보 목록은 **OS와 `%COMSPEC%`을 인자로 받는 순수 함수**라 테스트가 두 갈래를 모두 돈다. config에 **일반 OS 접미 메커니즘**(`shell.command.windows`·`font.size.macos` — 아무 키에나)과 **`shell.windows-shell`**(`powershell` 또는 `cmd` — 종류 선택)을 넣었다. 이로써 계약 §8의 "셸 설정의 OS 분기"가 닫혔다. **config 값을 실제 spawn에 배선하는 것은 W7**(Windows 호스트) — 지금은 `main.zig`가 config를 읽지 않는다 | 완료 |
| W3 | **`SpawnRequest` 중립화 + 입구 경로 정규화** — `zdotdir` → `shell_integration_dir`로 일반화하고 `login`은 의도로·`term`은 백엔드 위임으로 재문서화한다. `command`+`args`는 **그대로**. **wire 키 `"zdotdir"`는 불변** — 직렬화가 익명 구조체 리터럴이라 **그 리터럴의 필드 이름이 곧 JSON 키**이고, 한 줄 안에서 왼쪽(wire)과 오른쪽(Zig 필드)이 갈린다(계약 §4.2). 정규화는 `path_shape.normalizeSeparatorsFor(os_tag, …)`를 `$HOME`·`$XDG_CACHE_HOME` 입구에 건다 — 실측으로 terminfo 캐시 경로의 혼합 구분자가 사라진다. POSIX에선 무동작이라 macOS 동작 변화 0. **`trace anonymize`의 `$HOME`은 정규화하지 않는다** — 그것은 트레이스에서 홈 경로를 지우는 매칭 키라, 바꾸면 native 경로와 안 맞아 오히려 덜 지워진다 | 완료 |
| W4 | **ConPTY 백엔드** — `src/pty/windows.zig`. 필수 13 표면. 파이프는 `CreatePipe`가 아니라 **overlapped named pipe**(계약 §4.1). OS 무관한 조립 규칙은 `src/pty/windows_spawn.zig`로 갈라 **모든 타깃에서** 테스트가 돌게 했다. 계약이 W4에 남긴 두 결정을 실측으로 닫았다 — **쓰기 의미론**은 ①(미결 write 한 건)+스테이징 버퍼(§4.1), **EOF·종료**는 "배수한 뒤에 닫는다"와 "`ClosePseudoConsole`은 분리 스레드"(§4.1b). 자식 트리 종료는 job(`KILL_ON_JOB_CLOSE`) | 완료 |
| W5 | **셸 통합 주입** — cmd `PROMPT`, PowerShell 인라인 `-Command`(계약 §3.3). 사용자 프롬프트를 보존하고 `OSC 133 A/B`(+pwsh는 `D`)와 `9;9` cwd 보고를 켠다. `SpawnRequest.shell_integration`을 union으로 전환했다(§4.2a) — wire 키 `"zdotdir"`는 파일 갈래에 그대로 남아 안 깨진다. 내용 조립은 `pty/windows_integration.zig`가 소유하고 **모든 타깃에서** 테스트가 돈다 | 완료 |
| W6 | **헤드리스 세로 슬라이스** — `zig build demo`가 Windows에서 산출물을 낸다. 여기까지가 아키텍처 증명. **W4에서 함께 닫았다**: 백엔드를 켜는 순간 데모·스모크 fixture가 `/bin/sh`에 걸려 W2가 없앤 스택 트레이스가 되살아났으므로, 그 자리를 남겨 둘 수 없었다. fixture 명령의 OS 갈래는 `src/app/fixture_script.zig`가 단일 출처이고 **OS를 인자로** 받아 두 갈래가 모든 타깃에서 테스트된다. `demo`·`app-pty-smoke`·`app-pty-loop-smoke`·`app-pty-interactive-loop-smoke`(pwsh 7) 넷 다 Windows에서 산출물을 낸다(계약 §6) | 완료 |
| W7.0 | **W7 선행 정리** — 중립 레이어가 Windows에서 컴파일되지 않던 두 자리를 닫는다(계약 §4). ⑴ `live_pty.childPid()`의 `std.c.pid_t`를 중립 별칭 `pty.ChildPid`로(POSIX는 글자 그대로 같아 macOS 소비자 무변, Windows만 `u32`). ⑵ exec-restore 표면(`PreparedAdoption`·`upgradeEligible`·…)을 **막되 시끄럽게** 둔다 — `upgradeEligible`이 항상 false라 경로가 안 열리고, 나머지는 `error.UnsupportedOnWindows`/`@panic`이다. 합집합을 `live_pty` 테스트가 **컴파일 시점에** 고정하고 새 `zig build check-targets`(Run 없는 컴파일 전용)가 세 타깃으로 돌린다 — `-Dtarget=`은 산출물을 실행하려다 항상 실패해 게이트가 못 된다(코드 리뷰가 잡았다) | 완료 |
| W7.1 | **Win32 창과 메시지 펌프** — `src/platform/windows/win32_window.zig`. 창을 만들고 펌프하고 OS 메시지를 중립 이벤트(`resized`·`paint`·`close_requested`)로 바꿔 준다. 그리기·입력·앱 정책은 없고, 표시 대상은 `PresentTarget`으로 **주입받는다**(W7.2가 채운다 — 웹뷰 합성 모델이 닿는 곳을 두 지점에 가둔다). 계약 §2b가 규율 셋을 못 박았다: ⑴ `SendMessage`는 큐를 거치지 않으므로 `poll` 진입에서 비우면 `show()`의 `WM_SIZE`를 잃는다 → **버퍼 둘을 맞바꾼다**(한 버퍼를 빌려주면 순회 중 push가 use-after-free — 대조군에서 segfault). ⑵ `WM_CLOSE`·`WM_PAINT`에서 창이 스스로 닫거나 그리지 않는다. ⑶ `user32`·`gdi32`를 명시 링크한다. **실기 검증**: 창이 뜨고 외부 리사이즈 960×600→640×400에 `resized_events` 1→2, `client_px` 944×561→624×361, 셀 118×35→78×22가 따라왔다 | 완료 |
| W7.2a | **D3D11 표시 경로** — `src/platform/windows/d3d11_present.zig`. 디바이스·스왑체인·백버퍼 뷰·리사이즈·present까지. 그리는 것은 없다(W7.2b). **이 저장소의 첫 COM 소비자**라 규약을 계약 §2c에 세웠다: 부르지 않는 vtable 슬롯도 자리를 채우고, 슬롯 번호를 `@offsetOf`로 comptime에 못 박아 **Windows 러너 없이 세 타깃 전부**가 그 게이트를 통과하게 했다. 실측으로 정해진 것 셋 — HWND 스왑체인의 `AlphaMode`는 `UNSPECIFIED`여야 하고(`IGNORE`는 `DXGI_ERROR_INVALID_CALL`), **`MakeWindowAssociation(NO_ALT_ENTER)`이 필수**이며(안 하면 DXGI가 Alt+Enter를 가로채 W7.4가 그 키를 못 받는다), 하드웨어가 없으면 **WARP**로 선다(계획의 "GPU 없는 러너" 여지를 코드가 연다 — 대조군으로 `driver=warp` 확인). **판정식은 화면 픽셀**이다: 중앙 픽셀이 요청한 `0xFF1E2430`과 정확히 같아 채널 순서까지 확인된다 | 완료 |
| W7.2b | **셀 드로우** — `src/platform/windows/d3d11_cells.zig`. HLSL 셰이더(런타임 컴파일 — 빌드가 Windows SDK를 전제하지 않게 `d3dcompiler_47.dll`을 동적 로딩)·RGBA8 아틀라스·인스턴스 드로우. 블렌드 규약은 `NativeMetalCell`이 이미 정해 둔 것을 그대로 쓴다(배경 알파가 판정). **정점 버퍼가 없다** — 사각형은 `SV_VertexID`에서 만든다. COM 바인딩을 `d3d11.zig`로 갈라 표시 경로와 셀 파이프라인이 나눠 쓴다. 실측으로 고친 것 둘 — 아틀라스는 R8이 아니라 **RGBA8이고 커버리지가 알파**에 있고(`glyph_pixels` 계약), `synthesizeGlyph`에 **오프셋한 슬라이스를 넘기면 빈 글리프로 조용히 degrade**한다(슬롯 28개 "채움"에 덮인 픽셀 0). 판정은 화면에서 세 색이 각각 나오는지다(clear 비침·배경 채움·글리프 전경) | 완료 |
| W7.3 | **DirectWrite 글리프 래스터라이저** — `src/platform/windows/dwrite_font.zig`. 코드포인트 → RGBA8 커버리지(알파). 셀 격자를 폰트 메트릭에서 유도하고, 회색 AA는 ClearType 텍스처를 평균해 얻는다(DirectWrite가 회색 텍스처를 안 준다). **폰트 티어를 §3.1a의 셸 티어와 같은 모양으로** 세웠다(계약 §2e) — 주 폰트는 `font.family` → Cascadia Mono → Consolas → Courier New, 폴백은 `font.fallback` → Malgun Gothic → Noto Sans KR → … → Segoe UI Emoji. **폴백은 실측이 요구했다**: 고정폭 라틴 폰트에 한글이 없어 Cascadia Mono에서 한글 10자가 전부 `.notdef`였고, 폴백을 켜자 `slots_blank` 10→0이 됐다. 두 칸 글자는 `terminal.cellWidth`로 두 칸 폭 슬롯에 그린다. W7.2c 앞에 넣은 이유는 **W7.2c의 아틀라스를 rasterizer가 채우기** 때문이다(순서를 바꾸면 배관을 두 번 만든다) | 완료 |
| W7.2c-1 | **중립 프레임 계약을 Windows 백엔드로 채운다** — `win32_text.zig`(셰이퍼 `shape`·래스터라이저 `rasterize`)와 `win32_terminal.zig`(프레임 빌더). 창을 띄우지 않는다: §2a의 질문은 "계약이 받아들이는가"라 그림이 아니라 프레임이 답이다. 중립 레이어에 이음매 **한 줄**(`host.buildFrameAfterDrainWithRasterizer`)을 추가했다 — 코어 락 규율이 `host.zig` 한 곳에만 있어야 해서 조립 코드를 복사하지 않았다(기존 함수는 fake로 그것을 부르므로 동작 무변). `font_id` 매핑을 한 파일이 양방향으로 소유해 셰이퍼·래스터라이저 결정이 갈리지 않는다. **실측: 실제 셸 세션에서 45프레임, 글리프 39개 업로드, 덮인 픽셀 1881, 폴백·빈칸·건너뜀 0** — `upload_non_clear_pixels`가 판정이다(슬롯 수만 세면 글자가 안 그려져도 성공처럼 보인다). **§2a의 답은 예다** | 완료 |
| W7.2c-2 | **실제 터미널 화면이 뜬다** — §2f의 프레임을 §2c·§2d의 표시 경로에 흘려 넣는다. 잇는 것은 둘: 아틀라스 **부분 업로드**(`UpdateSubresource`, 텍스처 밖은 그리지 않고 알린다 — 넘치면 "글자가 다른 글자로 나온다")와 **셀 투영**(`NativeMetalCell` → `Cell`, 좌표계·색 표현만 바꾸고 정책은 중립 쪽에서 받는다). 창 리사이즈가 터미널 격자도 바꾼다. 아틀라스 grow는 텍스처를 다시 만든다 — 중립 쪽이 `atlas_full`로 전체 무효화·재배치하므로 안전하다(그 경로는 실측 미검증). **실측: PowerShell 7.6.3 세션이 창에 그려진다** — 프롬프트·경로·SGR 색·출력·블록 커서. `CellColors.cursor` 기본값이 `null`(커서 투영 안 함)이라 켜야 그 경로가 돈다 — 켜자 `cells_drawn`이 2485→2486으로 정확히 하나 늘었다. 셀 메트릭을 `TextLayoutConfig`로 안 넘기면 **글리프가 아래에서 잘린다**(화면으로 잡고 `upload_non_clear_pixels` 1881→2643(+40%)으로 확인). `foreground`는 알파가 없어 불투명으로 채워야 한다 — 안 하면 셰이더의 `cov * fg.a`가 커버리지를 죽여 글자가 아예 안 나온다 | 완료 |
| W7.4a | **키 입력** — `src/platform/windows/win32_keys.zig`(순수)와 창의 `WM_KEYDOWN`/`WM_CHAR`. 창이 중립 `KeyEvent`를 올리고 앱/셸 판정은 `handleKeyEvent`가 한다. 문자는 `WM_CHAR`(레이아웃·데드키는 OS 몫 — VK 에서 짐작하면 비영문 레이아웃이 깨진다), Ctrl·Alt 조합만 `MapVirtualKeyW`로 문자를 복원한다. UTF-16 서로게이트 쌍을 합친다. **⌘ 매핑을 `controlByte`로 판정한다**(계약 §2h) — plain `Cmd+<글자>` 12글자가 전부 C0 를 갖는 문자라 `Ctrl` 을 그대로 주면 `Ctrl+D`(EOF)·`Ctrl+W`를 잃는다. 밀려온 글자 집합은 바인딩 표에서 **comptime 유도**(손으로 박으면 어긋난다). **실측: 타이핑이 셸까지 가고 출력이 돌아온다** — `keys_to_shell=46`·`shell_ended=false`·`fallback_glyphs` 0→3678. 중복 없음은 통제 측정(3글자→3)으로 확인 | 완료 |
| W7.4c | **IME 조합 미리보기** — `WM_IME_COMPOSITION`의 `GCS_COMPSTR`만 읽어 중립 `setPreeditLocked`에 넣는다(계약 §2i). 확정 문자는 `DefWindowProcW`가 `WM_CHAR`로 만들게 둬 §2h 의 문자 경로 하나가 받는다. 미리보기 렌더는 중립 `renderSnapshot()`이 이미 합성하므로 Windows 가 만들지 않는다. 변환·잘림 규칙(`ImmGetCompositionStringW`가 바이트 수를 준다·서로게이트·버퍼 초과 시 글자 단위 잘림)을 순수 함수로 갈라 모든 타깃에서 테스트했다. **한계: 실제 한글 조합을 프로그램적으로 만들 수 없다** — 창이 포그라운드를 못 잡고(실측) 합성 메시지는 실제 IME 컨텍스트를 읽는다. 배관은 확인됐다(메시지 4개 → `preedit_updates=4`, 대조군 0/0). 후보창 위치 지정은 W7.4d 와 함께 | 완료 |
| W7.4b | **클립보드** — `src/platform/windows/win32_clipboard.zig`. **플랫폼이 소유한다**(계약 §2j) — `config/action.zig`가 이미 "Zig는 selection, Swift는 clipboard"로 그은 선을 Windows에서도 지킨다. 중립 계층이 요청하는 것은 OSC 52이고 코어가 pending으로 들고 있다(코어가 OS를 직접 안 만진다). `CF_UNICODETEXT` 하나만 쓴다 — `CF_TEXT`는 ANSI(이 기계 ACP 949)라 비영문이 깨진다. **줄바꿈 규칙이 방향마다 달라 왕복이 항등이 아니다**: 쓸 때 `\n`→`\r\n`(Windows 관례), 읽을 때 `\r\n`→`\r` — CRLF를 터미널에 주면 셸이 **두 줄을 실행한다**. 성공한 `SetClipboardData` 뒤에 `GlobalFree`를 부르지 않고(소유권이 시스템으로 넘어간다) 실패했을 때만 우리가 해제한다. 길이는 NUL까지 세서 잰다. 락 안에서 OS를 부르지 않는다(클립보드는 다른 프로세스를 기다릴 수 있어 그 사이 PTY 리더가 막힌다). 화음은 `Ctrl+Shift+V`·`Shift+Insert` 둘이고 평범한 `Ctrl+C`/`Ctrl+V`는 안 가로챈다(SIGINT를 잃는다). **raw 바이트를 셸에 보내지 않는다** — 중립 `encodePasteWith`가 bracketed 래핑·개행 정규화·ESC 치환을 하고, `pasteNeedsConfirmation`이 막으면 붙이지 않는다(확인 모달은 W8). 스스로 반증하다 찾은 결함이다: 처음엔 raw 로 보내서 클립보드의 `\x1b[201~`이 래핑을 빠져나올 수 있었다. **실측: OSC 52 쓰기가 실제 클립보드까지 닿는다**(`SENTINEL-BEFORE`→`CLIP-OSC-OK-한글`, `osc52_writes=1`·`clipboard_errors=0`), `win32-clipboard-smoke`가 5/5 통과하고 300 KiB가 정확히 왕복, 외부 작성자(.NET)가 넣은 한글·CRLF도 정확히 읽는다. **대조군이 두 가지를 가르쳐 줬다**: NUL 규칙은 자체 왕복으로 **판정되지 않고**(우리 할당은 정확해서 `GlobalSize`로 재도 같다 — 그래서 외부 작성자 모드를 뒀다), 깨진 UTF-16을 `OutOfMemory`로 부르던 것이 형식 오류를 메모리 오류처럼 보이게 해 `InvalidUtf16`으로 갈랐다. **한계**: 붙여넣기 화음의 실기 경로는 사람이 눌러야 한다 — `PostMessageW`가 스레드 키 상태를 갱신하지 않아 `Shift+Insert`가 평범한 Insert(`\x1b[2~`)로 간다(실측). 복사(선택 영역)는 마우스와 같은 계층이라 W7.4d | 완료 |
| W7.4d | **마우스 — 선택·스크롤·복사** — `src/platform/windows/win32_mouse.zig`(순수)와 창의 `WM_LBUTTON*`/`WM_MOUSEMOVE`/`WM_MOUSEWHEEL`/`WM_CAPTURECHANGED`. **중립 명령이 이미 다 있어**(`session/core_command.zig`의 `select_start`·`select_extend_or_collapse`·`select_word`·`select_line`·`select_clear`·`scroll`·`report_mouse`) Windows 는 번역만 한다 — 코어 mutate 는 전부 리더 스레드 위임이라 메인은 코어를 안 만진다. 규칙은 macOS 관례를 그대로 읽어 왔다(shift·alt 가 리포팅 override, alt 가 블록 선택, command 비트 마스킹). 순수 함수 9개 테스트로 세 타깃 전부 덮인다 — 픽셀→셀 clamp(드래그가 창 밖으로 나가도 안 끊긴다), **부호 있는 좌표 추출**(`LOWORD`를 부호 없이 읽으면 -1 이 65535 가 되어 선택이 반대쪽 끝으로 튄다), 휠 나머지 누적(정밀 터치패드), 연타 판정. `CS_DBLCLKS`를 **일부러 안 켠다** — Win32 는 트리플을 안 알려 주므로 우리가 세야 하고 그러려면 모든 클릭이 같은 메시지로 와야 한다. **복사가 여기서 붙어** §2j 의 `isCopyChord` 에 호출자가 생겼다. `input.right_click` 기본값 `paste` 도 구현했는데, 덕분에 **W7.4b 가 모디파이어 때문에 못 재고 남긴 붙여넣기 경로가 실기에서 닫혔다**(우클릭엔 모디파이어가 필요 없다 — `pastes=1 paste_bytes=29 blocked=0 errors=0`). **실측**: 드래그 선택이 코어에 닿아 `selection_bytes=24`(줄 전체), 더블클릭 `words=1`·13바이트, 트리플 `lines=1`·41바이트, **네 번째 클릭은 다시 단클릭**(대조군), 스크롤 5건, `wheel_lines_per_notch=10`(이 기계의 실제 사용자 설정 — 기본값 3 을 박았으면 틀렸다). 중복 `left_up` 하나를 실측이 잡았다(`ReleaseCapture` 가 `WM_CAPTURECHANGED` 를 부른다 — 이벤트가 11 이 아니라 12 였다). **한계: 마우스 리포팅이 안 온다 — 인박스 conhost 가 낡아서다**(계약 §2k). `1007` 은 도착하는데 `1000`·`1006` 은 사라진다. 트리거는 DECSET 이 아니라 `SetConsoleMode(stdin, ENABLE_MOUSE_INPUT)` 이고(microsoft/terminal#9970, 2021) 그것을 실제로 켜고(`after=0x98 ok=True`) 재도 안 왔다 — 이 기계의 conhost 는 **10.0.19041.4522** 로 그 수정보다 오래됐다. 우리 파서는 1000·1002·1003·1006 을 다 안다(우리 탓이 아니다). `PASSTHROUGH_MODE`(0x8)로도 안 되는 것을 실험으로 확인했다. **해결책은 있고 실측으로 확인했다** — Zed 가 번들한 `conpty.dll`(1.22.250314001)을 동적 로드해 `CreatePseudoConsole` 만 바꾼 A/B 에서 `mouse_tracking` 이 `none`→**`any`**, `mouse_format` 이 `x10`→**`sgr`** 로 바뀌고 클릭이 `reports=0 selections=1` → **`reports=2 selections=0`** 으로 갈렸다. **우리 코드는 한 줄도 안 바꿨다.** Microsoft 공식 방침이 그것이고(discussion #17608 — 인박스 백포트 대신 NuGet 배포), Warp·Zed·Android Studio(pty4j)·WezTerm 이 이미 그 쌍을 들고 다닌다(이 기계에서 확인). 배포 결정(산출물에 MIT 바이너리 둘)이라 사용자 판단 대기. 리포팅 코드는 옳게 두되 잠들어 있고 새 ConPTY 를 얹으면 **코드 변경 없이** 켜진다. **IME 후보창 위치도 여기서 닫았다**(§2i가 미뤄 둔 자리) — `ImmSetCompositionWindow`·`ImmSetCandidateWindow` 를 **둘 다** 부른다(IME 마다 보는 것이 달라 하나만 부르면 후보창이 창 좌상단에 남는다), 조합창은 글자 자리에·후보창은 `CFS_EXCLUDE` 로 그 셀을 가리지 말라고 준다. **조합 시작이 아니라 커서가 움직일 때** 갱신한다(IME 는 조합 시작 순간의 값을 쓴다 — 그때 세팅하면 늦다). 실측: 23자 타이핑에 13회 갱신, 대조군(무입력) 3회 | 완료 |
| W7.6 | **ConPTY 를 함께 배포한다** — `assets/windows/conpty/x64/` 에 `Microsoft.Windows.Console.ConPTY` `1.24.260710001` 의 `conpty.dll`+`OpenConsole.exe`(MIT, Microsoft 서명 유효, 1.12 MB)를 두고 `pty/windows.zig` 가 **있으면 그것을, 없으면 kernel32 를** 쓴다. 이유는 W7.4d 가 찾은 것 — 인박스 conhost 가 낡으면 마우스 모드를 안 넘겨 vim·htop 이 마우스를 못 받는다(계약 §2k·§4.3). Microsoft 방침이 그것이고(discussion #17608 — 인박스 백포트 대신 NuGet) Warp·Zed·Android Studio(pty4j)·WezTerm 이 다 그렇게 한다. **이름으로 로드하지 않는다**(CWD·PATH 를 뒤져 DLL 하이재킹 — 실행 파일 옆 전체 경로만), **셋을 한 모듈에서 다 못 얻으면 하나도 안 쓴다**(Create/Close 를 섞으면 나중에 이상하게 터진다), 경로가 MAX_PATH 를 넘으면 번들을 안 쓴다(#16860). 배치가 틀려도 `conpty.dll` 이 시스템 conhost 로 **조용히 되돌아가므로** 스모크가 `conpty=bundled\|system` 을 찍는다. **실측 A/B**(같은 빌드, dll 만 치웠다 넣었다): 번들이면 `mouse_tracking=any`·`mouse_format=sgr`·`reports=2 selections=0`, 인박스면 `none`·`x10`·`reports=0 selections=1` — 나머지는 같고(`keys_to_shell=20`) **§2k 코드는 한 줄도 안 바뀌었다**. 한계: 사용자가 `cmd.exe`·`wsl.exe` 를 직접 띄우면 그쪽은 시스템 conhost 다. 지금은 x64 만 — arm64 는 그 타깃을 넣을 때 | 완료 |
| W7.5 | **경로와 config** — 세 자리. ⒜ **루트 스트라이핑 두 곳**이 구분자를 한 바이트로 가정해 루트가 `/`·`C:/`처럼 구분자로 끝나면 첫 세그먼트를 먹었다 — `C:/a/b` 가 `/b` 가 되어 **`C:/b` 라는 다른 파일을 연다**. 규칙을 `path_shape.relativeUnderRoot` 하나로 모으고 경계 검사(`/a/proj` vs `/a/project`)도 넣었다. 테스트가 **옛 계산을 재현해 다르다는 것을 고정**한다(계약 §5.2 ⒝). ⒝ **config 경로 정규화**를 계약이 남긴 두 선택지 중 **⑴ 로더**로 정했다 — 근거는 규칙 1 자신의 "입구에서" 이고, ⑵ 는 같은 규칙을 흩어 ⒜ 와 같은 사고를 만든다. 표식을 스키마 1급(`Meta.path_value`)으로 올리고 **`abs_path` 가 그것을 함의**하게 했다(둘을 따로 적으면 한쪽만 붙이는 실수가 조용히 건너뛴다). POSIX 에선 무동작이고, 경로가 **아닌** text 필드는 안 건드리는 것도 테스트가 고정한다. ⒞ **사용자 config 배선** — W7.4a~d 가 하드코딩해 둔 넷(`paste-protection`·`bracketed-paste-is-safe`·`right-click`·`word-separators`)과 `osc52.read`·키바인딩이 `loadDefault` 하나로 온다. 검증 실패면 빌트인으로 접고 알린다(모호한 바인딩을 조용히 고르지 않는다). **판정은 값이 아니라 행동으로** 했다 — `right-click = menu` 면 `pastes=0`(기본은 1), `paste-protection = false` 면 여러 줄이 `blocked=1` → `pastes=1` 로 갈린다(계약 §2l). 곁들여 `check-boundaries` digest 갱신 도구가 한국어 Windows 에서 `UnicodeDecodeError` 로 죽던 것을 고쳤다(로케일 인코딩으로 UTF-8 진단을 읽고 있었다) | 완료 |
| W7 | **Win32 호스트 나머지.** 선행 정리는 W7.0, 창은 W7.1, 표시 경로는 W7.2a, 셀 드로우는 W7.2b, 폰트는 W7.3, 프레임은 W7.2c, 키 입력은 W7.4a, IME 미리보기는 W7.4c, 클립보드는 W7.4b, 마우스·후보창은 W7.4d, ConPTY 번들은 W7.6, 경로·config 는 W7.5에서 닫았다. **선행 결정 1건**(웹뷰 합성 모델)이 계약 §8에 있다 — GPU 백엔드는 **D3D11 + DXGI로 정해졌다**(계약 §2a) | 완료 |
| W8 | **ADE 표면** — 파일 패널·에디터·소스 컨트롤·에이전트 도크. 웹 패널은 WebView2 + DirectComposition. **진행 중**: W8.0 게이트 확장(계약 §2m.2)·W8.1 파일 트리 백엔드(§2m.3)·W8.2⒜ 데이터 경로(§2m.4)·폰트(§2e·§2m.14·§2m.15)·터미널 앱(§2m.16)·앱 config(§2m.17)·**셰이핑 다리 배선(§2m.18)**·W8.2⒝ 파일 트리(§2m.6)·W8.3 에디터(§2m.21~§2m.25)·**W8.4 소스 컨트롤 완료**(⒜ §2m.9 · ⒝ §2m.27·§2m.28 · ⒞1 §2m.29 · ⒞2 §2m.30). **W8.5b 완료**(⒜ 표면 §2m.56 · ⒝ 목록 데이터 §2m.57 — 그 길에서 Windows 파일 읽기 패닉·해제된 문자열·**크롬 한글 두부**(두 font id 체계의 값 범위가 겹쳤다)를 함께 고쳤다). 남은 것(2026-08-29 갱신): **W8.6** 웹 패널(결정 대기) · **W8.17⒜⒝** 편집·safe-save 와 외부 변경 감시 · **W8.18⒞** 접기·정렬 영속(저장 위치 결정 대기) · **W8.19** 상태바 우측(결정 대기) · **W8.21** 보고만 한 잔여 결함. W8.15·W8.16 은 닫혔고 W8.17⒞·W8.18⒜⒝ 도 닫혔다 — **이 칸이 또 낡아 있었다**(그 아래 행들은 맞는데 요약만 옛말을 했다). **이 칸이 한동안 "남은 것은 W8.6 뿐" 이라고 말했다**(2026-08-28 정정) — 실제로는 W8.10~W8.14 가 계획에 없는 채로 진행됐고 다음에 할 일은 PR 의 **한계 절**에만 있었다. 계획서가 "무엇이 남았나" 의 단일 출처이기를 그만둔 것이라, 새로 한 것을 행으로 세우고 남은 것도 행으로 적어 되돌린다 | 진행 중 |
| **W8.7** | **합성 — 한 창에 터미널과 도크**(계약 §2m.31). **이 행은 원래 계획에 없었다** — W8 은 표면 목록이라 넷을 다 만들어도 각자 창을 여는 스모크로 남는다. 사용자 질문이 그 빠진 자리를 드러냈고(2026-08-24) 합의로 W8.5b 보다 먼저 한다. 기하는 이미 중립이고(`session/dock_layout.compute`) 터미널을 부분 사각형에 놓는 배선도 이미 있다(`NativeMetalCell.origin_*`) — ⒜1 창이 갈린다(§2m.31, 완료) ⒜2 도크에 파일 트리(§2m.32, 완료 — 아틀라스 공유) ⒝ 입력 라우팅(§2m.34, 완료 — 포인터는 사각형으로) ⒞1 디바이더 드래그(§2m.35, 완료) ⒞2 뷰 전환(§2m.36, 완료 — 파일 트리 ↔ 소스 컨트롤) | **합성 완료**(뷰 바 아이콘 §2m.41 완료. 도크 스크롤 §2m.52 완료. 에이전트 뷰 §2m.56·§2m.57 완료. 사이드바 스크롤 §2m.53·트리 폴더 펼치기 §2m.55 완료. **헤더 아이콘 줄을 창 버튼과 같은 띠로** §2m.59. **스크롤바** §2m.63 — §2m.52·§2m.53 이 한계로 적어 둔 것을 갚았다. **에이전트 카드·그룹 클릭** §2m.65 — §2m.56 의 죽은 컨트롤을 갚았다. 그러다 **판정 각본이 제품에서도 돌던 것**을 찾아 막았다 §2m.64. **정렬 토글** §2m.66. **비동기 스캔** §2m.67·§2m.68 — 펼치기와 이력 훑기가 메인 스레드를 잡던 것을 제출/수령으로 갈랐다. 그 덕에 **새로고침** §2m.69 가 풀렸고, 앱 수명 arena 가 40 MB 를 물던 것과 상태바 런 목록 누수를 함께 찾았다. `scope` 는 여전히 모델이 없다. **파일 열기** §2m.70 — 목적지가 문서에 있는데 Windows 에 그 자리가 없어 사용자에게 묻고(2026-08-27) 사이드바 전환기를 재사용했다. `.text` 만 연다. 적대적 검증 7회 §2m.71~§2m.73 — 판정 넷이 속 비었고, 문서를 보는 중에 친 글자가 안 보이는 셸로 갔고, **저장소 밖에서 열면 이중 해제로 죽었다**. **파일 카드 닫기** §2m.74 — 그 길에 열 배치가 두 곳에서 갈려 있던 것을 중립으로 모았다. 세션 닫기는 중립에 모델이 없어 별개다). **여기까지 쌓아 온 것을 W8.10~W8.14 행으로 갈랐다** — 이 칸이 계획 대신 이력이 되어 가고 있었다 |
| W8.5 | **Windows 경로 레이아웃** — 여섯 소비자(config 로더·terminfo 캐시·컨트롤 소켓 디렉터리·ssh control path·install 위치·`trace anonymize` 매칭 키)가 각자 `getenv("HOME")`을 부르던 것을 `src/user_paths.zig`(순수·OS 인자) 하나로 모으고, **Windows 레이아웃을 `%LOCALAPPDATA%\maru\`로** 정했다(계약 §5.3 — Warp·Alacritty 선례 2:1, 결정타는 WebView2가 user data folder를 디스크에 강제한다는 점). 빈 `HOME`이 `/.cache/maru/terminfo`를 exit 0으로 내던 **조용한 오답**과 `--clear`의 거짓 성공 보고도 닫았다. terminfo 셸 명령이 경로를 재확장하던 중복을 없애 **해석기를 하나로** 만들었다. `$MARU_CONFIG`·`$XDG_CACHE_HOME`이 모든 OS에서 최우선이라 dotfiles 사용자는 예전 자리를 쓸 수 있다. `--refresh`/`--clear`가 POSIX 셸을 요구하는 것은 W9의 `/bin/sh` 결정과 같은 건이라 남는다 | 완료 |
| **W8.8** | **왼쪽 사이드바**(계약 §2m.37). **이 행도 원래 계획에 없었다** — W8 은 표면 목록인데 사이드바가 빠져 있고, W8.7 이 창을 갈랐지만 왼쪽은 `sidebar_width_px = 0` 이다. 사용자 질문이 드러냈고(2026-08-24) 합의로 넣는다. 히트테스트·기하는 이미 전부 중립이고(`chrome/components/sidebar.zig` 의 `pub fn` 26 개, `dock_layout` 이 `sidebar_width_px` 를 이미 받는다) 걸리는 것은 셋 — ⒜1 세로 띠와 카드 밴드(§2m.38, 완료) ⒜2 카드 글자(§2m.39, 완료 — 인코더/디코더 쌍을 중립으로) ⒜3 카드 클릭(§2m.50, 완료 — 중립 `Region.sidebar` 신설) ⒝ **프레임리스 창**(§2m.43, 완료) (`WM_NCCALCSIZE` 로 캡션을 지우고 `WM_NCHITTEST` 가 `HTCAPTION` 을 낸다 — Electron `-webkit-app-region: drag` 의 Win32 짝. macOS 는 **이미 프레임리스**다) + 헤더(§2m.46·§2m.48, 완료 — 아이콘 줄 1.7× · 검색 줄은 placeholder 까지, 입력 모델이 선행). **결정됨**(사용자 2026-08-24, Windows 관례): 캡션 버튼 ─ ☐ ✕ 를 타이틀바 띠 **오른쪽 끝**에 우리가 그리고, 사이드바 헤더 아이콘은 **안 옮긴다** — 두 예약 영역이 겹치지 않는다(macOS 는 신호등이 사이드바 헤더 **안**이었다) ⒞ 여러 세션·탭(§2m.51, 완료 — ＋ 가 만들고 카드가 전환한다. 닫기는 남았다) | **완료**. 그 칸이 남긴 셋 중 **둘의 전제가 틀렸다**(2026-08-28 확인) — ⑴ **닫기**: 파일 카드는 됐다(W8.14). 세션 카드만 남았고 그건 모델이 진짜로 없다(W8.16) ⑵ **검색 입력**: "모델이 선행" 이라 적었는데 `chrome/components/overlay_input.zig` 에 **이미 있다**(W8.15) ⑶ 아이콘 동작만 그대로 남았다 |
| **W8.9** | **하단 상태표시줄**(계약 §2m.60). **이 행도 원래 계획에 없었다** — W8.7·W8.8 에 이어 **세 번째**로, W8 이 표면 목록이라 그 목록에 없는 것이 통째로 빠졌다. 사용자 질문이 드러냈다(2026-08-26). 없는 것은 **Windows 배선뿐**이다: 순수 배치(`chrome/components/status_bar.zig`)·기하(`dock_layout` 의 `status_bar` rect)·계약 문서(`status-bar.md` 850줄)·config(`status-bar.show`, 기본 `true`)·macOS 렌더가 전부 있고, `dockGeometryFor` 만 `.status_bar_px = 0` 을 넘긴다 — 즉 그 키가 **Windows 에서 조용히 무시된다**. 항목의 모델도 이미 이 앱에 있다(브랜치 §2m.9 · cwd · 에이전트 개수 §2m.57). **폭은 픽셀로 재야 한다**(그 컴포넌트의 계약) | **좌측 둘 완료**(§2m.61 — 치수를 `src/status_bar_metrics.zig` 로 중립화하고 macOS 도 그 함수를 쓴다. 우측 항목·클릭은 **W8.19**) |
| **W8.10** | **스크롤바** — 도크·사이드바가 굴러가는데 막대가 없어 "얼마나 남았나" 를 알 방법이 없었다(§2m.52·§2m.53 이 한계로 적어 둔 것) | **완료**(§2m.63) |
| **W8.11** | **에이전트 카드·그룹 클릭과 정렬 토글** — §2m.56 이 표면을 세웠지만 눌리는 것이 하나도 없었다. 그 길에 **판정 각본이 제품에서도 돌던 것**을 찾아 막았다(§2m.64) | **완료**(§2m.65·§2m.66). `scope`·`resume_session` 은 모델이 선행 |
| **W8.12** | **비동기 스캔** — 폴더 펼치기가 400 회, 시작의 이력 훑기가 3000 회까지 그 자리에서 기다렸다. 제출과 수령을 갈라 프레임 루프가 받게 한다 | **완료**(§2m.67~§2m.69). 실측: 응답 시작 10359 ms → 266 ms. 그 덕에 **새로고침 인텐트**가 풀렸다 |
| **W8.13** | **파일 줄을 누르면 열린다** — §2m.55 가 "파일 행은 아직 아무 일도 안 한다" 로 남겨 둔 자리. 목적지가 문서에 있는데(워크스페이스 pane 탭) Windows 에 그 자리가 없어 **사용자에게 묻고**(2026-08-27) 사이드바 전환기를 재사용했다 | **완료**(§2m.70~§2m.73). `.text` 만 연다 — `.md`·`.html` 본문은 **W8.6** 이 선행. 적대적 검증 7 회에서 **저장소 밖에서 열면 죽던 이중 해제**를 함께 고쳤다 |
| **W8.14** | **파일 카드의 ✕ 가 눌린다** — 그 길에 사이드바 열 배치가 그리기와 히트테스트 두 곳으로 갈려 있던 것(오른쪽 inset 누락)을 중립 `sidebar.columns()` 로 모았다 | **완료**(§2m.74). 세션 카드의 ✕ 는 **W8.16** |
| **W8.15** | **검색에 글자를 친다** — 죽은 컨트롤 셋이 한 자리에 묶여 있다: 사이드바 검색 줄(§2m.46 이 placeholder 까지만), 에이전트 검색, `focus_search` 인텐트. **모델은 이미 중립에 있다** — `chrome/components/overlay_input.zig` 의 `OverlayInput`(find·palette·rename·사이드바 검색이 **공유**하던 것 — 인라인 rename 은 2026-09-29 에 `TextField` 로 옮겼다: `appendChar`·`backspace`·IME `setPreedit`/`commitPreedit`·`inputLineView`). **`text_field.zig` 가 아니다** — 그쪽은 주소창(omnibox) 전용이고, 그 파일 머리말이 직접 갈라 둔다: *"공유 `overlay_input.OverlayInput`(find·palette·rename·사이드바검색)은 끝-caret 전용"*. Windows 가 세울 것은 **포커스의 주인**(키가 터미널 것인가 검색 것인가), 캐럿 렌더, 목록 거르기 셋이다. 문서를 보는 중에 키를 삼키기로 한 §2m.71 ⑹ 과 같은 축이다 | **완료**(§2m.75 사이드바 · §2m.76 에이전트·`focus_search`). **훑는 중 표시도 완료**(§2m.86 — 중립이 이미 갖고 있던 `loading`/`refreshing`/`partial` 을 배선했다). **IME 조합 배선도 완료**(§2m.87 — 조합이 포커스를 따라가고, 그리는 값은 확정+조합, 거르는 값은 확정뿐이다). 남은 것은 **사이드바의 결과 없음 안내**(중립에 빈 상태가 없어 새 i18n 문구가 선행 — 사용자 결정) |
| **W8.16** | **세션 닫기** — 카드의 ✕ 가 세션 슬롯에서는 아직 아무 일도 안 한다(수치로만 남는다: `session_close_unimplemented`). **중립 `session/window.zig` 의 `AppWindow` 에 탭을 빼는 것이 없다**(있는 것은 `active`·`activeConst`·`selectTab` 셋뿐). PTY 를 죽이는 파괴적 동작이라 마지막 세션·실행 중 프로세스 규칙도 함께 정해야 하고, macOS 가 Swift 로 가진 모델과 겹칠 수 있다 | **완료**(§2m.77 기전 · §2m.79 확인 모달) — 프롬프트면 즉시, 실행 중이면 확인을 띄우고 승낙하면 닫힌다. 셸 통합(프롬프트 마크)을 심으면 확인 없이 즉시 닫히는 경우가 늘어난다 — 별개 슬라이스다. 마지막 세션은 안 닫는다(앱 종료 결정) |
| **W8.17** | **편집기를 끝까지** — capability를 통과한 일반 파일의 편집·native 저장·기존 백업 복원 연결은 §2m.158까지 진행했다. ⒜ 편집(캐럿·선택 입력·undo)과 safe-save ⒝ 외부 변경 감시(연 파일을 다시 안 읽는다) **⒞ 긴 줄 완료**(가로 휠·Shift+휠·가로 막대와 그 드래그 — §2m.82). ⒜ 는 `editor-surface.md` 의 revision 3축 CAS·`DocumentRegistry` 가 선행이라 여러 슬라이스다. ⒞ 가 남긴 것: 키보드 가로 이동(Home·End·좌우), 랩 토글, **세로 막대 입력 완료**(§2m.117 — 기하·렌더는 이미 있었고 클릭·드래그가 빠져 있었다. 창 밖 release·빠른 release·뷰 전환을 포함한 실제 창 판정 5개 통과) | ⒞ 완료 · ⒜ 선행 소유권/구조·native path pin·staging·읽을 수 있는 metadata 복사 진행(§2m.122~126) · 편집/저장·⒝ 감시 남음 |
| **W8.18** | **눈이 따라간다** — 상태가 맞는데 **화면이 그 자리를 안 보여 주는** 것들을 한 묶음으로. **⒜ 완료**(§2m.83 — 규칙은 중립 `sidebar.scrollToSlot` 이 소유한다. macOS 도 안 하던 것이라 parity 가 아니라 양쪽에 없던 것이고, macOS 배선은 남았다) **⒝ 완료**(§2m.84 — macOS 를 읽어 보니 리셋이 아니라 **clamp** 였다: 루트 변경에만 reset, 행을 다시 지을 때마다 clamp. 그 길에 **표면이 휠 나머지를 나눠 쓰던 결함**도 같이 고쳤다) ⒞ 접기·정렬 상태가 창을 닫으면 사라진다 | ⒜⒝ 완료 · ⒞ 미착수 |
| **W8.19** | **상태바 우측 항목** — W8.9 가 좌측 둘(브랜치·cwd)로 닫혔고 우측은 모델이 없어 비워 뒀다. 무엇을 놓을지(인코딩·줄 끝·위치·알림)부터가 결정이다 | **결정 대기** |
| **W8.20** | **사이드바가 그리는 목록과 재는 목록을 갈라 놓고 있었다** — W8.18⒜ 의 적대적 검증이 보고만 하고 넘어간 둘이다(§2m.83 의 보고 절). ⒜ 카드가 **열여섯을 넘으면** 기하·히트테스트·스크롤 상한이 `[16]` 배열로 자른 목록을 봐서, 열일곱 번째 카드는 그려지는데 **굴려 갈 수가 없었다**(세션 상한이 16 이고 연 파일 수에는 상한이 없다) ⒝ **굴린 목록이 헤더를 뚫고 보였다** — 헤더를 맨 나중에 그려도 글리프는 배경이 투명해 글자끼리 포개진다 | **완료**(§2m.85 — 행 목록을 힙으로, 목록 셀을 헤더 아래로 자르고 UV 도 같은 비율로 민다) |
| **W8.21** | **보고만 한 잔여 결함을 갚는다** — 슬라이스마다 "보고만 한다" 로 남긴 것들이 §2m 산문에만 있어 **여기서 다시 행으로 세운다**(W8 요약 칸이 두 번 낡은 그 실패의 짝). ~~⒜ `.md` 거절 안내가 없다~~ → **완료**(§2m.121 — 기존 Notice에 네 가지 실패·영어/한국어를 연결, 실제 클릭·렌더·입력 격리와 제품 변이 5회 확인) ⒝ **연 파일 상한이 없다**(§2m.85) ~~⒞ **그라디언트 quad 가 안 그려진다**~~ → **완료**(§2m.119~§2m.120 — 제품 chrome op lowering→실제 GPU 픽셀 28개, shader 변이 5회. 세로·가로·clip 보존·변별 border·독립 alpha·누락 role·빈 clip 확인) ⒟ **확인 모달이 도크를 덮는다**(§2m.79 — macOS 가 어디에 두는지와 안 견줬다) ~~⒠ **도크·SCM·에이전트 목록에는 헤더 clip 이 없다**~~ → **셋 다 갚았다**(§2m.89 탐색기 트리 — 위 153·아래 16 셀이 밖이었다 · §2m.91 SCM·에이전트 — 에이전트가 **589 중 391 셀**을 아래로, 최대 751px 밖에 그리고 있었다. **상태바가 덮고 있어 화면에서만 안 보였다**) ~~⒡ **`dock_scroll` 판정이 오래 판정 불가로 접혀 있다**~~ → **되살렸다**(§2m.88 — 꼬리로 옮겼고, 그 안의 `shift_applied` 가 **동어반복**이던 것을 함께 고쳤다) ~~⒢ **번들 폰트를 못 찾으면 크롬 제목이 엉뚱한 글리프로 그려진다**~~ → **고쳤다**(§2m.90 — 원인은 굵기였다. 셰이퍼가 **family 이름**을 신원으로 실어 같은 family 의 Bold 로 셰이핑한 글자를 Regular face 로 구웠다. 이제 **PostScript 이름**을 싣고, 그 이름의 face 가 목록에 없으면 그 family 안에서 열어 쓴다) | 진행 중 |
| **W8.22** | **에이전트·SCM 목록이 안 굴러간다** — §2m.91 이 clip 을 재다 함께 드러낸 것이다. 두 표면에는 스크롤이 **아예 없고**(`grep scroll` 0 건) 도크 휠은 탐색기 트리만 움직인다. 뷰포트보다 긴 목록은 **뒷부분에 닿을 방법이 없다**. **에이전트 완료**(§2m.92 — 중립 `scroll_area` 를 그대로 쓰고, 항목 높이 규칙을 중립 `session_dock/scroll.zig` 로 세웠다. 그 길에 **굴리자 헤더를 뚫고 나오던 것**도 함께 고쳤다: 글자는 `Text.scroll_clipped`, quad 는 `Op.Quad.clip` 을 Windows 가 안 읽고 있었다). ~~**SCM 뷰**~~ → **된다**(§2m.100 — 높이 규칙은 이미 중립 `DockMetrics.itemHeight` 가 갖고 있어 어댑터만 세웠다. **넘치는 상태는 «모두 보기» 뒤에 온다**는 것도 그 길에서 알게 됐다). ~~**SCM 막대 드래그**~~ → **된다**(§2m.102 — 에이전트에서 배운 셋을 처음부터 지켰다: 표면이 `DragEvent` 를 넘기고, 잡는 것은 `down`, 끄는 동안은 영역 판정 앞). 남은 것은 **탭 전환**(§2m.103 — 탭은 그려지는데 `select_tab` 을 Windows 가 안 받는다. 히스토리·에이전트 탭 내용이 선행)·**탭별 offset 기억** · ~~**키보드**~~ → **된다**(§2m.105) · ~~**스크롤바 드래그**~~ → **된다**(§2m.94 막대가 보이게 됐고 · §2m.95 잡아 끌 수 있게 됐다 — 표면이 중립의 `DragEvent` 를 버리고 있었고, 잡은 지점은 `began` 이 아니라 `down` 에서 정해야 했다). 남은 것은 ~~**키보드 Page/Home/End**~~ → **된다**(§2m.105 — 규칙은 셋 다 이미 문서에 있었고, 없던 것은 «도크가 키를 들었는가» 하나였다. 중립에 `applyKeyStep`, 순수 층에 `listScrollStep` 을 세웠다. **탐색기는 안 받는다** — 거기서 그 넷은 선택 이동의 주인이다) · **가상화**(§2m.107 이 열었다 닫았다 — 재 보니 비용이 목록 길이에 안 붙어 있었다: 항목 여덟에 17ms 였고 그 중 15ms 가 **폰트 폴백을 런마다 다시 짓는 것**이었다. 그쪽을 고쳐 10 배가 됐고 가상화는 남겨 둔다) (~~hover·drag 강조~~ → §2m.104 에서 **이미 동작한다**고 정정) · ~~**카드 펼침 상세**~~ → **된다**(§2m.97 — 공유 상세 백엔드를 그대로 쓴다. 그 길에서 Windows 핸들 플래그 패닉과 할당자 어긋남을 함께 고쳤고, 규약을 `positionalReadable` 로 뽑아 두 백엔드가 같은 것을 쓴다). 남은 것은 **버튼 셋**(resume·reveal·focus live — 지금은 죽여 뒀다) | ⒜ 에이전트 완료 · 나머지 미착수 |
| **W8.23** | **게이트가 상시 빨갰다** — Windows 러너를 안 두기로 했으므로 로컬 `mise run check` 가 유일한 그물인데, 재 보니 **13 개가 항상 실패**했다(§2m.108). 그 잡음에서 진짜 결함(§2m.106 복사 깨짐)을 손으로 골라내야 했고 같은 회차에 하나는 놓쳤다. **규칙은 이미 있었다** — `build.zig` 의 `macos_host_tests` 와 그 근거(«L4 가 먼저 죽으면 중립 회귀를 볼 방법이 없다»)가 Windows 실측과 함께 적혀 있는데 session_host 테스트 **40 중 하나**만 그것을 쓰고 있었다. 한 칸 느슨한 `posix_host_tests` 를 세워 40 자리에 걸고, e2e 의 `/bin/sh` 하드코딩을 호스트로 갈랐으며, 훅 스크립트의 POSIX 권한 검사 한 줄을 `SKIP` 으로 적었다(«안 됐다» 가 아니라 «못 쟀다» 다) | **`mise run check` 가 Windows 에서 `EXIT=0` (완료 — 단 `sh` 가 PATH 에 있는 셸에서, 즉 Git Bash. PowerShell 만으로는 아직 아니다: `sh` 를 요구하는 자리가 열이다 — 적대적 검증 4 회차, §2m.109)**. 처음 센 「13」은 **메시지를 grep 해 센 값**이라 둘을 놓쳤다(§2m.109) — `check-macos-app-host` 는 아무 메시지도 안 찍고 종료 코드로만 죽었고(mise 가 Windows 에서 `cmd` 로 돌려 POSIX `if` 를 못 읽는다 → `run_windows`), `check-mobile-contract` 는 실패를 `틀림` 으로 찍었다(`python3` 하드코딩 → `command -v` 로 인터프리터를 찾는다). **게이트는 종료 코드가 판정이고 메시지는 진단이다.** 그 길에 `tree_sitter` 27 개·ABI 타입 대조·모바일 키 판정·계획 인용이 이 호스트에서 **처음** 돈다. 남겨 뒀던 하나(중립 `tree_sitter.zig` 의 `std.c.clock_gettime`)도 §2m.109 에서 닫았다 — 「예산 대신 deadline」은 성립하지 않았고(시계가 파싱 **도중에** 필요하다), io 를 넘기면 호출자 수십 자리가 바뀐다. std 를 읽어 보니 **시계 읽기는 io 인스턴스를 안 쓴다**(`Threaded.now` 가 `_ = t;`) — 그래서 서명을 안 바꿨다. `tree_sitter` 테스트 27 개가 Windows 에서 처음 돌고, §2m.44 의 «항상 exit 1» 도 함께 정정했다 |
| **W8.24** | **게이트가 셸로 나간다** — §2m.109 가 남긴 물음(*«Windows 에서 어떤 셸을 지원하는가»*)의 답을 «셸 의존을 없앤다» 로 정했다(사용자 결정 2026-09-02). Alacritty·WezTerm 을 읽어 보니 패턴은 하나다 — **정확성 게이트는 빌드 도구 안에 있고 POSIX 스크립트는 곁다리이며 인터프리터를 명시한다.** maru 가 다른 지점은 스크립트가 있다는 것이 아니라 **게이트 자신이 셸로 나간다**는 것이다 | **넷 중 둘 완료**(publication 판정은 `tests/release_workflow/publication.zig`로 이관해 Windows에서 셸 없이 실행하고, 변이 5개를 모두 거부했다. §2m.110 — `test-session-host-release-workflow.sh` → `tests/release_workflow/authority_capture.zig`, 원본 `test` 줄과 일대일, 뮤턴트 넷으로 확인). **소스 대조 판정 이관은 완료**: 기존 `test-github-release-publication.sh`의 실제 현재 계약(legacy writer 부재·단계 순서·tag-only 서명·Action SHA·토큰 배치)을 유지한다. 현재 스크립트에는 `test -x`가 없었으므로 앞선 설명도 정정한다. 나머지 둘(`test-release-version.sh`·`check-agent-hook-command.sh`)은 **셸의 동작을 재는 판정**이라 옮기면 재는 것이 사라진다 — 그 둘은 «인터프리터를 빌드가 찾아 준다» 쪽 답이 필요하다. **결정 대기** |
| **W8.25** | **게이트가 새로 깨지는 것을 못 막는다** — §2m.111: 셸 단계 하나가 붙은 날 Windows 게이트가 깨졌고 **22 커밋 동안 아무도 몰랐다**(러너가 없으니 볼 사람이 없다). 하나씩 Zig 로 옮기는 W8.24 는 **이미 들어온 것만** 고친다 | **완료** — `tests/boundary/shell_gate_ledger.zig` 가 `build.zig` 를 훑어 기본 `test` 그래프의 셸 단계를 **명단과 대조**한다. 새로 붙이면 원장을 고쳐야 하고 그때 «모든 개발 호스트에서 도는가» 를 답하게 된다. **금지가 아니라 결정 강제다** — 재 보니 넷 중 셋은 Windows 에서 잘 돌아, «전부 가린다» 였으면 도는 계약 셋을 버릴 뻔했다. 실패하던 하나만 `.posix_only` 로 가렸다. 뮤턴트 넷으로 확인 |
| **W8.26** | **편집기가 글자를 한 색으로 그린다** — macOS 는 tree-sitter 로 칠하는데 Windows 는 `syntax` 모듈을 아예 안 물고 있었다 | **완료**(§2m.112). **베끼지 않고 옮겼다** — macOS 쪽 색 계산에 호스트 낱말이 없어서 통째로 중립 `chrome/components/editor_view/syntax_colors.zig` 로 갔고, 두 호스트가 그것을 부른다. 캡처 이름→색 투영은 최상위 `src/syntax_colors.zig`(chrome 은 session 을 import 하지 않는다 — `chrome_theme.zig`·`scm_items.zig` 와 같은 모양). 이름이 갈리면 **컴파일이 죽는다**. 그 길에 셋을 더 잡았다: CRLF 파일에서 줄 경계가 **가상 오프셋**이라 색이 밀리던 것 · 창 앞의 빈 줄을 프레임마다 다시 채워 `first_line=200_000` 에서 **프레임당 5.6 ms** 를 물던 것(→ 35 µs) · `check-targets` 크로스 exe 에 `syntax` 가 안 물려 게이트가 빨갛던 것 |
| **W8.27** | **화면 증거를 만들 방법이 없다** — §2m.112 가 그래서 스크린샷 없이 머지됐다. 처음엔 «스모크가 편집기를 안 그린다» 로 봤는데 재 보니 **334 프레임이나 그린다**. 못 한 것은 캡처가 그 위에 앉는 것이었다(스모크가 88 초이고 편집기 국면은 70 초 지점, 한 프레임은 16 ms) | **완료**(§2m.113) — `win32-terminal-smoke --hold-editor-ms <n>`. 기본 0 이라 게이트 시간은 안 변한다. 자기 전에 표식을, 깨어나서 **실측 ms** 를 찍는다(«멈췄다» 를 주장이 아니라 측정으로 만든다). 문턱은 `editor_syntax` 가 쓰는 그것 그대로다 — `esyn_judgeable` 만 보면 색 없는 프레임에서 멈춰 거짓 증거가 된다(적대적 검증 2 회차). 선택지 해석은 순수 함수로 빼서 판정을 걸었고, 그 자리에서 **안내문이 비워지지 않아 사용자에게 안 가던** 결함도 함께 고쳤다 |
| **W8.28** | **굴린 편집기의 색을 재는 판정이 없다** — §2m.112 가 남긴 구멍이다(`leading_empty` 뮤턴트가 판정 72 개를 전부 통과했다). 스모크는 편집기를 굴리지만 휠이 가는 파일이 `cache-cleanup.yml` 이고 **YAML 은 번들 grammar 에 없어서**, «굴린 프레임»과 «색 있는 프레임»이 한 번도 안 겹쳤다 | **완료**(§2m.114) — 색 있는 파일을 직접 굴리고(스핀 810, 기존 스크롤 판정 뒤) 잰 다음 **되돌린다**. 문턱은 칸 수가 아니라 **행 퍼짐**이다: 뮤턴트가 칸 370→21 로 무너지는데도 `colored>0` 은 **초록이었다**. 행으로는 28/31 대 1/31 이고 그 사이에서 절반을 골랐다. 셈법은 `countSyntaxPaint` 한 곳이 갖고 단위 판정이 붙어 있다. `--hold-editor-ms` 도 `kind=first`·`kind=scrolled` 로 두 번 잡는다 |
| **W8.29** | **스크롤 판정이 제품 결함을 거부한다** — sidebar clip은 실제 글리프를 경계에 걸치고, dock clamp는 실제 목록 상한에서 접은 뒤 frame clamp·redraw 결과를 잰다. 둘 중 하나라도 실패하면 제품 스모크는 exit 1이다. clip 변이 5회와 clamp 제품 변이·원복으로 확인(§2m.118). 에이전트 상세 스크롤의 판정 불가 문제는 남아 있다 | 두 판정 완료 · 상세 스크롤 검증 남음 |
| W9 | **`maru ssh` Windows 지원** — W2가 미지원 안내로 접어 둔 것을 되살린다. 지금은 `/bin/sh -c <래퍼 스크립트>`를 execve하는데 Windows엔 `/bin/sh`도 `environ`도 없다. **선행 결정**(계약 §3.5a에 없다): 래퍼 스크립트를 ⑴ `ssh.exe` 직접 exec로 대체하고 terminfo bootstrap을 포기할지 ⑵ Git for Windows의 `sh.exe`를 탐지해 쓸지(외부 의존) ⑶ PowerShell로 재작성할지. Windows 내장 OpenSSH **클라이언트**는 있다(§6 실측 — `sshd` 서버는 기본 Stopped) | 미착수 |
| W10 | **`maru install-cli` Windows 지원** — 마찬가지로 W2가 접어 뒀다. 지금은 `~/.local/bin/maru`에 symlink를 거는데 Windows엔 그 관례가 없고 `symlink` 심볼도 msvcrt에 없다. **선행 결정 3건**: 설치 위치(`%LOCALAPPDATA%\Programs`?), shim 방식·PATH 등록. **셋 다 정했다(§2m.62)** — 위치는 `%LOCALAPPDATA%\maru\bin`(`user_paths` 모듈 doc 이 "Windows 는 그 아래로 모은다" 로 이미 정한 자리), shim 은 `.cmd`(symlink 는 개발자 모드·관리자 권한이 필요하다), PATH 는 **안내만**(레지스트리를 쓰면 되돌리기와 실패 처리가 늘고 사용자가 안 시킨 시스템 상태를 바꾼다) | **완료**(§2m.62) |
| 후속 | **크롬 색이 테마를 안 탄다**(계약 §2m.33) — 터미널은 타는데 도크·트리·소스 컨트롤은 색 리터럴이다. 원인은 테마 → `chrome.Tokens` 매핑이 macOS `app_session.zig` 안에 갇힌 것(§3.4 의 빚)이고, 뺄 자리는 최상위 잎으로 정해져 있다. ~~**사용자 판단(2026-08-24): 인지된 부채로 둔다**~~ → **갚았다(§2m.40, 2026-08-25).** 투영을 `src/chrome_theme.zig` 로 빼고 Windows 리터럴 여섯을 역할로 바꿨다. **그 뒤에 늘어난 표면들(사이드바 헤더·뷰 바·에이전트 도크)까지 다시 쟀다** — 아홉 자리가 전부 따라온다(§2m.58) | **완료** |
| 후속 | **`platform/macos/` 에 있는 중립 파일 둘을 `src/app/` 로 옮긴다** — `file_tree_backend.zig`(1360줄)·`git_backend.zig`(3013줄). 네이티브 참조 0 이고 `std`·`builtin`·`maru` 만 import 한다. 나머지 셋(`coretext_frame_builder`·`system_text`·`chrome_draw_lowering`)은 진짜로 섞여 있어 **이동이 아니라 분해**라 범위 밖. 공용 폴더(`src/common/`)는 **안 만든다** — 근거·목적지·시점은 [layering-and-portability.md](../layering-and-portability.md) §3.4. ~~**W8 이 끝난 뒤** 독립 PR~~ → **안 옮긴다(결정 2026-08-25).** W8 이 끝나 실제로 해 보니 **"순수 이동" 이 아니었다** — 묶어 두는 것은 폴더가 아니라 **모듈 그래프**다(배럴은 wasm·모바일의 루트이기도 해서 `git_backend` 의 libc 호출 63 개가 따라 들어가 `check-targets` 가 깨진다). 실측 넷과 근거는 [layering-and-portability.md](../layering-and-portability.md) §3.4 "그런데 순수 이동이 아니었다" | **재개 — 파일 트리 완료, Git·text 분리 진행** (§3.4.2, 2026-10-03 사용자 요청) |
| 후속 | **영속 세션 호스트** — named pipe 기반 재설계. 계약 범위 밖 | 미착수 |

## 검증

- W1~W6은 전부 헤드리스라 `zig build test`·`check-boundaries`가 그물이다. Windows 호스트에서 이미 초록이므로
  회귀가 보인다.
- W4의 선행조건은 **해제됐다**(2026-08-16). ConPTY 자식 attach를 이 환경에서 실측으로 닫았다 — 자식 안의
  `mode con`이 넘긴 COORD를 그대로 보고했고, 대화형 왕복·resize·pwsh·"부모에 콘솔 있음"까지 확인했다.
  이전에 "샌드박스 탓"으로 적었던 것은 오판이었고 원인은 우리 spawn 절차였다(계약 §4.1a·§6).
- **W4 백엔드는 `zig build test`가 진짜 자식을 띄워 검증한다** — 크기 일치(attach의 유일한 증거), 대화형
  왕복 2회, resize, 종료 코드 수거, close. 마커 왕복만으로는 부족하다: 자식이 pty에 안 붙어도 마커는
  어딘가로 나오기 때문에, **자식이 본 콘솔 크기 == spawn에 준 크기**가 판정식이다(계약 §6).
- 이 테스트들은 Windows 호스트에서만 컴파일된다. OS 무관한 규칙(커맨드라인 인용·환경 블록·fixture 명령)은
  전부 **OS를 인자로 받는 순수 함수**로 갈라 두어 macOS·Linux CI에서도 두 갈래가 돈다.
- W7 이후의 시각 검증은 macOS와 같은 골든 이미지 경로를 쓰되, Windows는 **WARP 소프트웨어 래스터라이저**가
  있어 GPU 없는 CI 러너에서도 렌더 스모크를 돌릴 여지가 있다(macOS는 실제 window server가 필요해 못 한다).

## Windows 작업과 함께 진행하는 폴더 결합 정리 (2026-10-03)

사용자가 기존 safe-save 계약의 Windows 네이티브 구현과 macOS 경로 결합 정리를 승인했다.
목록·상세 세션 기록 worker는 `src/app`으로 이동했고 양쪽 host가 `maru.app`으로 소비한다
([모듈 연결과 검증](../layering-and-portability.md#341-세션-기록-worker의-실제-공통-계층-이동-2026-10-03)).
Git backend는 `src/app/git/backend.zig`로 이동했다. Chrome 텍스트 아티팩트는
`src/app/chrome_text.zig`로 분리했고 CoreText만 macOS adapter에 유지한다(layering-and-portability.md §3.4.3).
파일 트리 분리는 layering-and-portability.md §3.4.2에 기록했다.
W8.17의 metadata 보존·쓰기·충돌 검사·편집 입력·GUI 저장·외부 변경 감시는 계속 진행 대상이다.

파일 트리 worker도 `src/app/file_tree_backend.zig`로 이동했다. macOS SSH 전송은
별도 host adapter를 초기화 시 주입한다. 검증과 남은 범위는
[layering-and-portability.md](../layering-and-portability.md) §3.4.2가 소유한다.

안전 저장의 native staging은 windows-platform.md §2m.125에 구현·검증을 기록했다.
경로 핸들에 상대적으로 배타 생성·본문 교체·sync·미공개 kernel object 정리를 수행한다.
ACL/owner·부가 stream·속성 복사는 windows-platform.md §2m.133과 §2m.135에서 검증했다.
CAS/commit/rollback과 GUI 연결은 계속 남아 있다.

Windows 뷰 revision 갱신과 여러 view lease의 파생 캐시 수명은 windows-platform.md §2m.140에서
구현·검증했다. 제품 페인트 경로의 실창 수정/역연산 스모크도 추가했다. 일반 파일의 입력·선택·
undo 그룹·저장·dirty-close·외부 감시가 연결된 것은 아니므로 W8.17 완료로 세지 않는다.

실험적 local NTFS 저장 transaction과 native 판정은 windows-platform.md §2m.141에 기록했다.
일반 앱 저장에는 아직 연결하지 않았다. capability·crash 복구·경로 경쟁 검증과
키보드/IME 편집→저장→재열기 실앱 판정이 남아 있으므로 W8.17은 계속 진행 중이다.

열린 KTM 핸들의 실제 결과 조회와 uncertain phase 반영은 windows-platform.md §2m.142에서
검증했다. 모든 실패 타이밍과 프로세스 종료 후 복구, L2 revision 저장 ack는 별도 진행 대상이다.

Windows dispatcher의 native macOS 상수 경로 결합은 windows-platform.md §2m.143과
layering-and-portability.md §3.4.4에서 공통 CLI wire 계약으로 분리했다. POSIX parser와 실행은
macOS adapter에 남는다. Windows persistent host나 W8.17 편집·저장 완료를 뜻하지 않는다.

같은 file ID를 유지한 부모 reparse 전환의 native 조사 재현은 windows-platform.md §2m.144에 기록했다.
제품 begin 경로의 지속·일시적 같은-ID junction fixture와 첫 쓰기 전 namespace fence 판정은
§2m.145에서 검증했다. safe-save 58개와 경로 29개, 다섯 runtime 변이와 별도 binding 제거 변이가
통과했다. capability·crash 복구·모든 실패 타이밍·L2 저장 ack와 일반 편집/저장 실앱 연결은 남아 있다.

L2의 owned 저장 이미지·revision/disk CAS와 opened lifetime/요청 순서, 미확정 결과의 재저장 차단은
§2m.146에서 구현했다. 실험적 native commit/rollback/실제 commit 응답 유실 뒤 재조회 결과를
같은 문서 정책으로 연결했다. 공통 11개, native save 61개와 경로 29개 및 공통/native 각각 다섯
runtime 변이와 별도 두 변이를 검증했다. 일반 입력·GUI 저장·dirty-close·외부 감시와 capability/
crash 복구·실패 타이밍 전체는 남아 있다. W8.17 완료로 세지 않는다.

읽기 전용 일반 파일의 좌우/Home/End 및 primary modifier 이동·Shift 선택·Ctrl+A/C는
§2m.147에서 연결했다. 문서 행 기준 선택/caret projection, allocation-failure 소유권,
실제 창 WM_KEYDOWN 6개/7프레임과 runtime 변이 5회를 검증했다. 일반 쓰기/IME/undo,
GUI safe-save·dirty-close·감시·edit→disk→reopen, 세로/마우스 입력·가로 caret 추종·랩과
긴 행/행 projection 예산은 남아 있다. W8.17은 계속 진행 중이다.

준비 후 문서 권한 변경의 native 커밋 fence는 §2m.148에서 연결했다. 일반 byte commit의
document-bound 우회를 막고, 새 실제 파일 판정 다섯 개로 경로/readonly/disk/reload/uncertain
변경을 거절했다. Native root 66개·경로 29개와 runtime 변이 5회가 통과했다.
일반 편집/저장 연결과 capability·crash 복구·전체 실패 타이밍은 계속 남아 있다.

Writable 문서의 기본 Windows 문자/삭제 입력과 공통 Undo/Redo는 §2m.149에서 연결했다.
공통 명령 28개·Windows 입력 9개, 실제 창 입력 7개와 history 명령 6개의 두 뷰 26프레임,
runtime 변이 5회를 검증했다. 일반 파일은 여전히 읽기 전용이며, 일반 입력→native 저장→
재열기·물리 IME·dirty-close·감시와 capability/crash 복구는 남아 있다. W8.17은 진행 중이다.

최초 읽기 원본의 full ID와 선택 루트·문서 lifetime을 묶는 native grant는 §2m.150에서 구현했다.
14개 native 판정과 권한 검사 제거 변이 5회, 실제 창 입력→native 커밋→디스크 바이트→일반
열기 경로의 독립 재열기/paint를 검증했다. 저장은 fixture 직접 호출이며 원래 뷰는 살아 있다.
저장 시도 부모 DELETE fence는 분리하고, 원본 객체를 전체 128-bit ID로 열어 보관해 편집 중
일반 폴더 rename을 허용한다. 원래 상대 이름이 없으면 저장을 거절한다. GUI adoption 전
capability/crash 복구·일반 Ctrl+S/dirty-close/감시/물리 IME 연결은 계속 해결해야 한다.
일반 파일은 읽기 전용을 유지한다.

저장 요청·grant·native Attempt의 단일 pending 소유권과 commit/rollback/uncertain 정산은
§2m.151의 Controller로 연결했다. 15개 판정, 준비/commit 할당 실패, 적대적 변이 5회와
실제 창의 Controller→native 저장→독립 일반 재열기를 검증했다. GUI Ctrl+S/dirty-close/
감시/물리 IME, capability·crash 복구와 비동기 I/O/notice 연결은 계속 남아 있다.
일반 파일은 읽기 전용이며 W8.17은 진행 중이다.

Windows §2m.152는 6개 native 저장 checkpoint와 두 이미지의 12개 실제 프로세스
강제 종료를 Debug/ReleaseFast에서 검증했다. 커밋 전 원본/커밋 후 저장 바이트, full ID,
owner/group/DACL·생성 시각·속성·ADS와 재시작 뒤 새 저장 준비/abort를 확인하고 적대적
검증 5회를 수행했다. 전원 장애·미저장 백업 복원·capability·일반 GUI 저장/닫기/감시와
물리 IME 완료를 뜻하지 않는다. W8.17은 계속 진행 중이다.

Windows §2m.153은 private native 백업 저장소·공통 record·옛 disk_hash를 유지하는 단일 편집 복원과
양 OS 기본 경로 정책을 연결한다. 17개 집중 판정과 적대적 검증 5회, 두 실제 process crash 뒤 복원/
native save 또는 외부 CAS 거절, 실제 창 복원/undo 4개 추가 프레임을 확인했다. Windows runner의
compiled/passed count 인자도 이제 실제 검사한다. 일반 백업 root/debounce/종료 flush/복원 알림·
purge와 missing/untitled/remote 복원, interrupted-stage 정리·capability·GUI 저장/닫기/감시·물리 IME는
계속 남아 있다. W8.17은 진행 중이다.

§2m.154: Windows 입력의 실제 revision 변경을 백업 debounce에 연결했다. native 저장소 유지보수는
frame당 하나, shutdown 전체 distinct 문서, 실패 재시도/삭제 성공 후 상태 정리/용량 pause를 다룬다.
22개 집중 테스트와 이 수명주기 규칙의 runtime 적대적 검증 5회가 통과했다. 일반 root와 frame/종료
caller 연결, 복원 UI, GUI editable/save/dirty-close/감시·IME는 여전히 W8.17 잔여다.

§2m.155: 기본 LOCALAPPDATA root의 native 상위 핸들 소유를 구현하고 일반 앱 frame/종료 호출을
연결했다. 만기 전에는 폴더를 열지 않으며 view lease 해제 전 flush한다. Native 집중 판정은 27개이고
root 변형 5회 및 실제 창의 앱 helper 변형 5회가 runtime 결함을 검출했다. 실제 UNC share 검증,
복원 알림·accepted-close 삭제·pause 상태바·dirty 앱 재실행·GUI 저장/감시·IME는 계속 진행한다.

§2m.156: native 결과 미정 동안 Undo가 clean처럼 보여도 백업을 보존하고, 실제 결과/ack 확정 뒤
revision 변경 없이 유지보수를 재예약한다. 실제 commit-lost-reply 및 undetermined→rollback의
통합 판정과 clean/readonly 정책 판정을 추가해 30개 집중 gate가 통과했다. 적대적 검증 5회도
runtime 결함을 검출했다. 더 넓은 prepare/편집/crash 시점과 일반 앱 저장·복원·닫기·IME는 남아 있다.

§2m.157: prepare 후 commit 전 Undo가 백업을 삭제하는 실제 결함을 재현했다. L2 Request가
소유한 이미지 수를 epoch별로 추적하고 Windows clean 삭제가 그 수명의 끝을 기다리도록 연결한다.
겹치는 요청·reload 격리·할당 실패·counter 상한, 실제 prepare→Undo→commit/abort를 검증한다.
일반 앱 editable/save/복원·닫기·감시·IME와 더 넓은 process crash 시점은 계속 진행 중이다.

이미지 보호/epoch 해제/count 해제/reload 초기화/결정 뒤 재예약을 각각 깨뜨린 적대적 검증 5회가
runtime 결함을 검출했고 원복 후 shared 14개와 Windows backup 32개가 통과했다.

§2m.158: 앱 수명의 Book으로 일반 파일의 native grant·Ctrl+S·dirty-close를 연결했다.
기존 private root를 생성 없이 조회하고 이전 백업을 편집 전에 복원한다. capability나
복구 조회가 실패하면 readonly이며, 모든 파일의 편집을 허용한 것은 아니다. 집중 host
18개·backup 34개와 10개 runtime mutant 검출이 통과했다. 물리 키보드/IME와 일반
앱 프로세스 종료·재실행, 외부 감시 및 비동기 I/O는 여전히 남아 있다.

§2m.159: 일반 win32-terminal 프로세스의 파일 선택·편집·dirty-close 취소·저장 후 종료와
새 프로세스 재열기를 확인했다. 백업이 있는 미저장 앱 강제 종료 뒤 같은 파일을 다시 선택해
복원을 확인했고 실제 외부 충돌과 버리기도 검증했다. 열린 파일 목록의 자동 재구성은 검증
범위 밖이다. 긴 cwd에 밀리는 비모달 복원 안내를 고쳤고 host 19개 및 5개 runtime mutation
검출이 통과했다. 물리 키보드/IME·외부 감시·비동기 I/O는 계속 남아 있다.

§2m.160: 고정 주소 OVERLAPPED와 selected-handle identity를 가진 비동기 디렉터리 알림
transport를 구현했다. native 이동/종료/생성/수정/copy guard 5행과 aggregation을 포함해
Debug/ReleaseFast 7개, 다섯 runtime mutation 검출이 통과했다. 앱의 directory별 묶음·cap,
debounce/hash 재검증, clean 갱신·dirty 선택 연결은 계속 남아 있다.

§2m.161: full directory identity 공유, 최대 64개 directory cap, 독립 구독 해제와
200 ms trailing debounce를 구현했다. 실제 취소 후 재등록 및 할당 실패 검증을 포함해
Debug/ReleaseFast 14개, 다섯 group runtime mutation 검출이 통과했다. 앱 연결 및
identity/hash 재검증, clean 갱신·dirty 선택 연결은 계속 남아 있다.

§2m.162: 복구로 dirty가 된 문서의 목록 append 실패 후 무승인 close가 실패하는 경로를
제거했다. 앱과 fixture가 같은 slot 선확보 함수를 사용하며 실제 백업의 할당 실패·재시도,
원본과 레코드 보존을 검사한다. host Debug/ReleaseFast 20개와 다섯 runtime mutation
검출이 통과했다. 감시 앱 연결과 비동기 내용 재검증은 계속 남아 있다.

§2m.163: native 읽기 작업자와 Book의 app grant admission/완료를 연결했다. 작업자는
selected root/name/자체 I/O를 소유하고 bytes/hash를 프레임 밖에서 얻는다. 비재사용
source/reader scope로 같은 주소·같은 slot 재생성까지 거절한다. read 11개·host 23개의
Debug/ReleaseFast, 각각 다섯 runtime mutation 검출이 통과했다. 실제 창 fixture에도
worker read를 연결했다. 일반 앱의 hint 예약과 clean 갱신·dirty 선택 UI, 비동기 저장은 남아 있다.

§2m.164: 문서 grant에서 실제 부모 폴더를 pin해 감시 구독을 만드는 Book 경로와,
directory 알림을 살아 있는 개별 lease에 배분하는 검사를 추가했다. volume root를
비재귀 감시하는 오류를 피하며 같은 폴더의 peer 구독도 함께 받는다. 중첩 폴더의
실제 외부 쓰기·해제된 구독·다른 owner·경로/epoch drift·진행 중 저장·동일 bytes의
파일 교체를 검사한다. watch 14개·host 24개의 Debug/ReleaseFast와 각 다섯 compiled
runtime mutation 검출이 통과했다. 일반 앱 프레임 루프의 구독 수명 관리·hint 예약과
clean 갱신·dirty 선택 UI는 아직 남아 있으며, 이 구독 API만으로 연결 완료를 주장하지 않는다.

§2m.165: 공통 edit_commands의 clean 외부 변경 적용과 Windows view의 peer 게시 경로를
추가했다. 동일 prefix/suffix를 남기는 UTF-8 scalar 경계 replacement를 독립 Undo entry로
게시하여 이전 이력과 각 view의 selection을 보존한다. dirty·live save image·uncertain save는
거절하며 BOM/개행 속성·본문 saved hash·BOM 포함 raw disk hash를 함께 갱신한다. 할당 실패
시 본문·선택·이력·포맷·hash를 보존한다. 포맷만 바뀌면 텍스트 이력은 추가하지 않는다.
공통 명령 32개와 native host 25개의 Debug/ReleaseFast, 다섯 compiled runtime mutation
검출과 실제 창의 외부 내용 표시 2프레임·커서·Undo 검사가 통과했다. 빌드·문서 링크·
target·전체 경계 검사도 통과했다. 일반 앱의 구독 수명 관리·자동 예약과 dirty 선택 UI는
계속 남아 있다.

§2m.166: external_changes.Coordinator를 일반 앱 프레임 루프에 연결했다. 새 editable
view의 부모 폴더를 구독하고 native hint 뒤 단일 worker 읽기를 예약하며 현재 ticket과
실제 raw hash를 확인한다. 최초 읽기로 open→구독 사이 공백을 좁힌다. 닫힌 view는 구독을
해제하고 늦은 결과를 버린다. stale read·SourceBusy·SaveBusy·일시적 할당 실패는 200ms
뒤 재시도하고 cap/영구 실패는 해당 구독을 명시적으로 중단한다. clean은 공통 최소 edit로
갱신하고 dirty는 본문·저장 기준을 유지하며 안내한다. 같은 hash의 dirty 안내는 합친다.
기존 notice/confirm이 열려 있으면 새 안내를 대기시킨다. 최초 구독의 할당 실패도 기존 결과를
정산하며 200ms 뒤 재시도하고 구독 allocation prefix의 소유권 정산을 검사한다.
host 32개의 Debug/ReleaseFast와
다섯 compiled runtime mutation 검출이 통과했다. 실제 일반 앱에서 자동 갱신과 dirty 보존·
저장 충돌 거절·외부 원본을 유지한 버리기 종료를 확인했다. dirty reload/keep/compare 선택,
비동기 저장·초기 open과 물리 입력·IME는 남아 있다.

§2m.167: dirty 감시 알림의 Compare/Keep/Reload/Cancel을 일반 앱에 연결했다. Compare와
Reload는 단일 native reader의 새 읽기를 우선 예약하고 stale revision은 200ms 뒤 재시도한다.
Keep/Cancel은 저장 기준을 바꾸지 않는다. 비교는 소유된 두 본문과 공통 diff 행 대응·번호·색을
읽기 전용으로 표시하며 Esc로 돌아간다. Reload는 Undo 가능한 공통 edit로 적용하고 기존
이력을 보존한다. 공통 34개·host 35개 Debug/ReleaseFast와 각 경로 다섯 runtime mutation,
실제 앱의 비교·복귀·reload·keep 후 저장 거절·discard를 확인했다. 저장 시점의
Compare/Overwrite/Reload와 비교 scrollbar drag·크기 변경 UX, 비동기 저장·초기 open,
물리 입력·IME와 나머지 Windows 지원은 계속 남아 있다.

§2m.168: 저장 시점의 Compare/Overwrite/Reload/Cancel과 성공 후 원래 닫기 대상을 이어가는
경로를 연결했다. 명시적 overwrite의 관측 native raw hash와 이전 document CAS를 분리해
실패 전에 저장 기준을 바꾸지 않는다. 최초 native identity·경로·metadata 계약은 유지한다.
선택 중에는 입력을 잠그고 Esc로 취소하며 늦은 worker 결과를 정산한다. 공통 요청 16개·host
39개 Debug/ReleaseFast와 overwrite/취소 각 다섯 runtime mutation, native 회귀 66/14/15개가
통과했다. 일반 앱의 overwrite/compare/reload·닫기와 실제 writer를 유지한 대기/Esc 취소를
확인했다. native 쓰기·commit 및 초기 open의 UI I/O, 다중 파일 닫기 전체 GUI 검증과 나머지
Windows 계획은 계속 진행 대상이다.

§2m.169: Registry 접근 없는 불변 저장 이미지와 main-thread export 검증을 분리했다.
native prepared 이미지와 commit/ack 요청을 full lease·epoch·sequence·raw hash로 대조한다.
공통 요청 18개와 native safe-save 66개가 Debug/ReleaseFast에서 통과했고 source hash·checksum·
epoch·sequence·lease의 다섯 compiled runtime mutant를 검출했다. native 쓰기·commit의
worker 이관과 main-thread 승인 왕복, 최초 open 비동기화는 아직 진행 대상이다.

§2m.170: worker가 bytes/name/root 및 자체 I/O를 소유해 실제 native 준비·쓰기·flush를
실행한다. 결과 commit은 main-thread 원래 grant/request를 다시 검증한다. 새 gate 9개가
Debug/ReleaseFast에서 통과했고 최초 identity·source hash·checksum·copied owner·상한의
다섯 compiled runtime mutant와 실패 보존 제거의 추가 변형을 검출했다. 실제 partial write의
poisoned attempt와 실패를 결과로 유지해 main-thread rollback 정산으로 넘긴다. 일반 앱 배선, 비동기 commit/취소 정산과
초기 open 이관은 이어서 구현한다. 전체 비동기 저장 완료로 세지 않는다.

§2m.171: controller가 고정 주소의 Preparation에서 worker를 시작하고 preparing 상태에서
문서 이미지·슬롯을 보유한다. 취소 후에도 결과를 drain하고 rollback 미확정이면 native
attempt와 두 이미지를 유지한다. 취소 이미지는 commit으로 되살리지 않는다. controller
23개·worker 9개 Debug/ReleaseFast와 다섯 compiled runtime mutation 검출이 통과했다.
일반 앱 Book/UI는 아직 동기 저장 API를 사용하며, 비동기 commit/abort·정산과 앱 배선,
초기 open 이관 및 나머지 Windows 범위는 계속 진행한다.


§2m.172: 일반 앱 Ctrl+S와 Save-close가 Book의 준비 worker/poll 경로를 사용한다.
완료 receipt의 committed/ack를 확인한 뒤 닫기를 이어가며 Esc 취소는 이미지와 native
소유권 drain 후 정산한다. host 47개 Debug/ReleaseFast, controller 23개와 다섯 compiled
runtime mutation 검출이 통과했다. 격리 실제 앱의 대상 입력 큐로 Ctrl+S·Save-close와
BOM/CRLF 보존·종료를 확인했다. 물리 입력·IME, 비동기 commit/abort/정산·초기 open,
충돌 overwrite의 worker 이관과 다중 파일 닫기의 충돌·취소 GUI 검증은 계속 진행 대상이다.
다중 dirty 문서의 정상 Save-close는 격리 실제 앱에서 두 본문 저장·BOM/CRLF 및 LF 보존과
프로세스 종료를 확인했다. 이 성공 검증은 충돌·취소 조합을 증명하지 않는다.

§2m.173: native rollback/outcome worker가 독립 준비 이미지와 attempt의 소유권을 이동받아
Registry 없이 실행한다. 실패·unknown 결과도 handle/image/phase를 반환하고 미소비 결과의
deinit을 거절한다. native 7개 Debug/ReleaseFast와 다섯 compiled runtime mutant 검출을
통과했다. controller/앱의 취소·reconcile 연결, native commit 승인 왕복과 cleanup 이관,
초기 open 및 나머지 Windows 범위는 계속 진행한다. 앱의 비동기 rollback 완료로 세지 않는다.
