# 공유 뷰의 초기 구문 스냅샷

상태: 구현·집중 회귀·언어 대조·독립 결함 검출·전후 실측·기존 공유 회귀·실제 main 리베이스와 전체 로컬 게이트·PR CI 완료. PR #4574는 `db4e74406`으로 머지됐으며 머지 트리는 검증한 PR head와 동일하다.

## 확인한 비용

현재 `prepareSharedView`는 접힘 표시 범위와 `syntax_folds_applied`를 복사한다.
`finishAttach`는 구문 Provider를 새로 연다. 초기 파싱을 마친 뒤에도 복사한 표시 완료 상태
때문에 새 뷰의 접힘 캐시는 처음 조회할 때까지 없다. 첫 입력은 캐시 전체 수집이 된다.

제품 사본의 Swift 공유 뷰 진단은 다음과 같았다.

```text
FOLD_INITIAL primary_tree=1 primary_synced=1 primary_gen=1 peer_tree=0 peer_synced=0 peer_gen=1 peer_applied=1
FOLD_PEER key=0 reused=0 compared=0 nodes=200850 synced=2 generation=2
FOLD_PEER key=1 reused=1 compared=0 nodes=200858 synced=3 generation=3
```

입력 5개 파일의 각 20회, 총 100개 입력을 매 입력 전수 대조했고 모두 일치했다.
이는 정확성 결함이 아닌 첫 입력의 전체 구축 비용이다. 실제 GUI/HID 지연은 측정하지 않았다.
증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/shared-first-edit-diagnostic/`의
원본/계측/바이너리 해시·`verify-*.log`다. 진단의 출력 시간은 성능 비교에 쓰지 않는다.

## 구현

완료된 Source Provider의 현재 트리를 `ts_tree_copy`로 복사하고 새 TSParser를 세운다.
Provider는 각 뷰가 소유하며 괄호·심볼·색 버퍼는 새 뷰의 빈 상태로 시작한다.
언어가 다르거나 파싱 중이거나 트리가 없으면 기존 열기 경로를 쓴다.

접힘 캐시는 source parser·세대가 일치하고 미반영 편집이 없는 경우만 복사한다.
byte 후보 배열은 독립적으로 복제하고 트리 사본과 새 parser·세대를 함께 인계한다.
캐시 복제가 실패하면 캐시를 비운 기존 동작으로 복귀하며 표시 상태 사본을 보존한다.
선택·접힌 머리·스크롤의 독립성은 기존 Prepared seed의 계약을 유지한다.

복제는 게시 전 준비 단계에서 소유하고, 실패나 분할 취소는 Prepared 해제에서 회수한다.
준비된 구문 상태가 있으면 `finishAttach`는 그것을 인계받고, 없으면 기존 `syntax.open`을 쓴다.
문서 본문·Undo·workspace 포맷·뷰의 입력 정책은 변경하지 않는다.

## 필요한 검증

- 원본/복제의 parser와 트리 래퍼는 다르고, 한쪽 편집·해제 뒤 다른 쪽은 유효하다.
- 다른 언어·pending·세대 불일치·미반영 편집은 이전 상태를 잘못 인계하지 않는다.
- 캐시 배열 OOM·준비 취소·게시 전 후속 실패에서 누수·부분 게시가 없다.
- Source가 없어진 뒤 복제의 편집·접힘·Undo가 전체 순회와 일치한다.
- 분할 생성부터 초기 준비, 첫 입력, 후속 입력을 모두 측정한다. 비용을 초기 단계로
  옮기고 첫 입력만 빨라졌다고 주장하지 않는다. 전체 원시 표본과 전후 해시를 보존한다.

pending·다른 언어·낡은 세대 허용, 원본 parser에 캐시 바인딩, Prepared 해제 누락의 독립 결함 다섯 가지를 모두 런타임에서 검출했다. 원본 전후 대조군과 현재 네 제품 파일의 해시도 일치했다. 기존 공유 분할·접힘·OOM 회귀를 함께 검사한다.


## 집중 검사와 언어 범위

`test-editor-shared-snapshot`은 실제 6개와 import 4개, 총 10개다.
첫 편집의 국소 방문과 Source 뷰 닫기 뒤 Undo, pending·다른 언어, wrapper/후보 배열 OOM,
Source 캐시 메타데이터 불일치, 직접 준비 취소, 준비 직후 다음 할당 실패를 검사한다.
준비 후 실패는 pane tree·문서 참조와 추적 allocator의 할당/해제 byte 수가 보존되는지 확인한다.

`test-editor-native-snapshot`은 실제 2개와 import 1개, 총 3개다.
원본 편집 독립성·원본 해제 뒤 사용·native 할당 회수와 함께 지원 언어 31개를 순회한다.
공통 3줄 입력과 앞 개행 편집에서 기존 parser와 새 parser의 트리 종류·이름 여부·extra/missing/error·
byte/point·자식·field 이름 및 접힘을 대조했다. 미지원 태그 1개는 기존의 Provider 부재를 확인했다.
모든 문법 구문·사용자 문서를 전수 검사했다는 뜻은 아니다.

```sh
mise exec -- zig build test-editor-shared-snapshot test-editor-native-snapshot test-editor-incremental-folds -j2
python3 tools/editor-shared-snapshot/review.py --output <새 외부 경로> --deps "$PWD/zig-pkg"
```

## 전후 함수 실측

```sh
python3 tools/editor-shared-snapshot/run.py --baseline-ref <선행 커밋> --output <비교 경로>/baseline --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-shared-snapshot/run.py --output <비교 경로>/cursor --deps "$PWD/zig-pkg" --fixtures <비교 경로>/baseline/fixtures --repetitions 0
python3 tools/editor-fold-marks/compare.py <비교 경로> --workloads shared --repetitions 10
python3 tools/editor-fold-marks/compare.py <비교 경로> --workloads shared --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-shared-snapshot/summarize.py <비교 경로>
python3 tools/editor-shared-snapshot/verify_summary.py
```

기준판은 `52b085b2c`의 네 제품 파일을 그대로 읽고 관측만 넣는다.
`SHARED_SPLIT`은 공개 분할 명령, `SHARED_READY`는 명령 시작부터 두 뷰의 파싱·접힘 표시·
괄호 목록/짝 판정 준비까지다. Source의 남은 초기 괄호 준비도 포함될 수 있다.
최소 준비 프레임 수 등 기존 fixture 순서를 양쪽에 유지한다. 이 값은 물리 입력부터 화면
표시까지의 제품 지연이 아닌 fixture 함수 경과시간이다. Source 초기 문서 열기는 측정 전이다.

첫 입력을 포함한 20개 입력을 모두 보존한다. 준비+첫 입력은 서로 겹치지 않는 두 측정 구간의
합이며 분할 명령은 준비 시간 안에 포함되므로 다시 더하지 않는다. 타이머를 먼저 캡처해
준비 출력 비용을 제외한다. 최종 Source 준비 marker와 예상 peer 캐시 유무, 새 parser의
추가 native parse 0을 검사한다. 잘못된 구간·첫 입력 누락·중복·음수도 별도 대조한다.

파일 5개·두 방식·10회로 성능 100회/2,000개 입력을 측정했고, 별도 매 입력 대조
10회/200개 입력도 일치했다. 단위는 ms다.

| 파일 | 준비+첫 입력 전 p50/p95 | 후 p50/p95 | 첫 입력 전 p50/p95 | 후 p50/p95 | 분할 명령 전/후 p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.13 MB Zig | 661.548 / 671.241 | 336.564 / 362.678 | 157.700 / 161.863 | 78.094 / 95.964 | 10.779 / 6.795 |
| build.zig | 79.217 / 83.371 | 43.966 / 46.605 | 21.898 / 23.316 | 12.985 / 13.881 | 7.029 / 3.020 |
| Swift | 204.561 / 218.461 | 69.754 / 71.462 | 29.617 / 29.961 | 14.282 / 14.909 | 9.956 / 5.899 |

Source parser는 각각 독립적으로 유지한다. 새 뷰의 첫 파싱과 후보 전체 방문을 준비된 COW 트리와
독립 후보 배열 복제로 바꾼 것이다. 기존 선택·접힌 머리·스크롤 사본은 그대로다.
메모리 절약·모든 입력의 지연 개선·물리 GUI/HID·compositor 개선은 주장하지 않는다.
외부 부하는 통제하지 않았고 다른 PR의 별도 수치와 연속 곡선으로 더하지 않는다.

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/shared-initial-comparison/`의 원본/계측/기준 커밋/
바이너리 해시·실행 순서·원시 로그·`shared-summary.json`이다. `original-product/`는 측정 원본의
해시를 확인해 저장한 사본이다. 그 뒤 추가한 언어 검사는 test 블록만 추가하며 측정한 제품 함수는
바꾸지 않는다. 집계 손상 대조는 `shared-initial-summary-controls.log`에 있다.

전체 다섯 파일 결과는 [실측 표](../../tools/editor-shared-snapshot/results.md)에 보존한다.

기존 `test-editor-shared-view` 22개·`test-editor-shared` 72개·`test-editor-shared-split` 19개·
`test-editor-shared-anchors` 11개도 모두 통과했다(import 포함). 조합 거절 뒤 분할,
마지막 뷰 닫기·창/워크스페이스 이동·공유 편집 OOM·독립 선택/접힘/스크롤 회귀를 포함한다.

3,000행 Zig 후속 입력 최대는 6.299→22.502ms로 높았다. 해당 표본도 전체 집계에 보존하며
외부 부하를 원인으로 확정하거나 모든 입력의 개선·회귀 부재를 주장하지 않는다.
