# 에디터 Surface 전략 (코드 에디터·git diff·저장·도구·LSP)

이 문서는 Maru에 코드 에디터 surface를 추가하는 계획의 단일 출처다. 첫 제품 가치는 에이전트가 만든 변경을 사용자가 Maru 안에서 검토하는 것이고, 이후 같은 문서 모델 위에 편집·저장·포맷/린트·LSP를 얹는다.

경계:

- WKWebView 합성·입력·`maru-app://`·CSP는 [web-panel.md](web-panel.md)가 소유한다.
- 외부 프로세스의 Unix socket 인증과 capability 발급은 [control-plane.md](control-plane.md)가 소유한다.
- 레이어 경계는 [layering-and-portability.md](layering-and-portability.md), surface 생애주기는 [surface-runtime-api.md](surface-runtime-api.md)를 따른다.
- **우측 도크·파일 `Term` 호스팅·`.md`/`.html` 뷰어·CM6 편집기·파일 read/write 채널·웹 스택(React + Tailwind + shadcn/ui)은
  [file-panel.md](file-panel.md)가 소유한다.** git diff·editor는 그 위 확장으로 정합한다(§3·§3.5·§10.0). 여기서 재서술하지 않는다.
- 이 문서는 editor 브리지 method 확장과 `EditorGrant`, 문서 revision, safe-save CAS, 외부 변경 감시, diff/도구/LSP API와 단계 gate를 소유한다.

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

**diff 본문과 코드 편집의 엔진은 CM6가 아니라 네이티브 Zig + Metal이다**(사용자 결정 2026-08-09). 계약은 [native-editor.md](native-editor.md)가 단일 출처이며, diff 본문의 소유 관계는 그 문서 §7이 적는다 — **변경 목록(§3.5)은 계속 이 문서가 소유**하고 네이티브 chrome 그대로다.

이 개정이 무효화하는 것은 아래 §1.1a의 **엔진 선택**과, 그것을 전제한 §3~§11의 "CM6/MergeView" 서술이다(§7.1 번들 항목, §10.0의 0b·2번을 포함한다 — 각 지점에 개정 표기를 달았다). **무효화하지 않는 것**: `EditorGrant`·`DocumentRegistry`·safe-save CAS·revision 3축·외부 변경 감시·git/LSP adapter·§3.5 소스 컨트롤 뷰는 엔진과 무관하게 그대로 유효하다.

**대가를 명시한다.** 아래 원문이 CM6를 고른 근거 중 하나가 `@codemirror/merge`의 `acceptChunk`/`rejectChunk` 내장이었다 — hunk stage/unstage를 직접 구현해야 한다([native-editor.md](native-editor.md) §7). 읽기 전용 v1의 범위 밖이라 당장의 손실은 없지만 되찾는 비용이 CM6에서는 0이었다.

**`EditorGrant`의 성격이 바뀐다(중요).** §3.5는 "grant는 *웹 브리지*가 넘는 경계를 게이트하는 장치이고 도크는 웹이 아니다. 반대로 **diff 본문을 그리는 파일 Term은 웹이므로** `diff.open`은 grant 게이트를 통과해야 한다"는 비대칭 위에 서 있었다. **diff 본문이 네이티브가 되면 그 비대칭이 사라진다** — 목록도 본문도 in-process다.

- **사라지는 것**: diff/editor 표시 경로의 **브리지 신뢰 게이트**. 네이티브 뷰는 `maru-app://` origin도 `WKContentWorld`도 거치지 않으므로, "page가 root를 확대할 수 없게 한다"는 §3.2의 위협 모델이 그 경로에는 적용되지 않는다.
- **남는 것**: ⑴ **경로 스코프 정책 자체**(root 밖 접근 금지·`..`/symlink 거부)는 그대로 필요하다. 다만 성격이 *신뢰 경계*에서 *내부 불변식*으로 바뀌므로, 강제 지점이 브리지 handler가 아니라 L2 코어와 `check-boundaries`다. ⑵ **외부 CLI/agent 경계**는 그대로다 — control-plane capability nonce를 쓰는 §3.2 마지막 문단은 무효화되지 않는다. ⑶ **마크다운 CM6**가 계속 쓰는 `maru.file.*` 브리지 게이트(file-panel 소유)도 그대로다.
- **따라서 `EditorGrant`를 없애지는 않는다.** 다만 "웹 page로부터 방어하는 토큰"이 아니라 "surface에 결합된 자원 스코프 기술"로 읽는다. `tool_execute`(§8.1 workspace tool execution)는 **엔진과 무관하게** 그대로 유효하다 — LSP·포매터는 여전히 저장소의 임의 바이너리를 실행한다.

**이 문서를 읽는 법(2026-08-09 이후).** 본문 곳곳의 "CM6"·"MergeView"·"신뢰 shell origin에 마운트"는 **diff·코드 편집 축에서는 개정 전 서술**이다. 구조적으로 중요한 지점(§3 다이어그램·재사용 목록·§10.0)에는 개정 표기를 달았고, 나머지는 이 절이 덮는다. **마크다운 소스·리치 편집 축에서는 그 서술들이 계속 유효**하다(file-panel 소유).

아래는 그 결정의 원문이며, **마크다운 소스·리치 편집 축에서는 계속 유효**하다([file-panel.md](file-panel.md) §1의 미결 항목).

### 1.1a 원문 — 엔진 결정 (2026-07-17) — CodeMirror 6

위 표의 Monaco RED와 이후 실측을 근거로 **에디터 엔진을 CodeMirror 6(CM6)로 확정한다.** git diff는 `@codemirror/merge`의 `MergeView`(side-by-side)/`unifiedMergeView`(inline)로 구현한다. 근거:

- **WebKit.** Monaco의 RED(§1)는 view-line 텍스트 렌더 실패였고, DiffEditor도 같은 view-line으로 그리므로 **Monaco diff 표시에도 그대로 걸린다**(계산만 되고 화면엔 안 나옴). CM6는 [file-panel.md](file-panel.md)가 **채택을 확정**한 엔진이다(근거: contenteditable + WebKit 네이티브 IME). 단 **채택 ≠ 검증** — CM6 구현은 FP6(미착수)이라 제품 WebKit 검증은 E0.5A가 처음 한다(§7.4).
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
  - **웹 스택은 React + Tailwind + shadcn/ui**로 바뀌었다([file-panel.md](file-panel.md) §2.1, 2026-07-29 사용자 결정).
    "프레임워크 없음"을 전제한 §7.1 서술은 무효다.
  - **CM6 스타일 문제는 file-panel이 FP12b에서 이미 풀었다.** §1.1이 남긴 `unsafe-inline` 항목은 app origin 한정 완화로
    해소됐고(위 CSP 항목), 그 완화가 **정확히 CM6 style-mod 주입** 때문이라는 것이 결정 주석에 적혀 있다. editor가 새로
    결정하거나 배관할 CSP 작업은 없다 — MergeView도 같은 app origin에 마운트되므로 그대로 덮인다(§7.2).

## 3. 권장 구조 — 우측 도크(목록) + 파일 Term(본문)

**editor/git diff는 별도 surface를 새로 만들지 않고 [file-panel.md](file-panel.md)가 이미 가진 두 자리를 쓴다.** FP16 이후
그 두 자리는 이렇게 갈린다.

- **변경 목록·스테이징 UI = 우측 도크의 새 뷰**(Zig + GPU chrome). 탐색기 트리와 같은 컬럼을 공유하고 상단 아이콘 줄로
  전환한다(§3.5). 웹뷰가 아니다.
- **diff 본문 = 파일 `Term`**(**네이티브 등폭 GPU 뷰** — 2026-08-09 개정, §1.1. 옛 서술은 "WKWebView + CM6 `MergeView`").
  마크다운 문서가 그러하듯 탭 스트립에 살고, 터미널 옆에서 같은 split·드래그·닫기 계약을 그대로 쓴다. 본문의 렌더·매핑
  계약은 [native-editor.md](native-editor.md)가 소유한다.

이 분할은 새 정책이 아니라 **FP16을 그대로 따른 결과**다. 도크는 "여러 파일을 훑는 세로 컬럼", Term은 "지금 보는 문서"이고,
git 리뷰는 정확히 그 두 역할로 나뉜다. 초판이 상정한 "도크 콘텐츠 rect에 diff 웹앱을 얹는다"는 도크에 콘텐츠 rect가
없어졌으므로 성립하지 않는다.

```text
우측 도크 ── 창(chrome) 레벨, Zig + GPU, 폭 조절·접기 ────────
  뷰 스위처(아이콘 줄)  탐색기 | 소스 컨트롤 | (후속: 확장·작업)
  ├ 탐색기 뷰 = 파일 트리                    (file-explorer.md 소유)
  └ 소스 컨트롤 뷰 = 브랜치·커밋 메시지·변경 목록  (§3.5, 이 문서 소유)
       diff.list / git.status 결과를 **직접** 소비한다(웹 경유 없음)

워크스페이스 pane 트리 ── 탭 스트립 공유 ─────────────────────
  터미널 Term · 브라우저 Term · 파일 Term
  파일 Term(diff kind) = **네이티브 등폭 GPU 뷰**(2026-08-09 개정 · native-editor.md)
    in-process 직접 호출 — WKWebView·origin·브리지를 거치지 않는다
       editor.* / diff.* / git.*             ← L2 코어 직접 호출(경로 스코프는 내부 불변식, §1.1)

  파일 Term(markdown kind) = WKWebView, 두 web 컨텍스트(file-panel §2.1) — 개정 대상 아님:
    ├ 격리 렌더 origin  = 새니타이즈 md/rich-render(Mermaid 등). 브리지 없음.
    └ 신뢰 shell origin = CM6 마운트 + 브리지 + 오케스트레이션
         maru.file.read()/write(content)     ← file-panel: **핀 경로** read/write

신뢰 shell 브리지(확장) ── in-process, host가 surface에 결합한 grant 검증 후 직접 호출
  -> L2: file-panel 정책 + editor 코어(신규)
       |- DocumentRegistry (identity/revision/disk fingerprint/conflict/recovery)
       |- EditorGrant/path scope  (핀 단일 경로 → grant-root 상대 = 의도적 escalation, §3.2)
       |- diff/turn-base model (§6·§6.1)
       `- injected adapter interfaces
            |- L4 FileAdapter (descriptor-safe read/save/stat/hash)
            |- L4 WatchAdapter (DispatchSource/FSEvents)
            |- L4 GitAdapter (bounded read-only git invocation)
            `- L4 ToolAdapter (formatter/linter/LSP process)

external CLI/agent
  -> Unix socket + capability nonce
  -> 같은 L2 policy/services
```

**재사용 vs 신규(정합 — 2026-08-09 엔진 개정 반영):** 도크 컬럼·폭/접기·파일 Term 호스팅·dirty 보고는 **file-panel이 이미
가졌다**(재사용). editor가 신규로 짓는 것은 ⑴ L2 editor 코어(grant·registry·CAS·diff/turn model), ⑵ 그것을 부르는 **in-process
호출부**, ⑶ **도크 소스 컨트롤 뷰 chrome**(§3.5), ⑷ **네이티브 등폭 뷰**([native-editor.md](native-editor.md))다.
별도 `.editor` PanelKind를 만들지 않는다.

~~두 web 컨텍스트·CM6 마운트·`maru.file.*` 브리지 트랜스포트 재사용, 브리지 method 확장(diff/git/multi-file/save), 별도
origin·별도 브리지 금지~~ → **diff·코드 편집 축에서 소멸**(§1.1). 웹 컨텍스트를 지나지 않으므로 재사용할 트랜스포트도,
넓힐 브리지 method도, 금지할 새 origin도 없다. 이 서술들은 **마크다운 축에서는 계속 유효**하다(file-panel 소유).

**목록이 웹이 아닌 이유.** 아키텍처 B(“chrome은 Zig+GPU, WKWebView는 콘텐츠만” — [file-panel.md](file-panel.md) §1)를 그대로
따른다. 변경 목록은 트리·탭·사이드바 카드와 같은 계열의 chrome이고, 이미 GPU로 그리는 탐색기 트리 바로 위에 얹힌다. 목록을
웹앱으로 만들면 같은 컬럼 안에 GPU chrome과 웹 chrome이 섞여 룩·포커스·히트테스트가 이중이 된다. 대신 diff **본문**은 텍스트
편집기가 필요하므로 웹(CM6)이 맞다 — 경계는 “문서 내용이냐 아니냐”다.

제품 UI 요청을 자기 Unix socket으로 되돌려 보내지 않는다. socket 인증은 외부 프로세스 경계용이고, in-process bridge는 host가 surface에 결합한 grant를 검증한 뒤 같은 L2 dispatcher를 직접 호출한다. 이 구분으로 payload 복사·deadlock·자기 인증 우회를 피한다.

L2는 file descriptor, DispatchSource, FSEvents, child process, AppKit/WebKit 타입을 몰라야 한다. grant 판정·문서 상태·CAS 전이·DTO/error mapping은 `src/session/`의 순수 코어가 소유하고, 실제 파일·git·watch·process I/O는 `src/app` 공통 runtime 또는 `src/platform/macos` adapter가 주입한다. `check-boundaries`에 editor 코어의 platform import 금지를 추가한다.

### 3.1 kind와 trust 경계

**형태는 (a′)로 좁혀졌다**(§10.0) — 목록은 도크 뷰, 본문은 diff kind **파일 Term**이다. 따라서 이 절이 정하는 것은 새 surface
종류가 아니라 **파일 entry kind 하나**와 그 kind에 붙는 grant다.

- 파일 entry의 `EntryKind`([file-panel.md](file-panel.md) §2)에 `diff`를 additive로 더한다. 새 top-level `PanelKind`가 아니다 —
  FP16이 확인했듯 `PanelKind`는 `{markdown, browser}` 2값 = trust/config 선택자이고, 값을 더하면 Swift의
  `let trusted = (panelKind == 0)` 파생이 조용히 깨진다. `diff` kind는 `.markdown`(신뢰 shell)으로 파생한다.
- 목록 UI는 web이 아니라 GPU chrome이라 origin/CSP 결정이 아예 없다(§3).
- 별도 `.editor` surface(옛 (b)안)는 만들지 않는다. 되살릴 이유가 생기면 §10.0을 먼저 뒤집는다.

어느 쪽이든 아래 trust 경계는 동일하게 적용한다.

**정정: 마크다운 뷰어도 파일시스템을 만진다.** [file-panel.md](file-panel.md)의 파일 패널은 `.md`/`.html`을 `loadFileURL(allowingReadAccessTo:)`로 **읽고**(디렉터리 스코프), 열린 핀 경로 하나에만 `maru.file.write`로 **쓴다**(§3, write 스코프=열린 파일만). 즉 markdown은 "표시 전용/파일시스템 0"이 아니라 **경로가 고정된 읽기 + 좁은 쓰기**다. 여기서 진짜 신뢰 경계는 read/write 유무가 아니라 **범위**다.

신뢰 등급(범위 기준):

- **마크다운 뷰어(file-panel)**: 핀 파일 read(+ 좁은 write). 파일별로 열 때 확정, JS가 확대 불가.
- **read-only git diff**: 파일 write 없음. worktree/HEAD blob **read** + bounded `git_read`. → 신뢰 수준이 full editor보다 마크다운 뷰어에 가깝다.
- **editor(편집)**: 여기서 `file_write`가 붙는다. 이게 계단의 실제 단차다.

그러므로 **editor 파일 write op를 markdown/뷰어 route에 얹지 않는다**(범위 확대 금지). `browser`는 계속 untrusted이며 editor bridge와 `maru-app://` asset에 접근하지 못한다.

**레이아웃은 공유, trust는 분리(사용자 방향).** git diff·editor는 [file-panel.md](file-panel.md)의 전역 도크와 **동일한 시각 shell**(탭 스트립·헤더 밴드·파일 트리 = GPU chrome, 콘텐츠 rect = WKWebView)을 공유해 UX 일관성과 코드 재사용을 얻는다. 실제로 git diff는 도크의 **또 다른 콘텐츠 kind**(현행 `.md`/`.html` 옆)로 보는 게 자연스럽다. **다만 레이아웃 재사용이 trust 재사용을 뜻하지 않는다** — 같은 도크 안에서도 kind별 origin/CSP/grant는 위 계단대로 분리한다. 엔진은 **네이티브 등폭 GPU 뷰로 개정**됐고(§1.1 — 옛 서술 "CM6로 확정"), 도크 정합(a/b)만 §10.0 결정 항목이다. 이 문단의 "콘텐츠 rect = WKWebView"도 diff 본문 축에서는 개정 대상이다.

**origin 공유의 함정**: diff 파일 Term이 markdown 파일 Term과 같은 `maru-app://app` origin·같은 신뢰 shell 브리지를 공유하므로, **origin pin만으로는 "이 요청이 diff 리뷰냐 md 뷰어냐"를 구분할 수 없다**. 그래서 브리지 method가 `EditorGrant`를 요구하고, 그 grant는 native가 **그 파일 Term(surface_id)에 결합**한다 — md 뷰어 Term에는 `file_write`/`git_read`가 없고 diff/editor Term에만 있다. 즉 권한 구분은 origin이 아니라 **entry별 grant**가 한다. main frame + 신뢰 origin + top-level navigation 거부는 그대로 강제하고, md asset route로 이동해도 editor grant가 따라붙지 않게 한다.

### 3.2 브리지 확장과 grant — 핀 경로에서 grant-root로

editor는 file-panel의 **신뢰 shell origin 브리지를 그대로 쓴다** — editor op는 그 브리지의 **새 method**이고, 정책은 file-panel과 동일하게 Zig(L2)가 판정한다(control_bridge 현행 표면=`hello` 1개, 나머지는 전부 신규 — file-panel과 공유하는 신규 계약).

**미결(공유 결정 — file-panel FP4가 정한다)**: 현행 브리지는 **isolated `WKContentWorld` 전용**이고 page-world `window.maru`는 의도적으로 없다(§2). 그런데 CM6 웹앱이 브리지를 부르려면 ① 앱 JS를 isolated world에 태우거나(DOM은 공유되므로 CM6 마운트 가능) ② 신뢰 shell 문서에 한해 좁은 page-world shim을 노출해야 한다. §1 표의 PoC는 ②를 권장했다(기록). 이 선택은 file-panel `maru.file.read` 배선(FP4)이 처음 맞닥뜨리는 **공유 결정**이라 editor가 단독으로 정하지 않고 그 결과를 따른다 — 두 경우 모두 아래 grant 규칙은 동일하다.

**핵심 escalation**: file-panel의 `maru.file.*`는 **경로 인자가 없다** — 파일 Term을 열 때 핀된 **단일 경로** 하나에만 read/write한다(웹앱이 경로를 못 고르는 게 안전장치). 그런데 git diff 리뷰·편집은 **변경 세트의 여러 파일**을 열고 그 안에서 write해야 하므로, editor는 핀-단일-경로를 **`EditorGrant`(grant-root + 상대 경로)**로 넓힌다. 이게 §3.1 신뢰 계단의 실제 단차이며, 넓힌 만큼 경로 안전 규칙(아래)을 강제한다.

`EditorGrant`는 JS가 고르는 bearer nonce가 아니라 native host가 diff/editor **파일 Term** 생성 시 결합하는 리소스 권한이다.

```text
EditorGrant {
  surface_id,
  root_id,
  file_read,
  file_write,
  git_read,
  tool_execute,
}
```

규칙:

- 모든 요청은 bridge가 가진 `surface_id`와 native grant를 사용한다. JS가 root나 scope를 확대할 수 없다.
- `root_id`는 native가 열린 canonical root descriptor와 매핑하는 opaque id다. page에는 root 절대 경로나 descriptor를 권한 토큰처럼 주지 않는다.
- 경로는 root 기준 상대 경로만 받고 NUL, absolute path, `..`, symlink escape를 거부한다.
- `file_write`, `git_read`, `tool_execute`는 각각 분리한다. repo를 읽을 수 있다고 명령 실행까지 허용하지 않는다.
- request/result의 byte·item·time 상한, cancellation, surface close/revoke 시 terminal completion을 정의한다.
- push는 bounded editor event channel로만 전달한다. unbounded `evaluateJavaScript` 문자열 조립을 프로토콜로 삼지 않는다.

외부 CLI/agent가 같은 op를 쓸 때만 control-plane capability nonce를 사용한다. 제품 capability fd 실발급이 붙기 전에는 외부 file/tool op를 열지 않는다.

### 3.3 브리지 프로토콜과 생애주기

file-panel 브리지의 editor method도 임의 JS 객체 호출이 아니라 버전 있는 protocol로 고정한다(file-panel `maru.file.*`와 같은 규율을 공유하되, editor는 다중 파일·grant-root라 request가 무거워 상한·취소·epoch를 명시한다).

```text
EditorRequest {
  protocol_version,
  request_id,
  surface_id,
  method,       // file.open / file.save / diff.list / diff.open / git.* …
  params,
}

EditorResult = success | typed_error
```

- `surface_id`는 page 입력을 신뢰하지 않고 handler가 자신에게 결합된 값을 덮어쓴다.
- `request_id`는 surface 안에서 단조 증가하며 중복·이미 완료·취소 후 완료를 거부한다.
- method별 request/result byte, item, page, timeout 상한을 스키마와 테스트에 함께 둔다. E1 착수 전 실제 숫자를 확정한다.
- error는 최소 `invalid_request`, `unauthorized`, `outside_root`, `not_found`, `unsupported_encoding`, `too_large`, `binary`, `conflict`, `cancelled`, `tool_failed`, `internal_error`로 구분한다. 내부 경로·errno·프로세스 환경은 page에 그대로 노출하지 않는다.
- surface close, navigation, web-content process crash, workspace revoke 때 모든 pending request를 정확히 한 번 `cancelled`로 끝내고 adapter 작업도 취소한다. 늦은 callback은 새 surface/grant에 적용하지 않는다.
- page reload마다 bridge epoch를 새로 발급한다. 이전 epoch의 response/event는 버린다.
- push queue는 bounded이며 coalesce 가능한 diagnostic/watch 상태와 유실 불가 save completion을 구분한다. overflow를 조용히 drop하지 않는다.
- bridge DTO는 UTF-8 JSON을 쓰되 문서 bytes를 JSON string에 무제한 인라인하지 않는다. 상한 이하 UTF-8 text만 인라인하고, 이후 큰 payload transport는 별도 설계 전까지 거부한다.

### 3.4 예상 코드 배치 — L2 코어는 신규, 웹앱·브리지는 file-panel 확장

editor **L2 코어**(정책·상태)는 신규 파일로 나눠 `app_session.zig`/`MaruAppHost.swift` 재누적을 막되, **웹앱·브리지·도크 chrome은 file-panel 코드를 확장**한다(별도 트리를 새로 만들지 않는다).

```text
신규 — editor L2 코어 (엔진·플랫폼 무관)
  src/session/editor/
    protocol.zig           version/error/DTO/limit
    grant.zig              EditorGrant/path scope policy (핀→grant-root escalation)
    document_registry.zig  revision/owner/conflict/recovery state
    diff_model.zig         stable snapshot/status DTO + turn-base(§6.1)
  src/app/
    editor_runtime.zig     adapter orchestration/cancel/queue
  src/platform/macos/
    editor_file.zig        descriptor-relative file adapter (safe-save §5.1)
    editor_watch.zig       DispatchSource/FSEvents adapter
    editor_tool.zig        git/tool/LSP process adapter

신규 — 도크 소스 컨트롤 뷰 chrome (§3.5)
  src/session/
    scm_view.zig           뷰 상태(섹션 접힘·선택·스크롤)·행 모델·순수 레이아웃 계산

확장 — file-panel 소유 코드에 method/kind 추가 (신규 병렬 파일 아님)
  file-panel 신뢰 shell 브리지  += editor.*/diff.*/git.* method + EditorGrant 검증
  ~~file-panel 웹앱(web/, React) += diff 뷰(CM6 MergeView)~~ → **네이티브 등폭 뷰**(§1.1 개정)
  file-panel 웹앱(web/, React)  += 턴 타임라인(마크다운 축)
  파일 Term entry kind(file-panel §2) += diff kind
  도크 뷰 스위처(file-explorer.md) += 소스 컨트롤 뷰
```

`src/session.zig`는 editor L2 facade만 export한다. 브리지 method를 더하는 Swift 변경은 file-panel 브리지 어댑터(현행 `MaruAppHost.swift`의 bridge handler — FP4에서 분리될 수 있음)에 얹는다. 그 파일은 `build.zig` swiftc·swift-check에 이미 연결돼 있어 빌드 배선 신규가 없다. 실제 디렉터리를 추가하는 PR은 [project-structure.md](project-structure.md)와 [file-panel.md](file-panel.md)(브리지 method 표)를 같은 PR에서 갱신한다. app-global `DocumentRegistry`의 runtime owner는 per-window `AppSession`이 아니라 전 창이 공유하는 `AppRuntime` 계층에 둔다 — file-panel 도크는 창 안에서 전역(워크스페이스 무관)이고 도크 모델은 창(세션) 소유이므로, **여러 창의 도크가 같은 파일을 열 때** identity를 하나로 묶는 건 창 위 계층이어야 한다.

### 3.5 우측 도크 소스 컨트롤 뷰 (시각 구조·정보 계층)

**권한 경계.** 이 뷰는 **native chrome**이라 `EditorGrant`/`git_read`의 대상이 아니다 — 그 grant들은 *웹 브리지*가 넘는 경계를
게이트하는 장치이고(§3.2), 도크는 웹이 아니다. 사용자가 연 창에서 사용자의 저장소를 읽는 것이므로 추가 승인 계단을 만들지 않는다.
반대로 **diff 본문을 그리는 파일 Term은 웹**이므로 `diff.open`은 그대로 grant 게이트를 통과해야 한다. 이 비대칭이 §3 경계의
직접적 귀결이다.

**시각 구조 기준 = 사용자 제공 목업(2026-07-31).** 레퍼런스 앱의 코드·DOM은 사용하지 않고 **배치와 정보 계층만** 받아
maru GPU chrome으로 독립 구현한다([project-rules.md](project-rules.md) 레퍼런스 경계, [no-external-ref](pr-checklist.md)).
아래 구조는 그 목업을 Maru 용어로 옮긴 것이다.

```text
┌ 우측 도크(폭 조절·접기는 탐색기와 공유) ─────────────┐
│ [트리] [·] [브랜치] [체크]            [패널 토글]   │ ← 뷰 스위처(아이콘 줄)
├──────────────────────────────────────────────────┤
│ ⑂ PR #8443                        [검색] [⋯]     │ ← 헤더 1: 리뷰 대상
│ fix/terminal-test-print-crash                    │ ← 헤더 2: 현재 브랜치
│ → origin/main                       ↑3  [열기]   │ ← 헤더 3: upstream·ahead/behind
├──────────────────────────────────────────────────┤
│ ┌ 메시지 ─────────────────────────────┐          │ ← 커밋 메시지 입력(여러 줄)
│ └─────────────────────────────────────┘          │
│ [＋ 모두 스테이지                    ] [▾]        │ ← 주 동작 + 보조 메뉴
├──────────────────────────────────────────────────┤
│ ⌄ 변경 사항 1                          모두 보기 │ ← 섹션(접힘·개수·전체보기)
│   ▣ TablePeopleInput.js  apps/pc-…  +11 -11   M │ ← 행: 이름·경로·증감·상태
│ ⌄ 추적되지 않은 파일 3                 모두 보기 │
│   ▢ pos-connector        reference             U │
│ ⌄ 브랜치에 COMMIT 됨 4                 모두 보기 │
│   ▣ TerminalDetailInfo.js apps/mob… +6 -2     M │
│                                                  │
│ (남는 공간)                                       │
├──────────────────────────────────────────────────┤
│ › COMMITS                              [?] [↻]   │ ← 하단 접이식 섹션
└──────────────────────────────────────────────────┘
```

**뷰 스위처.** 도크는 지금 탐색기 하나만 담지만, 이 목업은 **같은 컬럼에서 뷰를 갈아 끼우는** 구조다. 그래서 도크 상단에
아이콘 줄을 두고 `탐색기 | 소스 컨트롤`을 전환한다(후속 뷰는 자리만 예약). 이는 새 도크를 만드는 것이 아니라 **하나의 도크가
여러 뷰를 갖는 것**이며, 폭·접기·`⌘⇧E` 왕복·포커스 축(`FocusOwner.file_tree`)은 그대로 공유한다. 뷰 선택은 창별 chrome 상태이고
workspace에 영속한다(탐색기로 되돌아오는 재시작을 강요하지 않는다).

**헤더 3줄의 출처와 경계**(명령은 2026-07-31 실측).

| 줄 | 내용 | 출처 | v1 |
|---|---|---|---|
| 1 | 리뷰 대상(PR 번호·제목) | **로컬 git 밖** — GitHub API/`gh` 필요 | **범위 밖**(§10.12) |
| 2 | 현재 브랜치 | `git symbolic-ref --short HEAD` | 포함 |
| 3 | **비교 기준 + ahead/behind** | `git rev-parse --abbrev-ref origin/HEAD` → `git rev-list --count --left-right <base>...HEAD` | 포함 |

**3줄의 기준은 `@{u}`가 아니라 기본 브랜치다.** 목업이 `→ origin/main`을 보여 주는데, PR 브랜치의 `@{u}`는 보통
`origin/<자기 브랜치>`라 그걸 쓰면 항상 `0 0`이 나온다(실측 확인). 리뷰가 알고 싶은 것은 "기본 브랜치 대비 내 브랜치"이므로
**`origin/HEAD`가 가리키는 기본 브랜치를 기준으로 쓴다** — 이 값은 네트워크 없이 로컬에서 읽힌다(실측: `origin/main`).
`origin/HEAD`가 없으면(clone 방식에 따라 없을 수 있다) 사용자가 기준을 고르게 하고, 그 선택을 workspace에 기억한다.
`@{u}`는 별도로 "push 됐는지"를 보여 주는 데만 쓴다.

**PR 헤더는 v1에 넣지 않는다.** 네트워크·인증·호스트별 API가 붙는 순간 이 문서의 경계(로컬 git read-only)를 넘고, 실패
모드(토큰 만료·rate limit·사설 호스트)가 리뷰 UI 전체의 신뢰도를 떨어뜨린다. 목업의 자리는 남겨 두되 v1은 2·3줄만 채우고,
PR 연동은 §10.12 결정 뒤 별도 슬라이스로 얹는다.

**섹션 모델.** 목업의 세 묶음은 git 비교 기준(§6)과 1:1로 대응한다 — 뭉개지 않는다.

| 섹션 | 비교 기준 | 상태 문자 | 기본 동작(행 클릭) |
|---|---|---|---|
| 에이전트가 방금 바꾼 것 | `마지막 턴 스냅샷 ↔ 작업트리` | `M`·`A`·`D`·`R` | 그 범위 diff 열기 |
| 스테이지된 변경 | `HEAD ↔ index` | `M`·`A`·`D`·`R` | index↔HEAD diff 열기 |
| 변경 사항 | `index ↔ worktree` | `M`·`D` | worktree↔index diff 열기 |
| 추적되지 않은 파일 | worktree 전용 | `U` | 파일 그대로 열기(비교 대상 없음) |
| 브랜치에 COMMIT 됨 | `merge-base(기본 브랜치) ↔ HEAD` | `M`·`A`·`D` | 그 커밋 범위 diff 열기 |

**기준을 못 잡으면 그 섹션만 숨긴다.** "브랜치에 COMMIT 됨"은 기본 브랜치가 있어야 계산되므로, `origin/HEAD`도 없고 사용자가
기준을 고르지도 않았으면 나머지 세 섹션만 보여 준다(오류로 취급하지 않는다). 그래서 이 섹션을 만드는 세 명령
(`merge-base`·`--name-status`·`--numstat`)은 **실패해도 목록을 깨지 않는다** — 실패를 목록 전체의 실패로 접으면
로컬 전용 저장소에서 아무것도 안 보인다.

범위는 **삼점**(`origin/HEAD...HEAD`)이다. 두 점(`..`)으로 물으면 기본 브랜치에 새로 들어온 커밋까지 "내가 바꾼
것"으로 잡혀 목록이 부풀어 오른다. 이 섹션 행의 diff는 `merge-base ↔ HEAD`이고 **양쪽 다 커밋**이라 작업트리를
읽지 않는다 — 왼쪽 커밋은 목록을 읽을 때 함께 받아 둔 merge-base 해시로 지정하며, 그 값은 **hex만** 받는다
(ref 이름이나 옵션처럼 생긴 문자열은 애초에 지정자로 만들어지지 않는다).

목업에는 "스테이지된 변경"이 비어 보이지 않지만(스테이지가 없는 상태), 섹션 자체는 4개가 정본이다. **개수가 0인 섹션은 숨긴다** —
빈 헤더 네 줄이 컬럼 위쪽을 잡아먹지 않게 한다. 섹션 접힘 상태는 뷰 상태로 기억한다.

**행의 정보 계층.** `아이콘 · 파일명 · 흐린 상대경로 · +N -N · 상태 문자` 순이고, 폭이 좁아지면 **경로가 먼저 말줄임**된다
(파일명·증감·상태는 끝까지 유지 — 셋이 스캔의 축이다). 말줄임은 chrome 공통 `appendEllipsizedTitle` 경로를 쓴다(한글 자모가
흩어지지 않게 — [chrome 셀 cluster 계약](grapheme-clustering.md)).

**증감 숫자는 목록에 필수다.** 그래서 §6의 `diff.list`는 `added_lines`/`removed_lines`를 선택이 아닌 **필수 필드**로 둔다
(`hunk_summary?`는 헝크 단위 요약이라 별개이고 계속 선택이다). 출처는 `git diff --numstat`이고(실측), **binary는 numstat이 `-\t-\t경로`로 표시**하므로 그대로 `bin`으로 옮긴다 —
`0/0`으로 거짓 표시하지 않는다. `status --porcelain=v2` 한 번으로 네 섹션의 상태 문자를 모두 얻지만 **증감은 들어 있지 않으므로**
`--numstat`을 staged·worktree 두 번 더 부른다(실측 확인). rename은 `--find-renames`가 필요하다.

**행 클릭 = 파일 Term 열기.** 파일 하나를 고르면 diff kind 파일 Term이 열리고 도크는 목록으로 남는다. **도크 안에서 diff를
그리지 않는다**(§3의 경계).

FP16의 "파일 1개 = 창당 Term 1개" 불변식과의 관계를 명시한다 — **유일성 키는 경로가 아니라 `(경로, kind, base)`다.** 같은
`README.md`를 읽기 모드로 보면서 그 파일의 diff도 함께 보는 것은 정상적인 리뷰 흐름이라, diff Term이 markdown Term을 빼앗거나
kind를 갈아 끼우면 안 된다. **base까지 키에 드는 이유는 같은 파일이 두 섹션에 동시에 있을 수 있기 때문이다**(`MM` — 스테이지한
변경과 아직 안 한 변경이 각각 있다). 섹션이 곧 기준이므로(§10.10) 그 둘은 서로 다른 비교이고, 하나가 다른 하나를 덮으면 사용자가
방금 누른 행이 아닌 것을 보게 된다. 이 확장은 FP16 불변식의 **예외가 아니라 키의 명시화**이며, 구현 시
[file-panel.md](file-panel.md)의 유일성 조회 지점과 함께 갱신한다(그 문서가 키의 단일 출처다).

**diff Term은 workspace에 저장하지 않는다.** diff는 디스크 파일이 아니라 **그 시점 git 상태의 비교 결과**다. 다음 실행에서
되살리면 저장할 때 보던 화면과 다른 것을 같은 것처럼 보여 준다(그 사이 stage·commit·checkout이 있었을 수 있다). 되살릴 값이
아니라 다시 계산할 값이므로, 복원 대신 소스 컨트롤 목록에서 다시 연다. writer가 diff entry를 건너뛰고 reader도 `diff` kind
이름을 받지 않는다 — 손으로 쓴 파일이 복원 못 할 상태를 만들지 못하게 한다. (저장이 필요해지면 base를 함께 적어야 하므로
workspace 포맷 개정과 같이 다룬다.)

**주 동작 버튼.** 목업의 `＋ 모두 스테이지`는 **write 동작**이라 `git_read` grant 밖이다. 읽기 전용 v1(E1)에서는 이 버튼과 커밋
메시지 입력을 **표시하지 않는다** — 누를 수 없는 버튼을 띄워 두는 것보다 없는 편이 정직하다. stage/unstage/commit이 들어오는
단계(§9 후속 backlog)에서 함께 켠다. 그 전까지 도크는 "무엇이 바뀌었나"를 보여 주는 읽기 표면이다.

**하단 `COMMITS` 섹션.** 커밋 목록(그래프가 아니라 선형 목록)을 접이식으로 둔다. v1 범위 밖이며 자리만 정의한다 — 턴 타임라인
(§6.1)과 표시 위치가 겹치므로, 둘을 같은 하단 섹션의 두 모드로 둘지 별도로 둘지는 §10.11과 함께 정한다.

**빈 상태.** ⑴ git 저장소가 아님 → `git 저장소가 아닙니다`와 탐색기 뷰로 돌아가는 힌트. ⑵ 저장소지만 변경 0 →
`변경 사항 없음`. ⑶ unborn(첫 커밋 전) → 섹션은 `추적되지 않은 파일`만 나온다. 셋 다 오류가 아니라 정상 상태이므로 경고색을
쓰지 않는다.

**목록은 스스로 갱신된다.** `<repo>/.git`을 감시해 stage·commit·checkout을 잡고, 작업트리 파일 변경도 같이 본다.
폴링하지 않는다 — 안 보는 화면 때문에 프로세스를 띄우지 않고, 이벤트가 몰려도 진행 중이면 건너뛴다. **작업트리만
감시하면 안 되는 이유**는 `git add`가 작업트리를 안 건드리고 index만 바꾸기 때문이다.

**섹션은 기본 10행까지 보여 주고 남으면 `모두 보기 (N개 더)`를 낸다.** 변경이 수백 개면 한 섹션이 첫 화면을 다
먹어 나머지 섹션이 **있는지조차 모르게** 된다(스크롤이 있어도 마찬가지다 — 사람은 첫 화면으로 판단한다). 그래서
섹션마다 자리를 나눠 주되 **잘렸다는 사실을 행으로 말한다** — 조용히 자르면 사용자는 자기가 바꾼 파일이 없어졌다고
읽는다. 섹션 헤더의 개수는 언제나 **전체**이고, 그 행은 **숨은 수**를 말한다. 누르면 그 섹션만 전부 펴고, 상한 안이면
그 행을 아예 내지 않는다(눌러도 아무 일 없는 컨트롤을 두지 않는다). 접힘과 마찬가지로 **행 모델 단계**에서 자른다 —
렌더만 자르면 화면에 없는 행이 클릭 좌표 계산에 남아 누른 것과 열리는 것이 어긋난다.

**목록 chrome.** 첫 줄은 브랜치 헤더(브랜치 · upstream 대비 ahead/behind)다. 섹션 헤더를 누르면 접히고, 접어도
개수는 남는다(몇 개가 숨었는지 모르면 접는 의미가 없다). 접힘은 **행 모델 단계**에서 처리한다 — 렌더만 숨기면
화면에 없는 행이 클릭 좌표 계산에 남아 누른 것과 열리는 것이 어긋난다. 파일 아이콘은 탐색기와 같은 분류기를 쓰고,
선택한 행은 강조해 지금 보고 있는 비교를 남긴다. 목록 스크롤 상태는 탐색기와 **따로** 갖는다.

**diff 본문의 시각 언어.** 왼쪽은 삭제(빨강)·오른쪽은 추가(초록)이고, 줄 전체에 옅은 색을 깔고 바뀐 글자만 진하게
겹친다(GitHub과 같은 관례 — 리뷰어가 새 언어를 배우지 않게). 색은 **터미널 팔레트에서 파생**한다(`--maru-diff-*`,
syntax 하이라이트와 같은 배관) — 테마를 바꾸면 diff도 따라와야 한 창 안에서 색 언어가 갈리지 않는다. 색만으로
구분하지 않도록 바뀐 줄 왼쪽에 색 띠를 함께 둔다. 줄 번호는 필수이고, **각 편집기가 자기 안에서 스크롤**한다 —
바깥이 스크롤하면 가로 막대가 문서 맨 아래에 생겨 긴 줄을 볼 수 없다. 세로 위치는 두 편집기 사이에서 맞춘다.

**포인터는 뷰별로 갈린다.** 도크 rect는 뷰가 공유하지만 그 안의 조작은 공유하지 않는다 — 탐색기 전용 동작(행 활성화·
폴더 선택 다이얼로그·배경 컨텍스트 메뉴·트리 스크롤·트리 스크롤바·트리 포커스 획득)은 **탐색기 뷰에서만** 탄다. 좌표가
같은 rect 안이라는 이유로 타면 소스 컨트롤 행을 누른 것이 폴더 선택 창이 된다(실측). 다른 뷰의 클릭은 도크가 소비하되
아무 동작도 하지 않는다 — 행 클릭의 diff 열기는 diff 뷰가 생길 때 붙인다(위 표). 뷰 전환 바는 언제나 트리보다 먼저 본다.

**경계 상태의 실측 결과(2026-08-01).** 아래는 실제 저장소를 만들어 확인한 것이고, 각 줄이 코드의 분기와 1:1이다.

| 상태 | git이 주는 것 | 목록 | 행 클릭 |
| --- | --- | --- | --- |
| 병합 충돌(`u UU`) | index에 stage 0 **없음**, numstat이 같은 경로에 여러 줄(첫 줄 `0 0`) | **변경 사항에만** `U`, 증감 자리는 빈다 | `HEAD ↔ 작업트리` — 충돌 표시를 그대로 본다 |
| 하위 모듈(`S...`, mode 160000) | blob 없음, 작업트리 쪽은 디렉터리 | 경로만(증감 없음) | 열지 않고 "하위 모듈은 비교를 표시하지 않습니다" |
| unborn(첫 커밋 전) | `# branch.oid (initial)`, merge-base 실패 | 브랜치 이름은 나오고 추적되지 않은 파일만 | 평소와 같다 |
| 링크 워크트리(`.git`가 파일) | `rev-parse --show-toplevel` 정상 | 평소와 같다 | 평소와 같다 |
| rename(`2 R.`) | 새 경로 + 옛 경로 | 새 경로 | 왼쪽은 **옛 경로**로 읽는다 |
| 비ASCII 경로 | 기본값이면 C-quote | `core.quotePath=false`로 원문 | 원문 경로로 읽는다 |

**충돌을 "스테이지된 변경"에 넣지 않는 이유**: 스테이지된 것이 아니라 해결되지 않은 상태다. 양쪽 섹션에 같은 파일을
두 번 띄우면 "일부만 스테이지한 파일"(`MM`)과 구분되지 않는다. **충돌·하위 모듈의 증감을 비우는 이유**: numstat의
첫 줄(`0 0`)을 그대로 쓰면 방금 충돌한 파일이 "안 바뀐 파일"로 보이고, 하위 모듈은 커밋 포인터라 줄 수 자체가
의미가 없다.

**말할 수 없는 상태를 "읽는 중"으로 위장하지 않는다.** 읽기가 끝나지 않는 것과 읽을 수 없는 것은 사용자에게 전혀 다른 일이다.

| 상태 | 안내 | 판정 |
| --- | --- | --- |
| git CLI 없음 | `git이 설치되어 있지 않습니다` | 실행 파일 후보를 다 봐도 없음(§6) — **실행을 시도하지 않는다** |
| 읽기 실패 | `git 읽기에 실패했습니다` | 명령이 0이 아닌 코드로 끝남. 직전 성공 목록은 버린다(다른 시점과 섞지 않는다) |
| 읽는 중 | `읽는 중…` | 요청이 실제로 떠 있는 동안만 |

실패는 화면에 남는다 — 뷰를 다시 선택하면 재시도한다. 자동 재시도는 넣지 않는다(같은 이유로 계속 실패할 명령을 매 프레임
돌릴 이유가 없다). git stderr는 어떤 상태에서도 화면·로그에 싣지 않는다(§6).

**갱신 시점.** 목록은 폴링하지 않는다. ⑴ 도크 뷰가 소스 컨트롤로 바뀔 때, ⑵ 파일 Term 저장 성공 뒤, ⑶ 창이 다시 포커스를
받을 때, ⑷ 사용자가 헤더 새로고침을 누를 때 다시 읽는다.

**저장소 전체 watcher는 v1에 넣지 않는다.** §5.2의 watcher는 *열린 문서의 디렉터리*를 보는 것이고, worktree 전체를 보는 것은
다른 비용 문제다 — 대형 저장소·`node_modules`·`.git` 내부 churn(index.lock·objects)이 이벤트를 쏟아 낸다. 에이전트가 파일을
바꾸는 동안 목록이 저절로 갱신되는 것은 분명 바람직하지만, 그건 **감시 범위·필터·coalesce를 따로 설계해야 하는 별도 슬라이스**다.
v1은 위 네 시점으로 충분하고, 그중 ⑶이 "터미널에서 에이전트가 일하고 도크로 돌아온다"는 실제 흐름을 덮는다.

## 4. 문서 권위와 저장 CAS

> **2026-08-09 개정 — 이 절의 전제가 바뀌었다.** 아래는 "native가 전체 text 정본을 보유하지 않는다"를 전제로 쓰였으나, [native-editor.md](native-editor.md) §2·§3.0이 **버퍼를 L2에 두어 정확히 그 정본을 만든다.** 두 귀결이 따라온다 — ⑴ **`writable CM6 owner surface 하나` 제약이 diff·코드 편집 축에서 소멸**하고, 같은 문서를 두 뷰가 공유할 수 있다([native-editor.md](native-editor.md) §2.4가 그 계약을 소유하며 `file-panel.md` §1 불변식에 명시 명령 예외가 붙는다), ⑵ **문서 text·undo·selection의 소유자가 CM6가 아니라 L2 모델**이다. 아래 `DocumentState`의 revision·fingerprint·conflict 3축은 **엔진과 무관하게 그대로 유효**하다. 마크다운 축에서는 원문이 계속 맞다.

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

## 6. bounded diff/git API

전체 저장소의 before/after blob을 한 응답에 싣는 `diff.read`는 사용하지 않는다.

- `diff.list`: `{path, old_path?, status, binary, before_size, after_size, added_lines, removed_lines, hunk_summary?}` metadata를
  pagination해서 반환한다. **`added_lines`/`removed_lines`는 필수**다 — 도크 목록 행이 항상 `+N -N`을 그리기 때문이고(§3.5),
  출처인 `git diff --numstat`이 그 값을 공짜로 준다. binary는 numstat이 `-`를 주므로 숫자 대신 `binary=true`로 옮긴다.
- `diff.list` 첫 응답은 `diff_snapshot_id`와 stable cursor를 발급한다. pagination 중 index/worktree가 바뀌면 서로 다른 시점의 목록을 섞지 않고 `stale_snapshot`으로 다시 시작하게 한다.
- `diff.open`: `{diff_snapshot_id, path}`로 한 파일의 original/modified를 명시적 byte 상한 안에서 반환한다. 너무 크거나 binary면 typed `too_large`/`binary` 결과와 external-open fallback을 준다.
- UI bridge와 외부 socket은 같은 의미 DTO를 쓰되 각각의 transport 상한 안에서 chunk/page한다.
- `git.stage`/`unstage`는 저장·conflict 모델이 안정된 후 별도 write capability로 추가한다.
- `git discard`는 파괴적이고 복구 의미가 달라 초기 roadmap에서 제외한다. 후속으로 하더라도 명시 확인·복구 경로를 별도 설계한다.

상한은 raw blob뿐 아니라 UTF-8 decode와 JSON escape 뒤 전송 bytes, 파일 수, hunk 수, line length를 각각 센다. 압축/escape 전 크기만 검사해 메모리 증폭을 허용하지 않는다.

**git 읽기 승인은 workspace root 승인에 포함된다(§10.4 결정).** 탐색기로 연 폴더는 사용자가 이미 고른 root이므로 그 안의
git 읽기를 위해 **사용자에게 다시 묻지 않는다**. 읽기 범위는 그 root 아래로 제한되고, root 밖 저장소를 읽으려면 그 root를
먼저 열어야 한다. **`EditorGrant.git_read` 플래그 자체는 그대로다**(§3.1·§3.2) — 그것은 사용자 확인 절차가 아니라 *웹
브리지가 넘는 경계*이고, diff Term과 md 뷰어 Term을 가르는 수단이다. 바뀌는 것은 그 플래그를 **root 승인에서 파생시킨다**는
점뿐이다. **쓰기(stage/unstage/discard)는 끝까지 별도 capability**다(§10.14).

Git 의미와 실행 안전도 E1 전에 고정한다.

- 비교 기준을 `HEAD↔index`, `index↔worktree`, `HEAD↔worktree`로 명시하고 staged/unstaged/untracked를 한 상태로 뭉개지 않는다.
- rename/copy, type change, mode-only change, symlink blob, deleted file, unmerged conflict(stage 1/2/3), submodule gitlink, empty/unborn repository를 typed status로 표현한다.
- `.git` directory뿐 아니라 worktree의 `.git` file과 bare/unborn 상태를 처리한다. 현재 sidebar branch 탐색의 best-effort 구현을 diff root 탐색에 재사용하지 않는다.
- `GitAdapter`는 shell이나 사용자 alias를 거치지 않고 승인된 git executable을 argv로 직접 실행한다. executable path/version을 기록하고 PATH hijack, pager/editor prompt, credential/network 접근이 없는 read-only 명령만 `git_read`로 허용한다.
- **실행 파일 결정**: 고정 경로 하나를 박지 않는다 — `/usr/bin/git`만 쓰면 homebrew·수동 설치 git을 쓰는 기기에서 사용자가
  셸에서 쓰는 것과 **다른 git**을 돌리게 된다. PATH 항목 → 통상 설치 위치 순으로 후보를 훑어 **실행 가능한 정규 파일 하나를
  절대경로로 확정**하고, 그 절대경로를 argv[0]로 실행한다. PATH 탐색은 후보를 고를 때만 쓰고 **exec에는 절대 쓰지 않는다**
  (`execvp`·셸 경유 없음 = PATH hijack 차단은 유지). 상대경로·빈 PATH 항목은 후보에서 배제한다(앱 cwd의 `git`을 실행하지
  않는다). 후보가 하나도 없으면 **실행을 시도하지 않고** git 미설치로 표시한다(§3.5).
- **macOS shim 예외**: `/usr/bin/git`은 진짜 git이 아니라 개발자 도구 shim이라, 도구가 없는 기기에서 실행하면 git이 도는 대신
  설치 모달이 뜬다. 파일 목록을 보려던 조작이 시스템 설치 창을 띄우는 건 사용자가 시킨 적 없는 일이므로, 도구가 실제로 있다는
  증거(명령행 도구·Xcode 툴체인의 git이 실행 가능)가 없으면 이 경로는 후보에서 뺀다.
- read-only diff 호출은 repository config가 외부 프로세스를 실행하지 못하도록 external diff/textconv/pager와 interactive prompt를 명시적으로 끈다. config·attributes·filter가 실행되는 각 명령을 adversarial repo fixture로 확인한다.
- git stderr에는 path/user/repo 정보가 있으므로 raw로 page/trace에 전달하지 않는다.
- **루트 밖 접근은 세 겹으로 막는다(2026-08-01).** ⑴ **구조**: 브리지 `diff.open`은 경로 인자를 받지 않는다 — 무엇을
  읽을지는 그 Term의 entry가 정하므로 웹이 대상을 고를 수 없다(가장 강한 방어이고, 나머지 둘은 **우리 자신의 버그와
  이상한 git 출력**에 대한 심층 방어다). ⑵ **문자열**: 저장소 루트 기준 상대경로만 받는다(`session.repo_path` —
  절대경로·`..`/`.` 세그먼트·빈 세그먼트·NUL 거부). ⑶ **열기**: 작업트리 파일은 루트에서 시작해 경로 요소마다
  `O_NOFOLLOW`로 내려간다 — 마지막 요소만 막으면 중간 디렉터리가 링크일 때 밖이 열린다(실제 링크가 든 저장소로 확인).

  **왜 이 경계를 두는가**: diff는 남의 코드를 보려고 만든 기능이라 **적대적일 수 있는 저장소를 여는 것이 정상 사용**
  이고, 읽은 내용은 신뢰 origin 웹뷰로 들어간다(마크다운 sanitizer 우회 같은 결함이 브리지 호출로 이어질 수 있는
  자리다 — §3.1). 사용자에게 무엇을 더 묻는 장치가 아니다(§10.4에서 git 읽기 승인은 root 승인에 포함됐다) —
  **우리 코드의 사고 반경**을 사용자가 연 폴더로 묶는 장치다. 참고로 VS Code·Zed는 이런 읽기 경계를 두지 않는다
  (그쪽 경계는 실행 신뢰다) — 우리가 다른 이유는 본문이 웹뷰에서 그려지기 때문이다.
- 이후 stage/unstage는 clean/smudge filter, index lock, partial hunk stale context를 별도 보안·CAS 문제로 다룬다.

### 6.1 에이전트 턴 diff (agent-turn base)

git 기준(HEAD/index/worktree) 외에 **"에이전트가 방금 바꾼 것"**을 diff base로 제공한다. 이는 git 개념이 아니라 **턴 경계 스냅샷**이 필요하다. Codex가 "Last turn"을 쉽게 하는 건 자기가 에이전트 런타임이라서인데, **maru는 에이전트를 소유하지 않고도** [agent_transcript.zig](../src/session/agent_transcript.zig)로 **claude·codex 양쪽 세션 transcript를 이미 파싱**해 턴 경계(working/idle/interrupted)를 안다. 따라서 maru의 turn-base는 **호스팅하는 아무 에이전트에나** 적용되는, Codex보다 넓은 기능이 될 수 있다.

**검증된 토대(실측):**

- **턴 인식은 이미 있다(프로덕션).** `agent_transcript.zig`의 `parseClaudeTail`/`parseCodexTail`이 `AgentState{running, idle, interrupted, unknown}`를 내고, `agent_session.zig`가 상태줄·idle 알림에 쓴다. working→idle 전이 = "턴 완료" 감지는 그대로 얻는다.
- **턴 스냅샷 메커니즘도 실증됨.** `git stash`가 쓰는 기법 — 임시 index로 `GIT_INDEX_FILE=… git read-tree HEAD && git add -A && git write-tree` → tree OID 하나(변경 blob만 기록·값쌈). 이후 `git diff <tree>`가 그 턴 이후 변경. **실제 index·작업트리 무변형**을 별도 fixture로 확인했다. tree OID는 git 히스토리 무관 content 스냅샷이라 중간 commit/rebase가 있어도 유효.

**신규 구현 필요(정직 — "공짜 재사용"이 아니다):**

- **⚠️ 현행 파서는 tail(끝 64KB)만 읽어 "현재 상태 하나"만 낸다** — 성능상 전체를 안 읽는 게 설계 의도(agent_session.zig `tail_window`/`tail_cap`). 따라서 **턴 타임라인(1턴 전·2턴 전…)은 전체 transcript를 파싱해 턴을 열거하는 신규 코드가 필요**하다. 단 jsonl은 모든 턴이 쌓인 append-only 로그라 **데이터는 이미 있다**(데이터 부재가 아니라 코드 부재).
- **턴 경계에서 스냅샷 캡처 배관** — 전이 감지는 폴링으로 있으나 "그 순간 write-tree"는 신규.
- **스냅샷 = 턴별 ring buffer** → "마지막 턴"뿐 아니라 N턴 전·임의 턴·범위가 같은 메커니즘(UI는 턴 타임라인 스크러버). 각 스냅샷을 전체-파싱으로 얻은 턴 identity와 짝짓는다.

**경계·정직:**

- **스냅샷 방식(결정 대상)**: ① `git write-tree`(값쌈, 전체 트리) vs ② 에이전트가 만진 파일만(transcript 편집 경로/FSEvents로 좁힘 — 대용량 repo 유리). 임시 index는 repo 밖(maru shadow)에 둔다(repo 안에 두면 그 파일이 diff에 잡힌다 — fixture에서 확인).
- (a) maru가 그 순간 transcript를 추적 중이어야 스냅샷이 찍힌다(상시 추적하나 캡처 배관은 신규). (b) "턴"=한 assistant 응답 단위라 그 안의 여러 편집이 한 turn diff로 묶인다(Codex "Last turn"과 동형). (c) 보관 개수·세션 경계·저장 위치는 결정 사항.
- **실현성 판정**: showstopper가 될 뻔한 두 관문(에이전트 턴 인식·스냅샷 안전성)이 실측으로 닫혔으므로 **불확실한 연구가 아니라 평범한 구현**이다.
- 이 base는 **read 전용**이라 `git_read`와 무관한 별도 위험이 없다(스냅샷 캡처는 write-tree/파일 read뿐, 작업트리 변형 없음). 다만 tree OID 캡처가 index를 건드리지 않도록 **임시 index**(`GIT_INDEX_FILE`)로 격리한다.

**결정(2026-08-01, §10.11 재결정)**: E1 안에서 구현한다. 스냅샷은 **①write-tree**이고, 보관은 **저장소당 링 8개**다.

**구현 계약(실측으로 확인 — 2026-08-01):**

- **턴 경계 = `running → idle`.** `blocked`(사용자에게 묻는 중)는 완료가 아니다 — 답하면 같은 턴이 이어지므로,
  여기서 찍으면 "마지막 턴"이 "마지막 질문 이후"라는 다른 뜻이 된다. `unknown`도 아니다(화면을 못 읽는 상태라
  "안 돈다"가 아니라 "모른다"이고, 그걸 턴 끝으로 삼으면 기준이 턴 중간으로 어긋난다).
- **스냅샷은 임시 index로만 돈다**: `read-tree HEAD` → `add -A` → `write-tree`를 `GIT_INDEX_FILE`을 걸어 실행한다.
  실측으로 **진짜 index·작업트리가 안 바뀜**을 확인했다(`.M`·`? b.txt` 그대로). 상속 환경의 `GIT_INDEX_FILE`은
  **항상 버린다** — 남기면 스냅샷이 아닌 명령까지 남의 index에 쓴다.
- **임시 index는 저장소 밖**(`~/.cache/maru/turn-index-<창>`)에 둔다. 안에 두면 그 파일 자체가 `add -A`에 잡혀
  스냅샷이 자기를 포함한다. 창마다 다른 파일을 쓴다(같은 파일을 두 창이 쓰면 한쪽 스냅샷이 다른 쪽 작업트리를 담는다).
- **비용**: 첫 스냅샷 292 ms, 임시 index를 재사용하면 **24 ms**(index 64 KB). 매 턴 돌려도 되는 값이다.
- **비교도 임시 index로** 한다: 비교 시점의 작업트리를 다시 반영한 뒤 `diff --cached <tree>`로 본다 — 작업트리와
  직접 비교하면 추적되지 않은 파일이 빠진다(실측).
- **같은 tree가 연달아 오면 링에 안 넣는다.** 파일을 안 건드린 턴까지 쌓으면 "마지막 턴"이 빈 비교가 된다.
- **저장소가 바뀌면 링을 버린다.** 다른 저장소의 tree로 비교하면 전부 삭제로 보인다.
- 화면에서는 **다섯 번째 섹션**("에이전트가 방금 바꾼 것")이고, 행 클릭 시 `스냅샷 tree ↔ 작업트리`다 —
  "섹션이 곧 기준"(§10.10)에 그대로 얹힌다(base 선택기가 없는 이유이기도 하다).

## 7. 빌드·에디터 엔진·CSP gate

### 7.1 툴체인

- self-host asset만 사용하고 CDN은 금지한다.
- **웹 스택은 file-panel을 그대로 따른다 — 현재 React + Tailwind + shadcn/ui다**([file-panel.md](file-panel.md) §2.1,
  2026-07-29 사용자 결정). 이 문서 초판의 "UI 프레임워크를 도입하지 않는다(vanilla TS)"는 그 결정으로 **무효**다. 단
  **도크 변경 목록은 애초에 웹이 아니라 GPU chrome**이므로(§3) 이 결정의 영향 범위는 diff 본문 화면뿐이다. CM6·remark류는
  프레임워크가 아니라 **DOM 마운트 라이브러리**라 이 결정과 직교하며, 편집기를 React 컴포넌트로 다시 쓰지 않는다.
- **에디터 엔진 = 네이티브 등폭 GPU 뷰(2026-08-09 개정, §1.1).** diff 본문에 CM6·`@codemirror/merge`를 쓰지 않으므로 **이 절의
  editor/diff 번들 증분은 0이다.** 아래 세 항목은 개정 전 계획이며, **마크다운 소스·리치 편집이 계속 쓰는 CM6 스택 자체는
  유효**하다(file-panel 소유). 즉 웹 번들은 유지되지만 editor가 거기에 더하는 것이 없다.
  - ~~에디터 엔진 = CodeMirror 6 (§1.1a 확정, 제품 출하 중). git diff는 `@codemirror/merge` `MergeView`/`unifiedMergeView`로
    구현한다. CM6는 file-panel 소스 모드로 이미 제품에서 돌고 있으므로(§2) editor/diff는 그 스택에 `@codemirror/merge`만
    더한다(별도 Monaco 엔진·별도 번들 없음).~~
  - ~~CM6는 필요한 lang/merge/theme extension만 import하고, output asset을 검증한다.~~ (Monaco의 `editor.api`/언어
    contribution/worker 배선·barrel 회피가 무의미하다는 서술은 엔진 개정 뒤에도 유효하다 — Monaco는 어느 쪽으로도 채택되지 않는다.)
  - ~~worker. CM6 MergeView diff는 워커가 없다(§1.1a 실측). 향후 LSP/무거운 계산에 워커를 붙이면…~~ **네이티브 경로에서 웹 워커
    개념은 적용되지 않는다.** LSP·무거운 계산의 스레딩은 [io-render-threading.md](io-render-threading.md) 규율을 따른다.
  - ~~zntc pin은 `0.1.4`로 이미 상향됐고 CM6가 번들된다(§2). editor가 더할 것은 `@codemirror/merge` 하나이며…~~ **editor가 더할
    web 의존은 없다.** zntc pin은 file-panel의 마크다운 스택 사정으로만 움직인다.

JS toolchain(zntc/`web/` Bun workspace)은 **FP2로 이미 도입 완료**됐으므로 editor는 툴체인을 새로 세우지 않는다(증분 = CM6 lang/merge extension + zntc pin 상향). bundle/RSS 예산 측정은 §7.4·§9에서 CM6 기준으로 확인한다.

### 7.2 CSP

`script-src 'unsafe-eval'`이나 remote source는 열지 않는다.

**결정은 이미 닫혀 있다(FP12b, 2026-07-22).** app origin은 `style-src 'self' 'unsafe-inline'`, render origin은 hash 핀이다
(§2). 그 완화의 이유가 바로 CM6 style-mod 주입이고, **MergeView도 같은 app origin에 마운트되므로 추가 CSP 작업이 없다.**

**왜 `'self'`나 hash로는 안 되는지**를 실측으로 남긴다(WKWebView, 동일 문서에서 `style-src`만 바꿔 측정 — 2026-07-31).

| `style-src` | 마크업 `<style>` | JS 생성 `<style>`+`textContent` | CSSOM `insertRule` | `style=` 속성 |
|---|---|---|---|---|
| (CSP 없음) | 적용 | 적용 | 적용 | 적용 |
| `'self'` | **차단** | **차단** | **차단**(`sheet`이 `null`) | **차단** |
| `'unsafe-inline'` | 적용 | 적용 | 적용 | 적용 |

`'self'` 같은 소스 표현식은 *외부* 스타일시트 로드에만 적용되고 인라인은 전혀 허용하지 않는다. CSSOM 우회도 통하지 않는다 —
`<style>` 자체가 차단되면 `sheet`이 `null`이라 `insertRule`을 부를 대상이 없다. style-mod는 문서 루트에서
`<style>`+`textContent` 경로를 타므로(`adoptedStyleSheets`는 ShadowRoot일 때만) hash 핀으로도 고정할 수 없다(내용이 런타임에
조립된다). FP12b의 결론과 같고, 이 표는 그 결론을 재확인한 기록이다.

**editor가 지킬 불변식 둘.**

1. **render origin의 hash 핀을 건드리지 않는다.** MergeView·diff 스타일이 격리 렌더 문서로 새면 sanitizer 우회 시 style 주입
   벡터가 열린다. diff는 신뢰 shell(app origin)에서만 그린다.
2. **`'unsafe-inline'`을 다른 origin으로 넓히지 않는다.** browser 패널·읽기 뷰는 그대로 둔다.

남은 확인은 CSP가 아니라 **MergeView가 app origin 밖으로 스타일을 내보내지 않는지**이며, E0.5A에서 함께 본다.

### 7.3 필수 semantic oracle

각 프런트 빌드의 자동 gate는 다음이다.

1. 산출물 재파싱과 asset/worker 누락·404 검사
2. module evaluation과 CSP violation 0 검사
3. CM6 semantic probe: 문서 text, 구문 highlight, MergeView diff chunk/문자 하이라이트, 진단 marker(있으면)
4. request/result 크기와 worker/process cleanup 검사
5. **도크 소스 컨트롤 뷰(§3.5)는 이 gate 밖이다** — GPU chrome이라 웹 oracle이 아니라 chrome 검증 경로(레이아웃 순수 계산
   단위 테스트 + 헤드리스 스크린샷)를 쓴다. 섹션 접힘·행 말줄임·빈 상태·개수 0 섹션 숨김이 그 대상이다.

Vite는 개발/비교 기준일 뿐 제품 runtime에 포함되지 않는다. Chromium도 제품에 추가하지 않는다. zntc↔Vite pixel 1:1 비교는 릴리스 qualification이나 디버그 artifact로만 사용하며 모든 PR의 필수 gate로 두지 않는다.

### 7.4 제품 WKWebView gate

Phase 0.5A 종료 조건은 실제 Maru `WKWebView`, `maru-app://`, editor CSP, 제품 asset resolver로 다음을 자동/수동 artifact와 함께 통과하는 것이다.

- editor text가 non-zero layout으로 실제 표시되고 screenshot에 포함됨
- caret/selection, ASCII insert/delete, undo/redo
- 한글 조합 중 preedit, 완성, NFD 입력 fixture, caret 이동, backspace/delete
- paste/copy, find, `Cmd+S`, Maru 전역 shortcut과 CM6 shortcut 충돌, first-responder 이동
- resize, backing scale, theme 전환, hide/show와 tab/window 이동 뒤 model·selection 보존
- diff decoration, marker, syntax token (CM6 MergeView는 워커가 없다(§7.1) — 워커 검증은 워커를 도입하는 시점에 이 목록에 복귀)
- page-world editor bridge allowlist, markdown/browser에서 bridge 부재
- CSP violation/console error/404 0, close/reload/crash 후 worker와 pending request 정리

E0.5A PR은 계획 명령 `mise run test-macos-editor-smoke`와 display opt-in `mise run macos-editor-smoke`를 실제 `.mise.toml`/development-commands에 추가한다. artifact는 `zig-out/maru-macos-editor-smoke/` 아래 최소 `editor.summary.txt`, `editor-dom.json`, `editor-snapshot.png`를 남긴다. summary는 engine/build identifier, CSP violations, console errors, worker count, text/caret/edit/IME/cleanup 결과를 machine-readable key로 기록한다. DOM artifact는 크기·role·상태만 담고 source text는 넣지 않으며, screenshot은 저장소의 synthetic fixture만 사용한다. 기존 Metal PPM은 WKWebView pixel을 포함하지 않으므로 WebKit `takeSnapshot` 또는 동등한 WKWebView snapshot 경로를 사용한다.

IME는 synthetic JS/AppKit event만으로 통과 처리하지 않는다. 자동 하니스는 DOM/model 상태를 고정하고, 종료 gate에는 실제 macOS 한글 입력기로 preedit→완성→caret→backspace를 수행한 수동 summary를 함께 요구한다.

**E0.5A 실측 결과(2026-07-31, 이 저장소·Apple Silicon).** `mise run test-macos-editor-smoke`가 제품 스킴 핸들러
(`MaruAppSchemeHandler`)·제품 CSP·실제 `WKWebView`로 하니스를 로드해 남긴 값이다.

| 항목 | 결과 |
| --- | --- |
| MergeView·unifiedMergeView 표시 | non-zero layout으로 렌더(스크린샷에 좌우 비교·gutter·Accept/Reject 확인) |
| chunk·마커 | split 3 · unified 3, gutter 마커 존재 |
| accept/reject | accept 후 chunk 3→2, reject가 해당 구간을 원본으로 되돌림 |
| CSP 위반 · console 오류 | **0 · 0** |
| CSP 실제 적용 확인 | `eval` 차단 관측(`script-src|eval`) — 위반 0이 헤더 부재 때문이 아님을 증명 |
| MergeView 스타일 유출 | 없음(모든 `<style>`이 하니스 문서 소유, iframe 0) |
| web content 프로세스 RSS | 1개 **45.7 MB** · 2개 **91.1 MB** · 4개 **182.4 MB**(정확히 선형) |
| 유휴 CPU(화면 밖) | 1·2·4개 모두 **0%** |
| 닫은 뒤 회수 | **0.6~0.7초**에 프로세스·메모리 전부 회수(잔존 0) |

**측정에서 배운 것 둘.**

- **선형 증가는 configuration을 뷰마다 새로 만든 결과다.** 하니스는 diff 파일 Term이 각자 패널인 제품 형태를 따라
  뷰마다 별도 `WKWebViewConfiguration`을 쓰고, 그래서 프로세스도 뷰당 하나다(4개=4프로세스). diff를 여러 개 여는
  사용이 흔하면 E1에서 **process pool 공유 여부**를 별도로 정해야 한다 — 공유하면 메모리는 줄지만 격리가 약해진다.
- **"위반 0"은 그 자체로 근거가 아니다.** CSP 헤더가 빠져도 위반 수는 0이므로, 게이트는 모든 계측을 마친 뒤 반드시
  차단돼야 하는 동작을 일부러 시도해 CSP가 살아 있는지와 수집기가 동작하는지를 함께 확인하고, 아니면 초록을 주지 않는다.

**아직 닫히지 않은 것: 실제 한글 입력기 수동 확인.** 위 표는 자동 하니스 결과이고, 이 문서가 요구하는 대로 synthetic
이벤트만으로 IME를 통과 처리하지 않는다. preedit→완성→caret→backspace 수동 summary가 남아 있다.

이 gate는 이제 **CM6 MergeView 기준으로 좁혀진다.** Monaco 하니스의 RED는 엔진 교체로 무효가 됐고, **CM6 편집 경로는 file-panel
소스 모드로 제품 WebKit에서 이미 검증됐다**(§2 — 텍스트·caret·편집·한글 IME가 출하 중). 따라서 이 gate가 **처음** 검증하는 것은
`@codemirror/merge`의 MergeView/unifiedMergeView 렌더·chunk 마커·accept/reject 상호작용과 그 CSP 영향(§7.2)이다. MergeView가
예상 밖으로 막히면 대안(예: 자체 diff 렌더)을 같은 gate로 비교한다.

## 8. 포맷·린트·LSP

### 8.1 workspace tool execution

formatter/linter와 LSP는 모두 저장소의 config/plugin/binary를 실행할 수 있다. `tool_execute`가 없는 workspace에서는 자동 실행하지 않는다.

- trusted workspace 확인과 도구별 allowlist/해결된 executable 표시
- shell 없이 argv 실행, canonical cwd=root, 최소화한 environment
- timeout, stdout/stderr byte 상한, child/process-group 상한, cancellation/kill/reap
- config discovery 결과와 실제 executable/version을 사용자 및 trace에 노출
- 포맷 결과는 곧바로 저장하지 않고 현재 revision에 대한 text edits로 반환
- tool이 root 밖 파일을 읽거나 쓰는 것을 OS 수준에서 sandbox하지 못하는 초기 버전의 한계를 확인 UX에 명시

포맷/린트를 “LSP보다 가볍다”는 이유로 보안 단계를 앞당기지 않는다. 필요성이 확인되면 저장 Phase 뒤 선택적으로 연다.

### 8.2 LSP seam

LSP는 다음 최소 seam만 요구한다.

- `didOpen/didChange/didSave/didClose`로 매핑 가능한 document revision event
- Content-Length framing을 control-plane ndjson과 분리한 transport
- server request/notification/response correlation, cancellation, restart/backoff
- diagnostic/completion/hover/definition/semantic-token의 bounded push
- workspace tool execution grant
- server→client `workspace/applyEdit`, `workspace/executeCommand`, file create/rename/delete, `window/showDocument`, 임의 URI open은 기본 거부하고 method별 사용자 승인/allowlist를 둔다.
- diagnostics/result에 root 밖 URI가 들어오면 표시와 파일 접근 권한을 분리한다. URI를 받았다는 이유로 grant가 확대되지 않는다.

TextMate, git staging, formatter는 LSP의 선행 조건이 아니다. 초기 syntax는 **CM6 내장 Lezer**(`@codemirror/language` + `@codemirror/lang-*`)로 시작하고, LSP semantic token이 부족하다는 측정이 있을 때만 TextMate/WASM을 재검토한다. (초판의 "Monarch"는 Monaco 토크나이저라 엔진 교체로 무효 — 정정.)

### 8.3 관측 가능성과 민감정보

editor event는 처음부터 하나의 domain schema를 공유하되 문서 원문을 기본 trace에 넣지 않는다.

- 최소 event: `editor.opened`, `editor.changed`(revision/byte count만), `editor.save-started`, `editor.save-completed`, `editor.conflict`, `editor.watch-invalidated`, `editor.tool-started/completed`, `editor.bridge-overflow`.
- path는 grant-relative 또는 익명화한 값만 artifact에 남기고 capability, full text, diff blob, diagnostic message 원문, tool stdout/stderr는 기본 제외한다.
- control-plane/bridge event를 trace에 넣는 PR은 먼저 [facade-contracts.md](facade-contracts.md)와 [trace-replay.md](trace-replay.md)의 event/redaction/replay 의미를 갱신한다.
- failure artifact를 fixture로 승격할 때 [project-rules.md](project-rules.md)의 공통 redaction guard를 사용한다. source code에 token이 bare text로 들어갈 수 있어 자동 guard만으로 충분하다고 간주하지 않고 사람 검토를 요구한다.
- E2E artifact는 semantic summary와 redacted screenshot을 기본으로 하고, 실제 사용자 repository를 자동 캡처하지 않는다.

## 9. 단계 계획과 종료 gate

기존 [control-plane.md](control-plane.md)의 Phase 7 웹 toolchain/markdown 계획과 번호가 충돌하지 않도록 editor는 `E` prefix를 쓴다. 구현 PR 하나가 단계 전체를 끝내는 것을 기본값으로 보지 않는다.

**file-panel과의 선후(§2 코드 대조 기준)**: 초판이 선행으로 적었던 FP 슬라이스(도크 모델·web 툴체인·도크 슬롯·브리지 read
배선·CM6 편집)는 **모두 완료돼 있다.** 즉 editor는 더 이상 file-panel을 기다리지 않는다. 남은 선후는 두 가지뿐이다.

- E1의 **도크 소스 컨트롤 뷰**(§3.5)는 도크에 **뷰 스위처**가 필요하다 — 지금 도크는 탐색기 하나만 담는다. 이 배관은
  [file-explorer.md](file-explorer.md)와 같은 PR에서 정합한다.
- E1의 **diff 파일 Term**은 파일 entry에 `diff` kind를 더한다 — `EntryKind`→`PanelKind` 파생과 mode 선택기(`modesForKind`)를
  함께 갱신한다([file-panel.md](file-panel.md) §2).

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
