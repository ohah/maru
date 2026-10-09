# 프로젝트 바꾸기 미리보기 — S3

검색 도크의 결과에서 **파일 전체 일치 또는 일치 하나**를 골라 변경 전후를 읽기 전용으로 비교한다.
VS Code의 [파일 범위 검색·바꾸기 미리보기](https://code.visualstudio.com/docs/editing/codebasics#_search-and-replace)를 참고한다.
사용자는 2026-10-09 미리보기 구현을 승인했다. 실제 여러 파일 적용은 S4이며 이 단계는 쓰지 않는다.

## 화면과 선택

- 검색 도크의 공통 SVG 꺾쇠 버튼으로 바꾸기 입력을 펼친다. 검색어·포함·제외 입력의 의미는 유지한다.
- 바꿀 내용은 일반 텍스트 필드처럼 선택·붙여넣기·IME를 지원한다. 빈 내용은 삭제 미리보기다.
- 바꾸기 모드에서 파일 제목을 누르면 그 파일의 모든 표시 일치를, 일치 행을 누르면 하나를 선택한다.
  일반 검색 모드의 파일 접기와 문서 이동은 그대로다. 이번 단계는 여러 파일 선택 집합을 적용하지 않는다.
- 도크 결과 영역에 `-` 원문과 `+` 변경 행을 표시한다. `←`는 검색 결과로 돌아간다.
  변경 지점으로 스크롤하며 긴 행은 변경 주변 문맥과 `…`를 표시한다. 생략된 내용을 전체 행으로 오인하지 않는다.
- 버튼은 공통 `Button` ghost/secondary 표면을 사용하고 텍스트는 측정된 가운데 정렬, 검색·펼침·돌아가기는 기존 SVG 슬롯을 쓴다.
  검색 옵션 세 개는 검색어 오른쪽에 두고, 입력 폭이 부족하면 다음 줄로 옮긴다. 실행·필터·탭 열기 등의 동작은 별도 고정 크기 그룹으로 배치한다.
  `Metrics.resolveForWidth`가 입력/그리기/스크롤 머리 높이를 함께 결정한다.
- 미리보기의 모든 행은 읽기 전용이며 행 클릭 동작을 발행하지 않는다. 부분·취소·오류 검색은 계획을 만들지 않는다.
- 입력이나 원문 신원이 바뀌면 현재 전문을 그대로 남기고 **충돌·이전 미리보기**라고 표시한다.
  다시 결과로 돌아가 새 미리보기를 만든다. 단순 커서·선택·도크 스크롤 변경은 원문 변경이 아니다.

## 소유권과 검색 의미

`session/editor/search/preview.zig`의 `Plan`은 원문·변경 전문과 기존 `diff.compute`의 줄 대응을 보관한다.
문서 레지스트리·파일 저장·Undo·커서 API를 호출하지 않는다. 범위 좌표는 기존 UTF-8 원문 축이다.
LF·CRLF를 정규화하지 않고 줄 끝까지 비교하여 줄바꿈만 바뀌는 경우도 diff에 들어간다.

정규식은 기존 `find.regex.Pattern`의 전문 검색과 `expandFromValidated`로 캡처를 확장한다.
선택하지 않은 앞선 매치도 순회해 `\G`·`\K`·lookbehind의 원래 검색 시작점과 문맥을 재현한다.
중복·겹친 범위·UTF-8 내부 좌표·재현되지 않은 매치는 거부한다. 평문에서도 같은 위치의 실제 일치를 확인한다.
검색 엔진 간 차이가 있어 캡처 범위를 재현할 수 없으면 추측하지 않고 충돌로 표시한다.

`platform/macos/app_session/editor/search/preview.zig`가 다음 내용을 준비한다.

- 열린 모델: 같은 문서 신원·revision·조합 stamp를 검사하고 불변 rope snapshot을 잡는다.
  공유 뷰의 문서는 한 신원이며 같은 경로의 독립 문서는 각각 선택할 수 있다. 조합 중 모델은 거부한다.
- 디스크: 같은 root capability·glob·ignore·query로 기존 `Backend.startBundledTarget`을 재실행한다.
  표시했던 매치의 원문·범위가 모두 확인되고 완료 상태가 complete일 때만 전문 읽기를 시작한다.
  `verify.read`는 navigation과 같은 regular file·root·stat 변경 검사를 사용한다.
  재검색 전후의 SHA-256과 읽은 전문의 SHA-256이 같아야 계획을 만든다. UTF-8 BOM은 편집기와 같은 좌표 축에서 제외한다.
- 전문 평탄화·읽기·캡처 확장·diff 계산은 worker에서 한다. main actor는 신원·작은 입력·범위를 준비한다.
  원문과 변경 전문은 각각 기존 편집기 읽기 한도 64MiB를 따른다. diff의 기존 실행·trace 예산도 유지한다.
  이것은 앱 전체 RSS 상한이나 wall-clock 완료 보장이 아니다.
- 입력·root·모델·디스크 감시 세대 변경과 숨김·취소는 worker를 취소하고 이전 계획을 충돌로 바꾼다.
  늦은 결과를 다시 게시하지 않는다. 준비 할당 실패는 이전 계획을 보존하고 기존 알림으로 알려준다.
- 작업은 참조수로 수명을 관리한다. 제품 종료는 느린 I/O를 기다리지 않는다.
  판정자 종료는 `quietDetachedWorkersForTest`에서 worker 참조 해제를 먼저 확인한다.

## 검증 입구

```sh
mise exec -- zig build test-editor-project-replace-preview
mise exec -- zig build test-editor-project-search-dock test-editor-project-search-owner macos-app-host-abi-lib
mise run -j2 -c check
python3 tools/editor-project-search-app/run.py --replace-preview --disk-files 2 --count 60
```

중립 판정은 여러 줄 캡처·원래 줄바꿈·일치 하나 선택·Unicode byte 폭·빈 매치·잘못된 범위·전체 할당 실패를 검사한다.
실제 AppSession의 `RPV1~3`은 파일/일치 선택과 원문·revision·선택·커서 보존, 디스크 BOM,
알림 전 수정·재검색 직후 tail 수정·감시 세대 변경, 준비 OOM·조합 Enter·즉시 취소를 검사한다.

격리 제품 하네스는 실제 AppKit 입력·파일 행 클릭과 Metal 프레임을 사용한다.
파일 전체·입력 변경 후 충돌·일치 하나·디스크 미리보기의 PNG, source/binary/harness 해시와 원본 무수정을 기록한다.
자동 callback 검증은 실제 두벌식 HID·OS 후보창·VoiceOver 조작의 증거가 아니다.

## 실행 증거 (2026-10-09)

- `test-editor-project-replace-preview`: 중립 5개(입구 포함)·제품 12개(입구 포함) 통과.
  비어 있지 않은 실제 Undo 기록을 만들고 미리보기 후 기존 Undo가 이전 입력을 되돌리는 것도 검증한다.
- 기존 검색 도크 26개·owner 29개와 호스트 ABI 빌드 통과. 문서 링크·줄 참조 통과.
- 제품 표본: `maru-editor-project-search-app-c9wmrfqn/manifest.json`의 960×600·1×와
  `maru-editor-project-search-app-66ljf12q/manifest.json`의 640×480·주입 2×에서 파일 전체·일치 하나·디스크·충돌 PNG를 생성했다.
  경로 접두는 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/`이다. 원본 무수정·실제 AppKit·Metal을 확인했다. 하단뿐 아니라 원래 우측 위치의 파일 전체·디스크·충돌 화면도 기록했다.
  펼침 버튼 자체도 AppKit mouse-down/up으로 눌러 바꾸기 입력을 연다.
- 별도 소스 사본에서 디스크 해시 대조를 제거하면 `RPV2`가 ready를 충돌로 기대하는 지점에서 실패했다.
  충돌 상태 전환을 제거하면 `RPV1~3`의 실제 상태 단언이 실패했다. 변이 사본을 제품 증거로 쓰지 않는다.
- 초기 전체 실행에서 기존 diff OOM sweep(2단계)과 코어 handoff 부하 판정이 실패했다.
  diff는 변경 전 main과 이번 코드의 분리 실행에서 각각 102단계(실패 99·성공 3)로 통과했고 handoff도 분리 실행에서 통과했다.
  이어 `mise run -j1 -c check`는 종료 코드 0, 1142.51초로 통과했다. 실패 원인을 순차 재실행의 성공만으로 단정하지 않는다.
- 버튼 배치를 수정한 뒤 검색 도크 26개·owner 29개·미리보기 중립 5개/제품 12개·호스트 ABI를 다시 통과했다.
  범위가 작은 UI 수정의 이 집중 결과와 전체 매트릭스의 결과를 구분해 기록한다.

## 남은 경계

S4의 실제 쓰기, 여러 파일 선택 집합·실패/부분 성공·재시도·되돌리기 정책은 아직 연결하지 않았다.
외부 수정 후 충돌 표시에는 기존 감시 세대를 사용한다. watcher의 모든 누락·overflow·지연 I/O 종료 상한을 증명하지 않는다.
향후 적용 시 미리보기 상태만 믿지 않고 원문을 다시 검증해야 한다. 새 workspace 포맷이나 영속 Undo를 도입하지 않는다.

검색 옵션 UI와 pane의 읽기 전용 결과·diff 탭은 [별도 계약과 검증](editor-project-search-pane.md)을 따른다.
