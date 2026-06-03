# PTY 운영 모델

이 문서는 macOS 초기 `PtySession`을 어떻게 운영할지 정한다.

## 결론

초기 macOS 구현은 `forkpty`와 **PTY마다 하나의 reader thread**를 사용한다.

이 선택은 최고 성능 설계가 아니라, 초기에 가장 이해하기 쉽고 테스트하기 쉬운 설계다. 여러 surface가 매우 많아지면 macOS `kqueue` 기반으로 바꿀 수 있지만, 먼저 맞춰야 할 것은 속도가 아니라 책임 경계와 재현 가능한 event 흐름이다.

## 기본 흐름

```text
PtySession.spawn(command)
  -> forkpty
  -> child process 실행
  -> parent는 master fd 보관
  -> reader thread 시작

reader thread
  -> master fd에서 bytes 읽기
  -> PtyEvent.output 생성
  -> bounded event queue에 넣기

app/runtime loop
  -> queue에서 PtyEvent 꺼내기
  -> SurfaceRuntime.applyPtyEvent
  -> Surface.TerminalCore.write
  -> snapshot/artifact 갱신
```

## 왜 reader thread인가

대안은 macOS `kqueue` 또는 nonblocking fd event loop다. 장기적으로는 좋지만 초기에는 다음 비용이 크다.

- platform event loop와 app event loop를 동시에 설계해야 한다.
- 테스트에서 timing race가 늘어난다.
- 초보자가 읽기 어렵다.
- parser/PTY/surface 책임 경계보다 OS I/O 세부사항이 먼저 커진다.

reader thread는 단순하다.

- PTY output을 읽는 책임이 한 곳에 있다.
- UI/runtime loop는 queue만 drain하면 된다.
- deterministic command test를 만들기 쉽다.

## backpressure 정책

PTY output은 임의로 버리지 않는다.

초기 queue는 bounded로 둔다. queue가 가득 차면 reader thread는 기다린다. 그러면 PTY master fd를 더 읽지 못하고, 결국 child process stdout도 막힐 수 있다.

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

reader thread가 EOF를 보거나 child process 종료를 감지하면 `PtyEvent.exited`를 보낸다.

`SurfaceRuntime`은 이 event를 받아 surface metadata를 갱신한다. 이때 surface 자체를 바로 삭제하지 않는다. 사용자는 종료된 surface의 마지막 화면을 볼 수 있어야 하기 때문이다.

## 초기 테스트

- controlled command가 stdout bytes를 event로 낸다.
- output event는 drop되지 않는다.
- queue가 가득 찼을 때 무한 메모리 증가가 없다.
- process exit가 `PtyEvent.exited`로 관측된다.
- resize request가 PTY layer까지 전달된다.
