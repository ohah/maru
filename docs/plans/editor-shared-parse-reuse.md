# 같은 입력의 완료된 파싱 결과 재사용

상태: 중립 신원/입력 판정·트리 인계 기계·앱 연결의 집중 대조 완료. 전후 제품 실측·독립 결함 5개 검출 완료. 3뷰·비관련 문서 128개의 작은 문서 Debug 대조 완료. 전체 에디터·경계·문서 게이트 통과. PR CI 통과 후 #4576으로 main에 합류했다.

## 근거와 경계

[Provider 비용 귀속](editor-provider-edit-attribution.md)에서 일반 입력은 C 파싱 한 번,
공유 두 뷰는 두 번이었다. 큰 Zig 공유 입력 p50의 Provider 40.662ms 중 C 파싱은 27.886ms였다.
다른 실행/구간의 중앙값을 더하거나 이 값으로 개선량을 미리 주장하지 않는다.

이 후보는 parser·Provider·괄호/접힘/색 작업 칸의 뷰별 소유를 유지한다.
이미 같은 입력을 완료한 뷰가 있으면 현재 트리를 COW 복사해 쓰는 방식이다.
문서 단위의 mutable Provider나 전역 캐시를 새로 만들지 않는다.
다른 뷰가 계산한 구조 변경 범위를 복사하지 않고 자기 이전 트리를 편집한 뒤 새 트리와 비교한다.
따라서 초기 트리/파싱 이력이 다른 뷰도 자기 세대·접힘 캐시·괄호 통지를 유지한다.

## 완료한 기계

- `document_registry.Registry.identity`는 살아 있는 lease에서만 기존 `DocumentIdentity`를 만든다.
  owner·slot·generation을 사용하며 서로 다른 참조의 id/kind는 문서 신원에 넣지 않는다.
- L2 `syntax_stamp.Stamp`는 문서 신원·본문 revision·parser 신원·tree generation을 모두 요구한다.
  값은 포인터를 역참조하거나 수명을 늘리지 않으며 workspace/백업에 저장하지 않는다.
- `Provider.onEditFromParsed`는 같은 parser/자기 자신/같은 tree 래퍼/다른 grammar/트리 부재를 거절한다.
  새 트리 복제를 먼저 준비하고 실패하면 기존 파싱을 선택할 수 있게 원본을 보존한다.
  대상 parser를 reset한 뒤 대상의 이전 트리에 편집을 적용하고 자신의 `noteChanged`를 계산한다.
  전체 재설정은 기존 세대 전진·전체 변경 무효화 의미를 보존한다.
- `stats.reused_parses`는 인계 수를 포화 계수로 기록한다. 실제 C 파싱 횟수와 구분한다.

## 집중 대조

`test-editor-syntax-stamp`는 실제 두 개와 import 28개, 총 30개다.
문서 owner/slot/generation·revision·parser·tree generation의 불일치를 각각 거절한다.
문서 lease 해제·read pin 생존·슬롯 재사용·다른 registry도 확인했다.

`test-editor-shared-parse-core`는 실제 다섯 개와 import 하나, 총 여섯 개다.
Zig·Python·Swift·JavaScript·Dart에서 유효한 UTF-8 삽입/삭제/교체 500개를 실행해
기존 parser의 독립 증분 파싱과 노드 속성·좌표/필드·구문 색·심볼·접힘·괄호를 대조했다.
다른 grammar·자기 자신·동일 parser/tree·트리 부재의 거절은 대상 자원을 보존했다.
전체 재설정 뒤 원본을 해제하고 대상 parser로 다시 편집하는 경로도 대조했다.
기존 host의 old_end_point 근사를 쓴 선행 개행 삭제와 다른 파싱 이력을 섞은 고정 사례도
다섯 언어에서 대조했다. 모든 가능한 근사 좌표·파싱 이력의 전수 증명은 아니다.
늦은 대상 트리에 없는 새 함수가 실제 편집 범위 밖에 있을 때 자기 변경 범위로 접힘을 복구하는 사례도 대조했다. 제공 뷰의 변경 범위는 비어 있고 두 provider의 이전 세대도 다르게 만들었다.
기존 `test-editor-native-snapshot` 세 개도 통과했다.

```sh
mise exec -- zig build test-editor-syntax-stamp test-editor-shared-parse-core test-editor-native-snapshot -j2
```

`test-editor-shared-parse-product`는 실제 세 개와 import 네 개, 총 일곱 개다.
양쪽 입력·Undo/Redo에서 인계가 한 번씩 발생하고 색·심볼·접힘·표식이 독립 결과와 같았다.
같은 revision 재갱신은 native 세대를 다시 밀지 않고, 원본 닫기 뒤에는 남은 뷰가 자체 파싱한다.
문서/리비전/parser/세대가 다른 증명과 직접 재파싱 뒤 옛 증명을 거절했다.
다른 문서의 State에 현재 문서의 증명을 강제로 넣어도 실제 live lease에서 거절한다.
실제 C 호출 수와 함수 처리 시간은 [전후 측정](../../tools/editor-shared-parse/results.md)에 기록한다. 물리 입력·화면 표시 지연의 측정은 아니다.

## 현재 앱 연결

`State.input_stamp`는 완료한 입력·parser/tree 판만 기록한다. 직접 편집/재파싱과 pending 재개는
이전 증명을 버린다. 새 State와 초기 공유 스냅샷은 증명 없이 시작한다.
`updateForInput`은 입력이 이미 맞으면 구문 중복 갱신을 건너뛰고, 그렇지 않으면 같은 입력을
증명한 다른 State의 트리를 선택한다. 실제 새 트리 판이 생긴 뒤에만 완료 증명을 기록한다.

`refreshSyntaxForInput`은 기존 뷰 갱신 안에서만 실행한다. 문서 통지·Publication 순서를 바꾸지 않는다.
단일 뷰는 탐색하지 않는다. 다른 Term의 현재 live lease가 같은 문서인지 중립 판정으로 확인한 뒤
State 증명도 확인한다. 선택·스크롤·LSP/semantic/inlay와 뷰별 파생 갱신은 기존 경로에 남긴다.

기존 프레임 계측은 새 provider 갱신 경계 전체를 관측한다. Provider 비용 도구의 schema 1은
기존 native 1/2회 자료로 보존하고, schema 2는 실행 모델과 성공한 인계 횟수를 함께 기록한다.
`revision-snapshots`는 일반/공유 모두 native 한 번, 공유 인계 한 번을 요구한다.
신원 판정을 포함한 원본/계측 파일은 새 모델에서 열한 개, 이전 모델의 새 기록은 열 개다.
이전 schema 1의 여덟 파일 자료도 계속 검증한다.

## 남은 검증

1. 같은 리비전 통지와 호출 뷰의 후속 refresh는 순서가 다를 수 있다.
   `shared_edit.Publication.finish`의 restore_source 경로도 현재 순서를 유지한다.
2. 구문 State의 입력 증명은 실제 완료한 갱신 뒤에만 기록한다. 직접 재파싱·pending 재개·
   grammar 교체·State 초기화는 오래된 증명을 남기지 않아야 한다. 새 뷰는 증명 없이 시작해도 된다.
3. 같은 문서의 다른 뷰가 현재 revision·grammar·Provider 판을 증명할 때만 완료 트리를 빌린다.
   단일 뷰는 검색하지 않고, 증명 부재·pending·언어 불일치·복제 실패는 기존 파싱으로 돌아간다.
4. 자기 뷰가 이미 현재 판을 완료했다면 구문 편집을 반복하지 않는다. 표시/선택/스크롤·LSP·
   semantic/inlay 등의 기존 독립 뷰 갱신은 계속 수행한다.
5. 편집/Undo/Redo·멀티커서·IME·전체 교체·Save As·숨은 뷰·마지막 닫기·OOM과 stale 신원을
   실제 앱 coordinator로 대조하고 독립 결함을 검출한다.
6. 파싱 호출 수는 일반 입력 하나·준비된 공유 입력 하나, 뷰별 변경 범위 비교는 각각 유지되는지
   관측한다. 기존 비용 귀속 도구의 이전 1/2회 계약도 명시적으로 버전 구분해 보존한다.
7. 실제 선행 제품과의 전후 비교는 시작/첫 입력/전체 표본을 보존하고, 다른 문서/뷰 수와
   많은 비관련 Term을 검색하는 비용·fallback도 측정한다. 결과를 본 뒤 제품 적용을 판단한다.

## 독립 결함 검출

`tools/editor-shared-parse/review.py`는 재사용 비활성화·live 문서 신원 우회·provider 세대 무시·grammar 경계 제거·제공 뷰의 변경 범위 복사를 각각 주입한다. 다섯 결함 모두 컴파일 성공 뒤 실행 단언에서 검출했고, 앞뒤 원본 대조군은 통과했다. 현재 세 제품 소스의 해시는 해당 결과의 원본 해시와 일치한다.
계측 자료 검증은 schema/실행 모델과 인계 횟수의 변조도 거절한다.

## 전체 로컬 게이트

`test-editor`는 중립 모델 793개·UI 컴포넌트 1,211개를 통과했고, 제품 묶음 1,588개 중 1,585개 통과·3개 의도한 건너뛰기·실패 0개였다. 집중/공유 스냅샷/공유 뷰/공유 분할과 전체 `check-boundaries`도 통과했다. 최신 선행 PR head `cd9e60281`와 실제 main `1e0ec896d` 위 재정리 전후 제품 코드는 동일하며 문서 세 개만 최신 상태로 합쳤다. 재정리 뒤 문서 링크·라인·config 게이트와 기존 독립 결함 원본 해시를 재확인했다.

## main 합류

PR #4576은 모든 필수 CI를 통과해 `f795a8497293d7b0f7b71e8d489951654311df4d`로 머지됐다. 머지 트리는 head `a6fb5707b66242b42250ea54b279e267d2b3dd38`와 동일하다. 초기 실패의 프로젝트 검색 개수 가드는 실제 289개 선택·288개 통과·Windows 전용 1개 건너뛰기와 일치시켰다. 실제 GUI/HID와 C allocator 전체 실패 검증의 한계는 그대로다.
