# PTY native spawn 비교 PoC

2026-11-05, macOS 26.5.1 arm64·Apple clang 17·SDK 26.2의 제품 이관 전 비교 실험이다. 제품의 `PtySession`은 변경하지 않는다.
[stdio 소유권](pty-stdio-ownership.md) 수정 이후에도 생성 순서는
`openpty → fork → setsid → TIOCSCTTY → cwd fallback → dup2 → execve`다.

## 방법과 관측

`tools/pty-spawn-poc/probe.c`는 공개 syscall만 사용하는 독립 C 모형이다.
`run.py`가 새 임시 디렉터리·명시 환경에서 21개의 서로 다른 조건을 네 방식과
C `-O0`·`-O2`로 비교한다(168개 관측). Zig Debug/ReleaseFast나 실제 제품 E2E 결과가 아니다.

| 방식 | 새 session/group | 제어 터미널·foreground | cwd 실패 폴백 | 주변 FD 83 |
| --- | --- | --- | --- | --- |
| `fork` (현재 syscall 순서 모형) | 확보 | 확보 | HOME, 이후 상속 cwd | 직접 exec에서 상속 |
| `spawn-dup` (SETSID + slave dup2) | 확보 | 미확보 | ENOENT, 생성 실패 | 차단 |
| `spawn-open` (SETSID + slave pathname open) | 확보 | 미확보 | ENOENT, 생성 실패 | 차단 |
| `spawn-helper` (SETSID + fresh exec + TIOCSCTTY) | 확보 | 확보 | HOME, 이후 상속 cwd | 차단 |

`isatty(0..2)=true`만으로 성공 판정하지 않는다. `/dev/tty` 열기, `tcgetpgrp`,
PID/SID/PGID와 실제 PTY Ctrl+C의 SIGINT 종료를 함께 검사한다.
직접 native 두 방식은 Ctrl+C로 끝나지 않아 유예 뒤 **검증 도구가 SIGKILL**로 정리한다.
이는 예상된 부적합 결과이며 native가 제품 계약을 통과했다는 뜻이 아니다.

21조건: 정상, 닫힌 stdio 7배치, 기존 stdio CLOEXEC 3배치, 실제 입력,
공백·따옴표·달러를 포함한 argv/env, 공백 cwd, 없는 cwd + 정상 HOME/없는 HOME/실패 HOME,
exit 42, 없는 executable, 실제 `/usr/bin/login -q -flp` + 무설정 bash `exec -l`, terminal Ctrl+C.
각 성공 probe는 stderr, 91×27 크기와 fully-reaped 상태도 확인한다.
login은 supervisor가 남아 PID와 PGID가 다를 수 있으므로 session/group/foreground를 비교하고,
login argv0와 `getlogin()`을 확인한다. login 자체가 주변 FD를 닫는 결과와 직접 exec를 구분한다.

## 검증 도구의 대조군

네 가지 독립 손상(helpers의 TIOCSCTTY 제거, CLOEXEC_DEFAULT 제거, HOME 폴백 제거,
FD promotion 제거)은 컴파일 후 실제 관측 불일치로 거부됐다. FD 복제 최소값을 3에서 4로
바꾼 동등 대조군은 168개 관측이 유지됐다. 반복 실행만으로 조건 수를 채우지 않는다.
초기 도구의 Ctrl+C 후 재전송/정리 오류와 login이 닫는 FD에 대한 잘못된 기대는 수정해
해당 초기 자료를 최종 결과에서 제외했다. 원문은 별도 보존한다.

## 판단

**현재는 기존 backend를 유지한다.** `POSIX_SPAWN_SETSID`와 file actions만으로의
단순 교체는 측정한 제어 터미널·foreground·Ctrl+C·cwd 폴백 계약을 만족하지 못한다.
helper는 제한된 모형에서 호환 후보지만 제품 채택 결정은 아니다.

제품 이관을 검토하려면 helper의 번들 경로·서명/업데이트·실행 권한·요청 전달과
초기화 실패 보고를 먼저 설계해야 한다. 그 뒤 실제 `PtySession`에 연결해 login 셸의
job control(stop/resume/foreground 전환), resize/SIGWINCH, signal 상속·정리, concurrent spawn,
host upgrade/reattach와 사용자 셸 설정을 검증한다. 이번 PoC는 이 경로·성능 개선·macOS 타 버전
호환성·전체 FD allowlist를 증명하지 않는다. helper 없이 가능한 모든 OS 기법의 불가능성 증명도 아니다.

## 재현과 근거

[도구 설명](../../tools/pty-spawn-poc/README.md)의 명령으로 실행한다.
관측 원문·소스/바이너리·컴파일러/SDK·Git HEAD를 외부 artifact에 남긴다.
기존 `PtySession`의 실제 테스트는 별도 `test-pty-stdio`가 소유하며 이 모형으로 대체하지 않는다.

공개 API 근거는 Apple [posix_spawn(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html),
[setsid(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsid.2.html),
[tty(4)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man4/tty.4.html)와
설치 macOS SDK `sys/spawn.h`의 `POSIX_SPAWN_SETSID`·`POSIX_SPAWN_CLOEXEC_DEFAULT`,
`spawn.h`의 addopen/adddup2/addchdir다. SDK 상수를 직접 포함하며 숫자 사본을 만들지 않는다.
다른 터미널 구현 소스를 열람·복사하지 않았다.

후속 [helper 적용 조건과 실제 셸 수명 PoC](pty-helper-lifecycle.md)는 bash job control과 resize,
환경 간섭으로 제외한 zsh 자료, 번들·실패 전달의 검토안을 구분한다.
