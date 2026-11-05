# PTY helper 적용 조건과 실제 셸 수명 PoC

[첫 비교](pty-native-spawn-poc.md)의 후속이다. **제품 backend 이관은 하지 않는다.**
독립 syscall 모형의 실제 bash 작업 제어를 검증하고, 제품 이관에 필요한 설계 선택을 남긴다.
아래 helper 배치·프로토콜은 검토안이며 구현된 제품 계약이 아니다.

## 실제 셸 검증

`probe.c`의 `spawn_target` 하나를 기존 캡처 실험과 새 live bridge가 공유한다.
bridge는 부모가 만든 PTY를 fork 또는 fresh-exec helper에 연결하고,
별도 채널로 root PID·실제 wait status·reap 완료를 보고한다.
`live.py`는 PTY와 종료 채널을 함께 읽고 실제 shell/job의 SID·foreground 그룹·정지 상태를 대조한다.

`lifecycle.py`의 서로 다른 20조건은 다음과 같다.

| 범위 | 조건 |
| --- | --- |
| 초기/로그인 | stdio tty·session/foreground, 실제 login wrapper와 login shell 옵션 |
| foreground | Ctrl+C(SIGINT), Ctrl+Z 정지, fg 재개, Ctrl+\\(SIGQUIT), exit 42 전달 |
| background | bg 재개·foreground 유지, 입력 SIGTTIN·출력 SIGTTOU와 jobs의 정지 사유, wait exit 42 |
| 종료 | master 닫힘의 SIGHUP(명시 trap exit 77), 셸 EOF, root reap |
| 크기 | foreground job SIGWINCH, shell trap SIGWINCH와 크기, 세 크기의 순차 반영 |
| 입력/상태 | 정지/재개 뒤 stdin, raw 모드의 Ctrl+C byte 3, cwd/env/argv 보존, 없는 명령 127 뒤 사용 가능 |

macOS 26.5.1 arm64·clang 17·SDK 26.2에서 bash 20조건 × fork/helper × C O0/O2 = 80개를 대조한다.
같은 조건을 다른 mode로 반복한 것을 독립 조건 수에 더하지 않는다. C O0/O2는 Zig Debug/ReleaseFast가 아니다.
사용자 셸 설정은 로드하지 않는 인자를 쓰며 HOME·환경을 격리한다. 실제 login 명령은 OS accounting에 영향을 줄 수 있다.

### 오판과 제외한 자료

- 초기 fixture는 종료 채널을 기다릴 때 PTY를 읽지 않았다. 출력 drain 없이 종료 관측이 지연되는 것을
  재현했고 두 채널을 함께 pump하도록 고쳤다. `missing-exit-drain` 변이는 이 회귀를 잡는다.
- bash history expansion으로 `$!` 명령이 실패하던 fixture를 초기화에서 명시적으로 끈다.
- 출력 조각 시작을 줄 시작으로 인정하지 않던 크기 정규식을 바로잡았다.
- 명령의 printf marker는 다음 readline 준비와 같지 않다. 최종 fixture는 명령 뒤 실제 PS1까지 읽는다.
  WINCH handler 뒤에는 별도 no-op 명령 완료를 기다린다(신호 뒤 PS1이 다시 출력된다고 가정하지 않는다).
- 보강 전의 `stty size` 27×91 기록은 보존한다. 후속 [인과 대조](pty-resize-overwrite.md)는 bash 사본이
  부모 뒤에 오래된 TIOCSWINSZ를 쓰는 동일 현상을 재현했다. 최초 1건의 writer 소급 단정과 제품 수정 완료는 아니다.
  80조건은 프롬프트 준비 경계의 검증이며 임의 전환 중 resize 전체를 증명하지 않는다.
- 이 머신의 `/etc/zshenv`는 `zsh -f`에서도 별도 background 명령을 실행했다.
  zsh의 job/EOF/HUP 결과는 환경 간섭 모집단으로 전부 제외한다. 시스템 파일은 수정하지 않았다.
  기본 실행은 bash만 쓰며 zsh는 명시 opt-in이고 system zshenv에 실행문이 있으면 실행 전 거부한다.
  깨끗한 host에서의 zsh 검증은 남아 있다. root 소유 init 파일/관련 작업은 이번 변경으로 정리하지 않는다.

세션 생성, SIGTSTP, raw 설정, WINCH handler, 종료 시 PTY drain을 제거한 다섯 독립 변이는
컴파일 뒤 실제 선택 조건에서 거부된다. 동등 pause-loop 대조군은 통과한다.
원래 21조건/168개 비교와 그 변이 대조군도 공통 launcher 추출 뒤 별도로 재실행한다.

## 제품 적용 설계 검토안

| 후보 | 이점 | 제품 적용 전 필요한 증거 |
| --- | --- | --- |
| 현재 CLI/host image의 내부 helper 진입점 | 별도 실행 파일 버전·서명 불일치 축을 줄일 수 있음 | 앱/CLI/동결 host 모두의 초기 dispatch, 실행 중 image의 고정과 버전·capability, 업데이트 뒤 경로 수명 |
| 별도 번들 helper | 최소 초기화 코드와 독립 책임 | inside-out 서명·아키텍처·Team ID/요구식, 배치·권한·업데이트·미설치/변조/구버전 오류 |

현재 `src/main.zig`는 `__session-host` 내부 CLI dispatch를 갖고, session-host launcher는
명시 executable 경로로 실행한다. **이것이 GUI executable에도 새 helper entry가 있다는 뜻은 아니다.**
`selfExePath`만 붙여 교체하면 GUI가 뜨거나 오래된 host가 새 진입점을 모를 수 있다.
실제 frozen image와 bundled CLI의 관계·초기화 지점을 각 제품 경로에서 먼저 확인해야 한다.
외부 PATH/사용자 환경변수로 helper를 고르거나 실행 중인 구 host가 새 bundle 경로를 무조건 쓰는 안은 채택하지 않는다.
현재 단계에서는 두 후보 중 제품 선택을 확정하지 않는다. 서명·업데이트의 기존 권위는
[배포](../distribution.md)와 [host upgrade](../session-host-upgrade.md)를 유지한다.

### 초기화 실패 전달의 검토안

1. 부모가 command/argv/env/cwd와 stdio·상태 채널을 준비한다. 새 session과 FD 매핑은 native spawn이 소유한다.
2. fresh helper는 제한된 FD와 요청 버전을 검증한 뒤 controlling tty·cwd 폴백·target exec를 수행한다.
3. 실패 채널은 고정 길이 version/stage/errno를 사용하고, target exec 때 닫히도록 helper가 CLOEXEC를 설정한다.
   길이 상한·잘림·중복·알 수 없는 단계·FD 소진·읽기 실패·즉시 사망·취소·timeout은 별도 대조가 필요하다.
4. **PID 반환은 ready가 아니고 EOF만으로 exec 성공을 증명하지 않는다.** 오류 없는 채널 EOF와
   실제 target readiness/종료는 구분한다. 사전 준비부터의 단일 deadline과 부모의 정확한 child/group 회수를 설계한다.
5. 요청/오류 FD는 target에 남기지 않는다. 기존 tty·cwd·login·foreground/cleanup 계약을 모형이 아닌 실제 `PtySession`으로 재검증한다.

지금의 모형은 초기화 실패를 126/127로만 관측한다. errno/stage 전달과 제품 성공 상태 전이는 아직 구현하지 않았다.
서명된 GUI/CLI/frozen-host 실증, 실패 채널, signal 상속·동시 spawn, 사용자 셸 설정,
다른 macOS 버전·host upgrade/reattach 검증 전에는 helper 채택이나 제품 이관 완료를 주장하지 않는다.

## 실행과 공개 API 근거

[명령과 결과 보존](../../tools/pty-spawn-poc/README.md)을 따른다.
Apple [tcsetpgrp(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/tcsetpgrp.3.html)의
동일 session/controlling-terminal 계약과 설치 SDK termios·ttycom ioctl/signal 상수를 사용한다.
레퍼런스 구현 코드는 복사하지 않았으며 제품 소스·빌드·번들 서명 설정은 변경하지 않는다.
