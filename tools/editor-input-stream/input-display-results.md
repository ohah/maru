# 현재 제품의 입력→첫 표시 단계 진단

상태: 실제 수집·원시 자료 독립 재계산·손상/정상 대조 완료. 제품 예약 정책은 바꾸지 않았다.

## 확인한 범위

제품 `940a6c1edff4d1127f8d494c1cbdfcbbc4f05f12`의 같은 ReleaseFast 진단 앱에서
CPU 구간 기록 끔/켬을 반복별 교대로 실행했다. 5만 함수·여러 줄 Zig·3,477,784bytes·50ms·30입력·
비동기·일반/공유 뷰 각 3프로세스다. 전체 12프로세스·360입력, 조건당 3프로세스·90입력이며
첫 입력을 포함했다. LSP·복원·wrap은 끄고 실제 접기는 실행하지 않았다.

기존 강조 전후 자료는 한 줄 함수 fixture와 50/100ms 조건이므로 합치거나 개선율을 계산하지 않는다.
이번 끔 조건도 기본 frame/drawable 시각과 기존 관측 검사를 수행한다. 계측이 없는 제품 기준선은 아니다.

## 첫 표시의 wall 구간

아래는 CPU 기록 **끔**에서 각 키의 구간을 구한 뒤 구한 중앙값이다. 단위 ms.
부품 중앙값이나 p95를 더해 전체 지연으로 쓰지 않는다.

| 구간 | 일반 | 공유 2뷰 |
| --- | ---: | ---: |
| native 도착→producing tick | 5.994 | 8.612 |
| tick의 프레임 준비 | 1.181 | 1.921 |
| tick 마무리 | 0.014 | 0.017 |
| Swift draw 진입 대기 | 0.001 | 0.002 |
| Swift 준비 | 0.011 | 0.013 |
| terminal drawable 획득 | 0.018 | 0.020 |
| overlay drawable 획득 | 0.005 | 0.005 |
| renderer 진입→arm 전체 | 0.192 | 0.181 |
| arm→commit | 0.003 | 0.004 |
| commit→실제 표시 | 18.030 | 22.016 |

renderer 전체는 drawable 획득을 포함하므로 표에서 중복 합산하지 않는다. 첫 표시한 drawable의
renderer 전체 p95는 약 0.24ms였고, 모든 실행에서 terminal/overlay nil 획득은 0개였다.
이 표본에서 drawable 획득 자체나 renderer 준비가 큰 지연이라는 가설은 지지되지 않았다.

commit→present가 가장 큰 관측 구간이었다. 그러나 GPU 실행, 제출 큐, 표시 대기를 함께 포함한다.
`presentedTime`을 GPU 완료 시각이나 광학 시각으로 부르지 않는다. GPU 실행이 느리거나 특정
VSync/timer가 원인이라고 확정하지 않는다.

## handler의 포함 CPU

아래는 CPU 기록 **켬**에서 각 키의 native→첫 표시 구간에 완전히 들어간 thread CPU의 중앙값이다.

| 계측 구간 | 일반 | 공유 2뷰 |
| --- | ---: | ---: |
| 입력 handler wall | 3.885ms | 6.218ms |
| 입력 handler CPU | 3.821ms | 6.142ms |
| 관측 handler 겹침 wall | 0.872ms | 0.923ms |
| 관측 handler 포함 CPU | 0.607ms | 0.647ms |

이 자료에서 관측/입력 handler 간 wall 중첩은 0개였다. 관측 handler와 native→표시 창의 경계가
겹친 입력은 공유 조건의 1개였으며 그 경계 CPU는 비례 배분하지 않았다. 관측 wall의 최댓값은
약 1.74ms였다. 이 계측으로 관측 handler만 전체 native→표시 지연을 설명할 수는 없다.

입력 handler 자체에는 공유 뷰에서 더 큰 main CPU 작업이 있었다. 이 구간은 AppKit 입력 경로와
제품 편집 처리를 함께 포함하며 특정 문자열 복사·파서·LSP 비용으로 아직 나누지 않았다.
`native→tick`에는 입력 handler 실행도 들어 있으므로 그 전체를 프레임 유휴 대기로 부르지 않는다.
handler 밖의 다른 main 실행과 실제 대기도 이 진단만으로 구분하지 않는다.

## 계측 켬/끔 대조

단위 ms, 각 조건의 입력별 pooled nearest-rank p95다.

| 조건 | 게시→표시 p95 | native→표시 p95 |
| --- | ---: | ---: |
| 끔·일반 | 37.459 | 34.702 |
| 켬·일반 | 41.565 | 39.266 |
| 끔·공유 | 50.663 | 39.277 |
| 켬·공유 | 44.959 | 41.862 |

방향과 크기가 조건별로 다르다. 계측이 스케줄/표시 위상에 영향을 줄 수 있으며, 이 표본의
p95 차이를 일정한 계측 비용으로 빼거나 제품 성능 개선/회귀로 부르지 않는다.
각 군은 독립 3프로세스뿐이고 단일 Mac·고정 workload의 진단 모집단이다.

## 검증과 발견한 수정

- Python 계약 및 같은 Swift 기록기의 실제 CPU 시계·끔 대조·넘침·시계 실패 검사 129개 통과.
- 실제 원본에 frame/drawable·CPU·스레드·완료 등을 독립 손상한 24개는 모두 거절됐다. 정상 전후 대조 48개와 등가 대조 1개를 유지했다.
- 독립 재판정 중 선언된 비교 쌍만으로 각 군의 실제 3반복을 대신할 수 있는 검증 누락을 보완했다. 각 군의 repetitions와 6개 실제 run 경로를 함께 검사한다. 이번 원본은 실제로 모두 3반복이어서 수치 변경은 없었다.
- 원본과 당시 도구 사본을 그대로 보존했다. 새 reader 해시를 보고서에 남기고, 기존 원본 report와 새 재판정의 군별 결과가 같음을 확인했다. 이 수정은 수집 앱/handler/시각을 바꾸지 않았다.
- 제품 source와 프레임 예약·투영·재시도 정책은 바꾸지 않았다.

## 증거와 다음 범위

- 불변 앱: `~/.cache/maru-agent-artifacts/input-display-build-1`.
- 앱 SHA-256: `731c876b469eac432badb3530873b35cc545f38a29fc5713bbd182f4a89bc4b8`.
- 원본: `~/.cache/maru-agent-artifacts/input-display-study-1`의 두 군별 원시 JSON·도구 사본·단계 자료.
- 최초 결과 `report.json`과 독립 재계산 `recomputed-v3.json`을 구분해 보존했다.
- 손상 대조: `~/.cache/maru-agent-artifacts/input-display-review-3`.
- [정확한 값·해시·조건별 분포](input-display-results.json), [계약과 재현](../../docs/plans/editor-current-input-display.md).

다음에 더 나눌 대상은 **commit→present의 GPU 실행/큐·표시 대기**와 **입력 handler 내부 CPU**다.
현재 자료만으로 프레임율/예약 정책 변경이나 특정 자료구조 최적화를 고르지 않는다.
광학 표시·사람의 물리 키보드·IME/스크롤·다른 문서 크기와 실제 접기는 별도 범위다.
