# 실제 구현 계획

이 문서는 Maru의 실제 구현 순서를 정한다. 기준은 "빨리 화면을 띄우는 것"이 아니라, 나중에 PTY, parser, renderer, workspace, plugin이 서로 엉켜서 다시 갈아엎지 않게 하는 것이다.

## 핵심 판단

초기 구현은 [초기 세로 슬라이스](initial-vertical-slice.md)를 기준으로 한다.

```text
macOS 로컬 shell 1개 surface
-> PTY output bytes
-> TerminalCore
-> snapshot/trace artifact
-> headless test 통과
```

중요한 점은 parser 전체를 먼저 만들지 않는 것이다. 완전한 VT parser를 먼저 파면 실제 PTY와 E2E 없이 parser 코드만 커질 가능성이 높다. 초기 구현에서는 실제 shell bytes가 Maru의 책임 경계를 지나가는 경로를 먼저 만들고, parser는 fixture가 요구하는 만큼만 작게 확장한다.

## TDD 기준

모든 단계가 같은 형태의 TDD를 갖지는 않는다.

- 순수 동작은 전통적인 red -> green -> refactor TDD를 한다.
- facade와 책임 경계는 compile-time contract test, import boundary test, public API smoke test로 검증한다.
- macOS PTY나 global shortcut처럼 OS 상태에 묶이는 영역은 unit test와 opt-in integration/app smoke test를 분리한다.
- 자동화가 불가능한 영역은 PR에서 이유와 수동 검증 산출물을 보고한다.

즉 1단계부터 TDD는 가능하지만, 1단계의 TDD는 화면 출력 테스트가 아니라 "이 경계가 유지되는가"를 검증하는 contract test다.

## 1단계: Facade 계약을 코드로 고정

목표:

- `TerminalCore`, `PtySession`, `Surface`, `SurfaceRuntime`, `Snapshot`, `Trace/Event`의 최소 public 타입과 책임 경계를 만든다.
- 각 facade가 몰라야 하는 레이어를 import하지 않게 한다.
- `KeyBindingResolver`의 최소 타입을 만든다. full global shortcut은 나중에 구현하더라도, app action과 terminal input이 섞이지 않는 경계는 초반에 고정한다.
- `SurfaceRuntime`의 구체 API는 [SurfaceRuntime API 계약](surface-runtime-api.md)을 따른다.

TDD 방식:

- compile smoke test: public facade가 import되고 최소 생성/해제가 가능해야 한다.
- boundary test: `TerminalCore`가 PTY/platform/renderer 타입을 public API로 노출하지 않는다.
- config/action test: app action과 terminal input이 같은 타입으로 섞이지 않는다.
- resolver contract test: app action으로 소비된 key event는 terminal input으로 변환되지 않는다.
- resolver contract test: `send_control("b")` 같은 terminal input macro는 terminal bytes로 변환되지만 app action과 같은 key chord를 공유할 수 없다.

완료 기준:

- `mise run check` 통과.
- 새 facade가 [Facade 계약](facade-contracts.md)과 어긋나지 않는다.
- PR 설명에 각 facade가 왜 존재하는지 초보자용 설명이 들어간다.
- `zig build check-boundaries`가 `mise run check`에 연결되어 있다. 단순 import smoke test만으로 경계가 지켜진다고 주장하지 않는다.

아직 하지 않는다:

- 실제 macOS PTY spawn.
- renderer.
- workspace restore.
- plugin ABI.
- 실제 OS global shortcut 등록.

### 1단계 boundary checker 최소 요구사항

`import boundary test`는 말만으로는 부족하다. 초기에는 `zig build check-boundaries`의 Zig 기반 검사를 사용한다.

이 검사는 금지 import를 자동으로 막는 것이 목적이다. src 트리가 커져 파일 목록을 직접 관리하기 어려워지면 디렉터리 워킹 기반 import graph 검사로 고도화한다.

초기 금지 규칙:

```text
src/terminal/**  -> src/pty/**, src/platform/**, src/renderer/** import 금지
src/pty/**       -> src/terminal/** private 구현 import 금지
src/renderer/**  -> src/pty/** import 금지
src/plugin/**    -> src/terminal/** private 구현, src/pty/** handle import 금지
```

## 2단계: Snapshot과 artifact를 먼저 확정

목표:

- 실패했을 때 볼 수 있는 공통 산출물을 먼저 만든다.
- 테스트, 로그, replay, future inspector가 같은 도메인 데이터를 소비하게 한다.
- snapshot schema는 `maru.snapshot.v2`로 versioning한다. 이 버전은 제품 버전이 아니라 테스트 산출물과 replay consumer가 읽는 데이터 포맷 버전이다.
- version 유지/증가 기준은 [Snapshot Versioning](snapshot-versioning.md)을 따른다.

TDD 방식:

- same state -> same snapshot text.
- trailing spaces, cursor, size가 손실되지 않는 snapshot test.
- 실패 artifact가 `tests/artifacts/` 아래에 남는 E2E/support test.
- snapshot version test: snapshot text에 schema version이 들어간다.

완료 기준:

- screen text와 structured snapshot이 모두 생성된다.
- artifact 포맷은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.
- snapshot이 renderer나 PTY 구현 세부사항을 몰라야 한다.
- snapshot 첫 줄에 bare 토큰 `maru.snapshot.v2`가 버전 표시로 들어간다(`schema=` 접두어 없이 첫 줄 전체가 schema 토큰, 현재 코드 기준).
- `future fields`를 어디에 추가할지 문서화되어 있다. cursor mode, style, alternate screen, scrollback이 붙어도 기존 버전 consumer가 깨지지 않게 한다.

아직 하지 않는다:

- full trace/replay 구현.
- GUI inspector.

## 3단계: 초기 shell 경로에 필요한 parser/core 동작만 작게 확장

목표:

- 완전한 VT parser가 아니라, 초기 shell smoke에 필요한 최소 terminal core 동작만 TDD로 추가한다.
- CR/LF, printable text, resize, cursor 위치 같은 기본기를 먼저 안정화한다.

TDD 방식:

- ANSI fixture -> `TerminalCore.write` -> screen golden.
- recorded oracle snapshot 비교.
- resize/write stress.
- `mise run perf`로 core hot path guardrail 확인.

완료 기준:

- 작은 fixture가 늘어날 때마다 golden과 snapshot artifact가 함께 남는다.
- parser 변경이 `TerminalCore` 내부 책임으로 닫혀 있다.
- PTY나 renderer를 위해 core API를 임시로 새지 않게 한다.

아직 하지 않는다:

- xterm 전체 호환성.
- Kitty graphics protocol.
- OSC/clipboard/advanced mouse mode 전체.
- autowrap/line wrap(DECAWM pending-wrap). 현재 core는 마지막 열에서 셀을 덮어쓰며, 폭을 넘는 출력 보존은 이 단계 이후에 설계/테스트한다.
- wide-character(East-Asian width/wcwidth) 셀 폭 처리. 현재는 모든 출력 가능 문자를 1열로 전진시키므로 한글/CJK/이모지가 어긋난다.
- PTY read 경계에서 잘린 multi-byte UTF-8 처리. 현재 `write`는 버퍼 전체를 한 번에 검증하므로, 실제 forkpty(4단계)가 붙기 전에 증분 디코더가 필요하다.
- Ghostty/libghostty-vt 코드 복사.

## 4단계: macOS `PtySession` 최소 구현

목표:

- macOS `forkpty` 기반으로 먼저 통제된 command를 실행한다.
- reader thread, queue, backpressure 같은 운영 모델은 [PTY 운영 모델](pty-operating-model.md)을 따른다.
- 통제된 command가 안정화된 뒤 interactive shell smoke를 opt-in으로 추가한다.
- PTY output bytes를 domain event로 내보낸다.
- terminal input bytes와 resize request를 PTY에 전달한다.

TDD 방식:

- unit test: spawn request/env/cwd validation.
- integration test: 통제된 command stdout을 읽는다.
- integration test: resize request가 PTY layer까지 전달된다.
- process lifecycle test: exit status가 event로 관측된다.
- opt-in smoke test: 사용자의 shell을 실행해 prompt/output이 crash 없이 snapshot까지 도달하는지 확인한다.

완료 기준:

- `PtySession`은 escape sequence 의미를 모른다.
- `TerminalCore`는 PTY file descriptor를 모른다.
- 실패 시 stdout bytes와 snapshot artifact가 남는다.
- deterministic controlled command PTY test와 환경 의존 interactive shell smoke가 분리되어 있다.
- interactive shell smoke는 처음부터 기본 `mise run check`에 넣지 않는다.

아직 하지 않는다:

- SSH.
- login shell UX 완성.
- job control 전체 호환성.
- global shortcut.

## 5단계: `SurfaceRuntime`으로 PTY와 Surface 연결

목표:

- 하나의 사용 가능한 terminal surface를 만든다.
- `PTY output event -> SurfaceRuntime -> Surface -> TerminalCore -> Snapshot` 경로를 완성한다.
- `Surface`는 `TerminalCore`와 복구 가능한 metadata를 보관하고, live `PtySession` handle은 직접 저장하지 않는다.
- `SurfaceRuntime`은 app layer에서 `Surface`와 `PtySession`의 live 연결만 관리한다.
- surface metadata인 title, cwd, env, command, size를 복구 가능한 형태로 보관한다.
- workspace restore는 구현하지 않더라도 `RestorableSurfaceMetadata` 초안은 만든다.

TDD 방식:

- unit test: PTY output event가 `SurfaceRuntime`을 거쳐 surface의 `TerminalCore`로 전달된다.
- unit test: surface resize가 `SurfaceRuntime`을 통해 core resize와 PTY resize request로 분리되어 전달된다.
- snapshot test: surface metadata와 terminal state가 같은 artifact에 함께 보인다.
- metadata test: cwd/env/command/size가 serializable draft model로 round-trip된다.
- 민감정보 test 초안: env를 그대로 저장하지 않고 allowlist/redaction 경계를 둔다.

완료 기준:

- surface는 renderer 좌표나 GPU resource를 모른다.
- workspace 저장 포맷을 아직 확정하지 않아도, 저장 가능한 metadata 경계는 존재한다.
- live PTY handle은 metadata에 들어가지 않는다.
- live PTY handle은 `Surface`가 아니라 `SurfaceRuntime` 책임이다.
- env 저장 정책은 최소 초안이라도 문서화한다.

아직 하지 않는다:

- 여러 탭.
- split layout.
- workspace restore.

## 6단계: Headless E2E를 초기 성공 기준으로 고정

목표:

- GUI 없이 실제 process/PTY output이 snapshot까지 도달하는지 자동으로 증명한다.
- 기본 check에는 deterministic path만 넣는다. 환경 의존 PTY shell smoke는 opt-in으로 둔다.

TDD 방식:

- E2E fixture: controlled command -> PTY -> SurfaceRuntime -> Surface -> TerminalCore -> screen snapshot.
- failure artifact: raw output, decoded screen, structured snapshot.
- replay 준비: event 이름과 저장 위치를 먼저 맞춘다.
- trace/replay schema와 의미는 [Trace와 Replay](trace-replay.md)를 따른다.
- opt-in smoke: interactive shell -> snapshot까지 crash 없이 도달하는지 확인한다.

완료 기준:

- `mise run check`가 deterministic headless E2E를 포함한다.
- PTY 구현 PR에서 `mise run pty` 또는 동등한 opt-in 명령을 추가하고, 그 명령이 macOS PTY smoke를 실행한다.
- 실패했을 때 원인을 parser, PTY, surface 연결 중 어디서 봐야 하는지 artifact로 판단할 수 있다.

아직 하지 않는다:

- app window screenshot E2E.
- renderer frame budget.

## 7단계: Renderer와 macOS app host 연결

목표:

- renderer는 snapshot 계약만 소비한다.
- macOS app host는 입력, window, focus, surface lifecycle을 관리한다.
- 실제 backend 선택과 검증 순서는 [렌더러 전략](renderer-strategy.md)을 따른다.

TDD 방식:

- renderer unit/golden test: snapshot -> draw command model.
- app smoke test: window 생성, resize, key input artifact.
- screenshot artifact: 실제 화면 검증이 가능한 곳부터 opt-in으로 추가한다.

완료 기준:

- renderer는 PTY나 parser를 모른다.
- app host는 terminal storage를 직접 수정하지 않는다.
- 성능 예산에 startup, first drawable, frame budget 초안을 추가한다.

아직 하지 않는다:

- 고급 glyph atlas 최적화.
- 복잡한 tab/split UI.
- plugin UI hook.

## 8단계: 탭, quick terminal, global shortcut

목표:

- 최소 탭 기능과 scratch/quick terminal UX를 app action으로 얹는다.
- global shortcut은 platform/app layer에서 처리하고, PTY input과 섞지 않는다.
- `KeyBindingResolver` 자체는 1단계에서 최소 계약을 만든다. 이 단계에서는 실제 탭/quick/global shortcut 동작을 연결한다.

TDD 방식:

- config validation test: 위험한 terminal 조합을 app/global shortcut으로 등록하면 경고한다.
- resolver test: focused app keybinding의 `send_control("b")`는 `0x02` terminal input으로 내려간다.
- resolver test: exact-match global shortcut만 소비한다.
- resolver test: 등록하지 않은 `Ctrl+B`는 PTY input으로 내려간다.
- app smoke test: global shortcut 등록 성공/실패를 artifact로 남긴다.

완료 기준:

- 세부 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.
- app/global shortcut으로 소비된 key event는 PTY로 전달하지 않는다.
- terminal input macro는 focused surface가 명확할 때만 PTY로 bytes를 보낸다.
- OS가 선점한 global shortcut 등록 실패를 조용히 무시하지 않는다.

아직 하지 않는다:

- workspace restore 전체.
- plugin ABI.

이 단계에서 다루지 않고 별도로 확장하는 입력 영역:

- 기본 terminal input 인코더의 modifier 처리(`Ctrl+letter` → C0 control, `Alt/Option` → meta-ESC). 현재 `encodeKey`는 `event.modifiers`를 읽지 않는다.
- application-cursor-key 모드(DECCKM, `\x1bOA` vs `\x1b[A`)와 CSI-u/Kitty 키 인코딩. 이를 위해 `[4]u8` 키 버퍼는 더 긴 시퀀스를 담도록 확장해야 한다.

## 9단계: Workspace restore

목표:

- 프로젝트별 workspace 저장.
- 탭/분할 layout restore.
- 각 surface의 cwd/env/command restore.
- 최근 workspace 빠른 복구.
- repo별 기본 레이아웃과 scratch terminal 정책.
- 저장 대상, env redaction, command restore 정책은 [Workspace Restore 전략](workspace-restore.md)을 따른다.

TDD 방식:

- serialized workspace fixture round-trip.
- restore E2E: 저장된 layout -> surface 생성 -> command/cwd/env 확인.
- 민감정보 test: env/token/path가 fixture에 그대로 들어가지 않는지 확인.

완료 기준:

- live PTY handle은 저장하지 않는다.
- 저장 포맷은 선언적 상태만 담는다.
- 복구 실패 시 어떤 surface가 왜 실패했는지 artifact가 남는다.

## 10단계: Plugin/Wasm

목표:

- plugin은 domain event와 action facade로만 상호작용한다.
- plugin이 `TerminalCore` private storage, PTY handle, renderer resource를 직접 만지지 못하게 한다.

TDD 방식:

- fixture plugin.
- permission failure test.
- plugin panic/failure isolation test.

완료 기준:

- plugin ABI와 권한 모델은 구현 전에 사용자와 별도 논의한다.
- plugin 실패가 surface/window 전체를 죽이지 않는다.

## 현재 문서에서 정리해야 할 점

[초기 아키텍처](architecture.md)의 기존 개발 순서는 parser를 너무 앞에 둔 표현이다. 실제 구현 순서는 이 문서를 따른다. `architecture.md`는 큰 구조 설명으로 유지하고, 구체적인 순서는 이 문서를 단일 출처로 둔다.

## PR마다 확인할 질문

- 이번 PR은 위 단계 중 어디에 속하는가?
- 그 단계의 TDD 방식으로 구현 전에 실패하는 테스트를 만들 수 있는가?
- 만들 수 없다면 contract test, smoke test, 수동 artifact 중 무엇으로 대체하는가?
- 새 코드가 이전 단계의 facade 계약을 깨지 않는가?
- 자동화할 수 없는 한계를 PR 설명에 보고했는가?
