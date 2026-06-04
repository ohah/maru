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

event kind는 `SurfaceRuntime`의 runtime event와 1:1로 맞춘다. 정식 대응표는 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절을 단일 출처로 둔다. 요약하면 `process-exit`는 runtime의 `PtyEvent.exited`와 같은 사건이고, `PtyEvent.read_error`는 환경 의존적 실패라 trace에 남기지 않는다.

Shell integration event는 아직 `maru.trace.v1`에 포함하지 않는다. `shell.cwd-changed`, `shell.prompt-start`, `shell.prompt-end`, `shell.command-start`, `shell.command-end`를 trace에 넣는 PR은 schema를 먼저 갱신하고, replay가 해당 metadata를 어떻게 surface/workspace에 반영하는지 테스트해야 한다.

초기에는 wall-clock timestamp를 replay 의미에 쓰지 않는다. 시간은 디버깅 보조 정보일 수 있지만, replay의 정답은 event 순서다.

## replay가 하는 일

Replay runner는 trace를 읽고 public facade만 호출한다.

```text
trace file
-> ReplayRunner
-> SurfaceRuntime.applyPtyEvent / writeInput / resize
-> Surface
-> TerminalCore
-> DebugSnapshot
```

중요한 점은 replay가 private parser storage를 직접 만지지 않는다는 것이다. 실제 앱과 같은 public 경로로만 재현해야 버그를 제대로 잡는다.

replay에는 live `PtySession`이 없다. trace는 이미 일어난 입력의 기록이므로, `writeInput`/`resize`의 PTY 방향 부수효과(child에게 bytes 전달, master fd ioctl)는 재현 대상이 아니다. 따라서 replay runner는 `SurfaceRuntime`에 no-op `PtySession`을 attach하거나 core 방향 효과만 적용하고, PTY 방향 호출은 무시한다. replay의 정답은 `output`/`resize` event가 `TerminalCore`에 반영된 결과이지 child process 재실행이 아니다.

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

- 같은 trace를 두 번 replay하면 같은 snapshot이 나온다.
- trace event 순서가 바뀌면 다른 snapshot이 나올 수 있음을 테스트한다.
- 민감정보 키워드가 있는 trace fixture는 저장 전에 실패한다.
- replay는 private parser storage를 import하지 않는다.
