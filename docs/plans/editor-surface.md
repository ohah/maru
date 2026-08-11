# 에디터 Surface 단계 계획 (§9)

E0.5A~E4 단계와 각 단계의 종료 gate다. 계약은 [에디터 Surface](../editor-surface.md)와 그 절별 소유 문서가 가진다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§3.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1·§2·§4·§5·§10·§11 [editor-surface.md](../editor-surface.md) · §3~§3.4 [권장 구조](../editor-surface-structure.md) · §3.5 [도크 소스 컨트롤 뷰](../editor-surface-dock.md) · §6~§8 [diff·빌드·LSP](../editor-surface-tooling.md) · §9 [단계 계획](../editor-surface.md)

## 9. 단계 계획과 종료 gate

기존 [control-plane.md](../control-plane.md)의 Phase 7 웹 toolchain/markdown 계획과 번호가 충돌하지 않도록 editor는 `E` prefix를 쓴다. 구현 PR 하나가 단계 전체를 끝내는 것을 기본값으로 보지 않는다.

**file-panel과의 선후(§2 코드 대조 기준)**: 초판이 선행으로 적었던 FP 슬라이스(도크 모델·web 툴체인·도크 슬롯·브리지 read
배선·CM6 편집)는 **모두 완료돼 있다.** 즉 editor는 더 이상 file-panel을 기다리지 않는다. 남은 선후는 두 가지뿐이다.

- E1의 **도크 소스 컨트롤 뷰**(§3.5)는 도크에 **뷰 스위처**가 필요하다 — 지금 도크는 탐색기 하나만 담는다. 이 배관은
  [file-explorer.md](../file-explorer.md)와 같은 PR에서 정합한다.
- E1의 **diff 파일 Term**은 파일 entry에 `diff` kind를 더한다 — `EntryKind`→`PanelKind` 파생과 mode 선택기(`modesForKind`)를
  함께 갱신한다([file-panel-kinds.md](../file-panel-kinds.md) §2).

### E0.5A — 제품 WebKit feasibility (범위 축소: MergeView만)

- committed editor smoke asset/harness. 사용자 승인 전 production `PanelKind`/ABI/wire는 바꾸지 않는다.
- **CM6 MergeView** 제품 WebKit 통과 확인. **편집 경로는 이 gate에서 빠진다** — file-panel 소스 모드로 이미 출하돼 검증됐다(§2).
- MergeView 렌더·chunk 마커·accept/reject 상호작용. **CSP 완화는 이미 있으므로**(§7.2) 이 gate가 볼 것은 위반 수가 아니라
  **MergeView 스타일이 app origin 밖(격리 렌더)으로 새지 않는지**다.
- 1/2/4 diff 파일 Term에서 web-process RSS, hidden/background CPU와 close 뒤 회수 측정
- **종료:** §7.4(MergeView WebKit) green + CSP 위반 수 + dependency/bundle/RSS·resource scaling 보고. MergeView가 막히면
  대안 diff 렌더를 같은 gate로 비교.
- **상태(2026-07-31): 자동 항목은 닫혔다.** 하니스·게이트·artifact가 저장소에 있고(`mise run test-macos-editor-smoke`),
  MergeView는 제품 WebKit에서 막히지 않으며 CSP 위반 0·RSS/회수 측정까지 §7.4 표에 있다. 대안 diff 렌더는 필요 없다.
  **남은 것은 실제 입력기로 하는 수동 IME summary 하나**다.

### E0.5B — 순수 계약

- `EditorGrant`, versioned bridge protocol/error/cancel/epoch, DTO size/page limits
- app-global DocumentState, multi-surface 구독, revision/CAS 상태머신
- encoding/newline model, descriptor-relative path policy, safe-save failure injection, directory watcher policy 단위 테스트
- dirty recovery의 journal 대 native shadow 선택과 schema/redaction/보존 정책
- **종료:** 구체적인 상한 숫자와 파일 포맷 지원 범위를 포함해 UI 없이 auth/path/revision/save/watch/recovery 불변식 green.

### E1 — read-only diff (완료, 2026-08-01)

- `web/` workspace에 `@codemirror/merge` 추가 + reproducible build(zntc pin은 `0.1.4` — §7.1). **완료**(제품 번들 포함).
- **도크 소스 컨트롤 뷰**(§3.5) — 네 섹션·행 chrome·브랜치 헤더·접기·아이콘·스크롤·선택·표시 상한, `.git` 감시 갱신.
  읽기 전용이라 스테이지 버튼·커밋 메시지 입력은 없다(§10.14). **완료**.
- **diff 파일 Term** — 파일 entry `diff` kind + 브리지 `diff.open`. **완료**. `diff.list`는 만들지 않았다 — 목록은 GPU
  chrome이라 네이티브가 이미 status/numstat을 직접 읽고, 같은 데이터를 브리지로 한 번 더 옮길 이유가 없다(§3).
- semantic oracle + 제품 WKWebView regression — **완료**. 게이트(`mise run test-macos-editor-smoke`)가 렌더·chunk·
  accept/reject·줄 번호·세로/가로 스크롤·CSP 위반 0·스타일 유출·RSS/회수·큰 응답 파싱 비용을 단언한다(§7.4).
- git comparison/status matrix와 external diff/textconv 실행 차단 — **완료**(§3.5 실측 표: 충돌·하위 모듈·unborn·링크
  워크트리·rename·비ASCII). base 선택기는 만들지 않았다(§10.10). 상한은 실측으로 한쪽 8 MiB(§10.6).
- 에이전트 턴 base(§6.1)는 §10.11에서 E2 후속으로 정했다가 **E1 마무리 시점에 앞당기기로 했다**(2026-08-01 사용자
  결정) — 읽기 전용이라 이 단계 안에서 성립한다.
- **종료 근거(항목별)**:

  | 종료 항목 | 근거 |
  | --- | --- |
  | grant root 밖 접근 | 구조(브리지가 경로 인자 없음)·문자열(`repo_path`)·열기(요소별 `O_NOFOLLOW`) 세 겹, 실제 심링크 저장소로 확인(§6) |
  | 큰 파일 | 한쪽 8 MiB·양쪽 16 MiB. 직렬화 189 ms·파싱 16 ms·마운트 ~500 ms 실측(§10.6) |
  | binary | 앞 8000바이트 NUL 판정 → typed 거절(§6) |
  | rename | 왼쪽을 옛 경로로 읽는다. 실제 `git mv` 저장소로 확인 |
  | worktree `.git` file | 링크 워크트리에서 루트 탐지·읽기 정상(§3.5 표) |
  | untracked/conflict/submodule | 충돌은 변경 사항에만·`HEAD ↔ 작업트리`로 열림, 하위 모듈은 열지 않고 이유를 말함(§3.5 표) |
  | close/revoke | 읽는 중 Term을 닫아도 늦은 결과가 짝 없이 버려진다(크래시·누수 없음 — 테스트) |

### E2 — 편집·저장·외부 변경

- DocumentRegistry, editor change event, safe-save CAS
- directory watcher, clean reload, dirty conflict UX
- **종료:** 동일 파일 재오픈 focus/read-only/owner-transfer, save 중 재편집, 외부 atomic replace, symlink swap/hard-link, encoding/newline 보존, mode/ownership/xattr 정책, 실제 web-content/app crash recovery restore/purge green.

### E3 — 선택적 도구 실행

- formatter/linter registry와 explicit trust UX
- timeout/output/process cleanup, edit application
- **종료:** 악성 config fixture와 취소/폭주/종료 cleanup green.

### E4 — LSP

- transport/supervisor와 document sync
- diagnostics부터 vertical slice, 이후 completion/hover/definition/semantic token
- **종료:** stale response, restart, cancellation, large diagnostics/backpressure, workspace revoke green.

### 후속 backlog

- git stage/unstage, 파괴적 discard UX
- TextMate/WASM
- 증분 대형 문서 전송과 virtualized diff
- 다중 root·동시 여러 repository, remote/SSH workspace. 단일 linked worktree의 `.git` file 처리는 E1 범위다.
