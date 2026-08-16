# PTY 운영 모델

이 문서는 macOS 초기 `PtySession`을 어떻게 운영할지 정한다.

> **Windows 백엔드는 여기가 아니다.** ConPTY는 fd도 `openpty`도 없고, 무엇보다 **자식이 죽어도 파이프가
> 끊기지 않아** EOF·종료 규율이 다르다. 그 계약은 [windows-platform.md](windows-platform.md) §4가 단일
> 출처다. 아래의 중립 표면(`waitIo`·`readChunk`·`writeInputNonBlocking`·`reapAfterEof`)은 두 백엔드가
> **같은 시그니처로** 채운다 — 갈리는 것은 그 밑의 메커니즘뿐이다.

> **현재 계약:** 이 문서의 close는 PTY/process를 실제 종료한다. 향후 앱 전체 quit만 client detach로 바꾸고
> `TerminalCore + LivePtySession`을 별도 Maru process가 소유하는 계획은
> [영속 터미널 세션 호스트](persistent-session-host.md)를 단일 출처로 둔다. 그 P4 전까지 현재 app teardown과
> Term/Workspace 명시 close의 bounded terminate 계약은 바뀌지 않는다.

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

현재 `PtySession` 최소 구현은 테스트가 통제할 수 있도록 blocking pull API인 `readEvent`를 먼저 제공한다. 앱 runtime 단계에서는 `PtyReader`가 이 `readEvent` 루프를 별도 reader thread에서 실행하고, `PtyEventQueue` bounded queue를 통해 `RuntimeEventPump`로 넘긴다. 즉 `PtySession` backend는 여전히 thread를 직접 소유하지 않고, app layer가 reader lifecycle과 queue drain을 조립한다.

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

RuntimeEventPump
  -> queue에서 QueuedPtyEvent 꺼내기
  -> SurfaceRuntime.applyPtyEvent
  -> Surface.TerminalCore.write
  -> snapshot/artifact 갱신
```

> **interactive 세션의 처리 위치([I/O–렌더 스레딩 분리](io-render-threading.md))**: 위 "큐→메인 드레인→core.write"
> 흐름은 controlled_smoke·테스트(직접 코어 구동)와 headless에 그대로 유효하다. 그러나 **interactive 세션**
> (`attachSurface(process_in_reader=true)`)은 reader thread가 `runProcessing`의 한 poll 루프(`waitIo`[read+write+wake])에서
> 출력을 `core.write`(`Surface.core_mutex` 락 아래)하고 코어가 만든 query 응답(OSC 10/11·CPR·DA)을 자기 PTY로
> 되쓴다. 응답이 렌더 frame-loop tick에 안 묶여, 출력 폭주(예: codex startup) 중에도 짧은 OSC 11 데드라인 안에
> 도착한다. 메인 tick은 그 코어를 락 아래 snapshot만 읽어 렌더한다(코어 읽기는 락 안, shaping/GPU는 락 밖).
>
> Phase 2(§8)에서 이 reader가 **유일한 PTY writer**가 됐다: 응답은 reader-로컬 outbound 버퍼에서 `POLLOUT`일 때
> 비차단으로 흘려보내(응답 write가 막혀도 read 무정지), 메인 입력(키/paste)은 공유 `PtyWriteQueue`로 들어와 같은
> 루프 write 단계에서 drain된다. 메인은 직접 PTY write를 하지 않는다(아래 "input write 정책").

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
- UI/runtime loop는 `RuntimeEventPump.drainAvailable`만 호출하면 된다.
- deterministic command test를 만들기 쉽다.
- queue event의 output bytes는 queue consumer가 소유권을 끝낸다. Maru 제품 코드에서는 그 consumer 역할을 `RuntimeEventPump`가 맡고, `SurfaceRuntime.applyPtyEvent` 성공/실패와 상관없이 `QueuedPtyEvent.deinit`을 정확히 한 번 호출한다.

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
-> RuntimeEventPump가 drain하면 다시 진행
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

input은 작다. 사용자가 누른 key나 paste 일부가 대부분이다. 그러나 PTY로 보내는 write의 **소유 스레드**가 둘이면(메인 입력 + I/O 스레드 응답) master fd에 동시 write가 생긴다 — 그래서 interactive 세션은 **단일 writer**로 모은다([I/O–렌더 스레딩 Phase 2 계획](plans/io-render-threading.md) §8).

**단일 writer 모델(interactive, `attachSurface(process_in_reader=true)`)**: 메인 스레드는 PTY에 직접 쓰지 않는다. `SurfaceRuntime.writeInput`/`writeInputNonBlocking`은 `LivePtySession.ptyIo(true)`가 돌려준 write-queue-backed `PtyIo`(`WriteQueueIo`)를 거쳐 입력을 `PtyWriteQueue`에 enqueue하고 `PtySession.signalWrite`로 I/O 스레드(reader)를 깨운다. 실제 master write는 **reader만** 한다 — reader가 `runProcessing`의 한 poll 루프 write 단계에서 (1) 코어가 만든 query 응답(reader-로컬 버퍼)을 먼저, (2) 그 다음 `PtyWriteQueue`를 비차단으로 drain한다. 이렇게 reader가 유일한 PTY writer가 돼 메인·I/O 동시 write 인터리브가 사라진다.

- 키/스크롤·메인스레드 query 응답: `enqueueBlocking`(전량 보장, 큐 포화 시 backpressure 대기 — 기존 직접 write가 PTY-full에 막히던 것과 동치).
- paste: `enqueueSome`(non-blocking, 들어가는 만큼만 — 잔량은 다음 tick, UI를 안 막는다).
- 응답이 reader-로컬 버퍼(`ArrayList`, append 무블록)인 이유: reader가 자기 응답을 적재하며 동시에 같은 큐를 drain하면 큐 포화 시 자기-enqueue에서 막혀 데드락이 된다. 그래서 응답(reader-로컬)과 메인 입력(공유 `PtyWriteQueue`)을 분리한다.
- `signalWrite`는 close용 wake self-pipe를 재사용한다(아래 close 참고). `waitIo`가 wake를 보면 `closing` 플래그로 write-wake(재-poll로 `POLLOUT` 반영)와 close-wake(`SessionClosed`)를 구분한다.

**non-interactive(controlled smoke/테스트, `process_in_reader=false`)**: reader가 `readEvent` 큐잉 경로라 `PtyWriteQueue`를 drain하지 않으므로, `ptyIo(false)`는 `PtySession.writeInput` 직접 경로를 유지한다(입력이 안 나가는 일이 없게).

## resize 순서

resize는 두 곳에 반영되어야 한다.

1. `TerminalCore.resize(cols, rows)`
2. `PtySession.resize(cols, rows)` 또는 `ioctl(TIOCSWINSZ)`

초기 정책은 하나의 `SurfaceRuntime.resize`에서 둘을 함께 호출한다. 실패 artifact에는 core resize 성공 여부와 PTY resize 성공 여부를 모두 남긴다.

## process exit

현재 `readEvent`가 EOF를 보거나 child process 종료를 감지하면 `PtyEvent.exited`를 반환한다. SurfaceRuntime 단계에서는 reader thread가 같은 event를 queue에 넣는다.

`SurfaceRuntime`은 이 event를 받아 surface metadata를 갱신한다. 이때 surface 자체를 바로 삭제하지 않는다. 사용자는 종료된 surface의 마지막 화면을 볼 수 있어야 하기 때문이다. 이 "마지막 화면 유지" 원칙은 app host에서 **창의 마지막 surface**까지 확장된다 — 첫 셸이 usable 세션에 도달하지 못하고(출력 0) 죽으면 앱을 종료하지 않고 창을 유지해 사용자가 원인을 보고 설정을 고치게 한다(단일 출처: `macos-app-host-boundary.md` "세션 자동 종료: 정상 종료 vs 비정상 시작 사망").

### read_error vs 검증된 exit — 워크스페이스 자동 닫기 게이트

reader가 `readChunk`/`waitIo`/`writeInputNonBlocking`에서 EOF가 아닌 I/O 오류(`POLLNVAL`, 비-`EIO` read 오류, master write 실패 등)를 만나면 `PtyEvent.read_error`를 낸다. **핵심 불변식: 워크스페이스(탭)의 자동 닫기·세션 종료 latch는 오직 "검증된 child 종료"에만 반응한다.** read_error는 그 자체로 child가 죽었다는 증거가 아니기 때문이다(EOF는 `reapAfterEof`가 `waitpid`/`kqueue`로 죽음을 확인하지만, read_error 경로엔 그 확인이 없었다).

- **소스 검증(pty_reader `pushTerminationForIoError`)**: I/O 오류를 만난 reader는 `PtySession.reapIfExited`(비차단 `waitpid` WNOHANG)로 child 생존을 확인한다. 이미 죽었으면 `PtyEvent.exited`(검증된 종료 — EOF 경로와 동치)로, 아직 살아 있으면 `PtyEvent.read_error`로 방출한다.
- **닫기 게이트(app_session `terminationClosesWorkspace`)**: tick drain이 `.exited`를 관측하면 기존대로 `finishAfterTermination`(reader join + child reap) → cascade close(Term→pane→워크스페이스)를 탄다. `.read_error`(= child 생존 미검증)는 surface를 exited로 latch해 I/O만 거부하고, **`finishAfterTermination`(→`session.close`→`shutdownChild`로 살아 있는 셸을 죽인다)·reap·closeTab을 타지 않는다.** 끝난 reader thread는 Term teardown(`close`/`stopAndJoin`)이 join한다.

  **의도된 트레이드오프(code-review)**: `.read_error` Term은 `terminated`를 세우지 않으므로 non-terminated로 남는다 — 이 때문에 (1) `allTabsTerminated`가 이 Term을 "살아있음"으로 세어 **다른 탭이 전부 exit해도 창이 자동으로 안 닫힐 수 있고**(수동 닫기 필요), (2) reader가 return하고 surface가 exited로 latch된 **응답 없는 죽은 pane**이 남는다(스크롤백은 보존 — "종료 surface 마지막 화면 유지" 원칙과 동일; 산 셸은 고아→Term teardown 시 `shutdownChild`로 정리). 이걸 "고치려" `terminated=true`를 세우면 곧장 reap→closeTab이 돌아 **사용자 신고 버그(read_error에 좌측 탭 닫힘)가 재발**하므로, 산 셸 데이터 보존을 위해 non-terminated가 불가피하다. `read_error`-with-alive-child 자체가 EINTR/EAGAIN 재시도·EIO=죽음(→`.exited`) 뒤 남는 드문(POLLNVAL 등) 경로라 이 degraded 상태는 흔치 않다.

이 게이트가 없으면, 셸에서 `claude` 같은 포그라운드 명령을 실행 중 `Ctrl+C`(0x03 write)가 일으킨 일시적 I/O 오류가 read_error → 미검증 종료로 처리돼, **살아 있는 셸을 죽이고 좌측 워크스페이스 탭을 통째로 닫는** 데이터 손실이 난다(사용자 보고 루트커즈). 단위 검증: `pty/macos.zig`의 `reapIfExited` 테스트(생존→null/종료→상태)와 `app_session.zig`의 `terminationClosesWorkspace` 테스트(.exited만 닫힘). 전체 통합은 mock 세션 주입 불가·live reader join 순서 문제로 수동 검증(위 시나리오 반복)이다.

## session close

이미 `PtyEvent.exited`로 종료가 관측된 session은 close 시 child를 다시 건드리지 않는다. 아직 살아 있는 child를 close할 때는 shell이 정리할 기회를 주기 위해 신호를 단계적으로 올린다. master fd는 이 단계에서 닫지 않는다(reader join 뒤 `deinit`에서 닫는다 — 아래 reader 정리 문단 참조).

```text
close (child가 아직 살아 있을 때)
  -> SIGHUP  (process group + child) + 짧은 grace 동안 reap 시도
  -> SIGTERM (process group + child) + 짧은 grace 동안 reap 시도
  -> SIGKILL (process group + child) + bounded reap (WNOHANG poll, 최대 ~3s)
```

`setsid`로 child가 process group leader가 되므로 group(`-pid`)과 child(`pid`) 양쪽에 보낸다. grace는 짧고 상한이 있어 close가 오래 멈추지 않는다. 마지막 `SIGKILL`은 무시할 수 없으므로 child 종료 자체는 보장되지만, **reap은 blocking `wait4`가 아니라 상한 있는 poll**(`reapBoundedAfterKill`, 10ms × 300 = 최대 ~3s, 보통 1~2회에 거둠)이다. 멀티스레드 reap 경합 등으로 `wait4(pid, 0)`이 영영 반환하지 않아 close가 22분 멈춘 사례가 관측돼, "무한 hang 위험" 대신 "포기 시 zombie가 잠깐 남을 수 있음"을 택했다 — 못 거둔 child는 부모 프로세스 종료 시 launchd/init이 고아로 회수하므로 zombie는 프로세스 수명 한정이다(단일 출처: `src/pty/macos.zig`의 `shutdownChild` 주석).

이 escalation은 `PtySession.close`에서 동기적으로 수행하고, `deinit`은 같은 close 경로를 재사용한다. 이 분리가 필요한 이유는 app이 탭/창을 닫을 때 session memory를 바로 파괴하면 reader thread가 아직 `readEvent` 안에서 같은 session을 잡고 있을 수 있기 때문이다.

reader thread가 blocking `readEvent`에 들어간 상태도 `PtyReader.stopAndJoin`으로 정리한다. 순서는 `queue.close -> session.close -> reader.join`이다. queue를 먼저 닫는 이유는 사용자가 닫은 pane에 새 output/read_error event를 더 쌓지 않기 위해서다. session close는 child를 reap하고, reader를 깨운다. master fd 자체는 여기서 닫지 않고 reader가 join된 뒤 `deinit`에서 닫는다. reader가 아직 그 fd 번호로 poll/read 중일 때 닫으면 OS가 번호를 재사용해 reader가 엉뚱한 fd를 읽을 수 있기 때문이다.

단일 writer 모델에서는 `LivePtySession.close`/`finishAfterTermination`이 event queue·session에 더해 `PtyWriteQueue`도 닫는다. 메인이 큐 포화로 `enqueueBlocking` backpressure 대기 중일 때 close가 그 대기를 `QueueClosed`로 풀어주지 않으면, 닫는 스레드와 입력 스레드가 다를 경우 메인이 영영 막힌다. reader는 `PtyWriteQueue`를 비차단으로 drain하므로 큐에서 대기하지 않고, `session.close`의 self-pipe wake로 `waitIo`에서 깨어나 종료한다(write 대기 중 close에서도 무UAF/좀비 — plans/io-render-threading.md §8 P2-4).

app host, smoke, demo 코드는 `PtySession`, `PtyEventQueue`, `PtyReader`를 각각 조립하지 않고 `LivePtySession` owner를 사용한다. 이유는 정상 종료 경로와 close/error cleanup 경로가 같은 reader를 서로 다른 방식으로 만지기 시작하면, 이미 join된 reader를 다시 stop하거나 반대로 실패 경로에서 reader thread를 놓치는 버그가 생기기 쉽기 때문이다. `LivePtySession.finishAfterTermination`은 정상 종료 뒤 reader join과 queue close를 한 번만 기록하고, `LivePtySession.close`/`deinit`은 아직 join되지 않은 경우에만 `PtyReader.stopAndJoin`을 호출한다. tab/window close처럼 surface도 함께 사라지는 경로는 `LivePtyRegistry`가 active surface의 live PTY mapping을 찾고 link 불변식을 검증한 뒤 `LivePtySession.closeAndDetach`를 호출한다. 이 함수는 닫힌 pane으로 늦게 도착한 output이나 input이 흘러가지 않도록 `SurfaceRuntime.detachSurface`를 먼저 수행하고, 그 다음 같은 PTY close 순서를 탄다. registry mapping은 close 성공 뒤 제거하고, 검증 실패 시에는 원인 분석을 위해 보존한다.

reader를 깨우는 방식은 self-pipe다. `readEvent`는 실제 `read` 전에 master fd와 wake fd를 함께 `poll`로 무한 대기하고, `close`는 wake fd에 1바이트를 보내 poll을 즉시 반환시킨다. 그래서 close 관측 지연은 사실상 0이고(timeout 폴링이 아니다), 출력이 없는 pane도 주기적 wakeup 없이 잠든다. macOS에서 다른 thread가 fd를 닫는 것만으로 blocking read가 깨어난다고 가정하지 않는다는 제약을, fd 자체가 아니라 별도의 wake 이벤트로 우회한 것이다.

reap 경로도 마찬가지로 `close`가 끼어들 수 없는 bare blocking `waitpid`를 쓰지 않는다. EOF를 보면 먼저 `WNOHANG`로 거두고(보통 child가 이미 종료해 즉시 성공), child가 stdio만 닫고 계속 살아 있으면(드문 daemonize) `kqueue`로 child의 실제 종료(`EVFILT_PROC`/`NOTE_EXIT`)와 close의 wake(self-pipe `EVFILT_READ`)를 함께 기다린다. 그래서 child가 끝내 종료하지 않아도 `stopAndJoin`이 reader를 깨워 `join`이 멈추지 않고, child는 close의 SIGKILL escalation으로 정리된다.

아직 남은 범위는 macOS window/app host의 실제 close button, tab close command, app quit lifecycle이 `FrameLoop.closeActiveLivePty`를 호출하도록 native lifecycle에 연결하는 일이다. `FrameLoop.closeActiveLivePty`는 registry에서 active surface의 live PTY를 찾아 `LivePtySession.closeAndDetach`로 내려간다. close 경로를 native UI와 조립할 때도 "신호를 단계적으로 올리고 상한 안에서 reap을 시도한다(절대 무한 대기하지 않는다)"는 계약은 동일하게 유지한다.

## 초기 테스트

- controlled command가 stdout bytes를 event로 낸다.
- output event는 drop되지 않는다.
- process exit가 `PtyEvent.exited`로 관측된다.
- resize request가 PTY layer까지 전달된다.
- 아직 살아 있는 child를 close할 때 HUP/TERM을 무시해도 escalation으로 reap된다(reap은 hang 방지를 위해 상한 있는 poll — 위 session close 절).

SurfaceRuntime reader thread와 pump 단계에서 추가된 테스트:

- queue가 가득 찼을 때 무한 메모리 증가가 없다(`tryPush`가 `QueueFull`을 반환하고, 실제 reader 경로는 `pushBlocking`으로 기다린다).
- `RuntimeEventPump`가 queued event를 `SurfaceRuntime`에 적용하고 output bytes 소유권을 끝낸다.
- reader thread가 실제 macOS PTY controlled command output/exit를 bounded queue에 넣고, `RuntimeEventPump`가 이를 `SurfaceRuntime`에 적용한다.
- 대량 stdout을 queue capacity 1로 흘려도 marker가 drop되지 않고, 여러 output event가 pump를 통과하며, 마지막 화면과 summary artifact가 남는다.
- `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 띄운 interactive shell smoke가 marker command를 PTY input으로 받고 종료하며, raw/screen/snapshot/summary artifact를 남긴다. 이 테스트는 실제 사용자의 dotfile과 prompt escape 영향을 일부러 통과시키지만, 현재 VT parser가 ANSI escape를 완전히 해석하지 못해 screen artifact가 지저분할 수 있다는 한계도 함께 드러낸다.
- `mise run app-pty-interactive-loop-smoke`는 같은 interactive shell을 app frame loop 위에 올리고, marker command를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경계로 보낸다. 이 테스트는 아직 visible UI가 아니지만, 제품 loop가 쓸 입력 경계와 반복 frame 생성 경로를 interactive shell까지 확장한다.
- `LivePtySession`이 controlled command의 정상 종료까지 PTY event queue를 소유하고, `finishAfterTermination` 뒤 cleanup이 다시 `stopAndJoin`을 부르지 않는다.
- close/error cleanup 경로에서 `LivePtySession.deinit`이 아직 join되지 않은 reader를 정확히 한 번 `stopAndJoin`한다.
- `LivePtySession.closeAndDetach`가 runtime routing을 먼저 끊고 queue를 닫아, 닫힌 surface로 late output/input이 들어가지 않는다.
- `LivePtyRegistry`가 중복 surface/pty registration을 거부하고, active surface mapping만 닫으며, link 불변식 실패 시 mapping을 보존한다.
- `host.closeActiveLivePty`가 registry를 통해 active surface live PTY를 닫고 registry mapping을 제거한다.
- 출력이 없는 long-running child에서 reader thread가 blocking read에 들어가도 `PtyReader.stopAndJoin`이 reader를 join하고 child를 reap한다.
- child가 stdio를 닫고 계속 살아 있어(daemonize) reader가 reap 경로의 kqueue 대기에 들어가도 `PtyReader.stopAndJoin`이 reader를 깨워 join하고 child를 reap한다(데드락 없음).

아직 추가하지 않은 테스트:

- 대량 stdout에서 reader가 오래 backpressure를 걸 때 RSS 상한, drain latency, UI responsiveness가 유지되는지.
- reader thread 종료와 process exit가 trace에 같은 domain event로 남는다.
- macOS app host의 실제 tab/window close event가 `FrameLoop.closeActiveLivePty`를 통해 registry에서 active surface live PTY를 찾고 `LivePtySession.closeAndDetach`로 내려가는지.
