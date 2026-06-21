# 에이전트 세션 감지·상태 (JSONL 트랜스크립트)

> 단일 출처(design). 터미널에서 도는 claude/codex의 **진행 상태(running/idle)·마지막 답변·완료 알림**을 사이드바
> 카드에 표시한다. 에이전트는 지금처럼 **터미널 TUI**로 돌고, Maru는 그들이 디스크에 남기는 **세션 JSONL
> 트랜스크립트**를 *읽기만* 한다(ACP/백그라운드 프로세스 불필요 — UX 변화 없음). 사이드바 카드 자체는
> [tabs-splits-layout.md](tabs-splits-layout.md)의 "에이전트 아이콘"을 확장한다.

## Context

이미 구현된 것(merge됨): 포그라운드 프로세스 감지로 **어느 에이전트가 도는지**(claude/codex, node 래퍼 포함)
판정해 사이드바에 아이콘 표시(`pollAgentKinds`/`classifyAgent`/`Term.agent_kind`). 이 문서는 그 위에 **진행
상태·마지막 답변·알림**을 얹는다. 신호원은 에이전트의 세션 JSONL이다.

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
  (예: `/Users/x/Documents/workspace/maru` → `-Users-x-Documents-workspace-maru`). 그 디렉터리에서 **mtime 최신
  `.jsonl`** = 그 cwd의 활성 세션.
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

카드를 **최대 4줄**로: line0=이름, (git면) line1=`⎇ 브랜치`·line2=경로, **line3=상태줄**.
- **상태줄(진행중 표시 + 답변 미리보기 겸용)**: running이면 `● 진행중`(또는 `진행중…`), idle이면
  `✓ {마지막 답변 첫 줄}`(완료 답변 미리보기 — 카드 폭으로 말줄임). 별도 미리보기 줄을 안 둬도 상태줄이 둘을 겸한다.
- **아이콘 펄스**: running인 동안 에이전트 아이콘을 깜빡/밝기 변조(기존 `blink_visible` 위상 재사용), idle이면 정적
  full-color. → 아이콘(펄스) + 상태줄 **둘 다**(사용자 결정).
- 인코딩은 4줄 수용(`sidebar_line_base=32`, `line_index` 0~3 → 4줄). 구현: `lines: [3]`→`[4]`, 슬롯 높이
  3.8×→~4.6×(4줄+여백). 비-git·비-에이전트 탭은 줄이 적어 같은 슬롯에 블록 세로 중앙 정렬(빈 줄 없음).

## 알림 (결정)

- `running → idle`(완료 마커) 전환 시 **macOS 알림**(제목=워크스페이스, 본문=마지막 답변 일부 또는 "완료").
  **활성(현재 보고 있는) 탭은 알림 안 함 — 비활성 탭/창에서 끝났을 때만 알림**(사용자 결정). **구현은 기존 OSC
  9/777 알림 경로를 재사용**한다 — `pendingNotification`(Swift가 tick마다 poll)에 에이전트 완료 큐를 합류시켜
  Swift `UNUserNotificationCenter`로 띄운다. 설계 초안의 `notify(title, body)` ABI 신설 대신 이미 있는 drain ABI를
  쓰므로 **새 ABI/Swift 코드가 없다**(더 단순·검증된 경로). 디바운스는 **전환 edge 자체**(idle 유지 중엔 mtime-skip
  으로 재진입 안 해 한 번만 발화 — 별도 timestamp 기억 불필요). 켜기/끄기 config(`notifications.agent-complete`).

## PR 분해

- **PR0(이 문서)**: 설계 단일 출처(doc-first). ✅ 완료.
- **PR1**: session core 순수 파싱 + **claude 어댑터** ✅ **완료** — `src/session/agent_transcript.zig`
  (`session.zig` 파사드 노출). `parseClaudeTail`(tail 바이트→`AgentState{unknown,running,idle}`+답변 미리보기),
  `encodeClaudeProjectDir`(cwd→디렉터리)는 OS-중립 순수 함수(std만 의존, `tests/boundary/imports.zig` 가드).
  최신 세션 선택은 platform(L4)이 디렉터리 스트리밍 나열에서 인라인으로 한다(순수 헬퍼는 둘 다 안 맞아 미사용). 고정 JSONL fixture로 헤드리스 테스트(running=user/tool_use, idle=end_turn,
  느린 API 갭, end_turn 뒤 tool_result/메타 꼬리/isMeta user, 잘린 선두 줄 skip, UTF-8 경계 말줄임, cwd→디렉터리).
  파일 I/O(세션 찾기·tail read·디렉터리 나열)와 사이드바 배선은 PR3(platform).
- **PR2**: **codex 어댑터** ✅ **완료** — 같은 `src/session/agent_transcript.zig`에 `parseCodexTail`(완료=명시적
  `event_msg`/`task_complete`, 답변=`last_agent_message`, `token_count` 무시, 그 밖 turn 엔트리=running),
  `parseCodexCwd`(첫 줄 `session_meta.payload.cwd` 추출 — 날짜 분할이라 cwd로 디렉터리를 못 찾아 첫 줄로 매핑).
  claude와 `AgentState`/`Status`·tail 규약·헬퍼 공유. fixture 테스트(idle/token_count 무시/진행 신호/메타뿐/잘린
  선두 줄/cwd 추출).
- **PR3**: platform tail-read + 사이드바 **상태 표시** ✅ **완료** — `src/platform/macos/agent_session.zig`(L4:
  세션 파일 찾기·디렉터리 나열·tail read; claude=enc(cwd) 디렉터리 최신 .jsonl을 `readTailScan`(끝 256KB→8MB 지수
  확장)으로 마지막 대화 턴까지 읽음, codex=연·월·day를 최신순 평탄 순회(자정 넘김 대응)해 첫 줄 cwd 일치 최신
  rollout을 끝 64KB tail로 읽음; mtime 안 바뀌면 재파싱 skip). `pollAgentKinds`가 활성 Term의
  `agent_state`를 갱신(cwd=OSC7 `currentCwd()`, 세션 코어로 판정). 사이드바 카드 4번째 **상태줄**(running=`● 진행중`,
  idle=`✓ {답변}`) + 아이콘 **펄스**(running일 때 blink 위상으로 밝기 변조, `dimRgb`) + 슬롯 높이 3.8×→**4.6×**
  (`lines:[3]→[4]`). Metal `.m` 디코더는 이미 4줄 지원(`line_count*4`)이라 무변경. temp-dir 통합 테스트(claude/codex
  최신 선택·cwd 매칭·mtime skip)는 macOS. **실 세션 육안 검증은 수동**(아래 한계).
- **PR4**: **완료 알림** ✅ **완료** — `running → idle` 전환을 **비활성 탭/창**에서 관측하면 macOS 알림을 띄운다
  (제목=워크스페이스 이름, 본문=마지막 답변 또는 "완료"). **기존 OSC 9/777 알림 ABI를 재사용**(`pendingNotification`
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

1. **상태 표시**: 아이콘 펄스(running) **+** 4번째 상태줄, 둘 다.
2. **답변 미리보기**: 카드 상태줄에 idle 시 마지막 답변 첫 줄 1줄(말줄임).
3. **알림**: 비활성 탭에서 완료될 때만(활성 탭은 안 함).
