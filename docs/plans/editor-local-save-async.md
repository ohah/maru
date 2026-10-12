# 로컬 저장 worker와 비동기 연결

## 범위와 상태

- worker 기반: 구현. 이름 있는 로컬 저장의 독립 bytes/path, 전용 I/O executor, 선할당 완료 슬롯, join 수명을 제공한다.
- 요청 큐와 완료 승인 기반: 구현. 한 큐의 FIFO 실행·동일 요청 합류·성공 기준 인계·caller 예산·stale 대상 거부를 제공한다.
- 사용자 저장·배치 UI 연결: 미착수. 아래 제안 정책을 논의하고 coordinator와 함께 연결한다.
- 저장 응답 지연 개선: 아직 측정하지 않았다. 기존 호출은 계속 동기다.

## 기반의 책임

`editor/save/worker.zig::Service`는 동시에 하나의 `Prepared`만 실행한다. 자료와 완료 슬롯을 먼저 확보하고 성공할 때만 소유권을 가져간다.
worker는 문서·선택·Undo·AppSession 값을 역참조하지 않고 전용 `std.Io.Threaded`로 기존 CAS writer를 실행한다.
쓰기 가능 단계 판정은 L2 `save_ops.writable`를 동기 저장과 공유한다. actor는 atomic acquire 뒤 `take`로 성공/실패와 실제 저장 자료를 한 번 받는다. 완료 전달은 할당하지 않는다.
`deinit`는 시작된 쓰기를 join한 뒤 자원을 해제한다. 취소나 이미 반영된 쓰기의 rollback이 아니다.
worker 기반은 제품 큐·실패 안내·종료 정책을 결정하지 않는다. 파일시스템 I/O가 끝나지 않으면 join도 끝나지 않을 수 있어, 서비스 destructor를 main UI의 종료 대기 구현으로 사용하지 않는다. 성공 결과를 버리면 disk 상태는 이미 바뀌었으므로 실제 caller는 완료를 처리한 뒤 정리한다.

## UI 연결 제안 — 아직 미승인

1. 수동 저장은 기존 code action→format·IME 확정 경계를 통과한 시점의 본문을 고정한다. 배치는 함께 반영한 본문을 고정한다.
   실행 직전 최신 본문으로 바꾸지 않는다. 동일 본문의 중복 요청만 합류시키고 다른 본문 요청은 순서를 유지한다.
2. 성공한 A의 raw disk hash를 뒤의 B에 인계한다. 실패한 A 뒤에는 외부 hash를 채택하지 않는다.
3. 저장 중 본문 편집·Undo는 허용한다. 성공 완료는 실제 저장한 logical content로 clean/dirty·백업을 판정하고 실제 저장 본문을 didSave에 전달한다.
4. 실행 중인 문서의 Save As·앱 내부 rename/삭제·대상 root 이동은 완료 후로 미룬다. 외부 변경을 막을 수 있다는 보장은 하지 않는다.
5. 문서 닫기·앱 종료는 저장 완료를 기다린 뒤 기존 dirty/백업/저장 실패 판단을 다시 한다. 실패 문서를 자동으로 닫지 않는다.
   main UI를 join으로 막지 않고 완료 pump를 계속 돌린다. 강제 종료/전원 손실은 별도 백업 계약이며 drain 보장이 아니다.
6. batch 결과는 저장 중/성공/실패를 구분하고 검색 결과를 닫아도 문서 저장은 계속 소유한다. 실패 후 재시도는 현재 본문을 새 요청으로 저장한다.
7. 전역 writer는 우선 하나를 사용한다. 대기 요청 수와 snapshot bytes 예산은 실제 준비/병렬 부하 측정 뒤 결정한다.
   메모리 한도를 넘었다고 성공으로 응답하거나 요청을 조용히 버리지 않는다. 가득 찼을 때의 UX는 예산과 함께 논의한다.
8. watcher는 완료된 own-write와 raw hash를 대조한다. 진행 중 모든 이벤트를 무시하지 않고 새 외부 내용은 충돌로 보존한다.

현재 서비스는 하나의 실행 자리만 제공하므로 위 큐 정책의 구현 증거가 아니다. 물리 대상 별칭·rename commit·종료 pump·batch result·watcher까지 연결한 뒤 실제 제품 실측을 반복한다.

## 검증 계획

worker의 실제 파일 쓰기와 오류 보존, 차단된 worker 동안 caller의 재편집, 준비/완료 수명과 join, 두 번 완료 소비 방지,
준비 실패·실행 자리 충돌의 소유권 보존, 실행 중 외부 수정 CAS 거부를 실행한다.
제품 연결은 실제 main queue 지연·원문 바이트 대조와 별도의 경합 판정자를 추가한다.

`tools/test-editor-local-save-worker-adversarial.py`는 정상/복원 대조군과 함께 조기 완료 게시·저장 오류 유실·logical/raw 혼동·완료 자료 재시작·다른 대상 완료의 다섯 결함을 격리 소스에 넣는다. 실제 테스트 단언 실패를 요구하며 컴파일 실패를 검출로 세지 않는다. 이는 writer 기반 검증이며 coordinator·제품 UI 경합 전체를 검증했다는 뜻은 아니다.

## 요청 큐와 완료 승인 기반

`editor/save/queue.zig::Queue`는 actor가 준비한 요청을 FIFO로 소유한다. 대상은 L2 `save_ops.Target`의 문서 신원·경로·actor 발급 epoch다. 같은 문서의 가장 최근 요청에서만 실제 raw bytes와 준비 기준을 대조해 합류한다. A→B→A는 세 번의 요청이며 맨 뒤 A를 맨 앞 A에 합치지 않는다. 중간 요청의 path/epoch가 달라도 같은 문서면 순서 장벽이며 오래된 요청을 건너뛰어 합류시키지 않는다. 다른 문서가 끼어 있어도 그 문서의 기준은 섞이지 않는다.

`startNext`는 actor가 현재 살아 있는 대상을 찾아 제공한 Target과 대조한 뒤 worker를 시작한다. target epoch와 slot generation은 서로 다른 축이다. 큐 자체는 편집기의 경로 세대를 발급하거나 rename을 막지 않는다. 사라진 대상은 `rejectNext`로 디스크를 쓰지 않은 StaleTarget 결과를 만들어 같은 완료 통로에서 소비한다.

`poll` 결과는 actor의 `ack`까지 큐가 소유하고 request/bytes 예산도 유지한다. `Queue.apply`가 현재 Target/epoch를 재확인한 뒤 실제 `Prepared.finish`를 반영한 성공만 `ack(true)`로 승인한다. 실패나 무효 완료는 `ack(false)`다. 승인한 성공의 raw hash는 같은 문서·경로·epoch이고 같은 이전 disk 기준을 가진 대기 요청에만 인계한다. 실패한 쓰기나 이미 다른 기준을 가진 요청에는 기준을 덮어씌우지 않는다.

`Limits`는 caller가 정한다. 제품 기본 숫자·한도 초과 UX는 이 PR이 결정하지 않는다. bytes 비용은 큐가 소유하는 raw bytes와 path의 길이이며 실행 중/완료 보관 중 자료도 포함한다. 큐 메타데이터 capacity·스레드 stack·I/O executor·caller의 아직 제출하지 않은 자료까지 합친 RSS 상한이 아니다. OOM/QueueFull/TooLarge/ID 고갈은 자료를 소비하지 않는다. 같은 요청의 합류는 새 비용을 더하지 않는다. snapshot은 큐와 같은 allocator로 준비해야 한다.

LSAVEQ1~6은 실제 worker의 성공→후속 CAS(BOM 포함), 실패 뒤 기준 보존, A→B→A 순서, 완료 보관 비용, 등록/worker 시작 OOM·예산/ID 실패 소유권, epoch와 실제 닫기/slot 재사용 거부, 다른 문서의 독립 성공을 검사한다. 사용자 ⌘S·닫기·watcher·배치 UI 경합이나 전체 응답 지연 개선을 완료한 증거는 아니다.

추가 실행 검증에서 다른 epoch의 요청을 건너뛰어 오래된 요청에 합류하는 결함을 재현했고, `sameDocument`로 가장 최근 문서 요청을 찾는 순서 장벽으로 수정했다. 완료의 `apply`도 현재 Target을 다시 대조하며 중복 apply가 성공 플래그를 지우지 않는다. 제출 시점의 확인만으로 완료를 반영하지 않는다.

쓰기 시작 전 슬롯 재사용뿐 아니라 실행 중 문서를 강제로 닫고 같은 슬롯의 새 문서를 만든 경우도 검사한다. 이미 시작된 디스크 쓰기는 끝날 수 있지만, 완료는 새 문서의 본문·disk 기준·clean 상태를 바꾸지 않는다. 이것이 제품의 닫기 대기 UX를 구현했다는 뜻은 아니다.
