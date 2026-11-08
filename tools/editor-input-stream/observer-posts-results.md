# 완료 JSON 관측 비용 분리

상태: 동일 앱의 네 조건 24프로세스·720키 비교와 실제 자료 손상 검증 완료. 제품은 변경하지 않는다.

## 실험 설계

같은 실행 파일에서 완료 JSON 처리 방식(`repeated_posts`·`cached_posts`)과 거절 재시도
(`without_retry`·`with_retry`)를 교차한다. 두 진단 축과 단일/공유 2뷰, 독립 3프로세스의
24개 실행·720키를 수집한다. 각 조건은 50,000함수·50ms·30키를 유지한다.
같은 flow/repetition의 네 실행을 교대로 배치하고 순서를 원문에 보관한다. 각 조건 3표본이므로
모든 순서 효과를 제거한 것으로 해석하지 않는다.

모든 실행은 같은 대상 창 예약과 60Hz native 예산을 켠다. 캐시 경로는 producer의 atomic 완료
파일을 처음 정상 파싱한 뒤 그대로 재사용한다. 매번 하던 포커스·입력 소스·문서 대상·표시 완료
검사는 계속 수행한다. 읽기 실패·잘못된 JSON은 재시도하며, producer 오류는 성공으로 저장하지 않는다.

producer는 마지막 입력 뒤 완료 파일을 한 번 게시한다. 따라서 이 재사용의 주된 개입 구간은
완료 이후 유휴이며, 초기 입력의 차이를 JSON 캐시 효과로 귀속하지 않는다. 첫 키를 포함한
전체 첫 표시 p95와 마지막 구문 표시도 계속 기록한다.

## 신원과 CPU 정산

`observer_posts.swift.inc`의 `ObserverPosts.complete`는 검사·읽기 시도·성공한 읽기·파싱·재사용과
해당 함수의 thread CPU를 센다. 반복 경로의 최초 원문 동일성 대조도 이 작업 CPU에 포함된다. `posts_*` snapshot은 시각·검사·시도·읽기·파싱·재사용·CPU·오류 순서다.
매 구간에서 `검사 = 시도 + 재사용`, `파싱 ≤ 읽기 ≤ 시도`를 검사하고 handler 호출 수와도 맞춘다.
작업 CPU가 handler CPU를 넘으면 거절한다. 관측기 handler CPU와 process CPU는 기존 계측을 유지한다.

정상 파싱에서 받아들인 원문을 base64로 남기고 실제 producer 파일 SHA-256과 대조한다.
앱 종료 때 파일 원문을 다시 읽어 최초 데이터와 달라졌으면 오류로 기록한다. 외부 파일을 악의적으로
바꿨다가 원상 복구한 모든 중간 상태를 탐지한다는 계약은 아니며, producer의 단일 atomic 게시와
격리된 실행 디렉터리를 전제로 한다.

## 실행

```sh
python3 tools/editor-input-latency/prepare.py --output <새 외부 빌드> --deps <의존성 경로> --cache <전용 캐시> --stream --fold-reuse-control --parse-stages --display-stages --frame-wake-control --target-frame-control --observer-cpu --deferred-retry-control --observer-posts-control
python3 tools/editor-input-stream/observer_posts_study.py --build <빌드> --output <새 외부 자료>
python3 tools/editor-input-stream/observer_posts_report.py <자료> --output <새 JSON>
python3 tools/editor-input-stream/frame_tail_report.py <자료> --output <새 JSON>
python3 tools/editor-input-stream/observer_posts_review.py <자료> --output <새 외부 검증>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

## 검증과 한계

실제 Swift 헬퍼를 컴파일해 파일 없음·잘못된 JSON·producer 오류에서 성공을 캐시하지 않는지,
정상 재사용과 종료 시 원본 교체 검출을 검사한다. 이 헬퍼 검증은 macOS 전용이며 다른 플랫폼에서는
QuartzCore 검사를 skip한다. Python 순수 판정자는 플랫폼과 무관하다.

관측 JSON 함수의 CPU 감소가 process 전체 CPU 감소와 같은 것은 아니다. 다른 계측·호스트 부하·
worker와 UI 작업이 나머지 process에 포함된다. 새 앱의 자료를 이전 실험과 한 분포로 합치지 않는다.
단일 창 1뷰/공유 2뷰의 CGEventPostToPid ASCII 진단이며 물리 HID·한국어 IME·광학 지연·복수 창 검증은 아니다.


## 실측 결과

계측 빌드의 제품 HEAD는 `975bf56b792c7baf869eaf3bee0174ecadd9a33b`,
앱 SHA-256은 `727d95c2f02f629d3d87801223971486acc84dbc11118a484606d6c83ad49f87`다.
PR의 도구/문서 커밋 HEAD에서 제품을 다시 빌드했다는 뜻은 아니다.
모든 앱/producer exit가 0이고 입력·본문·포커스·소스 복원 검증을 통과했다. 종료 뒤 남은 소유 PID는 없었다.

아래는 조건별 독립 3프로세스의 유휴 CPU 중앙값이다. 유휴 wall 구간은 2.000–2.019초다.
`완료 JSON 작업`은 읽기·파싱·원문 대조 또는 재사용 호출을 포함하며 순수 파싱 시간만은 아니다.

| 조건 | 완료 JSON 작업 CPU(ms), 반복 → 재사용 | 관측기 handler CPU(ms) | process CPU(ms) |
| --- | --- | --- | --- |
| 단일·재시도 없음 | 29.74 → 0.10 | 142.21 → 97.69 | 237.49 → 183.84 |
| 공유·재시도 없음 | 28.90 → 0.09 | 140.02 → 97.64 | 232.97 → 189.85 |
| 단일·재시도 연결 | 25.80 → 0.10 | 122.17 → 98.11 | 213.48 → 181.20 |
| 공유·재시도 연결 | 27.73 → 0.11 | 125.39 → 109.94 | 208.97 → 198.26 |

모든 재사용 유휴 구간은 파일 읽기·파싱 0회, 재사용 119–121회였다. 반복 구간은 119–121회 읽고
같은 횟수로 파싱했다. 반복 JSON 작업은 해당 실행 handler CPU의 19.34–26.42%, process CPU의
12.07–14.56%였다. 반복 작업 자체의 비용과 재사용에 의한 감소는 확인했다.

같은 flow/repetition끼리 process CPU를 비교하면 12쌍 중 10쌍에서 줄었고 2쌍에서는 늘었다.
재시도 없는 단일의 재사용−반복 차이는 −53.65/−91.94/+5.81ms,
재시도 없는 공유는 −84.20/+69.37/−27.78ms였다. JSON 외 handler와 나머지 process CPU도
실행마다 크게 달랐다. 이 변동을 재시도 비용으로 확정하거나 전체 CPU 차이를 JSON만으로
설명하지 않는다. 각 구간의 중앙값을 더해 다른 중앙값을 구성하지 않는다.

[실행별 수치와 공유 상위 입력](observer-posts-results.json)에 모든 CPU 값과 구간을 기록했다.

## 첫 표시와 공유 지연

첫 키를 포함한 조건별 90키의 p95다. 재시도 없음→연결을 관측 방식별로 비교한다.

| 관측 방식 | 단일 첫 표시 p95(ms) | 공유 첫 표시 p95(ms) |
| --- | --- | --- |
| 매번 읽기 | 44.85 → 45.55 | 41.20 → 43.49 |
| 완료 후 재사용 | 46.75 → 43.50 | 46.64 → 44.85 |

재시도에 따른 방향이 두 관측 방식에서 갈린다. 특히 재사용은 producer 완료 이후에 시작하므로
이 표의 초기 입력 차이를 캐시의 직접 효과로 해석하지 않는다. 제품 후보 적용은 계속 보류한다.

공유 조건의 가장 느린 5개 입력씩을 동일 producing frame/drawable에 연결했다. 재시도 연결
두 조건의 상위 10개에는 투영 거절이 없었다. 그 중 6개는 첫 입력이며, 해당 키의 게시→native
도착은 12.41–18.30ms였다. 전체 상위 10개에서 native→producing tick은 11.39–17.89ms,
투영은 1.78–2.93ms, commit 직전→실제 표시는 14.95–27.10ms였다. 개별 키의 구간 합계는
그 키 전체 시간과 같다. 서로 다른 키의 구간 중앙값을 더하지 않는다.

이 자료에서 투영 계산이 상위 지연의 가장 큰 구간은 아니었다. 거절이 없는 키의 지연을
거절 대기만으로 설명할 수 없지만, 다른 입력의 완료 후 예약이 메인 큐에 준 간접 영향까지
없다고 증명한 것은 아니다. 메인 실행/대기와 표시 동기화의 책임을 더 분리해야 한다.

## 유휴 재시도와 후속

24개 유휴 구간 중 재시도 연결 실행 3개에 새 거절에서 비롯된 요청·추가 세션 tick이 각각
1건 있었다(재사용 단일 rep 2, 반복 공유 rep 1/2). 나머지 구간은 0건이었다. 모든 요청은 거절 원시
기록과 기한·큐 정산에 맞았다. 이는 2초 구간의 관측이며 긴 유휴에서 반복이 없다는 증명은 아니다.

다음은 포커스/입력 소스/문서 확인 등 남은 handler CPU를 작업별로 계측하고, 첫 입력의
게시→native와 native→tick 대기를 분리하는 것이다. 안전 검사를 제거하거나 초기 입력을
공식 지표에서 빼서 숫자를 개선하지 않는다. 이번에는 진단 도구와 결과만 반영한다.

## 증거와 검증 결과

`~/.cache/maru-agent-artifacts/observer-posts-build-1`에 불변 앱·소스·receipt,
`observer-posts-study-1`에 24개 실행과 producer 원문/소스 복원·도구 사본,
`observer-posts-tail-1.json`에 모든 키의 첫 표시 구간,
`observer-posts-review-1`에 실제 손상 원문과 대조 결과를 보관한다.

실제 자료의 모드·신원·작업 수·숨은 재읽기·CPU 과대 귀속 등 25개 독립 손상은 모두 거절됐고
정상 대조 26개가 보존됐다([검증 결과](observer-posts-validation.json)).
Swift 실제 파일 헬퍼를 포함한 자동 검사 113개, 앱 번들 빌드, 문서 링크/코드 위치 검사도 통과했다.
기존 360키 자료 재계산도 유지된다. 이 로컬 결과를 전체 `mise run check` 또는 CI 통과로 부르지 않는다.
