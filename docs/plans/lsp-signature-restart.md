# 서버 종료 뒤 시그니처 대기 복구

상태: 재현·수정과 최종 로컬 검증 완료. PR #4652의 main 리베이스 뒤에서 작업한다.

## 문제 가설과 계약

`lsp.releaseWaiting`은 서버가 사라지면 응답이 올 수 없는 대기를 해제한다. 시그니처는
hide로 해제된다는 전제로 제외되어 있다. SIGSTALL 요청을 보낸 실제 fake 서버를 종료하고
재시작한 뒤 같은 원본에서 명령을 실행해도 이전 대기에 합쳐져 새 요청이 나가지 않는지 확인한다.

재현되면 다음 host API 계약으로 고친다. 순수 소유 판정은 기존 L2 lsp_response_owner를 쓴다.

- `lsp.boundClientFor(session, term)`: 문법·root·열린 문서의 결합을 찾되 ready/proc는 요구하지
  않는다. 종료 처리에서 proc를 이미 떼었어도 원본 서버를 구분하기 위한 조회다. 요청 허가는
  계속 readyClientFor가 enabled·ready·proc를 검사하며, 두 조회의 문서 결합 규칙은 공유한다.
- `signature.onClientStopped(session, origin, term)`: 같은 원본·현재 결합 서버의 대기만 놓는다.
  다른 root나 auxiliary의 종료는 유효한 대기를 취소하지 않는다. hide를 사용하되 시그니처가
  소유하지 않은 호버 박스는 보존한다.
- dropProcess/lowerServers의 공통 releaseWaiting에서 문서 연결을 지우기 전에 호출한다.
  기존 다른 요청의 release·재시작 backoff·종료 정책은 유지한다. 새 State/ABI 필드는 필요 없다.

## 검증

실제 fixture 소유 서버 PID만 종료하고 PID 교체·문서 재개방·새 요청·정상 응답을 확인한다.
빈 대기, dirty 후속, 활성 시그니처의 재요청 대기를 구분한다. 다른 root/auxiliary 종료와
다른 호버 소유권을 대조하고, 직접 종료 알림 주입은 실제 프로세스 종료 증거와 분리한다.
backoff 시각 필드를 당기는 것은 명시적 시험 seam이다. HID/화면 픽셀이나 모든 서버 교체·
설정 변경·재시작 세대를 검증했다는 뜻으로 확대하지 않는다.

원시 로그·적대적 조건과 정상 대조는 저장소 밖
~/Library/Caches/maru-verification/lsp-signature-restart-*에 둔다. 관련 원본/호버·기존 재시작
집중 검사와 ReleaseFast, 문서 검사, 전체 경계 검사를 실행한다. 새 의존성·렌더링 정책은 없다.

## 발견과 대조 결과

수정 전 SIGR1은 다른 PID의 서버가 ready가 된 뒤에도 전송 수가 1에서 2로 늘지 않아 실패했다.
수정 후에는 빈 대기·dirty 후속·활성 시그니처의 후속 대기를 실제 프로세스 종료/재시작으로
확인했다. SIGR2는 같은 번호의 다른 root 서버 종료, 종료 알림의 잘못된 Client/Term 조합,
종료 알림 재생과 다른 호버 소유권을 검사한다. SIGR3은 같은 문서를 연 auxiliary만 실제로
종료해 primary의 대기와 PID를 보존하는지, SIGR4는 LSP 비활성화·재활성화를 검사한다.

현재 집중 gate는 SIGR1~4·SIG1~4·ASB1·LSPB1과 모듈 초기화 4개를 포함한 14개다.
실제 종료 뒤 readyClientFor는 null이어도 boundClientFor는 결합을 찾는다. 이때 명령은
전송하지 않고 false를 반환하며, 새 ready PID에서는 새 요청과 정상 시그니처까지 확인한다.
Client 종료 대조에서만 ready 조회를 사용한 실행 파일은 컴파일 성공 뒤 SIGR1/2/4가 실패하고
나머지 11개가 통과했다. 정확한 원본을 복구한 뒤 최종 소스로 재검증해 통과했다.

- `mise exec -- zig build test-editor-signature-restart -j2` 및 `-Doptimize=ReleaseFast`.
- 기존 `test-editor-read-origins`, `test-editor-hover-origins`, `test-editor-definition-origins`,
  `test-editor-save-pipeline`, `macos-app-host-abi-lib`, 문서 링크/줄 참조와 전체 경계를 확인한다.
- 종료 알림의 일부 부정 대조는 직접 호출이며 실제 SIGKILL 증거와 구분한다. 종료한 PID는
  해당 fixture가 생성한 서버에서만 얻는다. 원격 전송·실제 SDK·모든 설정 교체 조합은 미검증이다.

새 상태 필드가 없어 ABI는 252를 유지한다. boundClientFor는 요청 허가 API가 아니며,
모든 기존 요청은 계속 readyClientFor의 enabled·ready·proc 검사를 통과해야 한다.

최종 로컬에서 Debug/ReleaseFast 집중 14개, Debug 원본 격리 15개·호버 10개·정의 8개·
저장 12개, 중립 판정 1개와 ABI 라이브러리 빌드·문서 링크/줄 참조·전체 경계가 통과했다.
서로 다른 적대적 조건 25개와 정상 대조를 기록했다. 각 gate의 모듈 초기화 검사를 포함하며
고유 테스트 합계로 세지 않는다. 원격 CI와 선행 머지 뒤 리베이스 검증은 별개다.
