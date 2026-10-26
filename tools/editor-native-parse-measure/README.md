# Native 파싱·변경 범위 계측

제품 소스는 바꾸지 않고 저장소 밖 사본에서 측정한다. macOS와 프로젝트의 Zig·C 의존성이 필요하다.
기준 실측은 기존 Provider/frame/storage 도구를 사용하고, 콜백 계수는 별도 진단 바이너리에만 넣는다.
[계획](../../docs/plans/editor-native-parse-attribution.md)과 [확인한 결과](results.md)를 함께 본다.

## 입력과 실행

고정 원문 폴더에는 다음 다섯 파일이 있어야 한다. 현재 보존 자료의 입력은
`/Users/yoonhb/.cache/maru-agent-artifacts/visible-color-window-paired-1/fixtures`다.
과거 원문 바이트를 재사용하되 과거 시간 표본은 재사용하지 않는다.

- `flat-3000.zig`, `flat-15000.zig`, `flat-50000.zig`
- `real-build.zig`, `real-host.swift`

각 출력은 저장소 밖의 새 경로여야 한다. 이미 있는 출력과 원시 로그를 덮어쓰지 않는다.
아래의 입력·의존성 경로와 수집 당시의 전체 commit ID를 실제 값으로 바꾼다.

```sh
python3 tools/editor-native-parse-measure/baseline.py --output /tmp/native-parse-new/baseline --deps /path/to/zig-pkg --fixtures /path/to/pinned-fixtures
python3 tools/editor-native-parse-measure/run.py --output /tmp/native-parse-new/diagnostic --deps /path/to/zig-pkg --fixtures /tmp/native-parse-new/baseline/fixtures
python3 tools/editor-native-parse-measure/verify.py --baseline /tmp/native-parse-new/baseline --diagnostic /tmp/native-parse-new/diagnostic --expected-head FULL_COMMIT_ID --output /tmp/native-parse-new/readback.json
python3 tools/editor-native-parse-measure/adversarial.py --baseline /tmp/native-parse-new/baseline --diagnostic /tmp/native-parse-new/diagnostic --expected-head FULL_COMMIT_ID --output /tmp/native-parse-new/adversarial
python3 tools/editor-native-parse-measure/positive.py --output /tmp/native-parse-new/positive --deps /path/to/zig-pkg
python3 -m unittest discover -s tools/editor-native-parse-measure -p 'test_*.py'
```

기준은 일반/공유 입력 각각 성능 3프로세스와 별도 정확성 1프로세스다.
프로세스마다 문서 중간 부근에 공백 한 글자를 20회 삽입한다. 첫 입력을 포함한
성능 600입력과 별도 정확성 200입력이다. 진단은 10프로세스·정확성 200입력을 추가한다.
준비 빌드의 실행과 추가 양성 대조는 이 모집단에 포함하지 않는다.

## 데이터 의미

진단 필드는 `contract.FIELDS` 한 곳에서 정의하며 Zig 계수 구조와 출력 필드를 생성한다.
기존 Provider schema 3·frame schema 2와 새 native probe schema 1은 별도 축이다.
계수는 이 단일 스레드 진단의 입력 직전에 비우고 제품 프레임 직후 읽는다. 뒤따르는 전수 대조의
호출을 다음 입력의 관측에 섞지 않으며, 제품의 공용 스레드 상태나 API로 이 전역 계수를 추가하지 않는다.

- `calls`, `old_tree_calls`, `source_bytes`, `budget_ns`, `done`, `pending`: 실제 파싱 호출 경계의 자료다.
- `read_calls`, `eof_calls`, `offered_bytes`: reader 콜백의 호출·EOF·제시 길이다.
  제공한 suffix 길이는 파서가 실제로 소비한 길이가 아니다. 중복 제공 합계가 원문 길이보다 클 수 있다.
- `progress_calls`, `cancel_returns`: 실제 콜백 호출과 취소 반환 수다. 방문 노드 수가 아니다.
- `range_calls`, `range_items`, `nonempty_ranges`: 실제 native 변경 범위 호출·반환 개수다.
  범위 0이 텍스트 불변이나 다음 계산 생략의 안전성을 증명하지는 않는다.

추가 계수 비용이 있는 진단 시간은 성능 표본으로 쓰지 않는다. 상위/하위 포함 시간을 더하거나
서로 다른 중앙값을 빼서 잔여 비용을 만들지 않는다. 구조 편집·붙여넣기·Undo·GUI/HID·GPU present·
RSS·모든 언어의 최악 비용으로 확대하지 않는다.
기본 타이머는 awake 경과시간이며 스레드 CPU 시간을 측정한 결과가 아니다.

## 검증과 보존

검증기는 전체 Git 원본 src·빌드·의존성 선언, 계측 소스, 생산자 snapshot, 입력, 실행 파일과
로그의 해시를 대조한다. 제품 결과·키/모집단·스키마 타입·호출 수·시간 포함 관계를 확인한다.
기준·진단의 바이너리 해시도 달라야 한다. `archived-test`를 보존하므로 빌드 캐시가 없어도
같은 실행 파일을 재검증할 수 있다. Git 원본을 대조할 commit object는 로컬 저장소에 있어야 한다.

적대적 검증은 별도의 사본에서 기록·메타데이터·근거 파일을 손상한다. 의미 검사는 로그 해시도
함께 맞춰 해당 판정까지 도달시킨다. 가설 전후 정상 대조와 원본 불변을 확인한다.
`positive.py`는 별도의 실제 C 실행에서 초기 파싱·구조 변경·취소/재개를 확인한다.
취소 대조 사본에만 만료 조건을 강제하며, 실제 UI 마감이나 벽시계 지연을 검증하는 것은 아니다.

원본·계측 코드와 로그·메타데이터·생산자 사본·보관 바이너리를 유지한다.
측정 중에는 캐시 안의 파일을 열어 두어 사용 중임을 확인할 수 있다.
소스나 판독기를 수정했다면 이전 생산자 snapshot을 덮어쓰지 않고 새 판독기의 해시와 재검증을 구분한다.
