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
`agent`, `state`, `all/any/none` 문자열 조건, 화면 하단 거리, `visible_idle`, `visible_blocker`, `visible_running` 메타만 표현한다.
정규식·임의 코드 실행·외부 다운로드는 v1에 넣지 않는다. 빌드에 포함된 manifest만 사용하며 fixture가 근거다.

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

## 사이드바와 알림

카드 상태줄은 다음처럼 표시한다.

- `running`: 브랜드색 `▁▅▇▃ 진행중`; pane/Term 탭에는 기존 정적 `●` 플래그
- `blocked`: 경고색 `? 입력 대기`; 애니메이션과 `●` 플래그 없음
- `idle`: `✓ 대기중`; 마지막 답변은 표시하지 않음
- `unknown`: `· 상태 확인 중`; 종류 아이콘은 유지

워크스페이스 카드의 상태는 탭 안 모든 pane/Term을 훑어 `blocked > running > idle > unknown` 순으로 대표한다.
사용자 조치가 필요한 Term을 작업 중 Term보다 먼저 보여 주기 위함이다. 같은 우선순위가 여러 개면 기존 순회 순서를
유지하고, 색은 그 상태를 제공한 Term의 kind를 쓴다.

완료 알림은 `running → idle`만으로 보내지 않는다. 새 `idle`은 완료뿐 아니라 ESC 중단 뒤 prompt 복귀도 포함하므로
그 전이를 완료로 해석하면 가짜 알림이 된다. 구조화된 완료 신호가 없는 v1에서는 agent 완료 알림을 제공하지 않는다.
OSC 9/777 알림은 별개로 유지한다.

## 컨트롤 플레인 계약

`agent.state` wire 값은 `running | blocked | idle | unknown`이다. `idle` 의미는 “턴 완료”에서 “입력 가능한 agent
화면”으로 바뀐다. `blocked`를 추가하고 `interrupted`는 더 이상 emit하지 않는다. 이 API는 아직 내부 소비 단계이므로
별도 version negotiation을 추가하지 않고 문서·CLI fixture를 함께 갱신한다. 소비자는 알 수 없는 enum을 `unknown`으로
처리해야 한다.

상태 변경 이벤트는 observer가 안정화된 상태를 publish할 때만 발생한다. PTY byte마다 이벤트를 내지 않으며, 같은 상태의
visible blocker는 향후 attention refresh가 필요할 때만 별도 이벤트 정책을 논의한다.

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
- migration: `AppSession.init` 전후 provider config/mapping bytes와 디렉터리 manifest 불변, cleanup 파일·호출·전용 env filter 부재.
- workspace: 옛 provider scalar parse 성공+무시, 새 저장에 필드 없음, 멀티윈도우 cwd/layout/active round-trip 불변.
- 수동 E2E: 실제 claude/codex에서 prompt, 작업, 권한 질문, ESC 중단, pane/Term 전환을 반복해 카드와 control 상태 확인.

## 한계

provider가 UI 문구·OSC를 바꾸면 manifest fixture 갱신이 필요하다. 텍스트 기반 판정은 false positive/negative가 가능하므로
모호할 때는 `unknown`으로 실패한다. terminal observer 하나로 provider 내부 완료 의미, 마지막 답변, 정확한 session id를
동시에 얻을 수 없다는 제한을 제품 계약으로 숨기지 않는다.
