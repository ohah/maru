# Session host 외부 명령 실행 경계

`src/platform/macos/session_host/bounded_process.zig`는 release adapter와 codesign 관측 명령의
capture·관측·receipt pipe·framed socket 수명을 소유한다. PTY 셸이나 session host daemon의
launcher는 이 계약 밖이다.

## 생성과 그룹 소유권

macOS 생성은 `src/pty/macos_spawn.zig`의 `spawnGrouped`에 위임한다. Apple의
[posix_spawnattr_setpgroup(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setpgroup.3.html)에
따라 `SETPGROUP`과 group 0을 사용한다. 자식 프로그램이 실행되기 전에 PID와 같은 ID의 그룹을
만들며, 부모와 자식이 각각 `setpgid`를 호출하지 않는다. 반환한 PID의 그룹만 종료하고 direct child를 reap한다.

`CLOEXEC_DEFAULT`로 명시한 FD만 전달한다. capture는 stdio만, receipt/socket은 stdio와 fd 3만
전달한다. 현재 soft limit보다 높은 non-CLOEXEC FD도 상속하지 않는다. 매핑 원본은 모든 목적지보다
높은 `F_DUPFD_CLOEXEC` 사본으로 먼저 고정한다. 닫힌 stdio 때문에 원본이 0..3에 생겨도 앞선 매핑이
뒤 매핑의 원본을 덮어쓰지 않는다. 임시 사본은 성공·준비 실패·생성 실패 모두에서 부모가 닫는다.
공통 native 호출은 기존 helper 안에 하나만 둔다.

held-directory는 매핑 전에 `addfchdir_np`로 cwd vnode에 결속한다. `./leaf` 실행도 이 cwd를
사용하며 부모 cwd는 바꾸지 않는다. regular input FD는 caller 소유이고, validation 뒤 spawn 전에
공유 file-description offset을 0으로 돌린다. 따라서 생성 실패에도 offset은 0일 수 있다. caller는
이 FD에 대한 병행 seek/read를 직렬화해야 한다. 부모 FD의 identity·CLOEXEC·소유권은 바꾸지 않는다.
grouped spawn은 기존 bounded exec처럼 신호 마스크와 무시 처분을 상속한다. 일반 shell helper의
기본 신호 처리 복원 정책은 별도다.

## 실패와 시간 예산

- validation 실패는 기존 `Invalid*` 오류다. FD 준비나 file-action 준비 실패는 `SpawnSetupFailed`다.
- executable 부재·실행 권한 거부 등 native 생성 실패는 `SpawnFailed`다. 존재하지 않는 child를
  exit 126으로 합성하지 않으며, inherited owner도 발급하지 않는다.
- 실제 실행된 프로그램의 nonzero/signal은 capture에서 `ChildFailed`, observation에서 실제
  `Termination`이다. 프로그램이 스스로 exit 126을 반환하면 observation도 `.exited = 126`이다.
- capture·observation·digest·held-file write는 validation 뒤 FD 준비부터 하나의 absolute awake-clock
  deadline을 쓴다. spawn 뒤 새 예산을 시작하지 않는다. 예산 소진 시 출력 성공을 공개하지 않고
  그룹 종료와 direct-child reap을 마친다. native 생성 syscall 자체를 선점하거나 중단하는 보장은 없다.
- receipt/socket 생성은 시간 예산 인자를 받지 않는다. 반환한 owner의 read/write/wait가 각 호출의
  예산을 소유하며, 실패 뒤에도 terminate 권한을 유지한다.

## 검증

`zig build test-session-host-bounded-process`는 Debug·ReleaseFast에서 실제 child와 C FD oracle을
사용한다. 두 stream의 cap·EOF·상태, held cwd/input, descendant timeout, 반복 FD delta,
닫힌 stdio 하나씩·모두, fd 3 alias, 높은 ambient FD, 부분 source-pinning 실패의 cleanup,
실제 exit 126과 생성 실패의 구별을 검사한다. C oracle은 shell이 descriptor를 바꾸기 전에 검사한다.

원래 실패 소비자의 경로는 `zig build test-session-host-release-adapter-profile-authored-attestation-fence`다.
검증 상태와 한계는 [검증 매트릭스](verification-matrix.md), 진행은
[구현 계획](plans/bounded-process-spawn.md)이 소유한다.


## POSIX 테스트 호스트

같은 release-adapter는 Linux CI에서도 실제 자식을 실행한다. Darwin 전용 spawn action을 Linux에서
분석하지 않도록 `bounded_process_fork.zig`에 기존 fork/exec·부모/자식 그룹 설정·FD close 경로를
유지한다. macOS 분기는 이 backend를 실행하지 않는다. Linux의 exec 실패는 종전처럼 capture의
`ChildFailed` 또는 observation의 exit 126이며, macOS의 native 생성 실패와 별도로 검증한다.
두 경우 aggregate-child의 최종 reducer 판단은 `audit_required`다. 단일 시간 예산은 두 backend가 공유한다.
