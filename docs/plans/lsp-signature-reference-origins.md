# 시그니처·참조 응답의 출처와 재시도 원본

상태: 네 결함 재현·수정과 최종 로컬 검증 완료. 호버 PR #4650의 후속이다.

## 계약과 순서

공통 L2 lsp_response_owner의 Owner(surface·문서·저장 대상 epoch)와 decide를 그대로 쓴다.
새로운 순수 판정이나 의존성은 추가하지 않는다. host는 요청 당시 신원을 캡처하고 현재
Client/Term 신원을 찾아 전달한다. source의 문서 신원과 본문 revision을 같은 개념으로 세지 않는다.

1. 두 실제 fake 주 서버의 같은 번호 시그니처 응답을 겹친다. 첫 요청 취소 뒤 두 번째
   서버는 SIGSTALL로 보류해 첫 응답이 두 번째 대기를 끝내는지 확인한다.
2. 시그니처 대기 중 다른 문서에서 명령을 실행하면 새 원본의 요청이 나가는지 확인한다.
   같은 원본의 추가 트리거는 기존 dirty/단일 재요청 정책을 유지한다.
3. 참조·구현·타입 정의·선언을 두 root의 같은 번호로 각각 겹친다. REFSTALL 보류는
   실제 fake 서버의 응답 분기에만 추가한다. 응답 Client를 잃는 공백을 재현한다.
4. ContentModified 뒤 원본에서 예약한 참조 재시도가 다른 활성 문서에 전송되는지
   확인한다. 원본이 계속 활성인 경우에는 기존처럼 그 문서의 최신 caret으로 되묻고,
   원본이 닫히거나 활성 문서/저장 대상이 달라지면 그 예약을 취소한다. 다른 문서에
   옛 명령을 재전송하지 않는 기존 원본 소유 계약의 적용이다.

재현된 결함만 고치고 기존 오버레이·provider·최대 재시도·입력/렌더링 정책은 유지한다.
원본의 실제 Save As/닫기, 다른 seq/kind/Client와 정상 응답도 대조한다. 상태 크기가 바뀌면
app-host ABI를 함께 올린다. 집중/ReleaseFast·기존 helper 회귀·전체 경계를 검사한다.

## 증거 경계

실제 subprocess/제품 라우터, 핸들러 직접 주입, clock 필드 조작, 실제 디스크 저장을
구분한다. 원시 로그·공격 조건과 정상 대조는 저장소 밖
~/Library/Caches/maru-verification/lsp-read-*에 둔다. HID/픽셀 또는 모든 SDK/재시작 세대를
검증했다는 뜻으로 확대하지 않는다. 기존 source 감사의 미결을 결과에 맞춰 갱신한다.

## 현재 확인한 결과

수정 전 실제 Surface 활성화·두 subprocess를 사용한 SIG2/SIG3/REF5/REF6가 모두 실패했다.
첫 수정은 네 재현을 고쳤으나 REF1의 기존 dropped_stale 계수를 빠뜨렸고, 기대값을 유지한 채
새 입구에서도 폐기 수를 기록하도록 보완했다. 이후 집중 15개가 통과했다(모듈 초기화 4개 포함).
SIG3/REF5의 직접 입구 부정 대조는 잘못된 seq/kind/Client·빈 응답·중복·닫힌 원본을 확인한다.
SIG4는 실제 Save As 뒤 이전 요청/예약을 취소하고 양쪽 파일 bytes를 확인한다.

- `mise exec -- zig build test-editor-read-origins -j2` 및 `-Doptimize=ReleaseFast`.
- 기존 `test-editor-hover-origins`, `test-editor-definition-origins`, `test-editor-save-pipeline`,
  `macos-app-host-abi-lib`, `check-doc-links`, 전체 `check-boundaries`로 영향을 확인한다.
- 상태 크기 변경에 따라 app-host ABI 251→252와 계약/변이 입력을 동기화한다.
- 기존 SIG1의 정상 시그니처/타이핑, REF1의 실제 같은 문서 재시도·상한/목록·이동,
  provider와 오버레이 회귀를 대조한다. 실패 로그와 중간 수정 실패도 저장소 밖에 보존한다.

시그니처의 표시/활성 파라미터 정책이나 참조의 기존 같은 문서 재시도 정책을 바꾸지 않는다.
모든 본문 revision·서버 재시작·SDK별 의미 정확성 검증은 별도이며 이 수정으로 완료 처리하지 않는다.

최종 로컬 결과: Debug/ReleaseFast 집중 15개, Debug 호버 10개·정의 8개·저장 12개,
중립 판정 1개, ABI 라이브러리 빌드·문서 링크/줄 참조·전체 `check-boundaries`가 통과했다.
서로 다른 적대적 조건 26개와 정상 대조를 기록했다. 각 gate의 초기화 검사를 포함한 개수이며
고유 테스트 합계로 세지 않는다. 원격 CI와 선행 머지 후 main 리베이스 검증은 별개다.
