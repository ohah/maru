# 프로젝트 검색 AppSession owner 연결

상태: 현재 창의 지정된 로컬 root에 대한 요청·문서 사본·IME·worker 수명 연결. [여러 root 연결](editor-project-search-roots.md)은 요청 전체의 사본·후보 합집합·결과 예산을 추가한다. 검색 도크·클릭 이동·제품 기본 예산과 실제 HID/앱 측정은 [도크 검증](editor-project-search-dock.md)에 연결했다.

## 요청과 사본

`AppSession.requestProjectSearch`가 검색어·glob 옵션의 사본과 호출자가 명시한 예산을 소유한다. 교체 요청은 하나이며 이전 worker를 취소하고 완료를 관측한 뒤 시작한다. 요청 번호와 문서·root·감시 상태의 fingerprint가 다른 batch와 completion은 전달하지 않는다.

`owner.Prepared`는 프레임마다 최대 32개 surface를 준비한다. 이 수는 capture 호출 수의 한도이며, 전체 surface fingerprint 순회나 조합 문자열·커서 정렬 비용의 시간 상한은 아니다. 본문은 O(1) rope snapshot이며 문서·선택·Undo를 바꾸지 않는다. 현재 창의 공유 문서는 registry/slot/generation으로 한 번만 캡처하고 독립 문서는 합치지 않는다. 경로는 main에서 파일 I/O 없이 lexical 정규화한다. 생성·닫기·Save As·편집 revision·조합 문자열/범위·root/감시 변경은 준비와 결과를 무효화한다. 배치 cursor는 터미널도 세므로 터미널 삽입·닫기 역시 fingerprint에 포함한다.

IME callback transaction과 pending commit 사이에는 시작하지 않고, 기존 batch와 completion도 전달하지 않는다. 대기 중에는 결과를 소비하지 않으므로 transaction이 끝난 뒤 신원이 그대로면 같은 결과를 전달할 수 있다. transaction 밖의 marked text는 주 커서의 교체 범위와 보조 선택 범위를 정규화한 뒤 소유한 overlay로 캡처한다. worker가 원문 snapshot의 조각을 복사하며 비겹침 overlay를 적용한다. 조합 범위의 UTF-8 경계·overflow·예산·취소를 검사한다. 조합 결과의 좌표는 **조합이 적용된 검색 subject**의 좌표다. 정본 revision만 맞는다는 이유로 정본 선택에 바로 적용하면 안 된다. S2 클릭은 composition 신원도 재검증해야 한다.

본문/overlay 예산을 넘긴 공유 문서는 제외하고 경로 점유를 유지한다. 미지원 web editor도 점유·제외하며 디스크의 옛 본문을 대신 보여주지 않는다. 준비 자체의 할당 실패는 실행 실패로 남기고 disk 작업을 시작하지 않는다. 고정된 입력·신원에서 시작이 실패하면 매 프레임 같은 실패를 반복하지 않는다.

## 감시와 실행

root index는 현재 탐색기의 root 중 하나다. 미검증 root나 원격 활성 pane에서 로컬 검색을 시작하지 않는다. 상위 root의 capability를 자식 root의 검증으로 사용하지 않는다. worker는 탐색기가 검증한 device/inode와 실제 연 root를 비교한 뒤 모델을 검색한다.

Swift `MaruFileTreeWatcher`가 실제 stream 시작에 성공한 후 ABI로 현재 root generation을 확인한다. 처리되지 않은 감시 요청/reset이나 옛 generation의 확인은 검색 시작을 허용하지 않는다. stream stop/rebuild는 확인을 먼저 지운다. FSEvents의 coarse/overflow/root 변경도 기존 root 변경 콜백을 통해 전체 검색을 무효화한다. root 밖 symlink 대상의 감시 보장을 추가한 것은 아니다.

앱의 `global_single_threaded` I/O는 프로세스 실행에 필요한 할당을 지원하지 않았다. 실제 AppSession 실행에서 helper가 `OutOfMemory`로 실패하는 것을 재현했다. worker가 allocator를 가진 실행 I/O를 소유하고 완료 전에 정리한다. 환경은 main actor에서 소유한 사본으로 잡아 helper에 전달하며 환경 값을 로그에 남기지 않는다. helper 선택은 제품에서 현재 앱의 `Contents/Helpers/rg`이며 테스트 전용 명시적 helper는 `builtin.is_test` 분기에만 있다.

## 종료

창 teardown은 요청을 취소하고 worker 참조를 놓는다. 테스트에서는 기존 `quietDetachedWorkersForTest` 한 자리에서 worker 참조가 정산될 때까지 기다린다. 마지막 앱 종료의 성공 reply는 검색 worker의 최종 참조 해제를 관측한 뒤 전달한다. MainActor에서 join/sleep하지 않고 common run-loop timer로 확인한다. 열린 창뿐 아니라 이미 닫힌 창의 detached worker도 전역 counter에 남는다. blocking filesystem 호출 자체의 벽시계 상한을 새로 보장하지 않는다.

## 경로 별칭 처리와 검증

이전에는 점유 키가 lexical 상대 경로의 바이트 문자열만 비교하여 `Case.txt`를 `case.txt`로 열거나 NFC/NFD 별칭을 사용하면 디스크의 옛 결과가 섞였다. 상위 폴더·include glob·snapshot 예산 제외·root 밖 링크에서도 재현했다.

`path.prepare`는 검증된 root를 연 뒤 **worker에서만** 각 상대 경로 구성요소의 저장된 이름을 읽는다. [Apple getattrlist(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getattrlist.2.html)의 `ATTR_CMN_NAME`과 `FSOPT_NOFOLLOW`를 사용한다. 마지막 구성요소의 링크를 따라가지 않으므로 `Link/file`의 `Link`를 물리 대상 이름으로 바꾸지 않는다. 다음 구성요소 조회는 디렉터리 링크를 통과하므로 root 밖 대상의 파일명도 처리한다. inode나 realpath로 별도 논리 경로를 합치지 않는다. `attrreference`는 현재 macOS SDK의 int32/u32 ABI로 읽고 범위·잘림·NUL·UTF-8을 검사한다.

점유 집합은 기존 키와 저장된 철자의 키를 함께 유지한다. 예산 제외·미지원 문서도 이 집합에 있으므로 디스크의 옛 본문을 되살리지 않는다. 캡처한 모델의 **소유한 사본 경로**도 같은 표기로 바꿔 include/exclude glob이 디스크와 같은 경로 축을 사용하게 한다. 정본 경로·document/revision/composition 신원·본문·Undo는 바꾸지 않는다. 아직 없는 이름은 확인한 부모 아래에서 나머지 원래 이름을 보존해 디스크에 없는 이름 있는 모델도 검색한다.

정규화가 끝난 뒤 root의 inode/device도 다시 검증하고, 그 전에는 모델/디스크를 검색하지 않는다. 할당 실패·메타데이터 해석/조회 실패는 요청 실패로 남기고 helper를 시작하지 않는다. 지원하지 않는 메타데이터나 접근 거절을 lexical 비교로 몰래 대체하지 않는다. 취소는 구성요소 사이에서 확인한다. 파일시스템 syscall 자체의 벽시계 상한은 새로 보장하지 않는다. 이 단계는 이미 준비된 **root 상대 경로**를 처리하며 절대 root 표기와 범위 입장의 전체 호환성까지 증명한 것은 아니다.

`path-occupancy-audit.py`로 이전 누출과 대조군을 다시 실행했다. 접근 거절 시 helper 없이 실패하는 대조군까지 총 21개 사례가 모두 통과했다. 파일명/폴더 별칭, 0건/예산 제외, 저장된 철자의 glob으로 모델만 있는 텍스트 검색, 없는 leaf, 내부/외부 링크, hardlink 교체를 대조한다. 별도 case-sensitive APFS 이미지에서 `Case.txt`/`case.txt` 및 `Folder`/`folder`의 서로 다른 inode를 확인했고, 한쪽 모델의 점유가 다른 쪽 디스크 결과를 가리지 않았다. 이 이미지 검사는 로컬 추가 검증이며 기본 CI의 모든 파일시스템을 증명하지 않는다.

진단은 `report.json`/`latest.json`을 남기고 0=계약 충족, 1=계약 결함, 2=검증 불완전이다. 재현되지 않은 별칭과 실행 오류를 성공으로 취급하지 않는다. OS별/파일시스템별 대조가 포함된 opt-in 진단이며 CI의 기본 성공 판정자와 구분한다. 소유권 판정자는 이 경로 정규화의 모든 할당 실패를 흔들어도 snapshot·경로·점유 키가 새지 않는지 확인한다.

전체 AppSession CI에서 EDPS4가 `FileNotFound`로 실패한 로그를 확인했다. 전용 owner 타깃에만 rg 준비가 연결된 것이 원인이므로 `test-macos-app-host-abi`의 샤드 실행과 `test-editor`에도 오프라인 helper 준비 의존성을 연결했다. 테스트를 건너뛰거나 외부 PATH helper로 대체하지 않는다.

## 검증과 남은 gate

- `zig build test-editor-project-search-owner`: 실제 AppSession의 shared IME callback·멀티커서 사본·원문 보존·배치 준비·무효화·미검증 root/transaction 거부·감시 확인 후 실제 rg 실행·편집 후 재검색·transaction 중 결과 보류·조합 준비/옵션의 모든 할당 실패·surface 순서/공유 view 닫기·예산 제외의 점유/중복 집계·요청 교체/거절과 owner 해제 후 worker 정산·실제 외부 쓰기/변경 콜백 후 미저장 모델 보존·수락된 마지막 view 닫기 후 디스크 전환·root 교체 중 최신 query/새 감시 세대 확인·native 모델의 저장된 철자/glob/신원/원래 경로 보존·메타데이터 참조의 잘림/오프셋 거절. 이 검사는 OS FSEvents 전달이나 닫기 확인 UI를 증명하지 않는다.
- `zig build test-macos-project-search-worker`: 기존 141개 helper/model 실패 경로와 소유권 검사. overlay 생성·literal/regex 실행의 모든 할당 실패와 UTF-8 중간 경계/역방향/범위 초과 거절도 포함한다.
- `zig build macos-app-host-swift-check` 및 `macos-app-host-abi-lib`: 실제 Swift/ABI 빌드.

전체 S1b 완료로 표시하지 않는다. [여러 root의 순서·중복 결과·전역 예산](editor-project-search-roots.md)은 별도 연결했고, 다른 파일시스템 및 절대 root 별칭/범위 입장의 전체 호환성, 전체 FSEvents·종료 경계는 남아 있다. 실제 두벌식 HID와 앱 RSS/첫 결과/취소·준비 tick의 표본은 [도크 검증](editor-project-search-dock.md)에 기록했다. S2 검색 도크·IME Enter·클릭·시각 검증과 제품 기본 예산을 이 API의 합성 검증으로 대체하지 않는다.
