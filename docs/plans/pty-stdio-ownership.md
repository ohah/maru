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
- 남은 범위: PTY 전체 native 이관은 setsid·제어 터미널·foreground·login·cwd 폴백을
  실제 OS에서 대조하는 PoC가 먼저다. 이번 변경은 임의의 주변 FD 전체 차단을 구현하지 않는다.

최종 로컬·경계·원격 CI 결과와 제한은 Draft PR 본문/checks가 기록한다.

공개 API 근거: Apple [dup2(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/dup2.2.html)의 FD 대체와 복제 규칙,
[fcntl(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)의 FD_CLOEXEC 규칙을 따른다.
`F_DUPFD_CLOEXEC` 상수와 호출 표면은 현재 macOS SDK의 `sys/fcntl.h`로 확인했다.
