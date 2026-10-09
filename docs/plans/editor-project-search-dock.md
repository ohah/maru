# 프로젝트 검색 도크 구현과 검증

파일별 결과 모델·입력 수명·Chrome 표시 컴포넌트와 AppSession 연결을 구현했다. S2의 실제 화면·두벌식 HID·공유/독립 문서·root 교체·클릭·앱 메모리 표본을 실행 검증했다. 전체 파일시스템·OS watcher/지연 I/O 종료·VoiceOver·OS 후보창 픽셀과 S3/S4 바꾸기는 별도 범위다.
제품 계약과 단계별 완료 조건은 [프로젝트 검색 계획](editor-project-search.md)을 따른다.

## 수정한 결함

- 결과 경로 `a.zig`와 `./a.zig`가 다른 그룹으로 나뉘었다. 기존 요청의 상대 경로 검증을 적용하여 그룹 키를 통일한다.
  상위 이동·절대 경로는 받지 않으며, 실패한 행의 소유권은 호출자에게 남긴다. symlink·hard link의 서로 다른 이름은 합치지 않는다.
- 텍스트 clip이 조상 도크 영역만 따라 입력칸·버튼·결과 행의 경계를 넘었다. 자기 면과 조상 clip의 교집합을 사용한다.
  소수 좌표에서는 가까운 변을 올리고 먼 변을 내려 옆 면으로 글자가 번지지 않게 한다.
- 비활성 검색·취소 버튼을 접근성 서술자에서는 활성으로 표시했다. 동작 표와 서술자가 같은 활성 판정을 사용하며,
  비활성 글자는 흐린 색으로 그린다.
- 자동 대기 판정은 조합을 막았지만 명시적 시작 API는 이를 확인하지 않았다. `presentation.State.begin`은
  조합 상태 또는 OS 입력 transaction이 있으면 `false`를 반환하고 상태를 그대로 둔다. 앱도 실제 marked text와 transaction을 검사한다.
- 잘못된 scroll shift나 결과 높이 산술이 정수 변환·곱셈에서 실패할 수 있었다. build 전에 검증하여
  `InvalidGeometry`로 거부한다. 같은 행 ID가 반복되면 공통 tree의 `DuplicateIdentity`로 발행을 중단한다.

## 확인한 동작

- root·문서 owner·slot·generation·revision·composition 중 하나가 달라도 독립 그룹을 유지한다.
- 현재 요청·root·모델 신원과 다른 batch·완료, 취소·입력 변경 후 늦은 완료는 적용하지 않는다.
  완료 후 재완료·추가 행도 받아들이지 않는다. 부분 결과·실패·성공 0건은 다른 상태로 유지한다.
- 모든 행 추가·표시 인덱스 allocation 실패를 주입하여 이미 받은 행의 회수와 caller 소유권을 확인한다.
  표시 실패 후 옛 결과·요청 신원을 남기지 않는다.
- 20,000개 일치·20,000개 파일 그룹을 생성해 펼친 인덱스 40,000행을 검사한다. `Model.window`가
  viewport와 겹치는 행만 반환하며, 창 계산은 allocation을 하지 않는다. 모든 보관 allocation은 해제한다.
- 고정 머리·부분 행·좁은 폭·소수 배율·숨긴 필터·비활성 버튼·낡은 세대·중복 ID·부족한 frame/paint buffer를 검사한다.
  이 검사는 Chrome draw 명령과 tree 기하를 비교하며, 실제 Metal 픽셀이나 AppKit 입력을 증명하지 않는다.
- 문서 신원 확인·실패 시 무효화·자기 면 clip·조합 시작 차단·버튼 접근성 활성 판정을 각각 제거한
  대조군이 해당 실행 검사에서 실패했다. 원래 코드를 복원한 뒤 검사를 다시 실행한다.

## 재실행 명령

```sh
mise run test-editor-project-search-dock test-editor-project-search
mise exec -- zig build test-editor-project-search-dock test-editor-project-search -Doptimize=ReleaseFast
mise exec -- zig build test-editor-project-search-owner test-macos-project-search-adapter test-macos-project-search-worker test-macos-project-search-roots
mise run check
mise run macos-app-host-swift-check
```

모델과 컴포넌트 판정은 각각 기본 `maru`·Chrome 테스트에도 포함된다. 집중 실행 입구는 위 첫 명령이다.
성능 표본의 `testing` allocator는 누수 검사 비용을 포함한다. `smp` allocator는 앱 호스트와 같은 allocator를 사용하지만,
**이 역시 중립 모델 표본이지 앱 전체 RSS·main tick·첫 검색 결과·취소 지연 측정이 아니다.** 제품 측정은 아래 별도 절을 따른다.

## 모델 실측 (2026-10-08)

ReleaseFast에서 앱 호스트와 같은 `smp_allocator`를 사용한 두 실행 표본이다.
20,000개 일치가 서로 다른 20,000개 파일 그룹에 속하는 합성 자료이며 미리보기는 `foo`다.

| 항목 | 관측값 |
|---|---|
| 모델 보관 allocation | 10,926,292 bytes (약 10.42MiB) |
| 행·그룹 추가 전체 | 4.86~5.32ms |
| 펼친 40,000행 인덱스 재구성 | 0.277~0.356ms |
| 모델 해제 | 0.476~0.644ms |
| viewport 창 계산 | allocation 0 |

이 값은 allocator 호출의 보관량이며 RSS가 아니다. allocator의 해제 후 page cache까지 OS에 반환한다는 뜻도 아니다.
긴 미리보기·경로·큰 열린 문서 사본이나 앱의 shape·paint·입력 비용을 포함하지 않으므로 제품 byte 예산으로 채택하지 않는다.
명령 출력의 `search-dock-model allocator=smp` 표본으로 다시 확인할 수 있다. 누수 검사용 `testing` allocator 표본은
스택·메타데이터 검사 비용을 포함하므로 앱 성능으로 읽지 않는다. 절대 시간에 의한 실패 gate는 추가하지 않았다.

## 기반 판정의 범위

모델·Chrome 컴포넌트 판정은 실제 제품 픽셀·OS 입력을 증명하지 않는다.
앱 연결과 제품 실측은 아래 별도 절을 따른다. S2 제품 실행 증거는 아래 main 통합 검증 절을 따른다.

## 실제 앱 연결

- `show_project_search`와 ⇧⌘F는 현재 창의 확인된 로컬 탐색기 루트를 대상으로 검색 도크를 연다.
  검색 뷰의 자동 우측 폭은 240pt이며 수동 크기는 기존 도크 설정을 따른다. 여섯 도크 아이콘은
  폭에 맞는 공통 셀 격자로 그리기와 클릭 위치를 함께 계산한다.
- 검색어·대소문자·단어·정규식·포함/제외 입력을 worker 요청에 연결한다. 입력 변경은 이전 결과의 동작을
  즉시 무효화하며 300ms 뒤 검색한다. 실제 조합 중 Enter는 검색을 실행하지 않는다.
  일반 Enter가 OS transaction 안에서 전달되면 transaction이 닫힌 다음 tick에 실행한다.
- 검색 확정과 붙여넣기는 선택을 지우기 전에 저장 공간을 예약한다. 예약 실패 시 이전 글자·선택·조합을 보존한다.
  빈 unmark 콜백이 이미 확정된 검색을 다시 조합 상태로 바꾸지 않는다.
- 입력 caret·선택·포인터는 표시와 같은 CoreText face와 축약된 CTLine으로 계산한다. 드래그 선택은
  grapheme 경계에 맞춘다. caret는 별도 quad로 그려 빈 입력의 placeholder와 검색 가능 판정을 흔들지 않는다.
- tick당 결과 행은 최대 256개를 전달한다. 완료를 적용하기 전에 남은 batch를 다시 확인하며, 모델·경로 문자열의
  소유권은 성공한 전달에서만 바뀐다. 그리기는 보이는 행만 투영한다.
- 열린 문서 결과는 문서 신원·revision·조합 상태를 다시 확인한다. 디스크 결과는 같은 옵션·glob·ignore로 해당
  파일을 다시 검색하고, 검색 전후 디스크 해시와 실제 열린 불변 문서의 해시가 같은 경우에만 선택 범위를 적용한다.
  root 신원도 내용 읽기 전에 검증한다. UTF-8 BOM은 문서 모델과 같은 기준으로 제외하고 CRLF는 보존한다.
- 취소된 클릭 검증은 worker가 종료될 때까지 하나만 보관한다. 숨김·요청 교체·포커스 상실·기하 변경은
  이전 포인터 capture를 거둔다. 본문 클릭은 검색 입력 소유권을 돌려준다.
- root 번호와 열린 문서의 현재 요청 내 표시 번호로 같은 경로의 독립 결과를 구분한다. 원격 문서·diff와
  원격 pane에서는 이전 로컬 범위를 표시하거나 검색하지 않는다. 숨겨진 검색 도크의 접근성 개수는 0이다.
- glob 목록의 쉼표 분리와 부모 경로 처리는 같은 `query.GlobScope`를 사용한다. 리터럴 `[`·`]` 클래스도
  유지하며 실제 매칭은 ripgrep에 맡긴다. 구문 근거는 [globset 공개 구문](https://docs.rs/globset/latest/globset/#syntax)이다.

검색 owner/AppSession 집중 판정 29개, 도크 모델·컴포넌트 판정 25개, Chrome UI 판정도 실행했다.
디스크가 검색 전에 바뀐 경우뿐 아니라 재검색 후 같은 preview를 유지한 채 뒤쪽 내용이 바뀐 경우도 이동을 막는다.
변경 없는 BOM/CRLF 파일의 실제 열기·선택은 성공한다. 이 판정은 물리 입력기나 VoiceOver 편집을 증명하지 않는다.

## 추가 검증에서 수정한 경계

- `navigation.poll`은 첫 결과 수신 뒤 완료 신호가 게시되는 경우를 고려해, 완료 확인 뒤 마지막 배치를 다시 읽는다.
  그렇지 않으면 변경 없는 파일도 일치 결과가 없는 것으로 처리할 수 있다. 재검증의 내용·해시 조건은 유지한다.
- `dock.commitPreedit`은 확정 성공 여부를 반환하고 `AppSession.tryCommitComposition`이 이를 전달한다.
  할당 실패 시 OS marked session 폐기를 허가하거나 Tab·Esc로 입력 포커스를 옮기지 않는다.
  실패 주입 판정은 본문·선택·조합·입력 포커스 보존을 확인한다.
- 검색이 완료되고 입력 포커스가 없어도 도크를 숨기면 진행 중인 클릭 재검증을 취소한다.
  `EDPSD6`은 다른 도크로 전환한 뒤 파일 열기·이동 이력이 생기지 않는 경우도 확인한다.
- 해시 worker 판정은 결과 공개인 `done`뿐 아니라 worker 참조 해제까지 기다리고 allocator를 검사한다.
  제품 경로의 detached worker 소유권과 결과 공개 순서는 바꾸지 않는다.

입력·클릭 기하 경계, worker 수명·완료 경쟁, 디스크·루트·glob 경계를 각각 검토했다.
실제 helper adapter 21개, worker 141개, 다중 루트 20개 판정은 통과했다.
격리 소스에서 확정 실패 전달을 제거하면 `EDPSD2`가 반환값 assertion으로 실패한다.
첫 수신에는 행이 없고 완료 때 마지막 행이 도착한 스케줄을 강제하면 수정본은 통과하며,
완료 후 재수신을 제거한 음성 대조는 `EDPSD6`의 정상 파일 이동 assertion으로 실패한다.
도크 숨김 취소를 제거한 격리 소스도 `EDPSD6`의 취소 상태 assertion으로 실패했다.
새 빌드의 60개 모델 일치·2개 디스크 일치에서 실제 입력·선택·파일 열기·하단 스크롤·취소를 확인했다.
하네스는 하단 첫 표시 행을 디스크 결과라고 가정하지 않고 결과 source를 확인해 클릭한다.
이 표본은 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-editor-project-search-app-_0395vmn/manifest.json`에 남겼다.
물리 IME와 VoiceOver 경계는 아래 제품 한계와 동일하며 이 검토로 완료 처리하지 않는다.

## 추가로 재현해 수정한 실패 경로

- `leave`·`blur`의 확정 거부를 도크 뷰·본문 포커스 전환 호출자에게 전달한다. 거부된 전환의 진입 훅도 실행하지 않는다.
- 표시 폭이 사라진 도크는 입력이나 검색 작업을 소유하지 않는다. 공통 레이아웃의 최소 본문 폭 정책은 유지한다.
- 실제 화면 수집의 paint·shape 실패는 이미 게시한 동작 표와 접근성 표를 회수한다.
  `EDPSD7`이 제품 수집 경로의 할당 실패 지점들을 주입해 이를 검사한다.
- 공통 `chrome/system_text.prepareRequest`는 문자열 복사 이후 run 표 확장 실패 시 아직 이전되지 않은 사본을 회수한다.
  paint 실패 주입에서 실제 allocator 누수로 재현했고 수정 뒤 누수 검사까지 통과했다.
- 열린 사본 해시 worker 오류는 내용이 바뀐 경우와 구분하여 기존 편집기 오류 안내를 표시한다.

실제 HID 표본은 `y5svflvn/manifest.json`, AppKit 행렬 표본은 `ctgjhipf/manifest.json`,
640×480 창·주입한 2× backing scale 표본은 `kyjpnv79/manifest.json`이다. 모두
`/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-editor-project-search-app-` 아래의 격리 실행이며
각 manifest가 실제 소스·바이너리·하네스·PNG를 해시로 결속한다. 이후 main 통합 검사는 별도로 기록한다.

HID는 조합 `ㅎ → 하 → 한 → 한그 → 한글` 동안 `.composing`과 검색 요청 없음,
Enter 뒤 확정된 `한글`과 실제 1개 결과를 확인했다. 전역 입력기는 기존 복원 기록 계약으로 복원했다.
AppKit 행렬은 공유 뷰의 결과 60개·독립 문서 추가 후 120개·독립 문서의 0건 편집 후 60개,
root 교체 후 새 파일 1개·교체 전에 누른 행의 늦은 놓음 무시를 실제 제품 경로에서 확인했다.
이 검사는 전체 FSEvents overflow·다른 파일시스템·OS 후보창 픽셀·VoiceOver 편집을 증명하지 않는다.

```sh
python3 tools/editor-project-search-app/run.py --physical-ime
python3 tools/editor-project-search-app/run.py --matrix
python3 tools/editor-project-search-app/run.py --matrix --window-size 640x480 --render-scale 2000
python3 tools/editor-project-search-app/run.py --matrix --narrow-hidden --window-size 480x480
```

## 제품 실측 (2026-10-09)

`python3 tools/editor-project-search-app/run.py --count 12000 --disk-files 2048`의 격리된 실제 앱 표본이다.
열린 Zig 문서 12,000개 일치와 약 127MiB의 디스크 파일 2,048개 일치, 총 14,048개 결과를 사용했다.
동시에 다른 검사가 실행 중이었다. 아래 시간은 이 표본의 관측값이며 보편적인 상한이나 CI 성능 gate가 아니다.

| 항목 | 관측값 |
|---|---|
| 첫 결과 | 334~336ms (300ms debounce 포함) |
| 전체 결과 수신 | 1.75~2.06초 |
| 검색 owner/pump의 최대 main tick 구간 | 1.30~5.90ms |
| 취소 호출 | 약 1.2~2.3µs |
| 취소 후 worker 회수 | 7.2~8.8ms |
| 앱 전체 최대 RSS | 181,223,424~182,960,128 bytes (약 173~175MiB) |

RSS는 편집기·구문 트리·폰트·렌더러를 포함하며 검색 모델의 보관 allocation과 다르다.
상태표시줄은 앱·자식 프로세스의 footprint를 합산하므로 이 앱 프로세스의 RSS와 같은 수치가 아니다.
전체 frame 시간과 일반 파일 열기 API의 큰 파일 지연을 뜻하지 않는다.
당시 main 리베이스 후에도 같은 부하를 재실행했다. 첫 표본의 실측 artifact는 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-editor-project-search-app-tfjs2j6u/manifest.json`이다.
실제 디스크 결과 클릭·다른 파일 이동까지 포함한 추가 표본은 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-editor-project-search-app-7onqfb30/manifest.json`이다.
리베이스 후 표본은 `/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-editor-project-search-app-r630akyk/manifest.json`이다.
재실행 시 생성되는 manifest는 소스·바이너리·하네스·PNG 해시와 RSS/시간을 결속한다.

초기 요청 방벽은 결과 payload 8MiB, JSON event 하나 4MiB, 열린 문서 사본 전체 64MiB,
후보 선정 storage 8MiB, preview 256 bytes, 일치 20,000개다. 실행 10초와 child 회수 1초도 별도 방벽이다.
이를 앱 전체 메모리 상한으로 해석하지 않는다. 검색 owner/pump 구간에는 추가 표본의 디스크 이동도 포함되며 전체 frame 비용은 별도다. 상한·시한 도달은 부분 결과, 사본 제외는 제외 개수로 나타낸다.
클릭 내용 검증은 새 파일 크기 정책을 만들지 않고 기존 `editor.read_limit_bytes`를 따른다.

## 제품 재실행과 남은 경계

```sh
python3 tools/editor-project-search-app/run.py
python3 tools/editor-project-search-app/run.py --unicode-field
python3 tools/editor-project-search-app/run.py --count 12000 --disk-files 2048
```

실제 AppKit 입력·마우스와 제품 Metal 읽기로 검색, 한글/이모지의 grapheme 선택, 파일 이동, 하단 도크,
스크롤·취소를 확인한다. 해시 비교를 제거한 대조군은 같은 preview를 유지한 외부 변경 판정에서 실패했고 복원 후 28개 판정이 다시 통과했다. 이 방법은 직접 AppKit 콜백을 사용하는 부분이 있으므로 물리 두벌식 조합·Enter·후보창
확인과 구분한다. 실제 두벌식 HID 조합·Enter는 추가 제품 실행으로 확인했다. OS 후보창 픽셀과 VoiceOver 조작은 이 증거가 확인하지 않는다. 공유/독립 문서·root 교체·낡은 요청의
집중 판정과 실제 화면 검증도 같은 것으로 합산하지 않는다. S2 제품 실행 증거는 아래 main 통합 검증 절을 따른다.

## main 통합 검증 (2026-10-09)

base `3f7fd7a4c`로 리베이스하면서 모든 중간 커밋에 `zig build check-boundaries`를 실행했다.
헤더 개수 원장 충돌은 해당 커밋에서 수정하여 검색 컴포넌트·검색 별칭과 main의 서버 정보 별칭을 모두 보존했다.
`mise run -j2 -c check`는 실제 작업 checkout에서 755.62초, 종료 코드 0으로 끝났다.
`EDPSD2`는 새 조합 갱신의 할당 실패도 이전 조합을 보존하는지 확인한다. 방어를 넣지 않은 별도 checkout은
기존 조합 `나`가 빈 값으로 바뀌어 실제 assertion으로 실패했다.

최종 코드의 제품 표본은 같은 격리 디렉터리 접두 아래에 다음과 같이 남겼다.

- `e26xjcui/manifest.json`: 실제 디스크 파일 열기·선택·스크롤·취소, 모델 60개와 디스크 2개 결과.
- `v43fr0ic/manifest.json`: 640×480 창·주입한 2× backing scale에서 공유/독립·0건 점유·root 교체·낡은 놓음 행렬.
- `5u5e29uf/manifest.json`: 480×480에서 기하 0px·입력 해제, 640×480 확대 후 복귀와 전체 행렬.
- `iw9ycyet/manifest.json`: 최종 빌드의 실제 두벌식 HID 조합·Enter, 검색 1건·원문 보존·입력기 복원.

임시 checkout을 `/tmp` 아래에 둔 전체 검사에서는 임시파일 테스트 두 건의 “임시 루트 밖” 전제와 충돌했다.
실제 checkout에서 같은 코드를 검사하여 두 건을 포함한 전체 검사가 통과했다. 임시파일 삭제 정책은 변경하지 않았다.
실제 HID 재시도 중 화면 잠금으로 중단된 실행은 성공 증거에서 제외했고, 입력기는 원래 ABC로 복원됐다.
잠금 해제 뒤 최종 재실행은 성공했다. OS 후보창 픽셀·VoiceOver 조작은 이 증거 범위에 포함하지 않는다.
