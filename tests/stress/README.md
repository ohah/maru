# `tests/stress`

스트레스 테스트는 벤치마크가 아니라 안정성 테스트다.

목표는 긴 출력, 반복 resize, snapshot 생성처럼 터미널 hot path가 많이 호출되는 상황에서 다음 문제가 없는지 확인하는 것이다.

- 무한 루프
- 잘못된 cell storage 크기
- cursor가 화면 밖으로 나가는 문제
- resize 후 이전 버퍼를 잘못 읽는 문제
- 사람이 확인할 수 없는 실패 산출물

## 실행 계층

- `mise run stress`: 빠른 스트레스 테스트다. 기본 `mise run check`에 포함된다.
- `mise run stress-soak`: 더 긴 opt-in 테스트다. 로컬에서 큰 변경 전후에 실행한다. 기본 `check`에는 넣지 않는다.

절대 시간 기준은 아직 두지 않는다. 성능 예산 문서가 생기기 전까지는 실행 시간으로 실패시키지 않고, 상태 불변식과 snapshot artifact를 검증한다.
