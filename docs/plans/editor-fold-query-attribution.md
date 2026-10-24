# 접힘 조회 세부 비용 측정

상태: 측정 도구 구현·성능 실행 완료, 독립 정확성 실행 완료.

## 목적과 범위

[근처 행 조회](editor-fold-points.md) 이후에도 남는 `foldSpansCached` 비용을 구분한다.
제품 소스를 직접 수정하지 않고 외부 사본에만 타이머를 주입한다.
`tools/editor-fold-query/run.py`는 기존 프레임 측정·접힘/표식 대조기를 재사용한다.
원문·사본·바이너리 해시는 기존 manifest에 보존하고 새 계측 파일 해시를 갱신한다.

조회 성공 경로를 변경 범위 계산, 후보 삭제·국소 수집, 정렬, 중복 제거,
좌표·출력 변환, snapshot 교체의 겹치지 않는 구간으로 나눈다.
첫 조회에는 이전 트리가 없으므로 변경 범위 시간은 0이고 전체 수집은 후보 갱신에 포함한다.
C 변경 범위 배열의 해제는 후보 갱신에 포함한다. 시계 호출·분기 등 잔여 시간은 따로 남긴다.
`OutOfMemory` 또는 조기 반환 경로의 완전한 비용 분해는 이 측정의 계약 밖이다.
사본의 전역 집계기는 단일 스레드 fixture 전용이며 제품 관측 API가 아니다.

## 재현과 판정

```sh
python3 tools/editor-fold-query/run.py --output <새 외부 경로> --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-fold-query/run.py --output <같은 경로> --deps "$PWD/zig-pkg" --run-only --resume --repetitions 3 --workloads typing,structure,paste,undo,shared,folded,command
python3 tools/editor-fold-query/run.py --output <같은 경로> --deps "$PWD/zig-pkg" --run-only --resume --prefix verify --verify-each-edit 1 --repetitions 1 --workloads typing,structure,paste,undo,shared,folded,command
python3 tools/editor-fold-query/summarize.py <같은 경로>
python3 tools/editor-fold-query/verify.py
```

기존 로그와 겹치지 않는 prefix·새 경로를 사용한다. 성능 실행과 매 입력의 독립 대조를 분리한다.
집계기는 성공한 테스트 5개를 요구하고 FRAME/FOLD_QUERY의 키를 일대일 대응시킨다.
중복 키·누락 구간·음수·세부 시간 합이 상위 시간보다 큰 기록을 거절한다.
각 결함 기록과 원본 전후 대조군을 `verify.py`로 검증한다.
실행 중인 미완성 로그도 성공 기록이 없으므로 거절한다.

## 측정 결과

고정 원문 5개·작업 7종·3회, 총 105회/1,455개 입력이다.
별도 매 입력 대조 35회/485개 입력도 모두 일치했다.
다음 값은 함수 경과시간의 중앙값이며 단위는 ms다.

| 일반 입력 | 조회 전체 | 변경 범위 | 후보 갱신 | 정렬 | 중복 제거 | 좌표·출력 | snapshot |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3.13 MB Zig | 10.750 | 9.924 | 0.059 | 0.318 | 0.038 | 0.394 | 0.004 |
| build.zig | 0.548 | 0.454 | 0.003 | 0.013 | 0.001 | 0.073 | 0.002 |
| Swift | 0.528 | 0.366 | 0.006 | 0.018 | 0.001 | 0.134 | 0.002 |

큰 Zig 공유 두 뷰는 조회 전체 21.050ms, 변경 범위 19.221ms였다.
각 열의 중앙값은 서로 다른 입력에서 나올 수 있으므로 더해서 전체와 같다고 해석하지 않는다.
키별 세부 합과 상위 시간 비교는 집계기가 원시값에서 검사한다.
증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/fold-query-attribution/`의
manifest·바이너리·원시 로그·`summary.json`이다.

이 실행은 구간 귀속이며 이전 PR과 시간 순서·부하가 달라 전후 성능 비교가 아니다.
계측 오버헤드가 없는 동일 실행과 교차하지 않았으므로 계측 자체의 오버헤드도 확정하지 않는다.
외부 프로세스 부하, test allocator, 시계 호출의 영향을 포함한다.
실제 AppKit·물리 IME·HID·compositor 지연 개선은 주장하지 않는다.

## 후속

`Provider.noteChanged`와 `Cache.query`는 각각 `ts_tree_get_changed_ranges`를 호출한다.
이는 중복 계산을 줄일 후보지만 두 호출이 항상 같은 이전 트리를 뜻하지는 않는다.
뷰의 지연·여러 편집·세대 도약·구조가 같은 텍스트 편집·범위 저장 초과와 소비 수명을
대조한 뒤에만 공유를 설계한다. 이번 측정은 재사용 구현이나 안전성 입증을 포함하지 않는다.
후보 정렬 최적화보다 변경 범위 계산의 중복 여부를 먼저 검증한다.
