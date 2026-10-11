# 에이전트 로그 세대와 이어읽기

## 상태

설계 확정. 사용자는 명시적인 세대 ID와 offset의 공통 계약에 이어 native 기록기
방식으로 후속 구현을 진행하도록 승인했다(2026-10-11). 아래는 단계별 구현 계획이며
각 단계의 라이브 배선과 OS 검증이 완료되기 전에는 제품 지원 완료를 뜻하지 않는다.
1단계 순수 codec과 reconciliation, 2단계 native I/O 기반은 구현됐다.
제품 기록 CLI와 준비된 native 훅, 명시적 v2 스트리머는 구현됐다.
wire 수신·재접속 배선과 명시적으로 선택하는 로컬 native reader가 구현됐다.
제품 훅의 기본 활성화와 구형 in-flight 훅의 이행은 후속이며 peer ACK는 별도 범위다.

## 현재 경로와 필요한 변경

`agent_hook_command.build`는 셸 내장 printf로 로그를 append한다. 이 함수의 주석은
추가 프로세스를 쓰지 않는 성능 전략과 항상 exit 0인 provider 훅 계약을 설명한다.
현재 Windows 전용 native 기록기는 없으며 POSIX 셸 커맨드 검증 경로와 Windows native
지원은 구분한다. 로그에 UUID를 추가하는 것만으로는 기록과 회전 사이의 경쟁을 해결하지 못한다.

새 native 기록기는 난수 생성, 헤더 확인과 append를 잠금 안에서 수행한다. 단순히 매
이벤트마다 UUID를 바꾸지 않는다. 파일의 새 세대 생성과 회전 때만 생성한다.
기존 inline 셸의 payload 상한·Codex parent attribution·tmux sidecar·stdin drain은
그대로 유지해야 한다. native 기록기 호출 방식은 추가 프로세스 비용 및 실패해도
provider를 막지 않는 계약을 함께 잰다. native 기록기 방식은 사용자 승인됐다.

## 공통 데이터 계약

- 세대 ID: OS CSPRNG에서 얻는 128비트 값. wire에는 소문자 hex 32자리. PID·mtime·
  파일 크기·inode만으로 만들지 않는다. OS 파일 식별자는 선택적인 진단 보조값이다.
- v2 파일: 고정 magic/version과 세대 ID를 가진 첫 줄, 뒤에는 기존 provider-tab-payload
  줄을 그대로 둔다. ID 옆 파일과 본문을 따로 갱신하지 않는다. 세대가 본문과 같은 파일에 있다.
- v2 커서: 이름·세대 ID·payload 기준 offset. 헤더 뒤가 offset 0이다. 헤더의 물리
  바이트 수는 공개 커서에 넣지 않는다. seek는 header length+offset의 overflow를 검사한다.
- resume 후보: `이름:offset:세대hex`. 기존 `이름:offset`은 v1 커서로 구분한다. 동일
  이름 중복은 세대나 offset과 무관하게 거부한다. 파일 이름/ID/offset은 모두 기존
  parser의 엄격한 문법·범위 검사와 연결한다.
- cursor frame 후보: 기존 cur/at 필드에 gen 필드를 추가한다. 이벤트 payload는
  바꾸지 않는다. gen의 잘못된 길이/문자/중복 필드는 조용히 v1로 낮추지 않고 거부한다.
- 파일의 세대와 커서의 세대가 같을 때만 offset을 적용한다. 다르면 새 payload의
  시작에서 읽는다. 파일 크기가 같거나 커져도 같은 규칙이다.

## 원자성과 잠금

파일별 안정된 sibling lock을 기록기·회전기·시작 시 정리가 공유한다. 잠금 대상은
회전으로 바뀌는 로그 inode가 아니며, 잠금 파일은 실행 중 unlink하지 않는다.
OS I/O 경계 뒤에서 POSIX와 Windows 동작을 구현·실행 검증한다. Zig 0.16의
Io.Dir open/create lock 옵션을 우선 검증하며, 특정 OS에서 지원하지 않는 경우
지원한다고 선언하지 않는다. Windows에서는 파일 공유/rename 제한과 ACL도 검증한다.

새 헤더는 private temporary regular file에 완전히 쓴 뒤 같은 디렉터리에서 publish한다.
파일 권한과 directory ownership/symlink 검사를 기존 보안 계약과 연결한다. 디스크 실패나
난수 실패 시 기존 로그를 그대로 둔다. UUID를 고정값으로 대체하지 않는다.
헤더가 일부만 쓰였거나 magic이 손상됐으면 legacy 파일로 오인하지 않고 실패한다.

기록기는 잠금 안에서 현재 헤더와 generation을 읽고 완전한 이벤트를 append한다.
실패 시 기존 완전한 줄을 파괴하지 않으며 부분 쓰기/복구 실패도 검증한다.
회전기는 새 generation의 헤더가 있는 파일을 교체한다. 기존 파일을 0바이트로
비우고 별도 sidecar만 바꾸는 방식은 사용하지 않는다.

스트리머는 잠금 안에서 bounded snapshot과 generation을 얻고, 잠금을 풀고 출력한다.
stdout backpressure 동안 잠금을 잡아 provider의 턴을 막지 않는다. 출력 flush 후
절단하려면 다시 잠금을 잡아 generation과 소비한 EOF가 현재 파일과 같은지 확인한다.
append나 교체가 있으면 비우지 않고 다음 회차에 읽는다. 같은 잠금을 사용하는 기록기라야
검사와 교체 사이의 append 경쟁을 닫을 수 있다. 잠금 없는 외부 수정은 지원 계약 밖이다.

## 호환성과 단계적 이행

생성기·스트리머·수신기가 서로 다른 버전일 수 있으므로 기능 협상을 먼저 설계한다.
v2 기능이 확인되기 전에는 v2 resume를 구버전 CLI에 보내지 않는다. 기능 확인 전에
저장해 둔 generation을 버리고 offset만 보내는 조용한 downgrade도 금지한다.

기존 로그와 기존 훅은 v1로 명시적으로 취급한다. 자동으로 헤더를 앞에 삽입하거나
아직 실행 중인 구형 append와 v2 회전을 섞지 않는다. 새 훅 설치와 in-flight 구형
훅의 이행 경계가 닫힌 로그만 v2의 보장을 주장한다. Codex trusted_hash 변경과
재승인/바이너리 경로의 수명도 이행 계획에 포함한다.

보관할 cursor 개수는 기존 RemoteAgentHost.cursor_max를 유지한다. generation 추가로
현재 resume_spec_max 예산을 넘을 수 있으므로 최대 이름·u64 자릿수·세대 길이를
조합한 comptime 검사를 유지한다. 문자열이 넘으면 이어읽기를 조용히 포기하지 않는다.

## 계획에 대한 공격과 대응

| 공격 | 그대로 구현하면 생기는 문제 | 설계의 대응/게이트 |
| --- | --- | --- |
| 본문 교체 후 ID sidecar 쓰기 전 crash | 새 본문에 이전 세대가 붙음 | 헤더와 본문을 같은 파일로 publish |
| 같은 크기/더 큰 크기 파일 교체 | 크기 감지로는 offset이 새 본문을 건너뜀 | 다른 세대는 반드시 payload 0 |
| 동시에 두 기록기가 빈 파일을 만듦 | 각각 다른 헤더/이벤트가 섞임 | 안정된 lock 아래 생성·append |
| flush 동안 append | 새 꼬리까지 회전으로 삭제 | 재취득 후 같은 gen/EOF를 검사 |
| stdout가 막힘 | lock을 잡으면 provider 턴이 지연됨 | snapshot 뒤 lock 해제, 출력 후 재검사 |
| lock 파일을 지움/다시 만듦 | 서로 다른 inode lock으로 동시 진입 | 활성 lock unlink 금지 |
| 잘못된 gen을 legacy로 처리 | 오류가 offset-only 이어읽기로 낮아짐 | presence와 형식 오류를 구분해 거부 |
| 구버전 streamer에 새 resume 전달 | usage 오류→재시도 소진 | 기능 협상과 명시적 downgrade 정책 |
| 최대 nonce 32개 커서 | 현재 argv 예산 초과→전체 replay | 최대 인코딩 크기 comptime 검사 |
| Windows rename/share 제한 | POSIX-only gate는 통과하나 실제 교체 실패 | native Windows의 다중 프로세스 gate |
| 정상 publish 뒤 전원 손실 | live 원자성이 crash durability로 오인됨 | fsync/durability 보장은 별도로 정의 |
| OS 전송 성공 뒤 수신 앱 종료 | generation이 있어도 중복/누락 가능 | ACK/재전송은 이번 범위 밖 |

## 구현 순서와 완료 게이트

3단계의 제품 검증 경로는 명시적인 `agent-events --log-format=v2` 선택으로
격리한다. 기본은 v1이며 혼합 디렉터리를 자동 판별하지 않는다. v2 선택은 별도
`maru-agent-events-v2` hello 식별자/version 2와 generation cursor를 낸다.
기존 수신기는 version 값이 아니라 닫는 따옴표까지 포함한 v1 식별자 접두사를
검사하므로, 숫자만 바꾸지 않고 식별자를 분리해 v1으로 오인하지 않도록 한다. 앱의 capability 협상과 기본 훅 전환은 4단계까지 보류한다.
v2 시작 정리는 같은 잠금 안에서 현재 파일의 generation/EOF/mtime을 읽고
7일 만료는 삭제, payload 1 MiB 이상은 새 generation으로 교체한다. 바쁜 파일은
그대로 둔다. sidecar와 영구 lock 슬롯은 이 정리에서 삭제하지 않는다.
v2 reader는 snapshot 후 잠금을 풀고 이벤트와 커서를 출력하며 flush 성공 뒤에만
읽기 위치를 확정한다. 회전 재검사가 실패하면 읽은 위치를 유지한다. generation이
바뀐 빈 파일도 offset 0 cursor를 보내 이전 resume를 남기지 않는다.

1. 순수 Generation/Header/Cursor codec과 reconciliation. macOS·Linux·Windows compile,
   malformed·overflow·same/larger replacement·동일 이름 중복 및 독립 oracle.
2. native writer와 파일 publish/lock 경계. 기록기 경로 수명, provider exit 계약과
   기존 훅 대비 latency를 실제 재고, Codex trust 변경과 이행을 확정한다.
3. 스트리머 snapshot/회전/startup 정리를 같은 경계로 이관한다. 동시 append·
   stdout backpressure·broken pipe·락 소유자 crash·disk full을 실제 프로세스로 검사한다.
4. wire capability·수신 cursor 저장·resume 조립을 함께 배선한다. 버전 조합과
   argv 예산, 재접속·app restart 차이를 검증하고 source digest 원장을 수렴한다.
5. Windows native 다중 기록기/교체/공유 모드 gate와 macOS/Linux live CLI gate를
   실행한다. cross compile만으로 Windows 실동작 완료라고 쓰지 않는다.

기록기/수신기 배선 및 OS 실행 검증이 닫히기 전에는 세대 기반 이어읽기 완료라고
표시하지 않는다. legacy 지원·ACK·crash durability와 검증 상태를 분리한다.

## 1단계 codec의 확정 바이트 계약

v2 헤더는 `MARU_AGENT_LOG_V2\t<소문자 hex 32자리>\n`이다. codec은 이 헤더만
엄격하게 해석한다. 일반 v1 로그는 NotGenerationLog로 구분하며 예약 magic의 부분
헤더·지원하지 않는 버전·잘못된 ID를 v1로 취급하지 않는다. 헤더 뒤의 데이터는 그대로 둔다.
빈 파일의 초기 생성은 기록기가 맡으며 빈 입력은 incomplete header다.

resume entry는 `이름:offset` 또는 `이름:offset:세대hex`이며 이름은 기존
agent_hook_command의 토큰 클래스와 remote_log_name_max를 따른다. offset은
ASCII 숫자로 된 u64, 선행 0 허용이며 추가 구분자·부호·공백을 거부한다. 이름별 중복은
목록을 소유하는 기존 맵에서 검사하며 entry codec이 혼자 목록을 소유하지 않는다.

v2 reconciliation은 같은 generation이고 offset이 현재 payload 크기 이내인
경우만 위치를 유지한다. 다른/없는 generation 또는 범위 밖 위치는 현재 generation의
payload 0으로 돌아간다. 실제 seek는 고정 헤더 길이+offset의 overflow를 검사한다.
회전 eligibility는 snapshot의 끝까지 소비했고 현재 generation과 EOF가 snapshot과
일치할 때만 참이다. 이 판정은 공유 lock과 출력 flush를 대신하지 않는다.

1단계는 순수 계약과 기본 test 배선까지이며 native 기록기·wire 협상·앱 cursor의
라이브 연결은 후속 단계다. 이 단계에서 기존 CLI 입력과 제품 로그를 변경하지 않는다.

## 1단계 구현 결과

`session.agent_log_generation`이 Generation/Header/ResumeEntry codec, payload seek
overflow 검사, generation-aware reconciliation 및 snapshot 회전 eligibility를
소유한다. `test-agent-log-generations`는 기본 test 그래프에 포함된다. 단위 검사에는
독립 golden header와 std hex formatter oracle, 모든 byte 값/ID byte 위치,
최대 이름·u64·작은 buffer·헤더 절단 위치·legacy 구분이 포함된다.

macOS Debug·ReleaseFast와 실제 Ubuntu 24.04 ARM64 테스트 실행이 통과했다.
Windows x86_64 test 모듈 cross compile은 통과했으나 Windows native 실행은
미검증이다. generation 비교·offset 범위·회전 크기·회전 generation·부분 헤더
가드를 무력화한 변형은 컴파일 후 해당 행위 테스트에서 실패했고 등가 조건은 통과했다.
변형은 격리된 소스 사본에서 실행하고 제거했다.

새 포맷은 아직 기록기·CLI·수신 앱에 연결되지 않았으므로 제품의 같은 크기 파일
교체 감지 완료를 의미하지 않는다. 2단계는 native 기록기의 세대 생성·잠금·publish와
기존 훅 대비 latency 검증이다.

전체 `check-targets`·`check-boundaries`, native build 및 문서 링크/행 인용 검사도 통과했다.

## 2단계 native I/O 계약 — 진행

`maru.agent_log_writer`는 caller가 이미 인증한 private directory handle을 받아
basename만 다룬다. parent ownership/Windows ACL 검증은 directory를 제공하는
상위 어댑터의 책임이다. 이름은 기존 nonce 클래스/상한을 사용한다.
기록/회전 lock domain v1은 `maru.agent_log_writer.lock_slot_count`가 소유하는
64개 고정 sibling 슬롯을 사용하고 삭제하지 않는다.
`SHA256(name)[0] & 63`이 슬롯이며 경로는 `.maru-agent-log-lock-v1-<2hex>`다.
이 관계는 버전 계약이며 변경은 live writer 이행이 필요하다. 서로 다른 이름의 충돌은
일시적인 직렬화일 뿐 로그/generation을 합치지 않는다. 모든
잠금은 nonblocking으로 취득하고 바쁜 경우 caller가 provider timeout 안에서
재시도하거나 실패를 전파한다. 로그 open은 symlink를 따르지 않고 regular file,
단일 hard link와 POSIX 0600을 확인한다. Windows mode와 ACL을 혼동하지 않는다.

새 파일은 OS secure random generation의 헤더와 첫 이벤트를 private exclusive
temp에 완성한 뒤 publish한다. append는 공유 잠금 아래 header/EOF/완전한 꼬리를
확인하고 positional write한다. 쓰기 실패는 원래 길이로 rollback하며 rollback 실패는
명시적인 오류다. 기존 empty/legacy/corrupt 파일을 자동 변환하지 않는다.
rotate는 공유 잠금 아래 current generation/EOF를 다시 확인하고, 일치할 때만
다른 세대의 완전한 헤더 파일로 교체한다. readSnapshot은 caller buffer를 채운 뒤
잠금을 풀어 반환한다. OS transport/ACK 성공은 여전히 상위 caller의 책임이다.

검증은 native test driver에서 실제 다중 프로세스 기록·잠금 holder 종료·snapshot 후
append/교체·파일 실패와 latency를 확인한다. 이 driver는 테스트 전용이며 provider
설정과 제품 CLI의 기록 경로는 아직 전환하지 않는다.

## 2단계 native I/O 구현 결과

`maru.agent_log_writer`는 macOS/Linux/Windows native target에서 공개한다.
append/readSnapshot/rotate는 동일한 sibling lock을 사용하며 reader는 caller buffer에
snapshot을 만든 뒤 lock과 file을 닫는다. 임시 파일은 실패 시 close 후 삭제한다.
FIFO의 readonly open은 block할 수 있어 log open은 read/write 후 regular metadata를
검사한다. 구형/불완전 로그, 복수 hard link와 POSIX 비공개 권한 위반을 거부한다.

테스트 driver는 8개 프로세스의 200개 기록에서 누락/중복/세대 혼합 없음, lock holder
SIGKILL 후 재사용, snapshot 후 append와 stale generation 회전 거부를 확인했다.
POSIX symlink/hard link/FIFO 거부와 실제 RLIMIT_FSIZE 부분 쓰기·rollback도 확인했다.
난수 실패·rename 실패·새 파일 partial write·rollback 실패는 기존 std.Io vtable
주입으로 검증하며 공개 제품 env나 fault 토글은 추가하지 않는다.

Linux 최초 실행은 테스트 tmpDir에 iterate 옵션이 빠져 목록 검사에서 BADF로 실패했다.
macOS에서 우연히 동작하던 테스트의 capability 오류였고 iterate=true로 수정했다.
Linux 단위/다중 프로세스 실행과 Windows cross compile이 통과했다. Windows native
공유·ACL·rename 실행 검증은 아직 남아 있다.

ReleaseFast 테스트 driver의 macOS 기록 호출 median은 약 3ms, plain sh printf는
약 6ms였다. Debug는 약 9ms다. 이 값은 standalone driver이며 실제 provider 훅
전체 latency 또는 제품 경로 수명 검증을 대신하지 않는다.

제품 훅·CLI 기록 entrypoint와 스트리머는 아직 이 I/O에 연결하지 않았다. 상위
adapter의 private directory 인증/Windows ACL과 설치 이행, source/control wire
배선은 후속 단계다. 중단/전원 손실의 fsync durability와 peer ACK는 보장하지 않는다.

최종 검토에서 per-name lock 파일은 stale 로그를 지워도 계속 남아 기존 파일 수
관리와 충돌함을 발견했다. 제품 적용 전 64개 고정 슬롯 도메인으로 수정했다.
slot algorithm/path golden과 여러 이름의 실제 파일 수를 검사한다.
활성 lock을 unlink해 inode를 갈라 놓는 cleanup은 사용하지 않는다.

최종 검증: macOS Debug/ReleaseFast와 실제 Linux 단위 112개 및 process 검사가 통과했다.
Windows cross compile, native build, 전체 check-targets/check-boundaries와 문서 검사도 통과했다.

## 2b 기록 entrypoint와 훅 호출 경로

`maru agent-hooks record --file=<absolute .ndjson path>`는 접힌
`provider<TAB>payload<LF>` 한 줄만 stdin으로 받는다. 반복 옵션·추가 인자·빈 입력·
여러 줄·상한 초과는 쓰기 전에 거부하고, 성공 시 stdout 없이 종료한다.
오류는 CLI의 비영 종료로 관측하며 생성된 훅은 stderr를 숨기고 항상 exit 0을 유지한다.

POSIX adapter는 절대 경로의 각 디렉터리를 no-follow로 열고 최종 handle의
실효 UID 소유권과 0700을 확인한다. 경로를 만들거나 chmod하지 않는다.
Windows는 ACL 인증 adapter가 완료되기 전에는 이 entrypoint의 기록을 거부한다.
고정 슬롯 lock의 WouldBlock은 provider의 2초 timeout보다 짧은 하나의 deadline
안에서 재시도한다. payload 내용과 파일 이름을 argv 진단에 싣지 않는다.

native 훅 생성은 기존 stdin drain·payload 접기·pane 귀속·Codex 부모 PID·tmux
sidecar 로직을 공유하고 마지막 append만 인용된 절대 binary 호출로 바꾼다.
PATH에서 maru를 찾지 않으며 바이너리 경로가 사라지면 조용히 이벤트 기록을 포기한다.
기존 v1에서도 `sh -e`의 append/sidecar 실패가 마지막 exit 0 전에 종료 코드 1을
반환하는 것을 재현했다. 공통 생성기에서 두 쓰기의 실패를 흡수한다. 이 수정은
v1 파일 포맷을 유지하지만 command bytes를 바꾸므로 기존 Codex 신뢰 갱신 절차를 따른다.
native 설치 기본값은 아직 활성화하지 않는다.
이 단계의 새 생성기는 fixture에서 실제 CLI로 검증하며 provider 설정에 설치하지 않는다.
v1 reader/회전기와 구형 in-flight 훅을 v2 기록과 혼합하지 않도록, 기본 활성화는
3·4단계 reader/회전·capability 이행과 함께 한다. 이 경계는 제품 전환 완료가 아니다.

실제 프로세스 gate는 native command→CLI→파일을 대조하고 정상/상한/다중 기록,
잠금 시간 초과·권한·디렉터리 링크·기록기 부재에서도 provider stdout/exit 계약을
검사한다. 합성 HOME와 private temp만 사용하고 사용자 provider 설정은 수정하지 않는다.


기록 CLI와 준비된 native 생성기가 구현됐다. 기존 v1과 native의 실패 종료 계약을
실제 `sh -e`로 검사하며 CLI 도움말과 golden fixture도 함께 갱신했다.
디렉터리 인증은 macOS의 held-fd fstat, Linux의 statx EMPTY_PATH를 사용한다.
Windows는 인증 구현 전 UnsupportedPlatform으로 쓰기 전에 거부한다.

## 3단계 스트리머 구현 경계

`agent-events --log-format=v2`는 인증한 directory handle을 실행 수명 동안 유지한다.
기본 v1 hello/읽기/회전은 호환 경로이며 v2는 hello version 2와 generation cursor를
사용한다. 식별자는 `maru-agent-events-v2`이며 기존 v1 Channel/host 관문이
이를 열거나 offset-only cursor로 저장하지 않는 경계를 검사한다. v2 startup cleanup은 현재 header/EOF/mtime을 공유 잠금 아래 확인한다.
7일 만료와 1 MiB payload 제한을 적용하며 바쁜 파일·sidecar·고정 lock 슬롯은 보존한다.
snapshot lock은 stdout 출력 전에 풀고, flush 성공 뒤에 읽기 위치를 확정한다.
회전은 같은 generation/EOF를 재검사하며 새 빈 generation도 cursor로 출력한다.

v2 sidecar는 nofollow/read-write open 뒤 단일 링크의 0600 regular file과 4096바이트
상한을 확인한다. 이는 FIFO open/read로 소비자가 멈추지 않도록 하며, sidecar는
로그 generation의 일부가 아닌 기존 tmux routing hint다.

`test-agent-log-stream-process`는 실제 product CLI pipe와 native writer로 resume,
같은 크기 교체, 잠금 holder 종료, startup 회전/만료, backpressure 중 append,
broken pipe의 원본 보존, FIFO log/sidecar, directory pathname 교체를 검사한다.
cleanup의 난수/부분 쓰기/rename 실패는 native I/O fault gate에서 원본을 보존한다.
실제 CLI에 적용한 커널 파일 크기 제한도 startup publish 실패 뒤 원본을 보존했다.
macOS Debug/ReleaseFast와 방어 조건 무력화·등가 변형을 확인했다. Linux 실행은
Ubuntu CI에서 확인하며 cross compile만으로 Windows native 실행을 주장하지 않는다.
결과는 ignored artifacts에만 남긴다. 앱의 capability/수신 cursor와 로컬 reader,
기본 훅 설치의 in-flight 이행 및 Windows ACL/native 실행은 완료 범위에 넣지 않는다.

## 4단계 수신과 재접속 계약

hello가 이번 스트림의 capability다. v1 식별자/version 1과 v2 식별자/version 2를
엄격한 JSON으로 판정하고 두 값이 일치해야 연결을 연다. Channel과 host cursor 수집은
같은 판정자를 쓴다. v2 hello를 확인한 host만 재접속에서 `--log-format=v2`와
세대 resume를 보낸다. capability는 host의 앱 수명 동안 보존하고 새 스트림에서는
hello를 다시 확인한다. 확인한 v2를 구버전 peer 때문에 v1으로 낮추지 않는다.

v2 cursor는 gen을 반드시 가지며 길이/문자/타입/중복 오류는 프레임 전체를 거부한다.
v1 cursor에 gen이 있으면 무시하지 않고 거부한다. cursor JSON의 숫자는 문자열로
해석해 u64 상한에서 부동소수점 반올림이 생기지 않도록 한다. 이벤트 hot path의
기존 opaque payload 규칙은 유지하고 작은 hello/cursor만 bounded scratch로 파싱한다.

host는 세대를 offset과 함께 저장하고 늦게 attach하는 Channel도 확인한 profile로
초기화한다. resume 조립은 공통 codec으로 하며, 실패 시 이력을 지우거나 부분/빈
resume로 재생하지 않고 기존 재시도 경로로 실패를 드러낸다. 32개 커서의 최대
이름/u64/세대 예산을 공통 상수와 comptime 검사로 연결한다.

이 단계는 수신·capability·재접속 배선이다. 기존 훅의 기본 설치는 v1을 유지한다.
기본 native 활성화는 로컬 reader와 구형 in-flight 훅의 분리된 이행 경계,
바이너리 경로 수명·Codex 재승인 검증이 닫힌 뒤 적용한다. ACK/Windows ACL은 별도다.

수신부는 hello 확인 전 잡음과 다른 profile 응답으로 재시도 예산이나 생존 시각을
갱신하지 않는다. 재접속 목록은 최대 32개 서로 다른 파일명만 허용하며, 조립 중
할당 실패는 완성된 이전 목록과 host 커서를 보존한다. 원격 접속을 다시 시도할 때
v2 hello로 확인한 host만 `--log-format=v2`와 세대가 포함된 resume를 보낸다.

## 4b단계 로컬 reader 계약

로컬 Term은 설치/이행에서 선택한 profile을 명시적으로 가진다. 기본은 계속 v1이며
파일 내용을 보고 v2로 자동 전환하지 않는다. v2로 선택한 Term만 native snapshot을
읽고 generation과 payload offset을 보존한다. 기존 provider 설정은 이 단계에서
바꾸지 않으며 fixture가 명시적인 v2 경로를 검증한다.

snapshot은 인증한 0700 directory handle과 공유 stable lock으로 읽는다. 처음 읽을
때의 backlog tail window도 header/EOF를 확인한 같은 lease 안에서 결정한다. 잠금,
읽기, 인증 실패는 기존 커서를 변경하지 않는다. 바뀐 generation은 크기/inode와
관계없이 payload 0부터 읽으며 손상된 header를 legacy로 낮추지 않는다. snapshot
buffer는 기존 tick 읽기 상한을 넘지 않고 pathname stat은 할당 크기 힌트로만 쓴다.

이벤트 파싱·귀속·턴 캡처·backlog 알림 억제는 기존 local 소비 경로를 공유한다.
소비 뒤 회전은 읽을 때 유지한 directory handle에서 같은 generation/EOF와 소비
offset을 재검사한다. v1의 rename/tail drain은 v2에 사용하지 않는다. 처리 중 append나
교체가 생기면 회전을 포기하고 다음 tick에서 재확인한다. provider/OS 실행 검증,
구형 in-flight 훅을 다른 파일 namespace로 분리하는 설치 이행 및 binary/trust 수명은
기본 활성화 전에 별도로 닫는다.

backlog 따라잡기의 종료는 버퍼 안의 남은 완전한 줄뿐 아니라 snapshot payload EOF로
판정한다. pathname stat 뒤 append로 파일이 커지면 할당 힌트가 작은 버퍼를 만들 수
있다. 그 부분 chunk를 다 읽었다고 알림 억제를 종료하지 않도록 실제 AppSession의
stat 이후 append fixture로 검사한다.

읽은 EOF에서 회전 publish가 실패하면 커서는 그대로 유지한다. 이후 새 이벤트가
없어도 다음 tick의 동일 세대 EOF snapshot에서 회전만 다시 시도한다. 이벤트 재생과
턴 캡처를 반복하지 않는다. 실제 AppSession에 난수 실패를 주입한 뒤 입력을 추가하지
않고 회전 재시도와 원본 보존을 검사한다.

## 4c단계 훅 format 선택과 이름공간 분리

기본 설치 전환은 세 부분으로 나눈다. 먼저 프로세스에 고정된 format과 분리된
이름공간을 생성기/reader에 연결한다. 다음에 기록 바이너리의 수명·provision과
provider 신뢰 갱신을 검증한다. 마지막에 새 runtime의 env와 재접속 metadata를
연결하고 실제 provider 전환을 검사한 뒤 기본 활성화한다. 이미 살아 있는 runtime의
format을 설정 파일 변경만으로 바꾸지 않는다.

첫 부분의 준비된 이행 커맨드는 local context에서 `MARU_AGENT_LOG_FORMAT`, remote
context에서 `LC_MARU_LOG_FORMAT`을 읽는다. 미지정은 v1, 정확한 `1`/`2`만 허용한다.
빈 값·미지 버전·형식 오류는 stdin을 끝까지 비운 뒤 기록 없이 exit 0이며 v1로
내리지 않는다. local identity가 있으면 remote format은 사용하지 않는다.

v1은 기존 디렉터리와 셸 append를 사용한다. v2는 local
`.cache/maru/agent-turn-events-v2`, remote `.cache/maru/remote-agent-events-v2`를
사용하고 절대 binary의 native record만 호출한다. 생성기의 네 디렉터리는 canonical
absolute path이며 서로 동일하거나 조상/자손이면 거부한다. 실제 native I/O의
nofollow/UID/권한 인증은 계속 별도로 적용한다. 임의 path alias의 물리적 동일성을
순수 문자열 검증이 증명한다고 주장하지 않는다.

reader는 선택한 profile의 이름공간만 읽는다. 구형 로그를 변환하거나 지우지 않는다.
오래 전에 생성한 v1 커맨드가 늦게 실행돼도 v2 header와 native 회전에 닿지 않는지,
서로 다른 scope의 format·불명확한 값·binary 부재·quote와 stdin drain·실패 종료
계약을 합성 HOME의 실제 프로세스로 검사한다. 이 준비 단계는 provider 설정을
자동 전환하거나 기존 runtime env를 변경하지 않는다.


## 4c-2 바이너리 수명과 신뢰 검증

로컬 준비 명령의 실행 경로는 기존 앱의 형제 `maru` CLI 절대 경로를 사용한다.
별도 복사 캐시나 PATH 검색을 도입하지 않는다. 같은 설치 경로의 atomic binary
교체는 command bytes와 Codex hash를 바꾸지 않는다. 삭제·이동 중 경로 부재는 기존
계약대로 기록 없이 exit 0이고 v1 fallback이 없다. 앱 이동 후 새 경로를 반영하면
command가 바뀌므로 기존 trust reconciliation을 반드시 다시 적용해야 한다.
이 계약은 업데이트가 구형 record 프로토콜 호환성을 유지한다는 조건이며, 다른
실행 파일을 해당 경로에 바꿔 놓는 공격에 대한 새 인증 보장을 뜻하지 않는다.

검증은 합성 bundle의 CLI 교체·제거·재배치에서 보관한 훅을 실제 실행한다.
Codex hash는 전환 명령과 기존 `agent_hook_trust`로 계산하고 installed Codex의
`hooks/list`를 독립 oracle로 대조한다. 실제 provider 검증은 opt-in이며 계정·모델
요청 없이 격리 CODEX_HOME의 app-server만 사용한다. 신뢰 정상·명령 변경 후 modified·
기존 reconciliation 후 trusted와 사용자 승인 값의 divergence 보존을 구분한다.
실제 설치와 runtime env 기본 전환은 이 검증 뒤 별도 단계로 유지한다.


## 4c-3 runtime format 고정 경계

먼저 PTY 생성 요청에 typed profile(default v1)을 둔다. format enum과 env 이름은
OS 없는 중립 leaf에서 공유하고, namespace·명령 생성 정책은 기존 session 모듈에 둔다.
부모 snapshot·명시 env·사용자 override의 local format은 제거하고 요청의 profile을
마지막에 한 번 주입한다. 기존 runtime의 환경은 변경하지 않는다. GUI가 host에
넘기는 process-local identity는 기존대로 제거한다. metadata/capability 배선 전의
명시적 v2 persistent 요청은 spawn 전에 거부하며 조용히 v1로 낮추지 않는다. 이 경계가 재접속 metadata와 capability
협상을 대신하지 않는다. host state·upgrade handoff·attach 관측에 immutable profile을
연결한 후에만 v2 기본값을 활성화한다.
