# 표시된 코드 액션 메뉴와 새 목록의 문서 버전 분리

상태: 잘못된 본문 적용 재현·수정 및 최종 로컬 검사 통과. 원격 CI·머지는 별도로 확인한다.

표시된 메뉴의 edit/resolve 원본은 그 메뉴를 요청한 시점의 문서 버전을 따른다. 새 목록을
요청해도 표시된 이전 메뉴의 버전 기록을 바꾸지 않는다. 문서가 편집된 뒤 이전 메뉴를
선택하면 기존 WorkspaceEdit stale 검사가 거절해야 한다.

현재 pending/items는 분리되어 있지만 snapshotVersions가 공통 snaps를 덮어쓴다. 실제
메뉴 게시 뒤 실제 편집·새 quickFix 요청을 실행하고 이전 항목을 선택해 본문·Undo가
추가로 바뀌는지 재현한다. 바로 적용하는 항목과 resolve 항목, 새 결과가 대기/버려지는
경계와 정상 새 메뉴 적용을 구분한다.

새 목록용 pending_snaps를 별도로 캡처하고, pending 항목이 실제 items로
게시될 때만 공개 snaps를 교체한다. 선택 뒤 resolve_snaps로 복사하는 기존 계약은
유지한다. 기존 stale·전송·overlay·Save As 정책을 바꾸지 않는 원본 metadata 분리다.
State 필드 추가에 맞춰 macOS app-host ABI와 관련 버전 경계·변이 기준을 253→254로 동기화한다.

최소 20개의 서로 다른 조건과 정상 적용/Undo 대조, 기존 code action origin·resolve·
Save As·WorkspaceEdit 검사, Debug/ReleaseFast·ABI·문서·전체 경계를 확인한다.
직접 callback과 native controller·실제 파일을 구분하고 OS/HID/픽셀 증거로 확대하지 않는다.
원시 자료는 저장소 밖 `~/Library/Caches/maru-verification/action-menu-snapshot-*`에 둔다.

## 발견과 수정

실제 메뉴 게시 뒤 native editor controller로 `Z`를 앞에 넣고 새 quickFix를 요청했다.
이전 항목을 고르면 `Zint a; // CASTALL`이 `FIXEDt a; // CASTALL`로 바뀌고 Undo도
1개에서 2개로 늘었다. ready와 lazy 모두 재현됐다. 메뉴가 모달이라 일반 키 입력은
메뉴를 먼저 닫는다. 이번 재현은 메뉴가 유지되는 동안의 프로그램적 문서 변경과 새 요청
수명이며 실제 HID 조합을 재현했다고 설명하지 않는다.

snapshotPendingVersions는 새 요청의 pending_snaps만 기록한다. finish가 실제 items를
게시할 때만 snaps로 복사하고, clearPending은 pending 길이도 지운다. 이전 메뉴와 이미
선택한 resolve의 snapshot은 새 대기·버려진 응답으로 갱신되지 않는다. 기존 WorkspaceEdit
stale 검사와 Save As 원본 정책을 유지했다. 고정 상한 64개를 사용하며 새 동적 할당은 없다.

ready/lazy × 편집 전/후 × 대기/positive·null·error 버림/할당 실패/정상 게시의 24조건이
Debug/ReleaseFast 모두 통과했다. 편집된 문서의 이전 항목 거절 10조건과 정상 적용·Undo
14조건을 구분했다. 실제 디스크 파일은 모든 조건에서 보존됐다. 집중 gate는 행동 2개와
초기화 4개, 총 6개다. 기존 origin 10개·Save As 10개·WorkspaceEdit 21개도 두 모드에서 통과했다.

Debug의 ABI 라이브러리·전체 경계·문서 링크/좌표와 Zig 포맷·diff가 통과했다. 그 뒤 별도로
실행한 macOS 앱 호스트 ABI 전체 계약 집계도 exit 0이다. 빌드가 정한 샤드·fresh 분리와
skip/filter를 유지하며 등록 수를 passed 합계로 더하지 않는다. 새 CAMENU1/2와 버전 고정
검사도 집계에 포함됐다.

ABI drift의 실제 변이 기준을 격리 사본에서 254→253으로 적용했다. 원본/정상 사본/변이/
복원 사본의 종료 코드는 0/0/1/0이며 원본 소스 SHA는 그대로다. 이는 소스 경계 증거이며
실제 AppKit 입력 검증이 아니다. 관련 기존 필드·호출 검사를 약화하지 않았다.

원시 자료는 `action-menu-snapshot-behavior-before.log`, `action-menu-snapshot-after.log`,
`action-menu-snapshot-final-debug.log`·`action-menu-snapshot-final-releasefast.log`,
`action-menu-snapshot-abi-full.log`에 보존한다. 조건별 관측·최종 소스 SHA는
`action-menu-snapshot-final-cases.json`, ABI 음성 대조는 `action-menu-abi-mutation.json`이다.
