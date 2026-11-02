# 워커 심볼 요약 준비 검증

실제 완료를 두 뷰에 설치하는 회귀가 수정 전 `expected 0, found 33`으로 실패했다.
워커에서 기존 요약을 준비하고 복제한 뒤에는 두 뷰의 첫 조회 재구축이 0이다.

## 불변식과 실패 경로

다음은 서로 다른 실패 가설이며 같은 테스트의 단순 반복을 세지 않았다.
Debug와 ReleaseFast 집중 게이트, syntax 및 제품 입력 회귀에서 아래 조건을 확인했다.

| 공격 조건 | 실제 확인된 결과 | 판정자 |
| --- | --- | --- |
| 완료를 두 뷰에 설치해 첫 조회 | 양쪽 재구축 0, 정상 심볼 조회 | parse-view |
| 원본 완료를 먼저 종료 | 복제 요약은 독립 참조로 유효 | sticky-preparation |
| 심볼이 없는 원문 | 빈 집계도 준비·복사하며 재구축 0 | sticky-preparation |
| CRLF·NFD·이모지 원문 | 독립 조상 조회와 결과 일치 | sticky-preparation |
| 준비 시작 전 취소 | 집계 미공개, 정상 재시도 성공 | sticky-preparation |
| cold 순회 중 취소 | 부분 개수 미공개, 정상 재시도 성공 | sticky-preparation |
| 증분 순회 중 취소 | 이전 트리·세대·개수 보존 | sticky-preparation |
| 증분 집계 할당 실패 | 이전 집계 보존, 정상 후속 조회 성공 | sticky-preparation |
| 실제 worker 준비 장벽에서 취소 | 완료 거절, native 자원 회수 | parse-worker |
| 실제 worker 선택적 캐시 OOM | 파싱 유지, 요약 없는 뷰는 기존 조회로 집계 | parse-worker |
| 오래된 요약 세대 | 현재 완료 요약으로 복사하지 않고 재집계 | sticky-snapshot |
| 미반영 편집이 있는 요약 | 현재 완료 요약으로 복사하지 않음 | sticky-snapshot |
| 다른 언어로 복사 | 요약 및 트리 인계 거절 | sticky-snapshot |
| 구조 범위가 빈 선언 편집 | 실제 선언 존재 여부 갱신 | sticky-changes |
| 지연된 여러 편집·전체 교체 | 독립 전체 집계와 일치 | sticky-changes |
| 수신 뷰와 다른 이전 트리 | 수신의 범위와 요약으로 계산 | sticky-changes |
| 범위 차용·자체 비교의 모든 Zig 할당 실패 | 누수 없이 재시도 집계 보존 | sticky-changes |
| 새 요청이 아직 빌리지 않은 완료를 교체 | 이전 완료 퇴역, 최신 결과 수락 | parse-worker |
| 결과를 빌린 동안 종료 | 종료 거절, 반환 뒤 정상 종료 | parse-worker |
| 측정 분기 라벨 위조·잘못된 계수/타입 | 실제 우회/준비/뷰 재구축 계수와 맞지 않으면 거절 | test_summary_control.py |

집중 게이트: sticky-preparation 6, parse-worker 21, parse-view 5,
sticky-snapshot 4, sticky-changes 7. 모두 Debug·ReleaseFast 통과.
추가 Debug: syntax 106, parse-view-regression 35, sticky-snapshot-product 5,
parse-input 10. production-mode native worker도 cold 1 / incremental 1 / accepted 2 통과.
Python stream 계약 63개 통과. 숫자는 import 검사를 포함하는 게이트의 실제 수집 수다.

## 성능 대조 범위

동일한 외부 측정 실행 파일에서 워커 준비만 끄고 켠다. 앱과 생산자 해시가 같고,
인접 실행의 순서를 교대한다. 첫 키를 포함한 모든 키의 median/nearest-rank p95/max를
보존한다. 프로파일러는 붙이지 않는다. 입력 ID·본문 접두부·Metal 표시·최종 색과 실제
워커 분기 및 뷰 재구축 계수를 검증한다. 물리 키보드·IME·광학 표시의 검증은 아니다.
화면 레이아웃·스타일은 바꾸지 않으며, native 조상 조회와 제품 sticky snapshot 회귀가
기존 표시 내용을 확인한다. 새 PNG의 전후 픽셀 동등성을 주장하지 않는다.

## 같은 실행 파일의 실측

2026-11-02 잠금 해제된 macOS에서 앱 48회·1,440입력을 모두 채택했다.
조건마다 준비 끔/켬 각 3프로세스·90키이며 예상 밖 실패·재시도·표본 제거는 없다.
별도 pilot 2프로세스는 본 행렬에 넣지 않았다. 본 작업의 경계 검사 프로세스 그룹은
측정 동안 멈추고 종료 후 다시 실행했다. 다른 사용자 작업은 중단하지 않았다.

아래 단위는 ms, 숫자는 준비 **끔 → 켬**이다. `shared`는 같은 문서의 두 분할이다.

| 함수 수 | 게시 간격 | 뷰 | 첫 표시 중앙값 | 첫 표시 p95 | 첫 표시 최대 | 최종 색 완료 최대 |
| --- | --- | --- | --- | --- | --- | --- |
| 3000 | 50 | shared | 54.4 → 51.3 | 64.3 → 59.9 | 67.4 → 63.4 | 82.1 → 70.9 |
| 3000 | 50 | typing | 48.7 → 45.6 | 56.2 → 52.0 | 56.8 → 54.2 | 79.0 → 55.3 |
| 3000 | 100 | shared | 55.7 → 44.8 | 65.0 → 55.7 | 65.9 → 59.5 | 69.2 → 81.0 |
| 3000 | 100 | typing | 48.4 → 41.6 | 55.5 → 51.6 | 58.0 → 66.4 | 72.5 → 64.0 |
| 50000 | 50 | shared | 134.0 → 49.3 | 340.4 → 196.6 | 366.9 → 199.3 | 1067.7 → 825.8 |
| 50000 | 50 | typing | 60.0 → 49.7 | 189.2 → 119.0 | 191.5 → 126.1 | 707.5 → 653.1 |
| 50000 | 100 | shared | 168.3 → 89.7 | 311.4 → 190.2 | 337.1 → 194.1 | 1098.8 → 845.3 |
| 50000 | 100 | typing | 90.1 → 73.4 | 186.9 → 109.4 | 191.4 → 119.5 | 830.7 → 658.3 |

8조건 모두 첫 표시 중앙값·p95가 낮았다. 큰 공유 문서에서는 효과가 컸지만
작은 공유 문서의 100ms 조건에서 최종 색 완료 최대는 69.2→81.0ms로 늘었다.
이 조건의 3회 원시 값도 JSON에 그대로 남긴다. 프로세스 peak 메모리의 전체 최대는
319.0→319.2MiB였다. 이는 시작 비용을 포함하는 프로세스 측정이며 요약 자체의 할당량이 아니다.
단일 호스트·특정 Zig fixture의 대조여서 모든 언어·문서·IME의 개선율로 일반화하지 않는다.
접힘 승격은 여전히 남아 있으므로 입력 지연 문제가 전부 해결됐다고 주장하지 않는다.

기능을 끈 24프로세스 모두 worker 우회·뷰 재구축을 확인했고, 켠 24프로세스는 worker 준비 성공과
최종 뷰 재구축 0을 확인했다. [집계와 원시 영수증 해시](summary-results.json)에
게시→native·native→표시, 색 완료·메모리의 개별 프로세스 값과 실제 분기 계수를 보관한다.

- 측정 소스: `15a83e4fc64af7fa194d3fe8db6032ce8c3b47f4`
- 같은 앱 SHA-256: `af2ba83741202b6d6bb6fddaf087bbafed9981c82ba47aed9d150edd84ff7d48`
- 원본: `~/.cache/maru-agent-artifacts/async-sticky-study-1` (양쪽 manifest·앱/생산자 JSON·로그·fixture·tool snapshot).
- 불변 실행 파일/소스: `~/.cache/maru-agent-artifacts/async-sticky-control-build-1`.
- 설치 RED: `/tmp/maru-async-sticky-red.log`; focused/release/regression 로그는
  `/tmp/maru-async-sticky-{focused,release,regression}.log`.
- 실행: `python3 tools/editor-input-stream/summary_study.py --build <불변 앱 디렉터리> --output <새 외부 디렉터리>`.

임시 앱 전용 분기·통계 ABI는 제품에 들어가지 않는다. 본 결과는 워커 준비의 한 번의
paired 실행 행렬이며, 별도 프로파일러 재귀속이나 장시간 열/전력 실험을 대체하지 않는다.
