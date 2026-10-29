# 저장 파이프라인 수명과 LSP 지연 응답 점검

상태: 재현한 두 결함 수정 및 로컬 검증 완료. 원격 CI는 PR에서 확인한다.

## 확인한 문제와 수정

- 저장 시 code action을 기다리던 원본 뷰를 닫으면 시간 초과 때 다른 화면에
  “저장했다”는 안내가 나타났다. 실제 fake 서버의 `CASTALL` 응답 보류와 실제 뷰 닫기로
  재현했다. 원본이 없으면 알리지 않고 작업을 끝내며, 기존 저장 재개 통지는 유지한다.
- 두 root의 정의 요청은 서로 다른 실제 fake 서버에서 같은 seq를 얻었다. 두 번째 요청 뒤
  첫 번째 서버 응답이 먼저 들어오면 첫 번째 파일로 이동했다. 라우터가 Client를 전달하고
  공통 L2 `lsp_response_owner`로 원본 surface·문서·저장 대상 epoch와 현재 Client를 확인한다.
  다른 Client의 응답은 기다림을 지우지 않고, 사라진 원본은 조용히 취소한다.
  상태 크기 변경으로 macOS app-host ABI를 249에서 250으로 올린다.

Save As에는 이미 `prior_saves`/`ready` 장벽이 있었다. 이를 결함으로 바꾸거나 중복 장벽을
추가하지 않았다. 실제 저장 명령·fake 서버의 code action/format 보류·실제 Save As 선택과
추가 CmdS를 조합해, 대상 채택 전 원본 유지, 원본 저장 후 새 대상 채택, 양쪽 실제 bytes,
보류 요청 정산을 확인한다. 임의의 epoch 변경을 Save As 재현으로 사용하지 않는다.

## 응답 분기 소스 감사

`src/platform/macos/app_session/editor/lsp.zig`의 response switch 전체가 점검 범위다.
아래의 “기존 방어”는 소스에서 확인한 구조이며 각 수명·재시작 조합을 이번에 실행했다는 뜻은 아니다.

| 응답 | 출처/문서 대응 | 이번 결과와 한계 |
| --- | --- | --- |
| initialize, shutdown | 해당 Client의 연결 상태 | 연결 내부 처리, 재시작 전수 시험은 미실시 |
| completion, completion resolve | Client를 핸들러에 전달, 현재 Client·문서 수명 확인 | 기존 방어, 이번 저장/정의 수정과 별도 |
| rename | Client와 공통 원본 판정, 편집 버전 snapshot | 기존 방어, workspace-edit 회귀 대상으로 확인 |
| code action, resolve | 저장 단계가 먼저 Client·원본 소유 검사, 메뉴도 Client/문서 확인 | 저장 회귀와 메뉴 origin 회귀 대상으로 확인 |
| formatting | onClientResponse에서 원본 Client의 문서 소유 확인 | 저장 회귀 대상으로 확인 |
| semantic tokens, inlay hint, document highlight | Client.findDoc 뒤 문서별 대기 seq | 기존 방어, 모든 수명/재시작 조합은 미검증 |
| selection range, document symbol, folding range | Client.findDoc 뒤 문서별 대기 seq | 기존 방어, 모든 수명/재시작 조합은 미검증 |
| diagnostic pull | 해당 Client.docs의 pull/barrier seq와 문서 버전 | 기존 방어, 모든 서버 재시작 조합은 미검증 |
| definition | 이번에 Client·불변 원본 수명 확인 추가 | 실제 두 subprocess seq 충돌 수정, 직접 호출 부정 대조도 추가 |
| hover | 원 감사 시 Client를 버리는 공백 확인 | [호버 후속](lsp-hover-response-origin.md)에서 실제 주 서버 충돌·Save As timeout 재현과 원본 수명 확인 추가 |
| signature | 라우터가 Client를 버림, 핸들러는 seq와 보이는 source surface 확인 | 출처 확인 공백. 실제 충돌 및 편집 도중 응답 검증은 후속 |
| references, implementation, type definition, declaration | kind·seq만 대응, Client와 원본 문서 수명은 미전달 | 출처 확인 공백. 재시도 시 활성 문서를 다시 읽는 경계도 후속 검증 |

추가로 push diagnostics는 Client.docs의 URI·문서 대응과 제공된 version을 검사한다.
version이 생략된 push를 최신 내용으로 증명할 수 있다는 뜻은 아니다. 서버가 먼저 보내는 요청,
전송/재시작 세대 전체, SDK별 의미 정확성은 이번 감사의 전수 검증 범위 밖이다.

## 실행과 관측

- `mise exec -- zig build test-editor-save-pipeline test-editor-definition-origins -j2`
  저장 12개, 정의/overlay 8개(모듈 초기화 검사 포함). `-Doptimize=ReleaseFast`도 같은 경로다.
- 기존 `test-editor-workspace-edit`, `test-editor-code-action-origins`,
  `macos-app-host-abi-lib`, `check-doc-links`, 전체 `check-boundaries`로 영향 범위를 확인한다.
- `CSA2`는 수정 전 잘못된 알림을, `GOTO3`는 수정 전 잘못된 파일 이동을 거절한다.
  `GOTO3`의 두 subprocess 재현과 후반부 직접 핸들러 호출 대조를 구분한다.
- 시한은 필드로 당겨 결정적으로 시험한다. 실제 벽시계 지연·HID·AppKit 픽셀 검증은 아니다.
- raw 로그와 적대적 조건/정상 대조는 저장소 밖 `~/Library/Caches/maru-verification/`의
  `lsp-save-*`, `lsp-definition-*`, `lsp-audit-*`에 보관한다. PNG는 커밋하지 않는다.

최종 로컬 결과: Debug/ReleaseFast의 저장 12개·정의/overlay 8개, Debug의 WorkspaceEdit
21개·code action origin 10개, 중립 판정 1개와 ABI 라이브러리 빌드, 문서 링크, 전체
`check-boundaries`가 통과했다. 서로 다른 적대적 조건 22개와 정상 대조를 기록했다.
이 개수는 각 gate의 모듈 초기화 검사를 포함하며 고유 테스트 합계로 세지 않는다.

새 의존성·저장/탐색 정책 변경은 없다. 남은 hover·signature·참조 계열은 순서대로 재현하고
확인된 결함만 수정한다. 이 감사 완료를 모든 LSP 응답 격리 완료로 표시하지 않는다.
