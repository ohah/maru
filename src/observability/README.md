# `src/observability`

디버깅, 로그, 테스트, 리플레이가 공유하는 관측 가능성 모델을 담는 폴더다. 임시 포맷을 따로 두지 않고 같은 도메인 데이터를 producer(writer)와 consumer(reader)가 공유한다.

현재 구현:

- `snapshot.zig` — `maru.snapshot.v3` 화면 스냅샷 **writer**(`renderTerminalSnapshot`) + **reader**(`parseSnapshot` → `ParsedSnapshot`, round-trip). 부분 복원(writer가 직렬화하는 size·cursor·dirty·행·cell-metadata·styled-cells만 — docs/snapshot-versioning.md "v3 reader 규칙").
- `trace.zig` — `maru.trace.v1` **writer**(shell: `renderShellEvents`/`writeEvent`, base kind: `writeOutputEvent`/`writeResizeEvent`/`writeInputEvent`/`writeProcessExitEvent`) + **reader**(`parseEvents` → `[]ParsedEvent`, shell.* 와 base kind 전부). escape/unescape는 top-level `text_escape.zig` 단일 출처.
- `replay.zig` — trace **재적용**(`replayTrace`). output/resize를 `core.write`/`core.resize`로 흘려 화면을 byte-for-byte 재구성(파서가 셸 이벤트·cwd 재도출), output 없는 shell-only trace는 shell.* 를 OSC로 재발행(fallback).

라이브 레코딩은 `app/trace_recorder.zig`의 `TraceRecorder`(app 레이어 — 파일 I/O)가 맡는다: `MARU_TRACE=<경로>`면 `SurfaceRuntime` 훅에서 base kind를 이 폴더의 writer 함수로 누적하고 `AppSession.deinit`에서 파일로 굳힌다.

후속 책임(아직 없음): GUI inspector, 입력 이벤트 기록, 경로/유저명 익명화 transform. 실제 심볼명은 `RenderSnapshot`(terminal/types.zig)·`renderTerminalSnapshot`/`parseSnapshot`·`renderShellEvents`/`parseEvents`/`replayTrace`·`TraceRecorder`(app/trace_recorder.zig)이며, 예전 개념명(`DebugSnapshot`/`ReplayRunner` 등)은 코드에 없다 — 이 데이터를 새로 소비하는 컴포넌트는 실제 심볼을 재사용한다.
