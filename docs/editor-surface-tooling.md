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
| **설치 안내** | 클릭 → `newTab` + `sendTextAsKeys(명령)` — **Enter 는 안 보낸다**. 명령: `brew install zls` · `brew install llvm`(clangd — Xcode 가 있으면 이미 `/usr/bin/clangd`) · `npm i -g typescript-language-server typescript@5` · `rustup component add rust-analyzer` · `npm i -g pyright` · `go install golang.org/x/tools/gopls@latest` | §8.1a 「입력까지만 하고 실행하지 않는 것이 경계다」 |
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

**요청 id 는 i32 안(2026-09-20 실측 뒤의 결정).** 종류마다 `id_span = 1e8` 칸: hover `1e8+seq` · definition `2e8` · signatureHelp `3e8` · formatting `4e8` ·
rename `5e8` · completion `6e8` · codeAction `7e8` · codeAction/resolve `8e8` · completionItem/resolve `9e8` · semanticTokens `10e8`(`rpc.zig` 의 base 상수, `nextSeq` 가 칸 안에서 돌린다,
`classify` 는 칸으로 가른다; 가장 큰 칸 10e8+1e8-1 = 1,099,999,999 < 2^31). 처음엔 `N×1e9+seq` 였고 JSON-RPC 로는 적법하지만, **rust-analyzer(와 ruff 등 Rust `lsp-server` 크레이트 서버)는 정수 id 를 i32 로만
읽어** 넘치는 요청을 **알림으로 오인해 버린다** — `6_000_000_001` 짜리 completion 이 stderr 에 `unhandled notification` 으로만 남고 응답이 없었다(hover·definition 만
i32 안이라 그 둘만 됐다). 실 rust-analyzer 에 프레임을 그대로 재생해 잡았다(§8.2g-b 실측). 관측점 `LSJ13`(가장 큰 칸 끝 ≤ i32 최대 · seq 가 칸 안에서 돌고 0 을
건너뜀 · 칸 경계 · 칸 밖은 무시). 아래 절들의 id 표기는 이 표를 따른다.

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
| **요청** | 포인터가 머문 자리마다 요청 하나(id 는 `1e8+seq`(§8.2a id 표), 문서마다가 아니라 클라이언트마다 seq). **응답이 오면** 그 seq 가 지금 기다리는 것일 때만 연다 — 낡은 응답은 버린다. 서버가 없거나(ready 아님) 진단만 있으면 지연 뒤 **바로** 연다. 서버가 있고 진단도 있으면 응답을 기다린다(진단만 먼저 띄우면 응답이 와서 상자가 커지며 흔들린다) — 응답이 2초 안에 안 오면 진단만 연다 | `$/cancelRequest` 는 안 보낸다(1단 「하지 않는 것」과 같은 폭 — 낡은 응답을 버리는 것으로 충분) |
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
| **요청** | id 는 `2e8+seq`(hover 의 `1e8+seq` 와 같은 꼴 — §8.2a id 표). 응답이 오면 **지금 기다리는 seq** 일 때만 움직인다 — 낡은 응답은 버린다. 서버가 없거나 ready 아니면 무동작 | §8.2b 와 같은 규율 |
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

### 8.2d LSP 2단 ③ — 시그니처 힌트 (2026-09-18, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① [native-editor-ui §8.3](native-editor-ui.md) 은 호버와 시그니처를 **한 박스**로 계약했고 그 박스(`hover_box`)가
§8.2b 로 섰다 — 새로 서는 것은 「언제 띄우고 무엇을 강조하는가」뿐이다. ② 오버레이 raster 는 run 마다 **색**만 낸다(굵게 없음, `metal_lowering`
`placeText`) — 활성 파라미터 강조는 색 role 로 한다. ③ 트리거 글자는 서버가 준다(`signatureHelpProvider.triggerCharacters` — clangd 는
`(`·`,`·`<`… 여섯) — 1단은 `initialize` 응답에서 인코딩만 읽었으므로 이것을 더 읽는다. ④ 호버와 상자를 나눠 쓰므로 **주인**이 있어야 한다 —
시그니처가 열려 있는 동안 호버는 열지도 닫지도 않는다. ⑤ `ParameterInformation.label` 이 `[start, end]` 이면 그 offset 은 **협상한 위치
인코딩**의 단위다(LSP 3.17 「offsets are based on a UTF-16 string representation as `Position.character`」 — 협상 뒤엔 그 인코딩) →
`position.byteInLine` 으로 label 의 byte 로 옮긴다.

**레퍼런스(동작만).** VS Code `parameterHintsModel`: 트리거 글자·재트리거 글자(열려 있을 때)·열려 있는 동안의 caret 이동·내용 변경이 다시
묻고(`triggerKind`·`isRetrigger`·`activeSignatureHelp`), 결과가 `null`/빈 배열·blur·**마우스로 caret 이동**·설정 끔이면 닫는다. 지연 120ms.
`⇧⌘Space` = `editor.action.triggerParameterHints`. `↑↓` 로 시그니처를 오간다(`cycle`). Zed 는 `auto_signature_help` 기본 **false**.
우리는 VS Code 를 따른다(§1.1 「VSCode 사용자 무회귀」 — 기본 켬).

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | ⑴ 타이핑한 글자가 서버의 `triggerCharacters` 에 있으면(`insertText` 의 마지막 byte) `signatureHelp`(`triggerKind` 2·그 글자) ⑵ 열려 있는 동안 `retriggerCharacters`(`)` 등)도 같다 ⑶ 열려 있는 동안 revision 이나 caret 이 바뀌면 다시 묻는다(`triggerKind` 3·`isRetrigger`) — 요청이 나가 있으면 표시해 두었다가 응답 뒤 한 번 ⑷ `trigger_parameter_hints`(`⇧⌘Space`·팔레트) 는 어디서든(`triggerKind` 1) | VS Code 와 같다. 지연은 두지 않는다 — 요청은 한 번에 하나이고 응답이 갈아 끼운다 |
| **서버가 없거나 `signatureHelpProvider` 가 없으면** | 타이핑 트리거 없음, 명령은 무동작 | — |
| **결과** | `signatures` 가 비면 닫는다. `activeSignature`(없으면 0)·`activeParameter`(시그니처 것 → 전체 것 → 0). 줄: ① `‹i/N› ‹label›`(N > 1 일 때만 카운터) — 활성 파라미터 구간은 **테마 accent 색**(`accent_bar` — 탭 언더바와 같은 색; `focus_accent` 는 어두운 테마에서 회색이라 덜 강조돼 보였다, 캡처 실측) ② 파라미터 documentation ③ 시그니처 documentation(마크다운 축소 §8.3). 문자열 label 은 시그니처 label 안의 첫 일치 | VS Code 도 활성 파라미터를 굵게·강조색 — 우리 raster 는 색만 |
| **자리** | caret 의 셀 아래(§8 규칙 2 — 아래, 안 들어가면 위), `hover_box` 그대로(80칸·12행·padding 간격). caret 이 움직이면 프레임마다 따라간다 | §8.3 「같은 박스」 |
| **닫힘** | 결과 없음 · `Esc`(소비하지 않는다) · 상자 밖 클릭(흘려보낸다) · 마우스 클릭으로 caret 이 옮겨짐 · 문서가 안 보임·비교 뷰·오버레이 · `editor.parameter-hints` 끔. **키 입력은 닫지 않는다** — 타이핑하면서 보는 것이 존재 이유다(호버와 다른 점) | VS Code 「마우스 caret 이동은 닫는다」 |
| **호버와의 관계** | 상자의 주인은 하나다: 시그니처가 열려 있으면 호버는 열지도(포인터 정지 무시) 닫지도 않는다. 시그니처가 열릴 때 호버는 닫힌다 | §8.3 「한 박스」 |
| **켜고 끄기** | `editor.parameter-hints`(기본 켬). 끄면 타이핑 트리거만 꺼지고 명령은 남는다 | `editor.hover` 와 같은 관계 |
| **하지 않는 것** | `↑↓` 로 시그니처 오가기(첫 조각은 활성 시그니처 하나 + 카운터) · 상자 안 포커스 · 굵게(raster 가 색만) · 자동완성 뒤 자동 트리거(Zed `show_signature_help_after_edits`) · 지연 120ms | 다음 조각 |

**구현이 계약에 되먹인 것(2026-09-18).** ① **위치 요청은 지금 본문 기준이어야 한다** — `add(` 를 친 직후의 `signatureHelp` 가 그 프레임의
`didChange` 보다 먼저 서버에 닿아 옛 본문의 자리를 봤다(SIG1 실측: `null`). §8.2a 의 「프레임당 한 번」 동기화는 그대로 두되, 위치를 싣는
요청(hover·definition·signatureHelp)이 나가는 순간에는 밀린 `didChange` 를 먼저 보낸다(`flushDocument`). ② 편집 직후에는 행 배열이 비어
caret 앵커가 없을 수 있다(`refreshAfterEdit` 가 스냅숏을 버린다) — 응답은 임시 자리로 열고 다음 프레임의 `refresh` 가 자리를 잡는다.
③ 캡처 훅 `MARU_FORCE_PARAM_HINTS=1` 이 caret 자리에서 명령을 부른다.

**적대적 검증(2026-09-18, 1~4회차 · 변이 27)**: 1회차 순수 8 → 0 · 2회차 상태 기계 10 → 3 · 3회차 배선·주인 9 → 3 · 4회차 재실행 4 → 1(선언한 등가).
- **B1** 트리거 글자가 아니어도 묻는다 — 닫힌 채 `z` 를 쳐도 요청 수가 그대로인지(`SIG1`).
- **B9** 대기 중의 트리거를 잊는다 — 대기(seq 55)를 손으로 세우고 명령 → 안 보내고 `dirty`, 응답 뒤 한 번 더 보낸다.
- **B10** 열릴 때 호버를 안 내린다 — 호버를 먼저 띄운 뒤 명령으로 열면 호버의 줄이 비어야 한다(주인은 하나).
- **C4** 마우스 caret 이동의 닫기 — **닿을 수 없는 코드**였다: 상자 밖 눌림은 `mouse()` 머리의 `hover_client.mouseDown` 이 먼저 닫고(주인이
  시그니처면 시그니처를) 상자 안은 삼킨다 → 걷어냈다. **C6** 호버 tick 의 `active` 검사 — 상자 열림 검사가 이미 막아 등가 → 걷어내고 불변식
  (「시그니처가 열려 있으면 상자가 열려 있다」)을 주석으로. **C7** 호버 refresh 의 `active` 가드 — 프레임이 시그니처를 먼저 묻고 `hide` 도 같은
  가드라 등가. 호출자가 늘어나는 날을 위해 남기고 주석에 적었다.

**관측점**: `LSJ7`(순수: 요청 id `3e8+seq`·context·capability 파싱·`signatureHelpProvider` 트리거 글자·결과의 활성 시그니처/파라미터
기본값·label 세 모양) · `SIG1`(제품 경계: 가짜 서버 — `(` 를 치면 열리고 첫 파라미터가 accent, `,` 로 둘째, `)` 로 닫힘, `Esc`, 명령, caret
이동 재요청, 끄면 명령만, 호버가 안 열림).

### 8.2e LSP 2단 ④ — text edits 적용과 문서 포맷 (2026-09-18, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① [document-model §3.6](native-editor-document-model.md) 의 세 규칙(undo 하나·커서 보존·revision 검증) 중 **둘은
이미 서 있다** — `delta.apply` 가 변경 여럿을 한 연산으로 적용하며 같은 연산에서 selection 을 밀고(삭제 구간 안이면 시작으로 접는다 —
`mapOffset`), 제품의 `applyEditAsOne` 이 그것을 되돌리기 하나·스크롤·caret 추종까지 묶는다. 새로 서는 것은 **LSP `TextEdit[]` → `Delta`
변환**(줄·글자 → byte, 정렬, 겹침 거부)과 **revision 검증**뿐이다. ② 첫 소비자를 rename 이 아니라 **문서 포맷**으로 둔다 — rename 은 새 이름을
받는 입력 UI 가 필요한데 그런 오버레이가 없다(`input_box` 는 설정의 숫자 위젯). 포맷은 UI 없이 §3.6 의 세 규칙을 전부 지난다(파일 전체가 바뀌고
caret 은 남아야 한다). ③ `FormattingOptions.insertSpaces` — 이 편집기의 들여쓰기 단위는 **탭 문자**(`Tab` 키·`indent_lines` 가 넣는 것)라
`insertSpaces = false`, `tabSize = editor.tab-width`. 서버가 프로젝트 설정(`.clang-format` 등)을 우선하면 그것이 이긴다. ④ 겹치는 edit 은
명세가 금한다(「must not overlap」) — 거부하고 **아무것도 적용하지 않는다**(반만 적용된 문서를 만들지 않는다, §3.6 「실패하면 문서가 그대로다」).

**레퍼런스(동작만).** VS Code `editor.action.formatDocument` = `⇧⌥F`, `editor.formatOnSave` 기본 false. 포맷 뒤 caret·스크롤은 남는다.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **변환** | `TextEdit{range, newText}` 배열 → `delta.Change[]`: `range` 의 `{line, character}` 를 서버 인코딩으로 byte 에(`position.offsetOf`), `start` 오름차순 정렬(같은 start 의 삽입은 온 순서), **겹치면 전부 거부**(`error.Overlap`), 줄 밖은 문서 끝으로 clamp. `newText` 는 복사해 적용이 끝날 때까지 든다 | `Delta.isWellFormed` 의 불변식(정렬·비겹침)을 변환이 만든다 |
| **revision** | 요청 때의 `editor_lsp_version` 을 기억하고 응답 때 다르면 **버린다** + 알림 「문서가 바뀌어 포맷 결과를 버렸습니다」. 서버 응답에는 version 이 없으므로 클라이언트가 잰다 | §3.6 「revision 이 어긋나면 버린다」 |
| **적용** | `applyEditAsOne` — 되돌리기 **하나**, selection 은 delta 가 민다(삭제 구간 안이면 시작으로), 스크롤 앵커 보존, caret 추종 | §3.6 세 규칙 · 「별도 경로를 만들지 않는다」 |
| **트리거** | `format_document` — `⇧⌥F`(편집기 컨텍스트 ⑴ `⌘` 없는 `⌥`) · 팔레트 「Editor: Format Document」. 서버가 없거나 `documentFormattingProvider` 가 없으면 무동작. 응답이 빈 배열이면 무동작(이미 정리됨) | VS Code 키. 저장 시 자동 포맷은 「하지 않는 것」(§3.6 — 저장 경로는 editor-surface, 그리고 §8.1 의 tool_execute 판정이 선행) |
| **요청** | id `4e8+seq`, `options = {tabSize: editor.tab-width, insertSpaces: false}`. 보내기 전에 밀린 didChange 를 먼저 보낸다(`flushDocument`, §8.2d 와 같다). 나가 있는 요청이 있으면 **새 것이 대체**한다 — 앞 응답은 seq 가 달라 버려진다(구현이 되먹인 것: 「나가 있으면 무시」로 두면 답을 안 주는 서버(HANG) 뒤로 포맷이 영영 막힌다) | 위 ③ · 정의로 이동과 같은 seq 규율 |
| **거부** | `Overlap`·`Malformed` 는 **아무것도 적용하지 않고** 알림 「포맷 결과를 거부했습니다 — 겹치거나 모양이 틀립니다」. 응답이 오류(`error` 멤버)면 결과 없음과 같이 무동작 | 위 ④ |
| **적용 대상** | 요청한 **문서**(surface) — 탭을 옮겨 안 보여도 문서가 살아 있으면 적용한다(포맷은 화면이 아니라 문서에 하는 것 — hover·시그니처의 「보이는 Term 에만」과 다르다). 닫혔으면 버린다 | §3.6 은 문서 모델의 규칙이다 |
| **하지 않는 것** | 저장 시 포맷 · 범위 포맷(`rangeFormatting`) · 타이핑 시 포맷 · rename(입력 UI 뒤) · `WorkspaceEdit`(여러 파일 — rename 과 함께) · 포맷 뒤 caret 을 「같은 글자」로 되돌리는 것 이상(줄바꿈이 재배치되면 근사) | 다음 조각 |

**관측점**: `LSJ8`(순수: formatting 요청 id·options·`textDocument/formatting` capability) · `TXE*`(순수: `TextEdit[]` → `Change[]` — 정렬·같은 start
삽입 순서·겹침 거부·인코딩·줄 밖 clamp·빈 배열) · `FMT1`(제품 경계: 가짜 서버 — `⇧⌥F` 로 두 줄이 한 번에 바뀌고 undo 하나로 돌아오며 caret 이
같은 글자를 가리킨다 · 낡은 revision 은 버리고 알린다 · 겹침(`BADFMT`)은 거부하고 알린다 · 읽기 전용이면 요청이 안 나간다 · 빈 결과 무동작 · 낡은 seq · 요청한 문서가 안 보여도 적용) · `FMT2`(제품 경계: capability 없는 서버(`MARU_FAKE_LSP_NOFMTCAP`)에는 `⇧⌥F` 가 요청을 안 보낸다). 가짜 서버는 `options` 가 계약(`insertSpaces=false`·`tabSize≥1`)과 다르면 `null` 을 내고(제품 경계에서 options 를 잰다), 줄마다 첫 공백 묶음을 한 칸으로 줄이는 edit 을 **역순**으로 낸다(정렬은 클라이언트의 몫), `NOFMT` 면 `null`.

**적대적 검증(2026-09-18, 1~4회차 · 변이 38)**: 1회차 순수 13 → 0(무효 3 → 유효로 재실행) · 2회차 상태 기계·요청 17 → 1(무효 2 → 유효로 재실행) ·
3회차 배선 8 → 4 · 4회차 재실행 7 → 0. 선언한 등가 3:
- **B17** 오류 응답의 `result` 를 그대로 넘긴다 — JSON-RPC 2.0 은 `error` 가 있으면 `result` 가 없어야 하므로 가드를 지워도 같다. 명세를 어기는
  서버에 대한 방어로 남기고 주석에 적었다.
- **C3** `⇧⌥F` 의 `needs_editable = false` — `needs_editable` 는 비교 뷰에서만 읽히고 비교 뷰에서는 `formatDocument` 가 먼저 거절한다(S5 B6 과
  같은 등가). `true` 인 것은 뜻이다.
- **C7** `formatDocument` 의 비교 뷰 검사 — `readyClientFor` 가 비교 뷰를 먼저 거절한다(비교 뷰는 서버에 동기화되지 않는다). 정의·호버·시그니처와
  같은 싼 조기 반환.
- **C5·C6** 알림 번역 둘이 바뀜 — 판정자가 `t()` 로 같은 표를 읽어 **동어반복**이었다. `tIn(.en/.ko)` 의 글자(「discarded」·「버렸」·「rejected」·
  「거부」)를 직접 재도록 고쳐 사살.

### 8.2f LSP 2단 ⑤ — WorkspaceEdit 적용 규칙과 심볼 이름 바꾸기 (2026-09-19, 계획 공격 뒤의 사용자 결정)

**계획 공격이 드러낸 것.** ① `WorkspaceEdit` 는 기능이 아니라 **응답의 모양**이다 — 파일 하나의 `TextEdit[]`(§8.2e)을 파일 단위로 넓힌 것.
그러므로 새로 서는 규칙은 「여러 파일」에서만 생기는 넷이다: 전부 검증 뒤 적용(하나라도 틀리면 전체 거부) · 열려 있지 않은 파일 · 저장 ·
여러 파일 되돌리기. 파일 안의 규칙(정렬·겹침 거부·revision·undo 하나·caret 보존)은 §8.2e 를 그대로 쓴다. ② 입력 UI 는 이미 있다 —
탭·pane·파일 트리의 **인라인 rename**(`RenameTarget`·`rename_input`·IME·모달 라우팅). 심볼 rename 은 그 대상 하나를 더하고 상자를
심볼 자리에 띄우는 것뿐이다. ③ 첫 소비자는 rename — 요청 하나, 결과가 WorkspaceEdit, UI 는 입력 하나. code action 은 목록 UI 가 더
필요해 다음. ④ **레퍼런스는 열어서 확인했다**(VS Code 소스, MIT — 동작만; 적대적 검증으로 앞선 추정 셋이 틀렸다):
`files.refactoring.autoSave`(기본 true)는 「관련된 dirty 작업 사본 **전부**」를 저장하되 **두 파일 이상일 때만**이고, 한 파일이면 dirty 로
둔다; rename 되돌리기는 rename 을 다시 돌리지 않고 **적용 때 만든 역편집**을 되감으며, 닫힌 파일도 내용 해시가 같으면 되돌린다;
revision 은 `documentChanges` 의 `version` 이 있을 때만 검사한다(clangd 의 `changes` 맵에는 검사가 없다). ⑤ Neovim·Helix 는 버퍼로
열어 두고 저장을 사용자에게 맡기는데 「저장 안 된 버퍼 ↔ 서버 불일치」가 반복 이슈다 — 이 계약은 VS Code 쪽을 따른다(§1.1).

**사용자 결정(2026-09-19)**: 저장 정책은 **VS Code 그대로**(두 파일 이상이면 관련 파일 전부 저장, 한 파일이면 dirty) · `Undo Rename`
명령은 **이 조각에** 포함.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | `rename_symbol` — `F2`(편집기 컨텍스트 ⑶ 기능키, 파일 트리가 초점일 때의 `F2` 와 겹치지 않는다 — 키 문서 전수 대조) · 팔레트 「Editor: Rename Symbol」. 서버가 없거나 `renameProvider` 가 없으면 무동작 | VS Code `editor.action.rename` |
| **입력 상자** | 기존 인라인 rename 의 새 대상 `RenameTarget.symbol{surface, offset, revision}` — caret 아래 **낱말**(식별자: 글자·숫자·`_`·비ASCII)을 씨앗으로, 낱말 첫 글자 셀 아래 팝업(`popup_box` `below_flip_up`, 호버 상자와 같은 간격)에 `input_box`(끝 caret). `Enter` 확정 · `Esc` 취소 · 비었거나 같은 이름이면 요청 없이 닫는다. 모달이라 열린 동안 문서는 안 바뀐다 | `prepareRename` 은 하지 않는다 — 상자를 즉시 띄우고, 못 바꾸는 자리는 서버의 오류 응답을 알림으로 낸다 |
| **요청** | id `5e8+seq`, `textDocument/rename{position, newName}`. 보내기 전 밀린 didChange 를 먼저(`flushDocument`). 한 번에 하나 — 새 요청이 앞 것을 대체(§8.2e 와 같다) | |
| **응답 모양** | `changes`(uri → TextEdit[]) 와 `documentChanges`(TextDocumentEdit[] — 같은 uri 는 이어 붙인다) 둘 다 받는다. `CreateFile`·`RenameFile`·`DeleteFile` 이 하나라도 있으면 **전체 거부** + 알림. `file:` 이 아닌 uri 도 전체 거부 | 반만 적용된 rename 은 컴파일되지 않는 코드다 |
| **검증 → 적용** | 먼저 **모든 파일**을 검증하고 하나라도 틀리면 **아무것도 적용하지 않는다**: root 밖(`withinNavRoot`) · 열린 문서의 revision(그 문서를 든 모든 Term: 서버가 마지막으로 본 `sent_version == editor_lsp_version`, `documentChanges.version` 이 있으면 그것도 같아야) · 읽기 전용 · `toChanges` 의 겹침/모양 · 열려 있지 않은 파일은 읽어서(§3.5 의 `openPath` — UTF-8·BOM·CRLF 보존, 상한 §8.2a) 같은 검증. 그 다음 적용: 열린 Term 은 `applyEditAsOne`(Term 마다 undo 하나), 열려 있지 않은 파일은 메모리에서 적용해 저장 경로(`writeDocumentBytes` — 외부 변경 검사)로 쓴다 | §3.6 · VS Code 보다 엄격한 revision(`changes` 맵에도 검사) |
| **저장** | 관련 파일이 **두 개 이상**이면 열린 Term 도 `saveDocument` 로 저장한다(열려 있지 않은 파일은 늘 저장 — 버퍼가 없다). **한 파일**이면 저장하지 않고 dirty 로 둔다 | VS Code `files.refactoring.autoSave` 기본(2026-09-19 사용자 결정) |
| **기록** | 적용에 성공한 WorkspaceEdit 하나를 세션이 든다: 이름·파일마다 {경로, **역연산**(`delta.apply` 가 돌려준 것, 텍스트 소유), 적용 직후 **내용 해시**}. 새 rename 이 성공하면 갈아 끼운다. 되돌리기는 이 기록 위에 선다 | VS Code 의 역편집 보관과 같은 원리 — 되돌리기는 서버에 다시 묻지 않는다 |
| **`undo_workspace_edit`** | 팔레트 「Editor: Undo Last Rename」(기본 chord 없음). 기록의 **모든 파일**을 먼저 검증: 열린 Term 은 내용 해시가 기록과 같아야(그 뒤 편집·`⌘Z` 가 있었으면 다르다), 열려 있지 않은 파일은 디스크를 읽어 같아야. 하나라도 다르면 **전체 거부** + 알림(「{0} 이 바뀌어 되돌릴 수 없습니다」). 전부 같으면 역연산을 같은 길로 적용(열린 Term 은 `applyEditAsOne` — 그것도 undo 하나, 파일은 쓰기) + 같은 저장 정책. 성공하면 기록을 비운다 | VS Code 는 어긋난 파일에서 「이 파일만」을 묻는다 — 첫 조각은 보수적 부분집합 |
| **`⌘Z`** | Term 의 `⌘Z` 는 종전대로 **그 문서만** 되돌린다(§3.3). 그러면 기록의 해시가 어긋나 `Undo Rename` 은 거부된다 — 뜻이 맞다(이미 손으로 되돌린 파일을 다시 되돌리면 두 번 되돌아간다) | |
| **알림** | 성공 「{0}개 파일에서 이름을 바꿨습니다」 · 서버 오류 「이름을 바꿀 수 없습니다 — {0}」(서버 message) · 낡음 「문서가 바뀌어 결과를 버렸습니다」 · root 밖 「루트 밖 파일이 있어 적용하지 않습니다 — {0}」 · 거부 「적용할 수 없는 편집입니다 — {0}」(파일 연산·겹침·읽기 전용·읽기 실패) · 되돌림 「{0}개 파일의 이름 바꾸기를 되돌렸습니다」 · 되돌릴 것 없음 | |
| **하지 않는 것** | `prepareRename` · 미리보기 · `⌘Z` 에서 여러 파일 확인창 · 「이 파일만 되돌리기」 · redo · `CreateFile`/`RenameFile`/`DeleteFile` · 서버 발 `workspace/applyEdit`(§8.1 기본 거부 그대로) · code action · `annotations`/`changeAnnotations` | 다음 조각 |

**적대적 검증(2026-09-19, 1~4회차 · 변이 44)**: 1회차 순수 12 → 0 · 2회차 적용 규칙·rename 상태 19 → 1 · 3회차 배선 13 → 1 · 4회차 재실행 2 → 1(선언한 등가).
- **B17** 확정 때의 revision 검사 — 처음엔 「모달이라 닿을 수 없다」고 봤는데 메뉴바 `⌘Z` 는 rename 이 chrome 모달이 아니라 막히지 않는다
  (`dispatchAppAction(.editor_undo)` 경로). 상자를 열고 문서를 되돌린 뒤 확정하면 요청이 나가지 않아야 한다(`RNM1`) — 판정자를 더해 사살.
- **C4** `F2` 의 `needs_editable = false` — `needs_editable` 는 비교 뷰에서만 읽히고 그때는 `startAtCaret` 이 먼저 거절한다(S5 B6·§8.2e C3 과 같은
  등가). `true` 인 것은 뜻이다.
- 가짜 서버의 결함도 판정자가 잡았다: `RENAMECREATE` 가 `changes` 맵 모드에서는 파일 연산을 싣지 못해 rename 이 적용됐다 — 파일 연산은
  `documentChanges` 에만 실릴 수 있으므로 그 표식은 그 모양을 강제한다.

**관측점**: `LSJ9`(순수: rename 요청 id·newName·capability·오류 message) · `WSE*`(순수: `WorkspaceEdit` → 파일별 edits — `changes`·`documentChanges`
합치기·version·파일 연산 거부·`file:` 아님 거부·모양) · `RNM1`(제품 경계: 가짜 서버 — `F2` 로 낱말이 씨앗인 상자, 이름을 치고 `Enter` → 열린 문서와
**열려 있지 않은** 이웃 파일이 함께 바뀌고 저장되며 기록이 선다 · `undo_workspace_edit` 가 둘 다 되돌린다 · 디스크가 바뀐 뒤의 되돌리기는
전체 거부 · 낡은 revision 전체 거부 · root 밖 전체 거부 · 파일 연산 전체 거부 · 서버 오류 알림 · `Esc` 는 요청 없음 · 한 파일이면 dirty) ·
`RNM2`(제품 경계: capability 없는 서버에는 `F2` 가 상자를 열지 않는다).

### 8.2g LSP 2단 ⑥ — 자동완성 ①-a: LSP 완성 팝업 (2026-09-19, 계획 공격 뒤의 결정)

**계획 공격이 드러난 것.** ① 팝업의 **UI 계약은 이미 있다**([native-editor-ui §8.2](native-editor-ui.md) — 공통 규칙 넷 + 로컬 필터·`isIncomplete`·
「고르면 §3.6 으로」·ghost text 는 별개). 이 절은 그 계약 위에 **언제 묻고·무엇을 어떻게 고르고·어떻게 적용하는가**만 정한다(호버 §8.2b 와
같은 분업). ② 규칙 4 「목록은 `dropdown.zig` 의 팝업 부분」은 **그대로 쓸 수 없다** — 그 팝업은 enum 값 위젯이라 `_`→`-` 표시 변환, 창 없는
전체 행, `below_clamp`(뒤집지 않음 — 규칙 2 위반), 항목 하나의 라벨만 안다. 기하는 `popup_box` 가 단일 출처가 됐으므로(§8.3 의 선례 —
「신규로 남은 것은 줄 배치와 자체 스크롤뿐」) 완성 목록도 같은 꼴로 선다: `chrome/components/suggest_box.zig` = `popup_box` + 창 행(상한
10) + 선택 강조 + `label`/`detail` 두 열. ③ 적용은 §3.6 세 번째 소비자 — `textEdit`(접두사 교체) + `additionalTextEdits`(자동 import)가
**한 delta**(#3794 의 길). 응답 뒤에도 타이핑이 이어지므로 offset 이 밀린다 → 아래 「적용」이 그 규칙을 든다. ④ 오버레이 raster 는 프레임에
상자 **하나**다(`buildChromeOverlayPrep`) — 완성 팝업이 뜨는 프레임에는 호버·시그니처 상자가 안 그려지고(상태는 남는다 — 닫히면 `refresh`
가 다시 세운다), 호버 tick 은 팝업이 열린 동안 열지 않는다. ⑤ 스니펫은 받지 않는다 — `snippetSupport = false` 로 선언하면 서버가 평문
`insertText` 를 보낸다(clangd 실측: `add` 만).

**레퍼런스(동작만).** VS Code: 식별자 글자를 치면 뜬다(`editor.quickSuggestions` 기본 on, 지연 10ms), 서버의 `triggerCharacters` 로도, `⌃Space`
로도(mac). `↑↓` 고르기, `Enter`/`Tab` 확정, `Esc` 닫기, 나머지 키는 편집기로. 접두사가 비면 닫힌다. `insertMode = insert`(교체 범위는
`textEdit` 의 insert 범위). 필터는 fuzzy — 첫 조각은 **접두사**(대소문자 무시)로 두고 fuzzy 는 다음.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | ⑴ `insertText` 의 마지막 글자가 **식별자 글자**(글자·숫자·`_`·비ASCII)면 `triggerKind=1`(설정 `editor.quick-suggestions`, 기본 `true`) · ⑵ 서버의 `completionProvider.triggerCharacters` 에 있으면 `triggerKind=2`(설정과 무관) · ⑶ `trigger_suggest` — `⌃Space`(ETX4 ⑷ — 터미널 Term 에서는 NUL 로 PTY 로 간다)·`⌥Esc`(⑴), 팔레트 「Editor: Trigger Suggest」. 서버가 없거나 `completionProvider` 가 없으면 무동작 | VS Code 기본 셋 |
| **요청** | id `6e8+seq`, `textDocument/completion{position, context}`. 보내기 전 `flushDocument`. 한 번에 하나 — 대기 중 트리거는 `dirty` 로 응답 뒤 한 번 더(§8.2d 와 같다). 낡은 seq 는 버린다 | |
| **낱말** | 요청 때 caret 앞 식별자 구간 `[word_start, caret)` 이 접두사. 응답이 `textEdit` 을 들면 그 범위의 `start` 가 `word_start` 를 이긴다(서버가 `.` 뒤 같은 자리를 안다) | LSP `textEdit.range` |
| **목록** | `CompletionList{isIncomplete, items}` 또는 `CompletionItem[]`. 항목: `label`·`filterText`(없으면 label)·`sortText`(없으면 label)·`insertText`/`textEdit.newText`(없으면 label)·`detail`·`preselect`·`additionalTextEdits`. **로컬 필터** = 접두사(대소문자 무시)로 `filterText` 시작; **정렬** = 대소문자까지 맞는 접두사가 먼저(구현이 되먹인 것 — clangd 실측: `pri` 에 index 의 `•PRId16` 매크로가 sortText 로 `printf` 를 앞서 창을 채웠다; VS Code 는 자기 fuzzy 점수를 sortText 앞에 둔다), 그 안에서 `sortText`, 같으면 label; `preselect` 가 있으면 그것을 처음 선택. 창 10행, 선택은 창을 따른다 | ui §8.2 「필터링은 로컬」 |
| **타이핑 중** | 문서가 바뀌면 프레임마다 접두사를 다시 잰다(`[word_start, caret)`). caret 이 `word_start` 앞이거나 다른 줄이면 **닫는다**; 접두사가 바뀌었는데 `isIncomplete` 면 다시 묻는다(응답이 목록을 갈아 끼운다); 필터 결과가 0 이면 닫는다(다음 글자로 다시 뜬다) | ui §8.2 |
| **키** | 열린 동안 `↑`/`↓` 선택(창 이동), `Enter`/`Tab` 확정, `Esc` 닫기 — 셋만 소비한다. 나머지는 편집기로(타이핑하면서 좁혀진다). 화살표 `←→`·마우스 caret 이동·다른 오버레이·rename·문서 재로드는 닫는다. **보이지 않는 목록은 확정하지 않는다** — 응답은 왔지만 프레임이 아직 상자를 세우지 않았으면 `Enter`/`Tab` 은 편집기로 흘린다(구현이 되먹인 것: 캡처 실측에서 그 사이의 키가 보이지도 않은 첫 항목을 넣었다; VS Code 도 위젯이 보일 때만 받는다) | ui §8 규칙 3 |
| **적용** | primary caret 하나: 주 편집 = `[word_start, caret)` → `newText`(§3.6 — `applyEditAsOne` 하나) + `additionalTextEdits`. **응답 뒤 문서가 바뀌었으면** `additionalTextEdits` 는 전부 `word_start` 앞에서 끝날 때만 함께 적용한다(타이핑은 `word_start` 뒤에서만 일어나므로 그 앞의 offset 은 그대로다) — 아니면 그 항목의 additional 은 버린다(카운터). 적용 뒤 caret 은 `newText` 끝. 멀티 커서는 primary 만(다음) | §3.6 「자동 import 가 딸린 완성 하나도 undo 하나」 |
| **하지 않는 것** | 스니펫(`$1` 탭스톱) · fuzzy 필터 · `completionItem/resolve`(문서 지연 로드) · 문서 패널 · kind 아이콘 · commitCharacters · 버퍼 단어 fallback·스니펫·경로 완성(①-b) · ghost text(§4) · `itemDefaults` · 멀티 커서 · `PageUp/Down` | 다음 조각 |

**적대적 검증(2026-09-19, 1~5회차 · 변이 46)**: 1회차 순수·chrome 18 → 0(무효 3 → 유효로 재실행) · 2회차 상태 기계 18 → 5(무효 4 → 재실행) ·
3회차 배선 10 → 1 · 4회차 재실행 13 → 4 · 5회차 재실행 2 → 0. 판정자를 더해 사살한 것 여섯, 등가 1, 죽은 가드 1 제거:
- **B5** 대기 중의 트리거를 잊는다 — 대기(seq 55)를 손으로 세우고 글자를 치면 안 보내고 `dirty`, 응답 뒤 한 번 더(`CMP1`).
- **B9** caret 이 다른 줄로 가도 안 닫힌다 — 프로그램적으로 caret 을 옮기고 프레임을 돌리면 닫혀야 한다(그 검사가 없으면 접두사 슬라이스가 **패닉**한다 —
  방어이자 뜻).
- **B14** 응답 뒤 문서가 바뀌어도 낱말 뒤의 additional 을 적용한다 — 가짜 서버에 `fake_tail`(다음 줄 머리에 `// tail`)을 더해, 그대로면 함께·바뀌었으면
  버림을 잰다.
- **B16** `textEdit.start` 가 낱말 시작을 못 이긴다 — 가짜 서버에 `.` 뒤 `arrow_fix`(`x.` 부터 덮어 `x->m`)를 더해 잰다.
- **B8v** 접두사가 같아도 매 프레임 다시 세어 선택이 초기화된다 — `↓` 뒤 프레임을 돌려도 선택이 남아야 한다.
- **B12v** 수정자 chord 에도 안 닫힌다 — 처음 둔 `⌘→` 판정자는 화살표 갈래가 어차피 닫아 헛것이었다 → caret 을 안 옮기는 `⌥Z` 로.
- **B17** 낱말 밖 글자 검사 = **거의 등가**(접두사 필터가 먼저 0 으로 닫는다) — 서버가 `a(` 로 시작하는 filterText 를 낼 수 있어 방어로 남기고 주석.
- **C10** 호버의 완성 가드 — `notePointer` 에 둔 것은 앞서 세워 둔 `pointer_valid` 를 못 막았고(3회차 생존), `tick` 에 두니 `notePointer` 것은 등가가
  됐다(4회차 생존) → `tick` 하나만 남겼다.

**관측점**: `LSJ10`(순수: 완성 요청 id·context·capability 의 triggerCharacters·`snippetSupport=false`) · `CPL*`(순수: 목록 파싱 두 모양·필터/정렬/preselect·
`changesFor` — textEdit 범위/insertText/label 폴백·additional 합침·겹침 거부·인코딩) · `SGB*`(chrome: 창 10행·선택 강조·뒤집기·두 열) · `CMP1`(제품 경계:
가짜 서버 — 식별자 글자로 열리고 접두사로 좁혀지며 `↓`·`Enter` 로 고르면 접두사 교체 + import 한 줄이 **undo 하나**; `Esc`; `.` 트리거; `isIncomplete`
재요청; 접두사가 비면 닫힘; `⌃Space`; 설정 끄면 타이핑 트리거만 꺼짐; 낡은 응답; 팝업이 뜬 프레임엔 시그니처 상자 없음) · `CMP2`(capability 없음).

#### 8.2g-b 자동완성 ①-b — 버퍼 단어·병합·fuzzy·resolve·kind (2026-09-19, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① ui §8.2 는 「LSP 가 없다고 자동완성이 없는 상태가 되지는 않는다」를 **요구**한다 — ①-a 뒤 서버 없는 파일(Markdown·셸·
설정)은 타이핑해도 아무것도 안 떴다. ② 출처가 둘이 되면 병합 규칙이 필요하다 — 같은 label 은 LSP 것이 이기고(detail·textEdit 이 있다), 지금 치는
낱말 자체는 후보가 아니다. ③ 필터는 fuzzy 가 관례(VS Code) — `prtf` 가 `printf` 를 찾아야 한다; 점수는 ①-a 의 「대소문자 맞는 접두사 우선」을
포함해야 한다(그 판정자가 그대로 살아야 한다). ④ rust-analyzer 는 `additionalTextEdits`(자동 import)를 `completionItem/resolve` 로 **지연**해 낸다 —
확정 뒤에 resolve 하면 import 가 별도 편집이 되어 §3.6 「자동 import 가 딸린 완성 하나도 undo 하나」가 깨진다. VS Code 는 **강조된 항목을 미리
resolve** 해 확정 때는 대개 끝나 있다 → 같은 방식. ⑤ 단어 스캔은 문서 전체를 훑는다 — 상한을 두고 재야 한다.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **버퍼 단어** | 문서의 식별자 run(글자·숫자·`_`·비ASCII, 숫자로 시작하지 않음)을 **첫 등장 순**으로 중복 없이 모은다(상한: 앞 1 MiB · 2,000 개). 지금 치는 낱말(`[word_start, caret)`)은 뺀다. 첫 조각은 글자 부류 분할 — §5.3 트리의 토큰 경계는 그것이 더 정확한 사례가 잡힐 때 | ui §8.2(「없으면 단순 단어 분할로 저하」) |
| **출처 병합** | 서버가 있으면 LSP 항목 + 버퍼 단어, 없으면 버퍼 단어만. 같은 label(대소문자 그대로)은 LSP 것이 이긴다. 버퍼 단어의 `sortText` 는 `~`+단어(LSP 뒤), kind 는 `text` | ui §8.2 「에디터가 병합한다」 |
| **트리거** | 서버 없이도 식별자 글자면 연다(설정 `editor.quick-suggestions`). 서버 트리거 글자·`⌃Space` 는 그대로. 서버가 없으면 요청 없이 **그 자리에서** 목록이 선다(`isIncomplete` 는 없다) | |
| **fuzzy** | 접두사 문자들이 `filterText` 에 **순서대로 부분열**로 있으면 후보. 점수 = 정확한 접두사(대소문자까지) > 접두사(무시) > 낱말 경계(`_`·camelCase) 일치 > 연속 일치 > 나머지; 같은 점수는 `sortText`, 그다음 label. 빈 접두사는 전부 | VS Code 의 순서와 같은 축 |
| **resolve** | `completionProvider.resolveProvider` 면 **강조된 항목**(선택이 바뀔 때·목록이 열릴 때)을 `completionItem/resolve`(id `9e8+seq`, 항목 JSON 그대로)로 미리 푼다. 응답의 `additionalTextEdits`·`insertText`/`textEdit`·`detail` 을 항목에 합친다. 확정 때 아직 안 풀렸으면 응답을 기다렸다 **한 번에** 적용한다(undo 하나) — 300 ms 안에 안 오면 additional 없이 적용하고 센다. 낡은 seq·다른 항목의 응답은 버린다 | 위 ④ · §3.6 |
| **kind** | LSP `CompletionItemKind` → 한 글자 열(`f` 함수/메서드/생성자, `v` 변수/필드/상수, `t` 타입(클래스·구조체·인터페이스·enum), `k` 키워드, `m` 모듈, `s` 스니펫, `p` 속성, `w` 버퍼 단어, ` ` 그 밖) — label 앞 열 | VS Code 의 아이콘 자리를 글자로(등폭 상자) |
| **하지 않는 것** | 스니펫·경로 완성 · ghost text · 문서 패널(resolve 의 `documentation` 은 받아 두기만) · §5.3 트리 토큰 경계 · commitCharacters | 다음 |

**관측점**: `CPL4`(순수: 버퍼 단어 수집 — 순서·중복·숫자 시작·상한·치는 낱말 제외) · `CPL5`(순수: 병합 — 같은 label 은 LSP 승·sortText·kind) · `CPL6`(순수: fuzzy — 부분열·
점수 순서·①-a 의 대소문자 우선이 그대로) · `CPL7`(순수: kind 글자) · `LSJ12`(순수: resolve 요청·capability·응답 합치기) · `CMP3`(제품 경계: 서버 없는 파일 —
타이핑으로 버퍼 단어 목록이 뜨고 좁혀지고 확정된다) · `CMP4`(제품 경계: 가짜 서버 — 강조 시 resolve → 확정은 undo 하나; 확정 때 미해결이면 응답 뒤 한 번에; `RESOLVESTALL`
이면 300 ms 뒤 additional 없이; 병합 목록에서 같은 label 은 LSP 것).

**구현이 계약에 되먹인 것.** ① **fuzzy 는 서버가 준 목록 안에서만** — 서버는 제 필터로 거른 목록을 낸다(clangd 실측: `prf`·`prtf` 에 `printf` 를 내지
않았다). 버퍼 단어는 우리가 전부 들고 있으므로 fuzzy 가 온전히 닿는다(캡처: `prf` → `w prefer_tab`). 서버 목록에 fuzzy 를 더 넓히려면 서버에 다시
묻는 길(`isIncomplete`)뿐이고, 그것은 서버의 몫이다. ② **resolve 는 한 번에 하나** — 열릴 때 강조된 항목(preselect)의 resolve 가 아직 날아가는 중에
강조가 옮겨지면, 새 항목의 resolve 는 그 응답이 온 뒤 이어 나간다(`onResolveResponse` → `resolveHighlighted`; 낡은 응답은 버린다). 확정이 그 사이에
오면 기다리던 것을 버리고 강조된 항목의 resolve 를 새로 보낸 뒤 기다린다. ③ 가짜 서버의 「답하지 않는 resolve」 표식은 `RESOLVESTALL` — `…HANG` 으로
지으면 didChange 의 `HANG` 표식(서버째 멈춤)에 먼저 걸려 클라이언트가 재시작 상태로 간다(CMP4 첫 판에서 겪었다).

**실 rust-analyzer 실측(2026-09-20 — 사용자 요청: 「못 잰 것」을 재라).** `rustup component add rust-analyzer` 로 설치해 잰 것 둘. ① **요청 id** —
처음 `6e9+seq` 짜리 completion 은 응답이 아예 없었다(§8.2a id 표: i32 로 고쳤다). ② **resolve 의 모양** — 가짜 서버가 모사한 대로다: 목록의 항목은
`data` + `filterText: HashMap` + `textEdit`(치던 `HashMa` 구간) + `kind: 22`(Struct → `t`) 만 들고 오고 `additionalTextEdits`·`detail` 은 없다;
`completionItem/resolve` 응답에 `additionalTextEdits: [{0:0-0:0, "use std::collections::HashMap;\n\n"}]` 과 `detail`·`documentation` 이 온다.
캡처: 강조되자 resolve 가 나가 detail 이 행에 서고(`t HashMap(use std::collections::HashMap)  HashMap<{unknown…`), 확정 하나로 첫 줄 `use …;` 와
`HashMap` 이 함께 들어간다(`MARU_FORCE_SUGGEST=accept`). 곁가지 셋: label 이 `HashMap(use std::collections::HashMap)` 인 것은 우리가 `labelDetailsSupport`
를 안 내 서버가 import 경로를 label 에 접은 것(filterText 로 걸러 fuzzy 는 `HashMap` 을 본다) · 워크스페이스 로드 전(~1.3 s)의 completion 은 오류가 아니라
`result: null` 이라 목록이 안 서고 다음 글자에서 다시 묻는다(로딩 상태는 `experimental/serverStatus` — 다음) · `isIncomplete` 는 늘 true(flyimport).

**적대적 검증(2026-09-20, 1~5회차 · 변이 59)**: 1회차 순수 25 → 2 · 2회차 상태 기계 25 → 10 · 3회차 배선 6 → 1 · 4회차 재실행 6 + 새 변이 2 → 1 ·
5회차 재실행 1 → 0. 판정자 보강 일곱, 죽은 가드·중복 3 제거, 등가 4:
- **A5** 단어 스캔의 1 MiB 상한 — 개수 상한만 재고 있었다 → `CPL4` 에 1 MiB+1 짜리 run 뒤의 단어가 안 보이는 판정자.
- **A13** 같은 점수면 짧은 filter 우선 — `CPL6` 에 `a_b` › `a_b_long`.
- **B6** 열릴 때 강조 항목을 미리 푼다 — `CMP4` 가 키 없이 나간 resolve 를 센다(가짜 서버는 치는 낱말 `laz` 자체도 내고 그것이 첫 행이다).
- **B9** 풀린 항목은 다시 묻지 않는다 — `↓↓` 뒤 요청 수 그대로.
- **B17** 타임아웃 300 ms — 기다리는 동안 프레임을 돌려 0 ms 면 응답보다 먼저 additional 없이 들어가는 것을 잡고, 경과는 상수가 아니라 **300 리터럴**로 잰다(상수를 되비추면 어떤 값이든 초록).
- **B19** 접두사가 바뀌어 강조가 옮겨지면 키 없이 푼다 — `laz` → `y` 로 lazy_import 만 남을 때 resolve 가 나간다.
- **B23/B23v** `words_only` 는 서버 목록이 설 때 지운다 — 처음엔 `hide` 와 `onResponse` 둘에 있어 판정자가 어느 쪽도 못 봤다 → `installItems` 하나로 모으고 앞 흔적을 심어 잰다.
- **B18** 타임아웃 뒤 `resolved` 표시 = 죽은 코드(accept 는 안 보고 hide 가 비운다) → 제거. **B25** words_only 의 isIncomplete 가드 = 죽은 가드(`incomplete=false` 로 선다) → 제거. **B21** Enter 의 둘째 `resolve_item == idx` = 첫 가드가 보장 → 제거(첫 가드를 빼면 죽는다 — B26).
- 등가로 남긴 것: **B10**(못 보내면 `resolved` 표시 — Enter 는 어차피 적용한다, 되묻지 않게 하는 표시) · **B22**(hide 의 `pending_accept` 초기화 — 설치가 다시 지운다) · **C2**(error 응답의 `result` 는 없다 — 둘 다 실은 서버 방어).

#### 8.2g-c 자동완성 ①-c — labelDetails (2026-09-20, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① §8.2g-b 실측에서 rust-analyzer 의 행이 `t HashMap(use std::collections::HashMap)  HashMap<{unknow…` 로 잘렸다 — 우리가
`labelDetailsSupport` 를 안 내서 서버가 import 경로를 **label 에 접어** 보낸 것이고(LSP 3.17 `CompletionItemLabelDetails`), 그 긴 label 이 detail 칸을 먹었다.
② 선언하면 무엇이 오는지 **실측**(rust-analyzer 1.96.1 · clangd): rust-analyzer 는 `label: "HashMap"` + `labelDetails{detail: "(use std::collections::HashMap)",
description: "HashMap<{unknown}, …>"}`(description = 타입, resolve 뒤의 `detail` 과 같은 글), clangd 는 `label: " printf"` + `labelDetails{detail: "(const char *, ...)"}`
+ `detail: "int"`(description 없음 — 반환형은 `detail`). 즉 `labelDetails.detail` 은 **label 바로 뒤에 붙는 꼬리**(시그니처·import 표시)이고 오른쪽 열은
`description` 이 있으면 그것, 없으면 `detail` 이다. ③ VS Code(MIT, 동작만 — `suggestWidgetRenderer.ts`·`suggest.css`): 왼쪽 = label + `label.detail`(옅게),
오른쪽 = `label.description`(85%·옅게); 위젯 430px 고정 안에서 **오른쪽이 먼저 접히고**(`flex-shrink: 4`, `max-width: 70%`) 그래도 넘치면 왼쪽도 `…`. 우리는
등폭 상자라 칸으로 같은 뜻을 세운다. ④ 필터·정렬·병합·resolve 는 건드릴 것이 없다 — filterText 는 그대로고(rust-analyzer `HashMap`, clangd `printf`) 버퍼 단어는
labelDetails 가 없다.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **capability** | `initialize` 에 `completionItem.labelDetailsSupport: true`. 선언했으면 **반드시 그린다** — 서버가 label 에서 뺀 것을 우리가 안 그리면 정보가 사라진다 | LSP 3.17 |
| **파싱** | `labelDetails.detail` → `label_detail`, `labelDetails.description` → `description`(둘 다 없을 수 있다). `filter`·`sort`·`insert` 규칙은 그대로 | ② |
| **행** | ` k ` + label + **label_detail(옅게, 간격 없이)** + 간격 2 + **오른쪽(옅게, 우측 정렬)** = `description` 있으면 그것, 없으면 `detail`. resolve 가 `detail` 을 채우면 오른쪽이 바뀐다(description 이 없을 때) | ③ · clangd 의 `int` 는 detail 이다 |
| **폭** | 좌패딩 1 + kind 1 + 간격 1 + (label + label_detail) + (오른쪽 있으면 간격 2 + 오른쪽) + 우패딩 1, 상한 60 | §8.2g 와 같은 상한 |
| **접기(넘칠 때)** | ① 오른쪽을 먼저 접되 **16칸 아래로는 안 접는다**(오른쪽이 16칸보다 짧으면 그 길이까지) → ② 그래도 넘치면 label_detail 을 `…` 로 → ③ 그래도 넘치면 label 을 `…` 로. 오른쪽이 없으면 label_detail → label 순. 상자가 문턱보다도 좁으면(화면 clamp) label 4칸을 남기고 오른쪽은 있는 만큼 | ③ 의 「오른쪽 먼저, 그래도 넘치면 왼쪽도」 — 등폭 상자에서 비례 대신 문턱 |
| **색** | label 은 `surface_fg`, label_detail·오른쪽은 `muted_fg`(run 별 role — lowering 은 run 의 색이 이긴다) | VS Code 의 옅은 두 자리 |
| **하지 않는 것** | 넓히기(드래그·저장) · 옆 문서 패널(②, resolve 의 `documentation` 은 받아 둔 채) · clangd 의 label 접두 정리 — `labelDetailsSupport` 를 내면 clangd 는 include 상태 칸(`•` = include 필요, 공백 = 이미 있음)을 label 머리에 붙여 `f  printf(...)` 로 한 칸 뜬다(캡처 실측; 서버의 것, filterText 는 `printf`) | 다음 |

**관측점**: `CPL8`(순수: labelDetails 파싱 — 둘·하나·없음, filter 는 그대로) · `LSJ14`(순수: initialize 의 `labelDetailsSupport`) · `SGB3`(순수 chrome: 행 run 셋과
색 역할 · 폭 계산 · 접기 순서 셋 — 오른쪽 16 문턱 → label_detail → label) · `CMP5`(제품 경계: 가짜 서버가 labelDetails 를 실은 항목 — 행에 꼬리와 오른쪽이 서고 description 이 detail 을 이기며, labelDetails 없는
항목은 꼬리가 없고, 폭은 label+꼬리) · `CMP3`(버퍼 단어 행에는 꼬리도 오른쪽도 없다) · `CMP4` ⑵(resolve 뒤 detail 이 오른쪽에 선다 — description 없는 항목).

**적대적 검증(2026-09-20, 1~3회차 · 변이 27)**: 1회차 순수·chrome 19 → 2 · 2회차 제품 8 → 1 · 3회차 재실행 1 → 0. 판정자 보강 하나, 등가 둘:
- **A18** 그리기가 fold 의 label 값을 쓴다 — `fold` 만 재고 그림은 안 쟀다 → `SGB3` 에 60칸을 넘는 label 행(`…` 이 서고 오른쪽 1칸이 산다).
- **A9** 문턱 계산의 안쪽 `@min(right_w, 16)` = 등가(바깥 `@min(right_w, …)` 이 이미 묶는다) → 뺐다. **B8** 빈 꼬리를 복사해도 0 바이트라 등가 — 「빈 것은 복사하지 않는다」는 뜻을 위해 남긴다.

#### 8.2g-d 자동완성 ①-d — 옆 문서 패널 (2026-09-20, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① §8.2g-c 뒤에도 긴 꼬리·설명은 60칸 안에서 `…` 로 접힌다 — 전문을 읽을 자리가 없다. ② VS Code(MIT, 동작만 —
`suggestWidgetDetails.ts`·`suggestWidget.ts`·`suggestController.ts`): 패널 = **`detail`(코드 머리) + `documentation`(마크다운)**, 자리는 **동 → 서 → 남/북**
순으로 들어가는 첫 자리, 토글은 mac `⌃Space`(위젯이 보이고 강조 항목이 있을 때 — 없을 땐 같은 키가 `triggerSuggest`), 펼침 상태는 프로필 저장
(`expandSuggestionDocs`, 기본 false), 미해결 항목은 250 ms 뒤 「Loading…」, 드래그로 넓힐 수 있다. ③ 우리가 이미 가진 것: 마크다운 축소
`session/editor/hover_text.reduce`(호버 §8.2b 가 쓴다), 줄 상자 `hover_box`(줄 배치·행 스크롤·폭 80/행 12 상한), `popup_box`(세로 배치 — **옆 배치가
없다**). ④ `initialize` 의 completion `documentationFormat` 이 `["plaintext"]` 라 서버가 문서를 평문으로 준다 — 패널을 세우면 호버처럼 마크다운을 받아
같은 축소를 쓴다(`Item` 은 아직 `documentation` 을 안 읽는다; resolve 로도 온다 — `resolveSupport` 에는 이미 있다).

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **내용** | `detail` 줄(코드) → 빈 줄 → `documentation`(문자열 또는 `MarkupContent.value`) 을 `hover_text.reduce` 로 줄들. 둘 다 없으면 패널이 없다. `documentationFormat: ["markdown", "plaintext"]` | ② · ③ |
| **자리** | 목록 상자의 **오른쪽**(간격 1칸, 위 맞춤) → 안 들어가면 **왼쪽** → 그것도 안 되면 **아래**, 그것도 안 되면 **위**(`popup_box.placeBeside`). 네 방향 모두 workspace 안쪽 한 셀을 남긴다(§8 팝업 규칙) | ② 의 동→서→남/북 |
| **크기** | `hover_box` 와 같다 — 폭 = 가장 긴 줄 + 좌우 1칸(상한 80), 높이 = 줄 수(상한 12), 긴 줄은 자르고 넘치는 줄은 행 스크롤(휠, 패널 안에서만) | ③ |
| **토글** | 목록이 열려 있고 강조 항목이 있으면 `⌃Space`(=`trigger_suggest`) 는 **패널 토글**, 아니면 지금처럼 목록 열기. 펼침 상태는 **앱 세션 동안 기억**한다(닫았다 다시 열어도 그대로) — 디스크 저장은 다음(설정 저장 층의 결정) | ② 의 같은 키 |
| **강조 따라가기** | 강조가 바뀌면 패널도 그 항목으로. 항목이 미해결이면(resolve 가 나가 있음) 강조 뒤 **250 ms** 가 지나야 `…` 한 줄(로딩)을 세우고, 응답이 오면 갈아 끼운다 — 250 ms 안에 오면 로딩 줄은 안 보인다 | ② 의 250 ms |
| **닫힘** | 목록이 닫히면 패널도(줄은 비운다, 펼침 상태는 남는다). 패널은 키를 가로채지 않고(모달 아님) 포인터는 패널 안 휠만 | §8.2b 「모달 아님」과 같다 |
| **하지 않는 것** | 드래그 넓히기 · 링크 클릭 · 펼침 상태 디스크 저장 · `documentation` 이 없는 항목의 resolve 재시도 | 다음 |

**구현이 계약에 되먹인 것.** ① §8.2g ⑻b 「수정자 키는 목록을 닫는다」에 예외 하나 — `trigger_suggest` 로 풀리는 chord(`⌃Space`·`⌥Esc`, 키바인딩
표로 판정)는 닫지 않고 흘려 `triggerManual` 이 토글한다(닫고 다시 열면 토글이 설 자리가 없다). ② 실측(rust-analyzer `HashMap`): 문서는 원문이
줄바꿈된 채 오고(hard wrap) 우리는 80칸에서 자른다 — 랩 없음은 호버와 같은 결정. clangd 의 `documentation` 은 문자열 `From <stdio.h>`.
③ 패널 줄은 강조 항목마다 다시 세우되 풀린 뒤에는 `docs_ready` 로 한 번만(프레임마다 축소하지 않는다) — 풀리기 전엔 참이 될 수 없으니 resolve 응답에서 따로 내리지 않는다.

**관측점**: `CPL9`(순수: `documentation` 파싱 — 문자열·MarkupContent·없음, resolve 로 합치기) · `PBX1`(순수: `placeBeside` — 동·서·남·북과 clamp) ·
`SGD1`(순수 chrome: 패널 줄·자리·스크롤) · `CMP6`(제품 경계: 가짜 서버 — `⌃Space` 토글, 강조 따라가기, 로딩 줄 250 ms, 응답 뒤 detail+문서, 닫힘, 세션
기억, 패널 안 휠).

**적대적 검증(2026-09-20, 1~4회차 · 변이 38)**: 1회차 순수·chrome 17 → 0 · 2회차 제품 20 → 3(+무효 1, 디스크가 차서 6개는 3회차로) · 3회차 재실행 8 → 3 ·
4회차 재실행 4 → 0. 판정자 보강 다섯, 등가 하나:
- **B3** 접혀 있으면 풀린 항목이라도 줄을 안 세운다 — 미해결일 때만 재면 접힘과 미해결이 겹쳤다(픽스처가 개념을 갈라야 한다).
- **B7** 풀린 뒤 한 번만 세운다 — 프레임을 더 돌려도 `docs_built` 그대로.
- **B18·B19·B20** 휠 배선·패널 안 클릭·강조 이동 시 스크롤 0 — 클라이언트를 직접 부르면 배선을 빼도 초록이었다 → **제품 진입점**(`scrollWheel`·`mouse`)으로.
- **B11** resolve 응답에서 `docs_ready` 를 내리는 줄 = 등가(풀리기 전엔 참이 될 수 없다) → 뺐다.

**적대적 검증 반복(2026-09-20, 5~8회차 · 새 변이 30 — 사용자 요청 「3회 반복」)**: 5회차 경계값 10 → 8 · 6회차 제품 상태 10 → 6 · 7회차 배선·자료
모양 10 → 7 · 8회차 재실행 17 → 0. 앞 네 회차가 「넉넉한 사례」만 재고 있었다 — 경계·상태 구석·그리기 순서가 통째로 비어 있었다. 판정자 보강 열넷,
죽은 것·등가 여섯:
- **C1~C4** `placeBeside` 의 네 경계(동 `x+w == 우측`, 서 `== 좌측`, 남 `== 하단`, 북 `== 상단`) — 딱 맞으면 그 자리다(`PBX1`).
- **C5·C10** 스크롤 값이 넘치면 마지막 창 / 음수는 0 에서 묶는다 — 안 묶으면 슬라이스 **패닉**·언더플로(방어이자 뜻, `SGD1`). **C6** 빈 줄은 op 을 안 낸다.
- **C7** 패널의 오른쪽 경계는 밖 · **C8** 폭 상한 80 은 `hover_box.size` 의 것(`SGD1`).
- **D1** 로딩 줄은 하나뿐 · **D2** 상자가 아직 안 섰으면 `⌃Space` 는 토글이 아니라 다시 묻기(「보이지 않는 목록」 규칙의 연장) · **D4** 휠 델타 0 은 무동작 ·
  **D8** 줄 색은 `surface_fg` · **D9** detail 없는 문서 항목(가짜 `arrow_fix` 에 문서를 실었다)은 빈 줄 없이 문서부터(`CMP6`).
- **E2·E10** host 가 목록 행 뒤에 패널 quad 를, 목록 상자 **위 맞춤·오른쪽 한 칸**에(host 판정자 새로) · **E3** value 없는 MarkupContent 는 문서 없음(`CPL9`).
- 등가·죽은 것: **D7** 토글 뒤 `docs_item = null`(접히면 `refreshDocs` 가 비우고 펼칠 땐 이미 비어 있다) → 뺐다 · `docs_loading` 필드는 읽는 곳이 없어 뺐다 ·
  **E5**(같은 문서 재복사 — 누수 아님) · **E7**(닫히면 줄이 비어 앞 가드 둘은 방어) · **E9**(토글의 `metal_dirty` — 키 경로가 세운다) · **E1** 은 주석만 바꾼 무효 변이.

### 8.2h LSP 2단 ⑦ — code action (2026-09-19, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① 결과는 `WorkspaceEdit` — §8.2f 의 `apply`(전부 검증·저장 정책·기록)를 **두 번째 소비자**가 그대로 쓴다(요청
시점 revision 스냅숏도 같다). 새로 서는 것은 「무엇을 묻고, 무엇을 목록에 내고, 고르면 어디로 가는가」뿐. ② **목록은 메뉴다** — 타이핑으로
좁히는 것이 아니라 고르는 명령 목록이므로 ui §8:441 「메뉴는 `context_menu.zig`」가 맞고(`suggest_box` 가 아니다), 우클릭·`⚙`·리소스 팝오버가
쓰는 그 하나에 갈래(`code_action_menu`)를 더한다 — 모달이라 열린 동안 키는 잡힌다(`Esc`·다른 키 = 닫힘, VS Code 의 action widget 과 같다).
③ **문맥 진단이 있어야 fix 가 온다**(clangd 실측 — 사용자 요청의 적대적 검증): 원본 진단 그대로 / `range`+`message`+`severity`+`code` 만 → 같은
`insert ';'` / 문맥을 비우면 **없음**. 우리 `Diagnostic` 은 넷을 다 든다(`data`·`source` 문자열은 안 들지만 clangd 는 필요로 하지 않았다). ④ rust-analyzer
는 `edit` 을 **지연**해 낸다(`codeAction/resolve` 가 있어야 edit 이 온다) — 첫 조각에 resolve 를 넣지 않으면 그 서버에서는 목록만 뜨고 아무것도
안 된다 → 넣는다. ⑤ `command` 만 있는 항목·`edit` 과 `command` 가 함께인 항목의 `command` — §8.2 seam 은 `workspace/executeCommand` 를 기본 거부로
못 박았다 → command 는 실행하지 않는다(전자는 숨기고, 후자는 edit 만).

**레퍼런스(동작만).** VS Code `editor.action.quickFix` = `⌘.`(mac), action widget: `↑↓`/`Enter`/`Esc`, `isPreferred` 가 앞, 진단이 있는 줄의 전구.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **트리거** | `quick_fix` — `⌘.`(ETX4 ⑵ 예외 — 전역 표에 `.` chord 없음, `needs_editable = true`) · 팔레트 「Editor: Quick Fix…」. 서버가 없거나 `codeActionProvider` 가 없으면 무동작 | VS Code |
| **요청** | id `7e8+seq`, `textDocument/codeAction{range, context{diagnostics, triggerKind: 1}}`. `range` = 선택이 있으면 그것, 없으면 caret. `context.diagnostics` = 그 범위와 겹치는 `.lsp` 진단을 `range`·`message`·`severity`·`code` 로 되돌린다(byte → 서버 인코딩). 보내기 전 `flushDocument`, 요청 시점 열린 문서 revision 스냅숏(§8.2f). 한 번에 하나 — 새 요청이 앞 것을 대체 | 위 ③ |
| **목록** | `(Command \| CodeAction)[]` 중 **`edit` 이 있거나(`resolveProvider` 면) `data` 로 resolve 할 수 있는 `CodeAction`** 만. `disabled` 는 숨긴다. `isPreferred` 가 앞(안정 정렬). 상한 25(메뉴 버퍼). 0 이면 알림 「사용할 수 있는 코드 액션이 없습니다」 | 위 ⑤ · VS Code |
| **메뉴** | `context_menu` 를 caret 셀 아래에 연다(`at_anchor` — 앵커가 caret 아래 줄). 항목은 `title` 그대로(kind 는 첫 조각에서 표시하지 않는다). `↑↓`/`Enter`/클릭 확정, `Esc`·다른 키·바깥 클릭 닫힘 | ui §8 규칙 넷 · §8:441 |
| **확정** | `edit` 이 있으면 §8.2f `apply`(전부 검증 → 열린 Term undo 하나·디스크·저장 정책·기록 — `Undo Last Rename` 이 이것도 되돌린다). 없으면 `codeAction/resolve`(id `8e8+seq`, 고른 항목의 JSON 그대로) → 응답의 `edit` 을 같은 길로. 낡음·root 밖·거부 알림은 §8.2f 것 그대로. `command` 는 실행하지 않는다 | 위 ①④⑤ |
| **하지 않는 것** | 전구(gutter 표시) · 자동 적용(`Fix All`·저장 시) · `command` 실행 · kind 별 묶음·머리글 · `only` 필터 · 저장 시 code action · refactor 미리보기 · 25 넘는 목록 | 다음 조각 |

**적대적 검증(2026-09-19, 1~4회차 · 변이 30)**: 1회차 순수 10 → 1(무효 2 → 유효로 재실행) · 2회차 상태 기계·요청 13 → 3 · 3회차 배선 7 → 1 ·
4회차 재실행 5 → 0. 판정자 보강 셋, 죽은 가드 1 제거, 등가 1:
- **A6** `Command` 형을 거르는 가드 — 뒤의 「`edit` 도 `data` 도 없음」이 이미 숨겨 **죽은 코드**였다 → 걷어내고 주석.
- **B5** 항목 상한 25(메뉴 버퍼) — 가짜 서버 `MANYACT`(data-only 30 개)로 잰다; 상한이 없으면 버퍼 밖을 써 **ABRT** 로 죽는다(방어이자 뜻).
- **B8** resolve 응답에 `edit` 이 없으면 알림 — 가짜 서버 `RESOLVEEMPTY` 로 잰다.
- **B13** resolve 요청의 capability 검사 = 등가 — `parse` 가 resolve 불가 서버의 data-only 항목을 이미 숨겨 그 길로 못 온다(방어로 남김).
- **C6** 알림 번역(ko)이 바뀜 — 판정자가 `t()` 로 같은 표를 읽어 동어반복이었다(§8.2e 와 같은 실수) → `tIn(.ko/.en)` 의 글자로 직접.

**관측점**: `LSJ11`(순수: codeAction 요청 id·range·context.diagnostics·resolve 요청·capability) · `CAX*`(순수: 항목 파싱 — `edit`/`data`/`command`/`disabled`/
`isPreferred` 정렬·Command 형 거름) · `CA1`(제품 경계: 가짜 서버 — `⌘.` 로 진단 자리의 fix 와 lazy 항목이 메뉴에, command-only 는 없음; fix 를 고르면 진단
범위가 바뀌고 undo 하나·기록; lazy 를 고르면 resolve → edit 적용; `Esc`·바깥 클릭 닫힘; 문맥 없는 자리(`NOACT`)는 알림; 낡은 revision 전체 거부; resolve
오류 알림; 낡은 seq) · `CA2`(capability 없음).

### 8.2i LSP 2단 ⑧ — semantic tokens 2층 (2026-09-20, 계획 공격 뒤의 결정)

**계획 공격이 드러낸 것.** ① visual-mapping §5 가 층 구조를 이미 계약해 뒀다 — 구문 트리(즉시·항상) 위에 LSP semantic tokens(지연 도착·의미
인식)가 **부분적으로** 덮고, 어휘는 각자 우리 `Role`(11색)로 다대일 매핑하며, **보이는 범위만** 묻고 범위를 못 하는 서버는 전체로 물러난다.
그 절이 정한 것은 그것까지고, 요청 시점·낡은 토큰·매핑 표·상한은 여기서 정한다. ② **실측** — rust-analyzer 1.96.1: `range` 지원, legend 가 표준
23종 밖의 것을 잔뜩 낸다(`builtinType`·`angle`·`brace`·`escapeSequence`·`formatSpecifier` …, 수식자도 `library`·`associated` 등) → **legend 이름으로
매핑하고 모르는 것은 무색**(우리가 `tokenTypes` 를 선언해도 서버는 제 legend 를 낸다); 로드 전에는 `-32801 content modified` **오류**로 답한다(다시
묻는다); 12줄에 토큰 60(≈5/줄). clangd: **`range` 없음, `full{delta}` 만** → 전체로 물러난다; 76,760줄·2.5 MB `parser.c` 가 토큰 1,874·39 KB·6 ms(자료
표라 적다) → 전체 요청의 상한은 문서 크기가 아니라 **토큰 수**로 둔다. ③ 편집 중의 낡은 토큰 — VS Code 는 옛 토큰을 편집만큼 **밀어** 새 것이 올 때까지
보인다(키마다 색이 꺼졌다 켜지면 깜빡인다); 우리는 편집 통지가 한 자리(`syntax onEdit` 와 같은 함수)를 지나므로 같은 자리에서 민다. ④ 위치는 서버
인코딩의 (줄, 글자, 길이)라 `position.offsetOf` 로 byte 로 옮긴다(한 줄 토큰만 — `multilineTokenSupport: false`). ⑤ 렌더 합성은 이미 「마지막 스팬이
이긴다」(`syntax_colors.lineColors`) — 1층 스팬 뒤에 2층 스팬을 문서 순서로 섞어 넣으면 겹치는 자리만 2층이 이긴다.

| 축 | 결정 | 근거 |
| --- | --- | --- |
| **capability** | `textDocument.semanticTokens{requests: {range: true, full: true}, tokenTypes: 표준 23, tokenModifiers: 표준 10, formats: ["relative"], multilineTokenSupport: false, overlappingTokenSupport: false}`. 서버의 `semanticTokensProvider{legend, range, full}` 를 읽는다 | LSP 3.17 |
| **요청** | id `10e8+seq`(§8.2a 표에 열 번째 칸). **capability 로 갈린다**(시도하고 물러나는 폴백이 아니다 — `initialize` 응답의 `range`/`full` 로 처음부터 정한다): `range` 를 냈으면 **보이는 원본 줄 범위 ± 20줄** 을 `semanticTokens/range`, 안 냈으면(clangd) `semanticTokens/full`(delta 는 안 쓴다). 보내기 전 `flushDocument`; 요청은 그 문서의 `editor_lsp_version` 을 단다 | §5 「보이는 범위만」·② |
| **시점** | 프레임마다 판정: 서버 ready·provider 있음·요청 없음·(토큰의 version ≠ 문서 version **또는** 보이는 범위가 덮인 범위 밖) **그리고 마지막 편집 뒤 120 ms** 가 지났을 때. 한 번에 하나, 대기 중 바뀌면 `dirty` 로 응답 뒤 한 번 더 | 타이핑마다 왕복하지 않는다(VS Code 도 지연) |
| **응답** | 그 요청의 version 과 지금 version 이 다르면 **버린다**(다시 묻는다). `-32801`(content modified)·오류·`null` 도 버리고 다시. `data` 를 relative 로 풀어 byte 스팬으로 — legend 이름을 `Role` 로 옮기고 모르는 것·무색 것은 뺀다. **상한 50,000 토큰** — 넘으면 앞부분만 | ② |
| **매핑(코드가 소유 — `session/lsp/semantic.zig`)** | `type·class·struct·enum·interface·typeParameter·builtinType·enumMember` → `type_name` · `function·method·macro` → `function` · `keyword·modifier·builtinAttribute?` → `keyword` · `comment` → `comment` · `string·character·regexp·escapeSequence` → `string` · `number·boolean` → `number` · `property·event` → `property` · `decorator·attribute·derive` → `attribute` · `operator` → `punctuation` · `variable·parameter·namespace·label·lifetime·그 밖` → 무색(1층이 그대로). 수식자는 첫 조각에서 안 쓴다 | §5 「다대일·색이 상한」 — tree-sitter 표(`syntax_capture`)와 같은 방향 |
| **편집 중** | 편집 통지(`start, old_end, new_end`)로 토큰을 민다: 편집 구간과 겹치는 토큰은 버리고 뒤는 `new_end - old_end` 만큼 옮긴다. 범위를 모르는 편집(undo/redo)은 전부 버린다. 민 토큰은 문서 version 이 아직 안 맞으므로 다음 요청이 갈아 끼운다 | ③ |
| **렌더** | `editor_syntax.lineColorsInto` 가 1층 스팬 뒤에 2층 스팬을 **문서 순서로 병합**(같은 시작이면 2층이 뒤) → 「마지막이 이긴다」로 겹친 자리만 2층 | ⑤ |
| **닫힘·수명** | 문서와 함께(`releaseEditorTerm`). 서버가 죽거나 provider 가 없으면 토큰 없음 — 1층만(저하, 실패 아님) | §5 「LSP 부재는 정확도 저하」 |
| **하지 않는 것** | `full/delta` · 수식자 색(deprecated 취소선 등) · 미니맵의 2층(§6 — 전 문서) · 토큰 기반 접힘 · `semanticTokens/refresh` 서버 요청(지금은 거부 응답 — 다음) | 다음 |

**구현이 계약에 되먹인 것.** ① **가시 변화는 1층이 못 가르는 자리에서만 난다** — 캡처 실측: C 의 `#define N` 의 `N`(1층 constant → number 색 →
2층 macro → function 색)·구조체 필드 `x`(1층 field → 2층 property), Rust 표본(`use std::collections::HashMap` · `fn add(a: i32…)`)은 tree-sitter 쿼리가 이미
타입·함수·필드를 가려 **바뀐 자리가 0**이었다. 2층의 값은 TS/JS 처럼 1층이 class 와 variable 을 못 가르는 언어·매크로·typedef 이름의 사용처에 있다.
② range 요청의 끝은 `{line: hi+1, character: 0}`(반열림) · `last_edit_ms == 0` 은 「아직 편집이 없다」라 조용 시계를 안 본다 · 응답이 오류면 조용 시계를 되감아
곧바로 되묻지 않는다. ③ 색 배열은 렌더 축이라 창 앞 줄만큼 빈 슬롯이 앞에 선다(판정자가 `first_line` 을 뺀 첨자로 읽다 틀렸다). ④ **TS 실측(typescript-language-server 6.0 + typescript@5)**:
`range`·`full` 둘 다 내고 legend 에 표준 밖 `member`(메서드 — function 으로 매핑). 표본(class·enum·enumMember·console.log)에서도 **바뀐 자리 0** — 이유가 다르다: 2층이
`enumMember → property`·`member → function` 을 냈지만 우리 팔레트에서 **property 와 function 이 같은 색(bright blue)**이고 `variable` 은 무색이라 구분이 색에서 사라진다.
색 11개 상한(§5.3)의 대가다 — 2층의 값을 보이게 하려면 팔레트 분리(별도 결정)가 먼저다. ⑤ `npm i -g … typescript` 는 이제 typescript@7(네이티브, `tsserver.js` 없음)을
받아 typescript-language-server 6.0 이 `initialize` 에서 죽는다 → 설치 명령을 `typescript@5` 로 고정했다(§8.1a·`servers.zig`).

**관측점**: `LSJ15`(순수: capability·provider 파싱·요청 둘·id 칸) · `SEM1`(순수: relative 풀기·legend 매핑·모르는 종류 무색·상한·인코딩 utf-16·legend 없는
provider) · `SEM2`(순수: 편집 밀기 — 앞·겹침·뒤) · `ES40`(순수: 1층+2층 병합 — 겹친 자리만 2층, 꼬리 1층 유지) · `SMT1`(제품 경계: 가짜 서버 — range 요청·
응답 뒤 색·편집 밀기·120 ms·낡은 version 버림·undo 는 밀기·스크롤 범위·반열림 끝) · `SMT2`(`full` 폴백·provider 없음·오류 응답 뒤 되묻기).

**적대적 검증(2026-09-20, 1~5회차 · 변이 50)**: 1회차 순수 20 → 4 · 2회차 제품 20 → 4 · 3회차 배선 10 → 4 · 4회차 재실행 5 → 2 · 5회차 재실행 1 → 0. 첫 실행은
`.zig-cache/o` 만 지운 탓에 빌드 러너가 없어 **50 전부 「죽음」으로 찍힌 헛것**이었다(검증 도구부터 검증) — 캐시를 통째로 지우고 다시 돌렸다. 판정자 보강 다섯,
죽은 가드·등가 일곱:
- **A3** legend 없는 provider 는 미지원 · **A8** 모르는 종류 첨자는 무색(처음 판정자는 그 튜플을 줄 밖에 둬 그 이유로 빠졌다 — 픽스처가 개념을 갈라야 한다).
- **B19** 마지막 2층 스팬 뒤의 1층 꼬리가 남는다(`ES40` 의 `void`) · **C6** range 끝은 반열림(`hi+1`) — 1층도 선언을 함수로 칠해 색으론 못 가르고, 끝 줄바꿈 없는
  문서의 마지막 줄 토큰이 **스팬 목록**에 드는지로 잰다(두 번 헛돌았다: 끝 빈 줄이 있으면 `hi` 가 그 줄이라 등가, 색은 1층이 이미 같았다).
- 등가·죽은 것: **A9**(`len == 0`)·**A10**(`end > content.len`) 은 `end <= start` 와 `offsetOf` 의 줄 끝 묶기가 이미 거른다 → 뺐다 · **B2**(tick 의 provider 검사 —
  요청이 다시 본다) → 뺐다 · **B15**(onEdit 의 `dirty` — 편집이 version 을 올린다) → 뺐다 · **B20**(1층이 비면 2층도 안 그림 — 글자가 있어야 토큰이 있다) ·
  **C2**(`is_error` — 오류 응답엔 result 가 없다) · **C5**(seq 증가 — 한 번에 하나) · **C8**(undo 를 빈 범위로 — undo 도 `spanFromInverse` 가 범위를 내어 `null` 경로는
  방어) 은 방어로 남기고 주석.

### 8.3 관측 가능성과 민감정보

editor event는 처음부터 하나의 domain schema를 공유하되 문서 원문을 기본 trace에 넣지 않는다.

- 최소 event: `editor.opened`, `editor.changed`(revision/byte count만), `editor.save-started`, `editor.save-completed`, `editor.conflict`, `editor.watch-invalidated`, `editor.tool-started/completed`, `editor.bridge-overflow`.
- path는 grant-relative 또는 익명화한 값만 artifact에 남기고 capability, full text, diff blob, diagnostic message 원문, tool stdout/stderr는 기본 제외한다.
- control-plane/bridge event를 trace에 넣는 PR은 먼저 [facade-contracts.md](facade-contracts.md)와 [trace-replay.md](trace-replay.md)의 event/redaction/replay 의미를 갱신한다.
- failure artifact를 fixture로 승격할 때 [project-rules.md](project-rules.md)의 공통 redaction guard를 사용한다. source code에 token이 bare text로 들어갈 수 있어 자동 guard만으로 충분하다고 간주하지 않고 사람 검토를 요구한다.
- E2E artifact는 semantic summary와 redacted screenshot을 기본으로 하고, 실제 사용자 repository를 자동 캡처하지 않는다.
