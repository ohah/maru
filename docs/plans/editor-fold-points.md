# 접힘 후보의 근처 행 조회

상태: 구현·좌표 대조·기존 캐시 회귀·독립 실패 주입·전후 함수 실측 완료.

## 방법과 수명

[비용 귀속](editor-frame-attribution.md)에서 접힘 캐시 조회가 국소 트리 방문 뒤에도 후보 전체의
행·열을 현재 줄 인덱스에서 구하는 비용을 확인했다. [표식 재구축](editor-fold-marks.md) 뒤의
다음 대상으로 이 좌표 조회를 분리한다. 후보 정렬·갱신·출력 게시 정책은 바꾸지 않는다.

`Cache.query`마다 시작·끝 위치의 힌트를 각각 0으로 만든다. 이전 행 근처에서 최대 여덟 칸을
전진해 올바른 구간을 찾으면 현재 문서의 줄 시작 byte로 열을 계산한다. 큰 이동·역방향·
여덟 칸 뒤에도 남는 이동은 기존 이진 탐색으로 처리하고 힌트를 갱신한다.
중첩된 후보의 끝은 정렬 순서대로 증가하지 않아도 된다. 조회당 추가 전진을 제한하므로
큰 범위를 앞뒤로 오갈 때 문서 전체를 반복 순회하지 않는다.

힌트는 조회 함수의 지역 값이다. 편집·프레임·문서 판을 건너 저장하지 않고, 행 번호를 편집 통지의
근사 좌표로 이동시키지도 않는다. byte 후보·C 트리 수명·세대 검증·새 문서 줄 인덱스라는 기존
권한을 유지한다. 힌트마다 새 할당이나 고정된 후보 개수 상한을 추가하지 않는다.

## 검증과 누락 방지

```sh
mise exec -- zig build test-editor-fold-points test-editor-fold-cache test-editor-incremental-folds -j2
python3 tools/editor-fold-points/review.py --output <새 외부 경로> --deps "$PWD/zig-pkg"
```

직접 좌표 검사는 한 줄·잘못된 이전 힌트·줄 경계·여덟 칸 경계·중첩 끝의 역방향·큰 도약·
서로 다른 줄 길이·반복 조회·무작위 5,000개 조회를 독립 전수 탐색과 대조한다.
값뿐 아니라 다음 힌트가 가리키는 행과 실제 전진 수의 제한도 검사한다.
시간 임계치를 unit-test의 통과 조건으로 쓰지 않는다.

집중 필터는 처음에 import 판정 하나만 선택했다. 개수 가드가 이를 실패로 만들었고,
구문 모듈의 test 블록에 `fold_cache`를 명시적으로 참조해 실제 좌표 5개와 import 1개,
총 6개가 실행되는 것을 확인했다. 기존 캐시 판정 9개와 제품 접힘 실행 12개도 대조한다.

줄 경계·이진 탐색 복귀 좌표·열 좌표·전진 제한·힌트 갱신을 각각 변형한 독립 결함 5개를
사본에서 런타임 검출하고 원본 전후 대조군을 확인한다. 컴파일 오류를 검출 성공으로 세지 않는다.

## 전후 실측 재현

```sh
python3 tools/editor-fold-points/run.py --baseline --output <비교 경로>/baseline --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-points/run.py --output <비교 경로>/cursor --deps "$PWD/zig-pkg" --fixtures <비교 경로>/baseline/fixtures --repetitions 0
python3 tools/editor-fold-marks/compare.py <비교 경로>
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-fold-marks/summarize.py <비교 경로> --metric foldSpansCached
```

표식의 순차 재구축은 양쪽에 유지하고, 좌표 조회만 기존 이진 탐색으로 되돌린 기준판과 힌트판을
같은 함수 관측기로 비교한다. 모든 뷰의 괄호 목록·판정을 완료하고 같은 원문·작업을 교차 실행한다.
원문·바이너리·계측 소스 해시, 키별 예상 본문·줄·접힘·표식과 실행 순서를 검사한다.
매 키의 독립 대조와 성능 실행은 분리하며 포함 시간을 합산하지 않는다.
공유 비교 도구의 기본 표식 집계는 그대로 유지하고 선택 metric만 확장한다.

함수 경과시간이며 외부 부하·test allocator·시계 비용을 포함한다. 실제 AppKit·물리 IME·HID·
compositor present·RSS 개선이나 모든 편집의 프레임 예산 충족을 입증하지 않는다.

### 결과

| 일반 입력 | 캐시 조회 전/후 p50 | 캐시 조회 전/후 p95 | 전체 전/후 p50 |
| --- | ---: | ---: | ---: |
| build.zig | 0.610 / 0.546 ms | 0.660 / 0.611 ms | 9.026 / 9.001 ms |
| Swift | 0.572 / 0.522 ms | 0.609 / 0.582 ms | 8.806 / 8.704 ms |
| 3.13 MB Zig | 14.308 / 9.518 ms | 15.508 / 10.579 ms | 64.345 / 57.761 ms |

큰 Zig 공유 두 뷰의 캐시 조회 p50은 29.496→20.049 ms, 전체는 135.101→122.053 ms였다.
같은 고정 원문 5개·작업 7종·두 방식·3회로 성능 210회/2,910개 입력을 측정했고,
별도 정확성 70회/970개 입력을 대조했다. 전체 조건은 [결과표](../../tools/editor-fold-points/results.md)에 둔다.

일반 파일의 전체 시간 변화는 작고 방향도 일정하지 않다. 초기 Swift 일반 입력의 전체 p95는
15.162→16.123 ms였다. 같은 바이너리로 6회씩 교차한 후속 대조에서 캐시 조회는
p50 0.584→0.550 ms, p95 0.610→0.571 ms였지만 전체는 p50 8.892→8.931 ms,
p95 9.642→9.703 ms였다. 따라서 일반 파일의 전체 지연 개선이나 모든 p95의 개선은 주장하지 않는다.
후속 대조를 초기 수치 대신 쓰지 않는다. 문서마다 다른 실측을 연속 개선 곡선으로 더하지도 않는다.

```sh
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix followup --files real-host.swift --workloads typing --repetitions 6
python3 tools/editor-fold-marks/summarize.py <비교 경로> --followup --metric foldSpansCached
```

이전 표식 비교의 기본 집계와 후속 집계를 새 도구로 재생해 기존 결과 파일이 byte 단위로
같은지도 확인했다. 신규 비교 대상·선택 metric은 기본 동작을 바꾸지 않는다.

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/fold-point-comparison/`의 변형별
`inputs.json`, `setup-1.json`, `binaries.json`, `run-*.log`, `verify-*.log`와
비교 루트의 실행 순서·`comparison-summary.json`·`followup-summary.json`이다.
실패 주입은 같은 artifacts 루트의 `fold-point-hints-review-final/`에 원본 전후·결함별 로그와 해시를 둔다.
후보 전체의 정렬·출력 순회와 C 트리 변경 범위 계산·파싱 비용은 여전히 남는다.


## CI의 GUI fixture 시작 경합

macOS 전용 CI는 접힘 검사를 통과한 뒤 GUI 실행 도구의 소유권 검사에서 실패했다.
fixture가 자식의 첫 `process_identity`를 저장하면 Python launcher가 같은 PID·UID·생성 시각을
유지한 채 interpreter로 exec하면서 실행 파일 경로가 바뀔 수 있었다. 실제 Python 시작
100개에서도 이 전이를 확인했다. 제품의 executable·UID·생성 시각 검사는 유지한다.

테스트 자식이 최종 interpreter에서 PID 준비 파일을 원자적으로 게시한 뒤에만 신원을 읽는다.
준비 지연은 유한한 제한 안에서 기다리고, 조기 종료·다른 PID·신원 부재는 계속 실패한다.
준비 전 shell→interpreter exec를 pipe로 제어하는 재현과 각 실패 경로를 포함해
`test_gui_launch.py`의 15개 검사를 실행한다. 준비 단계가 실패해도 자신이 만든 자식과 임시
디렉터리만 정리하도록 cleanup을 자식 생성 직후 등록한다. 실제 GUI 권한 검증으로 해석하지 않는다.


## CI의 diff 실패 주입 격리

다음 CI의 AppSession 전수 실행에서는 diff OOM sweep이 실패 지점 세 개 뒤에 끝났다.
실패 allocator를 세션 초기화부터 worker에 넘겨, 여러 스레드가 비원자 `alloc_index`를 만졌다.
로컬 계측에서도 다른 스레드 할당이 있었고, 주입 지점 21을 지정한 실행이 할당 100개를
완료하면서 실패를 주입하지 못한 경우를 재현했다. 이를 정상 완료로 보면 뒤 실패 지점을 놓친다.

세션과 worker는 backing allocator로 초기화하고 UI `poll` 동안만 실패 allocator를 건다.
종료 시 추가 할당을 완료 판정에 섞지 않으며, 주입 allocator에 다른 스레드가 접근하지 않았는지도
검사한다. worker 접근 계수 자체는 제어한 실제 스레드로 대조한다. 기존 최소 실패 수·정상 결과·
누수 검사는 유지한다. 제품 diff 계산·할당 정책은 변경하지 않는다.

```sh
mise exec -- zig build test-editor-diff-oom -j2
```

이 집중 경로는 실제 판정 둘과 import 넷, 총 6개다. 수정 후 sweep은 99개 실패 지점과
한 개 정상 완료까지 실행했다. 전수 AppSession의 대체가 아니라 빠른 회귀 확인 경로다.
