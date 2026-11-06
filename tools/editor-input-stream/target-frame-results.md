# 대상 창의 프레임 요청·기존 예약 합류 대조

상태: 외부 진단 사본의 대조 수집·독립 재계산·실제 자료 손상 검증을 완료했다. 제품 소스는 변경하지 않았다.

## 결과

단일/공유 뷰·경로별 3프로세스, 총 12프로세스·360키다. 첫 표시는 첫 키 포함 90키/조건의
pooled median/nearest-rank p95다. 나머지는 프로세스별 값 3개의 중앙값이며 서로 더하지 않는다.
표는 기존 예약 → 대상 요청+예약 소비+예산 순서다.

| 표시 지표 | 단일 뷰 | 공유 2뷰 |
| --- | --- | --- |
| 첫 표시 중앙값(ms) | 32.09 → 30.14 | 35.59 → 35.00 |
| 첫 표시 p95(ms) | 46.76 → 49.68 | 45.38 → 47.77 |
| 마지막 게시 → 구문 표시 중앙값(ms) | 66.63 → 47.81 | 62.27 → 55.17 |
| 설치 → tick 진입 대기 중앙값(ms) | 10.05 → 0.06 | 2.78 → 0.06 |
| 다음 키 전 구문 표시(각 87구간) | 3/87 → 37/87 | 10/87 → 11/87 |

| 입력 구간 비용(프로세스별 중앙값) | 단일 뷰 | 공유 2뷰 |
| --- | --- | --- |
| process user+system CPU(ms) | 1169.03 → 1162.91 | 1285.05 → 1276.35 |
| CPU 비율(1코어=100%, %) | 56.20 → 56.46 | 61.78 → 61.30 |
| host tick | 124 → 124 | 124 → 125 |
| 대상 세션 tick | 124 → 150 | 124 → 150 |
| draw 호출 | 62 → 62 | 61 → 62 |
| 허용 투영 | 62 → 62 | 61 → 62 |

입력 구간의 CPU에는 첫 게시 전 producer 대기와 진단 드라이버 비용이 포함되며 벽시계 구간은
약 2.06~2.10초였다. CPU 비율은 각 프로세스의 비율을 계산한 뒤 중앙값을 구한다.
후보의 179개 요청 중 23개는 기존 렌더 경로가 새 Metal 세대를 만든 뒤 소비했고, 156개는
추가 대상 세션 tick으로 처리했다. 같은 pending 요청끼리 합침과 deadline 재무장은 이번
표본에서는 발생하지 않았다. 그 계수 정산과 간격 경계는 별도 합성/native 대조로 검사했다.

후보의 모든 허용 투영 시작 간격은 60Hz 예산 이상이었다(관측 최소 16.711ms).
이는 투영 시작 간격의 검사이며 OS 표시 FPS의 절대 상한 증명은 아니다. 두 경로 모두 같은
generation 반복 draw는 0건이었다. 후보의 투영 제한 거절은 입력 중 39회, 유휴 중 1회였다.
거절된 투영의 dirty는 보존됐고 최종 문서/색/표시는 모두 완료됐다.

2초 유휴의 추가 요청·실행·합침과 추가 대상 세션 tick은 모두 0건이었다. 기존 host/session tick은
약 60Hz로 계속됐다. 유휴 CPU 중앙값은 단일 190.74→170.81ms, 공유 171.33→211.99ms였고,
유휴 draw는 단일 5→5회, 공유 5→6회였다. 진단 드라이버의 반복 확인도 포함하므로 제품의
일반 idle CPU나 전력으로 해석하지 않는다. 공유 뷰의 유휴 CPU 증가 원인은 이 자료로 확정하지 않는다.

## 판정

구문 표시 중앙값과 투영 수 측면에서는 개선 후보로 남긴다. 다만 첫 표시 p95가 양쪽 모두
늘었고 유휴 CPU가 높은 공유 표본도 있어 **제품 전환은 아직 확정하지 않는다**. 작은 표본의
통계적 유의성이나 일반적인 회귀/개선율을 주장하지 않는다. 추가 session tick은 남아 있고
구조 변경들의 개별 효과도 분리하지 않았다. 다음 검증은 첫 표시 상위 지연과 유휴 CPU 차이의
재현·귀속이며, 이번 결과를 이전 전역 tick 모집단과 합쳐 비교하지 않는다.

## 계약과 범위

같은 앱에서 기존 예약과 대상 창 요청+투영 예산을 대조한다. 기존 전역 타이머는 유지하며
추가 요청은 전역 `tickAppSession`을 호출하지 않고 해당 surface의 `renderTick`을 사용한다.
이 호출도 해당 Zig AppSession의 tick을 포함한다. 순수 GPU 호출이나 다른 세션 작업을 모두
생략한 전용 렌더 함수라고 표현하지 않는다.

새 결과가 실제 설치된 창마다 한 번 요청한다. 같은 창의 pending 요청은 합치고, 기존
`renderTick`이 새 Metal 세대를 생성하면 대기 항목을 취소·소비한다. 진입만으로 소비하면
예산 제한으로 프레임을 못 만든 경우 요청을 잃으므로 생성 이후에만 소비한다.
추가 콜백은 단조 증가 surface token과 ticket을 다시 검사하고 살아 있는 창/세션을 조회한다.
대상이 없어지거나 숨겨지면 실행하지 않고 자료에 남긴다.

후보에서는 해당 세션의 전체/부분 투영 사이 간격을 설정된 예산으로 제한한다. 단일 창·60Hz
실험이며 간격 하한은 `ceil(1e9/hz)` 나노초다. 입력·PTY/lifecycle 처리는 기존 tick 안에서 계속 실행하고
투영만 보류한다. denied projection은 기존 dirty를 다음 기회까지 유지한다. C의 16개 owner와
4,096개 기록은 이 단일 앱 진단의 상한이며 제품 저장소 정책이 아니다. 넘침/시계 역행/잘못된
Hz는 수집 오류로 거절한다. 후보의 모든 허용 투영 간격을 원시 기록에서 다시 확인한다.

대상 호출·예약 소비·투영 예산을 함께 바꾼 후보다. 각각의 효과를 단독 원인으로 분리하지
않는다. 이전의 전역 tick 대조와도 앱/HEAD가 다른 별도 모집단으로 보관한다.

## 재현

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --frame-wake-control --target-frame-control --output <새 외부 빌드 경로> --deps <실제 zig-pkg 경로> --cache <빌드 캐시>
python3 tools/editor-input-stream/frame_wake_study.py --build <고정 빌드 경로> --output <새 외부 수집 경로>
python3 tools/editor-input-stream/frame_wake_report.py <수집 경로> --output <새 외부 보고서 파일>
python3 tools/editor-input-stream/target_frame_review.py <수집 경로> --output <새 외부 손상 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

실제 전면 입력 전에 Mac 조작 중단 시간을 사용자와 조율한다. 가상 profile·cwd·허용 목록 환경과 기존 입력/문서/Metal 판정을 유지한다.

## 한계

제품 코드는 변경하지 않는다. 한 창의 단일/공유 2뷰·5만 함수·50ms·각 3반복으로 12프로세스의
360입력을 검증하고 마지막 입력 12개만 단계별 귀속한다. 실제 다중 창·닫기·IME·물리 HID·광학
표시·에너지 검증은 포함하지 않는다. 토큰/ticket과 대상 재조회는 진단 코드의 안전장치이며
해당 제품 시나리오까지 검증됐다고 주장하지 않는다. CPU에는 진단 드라이버 비용이 포함된다.

## 검증과 증거

- 자동 검사 102개 통과. 실제 C 코드에서 60/120Hz 간격 경계·owner 독립·잘못된 Hz/owner·시계 역행·정수/기록 한도와 선택 callback 등록/해제를 검사했다.
- 실제 자료 손상 28가지를 거절하고 정상 대조 29회 및 전체 원본 재판정을 유지했다.
- 라벨·snapshot·pending/dropped·예산 오류·행/owner/Hz·interval 정산·유휴 재무장·잘못된 숫자를 검사했다.
- source 변환은 요청 소비가 실제 native tick 및 새 Metal 세대 생성 뒤인지 고정한다. 해당 위치의 모호한 anchor는 거절한다.
- 최종 앱은 소비 위치를 보완한 build-3이며 build-1의 미측정 프로토타입과 build-2의 변환 실패는 수집에 사용하지 않았다.
- 기존 전역 wake 대조도 새 reader로 다시 읽어 통과했다.
- 제품 HEAD: `8f3d284f973e7981c9fce520ceb71111cf7d148d`.
- 앱 SHA-256: `22d4f4dc5cc24a71e183d3eb1546b635d3f18b20653d6c157b10eed52fb8d1ee`.
- 고정 빌드: `~/.cache/maru-agent-artifacts/target-frame-control-build-3`.
- 원본: `~/.cache/maru-agent-artifacts/target-frame-study-1`.
- 손상 대조: `~/.cache/maru-agent-artifacts/target-frame-review-1`.
- [개별 실행·CPU·프레임·메모리·reader 해시](target-frame-results.json), [독립 손상 판정](target-frame-validation.json).
