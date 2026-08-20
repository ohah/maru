# 에이전트 훅 통합 — 단계 계획

[에이전트 훅 통합](../agent-hooks.md)이 정한 층을 **무엇을 어느 순서로 만들고 각 단계를 무엇으로 검증하는가**만
정한다. 계약의 단일 출처는 그 문서다. 이 층의 소비자 계획은 둘로 갈린다 —
턴 변경분은 [단계 계획](agent-turn-changes.md), 상태·알림은 이 문서의 AH4~AH5가 소유한다.

## 0. 전제

- 스냅샷·링·타임라인 UI는 [scm-dock P5](scm-dock.md)(2026-08-18 완료)로 이미 돈다.
- 상태·알림의 현행 계약은 [agent-session.md](../agent-session.md)이고, 그 문서는 2026-08-20 개정으로
  **관측 모드 전용**이 됐다.
- 훅 payload는 양 provider 실측으로 확인했다(계약 §2). Codex `PostToolUse`만 미검증이다.

## 1. 단계

### AH1 — 전달 채널 ✅ 코어 완료

**구현됨(순수 층)**: [`session/agent_hook_command.zig`](../../src/session/agent_hook_command.zig)(인라인 커맨드
빌더·표식·legacy 식별)와 [`session/agent_hook_event.zig`](../../src/session/agent_hook_event.zig)(ndjson 파서·
tail 커서). 단위 40개 + 실제 셸 게이트 `zig build check-agent-hook-command`(계약 8개 — 로그 파일 `0600`을
넉넉한 umask에서 확인하는 것을 AH2a에서 더했다). **로그를 읽는 쪽은 아직 없다**(회전·정리는 AH3).


- 훅 스크립트: stdin 전량 소비 → pane 식별자 확인 → `<cache>/maru/agent-turn-events/<surface_id>.ndjson`에
  **한 줄 append** → `exit 0`. **백그라운드 서브셸로 분리하지 않는다** — 실측에서 오히려 2 ms 느렸다
  (계약 §3). 비용의 대부분은 `sh` spawn이라 스크립트로 줄일 수 있는 것이 없다.
- 훅 항목에 **`timeout`을 명시**한다(계약 §4.1). 값과 근거는 `agent_hook_command.timeout_seconds` 가 소유한다.
- **커맨드는 인라인**이다(계약 §4.1) — 스크립트 파일을 두지 않는다. 우리 항목 식별은 커맨드 안의 표식.
- 로그는 **소비 즉시 회전·삭제**한다(계약 §4.2). 파일 `0600`, 디렉터리 `0700`.
- 각 줄에 **provider 표식**을 우리가 붙인다(계약 §4.1) — payload에는 없다.
- 라인 상한(초과 절단)·파일 회전·오래된 파일 정리를 함께 넣는다. `PostToolUse`의 `tool_response.stdout`이
  수십 KB로 들어오므로 상한이 없으면 세션당 수백 MB가 된다.
- maru 쪽 소비기: tick마다 오프셋 전진 tail 파싱, tick당 처리 상한, **손상 라인은 조용히 버림**.
- 검증: 부분 라인·회전 경계·오프셋 전진·상한 절단·손상 라인 무시(순수 모듈 단위), 동시 append 인터리브.

### AH2 — 설치와 제거

**AH2a(claude) ✅ 완료.** `sidebar.agent-hooks`(기본 `false`) 게이트와 claude `settings.json` 배선이 섰다 —
판정·트리 수술은 [`session/agent_hook_install.zig`](../../src/session/agent_hook_install.zig)(순수, 단위 21개),
파일 세계는 `app_session/agent.zig`의 `reconcileAgentHooks`가 지킨다. **시작 시 로그 정리**(`cleanupAgentHookLogs`)도 함께 들어갔다 — 소비자가 아직 없어(AH3) 회전이 돌지 않으므로
그것이 없으면 프롬프트·명령 원문이 담긴 파일이 무한히 자란다. 검증은 **제품 경로 무인 게이트**
(`zig build test-provider-session-removal`)가 `AppSession.init`을 실제로 돌려 본다: 사용자 항목 순서 보존,
과거 표식 잔존, 로그 디렉터리 `0700`, 지난 실행 로그 정리와 남의 파일 보존, 재실행 시 바이트 무변경,
**게이트 off에서 `hooks` 키 무생성**.
남은 것은 AH2b(codex)와 statusLine 훅 제거, 그리고 **제거를 부르는 사용자 액션**이다 — 지금은 켤 수는 있는데
빼려면 `settings.json`을 손으로 고쳐야 한다(계약 §5의 ⚠️). **그 구멍을 닫기 전에는 게이트 기본값을 켜지 않는다.**


- Claude `~/.claude/settings.json`, Codex `~/.codex/hooks.json`에 계약 §2 세트를 등록한다. Codex는
  `config.toml`의 `trusted_hash`를 **함께** 갱신한다.
- **AH2b의 첫 일은 그 해시의 입력을 확정하는 실험이다**(계약 §2.1의 ⚠️ — 실측으로 재현하지 못했다).
  알려진 훅을 심고 codex를 한 번 돌려 기록된 값을 얻은 뒤 내용으로 역산한다. 못 맞히면 설치가
  **매 실행 승인 프롬프트**로 돌아온다.
- Codex `hooks.json`도 claude `settings.json`과 **같은 모양**이다(실측: `hooks` → 이벤트 → 그룹 →
  `hooks[]` → `{type, command}`). 그래서 `agent_hook_install`의 트리 수술을 그대로 쓴다 — 다른 것은
  이벤트 이름이 snake_case인 trust 키와 파일 위치뿐이다.
- `hooks`는 배열 항목이므로 **표식 기반 추가·선별 제거**다(감싸기가 아니다). 사용자 항목은 순서까지 보존한다.
- atomic write + `flock` 직렬화. config 게이트로 끄면 흔적까지 지우고 관측 모드로 복귀한다.
- **statusLine 훅을 제거한다** — `SessionStart`가 그 역할의 상위집합이고, 관측 모드용으로도 남기지
  않는다(계약 §5).
- **과거 표식(`MARU_AGENT_MAP_HOOK_V2`) 항목은 건드리지 않는다**(계약 §5, P1 «자동 정리하지 않는다»).
- 검증: 사용자 훅이 이미 있는 파일에서 순서·내용 보존, 설치·제거·재설치 멱등성, 게이트 off 시 완전 제거,
  **과거 표식 항목이 그대로 남는지**,
  Codex trust 항목 동시 갱신, statusLine 훅 제거 후 세션 신원이 여전히 잡히는지.

### AH3 — 모드 판정

- 정적: 설치됨 + 게이트 on → 훅 모드로 시작. 동적: **시간 기준 타임아웃** 안에 이벤트 0 → 관측 모드로
  강등 + 기록(계약 §1.2 — "한 턴"으로 잡으면 순환이다).
- **이 단계는 게이트 기본 off로 머지한다.** AH3은 관측 입력을 끄기만 하고 훅으로 채우는 쪽은 AH4다 —
  단독으로 켜면 `agent_state`가 `unknown`에 고정돼 **사이드바 배지가 통째로 사라진다.** AH4가 들어온 뒤
  기본값을 켠다(또는 두 단계를 한 PR로 묶는다).
- 훅 모드 Term에서 **OSC 9/777 알림 drain을 건너뛰고**(pending은 비워 버린다), `agent_observer`에 화면·OSC
  title/progress·`output_active`를 넣지 않는다. **OSC 7/133/52/11 등은 그대로 돈다**(계약 §1.1).
- 검증: 모드별로 상태·알림 소스가 정확히 하나인지(교차 오염 0), 강등이 기록되는지, 무관 OSC가 훅 모드에서도
  동작하는지, 같은 창에 두 모드 pane 공존.

### AH4 — 상태 소비 (사이드바 배지)

- `Term.agent_state`를 훅 모드에서 훅 payload로 채운다: `UserPromptSubmit`~`Stop` = 진행중,
  `PermissionRequest` = 입력 대기, `Stop` = 완료. `stop_hook_active` 재진입은 무시한다.
- **`Stop.background_tasks`가 비어 있지 않으면 완료로 단정하지 않는다** — 턴은 끝났어도 셸 작업이
  돌고 있다(실측으로 `{id, type: shell, status: running, description}` 형태를 확인했다).
- 진행중 세부와 **AI 소행 경로**(편집 도구의 `tool_input.file_path`)가 모두 `PreToolUse`에서 온다.
  진행중 라벨은 `tool_name` + **`tool_input.description`**(사람이 읽는 설명, 실측 확인)에서
  온다. 명령 원문은 길고 민감해 배지에 쓰지 않는다 — 관측 모드의 foreground
  process 라벨과 **같은 자리**에 그리되 소스는 섞지 않는다.
- 검증: 상태 전이표 단위 테스트, 조용히 오래 도는 셸 명령에서 진행중 유지(관측 모드가 틀리는 케이스),
  `AskUserQuestion`이 `PreToolUse`로만 올 때 입력 대기로 잡히는지.
- **완료 조건에 대화형 수동 검증을 포함한다** — `PermissionRequest`가 헤드리스에서 발화하지 않아
  미검증이다(계약 §9-6). 실제 승인 프롬프트가 뜨는 세션에서 입력 대기 전이를 눈으로 확인한다.

### AH4b — 사이드바 대화 줄

- 훅 모드에서 마지막 프롬프트·응답을 훅 payload로 채운다(`UserPromptSubmit.prompt`,
  `Stop.last_assistant_message`). 그 Term에 대해 **transcript tail 읽기를 중단한다** — 신원 해소·256 KiB
  파싱·폴링이 함께 빠진다.
- 관측 모드 경로([sidebar-agent-list.md](../sidebar-agent-list.md) §7)는 그대로 둔다.
- 검증: 훅 모드 Term에서 transcript 파일 열기 0회, 두 모드가 같은 자리에 같은 모양으로 그리는지,
  provider가 빈 응답을 준 턴의 표시.

### AH5 — 알림 소비

- `Stop`→완료(`last_assistant_message`), `PermissionRequest`→주의(`tool_name`+`tool_input`),
  `Notification(idle_prompt)`→기본 억제.
- **중복 방지**: 턴 단위 1회 + 재발화 가드 토큰. 주의 알림은 디바운스하되 **배지는 즉시** 바꾼다(자동 승인으로
  해소되는 요청 때문).
- 활성·포커스 pane은 배너 억제·목록만(현행 정책과 동형).
- 검증: 같은 턴 중복 0, 자동 해소된 승인에서 배너 0·배지 전이 1, 포커스 억제, 알림 문구에 위치 접두.
- **주의 알림도 대화형 수동 검증이 완료 조건이다**(같은 이유, 계약 §9-6).

### AH6 — 비용 측정과 후퇴 경로

- **1차 측정은 끝났다**(계약 §3): 훅 1회 12.27 ms, `sh` spawn 기저 8.04 ms, 백그라운드 분리는 오히려
  느림. 그 결과로 `PostToolUse`를 편집 도구로 좁혀 발화를 절반으로 줄였다.
- 남은 측정: **샌드박스 밖 실환경** 1회 비용, 실제 세션의 로그 증가량, 턴 체감 지연.
- 그래도 크면 다음 후퇴는 `PreToolUse`를 편집·셸 도구로 좁히는 것이다(그러면 Read·Grep 같은 도구가
  진행중 세부에서 빠진다).
- 검증: 측정 스크립트와 결과 artifact, 후퇴 설정에서 배지가 그대로인지.

## 2. 순서와 의존

```
AH1 전달 채널 ─┬─ AH2 설치·제거 ─ AH3 모드 판정 ─┬─ AH4 상태
               │                                  └─ AH5 알림
               └─ AT1 턴 경계(turn-changes 계획)
AH6 측정은 AH1~AH2 직후부터 상시
```

AH1~AH3까지가 인프라이고, AH4·AH5·AT1이 그 위의 소비자다. **AH3 없이 AH4를 켜면 두 모드가 섞인다** —
계약이 금지하는 상태다.

## 3. 알려진 한계 (구현 전에 적어 둔다)

- 훅 모드 Term에서 **임의 프로그램의 OSC 알림이 사라진다**(계약 §9-1). 발신자를 구분할 수 없어 감수하는
  손해이고, 되찾는 수단은 그 Term에서 훅을 끄는 것뿐이다.
- 도구 훅 비용은 1차 측정을 마쳤고 그 결과로 세트가 이미 한 번 바뀌었다(계약 §3.1). **샌드박스 밖
  실환경 측정은 남아 있다** — 그 값이 나쁘면 세트가 또 바뀔 수 있다.
- **`PermissionRequest`·`Notification`은 양 provider 모두 미검증**이다(계약 §9-6) — 헤드리스로는 발화를
  재현할 수 없어 AH4·AH5의 완료 조건이 대화형 수동 검증이다. Codex `PostToolUse`도 미검증이라 AH4의
  Codex 경로는 `PreToolUse`/`Stop`만으로도 상태가 서야 한다.
- 훅은 사용자 소유 설정 파일을 고친다. 게이트 기본값은 AH2 리뷰에서 사용자와 정한다.
