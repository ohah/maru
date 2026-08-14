# Trace와 Replay

이 문서는 Maru에서 trace/replay가 정확히 어떤 기능인지 설명한다.

## 한 줄 정의

Trace는 터미널에서 일어난 일을 시간순으로 기록한 파일이다. Replay는 그 기록을 다시 먹여서 같은 화면 상태가 나오는지 확인하는 기능이다.

## 왜 필요한가

터미널 버그는 보통 이렇게 보인다.

```text
vim을 열고 resize한 뒤 한글을 입력했더니 화면이 깨졌다.
```

이 말만으로는 원인을 찾기 어렵다. 원인이 다음 중 어디인지 모른다.

- PTY가 bytes를 이상하게 잘랐는지
- UTF-8 증분 디코더가 깨졌는지
- parser가 escape sequence를 잘못 해석했는지
- resize 순서가 잘못됐는지
- renderer가 snapshot을 잘못 그렸는지

Trace는 이 상황에서 "실제로 어떤 bytes와 resize/input event가 어떤 순서로 들어왔는지"를 저장한다. Replay는 그 저장된 기록을 GUI 없이 `TerminalCore`에 다시 넣어서 같은 문제를 재현한다.

## trace가 기록하는 것

초기 trace schema는 `maru.trace.v1`이다.

```text
maru.trace.v1
event 1 output surface=1 bytes="hello\\r\\n"
event 2 input surface=1 bytes="ls\\r"
event 3 resize surface=1 cols=120 rows=40
event 4 process-exit surface=1 code=0
```

필수 필드:

- schema 토큰: 첫 줄 전체가 bare 토큰 `maru.trace.v1`이다. snapshot과 같은 규칙으로 `schema=` 접두어를 쓰지 않는다.
- `event index`: 이벤트 순서. timestamp보다 중요하다.
- `event kind`: `output`, `input`, `resize`, `process-exit`, `read-error`.
- `surface`: 어느 surface에 속한 이벤트인지.
- event별 payload.

event kind는 `SurfaceRuntime`의 runtime event와 1:1로 맞춘다. 정식 대응표는 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절을 단일 출처로 둔다. 요약하면 `process-exit`는 runtime의 `RuntimePtyEvent.exited`(=**검증된 자식 종료**)와 같은 사건이고, `read-error`는 `RuntimePtyEvent.read_error`(reader I/O 오류 종료 — `err=<errno 이름>`, 예: `WriteFailed`=write EIO=slave 사라짐/자식 죽음, `PollFailed`=POLLNVAL=fd 레이스)와 같은 사건이다. 둘을 **별개 kind**로 둬, 세션 종료 트리거가 검증된 exit인지 미검증 read_error인지 트레이스만 봐도 구분된다("인터럽트에 탭이 왜 사라졌나" 진단 — read_error 무검증 종료 수정의 관측 경로). `read-error` payload에는 PII가 없어(정적 errno 이름) anonymize·redaction 대상이 아니다. 재생 화면 상태엔 영향 없는 메타데이터다(replay는 skip).

### Shell integration event (semantic prompt 라이프사이클)

`TerminalCore`가 OSC 133/7을 파싱하며 `types.ShellEvent`(`prompt_start`·`input_start`·`command_start`·`command_end{row,exit}`·`cwd_changed`)를 시간순으로 기록하고, 소비자가 `shellEvents()`로 읽고 `clearShellEvents()`로 비운다. 같은 도메인 데이터를 디버그 로그(`MARU_DEBUG`의 `shell.*` scoped 로그)·결정적 테스트·trace 직렬화가 공유한다(관측 가능성 원칙 — 임시 포맷을 따로 두지 않는다).

**이 스트림은 제품 신호로 쓸 수 없다(현재 배선 기준).** 위 문장만 보면 아무 소비자나 붙일 수 있어 보이지만, 실제로 비우는 곳은 `app_session/term.zig`의 `drainShellEventsForFrame` **하나**이고 그 배선에 제약이 둘 있다.

- **활성 Term 하나만 비운다**(`activeSurface(self).core`, 원격 surface는 통째로 skip). 비활성 Term의 이벤트는 아무도 드레인하지 않아 `shell_events_cap`(4096)에 닿으면 새 이벤트가 드롭되고 `shellEventsOverflowed()`가 계속 선다. 메모리는 상한이 있어 새지 않지만, **그 Term의 이벤트 스트림은 그 시점부터 불완전하다.**
- **매 프레임 비운다.** 다른 소비자가 읽기 전에 사라지므로, 같은 프레임 안에서 그 자리에 함께 붙지 않는 한 아무것도 못 본다.

지금 실해는 없다 — 유일한 소비자가 `MARU_DEBUG` 디버그 로그이고 제품 판정에 쓰이는 값이 없다. 하지만 **쓸 수 있어 보이는데 조용히 틀리는 자리**다. 실제로 cwd 축의 낡은 OSC 7 문제를 풀다 `cwd_changed`를 "OSC 7이 방금 왔다"는 신호로 쓰려던 시도가 여기서 막혔다([editor-surface-dock.md](editor-surface-dock.md) §3.5의 그 항목). 새 소비자가 필요하면 **`drainShellEventsForFrame`에 함께 붙이거나**, 그 전에 드레인 범위를 전체 Term으로 넓혀야 한다.

**직렬화·역파싱이 구현됐다**(writer + reader): `observability/trace.zig`의 `renderShellEvents`/`writeEvent`(writer)가 이벤트 스트림을 `maru.trace.v1` 라인으로 굳히고, `parseEvents`(reader — shell.* 와 base kind 통합)가 그 라인을 `ParsedEvent{index, surface_id, event: Event}`로 되읽는다(`Event` union의 `cwd_changed`/`output`/`input`은 unescape된 소유 문자열). `parseEvents(renderShellEvents(events, cwd))`가 원 이벤트와 cwd를 복원한다(round-trip 테스트). 이벤트 이름은 trace 토큰과 1:1이다. escape/unescape는 `text_escape.zig` 단일 출처를 공유한다.

```text
maru.trace.v1
event 0 shell.prompt-start surface=1 row=0
event 1 shell.prompt-end surface=1 row=0
event 2 shell.command-start surface=1 row=1
event 3 shell.cwd-changed surface=1 cwd="/Users/me/proj"
event 4 shell.command-end surface=1 row=2 exit=0
```

- `prompt_start`↔`shell.prompt-start`, `input_start`↔`shell.prompt-end`(입력 시작=프롬프트 끝), `command_start`↔`shell.command-start`, `command_end`↔`shell.command-end`, `cwd_changed`↔`shell.cwd-changed`.
- `row=`는 이벤트 발생 시점의 활성 화면 커서 행.
- `command-end`의 `exit=`는 OSC 133 D의 종료코드, 없으면 `exit=none`.
- `cwd="..."`는 `currentCwd()` 값(따옴표로 감싸고 `\` `"`·개행/CR/Tab을 escape). `ShellEvent.cwd_changed`는 값을 안 들므로(POD) 직렬화 시점의 `currentCwd()`를 적는다 — 한 batch에 cwd_changed가 둘이면(한 프레임 내 연속 cd) 둘 다 현재 cwd로 적힌다(문서화된 한계).

**구현됨**: base kind(`output`/`input`/`resize`/`process-exit`/`read-error`) writer(`writeOutputEvent`/`writeResizeEvent`/`writeInputEvent`/`writeProcessExitEvent`/`writeReadErrorEvent`) + reader(`parseEvents` — shell.* 와 base kind 전부 되읽음) + **replay 재적용**(`observability/replay.zig`의 `replayTrace`, 아래 "replay가 하는 일") + **live 레코딩**. `output`을 재생하면 파서가 화면·셸 이벤트·cwd를 전부 재도출한다(byte-for-byte).

**live 레코딩**(구현됨): `MARU_TRACE=<파일경로>`로 켠다. `app/trace_recorder.zig`의 `TraceRecorder`가 `SurfaceRuntime.applyPtyEvent`(output/exited/**read_error**)·`resize`(output/resize/process-exit/read-error)·`writeInput`/`writeInputNonBlocking`(input) 훅에서 base kind를 host가 준 file writer에 **이벤트마다 쓰고 flush**한다(증분 append). 그래서 **크래시가 나도 직전까지의 이벤트가 디스크에 남아** 재생된다(clean 종료 불필요 — `AppSession.deinit`은 마지막 버퍼 flush + sync + close만). opt-in(미설정이면 오버헤드 0), 8 MB 상한. write가 중간에 끊겨 부분 줄이 남아도 reader(`parseEvents`)가 잘린 마지막 줄을 관대 처리한다. shell.* 이벤트는 `output`에서 파생되므로 재생의 권위는 base kind다. **input은 재생 화면엔 안 쓰인다**(입력은 child로 갔고, 화면은 child가 되돌린 output의 echo로 재구성) — 완전한 세션 기록·타이밍 분석용이다. ⚠️input은 화면에 안 뜨는 타이핑(비밀번호 프롬프트 등)까지 담아 output보다 민감하다: guardFixture/anonymize가 할당·PII는 처리하지만 bare 비밀은 못 잡으니 fixture 승격 전 사람 검토가 최종 안전망.

**아직 없는 것**(후속): GUI inspector(아래 "GUI inspector 설계 방향"), allowlist(`PATH`/`LANG` — 정책상 사용자 확인 선행).

## 디버깅 워크플로: 세션 종료 트리거 판독

"인터럽트(Ctrl+C)에 좌측 탭이 왜 사라졌나" 같은 **세션/pane 종료 원인**을 사후에 특정하는 표준 절차다. `process-exit`(검증된 자식 종료)와 `read-error`(reader I/O 오류 종료)를 별개 kind로 남기므로, 트레이스만 봐도 트리거가 구분된다.

```bash
# 1. 트레이스를 켜고 앱 실행(파일은 그 창의 모든 surface 이벤트를 surface_id 태그로 증분 기록)
MARU_TRACE=/tmp/maru.trace mise run macos-app

# 2. 재현: 좌측 탭 셸에서 claude 등을 실행하고 Ctrl+C 인터럽트를 평소처럼 반복(간헐 케이스 유도)
# 3. 증상(탭 사라짐/pane 무응답) 재현 후 앱 종료(deinit이 최종 flush; 크래시여도 직전까지 디스크에 남음)

# 4. 종료 이벤트만 추려 트리거 판독
grep -E "read-error|process-exit" /tmp/maru.trace
```

판독:

| 인터럽트 근처에 나타난 이벤트 | 트리거 해석 |
| --- | --- |
| `read-error surface=<s> err=WriteFailed` | write EIO = slave fd 사라짐 = **자식이 실제로 죽음**(이 경우 `reapIfExited`가 죽음을 확인하면 `.exited`로 승격돼야 정상) |
| `read-error surface=<s> err=PollFailed` 등 | POLLNVAL 등 = fd 레이스 = **자식은 살아있는데 PTY 연결만 깨짐**(미검증 reader 오류 — `terminationClosesWorkspace`가 탭을 안 닫고 유지) |
| `process-exit surface=<s> code=<n>` | **검증된 셸 종료**. `code`로 원인 추적(0=정상, 130=SIGINT로 죽음 등) |
| 인터럽트 근처에 둘 다 없음 | claude가 SIGINT만 잡고 계속 실행 — **아무 종료도 없음**(정상) |

단일 출처: `read_error` 무검증 종료가 산 셸을 죽이고 탭을 닫던 루트커즈와 그 닫기 게이트는 [PTY 운영 모델](pty-operating-model.md)의 "read_error vs 검증된 exit — 워크스페이스 자동 닫기 게이트" 절.

## GUI inspector 설계 방향 (후속 — 미구현)

캡처한 세션을 사람이 **넘겨보며 각 순간의 화면을 보는** 뷰어다(트레이드오프 논의 결과 확정된 방향).

- **관전형(read-only)이다.** replay 스텝을 앞뒤로 스크럽하며 그 시점 화면을 본다 — asciinema·게임 다시보기와 같은 결. **중간 개입(입력 주입·상태 변경)은 없다:** replay엔 살아있는 셸이 없어(child 프로세스는 녹화에 없음) 개입이 원리적으로 불가능하다. 개입이 필요하면 그건 replay가 아니라 **라이브 디버깅**(런타임/컨트롤 플레인을 건드리는 별개 작업)이다.
- **HTML로, [웹 패널](web-panel.md)(인앱 브라우저)에 띄운다** — 네이티브 창이 아니다. 이유: (1) 이미 만드는 웹 패널을 재사용해 **새 UI 구조가 0**이다(네이티브 패널은 웹 패널과 기능이 겹치는 중복 UI가 된다), (2) 화면은 **터미널 격자**라 터미널 안에 그리면 색/커서가 엉키지만(터미널 속 터미널) HTML에선 자연스럽다, (3) 파일 하나로 공유·첨부 가능. 자기완결 HTML이라 웹 패널 완성 전엔 아무 브라우저로도 열린다.
- **replay 엔진을 그대로 쓴다(단일 출처).** 스텝 계산 = `replayEventsForSurface`로 N번째까지 재생 → `dumpUtf8`(레벨1: 글자 격자를 `<pre>`) 또는 `renderTerminalSnapshot`(레벨2: 칸별 색을 `<span>`). 브라우저에서 터미널을 재구현하지 않는다 — Zig 코어가 이미 만든 **완성된 격자를 칠하기만** 한다. HTML은 `maru trace anonymize`와 같은 패턴으로 **Zig가 문자열로 생성**하고, 브라우저 안 스크립트는 "슬라이더→미리 구운 화면 바꿔치기" 수십 줄뿐.
- **예상 CLI**: `maru trace inspect <trace> [out.html]`. 규모는 중간 PR 1개(replay·CLI 재사용 — 익명화·fixture+CI급). 각 스텝 재생은 한 코어에 이어붙여 O(N)으로.

### Control-plane event (미정)

[세션 컨트롤 플레인](control-plane.md)의 JSON-RPC 요청/응답/notification은 현재 `maru.trace.v1` event kind가 아니다. 따라서 구현 PR은 기존 trace 포맷을 그대로 "재사용"한다고 주장하면 안 된다. 컨트롤 플레인 기록이 필요해지는 PR은 먼저 [Facade 계약](facade-contracts.md)의 `Trace/Event` 대응표와 이 문서를 함께 갱신해 `control.request`/`control.response`/`control.notification` 같은 어휘, id 매칭, 실패 응답, replay 의미를 확정한다.

이 event에는 cwd, scrollback, command output, capability token, WebDriver script/cookie 같은 민감 데이터가 섞일 수 있다. 저장 전 redaction은 [프로젝트 규칙](project-rules.md)의 기준을 따르고, capability/token 값은 fixture에 남기지 않는다.

초기에는 wall-clock timestamp를 replay 의미에 쓰지 않는다. 시간은 디버깅 보조 정보일 수 있지만, replay의 정답은 event 순서다.

## replay가 하는 일

Replay runner(`observability/replay.zig`의 `replayTrace`)는 trace를 읽고 **public 경로만** 호출한다 — `parseEvents`로 되읽은 뒤 두 모드로 재적용한다. **한 core엔 한 surface만** 재구성한다(멀티 surface trace는 target=첫 output의 surface만; 다른 pane은 `replayEventsForSurface`로 각각) — 안 그러면 탭/split 출력이 한 화면에 뒤섞인다. 각 surface의 **초기 grid 크기는 attach 시점에 첫 resize 이벤트로 기록**돼(trace가 self-contained) replay가 원 크기를 정확히 복원한다.

```text
trace file
-> parseEvents (reader)
-> replayTrace
   ├─ 화면 replay(권위): output → core.write, resize → core.resize
   │    → 파서가 화면·셸 이벤트·cwd를 전부 재도출(byte-for-byte). shell.* 는 output 파생이라 재발행 안 함.
   └─ semantic replay(fallback): output 없는 shell-only trace는 shell.* 를 OSC로, cwd를 OSC 7로 재발행
        (행 좌표는 CUP로 커서를 먼저 두어 재현)
-> TerminalCore
-> RenderSnapshot (renderTerminalSnapshot)
```

중요한 점은 replay가 private parser storage를 직접 만지지 않는다는 것이다. 실제 앱과 같은 public 경로(`core.write`/`core.resize`)로만 재현해야 파서 버그까지 제대로 잡는다.

replay에는 live `PtySession`이 없다. trace는 이미 일어난 입력의 기록이므로, `writeInput`/`resize`의 PTY 방향 부수효과(child에게 bytes 전달, master fd ioctl)는 재현 대상이 아니다. 따라서 replay runner는 `SurfaceRuntime`에 no-op `PtyIo`를 attach하거나 core 방향 효과만 적용하고, PTY 방향 호출은 무시한다. replay의 정답은 `output`/`resize` event가 `TerminalCore`에 반영된 결과이지 child process 재실행이 아니다.

## trace와 로그의 차이

로그는 사람이 읽기 위한 설명이다.

```text
PTY output 12 bytes
resize to 120x40
```

Trace는 프로그램이 다시 실행할 수 있는 입력이다.

```text
event 3 resize surface=1 cols=120 rows=40
event 4 output surface=1 bytes="..."
```

그래서 trace는 로그보다 엄격한 schema가 필요하다.

## ConnectionIncident 진단 artifact

실행 중 session-host transport reconnect의 진단 단일 출처는 trace event가 아니라 중립 leaf
`src/observability/connection_incident.zig`의 versioned `ConnectionIncident` DTO다. `incident_id`는
`{app_instance_nonce: u128, sequence: nonzero checked-monotonic u64}`이며 zero/wrap은 새 incident/reconnect를 fail-close한다.
detail filename은 `i-<app_instance_nonce 32hex>-<sequence 16hex>.incident`, aggregate filename은
`a-<app_instance_nonce 32hex>-<record_generation 16hex>-<digest 64hex>.incident`다. aggregate slot은 봉투에 canonical
encoding되지 않으므로 파일 이름 권위로 복제하지 않고, 실제 봉투 generation과 digest를 결속한다. 모든 hex는 고정 길이
lowercase이고 다른 문자·축약·대문자를 허용하지 않는다. session client는 typed poison tuple과
bounded 숫자/enum만 채우고, 구조화 로그·테스트 artifact·future inspector가 같은 DTO를 직렬화한다. 최초 incident는
immutable이고 반복 횟수와 first/last timestamp만 별도 bounded `IncidentAggregate`가 갱신한다. raw terminal input/output,
paste, clipboard, cwd, command, SSH 주소와 임의 오류 문자열은 DTO에 들어가지 않는다.

### CR0b exact schema와 publication owner

`ConnectionIncident`는 Zig struct padding을 wire나 seal에 쓰지 않는 pointer-free scalar DTO다. canonical encoding version은 1이고
모든 정수는 little-endian이다. enum은 아래 닫힌 raw 값만 허용하며 reserved/tail bytes는 0이어야 한다.

| field | type | 계약 |
| --- | --- | --- |
| `version` | `u16` | exact 1 |
| `record_kind` | `u8` | `incident=1`; aggregate record에는 쓰지 않음 |
| `flags` | `u8` | bit0 expected, bit1 transport_usable, bit2 host_identity_present, 나머지 0 |
| `incident_id` | `{app_instance_nonce:u128,sequence:u64}` | 둘 다 nonzero, sequence checked-monotonic |
| `timestamp_ns` | `i128` | continuous monotonic clock의 nonnegative 값 |
| `host_id` | `u128` | identity-present면 nonzero, 아니면 0 |
| `host_adapter_generation` | `u64` | identity-present면 `HostPool.adapterGeneration(host_id)`의 nonzero 값, 아니면 0 |
| `connection_generation` | `u64` | identity-present면 nonzero, 아니면 0 |
| `wire_major` | `u16` | identity-present면 handshake가 확정한 nonzero major, 아니면 0 |
| `reason_raw` | `u8` | `client_poison.ConnectionReason` exact raw |
| `scope_raw` | `u8` | `client_poison.Scope` exact raw; CR0b incident는 connection만 허용 |
| `disposition_raw` | `u8` | `client_poison.Disposition` exact raw |
| `source_site_raw` | `u8` | 아래 `SourceSite` exact raw |
| `host_class_raw` | `u8` | `current=1,previous=2,external=3` |
| `parser_phase_raw` | `u8` | `idle=1,header=2,payload=3,terminal=4` |
| `outbound_phase_raw` | `u8` | `idle=1,queued=2,partial=3,terminal=4` |
| `reserved0` | `u8` | 0 |
| `last_success_request_id` | `u64` | 없으면 0 |
| `pending_request_count` | `u32` | bounded canonical count |
| `pending_stream_count` | `u32` | bounded canonical count |
| `pending_event_count` | `u32` | bounded canonical count |
| `queue_item_count` | `u32` | 위 queue 외 connection-owned item 합계 |
| `queue_bytes` | `u64` | checked resident byte 합계 |
| `outbound_offset` | `u64` | idle이면 0, 그 외 `<= outbound_length` |
| `outbound_length` | `u64` | idle이면 0 |
| `controller_generation` | `u64` | 관측되지 않았으면 0 |
| `upgrade_epoch` | `u64` | 관측되지 않았으면 0 |
| `occurrence_count` | `u64` | 최초 incident는 exact 1 |
| `first_timestamp_ns` | `i128` | 최초에는 `timestamp_ns`와 exact 동일 |
| `last_timestamp_ns` | `i128` | 최초에는 `timestamp_ns`와 exact 동일 |
| `reserved_tail` | `[18]u8` | 전부 0; 위 필드의 canonical encoding 합계는 exact 208 bytes |

`SourceSite`는 제품 poison owner family를 닫힌 값으로만 표현한다:
`client_read=1,client_write=2,client_response=3,client_event=4,client_queue=5,client_cleanup=6,
client_slot_operation=7,generation_transport=8,generation_attachment=9,remote_runtime_decode=10,
remote_runtime_pump=11,remote_backend=12,external_attach=13,external_pump=14,app_quit=15,integrity=16`.
새 poison 제품 caller는 이 enum과 source-boundary inventory를 함께 갱신하지 않으면 빌드되지 않는다. 파일/함수명 문자열이나 line
number는 artifact authority가 아니다.

process-global final-address `ConnectionIncidentService`가 `{self_addr,pid,process_nonce,app_instance_nonce,
last_issued_sequence,ring,pending_slots,writer_lifecycle,lifecycle}`를 소유한다. `process_nonce`와 `app_instance_nonce`는 daemon child가
ClientSlot process runtime과 독립된 OS entropy로 각각 한 번 발급하며 0을 거부한다. fork 뒤 daemon bootstrap이 부모의 ClientSlot seal을
재사용하거나 재초기화해서는 안 된다. service는 daemon bootstrap에서 ring과 함께 준비된 뒤 ready로 게시된다. fork child, copied/moved
service, PID/process nonce 불일치는 mutex 접근 전 typed reject한다. 중립 service counter owner는
`last_issued_sequence == maxInt(u64)`에서의 다음 발급을 mutation 0 `CounterExhausted`로 반환하고, 유일한 platform runtime adapter가 이를
`fatalIntegrity(.counter_exhausted)`로 닫는다. 초기값 0에서 첫 발급은 1이고 max sequence로 발급한 incident 자체는 유효하다.

CR0b가 artifact를 의무화하는 범위는 hello를 마치고 session-host의 `HostAdapter` 또는 app-global remote backend에 등록된
**managed Client**다. connect/hello 실패처럼 등록 전 Client가 없는 경로는 기존 typed error이며 reconnect admission 대상도 아니다.
등록 owner는 Client를 외부에 publish하기 전에 final-address Client 안에 pointer-free
`IncidentBinding {host_id,host_adapter_generation,connection_generation,wire_major,host_class_raw}`와 binding seal을 exact once
게시한다. 실제 소유권 순서는 `Client -> ClientSlot -> HostAdapter -> HostPool`이며 `HostPool`은 Client를 직접 import하거나
역참조하지 않는다. `HostPool.prepareOwnedPublication(host_id,adapter_addr,out)`가 map capacity, key 부재, 다음
`adapter_generation`을 mutation 없이 준비해 final-address process-sealed `PreparedHostPublication`에 봉인한다. 이 permit은
`{self_addr,pid,process_nonce,pool_addr,host_id,adapter_addr,adapter_generation,owned,lifecycle,seal}`을 exact 보존한다.
`HostAdapter.initManagedInPlace(out,node_allocator,source,permit)`이 permit의 exact adapter 주소와 host identity를 검증한 뒤
`ClientSlot.initManagedInPlace`에 binding projection을 넘긴다. ClientSlot은 source를 heap-pinned `ClientNode.client`로 옮긴
no-fail suffix 안에서 그 최종 Client 주소를 binding seal에 결속하고, `HostAdapter`는 pointer-free
`IncidentBindingPublication {client_addr,binding_seal}`만 permit에 연결한다. 마지막으로
`HostPool.commitOwnedPublication(permit,adapter)`이 permit·adapter identity·binding publication을 다시 검증한 뒤 allocation/callback
없는 suffix에서 map row와 `adapter_generation`을 게시한다. capacity 확보를 포함한 모든 fallible 작업은 prepare 앞쪽에서 끝나며,
prepare/adapter init 실패는 Client/binding/map mutation 0이다. Client binding 게시 뒤 map publication proof loss는 rollback,
adapter/client destroy, unbound fallback 없이 `fatalIntegrity(.incident_authority)`로 닫는다. `HostPool.addOwned`의 제품 caller는 0이고
test-only identity-absent fixture만 별도 helper를 쓴다. Client를 값으로 move한 뒤 binding을 복사하거나 pool publication 뒤 binding을
늦게 채우는 경로는 금지한다. standalone fixture나 등록 전 Client는 identity-absent binding만 가질 수 있고 artifact-required reconnect
경로에 들어갈 수 없다.
poison caller는 failure-site가 소유한 closed request만 canonical public facade에 전달하고, final owner가 완성한 pointer-free
`IncidentInput`만 private poison suffix에 전달한다. 기존 reason-only poison wrapper는 identity-absent·reconnect-ineligible 경로에만 남기고, managed Client 제품 caller는
source-boundary가 reason-only wrapper를 호출하지 못하게 한다.

managed public poison caller가 제출하는 값은 closed `ConnectionReason`, exact `SourceSite`, source-specific
`controller_generation`뿐이다. timestamp는 app-process incident owner가 `CLOCK_MONOTONIC`에서 exact 한 번 읽고, 나머지는
ClientSlot registered-operation pin 아래 Client가 투영한다. host/binding/wire/class와 upgrade epoch는 final Client binding/state,
parser phase는 unread parser bytes(`idle`, partial header, decoded-header 뒤 partial/complete payload, terminal Client), outbound phase와
offset/length는 single pending outbound owner, `last_success_request_id`는 correlated response를 실제 반환하기 직전에만 증가하는
Client scalar가 단일 출처다. pending request는 prepared execution 또는 pending outbound의 closed 0/1, stream/event count는 각
Client-owned queue 길이, queue item/bytes는 pending stream/event/batch/partial/outbound owner의 checked 합이다. caller가 완성된
`IncidentInput`, timestamp, disposition, binding identity나 queue counter를 제출하는 제품 경로는 0이다. count/byte cast·합 또는 clock이
실패하면 handoff, Client reason/fd, ring, admission을 모두 바꾸지 않는 typed prepare 실패다.

managed poison은 기존 Client mutation/registered operation 안에서 coordinator를 재진입하지 않는다. 실패를 발견한 exact owner는
operation pin 아래 `PreparedManagedPoison`만 준비한다. 이 값은 final-address prepared storage, PID/process nonce/thread,
slot/node generation, binding seal, 전체 `IncidentInput`과 `prepared` lifecycle을 process seal로 결속하는 pointer-free one-shot
handoff다. 이 단계는 first reason·fd·pending outbound·ring·scheduler를 바꾸지 않는다. 기존 operation이 반환된 뒤 app-process
incident owner의 단일 facade가 handoff와 final `HostAdapter`를 다시 검증하고 ClientSlot operation을 새로 획득한다. 이 facade
내부에서만 app-global publisher를 ephemeral borrow하고 coordinator를 호출한다. 제품 caller가 raw `Registry`·
`ConnectionIncidentRuntime`·`IncidentOperationQuery`를 서로 조합하거나 adapter/Client에 publisher pointer를 저장하는 경로는 0이다.

failure-site caller 2~6이 GUI `AppSession` 모듈을 역수입하거나 `GenerationAttachment`/`RemoteRuntime`에 publisher pointer를
보관하지 않도록, app-process owner 모듈은 bootstrap이 완전히 성공한 뒤 final-address owner 주소를 PID/process nonce/thread와
함께 process-sealed 단일 publication port에 게시한다. port는 owner shutdown admission 전에 revoke하며, 다른 주소·PID·thread,
pristine/closing owner, replay된 handoff를 graph 역참조 전에 거부한다. failure-site는 port나 owner 주소를 보지 않고 operation 반환 뒤
`publishPreparedManagedPoison(adapter, handoff)`만 호출한다. 이 module-level facade만 sealed owner 주소를 해석하고 instance facade에
위임하며, product source의 port install/revoke caller는 각각 app bootstrap/termination exact 1이다.

caller 2의 prepared execution 경로는 request write/response classification을 소유한 registered operation이 시작되기 전에 owner port에서
timestamp receipt를 한 번 받고, 실패가 확정되면 operation pin 아래 final-address `PreparedManagedPoison`을 완성한다. Client의
prepared-execution poison capture는 해당 operation과 handoff 주소에 결속된 stack-local one-shot이며 reason만 기록한다. capture가
armed인 동안 `poisonWhilePreparedExecutionHeld`는 first reason, unusable, fd, pending outbound를 바꾸지 않는다. cleanup registry와
prepared request authority가 terminal settlement를 끝내고 registered operation이 release된 뒤에만 port facade가 canonical publication,
Client terminalization, fd close, reconnect admission을 수행한다. capture 미설치인 identity-absent/test-only execution은 기존 reason-only
동작을 유지하되 managed product caller에서는 0으로 고정한다.

caller 4의 allocator callback은 caller 2와 같은 prepared execution transaction 안에서만 deferred poison capture를 공유한다. checked
allocator callback의 thread-local owner가 exact Client이고 active execution lease와 caller-final capture의 주소·operation·timestamp·
controller generation이 모두 일치할 때, `Client.poison`은 public mutation fence를 재진입하지 않고 reason과 allocator 전용
`SourceSite.client_cleanup`만 stack capture에 한 번 기록한다. callback 안에서는 first reason, unusable, fd, pending outbound, ring,
reconnect admission을 바꾸지 않는다. 이후 같은 failure가 일반 response error 경로에서도 관측되면 최초 allocator source를 보존하고,
서로 다른 reason은 proof loss로 fail-stop한다. allocator callback이 반환하고 caller 2의 cleanup/operation unwind가 끝난 뒤에만 기존
publication port가 `PreparedManagedPoison`을 canonical suffix에 제출한다. callback이 publisher·registry·runtime pointer를 보관하거나
operation 안에서 coordinator를 재진입하는 경로는 0이다.

caller 5의 read-event pump는 `RemoteRuntime.pumpDelta` 전체를 actual product ingress로 사용하며, screen batch는
`RemoteAttachment.pumpScreen -> GenerationBatchAdapter.readBatch -> ClientSlot.readAttachmentBatch -> Client.readGenerationBatch`
하위 경로를 지난다. runtime은 첫 event/screen read 전에 owner clock receipt를 한 번 받고, final-address batch adapter가
caller-final read capture를 exact adapter·slot·Client·thread와 `SourceSite.client_read`에 임시 결속한다. Client가 public mutation fence 아래 EOF, read failure,
partial frame 또는 parser resource failure를 확정하면 `Client.poison`은 first reason·unusable·fd·ring·pending·admission을 바꾸지 않고
closed reason과 별도 presence bit만 capture한다(`connection_eof`의 raw 0은 absence로 해석하지 않는다). event drain, batch ingress
reservation, guarded allocator scope, RemoteAttachment read callback이 모두 unwind되고 capture
binding이 해제된 뒤에만 RemoteRuntime이 final HostAdapter로 canonical `PreparedManagedPoison`을 만들고 publication port에 제출한다.
read callback이나 batch adapter가 publisher·registry·incident runtime pointer를 저장하거나 error tag에서 reason을 다시 추론하는 경로는
0이다. capture가 없거나 서로 다른 Client/adapter/source로 drift하면 graph mutation 전 typed reject 또는 incident-authority fail-stop이다.

caller 6의 outbound RPC ambiguity는 actual generation `RemoteRuntime.resize`에서 이미 일부 전송된 pending outbound를 먼저
flush하는 제품 경로를 사용한다. nonblocking socket의 partial write 뒤 `EAGAIN`은 execution lease에
`outbound_write_ambiguous`를 capture하고, caller는 allocator/operation guard가 살아 있는 동안 Client-owned pending frame의 exact
offset/length, 남은 queue bytes, pending request 1을 `SourceSite.client_response` handoff에 봉인한다. prepared request backing을
terminal settlement하되 Client first reason·fd·pending outbound는 건드리지 않고 publication scope와 execution lease, registered
operation을 모두 release한 뒤에만 기존 publication port가 canonical first suffix를 호출한다. coordinator가 ring evidence와
id/key/reason을 게시한 다음 terminalization이 pending outbound를 회수하고 fd를 exact once 닫으며 reconnect admission을 한 번
게시한다. caller가 write error tag로 reason을 다시 추론하거나 부분 전송 상태를 settlement 뒤 읽거나 operation 안에서
coordinator를 재진입하는 경로는 0이다.

coordinator는 held Client contextual state로 first/repeat를 선택한다. caller가 kind boolean을 제출하지 않는다. pristine
first fields만 `.first`, exact sealed repeat key와 같은 fingerprint만 `.repeat`이며, 다른 fingerprint는 mutation 0 typed reject다.
publication이 끝나면 같은 registered owner가 handoff에 봉인된 terminalization disposition을 no-reread continuation으로 적용한다.
fd/pending outbound를 먼저 닫거나 기존 reason-only poison을 호출한 뒤 publication을 시도하는 순서는 금지한다. precommit typed
실패는 terminalization/reconnect admission을 수행하지 않고 prepared handoff를 canonical owner에게 남기며, ring evidence 이후
proof loss만 common fatal로 수렴한다.

최초 incident 선형화는 `Client`의 canonical first-reason publication과 분리하지 않는다. public poison, registered-operation
deferred poison, allocator-callback deferred poison은 모두 같은 private suffix에서 ring evidence와
`Client.first_incident_id`를 먼저 게시하고, 마지막 store로 `first_poison_reason:null -> reason`을 게시한다. raw 두 저장소를
lock-free로 함께 읽는 API는 두지 않는다. reconnect scheduler와 inspector는 Client operation fence와 service mutex를 순서대로 잡는
contextual snapshot만 소비하며, crash가 마지막 store 전에 발생해도 orphan ring evidence는 허용하지만 reason만 있고 evidence가 없는
상태는 허용하지 않는다. suffix 진입 전에
`IncidentInput`과 binding을 모두 검증하며 실패는 Client/ring/reconnect mutation 0이다. suffix는 allocation/callback/syscall 0인
no-fail 구간이고, publication 중 proof loss는 재시도나 reason-only fallback 없이 `fatalIntegrity(.incident_authority)`로 닫는다.
이미 first reason이 있으면 새 incident ID를 만들지 않고 `first_incident_id`와 같은 fingerprint aggregate occurrence만
saturating 증가한다. service는 제출 뒤 Client/queue/parser pointer를 역참조하지 않고, caller는 raw payload가 아니라 위 scalar
projection을 operation/fence 아래에서 먼저 완성한다. ring publication과 first reason이 함께 보이는 마지막 store가 reconnect
scheduler admission보다 앞선 선형화점이다.

repeat publication은 raw incident ID만 받지 않는다. 최초 suffix가 Client final address, `first_incident_id`, fingerprint,
binding seal을 결속한 process-sealed `IncidentRepeatKey`를 Client inline storage에 게시하고, 같은 operation owner가 이 key와 현재
projection을 함께 제출할 때만 aggregate를 갱신한다. 상세 record가 120개 cap 뒤 drop됐더라도 key가 fingerprint authority다.
CR0b 중립 leaf의 unsealed repeat helper는 test-private이며 product caller는 0이다.

emergency ring은 exact 32 KiB이며 `IncidentRecord[120] + AggregateRecord[8]`로 구성된다. 두 record의 canonical storage envelope는
각각 exact 256 bytes이고 header `{version:u16,kind:u8,committed:u8,payload_len:u16,reserved:u16,generation:u64}` 16 bytes,
payload exact 208 bytes, BLAKE3 digest 32 bytes로 고정한다. incident payload는 위 208-byte DTO 자체다.
aggregate payload도 exact 208 bytes이며
`{version:u16=1,kind:u8=2,flags:u8(bit0 other, bit1 detail_dropped),reason_raw:u8,scope_raw:u8,
source_site_raw:u8,host_class_raw:u8,count:u64,detail_dropped_count:u64,first_timestamp_ns:i128,
last_timestamp_ns:i128,reserved:[152]u8=0}` 순서로 encode한다. producer는 process-global mutex 아래 pristine incident slot의
가장 낮은 index에 최초 120개 Client incident를 immutable publish하고, 모든 최초/repeat publication에서 fingerprint aggregate도
갱신한다. 상세 slot이 찬 뒤의 새 최초 incident는 새 nonzero ID를 Client에 남기되 상세 DTO 대신 해당 aggregate의
`detail_dropped_count`를 증가시킨다. 따라서 `first_incident_id`는 correlation identity이지 반드시 ring-resident 상세 slot을
뜻하지 않으며, contextual snapshot이 `detail_present`를 함께 반환한다. 이 bounded degradation도 artifact-before-recovery evidence다.
named aggregate fingerprint가 없으면 slot 0..6의 pristine 최저 index를 쓴다. aggregate slot 7은 처음부터 고정 `other`라 named
slot 일곱 개가 찬 뒤의 미등록 fingerprint만 saturating 합산한다. 기존 incident record와 named aggregate bucket을
evict·전환·재배치하지 않는다.
incident record generation은 `slot_index+1`로 불변이다. aggregate generation은 갱신마다 checked 증가하며 max 다음 갱신은
ring/Client/reconnect mutation 0 뒤 fail-stop한다. 한 poison이 incident와 aggregate를 함께 갱신할 때는 pristine 상세 slot,
aggregate slot/generation, sequence, Client destination을 전부 preflight한 뒤에만 mutation을 시작한다. producer는 mutex 아래
`committed=0`을 먼저 게시하고 payload+digest+generation을
쓴 뒤 마지막 store로 `committed=1`을 게시한다. writer도 같은 mutex 아래 committed record 전체를 value-copy하므로 갱신 중 payload를
볼 수 없다. producer 경로에는 allocation, callback, filesystem syscall이 없다.

process bootstrap은 heap에 final-address `ConnectionIncidentRuntime` 하나를 먼저 고정하고 그 안에 service, secure store,
nonblocking CLOEXEC wake pipe, completion pipe와 exact 한 개 writer thread를 둔다. service 단독 중립 테스트는 wake를 소유하지 않고,
제품 publication facade가 record의 마지막 store 뒤 해당 slot bit를 idempotent set한 다음 wake pipe에 한 바이트를 쓴다. pipe가 가득 찬
`EAGAIN`은 이미 wake가 보류 중이라는 뜻이므로 성공으로 취급하고, 그 밖의 write 실패는 ring evidence를 되돌리지 않은 채 writer 상태만
failed로 게시한다. queue node나 receipt를 동적으로 만들지 않으며 같은
aggregate의 여러 갱신은 한 bit로 coalesce된다. writer는 mutex 아래
`IncidentWriterHandoff`와 exact record를 value-copy하고 bit를 clear한 뒤
lock을 놓고 disk I/O를 수행한다. completion 때 record generation이 복사본보다 새로우면 bit를 다시 set하고, 같으면 disk 상태만
게시한다. reconnect/quit은 writer를 기다리지 않는다. late completion은 ring storage를 free하거나 incident/aggregate를 변경하지
않는다. writer는 별도 작업 ID를 발급하지 않고 record generation만 stale completion 판정에 사용한다.

정상 종료 owner는 `stopping`을 release-store하고 wake한 뒤 completion pipe를 process-monotonic 200 ms deadline까지 poll한다. deadline
전에 writer가 store/service 접근을 끝내고 completion byte를 게시하면 exact thread를 join하고 backing을 free한다. regular-file
`write/fsync`는 취소 가능한 syscall이 아니므로 deadline을 넘기면 join하지 않고 thread를 detach하며, runtime backing과 그 FD를 process
종료까지 의도적으로 남긴다. 이 bounded leak은 최대 service+32 KiB ring, 제어 pipe FD 네 개와 저장소 directory FD 한 개이며 reconnect나 일반 quit 경로에는 생기지
않는다. detached writer가 늦게 반환해도 backing은 살아 있고 Client/HostAdapter나 해제된 allocator를 호출하지 않는다. stack-local
runtime detach, timeout 뒤 backing/dir FD 해제, 무기한 join은 금지한다. producer lock→writer lock 외의 역방향 lock 획득은 0이고
writer는 Client/HostAdapter를 호출하지 않는다. fork child는 inherited runtime의 pipe·mutex·service를 만지기 전에 PID domain mismatch로
거부한다.

GUI와 daemon은 서로 다른 프로세스이므로 incident runtime도 process별 exact 하나를 소유한다. daemon bootstrap은 기존 host-owned
runtime을 설치하고, GUI는 첫 managed remote adapter publication보다 먼저 module-static final-address `AppProcessIncidentOwner`를
app-global coordinator에 게시한다. 이 owner가 heap-pinned runtime과 inline registry를 소유한다. GUI owner의 directory는
`${XDG_CACHE_HOME:-$HOME/.cache}/maru/incidents`이고 window/AppSession allocator가
아니라 app-global allocator를 쓴다. restore-first와 current-first는 같은 owner를 재사용하고 두 번째 owner 설치, 다른 final address
교체, fork child 재사용을 mutation 0으로 거부한다. daemon과 GUI가 같은 incident sequence나 nonce를 공유한다고 가정하지 않는다.

개별 Window/AppSession deinit과 remote backend init rollback은 process owner를 해제하지 않는다. Swift
`applicationWillTerminate`가 호출하는 exact 한 AppHost ABI가 app-global owner를 `ready -> closing`으로 revoke하고 active publisher
lease가 0이 될 때까지 200 ms absolute deadline으로 drain한 뒤 writer shutdown을 수행한다. ordinary window close의 이 ABI caller는
0이고, owner가 아직 없던 앱 종료는 inactive success다. 반환은 closed `IncidentShutdownOutcome {inactive,joined,detached,degraded}`다.
publisher lease가 deadline에 남으면 runtime/service/wake FD/registry backing 전체를 process-lifetime detached 상태로 보존하고
`.detached`를 반환하며 shutdown/free를 호출하지 않는다. lease 0 뒤 runtime shutdown의 clock/wake/pipe 오류도 sticky failure를 거쳐
`.degraded`로 수렴하고 AppKit termination을 막거나 재시도하지 않는다. writer completion을 확인한 `degraded_joined`는 backing과 빈
pathname을 회수하고, deadline·clock·poll 오류의 `degraded_detached`만 runtime/service/FD와 pathname을 process lifetime까지 보존한다. 제품 종료 hook과 daemon teardown 외
`ConnectionIncidentRuntime.shutdown` caller는 0이다.
AppHost의 exact 순서는 `control stop -> workspace save -> 모든 AppSession shutdown -> app-global remote backend/pool/client settlement ABI
-> incident owner termination ABI -> native termination return`이다. backend settlement ABI는 모든 Window가 자기 runtime을
remove/detach한 뒤에만 backend를 먼저 deinit하고 그 다음 pool 또는 legacy client를 exact once 해제한다. 전역 backend/pool/client 중
하나라도 남아 있으면 incident termination leaf 자체가 latch를 소비하지 않고 inactive로 거부하므로 Swift의 source 순서만을 신뢰하지
않는다. AppSession/backend teardown 중 발생한 managed poison은 아직 ready owner에
게시할 수 있고, incident ABI 뒤 AppSession shutdown caller는 0이다. Swift source-boundary가 incident ABI의
`shutdownAppSession` 이전 caller 0, 이후 exact 1을 고정한다.

`Client`와 `IncidentBinding`에는 runtime/service 포인터를 저장하지 않는다. process registry의 canonical entry는
`IncidentPublisherAuthority {self_addr,registry_addr,registry_generation,runtime_addr,runtime_generation,service_addr,
service_generation,pid,client_process_nonce,service_process_nonce,owner_thread,app_instance_nonce,lifecycle,seal}`과 active lease count를
소유한다. 모든 entry는 process-sealed final-address storage이며 PID를 secret·mutex·pointer 역참조보다 먼저 검증한다. registry는
단일 process-global mutex로 lifecycle과 active count를 선형화한다. acquire는 PID를 먼저 검사하고 mutex 아래 authority를 다시
검증해 `ready`일 때 count를 checked 증가한 뒤 mutex를 즉시 놓는다. release는 service mutex를 놓고 wake를 끝낸 뒤 registry mutex
아래 exact lease seal/generation을 검증해 count를 감소한다. teardown은 registry mutex 아래 `ready -> closing`을 게시한 뒤 mutex를
놓고 deadline까지 count를 재조회하며, mutex를 잡은 채 기다리지 않는다. 정확한 순서는 `Client fence -> registry mutex(acquire 후
unlock) -> service mutex`; writer는 service mutex만, lease release와 teardown은 service mutex를 잡지 않는다. closing publication 뒤
새 acquire는 mutation 0 typed reject이고 teardown은 active count 0 전 runtime/service를 해제하지 않는다.
copied/moved owner·lease, same-address generation ABA, service/runtime address splice, lifecycle replay, fork child의 pre-admission
사용은 mutation 0 typed reject로 닫는다. process-sealed authority를 검증한 뒤의 proof drift와 issuer exhaustion만 common fatal
leaf로 fail-stop한다. 제품 poison suffix가 raw global pointer를 직접 읽거나 `ConnectionIncidentRuntime`을 import하는 caller는 0이고, platform
runtime adapter만 ClientSlot의 pointer-free 등록 facade를 호출한다.

publication은 generic callback 대신 final-address `PreparedIncidentPublication`을 사용한다. closed kind는 `first|repeat`다. prepare는
fallible clock/input/binding 검증과 sequence/detail/aggregate preflight를 마치고 service mutex를 계속 소유한 채
`{self_addr,kind,mutex_owner_thread,service_lock_generation,lease seal,service generation,client_addr,slot_addr,node_addr,
slot_generation,node_generation,connection_generation,operation_id,operation_receipt_seal,binding_seal,input_digest,
first_id_destination,key_destination,reason_destination,incident id,existing repeat-key seal,fingerprint,detail slot,
aggregate slot/generation,lifecycle,seal}`을 봉인한다. 모든 destination extent는 service/runtime/permit/서로 간 exact·partial overlap과
checked-add overflow를 prepare 전에 거부한다. commit 직전 held Client operation 아래 주소·generation·receipt·binding·input digest를
전부 다시 검증한다. prepare 뒤에는 allocation/callback/syscall/error return 0이다. copied/moved/foreign-thread token, lock generation
drift, destination/operation drift는 common `fatalIntegrity(.incident_authority)`로 즉시 종료하며 unlock·lease release를 시도하지 않는다.

runtime과 service generation은 임의의 registry 입력이 아니다. `incident_runtime`의 process-global checked issuer가 heap runtime 생성 전에
서로 다른 nonzero generation을 발급하고 final-address `ConnectionIncidentRuntime`과 inline `ConnectionIncidentService`에 각각 저장한다.
runtime의 `publisherProjection()`만 `{runtime addr+generation, service addr+generation, service process nonce, app instance nonce}`를 만들며
registry install은 이 projection만 소비한다. issuer exhaustion은 owner publication 전에 common counter-exhausted fatal로 닫는다. coordinator는
raw lease 주소를 역참조하지 않는다. registry의 `projectValidatedLease()`가 mutex 아래 live row·lease seal·authority를 대조해 pointer-free
`PublisherLeaseProjection`을 만들고, runtime의 좁은 publication facade가 그 projection을 현재 final-address runtime/service generation과 다시
대조한 뒤에만 service transaction과 committed wake를 수행한다.

`PreparedIncidentPublication.seal`은 장식 필드가 아니다. 별도 `maru.prepared-incident-publication.v1` process-seal domain은 composite final
address, kind/lifecycle, lease final address·generation·seal, runtime/service generation, embedded service/client token의 final address·seal·lifecycle,
canonical input digest를 봉인한다. 현재 first composite prerequisite의 public `publishFirst`는 destination을 caller에게 받지 않고 자기 stack의
`PreparedFirstOwner` 안에서 composite와 lease를 함께 소유하므로 외부 destination alias surface가 없다. 각 embedded Client/service leaf의 owner-storage
exact·partial overlap 검사는 그대로 선행한다. 후속 first/repeat prepared API가 caller destination을 열 때에는 전체 composite와 실제 lease,
runtime/service/registry/authority, Client slot/node/client/binding/repeat-key/operation registry의 모든 extent 및 embedded token 상호 간 exact·partial
overlap을 checked-add로 거부하는 RED를 먼저 추가한다.

first의 현재 composite prerequisite에서 fallible acquisition 순서는 `canonical input/clock -> Client operation -> publisher lease -> runtime projection 재검증 ->
service prepare(lock held) -> Client bind -> composite seal`이다. service prepare 전 실패는 `publisher lease release -> Client operation finish`,
service prepare 뒤 Client bind 실패는 반드시 `service abort/unlock -> publisher lease release -> Client operation finish` 순서로 exact once
회수한다. 각 단계의 typed failure는 ring·pending·Client first fields를 바꾸지 않는다. service의 checked stage validation은 mutation 전 closed
proof를 반환하고 platform coordinator가 false를 common `fatalIntegrity(.incident_authority)`로 변환한다. neutral service가 `@panic`을
보안 provenance로 소유하거나 unchecked commit API를 외부에 공개하지 않는다.

`.first` commit은 먼저 committed ring evidence를 쓰고 `Client.first_incident_id -> IncidentRepeatKey -> first_poison_reason`을
no-fail로 게시한 뒤 service pending bit을 게시하고 mutex를 해제한다. 현재 composite prerequisite의 `.repeat` prepare는 Client의 sealed repeat key와 first ID,
binding, 새 projection fingerprint를 결속하고 canonical key fingerprint와 exact equality를 요구해 aggregate generation만 예약한다.
다른 fingerprint는 Client/ring/sequence/aggregate mutation 0 typed reject다. repeat commit은 detail/sequence/Client first fields를
바꾸지 않고 같은 fingerprint aggregate occurrence와 last timestamp, pending bit만 게시한 뒤 mutex를 해제한다. first/repeat 모두 abort는 ring/Client
publication 전 prepared transaction만 mutex 아래 exact once 허용하며, ring commit 이후 abort/rollback은 없다. writer는 pending bit이
보인 record만 취하므로 Client reason보다 앞서 disk handoff가 시작되지 않는다.

`.repeat`도 first와 같은 private final-address composite를 사용한다. service는 mutex를 계속 소유하는 `prepareRepeatPublication`과 checked
`commitPreparedRepeatEvidenceChecked`를 제공하고, Client facade는 held operation 아래 기존 sealed repeat key·first ID·binding·canonical fingerprint를
검증해 repeat arm을 bind한다. repeat에는 새 incident sequence/detail/Client first-field publication이 없으며 다른 fingerprint는 service
aggregate reservation 전에 typed mutation-0 reject다. 이 prerequisite는 제품 transaction primitive만 닫으며 실제 managed poison ingress 여섯 family 연결은
아래 여섯 번째 gate의 남은 범위다.

wake는 mutex 해제 뒤 publisher lease를 가진 platform facade가 수행한다. 반환은 error union이 아니라
`IncidentCommitResult {publication:PublishResult,wake:queued|coalesced|degraded}`이고, pipe write 실패는 sticky writer failure와
`degraded`를 게시한 committed success다. caller는 같은 poison을 재시도하지 않으며 ring/Client publication을 되돌리지 않는다.
lease release는 wake outcome과 무관하게 exact once 수행한다.
runtime의 wake-only facade는 validated live lease projection과 pending 게시 뒤 다시 봉인한 `wake_ready` composite를 함께 요구한다. pipe write 1 byte는 `queued`,
`EAGAIN`은 `coalesced`, 그 밖의 write 실패는 sticky writer failure를 세운 `degraded`다. raw wake FD와 service 포인터는 coordinator에
노출하지 않으며 legacy `runtime.publish`는 composite 제품 caller가 될 수 없다.

여섯 번째 CR0b gate는 위 제품 순서를 exact named TDD inventory로 고정한다. reason-only wrapper는 identity-absent fixture와 등록 전
typed failure에만 남고 managed Client 제품 caller는 0이다. Debug unexpected poison은 canonical publication 뒤 common fatal leaf로
종료하고 ReleaseFast는 같은 publication 뒤 scheduler continuation을 증명한다. Debug fatal의 exact 순서는
`commit(pending bit+mutex unlock) -> wake outcome publication -> publisher lease release -> fatalIntegrity`다. subprocess는 ring-resident
evidence와 Client contextual snapshot을 검증하되 writer disk completion은 기다리거나 성공 조건으로 삼지 않는다.

timestamp와 `IncidentInput`은 service mutex 진입 전에 operation owner가 process-monotonic clock에서 만들며 clock failure나 음수 값은
mutation 0 typed reject다. aggregate의 first/last는 각각 `min`/`max`로 갱신해 caller 간 관측 순서가 바뀌어도 역전되지 않는다.
Debug/test의 unexpected poison은 위 exact `commit -> wake outcome -> publisher lease release`가 모두 끝난 뒤에만 common
`fatalIntegrity(.unexpected_connection_poison)` leaf로 종료한다. expected poison과 Release 제품은 같은 publication 뒤 scheduler로
진행하며 artifact writer 성공을 기다리지 않는다.

Release는 preallocated 32 KiB ring handoff를 reconnect scheduling보다 먼저 끝낸다. disk writer는 별도 bounded owner이며
filesystem syscall 정지를 reconnect/main/quit 경로가 기다리지 않는다. `${XDG_CACHE_HOME:-$HOME/.cache}/maru/incidents`
디렉터리는 `0700`,
새 파일은 `0600` regular file로
exclusive create하고 symlink를 따르지 않으며 현재 uid 소유를 확인한다. 파일당·총량·보존 기간은 각각 64 KiB, 1 MiB,
7일이고 최대 128개에서 oldest-first로 지운다. 현재 version 1은 파일마다 exact 256-byte envelope 하나만 쓰지만 64 KiB는
향후 compatible tail을 포함한 hard cap이며 1 MiB는 파일 수와 독립적으로 유지하는 방어 한도다. 동일 filename의 existing regular
file은 current uid·0600·exact 256-byte content가 handoff와 byte-equal할 때만 idempotent success이고, symlink/non-regular/wrong-owner/
wrong-mode/content drift는 덮어쓰거나 unlink하지 않고 실패한다. eviction 순서는 현재 app nonce와 strict filename의
detail sequence 또는 aggregate generation/digest, 첫 256-byte envelope header와 BLAKE3 digest까지 일치한 regular file만 대상으로 삼고
`(mtime_ns, filename bytes)` 오름차순이며 7일 초과를 먼저, 그 다음 128개와 1 MiB를 만족할 때까지 지운다. scan 중 검증되지 않은
entry와 이 version의 strict filename을 벗어난 entry는 용량 계산·삭제 대상에서 제외한다. disk가 실패하면 process 시작 때 할당한 32 KiB fixed-record emergency ring에
writer는 이미 handoff된 ring record를 disk로 persist하며 실패하면 같은 record를 ring-resident로 유지한다. 재삽입이나
aggregate count 증가는 0이다. disk에 저장된 record는 ring eviction 대상이 아니다. ring은 first-N distinct immutable
slot과 fixed overflow bucket을 분리하고 `{reason,scope,source_site,host_class}` bounded enum fingerprint의 count/first/last만
saturating aggregate한다. incident ID와 raw host ID는 aggregate key가 아니다. Debug/test의
unexpected poison은 같은 기록 뒤 fail-stop한다. 이 artifact는 화면 replay 입력이 아니므로 `maru.trace.v1`에 억지로 섞지 않는다.

writer가 소비하는 중립 handoff는 pointer-free `IncidentWriterHandoff` 하나뿐이다. 이 값은 exact 256-byte envelope와
`{pid,process_nonce,service_addr,app_instance_nonce,slot_index,record_generation,incident_sequence,digest,receipt_digest}` receipt를 함께 보존한다.
detail slot만 `incident_sequence`가 nonzero이고 aggregate slot은 0이다. `takePendingForWriter`는
service 권위를 mutex 전·후에 검증하고 가장 낮은 pending bit의 committed envelope를 value-copy한 뒤 그 bit만 clear한다.
`receipt_digest`는 receipt의 앞선 모든 필드를 canonical little-endian 값으로 결속해 파일 I/O 경계에서 slot을 포함한 복사 drift를
서비스 mutex 없이 거부한다. 이는 같은 프로세스의 악의적 코드를 막는 비밀 seal이 아니라 값 인계의 구조적 결속이다.
pristine output, pending 0, invalid/corrupt envelope는 mutation 0 typed 결과다. `completeWriterHandoff`는 receipt와 현재 slot의
generation/digest를 다시 대조한다. 현재 generation이 더 크면 disk 결과를 해당 새 record의 결과로 오인하지 않고 pending bit를
다시 set한다. exact generation이면 `persisted|failed` bounded disk 상태와 완료 generation만 게시하며 ring envelope와 aggregate
count는 바꾸지 않는다. copied service, foreign PID/process nonce, receipt slot·generation·digest drift, replay completion은
mutation 0이다. 별도 job ID, heap node, Client/HostAdapter callback은 없다. 실제 writer thread와 secure filesystem adapter는 이
두 API의 sole product caller이며, bootstrap gate 전까지 product caller는 0으로 유지한다.

경로·권한·cap·eviction·disk/ring 실패는 deterministic fake storage로 검증하고, artifact 본문에는 프로젝트 redaction 규칙을
통과한 fixed schema 외 필드가 생기지 않도록 golden schema test를 둔다. fake storage는 ordering/failure injection만
증명한다. 실제 macOS tempdir integration은 component별 no-follow/current-UID/directory 검증, `openat`-relative exclusive
regular-file create, mode 0700/0600, preexisting symlink/non-regular/collision 거부와 bounded eviction을 별도 자동 gate로
검증한다.

## 민감정보 규칙

raw output bytes에는 경로, 서버 이름, token, 환경변수 값이 섞일 수 있다. 그래서 trace는 기본적으로 로컬 산출물이다.

git에 fixture로 넣으려면 [프로젝트 규칙](project-rules.md)의 "민감정보 redaction 기준 (단일 출처)"을 따른다. 같은 키 목록과 경로 일반화·익명화 규칙을 쓰며, 여기에 목록을 복제하지 않는다. sanitize 후에도 같은 replay 결과가 나오는지 확인하는 것까지가 fixture 추가 조건이다.

코드 단일 출처는 중립 leaf `src/redact.zig`다(project-rules.md 미러 — 토큰 목록·key 판정을 env·argv·fixture가 공유). 판정 `redact.hasSensitiveContent`는 인라인 할당(`<키>=값`·`:값`, `=` 주변 공백 허용)·dash 플래그(`--api-key sk-…`)·공백분리 할당을 잡는다(substring-on-key라 `apikey`·`myapitoken`까지 — 대가로 `monkey=` 류도 걸리는 deny-by-default). **trace fixture 가드는 `observability.trace.guardFixture(allocator, text)`**: output 바이트는 PTY read 경계로 이벤트마다 쪼개지므로 직렬화 텍스트를 그대로 스캔하면 놓친다 — output을 **경계 없이 재조립·unescape**한 뒤 스캔해(split secret 재결합) `SensitiveContent`로 거부한다. plain 텍스트(snapshot)는 `redact.guardFixture(text)`. 라이브 `MARU_TRACE`는 local-only라 차단은 안 하지만, 같은 재조립 스캔으로 민감 데이터가 잡히면 파일 write 시 stderr로 한 번 알린다. 경로·서버·사용자 이름 익명화는 keyword가 아니라 **별도 후속**(project-rules.md §redaction).

## 초기 테스트

reader(구현됨, `observability/trace.zig`):
- **round-trip**: 실제 OSC 133/7을 먹인 core의 이벤트 스트림을 직렬화한 뒤 `parseEvents`로 되읽으면 원 이벤트(태그+payload)와 cwd 경로가 그대로 복원된다. base kind(output/resize/input/process-exit)도 writer↔`parseEvents` round-trip(output 바이트는 ESC·제어 섞여도 escape 왕복 무손실).
- 헤더가 틀리면 `BadHeader`, 라인이 깨지면(kind/surface 누락 등) `BadLine`. `exit=none`/실패 exit code, cwd escape(공백·따옴표·개행) 복원.

replay 재적용(구현됨, `observability/replay.zig`):
- **화면 replay**: `output`/`resize` trace를 재생하면 화면(`dumpUtf8`)이 **byte-for-byte** 재구성되고 셸 이벤트·cwd·크기까지 파서가 재도출된다.
- 같은 output trace를 두 번 replay하면 같은 snapshot이 나온다(결정성).
- **semantic replay(fallback)**: output 없는 shell-only trace는 shell.* 를 OSC로 재발행해 이벤트 스트림·행·cwd를 재구성(cwd percent-encode 왕복 포함).
- replay는 private parser storage를 import하지 않고 `core.write`/`core.resize` public 경로만 쓴다.

redaction(구현됨, `src/redact.zig` + `observability/trace.zig`):
- **trace fixture 가드**: `trace.guardFixture`가 output을 재조립해 스캔하므로, 비밀이 read 경계로 두 output 이벤트에 쪼개져도(`API_TOKEN`/`=값`) 재결합해 `SensitiveContent`로 거부한다(직렬화 텍스트 스캔은 놓침). cwd 값 내 비밀도.
- **판정 범위**: 인라인 할당(공백 허용)·dash 플래그·공백분리 할당을 잡는다. substring-on-key라 `monkey=` 류도 걸린다(deny-by-default — false negative보다 안전).
- **익명화**(`trace.anonymizeTrace` / `maru trace anonymize`): keyword 가드가 못 잡는 PII/인프라를 일반화한다 — 홈 경로 세그먼트·IPv4·`user@host.domain`·알려진 유저명(env HOME/USER)을 자리표시자로. 구조 보존이라 결과가 여전히 파싱·재생 가능하고 멱등이다. 가드(secret 차단)와 짝: 익명화는 값 일반화.
- `keyIsSensitive`가 env·fixture redaction과 같은 토큰 목록을 공유한다.
