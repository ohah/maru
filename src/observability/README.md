# `src/observability`

디버깅, 로그, 테스트, 리플레이가 공유하는 관측 가능성 모델을 담는 폴더다.

초기 후보 책임은 `DebugEvent`, `TraceEvent`, `DebugSnapshot`, `TraceRecorder`, `ReplayRunner`, `FailureArtifact`다. 나중의 GUI inspector도 이 데이터를 시각화해야 한다.

