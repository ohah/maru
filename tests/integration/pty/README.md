# `tests/integration/pty`

PTY와 process 관련 통합 테스트를 담는다.

예시는 `openpty -> shell/program -> TerminalCore -> screen snapshot` 흐름이다.

`SurfaceRuntime`이 붙은 뒤에는 `openpty -> shell/program -> PtyReader -> PtyEventQueue -> SurfaceRuntime -> Surface -> TerminalCore -> screen snapshot` 흐름도 여기서 검증한다. 이 테스트는 GUI가 없어서 headless지만, 실제 macOS PTY를 사용하므로 기본 `mise run check`가 아니라 opt-in `mise run pty`에 남긴다.
