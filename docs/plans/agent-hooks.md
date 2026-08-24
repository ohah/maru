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
- 로그는 **소비 즉시 회전·삭제**한다(계약 §4.2). 파일 `0600`, 디렉터리 `0700`. ✅ **완료**(2026-08-21) —
  크기 상한 1 MiB, 회전 절차 4단계(rename → 커서 리셋 → **회전본 tail 건지기** → 삭제), 종료 시
  «그 세션 소유 pane» 정리, 시작 시 정리가 회전본까지 거둔다.
- 각 줄에 **provider 표식**을 우리가 붙인다(계약 §4.1) — payload에는 없다.
- 라인 상한(초과 절단)·파일 회전·오래된 파일 정리를 함께 넣는다. `PostToolUse`의 `tool_response.stdout`이
  수십 KB로 들어오므로 상한이 없으면 세션당 수백 MB가 된다.
- maru 쪽 소비기: tick마다 오프셋 전진 tail 파싱, tick당 처리 상한, **손상 라인은 조용히 버림**.
- 검증: 부분 라인·회전 경계·오프셋 전진·상한 절단·손상 라인 무시(순수 모듈 단위), 동시 append 인터리브.

### AH2 — 설치와 제거

**AH2a(claude) ✅ 완료.** `sidebar.agent-hooks` 게이트와 claude `settings.json` 배선이 섰다 —
판정·트리 수술은 [`session/agent_hook_install.zig`](../../src/session/agent_hook_install.zig)(순수, 단위 21개),
파일 세계는 `app_session/agent.zig`의 `reconcileAgentHooks`가 지킨다. **시작 시 로그 정리**(`cleanupAgentHookLogs`)도 함께 들어갔다 — 소비자가 아직 없어(AH3) 회전이 돌지 않으므로
그것이 없으면 프롬프트·명령 원문이 담긴 파일이 무한히 자란다. 검증은 **제품 경로 무인 게이트**
(`zig build test-provider-session-removal`)가 `AppSession.init`을 실제로 돌려 본다: 사용자 항목 순서 보존,
과거 표식 잔존, 로그 디렉터리 `0700`, 지난 실행 로그 정리와 남의 파일 보존, 재실행 시 바이트 무변경,
**게이트 off에서 `hooks` 키 무생성**.
**AH2b(codex) ✅ 완료.** 세트를 provider 별로 가르고(codex 7개 — 세트가 늘어날 때 이 숫자가 5 로 남아
있었다), 신뢰 값 계산을 순수 층으로 세우고
(`agent_hook_trust.zig` — golden 전원이 **codex 자신이 계산한 값**), `hooks.json` 설치와 `config.toml`
신뢰 기록을 배선했다. 제품 경로 게이트가 `AppSession.init`으로 확인한다: codex 세트대로 설치, 과거 표식
잔존, 사용자 항목이 앞, **신뢰 키가 실체 경로**(심링크 `CODEX_HOME` 픽스처로 못박음), 재실행 시 바이트
무변경, 새 `config.toml` 은 `0600`.

**끄면 지운다**(계약 §5): 게이트가 꺼져 있으면 같은 read-modify-write 를 `Intent.uninstall` 로 타고,
codex 는 `config.toml` 의 우리 신뢰 블록까지 거둔 뒤 남는 것이 없으면 파일째 지워 설치 전 상태로 돌린다.

남은 것은 statusLine 훅 제거다.


- Claude `~/.claude/settings.json`, Codex `~/.codex/hooks.json`에 계약 §2 세트를 등록한다. Codex는
  `config.toml`의 `trusted_hash`를 **함께** 갱신한다.
- **Codex 세트는 7개다** — `Notification` 과 `StopFailure` 가 Codex 에 없다(계약 §2 — codex 는 공개 소스의
  `HookEventName` 열거가 권위이고, 2026-08-22 대조에서 실측과 일치했다). 그래서 이 단계는 먼저
  `agent_hook_command.events` 를 **provider 별로 가른다**(`planForSet` 이 쓰는 세트 크기도 함께 갈린다).
  그 항목이 파일 파싱을 깨는지 조용히 무시되는지도 실험으로 확인한다 — 깨면 사용자의 `hooks.json` 이
  통째로 무효가 된다.
- **해시 입력도 matcher 규칙도 일곱 다 확정됐다**(계약 §2.1 — 이벤트 신원 객체, app-server `hooks/list`로
  codex 자신의 값을 받아 대조). 계산은 [`session/agent_hook_trust.zig`](../../src/session/agent_hook_trust.zig)
  가 소유하고 golden 이 세트 전원에 대해 그 값을 못박는다. 신뢰 항목은 **키가 비어 있을 때만** 쓴다(§2.1 — codex 쪽
  포맷이 바뀌어도 무한 프롬프트가 되지 않게).
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

✅ **완료**(AH4 상태·대화 소비 포함). 순수 층은
[`session/agent_hook_mode.zig`](../../src/session/agent_hook_mode.zig) — `modeFor`(게이트·로그 파일·에이전트
셋이 다 서야 훅 모드)와 `next`(턴 경계 전이). 배지 상태는 관측 모드의 열거를 **그대로** 쓴다(복사하지
않는다 — 복사하면 배지가 소스마다 다른 값을 갖는다). 파서의 `Kind` 전체를 comptime 으로 돌아 «전이가 있는
이벤트» 와 «의도적으로 상태를 안 흔드는 이벤트» 를 강제 분류한다.

platform 은 `pollAgentHookEvents` 가 tick 마다 로그를 tail 파싱해 `agent_state` 와 **마지막 대화**를 채우고
(`UserPromptSubmit.prompt` / `Stop.last_assistant_message`), `pollAgentKinds` 의 소비자 분기가 모드로 갈린다 —
훅 모드면 `pollAgentState`·`pollAgentTranscript` 를 **아예 부르지 않는다**. `drainOscNotificationFrom` 도 훅 모드
Term 의 알림을 버리되 `pending` 은 비운다(안 비우면 드레인 루프가 그 Term 에서 멈춘다).

**AH5(알림 소비)도 함께 들어갔다.** 알림을 상태 **전이**에 붙여 「턴 단위 1회」와 「재발화 가드」를 구조로
얻고(세는 코드를 두지 않는다), 주의 알림은 디바운스해 자동 승인으로 해소된 요청을 버린다(배지는 즉시
바뀐다). 방출은 관측 모드와 **같은 tail**(`emitNotification`)을 탄다.


- 정적: 설치됨 + 게이트 on → 훅 모드로 시작. 동적: **그 pane의 로그 파일이 없으면** 관측 모드로 강등 +
  기록(계약 §1.2 — 2026-08-21 확정). 이벤트 개수로 잡으면 가만히 있는 세션이, 시간으로 잡으면 이미 돌던
  세션이 잘못 강등된다.
- **이 단계는 게이트 기본 off로 머지했다**(그때의 결정 — 2026-08-22 에 기본을 켰다). AH3은 관측 입력을 끄기만 하고 훅으로 채우는 쪽은 AH4다 —
  단독으로 켜면 `agent_state`가 `unknown`에 고정돼 **사이드바 배지가 통째로 사라진다.** AH4가 들어온 뒤
  기본값을 켠다(또는 두 단계를 한 PR로 묶는다).
- 훅 모드 Term에서 **OSC 9/777 알림 drain을 건너뛰고**(pending은 비워 버린다), `agent_observer`에 화면·OSC
  title/progress·`output_active`를 넣지 않는다.
- **턴 스냅샷은 훅 쪽에서 찍는다.** 관측 트리거를 끄기만 하면 게이트를 켠 것만으로 «에이전트가 방금 바꾼
  것»이 사라진다 — 같은 술어(`isTurnEnd`)를 훅 전이에 태운다(2026-08-21, 문서-코드 대조가 잡은 누락).
  **배치당 한 번**만 찍고(배치 안의 이벤트는 같은 작업트리를 본다), 회전본을 건지는 경로도 같은 규율을
  탄다. 자식이 남아 lead를 붙잡은 동안에는 찍지 않는다 — 그때 찍으면 자식이 고칠 파일이 스냅샷 뒤에
  바뀌어 빠진다. **OSC 7/133/52/11 등은 그대로 돈다**(계약 §1.1).
- 검증: 모드별로 상태·알림 소스가 정확히 하나인지(교차 오염 0), 강등이 기록되는지, 무관 OSC가 훅 모드에서도
  동작하는지, 같은 창에 두 모드 pane 공존.

### AH4 — 상태 소비 (사이드바 배지)

- `Term.agent_state`를 훅 모드에서 훅 payload로 채운다: `UserPromptSubmit`~`Stop` = 진행중,
  `PermissionRequest` = 입력 대기, `Stop` = 완료. `stop_hook_active` 재진입은 무시한다.
- **「입력 대기」의 소스는 둘이다** — `PermissionRequest` 와 `Notification`(계약 §6). 후자는 **아는 종류**
  다섯(`permission_prompt`·`worker_permission_prompt`·`elicitation_dialog`·`elicitation_url_dialog`·
  `agent_needs_input`)만 배지를 옮기고, 모르는 종류·유휴 알림은 «모르는 이벤트» 와 같이 상태를 안 흔든다.
  둘을 두는 이유는 `PermissionRequest` 가 우리 실측에서 **한 번도 발화하지 않았기** 때문이다 — 그것 하나에만
  걸면 대화형에서도 안 올 경우 그 배지에 소스가 없다. codex 에는 `Notification` 이 없어 소스가 하나뿐이다.
- **`Stop.background_tasks`에 `status: running`인 항목이 있으면 완료로 단정하지 않는다** — 턴은 끝났어도
  셸 작업이 돌고 있다(실측으로 `{id, type: shell, status: running, description}` 형태를 확인했다).
  «비어 있나»로 보면 끝난 항목 하나가 배지를 영원히 붙잡는다. **claude 전용 필드다** — codex 바이너리에는
  그 키가 없고(2026-08-21 실측), 없으면 «도는 것 0»이라 codex에서는 평소 `Stop` 규칙 그대로다.
- **`StopFailure`도 턴 끝으로 다룬다** — 오류로 끝난 턴은 `Stop`이 오지 않는다. codex 열거에는 없고,
  **codex 는 그 경우 `Stop` 도 안 보낸다**(계약 §9-10 — 소스로 종결). 그래서 오류로 끝난 codex 턴은
  배지를 «진행 중» 에 남긴다. 훅으로 메울 방법이 없다.
- **서브에이전트를 `SubagentStart`/`SubagentStop`으로 «센다»** — 자식이 도는 동안 lead의 `Stop`은 턴 끝이
  아니고, 마지막 자식이 끝날 때 푼다. 세지 않고 «떴다» 표시만 들면 자식의 `Stop`이 `agent_id` 때문에
  무시되어 **배지가 영영 안 풀린다**(그 설계를 한 번 짰다가 되돌렸다). 두 이벤트는 양 provider에 다 있고
  **자식의 `agent_id`를 싣는다**(실측) — 그래서 «자식 이벤트는 무시» 가드를 수명 이벤트보다 앞에 두면
  셈이 통째로 죽는다.
- 풀지 말지는 **«lead의 턴이 열려 있는가»**로 가른다(계약 §2). 「lead가 끝났는가」로 물으면 «아직 시작
  안 함»과 «이미 끝남»이 같은 값이 되어 대기 상태에 자식 한 쌍이 오면 배지가 갇힌다 — 전수 탐색이 잡았다.
- **턴 식별자도 리셋 신호로 쓴다**(claude `prompt_id`·codex `turn_id`). `UserPromptSubmit` 하나에만 걸면
  그 줄이 유실될 때(§4.3) 지난 턴의 셈이 넘어와 배지가 안 풀린다. ⚠️ 자식 이벤트의 키는 보지 않는다 —
  codex의 자식은 **자기 `turn_id`**를 쓴다(실측).
- 진행중 세부와 **AI 소행 경로**(편집 도구의 `tool_input.file_path`)가 모두 `PreToolUse`에서 온다.
  진행중 라벨은 `tool_name` + **`tool_input.description`**(사람이 읽는 설명, 실측 확인)에서
  온다. 명령 원문은 길고 민감해 배지에 쓰지 않는다 — 관측 모드의 foreground
  process 라벨과 **같은 자리**에 그리되 소스는 섞지 않는다.
  **구현됨**: `agent_hook_mode.labelFor`(순수 규칙)가 세우고 지우는 자리를 정하고, `Term.agent_hook_tool`이
  들고, 사이드바의 running 상태줄이 `"▁▅▇▃ 진행중 · <세부>"`로 그린다. 세부가 없으면(관측 모드거나 아직
  도구를 안 부른 구간) **예전과 바이트가 같은** 문자열이다. 자식의 도구 호출은 부모 줄을 갈아 끼우지
  않고(`agent_id`), 턴 경계(`Stop`·`StopFailure`·`UserPromptSubmit`·`SessionStart`)에서 비운다.
- 검증: 상태 전이표 단위 테스트, 조용히 오래 도는 셸 명령에서 진행중 유지(관측 모드가 틀리는 케이스),
  `AskUserQuestion`이 `PreToolUse`로만 올 때 입력 대기로 잡히는지.
- **완료 조건에 대화형 수동 검증을 포함한다** — ✅ **충족**(2026-08-22). 실제 승인 프롬프트가 뜨는
  세션에서 `PreToolUse → PermissionRequest → Notification(permission_prompt)` 을 받았고 **배지가
  「입력 대기」로 서는 것을 눈으로 확인했다**(계약 §9-6). 한 승인에 두 소스가 다 발화하지만 전이가
  하나뿐이라 알림도 하나다.

### AH4b — 사이드바 대화 줄

- 훅 모드에서 마지막 프롬프트·응답을 훅 payload로 채운다(`UserPromptSubmit.prompt`,
  `Stop.last_assistant_message`). 그 Term에 대해 **transcript tail 읽기를 중단한다** — 신원 해소·256 KiB
  파싱·폴링이 함께 빠진다.
- 관측 모드 경로([sidebar-agent-list.md](../sidebar-agent-list.md) §7)는 그대로 둔다.
- 검증: 훅 모드 Term에서 transcript 파일 열기 0회, 두 모드가 같은 자리에 같은 모양으로 그리는지,
  provider가 빈 응답을 준 턴의 표시.

### AH5 — 알림 소비

- `Stop`→완료(`last_assistant_message`), `PermissionRequest`→주의(`tool_name`+`tool_input`),
  `Notification`→**종류로 갈린다**(계약 §6): 승인·입력을 기다리는 다섯 종류는 주의, `idle_prompt` 를
  포함한 나머지와 모르는 종류는 상태를 안 흔들어 알림도 안 난다.
- **codex에도 알림이 간다.** 없는 것은 `Notification`·`StopFailure` 이고, 완료(`Stop`)·주의
  (`PermissionRequest`)는 codex 열거에 다 있다(계약 §2, 2026-08-21 `hooks/list` 실측).
- **중복 방지**: 턴 단위 1회 + 재발화 가드 토큰. 주의 알림은 디바운스하되 **배지는 즉시** 바꾼다(자동 승인으로
  해소되는 요청 때문).
- 활성·포커스 pane은 배너 억제·목록만(현행 정책과 동형).
- 검증: 같은 턴 중복 0, 자동 해소된 승인에서 배너 0·배지 전이 1, 포커스 억제, 알림 문구에 위치 접두.
- **주의 알림도 대화형 수동 검증이 완료 조건이다**(같은 이유, 계약 §9-6). ✅ 배지 전이는 확인했다.
  ⚠️ **배너 자체는 아직 못 봤다** — 그 pane 을 보고 있으면 억제되는 것이 정책이라, 배너를 확인하려면
  다른 pane 을 보는 동안 승인 요구가 떠야 한다.

### AH6 — 비용 측정과 후퇴 경로

- **완료**(2026-08-21 재측정, 계약 §3). 훅 1회 10.39 ms, `sh` spawn 기저 10.05 ms — 7 판 × 300 회를
  **변종을 번갈아** 재고 중앙값을 썼다. 한 판씩 재고 빼면 판 사이 변동(±0.64 ms)이 효과보다 커서
  **훅이 기저보다 «빠르게» 나온다**(부호가 뒤집힌다) — 그 함정을 두 번 밟고서야 방법을 바꿨다.
- **샌드박스 밖도 쟀고 차이가 없었다**(기저 10.19 ms, 변동 폭 안). 옛 판의 「절대값을 상한으로 읽어라」는
  근거가 없어 계약에서 삭제했다.
- **스크립트 몫은 측정 한계 아래다**(+0.34 ms 대 ±0.64 ms). 그래서 「스크립트 최적화 여지가 없다」는
  결론이 오히려 단단해졌고, 레버는 **발화 횟수**뿐이다.
- **턴당 발화 횟수를 실측 로그에서 셌다**(계약 §3.0): 도구 없는 턴 2~3, 도구 턴 3~6, **서브에이전트 턴
  9**, 실사용에서 관측한 큰 턴 **36**. 세트가 6 → 9 로 늘고 자식 이벤트가 따로 오면서 서브에이전트 턴의
  비용이 옛 기록보다 크다(~90 ms, 큰 턴은 ~0.36 초). 다만 그런 턴은 모델 왕복이 이미 수십 초다.
- 그래도 크면 다음 후퇴는 `PreToolUse`를 편집·셸 도구로 좁히는 것이다(그러면 Read·Grep 같은 도구가
  진행중 세부에서 빠진다). **지금 수치로는 그 후퇴가 필요 없다.**
- ⚠️ 남는 한계: 이 값은 우리가 `sh` 를 띄워 잰 것이고 provider 가 자기 프로세스에서 fork·exec 하는
  경로는 다를 수 있다. 그 차이는 spawn 비용 자체의 차이이지 우리 스크립트 몫이 아니다.

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
- 도구 훅 비용은 측정을 마쳤다(AH6, 계약 §3). 샌드박스 안팎에 차이가 없었고 스크립트 몫은 측정 한계
  아래였다. 남은 레버는 발화 횟수뿐이고, 지금 수치로는 후퇴가 필요 없다.
- ✅ **양 provider 대화형 검증 완료**(2026-08-22). claude 는 `PermissionRequest` 와 `Notification` 이 **둘 다**
  오고(계약 §9-6), codex 는 `Notification` 이 없어 소스가 `PermissionRequest` 하나뿐인데 **그것이 실제로
  발화한다**(§9-8 — `codex -a on-request -s read-only` 로 확인). 두 경우 다 배지가 「입력 대기」로 서고,
  승인 프롬프트에서 선택을 옮겨도 **움직이지 않는다**(= 화면이 아니라 훅이 그린다).
- **승인된 뒤 명령이 도는 동안 배지가 「입력 대기」로 남는다**(계약 §6). 그 요구를 푸는 이벤트가 없다 —
  `PostToolUse` 를 payload 크기 때문에 뺐기 때문이다(§3.1). 다음 `PreToolUse`·`Stop` 이 와야 풀린다.
  자동 승인은 밀리초라 알림은 디바운스가 삼키지만 **사람이 승인한 긴 명령**은 그 시간 동안 배지가 실제와
  다르다. 되찾으려면 도구 종료 신호가 필요하고, 그것은 세트를 늘리는 결정이다. Codex `PostToolUse`도 미검증이라 AH4의
  Codex 경로는 `PreToolUse`/`Stop`만으로도 상태가 서야 한다.
- 훅은 사용자 소유 설정 파일을 고친다. 게이트 기본값은 AH2 리뷰에서 사용자와 정한다.
