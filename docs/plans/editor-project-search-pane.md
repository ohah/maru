# 프로젝트 검색 결과 탭과 옵션 UI

사용자는 2026-10-09 검색 옵션 정리와 pane의 읽기 전용 결과 탭을 승인했다.
검색 도크는 빠른 입력·좁은 결과 탐색에 유지하고, `→`로 현재 결과 사본을 활성 pane의 새 탭에 연다.

## 참고와 선택

- [VS Code Search Editor](https://code.visualstudio.com/docs/editing/codebasics#_search-editor)의
  결과·문맥을 넓은 편집 영역에서 읽는 방식을 참고했다.
- [Zed 프로젝트 검색](https://zed.dev/docs/finding-navigating#project-search)은 pane 탭의
  editable multibuffer다. Maru의 이번 탭은 읽기 전용이며 여러 파일을 직접 편집하는 기능은 아니다.
- 옵션은 검색어 오른쪽 같은 행의 `Aa`, 밑줄 `ab`, `.*`로 배치한다.
  필터·실행·취소·바꾸기·돌아가기·결과 탭 열기는 아래의 별도 동작 행이다.
  입력 폭이 부족하면 옵션 세 개를 다음 줄로 옮겨 검색어 입력 폭을 보존하고, 좁은 폭은 동작 행을 두 줄로 나눈다. 아이콘은 외부 자산을 복사하지 않고 독립 제작했다.

## 구현 계약

- 네이티브 편집기 렌더·선택·복사·가로/세로 스크롤을 재사용한다. 검색 결과의 원문 행은 한 번만 복사하고,
  각 일치는 원문 행 인덱스와 범위 인덱스를 보관한다. 한 행에 일치가 많아도 범위 배열을 반복 복사하지 않는다.
- 검색 결과 본문은 기존 검색 결과의 제한된 문맥 사본이다. 생략된 결과는 `…`로 표시하며 원문 전체로 오인하지 않는다. 원문 전체는 검증된 Enter 이동으로 연다.
- 결과 탭은 자체 query·glob·root 경로/device/inode·결과 신원과 본문을 소유한다.
  도크 재검색·입력 변경·닫기로 그 사본을 해제하지 않는다. 설명에도 읽기 전용 사본임을 표시한다.
- 결과 제목 또는 문맥 행을 선택하고 Enter를 누르면 원문으로 이동한다. 설명·빈 구분 행에서는 이동하지 않는다.
  모델은 문서 신원·revision·composition을, 디스크는 기존 worker 재검색과 열린 전문 hash를 검증한다.
  root의 순서/경로/실제 신원이 바뀌면 이동하지 않는다. 낡은 좌표로 선택하지 않는다.
- 진행 중 조합·확정 transaction의 Enter는 원문 이동을 시작하지 않는다.
- 준비한 diff가 ready이면 같은 버튼으로 전체 diff 행을 읽기 전용 탭에 연다. 도크의 256-byte 표시 생략을
  적용하지 않고 행 전체를 보관한다. 충돌/준비 중 미리보기는 새 탭으로 게시하지 않는다.
  이 탭은 변경 전후 사본이며 실제 파일 적용 버튼이 없다.
- 문서 file은 read_only이고 경로·untitled 번호·recovery owner가 없다. Undo 기록을 만들지 않는다.
  편집·저장은 거절하며 백업·workspace 저장 인덱스에 포함하지 않는다. 재시작 후 복원하지 않는다.
  일반 파일·이름 없는 문서의 기존 복원 포맷은 바꾸지 않는다.
- 본문·줄 배열·lease·metadata·pane 목록 예약을 성공시킨 뒤 게시한다. 준비 실패는 빈 탭을 남기지 않는다.
  출력 크기는 기존 편집기 read_limit_bytes를 넘으면 거절한다. 앱 전체 RSS 상한이라는 의미는 아니다.
- snapshot 열기 자체는 main actor에서 수행한다. 대량 결과의 탭 생성 지연·RSS는 별도 실측 경계이며
  worker 취소 지연이나 전체 파일시스템 호환성을 여기서 새로 보장하지 않는다.

## 검증

`test-editor-project-replace-preview`의 RPV4~7은 결과 사본 수명·원문 이동·revision 거절,
읽기 전용 편집/저장·복원 제외·준비 할당 실패·diff 탭 원문 보존·디스크 수정과 탭 닫기 뒤 늦은 완료를 검증한다.
`test-editor-project-search-dock`은 입력 폭·버튼·행의 동일 geometry와 paint clip을 검증한다.
제품 AppKit/Metal harness는 우측·하단 도크와 실제 결과 탭 열기 버튼, Enter 이동을 촬영한다.
최종 캡처와 실행 결과는 PR 본문에 연결한다. 물리 입력기의 후보창·VoiceOver는 별도 미검증 경계다.

## 실행 증거 (2026-10-09)

- `test-editor-project-replace-preview`: 중립 5개·제품 11개 통과. 도크 26개·owner 29개·호스트 ABI·문서 링크/줄 참조 통과.
- 순차 전체 검사 `mise run -j1 -c check` 종료 코드 0, 1028.45초. 수정 중 진행한 전체 검사와 별도로 최종 변경의 위 집중 판정을 다시 통과했다.
- 읽기 전용 file 설정을 별도 소스 사본에서 제거하면 RPV4의 실제 `insertText` 거절 판정이 실패했다. 사본은 복원했고 제품 코드에 변이를 적용하지 않았다.
- 실제 AppKit/Metal 960×600·1×: `maru-editor-project-search-app-3_2l3hck/manifest.json`. 640×480·주입 2×: `maru-editor-project-search-app-irzp8fv_/manifest.json`. 정확한 접두는 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/`다.
- 앞선 2× 실패에서 검색 옵션이 입력 폭을 빼앗는 문제를 수정했다. 이어 좁은 분기의 u1 덧셈 overflow가 단위/제품 실행에서 발견되어 usize 변환으로 수정했다. 최종 좁은 폭 재실행은 통과했다.
- 탭 열기 버튼의 실제 클릭·결과 Enter 이동·readonly 상태·diff 탭을 촬영했다. source/binary/harness/PNG hash를 manifest로 결속한다. 탭 생성 시간은 격리 하네스의 `open` 호출 구간이며 frame 전체/대량 결과 최대 지연은 아니다.
