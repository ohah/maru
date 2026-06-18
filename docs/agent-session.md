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
  `file-history-snapshot`/`queue-operation`/…. **대화** 엔트리는 `user`/`assistant`(나머지는 메타 — 무시).
- **완료 판정**: 마지막 *대화* 엔트리가 `assistant`이고 그 턴이 끝남(stop_reason=end_turn 류). 구현 시 정확한
  완료 필드를 fixture로 고정(공식 statusline 훅이 주는 `transcript_path`로 포맷 확인 가능).
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
- 상태/완료: 파일 끝에서 **tail**(끝 N KB만 seek해 읽고 마지막 대화/완료 엔트리 파싱). O(1).
- 마지막 답변: 같은 tail 버퍼에서 마지막 assistant/agent_message 추출. O(1).
- 세션 찾기: 디렉터리 `stat`/엔트리 나열(claude) 또는 최근 rollout 첫 줄 읽기(codex). O(최근 파일 수).
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

- `running → idle`(완료 마커) 전환 시 **macOS 알림**(제목=워크스페이스, 본문=마지막 답변 일부). **활성(현재 보고
  있는) 탭은 알림 안 함 — 비활성 탭/창에서 끝났을 때만 알림**(사용자 결정). Swift `UNUserNotificationCenter`
  (ABI 추가: `notify(title, body)`). 디바운스·중복 방지(세션별 마지막 완료 timestamp 기억). 켜기/끄기 config.

## PR 분해

- **PR0(이 문서)**: 설계 단일 출처(doc-first).
- **PR1**: `AgentTranscript` 인터페이스 + **claude 어댑터**(세션 찾기·상태·마지막답변) + 순수 파싱. 고정 JSONL
  fixture로 헤드리스 테스트(running/idle/완료·느린 API 갭·tail 큰 파일·cwd→세션). 사이드바 배선은 다음 PR.
- **PR2**: **codex 어댑터**(rollout·session_meta.cwd·task_complete). 같은 인터페이스, fixture 테스트.
- **PR3**: 사이드바 **상태 표시**(상태줄/아이콘 상태) + `pollAgentKinds`에 상태 polling·tail 배선. 슬롯 높이 조정.
- **PR4**: **완료 알림**(Swift 알림 API + ABI + config). ABI `.h`/`.zig`/`.swift` 동기.
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
