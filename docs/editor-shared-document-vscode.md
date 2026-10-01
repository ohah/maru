# 공유 편집기 뷰 — VS Code 정책 대조

2026-10-01 확인. VS Code 공식 문서와 microsoft/vscode main
`4fee1b66c3ce4d5c43b30999caabd9c37834d9c9`의 23개 파일을 대조했다.
소스는 로컬 `references/vscode/`에서 read-only로 참고했고 제품 코드 표현을 복사하지 않았다.
아래는 확인한 동작·추론·Maru 권장안을 구분한다. 실제 VS Code GUI/한국어 입력기를 이번에
실행한 결과는 아니다. 브라우저·OS·설정별 차이는 구현 시 동작 비교로 닫는다.
Maru 설계는 [공유 문서 제안](plans/editor-shared-document.md), 계약은 그 문서의 연결 문서가 소유한다.

## 정책별 대조와 권장안

| 항목 | VS Code에서 확인한 근거 | Maru 권장안/남은 조건 |
|---|---|---|
| 같은 파일 두 뷰 | 같은 text model을 두 editor가 사용하는 공식 cursor 회귀 테스트가 있다. ModelService는 URI로 모델을 찾는다 [S1][S2] | 정본 하나·뷰별 상태. 창을 넘는 app-global 소유는 기존 Maru 계약으로 별도 설계하며 VS Code가 모든 창에서 동일 정본을 공유한다는 근거로 쓰지 않음 |
| 공유 Undo/Redo | edit stack은 모델에 연결되고 편집 전후 선택을 기록한다 [S3] | 문서의 편집 순서로 공유 Undo. 원래 편집 뷰가 닫혀도 역연산·선택 snapshot 수명 유지 |
| Undo 선택 복원 | content change의 결과 선택은 포커스가 있는 cursor에 적용하며, 다른 cursor는 marker에서 선택을 복구한다 [S4] | 호출/포커스 뷰에 해당 Undo 선택을 복원, 다른 뷰는 delta 매핑. 모두 같은 선택으로 덮지 않음 |
| 뷰 전환과 Undo 그룹 | cursor focus setter 자체는 Undo stop을 만들지 않는다. 편집 operation의 before/after stop은 별도다 [S4] | 모든 뷰 전환이 항상 Undo stop이라는 주장을 철회. 정확한 그룹 규칙은 교차 뷰 타이핑·삭제·조합 종료를 동작 비교한 뒤 결정 |
| 비활성 커서와 삽입 affinity | 같은 위치의 두 cursor에 한쪽에서 `e`를 입력하면 두 cursor가 삽입 뒤 위치로 가는 회귀 테스트가 있다. marker는 선택 방향을 유지한다 [S1][S5] | 동일 위치의 접힌 caret는 삽입 뒤로, 범위 선택·역방향·삭제 겹침·UTF-8 경계는 별도 판정. 한 예를 모든 선택에 일반화하지 않음 |
| 스크롤 | ViewModel이 stable viewport를 캡처·복구하는 경로를 가진다 [S6] | 비활성 뷰를 편집 위치로 자동 점프시키지 않고 anchor를 매핑. 상단/접힘/랩/삭제로 anchor 소멸은 fixture와 화면 대조 |
| 접힘·표시 상태 | FoldingController는 editor contribution이고 view state를 저장·복원한다 [S7] | 접힘·스크롤·선택은 뷰별. 문서의 grammar와 표시용 테마/기하는 구분 |
| 검색 | editor별 find controller가 자체 FindReplaceState를 가진다. 이력/일부 옵션은 workspace 저장과도 연결된다 [S8] | 각 뷰의 활성 query·현재 결과·입력 owner를 유지. 검색 이력 저장과 현재 query 독립은 별개의 정책이며 기존 Maru 정책을 자동 변경하지 않음 |
| IME 조합 표시 | textarea onType이 compositionType을 호출하고 cursor는 모델 편집 operation을 실행한다. 조합 update는 공유 모델 내용에 반영되는 경로다 [S9][S16][S4] | 사용자 경험 목표는 반대 뷰에서도 입력 중인 문자가 보이는 것. 현재 Maru preedit를 정본에 넣는 구현은 기존 Undo/저장 계약과 달라 별도 결정. 공유 조합 projection으로 같은 표시를 제공할 가능성을 먼저 검토 |
| IME 포커스 이동 | textarea blur 시 아직 조합 중이면 내부 상태를 정산하고 composition end를 발생시키는 경로가 있다 [S9] | 원래 뷰의 거래를 정산하고 새 owner로 이동. AppKit marked/insert callback·확정 실패·중복 commit은 DOM 경로에서 자동 증명되지 않음 |
| 분할 방향·명령 | 공식 문서는 editor groups 분할과 Split Editor in Group을 구분한다. macOS 기본 Split Editor는 ⌘\, 방향별 명령도 존재한다 [D1][D2][S10] | 우선 기존 Maru pane에 같은 문서 뷰 생성. 우측 분할과 기본 shortcut을 후보로 하되 기존 Maru chord 충돌 확인. Split in Group은 기존 보류 유지 |
| 새 뷰 초기 상태 | group copy는 활성 editor view state를 가져오고 새 group을 focus하는 경로다 [S10][S11] | 원본 선택·스크롤·접힘 초기 상태 복사 후 독립 유지, 새 뷰 focus를 기본 권장. 실패 시 원래 레이아웃 유지 |
| 한 뷰/마지막 뷰 닫기 | 같은 editor가 다른 group에 남아 있으면 confirm을 생략한다. confirm 뒤와 save/revert 뒤 상태를 재검사한다. side-by-side/custom close 예외도 있다 [S12] | 일반 공유 뷰 하나 닫기는 dirty 확인 없음. 마지막 닫기는 최신 내용/연결 수 재검증. diff/merge/custom 흐름을 같은 규칙으로 무조건 합치지 않음 |
| 저장 순서·실패 | 진행 중 같은 version 저장은 재사용하고 다른 저장은 순서대로 queue한다. 성공 시 version이 같으면 clean, 오류 시 dirty와 error/conflict 상태를 설정한다 [S13] | 정본당 쓰기 직렬화·중복 요청 합류, 대상 세대/rename 검사, 실패 시 최신 내용 보존. 기존 내용 hash dirty·CAS는 유지 |
| Undo로 clean 복귀 | VS Code는 alternative version id가 저장 기준으로 돌아왔는지 확인한다 [S13] | 같은 사용자 결과를 기존 Maru saved_hash로 제공. 단조 revision을 dirty 기준으로 쓰지 않으며 VS Code 내부 version 표현을 복사하지 않음 |
| Save As 기존 대상 | 기존 target model이 있으면 그 모델을 사용하고 source snapshot으로 내용을 갱신·저장하는 경로가 있다. 대상 선택/overwrite 확인 경로는 따로 있다 [S14] | 두 정본·Undo를 합치지 않음. dirty 대상 덮어쓰기의 모든 확인 조건은 이번 소스 경로만으로 보장하지 못했으므로 Maru 충돌 선택 정책을 별도 확정 |
| 이름 없는/원격 문서 | 공식 설명은 untitled 미저장 복원을 포함하며 모델/저장 API는 URI를 사용한다 [D3][S2][S14] | 지원 표에 별도 항목으로 추가, 기존 untitled/원격 저장·백업 gate를 통과해야 split 노출. 모든 remote provider가 같은 정책이라는 추론은 하지 않음 |
| 재시작·Hot Exit | 공식 문서는 종료 시 미저장 복원과 Hot Exit 설정·window restore 설정을 구분한다. backup 서비스는 URI/type과 checkpoint version을 다룬다 [D3][S15] | 문서 백업 하나·뷰 상태 각각. runtime generation을 영속 identity로 쓰지 않고 기존 별도 backup/schema 정책 유지 |
| 할당 실패·Undo 유실 | 읽은 JS/TS 소스에서 Maru의 allocator 실패 주입과 동등한 정상 복구 계약은 확인하지 못했다 | VS Code도 같다고 가정하지 않음. 현행 pushUndo의 기록 실패 뒤 이력 정책은 Maru 독립 반례·실패 주입으로 결정 |
| stale 편집·비동기 종료·권한 | model 편집과 save 순서는 참고 가능하지만 Maru의 L4/AppRuntime·grant·AppKit 수명에 그대로 대응하지 않는다 | 기존 writer/revision/handle generation과 자원 scope 계약 유지. VS Code 참고만으로 미결 구현 경계를 완료 처리하지 않음 |

## 무엇을 결정할 수 있고 무엇을 더 검증해야 하나

VS Code를 기본 UX 근거로 삼을 권장안은 공유 Undo, 포커스 뷰의 Undo 선택 복원, 다른 뷰의
marker 대응 좌표 매핑, 초기 view state 복사, 뷰별 접힘/검색, 일반 공유 뷰의 마지막 닫기 확인,
저장 직렬화·중복 합류다. 2026-10-01 사용자가 VS Code 기준 UX 채택을 승인했다. 목표 계약은
[레이어 배치 §2.4a](native-editor-layering.md)에 반영했다. 제품 구현/실제 OS 검증 완료는 아니다.

IME는 중요한 차이가 있다. VS Code의 확인한 textarea 경로는 조합 중에도 모델을 고친다.
Maru는 현재 preedit를 확정 문서와 분리한다. 표시 경험을 맞추려면 반대 뷰에 같은 조합 projection을
보이는 방법과 정본 조합 편집 방법을 비교해야 한다. 검색·저장·LSP·Undo가 preedit를 어떻게
관측할지까지 결정하기 전에 모델 편집 방식을 그대로 채택하지 않는다.

아직 확인이 필요한 것은 교차 뷰 Undo 그룹의 정확한 경계, dirty 대상 Save As 확인/복원,
macOS 실제 IME blur·실패·재시도, 원격 provider/창 이동의 범위다. 할당 실패·권한·스레드 수명은
VS Code와 런타임이 달라 Maru 판정자로 닫는다. 이번에는 소스/문서 조사만 했고 GUI 실측은 하지 않았다.

## 고정된 1차 출처

[D1]: https://code.visualstudio.com/docs/configure/custom-layout
[D2]: https://code.visualstudio.com/docs/reference/default-keybindings
[D3]: https://code.visualstudio.com/docs/editing/codebasics#_hot-exit
[S1]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/test/browser/controller/cursor.test.ts#L6327-L6351
[S2]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/common/services/modelService.ts#L307-L460
[S3]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/common/model/editStack.ts#L20-L240
[S4]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/common/cursor/cursor.ts#L86-L604
[S5]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/common/cursor/oneCursor.ts#L45-L70
[S6]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/common/viewModel/viewModelImpl.ts#L267-L470
[S7]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/contrib/folding/browser/folding.ts#L68-L216
[S8]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/contrib/find/browser/findController.ts#L101-L205
[S9]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/browser/controller/editContext/textArea/textAreaEditContextInput.ts#L108-L470
[S10]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/browser/parts/editor/editorCommands.ts#L749-L781
[S11]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/browser/parts/editor/editorGroupView.ts#L1471-L1551
[S12]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/browser/parts/editor/editorGroupView.ts#L1738-L1894
[S13]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L600-L1012
[S14]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/services/textfile/browser/textFileService.ts#L431-L648
[S16]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/editor/browser/controller/editContext/textArea/textAreaEditContext.ts#L310-L437
[S15]: https://github.com/microsoft/vscode/blob/4fee1b66c3ce4d5c43b30999caabd9c37834d9c9/src/vs/workbench/services/workingCopy/common/workingCopyBackupService.ts#L1-L220

근거는 각 링크의 공개 동작/책임만 참고했다. 자료구조 레이아웃·함수 분해·control-flow를 Maru로
옮기지 않는다. 소스 버전이 달라지면 관찰도 달라질 수 있어 commit permalink를 사용한다.

## 추가 재조사 (2026-10-01)

최신 main `14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4`의 기존 23개 파일은 위 commit의
내용과 같았다. 추가로 `cursorTypeOperations.ts`, `cursorTypeEditOperations.ts`,
`textFileService.test.ts`, `textFileEditorModel.test.ts`를 읽었다. 소스 총 27개이며 테스트 실행은 아니다.

- [타이핑 경계 규칙](https://github.com/microsoft/vscode/blob/14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4/src/vs/editor/common/cursor/cursorTypeEditOperations.ts#L965-L994)과
  [cursor의 모델 변경 처리](https://github.com/microsoft/vscode/blob/14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4/src/vs/editor/common/cursor/cursor.ts#L249-L274)를 함께 보면,
  비활성 뷰의 입력 종류가 Other로 정산된 뒤 다음 일반 타이핑에서 경계가 생기는 것으로 추론할 수 있다.
  단순 focus 전환 자체에 항상 stop이 있는 것과 다르며 교차 뷰 실제 입력을 fixture/GUI로 재확인한다.
- [Save As 동일 대상과 경로 identity](https://github.com/microsoft/vscode/blob/14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4/src/vs/workbench/services/textfile/browser/textFileService.ts#L407-L432)는
  동일 대상 저장과 같은 identity의 이동을 분리한다. 기존 대상은 target model 재사용 경로로 연결한다.
  모든 dirty 대상 확인 조건을 코드 일부만으로 일반화하지 않고 기존 Maru 충돌 선택을 유지한다.
- [저장 테스트](https://github.com/microsoft/vscode/blob/14b9d22f9a980b451aacff4b0ed3864ca2a1b7c4/src/vs/workbench/services/textfile/test/browser/textFileService.test.ts#L76-L91)는
  Save As 동일 대상에서 dirty가 정산되는 사례를 포함한다. 두 dirty 모델 대상 충돌·실제 파일 대화상자의
  overwrite 조건까지 이 테스트가 증명하는 것은 아니다.

표의 권장안은 위 계약의 채택 전 비교 기록이다. 현재 승인된 UX와 남은 구현 gate는 §2.4a와
공유 문서 계획을 읽는다. VS Code 코드 표현은 계속 복사하지 않는다.
