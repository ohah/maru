# 큰 문서의 편집·프레임 비용 귀속

상태: EW3 뒤 제품 메인 `3d04eefcc4dc45b6fa0ea8d05883867739518ab9`에서 세부 계측 완료.
제품 최적화나 스레딩·UX 변경은 포함하지 않는다.

## 방법과 조건

`tools/editor-frame-measure/run.py`는 기존 저장소 계측과 제품 입력 판정자를 재사용한다.
저장소 밖의 소스 사본에만 시계를 넣어 편집 전체와 다음 pane 프레임을 나눈다.
구문 편집·provider 편집·C 파싱, 괄호 이동/갱신, 접힘 캐시 이동/조회, 들여쓰기 범위 수집,
범위 설치·표시 재구축, 구문 색·미니맵·줄 폭·draw 목록 생성을 따로 기록한다.

포함 시간은 합산하지 않는다. `advanceSyntax`는 승격을, 승격은 캐시 조회와 범위 설치를 포함한다.
`syntaxEdit`는 provider 편집을, provider 편집은 C 파싱을 포함한다. `rebuildVisible`과
`ensureLineCols`는 편집·프레임 양쪽에서 불릴 수 있으므로 한쪽의 자식으로 단정하지 않는다.
키별 시간·소유 구간을 검사하고, 합법적인 중첩을 오류로 거절하는 결함도 주입해 검출한다.

기존 EW3의 준비는 파싱·접힘 완료만 보장했다. 이번에는 모든 뷰에 `finishBrackets`와
설정에 맞는 `advanceBrackets`를 적용하고 목록·판정의 완료를 단언한 뒤 입력을 시작한다.
집계기도 이 준비 기록을 요구한다. 따라서 이전 48.71 ms와 아래 수치를 동일 조건의 회귀로 비교하지 않는다.
차이 전체를 괄호 처리 비용이라고 단정하지도 않는다. 외부 시스템 부하·allocator 배치도 통제하지 않았다.

## 결과와 다음 대상

| 일반 입력 p50 | build.zig | Swift | 3.13 MB 합성 Zig |
| --- | ---: | ---: | ---: |
| 편집+프레임 | 9.52 ms | 9.54 ms | 73.39 ms |
| 편집 전체 | 4.16 ms | 2.95 ms | 38.74 ms |
| pane 프레임 | 5.38 ms | 6.58 ms | 32.62 ms |
| C 파싱 | 2.96 ms | 0.82 ms | 20.52 ms |
| 접힘 캐시 조회 | 0.64 ms | 0.61 ms | 14.91 ms |
| 표시 재구축 | 0.28 ms | 0.53 ms | 7.22 ms |
| 구문 색 | 1.45 ms | 1.81 ms | 0.40 ms |

큰 합성 Zig의 전체 p95는 83.60 ms, 공유 두 뷰는 p50 150.73 ms였다.
단계별 중앙값의 합은 전체 중앙값이나 입력별 비중과 같지 않다. 전체 조건·하위 구간은
[결과표](../../tools/editor-frame-measure/results.md)에 둔다.

Maru가 제어하는 다음 개선 대상으로 접힘 캐시 조회와 표식 재구축을 우선 검토한다.
캐시 조회는 국소 트리 방문 뒤에도 전체 후보의 정렬·행 조회를 수행한다.
펼쳐진 `rebuildVisible`은 모든 줄에서 `markFor`로 정렬된 범위·접힘 머리를 이진 탐색한다.
이미 정렬된 입력을 병합 순회하는 방식이나 게시 중복 제거의 효과를 대조 실험으로 확인할 수 있다.
이 코드 관찰만으로 개선 폭을 보장하지 않으며, 실제 구현은 전체 표식/접힘 결과·실패 원자성과 함께 검증한다.
파싱을 워커로 옮기는 정책 변경은 이번 판단에 포함하지 않는다.

## 재현과 검증

```sh
python3 tools/editor-frame-measure/run.py --output <새 외부 경로> --deps "$PWD/zig-pkg"
python3 tools/editor-frame-measure/run.py --output <같은 경로> --deps "$PWD/zig-pkg" --resume --run-only --repetitions 1 --verify-each-edit 1 --prefix verify
python3 tools/editor-frame-measure/summarize.py <같은 경로>
python3 tools/editor-frame-measure/review.py --output <새 외부 검증 경로>
python3 -m unittest discover -s tools/editor-frame-measure -p 'test_*.py' -v
```

고정 원문 5개·입력 5종·3회로 성능 75회/855개 입력을 실행했다. 별도 정확성 25회/285개 입력은
키마다 버퍼/문서 본문·모든 뷰의 줄 내용·전체 순회 접힘 결과와 예상 byte/줄 수를 대조했다.
키 대응·시간 구간 중첩·부모 경계·포함 시간 이중 계산을 각각 누락/변형한 독립 결함 5개를
메모리 사본에 주입해 런타임에서 검출했고, 원본 전후 대조군 7개도 통과했다.
원문·바이너리·계측 소스 해시를 확인했다. 초기 함수 경계·상수 그림자 문제는 빌드 단계에서 수정했고,
괄호 준비 조건이 없던 중간 실행은 `preliminary*` 아래에 보존해 최종 집계에서 제외했다.

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/editor-frame-measure/`의 `inputs.json`,
`setup-1.json`, `binaries.json`, `hardware.json`, `frame-summary.json`, `run-*.log`, `verify-*.log`다.
실패 주입은 같은 artifacts 루트의 `editor-frame-measure-review-final-ready/`에 보존했다.
일반 뷰는 800×600, 공유 뷰는 각각 400×600이며 새 공유 뷰의 첫 접힘 캐시 구축 비용도 포함한다.
외부 `sample` 수집은 종료 코드 255로 실패했으므로 CPU 샘플 근거는 없으며 함수 경과시간만 인용한다.
실제 AppKit·물리 IME·HID·compositor present·RSS 개선을 입증한 실험은 아니다.
