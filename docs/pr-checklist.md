# PR 체크리스트

모든 PR은 기능 구현 여부와 상관없이 이 문서의 관점으로 평가한다.

GitHub PR 본문은 `.github/pull_request_template.md`를 사용한다. 이 문서는 템플릿에 들어가는 질문의 기준과 해석을 설명하는 단일 출처다.

## PR 메타데이터 (필수)

모든 PR은 다음을 반드시 갖춘다.

- 라벨: **영역 1개 + 성격 1개**를 단다(워크플로 게이트는 "하나 이상"만 강제하지만, 규율은 둘이다). **예외**: CI·빌드·테스트 하네스·문서 전용처럼 코드 영역이 없는 PR은 성격 라벨(`ci`·`tests`·`perf`·`docs`)만으로 충분하다.
- assignee: `ohah`로 지정한다.

```sh
# 새 PR
gh pr create --assignee ohah --label <영역>,<성격> ...
# 이미 만든 PR
gh pr edit <번호> --add-assignee ohah --add-label <영역>,<성격>
```

### 라벨 목록 (단일 출처)

라벨은 **커밋 scope와 같은 축**이다 — `feat(file-panel): …`이면 `file-panel` + `enhancement`. 여러 영역을 건드리면 영역 라벨을 여러 개 단다.

**영역(area — 파랑 `#0052cc`, 기존 라벨은 색이 섞여 있다)**

| 라벨 | 범위 | 대표 scope |
|---|---|---|
| `terminal-core` | 파서·스크린·커서·스크롤백·grapheme·선택·kitty | `terminal` `core` `grapheme` `scrollback` |
| `pty` | PTY·프로세스 수명·terminfo | `pty` `terminfo` |
| `ssh` | `maru ssh` 통합·원격 세션 | `ssh` |
| `renderer` | draw-list·Metal·프레임 투영·스레딩 | `renderer` `render` `io-render` |
| `font` | 폰트 로딩·셰이핑·글리프 atlas | `font` `glyph` |
| `chrome` | Zig+GPU UI — 사이드바·탭·모달·팔레트·세팅 GUI·주소창 필드 | `chrome` `sidebar` `settings` `palette` `text-field` |
| `file-panel` | 파일 패널·뷰어/편집기·파일 트리·도크 | `file-panel` `file-tree` `mermaid` |
| `editor` | 네이티브 편집기 — 문서 모델(버퍼·selection·undo)·시각 매핑·syntax·diff 본문 | `editor` `diff` `syntax` |
| `lsp` | 언어 서버 — 진단·자동완성·정의로 이동·포맷·서버 수명. **`editor`와 함께 단다**(표시는 편집기, 실행·신뢰는 [editor-surface-tooling.md](editor-surface-tooling.md) §8.1) | `lsp` `diagnostics` `completion` |
| `status-bar` | 하단 상태표시줄 — 항목·배치·클릭/호버, 창 높이 예약 | `status-bar` |
| `web-panel` | WKWebView 합성·인앱 브라우저·`web/` 콘텐츠 | `web-panel` `browser` |
| `terminal-web` | **웹 배포판** — 브라우저에서 도는 터미널(`packages/` 의 npm `@maru/*` 와 그것이 부르는 wasm 브리지 `src/platform/wasm/`). `terminal-core` 와 **같은 코어의 다른 타깃**이라 이름을 나란히 둔다 — 코어 파서 자체를 바꾸면 `terminal-core` 도 **함께** 단다. 앱 안의 WKWebView 인 `web-panel` 과는 다르다 | `packages` `wasm` |
| `control-plane` | CLI·IPC·`browser.*` 제어·capability | `control` `cli` |
| `session-host` | 영속 host·runtime 이관·host 업그레이드 | `session-host` |
| `workspace` | workspace 저장/복원·창 이동성 | `workspace` `window` `mobility` |
| `input` | 키 입력·IME·키바인딩·마우스 라우팅·**터치**·링크 | `input` `ime` `keybind` `touch` `link` |
| `agent` | 에이전트 관측·상태줄·사이드바 에이전트 목록 | `agent` |
| `notifications` | 데스크톱 알림·알림 패널·벨 | `notification` `bell` |
| `config` | config 스키마·로더·resolve 계약 | `config` |
| `observability` | snapshot·trace·replay·진단 계측 | `observability` `diag` |
| `platform` | **macOS** 어댑터·ABI·앱 호스트 | `platform` `macos` `app-host` |
| `mobile` | **iOS·Android 공통** — `platform/mobile`(C ABI·Zig 브리지)·모바일 타깃 빌드·계약·기기 하네스. macOS 와 층은 같지만(L4) 타깃이 달라 `platform` 과 가른다 | `mobile` |
| `ios` | iOS 전용 — UIKit host·Metal 백엔드·CoreText 래스터. **`mobile`과 함께 단다**(공통분모가 같이 움직이는지 보이게) | `ios` |
| `android` | Android 전용 — NativeActivity host·Vulkan 백엔드·JNI 래스터·IME shim. **`mobile`과 함께 단다** | `android` |
| `windows` | Windows 전용 — ConPTY·Win32 host·DirectWrite·경로 정규화. macOS 와 층은 같지만(L4) 타깃이 달라 `platform` 과 가른다 | `windows` `conpty` `win32` |
| `app-runtime` | 앱 런타임·surface 라우팅·세션 조정 | `app` `session` `runtime` |

**모바일 전용 기능에 새 라벨을 만들지 않는다.** 터치·IME·폰트 래스터·아틀라스 성장·드로우
배칭은 전부 이미 있는 **기능 축**(`input`·`font`·`renderer`)이고, 모바일은 그 기능의 **다른
타깃 구현**이다. 새 라벨을 파면 같은 기능의 회귀가 두 이름으로 갈려 검색이 깨진다. 대신
**타깃 라벨과 기능 라벨을 함께** 단다.

| 모바일에서 한 일 | 라벨 |
|---|---|
| IME shim·터치→셀 | `mobile` `android` `input` |
| 기기 폰트 래스터·아틀라스 성장 | `mobile` `ios` `android` `font` |
| 드로우 배칭·present 페이싱 | `mobile` `ios` `android` `renderer` |
| 원격 세션 연결(M3) | `mobile` `control-plane` (전송에 따라 `ssh`) |

**성격(kind)**

| 라벨 | 언제 |
|---|---|
| `enhancement` | 새 기능·능력 확장 (`feat`) |
| `bug` | 잘못된 동작 수정 (`fix`) |
| `correctness` | 불변식 보존·정합성 수정(동작은 같아 보여도 계약을 지키는 변경) |
| `refactor` | 동작 변경 없는 구조 개선·이관·삭제 (`refactor`) |
| `docs` | **문서 변경이 포함된** PR. 문서만 바꾸면 `docs` 단독(`docs(scope):`), 코드와 함께 문서를 고쳤으면 `enhancement`/`bug`에 **더해서** 단다 |
| `tests` | 테스트 추가·하네스 (`test`) |
| `perf` | 성능 예산·프로파일링·최적화 (`perf`) |
| `security` | 격리·capability·sanitize·권한 경계 |
| `ci` | 워크플로·빌드·릴리스 (`ci` `build` `chore`) |

일회성 분류(`duplicate`·`invalid`·`question`·`wontfix`·`good first issue`·`help wanted`)는 이슈용이며 PR 필수 라벨로 치지 않는다.

## CI 게이트 — 무엇이 머지를 막나 (2026-08-31 사용자 결정)

**required check 는 다섯이다**: `check` · `require label and assignee=ohah` · `core performance budget` ·
`file explorer macOS product path` · `web build and security fixtures`.

**session-host 잡 셋은 required 에서 빠졌고, PR 에서 아예 돌지 않는다**(`session host macOS (Debug)` ·
`session host bundled CLI macOS` · `session host slow observer macOS`). push(main)·수동 실행에서만 돈다.

왜: 셋 다 **실제 프로세스를 띄우고 타이밍에 매달리는** 게이트라 러너 부하에 취약하고, 그 취약함이
무관한 PR 을 막아 왔다 — 2026-08-31 에 자식 대기 hang 하나가 32분을 태우고 **PR 다섯을 연달아
취소**시켰다. main 에서 돌므로 회귀는 몇 시간 안에 드러나고, required 가 아니라서 그때도 다른 PR 을
막지 않는다.

**`file explorer macOS product path` 는 남겼다** — 골든·CoreText·provider 무변경·AppSession 전수·
`test-macos-only` 가 전부 그 잡에 묶여 있어 **macOS 제품 경로를 지키는 유일한 required 게이트**다.

되돌리려면 ⑴ 그 셋의 `if:` 에서 `github.event_name != 'pull_request'` 를 빼고 ⑵ branch protection 의
required 목록에 다시 넣는다(저장소 설정이라 코드에는 없다).

이 규칙은 `.github/workflows/pr-metadata.yml`가 확인한다. 체크 실패가 실제로 머지를 막으려면 GitHub branch protection에서 `PR metadata / require label and assignee=ohah`를 required check로 지정한다(저장소 설정이라 코드에는 없다).

이 워크플로에는 **concurrency(취소)를 두지 않는다.** PR 생성 시 `opened`+`labeled`(라벨 수만큼)+`assigned`가 같은 head SHA에서 거의 동시에 터지는데, concurrency로 묶으면 GitHub이 형제/중간 run을 취소하고 — 그 취소된 run이 required 컨텍스트를 **CANCELLED**로 남겨 — 형제 run이 SUCCESS여도 머지가 BLOCKED된다("체크 전부 green인데 머지 안 됨"의 원인). 묶지 않으면 모든 run이 SUCCESS로 끝나 이 문제가 사라진다(이 job은 5초 read-only라 중복 실행이 싸다). 자세한 근거는 워크플로 주석 참고. ci.yml·performance.yml은 ref 기준 group이라 취소가 항상 이전 커밋(cross-SHA) 대상이라 안전하다.

## 전략 영향 평가

PR 설명에는 다음 질문에 대한 답이 있어야 한다.

```text
이 PR은 기존 Maru 전략을 유지하는가?
아키텍처 경계가 흐려지지 않았는가?
테스트/TDD/E2E 전략에 빈틈이 생기지 않았는가?
로그, snapshot, trace, replay, future inspector가 같은 데이터를 공유하는 방향을 해치지 않았는가?
구현과 문서가 같은 상태를 설명하는가?
이 PR이 구현한 절의 `(계획)`·`(목표 계약)`·`(미착수)`·`(진행)` 라벨을 뗐는가? 스펙 문서의 미래형("…한다/이관한다")을 현재형으로 바꿨는가? (아래 "문서 상태 표기 규율")
새 의존성이 추가되었다면 왜 지금 필요한가?
메모리 전략을 성급하게 복잡하게 만들지 않았는가?
플러그인/확장 경계를 나중에 막지 않는가?
사용자 UX 목표인 가벼운 native shell/workspace 포지션을 해치지 않는가?
VT/parser 동작을 추가·변경했다면 유도한 공개 명세 섹션(ECMA-48, vt100.net DEC parser, xterm ctlseqs)을 인용했는가? (해당 없으면 N/A)
renderer/storage/platform interop를 추가·변경했다면 public spec, platform 문서, 또는 독립 설계 문서에서 유도했는가? (해당 없으면 N/A)
glyph role, wide-render-symbol, emoji/color glyph, 합성 glyph 분류를 바꿨다면 `src/width.zig`와 `src/platform/macos/coretext_smoke.m`의 주석-동기 미러, [글리프 역할 렌더 모델](glyph-role-render-model.md), 관련 smoke/manual gate를 함께 갱신했는가? (해당 없으면 N/A)
reference terminal의 코드 표현(자료구조 레이아웃, 함수 분해, control flow)을 옮기지 않았는가?
```

## 문서 상태 표기 규율

doc-first로 설계 문서를 먼저 쓰기 때문에, **구현한 뒤 문서의 상태 라벨을 떼지 않는 드리프트**가 구조적으로 생긴다(2026-07-29 감사에서 `web-panel.md` §4.1 "계획"·`persistent-session-host.md` "목표 계약"·`layering-and-portability.md` "3차 추출(계획)"이 전부 구현 완료인 채 남아 있었다). 다음을 지킨다.

- **문서 종류별로 상태를 어디에 쓰는지 고정한다.**

  | 문서 | 성격 | 상태 표기 |
  |---|---|---|
  | [실제 구현 계획](implementation-plan.md)의 인덱스가 가리키는 `docs/plans/*.md` | 계획 | "완료 / 미착수 / 보류" — **여기가 계획 진행의 출처** |
  | [검증 매트릭스](verification-matrix.md) | 상태 추적 | "구현 / 부분 구현 / 구현 전" + 한계·게이트 — **여기가 검증 상태의 출처** |
  | 그 외 `*.md`("…의 단일 출처다") | 구현 스펙 | **상태를 쓰지 않는다.** "무엇이 계약인가"를 현재형으로만 쓰고, 진행은 위 두 문서를 가리킨다 |

- **스펙 문서에서 금지**: "슬라이스 N 완료", "구현 상태: …", "(계획)·(목표 계약)·(미착수)" 절 라벨. 미구현은 "완료 안 됨"이 아니라 **"이 계약 밖(별도 이니셔티브)"** 으로 적는다.
- **예외**: 문서가 명시적으로 "이 절은 구현 이력/연대기"라고 선언한 절(예: [file-panel.md](file-panel.md) §10)에서는 날짜와 과거형을 쓴다. 이력은 과거형이 맞다.
- **PR에서 확인**: 이번 PR이 어떤 절을 현실로 만들었다면 그 절의 라벨을 떼고 미래형을 현재형으로 바꾼다. 새로 "계획" 라벨을 붙일 때는 **그 라벨을 뗄 PR이 어디인지**(슬라이스 이름)를 같이 적는다.

## 상수 값을 문서에 적는 규율

위가 **상태** 드리프트라면 이것은 **값** 드리프트다. 구현이 상수를 바꿀 때 그 숫자를 옮겨 적은 문서·주석은 같이 바뀌지 않는다 — 컴파일러도 게이트도 산문 속 숫자는 보지 않기 때문이다. 2026-08-18~19 실측에서 `max_status_bar_right_items`가 9일, `sidebar_slot_height_ratio_milli`가 47일, `min_panel_cols`가 56일 어긋난 채였고, **셋 다 값을 바꾼 커밋이 문서를 하나도 건드리지 않았다.**

- **숫자를 옮겨 적지 말고 상수 이름을 가리킨다.** 값이 한 곳에만 살면 어긋날 수가 없다.
  - 나쁨: 패널 폭은 `` `[min_panel_cols=30, max_panel_cols=44]` ``로 cap한다
  - 좋음: 패널 폭은 최소~`` `max_panel_cols` ``로 cap한다
- **값이 곧 근거인 자리에서는 숫자를 쓰되 소유자를 함께 적는다.** "왜 하필 이 값인가"를 설명하는 문장은 숫자가 있어야 읽힌다. 그때는 **어느 파일의 어느 상수가 그 값을 소유하는지**를 같이 적어 독자가 대조할 수 있게 한다.
- **개명은 값 변경보다 조용하다.** 상수 이름이 바뀌면 문서는 없는 이름을 계속 가리키고, 이름으로 찾는 어떤 검사도 그 자리를 못 본다. `min_panel_cols` → `min_panel_cols_floor`가 그랬다 — 값 드리프트가 개명으로 **덮여** 두 달을 더 살았다.
- **이력 절은 예외**: 위 예외와 같다. "예전 `x = 34`였다"는 과거형 서술은 그대로 둔다. 이력은 그때의 값이 맞다.

## 전략 수정 규칙

PR을 만들거나 리뷰하는 중 기존 전략을 수정해야 한다고 판단되면, 그 변경은 PR 안에서 임의로 처리하지 않는다.

반드시 사용자와 먼저 논의해야 하는 예시는 다음과 같다.

- Ghostty reference-only 원칙을 바꾸는 경우
- 레퍼런스 코드 표현을 구현 기준으로 삼으려는 경우
- macOS-first 범위를 바꾸는 경우
- 외부 의존성을 핵심 경로에 추가하는 경우
- 테스트/E2E가 불가능한 구조를 받아들이는 경우
- 관측 가능성 모델 없이 기능을 먼저 구현하려는 경우
- 코드가 구현된 뒤 문서가 실제 구조, 명령, 테스트 경로, artifact 포맷과 달라지는 경우
- 메모리 전략을 `std.mem.Allocator` 중심에서 외부 allocator 중심으로 바꾸는 경우
- plugin/extension boundary를 앞당기거나 늦추는 경우
- 실제 구현이 문서화된 전략과 달라지는 경우
- 예상하지 못한 플랫폼, 렌더러, PTY, parser, 테스트 자동화 한계가 드러나는 경우
- 구현에 필요한 결정이 설계 문서에 없고, 그 결정이 아키텍처, UX, 의존성, 테스트, 보안, 데이터 포맷, plugin boundary에 영향을 주는 경우

## PR 설명 필수 항목

```text
의도:
  이 PR이 해결하려는 문제

구현:
  어떤 책임 영역을 변경했는지

문서 정합성:
  관련 문서를 함께 수정했는지, 수정하지 않았다면 왜 필요 없었는지

clean-room 근거:
  구현 근거가 "공개 명세/platform 문서 유도", "Maru 독립 설계", "동작 비교만 reference 사용" 중 무엇인지. 해당 없으면 N/A
  터미널 동작이 단일 표준이 없는 사실상 표준(OSC 7·OSC 133·OSC 52 등)이면, 어느 명세/터미널을 베이스로 했고 레퍼런스 간 차이에서 무엇을 왜 택했는지 명시한다.

전략 영향 평가:
  기존 전략과 충돌하는 부분이 있는지

테스트:
  실행한 명령과 결과

E2E/관측 가능성:
  어떤 snapshot, trace, replay, artifact 경로가 있는지

한계:
  자동 검증이 안 된 영역, 실제 구현 중 발견한 한계, 수동 검증 방법

사용자 논의 필요 여부:
  전략 수정이 필요한지, 문서에 없는 결정을 사용자와 논의했는지, 발견한 한계를 사용자와 논의했는지
```

## 서술 수준과 다이어그램 (필수)

PR 본문은 **최대한 자세히** 적는다. 리뷰어가 변경 코드를 직접 열지 않고도 "무엇을·왜·어떻게" 바꿨는지 본문만으로 재구성할 수 있어야 한다.

- 위 9개 항목을 **전부** 채우고 축약하지 않는다. 해당 없는 항목도 비워 두지 말고 `N/A`로 명시하고 그 이유를 적는다.
- 변경한 파일·함수·타입·ABI 버전을 **실제 식별자 이름**으로 짚고, 핵심 분기·불변식·엣지 케이스·실패 경로를 글로 설명한다.
- 동작을 바꿨다면 **Before → After**를 대비해 적는다. 근거가 캡처/실측이면 그 값(시퀀스 바이트, 메트릭, PTY 캡처 등)을 그대로 인용한다("추측 말고 캡처").
- **디자인 시스템/chrome의 시각 결과를 바꾸는 PR**은 Chrome Lab 또는 같은 제품 Metal
  경로에서 만든 **PNG screenshot**을 PR 본문에 반드시 포함한다. artifact 파일 경로만 적거나
  로컬 이미지를 설명으로 대체하지 않는다. `gh attach <image> --markdown -R ohah/maru`가
  출력한 Markdown image reference를 `## UI 시각 검증` 절에 붙이고, scenario·viewport·theme·
  capture 명령을 함께 적는다. before/after가 의미 있는 변경이면 두 캡처를 함께 둔다.
  화면을 그리지 않는 순수 layout/토큰 refactor는 왜 visual output이 변하지 않는지 그 절에
  명시한다. capture가 불가능하면 UI 완료·시각 회귀 방지 주장을 할 수 없으며, 원인과
  수동 재현 방법을 `한계`에 남긴다.
- VT/parser·키 입력을 추가·변경했다면 유도한 공개 명세 섹션(ECMA-48, xterm ctlseqs, vt100.net DEC parser)을 인용하고 clean-room 근거와 연결한다. 단일 표준이 없는 사실상 표준(OSC 7·OSC 133·OSC 52 등)이면 **누가 정의했고 어느 터미널이 채택했는지**와 **레퍼런스 간 동작이 갈릴 때 무엇을 왜 택했는지**(Before→After·트레이드오프 포함)를 본문에 적는다.

**Mermaid 다이어그램을 가능하면 포함한다.** 글로만 설명하기 어려운 구조·흐름·상태 전이는 GitHub가 렌더링하는 ` ```mermaid ` 코드블록으로 그린다. 다이어그램이 설명을 더 명확하게 하는 경우가 사실상 대부분이므로, **넣지 못할 명확한 이유가 없으면 넣는 것을 기본**으로 한다. 종류는 내용에 맞게 고른다:

- **흐름/데이터 경로** (`flowchart`): 키 입력→인코딩→ABI→PTY 같은 파이프라인, 컴포넌트·facade 경계, 분기 결정 트리.
- **시퀀스** (`sequenceDiagram`): Swift↔Zig ABI 호출 순서, IME 트랜잭션(begin/insert/marked/end), `close → reader.join → deinit` 수명, login(1) 래핑 spawn 경로.
- **상태 머신** (`stateDiagram-v2`): 모드 전환(DECCKM·alt screen·DEC mode 2027), preedit/조합 상태, autowrap pending_wrap, 셀렉션/드래그 자동 스크롤.

다이어그램 노드는 **코드의 실제 식별자**(함수·타입·ABI 버전·escape 시퀀스)를 이름으로 써서 본문 설명과 1:1로 대응시킨다. 장식이 아니라 리뷰를 돕는 설명이어야 한다 — 다이어그램만 넣고 본문 서술을 줄이지 않는다.

**레이아웃은 가능하면 세로(좁고 긴)로 그린다.** `flowchart TD`로 흐름을 위→아래로 쌓는다. 독립 `subgraph`를 여러 개 옆으로 나란히 두면 Mermaid가 가로로 넓게 배치해 GitHub PR 컬럼에서 가로 스크롤이 생기고 축소돼 안 읽힌다. 단계가 여럿이면 옆으로 펼치지 말고 **세로로 연결**(`A --> B --> C`)하거나 하나의 top-down 흐름으로 합친다 — 폭이 좁고 길이가 긴 그림이 PR에서 가장 잘 읽힌다.

**문법 안전(GitHub에서 실제로 렌더돼야 한다)**: 깨지면 리뷰어에게 "Unable to render rich display / Parse error"만 보인다.

- 노드 라벨 안에 **escape된 따옴표(`\"`)를 넣지 않는다**. heredoc/JSON으로 본문을 만들면 `\"`가 그대로 새기 쉽다 — 따옴표가 필요하면 단어로 푼다(예: 빈 문자열).
- **빈 노드(`X[ ]`/`X[]`)를 만들지 않는다.** 무시/종료는 라벨 있는 노드로 표현한다(예: `IGN["무시: ..."]`).
- 라벨에 특수문자(`()` `:` `→` `#` `/`)가 있으면 `["..."]`로 인용하고, 불안하면 괄호를 풀거나 단순화한다(예: `(#296)`→`PR 296`).
- 올린 뒤 `gh pr view <n> --json body`로 mermaid 블록을 다시 확인한다(`\\"`·`[ ]` 패턴을 grep).
