# `tests/integration/pty`

PTY와 process 관련 통합 테스트를 담는다.

예시는 `openpty -> shell/program -> TerminalCore -> screen snapshot` 흐름이다.

`SurfaceRuntime`이 붙은 뒤에는 `openpty -> shell/program -> PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> Surface -> TerminalCore -> screen snapshot` 흐름도 여기서 검증한다. 이 테스트는 GUI가 없어서 headless지만, 실제 macOS PTY를 사용하므로 기본 `mise run check`가 아니라 opt-in `mise run pty`에 남긴다.

대량 stdout stress는 같은 opt-in 경로에 둔다. queue capacity를 1로 낮춰 reader/pump backpressure 경로를 지나게 하고, raw bytes, screen, snapshot, summary artifact로 drop 여부를 확인한다.

reader close lifecycle도 같은 opt-in 경로에 둔다. 출력이 없는 long-running child를 띄워 reader thread가 PTY read에서 기다릴 수 있는 상황을 만들고, `PtyReader.stopAndJoin`이 queue close, session close, thread join, child reap을 끝내는지 `reader-stop.summary.txt`로 확인한다. 이 테스트는 GUI app close button을 검증하지 않는다. 실제 window/tab close 연결은 app host 단계에서 별도로 검증한다.
