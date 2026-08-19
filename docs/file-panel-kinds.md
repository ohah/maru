# 파일 패널 — kind 분기와 문서 컨텍스트 메뉴 (§2 · §2.2 · §2.6)

파일 종류별 분기(`.md`·`.html`·텍스트/코드·svg·이미지·미디어·pdf)와 각 종류가 어느 렌더 경로로 가는지, 그리고 문서 영역 컨텍스트 메뉴의 계약이다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§2.4`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1·§4~§10·§12~§13 [file-panel.md](file-panel.md) · §2·§2.2·§2.6 [kind 분기](file-panel-kinds.md) · §2.1·§2.3·§2.4 [웹 스택과 렌더](file-panel-web-stack.md) · §2.5 [리치 편집 모드](file-panel-rich-edit.md) · §3 [도크 UI](file-panel-dock-ui.md) · §11 [테스트·검증](file-panel-verification.md)

## 2. kind 분기 (.md · .html · 텍스트/코드 · svg · 이미지 · 미디어 · pdf)

**kind는 확장자 나열이 아니라 "콘텐츠를 어떻게 다루느냐(신뢰 경계 + 전송 방식)"로 정의한다(FP12 결정, 2026-07-22 사용자 승인 — 범위 A+B+C+D 전부).** 새 값을 더해도 기존 두 컨텍스트(신뢰 shell / 격리 loadFileURL)와 전송 채널을 재사용하고 WKWebView 닫힌 열거를 넓히지 않는다(§1 아키텍처 B).

| 파일 | 콘텐츠 뷰 | 읽기 | 리치 | 소스 |
|---|---|---|---|---|
| `.md` | 신뢰 shell + bridge-free renderer | 문서 전체 새니타이즈 렌더(Mermaid·KaTeX·코드펜스 하이라이트 포함) | 툴바 + 문서모델 WYSIWYG(§2.5) | CM6 생 Markdown |
| `.html` | browser config(비신뢰 격리) | `loadFileURL(_:allowingReadAccessTo: 파일 디렉터리)` — WebKit 표준 API로 읽기 범위를 그 디렉터리에 한정 | 불가 | 불가(후속 §13) |
| **`text`**(FP12) | **신뢰 shell + CM6**(render origin 미사용) | 불가 | 불가 | **CM6 생 텍스트 + 확장자별 언어 하이라이트**(§2.2). `.md`/`.html`·바이너리 제외 **모든 파일**이 text(VSCode식) |
| **`svg`**(FP13) | 소스=신뢰 shell + CM6 / 프리뷰=**격리 render origin + sanitize→`data:`** | sanitize된 SVG 격리 렌더 | 불가 | CM6 생 XML |
| **`image`**(FP14→FP14b) | browser config(비신뢰 격리) — WebKit **image document** + 주입 뷰어 스크립트 | `loadFileURL` 직접(복사 0) → 주입 스크립트가 휠 줌·드래그 팬·테마 체커 배경 | 불가 | 불가 |
| **`media`**(FP15) | browser config(비신뢰 격리) — WebKit **media document**(래퍼 없음) | `loadFileURL` 디스크 스트리밍(range) | 불가 | 불가 |
| **`pdf`**(FP15) | browser config(비신뢰 격리, WebKit 내장 PDF) | `loadFileURL(_:allowingReadAccessTo: 파일 디렉터리)` | 불가 | 불가 |

- `.html`은 살아있는 스크립트라 신뢰 shell/markdown renderer에 인라인 렌더할 수 없다. 신뢰 CSP의 `frame-src` 예외는 정확히 `maru-app://render`인 번들 renderer 한 곳뿐이며 임의 문서·`file:` iframe은 허용하지 않는다([web-panel.md] §7). 도크 안에서도 `.html`은 browser config(도크 전용 ephemeral store) WKWebView로 격리 렌더한다.
- 현행 스킴 화이트리스트는 http/https만(`resolveNavUrl`·`popupTargetAllowed` — file: 거부)이므로 **도크의 .html 열기 경로만** `loadFileURL`을 쓴다. 주소창 네비게이션의 file: 거부는 불변.
- **`loadFileURL(allowingReadAccessTo:)` 정밀 시맨틱(FP5 확정)**: 디렉터리 스코프는 **하위 트리 전체 재귀** 읽기 + 스코프 내 file: 서브리소스 로드를 허용하고 스코프 **밖만** WebKit이 차단한다. HTML 정적 검사만으로 JS의 동적 import/fetch나 CSS 상대 리소스를 완전 판정할 수 없으므로 파일 유무별 케이스 분기 없이 **항상 핀 파일의 부모 디렉터리**를 준다. top-level file: 이동은 별도 navigation delegate가 차단한다.
- **도크 html 네비게이션 정책(FP5 구현, v125 라우팅 보강)**: 현행 browser `decidePolicyForNavigationAction`은 maru-app 차단 외 **전 스킴 허용**(file: 포함)이라, 도크 html 안 링크가 스코프 내 형제 파일로 이동해 헤더 밴드 핀 경로와 표시 문서가 어긋날 수 있다. 도크 html webview는 전용 분기에서 **핀 파일과 같은 top-level 로드/새로고침만 허용**하고 나머지는 차단한다. HTML 패널은 살아 있는 로컬 문서이므로 WebKit의 실제 사용자 활성화 판정이 있는 http(s) 링크만 §1의 설정 기반 in-app/system 경계로 보내며 script/redirect는 브라우저를 자동 실행하지 않고 취소한다. Markdown renderer의 더 좁은 isolated-world one-shot 계약은 §3과 [web-panel.md] §7을 따른다. 스코프 내 네비 허용+밴드 추종은 후속(§13).
- **도크 html은 브라우저 탭과 dataStore 비공유(결정)**: browser 탭들의 공유 `browserDataStore`(7e-0)가 아니라 **도크 전용 별도 ephemeral store**를 쓴다 — 로컬 html은 살아있는 스크립트+CSP 없음+네트워크 무제한이라 공유 시 브라우저 세션 쿠키로 credentialed 요청(CSRF류)을 탈 수 있고, 로컬 파일 뷰엔 로그인 연속성 근거가 없어 격리가 무비용이다.

### 2.2 새 파일 종류 (text/code · svg · image · media · pdf)

VSCode가 여는 유형 대부분을 도크로 흡수하되, 새 렌더 경로를 만들지 않고 위 두 컨텍스트에 매핑한다(§1 아키텍처 B). 확장자→kind→language 분류는 `openKindForPath`(`file_panel_bridge.zig`)가 유일 출처이고 터미널 링크·NSOpenPanel·트리·CLI가 같은 집합을 연다.

**text kind 범위(FP12 결정, 사용자 승인 2026-07-22)**: `.md`(markdown)·`.html`(html)과 **알려진 바이너리 확장자**(`isBinaryExtension` — 이미지·비디오·오디오·pdf/office·아카이브·실행/폰트/디자인)를 뺀 **나머지 모든 파일을 `text`로 연다**(VSCode식 "일단 텍스트로"). 확장자 없는 파일(`Dockerfile`·`README`·`.gitignore`)과 미지의 확장자도 text다. 바이너리는 `null`(외부 앱, FP14~에서 이미지/미디어/pdf 집합을 자기 kind로 뺀다). text는 `maru.file.read`의 UTF-8 8 MiB 검증이 안전망이라, 블록리스트에 없는 미지의 바이너리가 새어도 read가 UTF-8에서 실패해 조용히 닫힌다.

- **kind별 신뢰·전송·편집·폴백**:

| kind | 컨텍스트 | 전송 채널 | 편집 | 초과·실패 폴백 |
|---|---|---|---|---|
| `text` | ~~신뢰 shell(markdown과 동일 trust config·bridge)~~ → **네이티브 등폭 GPU 뷰**(2026-08-09 개정, §1 · [native-editor.md](native-editor.md) — **2026-08-19부터 기본이 네이티브다**(사용자 결정). 탐색기 클릭이 네이티브 편집기 Term을 연다. **그동안 이 kind가 내주는 것이 편집이다** — 네이티브는 N1이라 읽기 전용이라, 고쳐야 하는 파일은 `MARU_NATIVE_TEXT=0`으로 CM6를 부른다. 편집은 [plans/native-editor.md](plans/native-editor.md) N2에서 돌아온다) | ~~8 MiB UTF-8 텍스트 브리지~~ → 브리지를 거치지 않는다. 크기 상한은 native-editor §3.0이 별도로 정한다 | 소스 편집만 | ~~`> max_file_bytes`면 열지 않고 외부 앱~~ → 위와 같이 재결정 |
| `svg` | 소스=신뢰 shell / 프리뷰=격리 render origin | 텍스트 브리지 + sanitize→`data:` URL | 소스 편집만(프리뷰는 파생) | 8 MiB 초과 외부 앱 |
| `image`(FP14b) | 격리 loadFileURL(직접) | WebKit image document + 주입 뷰어 스크립트(줌·팬·체커) | 불가 | 디코드 실패 시 WebKit 기본 표시(빈 문서) |
| `media` | 격리 loadFileURL(직접) | 디스크 스트리밍(range) | 불가 | **인앱 컨테이너 allowlist 밖이면 열기 시점에 외부 앱** |
| `pdf` | 격리 loadFileURL(내장 PDF) | 디스크 스코프 | 불가 | — |

- **보안 3대 결정**:
  - **text/code가 신뢰 shell에 있어도 안전**: 파일 내용은 CM6 `Text` 문서로만 들어가고 렌더(HTML materialize) 단계가 없다. 하이라이트는 CM6 decoration(Lezer 토큰→style span)이라 콘텐츠 HTML 주입이 아니다. markdown의 격리 render origin·atomic worker·mermaid helper는 text에서 전부 미사용이고 shell은 CM6만 마운트한다.
  - **SVG는 loadFileURL 금지**: SVG를 top-level 문서로 로드하면 내장 `<script>`가 실행된다. 프리뷰는 반드시 §3 `readAsset`의 SVG sanitize(UTF-8 decode 후 URL/event sink 재검사)→`data:` URL 경로로 격리 render origin에서만 그린다. `.html`과 달리 `svg`는 `loadFileURL`을 쓰지 않는다.
  - **image(FP14b)는 격리 `loadFileURL` + WebKit 기본 뷰어**: 파일 문서 자체가 그 이미지라 **바이트를 옮기지 않는다** — WebKit이 디스크에서 직접 디코딩한다(복사 0·base64 0·`max_file_bytes` 무관). 팬/줌은 **WebKit `ImageDocument`가 소유**한다: 뷰포트보다 큰 이미지는 창에 맞춰 표시하고 클릭하면 실제 크기로 토글하며 스크롤로 이동한다. 트랙패드 핀치는 패널의 `allowsMagnification`이 처리한다(pdf·미디어도 같이 적용). **주입하는 것은 투명 이미지용 테마 파생 체커 배경 CSS 하나**뿐이고, 첫 줄에서 `document.contentType`이 `image/`인지 보고 아니면 no-op이라(pdf·미디어·로컬 HTML 무영향) 새 ABI 힌트가 필요 없다.
  - **왜 FP14의 신뢰 shell + `readSelfImage`를 걷어냈나(2026-07-28)**: 그 구조는 **복사를 위해 존재한 것이 아니라 커스텀 뷰어를 위해 치른 비용**이었다 — 신뢰 origin(`maru-app://`) 문서는 `file://`을 읽을 수 없어 바이트를 브리지로 밀어넣어야 했다. 대가가 셋이다: ⑴ **8 MiB 상한이 사진에 걸린다**(요즘 카메라 JPEG·긴 스크린샷이 쉽게 넘겨 프리뷰가 실패했다), ⑵ 20 MB 이미지면 base64 ~27 MB 문자열 + ABI/JS 복사 3회, ⑶ 브리지·mime·shell 힌트·web 배관·`panzoom` 의존이 image 하나 때문에 존재했다. 격리 경로는 셋을 모두 없앤다. **단, FP14가 격리 안을 기각했던 이유(흰 배경·상단 정렬·팬줌 없음)는 유효하므로** 주입 스크립트로 그 셋을 되살리는 것이 이 전환의 전제다 — 주입이 동작하지 않으면 WebKit 기본 화면을 출하하지 않고 스킴 핸들러 스트리밍(신뢰 shell 유지 + base64 제거)으로 올린다.
  - **커스텀 팬/줌은 시도했다가 걷어냈다(2026-07-29)**: 초판 FP14b는 주입 스크립트로 휠 줌·드래그 팬·더블클릭 토글을 직접 구현했다. 그런데 **드래그를 끝낼 때 배율이 튀는 증상**이 손 테스트에서 계속 나왔고, 세 번 고쳐도 남았다 — ⑴ 축 크기로 줌/팬을 가르던 판정 제거(트랙패드 스크롤도 `wheel`로 온다), ⑵ 핀치 5% 데드존(손 뗄 때 미세 배율 변화), ⑶ 드래그로 끝난 클릭의 `dblclick` 가드. 재현 조건이 **"뷰포트보다 큰 이미지 + 클릭 드래그"**로 좁혀지며 원인이 드러났다: **WebKit `ImageDocument`가 오버사이즈 이미지에 맞춤↔실제크기 클릭 토글을 내장**하고 있고, 그건 C++ 레이어라 우리 JS의 `preventDefault`로 막히지 않는다. 즉 네이티브가 이미 하는 일 위에 같은 기능을 겹쳐 구현하며 충돌한 것이다. **그래서 팬/줌 소유권을 WebKit에 넘기고 주입을 체커 배경 하나로 줄였다**(사용자 결정 2026-07-29). 잃은 것은 드래그 팬과 ⌘/Ctrl+스크롤 줌이다.
- **코덱 정책(media)**: WKWebView는 자체 코덱을 번들하지 않고 OS 미디어 스택(AVFoundation/VideoToolbox)을 쓴다. MP4/MOV/M4V + H.264/HEVC + AAC/MP3는 하드웨어 디코딩되지만 WebM(VP8/VP9)은 불안정, AV1/MKV/Ogg는 사실상 미지원이다. native AVKit으로 바꿔도 동일 백엔드라 커버리지가 같으므로 v1은 **OS가 확실히 재생하는 컨테이너만 인앱**으로 열고 나머지는 **열기 시점에** 외부 앱으로 보낸다. ffmpeg 번들은 라이선스·용량·보안상 비목표(§13).
  - **인앱 allowlist(`mediaExtension`, `file_panel_bridge.zig` 단일 출처)**: 비디오 `.mp4`·`.mov`·`.m4v`, 오디오 `.mp3`·`.m4a`·`.aac`·`.wav`·`.aiff`·`.aif`·`.flac`. 그 밖의 미디어 확장자(`.webm`·`.mkv`·`.avi`·`.wmv`·`.flv`·`.ogv`·`.ogg`·`.opus`·`.wma`·`.mpg`·`.m2ts`·`.mid` 등)는 `openKindForPath`가 **null**을 줘 기존 바이너리와 같은 외부 앱 폴백이 된다(동작 변화 0 — 지금도 외부 앱이다).
  - **왜 JS `MediaError` 감지가 아닌가(초안 정정, 2026-07-28)**: 초안은 `<video>`/`<audio>` **wrapper HTML**을 띄우고 `MediaError`를 잡아 폴백하려 했다. 격리 패널에서는 둘 다 성립하지 않는다 — ⑴ **보고 채널이 없다**: `filePanelKind == 2`는 메시지 핸들러를 0으로 유지하고(§8.1(c)) 로컬 파일에는 browser-control script도 주입하지 않으므로, JS가 오류를 잡아도 네이티브로 전달할 길이 없다. ⑵ **wrapper를 둘 자리가 없다**: `loadFileURL(_:allowingReadAccessTo:)`의 read scope는 **미디어 파일의 부모 디렉터리**(=사용자 폴더)이고 로드하는 문서는 그 scope 안에 있어야 한다 — wrapper를 쓰려면 사용자 폴더에 파일을 만들어야 한다. 그래서 v1은 **확장자 사전 판정 + WebKit media document 직접 로드**로 간다(pdf와 같은 경로라 **Swift 변경 0**).
  - **남는 한계**: 지원 컨테이너 안의 미지원 코덱(예: AV1-in-MP4)은 인앱에서 빈 플레이어가 된다 — 런타임 감지·폴백은 §13 백로그(보고 채널이 생기면).
- **모드**: `markdown`은 `read`(기본)|`rich`|`source_edit`(§1), `text`는 `source_edit` 단일 모드(읽기 없음), `svg`는 `read`(프리뷰 기본)|`source_edit`, `image`/`media`/`pdf`는 모드 없는 `read` 뷰다. `Mode.defaultFor`/`allowedFor`(`dock_panel.zig`)와 `dock_layout.modesForKind`가 kind별 유일 출처이고 `.html`의 read-only 계약을 그대로 확장한다.
- **하이라이트(text/code)**: `textLanguageForPath`(basename→확장자 순)가 `TextLanguage`를 정하고 wire 이름을 shell URL `?lang=`으로 실으면 web `source-language.ts`가 문법을 골라 마운트한다. **전용 `@codemirror/lang-*`**(json·javascript(js/ts/jsx/tsx)·python·css·xml(svg 포함)·yaml)과 **`@codemirror/legacy-modes` StreamLanguage**(toml·ini/properties·shell·sql·rust·go·c·cpp·java·csharp·kotlin·swift·ruby·lua·dockerfile·perl·r·powershell·groovy·scala·haskell·clojure·dart)를 쓴다. 그 외 확장자는 `plain`(색 없음, 편집 가능). 편집기는 `indentUnit(2 spaces)`·`indentOnInput`·`bracketMatching`·`closeBrackets`·`indentWithTab`으로 Enter 자동 들여쓰기·Tab 들여쓰기를 제공한다. 하이라이트 색은 theme 책임(§1)이라 `HighlightStyle`이 Lezer 태그(keyword/string/number/comment…)를 `--maru-syntax-*` CSS custom property에만 매핑한다. **색 소스는 Maru 터미널 색상 테마다(사용자 결정 2026-07-22)** — 시스템 light/dark가 아니라 `theme.palette`(ANSI 16색)+fg/bg에서 각 syntax 역할 색을 파생해 네이티브가 shell에 주입한다(FP12b, §2.3). 폴백(주입 실패·주입 전)은 `app.css`의 `--maru-syntax-*` light/dark 기본값이다. CM6 언어 패키지는 exact name/version/license를 `third-party-licenses.md`에 기록한다(FP12 완료).
- **브리지를 쓰는지는 kind가 아니라 entry가 안다**(2026-08-19). `text`가 네이티브와 CM6 두 경로로 열리므로
  `EntryKind.usesEditorBridgeByKind`만으로는 답이 갈리지 않는다 — read/write·dirty·저장·document epoch·외부변경
  게이트는 `Entry.usesEditorBridge`(= kind 술어 ∧ `!native_editor`)를 쓴다. kind로만 판정하면 닫기가 **오지 않을
  CM6 dirty 스냅샷을 기다려** 네이티브로 연 탭이 닫히지 않는다(`.text`의 기본 mode가 `.source_edit`이라
  `filePanelEntryNeedsDirtyProtection`이 늘 참이다).

- **`max_file_bytes`(8 MiB) 유지 근거**: ⑴ 브리지가 통짜 전송이라(스트리밍 없음) 내용이 Zig 버퍼·ABI 복사·JS 문자열·CM6 문서로 여러 번 뜨고 프레임 틱 blocking을 유발한다([performance-budget.md]), ⑵ write 보안 모델의 "피해 반경 = 그 파일 1개"가 bounded read 위에서 성립한다(§3·§12), ⑶ 초장문 single-line(minified/거대 JSON) 편집 실용성. 초과 파일은 외부 앱으로 폴백하고, **대형 파일 read-only 스트리밍 뷰는 §13 백로그**다.

### 2.6 문서 영역 컨텍스트 메뉴

> **2026-08-09 개정 — 적용 범위가 마크다운 본문으로 좁아진다.** `text` kind와 diff 본문은 네이티브 등폭 뷰가 되므로
> ([native-editor-ui.md](native-editor-ui.md) §8) 그 경로에는 **아래의 web 배관이 필요 없다** — 브리지 `maru.menu.open`,
> 렌더 iframe 좌표 보정, "렌더러가 준 `href`·`path`는 신뢰하지 않는 입력" 방어 셋 다 소거된다(우클릭 좌표와 대상을
> 뷰가 직접 안다). **유효하게 남는 것**은 ⑴ "메뉴는 Zig chrome이 그린다"는 결정과 ⑵ 아래 **항목 표**(대상 × 모드)이며,
> 두 경로가 같은 메뉴 컴포넌트를 서로 다른 입력으로 채운다. 아래 본문은 **마크다운 본문(읽기·리치, 그리고 `.md`
> 소스 모드가 CM6로 남는다면 그것까지)** 기준으로 읽는다.

파일 Term 본문(읽기·소스·리치 셋 다)에서 우클릭했을 때 뜨는 메뉴다. **지금은 아무것도 안 뜬다** — `main.ts`가
WKWebView 기본 메뉴를 억제하는데(Reload가 편집 중 WebContent를 재시작해 recovery latch를 건다) 대신 띄우는 것이
없어서다. 이 절이 그 빈자리를 채운다.

- **메뉴는 Zig chrome이 그린다(§2.1a 부분 정정).** 이미 있는 세 메뉴 — 터미널 본문 우클릭, 파일 트리 우클릭,
  사이드바 ⚙ — 와 **같은 경로**(`context_menu_items_buf` + `itemAt`/`draws`/`accept`, 분기는 플래그)를 쓴다.
  새 메뉴 UI를 만들지 않는다.
- **web은 대상만 올린다.** 브리지 `maru.menu.open`의 인자는 `{ editor_epoch, x, y, target, href?, path?,
  has_selection }`이고, `target`은 `text | link | image | empty`다. 그리기·키보드 이동·바깥 클릭 닫기·테마는
  Zig가 이미 하고 있으므로 web은 **무엇을 눌렀는지**만 답한다.
- **좌표는 shell 뷰포트 CSS px**다. 렌더 iframe에서 일어난 우클릭은 iframe이 자기 로컬 좌표로 shell에 postMessage
  하고, **shell이 iframe 오프셋을 더해** 브리지로 넘긴다. iframe은 자기가 화면 어디에 있는지 모르고(cross-origin),
  알 필요도 없다 — capability는 계속 0이다. Zig는 그 값을 surface rect + scale로 창 좌표로 바꾼다.
- **모드는 web이 안 보낸다.** 어느 모드인지는 그 Term의 entry가 이미 알고 있고, 두 곳에서 판단하면 갈린다.
- **렌더러가 준 값은 신뢰하지 않는 입력이다.** 적대적 문서가 `href`·`path`를 정하기 때문이다. 경로는 기존
  asset-path 정규화를 그대로 태우고(§2.2), `href`는 열기 직전 스킴을 검사한다(기존 `openLink` 경로 재사용).
- **항목**(대상 × 모드):

  | 대상 | 읽기 | 소스·리치 |
  | --- | --- | --- |
  | 선택된 텍스트 | 복사 | 잘라내기 · 복사 · 붙여넣기 |
  | 링크 | 링크 열기 · 주소 복사 | 링크 열기 · 주소 복사 |
  | 이미지 | 이미지 저장 · 경로 복사 | 이미지 저장 · 경로 복사 |
  | 빈 곳 | 전체 선택 · 소스 모드로 열기 | 붙여넣기 · 전체 선택 |

- **동작의 주인은 둘로 갈린다.** 링크 열기·경로 복사·모드 전환은 **Zig**가 이미 소유한 동작이라 그대로 실행한다.
  문서 선택에 붙은 것(복사·잘라내기·붙여넣기·전체 선택)은 선택이 web에 있으므로 native가 `maru:file-menu-action`
  이벤트로 **되돌려 보내** web이 실행한다(줌이 쓰는 `maru:file-zoom`과 같은 방향·같은 방식).
- **실행은 표준 편집 명령이다.** 고른 항목은 native가 `cut:`/`copy:`/`paste:`/`selectAll:`를 responder chain으로
  보내 처리한다 — **키보드 단축키와 같은 경로**다. web에 텍스트로 주고받게 하면 붙여넣기가 서식(HTML)을 잃고
  잘라내기가 편집기 자신의 되돌리기 기록과 다른 경로로 들어간다(둘 다 실제로 겪었다).
  같은 이유로 **Edit 메뉴에 Cut 항목이 있어야 한다** — WKWebView의 편집 단축키는 앱 메뉴 항목을 거쳐 오므로,
  항목이 없으면 `⌘X`가 어디에도 닿지 않는다(Copy·Paste만 있어서 ⌘X만 무반응이던 원인).
- **선택은 우클릭 직전에 붙잡아 되살린다.** 브라우저는 우클릭 기본 동작으로 선택을 접는데, 우리 메뉴는 native가
  그리므로 사용자가 항목을 고르는 시점에는 선택이 이미 없다. `mousedown`의 **capture 단계**에서 붙잡아
  (그때는 살아 있다) 메뉴를 열며 그 범위를 되살린다.
  **메뉴가 떠 있는 동안 웹뷰가 포커스를 지킨다.** 이 메뉴는 `terminalOwnsInput`의 예외다 — 다른 모달처럼
  firstResponder를 터미널로 옮기면 WKWebView가 포커스를 잃고, WebKit은 포커스 없는 문서의 선택을 **아예 안 그린다**.
  대가로 이 메뉴가 떠 있는 동안의 **키보드 이동(↑↓·Enter·Esc)은 아직 없다** — 키가 웹 문서로 간다. 항목 선택과
  닫기는 마우스로 한다(바깥 클릭은 hitTest 통과 경로로 그대로 닫힌다). 키 라우팅은 후속이다.
  **동작 뒤에는 그 문서로 포커스를 돌려준다.** 메뉴 클릭은 오버레이 통과 경로라 터미널 뷰가 받는데, 그대로 두면
  이어지는 ⌘Z·타이핑이 편집기까지 못 간다(잘라내기는 됐는데 되돌리기가 안 되던 원인). 편집기 트랜잭션 자체는
  되돌려진다는 것은 실측으로 확인했다 — 원인은 키가 편집기에 닿지 않는 쪽이었다.
  **선택 표시를 직접 그리지 않는다.** 범위를 되살리면 WebKit이 진짜 선택으로 다시 칠한다 — 실측으로 되살린 화면과
  원래 선택 화면의 픽셀 차이가 **0.000%**였다(Playwright WebKit). 직접 그리는 길은 실제로 시도했다가 접었다:
  `::highlight`는 글자 런만 칠해 줄 끝·문단 사이가 비고, 그 빈 곳을 사각형으로 채우면 리스트 마커처럼 텍스트 노드가
  아닌 것이 **덮여 사라진다**(`Highlight`는 불투명색이다). 브라우저가 이미 정확히 하는 일을 흉내 내지 않는다.
