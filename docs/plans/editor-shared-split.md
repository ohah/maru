# 공유 편집기 분할 명령

상태: 같은 창의 일반 로컬 파일에 공개 명령 구현 완료. AppKit 실행·재시작·실제 한국어 HID와 전체 에디터 회귀를 검증했다. 사용자 승인 범위는 #4125 머지 뒤 기존 공유 pane을 메뉴·팔레트·단축키에 연결하는 것이다.

## 동작과 지원 범위

계약은 [네이티브 공유 뷰](../native-editor-layering.md#24a-vs-code-기준-공유-뷰-ux-2026-10-01-사용자-승인)와
[분할 배치](../tabs-splits-layout.md)가 소유한다. 초기 뷰 상태 복사, 새 뷰 포커스, 공유 본문·Undo와
독립 선택·스크롤·접힘·검색은 기존 `splitSharedEditorPane`을 사용한다.

| 입력 | 동작 |
|---|---|
| 편집기의 `⌘\` | `split_editor_right`: 같은 문서를 오른쪽 새 pane으로 연다 |
| View 메뉴·팔레트·사용자 바인딩 | `split_editor_right`·`split_editor_left`·`split_editor_down`·`split_editor_up` |
| 사용자 rebind·terminal macro·unbind | 기존 키 해석 순서대로 기본키보다 우선한다 |
| 일반 로컬 파일 | 공유 뷰 생성과 workspace 재시작 복원을 지원한다 |
| 이름 없는 문서·원격 문서/캐시·diff·merge·비편집기 | 분할을 거절하고 레이아웃·포커스를 유지한다 |
| Quick 창의 탭 비허용 상태 | 새 pane을 만들지 않는다 |
| 공유 문서의 일부 뷰만 다른 창으로 이동 | 이동 전에 안내하고 거절한다. 단일 뷰/공유 뷰 전체 이동과 같은 창 안 이동은 허용한다 |

메뉴는 클릭 명령만 보내고 `keyEquivalent`를 등록하지 않는다. 키 해석기는 편집기 컨텍스트에서만
기본키를 소유하며, 팔레트·키 설정은 현재 유효한 바인딩을 표시한다. 기존 터미널 분할 action과
`⌘D` 다중 선택은 같은 동작을 유지한다. 저장하지 않은 편집을 가진 로컬 파일도 지원한다.
이름 없는 문서와 원격 문서의 공유 복원, 창 간 공유, Split in Group은 별도 단계다.

AppKit의 메뉴·단축키는 기존 공통 정책대로 원래 입력 대상의 조합을 먼저 확정한다.
확정이 거절되면 분할 명령도 실행하지 않는다. 그 이후의 Zig 분할 진입점은 지원 범위를
조합 확정보다 먼저 검사하므로, 직접 명령 호출이 지원 밖 문서의 조합을 추가로 정산하지 않는다.

## 검증 경로

- 공개 문자열 명령 네 방향 → 같은 정본·새 뷰 포커스·독립 검색과 초기 선택 복사.
- 실제 키 라우팅 → 기본키·비편집기/diff·rebind·unbind·macro·모달.
- 지원 밖 문서의 직접 명령과 확정 거절 → pane·정본·기존 조합 보존. 할당 실패 → 기존 내부 분할 회귀.
- 기존 AppKit 재시작 하네스의 분할 시작을 공개 명령으로 바꾸고 화면·재시작·IME를 대조한다.
- 메뉴·팔레트 발견성 및 실제 키 실행을 화면과 입력 기록으로 확인한다.

## 확인된 결과와 수정 사항

공개 명령을 연결하기 전 새 테스트는 문자열 명령·기본키·지원 밖 문서의 직접 호출에서 실제 런타임 실패를 냈다.
구현 후 네 방향의 배치와 정본 identity, 새 뷰 포커스, 복사한 선택과 독립 검색을 확인했다.
`test-editor`·`test-editor-shared-split`·`test-editor-chord-menu`, 일반 `macos-app-bundle` 빌드,
문서 링크/좌표/config 검사도 통과했다. [로컬 검사 기록](../evidence/editor-shared-split-20261004/verification.json)은
명령·로그 hash·대상 코드 커밋을 기록하며, CI 결과는 PR #4126에서 확인한다.
기존 내부 분할의 공유 Undo·마지막 뷰 닫기·접힘 독립성·모든 준비 할당 실패 검사도 유지한다.

검증에서 편집기 기본키를 사용자 rebind·macro·unbind로 가렸는데도 `chordForAction`이 그 키를
표시하는 오류를 찾았다. 실제 해석기와 같은 우선순위로 기본키를 걸러 팔레트/키 설정의 표시를 맞췄다.
명령 추가로 검색 결과가 늘어난 팔레트·설정 테스트도 실제 여섯 항목과 대조하도록 갱신했다.

공개 분할 → 한 pane을 새 워크스페이스로 이동 → 그 워크스페이스만 다른 창으로 이동하면,
이동은 성공하지만 두 뷰 모두 입력을 거절하는 반례를 실제 AppSession에서 재현했다.
공유 편집 coordinator는 한 창의 모든 뷰를 갱신하므로 일부 뷰만 창 밖으로 보내면 참조 수가 맞지 않는다.
이동 범위가 문서의 모든 뷰를 포함하는지 기존 닫기 범위 판정으로 검사하고, 조합 정산·탐색기 등록·
트리 변경 전에 안내 후 거절한다. 양쪽 어느 뷰를 옮겨도 한글 preedit·선택·정본·트리를 보존하며,
거절 후 입력과 정상 전체 이동 뒤 원래 창 종료/입력도 검사했다. 같은 창 안 이동도 유지한다.
검사를 제거하거나 모든 편집기 이동을 막는 변이는 런타임 실패했고 같은 의미의 조건식은 통과했다.
[이동 변이 결과](../evidence/editor-shared-split-20261004/move-mutations.json)를 보관한다.

| 실행 | 확인된 동작 | 증거 |
|---|---|---|
| AppKit 로컬 `⌘\` 이벤트 | 기본키로 오른쪽 공유 pane 생성 후 작은/큰 문서 재시작 | [keyboard](../evidence/editor-shared-split-20261004/keyboard.json) |
| 실제 NSMenu 항목 실행 | 네 방향 항목과 빈 `keyEquivalent` 존재, 오른쪽 항목으로 분할·재시작 | [menu](../evidence/editor-shared-split-20261004/menu.json) |
| 실제 팔레트 입력·Enter | `Editor: Split Right` 검색 결과와 `⌘\` 표시, 실행 뒤 두 pane 복원 | [palette](../evidence/editor-shared-split-20261004/palette.json) |
| 일부 공유 뷰의 창 이동 거절 | 제품 API에서 본문·트리 보존과 실제 Metal 안내 표시. 목적지는 헤드리스 AppSession | [move-refusal](../evidence/editor-shared-split-20261004/move-refusal.json) |
| NSTextInputClient 콜백 | 공개 분할 뒤 조합/확정·멀티커서·Undo·저장, `cat cat`과 독립 선택 재시작 보존 | [callbacks](../evidence/editor-shared-split-20261004/callbacks.json) |
| 실제 macOS 두벌식 HID | 공개 분할 뒤 A→B→A 조합, `L가 R나` 단일 반영·저장, 원래 입력 소스 복원과 독립 선택 재시작 보존 | [live-ime](../evidence/editor-shared-split-20261004/live-ime.json) |

메뉴·팔레트·단축키 실행은 약 60 KB/1.2 MB 문서에서 각각 seed·첫 프레임·복원 프로세스로 검사했다.
본문 hash·dirty·선택·wrap·접힌 머리 hash·맨 위 원문 줄·wrap 조각·가로 위치가 보존됐고,
960×600 → 640×480 → 1200×800 리사이즈와 원본 디스크 불변·백업 하나도 확인했다.
모든 보고서의 `issues`가 비었다. 분할 전 화면·팔레트·분할 뒤 두 pane의 제품 Metal PNG를 직접 확인했다.
증거는 하네스 관측기를 붙인 앱/소스 hash와 프로세스 ID, 원본 캡처 경로/hash를 담는다.

분할 축·앞/뒤 배치·공개 dispatch·지원 검사 순서·가려진 단축키 표시를 잘못 바꾸면
새 회귀 테스트가 각각 런타임 실패를 내는지 확인했다. 같은 뜻의 좌우 조건식은 통과했다.
[변이 결과](../evidence/editor-shared-split-20261004/mutations.json)는 변경한 식, 실제 실패,
로그 hash와 원복한 소스 hash를 기록한다.

창 이동 수정 빌드에서 `--move-refusal`의 한국어 안내 화면을 직접 확인했다.
같은 새 빌드의 [키 분할·작은/큰 문서 재시작](../evidence/editor-shared-split-20261004/post-move-keyboard.json)과
[IME 콜백·저장·재시작](../evidence/editor-shared-split-20261004/post-move-callbacks.json)도 `issues=[]`였다.
이동 거절의 목적지는 헤드리스 AppSession이므로 실제 두 OS 창 사이 메뉴·드래그의 증거로 세지 않는다.

## 남은 범위

AppKit 로컬 이벤트와 NSTextInputClient 콜백 주입은 실제 OS 입력기/HID 증거가 아니다.
잠금 해제 뒤 `python3 tools/shared-restore-app/run.py --only-ime`로 새 빌드의 실제 두벌식
A→B→A 조합·확정·저장·재시작을 검사했다. `setMarkedText` 네 번과 본문 단일 반영,
두 커서 byte 4/9 보존, 원래 입력 소스 복원, 실패 0을 확인했다. 이 드라이버는 공유 분할을
공개 action으로 준비하며 실제 물리 `⌘\` 이벤트 자체를 판정하지 않는다.
이름 없는/원격/비교/병합 문서의 공유 분할과 창 간 공유, 자연 발생하지 않은 늦은 OS 콜백은 이 범위 밖이다.

