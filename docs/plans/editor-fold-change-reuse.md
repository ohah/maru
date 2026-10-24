# 접힘 변경 범위 재사용

상태: 구현·집중 회귀·독립 결함 주입·전후 실측·전체 로컬 게이트 완료. 최종 main 리베이스·CI 미완료.

## 근거

[조회 비용 귀속](editor-fold-query-attribution.md)에서 큰 파일 조회의 대부분이
`ts_tree_get_changed_ranges`였고 `Provider.noteChanged`와 `Cache.query`가 각각 호출했다.
Provider가 마지막 성공 파싱에서 계산한 범위를 각 캐시가 독립적으로 읽을 수 있게 한다.

## 권한과 수명

Provider의 `fold_changes`는 기존 `changed`와 별도인 보관 공간이다.
`takeChanged`는 원래의 소비 계약을 유지하며 접힘용 보관 공간을 비우지 않는다.
보관 개수는 기존 `Provider.max_changed`를 재사용한다. 이를 넘는 결과는 버리지 않고,
재사용 권한만 없애 캐시가 자기 이전 트리와 현재 트리를 직접 비교하게 한다.
추가 heap 할당·작업 지연·접힘 출력 상한은 도입하지 않는다.

`fold_changes_before`는 계산에 쓴 이전 세대이며 다음 성공 세대만 대상으로 한다.
전체 파싱·빈 문서·지원 용량 밖의 본문은 보관 권한을 지운다.
접힘 캐시는 같은 parser와 세대를 확인한 기존 무효화 절차 뒤에 다음 조건을 모두 요구한다.

- 편집 통지를 정확히 한 번 받았다.
- 캐시의 동기화 세대가 범위의 이전 세대와 같다.
- 현재 세대가 범위의 다음 세대와 같고 두 세대 차이는 정확히 하나다.

세대를 건너뛴 캐시·여러 편집을 모은 캐시·보관 범위 부재는 기존 트리 비교로 돌아간다.
구조 변경 범위가 비어 있어도 실제 dirty 범위를 방문하는 기존 계약을 유지한다.
바이트 후보·현재 문서 줄 인덱스·범위 정렬·최장 후보·snapshot/OOM 계약은 그대로다.
`Cache.reused_changes`와 `compared_changes`는 경로 선택을 시간 없이 검사하는 누적 계수다.

## 검증

```sh
mise exec -- zig build test-editor-fold-changes test-editor-fold-cache test-editor-fold-points test-editor-incremental-folds -j2
python3 tools/editor-fold-changes/review.py --output <새 외부 경로> --deps "$PWD/zig-pkg"
```

집중 검사는 실제 5개와 import 1개로 총 6개다. 소비 API 뒤 두 캐시의 독립 읽기,
두 편집 누적, 같은 세대 재조회, 범위 부재·잘못된 세대, 전체 교체를 전수 접힘과 대조한다.
기존 캐시 검사 9개는 언어별 무작위 편집·외부 영향 구조 변화·같은 구조의 편집·OOM을 대조한다.
범위 부재 검사는 보관 불가 상태를 직접 주입한다. 실제 C 비교가 보관 한도보다 많은 범위를
돌려주는 사례를 이 검사만으로 입증했다고 주장하지 않는다.

독립 결함 주입은 재사용 차단·소비에 의한 권한 삭제·전체 교체의 권한 보존·잘못된 구조 범위·
실제 dirty 범위 누락을 각각 넣는다. 컴파일 실패를 검출 성공으로 세지 않고 원본 전후를 대조한다.

## 전후 실측

```sh
python3 tools/editor-fold-changes/run.py --baseline --output <비교 경로>/baseline --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-changes/run.py --output <비교 경로>/cursor --deps "$PWD/zig-pkg" --fixtures <비교 경로>/baseline/fixtures --repetitions 0
python3 tools/editor-fold-marks/compare.py <비교 경로>
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-fold-marks/summarize.py <비교 경로> --metric foldSpansCached
```

양쪽 모두 행 힌트·표식 최적화·Provider의 범위 보관을 유지하고 재사용 여부만 바꾼다.
함수 경과시간 대조이며 물리 입력·AppKit present·RSS 개선의 증거가 아니다.
실측 결과를 확인하기 전 지연 개선 폭을 주장하지 않는다.


### 결과와 한계

고정 원문 5개·작업 7종·두 방식·3회로 성능 210회/2,910개 입력,
별도 정확성 70회/970개 입력을 검증했다. 모든 본문·줄·접힘·표식 대조는 일치했다.
양쪽 모두 범위 보관을 수행하고 재사용만 켜거나 끈 비교이므로, 보관 자체를 추가한 비용을
포함한 과거 main과의 순수 비교라고 주장하지 않는다.

| 일반 입력 | 조회 전/후 p50 | 조회 전/후 p95 | 전체 전/후 p50 | 전체 전/후 p95 |
| --- | ---: | ---: | ---: | ---: |
| 3.13 MB Zig | 9.216 / 0.803 | 10.255 / 0.843 | 52.128 / 46.050 | 64.493 / 58.594 |
| build.zig | 0.555 / 0.086 | 0.592 / 0.102 | 8.558 / 8.078 | 9.238 / 8.641 |
| Swift | 0.489 / 0.167 | 0.543 / 0.173 | 8.475 / 8.274 | 9.334 / 8.833 |

단위는 ms다. 큰 Zig 공유 두 뷰는 조회 p50 18.118→1.599ms,
전체 p50 104.151→91.341ms였다. 전체 35조건은 [결과표](../../tools/editor-fold-changes/results.md)에 보존한다.
큰 Zig 붙여넣기는 조회 15.974→16.447ms, 전체 60.155→61.494ms로 개선되지 않았다.
진단 사본에서 C가 실제 변경 범위 100개를 반환했고, `Provider.max_changed`를 넘어
`fold_changes_before`가 비워진 것을 확인했다. `reused=0 compared=1`로 기존 트리 비교를
수행했고 전수 대조가 일치했다. 이 사례는 편집 여러 번 누적이 아니라 한 번의 편집에서
구조 변경 범위가 많은 경우다. 결과를 생략하지 않는다.

Swift 공유 뷰의 초기 전체 p95는 14.224→17.122ms였다. 같은 바이너리로 6회씩 교차한 후속 대조는
조회 p50 1.191→0.334ms, 전체 p50 13.985→13.515ms였지만 전체 p95는 16.289→23.424ms였다.
각 실행 첫 입력의 조회는 양쪽 모두 약 15ms였고 이후 입력은 훨씬 짧았다.
첫 입력이 전체의 5%여서 p95가 추가 지연에 민감하다. 후속 재사용판의 높은 지연 입력에서는
nativeParse·edit·다음 프레임 등 다른 구간도 늘었지만 외부 부하를 원인으로 확정하지 않는다.
모든 p95 개선이나 전체 지연의 회귀 부재를 주장하지 않는다. 후속 결과로 초기 결과를 대체하지 않는다.

```sh
python3 tools/editor-fold-marks/compare.py <비교 경로> --prefix followup --files real-host.swift --workloads shared --repetitions 6
python3 tools/editor-fold-marks/summarize.py <비교 경로> --followup --metric foldSpansCached
```

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/fold-change-comparison/`의 해시 manifest,
바이너리·원시 로그·실행 순서·`comparison-summary.json`·`followup-summary.json`이다.
독립 결함 주입의 최종 증거는 같은 artifacts 루트의 `fold-change-review-v2/`다.
초기 결함 주입에서 일반 전체 교체는 다른 초기화 경로가 결함을 가려, 빈 문서 교체도 검사하도록
강화한 뒤 다섯 결함 모두 런타임 검출했다. 초기 미완료 결과는 최종 검증으로 세지 않는다.


### 복귀 경로의 제품 사본 진단

```sh
python3 tools/editor-fold-changes/run.py --diagnostic --output <새 진단 경로> --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-changes/run.py --diagnostic --output <같은 경로> --deps "$PWD/zig-pkg" --resume --run-only --workloads paste --repetitions 1
```

`--diagnostic`은 사본에서 `FOLD_PROVIDER_CHANGES`의 실제 C 범위 개수와
`FOLD_CHANGES`의 누적 재사용·비교 계수·보관 권한·세대를 출력한다.
진단 로그의 시간은 성능 비교에 쓰지 않는다. 실제 최종 진단 증거는
`/Users/yoonhb/.cache/maru-agent-artifacts/fold-change-diagnostic-v2/`에 있다.
큰 Zig 붙여넣기는 `count=100 before=1`, `reused=0 compared=1 available=0 generation=2`였다.
상태를 주입한 unit 검사와 이 실제 C 결과 재현을 구분한다.


### 실제 선행 코드와의 추가 비교

재사용 효과만 분리한 위 실험을 보존하고, 범위 보관 자체가 없는 선행 커밋
`4d787888d62cd5d9874fad7c9156b4bfb906bce2`의 `folds.zig`·`tree_sitter.zig`를
그대로 읽어 프레임 관측만 넣은 기준판도 비교했다. `--baseline-ref`는 확정한 커밋과
원본 두 파일의 해시를 manifest에 별도로 기록한다. 현재 제품은 원래 검증한 바이너리를
해시 검증 후 그대로 재사용했다. 파일 5개·작업 7종·두 방식·3회, 210회/2,910개 입력과
별도 정확성 70회/970개 입력이 모두 성공했다.

```sh
python3 tools/editor-fold-changes/run.py --baseline-ref <선행 커밋> --output <새 비교 경로>/baseline --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-changes/run.py --output <새 비교 경로>/cursor --deps "$PWD/zig-pkg" --fixtures <새 비교 경로>/baseline/fixtures --repetitions 0
python3 tools/editor-fold-marks/compare.py <새 비교 경로> --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-fold-marks/compare.py <새 비교 경로>
python3 tools/editor-fold-marks/summarize.py <새 비교 경로> --metric foldSpansCached
```

| 일반 입력 | 조회 전/후 p50 | 조회 전/후 p95 | 전체 전/후 p50 | 전체 전/후 p95 |
| --- | ---: | ---: | ---: | ---: |
| 3.13 MB Zig | 9.923 / 0.801 | 11.523 / 0.851 | 57.088 / 49.499 | 68.469 / 65.761 |
| build.zig | 0.516 / 0.092 | 0.621 / 0.104 | 8.386 / 8.012 | 9.721 / 8.820 |
| Swift | 0.516 / 0.165 | 0.564 / 0.190 | 8.598 / 8.314 | 9.439 / 11.916 |

단위는 ms다. 큰 Zig 공유 뷰는 조회 p50 19.921→1.616ms, 전체 p50 116.763→98.883ms였다.
전체 35조건은 [실제 선행 코드 비교표](../../tools/editor-fold-changes/results-actual.md)에 보존한다.
큰 붙여넣기 초기 전체 p50은 59.482→68.871ms였다. 표본이 방식당 3개이므로 20쌍을
추가 교차했고, 전체 p50 57.735→58.450ms, p95 73.888→72.938ms였다.
조회 p50은 15.268→15.688ms였다. 이 경로의 개선이나 모든 회귀 부재를 주장하지 않는다.

Swift 공유 뷰의 전체 p95도 15.416→19.634ms로 높았다. 전체 입력을 유지한 보조 분해에서
첫 입력 3개의 전체 p50은 29.582→30.045ms였고, 후속 57개는 p50 13.710→13.152ms,
p95 15.151→14.553ms, 최대 15.416→19.634ms였다. 첫 입력 3개가 모두 더 길어 전체의
5%를 차지하므로 이 실행의 전체 p95는 후속 입력 최댓값에 해당한다. 이 분해로 원래 전체
p95를 대체하지 않으며, 외부 부하를 원인으로 확정하지 않는다.

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/fold-change-actual-comparison/`의
기준 커밋·원본/계측 해시·바이너리 해시·원시 로그·실행 순서·`comparison-summary.json`,
`followup-summary.json`, `shared-strata.json`이다. 전체 로컬 검사와 빌드가 끝난 뒤
성능 실행을 시작했으며 외부 프로세스 부하는 통제하지 않았다.

```sh
python3 tools/editor-fold-marks/compare.py <새 비교 경로> --prefix followup --files flat-50000.zig --workloads paste --repetitions 20
python3 tools/editor-fold-marks/summarize.py <새 비교 경로> --followup --metric foldSpansCached
```
