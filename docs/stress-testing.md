# 스트레스 테스트 전략

스트레스 테스트는 Maru의 hot path가 반복 호출될 때 상태가 깨지지 않는지 확인하는 테스트다. 벤치마크와 다르게 "몇 ms 안에 끝나야 한다"를 아직 강제하지 않는다. 성능 기준은 `performance budget` 문서가 생긴 뒤 별도로 둔다.

## 계층

| 계층 | 명령 | 기본 `check` 포함 | 목적 |
| --- | --- | --- | --- |
| 빠른 스트레스 | `mise run stress` | 포함 | 매 PR에서 대량 출력과 반복 상태 변경이 terminal core를 깨지 않는지 확인한다. |
| 긴 soak | `mise run stress-soak` | 미포함 | 큰 구조 변경 전후에 더 긴 반복으로 무한 루프, 저장소 불변식, 산출물 생성을 확인한다. |

## 현재 범위

- 많은 CRLF 라인을 terminal core에 입력한다.
- 반복적으로 resize 후 write를 수행한다.
- 최종 screen, structured snapshot, summary artifact를 `tests/artifacts/stress/` 아래에 남긴다.

## 의도적으로 아직 하지 않는 것

- 절대 시간 기준으로 실패시키지 않는다.
- 실제 PTY backpressure를 검증하지 않는다.
- Metal/WebGPU frame pacing을 검증하지 않는다.
- 메모리 상한을 강제하지 않는다.

이 항목들은 PTY, renderer, performance budget이 생긴 뒤 별도 스트레스/벤치마크로 추가한다.

## 추가해야 할 미래 스트레스

- parser: ANSI/OSC/DCS fixture corpus 반복 입력
- PTY: 대량 stdout, resize storm, tab close 중 process cleanup
- renderer: 큰 grid, dirty region storm, cursor blink와 redraw 압박
- workspace: 여러 tab/session restore 반복
- plugin: event queue flood, timeout, 권한 거부, 실패 격리
