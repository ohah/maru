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
- `event kind`: `output`, `input`, `resize`, `process-exit`.
- `surface`: 어느 surface에 속한 이벤트인지.
- event별 payload.

event kind는 `SurfaceRuntime`의 runtime event와 1:1로 맞춘다. 정식 대응표는 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절을 단일 출처로 둔다. 요약하면 `process-exit`는 runtime의 `RuntimePtyEvent.exited`와 같은 사건이고, `RuntimePtyEvent.read_error`는 환경 의존적 실패라 trace에 남기지 않는다.

### Shell integration event (semantic prompt 라이프사이클)

`TerminalCore`가 OSC 133/7을 파싱하며 `types.ShellEvent`(`prompt_start`·`input_start`·`command_start`·`command_end{row,exit}`·`cwd_changed`)를 시간순으로 기록하고, 소비자가 `shellEvents()`로 읽고 `clearShellEvents()`로 비운다. 같은 도메인 데이터를 디버그 로그(`MARU_DEBUG`의 `shell.*` scoped 로그)·결정적 테스트·trace 직렬화가 공유한다(관측 가능성 원칙 — 임시 포맷을 따로 두지 않는다).

**직렬화·역파싱이 구현됐다**(writer + reader): `observability/trace.zig`의 `renderShellEvents`/`writeEvent`(writer)가 이벤트 스트림을 `maru.trace.v1` 라인으로 굳히고, `parseShellEvents`(reader)가 그 라인을 `ParsedEvent`(원 `ShellEvent` + index/surface_id + cwd_changed의 unescape된 경로)로 되읽는다 — `parseShellEvents(renderShellEvents(events, cwd))`가 원 이벤트와 cwd를 복원한다(round-trip 테스트). 이벤트 이름은 trace 토큰과 1:1이다. escape/unescape는 `text_escape.zig` 단일 출처를 공유한다.

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

**아직 없는 것**(후속): (1) live 레코딩 — 실제 세션에서 이 라인을 파일로 append하는 `MARU_TRACE` 게이트(drain 훅은 `app_session.zig`의 `drainShellEventsForFrame`에 표시돼 있다), (2) replay용 `output`/`input`/`resize`/`process-exit` 이벤트(위 base kind), (3) **`ReplayRunner`** — reader가 되읽은 이벤트를 public facade(`SurfaceRuntime`)로 **재적용**해 상태를 재현하는 것(아래 "replay가 하는 일"). reader(텍스트→이벤트 역파싱)는 **구현됨**(`parseShellEvents`) — ReplayRunner는 그 위에서 재적용 단계를 얹는다.

### Control-plane event (미정)

[세션 컨트롤 플레인](control-plane.md)의 JSON-RPC 요청/응답/notification은 현재 `maru.trace.v1` event kind가 아니다. 따라서 구현 PR은 기존 trace 포맷을 그대로 "재사용"한다고 주장하면 안 된다. 컨트롤 플레인 기록이 필요해지는 PR은 먼저 [Facade 계약](facade-contracts.md)의 `Trace/Event` 대응표와 이 문서를 함께 갱신해 `control.request`/`control.response`/`control.notification` 같은 어휘, id 매칭, 실패 응답, replay 의미를 확정한다.

이 event에는 cwd, scrollback, command output, capability token, WebDriver script/cookie 같은 민감 데이터가 섞일 수 있다. 저장 전 redaction은 [프로젝트 규칙](project-rules.md)의 기준을 따르고, capability/token 값은 fixture에 남기지 않는다.

초기에는 wall-clock timestamp를 replay 의미에 쓰지 않는다. 시간은 디버깅 보조 정보일 수 있지만, replay의 정답은 event 순서다.

## replay가 하는 일

Replay runner는 trace를 읽고 public facade만 호출한다. trace **읽기**(`parseShellEvents`)는 구현됐고, 아래 **재적용**(ReplayRunner)이 후속이다 — reader가 낸 이벤트를 facade로 흘려보내는 단계.

```text
trace file
-> parseShellEvents (reader — 구현됨)
-> ReplayRunner (재적용 — 후속)
-> SurfaceRuntime.applyPtyEvent / writeInput / resize
-> Surface
-> TerminalCore
-> RenderSnapshot (renderTerminalSnapshot)
```

중요한 점은 replay가 private parser storage를 직접 만지지 않는다는 것이다. 실제 앱과 같은 public 경로로만 재현해야 버그를 제대로 잡는다.

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

## 초기 테스트

reader(구현됨, `observability/trace.zig`):
- **round-trip**: 실제 OSC 133/7을 먹인 core의 이벤트 스트림을 직렬화한 뒤 `parseShellEvents`로 되읽으면 원 이벤트(태그+payload)와 cwd 경로가 그대로 복원된다.
- 헤더가 틀리면 `BadHeader`, 라인이 깨지면(kind/surface 누락 등) `BadLine`. `exit=none`/실패 exit code, cwd escape(공백·따옴표·개행) 복원.

replay 재적용(후속):
- 같은 trace를 두 번 replay하면 같은 snapshot이 나온다.
- trace event 순서가 바뀌면 다른 snapshot이 나올 수 있음을 테스트한다.
- 민감정보 키워드가 있는 trace fixture는 저장 전에 실패한다.
- replay는 private parser storage를 import하지 않는다.
