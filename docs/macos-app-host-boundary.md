# macOS 앱 호스트 경계

이 문서는 실제 macOS 제품 앱을 만들기 직전에 Swift와 Zig가 어디서 만나는지 정한다. 목적은 빨리 창을 띄우는 것이 아니라, 제품 앱이 smoke 전용 Objective-C bridge를 복제하거나 PTY/runtime 책임을 AppKit 쪽으로 끌고 가지 않게 하는 것이다.

## 정책: 네이티브 레이어는 최대한 얇게

**Swift/Objective-C 같은 네이티브 의존성은 최소화한다.** 플랫폼에 묶이지 않는 모든 로직(계산·결정·정책)은 Zig에 두고 `std.testing`으로 테스트한다. 네이티브 레이어는 다음만 한다: AppKit/window lifecycle, focus/input, Metal draw 호출, ABI record marshaling. **비즈니스 로직·수치 계산·상태 결정은 네이티브에 두지 않는다** — 네이티브엔 단위 테스트 프레임워크가 없어 회귀를 못 막고, Linux/headless에서 재사용도 안 되기 때문이다.

판단 기준: "이 코드를 테스트하려면 window/run loop가 필요한가?" 아니라면 Zig로 간다. 예: 창 backing 픽셀 → grid(cols/rows) 계산, resize 중복 방지(같은 size+scale skip), backing scale → 폰트 device 픽셀 크기는 모두 Zig가 소유하고(app session의 `gridFromBacking`·resize dedup, `renderer.deviceFontSizeFromMilli`), Swift는 AppKit 값(backing 픽셀·scale)만 모아 ABI로 넘긴다. grid 계산은 별도 export로 빼지 않고 app session이 resize 처리 중 자기 cell 메트릭으로 내부에서 직접 한다(Swift가 부르는 grid helper export는 없다). **퀵 터미널 오버레이 패널의 보임/숨김 사각형**도 같은 원칙이다: 위치별 기하(top/bottom/left/right 가장자리 슬라이드·center 페이드·두께 비율)는 순수 모듈 `quick_terminal_geometry.zig`의 `compute`(세션·AppKit 없이 단위 테스트가 못박음)가 소유하고, Swift는 대상 화면 `visibleFrame`만 `maru_macos_app_session_quick_terminal_frames`로 넘겨 세션의 **현재** config로 계산받는다(매 토글 라이브 — 세션-불변 스냅샷 캐시 금지 → 설정 변경 즉시 반영, config-gui.md §6.10). 화면 선택(`screen=main`은 `NSScreen.screens.first`=주 디스플레이, `mouse`는 포인터 화면)만 window/screen 열거가 필요해 Swift에 남는다.

**웹 패널(WKWebView) 예외**: "네이티브 뷰 비사용"의 예외로 리치 웹 패널을 둔다. **예외의 닫힌 열거·근거(diff는 예외가 아니라 GPU 셀)는 [docs/control-plane.md] §1을 단일 출처로 둔다** — 여기 중복하지 않는다. 호스트 경계 관점의 규율만 여기 둔다: Swift는 WKWebView API 호출(`load`·`evaluateJavaScript`·`takeSnapshot`)만, **JSON-RPC 라우팅·디스패치·프레이밍·신뢰 게이트 판정은 Zig**(테스트 가능성·이식성). 웹 패널도 "OS 호출만 네이티브, 정책 0" 규율을 지킨다.

**컨트롤 플레인 collector Zig↔Swift 분담**: 세션 상태 수집(sessions.list 등의 데이터)은 2층이다(단일 출처 [docs/control-plane.md] §2). **Swift 몫은 열거뿐** — 살아있는 창(`windows`+`quick`)을 순회하며 창마다 per-session collect ABI를 호출한다(전역 AppSession 레지스트리가 아직 Zig에 없기 때문). **평탄화·정책은 Zig** — `AppSession.collectSessionInto`(A1, `app_session.zig`)가 한 세션의 tabs→panes→terms 트리를 walk해 OS-중립 `SurfaceDto[]`+`WindowMembershipSnapshot`으로 만들고(좌표·focused·cwd·git_branch·agent·at_prompt 3상 매핑, 코어 read는 `core_mutex` 아래 복사만 — §5), scope 필터·직렬화는 L2 순수 코어(`control_surface.zig`)가 소비한다. Swift는 DTO 필드 해석·wire 인코딩을 하지 않는다("OS 호출만 네이티브, 정책 0").

**A2b 라이브 서버 collect ABI + 스레딩(배선 완료)**: 컨트롤 소켓·accept 스레드·메인 marshal 큐는 Zig(`control_server.zig` generic L4 + `app_host_abi.zig` collect 조립·auth·dispatch)가 전부 소유한다. Swift는 세 ABI만 부른다 — launch서 `maru_macos_control_server_start()` 1회, 매 frame tick(`tickAppSession`)에 `maru_macos_control_server_drain(refs, count)`(살아있는 창+quick을 `MaruControlSessionRef{app_session, window_id=창 토큰, window_kind}`[]로 채워 넘김 — **열거만**), terminate서 `maru_macos_control_server_stop()`(accept 스레드 join·소켓 close). Swift는 collect 조립·auth 판정·wire를 하지 않는다(§2 열거만·정책 0). **스레딩**: accept 스레드는 요청을 메인 frame loop로 marshal하고(§5, [io-render-threading.md] §8.8 lock-order 준수 — accept 스레드는 core_mutex 미보유로만 큐 push/wait), 메인 drain이 `collectSessionInto`(surface `core_mutex` 아래 복사만)로 스냅샷을 조립·응답한다. 응답 write는 accept 스레드에서 락 밖(§5). ABI 스레드 규칙("PTY reader/event queue를 main thread에 안 묶는다")과 대칭 — accept 스레드도 main에 안 묶이고 marshal 큐로만 통신한다.

## 현재 결정

- Swift는 지속 실행되는 `NSApplication`을 소유한다.
- Swift는 window/tab/split lifecycle, focus, `keyDown:`, close/menu/preferences, IME, accessibility 같은 macOS UX를 소유한다.
- **창 타이틀바 chrome(신호등 inset 포함)은 platform(Swift) 책임이다.** `MaruAppHost`의 placeholder window가 네이티브 타이틀바를 숨기되(`titlebarAppearsTransparent=true`, `titleVisibility=.hidden`, `titlebarSeparatorStyle=.none`) 신호등(닫기·최소화·확대)은 남기고, `styleMask`에 `.fullSizeContentView`를 더해 콘텐츠(사이드바 chrome)가 창 top까지 차게 한다. **베이스/결정**: Apple HIG의 "신호등은 유지하고 콘텐츠를 타이틀바 영역까지 끌어올린다" 패턴을 베이스로, maru의 Zig+GPU chrome 전략(네이티브 뷰 비사용)과 부합하게 골랐다 — 사이드바 헤더(검색바·view options·새 워크스페이스 아이콘)를 신호등 옆/아래에 maru chrome으로 그린다. **OS-중립 헤더 레이아웃(아이콘·검색 위치 = `chrome/components/sidebar.zig` headerHit)은 Zig**가 소유하고, Swift는 신호등을 남기는 창 스타일 inset만 책임진다(이식 시 타깃별 창 chrome으로 교체 — [layering-and-portability.md](layering-and-portability.md) 참조). **창 이동/확대도 같은 분담**: 네이티브 타이틀바를 숨겨 콘텐츠가 마우스를 받으므로 `MaruMetalTerminalView.mouseDownCanMoveWindow=false`로 자동 창-드래그를 끄고, **'어디가 드래그/더블클릭-확대 영역인가'(헤더·타이틀바 띠의 빈 곳)는 Zig**(`isWindowDragRegion` → ABI `is_window_drag_region`)가 hit-test하며, **동작(performDrag/zoom)만 Swift**(AppKit 호출)가 한다 — 위치 판정은 OS-중립, OS 호출은 platform. 숨긴 타이틀바 높이만큼 터미널 영역을 아래로 들이는 **타이틀바 띠**(`titlebar_strip_px`)도 Zig가 termRect 단일 출처로 적용(신호등·아이콘 줄과 탭 바가 안 겹치게).
- Zig는 `PtySession`, `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, keybinding resolver, renderer frame 조립, 그리고 grid 계산·resize 중복 방지·device 픽셀 메트릭 같은 플랫폼 비의존 로직을 소유한다.
- Swift는 terminal storage, PTY file descriptor, renderer atlas/resource를 직접 만지지 않는다.
- Swift가 Zig에 넘기는 값은 `src/platform/macos/app_host_abi.h`의 fixed-width C ABI record만 사용한다. cols/rows 같은 파생값은 Swift가 계산하지 않는다. Swift는 backing 픽셀·scale만 resize 이벤트로 넘기고, app session(Zig)이 자기 cell 메트릭으로 grid를 내부에서 계산한다.
- Objective-C `*.m` smoke bridge는 삭제하지 않는다. 제품 앱 회귀와 low-level AppKit/Metal/CoreText 회귀를 분리해서 보기 위한 regression smoke로 남긴다.

## 닫기 확인(실행 중 명령 보호)

실행 중인 포그라운드 명령이 있는 터미널을 실수로 닫아 작업/데이터를 잃지 않도록, 닫기 전에 확인 모달을 띄운다. **창 하나 닫기**는 그 닫기가 teardown할 Term에 실행 중 명령이 있을 때만 묻고, **앱 전체 종료(Cmd+Q)**는 열린 모든 창·탭이 함께 사라져 더 파괴적이라 실행 중 명령 유무와 무관하게 **항상** 묻는다.

> **현재 동작과 후속 계획:** 현재 `applicationWillTerminate`는 workspace를 저장한 뒤 모든 app session과 live PTY를
> teardown한다. [영속 터미널 세션 호스트](persistent-session-host.md) P4가 종료 gate를 통과하면 앱 전체 quit은
> terminal runtime detach로 바뀔 수 있지만, Term/Workspace의 명시 close는 계속 terminate다. 그 전까지 이 절의
> 현재 종료 확인·dirty file 보호·teardown 계약이 제품 동작의 단일 기준이다.

**종료 중 창 숨김과 단계 계측**: `applicationWillTerminate`의 정리(mermaid 회수 → 컨트롤 서버 정지 → workspace 저장
→ session/PTY teardown)는 전부 **메인 스레드에서 동기로** 돈다. 그동안 이벤트 루프가 멈추므로 창이 떠 있는 채면 그
멈춤이 사용자에게 모래시계(응답 없음)로 보인다. 그래서 정리보다 **먼저** 모든 일반 창과 quick을 `orderOut`으로 화면에서
내린다(iTerm2·Terminal.app과 같은 순서). `orderOut`은 창을 화면에서 뺄 뿐 객체를 해제하지 않으므로 뒤따르는
teardown·요약이 읽는 window 참조는 그대로 살아 있고, `applicationShouldTerminateAfterLastWindowClosed`는 false라 숨김이
종료를 재유발하지도 않는다. **전체화면(native `.fullScreen`) 창은 예외로 숨기지 않는다** — 전체화면 창을 `orderOut`하면
macOS가 그 space를 없애며 이전 space로 전환하는데, 종료 직전에 그 애니메이션이 끼어들면 체감이 오히려 나빠지고,
전체화면은 뒤에 드러날 다른 창도 없어 숨겨서 얻을 것이 없다(workspace 저장이 전체화면 frame을 건너뛰는 것과 같은 결).

숨김에는 딸린 계약이 하나 더 있다. `orderOut`은 `isKeyWindow`를 false로 만들고, workspace의 `active-window` 마커(M3e —
다음 실행이 그 창을 다시 focus)는 그 값으로 정해진다. 그래서 창을 내리기 **직전**의 key 창을 붙잡아 두고 저장이 그것을
우선 본다. 판정 규칙과 이유는 `TerminationWindowPolicy`(`src/platform/macos/TerminationWindowPolicy.swift`)가 소유하고
`tests/macos_termination_window_policy.swift`가 고정한다 — 이 규칙이 없으면 종료할 때마다 활성 창 정보가 사라져 복원이
항상 첫 창을 고른다. 이 변경은 **체감**만 없애고 실제 정리 시간은 그대로이므로, 각 단계 경과를 `TerminationTiming`
(`src/platform/macos/TerminationTiming.swift`)에 기록해 종료 요약에 `quit_hide_windows_ms`·`quit_mermaid_ms`·
`quit_control_stop_ms`·`quit_save_workspace_ms`·`quit_teardown_ms`·`quit_total_ms`로 남긴다. 실행되지 않은 단계도 0으로
실려 요약 필드 집합은 실행 경로와 무관하게 같은 모양이다. total은 요약을 쓰는 시점에 확정하므로 단계 합과의 차이가
단계로 나누지 않은 잔여 시간을 뜻한다.

요약이 나가는 자리도 이 계측의 일부다. 아티팩트 경로(`zig-out/maru-macos-app/app.summary.txt`)는 저장소 상대 경로라
개발/CI(저장소 cwd)에서만 쓸 수 있고, `.app`을 Finder/Dock으로 실행하면 cwd가 `/`여서 쓰기가 실패하는 데다 stdout/stderr도
보이지 않아 요약이 통째로 사라진다. 정작 종료 지연이 문제되는 것은 그 실사용 경로이므로, 쓰기가 실패하면
`~/Library/Logs/maru/app.summary.txt`로 폴백한다. 기존 경로가 성공하는 개발/CI에서는 이 분기를 타지 않아 아티팩트 계약은
그대로다.

**검증**: 시간 측정 자체는 실제 종료에서만 재현되므로 host 배선은 수동 E2E이고, 필드 이름·순서·0.1ms 반올림 같은 표현
규칙은 `tests/macos_termination_timing.swift`가 결정론적으로 고정한다.

- **베이스/결정(사실상 표준)**: iTerm2·Terminal.app·Ghostty는 닫으려는 surface/창에 **셸이 아닌 실행 중 프로세스**가 있으면 닫기 확인 시트/다이얼로그를 띄운다. maru도 같은 관례를 택한다 — 단, 다이얼로그는 네이티브 NSAlert가 아니라 **maru 자체 오버레이**(`chrome/components/confirm.zig`)로 통일해 모든 닫기 경로에서 같은 룩/키(Enter·Y=닫기, Esc·N=취소)를 쓴다.
- **트리거 판정("무엇이 실행 중인가")**: 코어의 `TerminalCore.cursorIsAtPrompt()`(OS-중립)로 판정한다 — **셸 통합(OSC 133 semantic prompt)** 상태와 **alt 화면** 여부만 본다. alt 화면(vim·claude 등 풀스크린 TUI)이면 프롬프트 아님(=실행 중), 아니면 `semantic_state`로: `prompt`(A~B)·`input`(B~C)=프롬프트, `command`(C~D)·`unknown`=프롬프트 아님. 닫기 확인은 `!cursorIsAtPrompt()`를 "실행 중 명령 있음"으로 쓴다(`termHasRunningJob`; 단 `process_state==exited`·attach 전이면 명령 없음으로 단락). `ProcessState`는 "셸 살아있음"만 알고 "명령 실행 중"은 모른다.
  - **레퍼런스 간 선택(베이스/결정)**: 세 레퍼런스는 판정 **메커니즘**이 다르다 — iTerm2·Terminal.app은 포그라운드 프로세스 **이름을 안전 목록과 대조**하고, Ghostty는 **셸 통합**(`Terminal.cursorIsAtPrompt`)을 쓴다. maru는 **Ghostty 모델**을 택했다. 근거 둘:
    1. **이식성**(로드맵 목표): 프로세스/pgid syscall이 없어 판정이 100% OS-중립 코어에 있다 → Linux·Windows·web에 그대로 이식된다. 특히 Windows ConPTY엔 "tty의 포그라운드 프로세스 그룹" 개념 자체가 없어 pgid 방식은 이식 불가이고, web(원격/소켓)엔 클라이언트에 프로세스가 없어 OSC 133만이 유효하다. Windows Terminal도 OSC 133 기반이다.
    2. **정확성**: 옛 pgid 방식(`tcgetpgrp(master) ≠ 셸 child_pid`)은 "셸이 곧 child_pid이고 포그라운드 그룹 리더"라는 전제에 기댔는데, maru는 셸을 `login(1)`으로 감싸고(전체 로그인 세션) macOS `login`은 셸을 **fork**한다 — child_pid는 login이고 실제 셸은 login의 자식이자 **자기 pgrp 리더**라, idle 프롬프트에서도 `tcgetpgrp ≠ child_pid`가 **영구히** 참이 되어 "아무 명령 없는데 닫기 확인이 뜨는" 오확인을 냈다. 셸 통합은 이 프로세스 위상(login-fork)에 면역이다.
  - **폴백 없음(Ghostty와 동일)**: 셸 통합이 없는 셸은 `semantic_state=unknown`이라 보수적으로 "프롬프트 아님"(확인을 띄움)으로 본다 — 데이터 손실 방지 우선. maru는 기본 zsh에 OSC 133 통합을 주입하므로(`src/platform/macos/shell_integration.zig`) 정착한 idle 프롬프트는 항상 `input`이라 오확인이 없다. 명세: freedesktop semantic-prompts.md(FinalTerm 발). 단일 출처: `src/terminal/core.zig` `cursorIsAtPrompt`.
  - **원격/중첩(ssh·docker) 트레이드오프(OSC 133 신뢰의 필연적 귀결, Ghostty와 동일)**: `ssh`로 들어간 원격이 OSC 133을 emit하면 그 마커가 파이프로 흘러와 **로컬** `semantic_state`를 갱신한다. 결과는 오히려 더 정밀하다 — 원격이 명령을 돌리면(C 전달) `command`→확인, 원격이 idle 프롬프트면(B 전달) `input`→확인 없음(원격에 도는 게 없으니 로컬 idle과 동치). 통합 없는 원격은 로컬이 `ssh` 실행 때 찍은 `command`가 유지돼 항상 확인(보수적). 옛 pgid 방식은 ssh를 늘 포그라운드 pgrp로 보고 원격 idle에도 무조건 확인했었다 — 새 방식이 "원격이 실제 실행 중일 때만" 확인하므로 통합 원격에선 더 정확하다. 대가: 통합 원격의 idle 프롬프트에서 닫으면 확인 없이 연결이 끊긴다(도는 명령은 없음).
  - **락**: `cursorIsAtPrompt`가 읽는 `semantic_state`/`alt_active`는 reader 스레드가 `core.write`로 갱신하므로 `termHasRunningJob`은 **`lockCore` 아래**에서 읽는다(surface.zig 불변식·torn read 방지).
- **판정 범위**: 그 닫기가 **실제 teardown할 Term들**만 검사한다(과도하게 넓게/좁게 묻지 않게 cascade를 따라감 — `app_session.zig` `closeTargetHasRunningJob`). Term ✕=그 Term, pane collapse=그 pane의 Term들, 워크스페이스/창=그 탭(마지막이면 세션 전체)의 모든 Term.
- **in-app 닫기 경로**(Cmd+W/메뉴 `close_tab`·`close_term`, 사이드바 ✕, 탭바 ✕): `requestClose(target)`가 게이트다 — 실행 중 명령이 있으면 확인 모달을 띄우고 닫기를 보류(`pending_close`), 없으면 즉시 닫는다. 모달의 Enter/Y=`confirm_accept`→보류한 닫기 실행, Esc/N=`confirm_cancel`→버림(chrome 라우팅→`dispatchChromeAction`). **단 그 닫기가 세션 전체(마지막 탭 cascade)를 닫고 그 창이 앱의 마지막 창이면**(`resolveCloseScope`==`.session` && host가 주입한 `is_last_window`) 창 하나 닫기가 아니라 앱 종료이므로, 실행 중 명령 게이트를 건너뛰고 **Cmd+Q와 동일한 `requestAppQuit` 종료 확인**("maru를 종료할까요?")을 띄운다(아래 "앱 전체 종료"와 합류; 웹뷰 탭도 같은 `close_term` 경로라 마지막 탭이면 동일하게 확인). 마지막 창 여부는 Zig 리프 세션이 형제 NSWindow를 모르므로 `maru_macos_app_session_set_last_window`(ABI v110)로 host(Swift)가 `windows.count`를 매 tick 주입한다(기본 false=옛 조용히 닫기로 안전 폴백; quick 스크래치는 앱 종료 단위가 아니라 항상 false).
- **보류한 닫기의 표적 안정성**: `requestClose`는 **진입점**만 `pending_close`에 담고, `confirm_accept`가 실행 시점의 `resolveCloseScope`로 범위를 다시 푼다(판정 `closeTargetHasRunningJob`과 실행 `executeClose`가 같은 cascade를 공유 — "묻고 닫는 대상 일치"). 그래서 모달이 뜬 동안 활성 탭/pane/Term이 바뀌면 재해석된 표적이 사용자가 본 것과 달라져 **엉뚱한 탭/pane이 닫힐 수 있다**(데이터 손실). 이를 방어가 그때 무효화해 안전하게 abort한다(`.window`=세션 전체는 대상 불변이라 유지): 트리 변경(reap 직전)과 포커스 이동(`switchTab`/`focusPane`/`focusTerm`의 **실제 변경** 시) 모두 `invalidatePositionalPendingClose`가 보류를 무효화한다. 사용자는 새 상태에서 다시 닫으면 된다.
- **파일 도크 종료 보호**: 세션 전체를 없애는 모든 경로는 terminal job 확인보다 먼저 `hasProtectedFilePanelsForExit`를 공유한다. dirty/dirty-sync/conflict/source-edit entry 또는 close/save transaction이 있으면 일반 종료 confirm으로 바꾸지 않고 notice와 함께 fail-closed한다. 빨간 버튼, in-app session cascade, `latchSessionClose`, 마지막 terminal 자동 종료가 같은 gate를 쓰며, 보호 상태가 해소되면 자동 종료 latch를 재평가한다. Swift host도 모든 non-OK tick 결과에서 native teardown **직전** ABI getter를 다시 읽는다. protected normal/quick surface의 tick fault는 마지막 정상 frame과 session/WKWebView를 유지하고 다음 tick을 재시도한다. focus/notice 부수효과는 surface별 fault rising edge에서 한 번만 실행하고 정상 tick 또는 보호 해소에서 재무장해 persistent fault의 frame-rate 반복을 막는다. quick의 `chrome`/`minimal-tabs` 변경도 보호가 해소되기 전에는 파괴적 재생성을 보류한다.
- **macOS 빨간 닫기 버튼/창 단위 닫기**: AppKit `windowWillClose`는 이미 닫히는 중이라 가로챌 수 없으므로, `windowShouldClose`에서 게이트한다. **마지막(유일) 일반 창의 빨간 버튼은 앱 종료**라, `request_window_close`(실행 중 명령 게이트) 대신 `NSApp.terminate`(다음 run loop로 defer해 should-close 재진입 회피)를 불러 아래 "앱 전체 종료"의 `requestAppQuit` 종료 확인으로 합류하고 `false`를 돌려 닫기를 **보류**한다(확정 시 `applicationWillTerminate`→`shutdownAppSession`이 창을 닫고, 취소면 창 유지). **멀티 창의 비-마지막 창만** `maru_macos_app_session_request_window_close`(ABI v65) 게이트를 탄다 — 실행 중 명령이 있으면 Zig가 확인 모달을 열고 1(deferred)을 돌려주고 Swift는 `false`로 **보류**하며, 확정 시 세션 종료를 latch(`ended_seen`+`process_state=exited`)해 다음 tick의 `summary.ended`를 본 Swift가 `closeWindowOrQuit`으로 그 창만 닫는다(프로그래밍적 `close()`라 `windowShouldClose` 재호출/재확인 루프 없음). 실행 중 명령이 없으면 0 → 평소대로 닫는다(`windowWillClose`가 teardown).
- **앱 전체 종료(Cmd+Q/메뉴 "Quit maru"/Dock·로그아웃)**: 창 하나가 아니라 **열린 모든 창·탭의 세션이 함께 사라지므로**, 창 닫기와 달리 실행 중 명령 유무와 무관하게 확인 모달을 띄운다(사용자 결정 2026-06 — iTerm2 "Confirm Quit"의 *항상* 모드 모델; 모달 문구·버튼은 "maru를 종료할까요?"/"종료"·"취소"). 단, 파일 도크 보호 상태가 있으면 일반 confirm보다 앞에서 종료를 취소한다. AppKit `terminate:`는 `windowShouldClose`를 거치지 않으므로 `applicationShouldTerminate(_:)`에서 가로챈다. Swift는 `maru_macos_app_session_has_protected_file_panels`(ABI v126)로 모든 일반 창과 quick session을 요청 시점에 순회하고, 일반 confirm 확정 직전에도 다시 순회해 그 사이 다른 창에서 시작한 편집까지 막는다. 일반 창이 0개이고 quick이 숨겨져 `activeSurface == nil`이어도 quick을 먼저 열거한다. 보호 세션은 앞으로 가져와 `request_app_quit`의 notice+cancel을 실행한다. 보호가 없으면 선택한 세션에 `maru_macos_app_session_request_app_quit`(ABI v90)로 모달을 열고(`pending_quit`) `.terminateLater`를 돌려준 뒤, 모달 확정/취소가 다음 tick `FrameSummary.quit_decision`(0=대기·1=accepted·2=cancelled)에 latch되면 Swift가 `NSApp.reply(toApplicationShouldTerminate:)`로 종료를 진행/취소한다. **명시적으로 마지막 창을 닫는 제스처(Cmd+W·사이드바/탭바 ✕·빨간 버튼)는 이 종료 확인으로 합류한다**. 인앱 경로(⌘W/✕)는 보류된 terminate가 없으므로, 모달 확정 시 `drainQuitDecision`이 `NSApp.terminate`를 시작하고 취소면 유지한다. 빨간 버튼 경로는 `quitConfirmPending` 분기가 `NSApp.reply`로 마무리한다. 셸이 스스로 종료해도 파일 도크 보호가 있으면 `file_panel_exit_held`로 창을 유지하고, 보호가 없을 때만 기존처럼 재확인 없이 닫는다. smoke 모드와 런치 초기 에러는 무인 hang 방지를 위해 `.terminateNow`다.
- **종료 보류 중 다른 모달이 열리면 종료를 supersede한다**: 종료 확인(`pending_quit`)이 떠 있는 채로 리셋/닫기 모달이 열릴 수 있다 — 메뉴 마우스 클릭(`reset_defaults` 등)은 `any_overlay_open` 키/휠 게이트 밖이라 종료 보류를 가로챌 수 있다. 이때 `confirm_accept`가 `pending_quit`을 최우선 분기하므로, 그대로 두면 사용자가 연 모달("초기화")을 확정해도 엉뚱하게 앱이 종료되고 host가 `reply`를 못 받아 종료 보류가 안 풀린다. 그래서 모든 confirm 모달의 단일 chokepoint인 `showConfirmButtons`가 새 모달을 열기 전 **기존 `pending_quit`을 먼저 `.cancelled`로 supersede**(→ 다음 tick에 host가 `NSApp.reply(false)`로 종료 취소·앱 유지)한다 — "한 번에 한 모달" 불변식을 UI 게이트가 아니라 상태머신에서 강제(code-review medium 후속). `requestAppQuit`은 이 chokepoint 뒤에 `pending_quit`을 세워 자기 종료를 취소하지 않는다.
- **검증**: 술어(`cursorIsAtPrompt`)는 `src/terminal/core.zig` 단위 테스트가 각 `semantic_state`(prompt/input/command/unknown)와 alt 화면 진입/이탈을 OSC 133 시퀀스 write로 **결정론적**으로 증명한다. 닫기 라우팅(`termHasRunningJob`→모달/즉시)은 `app_session.zig` 단위 테스트가 활성 Term 코어의 `semantic_state`/`alt_active`를 직접 세팅해 네 경우(input=즉시 닫힘, command=모달+보류, alt=모달, unknown=보수적 모달)로 증명한다 — 프로세스/pgid를 안 쓰므로 job-control 셸이 필요 없다(닫기를 메커니즘으로만 쓰는 탭/pane/Term 수명 테스트는 `markAllTermsAtPrompt`로 idle 셸을 흉내 낸다). 모달 흐름(accept/cancel→실행/버림)은 `app_session.zig`가 키 경로로 증명한다. **마지막 창 종료 확인 합류**는 `app_session.zig` 단위 테스트가 `is_last_window`를 직접 세팅해 두 분기를 증명한다: `is_last_window=true`+세션 닫기→`requestAppQuit`(pending_quit·모달·`ended_seen` 미latch, confirm_accept→quit_decision=.accepted), `false`(비-마지막/기본값)+세션 닫기→종료 확인 없이 `ended_seen` latch. 컴포넌트(`confirm.zig`)·라우팅(`host.zig`)은 헤드리스 테스트. **host 배선(마지막 창 판정 주입·`windowShouldClose` terminate 합류·`drainQuitDecision` 인앱 terminate 시작)은 수동 E2E** — 단일 창에서 (1) idle 프롬프트로 ⌘W → "maru를 종료할까요?" 확인, (2) 빨간 버튼 → 같은 확인, (3) 웹뷰 탭이 마지막 탭일 때 ⌘W → 같은 확인, (4) 취소 시 앱·창 유지, (5) 셸 `exit`는 확인 없이 종료, (6) 멀티 창에서 비-마지막 창 닫기는 종료 확인 없이 그 창만 닫힘. 실행 중 명령이 있는 비-마지막 창을 빨간 버튼으로 닫으면 기존 "이 창을 닫을까요?" 모달(확정 시 닫힘·취소 시 유지).

## 세션 자동 종료: 정상 종료 vs 비정상 시작 사망(창 유지)

셸이 종료되면 `app_session.zig` tick이 `allTabsTerminated()`(live 탭 전부 `terminated`)를 보고 세션 종료를 latch한다. 단, 파일 도크에 보호 entry/transaction이 있으면 `file_panel_exit_held`로 창을 유지하고 notice를 표시하며, 사용자가 파일 탭을 저장하거나 닫아 보호가 해소된 다음 tick에만 재평가한다. 보호가 없으면 `ended_seen = true` → `writeSummaryFromState`가 `FrameSummary.ended = 1` → ABI가 `Status.session_ended`를 올리면(`app_host_abi.zig`) Swift `tickAppSession`이 `closeWindowOrQuit`으로 그 창을 닫고, **마지막 창이면 `NSApp.terminate`로 앱을 종료**한다.

문제는 `allTabsTerminated`가 **"쓰다가 종료"와 "시작하자마자 사망"을 구분하지 못한다**는 점이다. config가 잘못돼 첫(유일) 셸이 spawn 직후 죽으면(예: `shell.command = /usr/bin/false`, `shell.args = -c "exit 1"`, exec 실패) 세션이 **애초에 성립한 적이 없는데도** 위 경로가 앱을 종료시켜, 창이 깜빡하고 사라진다 — 사용자는 원인을 볼 수도, 설정 화면에 갈 수도 없다(매 실행 반복). `resolveConfiguredShell`(실행 불가 셸 *경로* 폴백)은 이 중 "경로가 틀린" 하나만 막고, 실행은 되지만 즉시 종료하는 셸/args는 여전히 이 lifecycle로 앱을 종료시킨다. 즉 루트커즈는 셸-경로 계층이 아니라 **"usable 세션에 도달한 적 없는 창의 자동 종료"를 정상 종료와 동일 취급**하는 lifecycle 계층이다.

**정책(창 유지)**: 세션 종료 latch(`latchSessionEndOrHold`)에서, 종료가 **비정상**(exit code≠0·시그널·exec 실패·read error — 정상 `exit 0`은 제외)이고 그 창이 **usable 세션에 도달하지 못했으면** `ended_seen`을 세우지 **않고** 창을 유지한다. 유지 상태는 `startup_held` 플래그로 latch한다 — `termination_finished`는 세우지 **않는다**(그래야 새 셸을 열면 re-arm돼 새 세션이 정상 종료 판정을 다시 받는다). `ended_seen=0`이라 ABI status는 `ok`로 남아 host가 창을 안 닫는다. 정상 종료(exit 0)이거나 usable였던 창은 기존대로 종료한다. 이 유지 동작은 config `workspace.hold-on-startup-failure`(bool, 기본 **true**)로 끌 수 있다 — false면 비정상 시작 사망도 기존처럼 창/앱을 종료한다(Terminal.app "shell 종료 시 닫기" 취향).

**안내(지속) + 복구**: `showNotice`로 원인(exit code)을 **초기 알림**하고, 더해서 죽은 surface의 **터미널 화면에 안내를 dim 텍스트로 지속 렌더**한다(`core.write` — notice를 닫아도 남아 "왜 멈췄고 어떻게 복구하나"가 계속 보인다; #5 지속성). notice는 아무 키에나 닫히는 토스트라 key-eating이 있어(⌘단축키까지 삼킴) 지속 안내를 이 토스트에 기대지 않고 터미널 화면에 둔다. **복구는 held 창에서 ⏎(Enter)** 를 누르면 그 자리에서 셸을 재시작한다(`newTermInActivePane` — in-place respawn, #4). Enter는 chrome 모달 라우팅보다 **먼저** 가로채 notice가 열려 있어도 즉시 동작하며, 다른 모달(설정·팔레트 등)이 열려 있으면 양보한다.

- **usable 미도달 신호**: (a) 창이 수명 동안 한 번도 PTY 출력이 없었거나(`total_output_events==0`), (b) 셸이 spawn 후 **grace window(`startup_grace_ms`, 기본 2000ms) 안에** 죽었으면 usable 미도달로 본다. (a)는 조용한 실패(exec 실패·`/usr/bin/false`·`exit N`), (b)는 에러를 한 줄 찍고 곧장 죽는 오설정을 잡는다. 둘 다 **비정상 종료 게이트 아래에서만** 판정한다.
- **exit-code 게이트가 필수인 이유**: 출력 유무만 보면 `/usr/bin/true`처럼 **조용히 성공(exit 0·무출력)**한 one-shot 명령까지 held돼 창이 영영 안 닫히고 실패 문구가 뜬다(성공을 실패로 오판). 그래서 `exit 0`은 항상 정상 종료로 취급해 유지하지 않는다. 신호 판정은 순수 함수 `holdOnStartupExit(uptime_ms, output_events, exit_abnormal, chrome_minimal)`로, 시계는 uptime을 주입해 결정론적으로 테스트한다. `pty-operating-model.md`("종료된 surface의 마지막 화면을 볼 수 있어야 한다")의 원칙을 **창의 마지막 surface까지** 확장한 것이다.
- **죽은 surface 입력 가드**: held 창의 활성 surface는 죽은 PTY(`process_state=.exited`)다. 터미널 입력은 `writeInput`이 `ProcessExited`/`WriteFailed`로 실패하는데, `ended_seen` 가드만으론 held(`ended_seen=0`)에서 안 걸린다. 그래서 `handleKeyEvent`는 `frame_loop.handleKeyEvent`의 그 에러를 **catch해 ignored로 회계**(late-input, 치명적 fault 아님)한다. ⌘,·⌘T 같은 앱 단축키는 host가 `.app_action`으로 resolve해 **write 없이** 처리하므로 이 catch에 안 걸려 계속 동작한다 → held 창에서도 복구가 가능하다.
- **복구 + 좀비 reap**: held 창에서 **⏎(Enter)** 또는 새 셸(⌘T/⌘N)을 열면 `createTerm`이 `startup_held`를 re-arm(false)하고, 새 live Term이 붙은 뒤 held로 남아 있던 죽은 Term을 reap한다(좀비 탭 방지 — `allTabsTerminated`가 true인 동안 `reapTerminatedTerms`가 early-return하므로 명시 reap). 설정(⌘,)에서 `shell.command`/`shell.args`를 고친 뒤 재시작하면 정상 실행되고, 새 세션이 정상 종료하면 기존대로 앱이 종료된다.
- **범위/한계**:
  - 정상 종료(exit 0)·usable였던 창·출력을 낸 뒤 grace 밖에서 죽은 셸은 유지하지 않는다(기존대로 종료).
  - 퀵 터미널·미니멀 스크래치(`chrome_minimal`)는 제외.
  - 사용자가 **명시적으로 닫는 경로**(Cmd+W/빨간 버튼/Cmd+Q)는 이 정책과 무관하다 — 위 "닫기 확인"이 관할한다.
  - config `workspace.hold-on-startup-failure=false`면 이 유지 정책 전체를 끈다(비정상 시작 사망도 종료).
- **검증**: 순수 `holdOnStartupExit`가 (비정상+무출력)·(비정상+grace내)→유지, (정상 exit0)·(usable였음)·(grace밖)→종료를 결정론적으로 증명(uptime 주입). `latchSessionEndOrHold`는 실 PTY 종료 상태로 held/정상 종료/re-arm+reap과 **knob off면 종료**를, `handleKeyEvent`는 terminated 활성 surface의 터미널 입력 무시와 **held+⏎→respawn**을 증명한다.

## 현재 app shell 범위

현재 app shell PR은 다음만 목표로 한다.

- Swift `@main` entrypoint가 실제 `NSApplication`을 실행한다.
- Swift가 Zig C ABI static library를 링크하고 startup 때 capability/version을 확인한다.
- terminal window(`MaruMetalTerminalView`, CAMetalLayer)가 계속 떠 있고, app session의 shell glyph와 반전 블록 커서를 그린다.
- Swift는 opaque app session handle만 보유하고, Zig가 shell surface, `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, `RendererState`를 소유한다.
- Swift timer가 Zig `maru_macos_app_session_tick`을 반복 호출해 frame loop를 진행하고, metal generation이 바뀐 tick에만 lean renderer로 다시 그린다(idle tick은 재드로우 생략).
- terminal view의 `keyDown`, window resize, window close가 fixed-width C ABI record를 통해 Zig app session으로 내려간다. resize는 backing 픽셀·scale만 넘기고 grid(cols/rows)는 Zig가 실제 cell 메트릭으로 계산한다.
- smoke 실행은 `zig-out/maru-macos-app/app.summary.txt`에 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `terminal_surface=true`, `terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer`, `metal_renderer_created=true`, `metal_frames_drawn>0`, `frame_prepared=true`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `resize_events=1`, `close_events=1`을 남긴다.

여기까지로 app session의 shell glyph·커서가 실제 Swift window에 그려지고, resize cell 수도 실제 CoreText font metrics(advance×line-height)와 분수 backing scale에서 Zig가 계산한다. 렌더는 **fixed-cell pixel layout**이다(각 cell을 고정 픽셀 사각형 col×cw, row×ch에 두고 drawable 크기로 NDC 투영 — 창을 키우면 글자가 늘어나는 대신 더 많은 cell이 보인다).

현재 app shell에서 아직 하지 않는 것:

- plugin/Wasm
- IME/입력 인코딩 중 일부(조합/확정·preedit 표시·레이아웃 독립 단축키·판정 상태 머신 Zig 이전·후보창 커서 위치 배치(ABI v22)·dead key는 완료; function key F1~F12·CSI-u/kitty·키패드 application 모드(DECKPAM) 인코딩도 완료 — 아래 "이미 구현된 것" 참조. 잔여는 F13+뿐(`input.zig functionKeySequence`가 표준 갈림을 이유로 거부, Ghostty도 todo))
- full VT parser 잔여 갭(alternate screen·scroll region·mouse mode는 구현; DECOM·ICH/DCH·SS2/SS3·British charset 등 잔여는 plans/terminal-input-and-protocols.md G-시리즈가 단일 출처)

이미 구현된 것(과거 이 목록에 있던 항목): 탭/분할 UI(세로 사이드바 탭·가로 탭 바·split 멀티 panel — 아래 "남은 한계" 단락 끝), workspace restore([workspace-restore.md] R1~R6, `captureWorkspaceWindow`/`restoreSpawn`), settings UI(`toggle_settings` ⌘, → schema-주도 세팅 모달, [config-gui.md])·runtime reload(ABI v56 `reloadConfig`), global shortcut(ABI v28 `GlobalHotkey` — 위 "C ABI 규칙" 참조). SGR 4 밑줄 등 텍스트 장식선 overlay 렌더(`draw_list.zig`가 `cell.style.underline`에 `.underline` LineOverlay 방출 → `metal_frame.zig`가 reserved kind로 투영(밑줄=reserved 9) → `maru_metal_renderer.m`가 reserved==9를 셀 하단 가는 띠로 그림 — 커서·hover 밑줄과 같은 부분-사각형 기법 재사용). function key F1~F12(`input.zig encodeKey`의 `.function`→`functionKeySequence`, F1~F4 SS3·F5~F12 CSI `~`)와 CSI-u/kitty 인코딩(`encodeKitty`)도 구현 — Swift는 `app_host_abi.zig keyEventFromAbi`로 f1~f12·home/end 등을 `terminal.KeyEvent`로 매핑한다.

## C ABI 규칙

- ABI version은 `MARU_MACOS_APP_HOST_ABI_VERSION`으로 시작한다.
- Swift는 startup 때 `maru_macos_app_host_abi_version()`과 `maru_macos_app_host_capabilities()`를 확인한다.
- Swift와 Zig 사이에는 Swift class, Zig slice, Zig allocator-owned buffer를 직접 넘기지 않는다.
- 포인터를 넘겨야 하는 API는 어느 쪽이 해제하는지 함수 이름과 문서에 함께 적는다.
- key/resize/close 같은 입력 event는 fixed-width struct로 넘기고, 실제 app action 판정은 Zig `KeyBindingResolver`/`FrameLoop` 쪽에서 한다.
- 전역(OS) 단축키(`keybind = global:…`)도 같은 원칙이다(ABI v28): Zig가 config를 파싱해 OS 등록용 기술자(`maru_macos_app_session_global_hotkey` — 가상 키코드 + Carbon modifier mask + action)를 만들고, Swift는 `maru_macos_app_session_global_hotkeys`로 받아 Carbon `RegisterEventHotKey`로 등록·창 토글(NSWindow)만 한다. 키→키코드 매핑·중복 제거·action 결정은 전부 Zig다(Swift는 OS 호출만 — 정책 0).
- status는 "치명적 세션 fault"와 "이 한 event만 거부됨", "정상 종료"를 구분한다. host는 셋을 다르게 처리한다.
  - per-event 거부(`KeyFailed`/`ResizeFailed`): 닫힌 pane의 late input 등. 앱을 죽이지 않고 무시·기록만 한다. Zig app session도 이미 종료된 세션의 key/resize는 fail이 아니라 ignored로 닫는다.
  - 정상 종료(`SessionEnded`): `tick`이 **검증된** PTY 셸 종료(`.exited` — 모든 Term이 끝났을 때)를 관측하면 ok 대신 이 status를 올린다. host는 frame loop tick을 멈추고 우아하게(exitCode 0) 내려간다. 죽은 세션을 계속 tick하지 않는다. **`.read_error`(자식 생존 미검증 I/O 오류)는 세션을 끝내지 않는다** — surface만 unusable로 latch하고 워크스페이스·탭·셸은 유지한다(`terminationClosesWorkspace` 게이트; Ctrl+C가 유발한 일시적 write 오류가 산 셸을 죽이고 좌측 탭을 닫던 버그의 수정. 단일 출처: `pty-operating-model.md` "read_error vs 검증된 exit").
  - 세션 fault(`TickFailed`/`CreateFailed` 등): 앱을 비정상 종료(exitCode 1)한다.
- `*_close`는 idempotent하지만 `*_destroy`는 단발성이다. host는 `destroy` 직후 handle을 비워 재호출(use-after-free)을 막는다.

## MainActor와 thread 규칙

- Swift AppKit entrypoint는 `@MainActor` 또는 main thread에서만 window/focus/input을 만진다.
- Zig PTY reader와 event queue는 Swift main thread에 묶지 않는다.
- Swift는 display tick 또는 AppKit event에서 Zig의 non-blocking frame tick API만 호출한다.
- Zig 호출이 blocking drain을 요구하면 제품 앱 loop에 넣지 않는다. blocking wait는 smoke나 opt-in test에만 둔다.

### Mermaid helper process 경계 (FP10)

Mermaid는 동기 JavaScript layout을 실행하므로 main app의 WKWebView나 `WKProcessPool`을 timeout 격리 경계로 쓰지 않는다. macOS 12+에서 여러 `WKProcessPool`은 격리 효과가 없다는 WebKit 공개 계약 때문이다. 앱 전역 Zig `AppRuntime.mermaid_queue: MermaidCoordinatorState`가 admission/coalesce/fairness/capability/deadline을 소유하고, `MaruAppHostController`의 Swift `MermaidRenderCoordinator`는 그 action을 적용하는 process adapter다. adapter는 nested helper `.app` 전체의 sealed code validity와 닫힌 entitlement 집합을 확인한 뒤 번들 내부 regular non-symlink executable `Contents/Helpers/MaruMermaidRenderer.app/Contents/MacOS/maru-mermaid-renderer`만 절대경로로 시작하며 앱 bridge·asset grant를 주지 않는다. `LSBackgroundOnly` helper는 App Sandbox와 WebContent service 기동에 필요한 `network.client`만 가지며 사용자 선택 파일·Downloads·network server entitlement는 없다. 환경은 `LANG`/`LC_ALL`/고정 `PATH`/`TMPDIR` allowlist, cwd는 helper 디렉터리로 제한한다. 문서 네트워크 권위는 strict inline CSP, document-start의 non-configurable API 차단 계수, CSP violation 계수, top-level navigation 계수가 모두 0일 때만 결과를 허용하는 native gate가 별도로 막는다. helper는 자기 ephemeral WKWebView만 소유하고 bridge/message handler 없는 strict inline CSP 빈 문서를 `baseURL: nil`의 opaque blank origin으로 먼저 완료한 뒤 exact runtime bytes를 평가해 첫 Mermaid byte부터 CSP를 적용한다. 합성 custom scheme이나 Launch Services 경로는 만들지 않는다.

Zig가 `start_helper_job` action을 commit한 monotonic 시각부터 helper 상태에 따라 deadline을 arm한다. 같은 `MermaidCoordinatorState`가 `spawn_helper=true`인 cold 요청에는 5초, 이미 기동·검증된 helper의 warm 요청에는 2초를 선택하므로 Swift가 이 정책을 다시 판정하지 않는다. cold 시간은 executor 대기와 bundle/path/signature validation, spawn, pipe setup, Hello/HelloAck, 첫 WKWebView/Request/Result 전체를 포함하며 Swift가 단계마다 새 timer를 만들지 않는다. Result frame을 완성한 마지막 successful read 직후 시각도 Zig가 commit 전에 같은 action deadline과 비교한다. terminal 판정은 Zig만 소유하고, Swift는 executor가 deadline 뒤에 action을 받았을 때 새 물리 spawn을 생략하고 transient completion을 돌려주는 안전 gate만 둔다. Swift의 reply timer는 C/Zig가 공유하는 cold 5초보다 250ms 뒤인 5.25초 safety fallback일 뿐이다. request는 coordinator-owned fixed frame lease에 있고 executor가 owned copy를 만든 exact ACK 전에는 재사용하지 않는다. Zig fixed terminal queue는 98개로 backlog와 모든 live pending/in-flight/accepted job을 동시에 담으며 admission은 `terminal+live+growth`를 source copy 전에 검사한다. coalesce의 `superseded`뿐 아니라 deadline·transient·integrity·invalid result·accepted capacity·failure latch가 모두 `{surface_id, job_id, renderer, reason}`을 내보내고 Swift는 `MaruMermaidTerminalResult` 상수와 `finishExact`만 소비해 해당 Promise를 즉시 끝낸다. native timeout/cancel은 job ID까지 대조하며, provisional navigation은 pagehide와 독립적으로 surface pending을 즉시 cancel한다. actual `.app` smoke는 isolated bridge hang이 helper in-flight인 동안 같은 `WKWebView.reload()`을 호출해 delegate 취소 1회·pending reply 0을 검증한다. 어느 단계든 실패하거나 deadline이 지나면 해당 `MermaidJobCapability`를 terminal revoke하고 in-flight/source bytes를 회수하며, helper process가 생겼다면 종료한다. navigation/widget 수명 revoke는 Web capability와 pending reply를 즉시 끝내되 이미 실행 중인 동기 render를 강제 종료하지 않는다. Zig가 그 slot을 `revoked`로 유지해 완성 body/protocol을 검증한 뒤 stale 폐기하므로 빠른 편집은 같은 helper를 재사용하고 DOM/reply는 0이다. revoked render가 멈추면 해당 action의 cold/warm deadline과 failure budget이 helper를 종료한다. validation/spawn/pipe/handshake/result terminal failure는 모두 60초 failure budget에 한 번만 귀속하고 3회면 앱 수명 동안 disabled로 latch한다. helper 누락·bundle 밖·symlink/비정규 파일·nested bundle seal·code-sign/Team ID/실행 PID identity 불일치·protocol version/HelloAck nonce 불일치는 첫 실패에 영구 무결성 오류로 분류해 같은 latch를 적용하고, 이후 validation/spawn/enqueue를 하지 않는다. parent seal을 통과한 re-signed resource mismatch도 helper의 embedded SHA-256 gate가 exact exit 12로 알리고 parent가 첫 start에서 permanent latch한다. 이는 앱 대기와 editor process 격리의 hard gate이지 WebKit service CPU가 정확히 deadline에 정지한다는 주장이 아니다. stdout/stderr는 nonblocking `DispatchSource`에서 각각 최대 64/16 KiB씩 읽고 stderr tail은 64 KiB만 유지한다. write는 최대 request frame 두 개의 partial-write state machine이며 EAGAIN은 write source 하나로 재개한다. EOF는 source와 decoder를 한 번만 끝내고, helper termination/failure completion은 I/O barrier가 이전 callback을 모두 quiesce한 뒤에만 발급한다. Result queue와 exact handoff/integrity/termination control lane을 분리해 payload overflow나 retired generation callback이 수명 ACK를 지우지 못한다. lifecycle/terminate/250ms kill은 I/O executor와 독립된 control executor라 pipe backpressure가 종료를 막지 않는다. MainActor/display tick에는 spawn/terminate·pipe setup/read/write·wait가 없고 FP11f는 pending-work/byte budget gate 뒤에만 pump를 배선한다. timeout/failure 뒤에는 Swift termination handler의 exact helper-instance ack 전까지 Zig가 다음 start action을 내지 않아 물리 helper≤1을 유지한다. 수명 revoke의 정상 stale result는 termination action을 만들지 않는다. app 종료는 Swift가 control/I/O executor와 physical process를 quiesce한 뒤 `maru_macos_mermaid_shutdown()`으로 Zig pending/result/helper/action lease/latch를 최종 회수한다. app-lifetime latch를 초기화하는 reset symbol은 제품 header/static library에 없고 별도 smoke ABI variant에만 존재한다. `macos-app-bundle`은 helper를 `Contents/Helpers`에 넣고 개발/CI bundle은 helper→CLI/main executable→app 순서로 ad-hoc inside-out signing, Developer ID 배포는 같은 순서로 hardened runtime+timestamp signing을 한다. runtime은 모든 채널에서 bundle containment·상위 포함 symlink-free regular file과 코드서명 validity를 검사하고, Developer ID build에서는 main/helper Team ID 일치도 요구한다. universal 빌드는 두 architecture helper를 `lipo`한 뒤 같은 순서로 서명·공증한다. test-only digest mismatch helper는 smoke artifact 하위에만 만들며 product graph와 경로를 공유하지 않는다. `mise run macos-mermaid-helper-build`/`mise run macos-mermaid-helper-smoke`가 실제 helper를 실행하며 artifact는 `zig-out/maru-macos-mermaid-helper-smoke/mermaid-helper.summary.json`이다.

공개 Swift `Process`에는 검증한 file descriptor 자체를 실행하는 API가 없으므로 pre-check와 path 기반 spawn을 inode-conditional syscall 하나로 만들 수는 없다. adapter는 spawn 전후의 symlink-free path·device/inode·정적 code-sign뿐 아니라 Hello 전에 실제 child PID의 dynamic `SecCode`를 조회해 prevalidated CDHash·identifier·Team ID와 대조한다. A→B→A path ABA도 실행 PID가 B이면 mismatch라 pipe capability를 보내기 전에 종료하고 integrity latch로 fail-close한다. 따라서 교체된 helper 결과가 앱 상태에 commit되는 경로는 0이지만, 잘못된 executable의 순간 실행까지 없앤다고 주장하지 않는다. 이를 제거하려면 `Process` 계약 대신 fd-exec를 제공하는 별도 native launcher 전략이 필요하다.

Web의 `renderMermaid` mailbox는 독립 timeout을 갖지 않고 Zig exact terminal/native reply만 기다린다. Native reply fallback은 admission 시점에 arm하지 않으며 `MermaidRenderCoordinator.pump`가 실제 start action을 drain할 때 `deadline_ms + 250ms`로 arm한다. 그러므로 pending queue 대기 시간이 뒤 job의 cold/warm 예산을 깎지 않고, 이미 끝난 exact job의 늦은 fallback은 one-shot table에서 무동작이다.

## 진단 로그: 시작 마커와 종료 마커의 짝

GUI 실행(Dock·Finder)의 stderr 는 `/dev/null` 이라 진단이 통째로 사라진다. `redirectStderrToAppLog`
(`app_host_abi.zig`)가 fd 2 를 `<cache>/app.log` 로 바꾸고 `=== maru app start pid=N ===` 을 찍어
어디부터가 이번 실행인지 표시한다. **stderr 가 tty 면 건드리지 않는다** — 터미널에서 띄웠다면 콘솔이
이미 진단을 받고 있고, 그것을 파일로 가로채면 개발 중 출력을 빼앗는다.

시작 마커만으로는 **어떻게 끝났는지**를 못 본다. 2026-08-29 에 앱 업데이트 직후 여섯 번 연속으로 앱이
조용히 사라졌는데, `app.log` 에 `workspace checkpoint: final-quit` 이 한 줄도 없고 크래시 리포트도
없었다 — "정상 종료도 크래시도 아니다"까지만 알고 그 이상 좁힐 재료가 없었다. 그래서
`installExitDiagnostics` 가 같은 자리에서 종료 마커를 건다:

| 로그 | 뜻 |
| --- | --- |
| `=== maru app exit pid=N signal=M ===` | 잡을 수 있는 시그널로 죽었다(크래시·TERM·HUP…) |
| `=== maru app exit pid=N via=exit ===` | `exit()` 로 끝났다(정상 quit 경로든 조기 반환이든) |
| 시작 마커만 있고 종료 줄이 없음 | `SIGKILL`·전원 차단처럼 **잡을 수 없는** 경로 — 부재가 곧 증거다 |

- 시그널 핸들러는 마커를 쓴 뒤 **기본 처분으로 되돌리고 다시 올린다**. 이 단계를 빼면 시그널을 삼켜
  macOS 가 크래시 리포트를 못 쓴다 — 진단을 늘리려다 원래 있던 진단을 없애는 교환이 된다.
  실측으로 `SIGTERM` 이 종료코드 143(=128+15)으로 그대로 전달되는 것을 확인했다.
- 핸들러 안에서는 async-signal-safe 한 것만 부를 수 있어 `std.fmt` 를 쓰지 않고 십진 변환을 직접 한다.
  버퍼가 모자라면 자르고 끝낸다 — 한 줄이 짧아지는 것보다 핸들러 안에서 죽는 것이 비교할 수 없이 나쁘다.
- `SIGPIPE` 는 **일부러 뺀다**. 이 저장소는 그 처분을 곳곳에서 의도적으로 관리하므로
  (`control_relay.zig`·`external_attach_cli.zig`) 여기서 덮으면 그 결정을 조용히 뒤집는다.

## 검증 경로

- `mise run test-macos-app-host-abi`: C header와 Zig extern layout/version이 맞는지 확인한다.
- `mise run macos-app-host-abi-lib`: Swift host가 링크할 Zig exported C ABI static library를 만든다.
- `mise run macos-app-host-swift-check`: Swift host가 C header를 import하고 AppKit 타입을 type-check할 수 있는지 확인한다.
- `mise run macos-app-build`: Swift host executable을 만들고 Zig static ABI library를 링크한다.
- `mise run macos-app-smoke`: 실제 `NSApplication` placeholder window를 잠깐 띄우고 controlled PTY command, scripted key events, scripted resize, app close가 Zig app session의 `FrameLoop`까지 도달했는지 summary에 `terminal_surface=true`, `frame_loop_ticks`, `output_events`, `exit_events`, `key_events`, `terminal_input_events`, `resize_events`, `close_events`, renderer frame 통계로 남긴다.
- `mise run macos-app`: 같은 executable을 smoke의 auto-quit timeout(`MARU_MACOS_APP_SMOKE_MS`) 없이 실행해 사용자가 window lifecycle을 수동 확인한다. smoke와 동일하게 Zig session의 shell glyph·커서를 Swift window에 그린다 — 차이는 자동 종료 타임아웃뿐이다(`drawMetalFrame`이 `frame.cells`를 무조건 그린다).
- 기존 `mise run macos-app-pty-metal-smoke`: Objective-C smoke bridge가 PTY/output/keyDown/close/render 경계를 계속 검증한다.

## 남은 한계

현재 app shell은 실제 제품 앱 loop와 Zig shell surface/frame loop를 함께 실행하고, `MaruMetalTerminalView`가 AppKit/Metal UI를 그리며 key/resize/close event를 Zig app session ABI로 내려보낸다. 표준 메뉴바와 `.app` bundle은 구현돼 있고 `zig build macos-app-bundle`이 Info.plist·CLI·web/font resources를 패키징하며 Developer ID 배포는 [distribution.md]의 서명·공증 경로를 쓴다. `install_cli`도 command catalog·팔릿에서 `~/.local/bin/maru` symlink를 설치하는 구현 상태다. 남은 한계는 이 문서의 각 자동 smoke가 실제 사용자 장시간 조작, 모든 AppKit firstResponder 경합, 모든 배포 환경의 Gatekeeper 결과를 완전히 대체하지 못한다는 점이다.
