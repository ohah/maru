# PTY 운영 모델

이 문서는 macOS 초기 `PtySession`을 어떻게 운영할지 정한다.

## 결론

초기 macOS 구현은 `openpty`를 사용한다.

`forkpty`는 사용하지 않는다. `forkpty`는 PTY 생성, fork, child stdio 연결, controlling terminal 설정을 한 번에 감춰서 초기 구현은 짧아지지만, 나중에 process group, pre-exec, fd lifecycle, failure artifact를 세밀하게 다루려면 다시 뜯어야 한다.

`posix_openpt + grantpt + unlockpt + ptsname`도 지금은 사용하지 않는다. 그 방식은 PTY 생성 과정을 가장 낮은 수준에서 제어할 수 있지만, 현재 단계에서 필요한 것은 slave path 조립이 아니라 child setup과 event 흐름을 안정적으로 검증하는 것이다.

그래서 Maru의 첫 실제 PTY backend는 중간 지점인 `openpty`를 사용한다.

```text
openpty
-> master/slave fd 획득
-> fork
-> child: setsid + TIOCSCTTY + dup2(slave, stdin/stdout/stderr) + exec
-> parent: slave close, master fd 보관
```

이 선택은 최고 성능 설계가 아니라, 초기에 충분한 제어권을 가지면서도 테스트하기 쉬운 설계다. 여러 surface가 매우 많아지면 macOS `kqueue` 기반으로 바꿀 수 있지만, 먼저 맞춰야 할 것은 속도가 아니라 책임 경계와 재현 가능한 event 흐름이다.

현재 `PtySession` 최소 구현은 테스트가 통제할 수 있도록 blocking pull API인 `readEvent`를 먼저 제공한다. 앱 runtime 단계에서는 `PtyReader`가 이 `readEvent` 루프를 별도 reader thread에서 실행하고, `PtyEventQueue` bounded queue를 통해 app/runtime loop로 넘긴다. 즉 `PtySession` backend는 여전히 thread를 직접 소유하지 않고, app layer가 reader lifecycle을 조립한다.

## 기본 흐름

```text
PtySession.spawn(command)
  -> openpty로 master/slave fd 생성
  -> fork
  -> child process 실행 전 controlling terminal과 stdio 연결
  -> parent는 master fd 보관하고 slave fd close
  -> blocking readEvent로 output/exit event 읽기

PtyReader thread
  -> readEvent 루프 실행
  -> PtyEvent.output 생성
  -> PtyEventQueue bounded queue에 넣기

app/runtime loop
  -> queue에서 QueuedPtyEvent 꺼내기
  -> SurfaceRuntime.applyPtyEvent
  -> Surface.TerminalCore.write
  -> snapshot/artifact 갱신
```

## 왜 `openpty`인가

비교하면 다음과 같다.

| 방식 | 장점 | 손해 | Maru 판단 |
| --- | --- | --- | --- |
| `forkpty` | 코드가 가장 짧고 초기 spike가 빠르다. | child setup이 감춰져 pre-exec, controlling terminal, fd lifecycle, 실패 단계별 artifact를 나중에 다시 뜯어야 한다. | 사용하지 않는다. facade 뒤에 숨겨도 장기 구조와 테스트가 약해질 가능성이 크다. |
| `openpty` | master/slave 생성은 맡기고, fork/exec/pre-exec/stdio 연결은 직접 통제한다. | `forkpty`보다 코드가 길다. | 초기 구현으로 채택한다. Ghostty와 유사한 제어 지점을 얻으면서 `posix_openpt`보다 단순하다. |
| `posix_openpt` | PTY master 생성부터 slave unlock/name/open까지 가장 낮은 수준에서 제어한다. | boilerplate와 실패 지점이 늘고 OS 차이를 더 많이 떠안는다. | 나중에 `openpty`가 막는 요구가 생길 때만 검토한다. |

## 왜 reader thread인가

현재 구현의 자동 테스트는 blocking `readEvent`를 직접 호출한다. 통제된 command는 출력 후 종료되므로 테스트가 스레드와 타이밍 경합 없이 PTY 계약을 검증할 수 있다.

SurfaceRuntime이 live shell을 연결하는 시점에는 reader thread를 둔다.

대안은 macOS `kqueue` 또는 nonblocking fd event loop다. 장기적으로는 좋지만 초기에는 다음 비용이 크다.

- platform event loop와 app event loop를 동시에 설계해야 한다.
- 테스트에서 timing race가 늘어난다.
- 초보자가 읽기 어렵다.
- parser/PTY/surface 책임 경계보다 OS I/O 세부사항이 먼저 커진다.

reader thread는 단순하다.

- PTY output을 읽는 책임이 한 곳에 있다.
- UI/runtime loop는 queue만 drain하면 된다.
- deterministic command test를 만들기 쉽다.
- queue event의 output bytes는 queue consumer가 소유권을 끝낸다. 그래서 consumer는 `SurfaceRuntime.applyPtyEvent` 후 `QueuedPtyEvent.deinit`으로 bytes를 해제해야 한다.

## backpressure 정책

PTY output은 임의로 버리지 않는다.

SurfaceRuntime 단계의 queue는 bounded로 둔다. queue가 가득 차면 reader thread는 기다린다. 그러면 PTY master fd를 더 읽지 못하고, 결국 child process stdout도 막힐 수 있다.

이것은 의도된 backpressure다.

터미널은 로그를 잃어버리면 안 된다. 메모리를 무한히 늘리는 것보다 child process가 잠시 느려지는 편이 낫다.

```text
대량 stdout
-> reader thread
-> queue full
-> reader blocks
-> child stdout blocks
-> UI/runtime loop가 drain하면 다시 진행
```

## UTF-8과 escape sequence 경계

PTY read는 byte chunk 단위다. 한글이나 이모지 같은 multi-byte UTF-8 문자는 두 read 사이에서 잘릴 수 있다.

따라서 `PtySession`은 bytes를 있는 그대로 event로 내보낸다. UTF-8 증분 디코딩과 escape parser 상태는 `TerminalCore`가 가진다.

```text
PtySession
  bytes chunk를 모른 척 전달

TerminalCore
  partial UTF-8 tail 보관
  parser state 보관
```

이렇게 해야 read chunk 크기가 달라도 화면 결과가 같아진다.

## input write 정책

초기 input은 작다. 사용자가 누른 key나 paste 일부가 대부분이다.

초기 구현은 `SurfaceRuntime.writeInput(surface_id, input)`이 해당 `PtySession.writeInput(bytes)`를 호출한다.

나중에 paste가 매우 크거나 write가 막히는 문제가 보이면 output처럼 write queue를 둔다. 초기에는 설계를 복잡하게 만들지 않는다.

## resize 순서

resize는 두 곳에 반영되어야 한다.

1. `TerminalCore.resize(cols, rows)`
2. `PtySession.resize(cols, rows)` 또는 `ioctl(TIOCSWINSZ)`

초기 정책은 하나의 `SurfaceRuntime.resize`에서 둘을 함께 호출한다. 실패 artifact에는 core resize 성공 여부와 PTY resize 성공 여부를 모두 남긴다.

## process exit

현재 `readEvent`가 EOF를 보거나 child process 종료를 감지하면 `PtyEvent.exited`를 반환한다. SurfaceRuntime 단계에서는 reader thread가 같은 event를 queue에 넣는다.

`SurfaceRuntime`은 이 event를 받아 surface metadata를 갱신한다. 이때 surface 자체를 바로 삭제하지 않는다. 사용자는 종료된 surface의 마지막 화면을 볼 수 있어야 하기 때문이다.

## session close

이미 `PtyEvent.exited`로 종료가 관측된 session은 close 시 child를 다시 건드리지 않는다. 아직 살아 있는 child를 close할 때는 zombie를 남기지 않으면서도 shell이 정리할 기회를 주기 위해 신호를 단계적으로 올린다.

```text
close (child가 아직 살아 있을 때)
  -> master fd close
  -> SIGHUP  (process group + child) + 짧은 grace 동안 reap 시도
  -> SIGTERM (process group + child) + 짧은 grace 동안 reap 시도
  -> SIGKILL (process group + child) + blocking reap
```

`setsid`로 child가 process group leader가 되므로 group(`-pid`)과 child(`pid`) 양쪽에 보낸다. grace는 짧고 상한이 있어 close가 오래 멈추지 않는다. 마지막 `SIGKILL`은 무시할 수 없으므로 blocking reap이 반드시 진행되어 zombie가 남지 않는다.

이 escalation은 현재 `deinit`에서 동기적으로 수행한다. reader thread가 `readEvent` 안에서 blocking 중인 interactive shell shutdown은 아직 별도 app lifecycle로 묶지 않았다. close 경로를 app host와 조립할 때도 "신호를 올리며 반드시 reap한다"는 계약은 동일하게 유지한다.

## 초기 테스트

- controlled command가 stdout bytes를 event로 낸다.
- output event는 drop되지 않는다.
- process exit가 `PtyEvent.exited`로 관측된다.
- resize request가 PTY layer까지 전달된다.
- 아직 살아 있는 child를 close할 때 HUP/TERM을 무시해도 escalation으로 reap되어 zombie가 남지 않는다.

SurfaceRuntime reader thread 단계에서 추가된 테스트:

- queue가 가득 찼을 때 무한 메모리 증가가 없다(`tryPush`가 `QueueFull`을 반환하고, 실제 reader 경로는 `pushBlocking`으로 기다린다).
- reader thread가 실제 macOS PTY controlled command output/exit를 bounded queue에 넣고, app/runtime loop가 이를 `SurfaceRuntime`에 적용한다.

아직 추가하지 않은 테스트:

- 대량 stdout에서 reader가 오래 backpressure를 걸 때 memory와 responsiveness가 유지되는지.
- 늦게 도착한 output이 detach된 surface로 흘러가지 않는다.
- reader thread 종료와 process exit가 trace에 같은 domain event로 남는다.
- interactive shell에서 app close가 blocking read를 깨우고 reader thread까지 정리되는지.
