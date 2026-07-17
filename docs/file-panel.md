# 파일 패널 (마크다운·HTML 뷰어/편집기 — 전역 도크)

로컬 `.md`/`.html` 파일을 maru 안에서 열람·편집하는 **전역 도크 파일 패널**의 단일 출처 문서다. WKWebView 합성·입력·web 특유 보안은 [web-panel.md](web-panel.md), 브리지 신뢰 게이트는 [control-plane.md](control-plane.md) §8.1, 파일 경로 링크 감지는 [link-detection.md](link-detection.md), 주소창 텍스트 편집 모델은 [text-field-editor.md](text-field-editor.md)를 단일 출처로 두고 재서술하지 않는다. control-plane §12 Phase 7 행(7a~7d)의 상세 분해가 이 문서다(§10 대응표).

> 결정은 2026-07-17 사용자 승인. 설계 전 코드 대조 검증(적대적 3축 + 대화 감사)을 거쳤고 본문 file:line은 그 시점 기준. **개정(같은 날)**: 초판의 "워크스페이스 내장 web Term" 호스팅을 **전역 도크**로 피벗 — 근거는 §1 첫 항목.

## 1. 확정 결정

- **1급 정책: 파일 콘텐츠는 워크스페이스 이동에도 화면에 남는다.** 파일 패널은 워크스페이스 pane 트리가 아니라 **창(chrome) 레벨의 전역 도크 슬롯**에 산다. 근거: ⑴ 워크스페이스 내장이면 전환 시 WKWebView가 파괴되고(검증 확정 — collectWebSurfaces 활성 워크스페이스만 walk[app_session.zig:7550] → diff destroyed[web_panel_layout.zig:165] → Swift dealloc[MaruAppHost.swift:5209], URL 재네비도 없음) keep-alive 수술을 해도 **화면에서는 사라진다**(hidden) — "문서를 옆에 두고 워크스페이스를 오가는" 용례에 구조적 미달. ⑵ 도크는 그 destroy 경로(가장 미묘한 출하 코드)를 한 줄도 안 건드려 회귀 반경이 작다. ⑶ 상태 소유가 창당 한 곳으로 모인다(§4·§5).
- **아키텍처 B — chrome은 Zig+GPU, WKWebView는 콘텐츠만.** 도크의 파일 탭바·헤더 밴드·파일 트리 = GPU 셀 chrome, 가운데 콘텐츠 rect만 WKWebView. 통짜 웹앱(웹이 탭·트리까지 그림)은 기각([control-plane.md] §1 원칙 + 이중 chrome·룩 드리프트). WKWebView 닫힌 열거는 넓히지 않는다.
- **도크 위치 = `right`(기본) | `bottom`(config `file-panel.dock` + 전환 UI).** 수명(전역)과 배치(우측/하단)를 분리한 결정 — 가로 모니터는 우측 컬럼, 세로 모니터는 하단 밴드(위=터미널, 아래=문서 — 상하 분할 습관 그대로). **하단 밴드 범위는 v1=터미널 스트립만**(사이드바는 전 높이 유지 — 사이드바 스크롤 뷰포트·scissor·key-hint의 backing_height 가정 3곳+렌더러를 안 건드림, 2차 검증), 전폭 밴드는 후속 옵션. 접기 토글·크기 드래그는 좌측 사이드바 **런타임** 클러스터와 동형(pt 권위·동적 clamp·드래그 시작값 write-back 가드·전 탭 resize 동기 — app_session.zig:3028) — 단 **영속은 동형이 아니다**(사이드바 폭=config `sidebar.width`·접힘은 미영속, 도크는 workspace.v1 §5 — 별도 결정임을 명시).
- **파일 1개 = 도크 탭 1개.** 이미 열린 경로를 다시 열면 새 탭이 아니라 기존 탭 활성화. 이 유일성은 그룹별이 아니라 **창 도크 전체** 불변식이다 — FP8 분할 뒤 다른 그룹을 target으로 열어도 원래 entry/group를 반환해 그 그룹으로 focus한다. 멀티 윈도우는 창마다 자기 도크(열기는 클릭이 일어난 창의 도크로).
- **도크 내 분할(여러 파일 동시 표시) = 모델은 처음부터 트리, UI는 FP8.** 도크 콘텐츠는 **에디터 그룹 트리**다 — 그룹(파일 탭 스트립 + 활성 entry)을 leaf로 `SplitTree(*DockGroup)` 인스턴스화(워크스페이스 `SplitTree(*Pane)`과 동형, 기존 L2 generic 재사용). v1은 그룹 1개(분할 UI 없음)지만 모델·직렬화가 트리라 FP8이 additive다. **PoC 실측(2026-07-17)**: 프로덕션 무변경으로 `SplitTree(*DockGroup)` 4 시나리오(단일 그룹 / `replaceLeaf` 분할 → 두 파일 rect 동시 분배 / 중첩 3그룹 + `removeLeaf` 닫기 복원 / 하단 도크 가로 rect 동일 트리) 첫 실행 전부 통과 + `layoutDividers`가 divider 드래그 좌표까지 제공 — **"새 수학 없음" 확정**. 남는 실비용은 UI 배관(그룹별 탭바 렌더·도크 divider 마우스 라우팅·그룹 포커스·분할 생성 UX)뿐.
- **웹 브라우저(⌘⌥T)는 현행 워크스페이스 term 유지.** 브라우징의 용례(터미널 옆 미리보기·팝업/OAuth[7f]·에이전트 제어)가 워크스페이스 맥락이고, 출하·손테스트 완료된 7e/7f/4e-4/4g를 재작업하지 않는다. 단 워크스페이스 전환 시 흰 페이지가 되는 현행 동작(위 검증)은 **URL 기억·재로드 얕은 수정**을 web-panel 백로그로 별도 제안(§13).
- **도크 배관은 kind-무관으로 설계**(entries가 kind를 든다) — 후속 "브라우저 탭을 도크로 보내기"(참조용 웹페이지 고정)를 additive로 열어둔다(§13).
- **편집기 = CodeMirror 6** (control-plane §13 열린 질문 해소 — 사용자 결정). 근거: 마크다운이 SSOT(항상 텍스트, 왕복 손실 0), 한글 IME 조합이 WebKit 네이티브 IME 위에서 가장 안정, sanitize 파이프와 렌더 공유. 문서모델 기반(왕복 손실·조합 엣지)은 기각. **프론트엔드 = vanilla TS**(프레임워크 없음 — B로 웹앱 최소화), **렌더 = remark/unified로 확정(FP2 실측)** + Mermaid·KaTeX MathML·Prism 리치 렌더 — 스택·근거·보안 배치는 §2.1.
- **기본 모드(v1) = 읽기 ↔ 소스 편집 토글**: md는 읽기(렌더 뷰) 기본·토글로 소스 편집(CM6 생 마크다운), html은 읽기 기본(소스 편집은 후속 — §2). **이 2모드 토글은 v1 징검다리**다 — 옵시디언식 Live Preview(편집=인라인 렌더 통합)가 최종형이고 소스 편집을 상위 대체하지만, CM6 커스텀 + 보안 모델 재검토(§13)라 후속으로 미룬다.
- **write 스코프 = 열린 파일만**(§3). **트리 루트 = git repo 루트 우선**(§7).
- **WKWebView 상한**: 도크 탭마다 WKWebView 1개(비활성 hidden·상태 유지 — Swift hide=isHidden만, 2차 검증). 상한 N(기본 8, config `file-panel.max-live-views`) 초과 시 가장 오래 안 본 **non-dirty** 탭의 웹뷰만 해제(탭은 스트립에 유지, 재선택 시 재로드) — dirty는 해제하지 않는다. 이 상한이 메모리 bound([performance-budget.md]에 WKWebView RSS 예산 부재). 해제=기존 전이 `destroyed` op·재선택=`created` op(새 op 불필요 — 2차 검증). 단 surface_id는 앱 전역 **비재사용** 불변식이라 재소환 시 **새 id 발급**하고, destroy 경로의 `browser.closed` push는 eviction 의미와 충돌하므로 도크 destroy에선 미발행한다(§4 destroy 판정과 같은 도크-aware 분기).

## 2. kind 분기 (.md vs .html)

| 파일 | 콘텐츠 뷰 | 읽기(렌더 뷰) | 소스 편집 |
|---|---|---|---|
| `.md` | 신뢰 웹앱(markdown config) | 새니타이즈 렌더 | CM6(같은 웹앱, 토글) |
| `.html` | browser config(비신뢰 격리) | `loadFileURL(_:allowingReadAccessTo: 파일 디렉터리)` — WebKit 표준 API로 읽기 범위를 그 디렉터리에 한정 | **v1 범위 밖**(후속 §13) |

- `.html`은 살아있는 스크립트라 신뢰 shell/markdown renderer에 인라인 렌더할 수 없다. 신뢰 CSP의 `frame-src` 예외는 정확히 `maru-app://render`인 번들 renderer 한 곳뿐이며 임의 문서·`file:` iframe은 허용하지 않는다([web-panel.md] §7). 도크 안에서도 `.html`은 browser config(도크 전용 ephemeral store) WKWebView로 격리 렌더한다.
- 현행 스킴 화이트리스트는 http/https만(`resolveNavUrl`·`popupTargetAllowed` — file: 거부)이므로 **도크의 .html 열기 경로만** `loadFileURL`을 쓴다. 주소창 네비게이션의 file: 거부는 불변.
- **`loadFileURL(allowingReadAccessTo:)` 정밀 시맨틱(FP5 확정)**: 디렉터리 스코프는 **하위 트리 전체 재귀** 읽기 + 스코프 내 file: 서브리소스 로드를 허용하고 스코프 **밖만** WebKit이 차단한다. HTML 정적 검사만으로 JS의 동적 import/fetch나 CSS 상대 리소스를 완전 판정할 수 없으므로 파일 유무별 케이스 분기 없이 **항상 핀 파일의 부모 디렉터리**를 준다. top-level file: 이동은 별도 navigation delegate가 차단한다.
- **도크 html 네비게이션 정책(FP5 구현)**: 현행 browser `decidePolicyForNavigationAction`은 maru-app 차단 외 **전 스킴 허용**(file: 포함)이라, 도크 html 안 링크가 스코프 내 형제 파일로 이동해 헤더 밴드 핀 경로와 표시 문서가 어긋날 수 있다. 도크 html webview는 전용 분기에서 **핀 파일과 같은 top-level 로드/새로고침만 허용**하고 나머지는 차단한다. 직접 활성화한 http(s) 링크(`linkActivated`)만 외부 브라우저로 보내며 script/redirect는 외부 앱을 자동 실행하지 않고 취소한다. 스코프 내 네비 허용+밴드 추종은 후속(§13). [web-panel.md] §7 "링크 라우팅"의 도크 케이스다.
- **도크 html은 브라우저 탭과 dataStore 비공유(결정)**: browser 탭들의 공유 `browserDataStore`(7e-0)가 아니라 **도크 전용 별도 ephemeral store**를 쓴다 — 로컬 html은 살아있는 스크립트+CSP 없음+네트워크 무제한이라 공유 시 브라우저 세션 쿠키로 credentialed 요청(CSRF류)을 탈 수 있고, 로컬 파일 뷰엔 로그인 연속성 근거가 없어 격리가 무비용이다.

### 2.1 웹 스택 (프론트엔드·렌더러·리치 렌더)

아키텍처 B로 WKWebView 웹앱의 일은 최소다(트리·탭·도크 chrome = 네이티브 Zig+GPU). 그래서:

- **프론트엔드 = vanilla TS(프레임워크 없음).** 웹앱 책임 = 새니타이즈 HTML 표시(읽기) + CM6 마운트(소스 편집) + 브리지 모드/테마 신호 수신 + dirty 보고뿐 — 반응형 UI 트리·라우팅이 없어 React/Svelte 런타임이 과하다. CM6·ProseMirror류는 프레임워크가 아니라 **DOM 마운트 에디터 라이브러리**라 이 결정과 직교(에디터를 바꿔도 vanilla 불변). 검증: Obsidian도 코어 UI를 오픈소스 컴포넌트의 바닐라 glue로 만든다(Electron·CM6·markdown-it/remark·Prism·Mermaid·MathJax).
- **렌더러 = remark/unified 확정(FP2)**. 실측으로 ⑴ raw HTML을 `remarkRehype` 경계에서 폐기, ⑵ `rehype-sanitize` AST allowlist, ⑶ unist 문자 offset→renderer-owned `data-maru-source-start/end`, ⑷ GFM·KaTeX MathML-only·Prism을 한 pipeline에서 보존하고 adversarial fixture를 통과했다. markdown-it의 block line 범위보다 후속 주석 앵커의 문자 offset hedge가 강하고 별도 DOM sanitizer가 불필요해 remark를 택했다.
- **리치 렌더 기능**(각 = 라이브러리 + 보안 배치):

| 기능 | 라이브러리(후보) | 보안 배치 |
|---|---|---|
| 다이어그램 | Mermaid.js | **격리 렌더 origin 실행**(브리지 없음 → 버그가 브리지 못 닿음) + `securityLevel: 'strict'` + 출력 SVG 새니타이즈(label XSS CVE 이력) |
| 수식 | KaTeX(경량 권장) / MathJax | 격리 origin, 수식→마크업 |
| 코드 하이라이트 | Shiki / Prism | 렌더·빌드타임, XSS 표면 작음 |

- **두 web 컨텍스트**(§3·web-panel §7, FP4 실구현): ① **격리 렌더 origin `maru-app://render`** = `sandbox="allow-scripts allow-same-origin"` iframe 안에서 새니타이즈 HTML + 리치 렌더 JS를 실행한다. shell과 host가 달라 same-origin이 아니며, `window.maru`/WebKit message handler가 없고 부모 DOM 접근도 실패하는지를 실제 WKWebView smoke가 고정한다. ② **신뢰 shell origin `maru-app://app`** = 브리지 + 오케스트레이션. 번들·SRI는 공유하되 브리지는 main-frame exact app origin에만 주입한다. **untrusted 콘텐츠를 처리하는 리치 렌더 라이브러리는 반드시 ①에서** 돌려 shell 침해를 구조로 차단한다.
- **번들(FP2 완료)**: `web/` Bun workspace(`package.json` + `bun.lock`) + `@zntc/core@0.1.3` bundle + oxlint/oxfmt(Oxc), SHA-384 SRI 생성 후 실제 bundle bytes 재검증. vanilla 단일 앱에는 PostCSS/Sass/HMR controller가 불필요해 `@zntc/web`은 넣지 않았다. `bun install --frozen-lockfile`과 별도 path-filtered CI로 재현하고 기존 dependency-free Zig `mise run check`에는 합치지 않는다.

## 3. 콘텐츠 채널 (read/write)

브리지가 유일한 채널 — CSP `connect-src 'none'` + 스킴 핸들러는 번들 asset root만 서빙([web-panel.md] §7 명시 금지). FP4에서 `hello`와 함께 `maru.file.read`/`readAsset`을 신뢰 shell main frame에만 열었다. 정책 판정은 Zig(L2), Swift는 현재 surface를 소유한 `AppSession`을 매 요청 다시 찾아 ABI로 전달하는 어댑터만 맡는다([control-plane.md] §11 게이트).

- **read(FP4 완료)**: `maru.file.read()` — **인자 없음**. Zig가 그 도크 entry에 핀된 경로를 읽어 reply(웹앱은 경로 지정 불가). UTF-8 markdown·파일 크기는 8 MiB 이하만 허용한다. md 상대 이미지용 `maru.file.readAsset({path})`는 핀 디렉터리 handle 아래를 component별 descriptor-relative/no-follow로 연다. 최종 파일은 nonblocking으로 open한 같은 fd에서 stat/read하며 정규 파일만 허용해 경로 TOCTOU·symlink 탈출뿐 아니라 FIFO/device/socket open 대기도 막는다. 파일별 8 MiB·viewer당 최대 64개·base64 응답 합계 48 MiB로 제한하며 `../`·절대경로·backslash·제어문자·모든 asset symlink·외부 URL은 거부한다. raster는 검증된 `data:` URL, SVG는 UTF-8 decode 후 URL/event sink를 다시 sanitize한 `data:` URL만 renderer에 전달한다. **`../` 상위-상대 리소스는 거부되어 이미지가 깨진다** — v1은 피해 반경 bound를 우선하고 트리 루트 확장은 후속(§13).
- **write**: `maru.file.write(content)` — **경로 인자 없음**, 핀 경로에만. 열 때 확정·이후 변경 불가. sanitizer 우회 성공 시 피해 반경 = 열려 있던 그 파일 1개.
- **선행(보안 코어)**: [web-panel.md] §7 "md-derived 문서는 브리지 없는 별도 origin" — write 전에 렌더된 md 콘텐츠와 편집 shell의 격리(shadow-DOM 격리 또는 별도 top-level document)를 실물 구현하고 `file.*` 호출부가 shell 컨텍스트 전용임을 고정. FP6 착수 전 이 절 설계 code-review 게이트.
- dirty(미저장)는 브리지 신호로 Zig 도크 entry에 미러(§1 상한 보호·탭 ●·닫기 확인에 사용).

### 3.1 도크 헤더 밴드

도크 탭 스트립 아래 밴드 = **경로 + [읽기|소스 편집] 토글 + dirty ●**(GPU 셀). 주소창이 아니다 — `←`/`→`(WebKit 백스택)는 단일 파일 문서에 무의미해서 없다("열었던 파일"은 트리의 열린 파일 하이라이트 + 최근 파일 섹션이 흡수 — §7). 밴드 렌더는 7e-1b 주소창 밴드 코드 구조 미러(전용 draw-list 빌더 신규 — `buildPaneAddressBarDrawList`는 browser 3버튼 시그니처). 토글 상태는 L2 도크 entry 필드, Zig→웹 신호는 take/drain 패턴(`take_web_nav_action` v106 동형).

## 4. 생명주기 (도크 = 워크스페이스 무영향)

- **워크스페이스 전환은 도크에 아무 영향이 없다** — 도크 entries는 pane 트리 밖이라 collectWebSurfaces의 활성-워크스페이스 walk(destroy 의미론 포함)에 애초에 안 걸린다. 그 규칙([web-panel.md] §2)은 무변경. keep-alive·LRU 수술 불필요(구조가 해결).
- **WKWebView 수집**: 도크 entries가 기존 `surfaceDiff`/batch 전이 ABI(v101 count+at)의 **별도 소스**로 합류한다 — rect는 pane이 아니라 도크 콘텐츠 rect, visible = 활성 도크 탭 여부(비활성 = hidden·상태 유지). Swift `webPanels` dict·op 적용은 **create/reframe/hide/show까지만 그대로**다(2차 검증). **도크-aware 확장이 필수인 두 곳(그대로는 오동작 실측)**: ⑴ **destroy 판정** — `reparentWebPanelToOwningWindow`→`has_web_surface`가 pane 트리 전용 조회라 도크 surface를 항상 "진짜 닫힘"으로 오판(웹뷰 파괴 + `browser.closed` 오발행) → 소유 판정에 도크 모델 포함(또는 도크 전용 판정). ⑵ **drain 진입 게이트** — `web_surfaces_present`(`activeTabHasWebTerm`, 활성 탭 트리 전용)가 도크 entry를 못 봐 **워크스페이스 web 0개 창에서 첫 도크 웹뷰 생성 전이가 영영 미적용** → presence 신호에 도크 포함. 둘 다 FP3 범위.
- **창 닫힘/병합**: 4e-4 reparent **패턴**(dict 이관 + 대상 창 adopt)을 재사용하되 **현행 코드 그대로는 불성립(2차 검증)** — `merge_window`는 워크스페이스 트리 수술이라 트리 밖 도크 모델을 안 옮기고, `teardownWebPanels`의 이관 판정(`has_web_surface`)도 트리만 조회해 도크를 파괴+`browser.closed` 오발행한다. 신규 2조각: ① merge 시 Zig 도크 모델(entries·active·dirty)을 대상 세션으로 이관, ② Swift 소유 판정의 도크-aware 확장(또는 teardown 전 도크 전용 이관 패스). **편집(FP6) 도입 전 필수**(그 전엔 뷰어라 파괴가 데이터 손실은 아님).
- 상한·웹뷰 해제는 §1 마지막 항목.

## 5. 재시작 복원 (workspace.v1)

**포맷 배치(2차 검증 정정 — "창 블록 안 새 라인 kind"는 additive가 아니다)**: 옛 리더는 창 블록 **중간**의 미지 라인 kind에서 BadLine(파일 전체 폴백), 창 **뒤** 미지 라인에선 후속 창을 통째 드롭한다 — 미지 키 skip은 **라인 안 키**에만 성립(workspace.zig:533). 따라서 도크는 **window 라인의 flat 키 + 반복 키**로 싣는다(`agent-argc`/`agent-arg` 선례): 스칼라 `dock-side`/`dock-size`/`dock-collapsed` + entry마다 `dock-entry=` 반복 키. FP1 wire는 `dock-entry="<kind>:<mode>:<active>:<path-byte-len>:<path>"`(`kind=markdown|html`, `mode=read|source-edit`, `active=0|1`) — path를 마지막 길이-구분 payload로 둬 `:`·공백·개행·따옴표가 있는 파일명도 바깥 workspace quoted escape와 함께 무손실 왕복한다. live 모델과 writer/reader는 같은 창당 **256 entry sanity 상한**을 사용해 정상 라이브 상태가 저장 불능이 되지 않게 한다(활성 WKWebView 상한 8과 별개인 metadata bound). 미래 버전의 미지원 `kind`/`mode`/`side`를 만나면 **도크만 기본 빈 상태로 강등**하고 terminal workspace는 계속 복원한다 — 후속 browser kind가 옛 앱에서 전체 복원을 깨지 않게 하는 forward-compat 규칙이다. `dock-size=0`은 FP3의 런타임 기본 크기를 사용한다는 sentinel이며 키를 생략한다(실제 기본 pt 값은 기하를 구현하는 FP3에서 확정). 나머지도 옵션-키 규율 그대로(기본값 생략=round-trip 고정점·옛 리더 미지 키 skip·헤더 bump 없음). 그룹 트리(FP8)는 TreeNode **패턴**(workspace.zig:8 — preorder·self-delimiting)을 미러하되 writer/parser가 `"tree-node"`/`"pane="` 하드코딩이라 도크용 변형이 필요하고, **v1은 writer가 트리 표현을 생략**(단일 그룹) — FP8이 트리 키를 실제 방출하는 시점에 옛 리더 호환을 재검증한다. 복원 시에도 live open과 같은 **절대 UTF-8 경로·kind↔확장자·regular-file 검증**을 다시 수행하고 실패한 entry만 제거한다. active entry가 제거되면 첫 유효 entry, 전부 제거되면 빈 도크로 강등해 terminal workspace 복원은 계속한다. 내용은 파일이 SSOT라 재로드가 곧 복원이고 dirty는 초기화한다(**미저장 편집은 재시작에서 무경고 유실**; ⌘Q 종료 확인 모달에 dirty 도크 entry 게이트 합류를 후속으로 §13). **초판의 per-Term `kind=`/`path=` 직렬화는 불필요해졌다**(파일 패널이 Term이 아니므로) — [workspace-restore.md]의 web Term 미저장 규칙은 무변경으로 유지된다(웹 브라우저의 **워크스페이스 전환 시** URL 재로드 완화는 §13 백로그이고, **재시작** URL 영속은 workspace-restore의 별개 Phase 5 계획).

## 6. 열기 규칙

**진입점**: ① 터미널 파일 경로 링크 클릭 — `handleUrlClick`이 `.md`/`.html`이면 ABI v121 `open_file_panel_path`로 **그 창의 도크**에 열고, 그 외 확장자는 현행 `NSWorkspace.open`을 유지한다. 링크 감지가 존재를 확인했더라도 ABI 경계에서 절대경로·UTF-8·확장자·regular-file을 다시 검증해 picker와 같은 정책을 쓴다. 지원 확장자지만 검증 실패면 외부 앱으로 우회하지 않는다. ② 트리 클릭(§7). ③ `open_file_panel` 액션 — 기본 `⌘O`, 메뉴/커맨드 팔릿/사용자 keybind에서 같은 one-shot `NSOpenPanel`을 연다(`.md`/`.html` 단일 선택). ④ CLI `panel open`(control-plane 7d)은 후속.

**목적지는 항상 그 창의 도크**다 — 초판의 지정 스코프 3종(pane/워크스페이스/전역)·surface_id 앵커 재기반·split 폴백은 **v1에서 전부 불필요**해졌다(전역 도크가 곧 "무조건 지정한 곳"). 특정 pane 옆에 파일을 split로 두는 "pane에 열기"는 후속 확장(§13). 도크 탭 우클릭 메뉴(닫기·경로 복사 등)는 기존 Zig 컨텍스트 메뉴 인프라 재사용(`renameTargetAt` 동형).

**포커스(2차 검증으로 "선행 필수"로 격상)**: 도크 webview는 pane 밖이라 4g 포커스 불변식("firstResponder ⟺ Zig 활성 pane" — [web-panel.md] §4.1)의 대상이 아니다. **확장 전 현행 동작(실측)**: 도크 웹뷰 클릭 → Direction 2 `activate_surface`가 트리에서 못 찾아 무동작 → **같은 reconcile 호출의 Direction 1이 즉시 firstResponder를 활성 pane으로 회수** — 도크는 포커스를 1 tick도 못 지켜 타이핑·IME·키보드 스크롤이 전부 불가(부분 결함이 아니라 기능 블로커). 도크 웹뷰를 별도 dict로 빼도 Direction 1이 여전히 회수하므로 회피 불가 — `reconcileWebFocus`에 도크 축(도크 포커스 소유 상태)을 추가하는 확장이 유일 경로다. **명시 수용: 뷰어 단계(FP4·FP5)는 마우스 상호작용(휠 스크롤·클릭·선택)만 보장**하고 키보드는 4g 확장(FP6)부터다(손 테스트에서 버그 오인 방지). 코어 포커스 코드 재진입이라 GUI 손 테스트 게이트(§11).

## 7. 파일 트리 (도크 영역 내)

- **배치**: 트리는 도크 영역 안의 고정 컬럼(우측 도크=도크의 우측단, 하단 도크=밴드의 우측단) — 콘텐츠와 함께 도크로 접히고 함께 이동한다.
- **루트**: 열린 파일이 git repo 안이면 repo 루트, 밖이면 부모 폴더. 서로 다른 루트는 멀티루트 섹션. 열린 파일 없으면 빈 안내(도크를 연 맥락에 터미널 pane이 있으면 그 cwd).
- **내용**: 폴더 접기(lazy 열거), 파일 클릭=열기(§6), 열린 파일 하이라이트 + dirty 점, **최근 파일 접이식 섹션**(파일 열람 히스토리 흡수처).
- **층 배치**: 트리 스냅샷·접힘 = L2 신규 모듈(`tests/boundary/imports.zig` 등록), rows 주입 = L3(sidebar.zig `Row` 패턴 — 단 Row는 워크스페이스 전용이라 파일 노드 variant 신규, 사이드바의 선형 마커-파생 depth와 달리 진짜 재귀 트리), 스크롤·hover·FS = L4.
- **FS 백엔드는 완전 신규**(디렉터리 열거·감시 선례 0 — pty kqueue는 proc reap 전용): 이벤트 구동 watcher(FSEvents) + debounce + bounded queue. **frame tick FS I/O 금지**([performance-budget.md] micro-slice 규율 — bounded 증명 artifact).
- **레이아웃 비용(2차 검증 정정)**: `termRect`(app_session.zig:2335)는 폭(사이드바)+높이(titlebar strip) inset 선례가 이미 있고 파생 ~30 호출처가 자동 추종한다. **단 "한 곳"이 아니라 두 곳 동기 규율** — spawn/resize grid는 termRect 파생이 아니라 `gridFromBacking`+`gridPadding()` 별도 경로(호출처 3곳)라, 도크 inset도 titlebar 선례대로 rect 한 곳+grid 한 곳을 동기한다. 비용의 본체는 도크 자신의 렌더·스크롤·hit-test 배관(사이드바 급 신규) + ChromeProps 소비처 4곳(폭 기준 — modal_box·overlay_input·context_menu·dropdown) + **하단 도크의 높이 방향 추가 대상**(modal_box 세로 중앙[backing_height 전체 기준]·context_menu/dropdown 하단 clamp·notifications 가용 높이·settings 행 수). 추가 표면 2개(실측): ⑴ **web seam** — collectWebSurfaces가 "termRect 바깥 경계=divider 없음"을 가정(app_session.zig:7587)해 도크 경계에 붙은 워크스페이스 web pane의 WKWebView가 도크 리사이즈 드래그를 삼킨다 → `seam_edges`에 도크 edge 비트 추가. ⑵ **드래그 중 WKWebView 가림 규범([web-panel.md] §3)은 현재 미구현**(4c 생략 상태) — 도크 리사이즈는 도크 웹뷰 자체가 매 tick resize라 FP3에서 실물 구현(드래그 세션 단위 hide)하거나 명시 백로그로.

## 8. 키 라우팅

현행 `performKeyEquivalent`는 app_action Cmd 조합 **외에 browser nav 특례(⌘R/⌘←/→ — panelKind==1이고 `activeWebSurfaceId`==자기 id일 때, 포커스 무관)도** 가로챈다(초판의 "app_action만"은 2차 검증으로 정정; 단일 출처 keyBindingResolver — app_session.zig:11210). 검증: **⌘S·⌘Z·⌘⇧Z·⌘C/V/X는 미바인딩이라 CM6 도달**, **⌘F(find)·⌘A(select_all)·⌘G·⌘K·⌘D(split)는 maru 선점**(config/keybinding.zig). **도크 함의(실측)**: ⑴ 특례 게이트는 활성 pane 기준이라 도크에선 절대 발화 안 함 — 도크 .html의 ⌘R은 resolver `.ignored`로 무동작(셸 누수 없음), 단 WKWebView **기본** ⌘R/히스토리가 maru 파이프라인 밖에서 발화할 수 있다. ⑵ **역방향 오라우팅** — 도크가 포커스인데 활성 pane이 browser면 그 워크스페이스 패널이 ⌘R을 소비(엉뚱한 브라우저 리로드) → 4g 도크 확장(FP6) 시 이 게이트도 도크-aware로 분기. 결정: **도크(markdown 콘텐츠) 포커스 시 편집 키 양보 분기** — [web-panel.md] §4의 "웹 소유 키 포커스 분기(Phase 5), 정책은 Zig/config 소유" 항목을 도크 kind 닫힌 목록(⌘F/⌘A/⌘G/⌘D…)으로 구현. 사용자 `unbind`는 계속 동작.

## 9. 베이스와 결정 (clean-room)

- WKWebView·`WKContentWorld` 브리지·`loadFileURL(_:allowingReadAccessTo:)`는 WebKit 표준 API.
- 수명(전역 도크)과 배치(right|bottom)의 분리는 maru 결정 — 단일 모델로 가로/세로 모니터 사용 습관을 모두 만족시키기 위함(§1).
- CodeMirror 6·remark/rehype·Mermaid·KaTeX(또는 MathJax)·Shiki(또는 Prism)는 외부 라이브러리 채택(§2.1 근거·SRI/락파일 고정), 프론트엔드는 프레임워크 없이 vanilla TS(Obsidian 코어와 동형). 도크 탭바·헤더 밴드·트리는 maru 기존 chrome 인프라(per-pane 탭바·주소창 밴드·사이드바 카드) 미러로 독립 설계.
- read/write "인자 없는 핀 경로" 형태는 maru 결정 — capability auth 없는 브리지 신뢰 모델(control_bridge.zig:5-7) 위에서 피해 반경을 구조로 bound.

## 10. 슬라이스 (FP0~FP8)

control-plane §12 Phase 7 행 대응: 7a·7b ⊂ FP2, 7c ⊂ FP4+FP6, **7d는 md/html 클릭 라우팅만 FP5**(`panel.bindSession`·`bind` capability·CLI `panel open`은 후속 §13 — 7d의 나머지 절반은 어느 FP에도 없음). **초판의 "FP5 생명주기 수술"은 도크 피벗으로 소멸**했다. FP1·FP2는 병행 가능. 도크 내 분할은 모델(FP1)과 UI(FP8)로 나뉜다(§1 PoC 근거).

- **FP0 — 이 문서(+cross-doc 정합)**: 완료(2026-07-17, 도크 개정 포함).
- **FP1 — 도크 모델(L2) + 직렬화: 완료(2026-07-17).** `src/session/dock_panel.zig`의 `DockPanel` 상태 = **그룹 트리**(`SplitTree(*DockGroup)` — v1은 leaf 1개) + 그룹(entries[path·kind·mode·dirty]·active) + side·size·collapsed. 주소 안정 leaf 소유·도크 전역 중복 경로 활성화·`splitGroup`/`removeGroup`·단일 그룹 `PersistedState` 복원을 순수 모듈로 구현했고, workspace.v1은 §5 flat/repeated wire로 왕복한다(tree·dirty 미저장). §1 PoC 4시나리오를 정식 헤드리스 테스트로 승격하고 옛 파일/default 고정점·legacy key skip·특수 경로·손상 entry·256/257 경계·미래 kind/mode 도크-only 강등을 함께 고정했다.
- **FP2 — web 툴체인 + 렌더러·sanitizer: 완료(2026-07-17).** `web/` Bun workspace, exact `bun.lock`, `@zntc/core@0.1.3` minified Safari 16 ESM hello bundle, SHA-384 SRI 생성/재대조, oxlint/oxfmt, path-filtered Linux CI를 추가했다. zntc는 `write:false` 뒤 diagnostics=0·output=`bundle.js` 하나를 확인해야 disk에 쓰므로 오류와 깨진 bundle이 함께 반환돼도 fail-closed다. remark/unified를 최종 선택하고 raw HTML 폐기→renderer-owned 문자 위치 attribute→rehype allowlist→KaTeX MathML-only/Prism→최종 inline-style/event/resource hardening 순서로 고정했다. `<script>`·`on*`·`javascript:`·iframe/srcdoc·외부 resource·위조 위치 attribute·KaTeX error style과 Mermaid SVG의 direct element URL 및 presentation attribute 외부 `url(...)` sink를 Bun fixture로 검증한다(`url(#fragment)`만 보존). Mermaid `11.16.0`은 핀했지만 untrusted render 중 출력 sanitize보다 앞선 외부 요청 가능성이 있어 FP2에서는 fence를 inert code로 유지하고, 실제 실행은 FP4의 bridge 없는 격리 origin+CSP 뒤에만 연다. `web:licenses`는 설치된 전체 lock graph의 SPDX license를 allowlist 감사하며 nested 오류는 전파하고 symlink를 realpath+cycle guard로 포함하며 khroma 예외는 name+version+license digest를 모두 핀한다. `@zntc/web`은 단일 앱에 불필요한 PostCSS/Sass/HMR 계층이라 제외했다. `mise run web:check`가 독립 게이트다.
- **FP3 — 도크 슬롯 배관: 완료(2026-07-17).** `dock_layout.zig`이 right 420pt/bottom 300pt 기본·동적 terminal floor·tab/header/content/divider rect를 한 번에 파생하고, `AppSession` termRect+gridPadding·전 탭 PTY resize·ChromeProps·workspace capture/apply가 그 모델을 소비한다. 도크 entry는 앱 전역 비재사용 surface id를 발급받아 기존 WKWebView `surfaceDiff` batch에 합류하며, presence/destroy 판정·workspace right/bottom dock-edge seam·right dock content left seam·resize 중 전 웹뷰 hide를 함께 고정했다. 손상된 최대 `dock-size`도 포화 pt→px 변환 뒤 terminal floor로 clamp한다. Metal 탭/경로 밴드·접기 토글·탭 전환·divider 드래그 hit-test가 같은 rect를 쓴다. 헤드리스 통합 테스트가 right/bottom·surface visibility·seam·presence·접기·workspace 캡처·실제 Metal 글리프를 검증하고, `MARU_FILE_PANEL`(+`MARU_FILE_PANEL_DOCK=bottom`)로 제품 Metal 스크린샷 픽스처를 남긴다. 본문은 FP4의 실 viewer가 이어받는다.
- **FP4 — 브리지 read + 뷰어 배선: 완료(2026-07-17).** ABI v120의 surface-pinned `maru.file.read`/`readAsset`과 8 MiB 파일·64 asset/48 MiB aggregate 한도를 추가했다. asset은 descriptor-relative/no-follow fd에서 읽는다. `web/dist`를 앱 `Resources/web`에 패키징하고 port 없는 `maru-app://app` shell → sandboxed `maru-app://render` iframe 고정 채널로 sanitized Markdown/로컬 이미지를 렌더한다. renderer에는 브리지/message handler가 없고 부모 DOM 접근도 불가하다. `MARU_FILE_PANEL` macOS smoke가 실제 fixture 본문+SVG, bridge round-trip, iframe load/ready, renderer 격리까지 자동 단언한다. 뷰어 단계의 키보드 포커스는 §6대로 FP6 전까지 범위 밖이다.
- **FP5 — 열기 라우팅: 완료(2026-07-17).** ABI v121 `open_file_panel` one-shot과 `open_file_panel_path`를 추가해 기본 `⌘O`·메뉴·팔릿 파일 선택과 터미널 경로 클릭을 한 Zig 정책으로 묶었다. `.md`/`.html` regular file만 현재 창 도크에 열고, 중복 경로는 entry를 늘리지 않고 기존 탭을 활성화하며, 다른 확장자는 외부 앱으로 남긴다. workspace 복원도 같은 파일 capability 검증을 거쳐 손상 entry만 제거한다. HTML은 surface→도크 entry 조회로 핀 경로를 얻어 부모 디렉터리 read scope의 `loadFileURL`로 열고, 브라우저와 별도인 도크 전용 ephemeral store를 쓴다. navigation delegate는 핀 파일 최초 로드/새로고침만 top-level 허용하고 직접 클릭한 http(s)는 외부 브라우저, 다른 top-level 이동은 취소한다. browser 전용 주소 상태·자동화·팝업·크래시/닫힘 이벤트도 HTML 도크에서 분리했다. 실제 WKWebView smoke가 script 실행, scope 내부 SVG 성공, scope 밖 SVG 차단, 형제 HTML 링크와 programmatic `about:blank` 시도 뒤 핀 URL 유지를 검증한다. 키보드 포커스는 §6대로 FP6 범위다.
- **FP6 — CM6 편집 + write + 폴리시**: origin 격리(§3 선행·code-review 게이트) + `maru.file.write` + dirty 미러 + 키 양보(§8) + 모드 토글 배선(§3.1) + 상한 웹뷰 해제(§1) + **도크 포커스 4g 확장(§6 — 편집의 선행 필수) + ⌘R 게이트 도크-aware 분기(§8) + merge 도크 이관(§4 — 편집 도입 전 필수)**.
- **FP7 — 파일 트리**: L2 트리 모델 + FS 백엔드/watcher + 멀티루트·하이라이트·최근 파일(§7).
- **FP8 — 도크 내 분할 UI**: 그룹별 탭바 렌더 + 도크 divider 드래그(`layoutDividers` 좌표) + 그룹 포커스(4g 확장에 합류) + 분할 생성/닫기 UX(커맨드 — `replaceLeaf`/`removeLeaf`). 모델·직렬화는 FP1이 이미 트리라 additive(§1 PoC).

## 11. 테스트·검증

- **헤드리스(Zig)**: 도크 모델·직렬화 왕복(옛 파일 호환·트리 키 생략 고정점), 그룹 트리 layout/divider/닫기 복원(§1 PoC 승격), 도크 기하(right/bottom termRect·접힘), 도크 소스 surfaceDiff 전이, `readAsset` 경로 adversarial, 상한 웹뷰 해제(dirty 보호), 트리 L2 스냅샷, 밴드 draw-list, 중복 경로 활성화.
- **bun test(web/)**: 렌더러·sanitizer adversarial fixture, DOM mailbox byte 제거, bridge-free renderer, asset path/response bound, runtime dependency notice graph.
- **스모크(macos)**: FP4는 `read`/`readAsset` 실제 WKWebView 왕복, sanitized fixture 본문+SVG 1개 로드, renderer bridge/message-handler 부재와 부모 DOM 접근 거부, 도크 계층을 자동 단언한다. FP5는 이어서 로컬 HTML의 별도 ephemeral store·브리지/스킴 핸들러 부재·부모 read scope·내부/외부 asset 경계·top-level pin을 자동 단언한다. write는 FP6에서 추가한다.
- **GUI 손 테스트(자동 불가)**: CM6 한글 IME(조합·확정·caret·후보창), 워크스페이스 왕복에 도크 화면·편집 유지, 도크 포커스 전이(4g 확장 무회귀 — 모달 Enter·pane 전환), right↔bottom 전환, WKWebView 픽셀 전반.
- **성능 artifact**: watcher debounce/bounded, 상한 준수, frame tick FS I/O 0.

## 12. 리스크

- **write 보안(origin 격리 실물)이 최대** — FP6 착수 전 §3 설계 code-review 게이트, "sanitizer 뚫려도 핀 파일 1개" 성립을 fixture로 고정.
- **"활성 pane/트리 기준" 판정의 도크 적용 = 결함 클러스터의 단일 뿌리(2차 검증)** — 4g 포커스 회수(§6, 선행 필수)·drain destroy 오판·presence 게이트(§4)·⌘R 게이트 오라우팅(§8)이 전부 같은 원인이다. 도크 슬라이스마다 "이 판정이 pane/트리 기준인가"를 체크리스트로 확인한다. 코어 포커스(모달·IME) 재진입이고 firstResponder는 헤드리스 밖이라 GUI 손 테스트가 유일 안전망.
- CM6 IME는 WebKit 내부라 maru 제어 불가 — 손 테스트.
- FS watcher가 첫 파일 감시 코드 — 성능 게이트.
- 도크 렌더 배관(사이드바 급)이 FP3에 몰림 — 슬라이스 내 재분할 여지.
- ~~**zntc 실체·공급망 미확정**~~ **FP2에서 해소** — `@zntc/core@0.1.3` MIT/prebuilt NAPI를 exact lock하고 macOS local+Linux CI에서 bundle한다. postinstall은 Bun 기본 차단 상태로도 prebuilt가 동작하고 `@zntc/web`은 불필요해 제외했다. SRI·lock graph license audit·CI cache까지 고정했다. 단 아직 pre-release 도구이므로 upgrade는 별도 PR에서 bundle/security fixture 전체를 재실행한다.
- **리치 렌더 라이브러리(Mermaid 등)가 untrusted 콘텐츠를 처리** — FP4가 격리 renderer origin과 `default-src 'none'` CSP를 실물로 제공해 브리지 침해는 구조 차단됐다. 다만 Mermaid는 출력 SVG sanitize 전에 레이아웃 DOM을 만들므로 FP4에서도 fence를 inert code로 유지한다. 실제 Mermaid 실행은 외부 요청 0을 별도 fixture로 증명한 뒤 연다. KaTeX는 MathML-only로 inline style을 만들지 않는다.
- [text-field-editor.md] 이니셔티브와 시퀀싱은 별개 사용자 결정(양쪽 대기).

## 13. 후속(비목표)

- **"pane에 열기"** — 특정 터미널 옆 워크스페이스 내장 split(초판 B-ws 모델의 부활 지점, 도크와 병존 가능).
- **"브라우저 탭을 도크로 보내기"** — 참조용 웹페이지 고정(도크 kind-무관 배관이 전제, §1 헤지).
- **웹 브라우저 URL 기억·재로드** — 워크스페이스 전환 흰 페이지 완화(web-panel 백로그 — Term에 URL 저장 후 재생성 시 reload).
- `.html` 소스 편집 토글(신뢰 편집기·격리 렌더 두-webview 스왑 설계).
- **Live Preview(옵시디언식 통합 편집 — v1 소스 편집을 상위 대체)**: 편집 중 그 자리에서 인라인 렌더(커서 주변만 마크다운 기호 노출) = "읽기/소스 편집" 토글의 편집 쪽이 렌더와 하나로 합쳐진 최종형. 두 선행: ⑴ CM6 decoration/widget 커스텀(CM6 기본 아님 — 옵시디언이 직접 구현), ⑵ **보안 모델 재검토** — Live Preview는 md를 CM6 편집기(=브리지 있는 신뢰 shell origin)에서 인라인 렌더하므로, "md 파생 콘텐츠는 브리지 없는 격리 origin"(§3·web-panel §7)이 무너진다. 켜기 전 편집기 origin 격리 또는 인라인 렌더 fragment의 신뢰 경계를 재설계한다.
- 새 파일 생성·다른 이름 저장·rename/삭제(트리 조작), CLI `panel open` 연동.
- **주석(annotation)** — 문서 텍스트 범위에 코멘트: 앵커 = 텍스트 인용+전후 문맥 재앵커링(오프셋 저장 아님 — 파일 편집에 견딤), 저장 = 사이드카(원본 `.md` 무오염), 표시 = 읽기 뷰는 신뢰 shell 오버레이(주석은 콘텐츠가 아니라 shell UI라 sanitize 무충돌)·소스 편집 뷰는 CM6 decoration(내장), 브리지 `maru.annotation.*` additive, 에이전트 열람은 control plane op. **선행 헤지는 FP2 소스 위치 매핑뿐**(이미 FP2 확정 기준에 포함) — 그 외 전 층이 additive라 지금 미고려로 무해.
- **재시작 미저장 편집 보호** — ⌘Q 종료 확인 모달(기존 인프라)에 dirty 도크 entry 게이트 합류 또는 자동 임시저장(현행 §5는 무경고 유실 — 명시 수용 상태).
- **도크 html 스코프 내 file: 네비 허용 + 헤더 밴드 추종**(v1은 top-level 네비 전부 차단 — §2).
- **readAsset 스코프의 트리 루트 확장**(§3 `../` 비대칭 해소 — v1은 파일 디렉터리 한정 수용).
- **`panel.bindSession`·`bind` capability·CLI `panel open`**(control-plane 7d의 나머지 절반 — §10 매핑 참조).
