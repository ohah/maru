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
- `keyIsSensitive`가 env·argv redaction과 같은 토큰 목록을 공유한다(agent_resume가 위임).
