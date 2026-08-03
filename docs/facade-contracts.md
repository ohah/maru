# Facade 계약

이 문서는 Maru의 핵심 facade가 무엇을 책임지고 무엇을 몰라야 하는지 정한다. 초보자 관점에서 중요한 이유는 간단하다. 터미널은 PTY, parser, renderer, workspace restore, plugin이 쉽게 서로 얽힌다. facade 계약은 얽힘을 막고, 나중에 내부 구현을 바꿔도 바깥 API를 크게 흔들지 않게 하는 울타리다.

## 공통 규칙

- 루트 `src/*.zig` 파일은 안정된 import 경로를 제공하는 얇은 facade다.
- 구현 세부사항은 하위 폴더에 둔다.
- facade는 다른 레이어의 private 구현 타입을 public API로 노출하지 않는다.
- 새로운 기능은 먼저 어떤 facade의 책임인지 정한 뒤 구현한다.
- 계약을 의도적으로 바꾸기로 합의한 경우, 같은 PR에서 문서·테스트·전략 영향 평가를 함께 갱신한다. 코드와 문서가 어긋났을 때의 일반 처리 규칙은 [PR 체크리스트](pr-checklist.md)를 단일 출처로 둔다.
- import boundary는 테스트로 확인한다. 단순히 "조심한다"는 규칙만으로 경계를 지켰다고 보지 않는다.

## `GenerationTransport`

책임:

- generation GUI attachment가 봉인한 단일 stream에 대해 closed input, control, event, RPC primitive만 제공한다.
- 매 호출에서 final address, process, owner thread, slot/node incarnation, binding과 role을 다시 검증한다.
- partial write와 각 response/event payload의 소유권 이전·해제를 typed outcome과 one-shot receipt로 표현한다. 반복 RPC의 transport
  authority 자체는 checked-monotonic epoch로 다음 호출에 재사용한다.
- attach 응답의 registry one-shot owner와 반복 RPC의 transport-local monotonic epoch owner를 분리하고, 닫힌 response destination으로
  둘을 혼용하지 못하게 한다.

몰라야 하는 것:

- raw `Client` pointer, 임의 RPC method string, `*anyopaque`, generic callback.
- `RemoteRuntime`의 input FIFO/barrier, response decode, metadata 적용 정책.
- legacy/external movable attachment의 owner graph.

정확한 15개 declaration, 단계별 migration gate와 오류/소유권 계약은
[영속 터미널 세션 호스트](persistent-session-host.md)의 CR3a-2 `GenerationTransport` 절을 단일 출처로 둔다.

## `TerminalCore`

책임:

- raw terminal output bytes를 screen state로 반영한다.
- terminal size 변경을 적용한다.
- cursor, visible cells, scrollback 같은 terminal state를 소유한다.
- renderer와 test가 소비할 snapshot을 만든다.

몰라야 하는 것:

- shell process를 어떻게 실행했는지.
- PTY file descriptor나 platform API.
- macOS window, renderer, GPU.
- workspace, tab, split, plugin runtime.

초기 테스트:

- ANSI fixture -> `TerminalCore.write` -> screen golden.
- recorded oracle snapshot 비교.
- resize/write stress.
- core hot path performance budget.

## `PtySession`

책임:

- local shell/process를 실행한다.
- PTY output bytes를 읽어 domain event로 내보낸다.
- 사용자 input bytes와 resize request를 PTY에 전달한다.
- process exit 상태를 보고한다.

몰라야 하는 것:

- escape sequence가 무슨 뜻인지.
- screen cell이나 cursor state.
- renderer frame timing.
- workspace restore 저장 포맷.

초기 테스트:

- 통제된 command가 stdout으로 낸 bytes를 읽는다.
- resize request가 PTY layer까지 전달된다.
- process exit가 domain event로 관측된다.
- app/global shortcut으로 소비된 key가 PTY input으로 내려오지 않는다.

## `Surface`

책임:

- 하나의 사용 가능한 terminal surface를 표현한다.
- `TerminalCore`와 복구 가능한 surface metadata를 소유한다.
- live `PtySession` handle은 직접 저장하지 않는다.
- surface의 title, cwd, env, command, size 같은 복구 가능한 metadata를 보관한다.
- snapshot을 만들 때 terminal state와 surface metadata를 함께 제공한다.

몰라야 하는 것:

- app window의 실제 좌표 계산.
- GPU draw call.
- workspace 파일 저장 방식.
- plugin 실행 방식.
- PTY file descriptor나 live process handle.

초기 테스트:

- Surface가 output bytes를 자신의 `TerminalCore.write`로 넘긴다(`PtySession` 없이).
- Surface size 변경이 `TerminalCore.resize`로 반영된다.
- `RestorableSurfaceMetadata`에는 cwd/env/command/size 같은 선언적 상태만 들어가고 live PTY handle은 들어가지 않는다.
- env 저장은 allowlist 또는 redaction 경계를 가져야 한다.

(PTY output routing과 PTY resize 분리는 `SurfaceRuntime` 책임이며 아래에서 테스트한다.)

## `SurfaceRuntime`

구체적인 초기 API는 [SurfaceRuntime API 계약](surface-runtime-api.md)을 따른다.

책임:

- app layer에서 `Surface`와 `PtySession`의 live 연결을 관리한다.
- PTY output event를 해당 surface의 `TerminalCore`로 전달한다.
- terminal input bytes와 resize request를 해당 `PtySession`으로 전달한다.
- process exit 같은 runtime event를 surface metadata 갱신이나 artifact로 연결한다.
- concrete `PtySession`을 직접 저장하지 않고 `PtyIo` adapter를 통해 input/resize만 호출한다.

몰라야 하는 것:

- renderer resource handle.
- workspace 저장 파일의 세부 포맷.
- plugin 내부 메모리.

초기 테스트:

- 하나의 PTY output event가 올바른 surface로 routing된다.
- surface resize가 `TerminalCore.resize`와 `PtySession.resize` 요청으로 분리된다.
- runtime 연결이 끊겨도 `RestorableSurfaceMetadata`에는 live handle이 남지 않는다.
- 같은 surface나 pty를 두 번 attach하면 오류가 난다.
- detach 이후 늦게 도착한 PTY output은 `UnknownPty`로 거부된다.
- process exit event 이후 같은 surface로 input을 보내면 `ProcessExited`가 난다.

## `LivePtySession` / `LivePtyRegistry` / `PtyReader` / `PtyEventQueue`

책임:

- `LivePtySession`은 하나의 live terminal session에 필요한 `PtySession`, `PtyEventQueue`, `PtyReader`, runtime attach link를 한 owner로 묶는다.
- `LivePtyRegistry`는 app state가 소유한 `LivePtySession`을 surface id/pty id로 찾는 non-owning mapping이다. session memory를 파괴하지 않고, native host가 active surface만으로 닫을 live PTY를 찾게 한다.
- app/demo/smoke는 개별 session/queue/reader를 따로 닫지 않고 `LivePtySession.close`, `LivePtySession.closeAndDetach`, 또는 `LivePtySession.deinit`을 호출한다. tab/window close command는 `FrameLoop.closeActiveLivePty`/`host.closeActiveLivePty`를 거쳐 registry가 active surface와 live PTY mapping을 찾고, 그 뒤 `LivePtySession.closeAndDetach`로 내려간다.
- `PtySession.readEvent`를 reader thread에서 반복 호출한다.
- reader thread가 만든 output/exit/read_error event를 bounded queue에 넣는다.
- queue가 가득 차면 output을 버리지 않고 reader thread를 기다리게 한다.
- output bytes의 소유권을 queue event로 넘기고, consumer가 `QueuedPtyEvent.deinit`으로 끝내게 한다.
- 탭/창 close 시 app host close action이 registry에서 active surface의 live PTY를 찾고 link 불변식을 검증한다. 통과하면 `LivePtySession.closeAndDetach`가 `SurfaceRuntime.detachSurface`로 runtime routing을 먼저 끊고, 내부적으로 `PtyReader.stopAndJoin`을 사용해 queue를 닫고, session을 close한 뒤 reader thread가 끝날 때까지 기다린다. registry mapping은 close가 성공한 뒤에 제거한다. close 전 검증이 실패하면 원인 추적을 위해 mapping을 보존한다.

몰라야 하는 것:

- escape sequence 의미.
- `TerminalCore` private storage.
- renderer resource handle.
- workspace 저장 포맷.

초기 테스트:

- queue capacity가 0이면 생성하지 않는다.
- queue가 full일 때 무한히 늘리지 않고 `QueueFull`로 관측된다.
- close된 queue는 새 push를 거부하고 empty pop을 종료한다.
- `LivePtySession`이 실제 macOS controlled command output/exit를 정상 종료까지 소유하고, `finishAfterTermination` 뒤 cleanup이 중복 stop하지 않는다.
- `LivePtySession.closeAndDetach`가 닫힌 surface를 runtime에서 detach하고 queue를 닫아 late output/input을 거부한다.
- `LivePtyRegistry`가 중복 surface/pty 등록을 거부한다.
- `LivePtyRegistry.closeActive`가 active surface mapping만 닫고, active가 아닌 surface의 PTY는 닫지 않는다.
- `LivePtyRegistry.closeActive`가 link 불변식 실패 시 mapping을 삭제하지 않는다.
- `host.closeActiveLivePty`가 registry를 통해 active surface live PTY를 닫고 mapping을 제거한다.
- 실제 macOS PTY controlled command output/exit가 reader thread와 queue를 지나 `SurfaceRuntime`에 적용된다.
- 실제 macOS PTY에서 출력이 없는 long-running child 때문에 reader가 blocking read 중이어도 `stopAndJoin`이 reader를 정리하고 child zombie를 남기지 않는다.

아직 하지 않는다:

- macOS window/app event loop의 실제 tab/window close button event와 `FrameLoop.closeActiveLivePty` 연결.
- 대량 stdout backpressure의 RSS/latency/UI responsiveness 성능 예산.

## `RuntimeEventPump`

책임:

- app/runtime loop가 `PtyEventQueue`에서 꺼낸 `QueuedPtyEvent`를 `SurfaceRuntime.applyPtyEvent`로 적용한다.
- queue event의 output bytes 소유권을 정확히 한 번 끝낸다.
- non-blocking drain과 blocking-until-termination drain을 제공한다. 후자는 headless integration을 위해 설계했고, `maru demo`(`zig build demo`)가 실행하는 `headless_demo`가 첫 실소비자다. 다만 byte 수집이 필요한 현재 macOS PTY integration test는 `applyQueuedEvent`로 자체 루프를 돈다.
- exit/read_error 같은 예상 가능한 종료는 error가 아니라 `DrainSummary.ended` 데이터로 반환한다.
- 실패 경로에서도 event 해제를 한 곳에서 처리해 테스트 helper마다 별도 ownership 규칙이 생기지 않게 한다.

몰라야 하는 것:

- macOS window server나 renderer frame timing.
- escape sequence 의미.
- workspace 저장 포맷.
- plugin 내부 메모리.

초기 테스트:

- queued output이 pump를 거쳐 surface core에 적용되고 output bytes가 해제된다.
- queued exit가 surface `process_state`를 `exited`로 바꾼다.
- 빈 queue에서 non-blocking drain이 즉시 끝난다.
- 종료 event가 오기 전에 queue가 닫히면 성공처럼 처리하지 않고 `ReaderQueueClosedBeforeTermination`을 반환한다.
- read_error는 `ReadFailed` throw가 아니라 `DrainSummary.ended.read_error`로 반환되고, 그 전에 적용한 output summary를 잃지 않는다.
- 알 수 없는 PTY로 들어온 output은 `UnknownPty`를 유지하면서도 output bytes를 해제한다.

아직 하지 않는다:

- 실제 macOS window/app event loop.
- macOS window/app event loop에서 시작되는 interactive shell shutdown lifecycle.
- 대량 stdout backpressure의 RSS/latency/UI responsiveness 성능 예산.

## `TermRuntimeBackend`

persistent-session P2의 seam이다. GUI layout(`session_model.Term`)이 terminal runtime 하나의 수명·입출력·관측을 다루는 유일한 표면으로, 구현 세부(in-process인지 원격 host인지)를 숨긴다. 단일 출처는 [영속 터미널 세션 호스트](persistent-session-host.md) §13 P2, API 계약은 [SurfaceRuntime API 계약](surface-runtime-api.md)과 같은 결이다.

책임:

- terminal runtime의 action을 spawn/attach/input/resize/pump/terminate/observe로 계약화한다. `runtime.PtyIo`와 같은 ctx+fn 포인터 vtable이다.
- runtime을 opaque `RuntimeHandle`로 가리킨다. handle 의미를 비트에 인코딩하지 않는다(P3에서 host 발급 `runtime_id`로 승격).
- `spawn`은 복구 가능한 `*Surface`만 돌려주고 live PTY handle은 노출하지 않는다.
- in-process 구현(`InProcessTermBackend`)은 기존 `LiveSurfaceRegistry`+`LivePtySession`+`SurfaceRuntime`을 감쌀 뿐 새 소유 자원을 만들지 않는다.

몰라야 하는 것:

- 호출자가 GUI인지 CLI인지, runtime이 in-process인지 원격 host인지(계약은 같다).
- renderer resource, workspace 저장 포맷, window 좌표.
- web surface(sentinel, PTY 없음)의 표시 정책 — terminal runtime만 다룬다.

초기 테스트:

- fake backend가 계약만으로 spawn→attach→input→resize를 수행하고, 입력이 그 runtime의 PTY 더블에 도달한다.
- `closeAndDetach` 뒤 같은 handle 입력이 `UnknownSurface`로 거부되고 살아 있는 다른 runtime으로 새지 않는다(late event).
- 미등록/web-arm handle의 attach/pump는 다른 runtime에 잘못 붙지 않고 거부된다.
- in-process 구현이 실 PTY로 controlled command를 종료까지 몰고 슬롯을 누수 없이 회수한다(macOS opt-in).

이미 배선됨(P2-b): `app_session`의 GUI layout(`TermRuntime`)이 `*LivePtySession` 대신 opaque `handle`을 들고, createTerm(spawn/attach/pump)·destroyTerm/close/deinit(terminate)·pollAgentKinds(`foregroundProcess*` 관통 관측)를 전부 `AppSession.termBackend()` + handle로 수행한다. `TermRuntime`에 `*LivePtySession` 필드가 없음을 컴파일 타임 test가 고정한다.

아직 하지 않는다:

- 원격 host transport(P3 `maru-sessiond`)와 snapshot/delta 스트림.
- web surface를 이 계약으로 다루는 것(web arm은 PTY 없는 sentinel이라 대상 밖 — `live_registry` 직접 정리).

## `AppHost`

책임:

- app window의 active surface를 기준으로 한 frame을 조립한다.
- `RuntimeEventPump.drainAvailable`로 PTY event를 surface에 반영한다.
- active surface snapshot을 renderer facade의 `DrawList`로 변환한다.
- focused input과 resize action을 `SurfaceRuntime`으로 보낸다.
- 실제 UI가 아직 없을 때는 smoke artifact에 `visible_ui=false`를 명시한다.

몰라야 하는 것:

- PTY file descriptor나 concrete process handle.
- `TerminalCore` private storage.
- Metal/AppKit private resource handle.
- workspace 저장 파일의 세부 포맷.

초기 테스트:

- queued output을 drain한 뒤 active surface의 `DrawList`를 만든다.
- focused input은 active surface id로 `SurfaceRuntime.writeInput`에 전달된다.
- resize는 `SurfaceRuntime.resize`를 통해 terminal storage와 PTY resize adapter 둘 다 갱신한다.
- `mise run app-smoke`가 summary와 draw-list artifact를 남긴다.

## `Workspace`

책임:

- 프로젝트별 workspace 식별자와 root path를 관리한다.
- 탭/분할 layout restore에 필요한 선언적 상태를 저장한다.
- 최근 workspace 목록을 관리한다.
- repo별 기본 레이아웃과 scratch terminal 정책을 나중에 수용한다.

몰라야 하는 것:

- live PTY file descriptor.
- terminal parser 내부 상태.
- renderer resource handle.

초기 테스트:

- 저장 가능한 layout model round-trip.
- cwd/env/command metadata가 민감정보 정책을 지키는지 확인.

## `Snapshot`

schema version 유지/증가 기준은 [Snapshot Versioning](snapshot-versioning.md)을 따른다.

책임:

- test, debug log, replay, future inspector가 같은 terminal 상태를 보게 한다.
- visible screen, cursor, size, surface/workspace metadata를 구조화한다.
- 실패 artifact로 저장할 수 있는 안정된 텍스트 표현을 제공한다.
- schema version을 포함한다. 현재 코드가 내보내는 버전은 `maru.snapshot.v3`이다. style, cursor mode, alternate screen, scrollback 같은 future field가 붙어도 기존 버전 consumer가 깨지지 않도록 추가 시 버전을 올린다.

몰라야 하는 것:

- snapshot을 만든 원인이 PTY인지 replay인지 renderer인지.
- GPU texture나 platform window handle.

초기 테스트:

- 같은 terminal state는 같은 snapshot text를 만든다.
- trailing spaces, cursor, size가 손실되지 않는다.
- snapshot text에 schema version이 포함된다.

## `Trace/Event`

trace schema와 replay 동작은 [Trace와 Replay](trace-replay.md)를 따른다.

책임:

- raw output bytes, key input, resize, process lifecycle을 시간순 event로 기록한다.
- replay runner가 public facade만 통해 같은 상태를 재현할 수 있게 한다.
- 민감정보가 들어갈 수 있는 cwd/env/command/raw bytes를 sanitized fixture로 바꿀 경계를 둔다.

정식 event 어휘는 이 표를 단일 출처로 둔다. trace kind와 `SurfaceRuntime`의 `RuntimePtyEvent`/입력 경로는 다음과 같이 대응한다.

| trace kind | runtime 대응 | 비고 |
| --- | --- | --- |
| `output` | `RuntimePtyEvent.output` | PTY → surface 방향. |
| `input` | `SurfaceRuntime.writeInput`(`TerminalInput`) | app → PTY 방향이라 대응하는 `RuntimePtyEvent`가 없다. |
| `resize` | `SurfaceRuntime.resize` | core resize와 PTY resize를 한 event로 묶는다. |
| `process-exit` | `RuntimePtyEvent.exited` | 같은 사건의 두 이름이다(=**검증된 자식 종료**). 새 이름을 추가하지 않는다. |
| `read-error` | `RuntimePtyEvent.read_error` | reader I/O 오류 종료. payload `err=<errno 이름>`(`@errorName`, PII 없음). `process-exit`(검증된 종료)과 **별개 kind**라 트레이스에서 세션 종료 트리거가 검증된 exit인지 미검증 read_error인지 구분된다. replay 화면 상태엔 영향 없는 메타데이터(skip). |

Shell integration event(`shell.cwd-changed`, `shell.prompt-start`, `shell.prompt-end`, `shell.command-start`, `shell.command-end`)는 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#shell-integration)의 어휘를 따른다. 이 event를 `maru.trace.v1`에 저장하는 구현 PR은 먼저 이 표와 [Trace와 Replay](trace-replay.md)의 schema를 함께 갱신해야 한다. raw OSC bytes를 각 기능이 임시로 파싱하지 않는다.

Control-plane JSON-RPC 요청/응답/notification도 아직 이 표의 정식 event가 아니다. 세션 컨트롤 플레인 구현에서 이를 trace/replay에 남기려면 `control.request`/`control.response`/`control.notification` 같은 trace kind, id 매칭, 실패 응답, redaction 범위, replay 의미를 이 표와 [Trace와 Replay](trace-replay.md)에 먼저 추가한다. 기존 `output`/`input`/`resize` event에 임시 payload로 끼워 넣지 않는다.

몰라야 하는 것:

- private parser storage.
- renderer 내부 frame resource.
- plugin 내부 메모리.

초기 테스트:

- trace -> replay -> snapshot이 원래 snapshot과 같아야 한다.
- 민감정보가 있는 event를 fixture로 저장할 때 제거 규칙을 적용한다.

## Plugin 경계

초기 구현에서는 Wasm plugin을 구현하지 않는다. 다만 나중에 plugin이 들어와도 core를 직접 만지지 못하게 다음 방향만 유지한다. 제품 정책과 권한 기본값은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#plugin--wasm)을 따른다.

- plugin은 domain event와 action facade를 통해서만 상호작용한다.
- plugin은 `TerminalCore` private storage, PTY handle, renderer resource를 직접 받지 않는다.
- plugin 실패는 surface/window 전체를 죽이지 않고 격리되어야 한다.

Plugin ABI나 권한 모델을 확정해야 하는 순간이 오면, 구현 전에 사용자와 별도 논의한다.

## 키 입력과 글로벌 핫키 경계

글로벌 핫키는 platform/app layer 책임이다. `TerminalCore`와 `PtySession`은 글로벌 핫키가 있다는 사실을 몰라야 한다. 제품 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#global-shortcut)을 따른다.

계약:

- platform layer는 OS 전역 shortcut 등록 성공/실패를 app layer에 보고한다.
- app layer는 key event를 `AppAction` 또는 `TerminalInput`으로 분류한다.
- `src/config/keybinding.zig`의 `KeyBindingResolver`는 이 최소 계약을 소유한다. 아직 파일 설정 parser나 AppKit keyDown bridge가 아니며, 순수 resolver로 충돌과 terminal byte 변환만 검증한다.
- terminal input macro는 `send_control`, `send_text`, `send_escape_sequence` 같은 명시적 terminal input action으로 표현한다.
- `PtySession`은 이미 terminal input으로 분류된 bytes만 받는다.
- app/global shortcut으로 소비된 key event는 PTY로 전달하지 않는다.

세부 충돌 규칙은 [키 입력과 단축키 경계](key-input-and-shortcuts.md)를 따른다.
