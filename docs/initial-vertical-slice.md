# 초기 세로 슬라이스

이 문서는 Maru의 첫 구현 목표를 좁게 고정한다. 목적은 많은 기능을 한 번에 넣는 것이 아니라, 실제 shell bytes가 Maru의 책임 경계를 지나 snapshot과 테스트 산출물로 보이는 길을 먼저 만드는 것이다.

`v0` 같은 제품 버전 이름을 쓰지 않는 이유는, 이 범위가 사용자에게 배포할 버전이 아니라 개발자가 처음으로 검증할 세로 경로이기 때문이다. 여기서 중요한 것은 이름이 아니라 `PTY -> TerminalCore -> snapshot/artifact` 경로가 자동 테스트로 증명되는 것이다.

## 목표

```text
macOS 로컬 shell 1개 surface
-> PTY output bytes
-> TerminalCore
-> snapshot/trace artifact
-> headless test 통과
```

GUI가 붙기 전에는 headless 경로가 첫 성공 기준이다. macOS 창과 renderer는 같은 계약을 소비하는 다음 단계로 붙인다.

## 포함한다

- macOS local shell을 실행할 수 있는 `PtySession` facade.
- PTY에서 읽은 raw bytes를 `TerminalCore.write`로 넣는 단방향 output path.
- 사용자가 입력한 key bytes를 PTY로 보내기 위한 최소 input path.
- surface 1개를 표현하는 `Surface` 모델.
- `TerminalCore` snapshot과 실패 artifact.
- raw input, resize, output을 나중에 replay할 수 있는 trace event 이름과 위치.
- headless E2E: 실제 프로세스 또는 통제된 PTY workload가 최종 screen snapshot으로 검증되는 경로.

## 의도적으로 하지 않는다

- 여러 탭.
- split layout.
- workspace restore.
- repo별 기본 레이아웃.
- scratch/quick terminal UX.
- 글로벌 핫키 구현.
- Wasm plugin ABI.
- renderer 최적화.
- 외부 terminal runtime 의존성 추가.

이 기능들은 구조상 들어올 자리를 막지 않는다. 다만 초기 세로 슬라이스에서는 interface와 문서상 경계만 유지하고, 실제 동작은 구현하지 않는다.

글로벌 핫키는 장기적으로 지원하되, 초기 세로 슬라이스에서는 [키 입력과 단축키 경계](key-input-and-shortcuts.md)에 적은 충돌 규칙만 유지한다.

## 성공 기준

- `mise run check`가 통과한다.
- PTY/headless E2E가 자동화되어 있다.
- 실패 시 raw input, decoded screen, structured snapshot이 `tests/artifacts/` 아래에 남는다.
- 구현 전 문서화된 경계와 실제 코드 경계가 다르면 PR에서 사용자에게 보고한다.
- 자동 E2E가 불가능한 영역은 완료 처리 전에 이유와 수동 검증 방법을 남긴다.

## 개발 순서

1. `docs/facade-contracts.md`의 계약을 먼저 지킨다.
2. trace/snapshot 산출물을 먼저 정의한다.
3. macOS `PtySession`을 최소 기능으로 붙인다.
4. `Surface`가 `PtySession`과 `TerminalCore`를 연결한다.
5. headless E2E로 shell output이 snapshot까지 도달하는지 검증한다.
6. 같은 snapshot 계약을 renderer와 macOS app host가 소비하게 만든다.

## 중단하고 사용자와 논의할 조건

- 초기 세로 슬라이스를 위해 외부 runtime 의존성이 필요해지는 경우.
- `TerminalCore`가 PTY나 renderer를 직접 알아야 하는 구조가 필요한 경우.
- trace/snapshot 없이 먼저 구현해야 한다고 판단되는 경우.
- 테스트 자동화가 불가능한 영역이 초기 성공 기준에 들어오는 경우.
- plugin, workspace restore, renderer 세부 API를 지금 확정해야 하는 상황이 생기는 경우.
