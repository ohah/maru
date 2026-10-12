# SSH 원격 에이전트 native 로그 활성화

## 상태와 논의할 결정

2026-10-12 사용자 요청에 따른 doc-first 설계다. 사용자는 기존 세션을 유지하는 점진 이행을 선택했다. 로컬 native 기본 선택과
원격 v2 재접속 namespace 수정은 구현됐다. 이 문서는 원격 기본 활성화는 아래 게이트로 검증 중이다. 기존 프로세스는 v1을 유지하고 새 프로세스만 준비 상태에 따라 v2를
선택한다는 목표는 같지만, 기존 단일 채널 전략을 유지하는 A안으로 구현한다.

현행 `RemoteAgentHost`는 목적지당 하나의 stream/profile/cursor 집합을 가진다.
`spawnStreamerFor`는 한 profile의 디렉터리만 읽는다. 기존 v1 프로세스가 있는 서버에서
새 v2 프로세스를 시작하면 두 namespace가 동시에 살아 있으므로 reader 하나의 profile을
바꾸는 것으로는 목표를 충족할 수 없다. 실행 중인 프로세스 환경을 변경하거나 두 파일의
본문을 합쳐 해결하지 않는다.

[원격 상태 계획 RA4](remote-agent-state.md#ra4--원격-스트리머-maru-agent-events---stdio)는
서버당 SSH 스트리머 채널 하나를 유지해 `MaxSessions` 예산을 보존한다.
[필수 프로젝트 규칙](../project-rules.md#전략-유지)에 따라 이 전략을 변경한다면 먼저
사용자와 논의한다. 비교한 두 안 중 A안을 사용하며 B안은 선택하지 않는다.

| 안 | 기존 세션 보존 | SSH 채널 예산 | wire/구현 비용 |
| --- | --- | --- | --- |
| A: 한 프로세스가 v1/v2를 함께 읽는 혼합 스트리머 (권장 초안) | 둘 다 읽고 profile별 커서를 유지 | 목적지당 하나 유지 | 명시적 새 capability와 혼합 wire 계약 필요 |
| B: 이행 중 profile별 스트리머 두 개 | 각자 기존 wire로 읽음 | 혼합 서버에서는 둘, 재시도·정리도 둘 | v1/v2 wire 유지, host 수명/라우팅/예산 전략 변경 필요 |

A는 기존의 단일 채널 전략을 유지하지만 기존 v2 hello를 혼합 지원으로 오인하지 않도록
별도 capability를 요구한다. B를 선택하면 채널 예산 증가를 문서와 검증에 반영하고,
구형 프로세스·tmux·다른 앱이 남길 수 있는 v1 기록을 무시해 임의로 채널을 닫지 않는다.

## 준비 판정과 프로세스 수명

1. `maru ssh`의 eligible 대화형 연결에서, 같은 ControlMaster 위의 bounded 준비 명령이
   원격 CLI 지원·private namespace 준비·provider 설치 명령의 정합성을 확인한다.
   `--terminfo-only`와 사용자 지정 원격 명령의 실행 의미는 바꾸지 않는다.
2. CLI가 없거나 구버전이면 선택 전에는 기존 v1을 유지한다. native를 명시적으로 선택한
   요청과 이미 확정된 v2 재접속은 구버전 때문에 v1으로 내리지 않고 실패를 드러낸다.
3. 준비 결과는 설치 성공과 native 지원을 구분한다. 현재 `parseOutcome`의 문자열 prefix
   매칭은 capability 인증으로 쓰지 않는다. bounded strict JSON, duplicate/type/version/
   provider 검증 및 두 provider의 결과를 검사한다. malformed 출력과 실패한 앞 provider를
   성공한 뒤 provider의 출력으로 덮지 않는다.
4. 실제 SSH 환경 전달을 확인한다. `LC_MARU_LOG_FORMAT`을 프로세스 시작 전에 고정한다.
   로컬 `MARU_AGENT_LOG_FORMAT`이나 부모의 원격 format 값만으로 선택하지 않는다.
   서버가 AcceptEnv를 거부하거나 기존 ControlMaster가 이 env를 전달하지 못하면,
   준비 단계에서 v1을 유지하며 이미 시작한 프로세스를 전환하지 않는다.
5. ControlMaster 생성 때부터 format의 SendEnv 허용 목록을 유지한다. pane 값이 없어서
   생성된 master를 나중에 GUI pane이 재사용하는 경우도 검사한다. 옵션을 추가한다고 이미
   떠 있는 master의 허용 목록이 바뀐다고 가정하지 않는다.
6. 준비 왕복과 GUI의 설치/reader 시작 사이의 경합을 닫는다. 셸의 첫 훅이 reader보다 먼저
   실행돼도 같은 private namespace에 남아 나중에 소비되어야 한다. 준비가 아직 안 된 GUI가
   이미 v2인 SSH 세션을 v1 reader에 붙이지 않는다.
7. 기존 tmux 서버와 Codex 공유 daemon은 생성 당시 환경을 유지할 수 있다. 새 연결의 format을
   이 프로세스들에 강제로 덮어쓰지 않는다. 혼합 reader로 v1 이벤트를 계속 소비하고,
   모든 원격 provider가 v2가 됐다고 표시하지 않는다.

## 혼합 reader 계약 — 구현 wire 계약

- 각 cursor의 identity는 `(profile, name)`이다. 같은 이름의 v1 offset과 v2 generation을
  하나의 map entry로 합치지 않는다. 파일 헤더로 profile을 추측하지 않는다.
- v2는 generation과 payload offset을 그대로 보존하고 v1은 기존 offset 계약을 유지한다.
  재접속·앱 재시작·이름 재사용·세대 교체를 각각 검증한다.
- A를 선택하면 기존 v1/v2 hello와 명령 옵션은 유지하고 새 혼합 모드를 명시적으로 협상한다.
  이벤트 payload는 opaque로 유지한다. 각 frame의 profile과 cursor/resume 문법·수신 상한·
  EOF/rotation 처리·공정한 읽기 예산은 구현 전에 wire 문서로 확정한다. 기존 v2 peer가
  혼합 모드를 지원한다고 추측하지 않는다.
- B를 선택하면 두 stream의 hello, pending tail, cursor, retry budget, 종료를 독립시킨다.
  단일 Term에 중복 알림·턴 캡처가 생기지 않도록 이벤트 수신은 기존 귀속 경로를 공유한다.
- profile 추가를 이유로 기존 cursor/argv/읽기 메모리 상한을 조용히 배로 늘리지 않는다.
  상한·eviction·resume 실패 시 보존 정책은 공통 codec과 comptime 검사로 연결한다.
- native read/rotation은 같은 stable lock과 generation/EOF 재검사를 사용한다.
  stdout 배압 동안 provider 기록기를 잠그지 않으며 v1 입력 때문에 v2가 굶지 않게 한다.

## 계획 공격과 대응

| 공격 | 결함 | 필요한 판정자 |
| --- | --- | --- |
| 설치 명령만 바꾸고 env를 안 보냄 | 훅은 계속 v1, v2 reader에는 이벤트 없음 | 실제 SSH 자식 env와 파일 namespace 대조 |
| v2 CLI hello만 확인해 기본 전환 | 기존 v1 이벤트를 놓침 | 같은 서버의 v1/v2 동시 기록·수신 |
| 부모 local format=2 또는 악성 remote env | 준비 없이 native 선택 | env override/중복·빈 값 및 CLI 없음 negative control |
| 이전 master가 새 SendEnv를 무시 | 세션 env는 v1인데 GUI는 v2로 판단 | format 옵션 없는 master 재사용 실물 SSH |
| AcceptEnv 차단·ForceCommand·MOTD/가짜 JSON | 준비 성공 오인 또는 무한 대기 | 제한 서버·strict parser·출력/시간 상한 |
| 설치 첫 provider 실패, 둘째 성공 | 불완전한 이행을 성공 처리 | 각 provider 실패·중복/누락 결과·exit 판정 |
| 같은 파일명에 v1/v2 cursor 존재 | offset/gen 교차 적용으로 누락/재생 | profile별 이름 충돌·최대 resume·OOM 보존 |
| 스트림 재시작 직전 native 파일 교체 | 이전 offset으로 새 로그 일부 건너뜀 | 같은/더 큰 payload의 세대 교체와 실제 재접속 |
| 구형 tmux/daemon에 새 세션 attach | 남은 v1 이벤트 누락 | 기존 서버/daemon 유지와 새 프로세스 공존 |
| 한 profile의 폭주/배압/lock 충돌 | 다른 profile 굶김 또는 provider 지연 | bounded fairness·동시 기록·stdout 배압 |
| 경로 symlink/다른 UID/CLI 교체 | 잘못된 디렉터리 기록 또는 신뢰 핑퐁 | held handle 인증·실제 CLI 경로·교체/삭제 |
| 준비 뒤 disconnect/앱 restore | 다시 선택해 실행 중 format 변경 | 프로세스 pinning과 재협상 시 downgrade 거부 |

## 구현 순서와 완료 게이트

1. 혼합 수신 방식(A안)과 wire/capability·준비 결과 계약 문서화 → parser/예산의 실패
   fixture부터 구현한다. 구버전과 malformed 입력은 구분한다.
2. 원격 CLI의 설치/준비 판정과 SSH 환경 pinning을 연결한다. 사용자 설정을 만지지 않는
   합성 provider HOME에서 제품 설치 명령·신뢰 hash·멱등성을 검사한다.
3. 선택한 혼합 reader를 제품 GUI 귀속·배지·턴 캡처·resume 경로까지 연결한다.
4. loopback sshd의 별도 키·control socket·config로 실제 SSH를 검증한다. 새로 생성한 master,
   구형 master, AcceptEnv 차단, 구 CLI, 재접속, 동시 v1/v2와 기존 tmux를 포함한다.
5. 설치된 Claude/Codex로 합성 읽기 전용 턴을 실행해 원격 훅 → 실제 SSH → 제품 reader →
   배지 상태와 봉인된 턴 캡처를 확인한다. provider 버전과 정확한 빌드 snapshot을 기록한다.
6. 방어 조건을 제거하는 변형과 독립 argv/file oracle로 계획 공격이 검출되는지 검사한다.
   필수 CI/제품 빌드가 통과하기 전에는 완료로 표시하지 않는다.

사용자 SSH 설정·로그인 정보·실제 provider 설정은 하네스에서 수정하지 않는다. 원문·환경·
인증 정보는 git에 남기지 않는다. Windows native ACL, peer ACK와 crash fsync durability는
이 작업의 완료 범위가 아니다. GUI 시각 출력 변경이 있으면 제품 렌더 경로에서 별도 캡처한다.

## 현재 재현과 준비 수정

- 현재 main(cfd207f4c)에서 빌드한 제품 CLI로 같은 이름의 v1/v2 파일을 만들고 각
  스트리머를 실행했다. 각각 자기 namespace의 이벤트만 전달했고 다른 포맷의 이벤트는
  전달하지 않았다. 기본 profile 변경만으로 두 프로세스를 보존할 수 없음을 재현했다.
- 설치 응답 parser가 version 11, 손상된 JSON, 잘못된 타입과 중복 필드를 성공으로
  받아들이는 문제와 첫 provider의 changed=true가 둘째 changed=false로 덮이는 문제를
  실패 fixture로 재현했다. generic 설치 결과를 bounded strict JSON으로 해석하고
  changed를 OR로 합산하도록 수정했다. 이는 native 준비 완료를 증명하는 capability
  응답 자체가 아니며, 두 provider의 준비 attestation은 선택한 이행 단계에서 추가한다.
- loopback sshd에서 별도 키와 control socket을 사용해 확인했다. 사용자 SSH 설정을
  제외하고 pane env만 허용한 기존 master는 새 client가 format SendEnv를 추가해도
  format을 보내지 않았다. format을 허용한 새 master에서는 세션마다 1과 2를 각각 받았다.
  서버 AcceptEnv에서 format을 제외하면 새 master에서도 값이 전달되지 않았다.
  사용자 설정의 SendEnv LC_*가 있는 master에서는 결과가 달라질 수 있으므로,
  master 생성 옵션과 실제 원격 수신값을 함께 검사해야 한다.
- 사용자는 v2 직접 마이그레이션 가능 여부를 질문했다. 파일의 데이터 이관과 살아 있는
  프로세스의 format 전환을 구분한다. 무중단이면 기존 v1 기록을 계속 읽으며 새 프로세스부터
  v2로 이행한다. v2 전용으로 즉시 전환하려면 관련 원격 셸·tmux·daemon 재시작이 필요하다.
  사용자는 점진 이행을 선택했다. 실제 원격 프로세스를 강제로 종료하지 않는다.

## A안 wire 계약

혼합 모드는 `--log-format=mixed`, hello는 `{"hello":"maru-agent-events-mixed","v":3}`다.
`--dir`은 remote 두 namespace를 담는 `.cache/maru`다. v1/v2 명령과 wire는 유지한다.
각 데이터 프레임은 canonical envelope `{"format":1,"frame":<기존 프레임>}` 또는
`{"format":2,"frame":<기존 프레임>}`로 싣는다. inner JSON의 구조를 검사하되 payload는
해석하지 않는다. format은 고정 숫자 1/2이며 envelope에 다른 top-level 필드를 허용하지 않는다.
resume는 `1:<이름>:<offset>` 또는 `2:<이름>:<offset>:<generation>`이며 같은 profile/name
중복을 거부한다. 총 cursor 상한은 계속 32개이고 prefix의 추가 바이트만 예산에 반영한다.
기존 v2 hello는 이 모드의 지원 증거가 아니다. 읽기 lease를 풀고 각 envelope를 실제 stdout에
flush한 뒤에만 cursor/rotation을 진행한다. 두 profile은 각 tick에 번갈아 소비한다.

## 구현 중 확인한 문제와 수정

- 준비 호출이 format만 보내고 pane 신원을 누락해 false readiness가 됐다. 두 값 모두
  같은 SSH 세션에서 명시적으로 보내며 신원이 없는 native 준비는 허용하지 않는다.
- 다중화 SSH가 FIFO를 열어 둬 두 응답이 와도 EOF를 기다리다 실패했다. 명시적인
  완료 표식으로 bounded 준비 packet을 마감한다. 크기/시간 상한과 owned child 회수를 유지한다.
- GUI의 기존 v1 host cache가 원격 CLI 업그레이드를 모르고 계속 한 포맷만 읽을 수 있었다.
  예약 control 로그는 재검증 힌트만 전달하고, 실제 두 provider 준비 확인 후 이전 pipe를
  소비하고 profile별 커서를 원자적으로 바꾼다. provider 파일에 표식을 끼워 넣지 않는다.
- GUI 지원 capability와 가변 훅 설정을 구분했다. 실행 중인 runtime의 버전 flag를 훅 On/Off로
  오인하지 않고 CLI가 시작 때 현재 config도 읽는다. 설치 응답의 JSON 오류와 changed 합산
  문제도 함께 수정했다.

실물 loopback SSH에서는 현재 peer의 기존 capability=0 프로세스가 v1, 새 capability=3
프로세스가 v2를 선택했고 같은 mixed 채널이 두 기록을 전달했다. AcceptEnv 차단,
훅 비활성화와 cfd207f4c에서 빌드한 구 peer는 계속 v1이었다. 이 결과는 실제 설치 명령에
합성 provider payload를 넣은 검증이며 설치된 Claude/Codex 모델 턴 결과와 구분한다.

설치된 Claude Code 2.1.296와 Codex CLI 0.162.1도 loopback SSH의 합성 읽기 전용 턴을
완료했다. 실제 mixed 프레임을 제품 AppSession에 재생해 nonce 귀속, idle 배지,
턴 종료와 remote capture 봉인을 확인했다. 이 검증은 화면 PNG나 OS 배너 검증은 아니다.
