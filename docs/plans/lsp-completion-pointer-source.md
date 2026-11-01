# 자동완성 행 클릭의 원본

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

행 클릭은 그려진 목록의 그 행을 확정한다. 현재 mouseDown이 handleKey(Enter)를 재사용해
새 키보드 focus 검사를 거치므로, A 목록이 계속 보이는 split에서 B focus 상태로 A 행을
눌러도 확정되지 않는지 실제 제품 pointer 경로로 확인한다.

기존 Enter/Tab의 선택 항목 확정 본문을 private acceptSelected로 분리한다. 키보드는
기존 focused source 검사 뒤 호출하고, mouseDown은 기존 docs 우선·padding·row hit 및
보이는 원본 검사를 통과한 뒤 호출한다. 클릭은 명시적으로 선택한 행의 원본에 적용하며
새 pane focus 이동 정책은 추가하지 않는다. 원본이 더 이상 보이지 않으면 취소해 다른
문서를 편집하지 않는다. L2 편집/원자적 resolve/Undo 규칙은 그대로다. 새 상태·ABI는 없다.

## 검증

실제 frame/overlay draw receipt를 만든 뒤 focus만 바꿔 다음 frame 전 mouse()를 호출한다.
split과 같은 pane, 정상 원본, resolve 대기, docs/padding/outside와 잘못된 좌표를 대조한다.
키보드 focus 회귀도 다시 실행한다. 직접 결과 전달과 native pointer/controller 증거를
실제 AppKit/HID/픽셀로 확대하지 않는다. 로그는 외부 Library/Caches/maru-verification에 둔다.

## 발견과 대조

수정 전 컴파일된 5개 중 행 클릭 행동 검사가 A 본문 기대 print_old/실제 pr로 실패했고
초기화 4개만 통과했다. 키 원본 검사가 명시적 행 클릭에도 적용된 것이 원인이다.
Enter/Tab 본문은 그대로 acceptSelected로 옮기고, 행 hit에서만 보이는 원본을 확인한 뒤
공통 transaction을 호출한다. 키보드 guard와 문서 패널/패딩/pending 클릭 순서는 유지한다.

CMPPOINTER1은 같은 pane/split의 단일·겹클릭 down과 B focus/선택/본문 보존을 확인한다.
CMPPOINTER2는 문서 패널과 padding의 세 down 종류를, CMPPOINTER3은 바깥과 NaN/Inf를
대조한다. 잘못된 좌표만 component 직접 호출로 검사한다. CMPPOINTER4는 pending 중
재클릭 취소와 late resolve를, CMPPOINTER5는 같은 원본 확정/Undo를 확인한다.
CMPPOINTER6은 미해결 행의 explicit click이 보이는 원본의 import까지 기다려 원자적으로
적용되고 Undo되는지, 숨겨진 원본은 취소되는지 확인한다. 정상/늦은 결과는 직접 전달한다.

테스트 좌표의 signed 정수 나눗셈 컴파일 오류는 @divTrunc로 고쳤다. 이 로그는 행동
성공/실패 증거로 세지 않는다. 현재 집중 10개와 기존 키 원본 9개가 통과했다.
공유 fixture는 resolved/prefetch/pending 준비를 구분하고 실제 metadata로 문서 패널을 그린다.
새 상태 필드가 없어 ABI는 252다. 원시 기록은 `lsp-completion-pointer-*.log`, 적대적 조건은
외부 `lsp-completion-pointer-adversarial.json`에 보존한다.

최종 Debug/ReleaseFast 포인터 집중 10개·전체 자동완성 43개·키 원본 9개씩, Debug의
상세 요청 종료 9개·중립 확정 계약 32개·overlay 7개, ABI 라이브러리 빌드, 문서 링크·
줄 참조·전체 경계와 format 검사가 통과했다. 초기화를 고유 합계로 더하지 않는다.
적대적 28조건과 같은 원본 정상 대조를 기록했다. 원격 CI와 머지는 로컬 결과와 별개다.
