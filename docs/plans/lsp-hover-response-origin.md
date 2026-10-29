# 호버 응답의 출처와 원본 수명

상태: 두 결함 재현·수정과 최종 로컬 검증 완료. 선행 PR #4649 위에서 작업한다.

## 재현과 수정

서로 다른 root의 실제 fake 주 서버가 같은 hover seq를 쓴다. 첫 요청을 취소한 뒤 다른
root에서 다시 요청하고 두 번째 서버는 `MUTEHOVER`로 보류했다. 첫 서버의 응답이 두 번째
대기를 끝냈다(`HOVB3`, 수정 전 실패). 기존 auxiliary 응답 차단은 주 서버끼리의 충돌을
막지 않았다.

응답 라우터가 Client를 전달하고 기존 공통 L2 `lsp_response_owner`로 Client·surface·문서·
저장 대상 epoch를 확인한다. 다른 Client의 내용/빈 응답은 대기를 보존하고, 사라진 원본은
취소한다. 닫았다가 새로 요청한 대기에 이전 root 응답이 들어와도 새 내용을 가로채지 않는다.

또한 실제 Save As actor와 디스크 쓰기 뒤에는 이전 요청의 내용과 진단 fallback이 새 대상에
표시되면 안 된다(`HOVB4`). 시간 초과 분기에서도 원본 신원을 확인한다. 이 검사만 제거한
실행 파일은 컴파일에 성공한 뒤 `!hover_box.open`에서 실패했다. 원본이 그대로인 정상
시간 초과는 진단만으로 열리는 대조군을 유지한다. 인위적인 epoch 증가를 Save As 재현으로
세지 않는다.

State 크기에 맞춰 macOS app-host ABI를 250에서 251로 동기화한다. 순수 판정은 기존
중립 L2를 그대로 사용하고 macOS에서는 현재 Client와 Term 신원만 조회한다.

## 검증과 관측

- `mise exec -- zig build test-editor-hover-origins -j2`: HOVB1~4, SIG1, ASB1과 모듈 초기화
  검사를 포함한 10개. `-Doptimize=ReleaseFast`도 동일하게 검사한다.
- 기존 `test-editor-definition-origins`, `test-editor-save-pipeline`, `macos-app-host-abi-lib`,
  `check-doc-links`, 전체 `check-boundaries`로 영향을 검사한다.
- HOVB3 앞부분은 실제 두 subprocess와 제품 라우터를 통과한다. 후반부 잘못된 seq·외부
  Client의 빈/본문 응답·중복·정상 내용·닫힌 원본은 핸들러 직접 호출 대조다. 정상 내용은
  실제 pane 프레임의 앵커와 호버 표시 상태·문구를 확인한다.
- HOVB4는 실제 Save As와 두 경로 bytes를 확인하되 늦은 내용은 직접 주입하고 timeout은
  시각 필드를 당긴다. 실제 벽시계 지연·HID·AppKit 픽셀 캡처로 일반화하지 않는다.
- 기존 HOVB1/2는 포인터·키·클릭·수정·렌더 draw list·진단 범위와 serverless fallback을,
  ASB1은 auxiliary spoof를, SIG1은 시그니처가 상자를 소유하는 대조군을 검사한다.
- raw 로그, 제거한 방어의 실패와 복구본, 적대적 조건은 저장소 밖
  `~/Library/Caches/maru-verification/lsp-hover-*`에 보관한다. PNG는 커밋하지 않는다.

최종 로컬 결과: Debug/ReleaseFast 호버 10개, Debug 정의 8개·저장 12개, 중립 판정
1개와 ABI 라이브러리 빌드·문서 링크·전체 `check-boundaries`가 통과했다. 현재 소스의
적대적 조건 22개와 정상 대조를 기록했다. 모듈 초기화 검사를 포함한 각 gate의 개수이며
고유 테스트 합계로 세지 않는다. 원격 CI 및 선행 머지 뒤 main 리베이스 검증은 별개다.

## 범위와 후속

기존 입력·오버레이·진단 fallback 및 렌더링 정책은 유지한다. 새 의존성은 없다.
이 변경은 응답/timeout 입구의 신원 확인이며 모든 편집 revision·SDK·프로세스 재시작 조합을
증명하지 않는다. 시그니처·참조의 실제 충돌과 참조 재시도에서 활성 문서가 바뀌는 경계는
후속 검증 대상으로 남긴다. 선행 감사 전체를 완료한 것으로 표시하지 않는다.
