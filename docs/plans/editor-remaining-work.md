# 에디터 전체 잔여 작업 점검

2026-09-30 main `8dfe0127dd51e7c3426fda824f2d9c2e2fe7a549` 기준 코드·계약·계획 대조다.
PR #4021은 이 main에 포함돼 있다. 이 문서는 기존 계약을 바꾸지 않고 현재 상태와 다음 작업 후보를 모은다.
구현 순서는 제안이며, 새 구조·UX 결정이나 구현 착수 승인을 뜻하지 않는다.

## 범위와 판정 방법

[네이티브 편집기 계획](native-editor.md), [에디터 Surface 계획](editor-surface.md),
[여러 뷰 원장](native-editor-multi-view.md), [이름 없는 문서 계획](editor-untitled.md),
[도구·LSP 계약](../editor-surface-tooling.md), [병합 계약](../editor-merge-conflicts.md),
[검증 매트릭스](../verification-matrix.md)를 현재 제품 코드와 비교했다.
SCM·원격 감시·앱 전체 접근성은 연결되는 경계만 다룬다. 그 프로젝트 전체의 완료 판정은 하지 않는다.

- **구현·제품 연결 있음**: 순수 helper뿐 아니라 요청/명령/렌더/저장 등의 소비 경로가 있다.
  모든 종료 gate나 모든 OS에서 검증됐다는 뜻은 아니다.
- **남은 기능**: 계획에 있으나 그 사용자 기능을 제공하는 현재 경로가 없다.
- **구조·정책 미결**: 기존 부분 구현만으로 계약을 충족하지 못하며 착수 전에 결정이 필요하다.
- **검증·범위 한계**: 구현이 있어도 특정 실패 조건·호스트·수명은 별도 확인해야 한다.
- **문서 낙후**: 구현된 기능이 미구현처럼 적혀 있다. 신규 개발로 다시 세지 않는다.

이 원장은 확인한 기능과 주요 잔여의 목록이며, 에디터 모든 종료 조건의 전수 완료 판정은 아니다.
이번 점검은 소스 대조다. 새 GUI/IME 실측이나 전체 런타임 테스트는 실행하지 않았다.
과거 제품 화면 증거는 매트릭스의 날짜·범위로만 읽고, 이번 시점의 새 실행 결과로 주장하지 않는다.

## 이미 있는 기능 — 재구현 대상에서 제외

| 범위 | 현재 구현 근거 | 완료 주장에 붙는 경계 |
|---|---|---|
| 읽기·편집·선택·멀티커서·Undo/Redo·클립보드·저장 | [editor/mod.zig](../../src/platform/macos/app_session/editor/mod.zig), [buffer](../../src/session/editor/buffer.zig), [delta](../../src/session/editor/delta.zig), [clipboard](../../src/session/editor/clipboard.zig) | 공유 문서/다중 뷰 완료를 뜻하지 않는다 |
| 이름 없는 문서·백업/복원·저장 실패/충돌 선택 | [editor-untitled 계획](editor-untitled.md), [저장](../../src/platform/macos/app_session/editor/untitled_save.zig), [백업](../../src/platform/macos/app_session/editor/backup.zig), [충돌 선택](../../src/platform/macos/app_session/editor/conflict.zig) | 외부 변경의 상시 감시·자동 clean reload 전체를 대신하지 않는다 |
| IME 문서 범위·모든 커서 조합 표시/확정 | 네이티브 계획 N3와 검증 매트릭스의 IME 행, `editor/mod.zig` | 실제 입력기 증거와 헤드리스 callback 증거를 구분한다 |
| 일반/PCRE2 찾기·바꾸기·검색 옵션 | [find host](../../src/platform/macos/app_session/find.zig), [editor find](../../src/session/editor/find.zig), [find UI](../../src/chrome/components/find.zig) | 프로젝트 전체 검색과 좌우 독립 찾기 상자는 별개다 |
| 구문 색·괄호·접힘·안내선·공백 표시·sticky·미니맵 | 네이티브 계획 N1/N4/N5, [frame](../../src/chrome/components/editor_view/frame.zig) | B2 draw 저장소 결정과 모든 부족 조건의 표시 보장은 남았다 |
| LSP 호버·시그니처·정의·포맷·이름 바꾸기·자동완성·code action | [도구 계약 §8.2b~h](../editor-surface-tooling.md), 대응 `editor_*` host 모듈, [LSP 응답 라우터](../../src/platform/macos/app_session/editor/lsp.zig) | 기능이 있다는 것과 E3 도구 실행 계약 전체 완료는 다르다 |
| semantic tokens·접힘·didSave·참조/구현/타입 정의/선언·inlay·심볼·낱말 강조·선택 확장 | 도구 계약 §8.2i~q와 대응 host 모듈 | 참조 피커와 문서 심볼 목록은 영구 도크 아웃라인이 아니다 |
| 비교 본문 선택·복사·랩된 이어진 조각의 글자 강조 | [diff host](../../src/platform/macos/app_session/editor/diff.zig)의 DSEL2·DSEL4·DSEL5, `frame`의 바뀐 글자 painter와 이어진 조각 회귀 판정자 | 좌우 wrap 높이 정렬 제한과는 다른 기능이다 |
| 3-way 병합 기본 기능 | [병합 계약 S1~S6](../editor-merge-conflicts.md), [merge host](../../src/platform/macos/app_session/editor/merge.zig) | 고르기 토글/스마트 결합 상태 모델은 별도 보류다 |

호버·시그니처는 `lsp.zig`의 응답 처리와 `app_session.zig`의 명령·tick·박스 렌더에 연결된다.
참조는 `references.zig`의 요청·응답·피커 선택과 LSP 라우터가 연결된다.
진단 overview도 `frame.Props.diag_lines`가 막대와 미니맵으로 전달되므로 신규 기능으로 다시 세지 않는다.

## 실제 남은 기능과 미결

| 항목 | 분류 | 현재 코드/계약 근거 | 다음 완료 조건 |
|---|---|---|---|
| 같은 파일 두 pane에서 공유 편집 | 승인된 설계의 단일 뷰 이관 + 공유 배선 미착수 | [layering §2.4](../native-editor-layering.md), 여러 뷰 원장 H1~H9. `app_session.zig`의 `TermRuntime.editor_document`가 본문·저장 정보·이력을 묶고 선택은 뷰에 남는다. [단일 뷰 이관](editor-shared-document.md)을 진행 중이다. 제품 소스에서 공유 `DocumentRegistry`와 명시적 editor split 명령을 찾지 못했다 | 승인된 [공유 문서 설계](editor-shared-document.md)에 따라 안정 핸들·연결 수명·provider/뷰 갱신을 구현하고, 한쪽 편집/Undo/외부 변경이 다른 뷰에 반영되며 선택·스크롤은 독립 |
| 비교 뷰 좌우 독립 찾기 상자 | 구현·검증 완료 | [독립 찾기 계획](editor-diff-find.md). 두 `find.State`와 열별 결과를 유지한다 | 헤드리스·제품 Metal·실제 AppKit/IME 검증 결과는 해당 계획에 기록 |
| 프로젝트 전체 검색·바꾸기 미리보기 | 남은 기능 + 정책 미결 | 네이티브 후속 표. 파일 안 검색은 있지만 프로젝트 검색 도크·진행/취소·적용 미리보기 경로는 확인되지 않았다 | 검색 범위·제외/무시 규칙·엔진/프로세스·결과 도크·취소·바꾸기 안전 규칙을 결정하고 실제 여러 파일 검증 |
| 영구 도크 심볼 아웃라인 | 남은 기능 | 후속 표의 목록 UI. `symbols.zig`는 문서 심볼을 공급하고 현재 소비자는 breadcrumb·symbol picker 등이다. 도크 아웃라인 경로는 확인되지 않았다 | 기존 심볼 목록을 재사용하는 도크 배치·선택/추종·문서 전환 계약 |
| 심볼 선택 중 문서 미리보기 | 남은 기능, 선행 대기 | 네이티브 UI §7.5와 후속 표. 현재 심볼 이동/피커와 다른 기능 | 공유 문서/뷰 수명 계약을 먼저 닫고, 미리보기 이동과 확정/취소 복원 검증 |
| Markdown 소스 모드의 편집기 선택 | 계약 밖의 정책 미결 | [네이티브 계약 §12](../native-editor.md), [파일 kind 계약](../file-panel-kinds.md). Markdown 소스는 현재 CM6이며 text/diff의 네이티브 이관과 별개다 | 소스도 네이티브로 할지, 웹 모드와의 전환·문서 소유·편집 경험을 어떻게 통일할지 결정 |
| 언어별 들여쓰기·자동 닫기 문맥 규칙 | 별도 개선 후보, 정책 미결 | 네이티브 계약 §12. 기본 `pairs.zig`·`language.zig`는 있지만 VS Code식 `onEnterRules`·문맥 제외·언어별 정규식 규칙까지 완료된 것은 아니다 | 실제 차이 입력부터 재현하고 grammar별 규칙 소유·엔진을 결정. 검색 PCRE2 채택을 타이핑 규칙 채택으로 해석하지 않는다 |
| 편집기 plugin 확장점 | 앱 전체 plugin 경계의 별도 결정 | 네이티브 계약 §12: 내부 span/completion provider와 외부 plugin API는 다르다 | 신뢰/권한·수명·확장 API 계약을 해당 이니셔티브에서 결정. 내부 provider 존재를 plugin 지원으로 세지 않는다 |
| 저장 시 자동 포맷/린트 fix | 남은 기능 + 보안 정책 미결 | 후속 표와 도구 §8.1. `format.zig`는 명시적 LSP 포맷 요청; `saveDocumentGuarded`의 저장은 자동 실행 기능을 제공하지 않는다 | 자동 실행 신뢰/권한과 실패·취소 정책, revision·커서·undo 한 번·저장 순서 검증 |
| 선택적 외부 formatter/linter 실행 | E3 계약 잔여 | 도구 §8.1의 trust/allowlist/executable·시간/출력/child 정산 규칙은 LSP 포맷만으로 닫히지 않는다 | registry·명시적 trust UX·취소/폭주/실행 종료 fixture를 별도 대조 후 구현 범위 결정 |
| B2 op 저장소 제품 적용 | 실험 있음, 제품 연결·정책 미결 | [B2 기록](editor-op-b2-evaluation.md). `B2Experiment`는 test 전용, 제품 `frame.build`는 기존 scratch 경로 | 소유 범위·창/pane 수명·메모리 정책 결정과 제품 출력/입력/실패/성능 검증 |
| 기본 scratch 부족 시 중요한 표시 보존 | 검증·범위 한계 | #4021은 기본 scratch에 들어간 현재 검색만 성장 실패에서 보호한다 | 부족 종류별 반례부터 재현하고, 실제 결함과 표시 정책을 구분 |
| 비교 뷰 wrap 조각 정렬 | 알려진 제한, 기존 보류 | 네이티브 계획 N1.5의 알려진 구멍과 `editor_diff` 판정자. wrap off/독립 가로 스크롤은 이미 완화책 | 사용자 결정 전 자동으로 재개하지 않는다 |
| Split in Group | 계약 없는 후속 | 여러 뷰 원장 §3~§4. pane 분할 공유 편집과 별도 기능 | pane 기반 공유 뷰 이후 필요성·배치·입력 라우팅 계약 |
| 병합 고르기 상태 모델·스마트 결합 | 기존 보류 | 병합 계약 §7 ⑦: 사용자 결정은 현재 마커 모델 | 실제 필요가 확인되면 별도 승인/계약. 현재 기본 병합 기능의 미완료로 세지 않는다 |
| 번들 언어 확대 | 언어별 후속 | 네이티브 후속 표, third-party 라이선스 규칙 | 언어별 필요성·grammar 크기·라이선스·오라클 검증 |
| 편집기 본문 접근성 | 앱 전체 후속 | 네이티브 후속 표와 chrome interaction 전략 | chrome 접근성 구현을 본문 텍스트/선택/편집의 VoiceOver 완료로 오인하지 말고 별도 계약·제품 검증 |

코드에서 찾지 못했다는 판정은 `src/` 전체 식별자/소비처 검색과 관련 host·UI·명령 카탈로그 대조에 기반한다.
같은 이름의 선언 유무만으로 판단하지 않았다. 외부 감시/자동 reload나 접근성 전체의 완전한 미구현 판정은
이 점검만으로 내리지 않는다. E2/E3의 세부 종료 gate는 다음 절처럼 별도 추적한다.

## 종료 gate 전수 대조와 실제 검증을 구분할 영역

- **E2 종료 gate 전수 대조 미실시**: 저장·충돌·백업 코드가 있어도 동일 파일 owner transfer, 공유 뷰,
  외부 atomic replace·symlink/hard-link·mode/ownership/xattr·실제 crash 복원 전체를 닫았다고 주장하지 않는다.
  현재 구현·판정자·제품 artifact를 항목별로 매핑해야 한다.
- **E3/E4 종료 gate 전수 대조 미실시**: 외부 도구 정책과 LSP transport·동기화·stale/restart/cancel/backpressure/revoke는
  개별 기능의 존재와 독립된 종료 조건이다. 도구 계약 §8.2의 기존 판정자를 먼저 재사용한다.
- **편집기 뷰 상태의 앱 재시작 복원**: 네이티브 후속의 연결 문서 표는 커서·스크롤·접힘 복원 범위를
  workspace restore 소유로 둔다. 탭/파일 재열기·미저장 내용 복원을 뷰 상태 복원 전체의 완료로 세지 않는다.
  `app_session/tab.zig`의 persisted snapshot과 복원 소비처를 상태별로 대조해야 하며, 이번에는 완료/미구현을 확정하지 않았다.
- **호스트/IME**: 실제 입력기·후보창 증거는 검증 매트릭스 범위다. 이번 문서 점검으로 새 GUI 통과를 추가하지 않는다.
- **ReleaseFast**: CI의 `editor macOS (ReleaseFast)`는 main용이며 PR에서 skipped될 수 있다.
  PR의 skip을 검증 공백으로 단정하거나, Debug 통과를 ReleaseFast 통과로 바꾸어 쓰지 않는다.
- **옛 WebKit E0.5**: CM6 MergeView 당시 feasibility 기록이다. 네이티브 N3 제품 검증과
  웹 입력기 검증은 서로 대체하지 않는다. 옛 수동 IME gate를 새 네이티브 미구현 기능으로 세지 않는다.

**잔여에 넣지 않는 범위**: flow 레이아웃·웹 읽기/리치 이관은 네이티브 계약 밖이다.
CJK 금칙·UTF-8 외 인코딩·virtual space·modal editing은 계획의 제외 항목이며 자동으로 신규 TODO로 올리지 않는다.
Markdown 소스 모드 선택은 웹 읽기/리치 이관과 별도의 미결이다.

## 다음 순서 제안

1. 이번 문서 정합성부터 닫는다. 완료 기능을 재구현 목록에서 걷어내고 확인되지 않은 종료 gate를 구분한다.
2. **비교 뷰 좌우 독립 찾기는 구현·검증 완료**이다. 사용자 승인한 VS Code 활성 열 정책을 따른다.
   종료 gate와 증거는 [독립 찾기 계획](editor-diff-find.md)에 기록한다.
3. **공유 문서·같은 파일 두 pane**는 [설계 제안과 단계](editor-shared-document.md)를 정리했다. VS Code 기준 UX는 [레이어 배치 §2.4a](../native-editor-layering.md)에 승인된 목표로 반영했다. 구현 수명/실패 gate는 단계별로 닫는다. 이미 있던 N2 요구이고
   심볼 미리보기의 선행이지만, `TermRuntime` 소유를 옮기므로 단순 배선 수정처럼 시작하지 않는다.
4. 프로젝트 검색과 도크 아웃라인은 새 도크 UX로 각각 연다. 외부 도구 자동 실행은 신뢰 정책 뒤에 둔다.
5. 버퍼 부족은 재현된 반례에 한해 개선한다. B2의 제품 적용·상한 수치·큰 구조 변경을
   다른 기능의 완료 조건으로 묶거나 자동으로 앞당기지 않는다.

이 순서는 기능 제한의 명확성·기존 계약/구현 재사용·구조 변경 비용에 따른 제안이다.
사용자가 재현이 불명확한 작업을 원하지 않는다는 조건을 유지한다.
