# PTY stdio 경계와 끝점 소유권

기존 fork/setsid/TIOCSCTTY 구조에서 닫힌 stdio가 PTY 끝점에 재사용되는 결함을 고친다.
LSP·formatter의 grouped spawn을 그대로 쓰는 이관은 제어 터미널 계약을 만족하지 않는다.

- 구현: 낮은 master/slave를 부모에서 3 이상으로 이동하고 두 끝점에 CLOEXEC를 적용한다.
- 실패: 이동한 FD를 즉시 소유 변수에 반영해 부분 준비 실패에서도 닫는다.
- 회귀: tty·session/group·foreground·크기·stdin/stdout/stderr·cwd/env/argv·실제 종료·FD/reap을 검사한다.
- `test-pty-stdio`: 독립 C probe, 서로 다른 20조건, Debug·ReleaseFast 각각 20 compiled/20 passed.
  stdio의 8배치, CLOEXEC 3배치, 입력 2배치, 혼합 플래그, cwd/env, HOME/상속 폴백,
  비정상 종료, 실제 fork 직전 FD 플래그, 자원 고갈 중 부분 이동 회수를 대조한다.
- 기존 소스는 20조건 중 14개가 각 모드에서 실패했다. 수정 후 두 모드가 통과한다.
- 기존 통합 fixture도 최종 reader 수명에서 stop/join 뒤 deinit을 호출해 transfer 버퍼를 회수한다.
  join은 pause/resume용 버퍼를 보존하는 API다.
- 반복 가능한 셸/reader 회귀는 `MARU_INTERACTIVE_SHELL=/bin/sh zig build test-pty`와 ReleaseFast를 사용한다.
  사용자 셸/dotfile을 쓰는 기본 opt-in 실행의 시작 시한은 별도 모집단으로 보존한다.
- PTY 전체 native 이관은 채택하지 않았다. 비교 PoC는 별도 조사 자료이며,
  이번 변경은 임의의 주변 FD 전체 차단을 구현하지 않는다.

최종 로컬·경계·원격 CI 결과와 제한은 Draft PR 본문/checks가 기록한다.

공개 API 근거: Apple [dup2(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/dup2.2.html)의 FD 대체와 복제 규칙,
[fcntl(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)의 FD_CLOEXEC 규칙을 따른다.
`F_DUPFD_CLOEXEC` 상수와 호출 표면은 현재 macOS SDK의 `sys/fcntl.h`로 확인했다.


머지 검토에서 수동 ReleaseFast의 기존 EOF fixture 경쟁을 확인했다. 완성 응답 수신 뒤에는
peer가 아직 열려 있을 수 있으므로, peer close 완료를 기다린 뒤 EOF를 단언한다.
추가 held-peer 대조군은 열린 동안 null·연결 유지, 닫힘 완료 뒤 terminal/source-zero를
legacy·generation 양쪽에서 검사한다. 기존 C3 cadence 12개(30개 실제 소켓 조건)를 두 모드에서 실행한다.
peer close를 보류한 채 원래 EOF 기대를 적용하면 두 모드에서 CI와 같은 실패가 재현됐다.
제품의 비차단 읽기 계약은 유지한다.

수동 editor ReleaseFast의 콜드 실행도 1502/2019까지 진행하다 잡 예산 35분으로 중단돼
전체 잡 예산을 50분으로 보완했다. 개별 테스트 시한과 단언은 유지한다.
사용자 기본 셸 시작 시한 건은 수정 전 backend에서도 재현한 별도 opt-in 환경 조건이다.

후속 [native spawn 비교 PoC](pty-native-spawn-poc.md)는 제어 터미널·cwd 폴백의 실제 OS 차이를 기록한다.
제품 backend 이관과 비교 모형의 결과를 구분한다.


후속 [fork 초기화 실패 전달](pty-fork-setup-status.md)은 기존20조건을 유지하고28개 실패/상태 조건을 더해
`test-pty-stdio`를 두 모드 각각48개로 확장한다. 제품은 fork/exec를 유지한다.
