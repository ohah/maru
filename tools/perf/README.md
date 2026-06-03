# `tools/perf`

성능 예산을 측정하는 로컬 실행 도구를 담는다.

이 폴더의 도구는 테스트와 다르다. 기본 `mise run check`에는 들어가지 않으며, 큰 구조 변경 전후에 `mise run perf`로 실행한다.

결과는 `tests/artifacts/perf/` 아래에 로컬 산출물로 남긴다.
