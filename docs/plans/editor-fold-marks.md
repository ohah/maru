# 접힘 표식의 순차 재구축

상태: 제품 구현·독립 대조·실패 주입·전후 함수 실측 완료.

## 구현과 계약

[비용 귀속](editor-frame-attribution.md)에서 큰 문서의 `rebuildVisible`이 매번 모든 줄의 접힘
머리를 이진 탐색하는 것을 확인했다. 중립 `session/editor/fold.HeadCursor`는 범위와 접힌 머리의
정렬 순서를 따라 전진하며 `.none`·`.open`·`.collapsed`를 낸다. macOS는 이를 gutter enum으로 옮긴다.
표식 구축은 줄 수 L, 범위 수 R, 접힌 머리 수 H에 대해 O(L+R+H)이며 새 할당을 하지 않는다.
표시 재구축의 다른 비용까지 모두 상수 또는 국소 작업이 되었다는 뜻은 아니다.

범위와 접힌 머리는 기존처럼 오름차순이어야 한다. 조회 줄은 감소하지 않으며 같은 줄의 반복 조회는
허용한다. 중복 머리와 숨은 줄을 건너뛰어도 답이 같고, 범위 없는 옛 접힘 머리는 표식을 만들지 않는다.
임의 순서의 점 조회용 이진 탐색은 독립 대조군으로 보존한다.

`rebuildVisible`마다 커서를 새로 만들므로 문서·뷰·접힘 판을 건너서 상태를 유지하지 않는다.
펼쳐진 전체 표식과 숨은 줄을 제외한 표식 모두 같은 경로를 쓴다. 표식 저장소가 짧으면 기존처럼
그 길이까지만 채운다. 기존 줄·번호 배열의 준비/게시·해제, 선택·스크롤 조정과 할당 실패 정책은 유지한다.
접힘 범위의 출처 우선순위, 중첩·공유 상태·Undo 정책과 화면 배치는 변경하지 않는다.

## 검증

```sh
mise exec -- zig build test-editor-fold-marks test-editor-incremental-folds -j2
python3 tools/editor-fold-marks/review.py --output <새 외부 경로>
```

중립 판정 5개는 빈 범위·고아 머리·중복·반복 조회·경계·숨은 줄 건너뛰기·고정 seed 무작위 목록과
4만 줄을 독립 전수 조회에 대조한다. 제품 실행 6개(동작 2개·import 4개)는 실제 펴기·부분/전체 접기와 공유 편집·Undo/Redo에서
게시한 모든 표식의 개수·값을 기존 이진 탐색과 대조한다. 기존 접힘 회귀 실행 12개는 할당 실패 시 게시 보존,
LSP 우선권, 공유 문서의 여러 줄 삭제·붙여넣기와 파싱 재개를 포함한다.
테스트의 표식 개수도 독립 확인해 빈 출력이 반복문을 우회하고 통과하지 못하게 했다.

범위 경계·접힌 머리 경계·고아 머리 무시·숨은 줄 건너뛰기·열린 머리 표식을 각각 변형한 독립 결함
5개를 사본에 주입해 런타임 검출했다. 원본 전후 대조군도 통과했다. 컴파일 오류를 검출 성공으로 세지 않는다.

## 전후 실측

```sh
python3 tools/editor-fold-marks/run.py --baseline --output <비교 경로>/baseline --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-marks/run.py --output <비교 경로>/cursor --deps "$PWD/zig-pkg" --fixtures <비교 경로>/baseline/fixtures --repetitions 0
python3 tools/editor-fold-marks/compare.py <비교 경로>
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-fold-marks/summarize.py <비교 경로>
```

동일한 제품 소스에서 두 표식 루프만 기존 점 조회로 되돌린 기준판과 제품판을 준비한다.
모든 뷰의 괄호 목록·판정을 완료한 뒤 같은 고정 원문으로 일반 입력·구조 편집·붙여넣기·Undo·
공유·접힌 상태·명시 접기 명령을 실행한다. 실행 순서는 파일·작업·반복마다 교차한다.
성능과 매 키의 독립 대조는 분리한다. 키별 본문·줄·전체 접힘·표식 결과와 원문·바이너리·계측 소스
해시를 검사하며, 실행 순서와 load average도 보존한다. 타이머는 포함 시간이므로 합산하지 않는다.

로컬 경계 검사와 다른 시스템 부하를 통제한 실험이 아니며 test allocator·시계 비용을 포함한다.
실제 GUI·물리 IME·HID·compositor present·RSS 개선을 입증하는 실험은 아니다.

### 결과

| 일반 입력 | 전체 전/후 p50 | 표시 재구축 전/후 p50 | 표시 재구축 전/후 p95 |
| --- | ---: | ---: | ---: |
| build.zig | 9.35 / 8.97 ms | 0.277 / 0.029 ms | 0.281 / 0.032 ms |
| Swift | 9.39 / 8.98 ms | 0.529 / 0.060 ms | 0.539 / 0.063 ms |
| 3.13 MB Zig | 75.52 / 70.85 ms | 7.206 / 0.330 ms | 8.648 / 0.345 ms |

큰 Zig 공유 두 뷰의 표시 재구축 p50은 14.434→0.660 ms, 명시 접기 명령은 10.675→0.723 ms였다.
성능은 5개 문서·7개 작업·두 방식·3회로 210회/2,910개 입력, 독립 정확성은 70회/970개 입력이다.
전체 수치와 p95는 [결과표](../../tools/editor-fold-marks/results.md)에 보존한다. 단계별 중앙값을 합산하지 않는다.

초기 Swift 일반 입력의 전체 p95는 10.342→12.318 ms로 높아졌고, 제품판 세 실행 중 마지막에서
파싱과 다른 구간도 함께 상승했다. 그때도 표시 재구축은 약 0.060 ms였다.
로컬 경계 검사가 끝난 뒤 같은 바이너리로 각각 6회/120개 입력을 교차 실행한 후속 대조에서는
전체 p50 9.343→8.856 ms, p95 9.835→9.617 ms로 상승이 재현되지 않았다.
초기 결과를 삭제하거나 후속 수치로 바꾸지 않는다. 원인을 외부 부하로 확정하거나 모든 p95의
개선을 보장하지 않는다. 재현 명령은 다음과 같다.

```sh
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix followup --files real-host.swift --workloads typing --repetitions 6
python3 tools/editor-fold-marks/summarize.py <비교 경로> --followup
```

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/fold-mark-comparison/`의 변형별
`inputs.json`, `setup-1.json`, `binaries.json`, `run-*.log`, `verify-*.log`,
비교 루트의 `run-order.json`, `verify-order.json`, `comparison-summary.json`,
`followup-order.json`, `followup-summary.json`과 원시 후속 로그다.
실패 주입은 같은 artifacts 루트의 `fold-mark-cursor-review-final/`에 원본 전후·결함별 증거를 둔다.
접힘 캐시의 후보 정렬·행 조회와 파싱 비용은 이번 변경에 포함하지 않았다.
