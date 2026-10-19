# 첫 저장 완료 통지 — 틱 대기 분리 검토

상태: 제품 통지 도입 전의 계측·이벤트 on/off 비교 이력. 현재 제품 통지는 [저장 이벤트 계획](editor-save-event-wake.md)과 머지된 [PR #4530](https://github.com/ohah/maru/pull/4530)이 소유한다.

## 선택 배경과 확인한 문제

첫 저장 비동기화는 기존 Save As actor의 registry lease·대상 예약·epoch·완료 승인·닫기 재검사를 재사용한다. 기존 actor가 AppSession.tick에서 poll되므로 첫 저장도 같은 처리 경계를 사용했다. 이는 수명을 보존하는 이전 단계였으며, 가장 빠른 완료 통지 방식으로 판정한 선택은 아니다.

실제 파일 쓰기는 이미 job별 별도 스레드다. worker가 문서/Term/AppSession을 직접 바꾸지 않고 immutable bytes/path를 쓰며, 메인 actor가 완료를 받아 경로와 도크·백업·언어·LSP 상태를 갱신한다. 추가 스레드나 상주 thread pool을 먼저 도입할 근거는 이번 계측에서 나오지 않았다.

격리 사본에 request, prepare begin/end, worker enter/done, collect, adopt, postprocess, tick begin/end, probe-ready 시각을 남겼다. 64KiB 무지연 3표본 중앙값은 시작 대기 14.453ms·worker 0.257ms·완료 수거 대기 14.899ms였다. 1MiB는 시작 대기 20.411ms·worker 0.327ms·수거 대기 28.631ms·수거 후 반영 10.434ms였다. 이는 실제 구간 차분이며 각 중앙값의 합이 전체 중앙값과 같다고 주장하지 않는다.

## 같은 바이너리에서 바꾼 조건

실험 사본에는 요청 접수와 worker 완료 시 메인 queue에 비동기 callback을 보내는 경로를 넣었다. 환경 플래그로 켜고 끄며 두 표본군의 binary hash가 동일함을 검사했다. 각 조건 3회, Debug·warm cache·짧은 줄 반복 본문이다. 이벤트 on의 모든 표본은 실제 callback 전달 로그도 확인했다. 원본·제품 checkout에는 이 실험 경로를 넣지 않았다.

| 본문 | 주입 | 틱 완료 관측 | 이벤트 완료 관측 |
|---|---:|---:|---:|
| 64KiB | 0ms | 34.793ms | 6.660ms |
| 64KiB | 200ms | 232.230ms | 209.214ms |
| 1MiB | 0ms | 78.859ms | 11.412ms |
| 1MiB | 200ms | 259.406ms | 212.864ms |

이벤트 방식에서도 이름 확정 caller 중앙값은 0.217–0.242ms였다. 결과는 파일 bytes·모델 경로·도크 entry·clean 확인이 성공한 시점의 관측이며, 저장 완료 표시가 화면에 처음 그려진 시각은 아니다. 기존 틱 경로에서는 완료 수거 뒤 같은 tick의 화면 준비가 끝날 때까지 probe가 실행되지 못할 수 있다. 이벤트 실험은 actor만 pump하므로 두 시간을 혼동하지 않는다. 5ms probe 간격도 남아 있다.

원본: `/tmp/maru-first-save-phases-measure/phases.json`, `/tmp/maru-first-save-event-pair-tick`, `/tmp/maru-first-save-event-pair-event`, `/tmp/maru-first-save-event-pair-results.json`. 각 samples.json의 manifest가 로그와 소스·binary·하네스 hash를 가리킨다. 임시 실험 도구는 `/tmp/maru-first-save-phases.py`와 `/tmp/maru-first-save-event-prototype.py`다. 실험 weak C fallback은 독립 ABI 링크용이며 제품 notifier 설계로 채택하지 않는다.

## 실험에서 제안한 제품 연결 범위

렌더 tick을 올리거나 저장용 스레드를 더 만들기 전에 요청/완료 이벤트로 기존 main actor를 깨우는 경계를 검토한다. 완료 판단·신원/epoch·예약·닫기/종료·Undo 계약을 바꾸지 않는다. worker는 완료 슬롯을 release로 게시한 뒤 비차단 통지만 하며, 문서나 창 포인터를 통지 payload로 빌리지 않는다.

메인 actor의 저장 pump와 화면 준비를 구분하고, 알림은 합쳐 처리한다. 이벤트가 없거나 다른 입력·선행 저장을 기다리는 경우 기존 tick은 진행을 위한 fallback으로 남긴다. 이벤트 callback과 tick이 같은 완료를 두 번 소비하지 못하도록 기존 단일 take/ack를 유지한다. 앱/창 종료 이후의 늦은 callback, worker join 중 재진입, 메모리 부족, 여러 창·여러 파일·IME·추가 편집·반복 저장·닫기 대기와 실제 화면 표시 시각을 검증해야 한다.

이번 결과는 이벤트 경로의 실효성을 보여 주지만 제품의 수명·실패 경로를 모두 검증한 결과는 아니다. 메인에서 남은 hash·언어·백업 비용까지 worker 통지만으로 없어지지 않는다.


## 재현 도구

제품 통지가 없던 소스에서 기존 실행기로 준비한 사본을 받아 다시 별도 사본을 만든다. 예를 들어 도입 전 main `f00891e8c`의 첫 저장 하네스에서 준비한다. 현재 메인의 준비 사본은 `wake.zig`가 있어 계측 전에 거절하며, 현재 제품 비교는 `tools/probe-editor-save-wake.py`를 쓴다. 아래 첫 명령은 도입 전 소스 checkout에서, 둘째 명령은 이 PR의 도구로 실행한다. 제품 소스나 원래 측정 사본은 수정하지 않는다.

```sh
python3 tools/editor-project-search-app/run.py --untitled-save-benchmark --untitled-bytes 65536 --count 3 --output /tmp/maru-first-save-base-new
python3 tools/probe-editor-first-save-completion.py --source /tmp/maru-first-save-base-new/source --output /tmp/maru-first-save-completion-new
python3 tools/test-editor-first-save-completion.py
```

출력 디렉터리는 새 경로여야 한다. 도구는 준비 사본을 복사하고 하나의 Debug 앱을 빌드한 뒤 tick/event 각각 크기 2종·지연 2종·3회로 총 24표본을 실행한다. 원래 하네스가 파일과 모델 결과를 검사하며, 추가 판정은 바이너리 동일성·실제 알림 전달·phase의 누락/중복/인과 순서·worker 내 주입 지연을 검사한다. 집계는 `completion-phases.json`이다. 사본 밖을 가리키는 계측 대상 symlink는 쓰기 전에 거절한다.

재사용 도구의 별도 실제 실행도 24표본·8조건 집계를 통과했다. 원본은 `/tmp/maru-first-save-completion-portable/completion-phases.json`이다. 이 실행은 로컬 확대 검사와 동시에 수행했으므로 위 성능 비교표의 표본에 섞지 않고 재현 도구의 실행 검증으로만 사용한다. 판정 단위 검사는 9개이며, 중복 허용·알 수 없는 phase 허용·시계 검사 제거·anchor 검사 제거·사본 탈출 검사 제거가 의미 검사 실패를 일으키는 대조를 실행했다. 정상·복원 대조군은 통과했다.

첫 저장 새 파일 생성의 양성 경로를 측정한 결과다. 덮어쓰기 대상의 분류/hash 등 main에 남은 작업, 실제 저장 표시의 첫 paint, OS IME 입력·종료 수명은 별도로 검증해야 한다. 현재 제품의 통지 경계와 합치기는 저장 이벤트 계획이 소유하며 이 실험의 weak C fallback은 배포 경로로 사용하지 않는다.

최신 메인 리베이스 뒤 판정 검사 10개와 제품 통지 소스 거절을 확인했다. 위 표는 당시 바이너리의 이력이며 현재 메인에서 재측정한 값으로 바꾸지 않았다.
