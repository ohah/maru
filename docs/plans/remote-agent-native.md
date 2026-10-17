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

## SSH 스트림 재접속 검증 계획

동일 이름의 v1/v2 로그를 실제 SSH로 받은 뒤, 수신한 profile별 cursor를 저장한다.
하네스가 소유한 ControlMaster를 종료해 연결을 끊고, 단절 중 설치된 훅으로 두 포맷의
새 턴을 기록한다. 새 SSH 연결에 저장한 resume를 전달하여 이전 턴 재생이 없고 새 턴 이벤트가
각각 한 번 전달되는지 독립 session_id 목록으로 판정한다. 재접속 원문 wire를 제품
AppSession에 재생하여 최종 idle 배지와 remote capture 봉인을 확인한다.
이는 GUI 재시도 스케줄러나 터미널 셸 wrapper 자체의 자동 재접속을 입증하지 않는다.
ACK 없는 전송 도중 종료에서 exactly-once를 보장한다고 주장하지 않는다.

실행 결과: live mixed 스트림이 붙은 소유 ControlMaster 종료를 실제 비정상 SSH 종료로
확인했다. 단절 중 설치된 Claude 훅에 합성 시작·도구 전후·종료 이벤트를 넣어 v1/v2에
각각 기록했고, 새 연결에서 8개 이벤트를 각각 한 번 수신했다. 이전 턴은 재생되지 않았다.
재접속 wire의 제품 AppSession 재생은 idle 배지·원격 캡처 봉인 검사를 통과했다.
합성 transcript 경로는 귀속 식별자이며 실제 provider transcript 파일을 읽은 증거가 아니다.
resume를 제거한 결함 대조군에서는 이전 턴이 재생되어 판정자가 실패했다.

## 제품 자동 재접속 검증 계획

실제 CLI wrapper를 reconnect=true로 실행하고 소유 SSH master를 끊는다. wrapper가
스스로 두 번째 연결을 열며 준비 호출을 반복하지 않고 포맷을 유지하는지 검사한다.
GUI는 제품 AppSession의 drain·재시도 예약·spawnStreamerFor를 실제 SSH 자식에 연결한다.
EOF 전후 cursor와 재기동 시점·새 hello·배지·캡처를 확인한다. 하네스가 재접속 스트림을
대신 띄우지 않는다. 소유 subprocess와 private fixture만 중단하며 OS 화면 검증은 아니다.

제품 경로 실행 결과: `test-remote-agent-automatic-reconnect`에서 CLI wrapper가 실제
연결 종료 255를 받고 두 번째 SSH 연결을 열었다. 시작 후 config를 바꿔도 두 연결 모두
v2를 유지하며 준비 명령은 한 번이었다. 제품 AppSession은 실제 SSH EOF에서 1초
백오프를 예약하고 drain 경로가 replacement를 띄웠다. 기존 v1/v2 커서를 보존하고 새
GUI nonce의 혼합 이벤트를 받아 idle 배지·원격 캡처 봉인과 재시도 예산 초기화를 확인했다.
하네스의 GUI nonce를 고정값으로 놓았을 때 실제 GUI가 발급한 신원과 달라지는 것을
확인해, 마커로 발급된 값을 전달하도록 보완했다. 제품 신원 정책은 바꾸지 않았다.
재시도 예약을 막는 결함은 예약 시각 검사에서, 준비 명령을 매 연결 반복하는 결함은
독립 SSH argv 장부에서 실행 중 검출됐다. 결함 소스는 복원하고 정상 검증을 다시 실행했다.
OS 화면·입력·실제 네트워크 장비 장애와 ACK 없는 전송의 exactly-once 보장은 포함하지 않는다.

## 실패·취소·종료 경로 검증 계획

CLI의 빠른 연결 실패는 3회에서 종료하고 대기 중 SIGINT는 다음 접속을 시작하지 않는지
실제 제품 shell loop로 확인한다. GUI는 연속 비정상 EOF에서 재시도 예산·백오프·cursor
보존을 검사하고, 전체 종료에서 저장된 mixed cursor의 할당과 자식·채널을 회수하는지
DebugAllocator와 실제 파이프로 판정한다. 반복 정상 복구와 실제 SSH/PTY 검증은 별도로
구분하며 사용자 SSH 설정이나 현재 실행 중인 프로세스는 변경하지 않는다.

이번 실패 경로 검증에서 전체 원격 host 종료가 cursor 키·맵의 해제를 빠뜨리는 누수를
DebugAllocator로 재현했다. 단일 host 종료와 전체 종료가 `closeRemoteAgentHost`를
공유하도록 수정했다. 실제 설치/스트리머 역할의 소유 자식을 fork해 종료 뒤 fd 닫힘·
waitpid 회수와 채널·nonce 초기화도 확인한다.

GUI 파이프 판정자는 연속 실패에서 6회 예약(1/2/4/8/16/32초) 뒤 포기하고 v1/v2 cursor를
보존하는지 검사한다. 정상 hello가 이어지는 반복 복구에서는 예산이 초기화되고 두 포맷의
시작/종료 이벤트가 배지를 running→idle로 옮기며 cursor가 전진하는지 판정한다.
실제 시간만큼 기다리는 soak가 아니라 제품 예약 시각과 실제 EOF/프레임 소비를 검사한다.

CLI process 판정자는 private HOME과 장애 주입용 `ssh` 실행 파일을 사용한다. 실제 제품
CLI wrapper가 3회 빠른 255 실패 후 포기하고, 대기 중 소유 foreground group에 SIGINT를
보내면 exit 130과 한 쌍의 ssh/ssh-end 뒤 새 시도 없이 종료하는지 확인한다. 키 입력을
주입한 PTY 검증은 아니며, 이번 sandbox는 loopback bind를 EPERM으로 거부해 실물 sshd
재검증을 실행하지 못했다. 기존 실제 SSH 검증 결과와 이번 파이프/주입기 결과를 구분한다.

권한 변경 후 최신 main 위에서 실제 loopback SSH와 제품 CLI/GUI 자동 재접속 gate를
다시 실행해 통과했다. PTY Ctrl-C 후보 검증은 현재 실행 환경에서 `/bin/sh` 대조군도
같은 입력으로 종료되지 않고 PTY foreground group의 SIGINT가 EPERM으로 거부되어
제품 결과로 사용하지 않았다. 기존 소유 프로세스 그룹 SIGINT 검증과 구분한다.

실제 GUI Terminal 검증은 `--terminal-cancel` opt-in으로 실행한다. 소유 `.command` 창의
제목과 foreground 및 화면 잠금을 확인한 뒤 GUI Control+C를 전송한다. 실제 SSH 연결을
끊고 제품의 재접속 안내가 나온 뒤 exit 130, 추가 접속 없음, ssh/ssh-end 한 쌍을 검사한다.
기존 Terminal 창은 종료하지 않는다. 실패 시 테스트 창은 조사용으로 남긴다.

2026-10-13 실제 GUI Ctrl+C와 일반 셸 대조군을 확인했다. 제품은 exit 130으로
끝났고 취소 뒤 추가 SSH 접속은 없었다. 하네스의 닫힌 master 재사용과 입력 전
Swift 확인이 1초 backoff를 소비하는 문제를 수정했다. 실제 GUI 단독 및 자동
재접속과 결합한 전체 loopback 검증 모두 통과했다.

## 앱 재시작 복구 검증 계획

기존 RA5 계약대로 앱의 커서는 메모리에만 두며 새 앱은 최근 원격 기록을 재생한다.
채널 재접속의 resume와 앱 재시작의 상태 재구성을 구분한다. 실제 loopback SSH wire를
새 AppSession에서 소비하여 배지 복원과 과거 완료 알림·턴 before 재캡처 여부를 검사한다.
다음 단계는 앱을 종료한 사이 기록한 두 포맷과 복원된 pane 신원을 새 프로세스에 전달하는
실물 restore 검증이다. 제품 receiver 재생만으로 실제 앱 재실행 완료를 주장하지 않는다.
초기 과거 기록과 live 기록을 구분할 수 없는 경우 임의의 시간·batch 크기로 경계를 추측하지
않고, wire 경계 계약을 먼저 설계하고 사용자와 논의한다.

### 재현 결과와 초기 경계 계약 제안

main `fcbd66ac5` 기반 실제 loopback SSH의 기존 v1/v2 wire를 새 AppSession에서
소비하면 idle 배지는 복원되지만 `term.hook.notice.kind`는 `.done`으로 남았다.
`test-remote-agent-restart-replay`가 `.none`을 기대해 실패한다. 이는 수신기와 알림
예약의 재현이며 실제 workspace restore·GUI 재실행·OS 배너 실측을 뜻하지 않는다.
로컬 수신기는 `backlog_catchup`으로 과거 기록의 알림·before 읽기를 억제하지만
원격 경로에는 초기 따라잡기 경계가 없다.

제안: 새 capability를 협상한 mixed reader가 초기 파일별 `(profile,name,generation,offset)`
watermark를 고정하고 그 경계까지의 이벤트를 replay로 표시한다. receiver는 배지·대화·
신원을 복원하되 과거 완료 알림과 현재 파일의 before 재캡처를 억제한다. 여러 tick·
stdout 배압에도 분류를 유지하고 경계를 지난 이벤트는 live로 처리한다. 채널 재접속은
기존 resume 계약을 유지한다. generation 교체·뒤늦은 파일 발견·rotation은 wire 설계에
명시하고 독립 fixture로 검증한다. 기존 v3 hello를 새 경계 지원으로 오인하지 않는다.
구 peer는 기존 동작을 유지하며 경계 지원이 없다는 진단을 남긴다.

공격 항목: 초기 파일이 여러 배치에 걸침, 두 profile 교차 소비, 초기 읽기 중 새 Stop,
rotation과 generation 교체, stdout 배압·EOF, resume와 fresh app 구분, 다른 pane,
구 peer. 첫 heartbeat·시간 지연·첫 batch만으로 replay 종료를 추측하지 않는다.
기존 wire 확장은 아래 사용자 승인과 확정 계약에 따라 구현한다.
초기 실패 판정자는 아래 확정 계약과 실제 SSH 회귀 gate로 발전시켰다.

### 확정한 초기 재생 경계 계약

2026-10-14 사용자가 통신 계약 확장을 승인했다. 기존 `--log-format=mixed`와 v3 wire는
유지한다. 두 provider의 준비 응답에 `replay_boundary:true`가 확인되면 GUI는
`--log-format=mixed --replay-boundary`를 요청한다. 이 모드의 hello는
`{"hello":"maru-agent-events-mixed-replay","v":4}`다. v3 hello는 이 기능의 증거가 아니다.
구 peer는 기존 v3 동작을 유지하며 과거 기록 억제는 지원하지 않는다.

초기 정리 후 두 namespace의 파일 크기·v2 generation·v1 inode를 **hello 전에** 고정한다.
파일 목록은 같은 순간의 전역 원자 snapshot이 아니라 파일별 순차 snapshot이다. 초기
snapshot 중 파일이 생기면 탐색에서 발견한 파일만 과거 경계를 갖는다. 실패한 v2 lock/read는
과거 기록을 live로 오인해 전달하지 않고 시작 실패로 드러낸다. 초기 과거 기록을 모두 읽을
때까지 UI를 기다리게 하지 않는다. 기존 파일/청크 읽기 예산과 번갈아 읽기를 유지한다.

v4 envelope는 `{"replay":true|false,"format":1|2,"frame":<기존 frame>}`다. 완성된 이벤트의
끝 offset이 고정한 경계 이하이고 파일 신원이 일치하면 replay다. 초기 부분 줄이 나중에
완성되어 경계를 넘으면 live다. v2 세대가 바뀌면 이전 경계를 적용하지 않는다. v1은 inode
교체와 크기 감소를 감지하지만 같은 inode를 truncate 후 다시 크게 쓴 경우는 기존 v1의
세대 식별 한계가 남는다. 이 보장을 v2 수준으로 주장하지 않는다.

커서 inner frame은 `replay_at`·`replay_inode`와 선택적 `replay_gen`을 함께 전달한다.
이 메타데이터를 위치 0의 초기 커서로 이벤트 전에 전송하여 첫 청크 중 EOF에도 기억한다.
GUI는 동일한 cursor 항목 안에 보관하고 재접속에서 `--replay-state=`로 되돌린다.
문법은 기존 mixed cursor 문법의 offset을 초기 경계로 해석하고 마지막 `:<inode>`를 붙인다.
예: `1:name:100:1234`, `2:name:200:<generation>:0`. 이름 중복·타입·상한을 검증하며
watermark는 대응하는 resume 항목 없이 적용할 수 없다. 32개 cursor 상한은 유지하고
replay-state 바이트 예산은 기존 mixed 예산 + 21×32로 별도 고정한다. 별도 SSH 채널이나
영속 커서 파일은 만들지 않는다. 메모리 커서는 앱 종료와 함께 사라진다.

replay 이벤트는 기존 상태 기계로 배지·대화·신원을 복원하되 완료/승인 알림, 현재 파일의
before 읽기와 과거 턴 재봉인/스냅샷 생성은 억제한다. 이미 영속한 턴 기록의 복원은 기존
복원 경로가 소유한다. 경계 뒤 live 이벤트는 정상 알림과 새 턴 캡처를 만든다.

검증 게이트 `test-remote-agent-restart-replay`는 실제 loopback SSH wire를 **새 제품
AppSession 프로세스**에서 소비한다. 과거 기록 억제, live 알림·캡처, 여러 청크의 과거
800개/live 8개, 초기 커서 전송 뒤 자식 종료·새 transport resume를 검사한다. OS 창을
종료/재실행하는 workspace restore E2E와 OS 배너 표시는 이 gate의 증거에 포함하지 않는다.
EOF 중 ACK 없는 프레임의 exactly-once나 읽은 파일 전부의 무제한 cursor 보존도 주장하지 않는다.

교차 profile 공격에서도 추가 결함을 재현했다. live Prompt 뒤 다른 profile의 과거
Prompt/Stop이 도착하면 live 턴이 idle로 덮였다. 중립 `HookSlot`이 pane별 live 수신 여부를
기억하고 그 뒤의 replay는 현재 상태·provider·알림을 변경하지 않도록 했다. 다른 pane의
초기 복원은 독립적으로 진행한다. 이 표시는 transport 재접속에서는 보존하고, 훅 끄기·
원격 이탈·다른 nonce owner로 전환할 때 초기화한다. v3의 기존 경로는 이 규칙을 쓰지 않는다.
v4는 명시적 replay envelope와 커서의 경계 메타데이터를 요구하며 v3 hello로 낮추지 않는다.

## 실제 macOS 창 종료·복원 검증 계획

#4435의 정확한 소스 사본을 사용하며 제품 이벤트·workspace checkpoint·runtime attach·
알림 전달 구현은 변경하지 않는다. 사본에는 상태 관측과 소유 창의 종료 요청만 추가한다.
private HOME·config·session-host root와 소유 loopback SSH를 사용한다. persistent PTY에서
`maru ssh`를 실행하고 실제 발급 nonce를 원격 fixture가 기록한다. 정상 AppKit 종료로
checkpoint를 만든 뒤 앱이 없는 동안 같은 nonce에 v1/v2 훅을 기록한다. 새 GUI 프로세스의
동일 runtime 재부착, 원격 배지, 과거 알림 억제 및 새 live 알림을 검사한다.

GUI는 Aqua 세션에서 실행하며 화면 잠금 상태에서는 진행하지 않는다. 첫/복원 창의 실제
Metal frame은 로컬 artifact로만 보관한다. Notification Center의 실제 배너는 소유 테스트
알림의 고유 식별자를 기준으로 확인하고, 전달 요청/예약 성공과 화면 표시를 구분한다.
기존 사용자 앱·SSH·Notification Center 기록은 종료·삭제하지 않는다. 서명/OS 알림 권한이
부족하면 정확한 조회 결과를 보고하며 자동 승인이나 정상 표시로 처리하지 않는다.

### 실행 방법과 검증 경계

`python3 tools/remote-restart-app/prepare.py --snapshot <저장소 밖 새 디렉터리> --dependency-root <동일 web lockfile과 node_modules를 가진 checkout>`으로
제품 소스 사본과 관측용 앱을 만든다. `remote-restart-source.json`은 원본 HEAD, 관측 코드와 서명된 바이너리
해시를 기록한다. 실행기는 앱/CLI 해시를 대조하고 artifact에 manifest를 복사한다. 정상 GUI 실행을 사용하며 smoke 실행의 workspace 복원 생략을 사용하지 않는다.

`python3 tools/test-remote-agent-native.py --cli <snapshot>/zig-out/Maru.app/Contents/MacOS/maru --gui-app <snapshot>/zig-out/Maru.app/Contents/MacOS/maru-macos-app --gui-output <새 artifact 디렉터리>`로
실행한다. 기존 private SSH carrier가 원격 훅과 foreground SSH process를 소유한다. provider
payload는 합성 데이터이며 provider 계정이나 사용자 SSH 설정을 변경하지 않는다.

종료는 제품의 Quit 요청과 Enter 확인 입력을 거쳐 final checkpoint·AppKit 종료를 실행한다.
확인 생략은 keep-alive 정책 확정까지 생략해 runtime을 끝내므로 성공 대조군으로 쓰지 않는다.
앱이 없는 동안 정확한 runtime 하나가 controller 없이 유지되는지 실제 CLI inventory로 확인한다.
복원 뒤 host/runtime nonce 전체와 원격 process owner가 같아야 하며, 초기 기록 2개와 오프라인
v1/v2 기록 8개가 실제 reader에서 replay로 적용되고 알림 전달은 없어야 한다. 이어서 새 v1/v2
기록 8개가 live로 적용되고 debounce를 지난 완료 알림이 실제 전달 큐에서 나와야 한다.
배치별 nonce 카운터를 누적 이벤트 수로 사용하지 않는다. 이벤트 적용 관측을 별도로 센다.

준비 완료 전에 실패하더라도 정확한 private namespace·실행 파일·UID·process birth가 일치하는
host만 정리한다. 재사용 artifact 디렉터리는 거부한다. Metal frame은 로컬에만 저장한다.
Notification Center 권한 조회와 전달 기록은 화면에 보이는 OS 배너의 증거가 아니다.
현재 gate는 `os_banner_verified=false`로 그 경계를 명시한다. 실제 배너의 양성 대조군과 표시
검증은 별도 후속 작업이며 이 gate의 통과나 UN authorization으로 완료 처리하지 않는다.

## 실제 provider → GUI 검증 계획

GUI reader 준비 후 설치된 Claude/Codex의 읽기 전용 `pwd` 턴을 시작한다. provider 설정은
private HOME에서 생성하며 사용자 설정이나 인증 원문은 변경·출력·커밋하지 않는다.
provider 버전과 실제 session ID를 GUI의 live 훅 적용, running/idle 배지, 원격 봉인 capture의
session·shell 호출 증거에 대조한다. 합성 startup/offline 이벤트를 실제 provider 증거로 세지 않는다.
실제 provider 종료 코드만으로 완료 처리하지 않고 두 provider 각각의 GUI 관측을 요구한다.
기존 v1/v2 동시 기록과 정상 종료·재부착 gate도 유지한다. 원본 훅 누락, reader 시작 이전 실행,
provider별 신원 오귀속, capture 없음, 인증 실패 및 cleanup 실패를 음성 경계로 검토한다.
OS 배너의 실제 표시는 이번 provider GUI gate에서도 별도다.

실행은 기존 앱 준비 도구로 만든 bundle을 `--providers --gui-providers --gui-app <앱 실행 파일>
--gui-output <새 디렉터리>`에 전달한다. 각 provider를 GUI 준비 이후 같은 foreground SSH에서
실행하며, 두 provider의 native v2 훅과 기존 합성 v1/v2 호환·종료/복원 검증을 구분해 기록한다.
원본 훅 oracle은 별도 CLI reader로 provider 파일을 읽어 GUI에서 확인한 실제 session ID와
`UserPromptSubmit/PreToolUse/PostToolUse/Stop`을 대조한다. 변경 파일이 없는 읽기 전용 턴이므로
파일 편집 결과나 OS 배너 표시를 검증했다고 주장하지 않는다.

### 실제 실행에서 확인한 실패

Codex exec는 argv prompt가 있어도 pipe stdin을 추가 입력으로 읽는다. SSH `-T`의 열린
stdin을 물려준 검증은 GUI 준비 뒤 EOF를 기다리다 timeout됐다. 비대화형 provider 실행은
명시적 DEVNULL을 사용한다. provider 실행이 길어 preflight ControlMaster의 idle TTL이 끝난
경우도 확인했으므로, 뒤따르는 transport 단절 검증은 정확한 소유 master를 먼저 확보한다.

stdin timeout으로 foreground runtime이 끝난 실패에서는 host의 `removeEndedTracker`에서
연결이 닫히고 GUI 재접속이 `ObserverAttachRejected` → incident_authority exit 86으로 이어졌다.
이 실패의 host/app 로그를 보존했다. 정상 provider GUI 경로와 별개인 runtime-end 정리/재접속
실패로 남긴다. 부분 전송 보호와 stream 계수·신원 불일치를 축소 재현에서 구분한다.
기존 frame/incident 권한 계약을 대조하기 전에는
integrity 보호를 끄거나 임의의 재접속 성공으로 처리하지 않는다.

### Runtime 종료·observer 거부 GUI 회귀 검증

다음 GUI 검증은 기존 CR6e-c3c 실제 AppKit의 두 runtime 자동 재접속 검사를 대조군으로 쓴다.
소스 복사본에서만 수신 스케줄을 제한하여 실제 snapshot 부분 전송을 만들고, 별도 admin
connection으로 한 runtime을 종료한다. 실제 `ended_purge_tracker/PartialFrame` 로그가 없는
회차는 해당 원인의 GUI 재현으로 세지 않는다. 살아 있는 sibling의 PID·controller 권한,
포커스·AppKit keyDown 이후 화면 marker와 Metal frame, 정상 Quit·자원 정리를 확인한다.
종료 대상의 reconnect row 순서도 구분하여 먼저 성공한 sibling과 아직 미정산인 sibling의
처리가 달라지는지 관측한다. 기존 canonical failure/retained-terminal 정책과 다른 결과가
필요하면 실제 증거를 먼저 보고하고 전략 변경을 논의하며 임의로 정책을 바꾸지 않는다.

수신 지연 실험은 `tools/remote-restart-app/prepare_partial.py`가 만든 외부 소스 복사본에서
실행한다. 두 runtime을 실제 sidebar 클릭으로 채택한 뒤 숨겨진 종료 대상의 PTY에 dense
출력을 만들고, 제품 `requestResync`로 snapshot을 요청한다. 복사본의 화면 drain·maintenance
수신과 같은 Client를 읽는 일반 RPC를 잠시 보류하고 실제 socket receive buffer를 제한한다. 별도 admin connection의
`runtime.terminate` 뒤 실제 host의 `PartialFrame` 진단을 확인해야 성공 판정 경로로 수신을 재개한다.
미재현·하네스 오류 시에는 실패를 보존한 채 수신 보류를 해제하여 소유한 앱의 정상 종료를 기다린다.
`run_partial.py`는 정상 수신 대조군의 v2 artifact를 거부하고 별도 실험 schema에서 살아 있는
runtime의 동일 PID·입력/화면 marker·Metal 제출·정상 Quit 정리를 확인한다. 이 실험에서 기존
대조군의 sibling은 종료 대상이며, 활성 primary가 살아 있어야 하는 터미널이다. 최초 확인
범위는 이 채택 순서 하나이며 반대 순서와 기존 연결의 모든 읽기 경로 차단 여부는 별도
검증 경계로 남긴다. 실험 코드의 준비만으로 GUI 회귀 검증 완료를 표시하지 않는다.

2026-10-15 실제 AppKit 실험에서는 628,615 byte dense snapshot과
`ended_purge_tracker/PartialFrame`을 확인했다. 종료 대상이 첫 runtime handle인 순서에서
`candidate_rejected next_index=0` → `retained_terminal`로 정산했고, 활성 primary의 자동 복구는
완료되지 않았다. 제품 Quit 경로는 backend 정산 중 `proof_loss`(exit 86)로 실패했다. 이 종료
실패는 당시 미해결로 기록했으며, 아래 2026-10-16 정산 수정과 일반 두-runtime 자동 재접속 대조군의 성공을 구분한다. in-process fixture
daemon의 진단은 CLI의 별도 host 로그가 아니라 상속한 stderr의 통합 gate 로그에 기록된다.

후속 정책은 서버가 정확한 host/runtime 요청에 종료를 확정한 항목만 ended로 정산하고
아직 시작하지 않은 형제 항목의 복구를 계속하는 것이다. 일반 attach 거부·권한 충돌·손상된 응답은
종료 확정으로 취급하지 않는다. 2026-10-16 사용자가 종료 정산 수정의 머지와 다음 작업 진행을
요청하여 이 제한된 정책으로 진행한다. 일반 forward-failure와 shared transport 실패 처리는 유지한다.

구현 순서와 판정 기준:

1. 실제 wire error 분기에서 `runtime_not_found`를 구분한다. 재확인한 현재 제품 executor는 JSON error
   응답도 accepted payload owner로 전달하며, `decodeAttachResponse`의 `wire_error`가 아직 살아 있는
   동안 code를 읽을 수 있다. 따라서 typed-reject payload를 새로 보존하거나 receipt ABI를 넓힐 필요는 없다.
   observer candidate가 정리되기 전에 positive missing만 구분하고 일반 거부는 기존 결과로 남긴다.
   **분류 구현 완료**: `ObserverRuntimeNotFound`를 별도 반환한다. 같은 실제 socket 회귀 검사에서
   정확한 부재와 동등한 JSON 표기·일반 거부·미지 code·중복/혼합 envelope·손상 JSON·잘못된 응답 ID·잘린 프레임·EOF를 구분하고 candidate 정리,
   기존 shell·게시 Client·connection generation·cleanup pin 보존을 Debug/ReleaseFast로 확인했다.
   분류만으로 sibling 복구 완료를 뜻하지 않으며, 아래 active-row 정산과 실제 GUI 검증을 별도로 둔다.
2. canonical job에 종료 확정 상태를 seal하고 해당 active row만 gone_positive/ended/closed로 전진한다.
   이미 게시한 sibling과 아직 시작하지 않은 suffix는 바꾸지 않는다. 공유 retired Client는 모든 row
   정산 뒤 정확히 한 번 회수한다. 추가 검토에서 종료 row는 candidate publication이 없어 old payload가
   retiring이 아니라 current인 상태임을 확인했다. 단순히 retiring reclaim을 부르는 구현은 피한다.
   종료된 current payload·화면/종료 projection의 수명, 다음 incident의 canonical row 수집과 membership
   count에서 종료 항목을 제외하는 일관성을 먼저 설계·검증해야 한다. 구현은 reducer의 별도
   observer 부재 event로 healthy/old_valid에서 gone_positive/ended/closed를 기록한다. 이는 takeover
   이후 부재 event와 구분한다. admission과 resident charge는 all-row 정산까지 유지하고 old current
   payload는 Term 종료 시 기존 owner가 회수한다. 현재 job의 ended row는 membership에 남기되 이전
   job에서 정산된 ended runtime은 다음 admission·snapshot·row 수집에서 제외한다. shared transport가
   나중에 실패해도 앞서 확정한 ended row를 frozen으로 되돌리지 않는다.
   **정책 배선과 실제 GUI 검증 완료(현재 채택 순서)**: 실제 daemon의 첫째·중간·마지막 종료, 모두 종료,
   종료 뒤 shared transport 실패, 정상 sibling 입력·화면 텍스트, 두 번째 재접속을 검증한다.
   다음 재접속에서 사용한 Client의 빈 catchup buffer가 capacity를 유지하는 정상 소유 상태를
   adoption용 zero-capacity 검사로 거부하는 결함도 재현했다. retirement 전용 검사는 bounded
   backing과 전체 allocation graph·destination 비중첩을 검증하고, 기존 adoption 검사는 유지한다.
   ended current payload는 canonical gone proof와 정확한 shell generation이 있을 때만 후속
   connection generation 이후에도 정상 teardown할 수 있다. pump_ended만으로 이 경로를 열지 않는다.
3. 없는 runtime과 일반 거부·잘못된 신원·손상 응답·EOF를 구분하는 실제 socket 검사를 둔다.
   세 runtime에서 처음·중간·마지막 종료를 공격하여 앞선 성공과 뒤 sibling 입력을 보존하는지 확인한다.
   continuation을 무력화하거나 일반 거부를 종료로 바꾸는 변이가 실패해야 한다.
4. 실제 PartialFrame GUI 재현에서 target 종료와 healthy PID/controller·입력/복사/resize·Metal frame·Quit을
   확인한다. 원래 두-runtime 대조군의 첫 입력 timeout도 별도 재현 경계로 유지하며 재실행 성공으로 덮지 않는다.

잠금 상태의 종료 원인 추적에는 외부 복사본의 `prepare_partial.py --optimize Debug
--nonvisual-diagnostic`을 사용한다. 이 복사본은 캡처 실패로 driver가 정지하는 부분만 건너뛰고,
캡처 관측값은 false로 남긴다. manifest와 AppKit artifact schema를 GUI 실험과 구분하며 runner는
`validation_scope=nonvisual_appkit_diagnostic`, `gui_continuity_verified=false`를 기록한다.
이 경로의 성공·실패는 AppKit 구성과 정산 진단이며 실제 화면·포커스·Metal 제출의 GUI 검증을
완료시키지 않는다. 잠금이 해제되면 원래 캡처를 수행하는 복사본으로 별도 검증한다.

2026-10-16 종료 원인 진단과 수정: Debug AppKit 구성에서 retired node의 parser에 7,425 byte가
남아 `prepareRetiredClientReclaim`이 거부되는 것을 확인했다. borrow·operation·RPC owner·cleanup
pin과 stream/event/batch 소유권은 모두 비어 있었다. `finishRetirementCleanup`이 admission close와
retirement detach 뒤 canonical operation 안에서 parser의 미소비 바이트만 버리도록 수정했다.
할당·free 없이 backing과 protocol major를 보존하며 기존 reclaim의 parser-empty 조건은 유지한다.
기존 R3 회귀 검사에 부분 snapshot과 소비된 header prefix, prepare/abort 보존을 추가했다.
Debug·ReleaseFast에서 통과했고 discard를 무력화한 컴파일 가능한 변이는 `expected 0, found 33`으로
실패했다. 수정한 Debug AppKit 구성은 실제 PartialFrame 뒤 정상 Quit, 동일 healthy child PID 유지,
controller/observer 해제와 worker/job/lease/runtime/client/FD/child/socket 정리를 확인했다.

nonvisual 진단은 현 정책의 `auto-reconnect-timeout`을 명시적으로 기록한 뒤 Quit을 정상 종료 코드로
진행시켜 바깥 harness가 정산을 검증한다. 이 timeout을 자동 복구 성공으로 읽지 않으며 GUI 전용
schema/판정자는 이 artifact를 거부한다. 실제 화면·입력 복구와 종료된 항목을 제외한 형제 복구 정책은
아직 별도 검증·구현 경계다.

같은 날 잠금 해제 뒤 최신 main 기반 실제 GUI 복사본에서도 628,615 byte snapshot의
`PartialFrame`과 `candidate_rejected` → `retained_terminal`을 재현했다. 캡처를 생략하지 않았으며
정상 sibling 자동 복구는 `auto-reconnect-timeout`으로 끝나 GUI gate는 exit 1이었다.
따라서 GUI 연속성은 미통과다. 다만 제품 Quit에서는 기존 `proof_loss`가 재발하지 않았고,
worker/job/completion/admission/lease/backend runtime 최종값이 모두 0,
`quit_teardown_ms=1.2`, `quit_total_ms=81.4`였다. 별도 admin의 종료 후 조회에서도 healthy runtime은
살아 있고 controller=false·observer_count=0이었다. 이 실제 GUI 종료 관측과 비시각 artifact의
동일 PID·전체 정리 판정을 구분한다.

`tools/test-runtime-end-pressure.py`는 격리된 실제 daemon과 PTY 두 개를 사용한다. 같은 MRSH connection에 종료 대상과
유지할 sibling을 attach하고 출력 수신을 늦춘 뒤 별도 admin connection으로 대상만 종료한다.
정상 수신 대조군과 느린 수신군을 비교하여 실제 close 로그의 site/err, sibling PID 유지,
새 connection에서 sibling 재attach와 입력·화면 복구를 확인한다. 송신 queue나 close state를
직접 수정하지 않으며 PartialFrame 보호 정책은 유지한다. 수신이 느렸다는 사실만으로 부분
전송 재현을 주장하지 않고, 부분 전송/오류가 관측되지 않은 회차는 미재현으로 기록한다.
실제 실행에서 초기 snapshot 부분 수신 중 종료는 `ended_purge_tracker/PartialFrame`과 잘린
payload로 재현됐고 sibling의 동일 PID·새 controller 권한·입력에 따른 화면 텍스트 복구가
확인됐다. 수신 완료 대조군은 공유 연결을 유지한다. 화면 판정은 raw marker 검색 대신
완전한 row/set_runs record의 viewport 안 text run을 읽고, 잘림·잘못된 UTF-8·보이지 않는
width-0 marker·viewport 밖/초과/미달 row를 거부한다. GUI 자동 재접속은 별도 검증 경계다.

후속 원인 진단은 `removeEndedTracker`의 slot 조회·tracker purge·stream accounting
실패에 기존 close 진단의 site와 실제 오류 이름을 남긴다. 보존된 실행 파일의 반환 주소는
purge 실패 갈래까지 특정했지만 당시 `Stale`과 `PartialFrame`은 구분하지 못했다.
실제 Client/Slot 회귀 검사는 두 purge 오류와 accounting 오류를 발생시켜 진단을 확인하고,
첫 close 사유 보존 및 `PartialFrame` fail-close를 유지한다. GUI 재실행과 원래 장애의
오류 이름 확인은 별도 증거로 남기며, 화면 잠금 동안의 단위 검사를 GUI 검증으로 세지 않는다.

제품 수정 #4448 당시 검증은 실제 GUI coordinator를 통과했다. 별도 소스 복사본에서만
테스트 소유 연결에 실제 `shutdown`을 실행하고, replacement 게시 후 observer 준비 직전에
짧게 대기한다. 외부 CLI `runtime end --yes`로 동일 runtime을 종료한 뒤 대기를 해제한다.
당시에는 daemon의 실제 거부 응답, `candidate_rejected` 관측, canonical terminal 로그, 앱 생존과
정상 Quit을 요구했다. 현재 종료 확정 동작에 맞춘 변경은 아래 판정기 동기화 절에 기록한다. job·seal·응답을 직접 바꾸거나 제품의 integrity 보호를 끄지 않는다.
이 fault injection은 연결 종료의 원인 자체나 PartialFrame 정책을 재현했다는 증거는 아니다.

`--gui-runtime-ended`는 provider 턴·정상 복원과 독립된 opt-in 시나리오다. marker 순서,
다른 host/runtime, 거부 누락, terminal summary 누락, exit 86, 미처리 fault를 음성 판정으로
검증한다. GUI·host·SSH namespace는 기존 검증과 같이 격리하고 이미지·로그는 커밋하지 않는다.

검증 결과는 정상 Quit 뒤 최종 로그를 다시 확인하고 모든 소유 자원을 정리한 뒤에만 쓴다.
진단 저장·한 소유자의 정리 실패도 나머지 정리를 생략하지 않으며 실패하면 성공 결과를
게시하지 않는다. 원본 빌드뿐 아니라 재사용된 staged bundle의 GUI·CLI 해시도 실행 전에
대조한다. CLI 종료 응답 이후 실제 runtime 목록이 비었는지를 observer 거부의 독립 증거로
확인한다. 순수 로그 판정과 실제 제어 프로세스의 정리 검사는 GUI 실행 증거와 구분한다.

실제 GUI 실행에서 observer 거부 뒤 `runtime_transactions_complete`까지 진행했고 앱은
살아 있었지만, 기존 제품 terminal 로그는 이 실패 정산 함수에서 출력되지 않아 하네스가
timeout됐다. 따라서 소스 복사본의 읽기 전용 관측기가 유효한 job의 실제 terminal summary를
직접 읽어 `REMOTE_ENDED_TERMINAL`로 기록한다. 기대한 summary 값을 만들거나 제품 로그의
성공 경로 출력 여부를 실패 경로의 판정 근거로 삼지 않는다.

2026-10-17 continuation 구현의 비시각 AppKit 진단에서는 실제 `ended_purge_tracker/PartialFrame`과
628,615 byte snapshot을 재현하고 recovery marker=true·recovery failure 없음·정상 Quit을
확인했다. healthy PID를 유지했고 worker/job/completion/admission/lease/backend runtime과
Client/FD/child/socket 정리도 확인했다. 이 실행은 `validation_scope=nonvisual_appkit_diagnostic`,
`gui_continuity_verified=false`이며 화면 잠금 상태였다. 화면·포커스·Metal 연속성 증거가 아니다.

### 종료 확정 GUI 판정기 동기화

positive `runtime_not_found` continuation 뒤 단일 runtime 종료의 현재 계약은
`replacement_published` → `candidate_ended` → terminal `total=1, published_old=0,
published_new=0, frozen=0, ended=1, retry_reserved=0`이다. 기존 `candidate_rejected`와
`frozen=1, ended=0, retry_reserved=1`을 요구하는 원격 GUI 판정기는 정상 결과를 거부하므로
이 계약에 맞춘다. 제품 상태나 seal을 하네스에서 만들지 않고 기존 읽기 전용 관측을 유지한다.

판정기는 같은 host의 모든 terminal 관측이 종료 확정 summary와 일치하는지도 검사한다.
앞선 정상 summary 뒤의 모순된 summary를 무시해서는 안 된다. 신원 불일치·순서 역전·옛
거부 정산·retry 잔류·GUI frame 누락·늦은 fatal 오류를 거부하는 대조군을 둔다. 합성 trace와
실제 소유 프로세스 cleanup 검사는 실제 GUI 실행 증거가 아니며, 화면 잠금 중에는 이 둘을
명확히 구분한다. 실제 artifact 변이 도구 역시 같은 현재 계약을 사용한다.

2026-10-17 실제 단일 runtime GUI 실행에서는 `candidate_ended`와 정확한 종료 summary 뒤
기본 `window.quit-after-last-window-closed=true` 정책으로 마지막 창과 앱이 정상 종료됐다.
종료된 창의 사후 frame과 앱 생존을 요구하던 검증기는 이 정상 동작을 실패로 판정했다.
이 단일 runtime fixture는 설정을 명시적으로 true로 고정하고, 시작 GUI capture와 같은 앱 PID의
종료 확정 → 마지막 창 종료 → final checkpoint 완료 → 정상 프로세스 종료를 검증한다.
제품 창/종료 정책은 바꾸지 않는다. 정상 형제가 남는 경우의 입력·Metal frame·Quit은
실제 PartialFrame GUI 시나리오에서 별도로 검증하며 단일 runtime 자동 종료로 대체하지 않는다.

같은 날 잠금 해제 후 실제 PartialFrame GUI를 서로 다른 host/runtime 신원으로 5회 실행했다.
각 실행에서 `ended_purge_tracker/PartialFrame`, 628,615 byte snapshot, 종료 대상의 부재,
정상 터미널의 동일 PID·controller 복구·키 입력 뒤 Metal 제출·화면 연속성 및 정상 Quit과
전체 소유 자원 정리를 확인했다. 이 결과는 `actual_appkit_gui`이며 비시각 진단과 구분한다.
현재 채택 순서 하나의 증거이며 반대 채택 순서의 GUI 검증까지 완료한 것은 아니다.

원격 단일 runtime의 실제 GUI 재검증도 종료 확정 summary와 같은 앱 PID의 정상 자동 종료,
소유 프로세스·host 정리를 확인했다. 그 실제 artifact에 종료 확정 누락·옛 retained 결과·retry
잔류·초기 GUI 누락·체크포인트 누락·다른 종료 PID 등을 주입한 16개 변이는 모두 거부했다.
최초 하네스 실패의 로그는 보존했고, 새 실행의 성공으로 과거 실패 기록을 덮어쓰지 않았다.
