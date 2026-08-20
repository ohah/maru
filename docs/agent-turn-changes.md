# 에이전트 턴 변경분 — 훅 경계·AI 소행·영속성

[에디터 Surface 도구](editor-surface-tooling.md) **§6.1 «에이전트 턴 diff(agent-turn base)»** 의 후속 절을
소유한다. §6.1이 정한 것 — 턴 경계의 의미, 임시 index 스냅샷 메커니즘, 링 8개, 비교 방식, 화면 소유(에이전트
탭 턴 타임라인, [editor-surface-dock.md §3.5.4](editor-surface-dock.md)) — 은 **그대로 두고 참조한다.**

**훅 층 자체는 [에이전트 훅 통합](agent-hooks.md)이 소유한다** — 이벤트 세트, 두 모드(훅/관측), 전달 채널,
설치·제거, 비용, 알림 정책. 이 문서는 그 층의 **소비자**로서 턴 변경분만 다룬다.

이 문서가 새로 정하는 것은 넷이다.

1. **턴 경계를 provider 훅으로** 잡는다(관측은 폴백 모드) — §3
2. **AI 소행을 확정**한다: 어느 파일이 에이전트 도구로 바뀌었는지 — §4
3. **셸 편집 사각지대**를 정직하게 표시한다 — §2.3·§5
4. **스냅샷을 재시작 너머로 보존**한다 — §6

## 1. 왜 지금 필요한가

§6.1의 구현(P5, 2026-08-18 완료)은 "무엇이 바뀌었나"를 정확히 답한다. tree↔tree 비교라 커밋·스테이징과
무관하고, `add -A`가 파일시스템을 통째로 굳히므로 **어떤 도구가 고쳤는지와 무관하게** 잡힌다.

남은 결함은 셋이고, 셋 다 "틀린 것을 보여준다"가 아니라 **"있어야 할 것이 없어진다"** 는 형태다.

| 결함 | 현상 | 이 문서의 대응 |
| --- | --- | --- |
| 턴 경계를 화면 관측으로 잡는다 | 전이를 한 번 놓치면 스냅샷이 안 찍혀 **두 턴이 하나로 합쳐진다.** 사후 복구 불가 | §3 훅 트리거 |
| AI 소행과 사용자 편집이 섞인다 | 턴 중 사용자가 저장한 파일이 그 턴 목록에 들어간다 | §4 배지 |
| 링이 메모리·창 로컬이다 | 앱을 끄면 목록이 사라지고, tree 객체도 참조가 없어 `git gc` 대상이라 **복원조차 불가** | §6 ref 고정 |

## 2. 실측 근거 (2026-08-20, 개발자 머신)

### 2.1 검증 수준

| 항목 | Claude | Codex |
| --- | --- | --- |
| 훅 `SessionStart` | ✅ **직접 실행**(`source=startup`) | ✅ **직접 실행**(격리 `CODEX_HOME`, `source=startup`) |
| 훅 `UserPromptSubmit` | ✅ 직접 실행 | ✅ 직접 실행(`turn_id` + `prompt` 원문) |
| 훅 `Stop` | ✅ 직접 실행 | ✅ 실물 payload(maru v2 훅이 남긴 것) |
| 훅 `PreToolUse`(편집 도구) | ✅ 직접 실행(`file_path`·`description`) | ✅ **직접 실행** — `command` 하나뿐이라 경로는 패치 텍스트에서 훑는다([계약 §2.1](agent-hooks.md)) |
| 훅 `PostToolUse`(편집 도구) | ✅ 직접 실행, `structuredPatch`·`originalFile` 확보 — **크기 때문에 세트에서 제외**([계약 §3.1](agent-hooks.md)) | ❌ 미검증 |
| 셸 편집에 파일 정보 없음 | ✅ 직접 실측 | ✅ **직접 실측**(`sed -i` 로 고쳤으나 명령 문자열 외에 경로 정보 없음) |
| 세션 파일의 변경 기록 | ✅ 파일 파싱 | ✅ 파일 파싱 |
| 세션 시작 커밋 | 필드 없음을 확인 | ✅ `session_meta.git.commit_hash` |
| 커밋 없이 tree 스냅샷 비교 | ✅ 실증(§2.4) | provider 무관 |

Codex 미검증 2건은 훅 자체는 발화했고(`SessionStart`·`UserPromptSubmit` 수신) 그 뒤 턴이 서지 않아 남았다.
한도가 풀린 뒤 §2.5 절차를 1회 더 돌려 채운다.

### 2.2 훅 payload — 두 provider가 동형이다

Claude(훅 임시 설치 → `claude -p` 1회 → stdin 덤프 → 설정 원복):

| 이벤트 | 관측한 필드 |
| --- | --- |
| `SessionStart` | `session_id`, `transcript_path`, `cwd`, `source=startup` |
| `Stop` | + `prompt_id`, `permission_mode`, `effort`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` |
| `PostToolUse`(Edit) | `tool_name`, `tool_use_id`, `duration_ms`, `tool_input{file_path, old_string, new_string, replace_all}`, `tool_response{filePath, oldString, newString, **originalFile**, **structuredPatch**, userModified, replaceAll}` |
| `PostToolUse`(Bash) | `tool_input{command, timeout}`, `tool_response{stdout, stderr, interrupted, isImage, noOutputExpected}` — **파일 정보 없음** |

실측한 `structuredPatch`: `[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-alpha","+beta"]}]`

Codex(격리 `CODEX_HOME`에 훅을 걸고 `codex exec --dangerously-bypass-hook-trust` 1회 — 사용자 실환경
`~/.codex`는 건드리지 않았다):

| 이벤트 | 관측한 필드 |
| --- | --- |
| `SessionStart` | `session_id`, `transcript_path`, `cwd`, `model`, `permission_mode`, `source=startup` |
| `UserPromptSubmit` | + **`turn_id`**, **`prompt`**(사용자 입력 원문) |
| `Stop` | + `stop_hook_active`, `last_assistant_message` |

**배선이 provider별로 갈리지 않는다.** 둘 다 `session_id` + `transcript_path` + `cwd` + `hook_event_name` +
`source`를 주고, 턴 식별자(Codex `turn_id` ↔ Claude `prompt_id`)와 Stop의 `last_assistant_message`·재진입
가드가 대응한다.

**⚠️ 그러나 지금 이 payload를 읽는 프로덕션 코드는 없다.** `~/.codex/hooks.json`의 maru v2 훅이 파일을
남기고는 있지만, 그 파일을 소비하는 유일한 경로
([`app_session/agent.zig`](../src/platform/macos/app_session/agent.zig) `agentIdentityFromStatuslineFile`)는
⑴ **claude 전용**이고(`term.agent_kind != .claude`면 즉시 반환) ⑵ `plausibleIdentity`로 **세션 id 문자열만**
인정한다. Codex가 쓴 JSON은 현재 legacy 정리 대상일 뿐이다. 위 payload는 **실측으로 회수한 것이지 배선이
있다는 뜻이 아니다** — 전달 채널은 AT1이 새로 정한다(§3.2).

### 2.3 셸 편집을 provider가 못 보는 이유

편집 도구(Edit/Write, apply_patch)는 **CLI가 직접 파일을 읽고 쓰므로** before/after를 안다. Bash/exec는
**셸 프로세스를 띄우고 stdout을 받을 뿐**이라 그 안에서 `sed`가 무엇을 했는지 CLI에 정보가 없다. 훅은 CLI가
아는 것을 배달하는 통로이므로 **훅을 더 걸어도 생기지 않는다.**

같은 이유로 Claude의 `~/.claude/file-history/` 백업도 안 뜬다 — 실험으로 확인했다(셸로 파일을 만들고 고친 뒤
그 세션 백업 디렉터리에 아무것도 생기지 않았다. Write 도구로 만든 것만 있었다).

규모: 한 세션(maru3, 2026-08-14) 툴 집계가 **Bash 3403 : Read 165 : Edit 12 : Write 5**였다. 이 저장소의
세션은 "가능하면 Bash로 편집"이라는 지시 아래 돈다. Codex는 `apply_patch`가 표준 경로라 사각지대가 훨씬
작다(같은 규모 세션에서 `patch_apply_end` 1355건).

**그래서 provider 기록은 변경의 권위가 될 수 없다.** §6.1의 tree 스냅샷이 권위이고, provider 기록은 **소행의
근거**다. 두 소스는 정확히 반대의 강점을 가진다(§4 표).

### 2.4 커밋 없이도 턴이 갈린다 — 실증

§6.1이 실측한 메커니즘을 이 워크트리에서 **커밋 0회·스테이징 0회**로 재확인했다.

```
턴1: read-tree HEAD → add -A → write-tree  →  7d70f81a…
     (그 사이 셸 `printf >>` 로 파일 수정 + 새 파일 생성)
턴2: 같은 절차                              →  7cc31cc1…
git diff --name-status 7d70f81a 7cc31cc1  →  M docs/…  A docs/turn2-probe.md
```

`git log -1` 그대로(커밋 안 생김), `git status --porcelain`에 staged 없음(진짜 index 무변형). 수정을 **셸로
했는데도 잡혔다**는 것이 §2.3 사각지대를 tree 스냅샷이 메운다는 증거다.

위 OID는 그 시점 워크트리에 의존하므로 **재현 대상이 아니다.** 재현할 것은 절차(세 명령과 두 확인)이고,
회귀로 고정할 것은 AT5의 통합 테스트다(임시 저장소에서 같은 절차를 돌린다).

### 2.5 수동 검증 절차 (provider 메이저 버전마다 재실행)

1. **격리 홈**을 쓴다 — Claude는 설정 백업 후 복원, Codex는 `CODEX_HOME`을 임시 디렉터리로 두고
   `auth.json`은 복사하지 말고 심볼릭으로 빌린다(자격증명 복제 회피).
2. 그 홈에 [계약 §2](agent-hooks.md) 세트를 걸어 stdin을 파일로 덤프한다(+검증 목적이면 `PostToolUse(*)`도
   임시로 걸어 payload 크기를 재확인한다 — 세트에서 뺀 근거가 그 크기다).
3. 헤드리스 1회 실행(`claude -p …` / `codex exec … --dangerously-bypass-hook-trust`). **편집 도구와 셸 편집을
   각각 1회씩** 시킨다.
4. 덤프에서 §2.2 표의 필드가 그대로인지 대조하고, 셸 편집이 여전히 payload에 안 나오는지 확인한다.
5. **원복한다.**

## 3. 턴 경계 — 관측에서 훅으로

§6.1의 경계 정의(`running → idle`, `blocked`·`unknown` 제외)는 **의미의 단일 출처로 그대로 둔다.** 바뀌는 것은
그 경계를 **무엇으로 아는가**뿐이다.

| 신호 | 트리거 | provider |
| --- | --- | --- |
| `SessionStart` | 세션 base 스냅샷(턴 0) | Claude ✅ / Codex ✅ |
| `UserPromptSubmit` | 진행 중 항목의 시작 표시 | Claude ✅ / Codex ✅(`turn_id`) |
| `Stop` | **턴 종료 스냅샷** + `last_assistant_message`를 그 턴 제목으로 | Claude ✅ / Codex ✅ |

- 관측 경로(`turn_snapshot.isTurnEnd`)는 **폴백으로 남긴다.** 훅 미설치·설치 거부·구버전 provider에서 기능이
  통째로 죽으면 안 된다.
- 두 경로는 **같은 `Ring.push`로 수렴한다.** §6.1의 "같은 tree가 연달아 오면 안 넣는다" 규칙이 중복 push를
  자동으로 흡수하므로, 훅과 관측이 같은 턴을 두 번 알려도 항목이 겹치지 않는다.
- 훅이 주는 것은 **경계 시각**이지 변경 내용이 아니다. 스냅샷은 여전히 §6.1 메커니즘으로 찍는다.

**훅이 고치는 것은 «놓침»이지 «지연»이 아니다.** 전달이 파일 경유이고 소비가 tick pull인 한(§3.2) 반응
지연은 tick 해상도 그대로다. 이득은 다른 데 있다 — 화면 관측은 전이를 놓치면 **그 턴이 영영 없지만**, 훅이
남긴 이벤트는 파일에 남아 다음 tick에 반드시 읽힌다. 문서·PR에서 이 둘을 바꿔 적지 않는다.

**Stop은 한 턴에 여러 번 올 수 있다.** 실측 payload에 `stop_hook_active`(재진입 표시)와 `background_tasks`가
있다 — 서브에이전트·백그라운드 작업이 있으면 Stop이 다시 발화한다. `stop_hook_active`가 참인 이벤트는
**턴 종료로 세지 않는다.** 그 가드가 없으면 한 턴이 스냅샷 두 개로 쪼개진다("같은 tree면 스킵" 규칙은 그
사이에 파일이 바뀌면 흡수하지 못한다).

### 3.1 링에 턴 식별자를 싣는다

`Stop`의 턴 식별자(Claude `prompt_id` / Codex `turn_id`)를 스냅샷 항목에 함께 저장한다. **§4의 AI 소행
확정이 이 값에 의존한다** — provider 기록에서 뽑은 턴별 편집 집합을 링의 몇 번 항목에 붙일지 잇는 유일한
안정 키다. 시각(`captured_s`)으로 맞추면 tick 지연·재진입 Stop에서 어긋난다.

### 3.2 전달 채널

훅 payload가 maru에 닿는 경로(append-only ndjson + 오프셋 tail 소비)와 그 근거는
[에이전트 훅 통합](agent-hooks.md) §4가 소유한다. 이 문서는 그 채널이 **모든 이벤트를 보존한다**는 성질에만
의존한다 — 턴 경계는 한 이벤트라도 유실되면 그 턴이 사라지기 때문이다.

## 4. AI 소행 확정

### 4.1 소스 둘의 역할

| 소스 | 셸 편집 | AI 소행 확정 | git 필요 | 상태 |
| --- | --- | --- | --- | --- |
| tree 스냅샷(§6.1) | ✅ | ❌ | ✅ | **구현됨**(P5) |
| provider 기록 | ❌ | ✅ | ❌ | 신규 |

**훅 모드에서는 이 파싱이 필요 없다.** 편집 도구의 경로가 `PreToolUse.tool_input.file_path`로 직접 오기
때문이다([agent-hooks.md](agent-hooks.md) §3.1). 아래 세션 파일 파싱은 **관측 모드용 폴백**이다.

provider 기록의 내용: Claude는 transcript user 라인의
`toolUseResult{filePath, oldString, newString, originalFile, structuredPatch}`, Codex는 rollout의
`patch_apply_end.changes{type, unified_diff, content, move_path}`. **둘 다 이미 hunk/diff 형식**이라 별도 계산
없이 경로 집합을 뽑을 수 있다.

**provider 기록으로 최종 상태를 재생(replay)하지 않는다.** 되돌린 변경·부분 적용·외부 편집 때문에 재생 결과가
디스크와 어긋난다. 표시할 내용은 언제나 §6.1의 tree 비교에서 온다.

### 4.2 배지

턴 목록의 각 파일에 근거를 붙인다.

| 배지 | 조건 | 뜻 |
| --- | --- | --- |
| `✎ AI 편집` | tree 비교에 있고 provider 기록에도 있음 | 에이전트가 편집 도구로 고쳤다 |
| `· 턴 중 변경` | tree 비교에만 있음 | 셸 편집이거나 사용자·다른 세션 |
| `↩ 순변경 없음` | provider 기록에만 있음 | 만졌지만 결과가 원복됐다 |

**기본은 전부 보인다.** `✎`만 보이도록 필터를 기본으로 걸면 §2.3 사각지대를 UI가 숨기는 셈이 된다. 필터는
토글로만 둔다.

### 4.3 파싱 비용

전체 transcript 파싱이 필요하다는 것은 §6.1이 이미 «신규 구현 필요»로 적어 두었다. 그 위에 더할 규율:

- **명시 액션에서만** 전량 스캔한다(탭을 펼쳤을 때). `toolUseResult`에 `originalFile` 전체가 실려 파일이 크다
  (47 MB 사례).
- 사이드바용 256 KiB tail 캐시([`agent_transcript.zig`](../src/session/agent_transcript.zig))를 재사용하지
  않는다 — 그건 마지막 한 쌍용이고, §6.1도 같은 이유로 신규 코드가 필요하다고 적었다.

## 5. 화면

§6.1·[§3.5.4](editor-surface-dock.md)의 에이전트 탭 턴 타임라인을 그대로 쓴다. **새 도크·새 뷰어를 만들지
않는다.** 항목에 더하는 것은 배지 한 칸과 셸 고지 한 줄뿐이다.

```text
턴 3 · 2분 전 · claude · "테마 토글을 설정에 노출"        3개 파일 +240 −57
  M src/config/theme.zig                +42 −3     ✎ AI 편집
  A docs/agent-turn-changes.md          +118 −0    ✎ AI 편집
  M src/platform/macos/app_session.zig  +80 −54    · 턴 중 변경
  ⚠ 셸 명령 12개 — 이 중 파일을 고친 것이 있을 수 있다
```

- 셸 고지는 그 턴의 provider 기록에서 센 **셸 도구 호출 수**다. 0이면 줄이 사라진다.
- git 저장소가 아니면 tree 비교가 없으므로 `· 턴 중 변경` 줄이 사라지고 `✎` 목록만 남는다. **기능이 죽지
  않는다.** 그 경우 목록 머리에 불완전함을 명시한다.
- 행 클릭은 선택만, diff 본문은 [네이티브 편집기 diff 뷰](native-editor-ui.md) 재사용.

## 6. 영속성

§6.1은 링을 정의했지만 **수명을 정하지 않았다.** 현행은 메모리·창 로컬이라 앱 종료 시 소실되고, 그때
스냅샷 tree는 참조가 없어 `git gc` 대상이 된다 — 즉 나중에 복원하려 해도 객체가 없을 수 있다.

- 링의 각 tree를 **`refs/maru/turn/<owner-key>/<n>`으로 고정한다.** ref가 있으면 `gc`가 수거하지 않는다.
- **`<owner-key>`는 재시작을 넘어 안정적이어야 한다.** 링은 창(`AppSession`)당 하나이므로
  ([`app_session.zig`](../src/platform/macos/app_session.zig) `turn_ring`) 두 창이 같은 저장소를 열면 ref 이름
  공간이 겹친다 — 저장소는 공유이고 링은 창 로컬이기 때문이다. §6.1의 임시 index가 창마다 다른 파일을 쓰는
  것과 같은 축이 필요하다.
  **그러나 그 창 키를 그대로 쓰면 안 된다** — 현행 임시 index 키는 `@intFromPtr(self)`(프로세스 안에서만
  유일한 포인터 주소)라, ref에 쓰면 재시작 후 자기 ref를 알아보지 못하고 고아 ref만 쌓인다. 키는 workspace
  restore가 쓰는 **안정 식별자**에서 온다(구체 선정은 AT5).
- ref는 링 용량(8)만큼만 유지하고, 밀려난 항목의 ref를 지운다. **`gc`를 직접 부르지 않는다.**
- 시작 시 자기 `<owner-key>` 아래의 고아 ref를 정리한다. 다른 키의 ref는 건드리지 않는다(다른 창의 것일 수 있다).
- 저장소가 바뀌면 링을 버린다는 §6.1 규칙은 그대로다 — 그때 ref도 함께 지운다.
- **목록 자체의 디스크 영속(재시작 후 타임라인 복원)은 별도 결정이다.** 이 문서는 객체 보존까지만 정한다.
  ref만 있어도 "그 tree가 아직 있다"가 보장되므로, 목록 영속은 나중에 얹을 수 있다.

## 7. 보안·개인정보

- `oldString`/`newString`/`originalFile`/`unified_diff`는 **사용자 소스코드 원문**이다. trace·crash artifact·
  fixture·telemetry에 싣지 않는다([project-rules.md](project-rules.md) redaction 기준).
- 관측 이벤트에는 파일 **개수·바이트·소요 시간**만 남긴다. 경로도 남기지 않는다.
- 훅 스크립트 계약: stdin을 **먼저 전부 삼키고**, 조건 불충족 경로에도 드레인을 깔고, 실패해도 항상 `exit 0`,
  타임아웃을 짧게. 훅이 에이전트를 멈추게 하는 일은 없어야 한다.
- Codex는 `~/.codex/config.toml`의 `[hooks.state."<파일>:<이벤트>:<그룹>:<핸들러>"] trusted_hash`가 커맨드
  바이트의 sha256이다. **커맨드를 한 글자만 고쳐도 미신뢰**가 되어 사용자에게 확인을 요구한다. 기존
  `MARU_AGENT_MAP_HOOK_V2`를 확장할 때 trust 항목을 함께 갱신한다.
- 검증용 격리 실행에서도 `auth.json`은 **복사하지 않고 심볼릭으로 빌린다**(§2.5).

## 8. 한계 (숨기지 않는다)

1. **셸 편집은 `· 턴 중 변경`까지만** 간다. 어느 도구가 고쳤는지는 어떤 소스로도 알 수 없다(§2.3).
2. 턴 중 사용자가 저장한 파일도 `· 턴 중 변경`에 섞인다. 워크스페이스를 대화마다 하나 쓰면 실질적으로 사라진다.
3. 링 8개 = 최대 7턴 + 진행 중(§6.1 결정). 커밋 여부와 무관한 별개 상한이다.
4. maru가 떠 있지 않은 동안의 턴은 애초에 없다. 빈 목록은 오류가 아니다.
5. Codex 는 `PreToolUse.tool_input` 에 `command` 만 주므로 편집 경로를 **패치 텍스트에서 훑어야** 한다
   ([계약 §2.1](agent-hooks.md)). 셸(`exec`) 편집은 Claude 와 마찬가지로 잡히지 않는다(실측).
6. git 아닌 워크스페이스에서는 `✎` 목록만 나온다. FSEvents 워처로 메우는 길이 있으나(macOS 어댑터는
   `MaruAppHost.swift`에 이미 있다) 실제 수요가 생길 때까지 만들지 않는다.

## 9. 설계 검토 기록 — 적대적 10회

| 회차 | 공격 관점 | 발견한 결함 | 반영 |
| --- | --- | --- | --- |
| A0 | 이 설계가 기존 문서·구현과 겹치지 않나 | 초판은 스냅샷·트리 diff·뷰 연결을 새로 설계했는데 **§6.1이 이미 소유**하고 P5로 구현까지 끝나 있었다(조사 부족) | 이 문서를 §6.1의 후속 절로 재정렬, 중복 삭제 |
| A1 | "훅 payload에 diff가 있으니 훅만으로 된다" | 셸 편집이 통째로 빠진다. 실측 **3403:12** | §4 두 소스를 겹침, 권위는 §6.1 tree |
| A2 | "훅을 더 걸면 셸도 잡힌다" | 훅은 배달부다 — CLI에 없는 정보는 배달되지 않는다(실측) | §2.3에 원리로 기록 |
| A3 | "커밋을 안 하면 턴을 못 가른다" | 오해다. `write-tree`는 커밋이 아니다 — 커밋 0회로 실증 | §2.4 |
| A4 | 링의 수명 | 참조 없는 tree는 `git gc`가 수거 → 재시작 뒤 복원조차 불가 | §6 ref 고정 |
| A5 | 턴 경계를 화면 관측으로 | 한 번 놓치면 두 턴이 합쳐지고 복구 불가 | §3 훅 트리거, 관측은 폴백 |
| A6 | 배지 필터 기본값 | `✎`만 보이게 하면 사각지대를 **UI가 숨긴다** | §4.2 기본 전부 표시 |
| A7 | provider 기록으로 최종 상태 재생 | 되돌림·부분 적용·외부 편집에서 디스크와 어긋난 diff를 확신 있게 그린다 | §4.1 재생 금지 |
| A8 | git 없는 워크스페이스 | tree에만 의존하면 기능이 통째로 죽는다 | §5 `✎` 목록만으로도 서게 |
| A9 | Codex 훅 문자열 변경 | trust 해시가 깨져 매번 확인 프롬프트가 뜬다 | §7 trust 항목 동시 갱신 |
| A10 | 실측이 사용자 환경을 오염시키지 않나 | Claude는 실설정을 고쳤고(원복함), Codex는 실행 중 세션에 trust 프롬프트를 띄울 뻔했다 | §2.5 격리 홈 + auth 심볼릭을 절차로 못박음 |

**2차 검토(2026-08-20, 문서 확정 후 코드 대조).** 위 10회는 설계 논리를 공격했고, 아래 다섯은 **문서가 전제한
것이 코드에 실재하는지**를 공격했다. 둘은 설계를 바꿨다.

| 회차 | 공격 관점 | 발견한 결함 | 반영 |
| --- | --- | --- | --- |
| A11 | 훅 payload가 maru에 **어떻게 도달하나** | 초판은 "payload → mapping id → `Ring.push`"로 얼버무렸다. 현행 채널은 `cat >` **덮어쓰기**라 한 tick 안의 앞 이벤트가 사라지고(실측: 회수 파일에 Stop 하나만), 소비 경로는 **claude 전용 + 세션 id 문자열만** 인정한다 — Codex JSON은 아무도 안 읽는다 | §3.2 append-only 이벤트 로그 + 오프셋 tail 소비를 계약으로 승격, §2.2에 "배선 없음" 명시 |
| A12 | ref 이름의 `<workspace-id>`가 뭔가 | 정의가 없었다. 링은 **창당 하나**인데 ref 이름 공간은 저장소 공유라 두 창이 같은 저장소를 열면 서로의 ref를 덮는다. 게다가 현행 창 키는 `@intFromPtr`(포인터)라 **재시작하면 달라져** 고아 ref만 쌓인다 | §6 `<owner-key>` 요구사항(재시작 안정)과 포인터 키 금지를 명시, 선정은 AT5 |
| A13 | "훅이 경계를 **정확히** 준다" | 과장이다. 파일 경유 + tick pull이면 지연은 tick 해상도 그대로다. 훅의 이득은 **놓침 제거**이지 지연 제거가 아니다 | §3에 둘을 구분해 못박음 |
| A14 | Stop이 턴과 1:1인가 | 아니다. 실측 payload에 `stop_hook_active`·`background_tasks`가 있다 — 서브에이전트가 있으면 Stop이 재발화해 한 턴이 스냅샷 둘로 쪼개진다 | §3에 재진입 가드 사용을 계약으로 |
| A15 | provider 기록의 턴을 링의 **어느 항목**에 붙이나 | 규칙이 없었다. 시각으로 맞추면 tick 지연·재진입에서 어긋난다 | §3.1 턴 식별자(`prompt_id`/`turn_id`)를 링에 저장 |

## 10. 설계 누락 탐색 — 5회

| 회차 | 점검한 빈칸 | 결정 |
| --- | --- | --- |
| M1 | 새 UI가 필요한가 | 아니다. §6.1이 정한 에이전트 탭 항목에 배지·고지만 더한다(§5) |
| M2 | 턴 제목을 뭘로 | `Stop`의 `last_assistant_message`(양 provider 공통, 실측 확인) |
| M3 | 만졌지만 순변경 0 | `↩ 순변경 없음`으로 명시. 빼면 "왜 안 보이지"가 된다(§4.2) |
| M4 | 저장소 밖 파일 | provider 기록에는 절대경로가 그대로 온다(실측에서 스크래치패드 경로 관측). 워크스페이스 밖은 접어서 표시 |
| M5 | 세션(대화) 전체 축 | 턴들의 누적으로 파생한다. 별도 base를 두지 않는다 — 링 첫 항목이 그 역할 |

정책적으로 남긴 비목표: 되돌리기, 원격/SSH 세션, 다른 provider, 링 용량 확대, 목록 자체의 디스크 영속.
