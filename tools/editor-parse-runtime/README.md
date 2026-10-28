# 파싱 메인 큐와 문서 수명 검증

`dispatch.submit`은 문서의 request lease와 지속되는 Gate로 작업을 준비한다.
`ready`의 Completion은 다음 poll·submit·close·shutdown 전까지만 빌린다.
워커는 Registry·뷰 포인터를 받지 않는다. 문서 참조는 두 Snapshot이 메인에서 반환될 때까지 유지한다.

```sh
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue test-editor-parse-worker test-editor-parse-request -j2
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-runtime/review.py --output /tmp/new-parse-runtime --deps /path/to/deps --cache /path/to/cache
```

Runtime 판정 10개는 마지막 뷰·실제 revision·공유 뷰·할당 실패·동일 문서 재생성 serial·늦은 전달을
검사한다. AppSession 판정 target은 실제 창 소유자 파괴 2개와 기존 익명 초기화 4개다.
Linux에서는 macOS 전용 익명 초기화 3개가 빠져 총 3개를 수집하고, 실제 창 수명 2개는 skip한다.
플랫폼별 정확한 개수를 검사해 target 누락을 허용하지 않는다.
이 두 target의 OS 전달은 명시적으로 제어한다. 별도 production-mode probe는 제품의
`main_queue.c.inc`와 CoreFoundation run loop를 사용한다. 수동 poll이나 렌더 tick 없이
메인 스레드 수락·닫힌 문서 회수·종료 후 늦은 실제 전달을 확인한다.

독립 소스에서 문서 조기 해제·revision 검사 제거·Gate 초기화·재무장 제거·닫기 무효화 제거를
각각 컴파일하고 실행 assertion 실패를 요구한다. 정상 전후 대조는 통과해야 한다.
컴파일 실패를 검출 성공으로 세지 않는다. 새 소스는 먼저 stage하며 기존 output을 재사용하지 않는다.
원본/변형 소스·실행 파일·로그·전체 해시는 외부 output의 result.json에 보존한다.

현재 증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-runtime-review-1/`이다.
다섯 결함 모두 실행 중 거절됐고 정상 전후 대조는 통과했다.
기존 worker 19개·요청 Gate 36개도 별도 회귀 target을 유지한다.

일반 편집기의 입력·렌더 경로는 아직 전환하지 않았다. 뷰별 캐시 설치·실제 GUI/IME·입력 지연·
race detector·C malloc 실패 전수 검증은 이 결과에 포함하지 않는다.
준비 실패는 내부 호출자에게 오류를 반환하며 본문·Undo를 바꾸거나 동기 파싱으로 우회하지 않는다.

## 화면 연결 전 상태 조회

`dispatch.observe`/`Runtime.observe`는 현재 문서·본문 판·언어 설정에 해당하는 게시 대기와
실패를 포함한 완료를 구분한다. 완료 값은 Request와 Outcome 값만 보유하며 트리나 Job을 빌리지 않는다.
`submit` 준비 실패는 오류 반환과 `none`으로 표시하며 자동 재시도하지 않는다.
호출자가 알림·재시도를 결정하기 위한 기반이고 일반 입력·표시 경로는 전환하지 않았다.

```sh
python3 tools/editor-parse-runtime/review.py --scope observation --output /tmp/new-parse-observation --deps /path/to/deps --cache /path/to/cache
```

실패 버리기·옛 실패의 새 요청 덮어쓰기·grammar 무시·revision 무시·재시도에서 옛 실패 보존의
다섯 실제 결함을 컴파일한다. 옛 완료 검사는 이전 작업과 새 작업의 실제 copy allocator를 각각 장벽으로 멈춰
완료 순서를 결정한다. 고정 sleep이나 경쟁이 우연히 일어났다는 추정에 의존하지 않는다.
기본 `--scope lifetime`은 기존 수명 결함 대조를 유지한다. 두 모드 모두 runtime 10개·host 6개와
실제 Apple 전달 실행을 요구한다. UI·알림 정책은 별도다.

## 소비자 보유 참조

`acquire`는 현재 결과를 검증해 보유하고 `Completion.retain`은 그 보유를 추가한다.
각 핸들은 정확히 한 번 release한다. 반환 전에는 읽기 전용 provider 자원을 빌릴 수 있으나
이전 본문의 결과를 새 본문에 사용하는 허가는 아니다. 마지막 반환만 워커 퇴역을 게시한다.
뷰 연결 시 독립 뷰 자원을 먼저 반납하고 이 핸들을 나중에 반환해야 최종 해제 경계가 유지된다.

`Runtime.deinit`와 `dispatch.tryShutdown`은 외부 참조가 있으면 ResultsHeld로 거절하며
현재 Gate·결과·전역 소유자를 보존한다. 기존 `shutdown`은 소비자가 모두 반환됐다는 선행 조건을
갖는다. 일반 입력/뷰 연결은 아직 이 참조를 사용하지 않는다.

```sh
python3 tools/editor-parse-runtime/review.py --scope leases --output /tmp/new-parse-leases --deps /path/to/deps --cache /path/to/cache
```

Job 참조 증가 누락·전체 참조 증가 누락·마지막 반환 전 퇴역·종료 가드 제거·현재 입력 검사 없는
acquire의 다섯 실제 결함을 컴파일·실행한다. runtime 10개·host 6개·worker 19개와 실제 Apple
전달을 요구한다. worker C 장벽 아래에서 큐 게시를 검사하고, 잘못된 참조 수와 조기 게시를 주입한
경우에도 테스트 cleanup만 복구해 assertion 결과와 별개 누수/이중 해제를 섞지 않는다.
Apple probe의 `retained_result=1`은 실제 메인 큐 수락 후 보유 중 종료 거절·반환 후 종료 증거다.
