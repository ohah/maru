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

- **스냅샷 방식 — ②로 결정됐다**(2026-08-23, [에이전트 턴 변경분](agent-turn-changes.md) §4.4). 선택지는 ① `git write-tree`(전체 트리) vs ② 에이전트가 만진 파일만(훅 편집 경로/FSEvents로 좁힘)이었고, **①을 «값쌈»으로 적은 이 줄이 근거 없는 추정이었다** — 재보니 이 저장소에서 0.49초(warm, 추적 1,280 파일)라 도구 단위 귀속을 감당하지 못한다(같은 문서 §2.6). 게다가 ①은 작업트리 전체라 같은 폴더의 다른 세션·사용자 편집이 원리적으로 섞인다. ②는 파일 하나 3 ms이고 훅 이벤트에서 나오므로 처음부터 세션별이다. **P5로 구현된 ①(임시 index + `write-tree`)은 에이전트 턴 경로에서 걷어낸다** — 임시 index를 repo 밖에 두던 규율(repo 안에 두면 그 파일이 diff에 잡힌다 — fixture 확인)도 그 경로와 함께 사라진다.
- (a) maru가 그 순간 transcript를 추적 중이어야 스냅샷이 찍힌다(상시 추적하나 캡처 배관은 신규). (b) "턴"=한 assistant 응답 단위라 그 안의 여러 편집이 한 turn diff로 묶인다(Codex "Last turn"과 동형). (c) 보관 개수·세션 경계·저장 위치는 결정 사항.
- **실현성 판정**: showstopper가 될 뻔한 두 관문(에이전트 턴 인식·스냅샷 안전성)이 실측으로 닫혔으므로 **불확실한 연구가 아니라 평범한 구현**이다.
- 이 base는 **read 전용**이라 `git_read`와 무관한 별도 위험이 없다(스냅샷 캡처는 write-tree/파일 read뿐, 작업트리 변형 없음). 다만 tree OID 캡처가 index를 건드리지 않도록 **임시 index**(`GIT_INDEX_FILE`)로 격리한다.

**결정(2026-08-01, §10.11 재결정)**: E1 안에서 구현한다. 스냅샷은 **①write-tree**이고, 보관은 ~~저장소당~~ 링 8개다.

**개정(2026-08-23, 사용자 결정) — 링의 소유자는 «세션»이다.** 초판은 «저장소당 링 8개»였고 저장소가 바뀌면 링을 버렸다. **실사용에서 그 결정이 기능을 무력화한다.**

`repoRootFor`는 `.git`이 디렉터리든 **파일(worktree)이든 존재만 보므로** 워크트리 루트가 곧 저장소 루트다. 그런데 사용자는 **세션마다 워크트리를 판다** — 그러면 세션을 옮길 때마다 저장소가 바뀌고 링이 통째로 버려진다. 워크트리 A에서 턴을 쌓다가 B로 가면 A의 히스토리가 사라지고, 다시 A로 오면 B의 것이 사라진다. **오가며 일하면 목록이 늘 한두 줄이다.**

| | 초판(저장소당) | 개정(세션당) |
| --- | --- | --- |
| 링 소유 | 창 하나에 저장소 하나 | **Term(세션)마다 하나** |
| 워크트리 이동 | 링을 **버린다** | 무관 — 각 세션이 자기 것을 계속 든다 |
| 같은 폴더에 세션 둘 | 한 링에 섞인다 | 애초에 안 섞인다 |
| 저장소 전환 | 전역으로 링을 비운다 | **그 세션의 링만** 비운다 |

**세션이 턴의 주체다.** 턴을 만드는 것은 에이전트이고 에이전트는 세션에 붙어 있다. 링을 저장소에 매달면 «누가 한 일인가»를 사후에 되찾아야 하지만, 세션에 매달면 그 물음이 생기지 않는다.

**구조 — 키는 «provider 세션 id» 하나다**(2026-08-23 2차 검토). 링을 Term에 매달면 키가 둘이 된다: 살아 있는 동안은 `surface_id`, 영속할 때는 세션 id. 그 이원성을 **유지할 이유가 없다.**

```
AppSession:  turn_rings: <세션 id> → Ring     ← 단일 키
Term:        아무것도 안 가진다 — 자기 신원을 조회할 뿐
```

**신원을 어디서 얻는가가 이 결정의 전부다.** 실측(2026-08-23)으로 두 경로의 성질이 갈렸다.

| | 훅 모드 | 관측 모드 |
| --- | --- | --- |
| 경로 | **모든 훅 payload에 `session_id`가 실린다** — `SessionStart`·`UserPromptSubmit`·`PreToolUse`·`PostToolUse`·**`Stop`** | 에이전트의 **자식·손자 프로세스 env**(claude `CLAUDE_CODE_SESSION_ID`, codex `CODEX_THREAD_ID`) |
| 확실한가 | **그렇다** — 턴 경계 신호인 `Stop` 자체가 신원을 실어 오므로, 스냅샷을 찍는 그 순간 신원이 손에 있다 | **아니다** — 자식은 **도구 실행 중에만** 살아 있고 폴링은 1초(`transcript_poll_interval_ms`)다. `Read`·`Edit`·짧은 `Bash`는 그 사이에 뜨고 사라져 **대부분 놓친다** |

**그래서 에이전트 턴 기능은 «훅 모드 전용»이다**(2026-08-23 사용자 결정). 관측 모드에서는 목록이 빈다 — 오류가 아니라 **신원을 확실히 알 수 없으므로 아무것도 말하지 않는 것**이다. `agent_transcript`가 이미 같은 규율을 쓴다: 신원을 못 얻으면 대화를 안 보여준다, 추측으로 틀린 것을 보여주느니 비우는 편이 낫다.

claude statusline 파일은 보조 경로였으나 **제거 계획**이고([훅 통합 계획](plans/agent-hooks.md)), 그 근거가 «`SessionStart`가 그 역할의 상위집합»이라 이 결론과 같은 방향이다. **codex에는 그 폴백이 애초에 없다**(claude 전용).

키를 하나로 두면 아래가 **함께** 풀린다.

| | Term 소유(이원) | 세션 id 맵(단일) |
| --- | --- | --- |
| 한 터미널에서 에이전트를 갈아탐 | 링이 섞여 비워야 한다 | **키가 다르니 자동으로 갈린다** |
| 앱 재시작(‘surface_id’ 재발급) | 못 찾는다 | **같은 키로 그대로** |
| `--resume`(Term은 새것) | 빈 링 | **같은 세션 id → 그대로 이어진다** |
| 영속화 | 키를 따로 정해야 한다 | **키가 이미 그것** |

기존 규율과도 일관된다 — `agent_transcript`가 이미 «신원으로만 고른다, 추측하지 않는다»이고 신원을 못 얻으면 아무것도 보여주지 않는다. 링도 같다: **신원 없는 세션은 링이 없다.**

새로 생기는 규율은 하나다 — **맵 수명 상한.** 세션이 끝나도 링이 남으므로 최근 N개 세션으로 끊는다(링 자체의 8개 상한과 별개 축이다).

저장소 축은 그대로 세션 안에 남는다: 한 세션이 `cd`로 저장소를 옮기면 **그 세션의 링만** 비운다.

**수명과 한계**: 링은 Term이 아니라 맵이 소유하므로 **탭을 닫아도 그 세션 링은 남는다**(맵 상한에 밀려날 때까지). 다만 현행은 그 맵이 메모리에 있어 **앱을 끄면 사라진다** — `--resume`으로 같은 세션을 되살려도 그 실행에서는 링이 비어 있다. 그 복원은 이 절의 범위가 아니다: **세션 id**(`CLAUDE_CODE_SESSION_ID` / `CODEX_THREAD_ID` — 확보 경로는 [agent_transcript.zig](../src/session/agent_transcript.zig)에 이미 있다)를 키로 캐시에 영속화하면 성립하고, 그때 저장 대상은 tree OID가 아니라 **캡처본**이어야 한다([에이전트 턴 변경분](agent-turn-changes.md) §4.4) — 참조 없는 tree는 `git gc`가 수거해 나중에 객체가 없을 수 있다.

화면이 이 링을 어떻게 그리는지는 [§3.5.4](editor-surface-dock.md)가 소유한다.

**⚠️ `--resume`이 히스토리를 되살리지 않는다(사용자 질문 2026-08-23).** `--resume`은 **provider의 대화 맥락**을 잇는 것이고 우리 링과는 별개다. 되살릴 수 있는 것과 없는 것을 가른다.

| 그 턴이 돌 때 | 복원 |
| --- | --- |
| maru가 떠 있었고 **영속화도 했다면** | 세션 id로 되찾을 수 있다(후속) |
| maru가 떠 있었지만 영속화 전(현행) | ❌ 앱을 끄면 링이 사라진다 |
| **maru 없이 돌았다면** | ❌ 스냅샷을 찍은 적이 없다 |

세 번째가 핵심이다. resume은 «이미 실행된 결과»를 잇는데, 그 과거 턴의 작업트리를 **우리가 관측하지 않았다면 어디에도 없다.** tree를 찍은 적이 없고, 찍었더라도 참조가 없어 `git gc` 대상이다(A4).

메울 길이 하나 있긴 하다 — Claude transcript의 `toolUseResult{filePath, originalFile, structuredPatch}`에 그때의 before/after가 실제로 들어 있다(실측 [§2.2](agent-turn-changes.md)). 다만 그것은 [§4.1](agent-turn-changes.md)이 «provider 기록으로 최종 상태를 재생하지 않는다»로 금지한 영역과 겹친다. «지금 파일이 이렇다»가 아니라 «그때 이런 일이 있었다»를 그리는 것이라 경계가 다르지만, **별도 결정 없이 하지 않는다.**

**실측으로 닫혔다(2026-08-23) — 양쪽 다 같은 세션 id를 유지한다.** 격리 홈에 훅을 걸고 1차 실행 뒤 재개해 `SessionStart` 의 `session_id` 를 대조했다.

| | 1차 | resume | 같은가 | `source` |
| --- | --- | --- | --- | --- |
| Codex (`codex exec resume <id>`) | `01a02ec3…ed94` | `01a02ec3…ed94` | ✅ | `resume` |
| Claude (`claude -p --resume <id>`) | `52841062…9901` | `52841062…9901` | ✅ | `resume` |

Codex 는 `transcript_path` 까지 동일했다. `source` 가 `startup`/`resume` 으로 갈리므로 **재개인지도 payload 하나로 안다.** Claude 쪽은 격리 홈이라 로그인이 없어 모델 호출은 실패했지만(`Not logged in`), 세션 신원은 세션 생성 시점에 정해지므로 이 물음에는 답이 된다.

즉 **세션 id 를 키로 삼는 영속화가 성립한다.** 남은 것은 «무엇을 저장하는가» 이고, 그 답은 tree OID 가 아니라 캡처본이다(위 문단).

**구현 계약(실측으로 확인 — 2026-08-01):**

- **턴 경계 = `running → idle`.** `blocked`(사용자에게 묻는 중)는 완료가 아니다 — 답하면 같은 턴이 이어지므로,
  여기서 찍으면 "마지막 턴"이 "마지막 질문 이후"라는 다른 뜻이 된다. `unknown`도 아니다(화면을 못 읽는 상태라
  "안 돈다"가 아니라 "모른다"이고, 그걸 턴 끝으로 삼으면 기준이 턴 중간으로 어긋난다).
- **스냅샷은 임시 index로만 돈다**: `read-tree HEAD` → `add -A` → `write-tree`를 `GIT_INDEX_FILE`을 걸어 실행한다.
  실측으로 **진짜 index·작업트리가 안 바뀜**을 확인했다(`.M`·`? b.txt` 그대로). 상속 환경의 `GIT_INDEX_FILE`은
  **항상 버린다** — 남기면 스냅샷이 아닌 명령까지 남의 index에 쓴다.
- **임시 index는 저장소 밖**(`~/.cache/maru/turn-index-<창>`)에 둔다. 안에 두면 그 파일 자체가 `add -A`에 잡혀
  스냅샷이 자기를 포함한다. 창마다 다른 파일을 쓴다(같은 파일을 두 창이 쓰면 한쪽 스냅샷이 다른 쪽 작업트리를 담는다).
  - **수명**(2026-09-15 추가): 이름이 창의 포인터 주소라 **다음 실행은 그 파일을 재사용하지 않는다** — 초판의
    「종료 시 남아도 무해하다」는 파일 하나에는 맞았고 쌓임에는 틀렸다(실측: 8월 1일부터 6,123개, 최근 7일 ≈207개/일,
    지우는 자리 없음). 규칙은 [`turn_index_cache.zig`](../src/platform/macos/turn_index_cache.zig)가 든다: 창이
    닫히면 `AppSession.deinit`이 그 창의 파일을 지우고, 크래시로 남은 것은 스냅샷 워커가 **프로세스당 한 번**
    같은 디렉터리의 `turn-index-*` 중 mtime 7일 넘은 것을 쓸어 낸다(메인 스레드가 아닌 이유: 실측 6,127항목·4,678개
    삭제에 Debug 176 ms·ReleaseFast 143 ms — 프레임에 들어가면 안 된다). 살아 있는 창의 파일을 지워도 안전하다 — `read-tree`가 없으면 만들고 매번
    덮어쓰므로 잃는 것은 첫 스냅샷 비용(292 ms) 한 번이다. 접두가 다른 이름(`terminfo`·`remote-view` 등 같은
    디렉터리의 다른 캐시)은 건드리지 않는다. 남는 창: 워커가 `add -A` 중인 채로 창을 닫으면 git 이 잠금을 이름으로
    되돌려 파일이 다시 생길 수 있다(수백 ms 창) — 그것은 스윕 몫이다. 디렉터리(`~/.cache/maru`)는 `turnIndexPath`가
    **부모까지** 만든다 — 한 단계 `mkdir`이던 때는 `~/.cache`가 없는 계정에서 조용히 실패해 스냅샷이 안 찍혔다(제품에선
    terminfo 캐시가 먼저 만들어 가려져 있었고, 픽스처 HOME에서 드러났다).
- **비용**: 첫 스냅샷 292 ms, 임시 index를 재사용하면 **24 ms**(index 64 KB). 매 턴 돌려도 되는 값이다.
- **비교도 임시 index로** 한다: 비교 시점의 작업트리를 다시 반영한 뒤 `diff --cached <tree>`로 본다 — 작업트리와
  직접 비교하면 추적되지 않은 파일이 빠진다(실측).
- **같은 tree가 연달아 오면 링에 안 넣는다.** 파일을 안 건드린 턴까지 쌓으면 "마지막 턴"이 빈 비교가 된다.
- **저장소가 바뀌면 그 세션의 링을 비운다**(2026-08-23 개정 — 초판은 전역이었다). 다른 저장소의 tree로 비교하면 전부 삭제로 보인다는 이유는 그대로이고, 범위만 세션으로 좁아진다.
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

### 8.2a LSP seam 1단 — transport·수명·문서 동기화·진단 (2026-09-17, 계획 공격 뒤의 사용자 결정)

**계획 공격이 드러낸 것.** §8.2 의 seam 은 목록이고 코드는 **0 줄**이다 — 진단 층(visual-mapping §5.4)이 서고서야 「출처가 없다」가
보였다. 이 저장소에서 자식 프로세스는 `std.process.Child`(0.16 에서 io 기반)를 피해 **posix fork+execve+pipe** 로 띄우고(`ssh_upload`·
`update_check`·`git_backend` 의 결), 오래 사는 스트림은 **비차단 fd 를 세션 tick 에서 drain** 한다(원격 에이전트 이벤트 스트리머 —
`spawnAgentEvents`·`setNonBlockingFd`). LSP 도 그 결로 간다 — 스레드를 새로 두지 않는다.

**사용자 결정(2026-09-17).** ① 서버는 **번들하지 않는다**(§8.1a 그대로 — clangd 하나가 55.5 MB, 앱 실행 파일과 맞먹는다). ② 서버가
있으면 **워크스페이스마다 한 번 묻고 기억**한다(VS Code Workspace Trust 의 모양 — §8.1 의 「trusted workspace」가 이것이다). ③ 없으면
**상태바에 설치 안내**를 띄우고 누르면 새 터미널 탭에 설치 명령을 **입력만** 한다(§8.1a 흐름 4 — Enter 는 사용자).

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **범위(1단)** | transport(Content-Length·JSON-RPC 2.0) · 수명(`initialize`/`initialized`/`shutdown`/`exit`, 죽으면 backoff 재시작 1·2·4s 세 번) · `didOpen`/`didChange`(**Full sync**, 프레임당 한 번 최신 본문)/`didClose` · `publishDiagnostics` → §5.4 의 목록에 `.lsp` 출처로 합침 · 신뢰 프롬프트·기억 · 상태바 항목 · 설치 안내 | 진단이 오늘 표시 자리를 갖는 유일한 결과다. completion·hover·definition·semantic tokens·inlay 는 2단(표시 자리 §8.2·§8.3 이 먼저) |
| **하지 않는 것(1단)** | 서버→클라이언트 요청(`workspace/applyEdit`·`executeCommand`·`showDocument`·파일 생성/이름/삭제·`workspace/configuration`)은 **전부 거부**(`MethodNotFound` 응답) · 증분 동기화 · 여러 root · `didSave` | §8.2 「기본 거부하고 method 별 승인」— 승인 UI 가 없으니 1단은 거부만. 저장은 아직 서버가 알 필요 없다(진단은 didChange 로 온다) |
| **서버 찾기** | 언어(§3.7a `Grammar`) → 실행 파일 이름 **내장 표**: zig→`zls` · c/cpp→`clangd` · typescript/javascript/tsx→`typescript-language-server --stdio` · rust→`rust-analyzer` · python→`pyright-langserver --stdio` · go→`gopls` · 나머지 없음. **PATH 만** 본다(`/usr/bin/env` 로 execve — PATH 탐색은 env(1)). 설치 명령도 같은 표(brew·npm) | §8.1a 「내장 기본값 + config override」— override 는 2단(설정 키가 언어 수 × 2 라 표시 슬라이스가 커진다; 1단은 내장 표만, `lsp.enabled` 토글 하나) |
| **신뢰** | 파일을 열어 서버가 필요하고 PATH 에 있으면 **confirm 모달**: 「이 저장소에서 ‹서버›를 실행할까요? 서버는 저장소의 설정·빌드를 읽고 실행할 수 있습니다」 — 허용/거부. 답은 `~/.config/maru/lsp-trust`(줄마다 `allow\t‹root›` / `deny\t‹root›`)에 **root 별로** 기억. 거부하면 그 root 에서는 안 묻고 안 띄운다 — 상태바 항목을 누르면 다시 묻는다 | §8.1 「trusted workspace 확인」. zls 는 build_on_save 로 `zig build`(빌드 스크립트 실행), TS 서버는 node_modules 플러그인 — 저장소를 열기만 해도 코드가 도는 것을 사용자가 알고 허락해야 한다. 거부를 기억하는 이유는 「열 때마다 묻는 모달」이 곧 사용자를 허용으로 몰기 때문 |
| **root** | 그 Term 의 문서가 속한 **워크스페이스 root**(파일 트리의 root — `withinNavRoot` 가 쓰는 그것). 서버는 `(root, 언어)` 마다 하나. root 밖 문서는 서버를 안 띄운다 | §8.2 「root 밖 URI」 규칙의 전제 — 경계가 root 다 |
| **상태바** | 새 항목 `editor_lsp`(편집기 묶음, `editor_degraded` 바로 뒤 — 저하 계열이라 앞쪽): 「‹서버› 없음 — 설치」(클릭 → 새 탭 + 명령 입력) · 「‹서버› 묻는 중」 · 「‹서버› 시작 중」 · 「‹서버›」(연결) · 「‹서버› 실패 — 다시」(클릭 → 재시작) · 「‹서버› 거부됨 — 다시 묻기」(클릭 → 프롬프트). 언어에 서버 이름표가 없으면 항목 없음 | layering §2.2 「조용히 줄어들면 버그로 읽는다」. §8.1a 흐름 2·3·4 |
| **설치 안내** | 클릭 → `newTab` + `sendTextAsKeys(명령)` — **Enter 는 안 보낸다**. 명령: `brew install zls` · `brew install llvm`(clangd — Xcode 가 있으면 이미 `/usr/bin/clangd`) · `npm i -g typescript-language-server typescript` · `rustup component add rust-analyzer` · `npm i -g pyright` · `go install golang.org/x/tools/gopls@latest` | §8.1a 「입력까지만 하고 실행하지 않는 것이 경계다」 |
| **위치 인코딩** | `initialize` 에 `general.positionEncodings: ["utf-8", "utf-16"]`. 서버가 `utf-8` 을 고르면 byte 그대로, 아니면(기본 `utf-16`) 줄 안에서 UTF-16 code unit 을 세어 byte 로 옮긴다 | LSP 3.17 `positionEncoding`. clangd 는 utf-8 을 받아들이고 zls·tsserver 는 utf-16 만 — 둘 다 있어야 한다 |
| **진단 합치기** | `publishDiagnostics` 의 `uri` 가 열린 문서와 같고 `version`(있으면)이 지금 revision 과 같을 때만 받는다 — 아니면 버린다(§5 「revision 으로 폐기」). 그 문서의 `.lsp` 항목을 **통째로 갈아 끼우고** `.syntax` 는 둔다. `message` 와 `code`(문자열이든 정수든 글자로 — 호버 박스 §8.2b 가 `출처(코드)` 로 낸다)를 실어 온다. severity 1..4 → error·warning·info·hint, 없으면 error. root 밖 uri 는 무시(§8.2). 메시지는 서버 문자열을 **복사**해 든다(표시는 §8.3 호버가 오면) | §5 「출처가 여럿이어도 층은 하나」. 구문 오류와 서버 오류가 같은 줄에 겹치면 둘 다 선다(둘 다 참이다) |
| **동기화** | `didOpen`(languageId·version=revision·전문) → 편집마다 revision 이 오르면 **그 프레임 끝에 한 번** `didChange`(Full, 최신 전문·version). 문서를 닫으면 `didClose`. 큰 문서(§3.0 상한 넘음)는 안 보낸다 | 프레임당 한 번이면 타이핑 60Hz 에 60 회 전송 — Full 이라 전문 크기 × 60/s. 1 MB 문서면 60 MB/s: **1단의 알려진 대가**(증분 동기화가 2단인 이유). 상한을 넘는 문서는 아예 안 보낸다 |
| **수명·재시작** | 자식이 죽으면(읽기 EOF·`waitpid`) 1s·2s·4s 뒤 재시작, 세 번 실패하면 「실패」 상태로 멈춘다(클릭으로 재시도). 앱 종료·root 닫힘·마지막 문서 닫힘 뒤 30 초면 `shutdown`→`exit`, 5 초 안에 안 죽으면 SIGKILL | §8.2 「restart/backoff」. 30 초를 두는 이유는 탭을 오가며 여닫는 동안 서버를 매번 띄우지 않기 위해서다 |
| **stderr** | `/dev/null`. 서버 로그는 우리 것이 아니다 | §8.3 「tool stdout/stderr 는 기본 제외」 |
| **관측** | 1단은 trace event 없음 — 상태바가 관측점이다. `editor.tool-started/completed` 는 §8.3 의 redaction 갱신과 함께 2단 | §8.3 「control-plane event 를 trace 에 넣는 PR 은 먼저 facade/trace-replay 를 갱신한다」 |

**관측점**: 판정자 `LSF*`(순수: Content-Length 프레임 인코더/디코더 — 부분 도착·두 프레임 붙음·헤더 대소문자·잘못된 길이) · `LSJ*`(순수: JSON-RPC
요청/응답 대조·id·알림·서버 요청 거부) · `LSP*`(순수: UTF-16 ↔ byte 위치·범위 → 진단·severity·version/uri 필터) · `LST*`(순수: 신뢰
파일 읽기/쓰기·root 정규화) · `LSI*`(순수: 언어 → 서버·설치 명령 표) · `LSPB*`(제품 경계: **가짜 서버**(빌드가 내는 테스트 전용 실행
파일 `maru-fake-lsp` — 프레임을 읽고 initialize 에 답하며 didOpen/didChange 마다 진단 하나를 version 을 달아 낸다)로 파일을 열면
프롬프트 → 허용 → didOpen → 진단이 §5.4 표에 `.lsp` 로 서고, 편집하면 version 이 맞는 것만 남고, 서버가 죽으면 backoff 재시작,
거부하면 안 뜨고 기억되며, 없으면 상태바 「설치」가 새 탭에 명령을 입력한다) · `SBL4`(제품 경계: 상태바 항목을 **포인터로** 눌러 새 탭) ·
실측: clangd 로 C 파일(캡처).

**적대적 검증(2026-09-17, 1~5회차 · 변이 40)**: 1회차 순수 13 → 생존 1 · 2회차 제품(신뢰·수명·동기화) 16 → 생존 7 · 3회차 프로세스·상태바·설정
11 → 생존 4 · 4회차 재실행 12 → 생존 1 · 5회차 재실행 1 → 0. 살았던 것과 세운 판정자:
- **A12** 신뢰 파일이 접두 일치 — `deny /a/sub` 이 `/a` 의 답이 되면 안 된다(`LST1`).
- **B2** 프로그램이 닫은 모달을 거부로 기억 — 알림 토스트가 모달을 덮어도 파일 줄 수가 그대로고, 토스트가 사라지면 다시 묻는다(`LSPB2`).
- **B4** 파일의 deny 를 무시 — 새 세션(상태를 비우고 pump)의 클라이언트가 `denied` 이고 프로세스가 없다. 앞 단언은 **취소가 직접 세운**
  denied 만 봤다(`LSPB2`).
- **B5** 신뢰 대기 중에도 띄움 — root 가 둘(`sub/.git`)이면 다른 root 의 문서는 「허락 대기」·프로세스 없음, 답이 오면 그 차례(`LSPB2`).
  같은 root 둘만 있던 픽스처에선 안 보였다.
- **B7** 서버 요청에 답 안 함 — 가짜 서버가 `srv-1` 응답을 못 받으면 WARN message 를 `fake: warn noack` 으로 낸다. 클라이언트의
  `rejected_requests` 카운터는 「세고 안 보내는」 변이를 못 잡는다 — **서버 쪽에서 봐야 한다**(`LSPB1`).
- **B12** 보낸 version 을 안 굳힘 — tick 셋을 더 돌려도 didChange 가 1 이다(응답이 같은 tick 에 오면 카운터 하나로는 산다 — 걸음 수로 잰다).
- **B13** 재시작 뒤 didOpen 대신 didChange — 편집 하나가 있었는데도 didChange 수가 그대로다(가짜 서버는 둘을 같이 받아 진단만으론 안 갈린다).
- **B16** `lsp_dirty` 안 올림 — provider 를 뗀(트리 없는) 프레임에서 `WARN ` 을 빼면 표의 `.lsp` 항목이 둘 → 하나. 첫 판정자는 message 문자열을
  봤는데 **`lsp_messages` 버퍼의 조각이라 낡은 항목도 같은 자리의 새 글자를 가리켰다**(같은 길이 `fake: N`) — 4회차에서 살아 개수로 바꿨다.
- **C3** EOF 를 데이터 없음으로 — 가짜 서버 `HANG`: stdout 만 닫고 살아 있다(exit 가 없어 reap 으론 안 보인다) → 죽여서 재시작·복구(`LSPB1`).
- **C4** stderr 를 stdout 에 합침 — 가짜 서버가 시작 시 stderr 에 한 줄을 쓴다(clangd 가 그렇다). 섞이면 프레임이 깨져 ready 가 안 된다.
- **C5** 끄기 설정 무시(pump) — 「다시 묻기」를 눌러 둔 채 끄면 묻지 않는다. 할 일이 없는 상태에서 끄면 안 보였다.
- **C9** 상태 항목이 안 눌림 — `activateStatus` 직접 호출은 그 위 층(클릭 가능 판정)을 안 지났다. `SBL4` 가 포인터를 태운다.

판정자를 세우다 잡은 **판정자 결함**: `LSPB1` ⑸ 가 표식을 「0..5」로 지워 `WARN ` 이 지워지고 `STALE BOOM` 이 남은 채 초록이었다 —
`received_diagnostics` 가 클라이언트 합산(픽스처 doc.zig 의 zls 몫이 섞임)이고 ready 는 didOpen 이 죽이기 **전에** 잠깐 참이라 크래시 루프를
「복구」로 읽었다. 표식은 자리를 찾아 지우고, 복구는 「**그 version 의** 진단이 왔다」로 잰다.

### 8.2b LSP 2단 ① — 호버 박스와 진단 메시지 (2026-09-17, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① [native-editor-ui §8.3](native-editor-ui.md) 은 「재활용할 컴포넌트가 없어 작은 신규가 필요하다」고 적었는데
그 사이 **`popup_box`(2026-09-14)** 가 앵커 팝업의 기하(아래에 두고 안 들어가면 위로 뒤집고 workspace 로 당김)를 단일 출처로 갖게 됐다 —
신규는 **내용 배치(줄·스크롤)** 뿐이다. ② 그 절은 「언제 띄우고 언제 사라지는가」를 계약 밖(§12)으로 뒀고 계획 표는 「LSP 가 선행」이라
적었다 — 1단(§8.2a)이 서서 선행이 풀렸다. 여기가 그 정책의 자리다. ③ 진단 층(visual-mapping §5.4)은 「메시지 표시 자리 없음」을 남겼다 —
같은 박스가 낸다(VS Code 도 마커 호버와 언어 호버를 한 박스에 합친다). ④ 가장 가까운 선례는 **선택 헬퍼**(send-selection §6.2)다:
모달이 아니고(`.not_an_overlay`), 닫는 자리를 경로마다 심지 않고 **프레임마다 같은 질문 묶음을 다시 묻는다**. 그 규율을 그대로 쓴다.

**레퍼런스(동작만).** VS Code `editor.hover`: `enabled` on · `delay` 300ms · `sticky` true(포인터가 박스 위로 가면 남는다) · `hidingDelay`
300ms · `above` true(**위를 선호**) · 숨김: 편집기 밖으로 나감·스크롤·모델 변경·수정자 아닌 키·드래그 선택. Zed `hover_popover_enabled`
true · `hover_popover_delay` 300 · `hover_popover_sticky` true · `hover_popover_hiding_delay` 300. 둘이 같은 값이라 300ms 를 기본으로 둔다.
**위·아래는 우리 계약(§8 규칙 2 — 아래, 안 들어가면 위)을 따른다** — VS Code 의 `above` 는 설정이고, 우리 팝업 셋(메뉴·드롭다운·프리뷰)이
이미 아래-먼저다.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | 편집기 본문 위에서 포인터가 **한 자리에 `editor.hover-delay`(기본 300ms) 머물면** 그 글자의 offset 으로 연다. 글자가 없는 자리(줄 끝 뒤·빈 줄)는 열지 않는다. 드래그 중·버튼 눌림·오버레이(모달·메뉴·알림) 열림·비교 뷰에서는 열지 않는다 | VS Code·Zed 300ms. 「글자 없음 → 안 연다」는 헬퍼 §6.2 ③과 같은 이유 — 빈 자리에 뜨는 상자는 가린다 |
| **키보드** | 팔레트 명령 `show_hover`(「Editor: Show Hover」)가 **caret** offset 으로 연다. 기본 chord 없음 — VS Code 의 `⌘K ⌘I` 는 두 단계 chord 라 우리 키 계약(단일 chord)에 없다 | §8 규칙 1(앵커는 caret 또는 포인터) |
| **앵커** | 그 offset 이 든 **낱말**(selection.zig 의 단어 규칙 — 코드용) 의 시작 글자 셀. 서버 응답에 `range` 가 있으면 그것이 낱말을 대신한다. 상자는 그 셀 **한 줄 아래**, `popup_box.below_flip_up` | 헬퍼와 같은 좌표 출처(`bodyAnchor` — 렌더가 굳힌 행 배열) |
| **내용 순서** | ① 그 offset 을 덮는 **진단**(§5.4 목록) — **VS Code 마커 호버의 모양**(2026-09-17 사용자 결정): 메시지는 **평문**(아이콘·severity 색 없음 — gutter 글리프가 이미 있어 상자 안에서는 중복이고, VS Code 도 severity 를 정렬에만 쓴다), 그 **아래 줄**에 흐린 색으로 한 칸 들여 `출처(코드)`(출처만이면 `출처`, 코드만이면 `(코드)`, 둘 다 없으면 줄 없음). 구문 오류의 메시지는 i18n 「구문 오류」·「빠짐: ‹토큰›」이고 출처 줄이 없다(우리가 낸 것 — VS Code 의 마커도 source 가 없으면 그 줄이 없다). 서버 진단은 message 의 첫 줄, 출처 = 서버 실행 파일 이름, 코드 = `Diagnostic.code`(문자열·정수 — §8.2a 표에 실어 온다). 진단이 여럿이면 severity 높은 것부터. ② 서버 `textDocument/hover` 의 contents. ①·② 사이 빈 줄 하나 | VS Code `markerHoverParticipant`(MIT, 동작만): 메시지 span + 아래 줄 `source(code)` 불투명도 0.6·6px 들여쓰기, 아이콘·색 없음, severity 는 정렬. 「View Problem」·「Quick Fix」 동작 줄과 related information 은 「하지 않는 것」 |
| **마크다운** | §8.3 의 축소 규칙 그대로 — 펜스는 살리고(이 슬라이스는 **색 없음**), 인라인 코드·굵게·이탤릭은 기호만 지우고, 목록은 `• `, 표·이미지·링크는 평문. `MarkedString{language,value}` 는 펜스로 친다. 순수 모듈 `session/editor/hover_text.zig` | §8.3 「이것은 마크다운 렌더러가 아니다」 |
| **요청** | 포인터가 머문 자리마다 요청 하나(id 는 `1000+seq`, 문서마다가 아니라 클라이언트마다 seq). **응답이 오면** 그 seq 가 지금 기다리는 것일 때만 연다 — 낡은 응답은 버린다. 서버가 없거나(ready 아님) 진단만 있으면 지연 뒤 **바로** 연다. 서버가 있고 진단도 있으면 응답을 기다린다(진단만 먼저 띄우면 응답이 와서 상자가 커지며 흔들린다) — 응답이 2초 안에 안 오면 진단만 연다 | `$/cancelRequest` 는 안 보낸다(1단 「하지 않는 것」과 같은 폭 — 낡은 응답을 버리는 것으로 충분) |
| **닫힘** | 프레임마다 다시 묻는다(헬퍼 규율): 그 문서가 보이는가 · 그 줄이 아직 그려졌는가 · revision 이 같은가 · 오버레이가 없는가. 그 위에 즉시 닫는 것: 포인터가 **낱말 밖이면서 상자 밖**으로 감(sticky — 상자 위는 남는다) · 수정자 아닌 키 · 스크롤(상자 밖 휠) · 상자 밖 클릭(그 클릭은 흘려보낸다) · `Esc`(소비하지 않는다) · Term/탭 전환 | VS Code 숨김 조건 목록. 「상자 위는 남는다」가 §8.3 의 자체 스크롤을 가능하게 한다 |
| **크기·스크롤** | 폭 = 가장 긴 줄(EAW 표시폭) + 좌우 1칸, **상한 80칸**; 높이 = 줄 수, **상한 12행**. 넘치면 상자 안 휠로 스크롤(`scroll_area` 규칙 — 행 단위) · 긴 줄은 상한 폭에서 자른다(랩 없음 — 시그니처는 한 줄로 읽히는 편이 낫다) | §8.3 「높이를 제한하고 넘치면 자체 스크롤」. 폭 80 은 VS Code 기본 최대 폭(≈500px)과 같은 자릿수 |
| **모달 아님** | `modalInputRole` = `.not_an_overlay`(헬퍼·`key_hints` 자리). 키는 편집기로 그대로 간다(단, 키가 오면 닫힌다) · 받는 포인터는 상자 안 휠뿐 | 헬퍼 §6.2 「고르기를 마쳤을 뿐인 사용자에게서 키를 뺏으면 안 된다」 |
| **켜고 끄기** | `editor.hover`(기본 켬) · `editor.hover-delay`(ms, 기본 300, 0..5000). 끄면 포인터 트리거만 꺼지고 `show_hover` 명령은 남는다 | VS Code `editor.hover.enabled` 를 꺼도 `showHover` 명령은 남는다 |
| **하지 않는 것(이 슬라이스)** | 시그니처 힌트(`signatureHelp` — 활성 파라미터 추적은 별도) · 펜스 syntax 색 · 링크 이동·액션(quick fix·View Problem) · 진단의 related information · 메시지 둘째 줄 이후(clangd 의 note 나열 — 첫 줄이 요지다) · 호버 안 포커스/키보드 스크롤 · `hidingDelay`(포인터가 낱말과 상자 사이 틈을 지나는 유예 — 상자가 한 줄 아래에 붙어 있어 틈이 없다) · 비교 뷰 | §8.3 「링크 이동은 팝업이 감당할 상호작용이 아니다」 |

**구현이 계약에 되먹인 것(2026-09-17).** ① 포인터 아래의 글자는 **클릭의 caret 반올림과 다르다** — `byteAtPoint` 는 셀 중점에서 다음
경계로 반올림하므로(caret 은 글자 *사이*) 셀 오른쪽 절반에서 다음 글자가 잡혔다(HOVB1 실측 1 → 2). `content.clusterAtPoint` /
`hit.bodyPointMode(.cluster)` 가 「그 cluster 의 픽셀 범위가 x 를 덮으면 그 글자」로 답한다(§4.1g 의 두 뜻). ② 모달 quad 는 `modal_padding_px`
(12px)만큼 사방으로 **커져 그려진다** — 상자를 낱말 줄 바로 아래에 두면 그 padding 이 낱말 줄의 아래 2/3 를 가렸다(제품 캡처 실측). 간격을
padding 만큼 둔다(`popup_box.gap_px`); sticky·휠 판정도 **보이는** rect(`visibleRect`)로 한다. ③ 캡처 하니스: `MARU_FORCE_EDITOR_HOVER=1`
이 caret 자리에서 `show_hover` 를 부른다(포인터 정지는 헤드리스로 못 만든다) — 작업 공간 복원 알림이 떠 있으면 먼저 내린다(오버레이가
있으면 상자가 서지 않으므로).

**적대적 검증(2026-09-17, 1~4회차 · 변이 41)**: 1회차 순수 13 → 생존 1 · 2회차 chrome·상태 기계 16 → 생존 2 · 3회차 배선·요청 12 → 생존 4 ·
4회차 재실행 7 → 0. 살았던 것과 세운 판정자:
- **A6** 별 뒤가 공백이어도 여는 기호로 — `a * b and c*` 가 「a  b and c」가 됐다. 기존 픽스처는 닫는 별 앞도 공백이라 짝이 안 맞아 못 갈랐다(`HVT5`).
- **B4** 뒤집지 않고 당김 — 앵커 790 은 당겨도 앵커 위라 안 갈렸다. 앵커 700·12행 상자로 「당기면 앵커를 덮는다」를 잰다(`HOVX3`).
- **B15** revision 이 달라도 남음 — 편집 직후 `refresh` 를 물으면 행 배열이 비어 「행 없음」으로 닫혀 revision 검사가 안 보였다. **제품 순서**
  (pane 프레임을 그려 행을 다시 세운 뒤 오버레이를 묻는다)대로 프레임을 먼저 그린다(`HOVB1` ⑺).
- **C6** 클릭 배선 — `mouseDown` 직접 호출은 `mouse()` 의 그 줄을 안 지났다. 제품 진입점으로 눌러 닫힘 + 클릭 통과(caret 이 둘째 줄)를 잰다.
- **C7** tick 배선 · **C12** 응답 시간 초과 — `hover_client.tick` 직접 호출은 `AppSession.tick` 의 그 줄을 안 지났고, 가짜 서버는 늘 답했다.
  `MUTEHOVER`(답하지 않는 서버) + 제품 `tick` 만 돌려 2s 뒤 진단만으로 열리는 것을 잰다(`HOVB1` ⑽).
- **C8** 프레임이 안 냄 — `overlayFrameNeeded` 만 봤다. `buildChromeOverlayPrep` 이 `✖` 글자를 싣는지 본다.
판정자를 세우다 잡은 것: 같은 픽셀로 돌아온 포인터는 「안 움직였다」라 판정이 안 선다 — 실제 포인터는 딴 데를 지나 돌아오므로 판정자가
한 픽셀 옮긴다(제품 결함 아님).

**적대적 검증 — 진단 줄 모양(2026-09-17, 1~4회차 · 변이 15)**: 1회차 code 파싱 4 → 생존 1 · 2회차 줄 조합 8 → 2 · 3회차 경계 3 → 2 · 4회차 재실행 5 → 1(선언한 등가).
- **A2** code 저장소를 미리 안 잡음 — 작은 픽스처에선 재할당이 안 나 못 갈랐다. 진단 50 개·code 100 byte 로 재할당을 내고 **모든 슬라이스가 지금
  저장소 안을 가리키는지 주소로** 잰다(`LSP3` — 읽지 않고 주소로: 해제된 메모리를 읽는 판정은 우연히 초록일 수 있다).
- **B6** severity 순 · **B8** 첫 줄만 · **C1** 반열림 끝 — 같은 자리를 덮는 진단이 하나뿐이었다. 가짜 서버 `INFO`(첫 줄 0..1, 두 줄 message)로
  offset 0 은 error → info, offset 1 은 error 만(`HOVB1` ⑾).
- **C2** 코드만 있을 때 괄호 — 오늘 닿을 수 없다(`.lsp` 는 서버 이름이 늘 있고 `.lint` 는 아직 없다). 등가로 적고 코드 주석에 남겼다.

**관측점**: `HVT*`(순수: 마크다운 축소 — 펜스·인라인 기호·목록·표·`MarkedString`) · `HL20`(순수: `clusterAtPoint`) · `HOVX*`(chrome: 크기 상한·
스크롤·padding 간격·뒤집기·view) · `LSP3`(순수: code 저장소) · `LSJ5`(순수: hover 요청 id·응답 대조·`contents` 세 모양) ·
`HOVB*`(제품 경계: 가짜 서버가 `textDocument/hover` 에 답한다 — 포인터 정지 → 지연 → 요청 → 응답 → 상자(줄 내용·자리) · 낱말 밖으로 나가면 닫힘 ·
키·스크롤·편집으로 닫힘 · 서버 없이 구문 오류만으로 열림 · `show_hover` 가 caret 에서 연다 · 낡은 응답은 버린다 · 끄면 포인터로 안 열린다).

### 8.2c LSP 2단 ② — 정의로 이동과 되돌아가기 (2026-09-18, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① [visual-mapping §5.2](native-editor-visual-mapping.md) 의 수렴 진입점(`navigateTo`)과 되돌아가기 스택은 섰고 심볼
피커·`F7`·`F8` 이 쌓아 왔는데, **되돌아갈 키·명령이 없다**(`navigateBack`/`navigateForward` 는 판정자만 부른다 — 「기능은 섰는데 손이 닿지
않는다」의 또 한 사례). ② 그 진입점은 `(경로?, byte offset)` 을 받는데 LSP 는 `(line, character)` 를 **서버 인코딩**으로 주고, 대상 파일은
아직 안 열려 있을 수 있어 offset 을 미리 셀 수 없다 — 열고 나서 그 문서로 풀어야 한다. ③ root 밖 URI 는 §5.2 가 「알리되 열지 않는다」고
정했지만 알리는 자리가 없었다. ④ 키 계약(`ETX4`)은 편집기 컨텍스트 표에 `⌃` 조합을 막는다 — 되돌아가기의 VS Code mac 기본이 `⌃-` 라
**예외 갈래를 열어야 한다**(사용자 결정, 아래). ⑤ `⌘클릭` 은 `input.url-click-modifier` 의 링크 열기와 같은 수식키인데 편집기 본문에는
링크가 없다(링크 감지는 터미널 Term 만) — 같은 수식키가 편집기에서는 정의로 간다.

**레퍼런스(동작만).** VS Code macOS 기본: `F12` = `editor.action.revealDefinition` · `⌃-` = `workbench.action.navigateBack` · `⌃⇧-` =
`workbench.action.navigateForward` · `⌥F12` = peek · `⌘클릭` = 정의로 이동. 정의를 못 찾으면 편집기 안에 「No definition found for 'x'」.
결과가 여럿이면 peek 목록. Zed 도 `F12`·`⌘클릭`·`⌃-`.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | `goto_definition` — `F12`(편집기 컨텍스트 표 ⑶ 기능키) · **`⌘클릭`**(편집기 본문 위, 눌린 글자 = `.cluster` 판정) · 팔레트 「Editor: Go to Definition」. caret(키) 또는 포인터(클릭) 자리의 offset 으로 `textDocument/definition` | VS Code·Zed 와 같은 키. `⌘클릭` 은 링크 열기(`url_at`)가 먼저 보고 편집기에는 링크가 없어 `mouse()` 로 떨어진다 |
| **요청** | id 는 `2000+seq`(hover 의 `1000+seq` 와 같은 꼴). 응답이 오면 **지금 기다리는 seq** 일 때만 움직인다 — 낡은 응답은 버린다. 서버가 없거나 ready 아니면 무동작 | §8.2b 와 같은 규율 |
| **결과** | `Location` · `Location[]` · `LocationLink[]` — **첫 항목**. `LocationLink` 는 `targetSelectionRange`(없으면 `targetRange`)의 시작. `null`/빈 배열이면 알림 토스트 「정의를 찾지 못했습니다」 | VS Code 의 「No definition found」. 여럿의 목록(peek)은 「하지 않는 것」 |
| **이동** | §5.2 의 `navigateTo` **하나**로 — `NavTarget` 에 `(line, character, 인코딩)` 변형을 더해 **연 뒤 그 문서로 offset 을 푼다**(열기 → 풀기 → 펴기 → caret → 스크롤). 같은 파일이면 파일 열기 없이 같은 경로 | §5.2 「출처가 여럿이어도 경로는 하나다」 |
| **root 밖** | `withinNavRoot` 가 거부하면 열지 않고 알림 「루트 밖이라 열지 않습니다 — ‹경로›」 | §5.2 「표시와 접근을 가른다」 · §8.2 「URI 를 받았다는 이유로 grant 가 확대되지 않는다」 |
| **뒤로·앞으로** | `navigate_back` = `⌃-` · `navigate_forward` = `⌃⇧-`(`_` 도) · 팔레트 「Editor: Go Back / Go Forward」. 스택은 §5.2 것 그대로(창 하나에 하나, 닫힌 Term 은 건너뜀). 편집기 Term 컨텍스트에서만 — 터미널 Term 에서는 `⌃-` 가 PTY 로 간다 | **사용자 결정(2026-09-18)**: VS Code mac 기본을 따른다(§1.1 「VSCode 사용자 무회귀」). 키 계약에 `⌃` 예외 갈래 ⑷ 를 연다 — [키 입력](key-input-and-shortcuts.md) 「편집기 Term 컨텍스트」 |
| **하지 않는 것** | 여러 결과의 목록·peek(`⌥F12`) · declaration/typeDefinition/implementation/references · `⌘` 호버 밑줄(링크처럼 보이기) · 「정의로 이동 → 선택」(caret 만 놓는다 — §5.2) · stale 위치 보정 | 다음 조각들 |

**구현이 계약에 되먹인 것(2026-09-18).** ① **제품 캡처가 결함을 잡았다** — 파일 트리 root 가 `/` 인 창에서 같은 파일의 정의가 「root 밖」이 됐다:
`repo_path.underRoot` 의 경계 검사(`path[r.len] == '/'`)가 root `/` 에서 `//…` 만 통과시켰다. root 가 `/` 면 모든 절대 경로가 아래다(`CRUMB4`).
breadcrumb 표시가 같은 함수를 쓰므로 그쪽도 같은 판정이었다. ② 정의로 이동은 「파일 1개 = Term 1개」 유일성(`fileTermForPath`) 위에 선다 —
`file_entry` 없이 연 Term(판정자·캡처 훅의 `openPathInActivePane`)은 그 밖이라 같은 파일이 **또 열린다**. 제품 경로(파일 트리·`navigateTo`)는
전부 `openFileTermInActivePane` 이라 해당 없음이고, 판정자는 그 길로 연다. ③ 가짜 서버의 definition 답 모양은 **문서마다** 기억한다 —
전역 하나로 두면 다른 문서의 뒤늦은 `didOpen` 이 되돌린다(GOTO1 실측). ④ 캡처 훅 `MARU_FORCE_EDITOR_GOTO_DEF=1`: 요청이 나간 순간 caret
훅의 래치를 세운다 — 응답이 caret 을 옮긴 뒤 다음 프레임의 caret 훅이 먼저 돌아 되돌렸다.

**적대적 검증(2026-09-18, 1~4회차 · 변이 23)**: 1회차 순수 9 → 생존 1 · 2회차 제품 8 → 1(+무효 2 → 유효로 재실행) · 3회차 배선 6 → 1 · 4회차
재실행 5 → 1(선언한 등가).
- **B5** `⌘클릭`이 포인터가 아니라 caret 자리로 — 가짜 서버가 늘 같은 자리를 답해 「어디서 요청했는가」가 안 보였다. 첫 항목의 character 에
  **요청한 자리를 되돌리게** 하고, caret(2)과 포인터(1)를 갈라 잰다(`GOTO1`).
- **C6** 요청 seq 가 안 오름 — 판정자가 seq 를 손으로 세웠다. 요청마다 `waiting_seq` 가 1·2 로 오르는 것을 잰다.
- **B8** character 를 byte 로 — 가짜 서버가 utf-8 을 골라 등가였다. `MARU_FAKE_LSP_UTF16=1` 로 utf-16 을 고르게 하고 `가 x;` 의 byte 3 이
  character 1 로 가는 것을 되돌아온 자리로 잰다(`GOTO2`).
- **B1**(무효 → `seq > waiting_seq` 만 버리는 변이로 재실행) — 낮은 seq 의 낡은 응답이 움직였다 → `GOTO1` ⑺ 이 잡는다.
- **A9** `ETX4` ⑷ 의 전역 겹침 대조 — 오늘 전역에 `⌃` chord 가 없어 **등가**. 관문으로 남기고 코드 주석에 적었다.

**관측점**: `LSJ6`(순수: definition 요청 id·결과 세 모양·`LocationLink` 의 selection range 우선) · `CRUMB4`(순수: root `/`) · `GOTO2`(utf-16
서버 — character 단위) · `GOTO1`(제품 경계: 가짜 서버 — `F12` 로 같은
파일 안 이동(caret·되돌아가기 표식) · `⌃-`/`⌃⇧-` 로 뒤로·앞으로 · `⌘클릭` · 다른 파일(새 Term 이 열리고 caret) · root 밖(알림·안 열림) ·
`null`(알림) · 낡은 응답 버림) · `ETX4` 의 ⑷ 갈래(`⌃` 예외 목록).

### 8.3 관측 가능성과 민감정보

editor event는 처음부터 하나의 domain schema를 공유하되 문서 원문을 기본 trace에 넣지 않는다.

- 최소 event: `editor.opened`, `editor.changed`(revision/byte count만), `editor.save-started`, `editor.save-completed`, `editor.conflict`, `editor.watch-invalidated`, `editor.tool-started/completed`, `editor.bridge-overflow`.
- path는 grant-relative 또는 익명화한 값만 artifact에 남기고 capability, full text, diff blob, diagnostic message 원문, tool stdout/stderr는 기본 제외한다.
- control-plane/bridge event를 trace에 넣는 PR은 먼저 [facade-contracts.md](facade-contracts.md)와 [trace-replay.md](trace-replay.md)의 event/redaction/replay 의미를 갱신한다.
- failure artifact를 fixture로 승격할 때 [project-rules.md](project-rules.md)의 공통 redaction guard를 사용한다. source code에 token이 bare text로 들어갈 수 있어 자동 guard만으로 충분하다고 간주하지 않고 사람 검토를 요구한다.
- E2E artifact는 semantic summary와 redacted screenshot을 기본으로 하고, 실제 사용자 repository를 자동 캡처하지 않는다.
