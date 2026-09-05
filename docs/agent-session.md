# 에이전트 상태 감지(터미널 관측)

> 단일 출처(design). Maru는 터미널에서 실행되는 대화형 에이전트의 종류와 상태를 **터미널이 이미 소유한
> 관측값만으로** 판정한다. 사이드바의 "마지막 대화" 표시는 이 판정과 분리된 별도 기능이며, 그 계약은
> [사이드바 에이전트 목록](sidebar-agent-list.md)이 단일 출처다(아래 «목표와 비목표»).

## 목표와 비목표

목표는 claude/codex가 어느 Term에서 실행 중인지, 작업 중인지, 사용자 입력을 기다리는지, 입력 가능한 idle
화면인지 사이드바와 컨트롤 플레인에 표시하는 것이다. 에이전트 TUI는 기존처럼 PTY foreground에서 그대로 실행된다.

### 두 소스 (2026-08-20 결정 → 2026-09-01 개정 — 둘 다 사용자 결정)

**이 문서는 «화면·OSC 소스»의 계약이다.** 상태 판정은 Term마다 하나이고 거기에 훅과 이 문서의 규칙이
함께 들어간다. **훅이 설치된 Term에서도 이 문서의 화면 규칙은 계속 돈다** — 훅이 구조적으로 모르는
질문(승인 해제·codex 오류 종료·훅 유실)에 답하는 것이 이 규칙이기 때문이다. 어느 쪽이 이기는지는
[에이전트 훅 통합](agent-hooks.md) **§1.1 권위표**가 단일 출처이고, 그 표에 없는 뒤집기는 금지다.

| | 훅 | 화면·OSC(이 문서) |
| --- | --- | --- |
| 상태 | 훅 payload | 화면 규칙 + OSC title/progress + PTY activity |
| 알림 | 훅(`Stop`·`PermissionRequest`·`Notification`) | OSC 9/777 + 관측 주도 알림 — **훅이 도는 Term에서는 내지 않는다**(agent-hooks §1.1.1) |

**알림만은 여전히 한 소스다.** 상태는 합치지만 알림은 훅이 있으면 훅만 낸다 — «알림 = 상태 전이»로
중복을 막아 둔 구조(agent-hooks §6)가 두 소스가 각자 알리면 깨지기 때문이다.

**왜 뒤집었나**: 아래 비목표는 "설치가 필요 없다"를 얻는 대신 provider TUI 문구에 결합되는 비용을 감수한
것이었다. 그 비용이 실제로 두 곳에서 드러났다 — ⑴ 규칙이 특정 버전·설정의 화면에 묶여 있고(«실측 신호 기록»이
그 사실을 이미 적어 두었다) ⑵ provider가 턴 종료와 권한 요구를 같은 문구로 뭉쳐 보내는 문제를 화면 관측으로
되살리려 애쓰고 있었다(«관측 주도 완료·attention 알림»). 훅은 둘 다 추측 없이 해결한다. 다만 훅은 설치가
필요하고 claude·codex에만 있으므로, 이 관측 계층은 **폐기하지 않는다.** 2026-09-01 개정으로 그 위치가
«폴백»에서 **«항상 도는 또 하나의 소스»**로 올라갔다 — 훅이 모르는 것을 이쪽이 알기 때문이다.

이 관측 계층은 다음을 의도적으로 제공하지 않는다.

- **이 문서의 규칙은** provider 파일·훅에 의존하지 않는다 — kind·state를 화면과 process tree만으로 정한다.
  훅이 없는 Term은 이것만으로 살고, 훅이 있는 Term에서는 권위표의 C1·C2가 이 판정을 쓴다
- provider session id를 저장하거나 자동 resume/fork하는 workspace restore
- 에이전트 내부 단계, tool call, API 대기 원인을 정확히 복원하는 기능

관측 모드는 터미널 밖의 private 상태를 읽지 않는 대신 설치가 필요 없고, 같은 cwd의 여러 세션·중첩 프로세스·
provider 포맷 변경에 결합되지 않는다. 그 상태는 **화면에 드러난 사용자 관점**이며 provider 내부 상태의 증명은
아니다.

### 사이드바 대화 표시와의 경계

이 문서는 처음에 트랜스크립트 JSONL 해석과 마지막 답변 미리보기도 비목표로 뒀다. 이후 사용자 결정으로 사이드바
에이전트 행에 **마지막 대화**를 싣기로 했고, 그 설계의 단일 출처는 [사이드바 에이전트 목록](sidebar-agent-list.md)이다.
관측 계약을 지키기 위해 경계는 이렇게 둔다.

- **상태 판정은 여전히 provider 파일을 보지 않는다.** 트랜스크립트에서 오는 것은 표시할 대화 텍스트뿐이다.
- **세션 신원은 추측하지 않는다.** provider가 자식 프로세스에 내려주는 env가 1차 근거이고(§7.2.1), 도구를 한 번도
  실행하지 않는 세션을 메우는 claude 상태줄 훅이 보강이다(§7.2.2). 파일 mtime으로 어느 세션인지 고르지 않는다.
- **상태줄 훅은 없어졌다**(2026-08-21 — [agent-hooks.md](agent-hooks.md) §5). 앱은 지난 버전이 설치해 둔 것을
  거두기만 한다. 아래는 그 훅이 있던 시절의 규율이고, 되돌리는 쪽 규칙으로만 남아 있다. 끄면 provider 설정을 전혀
  수정하지 않고 이미 설치한 것도 원상 복구한다. 켜도 `settings.json`의 `statusLine` 키 하나만 바꾸고 `hooks`를
  포함한 나머지 JSON은 바이트 그대로 두며, 사용자가 쓰던 상태줄 명령은 지우지 않고 감싼다.
- 과거 `MARU_AGENT_MAP_HOOK_V2` 계열 **hook event 설치는 되살리지 않는다**(아래 «과거 source build 훅 수동 정리»).
  그 방식은 provider 실행 흐름에 개입하지만 상태줄은 표시 전용이라 실패해도 세션이 멈추지 않는다.

이 경계는 CI 게이트 `mise run test-provider-session-removal`이 무인 검증한다 — 옵션이 꺼진 기본 경로에서 provider
파일 무변경, 켠 경로에서 `statusLine` 외 무변경과 사용자 명령 보존.

## 영속 session host와의 관계

[영속 터미널 세션 호스트](persistent-session-host.md)가 구현되면 Claude/Codex가 이어지는 이유는 provider session ID를
저장·resume/fork해서가 아니라, 그 프로세스가 붙은 동일 PTY runtime을 `maru-sessiond`가 계속 소유하기 때문이다.
host 또는 agent process가 끝나면 그 실행 세션도 끝난 것이며 provider 복구는 하지 않는다.

provider session continuity용 workspace typed field/parser, restore 설정 alias, 과거 hook cleanup은 persistent-session P1에서
제거했다. live foreground process/screen observer와 `Term.agent_kind/agent_state`는 session restore가 아니므로 유지한다.

## 관측 입력

Term별 observer는 다음 입력을 함께 사용한다.

1. **foreground process group**: 실행 파일과 process tree로 agent kind를 판정한다. claude가 `comm`을 버전 문자열로
   바꾸거나 node/bun 래퍼 아래 실행되는 경우 argv/process tree를 확인한다. agent process가 사라지면 상태도 즉시
   `unknown`으로 리셋한다.
2. **live screen tail**: 현재 viewport의 마지막 텍스트 콘텐츠를 기준으로 bounded 행을 공백 정규화해 provider별 manifest와 매칭한다.
   fullscreen TUI가 resize 뒤 아래쪽에 빈 행을 남겨도 trailing blank padding은 tail 위치 계산에서 제외한다.
   scrollback 전체를 읽지 않으며 현재 화면에 없는 과거 문구는 상태 근거로 쓰지 않는다.
   행 상한은 **상시 chrome이 사용자 입력 길이에 밀려 tail 밖으로 나가지 않을 만큼** 넉넉히 둔다 — composer는 입력
   행 수만큼 자라므로(실측), 상한이 짧으면 입력이 길어질 때 프롬프트 마커가 tail을 벗어나 근거가 사라진다. 오래된
   오버레이 문구가 현재 근거로 끌려오는 것은 행 상한이 아니라 오버레이 규칙의 거리 게이트가 막는다.
3. **OSC metadata**: 터미널 코어가 이미 파싱한 title과 progress를 문자열 입력으로 제공한다. progress는
   [ConEmu specific OSC](https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC)가 정의한
   OSC `9;4;state[;progress]` 본문을 bounded 문자열로 보존한 값이다. 기존처럼 알림으로 발사하지 않고 observer의
   보조 입력으로만 쓴다. OSC는 agent가 실제로 보낸 값일 때만 신호이며 Maru가 provider 훅을 주입해 만들지 않는다.
4. **PTY output activity**: agent가 foreground인 동안 새 output이 지속된다는 사실은 **약한 신호**다. 화면·OSC 근거가
   하나도 없을 때만 `running` 폴백으로 쓰고, 근거 있는 직전 상태를 즉시 뒤집지는 못한다(아래 «상태 모델과 우선순위»
   의 신호 세기 중재). output에는 사용자가 타이핑한 에코와 composer 재그리기가 섞여 있어서, 출력이 있다는 사실만으로
   작업 중을 단정하면 **입력만 해도 running**이 된다. 반대로 출력이 잠시 멈췄다는 사실만으로 `idle`로 내리지도 않는다.
   느린 API·긴 도구 실행은 조용할 수 있기 때문이다.

screen/OSC/provider 패턴은 코드에 하드코딩된 거대한 switch 대신 작은 manifest 데이터로 둔다. manifest는
`agent`, `state`, 화면 region(아래 «화면 region 모델과 규칙 게이트» 참조), 불리언 게이트(`all`/`any`/`not`·`contains`/`line_prefix`),
`skip_state_update`, `visible_idle`, `visible_blocker`, `visible_running` 메타를 표현한다. 정규식·임의 코드 실행·외부 다운로드는
넣지 않는다 — 선형 정규식 엔진이 없어 손수 짠 패턴은 catastrophic backtracking 위험이 있고, 원격 규칙은 서명 없는 신뢰가
되기 때문이다. 빌드에 포함된 manifest만 사용하며 fixture가 근거다.

manifest 데이터 실수는 런타임이 아니라 **빌드에서** 잡는다. 게이트에 양성 매처가 있어야 하고(없으면 규칙이 모든 화면에서
조용히 발화한다), **상태를 세우는 규칙은 `visible_*` 근거 플래그를 하나 이상 들어야 한다.** 후자는 신호 세기 중재의 전제다 —
플래그를 빠뜨린 규칙은 조용히 약한 신호로 강등돼 근거 있는 직전 상태를 이기지 못한다. 이 검증이 “약한 신호 생산자는 PTY
activity 폴백 하나”라는 불변식을 데이터 차원에서 못박는다. `skip_state_update`는 상태를 세우지 않으므로 반대로 근거 플래그가
없어야 한다.

## 상태 모델과 우선순위

`agent_state(term) ∈ {unknown, running, blocked, idle}`이다. `agent_kind == none`이면 agent DTO 자체를 생략한다.

- **running**: 화면/OSC가 작업 중 UI를 명시하거나, agent foreground에서 PTY output activity가 관측됨.
- **blocked**: 현재 화면이 권한 확인, 선택, 질문 등 사용자 응답을 명시적으로 요구함.
- **idle**: 현재 화면이 새 prompt/input box 등 입력 가능한 agent chrome을 명시적으로 보여 줌.
- **unknown**: agent는 foreground지만 현재 관측값만으로 위 셋을 안전하게 고를 수 없음.

현재 화면의 blocker가 최우선이다. 같은 화면 tail에 idle/running 문구가 함께 있으면 고정 문자열 우선순위가 아니라
**더 아래에 보이는 하단 chrome**을 현재 증거로 택한다. prompt보다 아래의 `Esc to interrupt` footer는 running이고,
과거 footer보다 아래에 새 prompt가 돌아오면 idle이다. 화면 근거가 없을 때만 OSC progress/title, recent PTY activity
순으로 보조한다.

단 “아래=최신”은 provider마다 성립하지 않는다. codex는 실행 표시를 composer **위**에 그리고 그 **아래**에 steering
composer를 계속 열어 둔다(실측). 그래서 codex는 실행 footer 문구를 turn 진행의 단일 discriminator로 쓰고, 입력
프롬프트 규칙의 `none`과 실행 footer 규칙의 `any`가 **같은 문자열을 공유**해 두 규칙이 구성상 상호배타가 되게 한다.
같은 문자열을 쓰는 이유는 근거 공백을 만들지 않기 위함이다 — 한쪽이 좁으면(예: `Working` 단어를 함께 요구) provider가
문구를 바꿀 때 “프롬프트도 아니고 실행도 아닌” 화면이 생겨 판정이 폴백으로 떨어진다.

그 공유 discriminator는 문자열 조합이 아니라 **한 줄의 모양**으로 적는다(실측 `• Working (3s • esc to interrupt)` →
“불릿으로 시작하고 `working`과 `esc to interrupt`를 함께 담은 줄”). 근거는 두 실패를 동시에 막아야 한다는 것이다.

- 화면 전체에서 여러 문구를 `all`로 요구하면 **서로 다른 줄의 조각을 조합**한다. 에이전트가 그 표현을 여러 줄에 걸쳐
  설명하기만 해도 실행 chrome으로 오인된다.
- 반대로 문구를 `esc to interrupt)`처럼 **붙여 써서** 좁히면, footer 뒤에 항목이 하나 붙거나 wrap으로 `)`가 다음 줄로
  밀리는 순간 running 근거가 사라지고 아래 composer가 **근거 있는 idle**을 세운다. 작업 중인 세션이 turn 내내 “대기중”으로
  보이는 쪽이 거짓 running보다 나쁘다.

한 줄 모양으로 지정하면 두 실패가 함께 사라진다. claude에는 이 좁히기가 필요 없다 — claude는 실행 chrome이 프롬프트
박스 **아래**에 오므로 규칙을 `footer` region으로 자르는 편이 더 강하다. 반대로 `screen`으로 두면 사용자가 composer
본문에 그 문구를 타이핑하는 것만으로 위치 tiebreak가 실행 chrome 손을 들어 준다(idle 규칙의 위치는 프롬프트 **라인 시작**
offset이라 본문 안 문구가 늘 더 아래다). 즉 **provider 배치에 맞는 좁히기 수단이 다르다**: claude는 구조 region, codex는
한 줄 모양.

**항상 보이는 chrome 규칙에는 하단 거리 게이트를 걸지 않는다.** 입력 프롬프트와 실행 footer는 화면에 상주하는
chrome이고, 사용자가 여러 줄을 입력하면 그 chrome이 스스로 위로 밀린다. 거리 게이트를 걸면 **입력이 길어질수록 근거가
사라져** 판정이 폴백으로 떨어진다(실측: codex 입력 4행부터 idle 근거 0개 → PTY activity 폴백이 타이핑을 running으로
단정). 거리 게이트는 권한 확인·중단 배너처럼 **일시적 오버레이** 규칙에만 남긴다 — 그 문구는 chrome이 아니라 스크롤되는
출력이라, 위로 밀린 뒤에는 실제로 현재 근거가 아니다. 현재성 판정의 1차 수단은 구조 region(마커 앵커·수평선)과 위치
tiebreak이며, 거리 게이트는 구조 앵커가 없는 오버레이 규칙의 보조 수단이다.

거리 게이트는 **가장 위 근거**를 기준으로 잰다(“근거 전체가 하단 N행 안”). 가장 아래 근거만 재면 조건이 여럿인 규칙이
수십 행 떨어진 조각을 조합해도 통과해, 위쪽 산문과 아래쪽 사용자 입력이 합쳐져 거짓 blocked가 선다. 상한 값은 오버레이의
실측 높이에서 유도한다 — 예컨대 claude 권한 다이얼로그는 옵션 3개일 때 질문이 하단에서 5행이고 옵션마다 1행씩 밀리므로,
상한을 6으로 두면 옵션 4개부터 다이얼로그를 놓친다(«실측 신호 기록»).

이 의미는 **평면 조건과 불리언 게이트에 똑같이 적용된다.** 게이트 규칙이라고 거리 게이트가 면제되지 않는다 —
면제하면 평면 규칙을 게이트로 옮기는 것만으로 오버레이가 현재성을 잃어(위로 밀린 과거 문구가 계속 blocked를
세운다), 데이터에 상한을 적어도 동작하지 않는 함정이 된다. 게이트도 근거 구간의 **가장 위**를 거리 기준으로,
**가장 아래**를 위치 tiebreak 기준으로 쓴다.

명시 증거는 즉시 publish한다. 화면 재그리기의 짧은 공백에는 직전 상태를 최대 700ms 유지하지만, 그 안에 같은 상태의
근거가 다시 오지 않으면 `unknown`으로 내린다. 침묵이나 timeout으로 `idle`을 만들지 않으며, `running`·`blocked`도
무기한 보존하지 않는다. 따라서 느린 작업은 명시 UI/OSC가 없으면 일시적으로 `unknown`일 수 있지만, ESC 뒤 사라진
running 문구가 영구 고착되지는 않는다.

**신호 세기 중재.** 화면·OSC 근거(`visible_idle`/`visible_blocker`/`visible_running`) 없이 나온 상태는 **약한 신호**다.
약한 신호는 근거 있는 직전 상태와 다를 때 그 상태를 즉시 덮지 못하고, 직전 근거의 grace가 만료될 때까지 보류된다.
grace 안에 같은 근거가 다시 오면 약한 신호는 버려지고, 다시 오지 않으면 그때 약한 신호가 최신 근거가 되어 publish된다.
근거 있는 상태가 없을 때(`unknown`)나 약한 신호가 직전 상태와 같을 때는 보류 없이 그대로 반영한다. 현재 약한 신호를
내는 경로는 PTY activity 폴백 하나다. 이 중재가 없으면 타이핑 에코 같은 output이 근거 있는 idle을 곧바로 running으로
덮는다 — 규칙 데이터를 고쳐 근거 공백을 메워도, 폴백이 강한 근거를 이길 수 있는 구조가 남아 있으면 같은 증상이 다른
화면에서 재발한다.

`interrupted`는 새 observer의 상태가 아니다. 터미널은 ESC가 provider의 turn 중단인지 메뉴 닫기인지 일반화해 알 수
없고, provider별 내부 이벤트를 읽지 않는다는 경계와 충돌한다. 대신 중단 후 실제 화면이 idle이면 `idle`, 질문 화면이면
`blocked`, 판정할 수 없으면 `unknown`으로 표시한다. 따라서 `idle`은 더 이상 “턴 완료가 증명됨”을 뜻하지 않고
“현재 입력 가능한 화면이 보임”을 뜻한다.

## agent kind 판정

종류 판정은 foreground process group이 단일 출처다. 화면 문구만으로 claude/codex를 추측하지 않는다.

- process-group leader가 알려진 실행 파일이면 바로 분류한다.
- leader가 node/bun/런처이면 같은 group의 argv/script basename을 확인한다.
- `comm`이 숫자로 시작하는 버전 문자열이면 argv[0] basename을 사용한다.
- tmux/ssh 너머 원격 process tree가 로컬에서 보이지 않으면 kind/state는 `none/unknown`으로 남긴다. OSC title만으로
  agent kind를 승격하지 않는다. **다만 그 Term 의 알림은 산다** — kind 가 `none` 이라 훅 모드가
  안 서고, 그래서 OSC 경로가 그대로 남기 때문이다([agent-hooks.md](agent-hooks.md) §11).

v1 provider allowlist는 현재 UI·브랜드가 있는 claude/codex다. manifest 구조는 provider 추가를 허용하지만 새 종류는
아이콘·상태 fixture·수동 검증을 갖춘 별도 PR로 추가한다.

## 실측 신호 기록

규칙과 우선순위의 근거를 추측이 아니라 실제 캡처로 고정한다. 캡처 절차는 터미널 세션에서 에이전트를 띄운 뒤
렌더 화면(`capture-pane`)·OSC 타이틀(`display-message -p '#{pane_title}'`)·PTY 원시 바이트(`script`)를 각각 기록해
대조하는 것이다. 아래는 그 관측이며 **특정 버전·설정의 결과**다(«한계» 참조).

**claude (2.1.251~2.1.260 관측 — 2026-09-05, 화면 running 문구가 사라졌다)**

- 화면: 진행 중 줄이 `✽ Mulling… ` 이다(스피너 + 동사 + `…`). **`esc to interrupt` 는 화면에 없다** —
  `working_footer` 가 찾던 문구가 통째로 사라졌다.
- 끝나면 같은 자리가 `✻ Worked for 26s · done 오후 3:41 · 1 shell still running` 으로 바뀐다.
  **`…`(U+2026) 유무가 진행/완료를 가른다** — 7 pane × 30 회 관측에서 진행 줄은 **전부** `…` 로 끝났고
  완료 줄에는 **하나도** 없었다.
- 스피너 프레임은 회전한다 — `✻`(U+273B)·`✽`(U+273D) 실측. **prefix 로 고정할 수 없다.**
- 증상: **2026-08-12 와 같은 모양이 다른 원인으로 재발했다.** 그때는 타이틀 스피너 계열이 바뀌어
  `working_title` 이 죽었고, 이번에는 화면 문구가 바뀌어 `working_footer` 가 죽었다. 게다가 tmux 안에서는
  OSC 제목이 흡수되어 **바깥으로 나가지 않으므로**(`set-titles off` 에서 유출 0 — `on` 대조군은 2개,
  pty 캡처로 실증) `working_title` 도 못 뜬다. running 근거가 **하나도** 남지 않고 `live_prompt`(idle) 가
  단독으로 서서, 권위표 C2 가 훅의 running 을 뒤집었다. 앱 로그가 그대로 말한다 —
  `arbitrate running -> idle origin=screen rule=C2 hook=running screen=idle`.
- **레이아웃이 규칙 엔진의 가정을 깬다.** `ruleBetter` 는 「같은 화면의 idle/running 충돌은 더 아래에
  보이는 증거가 이긴다」로 정하는데, claude 는 진행 상태줄을 **입력창 위**에 그린다(스피너 10 행 ·
  프롬프트 13 행). 그래서 running 규칙을 더해도 위치에서 진다.
- 대응: 진행 상태줄을 지목하는 `working_spinner` 규칙을 더하고, 그 규칙에만 **`beats_position`**(위치 비교
  건너뛰기)을 준다. 스피너 prefix + `…` 로 **chrome 자체를 지목**하므로, 대화 출력에 남은 옛 `Working…`
  텍스트는 이 예외를 못 받는다 — 「낡은 footer 아래 새 프롬프트는 idle」 계약이 그대로 산다.
- **읽는 법**: 이 부류가 또 나면 `MARU_DEBUG=1` 로 `arbitrate … screen_rule=…` 을 먼저 본다. 화면이 어느
  규칙으로 그 상태를 냈는지가 거기 있다(계약 §1.7).

**claude (2.1.228 관측 — 2026-08-12, running 타이틀 스피너 계열이 바뀌었다)**

- 타이틀: running **반원 스피너**(관측 프레임 `◐` U+25D0 · `◑` U+25D1 교대) + `<요약>`. 2.1.218의 브라유
  (U+2810·U+2802)와 **교집합이 0**이다.
- 관측 방법: 실행 중 세션의 타이틀을 `maru sessions list`로 직접 읽었다(0.35초 간격 14회 표본 — `◑`×8, `◐`×6).
  앱을 띄우지 않고 제품 관측값을 그대로 보는 경로라, tmux `pane_title` 캡처보다 이 결함의 재현에 직접적이다.
- 증상: `working_title`이 브라유만 보고 있어 running 근거가 통째로 사라지고, composer의 `❯`가 `live_prompt`(idle)로
  이겨 **작업 중 세션이 "대기중"으로** 표시됐다. 사이드바 파형은 `.running`에서만 생성되므로 글리프 자체가
  안 그려졌다(색 문제가 아니었다). 알림은 claude가 보내는 OSC라 이 판정과 무관하게 정상이었다 — 사용자가
  "알림은 오는데 파형만 없다"고 보고한 근거다.
- 조치: `working_title`이 **브라유와 반원 두 계열을 함께** 인정한다(사용자 결정). 어느 버전에서 바뀌었는지는
  특정하지 못했다 — 2.1.226·227·228 바이너리 모두 두 문자를 평문으로 품고 있어 평문 검색으로는 가려지지 않는다.
  구버전 롤백이나 다른 provider가 브라유를 쓰는 경우를 위해 한쪽을 지우지 않는다. codex 타이틀은 이 시점에도
  정상 판정됐으므로(사용자 확인) codex 규칙은 **실측 없이 넓히지 않았다**.

**claude (2.1.218 관측)**

- 타이틀: idle `✳ <요약>`, running 브라유 스피너(관측 프레임 U+2810·U+2802) + `<요약>`.
- 화면: 수평선 사이에 bare `❯` 입력 줄이 있고 그 아래에 사용자 statusLine이 온다(설정에 따라 여러 줄). **작업 중에도
  입력 줄이 그대로 보이며**, 실행 표시는 입력 줄 **위**에 `<기호> <단어>… (Ns …)` 형태로 나타난다. `esc to interrupt`
  문구는 관측되지 않았다.
- 폴더 신뢰 확인 화면: `❯ 1. Yes…` 선택지와 `Enter to confirm · Esc to cancel`.
- **권한 다이얼로그(2.1.x, 100×30 캡처)**: 수평선 아래로 `Bash command` → 명령·설명 → `Do you want to proceed?` →
  `❯ 1. Yes` / `2. Yes, and always allow …` / `3. No` → `Esc to cancel · Tab to amend · ctrl+e to explain`가 온다.
  **이 화면은 composer와 사용자 statusLine을 대체한다** — 다이얼로그 아래에는 아무것도 없고 힌트 줄이 화면 마지막이다.
  따라서 질문의 하단 거리는 옵션 3개일 때 5이고 옵션마다 1씩 늘어난다(거리 상한 유도의 근거).

**claude (2.1.226 추가 관측 — 플랜 승인과 도구별 권한 질문)**

- **플랜 승인 화면**은 위 권한 다이얼로그와 **문구가 다르다**. 안내 줄이 `Claude has written up a plan and is ready to
  execute. Would you like to proceed?`이고(`Do you want to proceed?`가 **아니다**), 선택지는
  `❯ 1. Yes, and use auto mode` / `2. Yes, manually approve edits` / `3. Tell Claude what to change` +
  `shift+tab to approve with this feedback`, 마지막 줄은 `ctrl+g to edit in Vim · ~/.claude/plans/<이름>.md`다.
  **`Esc to cancel`·`Enter to confirm`·`Enter to select` 힌트가 하나도 없다.**
- **권한 다이얼로그의 질문은 도구마다 다르다.** Write 도구는 `Do you want to create hello.txt?`를 쓴다. 고정된 것은
  질문이 아니라 footer 힌트(`Esc to cancel · Tab to amend`)다 — 규칙은 질문이 아니라 이 footer를 앵커로 삼는다.
- **좁은 창에서 안내 문장은 줄바꿈된다.** 72칸 pane 실측에서 `… Would you` / `like to proceed?`로 끊겼고, 하단 힌트도
  `ctrl+g to edit in Vim ·` / `~/.claude/plans/….md` 두 줄이 됐다. 긴 문장 하나만 앵커로 쓰면 좁은 창에서 미스한다.
- 이 화면들에서 OSC 타이틀은 여전히 `✳ <요약>`(idle 근거)이므로, blocker 규칙이 미스하면 `idle_title`이 이겨
  **승인 대기가 유휴로 표시된다**. 실제로 그랬고 `plan_approval`·`permission_footer` 규칙으로 고쳤다.

**codex (0.145.0 관측)**

- 타이틀: idle은 마커 없는 사용자명, running은 브라유 스피너 + 사용자명, blocked는 `[ ! ] Action Required | <이름>`.
- 화면: composer `› …`가 **idle·running 모두** 표시된다. 실행 표시는 `• Working (Ns • esc to interrupt)`,
  중단은 `■ Conversation interrupted - …`, 승인 화면은 `Press enter to confirm or esc to cancel`.

**codex (0.146.0 추가 관측 — composer 배치와 다중 행 입력)**

거리 게이트를 뺀 근거다. 아래는 80×24 tmux pane 캡처 그대로다.

- composer에는 **박스 테두리가 없다.** bare `› <입력>` 한 덩어리이고, 그 아래에 빈 행 1개와 상태줄 1개가 **상수로**
  붙는다(idle: `Context 0% used · weekly 67% left · <모델>`). 즉 프롬프트 마커 아래에 항상 콘텐츠가 있어
  `prompt_anchor`(“마커 아래가 모두 공백”) 정의에 걸리지 않는다 → codex 규칙은 `screen` region을 유지한다.
- 입력이 길어지면 composer가 **여러 행으로 자라며 위로 밀린다.** 마커 기준 하단 거리는 입력 1행에서 2, 2행에서 3,
  **4행에서 5**가 되어 `max_lines_from_bottom = 4`를 넘긴다. 이 순간 codex의 유일한 idle 근거가 사라진다.
- 실행 중 배치는 위에서 아래로 `› <제출한 메시지 에코>` → `• Working (3s • esc to interrupt)` → `› <steering 입력>`
  → 상태줄 `tab to queue message … % context left`다. 즉 **실행 footer가 live composer보다 위**에 있고, 제출한 메시지도
  transcript에 같은 `›` 마커로 에코된다. 그래서 위치 tiebreak만으로는 running을 지킬 수 없고 `esc to interrupt`
  discriminator가 필요하다. 또 이 배치에서 footer의 하단 거리는 6이라, 거리 게이트가 걸려 있으면 **실제 작업 중에도**
  running 근거가 사라진다(반대 방향 결함).
- turn이 끝나면 `• Working …` 행은 화면에서 사라진다(스크롤로 남지 않는다). 따라서 `esc to interrupt` 존재 여부가
  turn 진행 여부와 1:1로 대응한다.

**공통**

- **OSC `9;4`(progress)는 두 provider 모두 emit하지 않았다.** 따라서 `progress_*` 규칙은 현재 두 provider에서 발화하지
  않는다. 표준(ConEmu) 기반 데이터라 존치하되 근거 없는 값으로 오해하지 않도록 여기 기록한다.
- 두 provider 모두 **작업 완료·입력 대기를 자체 데스크톱 알림으로 보낸다.** 예: claude의
  `Claude is waiting for your input`. Maru는 이를 가공 없이 인앱 알림 센터와 OS 배너로 전달한다(제목이 비면 팬 라벨로 채운다).
  **다만 시퀀스와 활성화 조건이 서로 다르다**(2.1.226 / 0.146.1 raw PTY 실측):
  - **claude는 OSC 777**(`notify;<title>;<body>`)을 쓴다. 알림 채널을 `TERM_PROGRAM` 화이트리스트로 **자동 선택**하므로
    사용자 설정 없이 켜진다 — Maru가 `TERM_PROGRAM=ghostty`를 심는 것(`src/pty/macos.zig`)이 이 경로를 여는 조건이다.
    본문으로 종류를 구분한다: 플랜 승인은 `Claude Code needs your approval for the plan`, 도구 권한은
    `Claude needs your permission`. 종결자는 ST가 아니라 **BEL**이다.
  - **codex는 OSC 9**이며 `[tui] notifications`가 **opt-in**이다. 설정이 없는 기본값에서는 승인·플랜 승인 화면이 떠 있어도
    **한 건도 발화하지 않았다**. 켜면 본문에 종류가 접두사로 붙는다: `Approval requested: …`, `Plan mode prompt: …`.
  - 따라서 "두 provider 모두 알림이 온다"는 **codex에 config가 있을 때만** 참이다. observer 주도 알림은 이 비대칭을
    없앤다(provider 설정과 무관하게 화면으로 판정하므로).
  **본문 뒤에는 그 Term의 마지막 대화가 붙는다** — provider 문구만으로는 에이전트를 여럿 돌릴 때 어느 세션인지 알 수
  없기 때문이다. provider 문구 자체는 고치지 않는다. 단일 출처는 [사이드바 에이전트 목록](sidebar-agent-list.md) §7.6.
  즉 **알림 자체는 이미 동작하며**, observer 주도 알림의 목적은 아래 절에 다시 적는다. OS 배너는 별도로 macOS 알림 권한이
  필요하다 — 권한이 없으면 인앱 센터에만 쌓인다.

**멀티플렉서(터미널 다중화) 환경 관측**

에이전트를 멀티플렉서 안에서 실행하면 관측값 세 가지가 **함께** 사라진다.

- **kind**: 멀티플렉서 서버가 에이전트를 자기 프로세스 트리로 가져가므로 pane의 foreground는 멀티플렉서 클라이언트다.
  `agent_kind`가 `none`이 되고, 상태 판정은 kind가 정해진 Term에서만 도는 구조라 **판정 자체가 호출되지 않는다**
  (사이드바에 아무 상태도 뜨지 않는다).
- **OSC 타이틀**: 기본 설정에서 안쪽 타이틀을 바깥 터미널로 전파하지 않는다.
- **provider 알림**: OSC 9 알림도 바깥으로 오지 않는다.

남는 관측값은 멀티플렉서가 렌더한 **화면뿐**이다. 따라서 이 환경을 지원하려면 **프로세스가 보이지 않을 때의 kind 판정
경로가 먼저** 필요하고, 그것 없이는 알림을 포함한 어떤 관측 주도 기능도 동작하지 않는다. 화면만으로 kind를 승격하는 것은
«agent kind 판정»의 경계를 여는 결정이므로 **별도 트랙**으로 둔다.

**로그는 필요한 것보다 많이 담는다 — 그리고 지금은 그게 싼 선택이다** (2026-08-29 실측 — 로그 2.4MB)

훅이 남기는 것은 provider payload **전문**이고, 그중 파서가 쓰는 것은 일부다. **얼마나 일부인지 실제로
쟀다**(이벤트 2,258 건 · 2.26MB).

| | 크기 |
| --- | --- |
| 파서가 **쓰는** 것 | 1,565KB (81%) |
| 안 쓰는 것 | **355KB (19%)** |

**절감 여지가 작다.** 가장 큰 `tool_input.command`(672KB)를 파서가 쓰고, `transcript_path`(283KB)·
`last_assistant_message`(208KB)·`background_tasks`(127KB)도 쓴다. 안 쓰이면서 큰 것은 `cwd`(137KB)·
`tool_use_id`(55KB)·`permission_mode`(40KB) 정도다. 필터링해도 **20% 남짓**(2.26MB → 1.81MB)이라 훅에
프로세스를 늘리거나 사후 재작성 파이프라인을 세울 값에 못 미친다.

**프라이버시도 필터링으로는 못 푼다.** 로그에 개수만 찍고 내용을 안 찍는 규율(§7)이 파일에는 적용되지
않는데, 정작 민감한 것(셸 명령 원문 `tool_input.command`, 대화 내용 `prompt`·`last_assistant_message`)이
**파서가 쓰는 바로 그 필드**다. 줄이려면 다른 축이어야 한다 — 보존 기간을 두어 오래된 파일을 지우거나,
그 값을 쓰는 기능(turn snapshot)이 원문 대신 길이·해시로 충분한지 다시 정하는 것이다.

**그래서 걸러내지 않는다.** 값이 20% 인데 비용은 작지 않다: 훅은 `printf` 한 줄이라 JSON 을 모르고,
필터링하려면 `jq` 같은 파서가 필요한데 그것은 §4.1 이 피한 프로세스다 — 훅은 **도구 호출마다** 실행되므로
(한 세션에서 `PreToolUse` 2,037 건 관측) 하나가 그만큼 곱해진다. 시각도 같은 벽에 부딪히지만(위 ⑴) 그쪽은
**읽는 쪽에서 풀 수 있어서** 풀었고, 필터링은 읽는 쪽에서 풀 수 있는 것이 아니다(이미 디스크에 쓴 뒤다).

필요해지면 선택지는 둘이다. 훅이 `maru` 를 부르게 바꿔 프로세스 비용을 받아들이거나, **읽은 뒤 잘라 다시
쓰는** 방식으로 훅은 그대로 두고 Maru 가 주기적으로 로그를 줄이는 것이다. 후자가 §4.1 을 안 깨면서 디스크와
잔존 내용을 함께 줄인다.

**codex 도 같고, 안전판은 한 겹 더 없다** (2026-08-29 실측 — 이벤트 191 건)

같은 pane 에서 codex 가 남긴 이벤트를 상태 기계로 재생했다. 최종 상태는 `idle` 로 고착이 없었지만,
**`Stop` 없이 새 턴이 열린 횟수가 11 턴 중 3 회**였다. 매번 사용자가 곧 다음 프롬프트를 내서 풀렸을 뿐,
안 냈다면 그때마다 «진행 중» 에 갇혔을 것이다. claude 와 같은 현상이고 빈도는 오히려 높게 관측됐다.

그런데 codex 에는 claude 에 있는 두 완충이 **없다**.

- **`StopFailure` 가 열거에 없다.** claude 는 오류로 끝난 턴을 이 이벤트로 잡지만 codex 는 그 신호 자체가
  없어, 오류 종료도 중단과 똑같이 «아무것도 안 오는» 모양이 된다.
- **턴 키가 안 바뀐다.** claude 는 중단 뒤 새 프롬프트에 새 `prompt_id` 를 실어 «턴 키가 바뀌었으면 새 턴»
  안전판이 걸리는데, 실측에서 codex 는 같은 `turn_id` 를 유지했다. 그 안전판이 이 경우에 발화하지 않는다.

실제 피해는 결국 같다 — `progress.reset()` 이 `user_prompt_submit` 에서 **무조건** 돌기 때문에 턴 키와
무관하게 새 프롬프트가 상태를 푼다. 즉 회복은 이 한 경로에만 걸려 있다.

**이 관측에서 codex 는 자식 이벤트를 한 번도 보내지 않았다.** `SubagentStart`·`SubagentStop` 이 각 0 건이고
`PermissionRequest` 도 0 건이다. 위 «자식 수를 세는 유일한 신뢰 신호… 양 provider 열거에 다 있다» 는 «걸 수
있다» 는 뜻이지 «실제로 온다» 는 보장이 아니다 — 이 구간의 codex 사용에는 서브에이전트가 없었을 수도 있어
부재의 원인까지는 가르지 못했다. 그래서 **codex 의 자식 셈은 아직 실측으로 확인되지 않은 축**으로 남긴다.

codex payload 에도 **시각이 없다**(필드: `session_id`·`transcript_path`·`cwd`·`hook_event_name`·`model`·
`permission_mode`·`turn_id`·`tool_name`·`tool_input`·`tool_use_id`·`prompt`·`stop_hook_active`·
`last_assistant_message`·`source`). 위 시각 공백은 양 provider 공통이다.

**중단된 턴은 «진행 중» 으로 남는다 — 훅 프로토콜에 끝 신호가 없다** (2026-08-28 실측)

사용자가 «끝났는데 사이드바가 진행 중이다» 라고 보고했고, 파 보니 **우리 결함이 아니었다.** 상태 기계는
정확히 동작하고 있었다 — 아는 마지막 사실이 «프롬프트를 냈다» 뿐이었다.

실측 경로는 이랬다. 그 pane 의 이벤트 로그를 상태 기계로 재생하니 `turn_open=true`, 자식 0, 마지막 lead
이벤트가 `UserPromptSubmit` 이었고 **그 뒤로 3 시간 반 동안 이벤트가 0 건**이었다. `PreToolUse` 도
`Stop` 도 `StopFailure` 도 없었다. 이어서 새 세션에서 프롬프트를 낸 직후 Esc 로 중단해 재현했다 — 그
로그의 전부가 `SessionStart` · `UserPromptSubmit` · `UserPromptSubmit` 3 건이고, **종료 이벤트가 하나도
없다.**

원인은 provider 에 **턴 중단 신호가 없다**는 것이다. 설치본(claude 2.1.250) 바이너리에서 훅 이벤트 열거를
직접 읽었고 30 종 중 중단·취소에 해당하는 것이 없다. `SessionEnd` 도 사유가
`clear`·`resume`·`logout`·`prompt_input_exit`·`other` 다섯뿐이라 «턴을 끊었다» 를 담지 못한다. 공식
문서와 열려 있는 이슈([anthropics/claude-code#9516](https://github.com/anthropics/claude-code/issues/9516))도
같은 말을 하며, 그 이슈는 우회책 둘을 **명시적으로 기각**한다 — 타임아웃 방식은 오래 도는 작업에서
오탐이고, `PreToolUse` 하트비트는 소음이다. 관리형 에이전트 이벤트 스트림조차 중단된 턴을
`stop_reason: end_turn` 으로 정상 종료와 **똑같이** 내보낸다.

**`idle_prompt` 로도 못 고친다.** 우리가 이미 받고 있는 `Notification` 중 대다수가 이 종류라 «독립적인
유휴 신호» 로 쓸 수 있어 보였는데, 실측하니 70 건 중 **69 건이 `Stop` 또는 `SubagentStop` 직후**였다.
`Stop` 에 종속된 파생 신호라 `Stop` 이 안 오는 바로 그 상황을 구제하지 못한다. 위 3 시간 반 멈춘 세션에도
오지 않았다.

**그래서 고치지 않는다.** 남은 선택지는 이 문서가 이미 금지한 것들이다 — 시간 만료는 «오래 도는 턴을
조용히 완료로 단정» 이고, 관측 모드를 보조로 얹는 것은 «두 소스를 한 Term 에 섞지 말라»(§1) 를 깬다.
지금 동작은 **틀린 정보를 만들지 않는다**: 아는 것만 말하고, 다음 프롬프트가 오면 `progress.reset()` 이
스스로 푼다. 다른 도구들도 이 벽을 못 넘었다 — `claude-team` 은 중단을 idle 에 합쳐 버리고,
`claude-session-tracker` 는 300 초 간격 추정을 쓴다.

**훅 payload 에 시각이 없다.** 이 조사에서 함께 드러났다. 이벤트가 싣는 것은 `session_id` ·
`transcript_path` · `cwd` · `prompt_id` · `hook_event_name` · `message` · `notification_type` 이 전부이고
**타임스탬프 필드가 없다**. 그래서 사후 추적에서 «이 턴이 언제 열렸나» 를 파일 mtime(=마지막 쓰기)으로만
추정할 수 있고, 그것은 로그 하나의 끝 시각이라 **개별 이벤트의 시각이 아니다**. 위 조사에서도 3 시간 반이라는
숫자는 mtime 에서 나온 것이지 이벤트에서 나온 것이 아니다. 턴 길이 측정, 다른 로그(app.log·크래시 리포트)와의
대조, «얼마나 오래 열려 있었나» 판정이 전부 이 공백에 걸린다.

**메울 자리를 고르는 것이 이 항목의 어려운 부분이다.** 셋을 재 봤다.

⑴ **쓰는 쪽(훅)에서 찍기** — 가장 정확하지만 **공짜가 아니다**. Claude Code 는 훅을 `/bin/sh` 로 돌리고
macOS 의 그것은 **bash 3.2** 라 `EPOCHREALTIME`(bash 5+)도 `printf '%(%s)T'`(bash 4.2+)도 없다. zsh 에는
있지만 zsh 를 띄우는 것 자체가 프로세스다. 남는 것은 `date` 인데 그러면 **훅마다 프로세스가 하나 는다** —
§4.1 이 피한 바로 그 비용이고, 도구 호출마다 실행되므로 배수가 크다.

⑵ **읽는 쪽에서 이벤트마다 «지금» 을 찍기** — **틀린다.** 앱이 꺼져 있던 동안 쌓인 백로그를 나중에 한꺼번에
읽으면 몇 시간 전 일이 전부 «지금» 으로 둔갑한다(이 문서가 backlog 를 따로 다루는 이유와 같은 사고다).
훅이 fire-and-forget 이라 병렬로 도는 것도 읽기 순서를 발생 순서로 못 쓰게 만든다.

⑶ **읽는 쪽에서 «구간» 을 기록하기** — 훅은 그대로 두고, 폴이 바이트를 소비할 때마다 `(offset, 시각)` 한
쌍을 남긴다. 커서가 이미 `offset` 을 추적하므로 새로 만들 상태가 없다. 이러면 **훅 비용이 0** 이고, 정확도는
폴 간격으로 **경계가 지어진다** — 그리고 백로그가 자동으로 갈린다: 첫 기록보다 앞선 구간은 «앱이 없던 시간»
이므로 시각을 주장하지 않으면 된다. ⑵ 가 틀리는 바로 그 지점을 구조로 피한다.

**⑶ 이 맞다.** 얻는 것은 «이 턴이 언제 열렸나» 를 **폴 간격 안에서** 답하는 것이고, 잃는 것은 개별 이벤트의
정밀도다. 오늘 조사에서 필요했던 것(«3 시간 반 열려 있었다» 를 mtime 이 아니라 근거로 말하기)에는 그 해상도로
충분하다. 더 정밀해야 하는 소비자가 생기면 그때 ⑴ 의 비용을 받아들일지 다시 정한다.

**구현은 그중에서도 가장 좁은 형태다.** 오프셋마다 시각을 남기는 일반 지도를 만들지 않고, **턴이 열리는
순간 한 번만** 찍는다(`Term.agent_hook_turn_opened_wall_ns`) — 지금 필요한 질문이 그것 하나이고, 일반 지도는
그 질문에 답하는 데 필요 없는 상태를 늘린다. 턴이 닫히면 0 으로 돌아간다.

**«턴이 열렸다» 는 불리언 경계로 잡으면 안 된다.** 중단 뒤 새 프롬프트가 오면 `reset` 이 턴을 닫았다가 같은
이벤트가 다시 여니 `true → true` 라 경계가 서지 않는다 — **하필 이 값이 가장 필요한 경우**이고, 그때 옛 턴의
시각이 남으면 방금 시작한 턴이 «3 시간 열려 있다» 로 보고된다. 그래서 **턴 정체**(turn key)가 바뀐 것도 새
턴으로 센다. 첫 구현이 이 함정을 밟았고 적대적 검증에서 잡았다.

**backlog 따라잡기 중에는 찍지 않는다.** 그 구간의 턴은 시각을 **주장하지 않고** 0 으로 남는다 — 알림·캡처를
억제하는 것과 같은 자리·같은 근거다. ⑵ 가 틀리는 지점을 이 게이트가 막는다.

**판정에는 쓰지 않는다.** 이 값으로 턴을 닫으면 그것이 곧 ⑵ 의 시간 만료이고, 이 문서가 금지한 «오래 도는
턴을 조용히 완료로 단정» 이다. 쓰이는 곳은 진단 한 줄뿐이다 — `MARU_DEBUG` 에서 열린 지 10 분이 넘은 턴을
`hook turn still open: <ms>` 로 남겨, 사후에 중단으로 끊긴 턴을 mtime 추정 없이 구분하게 한다.

## 규칙 우선순위의 근거

승자 판정은 세 단계다.

1. `visible_blocker`가 다르면 **blocker가 이긴다** — 사용자 조치를 요구하는 화면이 running/idle 신호에 가려지면 안 된다.
   실측 뒷받침: codex 승인 화면은 `› 1. Yes…` 줄이 있어 입력 프롬프트 규칙과 동시에 매치되지만, blocker 우선 규칙 덕에
   blocked로 정확히 판정된다.
2. 둘 다 화면 유래 region이고 위치가 다르면 **더 아래(더 최신 chrome)** 가 이긴다 — 터미널 출력은 아래로 흐른다.
3. 그 외에는 숫자 priority.

숫자 값은 실측 근거가 있는 것과 관례를 물려받은 것을 구분해 둔다.

- **작업 타이틀 > 입력 프롬프트(실측 기반).** 두 provider 모두 작업 중에도 입력 줄이 보여 idle 규칙과 동시 매치된다.
  타이틀 스피너는 작업 중에만 존재하고 중단·완료 즉시 사라져 **판별력이 있는** 반면, 입력 줄은 두 상태에 공통이라
  판별력이 없다. 따라서 충돌하면 스피너가 이긴다.
- **`progress_*`** 는 현재 두 provider가 emit하지 않아 발화하지 않는다. 상대 순서는 검증 대상이 아니다.
- **나머지 관계**(예: idle 타이틀 vs 실행 footer)는 관례를 물려받았고 실측으로 검증되지 않았다. 충돌이 드물어 현재
  영향은 작지만 근거 없는 값임을 숨기지 않는다.

## 사이드바와 알림

> **표시 형태 변경 예정**: 아래 "대표 1개 상태줄"은 [사이드바 에이전트 목록](sidebar-agent-list.md)이 **Term 단위 전수
> 나열**로 대체한다(설계 단계). 이 문서는 그 뒤에도 **상태 판정**(running/blocked/idle/unknown과 그 근거)의 단일
> 출처로 남고, 그 상태를 카드에 **어떻게 배치·표시**하는지는 그 문서가 가져간다. 아래 대표 우선순위 규칙은 목록
> 도입과 함께 표시 목적에서는 쓰이지 않게 된다(목록이 전부를 보여주므로 대표를 고를 필요가 없다).

카드 상태줄은 다음처럼 표시한다.

- `running`: 브랜드색 `▁▅▇▃ 진행중`; pane/Term 탭에는 기존 정적 `●` 플래그
- `blocked`: 경고색 `? 입력 대기`; 애니메이션과 `●` 플래그 없음
- `idle`: `✓ 대기중`; 마지막 답변은 표시하지 않음
- `unknown`: `· 상태 확인 중`; 종류 아이콘은 유지

워크스페이스 카드의 상태는 탭 안 모든 pane/Term을 훑어 `blocked > running > idle > unknown` 순으로 대표한다.
사용자 조치가 필요한 Term을 작업 중 Term보다 먼저 보여 주기 위함이다. 같은 우선순위가 여러 개면 기존 순회 순서를
유지하고, 색은 그 상태를 제공한 Term의 kind를 쓴다.

완료·attention 알림 정책은 아래 «관측 주도 완료·attention 알림»이 단일 출처다. 요지: `→blocked`는 attention 알림을 내고,
`running|blocked → idle`은 **백그라운드 pane**에서 interrupt 화면이 아니고 확인 지연 뒤에도 idle이 유지될 때만 완료 알림을
낸다. 활성·포커스 pane(사용자가 보는 중 — ESC 중단 복귀 포함)은 억제한다. provider가 스스로 보내는 OSC 9/777 알림은
**현재 실제로 동작하는 별도 경로**이며(«실측 신호 기록»), 두 경로가 함께 켜졌을 때의 중복 방지도 위 절이 단일 출처다.

## 컨트롤 플레인 계약

`agent.state` wire 값은 `running | blocked | idle | unknown`이다. `idle` 의미는 “턴 완료”에서 “입력 가능한 agent
화면”으로 바뀐다. `blocked`를 추가하고 `interrupted`는 더 이상 emit하지 않는다. 이 API는 아직 내부 소비 단계이므로
별도 version negotiation을 추가하지 않고 문서·CLI fixture를 함께 갱신한다. 소비자는 알 수 없는 enum을 `unknown`으로
처리해야 한다.

상태 변경 이벤트는 observer가 안정화된 상태를 publish할 때만 발생한다. PTY byte마다 이벤트를 내지 않으며, 같은 상태의
visible blocker는 향후 attention refresh가 필요할 때만 별도 이벤트 정책을 논의한다.

## 화면 region 모델과 규칙 게이트

> 베이스와 결정을 명시한다. 출발점은 하단 N행 평면 tail에 `all/any/none` 평면 조건과 `max_lines_from_bottom` 거리
> 게이트를 걸고, 같은 화면의 idle/running 충돌은 **더 아래(더 최신 chrome)** 위치가 이기는 tiebreak로 푸는 설계였다.
> 거리 게이트는 입력 박스가 상단·하단 테두리에 더해 별도 footer 구분선을 함께 그리거나(다중 수평선), 실행 중에도 아래
> composer가 열릴 때 오판할 수 있다. 그래서 거리 휴리스틱을 **구조적 region**으로 보강하고 평면 조건을 **중첩 게이트**로
> 확장한다. 강점인 위치 tiebreak와 `line_prefix`는 유지한다. 정규식·외부 다운로드는 계속 배제한다(사유는 manifest 절).

거리 게이트는 **상시 chrome 규칙(입력 프롬프트·실행 footer)에서 제거했다.** 사용자 입력이 여러 행이 되면 chrome이
스스로 위로 밀려 근거가 사라지기 때문이다(«상태 모델과 우선순위»·«실측 신호 기록»). 남은 사용처는 권한 확인·중단 배너
같은 일시적 오버레이 규칙이며, 그 규칙들이 오래된 문구를 현재 근거로 끌어오지 않게 막는 역할을 계속 맡는다.

**region 모델이 모든 provider에 맞지는 않는다.** `prompt_anchor`/`box_body`/`footer`는 “프롬프트 아래가 비어 있고 실행
chrome은 프롬프트 밑에 온다”는 박스형 배치를 전제한다. codex 0.146.0은 프롬프트 아래에 상태줄이 상수로 붙고 실행
표시는 프롬프트 **위**에 오므로 이 전제가 깨진다. 따라서 codex 규칙은 `screen` region + `esc to interrupt` discriminator를
쓰고, 구조 region 이관은 claude처럼 배치가 맞는 provider에만 적용한다. 맞지 않는 배치를 억지로 region에 끼우려고 새 휴리스틱을
추가하지 않는다.

**화면 region.** 화면 tail을 평면 하단 N행 대신 순수 문자열 슬라이싱으로 구조 region으로 나눈다(할당·정규식 없음).

- `whole_tail` — 기존 bounded 하단 tail(폴백 기준).
- `prompt_anchor` — 마지막 프롬프트 마커 라인. 마커는 `❯`/`›`이며, 앞의 박스 세로선 `│`와 공백을 벗긴 뒤 판정한다.
  “현재” 프롬프트의 정의는 두 갈래다. 마커가 **박스 상단 테두리 바로 아래 첫 줄**이고 아래에도 닫는 수평선이 있으면
  그 사이는 **박스 본문 = 사용자가 입력 중인 여러 행**이므로 내용이 있어도 잔상 근거가 아니다(실측: claude는 입력
  2행부터 여기에 걸려 idle 근거를 잃었다). 그 밖에는 마커와 **그 아래 첫 수평선 사이**가 모두 공백일 것(수평선이 없으면
  화면 끝까지) — 닫는 테두리가 없는 선택지 목록(`❯ 1. Yes` 아래 항목이 이어짐)과, 출력이 이어지는 잔상 프롬프트가 여기서
  걸러진다. 공백 검사를 **박스 안으로 한정**하는 것이 중요하다: 화면 끝까지 훑으면 박스 아래 상태줄이 비-공백이라, 박스 안
  두 번째 입력 행이 마커로 시작하는 경우(프롬프트 예시를 붙여넣기) 현재 프롬프트를 못 찾고 근거를 통째로 잃는다.
  “상단 바로 아래 첫 줄”을 함께 요구하는 이유는, 그렇지 않으면 잔상 프롬프트와 **에이전트 출력에 흔한 구분선** 하나만으로
  잔상이 현재 프롬프트로 승격되기 때문이다. 어느 갈래든 하단 거리는 보지 않는다.
- `box_body` — 프롬프트 박스 상단 테두리와 그 아래 첫 수평선 사이(사용자가 입력 중인 본문).
- `output` — 프롬프트 마커/박스 위, 첫 수평선 이전(에이전트 출력 영역).
- `footer` — 프롬프트 마커/박스 아래, 마지막 수평선 이후(`esc to interrupt` 등 실행 chrome).
- `title` / `progress` — 기존 OSC title·progress.

앵커 순서는 **프롬프트 마커 우선**, 없으면 수평선 기반, 둘 다 없으면 `whole_tail`로 폴백한다 — 박스를 그리지 않는 화면
(스트리밍 실행·평문 프롬프트·시작 화면)에서도 안전 바닥을 보장하고, 현행 대비 회귀가 없게 한다. 수평선은 `─ ━ ═`와 코너·
정션 문자를 인정해 둥근·이중 테두리 박스도 잡으며, 순수 rule 라인이거나 rule 문자 3개 이상일 때 rule로 본다.

**규칙 게이트.** 규칙은 불리언 게이트다. leaf는 `contains`(대소문자 무시)·`line_prefix`·`line`이고, `all`(AND)·`any`(OR)·`not`(NAND)로
재귀 결합한다. `line`은 **같은 한 줄** 안에서 prefix와 모든 contains를 요구하는 leaf다 — 평면 `contains`는 화면 전체를 훑어
서로 다른 줄의 조각을 조합하므로, chrome 한 줄의 모양을 지정하려면 이 leaf가 필요하다(그 조합이 실제 오탐의 공통 원인이었다). comptime 데이터라 힙이 없고, 규칙 수·중첩 깊이·매처 길이에 상한을 둬 데이터 위생을 강제한다. 기존 평면
`all/any/none`은 이 게이트의 단층 특수형이다.

**`skip_state_update`.** 매치돼도 상태를 바꾸지 않고 직전 상태를 유지하는 규칙. 전이·로딩 중간 화면이 순간적으로 다른
상태로 오판되는 것을 막는다. `state=unknown`·`visible_*` 없음일 때만 허용한다.

**해석.** region별로 게이트를 평가한 뒤 `visible_blocker` 최우선, 그다음 screen region은 위치(더 아래=최신) tiebreak,
마지막으로 priority로 승자를 고른다(기존 판정 순서 유지). 상태 모델(`unknown|running|blocked|idle`)과 안정화(700ms grace)는
불변이다.

## 관측 주도 완료·attention 알림

> **범위 축소(2026-08-20)**: 이 절은 이제 **관측 모드 전용**이다. 훅 모드에서는 훅이 `Stop`(완료)·
> `PermissionRequest`·`Notification`(입력 대기 — 종류로 갈린다, 계약 §6)을 **이미 갈라서** 주므로 아래의 화면 기반 의미 구분이 필요
> 없다 — 이 절이 되살리려던 정보를 provider가 구조화해서 직접 준다. 훅 모드 알림 정책의 단일 출처는
> [에이전트 훅 통합](agent-hooks.md) §6이고, 이 절은 훅이 없는 Term에서만 적용한다.
>
> 다만 아래의 **억제·중복 방지 판단**(보고 있는 pane에는 울리지 않기, 같은 사건을 한 번만)은 모드와 무관하게
> 필요하므로 훅 모드도 같은 정책을 쓴다.

> **전제를 실측으로 바로잡는다.** 이 절의 이전 서술은 "완료 알림이 없으니 observer가 새로 만든다"였으나, «실측 신호
> 기록»대로 **두 provider 모두 자체 데스크톱 알림을 OSC로 보내고 Maru가 이미 전달하고 있다.** 따라서 observer 주도 알림은
> 없던 기능을 만드는 것이 아니라 다음 네 가지를 개선하는 것이다.
>
> 1. **의미 구분** — provider 알림은 턴 종료와 권한 요구를 같은 "입력 대기"류 문구로 뭉쳐 보낸다. observer는 이미
>    `idle`과 `blocked`를 구분하므로 완료와 입력 대기를 **다른 알림으로** 낼 수 있다.
> 2. **억제 정책** — 보고 있는 pane에는 울리지 않는다. provider 알림에는 이 판단 근거가 없다.
> 3. **중단 구분** — ESC 중단 뒤 돌아온 프롬프트를 완료로 치지 않는다.
> 4. **도달 범위** — 멀티플렉서 환경에서는 provider 알림이 Maru까지 **오지 않는 것으로 관측됐다**(«실측 신호 기록»).
>    다만 그 환경은 `agent_kind`도 함께 사라져 상태 판정 자체가 돌지 않으므로, **이 이점은 kind 판정 경로가 먼저 생긴 뒤에야
>    실현된다.** 이 절의 알림만 구현해서는 멀티플렉서 환경이 개선되지 않는다.
>
> **중복 방지가 설계 항목이다.** provider 알림과 observer 알림이 함께 켜지면 같은 사건에 두 번 울린다. 기본은 기존
> `notifications.osc`로 provider pass-through를 끄고 observer 알림만 쓰는 것이며, 두 경로를 함께 켜는 경우의 억제 규칙은
> 구현 PR에서 fixture와 함께 확정한다.

**attention 알림 — `→ blocked` 전이.** 현재 화면이 권한 확인·선택·질문을 명시할 때만 blocked이므로 ESC 모호성이 없다.
활성·포커스 pane은 배너를 억제한다(사용자가 이미 그 화면을 보는 중).

**완료 알림 — `running | blocked → idle` 전이.** 다음을 **모두** 만족할 때만 낸다.

1. 대상 pane이 **활성·창 포커스가 아님**(백그라운드). 활성·포커스면 사용자가 보는 중이라 억제한다 — 사용자가 ESC로
   중단한 직후의 idle 복귀도 이 조건으로 함께 걸러진다.
2. idle 근거가 **interrupt 화면이 아님**. interrupt 판정 rule id로 온 idle은 완료로 치지 않는다.
3. **확인 지연** 뒤에도 상태가 여전히 `idle`이고 agent kind가 그대로임. 안정화의 evidence grace를 재사용해 순간적인 화면
   재그리기 튐을 거른다.

`idle`은 여전히 "입력 가능한 화면"을 뜻하고 **완료는 전이에서 파생**한다. 새 wire 상태(`done`)를 만들지 않으므로 컨트롤
플레인 계약(`running|blocked|idle|unknown`)은 불변이다. 전달은 기존 인앱 알림 센터·데스크톱 알림 경로를 재사용하고, 제목은
위치 라벨(탭 › 팬)과 상태를 조립한다. 워크스페이스 카드 대표 상태(`blocked > running > idle > unknown`)도 불변이다.

**config**(단일 출처는 [config 스키마](config-schema.md), 동작 정의는 이 문서 — 키는 알림 PR에서 스키마·사용자 문서에 동기):

> **아직 구현되지 않았다.** 아래 세 키는 §[화면 region·알림 구현 분해](#화면-region알림-구현-분해)의 **4단계(알림 PR)**
> 에서 배선할 **계획**이다. 지금 config 파일에 적으면 loader가 `알 수 없는 key — 무시` 진단을 내고 값은 반영되지 않는다
> (앱 로그에 `config line N: 알 수 없는 key — 무시`로 보인다). 특히 `notifications.agent-complete`는 **예전에 존재했다가
> 제거된 이름**이라(`refactor(session): provider 세션 연속성 잔여를 제거합니다`) 로더가 "제거된 호환 설정"으로 함께
> 취급한다 — 4단계에서 다시 도입할 때 그 제거 목록에서 빼야 한다.

- `notifications.agent-complete` (`true|false`, 기본 `true`) — 백그라운드 완료 알림 on/off. **(미구현 — 4단계)**
- `notifications.agent-attention` (`true|false`, 기본 `true`) — `→blocked` attention 알림 on/off. **(미구현 — 4단계)**
- `notifications.agent-complete-delay-ms` (정수, 기본 = evidence grace) — 완료 확인 지연. **(미구현 — 4단계)**

## 화면 region·알림 구현 분해

1. **문서 PR**: 이 절(«화면 region 모델»·«관측 주도 완료·attention 알림»)과 config 스키마·control-plane 문서를 먼저 맞춘다.
2. **region·게이트 엔진 PR**: OS-중립 순수 코어에 region 슬라이서·게이트 평가·`skip_state_update`를 추가하고 헤드리스
   red→green fixture로 못박는다. 기존 `detect()` 호환을 유지한다.
3. **규칙 이관 PR**: claude/codex 규칙을 구조적 region(마커 앵커·`footer`·`box_body`)으로 재작성한다. 기존 observer
   fixture가 그대로 green이고, 다중 테두리·박스 없음·steering composer 엣지 fixture를 추가한다.
4. **알림 PR**: 전이 분류기(억제·interrupt 제외·확인 지연)·config·전달 배선. 헤드리스 분류기 단위 + 전이 통합 테스트.
   config 3키는 아직 로더에 없으므로(위 §config 경고) 이 단계에서 `loader.zig`의 "제거된 호환 설정" 목록에서
   `notifications.agent-complete`를 빼고 스키마·`docs/configuration.md`에 함께 등재한다.

원격 process tree가 안 보이는 환경(멀티플렉서·SSH 원격)의 화면 시그니처 기반 kind 폴백은 **이 이니셔티브 범위 밖의 별도
트랙**이다(정책 전환·오탐 트레이드오프 필요). 아래 «한계» 참조.

## 과거 source build 훅 수동 정리

P1 이후 Maru는 provider **hook event**를 설치하지 않고 과거 mapping 파일을 읽거나 신뢰하지 않는다(현재 쓰는 상태줄
경로는 위 «사이드바 대화 표시와의 경계»가 별도 계약이다). 과거 source build/dev 버전이 설치한 훅은 provider가 계속
실행할 수 있으므로 필요할 때만 아래 경계로 수동 정리한다.

- provider config에서 `MARU_AGENT_MAP_HOOK_V2` 또는 `MARU_PANE_MAP_HOOK` marker를 찾는다.
- marker만으로 지우지 않는다. 같은 command가 `agent-sessions`, `cat`, pane/mapping selector를 함께 포함하는 **그 hook group만**
  제거한다. 다른 사용자 hook이나 config 파일 전체를 삭제하지 않는다.
- mapping은 Maru config 아래 `agent-sessions`의 숫자 파일 가운데 알려진 hook event와 `session_id` 또는
  `transcript_path` payload가 함께 있는 파일만 개별 확인해 제거한다. 디렉터리를 통째로 삭제하지 않는다.
- Maru는 이 정리를 자동 수행하거나 완료 marker/backup을 만들지 않는다. 확신할 수 없는 항목은 그대로 둔다.

구 workspace의 provider scalar는 일반 미지 scalar와 같이 건너뛰며, 새 저장에서는 나오지 않는다. 복원은 해당 Term의
정상 `shell_entry`, cwd, layout만 연다. 삭제된 설정 이름은 일반 unknown key 진단 대상이다.

## 성능과 관측 가능성

- screen snapshot은 변경 sequence가 바뀐 Term만 읽고 idle 안정 상태에서는 재스캔을 건너뛴다. trailing blank 행은
  최대 256행 cell scan으로만 건너뛰며 실제 UTF-8 복사는 마지막 콘텐츠 기준 bounded 행에 한정한다. 그보다 큰 blank
  padding은 오래된 화면 근거를 끌어오지 않고 `unknown`으로 안전하게 실패한다.
- screen tail은 행·바이트 상한을 함께 둔다. 행 상한은 상시 chrome이 tail 안에 남도록 화면 높이급으로 잡고, **바이트 상한은
  그 행 상한을 잘라먹지 않을 만큼** 크게 잡는다 — 직렬화가 `max_bytes / (cols*4 + 1)`로 행 수를 다시 계산하므로, 바이트
  상한이 작으면 넓은 창에서 행 상한이 조용히 무력화된다(행 수를 늘려 놓고도 옛 한계가 되살아난다). worst-case 가정일 뿐이고
  실제 복사량은 화면 내용만큼이며, idle 안정 상태에서는 재스캔 자체를 건너뛰므로 상시 비용이 되지 않는다.
- process probe는 foreground pgid 변화 시 즉시, 식별된 agent는 낮은 주기로 재확인한다.
- debug event는 kind, 이전/새 상태, 선택된 manifest rule id, visible flags, activity age만 남긴다. 화면 텍스트·OSC 원문·
  cwd·argv 전체는 로그에 남기지 않는다.
- observer domain snapshot을 사이드바, control plane, 테스트가 함께 소비한다. UI별 판정 로직을 만들지 않는다.

## 구현 분해

1. **문서 PR**: 이 계약과 workspace/control-plane/sidebar/notification 정책을 먼저 일치시킨다.
2. **observer PR**: OS-중립 manifest matcher·상태 안정화·fixture, Term runtime 배선, 사이드바/control-plane 상태를 구현한다.
3. **migration PR(P1 완료)**: transcript/hook/session-fork 호환 코드와 자동 cleanup을 제거하고 일반 unknown-scalar
   read-old/write-new 경계를 고정한다.

## 검증

- 순수 fixture: claude/codex 각각 idle/running/blocked, scrollback의 과거 blocker 무시, OSC-only 보조, 상충 신호 우선순위.
- 전이 테스트: output activity→running, visible idle 즉시 전환, evidence loss 700ms grace 뒤 unknown, process exit/kind change reset.
- 다중 행 입력(실측 캡처): codex composer 입력이 1·2·4행일 때 모두 `visible_idle` 근거가 유지되고, output이 흐르는
  동안에도 PTY activity 폴백으로 떨어지지 않음(타이핑이 running으로 보이지 않는다).
- tail 행 상한: 입력이 12행을 넘는 composer에서도 프롬프트 마커가 tail 안에 남는지(옛 12행 상한의 회귀 방지). **좁은 창과
  넓은 창을 함께** 확인한다 — 직렬화가 byte 상한을 cols worst-case로 나눠 행 수를 다시 줄이므로, 한 폭만 보면 상한이 조용히
  무력화된 것을 놓친다.
- 좁히기 수단: composer 본문에 실행 문구를 타이핑해도 idle이 유지되는지(claude, `footer` region), footer 뒤에 항목이 붙거나
  산문이 그 문구를 인용해도 각각 running·idle이 맞는지(codex, 한 줄 모양 게이트), 서로 다른 줄의 조각이 조합돼 blocked가
  되지 않는지(거리 게이트가 가장 위 근거를 재는지), 박스 안 두 번째 입력 행이 마커로 시작해도 프롬프트를 찾는지.
- 오버레이 현재성: 실측 권한 다이얼로그가 옵션 3개·5개에서 모두 blocked이고, 이미 승인이 끝난 오래된 승인 문구가 idle
  근거를 지우지 않는지.
- 실행 중 steering(실측 배치: 메시지 에코 → `• Working (… esc to interrupt)` → steering composer → 상태줄): output이
  조용해도 `visible_running` 근거로 running이 유지됨(폴백에 의존하지 않는다).
- 신호 세기 중재: 근거 있는 idle 직후의 약한 running(PTY activity)은 grace 안에는 idle을 덮지 못하고, 같은 근거가 다시
  오면 계속 idle, grace가 만료되면 running으로 반영됨. 근거 있는 상태가 없거나 약한 신호가 직전 상태와 같으면 즉시 반영.
- ESC 회귀: running 화면에서 ESC 뒤 idle fixture가 오면 다음 publish가 running이 아니며 완료 알림도 생성하지 않음.
- 다중 Term: background blocked가 workspace 대표가 되고, running Term의 탭 플래그와 dirty gate가 정확히 갱신됨.
- region 슬라이서: prompt 마커 앵커가 다중 수평선(box 상·하단 + footer 구분선)에서 footer/output을 정확히 분리, 둥근·이중
  테두리 인식, box 없는 화면(스트리밍·평문 프롬프트)에서 `whole_tail` 폴백.
- 게이트: `all`/`any`/`not` 중첩 평가, `skip_state_update`가 매치 시 직전 상태 보존.
- 알림 전이: `→blocked`=attention, 백그라운드 `running|blocked→idle`=완료, 활성·포커스 pane과 interrupt 화면은 억제,
  확인 지연 중 상태가 바뀌면 완료 취소.
- migration: `AppSession.init` 전후 provider config/mapping bytes와 디렉터리 manifest 불변, cleanup 파일·호출·전용 env filter 부재.
- workspace: 옛 provider scalar parse 성공+무시, 새 저장에 필드 없음, 멀티윈도우 cwd/layout/active round-trip 불변.
- 수동 E2E: 실제 claude/codex에서 prompt, 작업, 권한 질문, ESC 중단, pane/Term 전환을 반복해 카드와 control 상태 확인.

## 한계

**훅 모드의 상한은 provider 가 정한다.** 중단된 턴은 종료 이벤트를 하나도 남기지 않아 다음 프롬프트가 올
때까지 «진행 중» 으로 남고, 훅 payload 에 시각이 없어 «얼마나 오래 열려 있었나» 도 알 수 없다. 둘 다 우리가
고칠 수 있는 자리가 아니며 근거와 기각한 우회책은 «실측 신호 기록» 에 적었다.

provider가 UI 문구·OSC를 바꾸면 manifest fixture 갱신이 필요하다. 텍스트 기반 판정은 false positive/negative가 가능하므로
모호할 때는 `unknown`으로 실패한다.

terminal observer 하나로 provider 내부 완료 의미, 마지막 답변, 정확한 session id를 동시에 얻을 수 없다는 제한을 제품
계약으로 숨기지 않는다.

codex의 실행 footer discriminator는 결국 텍스트 모양이므로, 에이전트가 **그 줄을 자기 불릿 항목으로 그대로 출력**하면
여전히 오판한다(문장 안 인용은 불릿 요구가 걸러 낸다). tail 행 상한 안에 있어야 하므로 범위는 제한된다. 구조 region으로
좁히는 것이 정답이지만 codex 배치가 region 전제를 만족하지 않아(«화면 region 모델») 한 줄 모양으로 좁힌다. 반대로 provider가
footer 문구를 바꾸면 running 근거를 잃고 PTY activity 폴백으로 degrade된다 — 이 선택의 근거는 «상태 모델과 우선순위»에 적었다.

claude 쪽 `footer` region도 사용자 statusLine을 포함한다(구조상 박스 아래가 footer다). statusLine에 실행 문구가 들어 있으면
running으로 오판하지만, 그건 사용자가 자기 상태줄에 그 문구를 넣은 경우뿐이다.

에이전트가 **두 수평선 사이에 프롬프트 예시를 인쇄**하면 그 줄이 현재 프롬프트로 승격될 수 있다. 이는 구조 판정의 성질이고
이 변경으로 새로 생긴 것이 아니다(이전 계약도 같은 화면을 프롬프트로 봤다). 실제로는 그 아래에 진짜 composer가 있으면 더
아래 마커가 선택되므로 영향이 없다.

박스 본문을 사용자 입력으로 인정하면서, **박스 안에 그려지는 선택 메뉴**(예: 모델·effort 선택)도 입력 프롬프트로 잡힌다.
blocker 문구가 있는 화면은 blocker 우선 규칙이 그대로 이기므로 권한 확인은 영향받지 않지만, blocker 문구가 없는 메뉴는
`unknown`이 아니라 `idle`로 표시된다. 사용자가 조작 가능한 화면이라는 점에서 `idle`(“입력 가능한 화면”)의 정의에 어긋나지
않아 그대로 둔다.

tail 행 상한도 유한하므로, composer가 상한보다 더 크게 자라면(화면 대부분을 입력으로 채우는 경우) 프롬프트 마커가 다시
tail을 벗어나 근거가 사라진다. 그때는 폴백으로 degrade되며, 이 구조적 상한은 없앨 수 없다 — 상한을 화면 높이급으로 둬
현실적인 입력 길이를 덮는 것이 대응이다.

«실측 신호 기록»은 claude 2.1.218·codex 0.145.0/0.146.0을 특정 설정에서 관측한 결과다. provider가 UI 문구·스피너 프레임·상태줄
구성을 바꾸면 규칙과 기록을 함께 갱신해야 한다. 멀티플렉서 환경은 실제로 확인했고 결과는 «실측 신호 기록»에 적었다 —
kind·타이틀·provider 알림이 함께 사라져 **상태 판정 자체가 동작하지 않는다.** 이 환경의 지원은 kind 판정 경로가 선행
조건이며 별도 트랙이다.

kind 판정은 foreground 프로세스가 단일 출처이므로, 원격 process tree가 로컬에서 안 보이는 환경(멀티플렉서를 거친 원격
세션 등)에서는 kind가 `none/unknown`으로 남아 관측 주도 판정·알림이 동작하지 않는다. 화면만으로 kind를 승격하는 폴백은
이 이니셔티브 범위 밖의 **별도 트랙**이다(정책 전환·오탐 트레이드오프 필요). region 슬라이싱은 박스를 그리지 않는 화면에서
`prompt_anchor`/`whole_tail`로 폴백하고, resize 뒤 남는 trailing blank padding은 tail 위치 계산에서 계속 제외한다. 완료·attention
알림은 새 코드 경로이므로 헤드리스 fixture로 red→green TDD하고, 실제 claude/codex에서 백그라운드 완료·활성 억제·ESC 중단·
권한 질문 전이를 수동 E2E로 확인한다.
