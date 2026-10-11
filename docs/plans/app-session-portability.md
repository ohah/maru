# AppSession 이식 — 편집기 코드를 macOS 밖으로 (측정과 권장)

> **상태: 완료(측정·권장 끝, D1 사용자 결정 2026-10-11 — §4. 결정의 기록은 §5).**
>
> 이 문서가 갖는 것은 둘이다.
> - 「`app_session` 의 편집기 코드가 macOS 폴더에 있어야 하는가」에 대한 측정과 권장, 그리고 그 결정(D1).
> - 그 결정을 어디에 어떻게 기록했는가. ① 의 할 일과 이동 단계는 편집기 계획이, 결정 블록은 decomposition 이 소유한다(§1.4·§5).
>
> 다른 문서가 소유하는 것도 있다.
> - 위상: [layering-and-portability.md](../layering-and-portability.md) §2
> - `app_session` 분해: [app-session-decomposition.md](app-session-decomposition.md)
> - 편집기 레이어 계약: [native-editor-layering.md](../native-editor-layering.md) §2
>
> 수치는 §2 의 측정 방법으로 쟀다. 빌드로 확인한 것은 「실험」, 확인하지 않은 것은 「추정」이라고 적는다. 적대적 검증 이력은 §7.

## 1. 질문과 답

사용자 질문(2026-10-10, 멀티 커서 자동완성 PR 중):
- **「editor 는 macOS 에 있을 필요가 없는 코드잖아요?」**
- **「앱세션은 macOS 폴더에 있어야 할 이유가 있어요?」**

### 1.1 지금까지의 판정

이 판정은 이미 한 번 내려졌다.

- **L4 를 두 단으로 나눈다.** [layering-and-portability.md](../layering-and-portability.md) §2 의 「L4의 2단」(:35 — [app-layer-decomposition.md](../app-layer-decomposition.md) 옵션 A, 사용자 합의 2026-06)은 L4 를 다음 둘로 나눈다.
  - `src/app`: 이식 시 재사용하는 공통 런타임
  - `platform/macos`: 타깃별로 재작성하는 OS 어댑터
- **분해 문서의 기준.** [app-session-decomposition.md](app-session-decomposition.md) §2 의 기준 항목은 둘이다(셋째 :85 는 난점 목록이다).
  - 첫 항목(:82): 「`app_session`은 **L4 macOS 어댑터**라, 다른 OS로 포팅 시 **재작성 대상**이다」
  - 둘째 항목(:83): 「**순수는 `src/session`으로, macOS orchestration은 `src/platform/macos/app_session/<group>.zig`로** 가른다」
- **2026-06 사용자 합의(:140).** 「방향 확정(사용자 합의 2026-06): (b) 순수→session 이식 기여分만.」 — find(E1) 실측으로 「app_session 대부분이 orchestration(이식 무관 가독성)임이 실측돼」 orchestration 분리는 건너뛰고 순수 로직만 `src/session` 으로 뺀다(실제로 옮긴 것은 `layout_math` b1·b2). 편집기 코드는 아직 없었다(네이티브 편집기 첫 커밋은 2026-08-09 `2ba38ad82`).
- **find 실측.** E1 find 의 실측(:84)은 `chrome_host`·`metal_dirty` 에 묶인 orchestration 이 「순수분 0」이라고 보였다(:140 은 그 실측으로 (b) 대상을 좁혔다).
- **2026-08-08 사용자 합의(:128-136).** 「(b)의 "일단락"을 해제한다」, 「(b)의 이식 기준은 그대로 유지하고(순수分은 여전히 `src/session`(L2)으로)」. 그리고 「orchestration 그룹도 `app_session/<group>.zig`로 분해한다 — **이식 기여는 여전히 0**이며(§2 첫 항목은 정정 대상이 아니다)」. §6(:768)도 같은 판정이다. 이 합의로 분해한 대상은 F 시리즈 전체(에이전트 도크·파일 패널·pane·tab·sidebar·scroll·settings·workspace·git 등 — :158-175)였다.

정리하면, **허브에 묶인 orchestration(원문의 이름은 「macOS orchestration」, :83)은 L4 에 남고, 순수 로직만 `src/session` 으로 뺀다**는 것이 지금의 판정이다. 그 근거는 「`app_session` 은 L4 라 재작성 대상」(:82)이었다 — 사용자 질문이 바로 그 전제를 묻는다.

같은 시기의 편집기 계약은 L4 를 좁게 잡았다. [native-editor-layering.md](../native-editor-layering.md) §2(처음 적은 것은 2026-08-09 `docs/native-editor.md`, 지금 파일은 2026-08-11): L2 `buffer.zig` 는 「텍스트 저장 + 편집 연산 + undo」, L4 `src/platform/macos/` 는 「셀·quad lowering · 입력 이벤트 · IME(§11)」.


### 1.2 측정이 보인 것 (§2)

- **편집기 코드를 붙잡는 것은 대부분 허브다.** 허브 결합을 파일 수로 세면 다음과 같다(`self.` 는 그 함수의 `self` 가 `*AppSession` 인 것만 센다 — 문자 그대로면 `self.allocator` 는 38).
  - `self.allocator` 35
  - `metal_dirty`(`bool` 출력 플래그) 28
  - `chrome_host`(L3 타입) 14
- **그래도 OS 결합이 있는 자리가 있다.**
  - LSP 자식 프로세스(`lsp_process`)
  - 검색 워커(`std.Thread.spawn`·`std.c.environ`)
  - session host lease(`recovery_store`)
  - 신뢰 저장소: `~/Library/Application Support`, 볼륨 UUID 를 `fgetattrlist` 로 읽는다(`trust_store.zig:85-95`)
  - 검색 경로: `getattrlist`(`search/path.zig:16`)
  - CoreText — 검색 도크가 `extern "c" maru_macos_coretext_chrome_*` 를 부르고(`search/dock.zig:615·646`), outline·검색 도크 렌더가 `CoreTextFrameBuilder` 를 받는다(`outline/render.zig:118`·`search/dock/render.zig:206`)
- **허브 자체는 폴더를 옮길 수 없다.**
  - 빌드 모듈의 루트가 `platform/macos/app_host_abi.zig` 다(`build.zig:1732·2194·2332`).
  - 허브 `app_session.zig` 는 `coretext_frame_builder` 를 import 해 제품 코드에서 약 20 줄 쓴다(test 블록까지 세면 42 줄).
- **L4 에 편집기 제품 코드가 약 23.6k 줄(상한) 있다.** 판정 핵심 약 13.8k 줄은 L2/L3 에 있다. 그 23.6k 줄 안에 세 종류가 섞여 있다.
  - ① **편집 판정** — 문서 변경을 만들거나(편집 연산), 선택·문서로 결과를 정하거나(복사), 선택을 바꾸는(커서 이동·커서 추가·다음 일치 추가·낱말/줄 선택) 판정이다. 편집기 계약상 L2 자리다(L3 타입을 읽거나 내는 순수 계산은 최상위 잎 — §1.5).
    - `mod.zig` 에서 변경 리터럴을 만드는 제품 함수만 13 개다(정규식 — 첫 test 앞). 여기에 복사(`copySelection`)와, L2 잎(`motion` 등)을 L4 에서 섞어 부르는 선택 판정(`moveCarets`:4423·`movedOffset`:4073·`addCursorVertically`:4510·`addNextOccurrence`:4588·`selectWordOrLineAt`:6589)이 더해진다. `backup`·`conflict` 에도 있다. `workspace_edit` 은 변경 구성이 이미 L2(`lsp.text_edits`)이고, 남은 판정(revision stale·저장 정책·되돌리기 해시 대조)은 LSP 응답을 적용할지 정하는 정책이라 ① 이 아니라 ② 로 센다.
    - 목록은 편집기 계획이 소유한다(§1.4). 측정 뒤 그 목록에 `cutSelection`·`toggleCursorAt`·`selectionSpansLines` 와 `completion.accept` 의 caret 이동 계산을 더했다(권장 검증 23).
    - 이 중 네 함수에서 결함 다섯이 나왔다.
  - ③ **계산 클라이언트** — OS·LSP 부작용 없이 화면용 값을 계산한다(`guides`·`brackets`·`sticky`, 그리고 허브를 import 하지 않는 `syntax.zig`·`diagnostics`).
    - 판정 핵심은 이미 L2 에 있거나(`indent_guides`·`brackets`), tree-sitter 빌드 제약으로 지금 자리다(§3).
  - ② **허브 배선(orchestration)** — 알림·LSP 요청·오버레이·네비게이션·검색·복구·병합 클라이언트와 그 정책, 그리고 LSP 편집 응답의 적용(`workspace_edit`)이다.
    - 정책은 자리 기준(§1.5)으로 보면 L2 에 갈 수 있다.
    - 그러나 LSP 클라이언트 셋을 손으로 갈라 보니, 옮겨도 배선이 남는다(추정).

    | 클라이언트 | 정책 | 남는 배선 |
    | --- | --- | --- |
    | `highlight` | 약 80 줄 | 약 55 줄 |
    | `definition` | 약 30~35 줄 | 약 50 줄 |
    | `signature` | 약 45 줄 | 정책의 약 4 배 |

### 1.3 답

**「macOS 폴더에 있어야 할 이유」는 부분마다 다르다.**

| 부분 | macOS 에 있을 이유 | 갈 곳 |
| --- | --- | --- |
| ① 편집 판정(문서 변경을 만들거나, 선택·문서로 결과를 정하거나, 선택을 바꾸는 판정) | 없다 — 계약을 벗어나 L4 에 쓰였다(native-editor-layering §2: L2 `buffer.zig` 는 「텍스트 저장 + 편집 연산 + undo」, `selection.zig` 는 「multi-selection(byte range 배열) + goal column」) | 계약의 자리(대개 L2 — 아래) |
| ② 의 정책(요청 규율·클라이언트별 상태 전이·LSP 편집 응답의 적용) | 없다 — 허브에 묶였을 뿐이다 | 계약의 자리(대개 L2 — 아래) |
| ② 의 OS 결합(신뢰 저장소·검색 경로·CoreText 렌더·LSP 프로세스·검색 워커) | 있다 | `platform/macos` |
| ② 의 배선과 허브 자체 | 본질적 이유는 거의 없다 — 지금의 배치(빌드 모듈 루트가 `platform/macos` 에 있고, 허브가 CoreText 를 제품 코드 약 20 줄에서 쓴다)와 옮기는 비용(§2 「(라)의 비용」) 때문이다 | `platform/macos`(옮길지는 W8 전략 — §4 (라)) |
| ③ 계산 클라이언트 | 없지만 옮길 판정이 남지 않았거나 빌드 제약에 묶였다 | 지금 자리 |

**옮기는 때**(§4 D1 — 사용자 결정 2026-10-11). 대상은 ① 편집 판정과 ② 의 정책이다(③ 계산 클라이언트는 들지 않는다). ① 은 지금부터 단계를 세워 차례로 계약의 자리로 옮긴다(단계는 편집기 계획 — §1.4). ② 의 정책은 아래 두 계기 중 하나가 생긴 PR 에서 옮긴다. 두 계기는 ① 에도 걸린다 — 단계를 기다리지 않고 그 PR 에서 옮긴다. 계약의 자리는 대개 L2 다. L3 타입을 읽거나 내야 하는 순수 계산만 최상위 잎으로 간다 — L2 가 chrome 을 못 읽어서다(§1.5, 선례 `syntax_colors`). 아래에서 「L2 로 옮긴다」는 이 자리를 뜻한다.
- **계기 1 — 그 의미를 바꾸는 PR.** 변경 목록·caret 계산·요청 규율 같은 순수 부분의 동작을 바꾸거나 새 갈래를 더하는 PR, 그리고 그런 함수를 새로 쓰는 PR 이다. 배선만 바꾸는 PR 은 들지 않는다.
- **계기 2 — 다른 호스트(Windows·Linux)의 슬라이스가 그 함수를 필요로 하는 PR.** W8.3 ⒞2 히트테스트를 중립으로 뺀 [windows-platform.md](../windows-platform.md) §2m.24 와 같은 꼴이다.

**함께 옮기는 단위**(계기로 옮길 때)는 그 PR 이 바꾸는 코드를 공유하는 함수 전부다. 단계로 옮길 때의 단위는 편집기 계획의 단계다.
- 공유하는 판정 잎(가르면 순수가 되는 것 — 예: 줄 연산 다섯이 쓰는 `selectedLineNumbers` 는 선택을 읽어 줄 집합을 낸다)을 바꾸면 그 잎을 쓰는 함수 전부를 함께 옮긴다. 배선 잎(예: 여섯이 쓰는 `applyLineEdit` — undo·스크롤 앵커·reveal)을 바꾸는 것은 계기가 아니다. 그래서 이 규칙대로라면 결함 3 의 정렬은 `applyLineEdit` 안이 아니라 순수 쪽(변경 목록을 만드는 자리)에 들어간다 — 이동 규칙의 귀결이고, 수정 설계 자체는 편집기 계획이 정한다(§1.4).
- 여러 클라이언트의 같은 꼴을 한 번에 바꾸면 그 클라이언트 전부를 함께 옮긴다. 예: 여섯째 후보를 고치는 다섯.
- 옮기는 정책 상태를 직접 쓰는 함수도 단위에 든다. 예: 서버를 잃었을 때 넷(`semantic`·`inlay`·`symbols`·`fold_lsp`)의 `waiting`·`dirty` 와 `highlight` 의 `waiting` 을 덮어쓰는 `releaseWaiting`(`app_session/editor/lsp.zig` — 2026-10-11 기준 1345-1373 줄. 자라는 파일이라 좌표로 걸지 않는다). 허브 순회는 `platform/macos` 에 남는다. 순회 안에서 옮긴 클라이언트는 L2 의 전이 함수로 바꾸고, 남는 클라이언트(같은 루프의 `editor_completion` 등)는 지금처럼 직접 쓴다.
- 같은 꼴을 복제해 둔 다른 클라이언트까지 끌고 가지는 않는다. 그래서 요청 규율 다섯을 옮긴 뒤에도 `waiting_seq` 대조의 복사본이 L4 에 아홉 남는다 — 한쪽만 고쳐질 수 있다는 위험을 그대로 둔 선택이다(그 아홉도 각자 계기가 생기면 옮긴다).

**예외는 하나다.** 갈라도 계약의 자리에 못 가는 경우 — IME·OS 처리나 tree-sitter 타입(§3)과 얽혀 떼어 낼 수 없는 경우 — 에는 옮기지 않는다. 갈라서 옮길 수 있으면 갈라서 옮긴다. 예외가 단위의 일부에만 걸리면 나머지는 옮긴다. 갈라도 못 가는 것이 있으면(전부든 일부든) 계약을 바꾸는 일이라 사용자와 먼저 논의하고, 그 PR 에 사유를 적는다([pr-checklist.md](../pr-checklist.md) 전략 수정 규칙). 「함께 남기는」 것도 같은 문턱을 넘어야 한다. 배선의 크기는 기준으로 쓰지 않는다. 손으로 고른 경계에 결론이 달려 판정이 주관적이 되고, 결함이 가장 많은 함수를 면제하게 되기 때문이다.

**옮기는 순서** — 수정 커밋을 먼저, 이동 커밋을 나중에 둔다.
- 수정 커밋은 L4 자리에 회귀 test(결함의 재현 조건)를 더한다. 수정 커밋은 따로 머지해도 된다 — 사용자에게 보이는 결함을 이동 판단이 붙잡지 않는다.
- 이동 커밋은 그 test 가 이동 뒤에도 초록인 것으로 확인하고, 같은 재현 조건을 순수 test 로도 더한다(L2 로 가면 `src/session.zig` 의 `editor`·`lsp` 구조체에, 최상위 잎으로 가면 `src/maru.zig` 에 등록 — §3, 선례 `syntax_colors`·`scm_items`. 결함이 없는 단계의 조건은 편집기 계획의 test 규칙). 그래야 다른 호스트의 CI 도 그 판정을 잰다.
- 따로 머지한 수정 커밋의 후속 이동 PR 은, 언제 머지됐든(D1 결정 전이든 뒤든) 같은 계기로 본다.

**이 규칙을 다른 세션도 보게 한다.** 계약 이탈은 지금도 생긴다.
- #4294(`36a24ed70`)는 자동완성의 요청 정책(낡은 응답을 버리고 다시 묻기 `asked_shifted`, 확정 대기 중 재요청 금지, Esc 의 `cancel`)을 L4 `app_session/editor/completion.zig` 에 넣었다.
- type-over·surround 갈래는 계약(2026-08-09) 뒤인 2026-08-27(`83e8c12ec`)에 L4 로 들어왔다 — 그때의 `app_session/editor.zig` `insertText` 다. 그 본문은 2026-10-01(`d54521836`)에 `insertTextWithRange` 로 옮겨졌다.
- ① 의 함수들도 모두 계약 뒤에 쓰였다(§2).

그래서 [pr-checklist.md](../pr-checklist.md) 에 다음 한 줄을 둔다(이 PR 이 단다 — §5).
> 「`app_session`(허브 `app_session.zig` 포함)의 편집기 코드에서 편집 판정이나 클라이언트 정책(계산 클라이언트 제외)을 새로 쓰거나, 그 동작을 바꾸거나, 새 갈래를 더했거나, 다른 호스트가 그 함수를 쓰게 했다면 — 또는 다른 호스트에서 `app_session` 에 이미 있는 편집 판정과 같은 일을 새로 적었다면 — 그 순수 부분을 계약의 자리(대개 `src/session` L2, L3 타입을 읽거나 내는 순수 계산은 최상위 `src/*.zig`)로 옮겼는가? 수정만 먼저 머지했다면 후속 이동을 `docs/plans/native-editor.md` 에 할 일로 등록했는가? 갈라도 그 자리에 못 가는 경우라면 사용자와 논의하고 사유를 적었는가?」

자리는 둘이다. [pr-checklist.md](../pr-checklist.md) 「전략 영향 평가」 절의 질문 목록과, PR 작성자가 실제로 채우는 [PR 템플릿](../../.github/pull_request_template.md) 「전략 영향 평가」 체크박스다.

**판정자로 막는 수단은 아직 없다.** 이것은 자기 신고식이라, 같은 종류의 기존 항목이 #4294 와 `83e8c12ec` 를 막지 못했다. 후보로 본 줄 수 래칫(변경 리터럴 `.end = … .text =`·`waiting_seq` 가 있는 줄)은 셋이 걸려 이 계획에 넣지 않는다.
- #4294 꼴을 못 잡는다 — #4294 는 `waiting_seq` 줄을 늘리지 않고 새 필드 `asked_shifted` 와 기존 `pending_accept` 를 쓰는 조건으로 들어갔다.
- 배선 줄(`lsp.zig` 의 `termWaiting*`)이 섞인다.
- 기준값을 올리는 규칙과 「제품 줄」 정의가 따로 필요하다.

판정자를 세울지는 [plans/native-editor.md](native-editor.md) 의 할 일로 남긴다.

**무엇이 옮겨지고 무엇이 남는가**
- ① 은 단계를 따라 옮긴다. 문서 변경과 복사만 세면 `mod.zig` 에서 14 함수 876 줄이다(변경 리터럴 `.end = … .text =` 를 만드는 13 함수 819 줄과 `copySelection` 57 줄 — L4 편집기 제품 23.6k 줄의 약 3.7%). 여기에 `cutSelection`·선택 판정과 `mod.zig` 밖의 판정 셋(`conflict.confirmReload`·`backup`·`completion.accept`)이 더해진다(목록은 편집기 계획). 선택 판정은 Windows W8.3 의 남은 일(키보드 커서·단어 선택)이 계기 2 로 단계보다 먼저 부를 수 있는 자리다.
- ② 의 정책은 계기가 생길 때만 옮긴다. 옮겨도 배선이 남는다(LSP 표본 셋 중 둘에서 배선이 정책보다 크다 — 추정). 남는 배선은 `platform/macos` 의 호출 자리가 된다. 계기가 오지 않은 클라이언트 정책은 L4 에 무기한 남는다(§4).
- 계약을 지킨 새 코드도 있다(#4294 의 멀티 커서 합치기는 `session/lsp/completion.zig`, 공유 이력의 순수분은 `session/editor/history.zig`·`history/`). 그러나 같은 #4294 가 요청 정책은 L4 에 넣었다 — 그래서 위 pr-checklist 한 줄이 필요하다.

**지금까지의 판정과의 관계**
- 2026-06·2026-08-08 합의는 허브 배선(orchestration)을 L4 에 두었다(§1.1). 이 결정은 그중 편집 판정을 단계로, 「정책」을 두 계기에서 L2 로 옮긴다. 합의의 대상은 편집기가 아니었고 이 측정의 근거도 새것이라 사용자가 정했다(2026-10-11).
- layering §3 의 「추출 후 `platform/macos`엔 **L4 어댑터만** 남는다」, native-editor-layering §2 의 L4(「셀·quad lowering · 입력 이벤트 · IME」)와는 차이가 남는다. 배선과 허브(그리고 계기가 오지 않은 클라이언트 정책·계산 클라이언트)가 `platform/macos` 에 남기 때문이다. 이 차이는 이 권장이 처음 만든 것이 아니다. layering §3 2차 표가 이미 pane orchestration(`splitActivePane` 등)을 「platform 잔류」로 두었고, F 시리즈 orchestration 도 거기 남았다.
- [windows-platform.md](../windows-platform.md) :8908-8910 은 `app_session.zig` 가 하는 「정책과 조립」을 「그 정책은 플랫폼과 무관하다」고 적었다. 이 측정은 정책에는 그것이 맞고, 조립에는 결합이 있음을 보였다 — 배선은 빌드 결합(모듈 루트), 렌더는 OS 결합(CoreText)이다. 원문의 「그 정책」은 괄호 안의 판단(어떤 표면을 언제 열고 …)을 가리키므로 정책에 대해서는 맞는 문장이다. 다만 「정책과 조립」을 한데 말해 조립도 무관하다고 읽힐 수 있어, 원문 아래에 보충 블록(2026-10-11)을 달아 조립의 두 결합을 적었다.

### 1.4 편집기 계획으로 넘기는 것

① 의 목록·결함·할 일과 이동 단계는 [plans/native-editor.md](native-editor.md) 의 「다중 커서·여러 블록 편집 연산 결함과 계약 이탈」 절이 소유한다(이 계획 PR 이 등록한다). 이 문서 §2 에는 그 근거(실험·판정자 사각)만 남는다. 여섯째 후보(요청 규율 — ② 쪽 결함)의 재현도 그 절의 할 일이다.

### 1.5 자리 기준

| 자리 | 무엇 |
| --- | --- |
| **L2** `src/session/editor`·`src/session/lsp` | 문서·LSP 를 읽는 판정·정책·상태 전이 |
| **L3** `src/chrome` | 오버레이 상태와 그 상태만 읽는 판정 |
| **최상위 잎** `src/*.zig` | L3 타입을 읽거나 내는 순수 계산 — L2 와 L3 를 함께 읽는다(선례 `syntax_colors`·`scm_items`) |
| **`platform/macos`** | OS 어댑터 — 요청의 실행(프로세스·파일·클립보드), CoreText, ABI, AppKit 입력. 그리고 배선(L2 정책의 요청을 L3 상태와 실행부에 잇는 호출 자리)과 허브 |

§1.3 의 규칙으로 옮길 때 이 표가 자리를 정한다. 배선을 `src/app` 으로 옮기는 길은 이 규칙이 쓰지 않는다 — 그것은 D1 의 선택지가 아니라 W8 전략의 결정이다(§4 (라)).

- 정책을 L2 에 두는 이유는 import 금지다. session 은 `app`·`platform`·`pty`·`chrome` import 가 금지되어 실행부에 닿을 수 없다. `src/app` 에는 그런 규칙이 없다(layering §8 「의도적 혼합 레이어」).
- 그 금지는 `std.c`·`std.Io` 를 막지 않는다. 그래서 `platform/macos` 밖으로 옮긴 코드(L2 든 최상위 잎이든, 판정이든 정책이든)는 새 파일에 두고, 그 파일을 `tests/boundary/` 의 허용 목록 판정자에 등록한다. 꼴은 `ssh_sans_io` 다.
  - `std.<X>` 는 허용 목록 안이어야 한다. 옮길 코드가 쓰는 이름(예: 단계 1 의 `ArrayList`·`sort`·`unicode`)은 이유를 적고 연다. `c`·`posix`·`Io`·`fs`·`Thread`·`time` 은 열지 않는다. `extern`·`@cImport` 는 막는다.
  - import 는 `ssh_sans_io` 의 같은 폴더 규칙 대신 허용 목록으로 본다 — 옮긴 판정은 `terminal` 같은 다른 폴더를 읽는다. 허용은 L2 파일이면 `src/session` 아래와 `terminal`, 최상위 잎이면 배럴(`session.zig`·`chrome.zig`)과 `src/session`·`src/chrome` 아래, `terminal` 까지다(선례 `syntax_colors` 는 두 배럴을 import 한다). `root`·`builtin` 은 막는다.
  - 파일 목록으로 등록한다 — 그 폴더에는 OS 를 쓰는 기존 파일이 섞여 있어(예: `session/editor/backup.zig`·`edit_doc.zig` 가 `std.Io`·`std.c` 를 쓴다) 폴더를 훑을 수 없다. 그래서 새 파일을 목록에 올리는 것은 이동 커밋의 일이다. 기존 L2 파일에는 옮긴 코드를 넣지 않는다.
  - 최상위 잎은 import 규칙이 없는 자리라(§3) 이 판정자가 유일한 울타리다.
- [editor-surface-structure.md](../editor-surface-structure.md) §3(:72)의 원칙도 같다: 「L2는 file descriptor, DispatchSource, FSEvents, child process, AppKit/WebKit 타입을 몰라야 한다. … 실제 파일·git·watch·process I/O는 `src/app` 공통 runtime 또는 `src/platform/macos` adapter가 주입한다.」

## 2. 측정 (2026-10-10, `4e0503d53` — #4294 머지 직전 main)

**측정 방법** — 줄 휴리스틱이다. decomposition §6a 의 규율(`std.zig.Ast` 로 잰다 — 정규식 중괄호 맞추기는 구조체 끝을 지나친 적이 있다)과 다르다. 그래서 여기 수치는 방향을 보는 재료다. 결정에 쓰는 개수는 AST 로 정한다.
- **제품 줄**: 비어 있지 않고 주석이 아닌 줄. 최상위 `test` 블록(줄 머리 `test` 부터 줄 머리 `}` 까지)은 뺀다.
  - 파일 스코프의 test 헬퍼는 섞여 남는다. `editor/mod.zig` 의 경우 첫 test 뒤 2,425 줄의 대부분이 그렇다. 그래서 L4 수치는 상한이다.
- **test 줄**: 최상위 test 블록의 원시 줄. 빈 줄·주석을 포함한다.
- **필드**: 허브 `app_session.zig` 의 `TermRuntime`·`AppSession` struct 본문에서 4칸 들여쓰기 `이름:` 선언. 멀티라인 선언도 센다.
- **결합**: `app_session/editor/**` 제품 줄 중 그 식별자, 또는 `std.c.`·`std.posix.`·`extern "c"` 가 있는 줄.
- **시그니처**: `mod.zig` 의 `fn` 매개변수 목록 어디에든 `AppSession` 이 있는 것.
- **전이 폐포**: 상대 `@import("….zig")` 를 끝까지 따라간 집합. 모듈 import(`maru`·`syntax`)는 경계로 본다.

**편집기 코드가 사는 곳**

| 위치 | 파일 | 제품 줄 | test 줄 |
| --- | ---: | ---: | ---: |
| L2 `src/session/editor` | 50 | 6,537 | 7,108 |
| L2 `src/session/lsp` | 17 | 2,846 | 2,348 |
| L3 `src/chrome/components/editor_view` | 15 | 4,407 | 9,143 |
| L4 `platform/macos/app_session/editor` | 53 | 23,578(상한) | 50,540 |

`mod.zig` 에서 `AppSession` 을 받는 함수는 306 개, 제품 줄 약 6.5k 다(test 헬퍼 포함. 함수 범위·중첩 함수 처리에 따라 6,462~6,466). `src/session/lsp` 는 코덱과 순수 계산이다. 요청 상태기계(seq·조용 시계·낡은 응답 폐기)는 L4 클라이언트 파일에 있다(예: `app_session/editor/highlight.zig`·`fold_lsp.zig:18-80`). [editor-surface-tooling.md](../editor-surface-tooling.md) :1171 은 접기의 응답 검증(version 폐기·조용 시계 증가)을 「코드가 소유 — `session/lsp/fold_range.zig`」라고 적었었다(2026-10-11 이전 문구). 그 파일의 공개 함수는 `supportedFromResult`·`decode` 뿐이고 version 폐기·조용 시계는 없다. 그 칸은 2026-10-11 에 정정했다 — version 대조·「아직 아니다」·조용 시계 배수는 `fold_lsp.zig` 의 `onResponse`·`retryLater`, 항목 걸러내기·정렬·레벨은 `fold_range.zig` 의 순수 `decode` 다(두 파일은 같은 커밋 `72843ae94` 에서 났다).

**L4 편집기 코드의 결합**(제품 줄)

| 결합 | 성격 | 파일 | 줄 |
| --- | --- | ---: | ---: |
| `metal_dirty` | `bool` 출력 플래그(`app_session.zig:6435`) — OS 아님 | 28 | 177 |
| `chrome_host` | L3 `chrome.ChromeHost` — OS 아님 | 14 | 174 |
| libc 직접 | OS | 12 | 72 |
| `ime_*` | Swift 가 밀어 넣는 입력 상태 | 7 | 25 |

클라이언트별 `chrome` 결합(제품 줄 중 `\bchrome(\b|_)` 가 있는 줄):

| 클라이언트 | `chrome` 결합 |
| --- | --- |
| `completion` | 30(그중 `chrome_host.suggest_box` 줄 22) |
| `recovery`·`trust_ui` | 각 18 |
| `signature` | 12 |
| `rename`·`outline` | 각 10 |
| `hover`·`diff` | 각 23 |
| `references` | 9 |
| `highlight`·`definition` | 0 |

**OS 를 품은 편집기 상태**(필드 타입을 정의까지 따라감)

| 필드 | 품은 것 |
| --- | --- |
| `AppSession.editor_lsp` | `lsp_process.Process{pid, in_fd, out_fd}` |
| `AppSession.editor_project_search_live` | 검색 worker backend(`std.Thread.spawn`·`std.c.environ`) |
| `AppSession.editor_recovery`·`TermRuntime.editor_recovery` | 폐포가 session host lease(`owner_lease`)에 닿는다 |

- 나머지 필드가 품는 것은 허브 타입(`?*Term` 등)이나 L1 POD(셰이핑 결과 캐시)다.
- `TermRuntime.editor_syntax` 는 OS 가 아니지만 C 모듈 `syntax` 를 품어 배럴에 못 든다(§3).
- 필드 수: `TermRuntime` 152(`editor_*` 125), `AppSession` 814(`editor_*` 44).

**L2 짝 없는 판정**(`mod.zig` — native-editor-layering §2 의 「L2 `buffer.zig` 는 「텍스트 저장 + 편집 연산 + undo」인데 그 계약에서 벗어난 자리)

| 묶음 | 함수 | 순수 부분 | 남는 배선 |
| --- | --- | --- | --- |
| 줄 집합 연산 | 공유 잎 `selectedLineNumbers`(:9586 — 선택 → 줄 집합. toggle·delete·duplicate·move·indent 가 쓴다) + `moveLines`(:9863)·`deleteLines`(:9762)·`duplicateLines`(:9791)·`indentLines`·`toggleLineComment`(:9619) | 줄 집합 → 변경 목록. duplicate 는 사본 caret 계산을 포함한다 | `applyLineEdit`(:9718 — undo·스크롤 앵커·구문 통지·reveal). `toggleLineComment` 는 같은 순서를 직접 다시 적었다 |
| selection 연산 | `transformCase`·`insertNewlineKeepingIndent` — `applyLineEdit` 꼬리만 공유 | selection → 변경 목록 | 뒤의 것은 `insertText` 폴백이 배선이다 |
| 복사 | `copySelection`(:3529) | 구간 수집·빈 선택이면 줄 전체·정렬·`\n` 연결(약 35 줄). 조각 경계 기억·분배를 맡은 L2 자리 `session/editor/clipboard.zig` 옆에 둔다 | 활성 Term 조회·클립보드 쓰기 |
| 입력 조합 | `insertTextWithRange`(:8808, 코드 228 줄) | 변경 조합·정렬·겹침 거부·caret 재배치(IME-direct 제외, 약 100 줄) | 편집 적용·IME-direct(`DirectIMEState` 등 L4 타입)·preedit·undo |

줄 연산 일곱(줄 집합 연산 다섯 — `moveLines`·`deleteLines`·`duplicateLines`·`indentLines`·`toggleLineComment` — 과 selection 연산 둘)은 L4 타입 없이 L2 로 갈 수 있다.
- 쓰는 것은 `LineIndex`·`Selection`·`delta`·`language`(L2)와 `maru.terminal.selection` 의 대소문자 변환(`upperCase`·`foldCase` 등)이다. terminal 은 session 에 허용된다.
- L4 의존은 `SelectionIter`·`term.rt.*` 뿐이고, 둘 다 인자로 바꿀 수 있다.
- 이 함수들은 L2 자리(2026-08-09)와 native-editor-layering(2026-08-11)이 생긴 **뒤에** 쓰였다. 예를 들어 `toggleLineComment` 는 언어 판정만 L2 로 보냈다(`466bed2f4`, 08-27).
- 그래서 L4 에 남은 이유는 결합이 아니라 계약을 벗어난 것으로 보인다(추정 — 옮길 때 함수마다 확인한다).

**발견한 결함 — 근거(목록·할 일은 편집기 계획이 소유한다 — §1.4)**

모두 여러 커서·여러 블록·여러 줄에서 난다(결함 2 는 선택 하나로도 난다). 그 경우를 재는 판정자가 없다(각 항목의 「판정자 사각」).

1. **`duplicateLines` — 떨어진 블록을 여러 개 복제할 때 caret 이 어긋난다.**
   - 원인: 블록 k 의 caret 은 `delta.apply` 가 앞 블록 사본만큼 이미 밀었으므로 자기 사본 길이만 더해야 한다. 그런데 `:9842-9853` 이 **모든** 사본 길이의 합을 더한다. 첫 블록도 틀리고, 마지막 블록은 문서 끝을 넘을 수 있다.
   - 실험: 원본 `delta.zig` 를 복사한 독립 test 에서 caret 이 9·21 이었다. 기대는 6·16 이고, 문서 길이는 20 이다.
   - 판정자 사각: LN3.
2. **`deleteLines` — 마지막 내용 줄을 그 바로 앞 줄과 함께 지우지 못한다**(마지막 내용 줄은 `end_with_ending` 이 문서 길이와 같아 「앞 개행까지 먹는」 갈래(`:9776`)에 든다. 선택 하나로 걸쳐도 난다. 끝 개행이 있는 파일에서는 빈 마지막 줄도 그 갈래에 들어, {마지막 내용 줄, 빈 마지막 줄} 조합도 겹친다 — 이 조합은 커서 둘이 있어야 난다. 붙어 있지 않은 줄들은 정상이다).
   - 원인: 「문서 마지막 줄 — 앞 개행까지 먹는다」(:9777 주석)를 줄마다 따로 적용해 변경이 겹친다. 그래서 거절되고 아무 일도 안 일어난다.
   - 실험: `"a\nb\nc"` 에서 줄 {1,2} 를 지우면 `[2,4)·[3,5)` 가 나와 well-formed 가 거짓이다.
   - 판정자 사각: LN1·LN2.
3. **`insertNewlineKeepingIndent` — primary 가 뒤에 있고 커서 앞에 들여쓰기가 있으면 거절된다**(들여쓰기가 없으면 `any_indent` 가 거짓이라 정렬하는 `insertText` 로 넘어간다).
   - 원인: primary 를 먼저 쌓은 변경 목록을 정렬 없이 넘긴다(:10007-10030). `transformCase` 가 CS7 에서 고친 것과 같은 함정이다.
   - 실험: 커서 {10, 2} 로 well-formed 가 거짓.
   - 판정자 사각: LN6.
4. **`insertTextWithRange` — 문서상 첫 커서부터 primary 까지 중 일부만 type-over 하면 caret 이 어긋난다**(`selections()` 가 primary 를 먼저 내므로 정렬 전·후 인덱스가 갈린다. 모두 type-over 면 집합이 같아 어긋나지 않는다. extras 가 추가 순서라 정렬돼 있지 않은 경우는 따라가지 않았다).
   - 원인: `skip_overs` 는 정렬 **전** 인덱스(:8901)로 기록되는데, caret 루프는 정렬 **후** 인덱스(:9013)로 맞춘다.
   - 실험: `"a b)\n"` 에서 caret 이 3·4 로 갔다. 기대는 2·5 다.
   - 판정자 사각: AID6 은 primary 가 앞인 경우만 잰다.
5. **`insertTextWithRange` — 여러 커서로 감싸면 둘째 caret 이 첫 단어의 `)` 뒤로 간다.**
   - 원인: surround 는 커서 하나당 변경이 둘인데, caret 루프와 쌍 보정 루프(:9044)가 1:1 로 짝짓는다.
   - 실험: `"(aa) (bb)"` 에서 둘째 caret 이 4 였다.
   - 판정자 사각: AID7·AID3 은 내용만 잰다. 감싸기의 caret 을 재는 판정자는 없다(AID11 은 모든 커서가 type-over 인 경우의 caret 과, type-over·평범한 삽입이 섞인 경우의 문서 길이만 잰다).

실험은 원본 L2 파일을 복사하고 함수 본문을 옮겨 적은 독립 zig test 로 했다. 제품 빌드로는 확인하지 않았다.

계약의 단일 출처는 [native-editor-document-model.md](../native-editor-document-model.md) 다. 줄 조작·Enter 들여쓰기는 §3.9a 가, type-over·surround 는 §3.7 이 갖는다. 그래서 수정은 그 계약과 편집기 계획의 PR 로 한다.

**요청 규율의 반복**(`app_session/editor/*.zig` — `lsp.zig`·`mod.zig` 제외)

| 꼴 | 클라이언트 |
| --- | --- |
| `waiting`·`waiting_seq` 로 응답을 대조한다 | `code_action`·`completion`·`definition`·`fold_lsp`·`format`·`highlight`·`hover`·`inlay`·`references`·`rename`·`semantic`·`signature`·`smart_select`·`symbols` (14) |
| 위에 더해 조용 시계(`quiet_ms` 와 `last_edit_ms`/`last_move_ms`) | `fold_lsp`·`highlight`·`inlay`·`semantic`·`symbols` (5) |
| 그중 「실패하면 `dirty` 를 세우고 조용 뒤 다시」 | `fold_lsp`·`inlay`·`semantic`·`symbols` (4) — `highlight` 에는 `dirty` 가 없다(실패하면 `last_move_ms` 만 다시 적고, version·낱말 키가 갱신되지 않아 다시 묻게 된다). `fold_lsp` 만 오류·`null`·빈 응답이 이어지면 조용 시계를 두 배씩 늘린다(상한 7,680 ms) |

- 다섯의 `tick` 은 같은 꼴이다. `waiting` 이면 돌아가고, 조용 시계 안이면 돌아가고, 아니면 요청해 `waiting_seq` 를 적는다. `onResponse` 는 `!waiting or seq != waiting_seq` 면 버린다(예: `highlight.zig:84-116`·`inlay.zig:65-99`·`semantic.zig:54-91`).
- 실패 처리는 서로 다르다. `inlay`·`semantic` 은 `dirty` 와 시각을 다시 적고, `highlight` 는 시각만 다시 적는다. `fold_lsp` 는 오류 배수(`error_streak`)를 두고, `symbols` 는 빈 응답을 받아들인다. `inlay`·`semantic` 에는 덮은 범위(`covered_*`)가 따로 있다.
- 응답 decode 가 실패하면 다섯 모두 조용 시계 없이 다시 묻게 된다 — 여섯째 결함 후보(추정 — 코드 읽기, 실험 안 함).
  - `fold_lsp`·`inlay`·`symbols`: `dirty` 만 세우고 시각을 다시 적지 않는다.
  - `semantic`: 아무것도 하지 않는다(`semantic.zig:96` 의 `catch return`). 그래도 version·덮은 범위가 갱신되지 않아 다음 `tick` 이 곧바로 다시 묻는다(:59-65). `dirty` 만이 요청 이유였던 경우만 예외다.
  - `highlight`: `spans` 만 비운다(:133-136). `last_move_ms`·version·낱말 키가 그대로라 곧바로 다시 묻는다.
- 서버를 잃으면 `lsp.zig:1345-1373`(`releaseWaiting`)이 클라이언트 상태를 직접 고친다. `waiting`·`dirty` 를 함께 고치는 것은 넷(`semantic`·`inlay`·`symbols`·`fold_lsp`)이고, `highlight` 는 `waiting` 만, 그리고 세션 단위 `editor_completion` 의 `waiting`·`dirty` 도 고친다. 응답 라우팅은 `termWaiting*` 헬퍼 여섯(`lsp.zig:2289`·`:2322`·`:2330`·`:2338`·`:2347`·`:2385`)이 Term 마다 `waiting_seq` 를 훑어 한다(허브 순회라 L4 다).
- 이 규율은 허브 배선(②)의 정책이다(§4 D1). 여섯째 후보의 재현은 편집기 계획의 할 일이다(§1.4).

**orchestration 표본의 정책 대 배선**(추정 — 손으로 가른 것. 「남는 배선」에는 그 파일 밖의 줄도 넣었다: 요청 함수(`lsp.zig` 의 `requestDefinition` 등)·`mod.zig` 의 재수출·`lsp.zig:1667` 같은 되먹임. 그래서 두 열의 합이 파일 제품 줄 — `highlight` 124 · `definition` 70 · `signature` 238 — 보다 클 수 있다)

| 클라이언트 | 정책 | 남는 배선 |
| --- | --- | --- |
| `highlight` | 약 80 줄 | 약 55 줄 |
| `definition` | 약 30~35 줄(seq 대조·오버레이 밀어냄 버림·결과 없음/root 밖 분기) | 약 50 줄(import·질의 2 종·요청·실행·이동 결과 되먹임·재수출) |
| `signature` | 약 45 줄(`waiting`·`dirty`·`asked_*`·`active` 전이) | 약 4 배 — 그중 `buildLines` 는 L2 를 L3 타입으로 바꾸는 순수 계산이라 정의상 최상위 잎 후보다(빼도 3 배가 넘는다 — 추정)(`caretAnchor`·`visibleEditorTerm`·`hover_box` 조작·hover 와의 상자 다툼·L3 타입 `hover_box.Line` 을 만드는 `buildLines`) |

**클라이언트가 `AppSession` 에서 쓰는 것**(제품 줄 기계 집계)

| 묶음 | 클라이언트 |
| --- | --- |
| 허브를 import 하지 않음 | `syntax.zig`(`mod.zig` 의 별칭 `syntax_color`)·`diagnostics` |
| 계산(OS·LSP 부작용 없음, 캐시 갱신만) | `guides`(`allocator`·설정 bool 둘) · `brackets`·`sticky`(설정·포커스·셀 높이·`metal_dirty` — `syntax.zig` 를 거쳐 `syntax` 모듈에 의존) |
| 문서 조작(② — LSP 편집 응답의 적용) | `workspace_edit` |
| LSP 요청 | `semantic`·`fold_lsp`·`inlay`·`symbols`·`highlight`·`smart_select` |
| 알림·오버레이·네비게이션 | `lsp`·`hover`·`definition`·`references`·`signature`·`format`·`rename`·`completion`·`code_action`·`recovery`·`trust_ui`·`outline`·`search/dock`·`diff`·`merge` |

예: `definition`(제품 70 줄).
- 공개 함수는 `*AppSession`·`*Term` 을 받는다.
- 밖으로 부르는 것(L2 함수·`term.rt` 접근자 제외)은 8 개다. 부작용 4(`requestDefinition`·`navigateTo`·`showNoticeKey`·`showNoticeFmt`)와 질의 4(`activePane().activeTerm()`·`sticky_client.rowAt`·`hitTestBodyModeWithSession`·`responseWouldDisplaceOverlay`)다.
- 응답은 `app_session/editor/lsp.zig:1667` 이 거꾸로 불러 들어온다.
- 쓰는 타입 중 chrome·OS 는 없다. `NavTarget`/`NavError`(`mod.zig:380-401`)는 L2 타입 하나만 품는다.

**import 전이 폐포**: `app_session/**` 83 파일을 겹치지 않게 나누면 허브에 닿는 것 64, 허브에는 안 닿고 libc 에 닿는 것 10, 닫힌 것 9 다(위 「libc 직접 12 파일」은 `app_session/editor/**` 만 센 다른 집계로, 허브에 닿는 파일도 포함한다).

**Windows**: 편집기 표면은 `src/main.zig` 에 있다(`OpenFile`:4271 · `buildComposedEditor`:4455 — 읽기 전용). W8.3 의 드래그 선택은 스모크 안 지역 상태이고, CR 을 벗긴 가상 축을 쓴다(main.zig:16862·16901). 그래서 W8.3 의 남은 「복사」가 macOS 의 복사 판정을 함께 쓰려면 먼저 세 가지가 필요하다.
- 선택을 `OpenFile` 로 올린다.
- 실제 byte 축으로 바꾼다.
- L2 `LineIndex` 를 둔다(지금의 `OpenFile.line_starts` 는 CR 을 벗긴 가상 축이다).

**(라)의 비용** — 배선·허브를 `src/app` 으로 옮기면 무엇이 따라오는가(2026-10-11 측정. 소스는 위와 같은 `4e0503d53` — 이 계획의 브랜치는 문서만 바꾼다).
- **측정 방법**
  - 허브 줄: 위 「제품 줄」 정의.
  - 직접 간선: 허브와 `app_session/**`(84 파일)의 상대 `@import("….zig")` 중 그 84 밖의 `platform/macos` 파일을 가리키는 것. 최상위 test 블록 안의 import 는 따로 셌다.
  - 폐포: 위 「전이 폐포」 정의(허브에서 시작, test 블록 안 import 포함 — 「두 모듈」 오류는 test 블록에서도 난다, §3).
- **허브** `app_session.zig` 는 96,955 줄, 그중 제품 줄 17,546 이다.
- **편집기 배선만 떼어 낼 수 없다.** `app_session/editor/**` 53 파일 중 38 이 허브를 상대 import 한다. 그 파일을 옮기면 허브가 따라오거나 인터페이스 뒤로 가야 한다(그대로 두면 허브가 두 모듈에 걸린다 — §3, 추정).
- **허브와 `app_session/**` 가 직접 import 하는 다른 `platform/macos` 파일은 39 개다**(import 줄이 test 블록 안에 있는 것 1 — `chrome/lab.zig`. `test_env.zig` 는 import 줄이 파일 스코프지만 쓰는 곳은 test 블록뿐이다). 예:
  - 렌더: `coretext_frame_builder`·`coretext_shaper`·`coretext_smoke_bridge`·`chrome/metal_lowering`·`chrome/chrome_draw_lowering`·`chrome/system_text`
  - 프로세스·백엔드: `lsp_process`·`git_backend`·`file_tree_backend`·`file_tree_mutation_backend`·`agent_*_backend` 여섯·`ssh_upload`·`remote_watch`
  - OS 서비스: `global_hotkey`·`update_check`·`shell_integration`·`session_host.zig`·`session_host/owner_lease.zig` 등
- **폐포는 332 파일이다.** 허브와 `app_session/**` 84, 다른 `platform/macos` 248(그중 `session_host/` 208).
  - 그 248 의 대부분은 간선 하나에서 온다. `session_host.zig` 간선을 막고 다시 세면 48 이다 — 200 은 그 파일을 거쳐서만 닿는다. `session_host.zig` 를 직접 import 하는 것은 허브와 `app_session/workspace.zig` 다. 편집기 파일은 직접 import 하지 않지만 `pane.zig`·`term.zig` 등을 거쳐 `workspace.zig` 에 닿아서, 허브를 막고 세어도 편집기 53 파일 중 37 이 그 간선에 닿는다(`workspace.zig` 를 막으면 0).
  - 편집기 쪽을 묶는 것은 OS 보다 L4 안의 결합이다. `app_session/editor/**` 53 파일 중 허브를 import 하는 것 38, `app_session/pane.zig` 23, `app_session/term.zig` 13.
- **뜻**
  - 다른 호스트가 `src/app` 의 허브를 쓰려면 배럴 `src/app.zig` 가 그것을 import 해야 한다(그 배럴은 파일을 손으로 나열한다). 그러면 `maru.app` 으로 나가고, `check-targets` 의 walker 가 그 공개 선언을 Windows 로 분석해 OS 전용 호출이 하나라도 닿으면 그 트리플이 깨진다(§3 의 2026-10-11 실험과 같은 길). 배럴에 넣지 않으려면 새 모듈이 필요하다(§6 「새 모듈」).
  - 그래서 (라)의 실체는 폴더 이동이 아니라 「허브가 닿는 OS 진입점을 인터페이스 뒤로 빼는 것」이다. 그 진입점 수는 세지 않았다(위 39 파일이 상한 쪽 단서다 — 추정).

## 3. 빌드 그래프와 경계 (옮길 때 지켜야 할 것)

- **참조된 선언만 분석된다.**
  - 실험: 참조 안 된 함수 안의 `std.c.fork()`·없는 모듈 import 가 exit 0.
  - 그래서 libc 를 쓰는 `app` 을 배럴(`src/maru.zig`)이 내보내도 wasm 이 멀쩡하다.
  - 게이트는 둘이다. OS 셋은 `check-targets`(`build.zig:1544`, `cross_target_surface.zig` 가 배럴의 공개 선언을 끌어당긴다)가 지킨다. wasm 은 mise 태스크 `check-wasm-sync`(`.mise.toml:409`)가 지킨다.
  - layering §3.4 표(2026-08-25)의 「배럴(`src/maru.zig`)로 우회하면 **wasm 이 깨진다**」는 깨지는 게이트를 잘못 적은 것이었다. 실험(2026-10-11): 배럴에 `std.c.fork()` 를 부르는 공개 함수 하나를 걸자 `check-targets` 는 `x86_64-windows` 에서만 실패했고(`type 'void' not a function`, 참조 경로 `cross_target_surface.zig` 의 `refAllRecursive`), `check-wasm-sync` 는 해시 그대로 OK 였다. 그 표의 행 머리를 고치고 표 아래에 정정 블록을 달았다. 결정(옮기지 않는다)은 그대로다 — 「배럴 우회가 게이트를 깨뜨린다」는 결론과 나머지 세 행이 서 있다.
- **「두 모듈」 오류는 즉시 난다.**
  - 실험: 참조 안 된 선언이나 test 블록 안의 상대 import 한 줄로도 `file exists in modules …` 가 난다.
  - 그래서 이동 단위는 import 닫힘이다. 그 파일을 읽는 쪽도 같은 PR 에서 모듈 경유로 바꾼다.
  - 배럴 안 파일은 `@import("maru")` 를 쓸 수 없으므로 상대 import 로 쓴다.
- **tree-sitter 를 쓰는 코드는 배럴에 못 든다.** `build.zig:305-` 가 C 모듈 `syntax` 를 일부러 `maru` 에 매달지 않았다. 그 코드(`syntax`·`diagnostics`·`brackets`·`sticky` 등)는 빌드 제약 때문에 지금 자리에 둔다. 옮기려면 새 모듈 결정(layering §3.4 의 「두 번째 배럴」)이 먼저다.
- **경계 규칙**
  - session 행은 `chrome`·`app`·`platform`·`pty` import 와 macOS 타입 이름을 막는다. `terminal` 은 허용하고, `std.c`·`std.Io` 는 막지 않는다.
  - chrome 행은 `session`·`terminal`·`renderer`·`app`·`pty`·`platform` import 를 막는다(`tests/boundary/imports.zig:4073-4080`).
  - 그래서 문서·LSP 와 오버레이를 함께 읽는 코드는 둘로 처리한다. 정책·상태 전이라면 셋으로 가른다: 정책(L2), 오버레이 상태(L3), 그 둘을 잇는 배선(`platform/macos` 의 호출 자리). 값만 내는 순수 계산이라면 최상위 잎에 둔다(§1.5).
  - 최상위 잎과 `src/app` 에는 import 규칙이 없다.
  - `cross_target_surface` 는 제네릭 함수 본문을 덮지 못한다. 그래서 정책을 `comptime` 제네릭으로 만들면 그것을 인스턴스화하는 test 를 둔다.
- **새 L2 파일은 `src/session.zig` 의 `editor` 구조체(LSP 쪽은 `editor.lsp`)에, 새 최상위 잎은 `src/maru.zig` 에 등록한다**(선례 `syntax_colors`·`scm_items` — `maru.zig` 의 `refAllDecls` 가 그 test 를 싣는다). 등록된 파일이 import 하지 않는 새 파일은, 등록하지 않으면 그 test 가 집계 밖이다(`session.zig:284-285` — 실험: 등록된 파일이 import 한 미등록 파일의 test 는 실린다).
- **문자열로 읽는 판정자**(이동 PR 마다 전후 실행 수로 확인)
  - `tests` 의 `"src/platform/macos/app_session…"` 181 회
  - `imports.zig` 의 `term.rt.editorDocument()` 리터럴
  - `tools/*-app/fixture.zig.inc` 5 · `tools/shared-ime-gpu/*.zig.inc` 5
  - 허브 digest 원장
  - 개수 판정자는 단언을 옮기지 않고 쪼갠다(새 자리 N, 원래 자리 0).

## 4. 결정

| # | 무엇 | 선택지 | 결정(사용자 2026-10-11) |
| --- | --- | --- | --- |
| **D1** | 편집기 코드의 순수 판정·정책(① 과 ② 의 정책)을 언제 계약의 자리로 옮길 것인가 | (가) 옮기지 않는다 — 지금 자리에 둔다 / (나) §1.3 의 두 계기에서 옮긴다 / (다) 계획을 세워 지금부터 차례로 옮긴다 | **① 편집 판정은 (다), ② 의 정책은 (나).** 배선째 `src/app` 으로 옮기는 길((라))은 D1 의 선택지가 아니다 — 아래 |

- **① 을 (다)로 정한 이유** — 질문의 목적이 다른 호스트로의 이식이 아니라 계약대로의 배치였다(§1 의 사용자 질문 「앱세션은 macOS 폴더에 있어야 할 이유가 있어요?」).
  - 먼저 권한 안은 (나)에 전환 조건(다른 호스트에서 문서 변경을 적용하는 첫 PR 이 오면 남은 것을 옮긴다)을 붙인 것이었다. 그 근거는 두 번째 소비자가 API 의 모양을 확인할 수 있다는 것이었는데, 권장 검증 22 에서 서지 않았다(§7).
    - 다른 호스트가 부르는 함수는 계기 2 로 그 PR 에서 어차피 옮겨진다. 전환이 더 옮기는 것은 그 호스트가 부르지 않는 나머지이고, 그 모양은 전환 때도 소비자 하나로 정해진다.
    - (나)의 첫 사례(결함 수정)도 L2 API 를 소비자 하나로 정한다. 옮긴 뒤 API 를 고치는 비용은 L2 안의 변경이라 §3 의 이동 고정비가 다시 들지 않는다(추정).
  - 그러면 미룰 이유는 「다른 호스트가 끝내 편집을 안 하면 옮긴 것이 이식에 쓸모없다」 하나다. 목적이 배치면 이 이유는 서지 않는다. 다른 호스트의 문서 변경 편집도 아직 없다 — [plans/windows-platform.md](windows-platform.md) W8.17⒜(「편집(캐럿·선택 입력·undo)과 safe-save」)는 미착수이고, 2026-08-29(`2325bccdd` — 가로 스크롤) 뒤 Windows 편집기(`src/main.zig`)를 바꾼 기능 커밋은 표시 쪽이다(`c7c3f438f` 구문 색 2026-09-05. `821ddc941`(2026-09-12)은 macOS 설정 기능이 Windows 가로 상한 상수를 함께 바꾼 것이다).
  - 기다리는 동안에도 이탈은 쌓인다. 자기 신고식은 #4294·`83e8c12ec` 를 막지 못했다(§1.3).
  - 양이 작다 — 문서 변경과 복사 14 함수 876 줄(L4 편집기 제품 줄의 약 3.7%)에 `cutSelection`·선택 판정과 `mod.zig` 밖의 판정 셋(`conflict.confirmReload`·`backup`·`completion.accept`)이 더해진다(§1.3).
  - 언제 옮기든 드는 비용이 셋 있다. 앞의 둘은 단계가 다룬다.
    - 판정자가 재지 않는 조건이 많다. 결함 다섯은 모두 기존 판정자가 재지 않는 조건(여러 커서·여러 블록·caret·primary 가 문서상 뒤, 결함 2 는 줄 조합)에서 나왔다(§2 「판정자 사각」). 그래서 단계마다 그 조건의 test 를 먼저 둔다(편집기 계획 「이동 단계」의 test 규칙).
    - `mod.zig` 는 2026-10-01(`221660816`)에 옮겨진 뒤 origin/main `79249d66b`(2026-10-11) 까지 101 커밋을 받았다. 그래서 단계를 작게 자른다.
    - 이동마다 고정비(import 닫힘·허용 목록 판정자·문자열 판정자 전후 확인·digest 원장 — §1.5·§3)가 붙는다. 단계를 작게 자르면 단계마다 붙고, (나)였어도 이동마다 붙는 비용이다.
- **② 를 (나)로 둔 이유**
  - 편집기 계약(native-editor-layering §2)이 L2 로 정한 것은 ① 이다. ② 의 정책은 기존 합의가 L4 에 둔 orchestration 의 일부이고(§1.1), L2 로 보내는 것은 이 측정의 판단이다(§1.2). 그리고 표본 셋 중 둘에서 배선이 정책보다 크다(§1.2 — 추정).
  - Windows 계획에는 LSP 가 없다(`docs/plans/windows-platform.md`·`docs/windows-platform.md` 에서 낱말 단위 grep 0 건). 그래서 LSP 클라이언트에는 계기 2 가 오지 않는다. 계기가 오지 않은 클라이언트 정책과 `waiting_seq` 복사본 아홉(§1.3)은 L4 에 무기한 남는다 — 받아들인 결과다.
- **(가)를 고르지 않은 이유** — ① 의 계약 이탈을 그대로 두게 된다. 결함 다섯이 그 자리에서 나왔다.
- **(라)는 D1 의 대안이 아니다.** 배선·허브를 옮기는 것은 「다른 호스트가 macOS 의 허브·배선을 함께 쓰는가」라는 W8 전략의 결정이다. W8 은 지금 중립 로직(chrome·session)을 Win32 호스트에 각자 배선하는 길을 골랐다([windows-platform.md](../windows-platform.md) 「그래서 W8 은 표면 단위로 자른다」).
  - 비용은 §2 「(라)의 비용」이다. 편집기 배선만 떼어 낼 수 없다 — 편집기 53 파일 중 38 이 허브를, 23 이 `pane.zig` 를 import 한다. 허브를 옮기면 그 폐포가 다른 `platform/macos` 파일 248 개에 닿는다(그중 200 은 `session_host.zig` 간선 하나를 거친다 — 편집기도 `workspace.zig` 를 거쳐 거기 닿는다). 모듈 루트(`build.zig` 의 `app_host_abi.zig` — :1732·:2194·:2332)도 바꿔야 한다.
  - (라)만으로는 ① 의 계약 이탈이 풀리지 않는다. `src/app` 은 import 규칙이 없는 자리라(§1.5) 판정·정책이 실행부와 섞인 채 옮겨질 수 있다. 정책·판정은 어느 쪽이든 L2 로 따로 뗀다.
  - 그래서 정책·판정을 먼저 빼 두는 것은 (라)를 막지 않는다. 이 계획은 (라)를 정하지 않고, 그 물음을 W8 전략 단락에 넘겼다(§5). 지금의 W8 전략으로는 다른 호스트가 허브·배선을 함께 쓰지 않는다. 바꾸려면 사용자 결정이다.
- **단계** — ① 의 이동 단계와 순서는 편집기 계획이 갖는다(§1.4). 결함이 있는 것부터다 — 단계 1·2 가 결함 1~5 를 품고, 결함이 있는 단계는 수정 커밋이 먼저다. 단계는 서로 기다리지 않는다.
  - 결함 4·5 의 `insertTextWithRange`(단계 2)는 caret 루프 안에 IME 분기가 있어 예외 후보다. 가르면 옮길 수 있는지 그 PR 이 먼저 확인하고, 안 되면 사용자와 논의한다.
- **② 의 첫 사례** — 여섯째 후보(decode 실패 뒤 조용 시계 없는 재요청)를 고치는 PR 은 계기 1 이다. 다섯 클라이언트의 같은 꼴을 한 번에 고치므로 다섯을 함께 옮긴다. 그중 `symbols` 는 tree-sitter 타입(`syntax.Provider.Symbol`)을 상태에 두므로 예외 후보다.
- **새 이탈** — 막는 판정자를 세울지는 편집기 계획의 할 일이다(§1.3).

## 5. 문서를 고치는 규칙

1. **결정의 기록** — D1 은 2026-10-11 에 정해졌고, 이 PR 이 기록한다. 결정이 닿는 원문 뒤에 결정 블록과 짧은 줄을 덧붙이고, 원문은 지우지 않는다(decomposition :138 「근거로 보존한다」 관례). 짧은 줄의 문구는 그 줄이 원문이다 — 여기에는 내용만 적는다.
   - **결정 블록**은 decomposition §4 에 둔다. (b) 축(순수분을 L2 로)의 결정은 decomposition 이 2026-06·2026-08-08 에 기록해 온 관행을 따른다.
     - 자리: (b)·(c) 결정 기록(2026-08-08 블록 :128-138 과 그 아래 2026-06 기록·E 표, :140-150)이 끝난 뒤, `### 4.1` 앞.
     - 문구: 「2026-10 결정(사용자 2026-10-11) — 편집기의 편집 판정은 지금부터 단계를 세워 차례로 계약의 자리(대개 L2, L3 타입을 읽거나 내는 순수 계산은 최상위 잎)로 옮긴다. 그 단계는 [native-editor.md](native-editor.md) 의 「다중 커서·여러 블록 편집 연산 결함과 계약 이탈」 절이 갖는다 — 이 문서의 분해 단계와 별개로, 편집기 계약을 따르는 이동이라서다. 클라이언트 정책(계산 클라이언트 제외)은 그 의미를 바꾸는 PR 이나 다른 호스트가 그 함수를 필요로 하는 PR 에서 옮긴다. 계기가 오지 않은 클라이언트 정책과 계산 클라이언트, OS 결합은 `platform/macos` 에 남는다. 배선·허브도 `platform/macos` 에 둔다 — 지금의 W8 전략으로는 다른 호스트가 함께 쓰지 않고, 바꾸려면 사용자 결정이다. 사유·예외: [app-session-portability.md](app-session-portability.md) §1.3·§4」.
   - **짧은 줄**을 덧붙인 곳과 그 내용:
     - layering §3.3 의 (b) 「일단락」 문장 뒤, decomposition 의 「(b) 축(이식 기여)은 b1·b2(`layout_math`)로 일단락된 상태 그대로다」 문장 뒤, decomposition §6 첫 항목의 「그 축은 일단락 상태다」 뒤 — 편집기 코드에 대해 재개했고 근거는 2026-10 블록이다. decomposition 원문은 :128 에서 「(b)의 "일단락"을 해제한다」, 위 문장에서 「일단락된 상태 그대로다」라고 적는다. 둘 다 같은 커밋 `252140cda` 에서 쓰였고, 해제한 것은 분해 중단이고 유지한 것은 순수분의 일단락 판정이다(§1.1). 재개 줄은 후자에 단다. decomposition §7 경계 표가 이식 위상을 layering §3.3 에 두므로 layering 에도 단다.
     - layering §3 2차의 「`platform/macos`엔 **L4 어댑터만** 남는다」 뒤와 native-editor-layering §2 의 L4 줄 뒤 — 배선·허브, 계기가 오지 않은 클라이언트 정책, 계산 클라이언트는 남는다(2026-10 블록).
     - [pr-checklist.md](../pr-checklist.md) 「전략 영향 평가」 절의 질문 목록과 [PR 템플릿](../../.github/pull_request_template.md) 「전략 영향 평가」 체크박스 — §1.3 의 한 줄(글자 그대로).
     - [windows-platform.md](../windows-platform.md) W8.3 행(남은 일을 「배선」이라 적은 자리) — 그중 판정은 이식 계획 ① 이라 계기 2 로 계약의 자리(대개 L2)로 옮기고, 남는 것만 배선이다.
     - [windows-platform.md](../windows-platform.md) 「그래서 W8 은 표면 단위로 자른다」 단락 뒤 — 허브·배선을 다른 호스트가 함께 쓸지(§4 의 (라))는 지금 이 전략에서 함께 쓰지 않는 것이고, 바꾸려면 사용자 결정이다. 비용은 §2 「(라)의 비용」.
     - [plans/native-editor.md](native-editor.md) 의 해당 절 — 결정과 이동 단계.
     - decomposition §7 — 단락의 「사용자 결정 대기」를 결정으로, 경계 표 행의 소유 서술을 「결정 블록은 이 문서 §4, 편집 판정의 이동 단계는 편집기 계획」으로.
2. **이 계획 PR 이 함께 기록하는 것**
   - [plans/native-editor.md](native-editor.md) 에 ① 의 목록·결함·할 일을 등록한다.
   - decomposition §7 의 경계 표에 이 계획을 한 줄 등록하고, 그 절의 단일 출처 문장 뒤에 한 단락을 덧붙인다(문구는 그 단락이 원문이다).
3. **상태** — 머리에는 [pr-checklist.md](../pr-checklist.md) 어휘(미착수·보류·완료)만 쓴다. 측정·권장과 D1 의 기록이 끝나 「완료」다. 이 계획은 측정 기록으로 남는다. ① 의 이동은 편집기 계획이, 규칙은 decomposition 의 블록이 추적한다.

## 6. 하지 않는 것

- 배선·허브의 이동 — W8 전략의 결정이다(§4 (라)). 그 비용만 §2 에 남긴다. 계산 클라이언트(③)의 이동.
- 클라이언트 정책을 두 계기가 아닌 PR 에서 따로 옮기는 것(따로 머지한 수정의 후속 이동은 계기로 본다 — §1.3). 편집 판정은 편집기 계획의 단계를 따른다.
- 편집 판정의 수정 설계 — 편집기 계획의 몫이다(§1.4).
- libc 를 직접 쓰는 백엔드(`git_backend` 등) — 2026-08-25 결정 그대로다.
- Windows·Linux 호스트 구현과 W8.3 의 선택 상태 승격 — [windows-platform.md](../windows-platform.md) 의 몫이다.
- 렌더 백엔드 이식.
- 새 모듈.

## 7. 적대적 검증 이력 (2026-10-10~11)

**결론의 변천**
1. 새 모듈 `app_core` 로 옮기는 6 단계 계획(처음)
2. 실측 뒤 결정(4~6회차)
3. 데이터 분할 선행(7)
4. 보류(8)
5. 좁은 L4 쪽 정합(9)
6. L4 2단 유지 + `src/app`(10)
7. 정책은 L2, 판정 잎부터(11~21)
8. 권장 검증 1~3 — orchestration 을 옮기자는 권장이 차례로 뒤집혔다
9. 권장 검증 4·6 — 「조건부 유지」, 조건을 반영
10. 권장 검증 5 — 새로 넣은 수정·판정자 설계에서 결함이 나와 덜어냈다
11. 권장 검증 7 — 「조건부 유지」. ① 과 ② 의 정책에 같은 논리를 쓰라는 조건 → 규칙 하나(의미를 바꾸는 PR 에서 L2)로 합쳤다
12. 권장 검증 8 — 「조건부 유지」. 반영한 조건:
    - 배선 크기 기준을 뺐다(주관적이고, 결함이 가장 많은 함수를 면제한다).
    - 다른 호스트를 둘째 계기로 명시했다.
    - 요청 규율은 다섯 클라이언트를 함께 처리한다.
    - 규칙을 `pr-checklist.md` 에 둔다.
    - 커밋 순서는 수정 → 이동이다.
    - 허브에 대한 답을 「본질적 이유는 거의 없고 배치·비용 때문」으로 고쳤다.

13. 권장 검증 9 — 「조건부 유지」. 반영한 조건:
    - 「새 코드는 계약대로」는 틀렸다 — #4294 가 요청 정책을 L4 에 넣었고 type-over·surround 갈래도 계약 뒤에 L4 로 들어왔다 → pr-checklist 한 줄을 결정의 일부로, 새 함수·새 갈래까지 덮게.
    - 함께 옮기는 단위를 「바꾸는 코드를 공유하는 함수 전부」로 정했다(요청 규율 특례는 없앴다).
    - 함께 남기는 것도 예외 문턱을 넘게 했다.
    - 수정 커밋은 따로 머지해도 된다.
    - 예외에 tree-sitter 를 넣고 ③ 을 규칙 밖으로 명시했다.
14. 권장 검증 10 — 「조건부 유지」(약점은 문구 수준). 반영한 조건:
    - 공유 잎은 순수 잎만 — 배선 잎 `applyLineEdit` 를 바꾸는 것은 계기가 아니고, 결함 3 은 순수 쪽에서 고친다.
    - 자기 신고식 한 줄만으로는 #4294 같은 이탈을 못 막았다 → 변경 리터럴·`waiting_seq` 줄 수 래칫을 더했다(권장 검증 11 에서 덜어냈다).
    - 이동 커밋이 L2 순수 test 를 더한다.
    - 예외가 단위 일부에만 걸리면 나머지는 옮긴다.
    - 예외 문구를 「갈라도 못 가는 경우」로 바로잡았다.
    - 이동 비용은 「같다」가 아니라 건마다 고정비가 붙는다.

15. **권장 검증 11 — 「조건부 유지」.**
    - 새로 넣은 래칫이 #4294 꼴을 못 잡고, 배선 줄이 섞이고, 기준값을 올릴 길이 없었다 → 덜어냈다. 판정자는 편집기 계획의 할 일로.
    - 따로 머지한 수정의 후속 이동은 시점과 무관하게 계기로 본다.
    - 편집기 계획 라벨은 이동까지 끝나야 뗀다.
    - (라) 기각 사유를 모듈 루트·비용으로 고쳤다.
    - (다)·(라)일 때 단계는 decomposition 이 갖는다.

16. **권장 검증 12 — 「조건부 유지」(단위·범위 문구).**
    - 옮기는 정책 상태를 쓰는 함수(`releaseWaiting`)를 단위에 넣었다.
    - 선택을 바꾸는 판정을 ① 에 넣었다.
    - pr-checklist 한 줄이 다른 호스트에서 같은 판정을 다시 적는 경우도 묻고, 자리를 「전략 영향 평가」로 정했다.
    - L4 에 남는 `waiting_seq` 복사본 아홉을 정직하게 적었다.

17. **권장 검증 13 — 「조건부 유지」(규칙이 닿는 자리).**
    - Windows 문서가 W8.3 의 남은 일을 「배선」이라 불러 계기 2 가 걸리지 않을 수 있다 → 결정 PR 이 그 자리에 한 줄을 덧붙인다.
    - 수정만 먼저 머지한 PR 은 후속 이동을 할 일로 등록하게 했다(사용자 논의는 「갈라도 못 가는 경우」에만).
    - 한 줄을 PR 템플릿 체크박스에도 둔다.

18. **권장 검증 14 — 「조건부 유지」(조건 하나, 나머지는 사소).**
    - pr-checklist 한 줄의 범위를 허브(`app_session.zig`)까지 넓혔다. 허브에도 편집기 정책 갈래가 있다 — 예: `closeEditorHelpersBehindOverlay` 의 확정 보류 자동완성 갈래.
    - (나)의 이유 목록에서 (나)만의 이유가 아닌 것을 덜어냈다.

19. **권장 검증 14 의 모순 정리.**
    - (나)의 이유 문구를 계기 규칙과 맞췄다.
    - checklist 를 「어느 선택지든」이라 한 문장을 지웠다(그 줄은 (나)일 때 둔다).
    - 머리·제목의 「결론」을 「권장」으로 바꿨다.

20. **권장 검증 15 — 공격 리뷰어 「권장 유지」.** 남은 문구 둘을 고쳤다.
    - 편집기 계획의 이동 할 일에 허용 목록 판정자를 넣었다.
    - checklist 한 줄의 「그 계획」을 이름으로 적었다.

21. **권장 검증 15 의 모순 정리.** 머리의 소유 서술, 예외 문장의 「그때는」, (다) 줄의 옛 표현, checklist 괄호와 링크, 허용 목록 판정자의 대상(L2 로 옮긴 파일 전부).

22. **권장 검증 16 의 모순 정리.** 머리 상태를 「보류」로(남은 것은 결정뿐), 결정 PR 이 고칠 자리에 decomposition §7 단락과 편집기 계획 절의 「사용자 결정 대기」를 넣었다.

23. **권장 검증 17 의 모순 정리.** 규칙의 목적지를 「계약의 자리(대개 L2, L3 타입을 내는 순수 계산은 최상위 잎)」로 통일했다. 허용 목록 판정자를 `platform/macos` 밖으로 옮긴 파일 전부에 두었고, 편집기 계획 라벨 조건을 D1 결과별로 나눴다.

24. **권장 검증 18 의 모순 정리.** 「계약의 자리」를 문서 밖으로 나갈 문구(checklist 한 줄·decomposition 단락·결정 블록)에도 적었다. `signature` 의 `buildLines` 를 순수 계산으로 다시 분류했다.

25. **권장 검증 19 — 모순 리뷰어 「확인된 모순 없음」.** 경미한 긴장 둘을 문구로 정리했다(결함 3 의 정렬 자리는 이동 규칙의 귀결이라고 밝혔고, windows-platform 원문과의 차이는 해석 확인 대상으로 적었다).

26. **사용자 질문(2026-10-11) 둘** — 「장기적으론 (다)로 해야 하지 않나」·「배선째 `src/app` 으로 옮겨도 되지 않나」. 권장을 「(나), 전환 조건이 서면 (다)」로 바꿨다. (라)는 D1 의 대안이 아니라 W8 전략의 결정으로 다시 적고, 그 비용을 실측했다(§2 「(라)의 비용」).
27. **권장 검증 20** — 공격 리뷰어 「조건부 유지」. 전환 조건을 알아보는 자리를 W8.3 행에서 W8.17 행으로 옮기고 조건을 「문서를 바꾸는 편집」 하나로 통일했다(문서마다 「편집을 다루기」·「입력이나 LSP 요청」으로 갈려 있었다). 편집이 시작되지 않으면 무기한 남는다는 단서, (라)를 W8 전략 단락에 넘기는 줄을 더했다. (라)를 D1 선택지에서 뺐다(결정 소유자가 둘이 됐다). (라)의 근거를 248 에서 L4 안의 결합으로 고쳤다(248 중 200 은 `session_host.zig` 간선 하나). 사실: `test_env.zig` 는 test 에서만 쓰인다, 배럴 `src/app.zig` 는 손으로 나열한다, 결함 다섯의 판정자 사각은 커서 수만이 아니다, `mod.zig` 커밋 수는 기준 SHA 를 적어 101.
28. **권장 검증 21** — 공격 리뷰어 「조건부 유지」. 전환 조건을 관찰 가능한 사건 하나(다른 호스트에서 문서 변경을 적용하는 첫 PR)로 못 박고, 선행 슬라이스와 캐럿·선택 이동은 시작이 아니라고 적었다. 전환 대상을 ① 로 좁혔다 — Windows 계획에 LSP 가 없어 ② 에는 전환이 두 번째 소비자를 주지 않는다. (라) 넘김 줄을 「어느 선택지든」으로 옮기고 지금의 답(함께 쓰지 않는다)을 적었다. 「갈림길」(목적이 이식이면 (나)+전환, 계약대로의 배치면 지금 (다))을 사용자 결정으로 드러냈다. 사실: 편집기도 `workspace.zig` 를 거쳐 `session_host.zig` 에 닿는다(53 중 37), 결함 4 의 사각은 primary 위치, W8.17⒜ 원문은 safe-save 를 포함, 모듈 루트 자리는 셋.
29. **권장 검증 22 와 사용자 결정(2026-10-11)** — 공격 리뷰어가 권장 검증 4 회차 뒤 처음으로 「다른 권장」을 냈다. 전환 조건의 근거(두 번째 소비자가 API 의 모양을 확인할 수 있다는 것)가 서지 않는다 — 다른 호스트가 부르는 함수는 계기 2 로 어차피 옮겨지고, 나머지는 전환 때도 소비자 하나로 정해진다. 남는 이유(쓸모가 확인될 때까지 미룬다는 것)는 목적이 이식일 때만 선다. 사용자에게 갈림길(목적이 배치인가 이식인가)을 묻자 「지금 차례로 옮긴다」를 골랐다 → D1 = ① 은 (다), ② 는 (나). 전환 조건과 W8.17 줄을 지우고, 이 PR 이 결정을 기록한다(§5). 사실: 편집기는 `pane.zig`·`term.zig` 등을 거쳐 `workspace.zig` 에 닿는다. (이 회차에 「`DocumentRegistry` 는 아직 `src` 에 없다」·「Windows 편집기의 마지막 기능 커밋은 `2325bccdd`」라고 적었으나 둘 다 다음 회차에 고쳤다 — 그 이름은 없지만 `src/session/editor/document_registry.zig` 의 `Registry` 가 2026-10-01 부터 있고, 그 뒤에도 표시 쪽 기능 커밋이 있다.)
30. **권장 검증 23 — 결정 기록의 검증.** 운영 규칙 리뷰어 「조건부 작동」. 단계에서 빠진 ① 함수 넷(`cutSelection`·`toggleCursorAt`·`selectionSpansLines`·`completion.accept` 의 caret 계산)을 넣었다. 단계 4 의 L3 `VisualRow`·tree-sitter 결합을 예외 후보로 적고, 자리 문구를 「L3 타입을 읽거나 내는 순수 계산은 최상위 잎」으로 하나로 맞췄다. 단계 5 를 함수 이름으로 적었다(`workspace_edit` 은 다음 회차에 ② 로 다시 분류했다). 결함 없는 단계의 test 규칙을 적고, 단계는 서로 기다리지 않는다고 적었다. 모순: 라벨 조건에 여섯째 후보의 후속 이동, 남는 것에 계기가 오지 않은 클라이언트 정책·계산 클라이언트, PR 템플릿을 질문 줄 글자 그대로.
31. **권장 검증 24** — 운영 규칙 리뷰어 「조건부 작동」. 허용 목록 판정자를 기존 L2 파일에 두면 첫날부터 빨갛다(`backup.zig`·`edit_doc.zig` 가 이미 `std.Io`·`std.c` 를 쓴다) → 옮긴 코드는 새 파일에, 판정자는 std 허용 목록만. test 규칙의 범위를 하나로(같은 조건을 순수 test 로, 최상위 잎이면 `src/maru.zig` 에 등록). 단계 3 의 기대값(빈 caret 여럿·섞인 선택)을 test 전에 정하게 했고, 잘라내기 결함 후보를 적었다. 사실: `workspace_edit` 에 L4 순수 판정이 남아 있다(② 로 분류), `selectionSpansLines` 는 선택을 바꾸지 않는다. 모순: decomposition §7 단락을 결정 블록에 맞췄고, 문서 밖 줄의 「L2 로」를 「계약의 자리(대개 L2)로」.
32. **권장 검증 25** — 운영 규칙 리뷰어 「규칙 작동」(단계 1 PR 을 따라가 막히는 곳이 없었다). 모순: 같은 폴더 import 규칙을 빼자 최상위 잎의 「유일한 울타리」가 import 를 안 봤다 → import 를 허용 목록으로 보고, 열 std 이름과 파일 목록 등록을 적었다. `workspace_edit` 을 ② 열거와 §2 표에 넣었다. 등록 규칙(최상위 잎은 `maru.zig`)을 §3 에. 주의: 단계 1 은 caret 을 안 재던 함수가 많아 결함이 더 나올 수 있다 — 후보를 편집기 계획에 적었다.
33. **권장 검증 26** — 사실 「오류 0」, 모순 다섯(모두 문구). 계약 이탈 문장이 기존 L2 파일을 목적지로 읽혔다 → 「그 파일들 옆의 새 파일」. caret 사실을 `insertTextWithRange`·`deleteBy` 로 좁혔다(줄 연산은 매핑에 맡긴다). 결함 표 번호와 후보 서수 이름을 갈랐다. ② 정의 괄호에 LSP 편집 응답의 적용. 최상위 잎 import 허용에 배럴.
34. **권장 검증 27** — 사실 하나·모순 둘(문구). 계약 이탈 문장의 목적지에 「대개」와 최상위 잎 단서를, caret 사실에 `toggleLineComment`·`duplicateLines`·`insertNewlineKeepingIndent` 폴백·IME `.preserve_primary` 의 예외를 적었다.

**검증의 흐름**
- **1~21회차** — 사실·모순을 대조했다. 20회차 「확인된 사실 오류 없음」, 21회차 「확인된 모순 없음 · 결론을 뒤집는 반론 없음」.
- **권장 검증 1~19** — 1~15 회차는 사실·모순·권장 공격 리뷰어 셋을, 16~19 회차는 모순 리뷰어 하나를 띄웠다.
  - 1~3 회차는 공격 리뷰어가 「다른 권장」을 냈다.
  - 4~14 회차는 「조건부 유지」를 냈다(5·11 회차는 새로 넣은 설계의 결함을 짚었다). 15 회차에 「권장 유지」가 나왔다.
  - 모순 리뷰어는 4 회차부터 매번 「결론을 뒤집는 반론 없음」이었고, 19 회차에 「확인된 모순 없음」이 나왔다.

**회차마다 고친 사실** — 결함 다섯은 원본 L2 복사 실험으로 재현했다(제품 빌드 미확인).
- 줄번호·수치·인용 원문
- 실행 주체·선례 날짜
- AID11 이 재는 범위
- `std.Io` 는 OS 진입점이다
- `highlight` 에는 `dirty` 가 없다
- decode 실패 재요청은 다섯 모두다
- 두 합의의 대상
- 편집기 계약이 처음 적힌 날(2026-08-09)
- F 시리즈 범위 :158-175, `releaseWaiting` :1345-1373
- 결함이 나온 함수는 넷이다
- 「매핑에 맡기지 않는다」 주석은 `insertTextWithRange` 와 `deleteBy` 에 있다
- 결함 2·3·4 의 정확한 재현 조건
- `merge.zig` 의 CoreText 사용은 test 전용이다
- 이력 파일은 `history.zig`·`history/` 다
- `mod.zig` 는 2026-10-01 에 옮겨진 뒤 origin/main(2026-10-11) 까지 98 커밋을 받았다(그때의 origin/main `747188178` 기준. `79249d66b` 기준으로는 101 — §4)
- type-over·surround 갈래가 처음 들어간 곳은 그때의 `editor.zig` `insertText` 다
