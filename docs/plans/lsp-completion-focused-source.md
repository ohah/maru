# 표시 중인 자동완성의 키 입력 원본

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

A의 목록이 열린 채 B에 활성 입력 원본을 바꾸면 triggerManual이 A의 상세 패널만
토글하고 B 요청을 보내지 않는지 확인한다. handleKey도 이전 목록의 키를 소비해 B의
Enter/Tab을 삼키거나 다른 pane의 A에 적용하는지 제품 키 경로로 재현한다.

키와 명령은 현재 활성 editor의 원본에 귀속된다. 기존 L2 completion_ops에 sourceMatches
동일성 계약을 두고 기존 requestDisposition도 이를 사용한다. host는 active 원본과 현재
활성 surface를 조회해 다르면 기존 cancel로 이전 목록을 취소한다. triggerManual은 이후
B 요청을 계속하고, handleKey는 false로 반환해 B의 원래 편집 키가 처리되게 한다.
같은 원본의 상세 패널 토글과 확정은 유지한다. 새 상태/ABI 필드는 없다.

## 검증

실제 목록 설치와 제품 frame/활성화/키 경로를 사용한다. 같은 pane의 다른 문서와 두 pane을
구분한다. 명령·키 할당·Enter/Tab/화살표/Esc, 오래된 resolve와 정상 같은 원본 대조를
검사한다. 순서 제어용 직접 응답은 실제 SDK/HID/픽셀과 구분한다.
마우스 히트/클릭의 focus 전환 정책과 모든 문서 교체 세대는 이번 범위 밖이다.
원시 로그와 적대적 조건은 외부 Library/Caches/maru-verification에 둔다.

## 발견과 대조

수정 전 6개로 컴파일된 gate에서 명령 전송 수가 기대 2/실제 1로 실패했고, B Enter도
본문에 전달되지 않았다(초기화 4개만 통과). 수정 후에는 같은 focus의 키만 소비한다.
키 검사만 제거한 대조 실행은 컴파일에 성공한 뒤 split의 B Enter가 A의 `pr`을
`print_old`로 바꿔 실패했다. 원본 completion.zig를 복구했고 SHA-256
`225ce6f831c244d7bcc0f05bafccd136eea283438d3fd4e2e00e05cd3768114f`가 백업과 일치했다.

CMPFOCUS1/2는 같은 pane와 split의 명령·Enter를 확인한다. CMPFOCUS3은 두 배치의
Enter/Tab/위·아래/오른쪽/Esc/Control-Space/Option-Esc를 목록 없는 별도 fixture와 비교한다.
CMPFOCUS4는 원본으로 돌아온 뒤 상세 패널 토글과 정상 확정/Undo를 유지하는지 확인한다.
CMPFOCUS5는 두 배치와 명령/Enter 각각 A의 pending resolve를 취소하고 late import 응답이
A/B 어느 문서도 잘못 바꾸지 않는지 확인한다. 늦은 결과는 직접 전달한다.

현재 집중 9개(행동 5개, 초기화 4개)가 통과했다. 새 State 필드가 없어 ABI 252를 유지한다.
L2 sourceMatches를 기존 requestDisposition도 사용해 원본 동일성 규칙을 공유한다.
원시 실패/대조/최종 로그는 `lsp-completion-focus-*.log`, 적대적 조건과 정상 대조는
`lsp-completion-focus-adversarial.json`에 보존한다.

최종 Debug/ReleaseFast 집중 9개·전체 자동완성 37개씩, Debug 중립 확정 계약 32개·
상세 요청 종료 9개·overlay 7개, ABI 라이브러리 빌드, 문서 링크·줄 참조·전체 경계와
format 검사가 통과했다. 모듈 초기화를 고유 합계로 더하지 않는다.
적대적 26조건과 정상 대조를 기록했으며 원격 CI와 머지는 로컬 결과와 별도로 확인한다.
