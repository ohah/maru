# 구문 Provider 편집 비용 귀속

상태: 사본 계측·성능 30회/600개 입력·정확성 10회/200개 입력 완료. 다섯 독립 가설의 손상 기록·CLI 거절과 원본 전후 대조 완료. 전체 로컬 경계·문서 게이트 완료. 실제 main 리베이스 직후 전체 트리가 동일함을 확인했다. PR CI 통과 후 #4575로 main에 합류했다.

## 확인할 문제

공유 초기 스냅샷 이후에도 큰 문서의 공유 입력은 구문 편집 비용이 남는다.
프레임 계측의 `providerEdit`와 `nativeParse`만으로는 나머지가 트리 이동·변경 범위 계산·
기타 작업 중 어디에 있는지 가를 수 없다. 실제 호출 수와 책임별 포함 시간을 함께 기록한다.

## 제품과 계측의 경계

`tools/editor-provider-measure/run.py`는 기존 제품 접힘·저장소·프레임·표식 대조 호스트를 재사용한다.
제품의 `src/`·빌드·ABI에 마커를 추가하지 않는다. 외부 private 소스 사본에만 타이머와 누적 호출 수를 넣고
현재 macOS AppSession 호스트의 ReleaseFast 테스트 실행 파일을 만든다. 원본과 계측 소스의 해시, 원본 사본·계측 사본·바이너리·원문을 남긴다.
부모 모듈을 가져올 때 argv를 격리하고, 현재 비용 귀속과 다른 baseline·mode·workload, prefix/oracle 불일치와 기존 원시 로그 덮어쓰기는 명시적으로 거절한다.

| 구간 | 경계 | 시간 관계 |
| --- | --- | --- |
| `on_edit` | `Provider.onEditBudgeted` 전체 | 아래 native 파싱·편집·변경 통지를 포함 |
| `reset` | 같은 함수의 `ts_parser_reset` | 별도 구간 |
| `sticky_edit` | `sticky_summary.edit` | 별도 구간 |
| `tree_edit` | `ts_tree_edit` | 별도 구간 |
| `note_changed` | `Provider.noteChanged` 전체 | `changed_ranges`를 포함 |
| `changed_ranges` | `ts_tree_get_changed_ranges` | `note_changed` 안의 C 호출 |
| `tree_release` | 완료 파싱의 이전 트리 해제 조건문 | 별도 구간 |
| `native_parse` | 기존 프레임 관측의 `ts_parser_parse_with_options` | `on_edit` 안의 C 파싱 |

각 단계의 계수는 계측 구간의 실행 횟수다. `tree_release` 계수는 조건문 구간을 센 것이며 조건문 안의 C free 호출 횟수로 해석하지 않는다. native 파싱과 C 변경 범위 계산은 실제 C 호출 자리에서 별도로 센다.

시계는 기존 외부 계측과 같은 awake 경과시간이다. 프로파일링 zone을 제품에 중복 도입하거나
일반 릴리스에 타이머 비용을 남기지 않는다. 마커 이름은 정적 문자열이며 원문을 출력하지 않는다.

## 집계와 검증

- `summarize.py`는 고정 파일 5개·성능 실행 3회씩·일반/공유 입력 20개씩을 기본 모집단으로 요구한다.
  별도 매 입력 전수 대조 1회씩도 함께 있어야 한다. 성능 집계에 정확성 표본을 합치지 않는다.
- 파일·로그·입력 키의 누락·추가·중복·순서를 거절한다. 기존 FRAME/STORAGE와 EW2의 원문·줄·입력 수·
  전수 대조 여부·mismatch·샘플 시간을 대조한다. 성공 test 개수도 확인한다.
- 모든 입력에서 일반은 뷰 하나, 공유는 둘의 Provider/각 관측 단계/native 호출 수를 요구한다.
  상위보다 긴 하위 시간, 겹치지 않는 하위 구간 합이 상위를 넘는 기록은 거절한다.
- 원본·계측 소스 8개, 실행 바이너리, 원문과 스키마·대상 종류를 검사한다. JSON 중복 필드도 거절한다.
  큰 실행 파일의 해시는 정해진 크기의 청크로 계산한다.
- `verify.py`는 원본 자료를 읽기 전용으로 빌린 임시 사본에서 모집단·시간/호출 수·정확성·증거·CLI의
  다섯 실패 가설을 공격한다. 파일 손상 때는 링크를 끊은 사본만 쓰고 각 가설 전후와 원본을 다시 대조한다.

## 실행

```sh
python3 tools/editor-provider-measure/run.py --output <새 외부 경로> --deps "$PWD/zig-pkg" --repetitions 0
python3 tools/editor-provider-measure/run.py --output <같은 외부 경로> --deps "$PWD/zig-pkg" --resume --run-only --repetitions 3
python3 tools/editor-provider-measure/run.py --output <같은 외부 경로> --deps "$PWD/zig-pkg" --resume --run-only --repetitions 1 --verify-each-edit 1 --prefix verify
python3 tools/editor-provider-measure/summarize.py <같은 외부 경로>
python3 tools/editor-provider-measure/verify.py <같은 외부 경로> --receipt <외부 검증 기록.json>
```

도구의 실행 옵션은 표준 표본을 만드는 명령이다. 단일 workload를 진단용으로 실행할 수 있지만
위 집계는 두 workload와 정확성 로그 모두를 요구한다. 빠진 표본을 완전한 결과로 집계하지 않는다.

## 결과와 다음 판단

[전체 결과](../../tools/editor-provider-measure/results.md)와
`/Users/yoonhb/.cache/maru-agent-artifacts/provider-edit-attribution-final/`에 근거를 보존했다.
3.13 MB Zig 공유 입력의 p50은 전체 72.250ms·Provider 40.662ms·C 파싱 27.886ms·C 범위 계산 12.660ms다.
각 입력에서 C 호출은 두 번이었다. 값은 중첩되며 개별 중앙값을 합하지 않는다.

다음 설계는 파싱과 구조 범위 계산이 뷰별로 반복되는 경계를 먼저 살펴본다.
`shared_edit.Publication.finish`는 뷰를 순서대로 갱신하고 `restore_source` 경로는 호출 뷰의 갱신을
뒤로 미룬다. 한 진단의 두 뷰 호출 수만 보고 모든 편집에서 원본이 항상 먼저 처리된다고 가정하지 않는다.
준비된 트리 재사용과 문서/뷰 소유권, 실제 편집 순서·세대·완료/실패·다른 언어·IME·다중 편집을
별도로 설계·대조한 뒤에만 제품 변경을 판단한다. 구문 상태 통합이나 worker 이동을 이 측정으로 승인하지 않는다.

이 실험은 전후 개선량·GUI/HID·CPU 시간·RSS·모든 언어/입력의 최악 지연을 입증하지 않는다.
외부 부하는 통제하지 않았고, 다른 실험과 연속 개선 수치로 더하지 않는다.

## main 합류

PR #4575는 모든 필수 CI를 통과해 `1e0ec896dbdc6fa2a2f768d8d30f6065f0631b99`로 머지됐다. 머지 트리는 head `cd9e60281b60d45aafa5dd1b0b126b5481c3ee2d`와 동일하다.
