# 에디터 Surface 전략 (코드 에디터·git diff 뷰어·포맷/린트·LSP)

이 문서는 maru에 **코드 에디터 surface**(git diff 뷰어 → 인플레이스 편집 → 포맷/린트 → LSP)를 얹는 설계의 단일 출처다. "에이전트 워크벤치" 방향에서 **에이전트가 만든 변경을 사람이 터미널 안에서 리뷰·수정·커밋하는 루프**를 닫는 조각이다.

핵심 재구성: **"git diff 뷰어"는 primitive가 아니다.** 실제로 짓는 것은 **에디터 surface(문서 모델 + 렌더 컴포넌트)**이고, git diff는 그 에디터의 한 가지 **뷰/모드**다. diff 뷰어를 독립적으로 만들면 편집·LSP를 얹을 때 통째로 리셰이프하게 되므로, 토대를 doc-first로 먼저 고정한다.

경계·단일 출처:
- WKWebView 합성·입력·`maru-app://` 신뢰 채널·CSP는 [web-panel.md](web-panel.md)가 소유한다(여기서 재서술하지 않는다).
- 브리지 신뢰 게이트·capability·op 디스패치는 [control-plane.md](control-plane.md) §8이 소유한다.
- 레이어 경계(L2 코어 / L4 host)는 [layering-and-portability.md](layering-and-portability.md), surface 생애주기는 [surface-runtime-api.md](surface-runtime-api.md)를 단일 출처로 둔다.
- 이 문서는 "그 위에 에디터/문서/파일 I/O/포맷/LSP를 어떻게 얹는가"에 집중한다.

> **PoC 실측 범위**
> - **1차(2026-07-12, 정적)**: ① Monaco+워커5개를 zntc로 번들(성공), ② git diff op 데이터 형태, ③ 포매터 stdin/에러 거동(zig fmt·rustfmt), ④ LSP 왕복(rust-analyzer).
> - **2차(2026-07-13, 런타임·시각)**: 산출물을 **엄격 CSP 하에서 실제로 실행하고 화면을 찍었다**. Monaco DiffEditor가 diff·문자단위 하이라이트·구문강조·codicon까지 정상 렌더하고, TS 언어서비스가 201ms 만에 진단을 낸다. **기준 번들러(Vite) 산출물과 픽셀 0개 차이.** 자동완성·호버·찾기·커맨드팔레트·Monarch 14개 언어까지 두드려도 **`new Function`·`eval`·`WebAssembly` 호출 0회, CSP 위반 0건** → **`script-src 'unsafe-eval'` 불필요를 측정으로 확정**(§2·§4).
>
> **여전히 미검증: WKWebView(WebKit) 런타임.** 2차는 Chrome(Blink)이다. "코드가 `unsafe-eval`을 실제로 요구하는가"는 엔진 무관한 강한 신호지만, **커스텀 스킴(`maru-app://`) 위의 모듈 워커·스타일 주입·IME는 WebKit 고유 영역**이라 Phase 0.5 GUI 스파이크가 여전히 필요하다(§11·§14).
>
> **교훈(설계에 반영)**: 이 PoC 과정에서 번들러 결함을 여러 건 밟았는데, **전부 빌드가 exit 0으로 통과한 채** 뒤늦게 드러났다. 어떤 결함은 산출물이 파싱조차 안 됐고, 어떤 결함은 파싱·모듈평가까지 통과한 뒤 **API를 실제로 호출·렌더할 때만** 터졌다. **빌드 green은 동작 증거가 아니다** → 프런트 빌드 파이프라인에 **4층 검증 게이트**를 넣는다(§12).

---

## 1. 확정 결정

- **렌더 컴포넌트 = Monaco Editor(웹뷰), 셀 그리드 자작 아님.** diff editor + 편집기 + LSP 클라이언트가 한 컴포넌트의 세 모드다: git diff = `<DiffEditor>`(`IDiffEditorModel { original, modified }`), 편집 = editor, LSP = `monaco-languageclient`(후속). Metal 셀 그리드에 에디터를 자작하는 것은 diff·구문강조·LSP를 감안하면 비현실적이다.
- **Monaco는 self-host 번들, CDN 금지.** `maru-app://` CSP가 외부 호스트를 차단하므로 CDN은 애초에 불가. **번들 경유 = zntc NAPI `@zntc/core.build()`**(§4). 워커는 정적 문자열 리터럴 `new Worker(new URL("...worker.js", import.meta.url), { type: "module" })`로 배선(변수 스페시파이어는 정적 분석이 깨져 emit 안 됨).
- **번들은 barrel이 아니라 targeted import다** — `editor.api` + 쓸 언어의 `basic-languages/*.contribution`만(§2 레시피 ③). **4.2MB·워커 1종**으로 barrel(13.9MB·워커 5종) 대비 70% 작고 구문강조는 같다. **주의: barrel을 쓰면 JS/TS 모델이 TS 언어서비스를 자동 등록해 `ts.worker`를 요구한다** — "diff는 워커 하나면 된다"는 targeted import 전제에서만 참이다(실측).
- **엄격 CSP를 유지한다 — `unsafe-eval`도 `wasm-unsafe-eval`도 열지 않는다(실측 확정).** Monaco 코어·DiffEditor·**TS 언어워커까지** `script-src 'self'`만으로 동작한다(§2). 신뢰 채널 CSP를 약화시키지 않아도 되므로 **§13의 열린 결정 하나가 닫혔다.** 유일한 추가 완화는 **`img-src 'self' data:`**(오류 물결선이 `data:` SVG). TextMate(§8)를 도입할 때만 `wasm-unsafe-eval` 논의가 되살아난다.
- **에디터는 신뢰(trusted) surface다.** 로컬 저장소를 maru가 렌더하는 신뢰 콘텐츠라 `trust=trusted` + `maru-app://` 신뢰 채널(스킴 핸들러 + isolated-world MaruBridge)을 쓴다 — `browser`(임의 URL·untrusted)가 아니다. 즉 **현행 신뢰 markdown 패널의 호스팅 기계를 그대로 탄다**(§3).
- **문서 모델은 버전 + 변경이벤트 형태로 day 1에 고정한다**(§5). LSP를 마지막에 하더라도, 버퍼를 "버전 번호 + `open/change/save` 이벤트"로 지어두면 v3 LSP·semantic token이 additive가 된다. 이건 LSP 때문이 아니라 **에이전트×사람 파일 경합 재조정**이 어차피 요구하는 배관이다(§7).
- **파일 I/O는 신규 capability + op다**(§6). 현행 `write` scope는 **PTY 입력(`sendText`/`sendKeys`)**을 인가할 뿐 디스크 파일 쓰기가 아니다(control_capability.zig:121·498-499). 에디터의 파일 read/save는 별도 scope로 발급·게이트한다.
- **하이라이팅은 3층 로드맵**(§8): Monarch(내장·즉시) → TextMate(VS Code 동급, WASM CSP 대가) → semantic tokens(LSP).
- **포맷/린트는 LSP가 아닌 "외부 도구 레인"**(§9): 선언적 레지스트리 + `spawn stdin→stdout` op. LSP(§10)와 별개·경량.
- **의존성 근거**: Monaco·zntc는 **maru 자체 소유 도구(zntc=`ohah/zntc`) + 웹 표준 패턴**으로, 신뢰 채널 안에서만 산다. clean-room: 웹 표준(`new Worker(new URL)`·Monaco 공개 API)에서 유도, reference 코드 이식 없음.

---

## 2. PoC로 확정된 토대 (실측)

| 항목 | 결과 | 근거 |
|---|---|---|
| Monaco zntc 번들 | ✅ exit 0. 워커는 same-origin 해시청크로 **방출**됨 | zntc CLI/NAPI |
| git diff 뷰어 = DiffEditor | ✅ `IDiffEditorModel { original: ITextModel; modified: ITextModel }` | monaco.d.ts + 빌드 |
| **Monaco 렌더 (엄격 CSP)** | ✅ **DiffEditor 정상 렌더 — 라인 diff·문자단위 하이라이트·구문강조(토큰 7종)·codicon·오버뷰 룰러. 에러 0 · CSP 위반 0 · 404 0** | Playwright 헤드리스, `script-src 'self'`(unsafe-eval **없음**), 스크린샷 확인 |
| **Vite 대비 픽셀 동일성** | ✅ **0px 차이(0.000%)** — 렌더한 시나리오 한정이지만, 번들러가 의미를 바꾸지 않았다는 강한 증거 | 동일 앱을 zntc/Vite로 빌드 → 스크린샷 pixelmatch |
| **`script-src 'unsafe-eval'`** | ✅ **불필요 — 측정 확정.** 자동완성·호버·찾기·커맨드팔레트·접기·포맷·Monarch 14개 언어까지 두드려도 **Monaco의 `new Function`·`eval`·`WebAssembly` 호출 0회, CSP 위반 0건** | 위 하니스 + 동적코드실행 API 후킹 |
| **`img-src 'self' data:`** | ⚠️ **필요.** 진단 마커의 오류 물결선을 Monaco가 `data:` SVG로 그림 | 마커 표시 시 CSP 위반 1건 → `img-src` 개방 후 0건 |
| **TS 언어워커(ts.worker)** | ✅ 기동 + **201ms 만에 진단 마커**. **WASM 미사용 → `wasm-unsafe-eval` 불필요** | 오류 있는 JS 모델 → `getModelMarkers` end-to-end |
| **v1 번들 레시피** | ✅ **`editor.api` + 필요한 Monarch contribution만** → 15파일·**4.2MB**·**워커 1종**·에러 0·구문강조 동일. barrel(`import * as monaco from "monaco-editor"`)은 116파일·13.9MB·워커 5종 | 3구성 실측 비교(아래) |
| git diff op 데이터 형태 | before/after **전체 blob**(unified 아님), rename=old/new 경로, binary=numstat `-` 제외 | git PoC(rename R096·binary .ttf 실측) |
| 포매터 에러 정책 | 에러 시 stdout 공백 + exit≠0(zig=2·rust=1) | zig fmt·rustfmt stdin PoC |
| LSP 프리미티브 | initialize 0.02s·진단 4.85s(콜드), 프레이밍=Content-Length(≠maru ndjson) | rust-analyzer 왕복 PoC |

**결론: Monaco 경로는 end-to-end로 검증됐다.** 번들 → 파싱 → 모듈평가 → 실제 렌더까지 통과하고, 기준 번들러(Vite)와 픽셀이 완전히 같다.

**측정 범위(정직한 경계)**: 실제로 **기동한 워커는 `editor.worker`와 `ts.worker` 2종**이다. `css`/`json`/`html` 워커는 **방출은 되지만** 해당 언어 모델을 열지 않아 인스턴스화되지 않았다 — **미검증**이다. v1(diff·JS/TS 편집)은 이 2종이면 되고, CSS/JSON/HTML 파일 편집을 붙이는 시점에 그 워커들을 같은 하니스로 확인한다.

### v1 번들 레시피 (실측)

| 구성 | 파일 | 크기 | 워커 | diff | 구문강조 | page 에러 |
|---|---|---|---|---|---|---|
| ① barrel `import * as monaco from "monaco-editor"` | 116 | 13.9MB | 5종 | ✅ | 토큰 7 | — |
| ② `editor.api`만 | 4 | 2.9MB | 1종 | ✅ | **토큰 3(강조 사실상 없음)** | 0 |
| ③ **`editor.api` + 필요한 `basic-languages/*.contribution`** | 15 | **4.2MB** | **1종** | ✅ | **토큰 7(①과 동일)** | **0** |

**③을 v1 레시피로 확정한다** — barrel 대비 **70% 작고 워커 1종**인데 구문강조는 동일하다.

**함정(실측)**: barrel을 쓰면 JS/TS 모델이 **TS 언어서비스를 자동 등록**해 `ts.worker`를 요구한다. 이때 `editor.worker` 하나만 배선하면 `Missing requestHandler` 에러가 쏟아진다(diff 자체는 그려지지만). 즉 **"diff는 워커 하나면 된다"는 명제는 targeted import 전제에서만 참**이고, barrel에서는 거짓이다. Monarch 문법은 `editor.api`에 없으므로(②가 토큰 3인 이유) **쓸 언어의 contribution을 명시 임포트**해야 한다.

### 툴체인 전제 — zntc 최소 버전

에디터 스택은 zntc의 **첫 대형 소비자**라 PoC 과정에서 코드젠·자산·워커 해석 결함을 여러 건 밟았고, 전부 `ohah/zntc`에 보고·수정됐다. **Phase 1 착수 시점의 zntc 릴리스가 이 수정들을 포함해야 한다** — 프런트 workspace의 `@zntc/core`·`@zntc/web` 최소 버전을 그 릴리스로 못박는다(§13).

세부 결함 목록은 zntc 이슈 트래커가 단일 출처다. 이 문서는 그것을 재서술하지 않고, **거기서 얻은 설계 교훈(§12의 검증 게이트)만** 가져간다.

---

## 3. 신뢰 채널과 PanelKind — 새 kind가 필요 없을 수 있다

**실측 발견**: `PanelKind`(control_surface.zig:76 `{ markdown, browser }`)는 "패널 기능 종류"가 아니라 **신뢰/호스팅 판별자**다. 집행 지점은 `MaruAppHost.swift:937-951`(`MaruWebPanelView` init)이다.
- **신뢰(markdown)**: `let trusted = (panelKind == 0)` → `setURLSchemeHandler(MaruAppSchemeHandler…)`로 `maru-app://app/<path>` 서빙 + `WKContentWorld.world(name:"MaruBridge")` isolated-world 브리지 등록(:944-951). 경로 샌드박스·CSP는 app_scheme.zig `validateAppPath`/`csp_header`.
- **비신뢰(browser)**: ephemeral 데이터스토어로 격리 + 스킴 핸들러·브리지 **미등록**(:940-943, origin 위장 차단).

에디터는 신뢰 콘텐츠이므로 **markdown과 같은 신뢰 기계**를 탄다. 스킴 핸들러가 `maru-app://app/<path>`를 경로별로 서빙하므로, **에디터/git diff는 신뢰 SPA의 라우트**(`maru-app://app/editor`)로 얹을 수 있다 — 즉 **새 PanelKind가 필수는 아니다**.

- **권장(v1)**: 신뢰 SPA 단일 kind + 라우트(markdown 뷰·diff 뷰·editor 뷰). PanelKind 확장 불필요 → 닫힌 열거의 "사용자 승인" 게이트(control_surface.zig:74)를 회피.
- **대안**: 탭/사이드바 라벨·생애주기를 kind별로 구분하고 싶으면 얇은 신규 kind 추가. 이때 건드릴 곳(체크리스트): `PanelKind` enum(control_surface.zig:76) · **`WebMeta.panel_kind`**(:109 — `SurfaceDto`가 아니라 `WebMeta`(:105) 필드다. `SurfaceDto`(:125)는 `detail` tagged union으로 간접 포함) · `panelKindWire`(:229) · `session_model.web_panel_kind`(:58)·`webPanelLabel`(:89) · `web_panel_layout` wire · **ABI `panel_kind: u32` marshal(app_host_abi.zig:1229, 0/1 → 2 추가) + offset 계약 테스트(:2166)** · Swift `panel_kind` 분기(MaruAppHost.swift:937). → **이 선택은 사용자 결정(§13).**

---

## 4. 빌드 통합 — zntc NAPI, raw 바이너리 금지

**현황(실측)**: 프런트 빌드 파이프라인은 **미배선**이다. build.zig:706-713은 placeholder asset(`src/platform/macos/web/` — index.html·app.css·app.js 3개)을 `cp -R`만 한다. **번들러 빌드 스텝이 없다** — `.mise.toml`은 `zig` 하나뿐(node/bun/zntc 없음)이고, 루트 `web/` Bun workspace·`package.json`·`zntc.config.*`도 없다. (build.zig:708 주석은 "Phase 7 실 UI(zntc/Bun 빌드)가 이 소스 asset을 대체한다"고 **예고**할 뿐 실행 스텝이 아니다 — 초판이 "zntc는 build.zig 어디에도 없다"고 쓴 건 자기 인용 범위와 모순이라 정정.) **즉 마크다운 뷰어(Phase 7 콘텐츠)와 그를 빌드할 툴체인은 결정만 됐고 미착수**다.

함의: **에디터 스택이 Phase 7 프런트 툴체인을 처음 세우는 주체다.** "마크다운 뷰어 완성"을 전제로 두지 못한다(그게 없으므로).

- **빌드 호출은 NAPI 경유**: `import { build } from "@zntc/core"`. maru 빌드/트레이스에 구조화된 `{ errors, warnings }`를 그대로 물릴 수 있다. **standalone `zig-out/bin/zntc`는 금지** — 정책(mainFields/conditions/node_modules 루트)이 빈 채라 bare import가 resolve 실패한다(PoC에서 이 함정으로 가짜 블로커 발생). config(`zntc.config.ts`)는 .ts라 로딩 자체가 JS 런타임 일이므로 CLI/NAPI를 통해야 한다.
- **app 빌드 모드는 `@zntc/web`을 별도 요구한다(0.1.3 기준)**: HTML 엔트리(`--entry-html`) 경로는 `@zntc/core`만으로는 안 되고 `@zntc/web`이 설치돼 있어야 한다. maru 프런트 workspace의 devDependency에 포함한다.
- **워커**: `MonacoEnvironment.getWorker`를 정적 리터럴로. 헬퍼로 감싸면(변수 스페시파이어) 정적 분석이 깨져 워커가 emit되지 않는다(Vite/webpack 동일 제약, 실측). v1 레시피(§2 ③)에서는 `editor.worker` 하나다.
- **CSP(실측 확정)**: 아래 정책으로 Monaco 코어·DiffEditor·TS 언어서비스가 **CSP 위반 0건**으로 동작한다(헤드리스 Chrome).
  ```
  default-src 'self'; script-src 'self'; worker-src 'self';
  style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:
  ```
  - **`'unsafe-eval'` 불필요**: 코어에 `new Function` 문자열이 잔존하지만 **실행되지 않는 폴백**이다. 적대 스트레스(자동완성·호버·파라미터힌트·찾기/바꾸기·커맨드팔레트·접기·포맷·Monarch 14개 언어)를 걸고 `Function`/`eval`/`WebAssembly`를 후킹해 세었더니 **Monaco의 호출 0회, CSP 위반 0건**이었다. 초판이 정적 grep으로 "청정"을 단언했다가 적대 검증으로 정정했고, 이제 **런타임 측정이 그 결론을 지지한다.**
  - **`'wasm-unsafe-eval'` 불필요**: TS 언어워커도 WASM을 쓰지 않는다. **TextMate(§8) 도입 시에만** 재검토.
  - **`img-src ... data:` 필요**: 진단 마커의 오류 물결선이 `data:` SVG. 이건 마커가 실제로 뜨는 상태에서만 관측되므로, `ts.worker`가 죽어 있던 동안엔 보이지 않던 조건이다.
  - **미검증 워커**: 위 측정에서 실제 기동한 건 `editor.worker`·`ts.worker` 2종이다. `css`/`json`/`html` 워커는 해당 언어 모델을 열어야 인스턴스화되므로 **아직 CSP 확인 대상이 아니다** — 그 파일 타입 편집을 붙일 때 같은 하니스로 확인한다.
  - **잔여 리스크는 엔진 차이**: 위는 Blink 측정이다. WebKit + `maru-app://` 커스텀 스킴 위의 모듈 워커·스타일 주입은 Phase 0.5에서 확인한다(§11).
- **빌드 성공을 동작 증거로 삼지 않는다**: PoC에서 밟은 번들러 결함은 전부 빌드 exit 0을 통과했다. 프런트 빌드 파이프라인은 **4층 게이트**(재파싱 → 모듈평가 → 렌더/픽셀비교)를 함께 세운다(§12).

---

## 5. 문서(버퍼) 모델 — 신규, L2 소유, 버전+이벤트

**현황(실측)**: 터미널 스크린 버퍼(`Screen`, screen.zig:257 — 셀 그리드) 외에 **범용 편집 가능 텍스트 버퍼/문서 모델은 존재하지 않는다**(rope·piece table·TextBuffer 류 0건). → **문서 모델은 net-new.**

파일 I/O 프리미티브는 있다: read = `config/loader.zig:907 readFileAlloc`, **원자적 write = `agent_hooks.zig:336`·`app_session.zig:10484`의 `createFileAtomic(.{ .replace = true, .make_path = true })`**. §6의 "저장은 원자적 기록"은 **신규 발명이 아니라 이 선례를 재사용**하면 된다. (초판이 근거로 든 `workspace.zig`의 `writeAll`은 **디스크가 아니라 메모리 `std.Io.Writer`에 직렬화**하는 호출이라 오인이었다 — 정정.)

설계:
- **위치 = L2 코어**(session). 정본(canonical) 문서 레지스트리 `{ path, version, dirty, disk_mtime/hash }`를 L2가 소유해 재조정 권위로 둔다. WKWebView의 Monaco는 **라이브 편집 버퍼**를 쥐고, L2는 디스크 지속·변경 이벤트·경합 판정의 권위.
- **버전 + 변경이벤트**: `open/change/save` 어휘(LSP `didOpen/didChange/didSave`와 동형). LSP는 한 줄도 안 쓰되 **모양만** 이렇게 잡으면 v3에서 additive.
- **source-of-truth 규칙**: 열린 버퍼의 dirty 상태·최신 텍스트는 Monaco 소유, 디스크 반영은 save op(§6), 외부(에이전트) 디스크 변경은 file-watch→재조정(§7). 통짜 문자열 교체 금지 — 최소 diff edit로 Monaco undo 스택·커서 보존.

---

## 6. 파일 I/O capability와 op — 신규 scope

**현황(실측)**: capability 6종(metadata/bind/read-output/write/lifecycle/browser) 중 **`write`는 세션 입력(`sendText`/`sendKeys`)을 인가**한다(control_capability.zig:121 `session + "send" → .write`, 498-499). **디스크 파일 read/write를 인가하는 scope는 없다.**

설계:
- **신규 scope `filesystem`(가칭)**: 파일 내용 read/save를 게이트. 발급 UX·fd 상속 정책은 control-plane.md §8·§9의 capability 발급 모델을 따른다(browser cap 발급 선례). 임의 파일 접근이므로 기본 거부 + 명시 발급.
- **op 계열**(browser.* op 패턴 재사용 — deferred marshal/take/complete):
  - `diff.read` — 저장소 변경 파일별 `{ status, old_path, new_path, original_blob, modified_blob, is_binary }`. **read만**(write cap 불필요). worktree/index/HEAD/범위 모드 선택. rename=두 경로, binary=numstat `-` 제외, 대용량 blob 페이로드 고려(실측: 10k줄 파일 실재).
  - `file.read` / `file.write` — 편집 버퍼 열기/저장(`filesystem` cap). 저장은 `createFileAtomic`(§5의 기존 선례 재사용)으로 원자적 기록.
  - `git.stage`/`unstage`/`discard` — 헝크/라인 스테이징(write 액션 계열, 별도 Phase).

**전송 경로와 재사용/신규(실측)**:
- **브리지(`window.maru.*`)에는 capability 모델이 없다** — 신뢰는 origin/frame으로만 확립되고(control_bridge.zig:5-7, 현재 노출 method=`hello` 1개), 세분 grant가 불가하다. 파일/git write 같은 민감 op를 브리지로 노출하면 신뢰 콘텐츠가 **무제한 접근**한다.
- **비동기 골격은 generic이라 재사용**: `InFlight`/`deferRequest`/`completeInFlight`/`reapExpiredInFlight`(control_server.zig)는 메서드 무관. 단 `BrowserOpQueue` + take/complete ABI는 **browser 전용**(op_kind/arg 하드코딩)이라 새 async 계열(diff/file/git)은 병렬 큐 + ABI 또는 일반화가 필요(app_host_abi.zig).
- **소켓 경로도 오늘은 껍데기다(정정·실측)**: "소켓 = capability-gated니까 그쪽으로 흘리면 된다"는 초판의 전제가 과장이었다. 소켓으로 에디터 op를 나르려면 **세 가지를 다 지어야** 한다.
  1. **live capability 발급** — `control_cap_store`가 프로덕션에서 상시 빈 값이라(app_host_abi.zig:1758) 실 fd 발급/상속은 test-only 훅뿐이다. 순수 코어(authz/resolve/store)는 완성·테스트됨.
  2. **non-metadata 라이브 dispatch** — 디스패처는 metadata 3개만 처리하고 **cap이 인가해도** non-metadata는 `method_not_found`로 접는다(control_dispatch.zig:88-107). 즉 `file.*`/`diff.read`를 라우팅할 자리 자체가 없다.
  3. **notification(push) 스트림** — 존재하지 않는다(§10). LSP diagnostics·file-watch 이벤트에 필요.

  이 셋은 browser cap도 공유하는 선행조건이지 에디터 전용이 아니다. 다만 **전송 경로 결정(§13 #5)의 비용 계산이 바뀐다** — 소켓은 "이미 있는 것"이 아니라 "제대로 지어야 하는 것"이다.

---

## 7. 에이전트 × 사람 파일 경합 — 이 제품 고유의 난제

VS Code는 "사람이 유일 writer"를 가정하지만 **maru는 아니다** — 에이전트가 디스크의 파일 X를 고치는 동안 사람이 X를 dirty 버퍼로 열어 둔다.

**현황(실측·정정)**: **파일 감시는 없다** — FSEvents·DispatchSource 사용처가 repo 전체에 0건이다. → **file-watch는 net-new.**

단, 초판의 "kqueue도 전무"는 **틀렸다**: `pty/macos.zig:657-699`가 kqueue를 쓴다(자식 종료 수거 — `EVFILT.PROC`/`NOTE_EXIT` + self-pipe wake `EVFILT.READ`). 파일 감시(`EVFILT_VNODE`)는 아니지만 **kqueue 배관과 그 스레딩 패턴은 이미 있다** — file-watch를 FSEvents로 갈지 kqueue를 확장할지는 구현 시 선택지다.

설계:
- **file-watch(신규, L4 host)**: 열린 문서의 디스크 변경 감지 → L2 문서 레지스트리에 `disk changed` 이벤트. 드래그 세션처럼 **디바운스**.
- **재조정 정책**: dirty 아님 → 조용히 리로드. dirty → 충돌 UX(리로드/유지/머지 선택). LSP도 서버 뷰가 버퍼·디스크와 일치해야 하므로 이 동기화에 얹힌다.
- **day 1 반영**: §5 문서 모델을 버전+이벤트로 지어야 이 재조정이 가능. 나중에 못 끼운다.

---

## 8. 하이라이팅 3층

| 층 | 엔진 | 무게 | 시점 |
|---|---|---|---|
| 기본 | Monarch(Monaco 내장) | 가벼움·WASM 없음 | v1 즉시 |
| VS Code 동급 | TextMate 문법 + VS Code 테마(vscode-textmate + Oniguruma) | **WASM** 필요 | 후속 |
| 의미 기반 | semantic tokens | LSP 서버 필요 | LSP 단계 |

- Monarch로 v1은 충분(내장 수십 개 언어). **Monarch는 WASM을 쓰지 않으므로 엄격 CSP 그대로 간다**(§2 실측).
- TextMate는 VS Code와 픽셀 동급이나 **Oniguruma가 WASM이라 CSP `script-src 'wasm-unsafe-eval'`을 열어야** 한다 — **CSP 약화를 요구하는 유일한 항목**이다(§13 결정). 엔진 교체는 하이라이팅 레이어에 **격리**(에디터·문서 모델 무변경)되므로, 이 결정은 Phase 3까지 미룰 수 있다.
- **정정**: 초판은 "TS 언어워커도 `wasm-unsafe-eval`을 요구할 수 있다"고 적었으나 **틀렸다** — ts.worker는 WASM을 쓰지 않고 엄격 CSP에서 진단까지 정상 동작한다(§2).
- semantic tokens는 LSP `textDocument/semanticTokens`에서 옴 → LSP 단계에 additive(Monaco `registerDocumentSemanticTokensProvider`).

---

## 9. 외부 도구 레인 — 포맷/린트 (LSP 아님)

oxc(oxfmt/oxlint)·prettier·zig fmt·rustfmt·gofmt·black 등은 **LSP 서버가 아니다** — 포매터·린터(CLI)다. LSP 래퍼로 감쌀 수도 있으나 **직접 호출이 훨씬 가볍다**.

- **선언적 레지스트리**: `{ 언어 → command, args, input: stdin|file, output: stdout|inplace }`. stdin→stdout 우선. 새 포매터 = 코드가 아니라 설정 항목(conform.nvim·Helix·Zed 모델).
- **에러 정책(실측 확정)**: **exit==0일 때만 버퍼 교체.** zig fmt(exit 2)·rustfmt(exit 1) 모두 에러 시 stdout 공백이라 안전. 코드값은 툴마다 다르므로 `==0` 기준. 적용은 Monaco 최소 diff edit(undo·커서 보존).
- **린트**: `eslint`/`oxlint --format json` → 파싱 → Monaco 마커. 린트는 편집 불필요라 읽기 뷰에도 앞당길 수 있음.
- op = §6의 `spawn stdin→stdout 캡처`(maru 기존 subprocess spawn 재사용, PTY 없음). LSP 전송(§10) 불필요.

---

## 10. LSP 미래 seam

**맨 나중**(가장 무거움). 지금은 seam만 남긴다.

- **호스트 spawn**: 언어서버 = stdio JSON-RPC 서브프로세스(PTY 없음). per-project 싱글턴·idle shutdown. rust-analyzer 실측: initialize 0.02s·진단 4.85s(콜드).
- **전송 임피던스(실측)**: **LSP=Content-Length 프레이밍 ≠ maru 컨트롤 플레인 ndjson.** 그래서 passthrough는 단순 바이트 포워딩이 아니라 **프레이밍 브리지 + 2번째 JSON-RPC 스트림 멀티플렉싱**(per-server 채널 수명·백프레셔). browser.* op식 op-per-message는 고빈도라 부적합.
- **push 채널 — 어느 경로에도 없다(정정·실측)**: 브리지는 요청/응답 전용이고(control_bridge.zig), **소켓도 마찬가지다.**
  - **초판 오류**: 이 문서는 "소켓 경로엔 notification 스트림(`events.subscribe`·`session.subscribeOutput`)이 **이미 있어** 재사용 가능"이라 적었다. **틀렸다** — 그건 [control-plane.md](control-plane.md)의 **설계 규범**이지 구현이 아니다. 적대 검증에서 드러났다.
  - 근거: 소켓 디스패처는 `sessions.list`/`session.get`/`session.capture`(균일 unauthorized) **셋만** 처리하고 나머지는 `method_not_found`로 접는다(control_dispatch.zig:88-107). 주석이 못박는다 — *"non-metadata granted는 method_not_found로 접음"*(:99-104). `subscribeOutput`은 서버 헤더에 **"범위 밖"**으로 명시돼 있고(control_server.zig:14), capture chunk 기계(control_capture.zig)는 **라이브 서버에 미배선**이다(app_host_abi·control_server 어디서도 import·호출 0건).
  - **결과**: "브리지엔 push가 없지만 소켓엔 있다"는 대비가 성립하지 않는다. **LSP diagnostics push는 어느 경로를 택하든 신규 구축**이다. browser op은 1요청-1응답(deferRequest↔completeInFlight 1:1)이라 1요청-다응답 스트림을 나를 수 없다는 점만 그대로다.
- **보안**: 언어서버는 임의 로컬 코드 실행(rust-analyzer proc-macro/build script). 신규 `lsp` capability + 인지.
- **감지**: 확장자/루트 마커(`Cargo.toml`·`package.json`·`go.mod`) → 서버 cmd + PATH probe.

---

## 11. 단계 계획

전제 붕괴 정정: **"마크다운 뷰어 완성"이라는 전제는 실재하지 않는다(§4).** 따라서 에디터 스택이 **Phase 7 프런트 툴체인(zntc/Bun web workspace + build.zig 배선 + maru-app:// SPA asset 파이프라인)을 처음 세운다.** 이 툴체인 확립은 마크다운 뷰어와 **공유**되므로, 둘 중 무엇을 먼저 내든 이 토대를 함께 짓는다.

```mermaid
flowchart TD
  P0["Phase 0: 이 설계 문서 (doc-first)"]
  P05["Phase 0.5 스파이크 (GUI): WebKit 고유 영역만 — 커스텀 스킴 위 모듈워커 / 스타일 주입 / IME"]
  ZR["선행조건: PoC 수정분을 담은 zntc 릴리스"]
  P1["Phase 1: 프런트 툴체인 + 4층 게이트 + 읽기 diff 뷰 (Monaco DiffEditor)"]
  P15["Phase 1.5: 린트 진단 (편집 불필요)"]
  P2["Phase 2: 문서 모델 + 편집 + 저장 (filesystem cap + file.write)"]
  P2b["Phase 2b: 에이전트x사람 파일 경합 재조정 (FSEvents 신규)"]
  P25["Phase 2.5: 포맷 레인 (외부 도구 spawn)"]
  P27["Phase 2.7: git 스테이징"]
  P3["Phase 3: TextMate 하이라이팅 (WASM CSP 결정 — 유일한 잔여 CSP 완화)"]
  P4["Phase 4: LSP (프레이밍 브리지 전송 + push 채널 + lsp cap)"]
  P0 --> P05 --> P1 --> P15 --> P2 --> P2b
  ZR --> P1
  P2b --> P25
  P2b --> P27
  P2b --> P3
  P25 --> P4
  P27 --> P4
  P3 --> P4
```

- **Phase 0.5(스파이크·GUI 필수, 범위 축소됨)**: 헤드리스 Chrome 실측(§2)이 **CSP·워커·폰트·TS 워커 질문을 이미 닫았으므로**, 스파이크에 남는 것은 **WebKit 고유 영역뿐**이다 — ① `maru-app://` 커스텀 스킴 위에서 `{type:'module'}` 워커가 도는가(WKURLSchemeHandler + 워커 로딩 상호작용), ② Monaco 런타임 스타일 주입 vs 엄격 `style-src`, ③ 한글 IME. red면 워커 전략 재검토. **CSP 정책은 §4의 실측값을 그대로 적용하고 위반 여부만 확인한다.**
- **Phase 1**: zntc NAPI 빌드 배선(+`@zntc/web`, +§12 4층 게이트) + PanelKind 라우트(§3) + `diff.read` op(§6) + `<DiffEditor>` + 접기/펼치기·파일트리 + Monarch. **읽기 전용 diff는 스냅샷+새로고침으로 punt**(경합은 Phase 2b). **선행조건: PoC 수정분을 담은 zntc 릴리스**(§2).
- **Phase 2 / 2b**: 문서 모델(§5) + `filesystem` cap·`file.*` op + 파일 열기(NSWorkspace.open 승격) / file-watch 재조정(§7). **여기서 전송 경로 결정(§13 #5)이 현금화된다** — 소켓을 택하면 live cap 발급 + non-metadata dispatch를 먼저 지어야 하고(§6), 브리지를 택하면 capability 모델을 브리지에 이식해야 한다. **읽기 전용인 Phase 1은 이 결정을 피해 갈 수 있다**(브리지로 `diff.read`만 노출하면 민감 write가 없다) — 그래서 결정을 Phase 2로 미룰 수 있다.
- **2.5·2.7·3 병렬 가능**(문서 모델 위, 서로 독립). **4는 최후** — LSP는 push 채널이 필요한데 **어느 경로에도 없어서 신규 구축**이다(§10). 이게 4를 최후로 두는 이유를 하나 더 늘린다.

---

## 12. 관측 가능성·테스트 전략

### 프런트 빌드 검증 — 4층 게이트 (신규·필수)

PoC에서 밟은 번들러 결함은 **전부 빌드 exit 0**이었다. 각 결함이 어느 층에서야 처음 드러났는지를 그대로 게이트로 만든다. **위 층을 통과했다고 아래 층이 통과하는 게 아니다** — 실제로 각 층에서만 잡히는 결함이 따로 있었다.

| 층 | 검사 | 잡는 것 | 비용 |
|---|---|---|---|
| 1 | **빌드 exit code** | (거의 아무것도) — 모든 결함이 여기를 통과했다 | 0 |
| 2 | **산출물 재파싱** — 방출된 모든 `.js`를 파서로 재독 | 문법이 깨진 산출물. **빌드는 green인데 브라우저가 파싱조차 못 하는** 코드젠 결함 | ~0 |
| 3 | **모듈평가 스모크** — 헤드리스 브라우저에 띄워 엔트리 모듈이 끝까지 평가되는지 | 문법은 유효하나 **평가 중 죽는** 결함(식별자 섀도잉·미링크 바인딩). 2층은 통과한다 | 낮음 |
| 4 | **렌더 + 픽셀 비교** — 실제 API를 호출·렌더하고 **기준 번들러(Vite) 산출물과 스크린샷 픽셀 비교** | 평가는 통과하고 **API를 실제로 호출할 때만** 죽는 결함, 그리고 **조용한 오컴파일**(에러 없이 다른 픽셀) | 중간 |

- **4층이 필수인 이유**: 1~3층을 전부 통과하고 4층에서만 잡힌 결함이 실재했다. `import * as X from "lib"`만으로는 모듈 평가가 성공하고, **실제로 그려봐야** 드러난다.
- **픽셀 비교의 값어치**: Monaco를 zntc/Vite 양쪽으로 빌드해 렌더하면 **0px 차이**다. 이건 "에러가 없다"보다 훨씬 강한 진술 — **번들러가 의미를 바꾸지 않았다**는 증거다. 기준 번들러를 devDependency로 두는 비용은 이 보증에 비하면 싸다.
- Monaco는 CI 렌더 픽스처(고정 diff 입력·`automaticLayout:false`·애니메이션 off·고정 폰트)로 결정론적으로 찍는다. 회귀 시 diff 이미지를 artifact로 남긴다.
- **CSP도 이 게이트에 얹는다**: 3·4층 서버가 §4의 실측 CSP 헤더를 실어, 위반 0건을 상시 확인한다. CSP 회귀가 조용히 들어오는 걸 막는다.
- **한계**: 헤드리스 Chrome은 **WKWebView가 아니다**. 이 4층은 "빌드 green ≠ 동작 green" 갭의 대부분을 CI에서 잡아줄 뿐, WebKit 고유 리스크는 Phase 0.5·수동 GUI가 담당한다(§14).

### 그 외

- **프런트 단위**: Monaco 통합·포매터 레지스트리·diff op 매핑은 `bun test`(Phase 7 툴체인)로.
- **op 계약**: `diff.read`/`file.*`/`git.*`는 control-plane trace schema에 실어 snapshot/replay가 같은 데이터를 공유(control-plane.md 관측 원칙 유지).
- **GUI 수동(불가피)**: WKWebView 입력/포커스/폰트/한글 IME는 web-panel.md §11이 이미 "헤드리스 자동화 불가"로 규정한 영역. 에디터는 그 위에 Monaco 상호작용·format-on-save를 더한다 — 각 Phase 게이트에 수동 검증 항목을 명시한다.

---

## 13. 사용자 논의 필요 (문서에 없는 결정)

1. **PanelKind**: 신뢰 SPA 라우트(권장, 새 kind 불필요) vs 얇은 신규 kind(라벨/생애주기). §3.
2. ~~**CSP 완화**~~ → **해소(2026-07-13 실측).** `unsafe-eval`·`wasm-unsafe-eval` **모두 불필요**하고, `img-src 'self' data:`만 추가하면 된다(§2·§4). **잔여 결정은 TextMate뿐** — VS Code 동급 하이라이팅을 위해 `wasm-unsafe-eval`을 열 것인가(Phase 3까지 유예 가능, §8).
3. **신규 capability `filesystem`**: 임의 파일 read/write 발급 UX(기본 거부 + 명시 발급). §6.
4. **외부 의존성**: Monaco를 핵심 UX 경로에 추가 = "가벼운 native shell" 포지션과의 트레이드오프(웹뷰에 제품 상당부가 산다). pr-checklist "핵심 경로 외부 의존성" 항목.
5. **에디터 op 전송 경로**(비용 재산정됨): 초판은 "소켓 = capability-gated + push 스트림 보유"라 적었으나 **적대 검증에서 틀린 것으로 드러났다** — 소켓에는 오늘 **push 스트림도, non-metadata 라이브 dispatch도, live cap 발급도 없다**(§6·§10). 따라서 선택지는 "있는 것 vs 없는 것"이 아니라 **어느 쪽을 지을 것인가**다.
   - (a) **브리지에 capability 모델 + push를 얹는다** — 신뢰 채널이라 origin 기반 신뢰는 이미 있고, 웹뷰 in-process라 지연이 낮다. 대신 control-plane의 capability 설계를 브리지에 이식해야 한다.
   - (b) **소켓을 제대로 완성한다**(live cap 발급 + non-metadata dispatch + notification 스트림) — control-plane 설계와 정합하고 CLI/외부 에이전트도 같은 문을 쓴다. 대신 셋 다 신규다.
   - **분리 배치도 가능**: 읽기(diff.read)는 브리지, 민감 write·LSP push는 소켓. §6·§10.
6. **zntc 최소 버전(신규)**: 에디터 스택은 PoC에서 나온 zntc 수정분에 의존한다(§2). Phase 1을 그 릴리스까지 기다릴지, 그 전까지 lockfile을 프리릴리스에 고정할지.

---

## 14. 한계·미검증

- **WKWebView(WebKit) 런타임 미검증** — 남은 최대 갭. §2의 런타임 실측은 **헤드리스 Chrome(Blink)**이다. "코드가 `unsafe-eval`을 실제로 요구하는가"는 엔진 무관한 강한 신호라 CSP 결론은 유지될 가능성이 높지만, **`maru-app://` 커스텀 스킴 위의 모듈 워커 로딩·Monaco 스타일 주입·한글 IME는 WebKit 고유**라 Phase 0.5에서 확인해야 한다.
- **컨트롤 플레인 선행 인프라가 생각보다 크다**: 소켓 경로에는 오늘 **live cap 발급·non-metadata dispatch·notification 스트림이 셋 다 없다**(§6·§10). 초판은 소켓을 "이미 capability-gated + push 보유"로 오인했다. 에디터가 소켓을 쓰려면 이 셋이 선행이고, 이는 **에디터 전용이 아니라 컨트롤 플레인의 미완 부분**이다 — 일정 산정에 반영해야 한다.
- **이 문서가 두 번 저지른 실수(기록)**: ① 정적 grep으로 "CSP 청정"을 단언 → 런타임 측정으로 정정. ② **`control-plane.md`의 설계 규범을 구현된 코드로 오인**(소켓 notification 스트림) → 코드 검증으로 정정. 둘 다 **"문서에 적혀 있다 ≠ 코드에 있다", "문자열이 있다 ≠ 실행된다"**는 같은 뿌리다. 이 문서의 "실측" 표기는 **코드/런타임을 직접 확인한 것만** 뜻하도록 유지한다.
- **결함이 `--minify` 경로에 몰린다**: PoC에서 밟은 번들러 결함 상당수가 **minify에서만** 재현됐다(비-minify 빌드는 정상). 프로덕션 빌드가 곧 minify 빌드이므로, §12 게이트는 **minify 산출물을 대상으로** 돌려야 한다 — 개발 빌드가 통과했다는 건 아무 보증도 아니다.
- **surface당 자원 비용 미측정**: pane N개 × (Monaco + 워커 5스레드). 성능 예산(performance-budget.md) 대비 측정 필요, Monaco 공유 전략 미결. **번들 크기도 미최적화** — all-language barrel import 기준이라 targeted import로 줄여야 한다.
- **문서 모델 경계·경합 재조정 메커니즘**은 설계만, 구현 미착수(가장 어려운 부분).
- **전제 정정**: 마크다운 뷰어/프런트 툴체인 부재를 이 문서에서 처음 반영 — 기존 계획이 이를 전제했다면 함께 갱신 필요.
