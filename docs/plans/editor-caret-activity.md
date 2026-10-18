# 편집기 커서 활동과 깜빡임

상태: 완료. Debug·ReleaseFast 집중/회귀 검사와 실제 앱 Metal 캡처로 검증했다.

계약은 [문서 모델 §3.2](../native-editor-document-model.md#32-selection은-배열이다)가 소유한다.
커서 위치·선택·개수의 사용자 변경이 게시되면 즉시 보이고 기존 설정의 새 깜빡임 주기를 시작한다.
단순 스크롤이나 프레임 생성마다 초기화해 깜빡임을 멈추지 않는다.

## 조사 범위와 배선

`app_session` 아래의 `editor_selection`, 추가 선택, `editor_diff_selection`, 병합 `pane_caret`,
선택의 `focus`, IME 범위 쓰기와 커서 게시 함수의 호출자를 조사한다. 테스트/디버그 fixture의 직접
대입과 제품의 직접 대입을 구분한다. 새 사용자 경로가 생기면 아래 책임의 게시 지점에 연결한다.

| 경로 | 실제 게시 지점 | 처리 |
|---|---|---|
| 방향키·단어/줄/문서·괄호 이동과 Shift 선택 | `moveCarets` | 이동·병합 후 활동 표시 |
| 위/아래 커서·다음 일치 추가 | `addCursorVertically`, `addNextOccurrence` | 성공 후 활동 표시 |
| 클릭·더블/트리플 클릭·드래그·자동 스크롤 선택 확장 | `beginBodySelection`, `selectWordOrLineAt`, `dragBodySelection` | 선택 게시 후 활동 표시; 추가 병합 준비만 실패해도 이미 바뀐 primary는 표시 |
| Option 클릭 토글·열 선택 | `toggleCursorAt`, `writeCursors`, `applyColumnSelection` | 선택 게시 후 활동 표시 |
| 전체 선택·구조적 선택·고정 머리줄 클릭 | `selectAll`, `smart_select.step`, `sticky.click` | 성공 후 활동 표시 |
| 파일/정의/참조/심볼·검색 결과·뒤/앞 이동 | `placeCaretAndReveal`, `selectFindMatch` | 실제 선택 게시 후 활동 표시; 탐색 호출자가 공통 지점을 사용 |
| 타이핑·붙여넣기·삭제·줄 조작·치환·완성·코드 액션·충돌 수락·Undo/Redo | `refreshAfterEdit` | 성공한 본문 편집의 공통 출구; 괄호 type-over는 별도 표시 |
| 공유 문서의 다른 뷰 커서 매핑 | `shared_edit.Publication.publish` | 활성 뷰만 활동 표시; 다른 문서의 비활성 뷰는 제외 |
| 접기 뒤 숨은 커서 이동 | `adjustFoldedSelections` | 실제 선택이 옮겨졌을 때만 표시 |
| 비교 뷰의 클릭·낱말/줄 선택·드래그·이동·좌우 전환 | `beginDiffBodySelection`, `selectWordOrLineInDiff`, `dragDiffBodySelection`, `diffMove`, `diffSwitchSide` | 비교 행 좌표를 게시한 뒤 표시 |
| 병합 Current/Incoming/Base 판 | `merge.placePaneCaret`, `merge.paneMove` | Result 선택과 별도인 읽기 전용 판 커서도 표시 |
| IME 조합/명시적 범위/부분 조합 | `setEditorPreedit`, `input.imeMarked`, `input.editorImeReplacement`, `editor_ime.marked` | 조합 범위·선택 갱신 후 표시; 직접 확정은 본문 편집 경로 사용 |
| pane·pane 안 탭·워크스페이스 탭 | `term.noteEditorFocus` | 승인된 포커스 전환 후 표시 |
| 본문 입력 소유권·창 복귀 | `workspace.focusWorkspaceInput`, `AppSession.focusChanged` | 포커스를 돌려받을 때 주기 초기화 |
| 주소창·검색·rename 등 기존 입력 필드 | 기존 `handleKeyEvent`의 입력별 reset | 기존 경로 유지; 편집기 커서 누락을 고치기 위해 전체 키/렌더를 무조건 reset하지 않음 |

공통 시각 출구 `editor.noteCaretActivity`는 활성 편집기 Term만 확인하고 기존 `resetCursorBlink`와
`metal_dirty`를 세운다. 새 할당·커서 사본·프레임별 커서 해시/비교를 추가하지 않는다.
새 편집 판정은 없고 기존 L2 이동/선택/편집 계획을 그대로 사용한다.

## 제외한 직접 대입

- `revealOffsetForRenameBox`, 복구/충돌 편집의 임시 선택은 계산 뒤 원래 선택으로 돌아간다.
- 파일/워크스페이스 복원과 새 문서·검색 결과 탭의 초기 선택은 문서 생성/포커스 경로가 표시한다.
- 완료·WorkspaceEdit의 선택 정산은 본문 편집 출구가 표시한다. 문서 해제·diff 무효화는 죽는 커서를 다시 켜지 않는다.
- 심볼 미리보기 투영·진단·색상·접힘 데이터·viewport 캐시만 갱신하는 렌더는 활동이 아니다.

## 검증

집중 게이트 12개와 기존 회귀 109개를 Debug·ReleaseFast에서 통과했다. 실제 다른 Term·분할 pane
복귀, primary 게시 뒤 추가 선택 병합 준비 OOM, 자연 깜빡임 후 실제 앱 키 입력도 확인했다.

- CBL1: 수정 전 숨은 커서 이동 뒤 `blink_visible == false` 재현, 수정 후 즉시 표시.
- CBL2~3: 이동·선택·추가/열 커서·편집·Undo/Redo·IME·탐색·포인터 경로. primary 변경 후 추가 병합 할당 실패도 포함.
- CBL4: 스크롤·렌더·노출용 임시 선택·무관한 백그라운드 문서 편집이 기존 주기를 보존.
- CBL5~8: 창/뷰 포커스, 공유 뷰 매핑, 비교 좌우, 병합 판 커서.
- 실제 앱 하네스는 타이머가 스스로 숨긴 커서에 AppKit 키를 주고, 즉시 표시된 이동/멀티커서/Shift 선택과
  이후 다시 숨는 상태를 Metal로 캡처한다. 물리 HID·한국어 입력기 검증을 대신하지 않는다.

모든 키에서 초기화하는 방법은 포인터·비동기 선택을 놓치고, 모든 렌더에서 초기화하는 방법은 idle 깜빡임을
멈춘다. 커서 전체를 매 프레임 복사/비교하는 방법은 추가 저장소와 커서 수에 따른 비용을 만든다.
기존 게시 지점과 공통 편집/포커스 출구를 연결해 이 문제를 피한다.
