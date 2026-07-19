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

## 관측 입력

Term별 observer는 다음 입력을 함께 사용한다.

1. **foreground process group**: 실행 파일과 process tree로 agent kind를 판정한다. claude가 `comm`을 버전 문자열로
   바꾸거나 node/bun 래퍼 아래 실행되는 경우 argv/process tree를 확인한다. agent process가 사라지면 상태도 즉시
   `unknown`으로 리셋한다.
2. **live screen tail**: 현재 viewport의 마지막 bounded 행을 공백 정규화해 provider별 manifest와 매칭한다.
   scrollback 전체를 읽지 않으며 현재 화면에 없는 과거 문구는 상태 근거로 쓰지 않는다.
3. **OSC metadata**: 터미널 코어가 이미 파싱한 title과 progress를 문자열 입력으로 제공한다. progress는
   [ConEmu specific OSC](https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC)가 정의한
   OSC `9;4;state[;progress]` 본문을 bounded 문자열로 보존한 값이다. 기존처럼 알림으로 발사하지 않고 observer의
   보조 입력으로만 쓴다. OSC는 agent가 실제로 보낸 값일 때만 신호이며 Maru가 provider 훅을 주입해 만들지 않는다.
4. **PTY output activity**: agent가 foreground인 동안 새 output이 지속되면 `running` 근거다. 다만 출력이 잠시
   멈췄다는 사실만으로 `idle`로 내리지 않는다. 느린 API·긴 도구 실행은 조용할 수 있기 때문이다.

screen/OSC/provider 패턴은 코드에 하드코딩된 거대한 switch 대신 작은 manifest 데이터로 둔다. manifest는
`agent`, `state`, `all/any/none` 문자열 조건, `visible_idle`, `visible_blocker`, `visible_running` 메타만 표현한다.
정규식·임의 코드 실행·외부 다운로드는 v1에 넣지 않는다. 빌드에 포함된 manifest만 사용하며 fixture가 근거다.

## 상태 모델과 우선순위

`agent_state(term) ∈ {unknown, running, blocked, idle}`이다. `agent_kind == none`이면 agent DTO 자체를 생략한다.

- **running**: 화면/OSC가 작업 중 UI를 명시하거나, agent foreground에서 PTY output activity가 관측됨.
- **blocked**: 현재 화면이 권한 확인, 선택, 질문 등 사용자 응답을 명시적으로 요구함.
- **idle**: 현재 화면이 새 prompt/input box 등 입력 가능한 agent chrome을 명시적으로 보여 줌.
- **unknown**: agent는 foreground지만 현재 관측값만으로 위 셋을 안전하게 고를 수 없음.

우선순위는 `visible blocker > visible idle > visible running > recent PTY activity > previous stable state > unknown`이다.
화면의 명시 신호가 활동 추정보다 우선하므로 ESC로 작업을 끊고 prompt가 돌아오면 과거 output activity가 남아 있어도
즉시 `idle`이 된다. blocked 화면도 PTY가 잠깐 출력한 직후 `running`에 묻히지 않는다.

명시 화면 신호가 없는 `running → idle` 추정은 100ms 간격 3회 확인하되 700ms를 넘기지 않는다. 이는 화면 갱신
중간 프레임을 idle로 오인하는 것을 줄이기 위한 안정화이며, 명시 `visible_idle`은 지연하지 않는다. 입력 box가 보이는
idle과 권한 prompt인 blocked는 현재 화면 신호이므로 timeout 추정으로 만들지 않는다.

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
그 전이를 완료로 해석하면 가짜 알림이 된다. 구조화된 완료 신호가 없는 v1에서는 `notifications.agent-complete`를
deprecated no-op으로 두고 UI/설정에서 제거한다. OSC 9/777 알림은 별개로 유지한다.

## 컨트롤 플레인 계약

`agent.state` wire 값은 `running | blocked | idle | unknown`이다. `idle` 의미는 “턴 완료”에서 “입력 가능한 agent
화면”으로 바뀐다. `blocked`를 추가하고 `interrupted`는 더 이상 emit하지 않는다. 이 API는 아직 내부 소비 단계이므로
별도 version negotiation을 추가하지 않고 문서·CLI fixture를 함께 갱신한다. 소비자는 알 수 없는 enum을 `unknown`으로
처리해야 한다.

상태 변경 이벤트는 observer가 안정화된 상태를 publish할 때만 발생한다. PTY byte마다 이벤트를 내지 않으며, 같은 상태의
visible blocker는 향후 attention refresh가 필요할 때만 별도 이벤트 정책을 논의한다.

## 마이그레이션과 하위호환

### provider 훅 정리

업데이트 후 첫 시작에서 과거 Maru marker가 있는 claude/codex user config를 **한 번만 자동 정리**한다.

- Maru가 만든 marker와 command만 제거하고 같은 배열의 사용자 hook 순서와 나머지 JSON은 보존한다.
- 파싱 실패, 권한 오류, 4MiB 초과 파일은 무접촉하고 구조화 로그만 남긴다.
- 변경 전 `.maru-backup`을 만들며 기존 백업을 덮어쓰지 않는다.
- cleanup 완료 여부는 Maru config/runtime marker로 기록한다. 실패는 다음 시작에 재시도한다.
- 기존 `Re-register/Unregister Agent Session Hooks` command와 action/config 문법은 제거한다.
- `<config>/maru/agent-sessions/` 잔여 mapping은 민감하지 않은 Maru 생성물이며, cleanup 성공 뒤 Maru marker 형식 파일만
  정리한다. 디렉터리 전체를 무조건 삭제하지 않는다.

### workspace restore

기존 workspace의 `agent_kind`, `agent_session`, `agent_argv` 필드는 **읽을 수는 있지만 무시**한다. 복원은 해당 Term의
정상 `shell_entry`와 cwd만 연다. 새 workspace 저장에는 이 세 필드를 쓰지 않는다(read-old/write-new). 이 방식은 오래된
workspace 파일을 깨뜨리지 않으면서 provider 세션 자동 실행을 제거하고, 한 번 새로 저장하면 private session id와 argv가
자연스럽게 사라지게 한다. `workspace.restore-claude`와 `workspace.restore-codex` 설정은 deprecated no-op으로 한 릴리스
읽은 뒤 제거 대상으로 두되, UI에서는 즉시 숨긴다.

## 성능과 관측 가능성

- screen snapshot은 변경 sequence가 바뀐 Term만 읽고 idle 안정 상태에서는 재스캔을 건너뛴다.
- screen tail은 행·바이트 상한을 두고, 매 poll heap 전체 화면 복사를 피한다.
- process probe는 foreground pgid 변화 시 즉시, 식별된 agent는 낮은 주기로 재확인한다.
- debug event는 kind, 이전/새 상태, 선택된 manifest rule id, visible flags, activity age만 남긴다. 화면 텍스트·OSC 원문·
  cwd·argv 전체는 로그에 남기지 않는다.
- observer domain snapshot을 사이드바, control plane, 테스트가 함께 소비한다. UI별 판정 로직을 만들지 않는다.

## 구현 분해

1. **문서 PR**: 이 계약과 workspace/control-plane/sidebar/notification 정책을 먼저 일치시킨다.
2. **observer PR**: OS-중립 manifest matcher·상태 안정화·fixture, Term runtime 배선, 사이드바/control-plane 상태를 구현한다.
3. **migration PR**: transcript/hook/session-fork 코드를 제거하고, 1회 hook cleanup과 workspace read-old/write-new를 구현한다.

## 검증

- 순수 fixture: claude/codex 각각 idle/running/blocked, scrollback의 과거 blocker 무시, OSC-only 보조, 상충 신호 우선순위.
- 전이 테스트: output activity→running, visible idle 즉시 전환, plain idle 3회 확인/700ms cap, process exit/kind change reset.
- ESC 회귀: running 화면에서 ESC 뒤 idle fixture가 오면 다음 publish가 running이 아니며 완료 알림도 생성하지 않음.
- 다중 Term: background blocked가 workspace 대표가 되고, running Term의 탭 플래그와 dirty gate가 정확히 갱신됨.
- migration: 사용자 hook 보존·Maru marker만 제거·parse/read 실패 무접촉·재시도·백업 no-clobber.
- workspace: 옛 agent 필드 parse 성공+무시, 새 저장에 필드 없음, cwd/shell/일반 layout round-trip 불변.
- 수동 E2E: 실제 claude/codex에서 prompt, 작업, 권한 질문, ESC 중단, pane/Term 전환을 반복해 카드와 control 상태 확인.

## 한계

provider가 UI 문구·OSC를 바꾸면 manifest fixture 갱신이 필요하다. 텍스트 기반 판정은 false positive/negative가 가능하므로
모호할 때는 `unknown`으로 실패한다. terminal observer 하나로 provider 내부 완료 의미, 마지막 답변, 정확한 session id를
동시에 얻을 수 없다는 제한을 제품 계약으로 숨기지 않는다.
