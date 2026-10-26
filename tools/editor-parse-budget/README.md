# 일반 편집 파싱 예산 비교

제품 실행 코드를 바꾸지 않고 독립 사본에서 예산 0·4ms의 실제 Provider 호출을 비교한다.
[계획](../../docs/plans/editor-edit-parse-budget.md)이 범위·정책 경계를 소유하며 [실측 결과](results.md)에 분포와 한계를 적었다.
SDK 실행은 macOS·mise의 Zig 0.17·프로젝트의 기존 C 의존성이 필요하다.
순수 Python 계약 검사는 SDK·실측 자료 없이 일반 CI에서 실행한다.

## 재현

각 output은 저장소 밖의 새 경로다. 기존 성공·실패 자료를 덮어쓰지 않는다.
`--deps`는 실재하는 추출 의존성 디렉터리여야 한다. 끊어진 worktree 링크를 쓰지 않는다.
의존성 archive 준비는 기존 `tools/ci/prime-zig-packages.sh` 계약을 따른다.
고정 원문은 [Provider 실측](../editor-provider-measure/README.md)의 다섯 파일이며
파일 이름·원문 크기·SHA-256을 별도로 기록한다. 제품 Git ID와 실제 수집기 snapshot은 구분한다.

```sh
python3 tools/editor-parse-budget/run.py --output /tmp/budget-new --deps /path/to/dependencies --fixtures /path/to/pinned-fixtures
python3 tools/editor-parse-budget/verify.py /tmp/budget-new --expected-head FULL_PRODUCT_GIT_ID --output /tmp/budget-verified.json
python3 tools/editor-parse-budget/summarize.py /tmp/budget-new --expected-head FULL_PRODUCT_GIT_ID --output /tmp/budget-summary.json
python3 tools/editor-parse-budget/adversarial.py /tmp/budget-new --expected-head FULL_PRODUCT_GIT_ID --output /tmp/budget-record-faults
python3 tools/editor-parse-budget/mutants.py /tmp/budget-new --expected-head FULL_PRODUCT_GIT_ID --output /tmp/budget-compiled-faults
python3 tools/editor-parse-budget/tail.py /tmp/budget-new --expected-head FULL_PRODUCT_GIT_ID --output /tmp/budget-callback-diagnostic
python3 -m unittest discover -s tools/editor-parse-budget -p 'test_*.py'
```

수집기·다섯 가설의 실제 기록 손상 검사·실제 C 결함 사본은 별도 실행이다.
실행 중 도구를 수정하지 않는다. 사본의 source·바이너리·원문·도구·명령·대상 결과·로그를 보존한다.
빌드 캐시 밖에 바이너리를 보관하므로 캐시 수명과 증거 수명을 구분한다.
제품 src·build manifest뿐 아니라 실제 `tools/simple_test_runner.zig`와 `.mise.toml` 사본도 Git에 대조한다.

## 모집단과 시간

다섯 원문 × 예산 2개 × 독립 프로세스 3개 × 공백 삽입 20회가 성능 600입력이다.
별도 프로세스 10개에서 매 입력을 새 C 파싱과 대조한다(정확성 200입력).
초기 트리 준비·빌드 대조 실행은 이 모집단에 섞지 않는다. 첫 입력은 포함하고 별도 통계도 남긴다.
문서 가운데 줄 시작에 공백을 삽입한다. 실제 Undo 명령·GUI/HID·IME·공유 뷰 성능 표본은 아니다.

기존 경계 타이머를 양쪽 사본에 똑같이 둔다. progress 콜백을 추가하거나 만료를 강제하지 않는다.
실제 C 반환과 최종 완료를 대조하고 첫 호출·모든 재개 호출의 시간·최대 호출·호출 합을 각각 기록한다.
`wall_ns`는 중간 로그 출력까지 포함하며, `call_ns`는 호출 시간만 합친다. 둘은 CPU 시간이 아니다.
색 질의는 파싱 호출 합 밖에서 따로 재며 처음 쿼리 생성 비용도 제외하지 않는다.
원시 ns를 보존하고 p95는 nearest rank를 사용한다. 중첩 구간의 중앙값은 더하지 않는다.

## 정확성 대조

전체 C 노드의 종류·자식/필드·named/missing/extra/error·시작/끝 byte·행·열을 새 파싱과 대조한다.
실제 C 트리를 잘못 이동시킨 대조군을 거절하므로 S-expression만 같은 좌표 오류를 놓치지 않는다.
pending 중 다른 최신 원문, 트리 없는 cold pending, byte 역편집과 한글·이모지 전체 치환을 검사한다.
이 입력열은 제품 Undo 스택·물리 IME 입력의 검사가 아니다.

제품 syntax State API에서는 pending 입력 판/복사를 거절하고 기존 peer를 보존하는지,
재개 후 입력 판이 비어 있는지, 정상 재발급 뒤 공유 복사·접힘·괄호 결과와 원본 종료를 검사한다.
이것은 기존 API 경계 대조다. 후보 예산을 AppSession의 실제 편집 경로에 연결한 결과가 아니다.

## 콜백 간격 진단

`tail.py`는 별도 사본에서 progress 검사 사이의 최대 구간과 마지막 검사 이후 C 반환까지를 잰다.
동일 구간의 스레드 CPU 시간을 macOS 시계로 대조해 벽시계 대기를 계산 작업과 구분한다.
이 추가 계측의 시간은 성능 모집단에 넣지 않는다. 두 시계의 읽기 시점 차이가 있어 ns 단위의
동일성을 기대하지 않는다. 특정 C 내부 함수에 시간을 귀속시키는 도구는 아니다.

## 정책 경계

4ms 예산이 모든 호출의 엄격한 상한이라고 가정하지 않는다. 재개 뒤 전체 변경으로 저하되는 상태와
입력 판 재발급, 캐시 무효화 비용을 함께 판단해야 한다. 이 도구는 제품의 동기 완료 정책이나
pending 화면, worker, 저장 형식·의존성·파싱 예산을 변경하지 않는다.
