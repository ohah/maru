# 참조 결과 피커 IME 범위 문맥

상태: 범위 덧붙임 실패 재현과 수정 완료. 집중 호스트 42개와 제품 변이 5종·정상/원복 대조군 통과. 전체 ABI·경계·Swift·문서와 실제 입력·PNG/OCR 검증까지 통과했다.

## 보존할 계약

참조·구현·타입 정의·선언은 기존 reference_picker 하나를 공유한다. 기존 요청 seq/kind·늦은 응답 거절,
단일 오버레이, 0/1/여럿 결과 분기, root 밖 표시/접근 구분, 500행 상한과 파일 읽기 예산은 바꾸지 않는다.
제목·보조 텍스트의 ASCII fold 부분일치와 확정 query 필터를 유지한다. preedit는 표시만 한다.
후보 Return은 이동·닫기로 재생하지 않고 별도 Return만 기존 accept/navigateTo를 따른다.
query/preedit에 새 상한이나 Unicode 정규화는 추가하지 않는다.

범위·선택·취소·동적 snapshot/rollback은 기존 중립 overlay_input_ime.Projection/Transaction을 쓴다.
표시·caret은 palette의 기존 range_ime projection을 읽는다. host에 UTF-16 계산을 복제하지 않는다.

## 필터 API와 실패 원자성

Picker.prepareFilter(allocator)는 all 길이만큼 shown 용량을 확보하며 실패 시 기존 shown을 보존한다.
Picker.applyPreparedFilter(query)는 확보된 용량에서 기존 부분일치를 무할당으로 적용한다.
기존 applyFilter도 위 두 단계로 호출한다. 따라서 필터 알고리즘을 다른 host에 옮겨 적지 않는다.
native 키는 query publication 전에 용량을 준비하고, 실패하면 공유 key snapshot으로 query/preedit를
복원한다. 기존 shown·선택 행·탐색 이력은 바뀌지 않는다. 성공한 query 변경에만 결과와 선택 0을 게시한다.

## owner와 수명

owner는 피커의 열기 세대, 활성 editor surface/registry/document/revision, 결과 목록 세대와 명령 kind다.
Picker.clear/build는 결과 세대를 단조 증가시키며 필터만 바뀔 때는 증가시키지 않는다. 포화 시 닫힌다.
bit 52 namespace를 사용하고 Session Dock token 상한을 그 아래로 낮춘다. 새 응답·clear·닫기/재열기,
문서·revision·명령 종류·modal·terminal pin·빈 topology·포화에서 오래된 키를 목적지에 쓰지 않는다.
LSP transport의 응답 수락 규칙은 기존 references_client가 계속 소유한다.

## 검증

실제 editor/참조 행 fixture에서 a😀z의 UTF-16 (1,2)를 韓으로 교체할 때 기존 덧붙임 실패를 재현한다.
범위·비-BMP·surrogate split·NFD·잘못된 UTF-8·빈 입력·preview/cancel·후보/별도 Return,
행 필터/선택 보존·모든 할당 실패·다음 키 회복·결과 교체·문서/명령 전환 등 20개 이상 조건을 검사한다.
기존 filter 호출자도 OOM 뒤 shown이 보존되는지 검사한다. 컴파일되는 제품 변이 5종과 정상/원복 대조군을 둔다.
기존 참조/LSP·심볼 IME 회귀와 전체 ABI·경계·Swift·문서 검사를 수행한다.
실제 두벌식·후보 취소 5회·한자 확정·별도 Return 이동·에디터 복귀와 PNG/hash/OCR은 별도 증거로 기록한다.
이미지는 저장소 밖에 보관하고 PR 본문에만 업로드한다.

## 재현과 확인한 수정

기존 경로는 `a😀z`의 UTF-16 `(1,2)` 교체가 `a😀z韓`으로 덧붙었다. native range 연결 뒤
`a韓z`로 교체됐다. 기존 applyFilter는 먼저 shown을 비운 뒤 append하므로 메모리 부족 시
기존 결과를 잃었다. 준비/무할당 게시 API는 기존 호출자의 shown도 보존하도록 바꾼다.

호스트 artifact 42개(동작 37 + discovery 5)가 통과했다. 네 명령 kind, 새로운 결과/재열기와
문서 revision 전환, 무시된 늦은 LSP 응답, 다중 콜백 rollback, 모든 키 할당 실패, filter 용량 실패,
commitAll 실패의 preedit 보존을 포함한다. 심볼 IME 회귀도 통과했다.
범위 무시·기존 필터의 조기 clear·필터 게시 누락·결과 owner 무시·후보 Return 누출 제품 변이는
각각 컴파일 뒤 단언 실패로 검출됐고 원복 대조군이 통과했다.
`python3 tools/reference-picker-ime/mutations.py --output <new-external-dir>`로 재검증한다.

실제 입력 하네스는 owned fixture의 위치 응답을 기존 onLocationsResponse에 공급해 피커를 준비하고,
검색 편집·후보 열기/취소/확정·별도 Enter 이동·에디터 복귀는 외부 HID relay로 진행한다.
이 fixture 준비를 실제 LSP 서버 통신 증거로 계산하지 않는다. 독립 기록 손상 35개도 통과했으며
실제 OS·픽셀 증거와 구분한다. 원시 산출물은 `../maru-reference-picker-ime-os-20261027/`와
`../maru-reference-picker-ime-mutations-20261027/`에 보관하고 이미지는 PR 본문에만 올린다.

## 실제 입력 진단

실제 두벌식·후보 취소 5회·韓 확정·별도 Return 이동·에디터 복귀 `/` 진단이 통과했다.
후보 선택까지 revision 0·focus 0·history 0·PTY 0, 별도 Return 뒤 focus 34·history 1,
`/` 뒤 revision 1·focus 35·PTY 0이었다. 입력 소스 복원과 디스크 원본 보존도 통과했다.
고정 앱 hash는 `77fb241ce9fec9206b862e5ceddff4707fc0d44e446e5593335f850bb4c0f3d6`이며,
최초 화면 기록 조회가 false였으며 권한 허용 뒤 같은 앱으로 PNG/OCR까지 통과했다.
진단 결과는 `../maru-reference-picker-ime-os-20261027/diagnostic-2/`에 있다.

## 최종 검증 결과

전체 ABI 7,139개 중 7,020 통과·119 skip·0 실패. 경계·Swift·문서·fmt/diff 검사도 통과했다.
고정 앱의 `live-2`는 서로 다른 후보창 5개의 PNG/hash/크기·창 lifecycle과 독립 Vision OCR
(각 6행 이상)을 통과했다. `candidate_capture_verifier=passed`다. 후보 취소·韓 선택·별도 Enter
이동·실제 `/` 에디터 입력, 입력 소스 복원과 디스크 원본 보존도 통과했다.

첫 live는 macOS의 직접 화면 접근 추가 확인창으로 전경이 빠져 HID_owner에서 중단됐다.
이미 요청한 동일 앱 화면 접근 범위의 확인창을 허용한 뒤 앱/서명 변경 없이 재실행해 통과했고,
중단된 실행을 통과 증거로 넣지 않는다. 원시 창·PNG·키 receipt·manifest·제품 Metal 캡처와
독립 OCR 로그는 `../maru-reference-picker-ime-os-20261027/live-2/`에 있다.
실제 입력은 references 모드로 수행했다. 나머지 세 명령 kind의 공유 편집 동작은 호스트 검사 범위다.
실제 LSP 서버 전송이나 다른 picker/터미널 복귀까지 입증했다고 부르지 않는다.
