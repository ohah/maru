# SurfaceRuntime API 계약

이 문서는 `SurfaceRuntime`의 초기 public 계약을 정한다. 실제 이름을 바꾸고 싶으면 구현 PR에서 이 문서를 먼저 바꿔야 한다.

## 왜 필요한가

`Surface`는 복구 가능한 상태다. 즉 workspace restore에 저장할 수 있어야 한다.

반대로 `PtySession`은 live process와 file descriptor를 가진다. 이것은 저장할 수 없다. 앱을 껐다 켜면 같은 process handle은 사라진다.

그래서 실행 중 연결은 `SurfaceRuntime`이 맡는다.

```text
Surface
  TerminalCore + title/cwd/env/command/size metadata
  저장 가능

PtySession
  openpty master fd + child process lifecycle
  저장 불가능

PtyIo
  live PtySession 또는 fake PTY를 감싸는 작은 adapter
  SurfaceRuntime unit test가 macOS PTY에 묶이지 않게 함

SurfaceRuntime
  Surface와 PtyIo를 실행 중에만 연결
  저장 대상 아님
```

## 초기 타입

```zig
pub const SurfaceId = u64;
pub const PtyId = u64;

pub const RuntimeError = error{
    UnknownSurface,
    UnknownPty,
    SurfaceAlreadyAttached,
    PtyAlreadyAttached,
    ProcessExited,
    WriteFailed,
    ResizeFailed,
    ReadFailed,
    InvalidOutput,
    OutOfMemory,
};

pub const RuntimeLink = struct {
    surface_id: SurfaceId,
    pty_id: PtyId,
};

pub const RuntimePtyEvent = union(enum) {
    output: struct {
        pty_id: PtyId,
        bytes: []const u8,
    },
    exited: struct {
        pty_id: PtyId,
        status: maru.pty.ExitStatus,
    },
    read_error: struct {
        pty_id: PtyId,
        message: []const u8,
    },
};

pub const TerminalInput = struct {
    bytes: []const u8,
};

pub const PtyIo = struct {
    ctx: *anyopaque,
    write_input: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    resize_fn: *const fn (ctx: *anyopaque, size: maru.terminal.Size) anyerror!void,

    pub fn fromSession(session: *maru.pty.PtySession) PtyIo;
    pub fn writeInput(self: PtyIo, bytes: []const u8) !void;
    pub fn resize(self: PtyIo, size: maru.terminal.Size) !void;
};
```

`PtyReader`가 만든 queue event를 실제 runtime에 적용하는 쪽은 별도 app-layer helper인 `RuntimeEventPump`가 맡는다. `SurfaceRuntime`은 routing과 state update만 책임지고, queue ownership이나 blocking drain 정책을 직접 소유하지 않는다.

reader thread 자체의 종료 책임도 `SurfaceRuntime`에 넣지 않는다. reader thread는 live process/file descriptor와 같은 수명주기를 가지므로 app host가 `LivePtySession` owner로 소유한다. `SurfaceRuntime`은 output/exit/read_error event를 surface state에 반영할 뿐이고, 실제 window/tab close에서는 app host lifecycle이 `FrameLoop.closeActiveLivePty`를 호출한다. 이 app host action은 active surface와 live PTY link가 맞는지 확인한 뒤 `LivePtySession.closeAndDetach`로 내려가 `detachSurface`와 reader join을 같은 close operation으로 묶는다.

```zig
pub const RuntimeEventPump = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        queue: *PtyEventQueue,
        runtime: *SurfaceRuntime,
    ) RuntimeEventPump;

    pub fn drainAvailable(self: *RuntimeEventPump) PumpError!DrainSummary;
    pub fn drainBlockingUntilTermination(self: *RuntimeEventPump) PumpError!DrainSummary;
    pub fn applyQueuedEvent(self: *RuntimeEventPump, event: QueuedPtyEvent) RuntimeError!PumpedEvent;
};
```

이 분리가 필요한 이유는 초보자 관점에서 보면 간단하다. `SurfaceRuntime`이 queue까지 알면 "어떤 surface로 보낼지"와 "event memory를 언제 해제할지"가 한 파일에 섞인다. Maru는 후자를 `RuntimeEventPump`로 빼서 app host, integration test, future trace recorder가 같은 ownership 규칙을 쓰게 한다.

## 초기 함수

```zig
pub const SurfaceRuntime = struct {
    pub fn init(allocator: std.mem.Allocator) SurfaceRuntime;
    pub fn deinit(self: *SurfaceRuntime) void;

    pub fn attach(
        self: *SurfaceRuntime,
        surface: *Surface,
        pty_id: PtyId,
        pty: PtyIo,
    ) RuntimeError!RuntimeLink;

    pub fn detachSurface(self: *SurfaceRuntime, surface_id: SurfaceId) void;

    pub fn writeInput(
        self: *SurfaceRuntime,
        surface_id: SurfaceId,
        input: TerminalInput,
    ) RuntimeError!void;

    pub fn resize(
        self: *SurfaceRuntime,
        surface_id: SurfaceId,
        size: maru.terminal.Size,
    ) RuntimeError!void;

    pub fn applyPtyEvent(
        self: *SurfaceRuntime,
        event: RuntimePtyEvent,
    ) RuntimeError!void;
};
```

## 함수별 의도

`attach`:

- 하나의 `Surface`와 하나의 `PtyIo`를 연결한다.
- surface routing key는 `surface.id`를 그대로 쓴다. 별도 `surface_id` 인자를 받지 않아서, key가 surface의 실제 id와 어긋나 detach가 link을 못 찾는 stale link가 생기지 않는다.
- 이미 연결된 surface나 pty를 다시 연결하면 오류다.
- 이 함수는 workspace 저장 포맷을 만들지 않는다.
- `PtyIo`를 받는 이유는 `SurfaceRuntime`의 routing 계약을 fake PTY로 빠르게 unit test하기 위해서다. 실제 macOS backend는 `PtyIo.fromSession`으로 감싼다.

`detachSurface`:

- surface가 닫히거나 process가 끝났을 때 live 연결을 끊는다.
- surface의 복구 가능한 metadata는 남을 수 있지만, pty handle은 남기지 않는다.
- attach가 만든 surface↔pty 매핑을 양방향으로 제거한다. 그래서 detach 이후 같은 `pty_id`로 들어온 `applyPtyEvent`는 `UnknownPty`로 떨어지고, 끊긴 surface로 늦게 도착한 output이 흘러들지 않는다.

`writeInput`:

- 이미 `TerminalInput`으로 분류된 bytes만 PTY로 보낸다.
- keybinding 해석을 하지 않는다. keybinding은 app/config layer 책임이다.

`resize`:

- `Surface.TerminalCore.resize`와 `PtySession.resize`를 둘 다 요청한다.
- 두 작업을 같은 user action에서 발생한 하나의 runtime event로 trace에 남긴다.

`applyPtyEvent`:

- PTY reader가 만든 event를 surface에 반영한다.
- `RuntimePtyEvent`는 `surface_id`를 직접 들고 있지 않다. event의 `pty_id`로 attach 매핑을 거꾸로 조회해 대상 surface를 찾는다. 매핑에 없는 `pty_id`면 `UnknownPty`다.
- `output`은 해당 surface의 `TerminalCore.write`로 들어간다.
- `exited`는 surface metadata와 artifact에 반영한다. 이 event를 trace로 남길 때의 이름은 `process-exit`이며, 둘은 같은 사건의 두 이름이다(대응표는 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절).
- `read_error`는 `RuntimePtyEvent`에서만 쓰는 runtime 오류 event다. 실패 artifact에 남기고, 환경 의존적 실패라 trace에는 기록하지 않는다.

`RuntimeEventPump.applyQueuedEvent`:

- queue에서 꺼낸 `QueuedPtyEvent` 하나를 `SurfaceRuntime.applyPtyEvent`로 적용한다.
- 함수가 성공하든 실패하든 event의 `deinit`을 정확히 한 번 호출한다.
- `read_error`가 `SurfaceRuntime.applyPtyEvent`에서 `ReadFailed`로 관측되는 경우는 root-cause 결함이 아니라 reader 종료 신호로 보고 `PumpedEvent.termination`에 담아 반환한다.
- integration test가 raw PTY artifact를 남겨야 할 때도 event 적용/해제는 이 함수를 사용한다.

`RuntimeEventPump.drainAvailable`:

- GUI frame loop에서 쓰기 위한 non-blocking drain이다.
- 현재 queue에 있는 event만 처리하고 비어 있으면 즉시 반환한다.
- output을 적용한 뒤 같은 drain에서 exit/read_error를 보더라도 `DrainSummary.output_events`와 `DrainSummary.ended`를 함께 보존한다.

`RuntimeEventPump.drainBlockingUntilTermination`:

- window loop가 붙기 전 headless integration을 위해 설계한 helper다.
- `headless_demo`(`maru-dev demo` / `zig build demo`)가 이 helper의 첫 실소비자다. 다만 현재 macOS PTY integration test는 raw artifact용 output bytes를 따로 모아야 해서 이 helper 대신 `applyQueuedEvent`로 자체 루프를 돈다.
- `app-pty-smoke`도 raw PTY bytes artifact를 남겨야 하므로 `applyQueuedEvent`와 `DrainSummary.recordPumpedEvent`를 조합해 직접 drain한다. 이 방식은 output bytes 관찰만 smoke가 하고, event 적용/해제 ownership은 여전히 pump가 소유하게 만든다.
- exit 또는 read_error termination을 볼 때까지 기다린다.
- queue가 먼저 닫히면 `ReaderQueueClosedBeforeTermination`으로 실패한다.

`drainAppRequests`와 `completeClipboardRequest`:

- 이번 순수 runtime PR에서는 구현하지 않는다.
- OSC52 clipboard와 shell integration event는 `TerminalCore`가 app request를 만들 수 있게 된 뒤 별도 PR에서 이 문서에 다시 추가한다.

## drain 종료 계약

`drainAvailable`/`drainBlockingUntilTermination`은 "정상 종료(exit)"와 "reader 읽기 실패(read_error)"를 Zig error 채널로 던지지 않는다. 둘 다 terminal session이 끝났다는 예상 가능한 runtime event이므로 `DrainSummary.ended` 데이터로 반환한다.

왜 중요한가: `drainAvailable`의 첫 실소비자는 GUI frame loop다. queue에 output과 read_error가 같은 frame에 들어오면 frame loop가 원하는 동작은 "drain한 output 반영 -> 마지막 프레임 렌더 -> surface를 죽은 것으로 표시 -> 계속"이다. read_error를 `throw`하면 이미 적용한 output 개수와 redraw 판단을 잃는다.

현재 모델:

```zig
const Termination = union(enum) {
    exited: pty.ExitStatus,
    read_error: []const u8,
};

const DrainSummary = struct {
    output_events: usize = 0,
    exit_events: usize = 0,
    ended: ?Termination = null, // 이번 drain에서 관측한 종료. null이면 계속 진행
};
```

- `throw`는 `UnknownPty`, `InvalidOutput`, `OutOfMemory` 같은 진짜 결함에만 남긴다.
- `read_error`는 카운터가 아니라 1급 종료 값이다. 그래서 별도 `read_error_events` 카운터를 만들지 않는다.
- `SurfaceRuntime.applyPtyEvent(.read_error)` 자체는 surface를 exited로 latch한 뒤 `ReadFailed`를 반환한다. `RuntimeEventPump`는 이 `ReadFailed`를 session termination 데이터로 바꿔 frame loop에 전달한다.
- `UnknownPty`처럼 routing 자체가 틀린 경우는 여전히 error다. 이 경우는 종료가 아니라 app/runtime 연결 결함이다.

아직 남은 후보:

- integration test가 자체 drain 루프를 도는 중복(`tests/integration/pty/macos.zig`)을, output sink를 받는 helper로 흡수할지 결정한다. (`drainBlockingUntilTermination` 자체는 `headless_demo`가 쓰므로 미사용은 아니다.)
- 실제 frame loop가 붙을 때 `DrainSummary.ended`를 어떤 UI state로 보여줄지 결정한다.

## 반드시 지켜야 할 것

- `SurfaceRuntime`은 renderer resource를 알면 안 된다.
- `SurfaceRuntime`은 workspace 파일 포맷을 알면 안 된다.
- `SurfaceRuntime`은 system clipboard를 직접 읽거나 쓰면 안 된다.
- `Surface`는 live PTY handle을 저장하면 안 된다.
- `PtySession`은 escape sequence 의미를 알면 안 된다.
- `TerminalCore`는 PTY file descriptor를 알면 안 된다.
- `TerminalCore`는 platform clipboard API를 알면 안 된다.

## 초기 테스트

- 연결되지 않은 surface에 `writeInput`하면 `UnknownSurface`가 난다.
- 같은 surface를 두 번 attach하면 `SurfaceAlreadyAttached`가 난다.
- `RuntimePtyEvent.output`이 올바른 surface의 `TerminalCore.write`로 전달된다.
- `resize`는 core resize와 PTY resize를 모두 호출한다.
- `detachSurface` 이후 `RestorableSurfaceMetadata`에는 live handle이 남지 않는다.
- process exit event는 surface `process_state`를 `exited`로 바꾸고 이후 input을 막는다.
- `SurfaceRuntime` 단독으로 read error event를 적용하면 `ReadFailed`로 관측된다.
- pump는 queued output/exit/read_error를 runtime에 적용하고 event ownership을 끝낸다.
- pump는 read_error를 `DrainSummary.ended.read_error`로 반환하고, 같은 drain에서 먼저 처리한 output count를 잃지 않는다.
