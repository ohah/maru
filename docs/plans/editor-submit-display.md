# GPU 제출→첫 표시 구간 귀속

상태: 계측 구현·진단 앱 빌드·검사 135개·독립 Metal API 확인·실제 12프로세스/360입력 수집·독립 재계산·실제 자료 손상 대조 완료. 제품 정책은 유지했다.

## 목적과 계약

[입력→첫 표시 진단](editor-current-input-display.md)에서 큰 구간이었던 commit→present를 세 부분으로 나눈다. 제품의 프레임 요청·예약·구문 투영 정책은 유지하고, 외부 빌드 사본에만 `--submit-display`를 적용한다.

`submit_display.c.inc`는 같은 command buffer의 GPUStartTime/GPUEndTime과 같은 drawable의 presentedTime을 기록한다. commit→GPU 시작, GPU 실행, GPU 끝→present의 **개별 행 합**이 기존 commit→present와 같아야 한다. GPU 시작 전 구간에는 제출·스케줄링 등이 섞이므로 순수 큐 대기로 부르지 않는다. GPU 끝 이후도 광학 표시 지연을 뜻하지 않는다.

Apple의 [GPUStartTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime) 계약에 따라 GPU 시각은 completed handler에서 읽는다. [kernelEndTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/kernelendtime)은 CPU 스케줄링 경계다. callback에 진입한 CPU 시각을 GPU 경계로 대신하지 않는다. commit 반환과 GPU 실행, kernel 구간과 GPU 실행의 겹침을 허용한다. kernel 구간이 직렬일 때만 세부 직렬 분할을 제공한다.

행마다 generation·renderer invocation·command buffer·drawable 신원을 확인한다. 완료 뒤 재사용된 객체 주소는 허용하지만 한 행 안에서 다른 객체 callback을 연결하면 거절한다. 모든 callback 완료·넘침 없음·오류 없음·실제 첫 drawable 연결을 확인한다. 새 계측은 main thread에서 GPU 완료를 기다리지 않는다.

## 수집과 판정

동일 고정 앱에서 GPU callback 기록 enabled/disabled를 교대한다. 기존 CPU 구간 계측은 untimed로 고정한다. 두 조건 모두 기본 입력/표시 계측을 포함하므로 무계측 제품 기준선은 아니다. 5만 함수·여러 줄 Zig·50ms·30키·일반/공유 뷰·각 3프로세스로 12프로세스/360키를 수집한다. 실제 조작 중단 확인 뒤 실행하고 첫 예상 밖 실패에서 멈추며 실패 자료를 보존한다.

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --input-display --submit-display --output <새 외부 빌드> --deps <zig-pkg> --cache <외부 캐시>
python3 tools/editor-input-stream/submit_display_study.py --build <고정 빌드> --output <새 외부 수집>
python3 tools/editor-input-stream/submit_display_report.py <수집> --output <새 보고서>
python3 tools/editor-input-stream/submit_display_review.py <수집> --output <새 독립 손상 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

`submit_display_report.py`는 기존 입력 판정과 정확한 행 연결·시계 순서·구간 합을 함께 검사한다. `submit_display_review.py`는 실제 유효 수집이 생긴 뒤 신원·시계·결과·schema 등 24개 독립 손상과 정상 전후/등가 대조를 실행한다. 실제 수집의 손상 24개를 모두 거절하고 정상 전후 대조 48개와 등가 대조 1개를 유지했다.

## 준비 증거와 한계

- 제품 HEAD: `db1153297fdaa8b49bd43efec50bacc0127cd5b1`.
- 고정 빌드: `~/.cache/maru-agent-artifacts/submit-display-build-1`.
- 앱 SHA-256: `e9f7523f42999eb4fe2e0de52e6eb41d3477e4ac25ae6ca76589b00a021ff05d`.
- 독립 Metal probe: `submit_api_probe.m`을 실행한 `~/.cache/maru-agent-artifacts/submit-api-probe-2`. Apple M4 Max에서 4096 byte GPU fill 결과·동일 command buffer callback·API 시각·정상 완료를 확인했다. source/binary/result 해시는 receipt.json에 보존한다. 이 probe의 완료 대기는 독립 실행에만 있고 제품 계측에는 없다.
- 합성 검사는 kernel/GPU 겹침·늦은 callback·객체 주소 재사용을 허용하면서 잘못된 경계·소유권·결과를 거절한다.

독립 probe는 창·drawable·실제 입력·편집기 지연 증거가 아니다. GPU 종료 이후 구간 안의 compositor·표시 예약 원인은 아직 분리하지 않았다. 광학 표시, 물리 키보드, IME·스크롤, 다른 문서 크기는 이 진단 범위 밖이다.

## 실제 편집기 수집 결과

사용자가 조작 중단을 확인한 뒤 `submit-display-study-1`의 12프로세스·360입력을 수집했다. 전면 입력·첫 drawable 연결과 기존 구문 표시 검사를 통과했고 `report.json`과 독립 `recomputed.json`이 같았다. `submit-display-review-1`은 실제 원시 자료의 24개 독립 손상을 거절했다.

GPU 계측 enabled의 각 뷰 90입력 중앙값(ms):

| 구간 | 일반 뷰 | 공유 뷰 |
|---|---:|---:|
| commit→GPU 시작 | 0.517 | 0.519 |
| GPU 실행 | 0.082 | 0.075 |
| GPU 종료→presentedTime | 17.355 | 21.297 |

단계별 중앙값을 더한 전체 지연으로 해석하지 않는다. 각각의 180개 입력에서 GPU 종료 이후 구간이 앞의 두 구간 합보다 컸다. 이 workload의 제출 이후 큰 구간은 GPU 실행 자체가 아니라 GPU 종료 이후에 있었다. compositor·표시 예약·디스플레이 정책 중 어느 것이 원인인지는 이 계측만으로 확정하지 않는다.

kernel 스케줄링 종료와 GPU 시작이 겹친 입력은 일반 6개·공유 8개였다. reader가 직렬 순서를 강제하지 않고 이를 보존했으며 나머지 입력만 직렬 세부 분할에 사용했다.

native→첫 표시 p95는 disabled/enabled가 일반 37.964/38.948ms, 공유 48.328/39.315ms였다. 각 3프로세스 비교의 변동이 있으므로 일정한 계측 비용이나 개선 효과로 판정하지 않는다. 두 조건 모두 기본 계측이 있다. 현재 결과는 예약 정책 변경을 정당화하는 단독 근거가 아니며, 다음 진단은 GPU 종료 이후의 present 예약·표시 cadence와의 관계다.

## 표시 간격과 이전 프레임 겹침 추가 분석

`present_cadence_report.py`는 기존 cohort 전체 판정을 먼저 실행한 뒤 같은 프로세스 안에서 commit 순서로 행을 정렬한다. 앞서 기록된 drawable 중 현재 GPU 종료보다 늦게 표시된 수와 인접 표시 시각 차이를 보존한다. 프로세스 경계의 차이를 만들지 않으며 같은 시각·순서 역전도 숨기지 않는다. 추가 검사 포함 전체 141개가 통과했다.

`submit-display-study-1/presentation-timeline.json`의 terminal drawable은 일반 178개·공유 176개다. 이는 첫 입력 표시 180개의 분포와 다른 모집단이다. 인접 표시 간격 중앙값은 양쪽 26.676334ms이고 순서 역전/동시 표시는 없었다. 입력 전의 drawable과 overlay는 이 타임라인에 없고 제출 자체가 성기므로 실제 주사율이나 놓친 vblank 횟수로 환산하지 않는다.

GPU 종료 시 이전 기록 drawable이 미표시인 경우는 일반 66개·공유 46개였다. 미표시가 없는 일반 112개도 GPU 종료→표시 중앙값 22.103ms, 공유 130개도 19.757ms였다. 관측된 이전 drawable의 잔류만으로 큰 구간 전체를 설명할 수 없다. 이 수를 compositor 내부 큐 깊이로 부르지 않는다. 시작 전 기록되지 않은 작업은 알 수 없다.

소스에서 정상 renderer 경로는 `presentDrawable:`을 호출하며 `atTime:`/`afterMinimumDuration:`을 지정하지 않는다. `MaruAppHost.swift`의 `startFrameLoopTicks`는 설정 Hz의 main RunLoop Timer를 사용한다. terminal/overlay `makeBackingLayer`에는 `displaySyncEnabled`·`presentsWithTransaction`·`maximumDrawableCount` 대입이 없다. Apple은 [displaySyncEnabled](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled)의 기본값을 true, [presentsWithTransaction](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)의 기본값을 false로 정의한다. 이는 문서상 기본값이며 수집 시 runtime 값을 읽어 검증한 증거와 구분한다.

다음 계측은 레이어 runtime 설정과 실제 디스플레이 timing을 같은 시계로 함께 기록해야 한다. 앱 Timer와 표시 주기가 다르다는 이유만으로 GPU 종료 이후 구간의 원인을 확정하거나 display sync를 끄지 않는다. 최적화 비교 전에 display 관측기 자체 비용과 관측 누락·디스플레이 전환을 검증한다.

```sh
python3 tools/editor-input-stream/present_cadence_report.py <기존 유효 수집> --output <새 보고서>
```
