# 에이전트 상태 감지(터미널 관측)

> 단일 출처(design). Maru는 터미널에서 실행되는 대화형 에이전트의 종류와 상태를 **터미널이 이미 소유한
> 관측값만으로** 판정한다. 사용자 홈의 provider 설정을 수정하거나 세션 트랜스크립트를 읽지 않는다.

## 목표와 비목표

목표는 claude/codex가 어느 Term에서 실행 중인지, 작업 중인지, 사용자 입력을 기다리는지, 입력 가능한 idle
화면인지 사이드바와 컨트롤 플레인에 표시하는 것이다. 에이전트 TUI는 기존처럼 PTY foreground에서 그대로 실행된다.

다음은 의도적으로 제공하지 않는다.

- provider 훅 설치·신뢰·매핑과 트랜스크립트 JSONL 해석
- 마지막 답변 미리보기
- provider session id를 저장하거나 자동 resume/fork하는 workspace restore
- 에이전트 내부 단계, tool call, API 대기 원인을 정확히 복원하는 기능

터미널 밖의 private 상태를 읽지 않는 대신 설치가 필요 없고, 같은 cwd의 여러 세션·중첩 프로세스·provider 포맷
변경에 결합되지 않는다. 상태는 **화면에 드러난 사용자 관점**이며 provider 내부 상태의 증명은 아니다.

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
3. **OSC metadata**: 터미널 코어가 이미 파싱한 title과 progress를 문자열 입력으로 제공한다. progress는
   [ConEmu specific OSC](https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC)가 정의한
   OSC `9;4;state[;progress]` 본문을 bounded 문자열로 보존한 값이다. 기존처럼 알림으로 발사하지 않고 observer의
   보조 입력으로만 쓴다. OSC는 agent가 실제로 보낸 값일 때만 신호이며 Maru가 provider 훅을 주입해 만들지 않는다.
4. **PTY output activity**: agent가 foreground인 동안 새 output이 지속되면 `running` 근거다. 다만 출력이 잠시
   멈췄다는 사실만으로 `idle`로 내리지 않는다. 느린 API·긴 도구 실행은 조용할 수 있기 때문이다.

screen/OSC/provider 패턴은 코드에 하드코딩된 거대한 switch 대신 작은 manifest 데이터로 둔다. manifest는
`agent`, `state`, 화면 region(아래 «화면 region 모델과 규칙 게이트» 참조), 불리언 게이트(`all`/`any`/`not`·`contains`/`line_prefix`),
`skip_state_update`, `visible_idle`, `visible_blocker`, `visible_running` 메타를 표현한다. 정규식·임의 코드 실행·외부 다운로드는
넣지 않는다 — 선형 정규식 엔진이 없어 손수 짠 패턴은 catastrophic backtracking 위험이 있고, 원격 규칙은 서명 없는 신뢰가
되기 때문이다. 빌드에 포함된 manifest만 사용하며 fixture가 근거다.

## 상태 모델과 우선순위

`agent_state(term) ∈ {unknown, running, blocked, idle}`이다. `agent_kind == none`이면 agent DTO 자체를 생략한다.

- **running**: 화면/OSC가 작업 중 UI를 명시하거나, agent foreground에서 PTY output activity가 관측됨.
- **blocked**: 현재 화면이 권한 확인, 선택, 질문 등 사용자 응답을 명시적으로 요구함.
- **idle**: 현재 화면이 새 prompt/input box 등 입력 가능한 agent chrome을 명시적으로 보여 줌.
- **unknown**: agent는 foreground지만 현재 관측값만으로 위 셋을 안전하게 고를 수 없음.

현재 화면의 blocker가 최우선이다. 같은 화면 tail에 idle/running 문구가 함께 있으면 고정 문자열 우선순위가 아니라
**더 아래에 보이는 하단 chrome**을 현재 증거로 택한다. prompt보다 아래의 `Esc to interrupt` footer는 running이고,
과거 footer보다 아래에 새 prompt가 돌아오면 idle이다. 화면 규칙은 provider별 하단 4~6줄 안에서만 유효하므로 tail 위쪽의
과거 prompt나 `Conversation interrupted` 문구는 새 작업 상태를 덮지 않는다. 화면 근거가 없을 때만 OSC progress/title,
recent PTY activity 순으로 보조한다.

명시 증거는 즉시 publish한다. 화면 재그리기의 짧은 공백에는 직전 상태를 최대 700ms 유지하지만, 그 안에 같은 상태의
근거가 다시 오지 않으면 `unknown`으로 내린다. 침묵이나 timeout으로 `idle`을 만들지 않으며, `running`·`blocked`도
무기한 보존하지 않는다. 따라서 느린 작업은 명시 UI/OSC가 없으면 일시적으로 `unknown`일 수 있지만, ESC 뒤 사라진
running 문구가 영구 고착되지는 않는다.

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
  agent kind를 승격하지 않는다.

v1 provider allowlist는 현재 UI·브랜드가 있는 claude/codex다. manifest 구조는 provider 추가를 허용하지만 새 종류는
아이콘·상태 fixture·수동 검증을 갖춘 별도 PR로 추가한다.

## 실측 신호 기록

규칙과 우선순위의 근거를 추측이 아니라 실제 캡처로 고정한다. 캡처 절차는 터미널 세션에서 에이전트를 띄운 뒤
렌더 화면(`capture-pane`)·OSC 타이틀(`display-message -p '#{pane_title}'`)·PTY 원시 바이트(`script`)를 각각 기록해
대조하는 것이다. 아래는 그 관측이며 **특정 버전·설정의 결과**다(«한계» 참조).

**claude (2.1.218 관측)**

- 타이틀: idle `✳ <요약>`, running 브라유 스피너(관측 프레임 U+2810·U+2802) + `<요약>`.
- 화면: 수평선 사이에 bare `❯` 입력 줄이 있고 그 아래에 사용자 statusLine이 온다(설정에 따라 여러 줄). **작업 중에도
  입력 줄이 그대로 보이며**, 실행 표시는 입력 줄 **위**에 `<기호> <단어>… (Ns …)` 형태로 나타난다. `esc to interrupt`
  문구는 관측되지 않았다.
- 폴더 신뢰 확인 화면: `❯ 1. Yes…` 선택지와 `Enter to confirm · Esc to cancel`.

**codex (0.145.0 관측)**

- 타이틀: idle은 마커 없는 사용자명, running은 브라유 스피너 + 사용자명, blocked는 `[ ! ] Action Required | <이름>`.
- 화면: composer `› …`가 **idle·running 모두** 표시된다. 실행 표시는 `• Working (Ns • esc to interrupt)`,
  중단은 `■ Conversation interrupted - …`, 승인 화면은 `Press enter to confirm or esc to cancel`.

**공통**

- **OSC `9;4`(progress)는 두 provider 모두 emit하지 않았다.** 따라서 `progress_*` 규칙은 현재 두 provider에서 발화하지
  않는다. 표준(ConEmu) 기반 데이터라 존치하되 근거 없는 값으로 오해하지 않도록 여기 기록한다.
- 두 provider 모두 **작업 완료·입력 대기를 자체 데스크톱 알림(OSC 9 본문)으로 보낸다.** 예: claude의
  `Claude is waiting for your input`. Maru는 이를 가공 없이 인앱 알림 센터와 OS 배너로 전달한다(제목이 비면 팬 라벨로 채운다).
  즉 **알림 자체는 이미 동작하며**, observer 주도 알림의 목적은 아래 절에 다시 적는다.

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

> 베이스와 결정을 명시한다. 현재 규칙은 하단 N행 평면 tail에 `all/any/none` 평면 조건과 `max_lines_from_bottom` 거리
> 게이트를 걸고, 같은 화면의 idle/running 충돌은 **더 아래(더 최신 chrome)** 위치가 이기는 tiebreak로 푼다. 거리 게이트는
> 입력 박스가 상단·하단 테두리에 더해 별도 footer 구분선을 함께 그리거나(다중 수평선), 실행 중에도 아래 composer가 열릴
> 때 오판할 수 있다. 그래서 거리 휴리스틱을 **구조적 region**으로 보강하고 평면 조건을 **중첩 게이트**로 확장한다. 강점인
> 위치 tiebreak와 `line_prefix`는 유지한다. 정규식·외부 다운로드는 계속 배제한다(사유는 manifest 절).

**화면 region.** 화면 tail을 평면 하단 N행 대신 순수 문자열 슬라이싱으로 구조 region으로 나눈다(할당·정규식 없음).

- `whole_tail` — 기존 bounded 하단 tail(폴백 기준).
- `prompt_anchor` — 마지막 프롬프트 마커 라인. 마커는 `❯`/`›`이며, 앞의 박스 세로선 `│`와 공백을 벗긴 뒤 판정한다.
- `box_body` — 프롬프트 박스 상단 테두리와 그 아래 첫 수평선 사이(사용자가 입력 중인 본문).
- `output` — 프롬프트 마커/박스 위, 첫 수평선 이전(에이전트 출력 영역).
- `footer` — 프롬프트 마커/박스 아래, 마지막 수평선 이후(`esc to interrupt` 등 실행 chrome).
- `title` / `progress` — 기존 OSC title·progress.

앵커 순서는 **프롬프트 마커 우선**, 없으면 수평선 기반, 둘 다 없으면 `whole_tail`로 폴백한다 — 박스를 그리지 않는 화면
(스트리밍 실행·평문 프롬프트·시작 화면)에서도 안전 바닥을 보장하고, 현행 대비 회귀가 없게 한다. 수평선은 `─ ━ ═`와 코너·
정션 문자를 인정해 둥근·이중 테두리 박스도 잡으며, 순수 rule 라인이거나 rule 문자 3개 이상일 때 rule로 본다.

**규칙 게이트.** 규칙은 불리언 게이트다. leaf는 `contains`(대소문자 무시)와 `line_prefix`이고, `all`(AND)·`any`(OR)·`not`(NAND)로
재귀 결합한다. comptime 데이터라 힙이 없고, 규칙 수·중첩 깊이·매처 길이에 상한을 둬 데이터 위생을 강제한다. 기존 평면
`all/any/none`은 이 게이트의 단층 특수형이다.

**`skip_state_update`.** 매치돼도 상태를 바꾸지 않고 직전 상태를 유지하는 규칙. 전이·로딩 중간 화면이 순간적으로 다른
상태로 오판되는 것을 막는다. `state=unknown`·`visible_*` 없음일 때만 허용한다.

**해석.** region별로 게이트를 평가한 뒤 `visible_blocker` 최우선, 그다음 screen region은 위치(더 아래=최신) tiebreak,
마지막으로 priority로 승자를 고른다(기존 판정 순서 유지). 상태 모델(`unknown|running|blocked|idle`)과 안정화(700ms grace)는
불변이다.

## 관측 주도 완료·attention 알림

> **전제를 실측으로 바로잡는다.** 이 절의 이전 서술은 "완료 알림이 없으니 observer가 새로 만든다"였으나, «실측 신호
> 기록»대로 **두 provider 모두 자체 데스크톱 알림을 OSC로 보내고 Maru가 이미 전달하고 있다.** 따라서 observer 주도 알림은
> 없던 기능을 만드는 것이 아니라 다음 네 가지를 개선하는 것이다.
>
> 1. **의미 구분** — provider 알림은 턴 종료와 권한 요구를 같은 "입력 대기"류 문구로 뭉쳐 보낸다. observer는 이미
>    `idle`과 `blocked`를 구분하므로 완료와 입력 대기를 **다른 알림으로** 낼 수 있다.
> 2. **억제 정책** — 보고 있는 pane에는 울리지 않는다. provider 알림에는 이 판단 근거가 없다.
> 3. **중단 구분** — ESC 중단 뒤 돌아온 프롬프트를 완료로 치지 않는다.
> 4. **도달 범위** — OSC가 그대로 전달되지 않는 경로(멀티플렉서를 거친 원격 세션 등)에서는 provider 알림이 Maru까지 오지
>    않을 수 있다. 화면 관측 기반이면 그 경로에서도 동작한다. 단 이 경로의 실제 도달 여부는 아직 측정하지 않았다(«한계»).
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

- `notifications.agent-complete` (`true|false`, 기본 `true`) — 백그라운드 완료 알림 on/off.
- `notifications.agent-attention` (`true|false`, 기본 `true`) — `→blocked` attention 알림 on/off.
- `notifications.agent-complete-delay-ms` (정수, 기본 = evidence grace) — 완료 확인 지연.

## 화면 region·알림 구현 분해

1. **문서 PR**: 이 절(«화면 region 모델»·«관측 주도 완료·attention 알림»)과 config 스키마·control-plane 문서를 먼저 맞춘다.
2. **region·게이트 엔진 PR**: OS-중립 순수 코어에 region 슬라이서·게이트 평가·`skip_state_update`를 추가하고 헤드리스
   red→green fixture로 못박는다. 기존 `detect()` 호환을 유지한다.
3. **규칙 이관 PR**: claude/codex 규칙을 구조적 region(마커 앵커·`footer`·`box_body`)으로 재작성한다. 기존 observer
   fixture가 그대로 green이고, 다중 테두리·박스 없음·steering composer 엣지 fixture를 추가한다.
4. **알림 PR**: 전이 분류기(억제·interrupt 제외·확인 지연)·config·전달 배선. 헤드리스 분류기 단위 + 전이 통합 테스트.

원격 process tree가 안 보이는 환경(멀티플렉서·SSH 원격)의 화면 시그니처 기반 kind 폴백은 **이 이니셔티브 범위 밖의 별도
트랙**이다(정책 전환·오탐 트레이드오프 필요). 아래 «한계» 참조.

## 과거 source build 훅 수동 정리

P1 이후 Maru는 provider config나 mapping 파일을 읽거나 신뢰하거나 수정하지 않는다. 과거 source build/dev 버전이 설치한
훅은 provider가 계속 실행할 수 있으므로 필요할 때만 아래 경계로 수동 정리한다.

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
- screen tail은 행·바이트 상한을 두고, 매 poll heap 전체 화면 복사를 피한다.
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

provider가 UI 문구·OSC를 바꾸면 manifest fixture 갱신이 필요하다. 텍스트 기반 판정은 false positive/negative가 가능하므로
모호할 때는 `unknown`으로 실패한다. terminal observer 하나로 provider 내부 완료 의미, 마지막 답변, 정확한 session id를
동시에 얻을 수 없다는 제한을 제품 계약으로 숨기지 않는다.

«실측 신호 기록»은 claude 2.1.218·codex 0.145.0을 특정 설정에서 관측한 결과다. provider가 UI 문구·스피너 프레임·상태줄
구성을 바꾸면 규칙과 기록을 함께 갱신해야 한다. 아직 측정하지 않은 것도 명시해 둔다 — **멀티플렉서를 거친 원격 세션에서
provider의 OSC 알림이 Maru까지 도달하는지**는 확인하지 않았다. observer 주도 알림의 "도달 범위" 이점은 그 측정 뒤에야
확정된다.

kind 판정은 foreground 프로세스가 단일 출처이므로, 원격 process tree가 로컬에서 안 보이는 환경(멀티플렉서를 거친 원격
세션 등)에서는 kind가 `none/unknown`으로 남아 관측 주도 판정·알림이 동작하지 않는다. 화면만으로 kind를 승격하는 폴백은
이 이니셔티브 범위 밖의 **별도 트랙**이다(정책 전환·오탐 트레이드오프 필요). region 슬라이싱은 박스를 그리지 않는 화면에서
`prompt_anchor`/`whole_tail`로 폴백하고, resize 뒤 남는 trailing blank padding은 tail 위치 계산에서 계속 제외한다. 완료·attention
알림은 새 코드 경로이므로 헤드리스 fixture로 red→green TDD하고, 실제 claude/codex에서 백그라운드 완료·활성 억제·ESC 중단·
권한 질문 전이를 수동 E2E로 확인한다.
