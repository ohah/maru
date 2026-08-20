# 에디터 Surface — diff/git API·빌드·LSP (§6~§8)

bounded diff/git API, 빌드·에디터 엔진·CSP gate, 포맷·린트·LSP seam의 계약이다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§3.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1·§2·§4·§5·§10·§11 [editor-surface.md](editor-surface.md) · §3~§3.4 [권장 구조](editor-surface-structure.md) · §3.5 [도크 소스 컨트롤 뷰](editor-surface-dock.md) · §6~§8 [diff·빌드·LSP](editor-surface-tooling.md) · §9 [단계 계획](plans/editor-surface.md)

## 6. bounded diff/git API

전체 저장소의 before/after blob을 한 응답에 싣는 `diff.read`는 사용하지 않는다.

- `diff.list`: `{path, old_path?, status, binary, before_size, after_size, added_lines, removed_lines, hunk_summary?}` metadata를
  pagination해서 반환한다. **`added_lines`/`removed_lines`는 필수**다 — 도크 목록 행이 항상 `+N -N`을 그리기 때문이고(§3.5),
  출처인 `git diff --numstat`이 그 값을 공짜로 준다. binary는 numstat이 `-`를 주므로 숫자 대신 `binary=true`로 옮긴다.
- `diff.list` 첫 응답은 `diff_snapshot_id`와 stable cursor를 발급한다. pagination 중 index/worktree가 바뀌면 서로 다른 시점의 목록을 섞지 않고 `stale_snapshot`으로 다시 시작하게 한다.
- `diff.open`: `{diff_snapshot_id, path}`로 한 파일의 original/modified를 명시적 byte 상한 안에서 반환한다. 너무 크거나 binary면 typed `too_large`/`binary` 결과와 external-open fallback을 준다.
- UI bridge와 외부 socket은 같은 의미 DTO를 쓰되 각각의 transport 상한 안에서 chunk/page한다.
- `git.stage`/`unstage`는 저장·conflict 모델이 안정된 후 별도 write capability로 추가한다. **이 항목은 웹 브리지
  method에 대한 것이고 그대로 유효하다.** 도크(native chrome)의 stage/unstage/commit/fetch는 브리지를 거치지 않으며
  2026-08-14 결정으로 구현에 들어갔다 — 그 명령들의 안전 계약은 [소스 컨트롤 쓰기·원격](editor-surface-dock-write.md)이
  단일 출처다. **이 절(§6)의 읽기 전용 규칙은 읽기 명령에만 걸린다** — 쓰기는 index 잠금·hook·stderr 처리가 반대이며,
  그 차이를 그 문서 §1의 표가 명령 종류별로 고정한다.
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
- ~~화면에서는 **다섯 번째 섹션**("에이전트가 방금 바꾼 것")이고, 행 클릭 시 `스냅샷 tree ↔ 작업트리`다.~~
  **개정(2026-08-14)**: 도크 2판에서 이 base는 섹션이 아니라 **에이전트 탭의 턴 타임라인**이 소유한다
  ([§3.5.4](editor-surface-dock.md)). 항목이 턴이므로 기준도 `latest ↔ 작업트리` 하나가 아니라 **스냅샷 두 개
  사이**(`[K+1] ↔ [K]`)이고, 그 변경이 "턴이 끝나는 순간 목록이 비는" 현행 결함을 함께 고친다.

**후속 절의 소유**(2026-08-20): 이 절이 정한 턴 경계의 의미·스냅샷 메커니즘·링 정책·화면 소유는 여기가
계속 단일 출처다. 그 위에 얹는 넷 — ⑴ 턴 경계를 **provider 훅**으로 잡는 것(화면 관측은 폴백), ⑵ 어느 파일이
**에이전트 도구로** 바뀌었는지 확정하는 것, ⑶ **셸 편집 사각지대**의 정직한 표시, ⑷ 스냅샷 tree의 **`gc`
생존(ref 고정)** — 은 [에이전트 턴 변경분](agent-turn-changes.md)이 소유한다. 훅 payload와 셸 사각지대는 양
provider 실측으로 확인했다(그 문서 §2).

## 7. 빌드·에디터 엔진·CSP gate

### 7.1 툴체인

- self-host asset만 사용하고 CDN은 금지한다.
- **웹 스택은 file-panel을 그대로 따른다 — 현재 React + Tailwind + shadcn/ui다**([file-panel-web-stack.md](file-panel-web-stack.md) §2.1,
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

### 8.1a 언어 서버는 번들하지 않고 설치를 안내한다 (2026-08-10 사용자 결정)

**번들은 크기가 허락하지 않는다.** 실측: `Maru.app` 전체가 80MB인데 `rust-analyzer` 하나가 11MB(배포판에 따라 40~50MB)다. 서버 5~10개를 넣으면 앱이 2~5배가 되고, **사용자가 어떤 언어를 쓸지 모르는 채로** 전부 넣는 것이라 대부분이 낭비다.

**tree-sitter grammar와 갈리는 지점이 여기다.** grammar는 `parser.c` 수백KB~수MB라 번들할 수 있고(그래서 [native-editor-visual-mapping.md](native-editor-visual-mapping.md) §5의 1층이 **항상** 동작한다), 언어 서버는 언어마다 별개 프로세스에 수십MB라 번들할 수 없다.

**우리가 바이너리를 받지 않는다.** 대신 **패키지 매니저 명령을 터미널에 입력해 주고, 실행은 사용자가 한다.**

| 방식 | 신뢰 책임 | 채택 |
|---|---|---|
| 우리가 직접 다운로드(Zed `fetch_server_binary`) | **우리** — 배포처·체크섬·서명·플랫폼별 바이너리·업데이트 | ✗ |
| **패키지 매니저 명령을 우리 터미널에 입력** | **brew·npm 등 그대로** | **✓** |
| 문서로만 안내(Helix) | 사용자 | ✗ — 발견 실패를 알리지 않으면 사용자는 버그로 읽는다 |

**이 선택이 가능한 이유는 우리 제품이 터미널이기 때문이다.** 설치 과정과 출력이 사용자가 이미 보고 있는 화면에서 일어난다.

흐름:

1. 파일을 연다 → 서버 탐색 실패
2. **상태바가 알린다** — [native-editor-layering.md](native-editor-layering.md) §2.2가 *"조용히 줄어들면 사용자는 버그로 읽는다"*며 저하 표시 자리를 이미 잡아 두었다
3. 클릭하면 무엇이 없는지와 설치 명령을 보여준다
4. **새 터미널 탭을 열어 명령을 입력만 한다 — Enter는 사용자가 누른다**
   - **현재 탭에 넣지 않는다.** 그 탭이 셸 프롬프트라는 보장이 없다 — `vim`·REPL·`less`가 떠 있으면 명령이 그리로 들어가 사용자가 하던 작업을 망친다. 탭 하나가 느는 비용이 그 위험보다 싸다.
5. 완료 후 재탐색

- **입력까지만 하고 실행하지 않는 것이 경계다.** §8.1이 *"shell 없이 argv 실행"*까지 조여 둔 자세와 일관된다 — 사용자가 명령을 눈으로 확인하고 Enter를 누르는 그 한 단계가 "우리는 임의 명령을 실행하지 않는다"를 지킨다. 자동 실행은 그 경계를 무너뜨리면서 얻는 것이 키 한 번뿐이다.
- **언어별 설치 명령은 내장 기본값 + config override**다. 내장이 없으면 즉시 동작하지 않고, config가 없으면 사용자가 자기 환경(다른 패키지 매니저·사내 미러)에 맞출 수 없다. 폰트 fallback이 번들 기본값 위에 사용자 설정을 얹는 것과 같은 구조다.
- **서버가 없어도 편집기는 온전히 동작한다.** tree-sitter 1층이 색·접기·괄호 점프·타이핑 보조를 이미 제공하므로(§5), LSP 부재는 **기능 상실이 아니라 정확도 저하**다. `tic`이 없으면 `xterm-256color`로 폴백해 로컬이 절대 깨지지 않는 terminfo 계약([configuration.md](configuration.md))과 같은 자세다.
- **자동 다운로드는 이 결정으로 닫힌 것이 아니라 열어 둔다.** 하려면 배포처 신뢰·체크섬·서명 계약을 새로 써야 하고, 그것은 §8.1의 실행 경계와 별개 슬라이스다. 지금 그것을 LSP 표시와 같은 슬라이스에 넣으면 둘 다 흐려진다.

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
