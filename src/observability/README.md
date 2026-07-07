# `src/observability`

디버깅, 로그, 테스트, 리플레이가 공유하는 관측 가능성 모델을 담는 폴더다. 임시 포맷을 따로 두지 않고 같은 도메인 데이터를 producer(writer)와 consumer(reader)가 공유한다.

현재 구현:

- `snapshot.zig` — `maru.snapshot.v3` 화면 스냅샷 **writer**(`renderTerminalSnapshot`). 텍스트 역파싱 reader는 후속(docs/snapshot-versioning.md).
- `trace.zig` — `maru.trace.v1` 셸 의미 이벤트 **writer**(`renderShellEvents`/`writeEvent`) + **reader**(`parseShellEvents`, round-trip). escape/unescape는 top-level `text_escape.zig` 단일 출처.

후속 책임(아직 없음): live 레코딩(`MARU_TRACE` 게이트), replay 재적용(`ReplayRunner` — reader가 되읽은 이벤트를 facade로 다시 흘림), base kind(output/input/resize/process-exit) 이벤트, GUI inspector. 실제 심볼명은 `RenderSnapshot`(terminal/types.zig)·`renderTerminalSnapshot`·`renderShellEvents`·`parseShellEvents`이며, 예전 개념명(`DebugSnapshot`/`TraceRecorder` 등)은 코드에 없다 — 이 데이터를 새로 소비하는 컴포넌트는 실제 심볼을 재사용한다.
