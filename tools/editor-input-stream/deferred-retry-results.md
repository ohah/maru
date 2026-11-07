# 투영 거절 후 재시도 대조

상태: 진단 후보 구현과 12프로세스·360키 비교 완료. 제품 적용은 보류하며 제품 소스는 변경하지 않는다.

## 비교 조건

같은 실행 파일의 `without_retry`와 `with_retry`를 교대로 실행한다. 두 경로 모두
`frame_wake_control=immediate`로 대상 창 예약과 native 투영 예산을 켠다.
재시도 연결만 `MARU_STREAM_DEFERRED_FRAME_RETRY`로 나누므로, 기존 `scheduled` 비교와
같은 이름이나 모집단으로 해석하지 않는다.

`deferred_retry_control.present`는 유효한 투영 거절의 owner·시각·기한·Hz·실제 모드를 기록한다.
Swift `streamDeferredRetry`는 입력 관측 단계에서 같은 `TargetFrame.request`를 호출한다.
이미 pending이면 합치고, 예약은 기존 deadline 재검사를 거쳐 실행한다. 세션 포인터를
work item에 보관하지 않고 실행 시 살아 있는 대상 창을 다시 찾는 기존 후보 경로를 쓴다.

`retry_*` snapshot은 wall 시각·거절 통지·재시도 요청·오류 순서다. `retry_events`는
owner·거절 시각·기한·Hz·실제 연결 여부 순서다. 모든 거절 기록과 예산 거절을 일대일 대조하고
직전 허용 시각에서 기한을 재계산한다. 요청은 완료 요청과 분리하되 전체 queue 정산과 맞아야 한다.
유휴 요청도 새 거절에서만 인정한다. 거절이 없는 반복 요청을 정상 유휴로 받아들이지 않는다.

## 실행

```sh
python3 tools/editor-input-latency/prepare.py --output <새 외부 빌드> --deps <의존성 경로> --cache <전용 캐시> --stream --fold-reuse-control --parse-stages --display-stages --frame-wake-control --target-frame-control --observer-cpu --deferred-retry-control
python3 tools/editor-input-stream/deferred_retry_study.py --build <빌드> --output <새 외부 자료> --repetitions 3
python3 tools/editor-input-stream/deferred_retry_report.py <자료> --output <새 JSON>
python3 tools/editor-input-stream/frame_tail_report.py <자료> --output <새 JSON>
python3 tools/editor-input-stream/deferred_retry_review.py <자료> --output <새 외부 검증>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

## 검증 범위

자동 검사는 잘못된 모드·시계·기한·owner·Hz·실제 분기·기록 넘침·요청 누락/과다 정산을
거절한다. 실제 C 콜백의 미등록·등록·해제, 거절 직전/기한 경계, 런타임 분기와 overflow를 실행한다.
기존 자료의 무요청 유휴 계약은 유지하며, 새 요청은 원시 거절에 귀속된 경우만 수락한다.

이 계측에는 공통 관측 비용과 호스트 스케줄링이 포함된다. CGEventPostToPid의 ASCII 입력이며
물리 HID·한국어 IME·광학 지연·복수 창/창 닫기 검증은 아니다. 단일 창의 1뷰와 공유 2뷰를 비교한다.


## 실제 표시 결과

빌드의 제품 HEAD는 `b037101a2e40a166793f875d7022d72232f57995`,
앱 SHA-256은 `0f496b053845e13e80dec08bf2aa15caf37bf9538810c116bd04dfa49a43c194`다.
PR의 후속 도구/문서 커밋 HEAD에서 제품을 다시 빌드했다는 의미가 아니다.
ReleaseFast·50,000함수·50ms·조건별 독립 3프로세스·30키이며 모든 첫 입력을 포함한다.
각 쌍은 반복 번호에 따라 순서를 교대했다. 이전 앱의 자료와 합치지 않는다.

| 지표(ms, 재시도 없음 → 연결) | 단일 뷰 | 공유 2뷰 |
| --- | --- | --- |
| 첫 표시 중앙값, 조건별 90키 | 34.09 → 31.80 | 35.93 → 35.45 |
| 첫 표시 p95, 조건별 90키 | 47.31 → 44.39 | 44.63 → 46.19 |
| 마지막 구문 표시 중앙값, 조건별 마지막 입력 3개 | 58.19 → 52.85 | 58.97 → 59.95 |
| 2초 유휴 process CPU 중앙값 | 84.17 → 105.13 | 89.84 → 176.32 |
| 같은 유휴 관측기 thread CPU 중앙값 | 44.74 → 55.00 | 47.45 → 99.88 |
| 나머지 process CPU 중앙값 | 39.43 → 50.13 | 42.39 → 76.44 |

요약은 [값과 실행별 CPU](deferred-retry-results.json), 손상 검증은
[검증 결과](deferred-retry-validation.json)를 따른다. 구간별 중앙값을 더해 전체 지연을 만들지 않는다.

모든 키에서 앱 도착부터 첫 프레임까지의 거절을 찾아 이전 허용·기한·다음 허용에 연결했다.
양쪽 각각 8개 거절 사건에서 기한→다음 허용의 중앙값은 13.18→1.10ms,
범위는 4.16–18.43→0.15–1.34ms였다. 모든 사건에서 직전 프레임은 해당 키 이전 본문이었고
다음 허용이 그 키의 첫 프레임이었다. 양쪽의 동일 키가 일대일로 재현된 사건은 아니므로
이 값만으로 전체 p95 개선량을 추정하지 않는다.

연결 경로의 활성 재시도 요청은 단일 8/21/7건, 공유 6/6/1건이었다.
모두 원시 거절 통지와 맞고, 전체 완료+재시도 요청은 실행/기존 소비/합쳐짐과 정산됐다.
연결 경로의 6개 유휴 구간에서 추가 요청·추가 세션 tick은 0이었다.
재시도 없는 단일 첫 실행에는 유휴 거절 1건이 있었으나 재시도 요청은 0건이었다.

유휴 process CPU는 실행별 변화가 크다. 예를 들어 재시도 없는 단일은 274.86/84.17/83.71ms,
연결한 공유는 176.32/87.46/218.87ms였다. 같은 관측기의 completed call 수는 각 120–121회였다.
유휴 요청이 0이라는 사실은 추가 예약이 없었다는 증거이며 CPU 증가가 없다는 증거는 아니다.
관측기와 나머지 CPU가 함께 늘었으나 호스트 부하·관측 비용·제품의 기여는 분리하지 못했다.

## 판단과 남은 작업

거절 후 deadline 예약 누락은 보완됐고 해당 사건의 대기는 줄었다. 단일 첫 표시 p95도 줄었지만
공유 p95와 유휴 CPU가 같은 방향으로 좋아지지 않았으므로 제품에 후보를 적용하지 않는다.
다음은 유휴에서 매 tick 반복하는 관측기 작업을 분리해 CPU 차이의 재현성을 확인하고,
공유 뷰 첫 표시의 구간별 지연을 별도로 확인하는 작업이다. 이번 자료는 특정 CPU 증가 원인을
확정하거나 이전 실험의 유휴 차이를 소급해 수정하는 근거로 쓰지 않는다.

## 증거 보관과 검증

`~/.cache/maru-agent-artifacts/deferred-retry-build-1`에 불변 앱·계측 소스·빌드 receipt,
`deferred-retry-study-1`에 12개 프로세스의 앱/producer/메타데이터와 도구 사본,
`deferred-retry-tail-1.json`에 모든 키의 첫 표시 구간,
`deferred-retry-review-1`에 실제 자료 손상과 정상 대조를 보관한다.
모든 앱/producer exit는 0이며 소유 PID가 남지 않았음을 확인했다.

실제 자료의 모드·기한·누락/과다 요청·유휴 실행 등 25개 독립 손상은 모두 거절됐고
정상 대조 26개가 보존됐다. 새 자동 검사까지 Python 110개가 통과했다.
앱 번들 빌드, 문서 링크 및 코드 위치 참조 검사도 통과했다.
전체 `mise run check`와 CI 통과를 이 로컬 결과로 대체하지 않는다.
