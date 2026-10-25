# 접힘 범위 승격의 내부 비용 귀속

상태: #4584가 머지된 main `a5b7b22ca`에서 제품 사본 빌드·성능 30회/600편집·별도
정확성 10회/200편집/300뷰를 완료했다. 합성 반례 검사 7개와 실제 원시 자료에 대한
다섯 독립 공격의 23개 오류 거절·정상 전후 대조·원본 불변도 통과했다.
[전체 분포와 증거](../../tools/editor-fold-promotion-measure/results.md)를 따른다.
제품 최적화는 별도 후속이다. #4585의 필수 CI가 통과해 `fd953386b`로 머지됐고,
실제 main의 문서 링크·행 참조·config 검사도 통과했다. 머지된 main의 CI
`40173818911`도 성공했다.

## 확인할 문제

[pane 구문 실측](../../tools/editor-pane-syntax-measure/results.md)의 `promoteFolds`는
실제 `promoteFoldRangesToSyntax` 전체 호출 시간이다. 3,127,780바이트 합성 Zig의
공유 2뷰 중앙값은 2.385ms였다. 이 원문의 파일명 `flat-50000.zig`는 함수 수를
뜻하며, 실제 LF 개행은 200,000개다. 이 과거 수치를 현재 main의 값이나 개선량으로 쓰지 않는다.

이 함수는 캐시의 접힘 후보를 읽는 것 외에도 행 범위·깊이를 만들고, 접힌 머리를
검증하고, 범위 저장소와 보이는 줄·열 폭·스크롤 상태를 갱신한다. 전체 시간만 보고
구문 트리 순회가 원인이라고 판단하지 않는다.

## 제품과 관측의 경계

새 도구는 기존 pane 구문 측정기의 외부 사본만 계측한다. 원본 `src/`·제품 빌드·ABI·
뷰 소유·접힘 정책은 바꾸지 않는다. LSP 우선권, 복원 의도, 공유 뷰의 접힌 범위 보존,
할당 실패 뒤 펼쳐진 뷰의 일관성은 기존 구현과 oracle이 소유한다.

관측은 pane의 `advanceSyntax` 안에서 시작한 구문 승격에만 한정한다. 같은 함수가
편집 중·LSP 응답·사용자 접기·복원에서 호출된 시간은 섞지 않는다. 현재 승격과 그 안의
설치 문맥을 각각 저장하고 `defer`로 복원하며, 입력 시작과 끝에서 플래그 해제를 검사한다.

| 구간 | 실제 경계 | 포함 관계 |
|---|---|---|
| `promote` | `promoteFoldRangesToSyntax` | 기존 `INNER.promoteFolds` 안 |
| `query` | `prov.foldSpansCached` 호출 | `promote` 안 |
| `ranges` | 결과 범위 할당과 깊이 변환 | `promote` 안 |
| `install` | `installFoldRanges` | `promote` 안 |
| `visible` | 설치 중의 `rebuildVisible` 호출 | `install` 안 |
| `finish` | 설치 중의 `finishFoldChange` 호출 | `install` 안 |

`query`·`ranges`·`install`은 서로 겹치지 않는다. `visible`·`finish`도 형제 호출이며
설치의 다른 작업과 스크롤 복원은 남은 포함 시간에 들어간다. 이를 개별 중앙값의
뺄셈으로 정확한 독립 구간이라고 설명하지 않는다. 계측 자체의 시간도 포함된다.
실패 시 `rebuildVisible`이 다시 호출되면 실제 호출 수를 그대로 센다. 정식 정상
fixture에서는 뷰당 한 번의 각 구간과 비어 있지 않은 후보를 요구한다.

## 고정 입력과 실행

기존 다섯 원문과 일반 1뷰·공유 2뷰를 사용한다. 세 합성 Zig 파일의 LF 개행 수는
각각 12,000·60,000·200,000개이고, 두 실제 파일은 기존 고정 사본이다. 입력마다
파일 해시·실제 byte 수·LF 수를 저장해 파일명 숫자와 표시 줄 수를 혼동하지 않는다.

성능은 셀당 20편집씩 3반복(30개 프로세스·600편집), 매 입력 전체 대조는 별도
1반복(10개 프로세스·200편집·300뷰)이다. 성능 표본과 oracle 실행을 합치지 않는다.
기존 FRAME·STORAGE·PROVIDER·PANE·LOWERING·INNER의 호출·시간·본문/접힘/괄호·
sticky 대조를 유지한다. 실제 호출 수와 성공한 프로세스 순서를 함께 보존한다.

새 출력은 독립 schema·target·구간 순서·문맥 설명을 가진다. 생성기를 빌드 전에
사본과 SHA-256으로 고정하고 원본/계측 소스·실행 파일·원문·원시 로그를 보존한다.
진단에서 사후로 수집한 해시를 정식 실행 전 기록으로 설명하지 않는다.

## 검증과 판단

판독기는 입력 20개의 누락·중복·순서와 뷰별 호출 수, 후보 수, 위 표의 포함 관계와
형제 구간 합계를 검사한다. 기존 모집단과 정확성 대조를 빠뜨린 자료는 완료로 받지 않는다.
출력은 모든 파일·뷰의 중앙값/p95/최댓값이며, 호출하지 않은 구간을 반올림된 0ms와 구분한다.

다섯 독립 공격은 표본/순서, 호출 문맥/작업량, 시간 포함/겹침, schema/생성 모델,
원본·실행 파일·로그 증거를 대상으로 한다. 각 전후 정상 대조군과 원본 불변을 확인한다.
새 도구의 CLI로 다른 모델을 정식 표본인 것처럼 통과시키거나 기존 원시 자료를 덮는 경우도 거절한다.

원인이 확인되면 결과를 근거로 다음 구현 범위를 정한다. 캐시 추가·함수 생략·worker 이동·
접힘 UX 변경을 이 계획으로 승인하지 않는다. 함수 경과시간을 AppKit/HID·GPU present·RSS나
모든 언어와 입력의 최악 지연으로 일반화하지 않는다.

## 재현 명령

```sh
python3 tools/editor-fold-promotion-measure/run.py --output <새 외부 경로> \
  --fixtures <고정 다섯 원문 폴더> --deps <Zig 패키지 경로> --repetitions 0
python3 tools/editor-fold-promotion-measure/run.py --output <같은 외부 경로> \
  --deps <Zig 패키지 경로> --resume --run-only --repetitions 3
python3 tools/editor-fold-promotion-measure/run.py --output <같은 외부 경로> \
  --deps <Zig 패키지 경로> --resume --run-only --repetitions 1 --prefix verify --verify-each-edit 1
python3 tools/editor-fold-promotion-measure/summarize.py <같은 외부 경로>
python3 tools/editor-fold-promotion-measure/verify.py <같은 외부 경로> --receipt <새 외부 기록.json>
python3 -m unittest discover -s tools/editor-fold-promotion-measure -p 'test_*.py'
```

준비는 원문을 명시한 새 외부 경로만 받는다. 실행은 저장된 생성기·전체 소스·원문을
검사한 뒤 기존 사본과 실행 파일을 사용하며 원문을 교체하지 않는다. 실제 명령의 반복 수·
workload 순서·oracle 여부와 실행 순서·로그 해시를 phase별로 보존한다.
잘못된 모델과 기존 원시 자료를 덮는 재실행은 거절한다. 합성 반례 성공은 실제 제품 실행을 뜻하지 않는다.
