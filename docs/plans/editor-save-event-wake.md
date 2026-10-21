# 로컬 저장의 메인 큐 완료 통지

상태: 제품 연결 구현. 저장 요청/완료의 프레임 대기를 줄이는 단계이며 렌더러 스레드 이관은 아니다.

## 소유권과 실행

기존 로컬 저장 큐와 Save As actor가 문서 lease·epoch·목적지 예약·완료 승인·Undo와 닫기 판단을 계속 소유한다. 실제 쓰기는 기존 job별 worker가 한다. worker는 완료 슬롯을 release로 게시한 뒤 비차단 통지를 보내며 메인 실행을 기다리지 않는다. 메인은 acquire 뒤 기존 take/join/ack로 결과를 한 번 소비한다.

`editor/save/wake.zig`는 앱 전역 통지를 atomic flag로 합친다. 콜백은 문서·창·job 포인터를 payload로 빌리지 않는다. Apple Dispatch main queue에서 현재 저장 actor를 다시 조회하고 실행하며 전체 `AppSession.tick`이나 렌더링을 호출하지 않는다. 처리 전에 flag를 내려 처리 도중 게시된 후속 작업도 다음 turn을 예약할 수 있다. 기존 actor별 처리량 제한을 유지하며 메인 큐를 빌 때까지 무한 drain하지 않는다.

네이티브 호출은 `main_queue.c.inc`의 `dispatch_async_f(dispatch_get_main_queue(), NULL, callback)` 어댑터가 소유한다. 기존 제품/ABI 네이티브 브리지 archive에 `coretext_smoke.m`의 include로 포함되지만 CoreText 처리나 Swift ABI를 변경하지 않는다. 새 런타임 의존성은 없다. 설계 근거는 Apple Dispatch의 [main queue](https://developer.apple.com/documentation/dispatch/dispatch_get_main_queue)와 [비동기 제출 계약](https://developer.apple.com/documentation/dispatch/dispatch_async_f)이며 Ghostty 코드 표현을 옮기지 않는다.

## 깨우는 조건과 안전망

- 일반 저장 접수, Save As 패널 응답, 이름 없는 문서 첫 저장 접수.
- worker 완료, 저장 결과 정산과 다음 저장으로 인계. worker를 만들기 전에 거절/실패한 결과도 다음 turn에서 정산한다.
- IME 입력 트랜잭션 종료와 보류 확정 재시도, 저장 code action/포맷 단계 종료.
- 큐에 들어가기 전에 입력 종료를 기다리는 닫기 저장도 재개 대상으로 본다.

저장이 없으면 입력/포맷 종료 훅은 통지를 만들지 않는다. IME·선행 저장·포맷 등 조건이 풀리지 않았다는 이유만으로 재예약하지 않는다. 모달 해제·앱/창 종료 등 아직 개별 이벤트로 완전히 분리하지 않은 조건은 기존 틱이 진행을 보장한다. 따라서 이번 단계는 틱 제거가 아니다. 렌더링·백업·LSP의 틱 처리 정책도 바꾸지 않는다.

## 검증

`mise exec -- zig build test-editor-save-wake`는 frame tick과 actor 직접 poll 없이 제품 콜백 drain으로 접수/완료·IME 재개·추가 입력/반복 저장·외부 충돌/대상 세대·모든 창 해제 후 늦은 알림·IME 종료 뒤 닫기·worker 없는 시작 전 거절을 검사한다. 기존 첫 저장·Save As·닫기 저장 회귀도 함께 실행한다. 헤드리스 IME 상태 전환은 실제 OS 입력기 화면 검증을 대신하지 않는다.

`python3 tools/test-editor-save-wake-native.py`는 실제 main run loop에서 제품 C 어댑터의 비동기 제출, 메인 스레드 실행, 콜백 안에서 게시 worker join, 1,000개 전달을 검사한다. `dispatch_main()`이 호출 스레드를 끝낼 수 있는 CLI 모델 대신 앱과 같은 main run loop를 쓴다.

`python3 tools/test-editor-save-wake-adversarial.py`는 별도 사본에서 접수 알림 누락·완료 알림 누락·IME 재개 누락·처리 중 재예약 유실·저장 없는 입력의 불필요 재예약·worker 없는 실패의 정산 누락을 의미 실패로 검사하고 정상/복원 대조군을 실행한다.

## 성능과 남은 범위

기존 계측 PR #4525의 이벤트 실험 수치는 제품의 최종 성능 보장이 아니다. 이번 제품 바이너리로 첫 저장의 호출·다음 메인 이벤트·모델 완료 관측을 다시 잰다. 화면의 첫 완료 표시 시각, 큰 덮어쓰기 대상의 분류/hash, 백업 정리·syntax/LSP 후처리 비용은 별도다. 여러 앱이 빌드/테스트 중인 표본은 통제된 전후 성능 비교로 사용하지 않는다.

후속 [백업 동기 호출 실측](editor-backup-main-latency.md)은 실제 백업 쓰기 비용을 먼저 측정한 뒤 worker 분리 여부를 판단한다.


재현 가능한 제품 비교는 `python3 tools/probe-editor-save-wake.py --source <첫 저장 하네스의 준비 source> --output <저장소 밖 새 경로>`다. 도구는 사본에서만 통지 차단과 전달 로그를 넣고 같은 Debug 바이너리로 24표본을 순서를 교차해 실행한다. 이미 이 도구가 빌드한 source는 `--reuse-prepared`로 신원을 대조해 재사용할 수 있다. 통지 on에서도 안전망이 먼저 결과를 처리할 수 있으므로 callback이 반드시 두 번이라는 조건을 강제하지 않는다. on은 실제 통지 한 번 이상, off는 0번을 요구하고 전달 횟수를 보존한다. 이는 이벤트 활성화 효과의 비교이며 각 결과가 event에서만 수거됐다는 증거가 아니다. `test-editor-save-wake-probe.py`는 유효한 한 번 전달과 조건/바이너리/빌드가 섞인 표본 거절을 검사한다.


추가 경합 검증은 `python3 tools/test-editor-save-wake-extra.py`로 재현한다. 두 창의 첫 저장, 32개 연속 편집/저장, 한 창의 IME 대기와 다른 창의 닫기, 실패 뒤 정상 재저장, 처리 중 강제 재진입을 별도 사본에서 검사한다. 첫 창에만 작업을 허용하기·대기 중 후속 요청 버리기·IME 창에서 다른 창 진행도 멈추기·실패로 저장 기준값 오염시키기·재진입 방어 제거의 변이가 실제 검사를 실패시키는지 대조한다. 강제 재진입은 사본에만 둔 호출 훅으로 기존 제품 방어 분기를 실행하는 헤드리스 검증이며 실제 AppKit 중첩 런루프를 재현했다는 뜻은 아니다. 원본의 저장 코드와 공개 API는 바꾸지 않는다.
