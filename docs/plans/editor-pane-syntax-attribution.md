# pane 구문 준비와 본문 색의 내부 비용 귀속

상태: #4582가 필수 PR CI 통과 후 2026-10-25 `b06e9eb3a`로 머지됐다.
정식 성능 30회/600편집·별도 정확성 10회/200편집·다섯 실패 가설의 43개 손상 거절과
전체 로컬 경계·문서/config 게이트를 완료했다. 실제 main의 문서 링크·줄 참조·config
재검사도 통과했다. 합류 사이 주소창 검사 PR이 더해졌지만 제품 `src/`와 `build.zig`는
PR head와 모두 같다. 최신 main CI 40158024787도 전체 통과했다.

[pane 변환 비용](editor-pane-lowering-attribution.md)의 관측 뒤 남은 경계를 더 나눈다.
제품 함수의 캐시·worker·조회 범위·색·접힘·괄호 정책은 변경하지 않는다.
초기 저장소 밖 단발성 사본 진단은 가설을 좁히는 데만 쓰며 정식 분포와 합치지 않는다.

## 계측 계약

`tools/editor-pane-syntax-measure/run.py`가 기존 사본 준비를 이어서 사용한다.
FRAME/PROVIDER/PANE와 LOWERING schema 2는 유지하고, 별도 INNER schema 1을 추가한다.
형식·target·구간 순서·범위를 고정하고, 과거 다른 계측 자료를 새 형식으로 바꾸어 읽지 않는다.

| 부모 범위 | 내부 구간 | 의미 |
|---|---|---|
| pane의 `advanceSyntax` | `resumeParse`, `advanceBrackets`, `promoteFolds` | 재개 호출·괄호 갱신·접힘 승격의 서로 겹치지 않는 호출 범위 |
| pane의 `syntaxColors` | `lineColorsInto` | 본문 줄 색 파사드의 포함 시간 |
| 본문의 `lineColorsInto` | `captureQuery`, `captureRoles`, `semanticLayer`, `bracketLayer`, `lineBounds`, `neutralColor` | 캡처 조회·역할 변환·레이어 조건/병합·줄 경계·중립 줄 색 변환 |

구간 이름과 순서는 생성기의 `STAGES`가 소유한다. 본문·준비 플래그는 pane 안에서만 켜고
`defer`로 복원한다. 편집 중 같은 함수, 미니맵·고정 머리줄의 색 호출은 이 내부 구간에 섞지 않는다.
입력마다 플래그가 꺼져 있는지를 ReleaseFast에서도 동작하는 `testing.expect`로 검사한다.
일반은 한 뷰, 공유는 두 뷰의 구간 호출 수를 요구한다.

`semanticLayer`·`bracketLayer`는 빈 조건 검사까지 포함한 범위다. 실제 함수가 빈 재료에도
실행됐다고 해석하지 않는다. 별도 `semanticWork`·`bracketWork`가 비어 있지 않은 조건을 센다.
기존 고정 fixture의 LSP 비활성·준비된 괄호 색 계약에 맞춰 각각 0과 뷰 수를 요구한다.
각 재개 호출도 빠른 반환을 포함한다. 반올림한 0.000ms는 호출이 없다는 뜻이 아니다.

중립 `src/chrome/components/editor_view/syntax_colors.zig`까지 준비 시점의 원본/계측 소스
목록에 포함한다. 생성기 사본 `inner-generator.py`와 SHA-256도 빌드 전에 저장한다.
요약기는 소스·실행 파일·생성기 해시를 검증한다. 과거 진단에 사후 확인한 해시를
정식 실행 전 영수증으로 바꾸어 설명하지 않는다.

## 실행·검증과 한계

고정 5파일 × 일반/공유 × 성능 3반복과 별도 정확성 1반복을 사용한다.
각 실행의 20편집과 실제 subprocess 종료/순서를 유지한다. 전체 sticky 기준 대조는
측정 종료 후 수행하며 기존 제품 줄·접힘·괄호 대조도 유지한다.

요약기는 20개 입력의 누락·중복·순서, 모든 구간 호출 수와 분기 조건, 각 자식과 부모 시간,
형제 구간의 합계를 검사한다. 포함된 `lineColorsInto`와 그 자식들을 다시 합치지 않는다.
출력은 p50/p95/최대이며 함수 시간을 GUI/HID·GPU present·RSS로 확장하지 않는다.

독립 검증은 표본/순서, 호출 범위/분기, 중첩 시간/합계, 형식/생성 모델,
제품 기준/소스/실행 근거의 다섯 실패 가설을 공격하고 각 묶음 전후 정상 자료를 대조한다.
기존 원시 자료 덮어쓰기와 다른 실행 모델을 CLI로 우회하는 경우도 거절한다.
백그라운드 부하는 완전히 통제하지 못하며 새 캐시나 알고리즘 변경의 승인은 아니다.

[실측과 재현 명령](../../tools/editor-pane-syntax-measure/results.md)을 따른다.
