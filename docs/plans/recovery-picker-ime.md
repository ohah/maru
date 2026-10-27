# 복구 목록 검색창 IME 범위 문맥

상태: 범위 교체 실패를 재현한 뒤 구현했다. 중립 모델 Debug/ReleaseFast 각각 11개와 제품/발견 41개가 통과했다. 실제 두벌식 입력·후보 취소 5회·한자 확정·별도 Return 복구·편집 복귀도 확인했다. 전체 macOS 제품 회귀·기존 참조/심볼 IME·Swift·경계·문서 검사와 제품 변이 5종/정상·원복 대조군이 통과했다. PNG/OCR은 고정 앱의 화면 기록 허용을 기다린다.

## 보존할 계약

기존 editor-backup-discovery의 복구 정책을 유지한다. 목록은 읽기 전용 열거이며 선택한 백업은
기존 Source/버전/claim 검사를 거쳐 새 미저장 문서로 연다. 후보 Return이 복구를 실행하지 않으며
별도로 누른 Return만 기존 accept를 따른다. 실제 사용자 백업은 검증에 사용하지 않는다.

query/preedit는 원문을 유지한다. 필터 비교에만 기존 composeHangul과 label/name ASCII fold를 적용한다.
preedit는 표시만 하고 확정 query만 필터에 게시한다. 새 길이 제한·정규화·삭제 권한을 추가하지 않는다.
범위·선택·취소·키 snapshot/rollback은 공용 overlay_input_ime.Projection/Transaction을 재사용한다.
palette의 기존 range projection으로 표시와 caret을 연결한다.

## 필터 준비와 게시

중립 chrome.components.recovery_filter.Plan이 비교용 한글 조합·label/name 매칭·선택 신원 계산을 소유한다.
recovery.prepareFilter(query)는 catalog와 registry 상태를 읽어 그 Plan에 제공하고 새 shown을 준비한다.
성공 뒤 publishFilter가 결과/프롬프트/filter_failed와 선택/스크롤을 함께 게시한다. 기존 refresh와
recompute도 같은 API를 사용해 필터 판정을 복제하지 않는다. 실패한 native 키는 공유 snapshot으로
query/preedit를 복원하며 기존 결과·선택·스크롤·filter_failed·프롬프트를 보존한다.
기존 refresh 실패의 partial 표시와 복구 실행 금지 규칙은 유지한다.
query 변경 성공은 기존대로 선택 0/스크롤 초기화, 목록 갱신은 보이는 동일 후보 이름을 찾아 선택을
유지하고 사라진 경우에는 기존 인덱스 clamp를 따른다.

## owner 수명과 목록 갱신

owner는 열기 세대와 활성 surface에 묶는다. catalog가 없거나 bootstrap/빈 topology/terminal pin/
세대 포화이면 입력을 닫는다. bit 51 namespace를 사용하고 Session Dock 상한을 그 아래로 제한한다.
닫기/재열기·다른 입력 owner·surface 전환에서는 이전 콜백을 차단한다.

같은 Catalog의 append/완료/실패 상태 갱신은 입력 owner를 교체하지 않는다. 열거 때문에 두벌식 조합을
끊지 않고 tick은 확정 query로 필터를 준비한다. 키 확정도 동기적으로 최신 catalog에 대해 준비한 뒤
게시하며 중간에 이벤트 루프로 돌아가지 않는다. claim·파일 검사·문서 복구·백업 쓰기는 기존 경계가 소유한다.

## 검증

격리된 candidate fixture에서 a😀z의 UTF-16 (1,2) 교체 실패를 먼저 재현한다. 범위·NFD 원문/비교 조합·
비-BMP·잘못된 UTF-8·빈 입력·candidate Return·동적 길이·다중 콜백·전체 할당 실패·다음 키 회복,
열기/owner/포화 전환과 목록 append 중 조합/선택 보존 등 20개 이상 조건을 검사한다.
실제 private backup fixture에서 후보 Return 복구 0회와 별도 Return 복구 1회, 원본 보존을 확인한다.
컴파일되는 제품 변이 5종과 정상/원복 대조군, 기존 복구/참조/심볼 IME·전체 ABI·경계·Swift·문서 검사를 수행한다.
실제 두벌식 후보 취소 5회·한자 선택·별도 Enter 복구·에디터 복귀와 PNG/hash/OCR은 별도로 확인한다.
백업·원시 산출물·이미지는 저장소 밖에 두고 이미지는 PR 본문에만 업로드한다.

## 현재 확인한 결과

UTF-16 (1,2) 교체에서 `a😀z韓`로 뒤에 붙던 경로를 공용 범위 projection으로 연결해 `a韓z`로 바꿨다.
목록은 필터 준비 성공 뒤 한 번에 게시하며, 할당 실패는 query/preedit와 기존 목록·선택을 보존한다.
열거 진행을 입력 owner에 포함하지 않아 실제 private 디렉터리의 추가 발견 중에도 조합이 이어진다.
실제 백업 제품 검사는 후보 Return에서 문서 수가 그대로이고 별도 Return에서 dirty·무경로 문서가
하나 늘며 원래 디스크 내용이 유지되는 것을 확인했다. 이 검사는 실제 HID 증거와 구분한다.

집중 검증은 `mise exec -- zig build test-recovery-picker-ime -j2`다.
`tools/recovery-picker-ime/mutations.py --output <새 외부 경로>`는 컴파일되는 제품 변이를 검증한다.
`python3 tools/recovery-picker-ime/run.py --output <새 외부 경로> --mode diagnostic`는 격리 백업을
만들고 실제 입력·취소·확정·복구·편집 복귀를 확인한다. `--mode live`만 후보창 PNG/OCR 증거를 검사한다.
선택 백업은 복구 이후 새 백업의 durable 게시가 끝나면 기존 정책에 따라 이행·삭제될 수 있다.
원본 파일 보존과 후보 Return 이전의 복구 금지를 이 정책과 혼동하지 않는다.

실제 진단의 첫 시작은 앱 활성 상태를 얻을 때까지 대기했고, 다음 실행에서는 검증 도구가 초기 문서 수를
복구로 센 문제가 드러났다. 시작 문서 수를 기록해 추가된 수만 관측하도록 수정했다. 실제 입력 완료 뒤에는
참조 피커와 달리 복구가 새 surface를 만든다는 독립 검사기 계약을 바로잡았고, 같은 원시 기록을 재판정했다.
새 surface는 원본과 달라야 하고 편집 복귀까지 같아야 한다. 원본 surface 재사용과 편집 중 surface 변경을
손상 대조군에 추가했다. 실제 OS 진단과 재판정은 `maru-recovery-picker-ime-diagnostic-3` 외부 경로에 보존했다.
