# 마지막 입력의 워커·뷰 설치·표시 지연

상태: 외부 진단 앱의 단계별 시각을 수집·검증했다. 제품 코드는 바꾸지 않았다. 이 계측 모집단은 일반 입력 성능 비교에 넣지 않는다.

## 결과

5만 개 여러 줄 함수·50ms·30키·비동기·단일/공유 뷰별 3프로세스다. 총 6프로세스·180입력의 문서·입력·Metal 표시가 검증됐고, **각 프로세스의 마지막 입력 1개씩, 6개 입력만 단계별로 귀속**했다. 첫 키나 중간 취소 요청에 이 결과를 일반화하지 않는다.

단위는 ms, 표는 각 뷰의 3프로세스 중앙값이다. 단계별 중앙값은 서로 다른 실행에서 나올 수 있으므로 더해서 전체 중앙값으로 쓰지 않는다. 개별 실행에서는 구간 합계와 전체 경과가 일치한다.

| 구간 | 단일 뷰 | 공유 2뷰 |
| --- | --- | --- |
| 마지막 게시 → 큐 제출 | 2.858 | 4.104 |
| 큐 제출 → 워커 시작 | 0.003 | 0.004 |
| 워커 실행 | 41.447 | 35.298 |
| 워커 종료 → 완료 공개 직전 | 0.0003 | 0.0003 |
| 완료 공개 직전 → runtime 수락 | 0.019 | 0.021 |
| 수락 → 모든 뷰 설치 완료 | 0.063 | 0.135 |
| 모든 뷰 설치 → 구문 준비 프레임 표시 | 33.227 | 22.864 |
| 마지막 게시 → 구문 준비 프레임 표시 | 77.500 | 61.675 |

이 표본에서 워커 실행은 29.31~47.97ms, 마지막 뷰 설치 후 표시는 20.84~40.38ms다. 전달·설치는 짧았다. 표시 구간은 프레임 예약·본문 색/그리기 준비·Metal 제출·표시 대기를 모두 포함한다. GPU 실행 시간이나 특정 timer 비용으로 단정하지 않는다. worker 값도 복사·native 호출·자원 정리·스케줄링을 포함하는 경과시간이며 CPU 시간이 아니다.

다음 조사 지점은 설치 이후의 프레임 준비와 제출·표시 경계다. 워커도 큰 비중을 차지하므로 이 결과만으로 워커 최적화가 불필요하다고 판단하지 않는다. 공유 뷰가 더 빠르다는 일반 결론이나 이전 성능 모집단 대비 개선율도 도출하지 않는다.

## 기록 계약

요청 identity는 owner·slot·document generation·revision·serial을 모두 사용한다. `CACurrentMediaTime` 기반 동일 시계에서 C 기록기가 시각을 찍고, 별도 mutex 안에서 고정 2,048행을 기록한다. 넘치면 자료를 거절한다. 이는 진단 저장소 한도이며 제품의 큐 예산이 아니다. 스레드 ID는 main과 worker 소유 구간 검증에만 사용하고 공개 집계에는 담지 않는다.

| 단계 | 실제 위치 | 의미 |
| --- | --- | --- |
| 1 | `Service.submitImpl`의 waiting.push 직전 | 기준 native 복사 등 제출 전 준비가 끝난 시점 |
| 2/3 | `Job.execute` 진입/모든 defer 종료 | 취소된 작업도 종료·outcome을 기록 |
| 4 | worker 큐 mutex 획득 후 completed/retiring.push 직전 | 수락까지에는 실제 공개와 전달도 포함 |
| 5 | `Runtime.poll`의 gate 수락 후 current 지정 | 현재 요청의 ready 결과만 인정 |
| 6/7 | `view.prepare`의 copyReady 전후 | main의 독립 native 복사 준비 |
| 8 | `Prepared.install`의 캐시 복사 뒤 | 각 뷰 설치의 끝, 대상 포인터로 중복 배제 |

본문 revision은 기존 입력 증명의 baseline revision+30과 일치해야 한다. 단일/공유 뷰 설치 수·서로 다른 대상·스레드·단계 순서·ready outcome·실제 구문 프레임 시각을 함께 검사한다. 존재하지 않는 구간을 0으로 채우지 않는다. 기록 중에는 제품 큐를 기다리거나 파일을 쓰지 않고, Swift 종료 기록에서 한 번 복사한다.

## 재현

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --output <새 외부 빌드 경로> --deps <실제 zig-pkg 경로> --cache <빌드 캐시>
python3 tools/editor-input-stream/parse_stage_study.py --build <고정 빌드 경로> --output <새 외부 수집 경로>
python3 tools/editor-input-stream/parse_stage_report.py <수집 경로> --output <새 외부 보고서 파일>
python3 tools/editor-input-stream/parse_stage_review.py <수집 경로> --output <새 외부 손상 대조 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

실제 실행 전 전면 입력을 위해 사용자와 Mac 조작 중단 시간을 조율한다. collector는 허용 목록 환경·가상 프로필·실행별 cwd를 사용하고 기존 provider 설정과 입력 소스 복원을 검증한다. 새 앱은 접힘 재사용을 켠 진단만 수집한다. `run.trial`은 진단 observer가 없으면 이 빌드를 거절하고 일반 `verify.read`도 parse_stages 빌드를 거절한다.

판정기는 보관 앱/생산자·계측 소스·수집 도구 사본·원시 JSON/로그 해시와 전체 행렬을 검사한다. 반복별 stages.json도 원시 시각에서 다시 계산한다. 불완전한 수집이나 실패 실행은 채택하지 않으며 재실행은 새 외부 경로를 사용한다.

## 검증과 증거

- Python 계약 90개 통과. 단계별 숫자·넘침·서로 다른 요청/문서·스레드·시각 순서·뷰 수·복사/설치 순서·누락된 표시를 검사한다.
- 이번 실제 자료에 독립 손상 24가지를 적용해 모두 거절했다. 정상 대조 25회와 전체 원본 재판정도 유지했다. 원본은 변경하지 않았다.
- 원본: `~/.cache/maru-agent-artifacts/syntax-display-stages-study-1`.
- 고정 빌드: `~/.cache/maru-agent-artifacts/syntax-display-stages-build-1`.
- 손상 대조: `~/.cache/maru-agent-artifacts/syntax-display-stages-review-1`.
- 제품 HEAD: `3c992d23ef3067c55a6ebcaf0b15894a78deb63b`.
- 앱 SHA-256: `f182643a03f5f8bae11854baa37bb3241e5dce3eae5841a3f4ebec821fdfd078`.
- [개별 실행](parse-stage-results.json), [손상 대조](parse-stage-validation.json).

## 한계

계측 호출·시계·별도 mutex 부하가 있다. 프로파일러는 붙이지 않았지만 일반 성능 모집단이나 최적화 전후 대조는 아니다. 한 호스트·Zig fixture·LSP/복원/자동 줄바꿈 끔·접기 실행 없음 조건이며, PID 대상 ASCII 입력과 Metal presentedTime을 검증했다. 물리 HID·IME·광학 표시·CPU 시간·전력 검증은 포함하지 않는다. 실제 뷰 설치 전부를 마지막 프레임과 연결하지만 설치 이후 내부 구간은 아직 분해하지 않았다.
