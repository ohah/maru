# 관측기 작업별 CPU와 첫 입력 구간 귀속

상태: 같은 앱의 계측 켬/끔 12프로세스·360키와 실제 자료 손상 검증 완료. 제품 코드는 변경하지 않는다.

## 비교 조건

`prepare.py --observer-work-control` 사본은 `cached_posts`·`with_retry`·대상 60Hz 예산을 고정하고
작업 계측 `untimed`/`timed`만 바꾼다. 단일 창 1뷰/공유 2뷰·50,000함수·50ms·30키를
각 조건 독립 3프로세스씩, 총 12프로세스·360키로 비교한다. 첫 입력도 공식 지표에 포함한다.

`observer_work.swift.inc`의 `ObserverWork.measure`는 기존 조건의 순서와 단락 평가를 보존한다.
로컬 포커스, 전면 앱, 전역 입력 소스, 뷰 입력 소스, header 복사, native 문서 상태 확인을 나눈다.
검사는 끄지 않으며 untimed도 같은 클로저·호출 수를 거친다. timed의 clock/기록 비용은
handler CPU에 포함된다. 켬/끔의 비교가 계측 전혀 없는 제품의 오버헤드 측정은 아니다.

## 원시 기록과 판정

`work_*` snapshot은 wall 시각·오류·event 수 뒤에 여섯 작업의 호출 수/CPU(ns)를 번갈아 둔다.
`work_events`는 작업 번호·시작 wall·종료 wall·CPU(ns)·그 작업의 호출 순서다.
phase 2에만 기록하고 main-thread 구간의 중첩·clock 오류·4,096행 넘침은 자료 오류로 거절한다.
이 상한은 진단 기록 크기이며 제품 큐의 한도가 아니다.

각 작업의 호출 수는 handler 호출 수와 맞아야 하고, timed event 수/CPU 합계는 snapshot 차이와
맞아야 한다. CPU는 각 작업의 wall을 넘지 않아야 하며 작업 CPU 합계와 JSON CPU는 handler CPU를
넘지 않아야 한다. untimed는 호출 수는 남기되 CPU와 event는 0이어야 한다.

첫 입력은 기존 `frame_tail_report.key_trace`로 같은 producing frame/drawable에 연결한다.
게시→native 도착, native→producing tick 구간에 실제 작업 event를 겹쳐 본다. wall은 겹친 부분만
세고 CPU는 완전히 들어간 event만 합한다. 경계 event의 CPU를 wall 비율로 나누지 않는다.
나머지 wall은 미귀속 시간이며 곧바로 OS queue 대기나 제품 계산으로 이름을 바꾸지 않는다.

## 실행

```sh
python3 tools/editor-input-latency/prepare.py --output <새 외부 빌드> --deps <의존성 경로> --cache <전용 캐시> --stream --fold-reuse-control --parse-stages --display-stages --frame-wake-control --target-frame-control --observer-cpu --deferred-retry-control --observer-posts-control --observer-work-control
python3 tools/editor-input-stream/observer_work_study.py --build <빌드> --output <새 외부 자료>
python3 tools/editor-input-stream/observer_work_report.py <자료> --output <새 JSON>
python3 tools/editor-input-stream/observer_work_review.py <자료> --output <새 외부 검증>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

## 검증과 한계

자동 판정자는 모드·조건·clock·event 형태·호출 순서·누락·중첩·CPU 합계를 확인한다.
Swift 실제 helper는 반환값·단락 평가·phase 밖의 무기록, 계측 켬/끔과 잘못된 작업 번호·중첩·
기록 넘침에서도 본래 작업을 수행하는지 검사한다. QuartzCore 실행은 macOS 전용이다.

CGEventPostToPid ASCII의 진단이며 물리 HID·한국어 IME·광학 지연 검증이 아니다.
작업 구간 밖의 메인 실행/대기를 분리한 것은 아니고, 계측이 스케줄링에 주는 영향도 비교해야 한다.
다른 앱·이전 자료와 한 모집단으로 합치지 않는다. 제품 프레임 후보 적용은 계속 보류한다.


## 헬퍼 검증에서 수정한 전제

최초 Swift 헬퍼 검증은 CPU만 1ns 단위 가짜 시계로 두고 실제 wall 시계를 사용했다.
저장한 실패 실행에서 `wall == wallEnd`인 짧은 작업이 재현돼 clock 오류로 분류됐다.
이는 실제 앱의 CPU 시계에서 재현한 제품 결함이 아니라 두 시계의 해상도가 맞지 않은 테스트 전제였다.
헬퍼 테스트는 두 시계를 함께 결정적으로 주입하고, 실제 thread CPU/wall을 쓰는 대조도 별도로 실행한다.
앱 계측 코드는 이 수정에서 바꾸지 않았다. 실패 자료는
`~/.cache/maru-agent-artifacts/observer-work-helper-failure-6db0b29457844f67a477950e7acc9e3d`와
`observer-work-helper-diagnosis-1`에 보존한다. 임의 sleep이나 재실행 성공으로 실패를 덮지 않는다.


## 실제 입력 결과

측정 앱의 제품 HEAD는 `cf1dd55e2cded969d456804239679737ce211c0b`,
앱 SHA-256은 `81709c7f8b64c92ebc2bd108a10d3844d9d081dcac659749a3701f988dbccf86`다.
후속 PR 커밋에서 제품을 다시 측정했다는 뜻이 아니다. 모든 앱/producer exit는 0이다.
[실행별 값](observer-work-results.json)과 [손상 판정](observer-work-validation.json)을 보존한다.

계측 켬 6개 실행에서 약 2초 유휴의 전면 앱 조회는 handler CPU의 91.89–94.50%였다.
`NSWorkspace.shared.frontmostApplication`을 포함한 검사 구간이며 제품 전체 CPU의 같은 비율이라는
뜻은 아니다. 단일/공유의 중앙값은 다음과 같다. 구간 중앙값을 합해 전체를 만들지 않는다.

| 유휴 작업 CPU(ms) | 단일 | 공유 2뷰 |
| --- | --- | --- |
| 로컬 포커스 | 0.237 | 0.181 |
| 전면 앱 조회 | 87.580 | 59.279 |
| 전역 입력 소스 | 0.914 | 0.650 |
| 뷰 입력 소스 | 1.623 | 1.225 |
| header 복사 | 0.191 | 0.150 |
| native 문서 상태 | 0.152 | 0.134 |

관측기 자체의 남은 CPU 주원인은 이 조건에서 전면 앱 조회였다. 이를 이유로 포커스 검사를 제거하지
않는다. 무해한 캐싱/사건 기반 확인을 도입하려면 소유권 변화 검출의 검증을 먼저 설계해야 한다.

| 지표, 계측 끔 → 켬 | 단일 | 공유 2뷰 |
| --- | --- | --- |
| 첫 표시 p95(ms), 조건별 90키 | 42.73 → 45.16 | 45.53 → 44.67 |
| 마지막 구문 표시 중앙값(ms), 마지막 키 3개 | 52.54 → 50.93 | 53.31 → 58.01 |
| 유휴 handler CPU 중앙값(ms) | 106.09 → 93.73 | 89.57 → 63.70 |
| 유휴 process CPU 중앙값(ms) | 201.23 → 187.10 | 172.39 → 134.22 |

계측 켬에서 CPU가 낮게 나온 것을 음의 오버헤드로 해석하지 않는다. 공유 handler는 끔에서
69.79/97.72/89.57ms, 켬에서 63.70/108.73/55.31ms로 실행별 편차가 있었다.
각 조건 독립 3프로세스의 비교이며 계측 오버헤드의 안정된 개선량으로 주장하지 않는다.

## 첫 입력에서 실제 겹친 작업

계측 켬의 첫 입력 6개에서 게시→native 도착은 9.32–22.98ms였다.
그 구간과 겹친 여섯 작업의 wall 합계는 0.43–0.77ms, 완전히 들어간 작업의 CPU는
0.28–0.52ms였다. 관측 작업의 CPU가 유휴 handler를 지배한다는 사실로 이 첫 입력 대기를
전부 설명할 수는 없다. native→producing tick은 9.26–17.44ms였고 이 여섯 작업의 겹침은
모든 실행에서 0이었다. 나머지 시간에는 다른 메인 실행과 실제 대기가 모두 있을 수 있다.
경계 CPU 비례 배분, 별개 키의 구간 중앙값 합산, 미귀속 시간을 특정 원인으로 부르는 일을 하지 않는다.

## 입력 중 하이라이트 표시의 별도 문제

사용자가 실측 중 입력마다 구문 하이라이트가 깜빡이는 현상을 보고했다.
이번 360키의 첫 표시에서 구문 준비는 모두 0이었다. 코드상 일반 입력은
`parse/client.refresh` → `discardCompleted`로 provider·색 버퍼를 비우고,
`lineColorsInto`는 provider가 없으면 빈 색을 반환한다. 새 결과 설치 때 다시 색을 만든다.
기존 [비동기 계획](../../docs/plans/editor-async-parse.md#제품-화면-연결)의 명시적 무색 대기 계약이다.

이것은 지연 시각 검증과 별도인 표시 연속성 문제다. 프레임의 준비 비트가 영상/픽셀 검증을 대신하지
않으며, 이번 진단으로 하이라이트 문제가 해결됐다고 주장하지 않는다.
[강조 연속성 설계안](../../docs/plans/editor-highlight-continuity.md)은 마지막 표시 정보만 편집에 맞춰
유지하는 UX 변경을 제안한다. 사용자 확인 전에는 제품 정책을 바꾸지 않는다.

## 증거와 검증

`~/.cache/maru-agent-artifacts/observer-work-build-1`에 불변 앱·소스·receipt,
`observer-work-study-1`에 원시 기록/도구 사본/비교 결과,
`observer-work-review-1`에 실제 자료 손상과 정상 대조를 보관한다.
실제 자료의 중첩·누락·순서·CPU 과대 귀속 등 26개 독립 손상은 모두 거절됐고 정상 대조 27개가 보존됐다.
Swift의 결정적/실제 시계 대조를 포함한 자동 검사 117개와 문서 링크/코드 위치 검사를 통과했다.
전체 `mise run check`와 CI 결과는 이 로컬 결과와 구분한다.
