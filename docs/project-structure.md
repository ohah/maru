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
  color.zig             backend-neutral 색 primitive(Rgb). terminal/renderer/config가 공유
  config.zig            action/config facade
  pty.zig               process/PTY facade
  renderer.zig          render facade
  terminal.zig          terminal-core facade
  observability.zig     debug event/trace/snapshot facade
  plugin.zig            action/plugin facade

  app/                  window/surface/runtime/pty_reader/runtime_pump처럼 앱 상태와 live 연결 책임별 구현
  config/               action parsing, theme/font config
  pty/                  PTY backend, spawn request, process handle
  terminal/             parser, screen, cursor, scrollback, key/mouse encoding
  renderer/             Metal-first renderer internals, future WebGPU backend boundary, font layout, glyph atlas, frame stats
  platform/             OS별 process/window/input bridge
    macos/
    windows/
    linux/
  workspace/            project workspace, layout restore, recent workspaces
  observability/        DebugEvent, TraceEvent, DebugSnapshot, ReplayRunner
  plugin/               future action/plugin/Wasm boundary
```

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
    performance.yml         `mise run perf`를 main push/수동/주간으로 실행한다(PR required check 아님)
    pr-metadata.yml         라벨 1개 이상 + assignee=ohah 강제(required check 지정은 branch protection에서 한다)
```
