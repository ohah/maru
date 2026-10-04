# 심볼 미리보기 — 현재 편집 화면

2026-10-04, 공유 분할 PR [#4126](https://github.com/ohah/maru/pull/4126) 머지 뒤의 후속이다.
사용자가 **현재 편집 화면에서 미리보기**를 승인했다. `⇧⌘O` 또는 breadcrumb 형제 목록에서
항목을 고르면 같은 pane에 대상 줄을 임시 표시한다. Enter는 이동 확정, Esc·토글·다른 오버레이·
목록 밖 클릭은 취소다. 별도 뷰포트 구상을 이 계약으로 대체한다.

## 먼저 고친 문제

`symbol_picker.Row`는 라벨을 복사하고 byte offset을 보관한다. 문자열 수명은 안전하지만
목록을 만든 문서와 뷰의 신원은 없었다. `acceptSymbolPicker`는 그 offset을 **현재 활성 Term**의
`navigateTo`에 넘겼다. 그래서 목록이 열린 뒤 대상이 달라져도 이전 위치가 적용됐다.

실제 AppSession/공유 편집 API로 다음을 재현했다. 처음 네 판정자는 수정 전에 모두 실패했다.

| 조건 | 수정 전 관측 | 수정 후 |
|---|---|---|
| 공유 peer가 문서 앞에 11바이트 삽입 | 매핑된 커서 11이 예전 심볼 offset 24로 이동 | 선택·문서 revision·이동 이력을 보존하고 닫음 |
| 같은 문서의 다른 뷰로 전환 | 다른 뷰 커서 1이 24로 이동 | 그 뷰에 이전 목록을 적용하지 않음 |
| 다른 파일로 전환 | 다른 문서 커서 1이 24로 이동 | 문서와 선택을 보존하고 닫음 |
| 닫은 목록에 확정 호출 | 커서 0이 24로 이동 | 무동작 |

`AppSession.symbol_picker_source`는 `SymbolPickerSource`의 surface id, registry 신원,
문서 handle과 revision을 보관한다. 문서 lease를 추가로 retain하지 않고 registry 포인터는
동일성 비교에만 사용한다. `recomputeSymbolPicker`와 `acceptSymbolPicker`가 현재 대상과 대조한다.
재필터에서 대상이 달라졌으면 닫고 행을 비운다. 형제 목록의 `sibling_of` 인덱스도 새 대상에
넘기지 않는다. 새로 열 때는 현재 대상을 다시 잡는다.

정상 확정은 기존처럼 닫은 뒤 `navigateTo` 한 번을 호출한다. Undo, 문서 저장과 공유 편집 게시 계약은 바꾸지 않는다. 미리보기 렌더는 아래처럼 분리한다. 재필터 할당 실패는 기존 정책대로 목록을 비우며,
이전에 성공한 행의 위치를 다시 사용하지 않는다.

`test-editor-symbol-picker`는 기존 필터·형제 목록·파싱 완료와 `SPTARGET1`~`SPTARGET7`을 함께 실행한다.
낡은 대상과 정상 재열기의 Enter는 `handleKeyEvent`를 거친다. 닫힌 목록의 중복 확정은 직접
host callback을 주입한다. 실제 OS에서 늦은 callback이 발생했다는 증거로 해석하지 않는다.
문서 handle 교체의 모든 제품 경로를 전수 실행했다는 주장도 하지 않는다.

## VS Code에서 확인한 동작

공식 [Go to Symbol 설명](https://code.visualstudio.com/docs/editing/editingevolved#_go-to-symbol)은
`⇧⌘O`와 위/아래 키로 파일 안 심볼을 탐색하는 기능을 설명한다. 아래의 세부 동작은
2026-10-04에 확인한 VS Code commit `5e86c7c4c2eb99b22e631e0aa4eb05f6b8b53f35`의 소스 근거다.

- [심볼 선택과 확정](https://github.com/microsoft/vscode/blob/5e86c7c4c2eb99b22e631e0aa4eb05f6b8b53f35/src/vs/editor/contrib/quickAccess/browser/gotoSymbolQuickAccess.ts):
  목록의 활성 항목이 바뀌면 기존 editor를 해당 범위로 스크롤하고 decoration을 더한다.
  확정하면 `gotoLocation`을 호출한다. 별도 편집 영역에 여는 버튼은 다른 경로다.
- [편집기 상태와 취소](https://github.com/microsoft/vscode/blob/5e86c7c4c2eb99b22e631e0aa4eb05f6b8b53f35/src/vs/editor/contrib/quickAccess/browser/editorNavigationQuickAccess.ts):
  view state를 보관하고 cursor 위치가 변하면 갱신한다. 취소 때 동일한 활성 editor이면 복원하고,
  정산 때 decoration을 제거한다. 확정은 selection을 바꾸고 editor에 포커스를 준다.

따라서 일반 코드 편집기의 이 미리보기는 **목록 옆의 두 번째 문서 뷰가 필수인 구조가 아니다**.
이는 소스 대조 결과이며 이번에 VS Code 앱을 직접 조작한 GUI 실측은 아니다.
소스는 `references/vscode/symbol-preview/<commit>/`에서만 읽었고 구현을 복사하지 않았다.
Maru의 위 대상 검사는 기존 API에 대한 독립 수정이다.

## 표시 상태의 소유

`symbol_preview.Projection`은 선택한 심볼이 보이도록 줄 참조·원문 줄 번호·gutter 표식을 만든다.
대상을 숨기는 접힘만 표시상 펼치며 정본 접힘 집합은 바꾸지 않는다. 본문 바이트·문서 lease·
새 Term은 복제하지 않는다. 투영과 랩 행 캐시는 Term이 소유하고 닫기/해제 시 돌려준다.
같은 revision·offset·접힘 범위·접힘 집합이면 투영을 재사용한다. 공간은 문서 줄 수와 접힘 수에
비례하며, 본문 전체 복사나 새 Undo 기록은 없다.

`appendPaneFrame`은 구문 갱신과 정상 resize clamp를 마친 뒤 `SymbolPreviewFrame`을 연다.
기존 본문 렌더러가 읽는 표시 줄·스크롤·행 캐시만 임시 교체하고, `defer`로 원래 값들을 돌려놓는다.
렌더링 중 실패·빈 사각·조기 반환에도 정산한다. 미리보기의 hit 표·스크롤바 입력 기하는 게시하지 않는다.
이전 정본의 본문·sticky·스크롤바·미니맵 입력 표도 비운다. Esc와 다음 클릭 사이에 렌더가
없을 수 있으므로, 원래 화면이 다시 그려지기 전에는 보이지 않는 원문 위치를 클릭하지 않는다.
따라서 프레임 밖에서 실행되는 편집·workspace checkpoint·공유 뷰 준비는 항상 정본 화면 상태를 읽는다.
재시작 `restoreViewState`를 취소 처리에 쓰지 않으며, 취소에 복원용 할당도 필요 없다.

대상 줄에는 줄 강조를 그린다. 실제 primary/extra selection, 선택의 목표 열, Undo와 이동 이력은
목록 탐색으로 바뀌지 않는다. 미리보기에서 caret·sticky 클릭 머리줄·충돌 해결 버튼을 새로 게시하지
않는다. 구문 색과 기존 본문 폭/랩 계산을 사용하고, 긴 이전 줄은 같은 시각 행 계산으로 문맥을 잡는다.
창 크기 변경은 기존 정본 clamp 규칙을 유지한다. 다른 공유 뷰는 이동하지 않는다.

| 사건 | 동작 |
|---|---|
| 위/아래·쿼리 필터·파싱 완료 | 현재 선택의 위치를 다시 표시. 실제 커서는 유지 |
| Enter | 투영을 해제하고 기존 `navigateTo` 한 번. 원래 커서에서 이동 이력을 쌓음 |
| Esc·토글·다른 overlay | 투영 해제. 다음 프레임에 정본 화면을 표시 |
| 목록 밖 클릭 | 취소하고 그 클릭을 소비. 임시 화면의 좌표로 본문을 편집하지 않음 |
| 빈 결과 | 원래 편집 화면 표시. 확정해도 이동하지 않음 |
| 문서 revision·뷰·문서 신원 변경 | 낡은 행의 표시/확정을 거절. 새 편집 결과를 이전 화면으로 덮지 않음 |
| 투영 준비 할당 실패 | 정본 상태 그대로 원래 화면 표시. 정상 Enter 이동은 유지 |
| 한국어 조합 | 기존 overlay 입력 경로로 목록 검색어에만 적용 |

목록 안은 기존 키보드 선택을 유지하며 목록 스크롤바·휠을 사용한다. 목록 행의 마우스 확정은
이번 범위가 아니다. 일반 문서 본문이 대상이며 diff/merge의 별도 비교 렌더에는 투영하지 않는다.
도크 아웃라인과 Split in Group도 별도 작업으로 남는다.

## 검증 계약

`mise exec -- zig build test-editor-symbol-picker`는 기존 필터·형제 목록·파싱 완료와
`SPTARGET1`~`SPTARGET7`, `SPPREVIEW` 판정자를 실행한다. 실제 AppSession의 키 라우팅과 본문
DrawList에서 대상 문자열을 검사하고, 취소·확정·checkpoint·여러 커서·공유 편집·접힘·랩·resize·
빈 결과·overlay IME 콜백·할당 실패를 확인한다. 보호를 제거한 컴파일 가능한 변이와 등가 대조를
별도 worktree에서 실행한다. 횟수 대신 실패 조건과 결과를 PR에 기록한다.

`python3 tools/symbol-preview-app/run.py`는 별도 HOME과 소스 사본으로 실제 macOS 앱을 빌드하고
AppKit 로컬 키 이벤트로 열기·검색·다음 항목·취소·확정을 실행한다. 제품 Metal renderer의 읽기 결과를
PNG로 만들고 원문 revision·정본 스크롤·커서·이동 이력을 함께 관측한다. 한국어 단계는
`NSTextInputClient` 콜백 주입이며 실제 한국어 입력 소스/HID의 증거와 구분한다.
Esc와 본문 클릭을 재그리기 없이 연속 호출하고, Enter는 미리보기 프레임을 그린 뒤에 보낸다.
Debug·ReleaseFast·전체 편집기·경계·타깃 빌드와 캡처 결과는 PR 본문에 기록한다.
