# Save As 중 코드 액션 메뉴 수명

상태: 메뉴 잔존과 이전 파일의 실제 디스크 편집 재현·수정 및 최종 로컬 회귀 검증 통과.

## 계약과 가설

코드 액션 목록은 요청 당시 파일에 속한다. 실제 Save As가 새 대상을 adopt하면 이전
대상의 목록 대기·표시된 메뉴·선택 뒤 resolve는 새 대상의 동작으로 재사용하지 않는다.
기존 resolve 응답 owner와 WorkspaceEdit 버전 검사는 이미 있지만, 메뉴를 선택하기 전
대상 교체와 같은 Client의 새 URI 재결합 뒤에도 이전 항목이 남는지 확인한다.

## 재현·수정 경계

실제 Save As actor/worker와 디스크 bytes·epoch를 대조한다. 대기·표시·resolve를 나누고
이전 positive/null·오류, 같은/공유 뷰 성공, 취소·쓰기 충돌 실패와 다른 문서의 요청을
최소 20개 조건으로 검사한다. 새 요청의 정상 메뉴와 적용/Undo를 대조한다.
확인된 결함만 성공한 adopt 뒤 기존 대상 수명 알림 경계에서 수정하며, 원본별로 정리해
다른 메뉴·문서의 새 요청을 지우지 않는다. 새 상태/ABI/정책이 필요하면 먼저 보고한다.

native controller와 실제 파일 관측은 직접 callback·fake 서버와 구분하며 OS/HID/픽셀
증거로 확대하지 않는다. 원시 로그와 조건별 관측은 외부 Library/Caches/maru-verification에 둔다.

## 발견과 수정

Save As 뒤 ready-edit/lazy 메뉴가 모두 남았다. 같은 primary가 after.c에 재결합한 뒤
실제 메뉴 선택을 실행하면 before.c의 실제 disk bytes가 각각 `FIXED a; ...`와
`// lazy` 삽입으로 바뀌었다. 열린 모델이 새 경로로 이동해 이전 경로는 WorkspaceEdit의
정상적인 닫힌 파일 편집 경로로 처리됐다. 일반 닫힌 파일 편집을 금지하는 대신 요청 수명을 고친다.

성공한 adopt 뒤 기존 공유 view/window 순회에서 code_action.onSaveTargetChanged를 호출한다.
기존 L2 sourceMatches로 목록 대기·메뉴·resolve를 각 원본별로 정리한다. 메뉴가 제목을
빌리므로 먼저 닫고 항목을 해제하며, 닫힌 메뉴의 지연된 선택도 항목이 없어 무동작이다.
다른 원본의 새 목록/resolve나 일반 context menu는 닫지 않는다. 새 상태/ABI는 없다.

집중 10개(행동 6개·초기화 4개), 기존 code action 원본 10개와 WorkspaceEdit 21개가 통과했다.
38조건은 네 단계(목록 대기·ready-edit 메뉴·lazy 메뉴·resolve) × 같은/공유 뷰 × 이전
positive/null/오류의 성공 24개, 단계별 취소/worker 목적지 충돌/다른 문서 저장 12개,
이전 메뉴와 다른 문서의 새 목록 대기에서 두 대상 적용 순서 2개다.
응답용 이전 URI는 요청 때 별도 버퍼로 복사한다. Save As 뒤 바뀐 Client 문서 URI를
다시 읽어 새 URI의 가짜 지연 결과로 검증하지 않는다. 새 URI의 같은 primary 재결합 뒤
이전 결과가 새 대기를 끝내지 않고 정상 새 적용/Undo가 가능한 것을 대조한다.

최종 Debug/ReleaseFast에서 집중 10개·기존 원본 10개·WorkspaceEdit 21개·저장 파이프라인
12개·Save As 명령 16개가 각각 통과했다. Debug의 tooltip Save As 9개, ABI 라이브러리·
전체 경계·문서 링크/좌표·포맷 검사도 통과했다. 초기화를 고유 합계로 더하지 않으며
로컬 결과와 원격 CI·머지를 구분한다. 원시 기록은 외부 `lsp-code-action-save-as-*.log`,
조건별 관측은 `lsp-code-action-save-as-adversarial.json`에 보존한다.
