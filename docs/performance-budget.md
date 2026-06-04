# 성능 예산

성능 예산은 Maru가 "작고 빠른 native shell"이라는 목표를 실제 숫자로 추적하기 위한 기준이다. 이 문서는 벤치마크 점수를 자랑하기 위한 문서가 아니라, 기능을 추가할 때 느린 구조가 조용히 들어오지 않게 막는 안전장치다.

## 원칙

- 기본 `mise run check`에는 성능 측정을 넣지 않는다. 하드웨어와 시스템 부하에 따라 결과가 흔들릴 수 있기 때문이다.
- `mise run perf`는 로컬 opt-in 명령이다. 큰 구조 변경 전후에 실행한다.
- 초기에 걸어두는 숫자는 보수적인 guardrail이다. 정확한 목표치는 macOS app, PTY, renderer가 붙은 뒤 다시 조정한다.
- 성능 실패는 숫자만 보고 고치지 않는다. 어떤 책임 경계가 느린지 trace/snapshot/artifact로 확인한 뒤 루트커즈를 고친다.

## 현재 측정 명령

```sh
mise run perf
```

현재 산출물:

```text
tests/artifacts/perf/core.txt
```

## 현재 자동 예산

| 항목 | 현재 예산 | 측정 범위 | 이유 |
| --- | --- | --- | --- |
| `core_large_output` | 2,000ms 이하 | 100,000개 CRLF line을 `TerminalCore.write`에 입력 | 대량 stdout에서 무한 루프나 비정상적으로 느린 cell update를 조기에 찾는다. |
| `core_resize_loop` | 1,000ms 이하 | 5,000회 resize/write 반복 | window resize, font size 변경, 미래 split/workspace restore가 storage 불변식을 깨지 않는지 본다. |
| `snapshot_serialize` | 1,000ms 이하 | 120x40 snapshot 200회 구조화 직렬화 | 관측 가능성 도구가 너무 무거워져 hot path를 방해하지 않도록 감시한다. |

이 숫자는 최종 제품 목표가 아니다. 현재 MVP core가 실수로 극단적으로 느려지는 것을 막는 최소 guardrail이다.

## 아직 예산이 없는 영역

| 영역 | 이유 | 예정 측정 |
| --- | --- | --- |
| 앱 시작 시간 | macOS host가 아직 없다. | app launch -> first drawable time |
| 입력 지연 | PTY와 GUI input path가 아직 없다. | key event -> PTY write, PTY output -> snapshot update |
| frame budget | Metal-first renderer가 아직 없다. future WebGPU backend도 같은 기준을 따른다. | snapshot -> GPU frame submit |
| font/glyph atlas | font resolve와 atlas가 아직 없다. 세부 정책은 [폰트 전략](font-strategy.md)을 따른다. | first glyph resolve, frame당 atlas miss, atlas upload bytes, font size 변경 후 첫 frame |
| RSS/memory baseline | platform별 측정 API가 필요하다. | cold start RSS, one tab RSS, scrollback RSS |
| PTY backpressure | 실제 PTY backend가 아직 없다. | large stdout producer -> UI responsiveness |

## 향후 목표 초안

이 값은 구현이 붙은 뒤 검증하며 조정한다.

| 항목 | 초안 |
| --- | --- |
| cold start to first window | 150ms 이하 목표 |
| first shell prompt | 300ms 이하 목표 |
| key input local echo path | p95 8ms 이하 목표 |
| steady frame budget | 120Hz 기준 8.3ms 안쪽 목표 |
| one idle tab RSS | 측정 후 기준 확정 |
| large scrollback memory | page storage 설계 후 기준 확정 |
