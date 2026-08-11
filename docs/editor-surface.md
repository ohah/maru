# 에디터 Surface 전략 (코드 에디터·git diff·저장·도구·LSP)

이 문서는 Maru에 코드 에디터 surface를 추가하는 계획의 단일 출처다. 첫 제품 가치는 에이전트가 만든 변경을 사용자가 Maru 안에서 검토하는 것이고, 이후 같은 문서 모델 위에 편집·저장·포맷/린트·LSP를 얹는다.

경계:

- WKWebView 합성·입력·`maru-app://`·CSP는 [web-panel.md](web-panel.md)가 소유한다.
- 외부 프로세스의 Unix socket 인증과 capability 발급은 [control-plane.md](control-plane.md)가 소유한다.
- 레이어 경계는 [layering-and-portability.md](layering-and-portability.md), surface 생애주기는 [surface-runtime-api.md](surface-runtime-api.md)를 따른다.
- **우측 도크·파일 `Term` 호스팅·`.md`/`.html` 뷰어·CM6 편집기·파일 read/write 채널·웹 스택(React + Tailwind + shadcn/ui)은
  [file-panel.md](file-panel.md)가 소유한다.** git diff·editor는 그 위 확장으로 정합한다(§3·§3.5·§10.0). 여기서 재서술하지 않는다.
- 이 문서는 editor 브리지 method 확장과 `EditorGrant`, 문서 revision, safe-save CAS, 외부 변경 감시, diff/도구/LSP API와 단계 gate를 소유한다.

## 계약 문서 구성

에디터 Surface 계약은 아래 문서가 나눠 소유한다. **절 번호는 파일을 넘어 이어진다** — 다른 문서와
코드 주석이 `editor-surface.md §3.5`처럼 절 번호로 가리키므로 재번호하지 않는다.

| 절 | 문서 | 소유 |
|---|---|---|
| §1·§2 · §4·§5 · §10·§11 | 이 문서 | 적대적 PoC 결론, 현재 코드 경계, 문서 권위와 저장 CAS, 파일 I/O와 감시, 사용자 결정, 현재 한계 |
| §3~§3.4 | [권장 구조](editor-surface-structure.md) | 도크+파일 Term 배치, kind와 trust, 브리지와 grant, 코드 배치 |
| §3.5 | [도크 소스 컨트롤 뷰](editor-surface-dock.md) | 시각 구조·정보 계층 |
| §6~§8 | [diff/git API·빌드·LSP](editor-surface-tooling.md) | bounded diff/git, 빌드·엔진·CSP gate, 포맷·린트·LSP |
| §9 | [단계 계획](plans/editor-surface.md) | E0.5A~E4 단계와 종료 gate |

## 1. 2026-07-16 적대적 PoC 결론

이번 PoC는 임시 로컬 하니스로 수행했다. 결과 자체는 설계 근거지만 아직 저장소의 반복 가능한 자동 테스트가 아니다. Phase 0.5의 첫 PR은 같은 검증을 제품 하니스로 커밋해야 한다.

| 가정 | 결과 | 설계 반영 |
| --- | --- | --- |
| zntc가 Monaco를 번들할 수 있다 | **부분 통과.** zntc `16f1fda0055f844b77520cbdc4dc329cb294fef4`에서 NAPI/core/web 빌드와 Monaco semantic parity 테스트 통과. npm 최신 `0.1.3`에는 해당 수정이 모두 릴리스되지 않았다. | 아직 최소 릴리스 버전을 확정하지 않는다. 수정 포함 릴리스를 기다리거나 commit pin을 별도 승인한다. |
| Chrome에서 Vite와 픽셀이 같으면 제품에서도 된다 | **기각.** zntc 자체도 CI pixel flake 때문에 Monaco 필수 oracle을 semantic comparison으로 바꿨다. Chrome 결과는 WebKit 증거가 아니다. | 일반 CI는 semantic oracle, pixel은 선택 artifact/툴체인 qualification. 제품 gate는 별도 WKWebView E2E다. |
| 현행 엄격 CSP에서 Monaco가 동작한다 | **실패.** `style-src 'self'`에서 Monaco가 삽입한 inline `<style>`과 style attribute가 차단됐다. `unsafe-inline`을 열면 CSP 위반은 사라지고 worker/diff 계산은 동작했다. | editor 전용 CSP 결정이 필요하다. markdown CSP를 전역으로 약화하지 않는다. |
| custom scheme + module worker가 WebKit에서 된다 | **부분 통과.** `maru-poc://`에서 module 평가, worker, diff decoration 계산은 성공했다. | worker/asset 배선은 가능성이 높지만 편집기 전체 통과로 간주하지 않는다. |
| Monaco가 WKWebView에서 정상 표시·입력된다 | **실패/미해결.** window에 붙인 하니스에서도 view-line layout/text가 정상 렌더되지 않았다. Vite와 zntc 산출물이 같은 증상을 보여 zntc 고유 문제로 좁혀지지 않았다. caret·편집·한글 IME도 미검증이다. | **Phase 0.5A RED blocker.** 텍스트·caret·ASCII 편집·한글 조합/NFD·backspace가 제품 WKWebView에서 통과하기 전 Monaco 채택과 Phase 1을 확정하지 않는다. |
| isolated content world의 bridge를 page가 호출할 수 있다 | **부분 통과.** `CustomEvent`는 world를 넘지 않았지만 DOM attribute mailbox+`MutationObserver` 왕복은 성공했고 page의 `window.maru`는 계속 `undefined`였다. | 기술적으로 가능하지만 DOM은 보안 경계가 아니다. native allowlist/grant가 필수다. editor에는 더 단순한 전용 page-world shim을 권장한다. |
| 기존 atomic helper를 저장에 재사용하면 안전하다 | **기각.** `createFileAtomic(.replace=true,.make_path=true)` PoC에서 기존 mode `0640`이 `0644`로 바뀌었고 symlink 자체를 regular file로 교체했다. | editor 전용 safe-save를 구현한다. mode/symlink/xattr/ACL/fsync 정책과 CAS가 선행돼야 한다. |
| 열린 파일 FD를 감시하면 atomic replace도 계속 잡힌다 | **기각.** file-FD `DispatchSource`는 replace 때 delete만 받고 새 inode의 후속 write를 놓쳤다. directory-FD는 replace와 후속 write를 모두 신호했다. | 디렉터리 단위 감시 후 열린 문서를 재-stat/hash한다. watcher 이벤트는 힌트이고 hash가 권위다. |
| 포맷/린트는 가벼운 비신뢰 실행이다 | **기각.** Prettier config import가 임의 JS를 실행함을 실측했다. | LSP와 동일한 workspace tool-execution 신뢰 경계를 적용한다. |
| 저장 ack 하나로 dirty를 지울 수 있다 | **기각.** save 중 추가 편집이 있으면 이전 revision ack가 최신 dirty를 지우면 안 된다. 외부 disk hash 변경도 별도 충돌이다. | `editor_revision`, `persisted_editor_revision`, `disk_fingerprint` 3축 CAS를 사용한다. |
| diff before/after 전체 blob을 JSON-RPC로 보낼 수 있다 | **기각.** socket frame 상한은 1 MiB이고 현재 bridge 결과 버퍼는 8 KiB다. `app_session.zig` 한 파일만 2.7 MiB가 넘는다. | metadata 목록과 파일별 bounded open으로 분리한다. UI는 socket을 우회해 공통 L2 dispatcher를 직접 호출한다. |

### 1.1 엔진 결정 — 2026-08-09 개정: 네이티브 등폭 GPU 뷰

**diff 본문과 코드 편집의 엔진은 CM6가 아니라 네이티브 Zig + Metal이다**(사용자 결정 2026-08-09). 계약은 [native-editor.md](native-editor.md)가 단일 출처이며, diff 본문의 소유 관계는 [native-editor-ui.md](native-editor-ui.md) §7이 적는다 — **변경 목록(§3.5)은 계속 이 문서가 소유**하고 네이티브 chrome 그대로다.

이 개정이 무효화하는 것은 아래 §1.1a의 **엔진 선택**과, 그것을 전제한 §3~§11의 "CM6/MergeView" 서술이다(§7.1 번들 항목, §10.0의 0b·2번을 포함한다 — 각 지점에 개정 표기를 달았다). **무효화하지 않는 것**: `EditorGrant`·`DocumentRegistry`·safe-save CAS·revision 3축·외부 변경 감시·git/LSP adapter·§3.5 소스 컨트롤 뷰는 엔진과 무관하게 그대로 유효하다.

**대가를 명시한다.** 아래 원문이 CM6를 고른 근거 중 하나가 `@codemirror/merge`의 `acceptChunk`/`rejectChunk` 내장이었다 — hunk stage/unstage를 직접 구현해야 한다([native-editor-ui.md](native-editor-ui.md) §7). 읽기 전용 v1의 범위 밖이라 당장의 손실은 없지만 되찾는 비용이 CM6에서는 0이었다.

**`EditorGrant`의 성격이 바뀐다(중요).** §3.5는 "grant는 *웹 브리지*가 넘는 경계를 게이트하는 장치이고 도크는 웹이 아니다. 반대로 **diff 본문을 그리는 파일 Term은 웹이므로** `diff.open`은 grant 게이트를 통과해야 한다"는 비대칭 위에 서 있었다. **diff 본문이 네이티브가 되면 그 비대칭이 사라진다** — 목록도 본문도 in-process다.

- **사라지는 것**: diff/editor 표시 경로의 **브리지 신뢰 게이트**. 네이티브 뷰는 `maru-app://` origin도 `WKContentWorld`도 거치지 않으므로, "page가 root를 확대할 수 없게 한다"는 §3.2의 위협 모델이 그 경로에는 적용되지 않는다.
- **남는 것**: ⑴ **경로 스코프 정책 자체**(root 밖 접근 금지·`..`/symlink 거부)는 그대로 필요하다. 다만 성격이 *신뢰 경계*에서 *내부 불변식*으로 바뀌므로, 강제 지점이 브리지 handler가 아니라 L2 코어와 `check-boundaries`다. ⑵ **외부 CLI/agent 경계**는 그대로다 — control-plane capability nonce를 쓰는 §3.2 마지막 문단은 무효화되지 않는다. ⑶ **마크다운 CM6**가 계속 쓰는 `maru.file.*` 브리지 게이트(file-panel 소유)도 그대로다.
- **따라서 `EditorGrant`를 없애지는 않는다.** 다만 "웹 page로부터 방어하는 토큰"이 아니라 "surface에 결합된 자원 스코프 기술"로 읽는다. `tool_execute`(§8.1 workspace tool execution)는 **엔진과 무관하게** 그대로 유효하다 — LSP·포매터는 여전히 저장소의 임의 바이너리를 실행한다.

**이 문서를 읽는 법(2026-08-09 이후).** 본문 곳곳의 "CM6"·"MergeView"·"신뢰 shell origin에 마운트"는 **diff·코드 편집 축에서는 개정 전 서술**이다. 구조적으로 중요한 지점(§3 다이어그램·재사용 목록·§10.0)에는 개정 표기를 달았고, 나머지는 이 절이 덮는다. **마크다운 소스·리치 편집 축에서는 그 서술들이 계속 유효**하다(file-panel 소유).

아래는 그 결정의 원문이며, **마크다운 소스·리치 편집 축에서는 계속 유효**하다([file-panel.md](file-panel.md) §1의 미결 항목).

### 1.1a 원문 — 엔진 결정 (2026-07-17) — CodeMirror 6

위 표의 Monaco RED와 이후 실측을 근거로 **에디터 엔진을 CodeMirror 6(CM6)로 확정한다.** git diff는 `@codemirror/merge`의 `MergeView`(side-by-side)/`unifiedMergeView`(inline)로 구현한다. 근거:

- **WebKit.** Monaco의 RED(§1)는 view-line 텍스트 렌더 실패였고, DiffEditor도 같은 view-line으로 그리므로 **Monaco diff 표시에도 그대로 걸린다**(계산만 되고 화면엔 안 나옴). CM6는 [file-panel.md](file-panel.md)가 **채택을 확정**한 엔진이다(근거: contenteditable + WebKit 네이티브 IME). 단 **채택 ≠ 검증**이므로 제품 WKWebView에서 실제로 그려지는지를 따로 본다 — 그 gate는 [editor-surface-tooling.md](editor-surface-tooling.md) §7.4가 소유한다.
- **엔진 단일화.** 마크다운 편집·코드 편집·diff·hunk staging을 **CM6 하나**로 덮는다. Monaco를 diff에만 써도 마크다운은 CM6라 엔진이 둘이 된다.
- **hunk staging 적합.** `@codemirror/merge`는 `acceptChunk`/`rejectChunk`가 내장이라 git 헝크 stage/unstage(§단계 계획)에 그대로 맞는다. Monaco DiffEditor는 읽기 중심이라 이게 없다.
- **크기.** CM6 MergeView diff = **0.38 MB · 워커 0개** (targeted Monaco 4.2 MB · 워커 1개의 1/11). Chrome 실측.
- **한글 IME.** file-panel이 CM6를 고른 핵심 이유(WebKit 네이티브 IME 위 조합 안정)를 그대로 물려받는다.

**해소되지 않는 것(정직) — 2026-07-31 코드 대조로 **세 항목 모두 정정**됐다. 아래는 결정 당시의 기록이고, 현재 사실은 §2를 본다.**

- **`style-src 'unsafe-inline'`은 여전히 필요하다.** CM6도 인라인 style 속성을 쓴다(엄격 `style-src 'self'`에서 위반 4건, `unsafe-inline`에서 0 — Chrome 실측). §7.2 결정은 엔진 무관하게 남되, file-panel의 md 소스 편집(FP6)도 같은 CM6라 **동일한 완화가 필요**하다 — 처리를 공유하고, editor 때문에 markdown 읽기 뷰·격리 렌더를 새로 약화하지 않는다(§7.2 라우트별 CSP).
- **CM6의 WebKit 검증은 편집·MergeView 모두 남았다.** file-panel은 CM6를 **결정**했을 뿐 구현(FP6)은 미착수라, 제품 WebKit에서 CM6가 돈 적이 없다. Monaco 특이 RED가 재현될 가능성은 낮다고 **기대**하지만(엔진 구조가 다름), 통과 전 가정하지 않는다 — §7.4 gate가 편집+MergeView 전부를 처음 검증한다.
- **zntc 최소 버전 제약은 CM6에도 남는다.** npm 최신 `0.1.3`은 **codemirror 번들 산출물이 파싱 불가**다(#4481 `&&`-fold 괄호 소실 — 실측). Monaco 전용 수정 의존은 소멸했지만, CM6 역시 #4481 이후 수정을 포함한 릴리스가 필요하다. file-panel FP2의 `0.1.3` pin은 remark 번들 기준이라 CM6(FP6/E1)엔 불충분 — 그 시점에 pin 상향이 필요하다.
- **위 실측은 Chrome(Blink)이다.** 제품 gate는 WebKit(§7.4).

**2026-07-31 정정(코드 대조).** 위 세 항목은 그 사이 file-panel 구현이 진행되며 모두 사실이 아니게 됐다.

- `unsafe-inline`은 **file-panel이 FP12b(2026-07-22)에서 app origin 한정으로 이미 열었다.** 이 문서가 "Phase 0.5A에서
  확정한다"고 남겨 둔 결정은 그 사이 사용자 결정으로 닫혔고, editor가 할 일은 없다(§7.2).
- CM6는 **제품 WebKit에서 이미 돈다** — "돈 적이 없다"는 무효이고, 남은 미검증은 MergeView뿐이다(§7.4).
- zntc는 **`0.1.4`로 pin되어 CM6를 포함해 번들된다** — `0.1.3` 제약은 해소됐다(§7.1).

**연쇄 정정:** 아래 §3~§11에서 "Monaco"라 쓰인 엔진 소유·probe·gate·의존성 항목은 CM6 기준으로 읽는다. §1 표는 이 결정에 이른 **기록**으로 남긴다.

## 2. 현재 코드에서 확인한 경계

- `PanelKind`는 단순 trust bit가 아니다. label·DTO·layout·host config·복원 모델에 관여하는 의미 있는 종류다. 현재 `{ markdown, browser }`뿐이므로 editor를 markdown 라우트로 위장하면 권한과 lifecycle이 결합된다.
- 현행 trusted markdown bridge는 named `WKContentWorld`에만 존재하고 page world의 `window.maru`는 의도적으로 없다. 제품 smoke에서도 isolated probe=`object`, page-world probe=`undefined`, bridge hello=`0.1.0`을 확인했다.
- control dispatcher에는 metadata뿐 아니라 browser 전용 authenticated/deferred 경로가 이미 있다. 그러나 editor/file용 generic dispatcher와 제품 capability fd 발급 경로는 없다.
- **CSP는 이미 role별로 갈려 있다**(`src/session/app_scheme.zig` — FP12b, 2026-07-22 사용자 결정). Swift 스킴 핸들러가
  `AppAssetRole`에 맞는 헤더를 응답마다 붙인다. 초판이 적은 "전역 상수 하나, 라우트별 분기 없음"은 **무효**다.
  - `app_csp_header`(신뢰 shell): `… style-src 'self' 'unsafe-inline'; frame-src maru-app://render …`
  - `render_csp_header`(격리 렌더): `… style-src 'self' 'sha256-Xeh9es1…'; frame-src 'none' …`
  - 둘 다 `worker-src 'none'`·`connect-src 'none'`.
  app origin의 `'unsafe-inline'`은 정확히 **CM6 style-mod 주입** 때문에 열렸고(그 결정 주석이 "소스 에디터 하이라이트가
  전부 기본색이 되던 근본원인"이라고 적고 있다), render origin은 비신뢰 HTML을 materialize하므로 hash 핀을 유지한다.
- control socket 최대 frame은 1 MiB다. 브리지 응답도 현재 fixed 8 KiB라 큰 문서 전송 경로로 사용할 수 없다.
- **file-panel 진행 상태(2026-07-31 코드 대조)**: 이 문서가 "미래형"으로 적었던 전제 대부분이 **이미 현재형**이다.
  - **FP16 구조가 현재 계약이다**([file-panel.md](file-panel.md) 머리말): 파일 콘텐츠는 도크가 아니라 **워크스페이스
    `Term`**(`kind = .web` + 파일 entry)에 살고, 창 레벨 **도크는 `right` 고정 · 탐색기 전용**으로 축소됐다
    (`dock_panel.Side = enum { right, bottom }`이지만 배치는 right 고정). **따라서 이 문서 §3의 "도크 콘텐츠 rect에
    diff를 얹는다"는 전제는 더 이상 성립하지 않는다** — 아래 §3에서 재작성했다.
  - **CM6는 코드에 있고 제품에 출하돼 있다**(`web/src/editor.ts` — `@codemirror/{state,view,commands,lang-markdown}`).
    "FP6 예정이라 코드에 아직 없다"는 서술은 무효다.
  - **zntc pin은 `0.1.4`**이고 CM6를 포함한 번들이 실제로 나온다(`web/package.json`). "`0.1.3`은 CM6 번들 불가"라는
    한계는 해소됐다.
  - **웹 스택은 React + Tailwind + shadcn/ui**로 바뀌었다([file-panel-web-stack.md](file-panel-web-stack.md) §2.1, 2026-07-29 사용자 결정).
    "프레임워크 없음"을 전제한 §7.1 서술은 무효다.
  - **CM6 스타일 문제는 file-panel이 FP12b에서 이미 풀었다.** §1.1이 남긴 `unsafe-inline` 항목은 app origin 한정 완화로
    해소됐고(위 CSP 항목), 그 완화가 **정확히 CM6 style-mod 주입** 때문이라는 것이 결정 주석에 적혀 있다. editor가 새로
    결정하거나 배관할 CSP 작업은 없다 — MergeView도 같은 app origin에 마운트되므로 그대로 덮인다(§7.2).

## 4. 문서 권위와 저장 CAS

> **2026-08-09 개정 — 이 절의 전제가 바뀌었다.** 아래는 "native가 전체 text 정본을 보유하지 않는다"를 전제로 쓰였으나, [native-editor-layering.md](native-editor-layering.md) §2·[native-editor-document-model.md](native-editor-document-model.md) §3.0이 **버퍼를 L2에 두어 정확히 그 정본을 만든다.** 두 귀결이 따라온다 — ⑴ **`writable CM6 owner surface 하나` 제약이 diff·코드 편집 축에서 소멸**하고, 같은 문서를 두 뷰가 공유할 수 있다([native-editor-layering.md](native-editor-layering.md) §2.4가 그 계약을 소유하며 `file-panel.md` §1 불변식에 명시 명령 예외가 붙는다), ⑵ **문서 text·undo·selection의 소유자가 CM6가 아니라 L2 모델**이다. 아래 `DocumentState`의 revision·fingerprint·conflict 3축은 **엔진과 무관하게 그대로 유효**하다. 마크다운 축에서는 원문이 계속 맞다.

CM6가 열린 문서의 현재 text, undo stack, selection/cursor를 소유한다(file-panel의 CM6 소스 편집과 같은 엔진). file-panel은 이미 **dirty를 브리지 신호로 Zig에 미러**하는데(file-panel §3), editor는 그 dirty 신호를 **revision/fingerprint/conflict가 있는 `DocumentRegistry`로 확장**한다 — 단일 핀 파일이 아니라 grant-root 안 여러 문서를 다루므로 identity·CAS가 필요하다. `DocumentRegistry`는 앱 전역으로 하나를 두어 window/surface가 달라도 같은 파일 identity를 공유한다. 같은 파일을 독립 model 두 개로 열어 각자 저장하게 두는 구조는 CAS 충돌을 정상 UX로 가장하므로 허용하지 않는다.

native가 전체 text 정본을 보유하지 않는 v1에서는 한 document에 **writable CM6 owner surface 하나**만 둔다. 두 번째 open은 기존 owner를 focus하거나 명시적 read-only snapshot을 연다. owner close/move/crash 때 dirty 여부를 확인한 뒤 owner를 transfer/recover하며, 두 page의 editable model을 실시간 동기화하는 것은 native canonical text 또는 CRDT/OT가 필요하므로 v1 범위 밖이다.

L2 `DocumentRegistry`는 동일 text의 두 번째 정본을 상시 유지하지 않고 다음 상태를 소유한다.

```text
DocumentState {
  document_id,
  document_key,
  editor_revision,
  persisted_editor_revision,
  disk_fingerprint,
  conflict,
  subscribers,
  recovery_state,
}
```

- `document_key`는 단순 path 문자열이 아니라 grant `root_id` + 상대 경로 + 열린 시점 file identity를 포함한다. rename/replace 뒤에는 정책에 따라 같은 문서 identity를 유지하거나 명시적으로 새 문서로 전환한다.
- page는 `document_id`와 path의 대응을 선택할 수 없다. native가 `file.open`에서 결합하고 이후 save/change 요청은 그 결합을 사용한다.
- page의 content change마다 `editor_revision`이 단조 증가한다.
- save 요청은 `{document_id, editor_revision, expected_disk_fingerprint, bytes}`를 보낸다. 초기 버전은 bounded full text를 허용하되 큰 파일 상한을 둔다. 증분 edit 프로토콜은 필요가 측정될 때 추가한다.
- native는 write 직전에 disk fingerprint를 다시 비교한다. 다르면 쓰지 않고 conflict를 반환한다.
- save ack는 저장된 revision과 새 disk fingerprint를 돌려준다. ack 뒤 현재 editor revision이 더 크면 dirty는 유지한다.
- 외부 변경을 받아들일 때 통짜 model 교체로 undo/cursor를 깨지 않는다. clean 문서는 최소 edit로 갱신하고, dirty 문서는 reload/keep/compare를 사용자에게 선택하게 한다.
- fingerprint는 적어도 file identity, size, mtime, content hash를 포함하되 최종 authority는 content hash다.
- watcher가 자기 save를 다시 외부 변경으로 보고하지 않도록 save operation id와 결과 fingerprint를 기록한다. 단 operation id만으로 무시하지 않고 실제 hash가 예상값과 같을 때만 self-write로 접는다.
- dirty owner surface를 닫거나 workspace/window를 종료할 때 save/discard/cancel을 묻는다. discard는 메모리 buffer 폐기이지 `git discard`가 아니다. app 종료 중 여러 dirty document의 순서·일괄 취소·save 실패 후 종료 중단을 상태머신 테스트로 고정한다.

### 4.1 텍스트 포맷 계약

CM6 문자열(JS UTF-16 code unit)과 디스크 bytes 사이 변환을 암묵적으로 UTF-8이라고 가정하지 않는다.

- v1 지원 범위는 UTF-8(선택적 BOM) 텍스트로 제한하는 것을 권장한다. invalid UTF-8, UTF-16/32, binary는 읽기 전용 hex/external-open 또는 typed `unsupported_encoding`으로 거부한다.
- open 결과는 `encoding`, `bom`, `line_ending`(`lf|crlf|mixed`), `has_final_newline`을 함께 반환한다.
- save 기본은 원본 BOM·우세 개행·마지막 newline 상태 보존이다. 사용자가 명시적으로 바꾸지 않은 포맷을 formatter 결과 때문에 조용히 바꾸지 않는다.
- mixed line ending을 정규화할지 보존할지는 최초 저장 UX 전에 결정한다.
- CM6 UTF-16 offset과 LSP UTF-16 position, 디스크 UTF-8 byte offset을 별도 타입으로 다룬다. byte offset을 editor/LSP position으로 재사용하지 않는다.
- NUL 포함 파일, 매우 긴 한 줄, combining/NFD, lone CR, final newline 없음 fixture를 둔다.

### 4.2 unsaved recovery와 restore

“crash recovery green”만으로는 완료 조건이 아니다. 복구 데이터의 수명과 민감정보 정책을 먼저 정한다.

- 기본 workspace restore에는 editor 원문을 넣지 않는다. dirty buffer recovery는 별도 local-only journal 또는 native shadow checkpoint로 설계한다.
- recovery record는 `document_id`가 아니라 root의 익명화 가능한 identity, 상대 경로, base fingerprint, editor revision, content 또는 edit log, schema version을 가진다.
- 주기/최대 용량/보존 기간/정상 save 후 삭제/web-content crash 후 복원/app crash 후 안내를 정의한다.
- journal은 source code·token을 포함할 수 있으므로 fixture나 일반 trace에 원문을 복제하지 않는다. 권한 mode, backup exclusion, purge UX를 검증한다.
- recovery가 base fingerprint와 맞지 않으면 자동 덮어쓰기하지 않고 recovered-vs-disk 비교를 연다.
- native가 canonical text를 상시 갖지 않는 구조에서 recovery checkpoint까지 없으면 WKWebView process crash가 dirty buffer를 전부 잃는다. 따라서 E2 편집 기능은 journal/shadow 중 하나가 실제 crash restore를 통과하기 전 완료 처리하지 않는다. 복구 저장을 원하지 않는 정책이면 E1 read-only까지만 제공한다.

## 5. 파일 I/O와 감시

### 5.1 safe-save

file-panel의 `maru.file.write(content)`는 **핀 단일 경로**에만 쓰므로 피해 반경이 그 파일 하나로 bound된다(file-panel §3). editor는 grant-root 안 **임의 상대 경로**로 넓히므로(§3.2 escalation) 그 좁은 write로는 부족하고, 아래 safe-save가 그 넓힌 범위의 안전을 책임진다. 기존 `createFileAtomic(.replace=true,.make_path=true)`를 직접 재사용하지 않는다 — editor 전용 저장은 다음 순서를 만족해야 한다.

1. grant root를 열린 directory descriptor로 고정하고 상대 path segment를 descriptor-relative로 순회한다. 문자열 `canonicalize → 검사 → 다시 path로 open`하는 TOCTOU 구조는 사용하지 않는다.
2. expected disk fingerprint를 비교한다.
3. 같은 디렉터리에 `O_EXCL` temp를 만들고 정상 save에서는 parent 자동 생성을 금지한다.
4. 기존 mode를 보존하고 ACL/xattr 보존 정책을 명시한다. 보존 실패는 조용히 무시하지 않는다.
5. write-all, file flush/fsync, atomic rename, directory fsync 순으로 완료한다.
6. 오류·취소 시 temp를 정리하고 원본을 유지한다.

경로 순회는 각 segment에서 symlink 정책을 강제하고, 검사 뒤 공격자가 symlink/parent를 교체하는 race를 red test로 둔다. hard link는 in-place write면 root 밖 같은 inode까지 바꾸고 atomic replace면 기존 link 관계를 끊으므로, v1에서 link count>1 저장을 거부할지 사용자 확인할지 결정한다. file type은 regular file만 허용하고 device/FIFO/socket은 거부한다. ownership, mode, ACL, xattr, quarantine/backup metadata 중 무엇을 보존하는지 명시한다.

기존 파일 저장과 새 파일 생성은 같은 op로 암묵 처리하지 않는다. `file.save`는 이미 열린 document identity만 갱신하고, `file.create`는 별도 확인·충돌 검사·기본 mode·부모 존재 조건을 가진다. rename/delete도 E2 기본 범위에 넣지 않고 별도 capability/UX가 정해질 때까지 거부한다.

최소 테스트: 기존 mode/ownership, 새 파일, 내부·외부 symlink, symlink swap race, parent rename race, hard link, 특수 파일, read-only dir, xattr/ACL 정책, disk-full/short-write 주입, fsync/rename 실패, temp cleanup, CAS 충돌, save 중 추가 편집.

### 5.2 외부 변경 감시

L4 macOS host가 open document를 디렉터리별로 묶어 `DispatchSource` 또는 규모가 커질 때 FSEvents로 감시한다. 기존 PTY kqueue 구현은 lifecycle/threading 참고만 하고 file watcher로 일반화해 억지 재사용하지 않는다.

- event를 debounce/coalesce한 뒤 그 directory의 열린 문서를 모두 재-stat/hash한다.
- rename/delete로 directory watch 자체가 무효화되면 re-arm한다.
- watcher 이벤트 종류나 횟수는 정합성 authority가 아니다.
- close/revoke/workspace 변경 때 watch와 in-flight hash를 취소한다.
- v1은 directory watcher 수에 hard cap을 두고 초과 시 명시적으로 기능을 제한한다. FSEvents 전환은 실제 cap 압력이 측정될 때 후속으로 둔다. sleep/wake, volume unmount, case-only rename, rapid replace storm 뒤에도 최종 hash로 수렴하는 soak는 유지한다.

## 10. 사용자 결정

문서만으로 승인된 것으로 간주하지 않는 항목들이다. 결정된 것은 날짜와 함께 **계약**으로 남기고, 남은 것만 질문으로 둔다.
번호는 최초 목록의 것을 유지한다 — 다른 문서·PR이 번호로 참조하기 때문이다.

### 10.A 결정됨

0. **정합 형태 = (a′) 확정(2026-07-31).** **목록은 우측 도크의 새 뷰(GPU chrome) · 본문은 diff kind 파일 Term**이고 별도
   `PanelKind`는 만들지 않는다. 원래 질문이던 "(a) 도크 콘텐츠 kind vs (b) 별도 `.editor` surface"는 FP16이 도크에서 콘텐츠
   rect를 없애며 둘 다 성립하지 않게 됐고, §3~§3.5가 (a′) 기준으로 재작성돼 도크 뷰가 이미 그 형태로 출하됐다.

0b. **에디터 엔진 = 네이티브 등폭 GPU 뷰 (2026-08-09 개정 · §1.1).** diff 본문과 코드 편집은 CM6가 아니라 Zig + Metal이 그린다([native-editor.md](native-editor.md)). hunk staging은 CM6가 `acceptChunk`/`rejectChunk`로 무료 제공하던 것을 **직접 구현**해야 한다(읽기 전용 v1 범위 밖이라 당장의 손실은 없다). **아래는 개정 전 원문이며 마크다운 소스·리치 편집 축에서는 계속 유효하다:** ~~에디터 엔진 = CM6 (확정, 2026-07-17 · §1.1a). git diff는 `@codemirror/merge` MergeView/unifiedMergeView, hunk staging은 acceptChunk/rejectChunk. Monaco는 채택하지 않는다(WebKit RED가 diff 표시에도 걸리고, 마크다운이 CM6라 엔진 이원화). 이 확정이 §7.1·§7.4·§9의 Monaco 조건부 항목을 CM6 기준으로 바꿨다. 남은 엔진 관련 결정은 없다.~~

1. **`PanelKind.editor`·ABI/wire 확장은 만들지 않는다(2026-07-31).** (a′)의 직접 귀결이다 — 0을 뒤집을 때만 되살아난다.

2. ~~**`@codemirror/merge`를 쓴다(2026-07-31).**~~ → **소멸(2026-08-09 엔진 개정, §1.1).** diff 본문이 네이티브로 가므로
   이 의존을 유지하지 않는다. **정정**: 이 항목은 "제품 번들 편입은 E1에서"라고 적었으나 실제로는 `web/src/diff-view.ts`가
   작성돼 `main.ts`가 `bootDiff`를 import하므로 **이미 번들에 들어가 있다**. 다만 [검증 매트릭스](verification-matrix.md)가
   "MergeView는 번들·WebKit·CSP 어느 것도 확인된 적이 없다"고 적듯 **제품 WebKit 검증은 통과한 적이 없고**(§7.4 gate RED),
   그 미검증이 오히려 네이티브 이관의 근거를 보탠다 — Monaco를 기각한 이유가 같은 관문이었다(§1).

3. ~~editor origin 한정 `style-src 'unsafe-inline'` 허용 여부~~ → **소멸(FP12b, 2026-07-22 사용자 결정으로 이미 닫힘).**
   app origin은 `'unsafe-inline'`, render origin은 hash 핀이며 그 완화 이유가 CM6 style-mod다(§2·§7.2). editor는 그 위에
   얹기만 한다.

4. **git 읽기 승인은 workspace root 승인에 포함한다(2026-07-31).** 탐색기로 연 폴더 안의 git 읽기를 위해 사용자에게
   다시 묻지 않고, `EditorGrant.git_read`는 그 root 승인에서 **파생**시킨다(플래그 자체는 §3.1 그대로 — 웹 브리지 경계는
   유지된다). **쓰기(stage/unstage/discard)는 끝까지 별도 capability**다(§6·§10.14). native `root_id`/descriptor 발급·회수
   방식은 E1 구현에서 정한다.

6. **상한은 바이트로만 걸고, 한쪽 8 MiB다(2026-08-01 실측).** 넘으면 typed `too_large`와 external-open
   fallback을 준다(§6).

   두 번에 걸쳐 정정한 값이다. ⑴ **"diff 페이지 500행"은 페이지네이션 단위이지 표시 상한이 아니다** — 초판 구현이
   그걸 상한으로 써서 500줄 넘는 파일(대부분)이 안 열렸다. ⑵ 그 뒤 남은 1 MiB 바이트 상한도 실제 소스를 막았다 —
   이 저장소의 `app_session.zig`가 4.0 MB(60,965줄)라 못 열렸다.

   | 문서 | 크기 | 마운트(제품 WKWebView) |
   | --- | --- | --- |
   | 2만 줄 | 3.7 MB | 238 ms |
   | 4만 줄 | 7.4 MB | 369 ms |
   | 6만 줄 | 11 MB | 514 ms |

   비용이 크기에 완만하게 붙는다(CM6가 화면 밖을 그리지 않는다). 8 MiB는 평범한 소스 파일을 덮으면서 브리지가 한
   번에 옮기는 양은 묶어 둔다(양쪽 합 16 MiB).

   **브리지 왕복도 쟀다(최악, 양쪽 8 MiB씩):** 네이티브 직렬화 **189 ms**(입력 16 MiB → 응답 17 MiB, escape 증폭
   6%), 웹 `JSON.parse` **16 ms**, CM6 마운트 ~500 ms. 합쳐 0.7초 남짓이고 증폭이 없으므로 이 상한에서 "열리긴
   하는데 앱이 멎는" 구간은 없다. 상한을 더 올릴 일이 생기면 **그때는 값이 아니라 전송 방식**(청크·페이지)을 바꾼다 —
   한 번에 옮기는 양이 늘수록 escape·복사·파싱이 전부 같이 늘기 때문이다. **백엔드 읽기 상한은 이보다 커야 한다**(16 MiB) — 작으면 blob이
   거기서 먼저 잘려 "너무 큼"으로 거절되는데, 그 판단은 payload 정책이 해야 한다(같은 한계를 두 곳에서 다르게 말하지
   않는다). 더 큰 파일은 상한을 또 올릴 것이 아니라 **전송 방식**(청크·페이지)을 바꿀 일이다.

10. **섹션이 곧 기준이다 — 전역 기본 base도, base 선택기도 두지 않는다(2026-07-31).** 행이 속한 섹션이 비교 기준을
    정한다(스테이지된 변경=`HEAD↔index`, 변경 사항=`index↔worktree`, 추적되지 않은 파일=비교 대상 없음 — §3.5 표). 목록이
    이미 그렇게 서 있어 규칙이 하나로 유지되고, 사용자가 base를 고를 일이 없다. conflict는 `U`로 표시하고(파서 구현됨),
    submodule은 v1에서 별도 표기 없이 경로로만 낸다.

11. **에이전트 턴 diff(§6.1)를 E1에 넣는다(2026-08-01 재결정).** 7월 31일에는 E2 후속으로 정했으나, E1의 나머지가
    닫히고 나니 **읽기 전용이라 이 단계 안에서 성립**하고 목업의 핵심 UX라 앞당긴다. 아래 7월 31일 판단은 그때의
    근거로 남긴다(무엇이 바뀌어 결정이 뒤집혔는지 보이게).
    ~~**에이전트 턴 diff(§6.1)는 E2 후속이다(2026-07-31).**~~ v1은 git 기준(HEAD/index/worktree)만 다룬다. 턴 base는 전체
    transcript 파싱(현행 파서는 tail만 읽는다)·턴 경계 스냅샷 배관·ring buffer 보관 정책이 **전부 신규**라 E1을 두 배로
    키운다. diff가 제품에서 도는 것을 먼저 확인하고 얹는다. 스냅샷 방식(write-tree vs touched-files)과 보관 정책은 그때 정한다.

13. **도크 뷰 스위처 = 3슬롯·영속·마지막 뷰 유지(2026-07-31, 출하됨).** 아이콘 줄은 탐색기 · 소스 컨트롤 · AI 세션
    목록 세 칸이다. 선택한 뷰는 workspace에 `dock-view`로 영속하고 모르는 값은 탐색기로 clamp한다. 포커스 왕복은 뷰를
    바꾸지 않는다(마지막 뷰 유지). 이 결정은 [file-explorer.md](file-explorer.md) §3.5와 공유한다.

### 10.B 남음

5·7·8·9는 **쓰기**가 생겨야 판단 근거가 생기고(E2 이후), 12·14는 v1 범위 밖으로 미뤄 둔 것이다.

5. 새 파일의 기본 mode 및 기존 ownership/ACL/xattr/hard-link 보존·거부·실패 정책

7. v1 지원 encoding/BOM/mixed-newline 정책과 binary/invalid UTF-8 UX

8. 동일 파일을 여러 surface에서 여는 UX와 app-global document session 공유 방식

9. dirty recovery의 journal 대 native shadow, 기본 활성/opt-out UX, 최대 용량, 보존 기간, purge UX

12. **PR 헤더(§3.5).** 목업 첫 줄의 `PR #8443`은 로컬 git 밖 정보다(GitHub API/`gh`·인증·사설 호스트·rate limit). v1은 브랜치·
    upstream·ahead/behind만 채우고 자리를 비워 둔다 — PR 연동을 할지, 한다면 `gh` CLI 위임인지 자체 HTTP인지, 실패 시 헤더를
    어떻게 접을지를 별도로 정한다.

14. **스테이징 UI를 켜는 시점(§3.5).** `＋ 모두 스테이지`·커밋 메시지·`COMMITS` 섹션은 write 동작이라 v1에서 감춘다. 어느
    단계에서 켤지와, 그때 `git_write` grant를 `git_read`와 분리할지 한 grant로 묶을지.

## 11. 현재 한계

- **§3~§8은 FP16 구조(도크 목록 + 파일 Term 본문)로 재작성됐다**(2026-07-31, 구조·정합 층). 남은 것은 **구현 층 세부** —
  MergeView/unifiedMergeView·acceptChunk 배선, CM6↔디스크 인코딩 매핑, 브리지 method 표의 실제 스키마, 도크 뷰 chrome의
  기하·히트테스트 — 로, E0.5B/E1 slice에서 코드와 함께 고정한다. 정합 형태는 (a′)로 확정됐다(§10.0, 2026-07-31).
- **도크 소스 컨트롤 뷰(§3.5)는 목업의 정보 계층만 옮긴 것이고 기하는 미정이다.** 행 높이·아이콘 세트·색 토큰·스크롤·키보드
  이동은 탐색기 트리와 공유해야 하는데, 그 공유 표면이 [file-explorer.md](file-explorer.md)에 아직 뷰 하나 기준으로만 적혀 있다.
- 제품 WKWebView에서 **MergeView는 검증됐다**(2026-07-31 — §7.4 표). 렌더·chunk·accept/reject·CSP 위반 0·RSS/회수까지
  자동 게이트가 남긴다. 남은 것은 실제 입력기로 하는 수동 IME 확인이다.
- 하니스와 결과 artifact가 저장소에 있다(`tests/macos_editor_smoke.swift`·`web/src/diff-harness.ts`,
  산출물 `zig-out/maru-macos-editor-smoke/`). 재현은 `mise run test-macos-editor-smoke`.
- **`@codemirror/merge` 번들 가능성은 확인됐다(PoC 2026-07-31).** `@codemirror/merge@6.12.2`를 실제 앱 엔트리에 넣어
  zntc `0.1.4`로 번들했고, 산출물이 파싱되며 크기는 **+31 KiB**(2,752,306 → 2,784,419 bytes)다. CM6 코어가 이미 들어 있어
  증분이 작다. 3 MiB 예산 여유는 약 353 KiB 남는다. **런타임 동작과 CSP 영향도 이제 확인됐다**(§7.4 표) — 다만 그
  확인은 스모크 전용 asset root(하니스 번들 281 KiB)에서 한 것이고, **제품 번들에 diff를 넣는 순간의 크기·예산은 E1에서
  다시 잰다**(제품 번들은 이 PR에서 바뀌지 않았다).
- **MergeView 스타일은 app origin에 머문다(확인됨, 2026-07-31).** 하니스 문서의 모든 `<style>`이 그 문서 소유였고
  격리 렌더 문서는 만들어지지 않았다(§7.4 표). 제품 배선에서 diff를 다른 문서에 얹으면 이 확인은 다시 해야 한다.
- safe-save는 요구사항만 검증됐고 구현되지 않았다.
- 제품 file capability 발급, editor bridge, DocumentRegistry, watcher, diff service는 모두 미구현이다.
- bundle size 외 실제 WKWebView web-process RSS, first interactive, large-file latency 예산은 미측정이다.
- 파일 encoding/newline, multi-surface 동시 편집, crash recovery, hard-link/TOCTOU, git worktree/conflict 의미는 이번 문서에서 구현 gate로 추가됐지만 아직 PoC가 없다.
- editor domain event/trace schema와 민감정보 artifact 형식은 미정이며 E0.5B에서 facade/trace 문서와 함께 닫아야 한다.
