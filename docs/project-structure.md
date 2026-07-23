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
  width.zig             코드포인트 셀 폭·wide 렌더 심볼 판정 단일 출처(중립 leaf). C 게이트(coretext_smoke.m)와 주석-동기 미러
  observability.zig     debug event/trace/snapshot facade
  plugin.zig            action/plugin facade

  app/                  window/surface/runtime/pty_reader/runtime_pump처럼 앱 상태와 live 연결 책임별 구현.
                        persistent-session P2: terminal runtime의 수명·입출력·관측을 GUI layout에서 분리하는
                        vtable 계약 `term_runtime_backend.zig`(TermRuntimeBackend·RuntimeHandle — opaque, PtyIo와 같은
                        관용구)와 그 in-process 구현 `in_process_term_backend.zig`(기존 LiveSurfaceRegistry+LivePtySession+
                        SurfaceRuntime을 감쌈)를 둔다. GUI layout 정책과 session-host transport(P3 session_host/)를 한
                        파일에 섞지 않는다. P2 배선은 완료되어 app_session이 opaque handle과 backend 계약만 사용한다.
  chrome/               플랫폼 중립 디자인 시스템 구현 — draw/tokens/props/input/state/host + components/(sidebar·tabbar·settings·palette·find·notice·modal 등)
  cli/                  CLI 서브커맨드의 테스트 가능한 순수 로직(ssh: 원격 terminfo 전파 — 파싱·셸 스크립트·exec argv; install: maru CLI를 PATH에 symlink하는 경로/PATH 헬퍼; terminfo: `maru terminfo` 캐시 관리 인자 파싱 — 캐시 메커니즘은 top-level terminfo_cache.zig; sessions: 컨트롤 플레인 `sessions list`/`session get` 파서·`--help`·client wire — 1d — 및 소켓 발견 순수 정책 `controlDir`/`pickSocket` — A2a; persistent-session P5는 runtime.zig(`host status`, `runtime list/get/end`)와 attach.zig(ANSI adapter·detach chord)를 추가하되 protocol codec은 아래 session_host/를 재사용; trace: `maru trace anonymize` 인자 파싱 — 익명화 로직은 observability.trace/redact). main.zig는 얇은 디스패처로 두고 실질 로직을 여기 둔다(A2a: `runSessionRequest`가 결정론 경로 발견→`std.c.connect`→왕복→`renderResponse`, 서버 부재면 graceful; 소켓 syscall만 main에)
  session/              L2 세션 코어(OS-중립·app/pty/platform import 0, check-boundaries 강제): 세션 모델(Model·Tab·Pane·surface·split_tree·workspace·dock_panel·core_command)과 **컨트롤 플레인/이동성 골격** — surface_id(M0a), window_membership(M0b), window_graph(M1), live_surface_registry(M2a generic), control_plane(1a JSON-RPC/ndjson), control_surface(1c Surface DTO·scope 응답), control_dispatch(1d read-only 라우터), layout/input math·ime·keyhint. platform이 런타임 타입을 넣어 인스턴스화한다
  config/               action parsing, raw theme/font/cursor config, resolved appearance config
  pty/                  PTY backend, spawn request, process handle
  terminal/             parser, screen, cursor, scrollback, key/mouse encoding
  renderer/             Metal-first renderer internals, future WebGPU backend boundary, font layout, font identity registry, persistent renderer state, glyph atlas, frame stats
  platform/             OS별 process/window/input bridge
    macos/              AppKit/Metal/CoreText smoke bridge, Swift app host app shell, Swift/Zig C ABI 계약, control_socket.zig(1b: 컨트롤 플레인 unix socket bind/accept/peer-cred/hello + A2a `serveReadOnly` per-connection read-only serve 함수(`readInto`+`Framer`→`dispatchReadOnly`→응답+`\n`) + poll-gated accept·read-timeout 헬퍼(A2b용) — macOS-gated 테스트), control_server.zig(**A2b 라이브 서버**: 앱-전역 소켓+accept 스레드+메인 marshal 큐(`ControlRequestQueue`·`PendingRequest`, generic·AppSession 비의존, §8.8 lock-order 준수) — macOS-gated 테스트), app_host_abi.zig(A2b start/drain/stop ABI + collectSessionsInto 멀티창 조립·auth(metadata:self)·dispatch 배선), app_session.zig 안 A1 컨트롤 플레인 per-session collector(collectSessionInto/collectSession — 실 트리→중립 SurfaceDto[]+membership, private 자산 재사용 위해 세션 모듈에 co-locate)
    session_host.zig     P3 barrel(protocol·framing·screen_stream·registry·server·socket_server re-export + test 집약, test module은 socket용 link_libc). 구현은 session_host/에 목적별로.
    session_host/        P3 진행: protocol.zig(`MRSH` 32-byte header·kind/flag·error 어휘 codec — **구현됨, P3-a**),
                        framing.zig(partial I/O incremental parser·kind별 cap·unknown optional skip — **구현됨, P3-a**),
                        screen_stream.zig(`maru.screen-stream.v1` 28-byte record header + snapshot/delta record codec·resolved run·
                        row 폭 검증·UTF-8/cap 거부 — **구현됨, P3-b**),
                        registry.zig(`TerminalRuntimeRegistry` + controller/observer capability state machine — runtime_id 소유표·
                        attach/detach/takeover·resize sequence/generation·client 0 크기 유지, 실 runtime handle은 opaque 슬롯 —
                        **구현됨, P3-c**),
                        server.zig(connection dispatch state machine — hello 협상 + command dispatch(host.info·runtime.list·get read-only;
                        runtime.spawn/terminate는 `RuntimeOps` 중립 vtable로 위임, host만 설정·read-only는 unauthorized)·pong echo·
                        typed error, 순수 로직 — **구현됨, P3-d1 + P3-e2a**),
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
                        순수 JSON helper·fork host roundtrip smoke, macOS 전용 — **구현됨, P3-e1**);
                        P3-e2/e3 core 구현: runtime_manager·remote_runtime·remote_term_backend가 spawn/attach/input/resize/terminate,
                        snapshot/delta demux와 app_session discovery→launch→attach·workspace runtime-handle 재접속을 맡는다.
                        incremental checkpoint·quick persistence·외부 attach·완전한 nonblocking writer는 P4/P5 후속. control-plane/browser
                        server와 ID·wire를 공유하지 않으며, macOS launch/peer-cred/socket adapter만 platform 경계에 두고
                        codec/state machine은 OS 중립(platform import 0)으로 둔다. 테스트는 `zig build test-session-host`(기본 `test`에도 편입)
    windows/
    linux/
  workspace/            project workspace, layout restore, recent workspaces
  observability/        DebugEvent, TraceEvent, DebugSnapshot, ReplayRunner
  plugin/               future action/plugin/Wasm boundary
```

파일 패널의 웹 콘텐츠는 루트 `web/`에 둔다. `web/src/`는 vanilla TypeScript shell·격리 renderer·sanitizer, `web/scripts/`는 zntc bundle/SRI·runtime notice/license audit, `web/tests/`는 Bun adversarial fixture를 소유한다. 생성물 `web/dist/`와 `web/node_modules/`는 커밋하지 않는다. `build.zig`가 `web:build`를 선행해 `web/dist`를 앱 `Resources/web/`에 복사하므로 옛 `src/platform/macos/web/` placeholder는 FP4에서 제거했다. 파일 read/asset 경로 정책은 L2 `src/session/file_panel_bridge.zig`, 실 surface-pinned FS I/O와 Swift ABI는 `src/platform/macos/app_session.zig`·`app_host_abi.{zig,h}`가 소유한다. Mermaid helper의 wire codec과 앱 전역 queue/failure 정책은 각각 L2 `src/session/mermaid_protocol.zig`·`mermaid_coordinator.zig`, native transport는 목적별 `MermaidProtocolBridge.swift`·`MermaidHelperProcess.swift`, 별도 helper entrypoint는 `MaruMermaidRenderer.swift`가 소유한다. `MermaidRendererPage.swift`는 helper WKWebView의 inert HTML·CSP·ephemeral data store·base URL 구성을 단독 소유하며, FP10c2의 내부 scheme/navigation 정책도 이 page 경계에서 확장한다. helper Swift에는 wire serializer나 queue 정책을 두지 않는다.

루트의 `*.zig` 파일은 외부 import 경로를 안정화하는 facade다. 실제 구현은 위 하위 폴더에 목적별로 둔다.

## 테스트 구조

```text
tests/
  unit/                 facade 밖에 둘 단위 테스트
  boundary/             facade/import 책임 경계를 자동으로 확인하는 테스트
  oracle/               recorded reference terminal snapshot 비교
  stress/               대량 출력, 반복 resize, hot path 안정성 테스트
  integration/
    pty/                openpty, process, resize propagation
    ssh/                ssh localhost/통제된 원격 환경 smoke
  e2e/
    headless.zig        real process -> TerminalCore -> screen snapshot
    app/                macOS app, renderer, input, screenshot smoke
  fixtures/
    ansi/               ANSI/VT 입력 fixture
    traces/             sanitized replay trace
  golden/
    screen/             screen snapshot expected output
  support/              테스트 공통 helper
  artifacts/            테스트 실행 시 생성되는 로컬 산출물
```

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
```

## GitHub 구조

```text
.github/
  pull_request_template.md  PR마다 전략 영향 평가와 한계 보고를 빠뜨리지 않게 하는 템플릿
  workflows/
    ci.yml                  check 게이트(`mise run check`: fmt-check/unit/e2e/recorded-oracle/stress/facade 경계/build) + 외부 오라클 oracles 잡(libvterm·Alacritty를 매 푸시/PR에 강제, Ghostty는 CI 제외) + 테스트 artifact 업로드
    web.yml                 `web/**` 변경 시 Bun lock install + zntc bundle/SRI + sanitizer fixture + Oxc + license audit를 실행하고 생성 bundle evidence를 업로드
    performance.yml         `mise run perf`를 모든 PR(required check)·main push·수동·주간으로 실행한다(성능 회귀가 main에 들어가기 전에 잡는다 — 예산 정책은 performance-budget.md)
    pr-metadata.yml         라벨 1개 이상 + assignee=ohah 강제(required check 지정은 branch protection에서 한다)
    release.yml             태그 푸시(v*) 시 universal .dmg를 서명·공증해 GitHub Release에 첨부한다(distribution.md "CI 릴리스")
```
