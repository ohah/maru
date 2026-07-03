# 에이전트 세션 감지·상태 (JSONL 트랜스크립트)

> 단일 출처(design). 터미널에서 도는 claude/codex의 **진행 상태(running/idle)·마지막 답변·완료 알림**을 사이드바
> 카드에 표시한다. 에이전트는 지금처럼 **터미널 TUI**로 돌고, Maru는 그들이 디스크에 남기는 **세션 JSONL
> 트랜스크립트**를 *읽기만* 한다(ACP/백그라운드 프로세스 불필요 — UX 변화 없음). 사이드바 카드 자체는
> [tabs-splits-layout.md](tabs-splits-layout.md)의 "에이전트 아이콘"을 확장한다.

## Context

이미 구현된 것(merge됨): 포그라운드 프로세스 감지로 **어느 에이전트가 도는지**(claude/codex, node 래퍼 포함)
판정해 사이드바에 아이콘 표시(`pollAgentKinds`/`classifyAgent`/`Term.agent_kind`). 이 문서는 그 위에 **진행
상태·마지막 답변·알림**을 얹는다. 신호원은 에이전트의 세션 JSONL이다.

### 세션 파일 찾기 = **훅 매핑**(팬별 정확)

라이브 상태 poll이 "이 팬의 세션 트랜스크립트가 어느 파일인가"를 아는 방법은 **에이전트 공식 훅**이다
(`src/platform/macos/agent_hooks.zig`):

1. maru가 각 팬 셸에 `MARU_PANE_ID=<surface.id>`를 주입한다(`pty/macos.zig` `appendParentEnv`, `MARU_BIN`과 동형).
2. maru가 시작 시 claude(`~/.claude/settings.json`)·codex(`~/.codex/hooks.json`)의 `hooks`에 **SessionStart·
   UserPromptSubmit·Stop** 훅을 등록한다(원자적·idempotent·백업; 파싱 실패 시 무접촉). 훅 command는 인라인 셸
   한 줄 — stdin(JSON payload = `transcript_path` 포함)을 `<config>/maru/agent-sessions/$MARU_PANE_ID`로 덤프한다
   (jq 등 의존성 0). **매 턴 이벤트(UserPromptSubmit/Stop)** 덕에 등록 이전부터 돌던 세션도 다음 활동에 매핑된다.
3. `pollAgentState`가 `term.surface.id`로 그 파일을 읽어(`readMapping`) `transcript_path`를 뽑아 `poll`이 **그 파일을
   직접** tail-read한다. 매핑이 없으면 state=unknown(**cwd 추측·mtime 폴백 없음** — 훅-only 결정).

**왜 훅인가**: cwd+mtime 추측은 같은 폴더 다중 세션에서 섞이고, `CLAUDE_CODE_SESSION_ID` env는 상속·`CHILD_SESSION`
상시라 취약하며 codex는 세션 id를 env로 아예 안 낸다(전부 실측 확인). Anthropic·OpenAI 문서 모두 "트랜스크립트
포맷은 internal, 버전마다 바뀐다"고 경고 → 직접 추측은 근본적으로 취약. 훅은 에이전트가 `transcript_path`를 **공식
채널로** 알려주고 maru가 자기 키(`MARU_PANE_ID`)로 정확히 잇는다(읽기→쓰기). 토큰·오염 0. cmux·Claude Squad가
쓰는 "런치 제어/워크트리 격리"의 passive-터미널 판본. 자동등록이 실패하거나 훅이 stale하면 커맨드 팔레트 **Re-register Agent
Session Hooks**로 수동 복구(`reregister_agent_hooks` 액션 → `agent_hooks.reregister` — **force 재등록, 매핑은 안 지움**;
시작 시 `agent_hooks.setup`은 매핑 dir까지 정리하므로 복구엔 안 쓴다). 전역 config에서 떼려면 **Unregister**(`agent_hooks.unregister`).

**restore도 훅 경로**: workspace restore가 종료 시점에 resume 대상 **session id**를 캡처하는 것도 이제 **훅 매핑**을 쓴다
(`captureAgentSessionId` → `readMapping(surface.id)` → `sessionIdFromTranscript` — claude=파일명 uuid, codex=첫 줄
`session_meta.payload.id`). cwd+mtime 추측이 없어 **같은 폴더 다중 세션도 팬별 정확히 resume**한다. 옛 cwd+mtime/날짜-스캔
탐색(`resolveClaude`/`resolveCodex`/`resolveSessionId`)은 훅으로 대체돼 **제거**됐다([workspace-restore.md](workspace-restore.md) "에이전트 세션 자동 resume").

**안전·한계(코드리뷰 반영)**:
- **config 편집 안전**: 첫 등록만 재정렬(백업 `<config>.maru-backup`), 이후 마커로 skip해 무접촉. **읽기 오류**(EACCES·>4MB)와 파일 없음을 구분해 — 읽을 수 없으면 손대지 않는다(minimal로 덮어쓰지 않음). 파싱 실패·최상위 비-object도 무접촉.
- **복구/제거**: 자동등록 실패·**경로가 바뀐 stale 훅**은 팔릿 **Re-register**(force — 기존 maru 훅 제거 후 재추가, **매핑은 안 지움**)로 고친다. 전역 config에서 떼려면 **Unregister**(maru 훅만 제거). 훅은 전역 `~/.claude`·`~/.codex`에 남아 maru 밖에서도 발화하나, `MARU_PANE_ID` 없으면 stdin만 소비(`/dev/null`)해 무해.
- **경로 방어**: `transcript_path`는 매핑 파일(팬 셸 아무 프로세스나 쓸 수 있음)에서 오므로 **절대경로+`.jsonl`+`..` 없음**만 허용(traversal 방지, 옛 `isBasenameSafe` 대체).
- **중첩 에이전트 한계**: 한 팬 안에서 claude 안 claude(중첩)를 띄우면 자식이 `MARU_PANE_ID`를 상속해 그 팬 매핑을 자기 트랜스크립트로 덮는다. 바깥 에이전트의 다음 활동(UserPromptSubmit/Stop)에 매핑이 다시 올바르게 쓰이므로 **일시적**이지만, 중첩이 도는 동안엔 카드가 중첩 세션 상태를 보일 수 있다(드문 엣지).
- **훅-only 창**: 팬 spawn 직후 첫 훅 발화 전, 또는 훅 미발화 세션은 state=unknown(cwd 추측 폴백 없음 — 훅-only 결정). 매 턴 이벤트로 곧 채워진다.
- **매핑된 트랜스크립트 부재 = 세션 gone(stale 매핑 자가정리)**: `transcript_path`는 **세션 내내 고정**이다(claude 확인: auto-compaction·`/compact`·`--continue`/`--resume` 모두 같은 파일에 append; 새 파일은 **새 세션·`/clear`**만). 따라서 매핑이 가리키는 파일이 **없어졌다(`FileNotFound`)**는 건 회전이 아니라 **그 세션이 사라진 것**(수동 삭제·30일 retention·`/clear`로 옛 UUID 유기 등)이다. `poll`은 이 경우를 일반 unknown(불완전 tail — 일시적, 직전 상태 보존)과 **구분**해 `missing`으로 신호하고, `pollAgentState`는 직전이 running/idle이었으면 그 팬의 **stale 매핑 파일을 파기**(`removeMapping`)하고 상태를 unknown으로 **리셋**한다 — 안 그러면 unknown의 "직전 상태 보존" 계약 때문에 삭제된 running 세션이 **스피너가 영영 안 풀린다**. 새 세션은 SessionStart 훅이 새 UUID로 매핑을 다시 쓰므로 자가회복. running→unknown 리셋이라 **완료 알림은 안 뜬다**(사라진 세션은 완료가 아님).
  - **SessionEnd 훅은 안 쓴다(결정)**: 세션 종료 시 매핑을 훅으로 지우는 대안도 있으나, 깨끗한 종료는 **포그라운드=셸 감지(kind=none)** 로 이미 카드가 안 뜨고, 시작 시 `clearMappings`가 옛 매핑을 비우며, 위 `missing` 자가정리가 파일 삭제까지 덮는다. per-event 삭제 command를 위해 `buildCommand`를 event별로 나눠 사용자 `settings.json` 접촉면을 넓히는 비용 대비 이득이 없어 **maru-side 자가정리로 일원화**한다.

## 왜 JSONL인가 (방식 결정)

| 방식 | running/idle | 마지막 답변 | 알림 | 백그라운드 | UX |
|---|---|---|---|---|---|
| 터미널 모니터링(스피너) | ✅ 실시간 | ❌ 렌더 바이트라 텍스트 불가 | ✅ | 불필요 | 무변화 |
| **JSONL 트랜스크립트** | ✅ 마지막-엔트리 의미 | ✅ | ✅ | 불필요 | 무변화 |
| ACP | ✅ 구조화 | ✅ | ✅ | **필요(에이전트 직접 spawn)** | **큼(TUI→패널)** |

**결정:** JSONL을 주 신호로 한다 — 터미널 워크플로(에이전트를 터미널에서 돌림)를 유지한 채 상태·답변·알림을 다
얻고, 느린 API에도 견디며(아래), 포맷이 공식 문서화/오픈소스라 라이선스가 안전하기 때문. (선택) 터미널 스피너를
실시간 보조로 둘 수 있다. ACP는 에이전트를 maru가 백그라운드로 직접 모는 *별개 surface*라 본 목표와 불일치 — 제외.

## 데이터 소스 (실 세션 파일로 검증)

### claude
- 경로: `~/.claude/projects/<cwd-인코딩>/<session-uuid>.jsonl`. **cwd 인코딩** = 절대경로의 `/`→`-`
  (예: `/Users/x/Documents/workspace/maru` → `-Users-x-Documents-workspace-maru`). 라이브 poll·restore **둘 다** 이 경로를
  **훅 매핑**(위 Context)이 정확히 준다 — cwd 인코딩은 훅 payload의 경로 안에 이미 들어 있어 maru가 인코딩할 일이 없다.
- 엔트리(줄): `{type, message?, timestamp, ...}`. `type` ∈ `user`/`assistant`/`system`/`attachment`/
  `file-history-snapshot`/`queue-operation`/`mode`/`permission-mode`/`pr-link`/…. **대화** 엔트리는
  `user`/`assistant`(나머지는 메타 — 무시). 단 `isMeta:true`인 `user`(local-command caveat·hook 주입)는
  대화가 아니라 메타다 — 완료된 턴 뒤에 붙어도 false running으로 뒤집히면 안 되므로 제외한다(실측 함정).
- **완료 판정(실측 정밀화)**: 마지막 *대화* 엔트리가 `assistant`이고 `message.stop_reason`가 **턴-종료 사유**
  (`end_turn`/`stop_sequence`/`max_tokens`)면 idle. `tool_use`(도구 결과 대기)·`null`·모르는 값은 **running**
  으로 보수 판정 — 모르는 값을 idle로 보면 느린 API 중 false idle이 생긴다(allowlist 근거: Anthropic Messages
  API stop_reason). 실 세션 분포 검증: 한 세션에서 `tool_use` 2860건 vs `end_turn` 111건(도구 호출마다 tool_use).
- **메타 꼬리 주의(실측 함정)**: 파일의 *물리적 마지막 줄*은 대화가 아니라 메타(`mode`/`permission-mode`/
  `pr-link`)인 경우가 잦다. 그래서 "마지막 줄"이 아니라 "마지막 *대화* 엔트리"를 본다 — tail에서 메타 꼬리를
  건너뛴다. 정확한 필드는 `transcript_path`(statusline 훅)로 포맷 확인 후 고정 JSONL fixture로 못박았다.
- 검증: user 엔트리가 **제출 즉시** 기록되고 assistant는 응답 시 기록(실측 user 02:18:09 → assistant 02:18:53,
  **44초 갭**). 그 44초 동안 마지막 대화 엔트리 = user → running.

### codex
- 경로: `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl`. **날짜 분할**이라 cwd로 디렉터리를
  못 찾는다 → 각 rollout 첫 줄 `session_meta.payload.cwd`로 매핑(최근 파일들을 stat해 cwd 일치 + 최신).
- 엔트리(줄): `{type, payload, timestamp}`. `type` ∈ `response_item`(payload.type: `message`/`reasoning`/
  `function_call`/`function_call_output`) / `event_msg`(payload.type: `agent_message`/`token_count`/
  **`task_complete`**).
- **완료 판정(명시적)**: `event_msg` + `payload.type == "task_complete"`. claude보다 깔끔(추론 불필요).
- **마지막 답변**: `event_msg`/`agent_message`(또는 `response_item`/`message`).
- 검증: function_call_output 09:55:14 → reasoning 09:55:25(**11초 갭**, API 대기) → agent_message → task_complete.
  그 11초 동안 마지막 ≠ task_complete → running.

## 상태 모델 (느린 API 견딤)

`agent_state(term) ∈ {none, running, idle}`:
- **none** = 그 Term 포그라운드가 에이전트가 아님(`agent_kind == .none`).
- **running** = 에이전트 포그라운드 **AND** 세션의 마지막 *대화* 엔트리가 **미완료**(claude: user거나 end_turn 아닌
  assistant / codex: 마지막 `event_msg`가 `task_complete` 아님).
- **idle** = 에이전트 포그라운드 **AND** 완료 마커가 마지막(claude end_turn / codex task_complete).

핵심: **mtime을 쓰지 않는다**(느린 API 중엔 파일이 안 써져서 false idle). 대신 **마지막 대화 엔트리의 의미**
(턴 완료 여부)를 본다 — API가 44초든 5분이든 "턴 미완료"는 구조적 사실이라 false idle이 없다. **포그라운드 체크**를
AND로 묶어 crash/Ctrl-C(마지막이 user로 남았지만 프로세스는 죽음) false-running을 막는다.

## 성능 (큰 파일 안전)

긴 대화는 JSONL이 수백 MB가 될 수 있다. **절대 전체를 안 읽는다**:
- 상태/완료(codex): 파일 끝에서 **tail**(끝 64KB만 seek). codex는 마지막 엔트리가 `task_complete`(명시적 완료)라 끝부분만으로 충분. O(1).
- 상태/완료(claude): claude는 마지막 `assistant` 턴 뒤에 대량 비-대화 엔트리(attachment·file-history-snapshot 등)를 append해 마지막 대화 턴이 끝에서 수백 KB까지 밀릴 수 있다(실측 ~800KB). 그래서 끝에서 **256KB부터 지수 확장(→2×→…→8MB 상한)하며 마지막 대화 엔트리를 찾는 `readTailScan`**을 쓴다(`agent_session.zig`). 활성 세션의 흔한 경우는 첫 청크로 끝나고, 멀 때만 확장. 8MB까지 못 찾으면 unknown(사실상 죽은 세션). 파서가 잘린 선두 줄을 skip하므로 청크 경계 처리가 불필요하다.
- 마지막 답변: 같은 tail 버퍼에서 마지막 assistant/agent_message 추출. O(1).
- 세션 찾기: 디렉터리 `stat`/엔트리 나열(claude=enc(cwd) 디렉터리 최신 `.jsonl`) 또는 최근 rollout 첫 줄 읽기(codex). codex는 날짜 분할(`YYYY/MM/DD`)이라 **최신 날짜 하나만 보면 자정·월말·연말을 넘긴 세션을 놓치므로**, 연(top)·월(top)·day(존재 기준 최대 14개)를 **최신순으로 평탄 순회**하며 cwd 일치 최신 rollout을 찾는다(첫 매칭=전역 최신). O(최근 day·파일 수).
- 한 *줄*이 거대한 경우(초대형 메시지): tail 상한 내에서 잘라 미리보기(truncate). 폴링은 사이드바 빌드 주기에
  맞춰 ≈0.5~1s, mtime이 안 바뀌면 재파싱 skip.

## 아키텍처 / 레이어 (이식성)

[portability](layering-and-portability.md) 4층 위상에 맞춘다:
- **session core(OS-중립)**: `AgentTranscript` 인터페이스 — `state()`, `lastAnswer()`, `pollForCompletion()`.
  JSONL 줄 파싱·상태 판정은 순수 함수(헤드리스 테스트). 에이전트별 스키마 어댑터(claude/codex)도 여기(파싱은
  OS 무관).
- **platform adapter(macos)**: 세션 파일 *위치*(`~/.claude/projects`, `~/.codex/sessions`)·디렉터리 나열·tail
  read만 macOS 경로. (Linux/Win 포팅 시 경로만 교체.)
- **chrome(렌더)**: 상태를 사이드바 카드 줄/아이콘으로 lower(기존 `buildSidebarTitleFrame` 확장).
- **platform(Swift)**: 완료 알림(macOS 알림 API)만 네이티브.

기존 `Term.agent_kind`(어느 에이전트) 옆에 `Term.agent_state`(running/idle)와 캐시(세션 경로·마지막 mtime·마지막
답변)를 둔다. `pollAgentKinds`가 상태도 함께 polling(throttle 공유).

## 사이드바 통합 (결정)

카드를 **최대 4줄**로: line0=이름, (git면) line1=`├ 브랜치`·line2=경로, **line3=상태줄**.
- **상태줄(진행중 표시 + 답변 미리보기 겸용)**: running이면 **`▁▅▇▃ 진행중`**(codex식 이퀄라이저 스피너), idle이면
  `✓ {마지막 답변 첫 줄}`(완료 답변 미리보기 — 카드 폭으로 말줄임). 별도 미리보기 줄을 안 둬도 상태줄이 둘을 겸한다.
- **running 스피너 + 솔리드 아이콘**(사용자 피드백, 펄스 폐기): 옛 "아이콘 밝기 펄스"(`blink_visible` 500ms 변조)는 작은
  아이콘에선 작업 중인지 알기 어려웠다. 이제 **아이콘은 항상 솔리드 브랜드색**(큰 별/다이아 — 종류·presence를 또렷이)이고,
  **작업 중 애니메이션은 상태줄 스피너**가 담당한다 — `● 진행중` 대신 **codex "working" 파형(이퀄라이저)의 축소판인 4칸
  바운싱 바**(블록 문자 `▁▂▃▄▅▆▇█` U+2581~2588, `renderer/block_glyph.zig` 절차 합성)를 쓴다. 각 바 높이는 삼각 파형
  (`spinner_wave`, 주기 14)을 서로 다른 위상(`spinner_bar_phase=[0,4,8,12]`)으로 읽어 파도처럼 흐른다.
  `agent_spin_frame`(running일 때 약 133ms마다 +1 mod 14, 사이드바 재투영)으로 진행. **스피너는 브랜드색**
  (코랄/청록 — 색칠 루프가 아이콘과 같은 패턴으로 칠함)이라 "진행중"에 색 표현이 생긴다(사용자 요청). idle은 스피너 없이 `✓`.
  (옛 브라유 회전 dot `⠋⠙⠹⠸⠼⠴⠦⠧`은 "작은 점 왔다갔다"라는 피드백으로 codex 스피너식 파형으로 교체 — codex의 인라인
  글리프 스피너 자체도 사실 같은 브라유[10프레임]이고, 눈에 띄는 애니메이션은 이 블록 파형이라 그쪽을 좁은 카드 폭에 맞춰 축소.)
  - **트레이드오프(폭, 수용됨)**: running 상태줄이 1칸(옛 브라유)→**4칸**으로 넓어졌다. 아주 좁은 사이드바(~12–14칸)에서는
    `▁▅▇▃ 진행중`이 카드 폭을 넘어 **끝에서 말줄임**되어 막대+`…`만 남고 "진행중" 라벨이 잘릴 수 있다(옛 1칸 스피너는 그 폭에서도
    라벨이 붙었다). 기본 사이드바 폭에선 문제없고 사이드바를 매우 좁게 드래그한 경우에만 해당하는 엣지라 **4칸을 그대로 수용**한다
    (사용자 결정 — 좁은 폭 우선순위보다 codex식 파형 표현을 택함). 필요하면 후속으로 폭 적응(좁으면 바 수 축소·라벨 우선)을 검토.
  - **범위 = 워크스페이스(탭) 단위**(사용자 요청): 상태줄·gutter 아이콘·브랜드색은 활성 Term만이 아니라 **탭 안 어느 pane/Term이든**
    running이면 표시한다(`tabHasRunningAgent`/`tabAgentKind` — running Term 우선, 없으면 활성 Term 폴백). 에이전트를 백그라운드
    pane/split·비활성 가로탭에서 돌려도 카드에 파형이 뜬다(옛 "활성 Term만" 한계 해소 — `pollAgentKinds`가 모든 pane×Term을 갱신).
    running Term의 kind로 아이콘/색을 고르므로 활성 Term이 셸(none)이어도 백그라운드 claude/codex가 카드에 종류색으로 보인다.
    - **의도된 기준 분리(수용됨, 사용자 결정 A)**: 같은 카드에서 **이름·브랜치(저장소)·경로는 활성 Term** 기준, **스피너·아이콘·색은
      워크스페이스 전체**(아무 pane/Term) 기준으로 **갈린다**. 근거: 사이드바는 **비활성 워크스페이스의 상태까지 한눈에** 보는 유일한
      곳이라(탭바는 활성 워크스페이스만) 백그라운드 Term 에이전트도 "이 워크스페이스가 바쁨"으로 떠야 개요가 산다. **활성 Term과
      running Term이 다른**(다른 repo이거나 같은 repo의 다른 하위 디렉터리·브랜치) 경우에만 repo/경로(활성)와 스피너(다른 Term)가
      시각적으로 어긋난다 — 개요 가치를 위해 수용.
      (대안 B[스피너도 활성 Term으로 통일]는 카드 내부는 일관되나 백그라운드 에이전트가 사이드바 목록에서 사라져 개요가 약해져 기각.)
      추가 수용 사항(code-review high): ① 상태줄은 어느 Term이든 running이면 파형이 우선이라, 활성 Term이 방금 끝낸 답변 미리보기
      (`✓ {답변}`)가 **백그라운드 에이전트가 도는 동안 가려진다**(모든 running이 끝나면 다시 보임). ② 한 pane의 가로 Term 탭이
      claude+codex **혼재**면 탭바 플래그(●) 색이 pane 대표 kind 하나로 통일된다(다른 kind 탭은 색이 어긋남 — 드묾).
  - **상단 탭바 running 표시 = 1칸 정적 플래그 ●**(사용자 요청 "여기도"): 사이드바 카드는 전용 상태줄이 있어 애니메이션 파형을
    쓰지만, **탭 바(pane 라벨·Term 탭)는 등폭이라 폭이 귀하다** — 4칸 파형을 붙이면 식별용 이름이 잘린다(code-review max #1).
    그래서 **tmux/screen 창-목록 활동 플래그(1글자)·zellij/iTerm2 탭 활동 점 관례**를 따라, running pane 라벨과 running Term 탭 앞에
    `● `(U+25CF + 공백, `flagPrefixedLabel`) **정적 1칸 플래그**를 붙이고 ● 셀을 브랜드색으로 칠한다(`recolorAgentFlagCells`, pane
    대표 kind). **정적이라 매 프레임 재투영이 필요 없고**(상태 변화 시에만 `pollAgentKinds`가 dirty), 종류색(코랄/청록)으로 종류도
    드러난다. 편집(rename) 중인 라벨/탭엔 붙이지 않는다. (혼재 claude+codex pane의 플래그 색은 pane 대표 kind로 통일 — 드문 트레이드오프.)
  - **재렌더 게이트 확장**(`agentDisplayVisible`): 정적 플래그·워크스페이스 단위 카드가 생기며, 상태/종류 변화 시 `metal_dirty`를
    올리는 게이트를 "활성 Term만"에서 **탭 단위**(보이는 사이드바 카드 or 활성 탭의 탭 바)로 넓혔다 — 백그라운드 Term이 running으로
    바뀌어도 그 탭 카드/탭바 플래그가 제때 갱신된다. 사이드바 파형 애니메이션(`anyAgentRunning`, 130ms)은 카드 전용이라 그대로.
- 인코딩은 4줄 수용(`sidebar_line_base=32`, `line_index` 0~3 → 4줄). 구현: `lines: [3]`→`[4]`, 슬롯 높이
  3.8×→~4.6×(4줄+여백). 비-git·비-에이전트 탭은 줄이 적어 같은 슬롯에 블록 세로 중앙 정렬(빈 줄 없음).

## 알림 (결정)

- `running → idle`(완료 마커) 전환 시 **macOS 알림**. **제목 = `{심볼} {Claude|Codex} · {끝난 Term 라벨}`**
  (심볼은 사이드바 에이전트 아이콘과 같은 ✶ claude/◆ codex — macOS 알림 왼쪽 큰 아이콘은 앱 아이콘 고정이라 제목
  prefix로 종류를 구분; 라벨은 **끝난 그 Term**의 termLabel이라 background split/가로탭 완료도 그 세션을 정확히 가리킨다).
  **본문 = 마지막 답변 미리보기(여러 줄을 한 줄로 평탄화 — `copyPreviewFlattened`, 알림 배너가 답변을 더 많이 보임;
  사이드바 상태줄은 같은 문자열을 카드 폭으로 다시 말줄임)** 또는 답변이 없으면 "완료". 종류 없음이면 워크스페이스 라벨 폴백.
  **활성(현재 보고 있는) 탭은 알림 안 함 — 비활성 탭/창에서 끝났을 때만 알림**(사용자 결정). **구현은 기존 OSC
  9/777 알림 경로를 재사용**한다 — `pendingNotification`(Swift가 tick마다 poll)에 에이전트 완료 큐를 합류시켜
  Swift `UNUserNotificationCenter`로 띄운다. 설계 초안의 `notify(title, body)` ABI 신설 대신 이미 있는 drain ABI를
  쓰므로 **새 ABI/Swift 코드가 없다**(더 단순·검증된 경로). 디바운스는 **전환 edge 자체**(idle 유지 중엔 mtime-skip
  으로 재진입 안 해 한 번만 발화 — 별도 timestamp 기억 불필요). 켜기/끄기 config(`notifications.agent-complete`).

## PR 분해

- **PR0(이 문서)**: 설계 단일 출처(doc-first). ✅ 완료.
- **PR1**: session core 순수 파싱 + **claude 어댑터** ✅ **완료** — `src/session/agent_transcript.zig`
  (`session.zig` 파사드 노출). `parseClaudeTail`(tail 바이트→`AgentState{unknown,running,idle}`+답변 미리보기),
  는 OS-중립 순수 함수(std만 의존, `tests/boundary/imports.zig` 가드). **⚠️ 세션 파일 위치는 이후 훅 매핑(위 Context)으로
  대체돼, cwd→디렉터리 인코딩(`encodeClaudeProjectDir`)·mtime 최신 인라인 선택은 제거됐다** — 이 항목은 히스토리 보존용. 고정 JSONL fixture로 헤드리스 테스트(running=user/tool_use, idle=end_turn,
  느린 API 갭, end_turn 뒤 tool_result/메타 꼬리/isMeta user, 잘린 선두 줄 skip, UTF-8 경계 말줄임, cwd→디렉터리).
  파일 I/O(세션 찾기·tail read·디렉터리 나열)와 사이드바 배선은 PR3(platform).
- **PR2**: **codex 어댑터** ✅ **완료** — 같은 `src/session/agent_transcript.zig`에 `parseCodexTail`(완료=명시적
  `event_msg`/`task_complete`, 답변=`last_agent_message`, `token_count` 무시, 그 밖 turn 엔트리=running),
  `parseCodexId`(첫 줄 `session_meta.payload.id` — resume 대상). **⚠️ cwd로 세션을 찾던 `parseCodexCwd`/날짜-스캔은 훅
  매핑으로 대체돼 제거됨**(위 Context). claude와 `AgentState`/`Status`·tail 규약·헬퍼 공유. fixture 테스트(idle/token_count 무시/진행 신호/메타뿐/잘린 선두 줄).
- **PR3**: platform tail-read + 사이드바 **상태 표시** ✅ **완료** — `src/platform/macos/agent_session.zig`(L4:
  세션 파일 찾기·디렉터리 나열·tail read; claude=enc(cwd) 디렉터리 최신 .jsonl을 `readTailScan`(끝 256KB→8MB 지수
  확장)으로 마지막 대화 턴까지 읽음, codex=연·월·day를 최신순 평탄 순회(자정 넘김 대응)해 첫 줄 cwd 일치 최신
  rollout을 끝 64KB tail로 읽음; mtime 안 바뀌면 재파싱 skip). `pollAgentKinds`가 활성 Term의
  `agent_state`를 갱신(cwd=OSC7 `currentCwd()`, 세션 코어로 판정). 사이드바 카드 4번째 **상태줄**(running=`▁▅▇▃ 진행중`
  이퀄라이저 스피너[브랜드색], idle=`✓ {답변}`) + 아이콘은 **솔리드 브랜드색**(옛 밝기 펄스 폐기 — 위 "running 스피너" 절) + 슬롯 높이 3.8×→**4.6×**
  (`lines:[3]→[4]`). Metal `.m` 디코더는 이미 4줄 지원(`line_count*4`)이라 무변경. temp-dir 통합 테스트(claude/codex
  최신 선택·cwd 매칭·mtime skip)는 macOS. **실 세션 육안 검증은 수동**(아래 한계).
- **PR4**: **완료 알림** ✅ **완료** — `running → idle` 전환을 **비활성 탭/창**에서 관측하면 macOS 알림을 띄운다
  (제목=`{✶|◆} {Claude|Codex} · {끝난 Term 라벨}`, 본문=마지막 답변 평탄화 미리보기 또는 "완료" — 위 "알림" 절이
  단일 출처). **기존 OSC 9/777 알림 ABI를 재사용**(`pendingNotification`
  /`maru_macos_app_session_pending_notification` v52 + Swift `UNUserNotificationCenter`) — **새 ABI/Swift 불필요**
  (설계 초안의 `notify(title,body)` 추가 대신 이미 있는 drain 경로에 합류). `pollAgentState`가 전환 edge에서
  `enqueueAgentCompletion`(owned 큐, 상한 가드), `pendingNotification`이 OSC보다 먼저 드레인. 디바운스=전환 edge
  자체(idle 유지 중 mtime-skip으로 재진입 없음). "보고 있는 탭"=포커스 창(`window_focused`, focusChanged)의 활성
  탭은 제외. config `notifications.agent-complete`(기본 true). 헤드리스 테스트(enqueue→OSC보다 먼저 드레인·답변
  폴백·config 파싱).
- **PR5(선택)**: **마지막 답변 미리보기**(길이/위치 결정 후).

## 검증

- **헤드리스 단위(Linux CI 포함)**: 고정 JSONL fixture로 — 상태 판정(running/idle/done), **느린 API 갭**
  (마지막=user/미완료 → running), tail 큰 파일(끝 N KB만), cwd→세션 매핑(claude 인코딩·codex session_meta),
  마지막 답변 추출, 완료 감지. 파싱은 순수 함수라 OS 무관.
- **수동(macOS)**: 실 claude/codex로 상태 전환·알림 육안.

## 규칙 / 베이스

- **doc-first**: PR0이 이 문서(단일 출처).
- **document-basis-and-decision**: claude 포맷은 공식 문서(`code.claude.com/docs`, statusline 훅의 `transcript_path`),
  codex는 오픈소스(`openai/codex`, Apache-2.0)를 베이스로 인용. mtime 대신 마지막-엔트리-의미를 택한 근거(느린 API)
  를 코드·docs에 기록.
- **clean-room**: 데이터 포맷(JSONL)은 저작권 대상이 아니며, Maru가 *자체* 파서로 읽는다. 참고용 OSS 파서
  (`simonw/claude-code-transcripts` 등)는 *포맷 이해*용으로만 보고 코드는 복사하지 않는다.
- **헛방어 금지**: 스키마 필드 누락/버전차는 한 곳(파서)에서만 처리(없으면 none으로 폴백), 산발적 방어 없음.
- **no-external-ref**: 외부 터미널(cmux/Warp) 형태만 참고, 산출물·용어는 Maru 독립.

## 결정된 UX (사용자 확정)

1. **상태 표시**: 솔리드 브랜드색 아이콘(종류·presence) **+** 4번째 상태줄의 running 이퀄라이저 스피너(`▁▅▇▃ 진행중`, codex식 파형, 브랜드색). (옛 "아이콘 밝기 펄스"는 작아서 안 보인다는 사용자 피드백으로 스피너로 대체.)
2. **답변 미리보기**: 카드 상태줄에 idle 시 마지막 답변 첫 줄 1줄(말줄임).
3. **알림**: 비활성 탭에서 완료될 때만(활성 탭은 안 함).
