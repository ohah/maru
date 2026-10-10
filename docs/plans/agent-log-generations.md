# 에이전트 로그 세대와 이어읽기

## 상태

설계 확정. 사용자는 명시적인 세대 ID와 offset의 공통 계약에 이어 native 기록기
방식으로 후속 구현을 진행하도록 승인했다(2026-10-11). 아래는 단계별 구현 계획이며
각 단계의 라이브 배선과 OS 검증이 완료되기 전에는 제품 지원 완료를 뜻하지 않는다.
현재 다음 작업은 1단계 순수 codec과 reconciliation이다. peer ACK는 별도 범위다.

## 현재 경로와 필요한 변경

`agent_hook_command.build`는 셸 내장 printf로 로그를 append한다. 이 함수의 주석은
추가 프로세스를 쓰지 않는 성능 전략과 항상 exit 0인 provider 훅 계약을 설명한다.
현재 Windows 전용 native 기록기는 없으며 POSIX 셸 커맨드 검증 경로와 Windows native
지원은 구분한다. 로그에 UUID를 추가하는 것만으로는 기록과 회전 사이의 경쟁을 해결하지 못한다.

새 native 기록기는 난수 생성, 헤더 확인과 append를 잠금 안에서 수행한다. 단순히 매
이벤트마다 UUID를 바꾸지 않는다. 파일의 새 세대 생성과 회전 때만 생성한다.
기존 inline 셸의 payload 상한·Codex parent attribution·tmux sidecar·stdin drain은
그대로 유지해야 한다. native 기록기 호출 방식은 추가 프로세스 비용 및 실패해도
provider를 막지 않는 계약을 함께 재야 하므로 전략 변경 논의가 필요하다.

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
