# 검증 매트릭스

이 문서는 Maru의 각 영역이 무엇으로 검증되는지 추적하기 위한 표다. 목표는 "나중에 구현하자"가 아니라, 아직 구현되지 않은 영역도 어떤 자동 테스트와 산출물로 증명할지 먼저 정해 두는 것이다.

## 현재 자동 검증되는 영역

| 영역 | 현재 검증 방법 | 산출물 | 의미 |
| --- | --- | --- | --- |
| 기본 Zig 빌드 | `mise run build` | 없음 | 프로젝트가 Zig 0.16.0으로 컴파일되는지 확인한다. |
| 단위 테스트 | `mise run test` | 없음 | facade, config, terminal core 같은 작은 단위가 의도대로 동작하는지 확인한다. |
| headless E2E | `mise run e2e` | `tests/artifacts/e2e/headless/*.screen.txt`, `*.snapshot.txt`, `*.stdout.txt` | 실제 프로세스 stdout이 terminal core 상태로 변환되는지 확인한다. |
| recorded oracle 비교 | `mise run oracle` | `tests/artifacts/oracle/*/*.actual.txt`, `*.expected.txt`, `*.snapshot.txt`, `*.decoded.txt` | Maru의 화면 결과가 기록된 reference snapshot과 같은지 확인한다. |
| 빠른 스트레스 | `mise run stress` | `tests/artifacts/stress/quick/*.screen.txt`, `*.snapshot.txt`, `*.summary.txt` | 대량 출력과 반복 resize가 terminal core 상태를 깨지 않는지 확인한다. |
| 성능 예산 측정 | `mise run perf` | `tests/artifacts/perf/core.txt` | terminal core hot path가 보수적인 초기 성능 guardrail 안에 있는지 확인한다. |
| 전체 확인 | `mise run check` | 위 산출물 전체 | format, unit, E2E, oracle, stress, build를 한 번에 확인한다. |

## 구조화 스냅샷

`*.screen.txt`는 사람이 보기 좋지만 터미널 내부 상태를 모두 증명하지 못한다. 그래서 `*.snapshot.txt`는 `RenderSnapshot`에서 다음 상태를 함께 기록한다.

- 화면 크기
- 커서 위치와 표시 여부
- dirty region
- 각 row의 셀 텍스트
- non-default style이 있는 셀 목록

이 포맷은 현재 테스트 산출물이면서, 나중에 replay trace와 inspector가 같은 도메인 데이터를 보도록 하기 위한 첫 관측 가능성 경계다.

## 아직 완전 자동 검증이 아닌 영역

불가 이유는 다음 의미로 쓴다.

- `구현 전`: 기능이나 테스트 러너가 아직 없어서 못 검증한다. 만들면 자동화할 수 있다.
- `환경 의존`: 외부 바이너리, SSH 서버, macOS window server, GPU driver, font stack처럼 실행 환경에 따라 결과가 달라질 수 있다.
- `시스템 한계에 가까움`: 순수 headless 테스트만으로는 실제 화면이나 하드웨어 동작을 완전히 증명하기 어렵다. 대신 내부 snapshot, screenshot, 수동 산출물을 함께 남긴다.

| 영역 | 불가 이유 | 현재 한계 | 손해 | 예정 검증 경로 |
| --- | --- | --- | --- | --- |
| 실제 외부 오라클 실행 | 구현 전, 환경 의존 | `xterm`, `libvterm`, `Alacritty`, Ghostty를 테스트 중 직접 실행하지 않는다. | recorded golden이 틀리면 Maru도 틀린 정답을 따라갈 수 있다. | 선택형 oracle runner를 추가하고, sanitized snapshot 갱신 흐름을 만든다. 새 필수 의존성은 사용자와 먼저 논의한다. |
| PTY/forkpty | 구현 전 | 아직 `PTY` facade만 있고 실제 macOS PTY 연결은 없다. | shell, job control, resize, signal, interactive input 문제를 검증하지 못한다. | `tests/integration/pty/`에서 macOS PTY smoke test를 추가한다. |
| VT parser | 구현 전 | 현재 core는 UTF-8 텍스트와 일부 control만 처리한다. | ANSI 색상, cursor movement, alternate screen, mouse mode 같은 터미널 핵심 호환성을 검증하지 못한다. | 작은 ANSI fixture를 TDD로 추가하고 oracle snapshot을 함께 늘린다. |
| GPU renderer | 구현 전, 환경 의존, 시스템 한계에 가까움 | Metal/WebGPU 렌더러가 아직 없다. 실제 화면 검증은 macOS window server, GPU driver, font stack 영향을 받는다. | 폰트, glyph atlas, frame pacing, dirty redraw 문제를 검증하지 못한다. | headless snapshot과 GUI screenshot artifact를 연결하는 app E2E를 추가한다. |
| workspace/session restore | 구현 전 | 아직 session model만 초기 구조다. | cwd/env/command/layout restore가 실제 사용자 UX로 보장되지 않는다. | serialized workspace fixture와 restore E2E를 추가한다. |
| Wasm plugin | 구현 전 | 현재 plugin registry는 no-op 구조다. | plugin boundary, 권한, event ABI, 실패 격리를 검증하지 못한다. | plugin hook API가 정해진 뒤 fixture plugin과 sandbox failure test를 추가한다. |
| trace/replay | 구현 전 | snapshot은 있지만 event trace/replay는 아직 없다. | 실패를 시간순으로 재현하기 어렵다. | terminal input/output event를 domain event로 기록하고 replay test를 추가한다. |
| SSH workload | 구현 전, 환경 의존 | SSH 전용 integration은 아직 실행하지 않는다. 외부 네트워크나 특정 원격 서버에 묶이지 않는 방식이 필요하다. | 원격 shell, latency, locale, terminal mode 차이를 검증하지 못한다. | 로컬 테스트 서버나 opt-in 환경변수 기반 SSH smoke test를 추가한다. |
| 긴 soak/제품 성능 예산 | 부분 구현, 환경 의존 | `mise run perf`는 core 기준만 측정한다. 앱 시작, 입력 지연, frame budget, RSS는 아직 없다. | GUI/PTY/renderer 성능 회귀는 아직 숫자로 실패시키지 못한다. | macOS host, PTY, renderer가 붙으면 startup, latency, memory, throughput 기준을 확장한다. |

## PR마다 확인할 질문

- 새 기능이 이 표의 어느 검증 경로에 연결되는가?
- 자동 검증이 불가능하다면 어떤 수동 검증 산출물을 남기는가?
- 새 산출물이 기존 snapshot, trace, replay, future inspector와 같은 도메인 데이터를 쓰는가?
- 한계가 새로 드러났다면 PR 설명과 사용자 보고에 적었는가?
