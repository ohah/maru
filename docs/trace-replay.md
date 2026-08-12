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
filename은 두 값을 고정 길이 lowercase hex로만 인코딩한다. session client는 typed poison tuple과
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
last_issued_sequence,ring,pending_slots,writer_lifecycle,lifecycle}`를 소유한다. `app_instance_nonce`는 process seal nonce와 별도로 OS entropy에서 한 번
발급하며 0을 거부한다. service는 process runtime bootstrap에서 ring과 함께 준비된 뒤 ready로 게시된다. fork child, copied/moved
service, PID/process nonce 불일치, `last_issued_sequence == maxInt(u64)`에서의 다음 발급은 Client/ring/reconnect mutation 0 뒤
`fatalIntegrity(.incident_authority)`로 닫는다. 초기값 0에서 첫 발급은 1이고 max sequence로 발급한 incident 자체는 유효하다.

CR0b가 artifact를 의무화하는 범위는 hello를 마치고 session-host의 `HostAdapter` 또는 app-global remote backend에 등록된
**managed Client**다. connect/hello 실패처럼 등록 전 Client가 없는 경로는 기존 typed error이며 reconnect admission 대상도 아니다.
등록 owner는 Client를 외부에 publish하기 전에 final-address Client 안에 pointer-free
`IncidentBinding {host_id,host_adapter_generation,connection_generation,wire_major,host_class_raw}`와 binding seal을 exact once
게시한다. `HostPool` 등록은 map capacity와 다음 adapter generation을 mutation 없이 준비하는 `PreparedIncidentBinding`을 먼저 만들고,
최종 Client 주소의 pristine binding을 봉인한 뒤 allocation/callback 없는 suffix에서 map row를 publish한다. 준비 실패는
Client/binding/map mutation 0이고, binding 게시 뒤 map publication proof loss는 rollback이나 unbound fallback 없이 fail-stop한다.
Client를 값으로 move한 뒤 binding을 복사하거나 pool publication 뒤 binding을 늦게 채우는 경로는 금지한다. standalone fixture나 등록 전
Client는 identity-absent binding만 가질 수 있고 artifact-required reconnect 경로에 들어갈 수 없다.
poison caller는 `SourceSite`와 parser/outbound/count projection을 담은 pointer-free `IncidentInput`을 만든 뒤 canonical poison suffix에
전달한다. 기존 reason-only poison wrapper는 identity-absent·reconnect-ineligible 경로에만 남기고, managed Client 제품 caller는
source-boundary가 reason-only wrapper를 호출하지 못하게 한다.

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

service는 exact 한 개 writer thread와 128-bit `pending_slots` bitmap, wake primitive를 bootstrap 때 함께 준비한다. producer는 record의
마지막 store 뒤 해당 slot bit를 idempotent set하고 non-allocating wake만 수행한다. queue node나 receipt를 동적으로 만들지 않으며 같은
aggregate의 여러 갱신은 한 bit로 coalesce된다. writer는 mutex 아래
`{pid,process_nonce,slot_index,record_generation,digest}` receipt와 exact record를 value-copy하고 bit를 clear한 뒤
lock을 놓고 disk I/O를 수행한다. completion 때 record generation이 복사본보다 새로우면 bit를 다시 set하고, 같으면 disk 상태만
게시한다. reconnect/quit은 writer를 기다리지 않는다. late completion은 ring storage를 free하거나 incident/aggregate를 변경하지
않는다. writer는 별도 작업 ID를 발급하지 않고 record generation만 stale completion 판정에 사용한다. process teardown은 writer를
bounded deadline까지 join한 뒤 미완료 작업을 ring-only로 남기며 ring backing을 writer보다
먼저 파괴하지 않는다. producer lock→writer lock 외의 역방향 lock 획득은 0이고 writer는 Client/HostAdapter를 호출하지 않는다.

timestamp와 `IncidentInput`은 service mutex 진입 전에 operation owner가 process-monotonic clock에서 만들며 clock failure나 음수 값은
mutation 0 typed reject다. aggregate의 first/last는 각각 `min`/`max`로 갱신해 caller 간 관측 순서가 바뀌어도 역전되지 않는다.
Debug/test의 unexpected poison은 ring evidence와 first reason의 마지막 store가 끝난 직후 common
`fatalIntegrity(.unexpected_connection_poison)` leaf로만 종료한다. expected poison과 Release 제품은 같은 publication 뒤 scheduler로
진행하며 artifact writer 성공을 기다리지 않는다.

Release는 preallocated 32 KiB ring handoff를 reconnect scheduling보다 먼저 끝낸다. disk writer는 별도 bounded owner이며
filesystem syscall 정지를 reconnect/main/quit 경로가 기다리지 않는다. `${XDG_CACHE_HOME:-$HOME/.cache}/maru/incidents`
디렉터리는 `0700`,
새 파일은 `0600` regular file로
exclusive create하고 symlink를 따르지 않으며 현재 uid 소유를 확인한다. 파일당·총량·보존 기간은 각각 64 KiB, 1 MiB,
7일이고 최대 128개에서 oldest-first로 지운다. disk가 실패하면 process 시작 때 할당한 32 KiB fixed-record emergency ring에
writer는 이미 handoff된 ring record를 disk로 persist하며 실패하면 같은 record를 ring-resident로 유지한다. 재삽입이나
aggregate count 증가는 0이다. disk에 저장된 record는 ring eviction 대상이 아니다. ring은 first-N distinct immutable
slot과 fixed overflow bucket을 분리하고 `{reason,scope,source_site,host_class}` bounded enum fingerprint의 count/first/last만
saturating aggregate한다. incident ID와 raw host ID는 aggregate key가 아니다. Debug/test의
unexpected poison은 같은 기록 뒤 fail-stop한다. 이 artifact는 화면 replay 입력이 아니므로 `maru.trace.v1`에 억지로 섞지 않는다.

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
