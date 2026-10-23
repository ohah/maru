# 에디터 전체 잔여 작업 점검

2026-09-30 main `8dfe0127dd51e7c3426fda824f2d9c2e2fe7a549` 기준 코드·계약·계획 대조다.
PR #4021은 이 main에 포함돼 있다. 이 문서는 기존 계약을 바꾸지 않고 현재 상태와 다음 작업 후보를 모은다.
구현 순서는 제안이며, 새 구조·UX 결정이나 구현 착수 승인을 뜻하지 않는다.

2026-10-04 후속: ID 백업·워크스페이스 문서/뷰 복원은 [공유 복원 계획](editor-shared-restore.md),
checkpoint 참조 없이 남은 사본의 수동 복구는 [백업 발견 계획](editor-backup-discovery.md)에
현재 구현과 검증 범위를 기록한다. 로컬 파일의 메뉴·팔레트·단축키 공유 분할은
[공유 분할 명령](editor-shared-split.md)에 구현·검증됐다. 아래 표의 공유 편집·뷰 복원과
심볼 미리보기 항목만 이를 반영했다. 9월 30일 점검 전체를 새로 실행했다는 뜻은 아니다.

## 범위와 판정 방법

2026-10-17 후속 대조에서는 프로젝트 검색·바꾸기의 제품 연결을 다시 확인했다.
`search/owner.zig`가 열린 모델을 캡처하고 번들 helper 백엔드를 시작하며,
`search/batch/ui.zig`가 전체 미리보기·적용·파일별 저장 재시도를 연결한다.
아래 검색 행과 다음 순서만 이를 반영한다. 이 갱신으로 다른 행의 과거 점검 날짜나
물리 IME·파일시스템·종료 검증 범위를 새로 확인한 것으로 바꾸지 않는다.

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
| semantic tokens·접힘·didSave·참조/구현/타입 정의/선언·inlay·심볼·낱말 강조·선택 확장 | 도구 계약 §8.2i~q와 대응 host 모듈 | 도크 아웃라인은 아래 별도 항목에서 범위를 구분한다 |
| 비교 본문 선택·복사·랩된 이어진 조각의 글자 강조 | [diff host](../../src/platform/macos/app_session/editor/diff.zig)의 DSEL2·DSEL4·DSEL5, `frame`의 바뀐 글자 painter와 이어진 조각 회귀 판정자 | 좌우 wrap 높이 정렬 제한과는 다른 기능이다 |
| 3-way 병합 기본 기능 | [병합 계약 S1~S6](../editor-merge-conflicts.md), [merge host](../../src/platform/macos/app_session/editor/merge.zig) | 고르기 토글/스마트 결합 상태 모델은 별도 보류다 |

호버·시그니처는 `lsp.zig`의 응답 처리와 `app_session.zig`의 명령·tick·박스 렌더에 연결된다.
참조는 `references.zig`의 요청·응답·피커 선택과 LSP 라우터가 연결된다.
진단 overview도 `frame.Props.diag_lines`가 막대와 미니맵으로 전달되므로 신규 기능으로 다시 세지 않는다.

## 실제 남은 기능과 미결

| 항목 | 분류 | 현재 코드/계약 근거 | 다음 완료 조건 |
|---|---|---|---|
| 같은 파일 두 pane에서 공유 편집 | 일반 로컬 파일의 같은 창 공유 분할 구현·검증 | [공유 분할 명령](editor-shared-split.md), [공유 문서 계획](editor-shared-document.md), [복원 제품 연결](editor-recovery-integration.md). 편집·Undo·뷰별 검색·선택·스크롤·접힘과 재시작 및 실제 한국어 HID의 검사 범위를 각각 기록한다 | 이름 없는/원격/비교/병합 문서의 공유 분할·창 간 동시 공유·경로 alias 통합은 이 완료 범위 밖이다. 외부 변경의 모든 종료 gate를 닫았다는 뜻도 아니다 |
| 비교 뷰 좌우 독립 찾기 상자 | 구현·검증 완료 | [독립 찾기 계획](editor-diff-find.md). 두 `find.State`와 열별 결과를 유지한다 | 헤드리스·제품 Metal·실제 AppKit/IME 검증 결과는 해당 계획에 기록 |
| 프로젝트 전체 검색·바꾸기 | 제품 연결 구현 | [검색 worker](editor-project-search-worker.md)·[앱 owner](editor-project-search-owner.md)·[도크](editor-project-search-dock.md)·[결과 탭](editor-project-search-pane.md)을 연결했다. 번들 rg의 디스크 검색과 열린 모델 우선 검색, [바꾸기 미리보기](editor-project-replace-preview.md), [단일 파일 적용](editor-project-replace-apply.md), [열린 모델·닫힌 파일의 배치 UI와 저장 재시도](editor-project-replace-batch-ui.md)가 있다 | 엔진·인코딩 차이와 전체 OS watcher·지연 I/O 종료·VoiceOver·OS 후보창 픽셀은 각 계획의 검증 경계를 따른다. 제품 연결을 모든 환경 검증 완료로 해석하지 않는다 |
| 영구 도크 심볼 아웃라인 | 구현 | [도크 아웃라인](editor-outline.md). 활성 문서 계층·접힘·현재 커서 강조, 클릭 이동과 문서/뷰/리비전 교체 검사 | diff/merge, 정렬·필터 설정과 접힘의 재시작 보존은 범위 밖 |
| 심볼 선택 중 문서 미리보기 | 구현 | [현재 pane 미리보기](editor-symbol-preview.md). 목록 선택은 임시 표시, Enter는 확정, Esc는 원래 화면 | 도크 아웃라인은 별도 목록으로 구현 |
| Markdown 소스 모드의 편집기 선택 | 계약 밖의 정책 미결 | [네이티브 계약 §12](../native-editor.md), [파일 kind 계약](../file-panel-kinds.md). Markdown 소스는 현재 CM6이며 text/diff의 네이티브 이관과 별개다 | 소스도 네이티브로 할지, 웹 모드와의 전환·문서 소유·편집 경험을 어떻게 통일할지 결정 |
| 언어별 들여쓰기·자동 닫기 문맥 규칙 | 정책 결정(2026-10-13 — 단위는 파일에서 감지, 규칙은 정규식 없이 Zig 표), [계획](editor-typing-rules.md) TR1(들여쓰기 단위)·TR2(괄호 Enter·닫는 괄호 내어쓰기)·TR3(언어 규칙 표 + VS Code 규칙 대조)·TR4(구문 트리 문맥) 완료, 네 조각을 합친 최종 검토(2026-10-14 — 결함 일곱 수정) | 네이티브 계약 §12·문서 모델 §3.7·§3.9a. 차이 입력은 계획의 재현 표 | 사용자 정의 규칙(plugin 경계 결정 뒤) |
| 편집기 plugin 확장점 | 앱 전체 plugin 경계의 별도 결정 | 네이티브 계약 §12: 내부 span/completion provider와 외부 plugin API는 다르다 | 신뢰/권한·수명·확장 API 계약을 해당 이니셔티브에서 결정. 내부 provider 존재를 plugin 지원으로 세지 않는다 |
| 저장 시 자동 포맷/린트 fix | 언어 서버의 포맷·code action 은 구현(2026-10-11) · 외부 포매터 구현(2026-10-12 — Prettier·Biome·oxfmt·ruff·black·rustfmt·zig fmt·사용자 명령) · 린트 fix 는 남은 기능 | 언어 서버의 저장 시 포맷은 [계획](editor-format-on-save.md)·도구 §8.2r(`⌘S` 가 응답 뒤에 저장, 기본 켬, 1 초 시한; 신뢰는 서버가 뜨는 조건). 저장 시 code action(`source.organizeImports`·서버의 `source.fixAll` 등)은 [계획](editor-code-actions-on-save.md)·도구 §8.2s(설정 `editor.code-actions-on-save`, 기본 끔, 포맷보다 먼저). 외부 포매터는 [계획](editor-external-formatter.md)·도구 §8.2t(저장소 설정 감지·저장소 실행 파일·신뢰한 저장소에서만). 린트 fix(ESLint·ruff)는 보조 언어 서버(한 문서에 서버 여럿 — [계획](editor-auxiliary-servers.md)·도구 §8.2u)가 맡는다 — AS1(구조·ruff 진단)·AS2(`⌘.` 메뉴·저장 시 fix)·AS3(ESLint — pull 진단·설정 답)·AS4(Biome·oxlint)·AS5(Biome 의 JSON·CSS) | 다른 린터는 요청이 있을 때 같은 표에 |
| 선택적 외부 formatter/linter 실행 | 포매터 실행 경로 구현(EF1·EF2), 린터는 보조 언어 서버로 — ruff·ESLint·Biome·oxlint 진단과 fix(AS1~AS5) | 도구 §8.2t: 신뢰한 저장소에서만·셸 없이 argv·cwd=root·도구 환경·시한 3 초·stdout/stderr 상한·프로세스 그룹째 끝냄·실행 파일과 감지한 설정을 「Editor: Show Formatter Info」로 보인다([계획](editor-external-formatter.md)) | 다른 린터는 요청이 있을 때([계획](editor-auxiliary-servers.md)) |
| B2 op 저장소 제품 적용 | 실험 있음, 제품 연결·정책 미결 | [B2 기록](editor-op-b2-evaluation.md). `B2Experiment`는 test 전용, 제품 `frame.build`는 기존 scratch 경로 | 소유 범위·창/pane 수명·메모리 정책 결정과 제품 출력/입력/실패/성능 검증 |
| 기본 scratch 부족 시 중요한 표시 보존 | 검증·범위 한계 | #4021은 기본 scratch에 들어간 현재 검색만 성장 실패에서 보호한다 | 부족 종류별 반례부터 재현하고, 실제 결함과 표시 정책을 구분 |
| 비교 뷰 wrap 조각 정렬 | 알려진 제한, 기존 보류 | 네이티브 계획 N1.5의 알려진 구멍과 `editor_diff` 판정자. wrap off/독립 가로 스크롤은 이미 완화책 | 사용자 결정 전 자동으로 재개하지 않는다 |
| Split in Group | 계약 없는 후속 | 여러 뷰 원장 §3~§4. pane 분할 공유 편집과 별도 기능 | pane 기반 공유 뷰 이후 필요성·배치·입력 라우팅 계약 |
| 병합 고르기 상태 모델·스마트 결합 | 기존 보류 | 병합 계약 §7 ⑦: 사용자 결정은 현재 마커 모델 | 실제 필요가 확인되면 별도 승인/계약. 현재 기본 병합 기능의 미완료로 세지 않는다 |
| 번들 언어 확대 | 사용자 결정(2026-10-14 — 후보 열둘 전부), [계획](editor-bundled-languages.md) BL1(YAML·TOML·XML·DTD·Lua·Dockerfile·Make)·BLP(쿼리 술어 평가)·BL2(Swift)·BL3(SQL·Dart)·BL4(C#·Objective-C·Scala) 완료 — 후보 열둘 전부 | 네이티브 후속 표, third-party 라이선스 규칙 | — |
| 진단 출처를 언어 서버로만 | 구현(2026-10-15 — 사용자 결정) | tree-sitter 구문 오류(`ERROR`·`MISSING`)를 진단 출처에서 걷었다 — `Provider.syntaxErrors`·호버의 구문 오류 문장·SQL 만 끄던 칸까지([시각 매핑](../native-editor-visual-mapping.md) §5.4 「출처 결정」). Objective-C 에 clangd 를 더했다 | 언어 서버 후보 확대로 이었다(아래 행) |
| 언어 서버 후보 확대 | 구현(LS1 2026-10-20 #4528·LS2 2026-10-21 #4532·LS3 2026-10-21 #4533·LS4 2026-10-21) — 사용자 결정(2026-10-16), [계획](editor-lsp-servers-expand.md) LS1(Swift·Dart·C#·Scala·Java·Kotlin·PHP·Lua·Bash·YAML·TOML·Dockerfile·JSON·CSS·HTML — maru 와 같은 능력으로 실측) | 서버 표(`session/lsp/servers.zig`)·툴링 §8.2a 「서버 찾기」·「설치 안내」. 문서마다 languageId(`.scss`·`.less`)·다루지 않는 확장자(Bash 서버의 `.zsh`). LS2 — 주 서버의 서버별 pull 진단(tsgo·TS 7 `tsc` 는 파일 진단을 pull 로만 낸다 — 실측)·파일 간 의존이면 다른 열린 문서도 다시 묻기. LS3 — 전문 didChange 를 문서 전체를 덮는 range 하나로(툴링 §8.2a 「동기화」). LS4 — Ruby(`ruby-lsp`) 와 그 pull 앞의 장벽(작업 스레드가 didChange 를 적용한 뒤에 묻는다) | 남은 조각 없음. SQL·Markdown·XML·DTD·Make 는 쓸 만한 서버가 없다(계획 「싣지 않는 것」) |
| 하이라이트 쿼리 미리 데우기 | 결정 필요 — 번들 언어 확대가 드러낸 비용 | 쿼리는 그 언어로 처음 칠할 때 메인 스레드에서 한 번 컴파일된다(`tree_sitter.queryFor` — 프로세스 수명 캐시). 실측 Swift 84 ms·Objective-C 78 ms·Dart 46 ms([번들 언어 확대](editor-bundled-languages.md) 「한계」) | 다른 스레드에서 미리 만들지(경쟁하면 진 쪽이 버리는 캐시는 이미 그 모양이다), 언제(앱 시작·파일 열기 직전) 데울지 정하고 첫 프레임 시간을 판정자로 잰다 |
| 편집 한 번의 메인 스레드 비용 | EW0·EW1 구현, EW2~EW3 남음 — 사용자 결정(2026-10-22 — 계측으로 원인부터), [계획](editor-edit-frame-cost.md) | 실측(ReleaseFast): 한 글자 편집 + 프레임이 72 KB 3.5 ms·178 KB 5.5 ms 로 예산 안, 719 KB 19 ms·1.1 MB 28 ms 로 60 fps 예산(16.7 ms)을 넘는다. 이 수치는 EW1 전 기준이다. EW1은 심볼 전체 순회를 조상·변경 범위 조회로 바꿨고, 같은 기준 원문 5회 중앙값은 build.zig 20.82→14.52 ms·Swift 29.69→18.12 ms다. 접힘 전체 순회는 남았다 | EW2(접힘 — 길 결정 필요)·EW3(편집 쪽 다시 재기) |
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
  [복원 제품 연결](editor-recovery-integration.md)과 [공유 분할 명령](editor-shared-split.md)에
  커서·스크롤·접힘·랩의 제품 재시작 검증이 추가됐다. 지원 밖 문서와 기존 복원 검증 한계는 각 계획을 따른다.
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
3. **일반 로컬 파일의 같은 창 공유 문서·분할·재시작은 구현했다.** [공유 분할](editor-shared-split.md)과
   [심볼 미리보기](editor-symbol-preview.md)에 현재 범위와 검증을 기록했다. 교차 창 동시 공유,
   이름 없는 문서·원격·diff/merge 분할, Split in Group은 자동으로 범위를 넓히지 않는다.
4. **도크 아웃라인과 프로젝트 전체 검색·바꾸기는 제품에 연결됐다.** 검색 도크·결과 탭·미리보기·단일 파일 및 여러 파일 적용·파일별 저장 재시도를 신규 구현 대상으로 다시 세지 않는다. 검색·바꾸기의 추가 검증은 위 개별 계획의 남은 경계에서 선택하고, 외부 도구의 신뢰·실행 gate는 별도로 다룬다.
5. 버퍼 부족은 재현된 반례에 한해 개선한다. B2의 제품 적용·상한 수치·큰 구조 변경을
   다른 기능의 완료 조건으로 묶거나 자동으로 앞당기지 않는다.

이 순서는 기능 제한의 명확성·기존 계약/구현 재사용·구조 변경 비용에 따른 제안이다.
사용자가 재현이 불명확한 작업을 원하지 않는다는 조건을 유지한다.

공유 문서의 문서 통지 분리는 `State.notifications`, 안정 handle별 LSP 연결과 read pin,
revision별 단일 통지와 뷰별 provider 갱신을 사용한다. SHVIEW15~18로 실제 서버 프로세스와
백업 파일, 부분/마지막 닫기와 WorkspaceEdit 단일 적용을 판정한다. 구문/provider 결과를 공유
캐시로 합친 상태는 아니다. 공유 IME·뷰별 검색·제품 split UI와 재시작은 이후 연결됐으며,
실제 입력기 증거와 남은 지원 범위는 위의 최신 공유 분할·복원 계획을 따른다.
