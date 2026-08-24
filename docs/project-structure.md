# 파일/폴더 구조

Maru는 초기에 파일 이동을 최소화한다. 기존 `src/*.zig` 파일은 public facade 역할을 유지하고, 기능이 커질 때 하위 폴더에 책임별 구현을 추가한다.

## 원칙

- 기존 facade 파일은 오래 유지한다.
- 새 기능은 가장 가까운 책임 폴더에 추가한다.
- 한 파일이 여러 책임을 갖기 시작하면 새 폴더로 분리한다.
- 파일은 가능한 한 하나의 목적을 갖는다. 서로 다른 이유로 변경되는 코드가 같은 파일에 쌓이면, public API를 유지한 채 구현 파일을 목적별로 나눈다.
- `main.zig`, `maru.zig`, `terminal.zig`, `renderer.zig` 같은 facade 파일은 얇게 유지한다. facade는 import/export와 안정된 진입점 역할을 하고, 실제 구현 책임을 계속 떠안지 않는다.
- 테스트, trace, snapshot, replay 자료는 기능 코드와 같은 책임 이름을 사용한다.
- 빈 폴더도 의도를 문서화해서 나중에 위치를 다시 정하는 리팩토링을 줄인다.

### Zig 파일·폴더 네이밍 컨벤션

- public facade(`maru.zig`, `chrome.zig`, `session.zig` 등)만 `src/` 또는 도메인 루트에 둔다.
  facade는 re-export와 안정된 import 진입점만 소유하며 구현 파일을 다시 품지 않는다.
- 구현 Zig 파일은 반드시 가장 가까운 **책임 namespace 폴더**에 둔다. 기능 prefix가 파일명에
  반복되기 시작하면(`ui_tree.zig`, `ui_paint.zig`, `ui_interaction.zig`처럼) prefix를 계속 붙이지
  않고 `ui/{tree,paint,interaction}.zig`로 승격한다. 폴더가 domain, 파일명이 그 안의 한 책임을
  표현한다.
- 한 namespace 안의 파일은 한 가지 변경 이유만 가진다. 예를 들어 `ui/style.zig`는 닫힌 제품
  prop 어휘, `ui/tree.zig`는 identity/AST/rect snapshot, `ui/paint_style.zig`는 token state 해석,
  `ui/paint.zig`는 pixel snap과 draw emission만 소유한다. layout·provider I/O·platform lowering을
  같은 파일에 넣지 않는다.
- 새 구현은 이 규칙을 즉시 따른다. 기존 flat 파일은 무관한 대규모 rename PR로 한꺼번에 이동하지
  않는다. 해당 도메인을 수정할 때 facade import, build test, 문서 링크를 같은 PR에서 바꾸어
  점진적으로 namespace로 옮긴다. 이동만으로 public facade path를 깨지 않는다.
- 이름이 한 파일뿐인 범용 leaf(`color.zig`, `width.zig` 등)와 executable entrypoint는 억지로
  한-file 폴더를 만들지 않는다. 둘 이상의 협력 구현 파일이 생기거나 책임 경계가 분명해지는 즉시
  위 namespace 규칙을 적용한다.

## 소스 구조

```text
src/
  maru.zig              public import facade
  main.zig              개발용 CLI entrypoint
  app.zig               탭/창/surface facade
  chrome.zig            플랫폼 중립 디자인 시스템(ChromeDraw) facade
  cli.zig               개발용 CLI 서브커맨드 구현 facade(main.zig가 디스패치, 로직은 cli/에)
  color.zig             backend-neutral 색 primitive(Rgb). terminal/renderer/config가 공유
  config.zig            action/config facade
  pty.zig               process/PTY facade
  renderer.zig          render facade
  session.zig           OS-중립 세션 코어 facade(L2) — 세션 모델·입력/재정렬 수학·IME 판정·agent observer
  terminal.zig          terminal-core facade
  terminfo_cache.zig    maru 자체 terminfo 로컬 캐시 단일 출처(경로·버전·컴파일 셸 명령). pty 자동 컴파일 + cli/terminfo 서브커맨드가 공유(top-level 중립 — color.zig 결)
  text_escape.zig       라인 기반 텍스트 포맷(maru.workspace.v1·maru.trace.v1·snapshot)의 따옴표 escape 규칙 단일 출처. 어느 facade에도 속하지 않는 중립 leaf
  observability.zig     debug event/trace/snapshot facade
  plugin.zig            action/plugin facade
  ui_test.zig           typed Chrome UI namespace만 좁혀 도는 test root(`zig build test-chrome-ui`). 제품 `chrome.zig`가 모든 component를 import하므로 build entrypoint를 따로 둔다

  # 중립 leaf — 어느 facade에도 속하지 않고 여러 층이 함께 import한다(color.zig 결).
  # 한 파일뿐인 범용 leaf는 억지로 한-file 폴더를 만들지 않는다(아래 네이밍 컨벤션).
  width.zig             코드포인트 셀 폭·wide 렌더 심볼 판정 단일 출처. C 게이트(coretext_smoke.m)와 주석-동기 미러
  display_width.zig     편집기 본문의 표시 폭. `width.cellWidth`(터미널 협상용)를 대체하지 않고 그 위에 편집기 규칙을 얹는다(native-editor-visual-mapping.md §4.2)
  grapheme.zig          한글 grapheme cluster 분절 — NFD conjoining 자모(macOS 파일시스템 기본)를 한 음절로 묶는다
  path_shape.zig        경로 모양 판정(절대·구분자). L1 링크 감지와 L2 경로 가드 양쪽이 필요한데 L1은 L2를 import할 수 없어 최상위에 둔다
  redact.zig            민감정보 redaction 단일 출처(코드). project-rules.md "민감정보 redaction 기준"의 코드 미러 — app/observability/config/session이 공유
  hazard.zig            문서 내용의 신뢰 판정 — 보이는 것과 실제가 달라지게 만드는 문자를 가려낸다(native-editor-document-model.md §3.8)
  icons.zig             **생성 파일**(tools/svg_to_coverage.py). 아이콘 semantic 이름이 단일 출처이고 소비처는 codepoint 리터럴 대신 이 enum을 쓴다. 직접 수정하지 않는다
  i18n.zig              UI 표시 문자열의 언어별 테이블·조회·런타임 보간(i18n.md 계약). 문자열이 platform에 갇히지 않게 하는 자리라 chrome·session·config·platform이 모두 import한다
  shutdown_wire_contract.zig  종료 backend와 앱 조합 계층이 함께 쓰는 포인터 없는 wire 권위 값

    app_session/        app_session.zig에서 목적별로 떼어낸 그룹 구현(docs/app-session-decomposition.md §4.1 F 시리즈).
                        find.zig(⌘F orchestration — E1. 스크롤백과 **편집기 문서** 둘 다 배선한다.
                        어느 쪽을 검색할지는 활성 Term이 정하고, 편집기 쪽 일치 계산은 L2 session/editor/find.zig다), agent_dock.zig(에이전트 세션 기록 도크 —
                        아카이브 스캔·필터·스크롤·인라인 상세, F1+F3 병합), file_panel.zig(파일 탐색기·파일
                        패널 — 트리 mutation·패널 생명주기·dock entry, F2. tree↔panel이 순환하므로 한 파일이다), pane.zig(pane·split·divider —
                        분할/합치기·pane 포커스·드래그·divider 히트테스트·pane별 바/스크롤바, F4), dock.zig(도크 일반 —
                        view 전환·레이아웃·리스트 스크롤바·포커스 큐, F5. 도크 *안*의 내용물은 각자
                        agent_dock/file_panel 소유다), tab.zig(탭 — 생성·닫기·전환·이동·고정·그룹·제목·표면
                        집계, F6. `*Tab` 하나만 보는 순수 판정 10개를 함께 가진다), sidebar.zig(사이드바 — 행 모델
                        재구축·스크롤·드래그 프리뷰·카드 렌더·헤더, F7. 탭 그룹 마커·depth 수술은
                        여기가 아니라 tab.zig 소유다), scroll.zig(스크롤 — 휠·페이지 라우팅, 스크롤바 위젯의 썸
                        기하·드래그 캡처·페이드, 오버레이 스크롤, F8. 표면별 스크롤 상태는 각 표면
                        그룹이 가진다), settings.zig(세팅 UI·컨텍스트 메뉴·이름 변경과 바뀐 config를 살아 있는
                        세션에 다시 먹이는 경로, F9), workspace.zig(창 캡처/복원/이동과 창 속성·드래그 영역, F10.
                        24개 중 12개를 Swift 호스트가 직접 부른다), web.zig(web panel·인앱 브라우저 — WKWebView surface
                        수명·주소창·내비·web term, F11. 52개 중 20개를 호스트가 직접 부른다), input.zig(키 입력·IME·키바인딩 — 라우팅과 소비 판정,
                        IME 조합 수명, 커밋 텍스트, 키 힌트, 전역 핫키, F12), notification.zig(알림·벨 — OSC 9/777
                        수신과 방출, 이력·읽음 상태, 패널·배지, 벨 플래시, 원격 폴링, F13), agent.zig(에이전트 관측 —
                        상태·종류·트랜스크립트 폴링, 상태줄, 스피너, 사이드바 행, 세션 재개, F14.
                        세션 기록 도크는 여기가 아니라 agent_dock.zig 소유다), git.zig(git·SCM — 저장소 탐지,
                        브랜치·상태 갱신, SCM 뷰 행, diff term, F15), term.zig(term·surface — 생성/파괴·등록·
                        조회·포커스·종료, F16. `Term`/`Surface`가 거의 모든 도메인에 걸리므로 경계를 이름이 아니라
                        내용으로 잡았다), debug_fixtures.zig(`MARU_*` 환경변수 게이트로 사이드바 접힘·가짜 브랜치·
                        그룹 상태·드래그 고스트·알림 배지를 강제하는 **디버그/스모크 하네스** — 게이트는 분리 시점
                        40여 개에서 계속 는다. **세는 법을 못 박는다**: 이 파일 안에서 `getenv("MARU_…")`로 읽는
                        **서로 다른 이름**의 수다. **재려면 tree 도 못 박아야 한다** — 같은 날에도 이 파일이
                        여러 번 바뀐다(2026-08-18 하루에 셋). 그 기준으로 `cf5d378b`(2026-08-18)에 58개,
                        `36f1e0ee`(2026-08-24)에 73개다(전에 적힌 「57」은 세는 법도 tree도 없어 재현되지 않았다.
                        그날 tick에서 마저 옮겨 온 상태바 캡처 게이트 넷은 그중 +4이고, 나머지 증가분은 그 사이
                        다른 작업이 늘린 것이다). 함수 이름은
                        `maybeDebugOpenSettings`였지만 하는 일이 세팅이 아니라 시나리오 강제라, 제품 경로를 읽는
                        사람이 이 분량을 지나지 않도록 따로 뺐다). 각 파일은 `*AppSession`을 받는
                        free fn 모음이고, `app_session.zig`에는 ABI가 직접 부르는 진입을 얇은 facade로 남긴다.
                        **F 시리즈가 아닌 파일도 이 폴더에 산다** — editor.zig·editor_diff.zig(네이티브 편집기의
                        platform 쪽 절반 — 파일 읽기/권한 판정, diff Term 배선. docs/plans/native-editor.md가 단계를
                        소유한다)와 scm_dock.zig(소스 컨트롤 도크의 호스트 배선 — `session/scm_view.zig`의 행 모델을
                        component props로 투영하고 포인터를 그 tree로 라우팅한다. Session Dock과 같은 경로를 쓴다)는
                        **분해로 떼어낸 것이 아니라 처음부터 여기에 쓴** 새 기능이고, 그래서 아래 "test는
                        그룹 파일로 옮기지 않는다"의 예외다 — 자기 test를 함께 갖는다(§2-c-3의 "새 파일을 처음
                        작성할 때만 그 파일에 test를 쓴다").
                        **다만 허브가 이미 얇아졌다는 뜻은 아니다** — 분해는 진행 중이고(72,317줄에서 출발),
                        F 시리즈가 옮긴 것은 그룹 본문뿐이다. test 900여 개는 판정자가 그룹 밖 표면에 훨씬 넓게
                        닿아 동반 이동 시 pub화가 6배로 늘기 때문에 **의도적으로 허브에 남겼다**(아래 항목).
                        현재 줄 수와 남은 단계는 docs/app-session-decomposition.md가 단일 출처다.
                        그룹끼리 서로를 부를 때는 `app_session.zig`의 재수출을 거치지 않고 **직접
                        `@import`**한다 — 허브를 경유하면 허브의 pub 표면만 늘어난다(F6에서 정리).
                        **분해로 떼어낸 이 17개(find + F1~F16 + debug_fixtures)는 독립 모듈이 아니라 한
                        모듈(`AppSession`)의 조각이다** — 필드를 공유하므로 서로를 부르고, 2026-08-10 실측으로
                        양방향 쌍이 39개였다(43% 밀도). 순환은 결함이 아니라 이 구조의 성질이고, 얻은 것은
                        모듈 경계가 아니라 **탐색성**이다
                        (docs/app-session-decomposition.md "그룹 파일 17개는 독립 모듈이 아니다").
                        **분해로 떼어낸 파일의 test는 그룹으로 옮기지 않는다** — 판정자가 그룹 밖 표면에 훨씬 넓게 닿아
                        동반 이동 시 pub화가 6배로 늘어난다(같은 문서 §2-c-3 실측). 위 세 예외(editor·editor_diff·
                        scm_dock)는 분해 산물이 아니므로 이 규칙 밖이다.
  app/                  window/surface/runtime/pty_reader/runtime_pump처럼 앱 상태와 live 연결 책임별 구현.
                        persistent-session P2: terminal runtime의 수명·입출력·관측을 GUI layout에서 분리하는
                        vtable 계약 `term_runtime_backend.zig`(TermRuntimeBackend·RuntimeHandle — opaque, PtyIo와 같은
                        관용구)와 그 in-process 구현 `in_process_term_backend.zig`(기존 LiveSurfaceRegistry+LivePtySession+
                        SurfaceRuntime을 감쌈)를 둔다. GUI layout 정책과 session-host transport(P3 session_host/)를 한
                        파일에 섞지 않는다. P2 배선은 완료되어 app_session이 opaque handle과 backend 계약만 사용한다.
  chrome/               플랫폼 중립 디자인 시스템 구현 — draw/tokens/props/input/state/host + text_layout(셀 텍스트 배치 규율 — L3, OS-중립)·file_tree_icon(filesystem 비의존 아이콘 분류)
    ui/                 새 rich/Metal typed component tree. style(닫힌 prop 어휘)·layout(typed flex)·tree(identity/rect snapshot)·interaction(pointer-local state)·paint_style(token/state resolver)·paint(pixel snap→ChromeDraw)를 책임별로 둔다. `chrome.zig`는 `chrome.ui.*` namespace로만 re-export한다.
    components/         제품 컴포넌트(sidebar·tabbar·settings·palette·find·notice·modal 등). 한 파일로 끝나는 컴포넌트는 flat하게 두고,
                        **types/build/ids/view 네 책임으로 갈리는 컴포넌트만 같은 이름의 폴더로 승격**한다 — session_dock·archive_detail·scm_dock이
                        그 형태이고 facade `<name>.zig`가 네 파일을 re-export한다. types(platform 중립 입력 DTO)·build(bounded geometry와
                        action 투영)·ids(frame-local intent 표)·view(semantic paint와 text 투영)는 서로 다른 이유로 바뀐다.
                        editor_view/는 facade 없이 폴더만 두고 편집기 본문 렌더를 content·frame·diff_frame·geometry·gutter·scrollbar·surface·viewport로 가른다.
  cli/                  CLI 서브커맨드의 테스트 가능한 순수 로직(ssh: 원격 terminfo 전파 — 파싱·셸 스크립트·exec argv; install: maru CLI를 PATH에 symlink하는 경로/PATH 헬퍼; terminfo: `maru terminfo` 캐시 관리 인자 파싱 — 캐시 메커니즘은 top-level terminfo_cache.zig; sessions: 컨트롤 플레인 `sessions list`/`session get` 파서·`--help`·client wire — 1d — 및 소켓 발견 순수 정책 `controlDir`/`pickSocket` — A2a; persistent-session P5는 runtime.zig(`host status`, `runtime list/get/end`)와 attach.zig(ANSI adapter·detach chord)를 추가하되 protocol codec은 아래 session_host/를 재사용; trace: `maru trace anonymize` 인자 파싱 — 익명화 로직은 observability.trace/redact). main.zig는 얇은 디스패처로 두고 실질 로직을 여기 둔다.
                        **이 폴더의 제품 코드는 순수하다**(std + 계약 모듈만, 소켓·OS 0) — 그 순수성이 파서·wire·validator를 테스트 가능하게 만드는 근거다.
                        `test` 블록은 이 규칙 밖이다(실제 동작을 실측하느라 fork/pipe를 쓸 수 있다 — `ssh.zig`의 신호 수명 헬퍼가 그 예다).
                        **이 규칙은 산문이 아니라 `tests/boundary/cli_purity.zig`가 기계로 고정한다** — 재고에 없는 파일은 impure 토큰 0이고,
                        새 파일은 하위 폴더에 생겨도 자동으로 규칙을 받는다. 예외는 딱 두 파일이며 각자 왜 예외인지를 파일 머리에 적는다:
                        `control_client.zig`(컨트롤 소켓 발견→connect→`auth.self`→요청 전송→응답 수신. sessions·browser CLI가 공유하는
                        유일한 syscall 접착이고, 순수 정책인 경로 규칙·소켓 선택 판정은 여전히 `sessions.zig`가 소유한다.
                        Windows gate 문구의 단일 출처이기도 하다 — `main.zig`의 `HostGatedFeature.control_socket`이 그 값을 되돌려 준다),
                        `browser/run.zig`(`browser.zig`의 impure 짝 — 응답 수신 상태 기계·chunk 재조립·`--out` 원자 공개.
                        facade+같은 이름 폴더는 `session_host.zig`+`session_host/`와 같은 관용구다).
                        예전에는 이 둘이 `main.zig`에 있었고 그래서 허브가 1,442줄이었다 — 접착을 여기로 모으면 "cli/는 순수"와
                        "main은 얇은 디스패처"가 **동시에** 성립한다
  session/              L2 세션 코어(OS-중립·app/pty/platform import 0, check-boundaries 강제): 세션 모델(Model·Tab·Pane·surface·split_tree·workspace·dock_panel·core_command)과 **컨트롤 플레인/이동성 골격** — surface_id(M0a), window_membership(M0b), window_graph(M1), live_surface_registry(M2a generic), control_plane(1a JSON-RPC/ndjson), control_surface(1c Surface DTO·scope 응답), control_dispatch(1d read-only 라우터), layout/input math·ime·keyhint. platform이 런타임 타입을 넣어 인스턴스화한다. **`ssh/` 는 이 층 안의 sans-io SSH 프로토콜 코어**(패킷·와이어·버전 교환·KEXINIT·KEX·암호·전송 루프·호스트키·`known_hosts`·인증·개인키) — 소켓·파일·시계를 모르고 할당은 주입받는다. 모바일 브리지가 OS 호출 0 이라 데스크톱과 모바일이 **같은 프로토콜 코드**를 써야 하기 때문이고, `tests/boundary/ssh_sans_io.zig` 가 그것을 강제한다(단일 출처: docs/ssh-client.md)
    editor/             네이티브 편집기의 L2 코어 — document(버퍼·편집), line_index(줄 색인), selection, fold(들여쓰기 접힘 층), find(문서 안 일치 계산 — 순수), buffer(편집 가능한 내용 — persistent rope), delta(한 번의 편집 + selection 매핑 + 역연산), occurrence(다음 일치 추가 — 멀티커서 자리), diff·diff_state·intraline(줄 안 차이), open(열기 판정). 시각 매핑과 렌더는 chrome/components/editor_view/와 platform이 맡는다
  config/               action parsing, raw theme/font/cursor config, resolved appearance config
  pty/                  PTY backend, spawn request, process handle
  terminal/             parser, screen, cursor, scrollback, key/mouse encoding
  renderer/             Metal-first renderer internals, future WebGPU backend boundary, font layout, font identity registry, persistent renderer state, glyph atlas, frame stats
  platform/             OS별 process/window/input bridge
    macos/              AppKit/Metal/CoreText smoke bridge, Swift app host app shell, Swift/Zig C ABI 계약, workspace_checkpoint_file.zig(P4 C2: parent-fd 결속 fixed temp→atomic rename, typed failure·crash fixture; capture/coordinator/AppKit 비소유), control_socket.zig(1b: 컨트롤 플레인 unix socket bind/accept/peer-cred/hello + A2a `serveReadOnly` per-connection read-only serve 함수(`readInto`+`Framer`→`dispatchReadOnly`→응답+`\n`) + poll-gated accept·read-timeout 헬퍼(A2b용) — macOS-gated 테스트), control_server.zig(**A2b 라이브 서버**: 앱-전역 소켓+accept 스레드+메인 marshal 큐(`ControlRequestQueue`·`PendingRequest`, generic·AppSession 비의존, §8.8 lock-order 준수) — macOS-gated 테스트), app_host_abi.zig(A2b start/drain/stop ABI + collectSessionsInto 멀티창 조립·auth(metadata:self)·dispatch 배선), app_session.zig 안 A1 컨트롤 플레인 per-session collector(collectSessionInto/collectSession — 실 트리→중립 SurfaceDto[]+membership, private 자산 재사용 위해 세션 모듈에 co-locate)
    session_host.zig     P3 barrel(protocol·framing·screen_stream·registry·server·socket_server re-export + test 집약, test module은 socket용 link_libc). 구현은 session_host/에 목적별로.
    session_host/        P3 진행: entrypoint.zig(hidden `__session-host` CLI command의 launcher/main 공용 단일 출처),
                        protocol.zig(`MRSH` 32-byte header·kind/flag·error 어휘 codec — **구현됨, P3-a**),
                        framing.zig(partial I/O incremental parser·kind별 cap·unknown optional skip — **구현됨, P3-a**),
                        screen_stream.zig(`maru.screen-stream.v1` 28-byte record header + snapshot/delta record codec·resolved run·
                        row 폭 검증·UTF-8/cap 거부 — **구현됨, P3-b**),
                        core_command_wire.zig(host-authoritative focus/config/prompt command의 strict bounded JSON DTO·codec,
                        legacy scroll capability 분기 — **구현됨, P3-e4c-3**),
                        registry.zig(`TerminalRuntimeRegistry` + controller/observer capability state machine — runtime_id 소유표·
                        attach/detach·prepared takeover/release·resize sequence/generation·client 0 크기 유지, 실 runtime handle은
                        opaque 슬롯이고 cross-fd routing/queue는 모름 — **구현됨, P3-c + P5b3 core**),
                        server.zig(connection dispatch state machine — hello 협상 + command dispatch(host.info·runtime.list·get read-only;
                        runtime.spawn/terminate는 `RuntimeOps` 중립 vtable로 위임, controller.status/takeover/release는 side-effect-free
                        typed intent와 control frame만 생성, host만 설정·read-only는 unauthorized)·pong echo·typed error,
                        순수 로직 — **구현됨, P3-d1 + P3-e2a + P5b3 wire**),
                        subscription_identity.zig(connection-local stream↔daemon-global SubscriptionId와 stable ConnectionKey
                        양방향 권위), connection_slot.zig(fixed queue/ledger와 최대 2-slot authority control batch atomic admission),
                        connection_turn.zig(fd readiness turn과 owner callback 경계), poll_owner.zig(cross-client controller
                        revocation routing·control admission 뒤 registry commit 및 upgrade drain SSOT — **구현됨, P5b1~P5b3**),
                        socket_server.zig(실 unix socket bind(0700 dir·0600 socket·symlink 방어)·accept·peer-cred same-UID·read/write
                        I/O loop, self-contained macOS adapter(maru 무관)·process smoke — **구현됨, P3-d2a**),
                        discovery.zig(§10 socket 발견 state machine·경로 — connect-first·조회 auto-start 금지·spawn 의도 start lock
                        winner·control-plane과 경로 분리, 순수 — **구현됨, P3-d2b**),
                        daemon.zig(`maru-sessiond` entrypoint `runSessionHost` — host_id 발급·socket bind·poll-gated accept loop·
                        Connection dispatch, fork+setsid process smoke로 부모-독립 host 생존 실증, macOS 전용 — **구현됨, P3-d2c**),
                        launcher.zig(detached-helper spawn — double-fork+setsid+`/dev/null` fd+execv로 host를 부모-독립 orphan으로
                        띄움, argv 순수 조립·marker process smoke, macOS 전용 — **구현됨, P3-d2d**. `maru __session-host` CLI는
                        src/main.zig hidden 서브커맨드),
                        client.zig(GUI/CLI 측 host connect·hello·host_id 확정·read-only command 왕복 — server dispatch의 대칭,
                        순수 JSON helper·fork host roundtrip smoke, macOS 전용 — **구현됨, P3-e1**),
                        client_external_rx_turn.zig(external mode의 transport-independent sealed parser traversal,
                        final-address Scratch lifecycle·mandatory allocation guard·failure cleanup과
                        guarded parser traversal·intent move·partial cursor를 소유; storage/ledger/socket import 0 —
                        **구현됨, P3-d2c 진입 전 구조 분해**),
                        client_external_rx_read.zig(external mode의 nonblocking RX read DTO,
                        `client_external_mode.maxReadable` allowance re-export·동률 stop classifier,
                        1 MiB read/256 KiB metadata 예산과 final-address `ExternalRxReadScratch`를 소유;
                        collector·POSIX syscall·pump/storage/ledger/traversal import는 후속 gate 전까지 0),
                        client_external_mode.zig(blocking→external 전환, sealed parser provenance,
                        guarded replacement admit과 frozen cleanup·typed bounded quarantine를 소유;
                        product owner inventory와 socket read import는 0),
                        client_external_pump.zig(external storage/lease/ledger/turn aggregate와
                        cross-owner quarantine 총예산을 소유; d2c 세부 구현 상태는 verification-matrix가 단일 출처),
                        client_external_rx_turn_test_support.zig(해당 traversal의 hostile wire/owner fixture 전용,
                        제품 import 0 — **구현됨, P3-d2c 진입 전 구조 분해**),
                        handoff_inventory.zig(session host 동일 PID exec upgrade U0 — terminal core/scrollback page,
                        PTY/reader/queue, Surface/owner registry/runtime link, RuntimeManager/host registry/socket owner field를
                        serialized/reconstructed/inherited_resource/must_be_empty로 compile-time 전수 분류; 실제 codec/exec는
                        후속 — **구현됨, U0**);
                        P3-e2/e3 core 구현: runtime_manager·remote_runtime·remote_term_backend가 spawn/attach/input/resize/terminate,
                        snapshot/delta demux와 app_session discovery→launch→attach·workspace runtime-handle 재접속을 맡는다.
                        incremental checkpoint·durable tombstone·single-connection nonblocking writer는 P4,
                        multi-fd reactor·외부 attach는 P5 후속.
                        quick terminal은 확정적으로 in-process이며 persistent 범위 밖. control-plane/browser
                        server와 ID·wire를 공유하지 않으며, macOS launch/peer-cred/socket adapter만 platform 경계에 두고
                        codec/state machine은 OS 중립(platform import 0)으로 둔다. 테스트는 `zig build test-session-host`(기본 `test`에도 편입).
                        `tests/session_host_signed_upgrade_e2e.zig`는 caller-attested signed frozen N-1/current 제품 executable을 입력받아
                        non-empty PTY의 same-PID exec 성공 경로를 검증하는 macOS opt-in release gate다.
    mobile/             iOS·Android **공통분모**(L4) — mobile_bridge.zig(코어 쪽 절반: 논리 px 크기→quad 목록, 셀 판정),
                        mobile_host_abi.h(C ABI 단일 출처 — bridge export와 필드 순서·타입을 함께 바꾼다),
                        mobile_config.zig(모바일 config 스키마·파싱). **OS 호출은 두지 않는다** — 있으면 ios/·android/로 내린다
    ios/                iOS 전용 — UIKit host·Metal 백엔드·CoreText 래스터(`ios_app_host.m`)
    android/            Android 전용 — NativeActivity host·Vulkan 백엔드·JNI 래스터(`android_app_host.c`),
                        IME shim(`MaruActivity.java` — NDK에는 InputConnection 대응물이 없어 Java로 받는다), shaders/(SPIR-V)
    windows/
    linux/
  workspace/            project workspace, layout restore, recent workspaces
  observability/        DebugEvent, TraceEvent, DebugSnapshot, ReplayRunner
  plugin/               future action/plugin/Wasm boundary
```

파일 패널의 웹 콘텐츠는 루트 `web/`에 둔다. `web/src/`는 vanilla TypeScript shell·격리 renderer·sanitizer, `web/scripts/`는 zntc bundle/SRI·runtime notice/license audit, `web/tests/`는 Bun adversarial fixture를 소유한다. 생성물 `web/dist/`와 `web/node_modules/`는 커밋하지 않는다. `build.zig`가 `web:build`를 선행해 `web/dist`를 앱 `Resources/web/`에 복사하므로 옛 `src/platform/macos/web/` placeholder는 FP4에서 제거했다. 파일 read/asset 경로 정책은 L2 `src/session/file_panel_bridge.zig`, 실 surface-pinned FS I/O와 Swift ABI는 `src/platform/macos/app_session.zig`·`app_host_abi.{zig,h}`가 소유한다. Mermaid helper의 wire codec과 앱 전역 queue/failure 정책은 각각 L2 `src/session/mermaid_protocol.zig`·`mermaid_coordinator.zig`, native transport는 목적별 `MermaidProtocolBridge.swift`·`MermaidHelperProcess.swift`, 별도 helper entrypoint는 `MaruMermaidRenderer.swift`가 소유한다. `MermaidRendererPage.swift`는 helper WKWebView의 inert HTML·CSP·ephemeral data store·base URL 구성을 단독 소유하며, FP10c2의 내부 scheme/navigation 정책도 이 page 경계에서 확장한다. helper Swift에는 wire serializer나 queue 정책을 두지 않는다.

npm 라이브러리(`@maru/*`)는 루트 `packages/`에 둔다. `web/`과 분리하는 이유는 소유 주체가 다르기 때문이다 — `web/`은 **앱이 싣는** 파일 패널 콘텐츠이고, `packages/`는 **밖으로 배포하는** 패키지다. 워크스페이스 루트는 `packages/package.json`이고 하위에 `core`(wasm·바닐라 TS·렌더러)와 프레임워크 래퍼 `react`·`vue`·`svelte`·`lit`이 있다. 생성물 `packages/*/dist/`와 `packages/node_modules/`는 커밋하지 않지만, **`packages/core/wasm/maru-vt.wasm`은 커밋한다** — npm에 실려 나가는 배포 산출물이고 받는 쪽에 Zig 툴체인이 없다(소스와의 동기는 `check-wasm-sync`가 지킨다). `build.zig`의 `wasm-lib` step이 그 자리에 산출물을 놓는다. 계약은 [maru-term 라이브러리](maru-term-library.md)가 단일 출처다.

루트의 `*.zig` 파일은 외부 import 경로를 안정화하는 facade다. 실제 구현은 위 하위 폴더에 목적별로 둔다.

## 테스트 구조

```text
tests/
  unit/                 facade 밖에 둘 단위 테스트
  boundary/             facade/import 책임 경계를 자동으로 확인하는 테스트
                        (imports·icon_literals·chrome_text_clusters·cwd_axis·cli_purity — 주석에만 있던 규율을 실행 가능한 게이트로 굳힌다)
  oracle/               recorded reference terminal snapshot 비교 + 외부 오라클(libvterm·Alacritty·Ghostty, opt-in)
  stress/               대량 출력, 반복 resize, hot path 안정성 테스트
  integration/
    pty/                openpty, process, resize propagation
    ssh/                ssh localhost/통제된 원격 환경 smoke
  e2e/
    headless.zig        real process -> TerminalCore -> screen snapshot
    app/                macOS app, renderer, input, screenshot smoke
  doc_links/            docs/**의 상대 링크가 실제 파일을 가리키는지 확인한다
  config_docs/          config 키가 스키마와 문서 양쪽에 같은 상태로 있는지 확인한다
  fixtures/
    ansi/               ANSI/VT 입력 fixture
    traces/             sanitized replay trace
  golden/
    screen/             screen snapshot expected output
    dock_visual.zig     Session Dock 시각 골든 게이트
  support/              테스트 공통 helper
  artifacts/            테스트 실행 시 생성되는 로컬 산출물
  session_host_*.zig    영속 세션 호스트 경계·sentinel·E2E(진행 중 이니셔티브라 루트에 평평하게 쌓여 있다)
```

**`tests/` 루트의 flat 파일은 구조가 아니라 현재 상태다.** 위 폴더가 정본이고, 새 테스트는 그 책임
폴더에 넣는다. 루트에 쌓인 `session_host_*`는 [영속 터미널 세션 호스트](persistent-session-host.md)가
진행 중이라 아직 옮기지 않은 것이며, 그 단계가 닫힐 때 함께 정리한다 — 이 예외를 다른 도메인이
선례로 삼지 않는다.

모든 테스트 파일은 **무엇을 증명하는지와 터미널에서 왜 중요한지**를 파일 상단 주석으로 설명한다
([필수 프로젝트 규칙](project-rules.md) "테스트와 E2E"). `//!` 모듈 주석과 `//` 주석 중 무엇을 쓰는지는
규칙이 아니며, 설명이 있는지가 규칙이다.

fixture와 golden 파일의 저장 규칙은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.

## build.zig 연결 원칙

새 테스트 파일을 추가할 때는 같은 PR에서 `build.zig`와 `.mise.toml` 태스크에 연결한다.

테스트가 아직 자동화될 수 없다면 문서와 PR 설명에 다음을 남긴다.

```text
왜 자동화가 불가능한가?
어떤 수동 검증을 했는가?
나중에 자동화하려면 어떤 경계가 필요한가?
```

## 도구 구조

```text
tools/
  perf/                 로컬 성능 예산 측정 harness
  ci/                   CI 파이프라인 헬퍼. `changed-areas.sh`가 "이 diff는 어떤 CI 축을 실행해야 하는가"의 단일 출처이고 `changed-areas.test.sh`(=`mise run ci:changed-areas-check`)가 그 분류를 실제 git diff로 고정한다
```

## GitHub 구조

```text
.github/
  pull_request_template.md  PR마다 전략 영향 평가와 한계 보고를 빠뜨리지 않게 하는 템플릿
  workflows/
    ci.yml                  changed-areas 판정(changes 잡) + check 게이트(`mise run check`: fmt-check/unit/e2e/recorded-oracle/stress/facade 경계/build) + macOS 제품 경로 잡 + 외부 오라클 oracles 잡(libvterm·Alacritty, Ghostty는 CI 제외) + 테스트 artifact 업로드. 무거운 잡은 `code`/`web` 축이 바뀐 PR에서만 돈다(performance-budget.md "변경 영역별 실행")
    web.yml                 `web/**` 변경 시 Bun lock install + zntc bundle/SRI + sanitizer fixture + Oxc + license audit를 실행하고 생성 bundle evidence를 업로드
    performance.yml         `mise run perf`를 `code` 변경 PR(required check)·main push·수동·주간으로 실행한다(성능 회귀가 main에 들어가기 전에 잡는다 — 예산 정책은 performance-budget.md)
    pr-metadata.yml         라벨 1개 이상 + assignee=ohah 강제(required check 지정은 branch protection에서 한다)
    release.yml             태그 푸시(v*) 시 universal .dmg를 서명·공증해 GitHub Release에 첨부한다(distribution.md "CI 릴리스")
```
