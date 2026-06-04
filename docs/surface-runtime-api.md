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
  forkpty master fd + child process lifecycle
  저장 불가능

SurfaceRuntime
  Surface와 PtySession을 실행 중에만 연결
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
};

pub const RuntimeLink = struct {
    surface_id: SurfaceId,
    pty_id: PtyId,
};

pub const PtyEvent = union(enum) {
    output: struct {
        pty_id: PtyId,
        bytes: []const u8,
    },
    exited: struct {
        pty_id: PtyId,
        code: ?u8,
    },
    read_error: struct {
        pty_id: PtyId,
        message: []const u8,
    },
};

pub const TerminalInput = struct {
    bytes: []const u8,
};

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

pub const AppRequest = union(enum) {
    clipboard: ClipboardRequest,
    shell_integration: ShellIntegrationEvent,
};

pub const ClipboardRequest = struct {
    request_id: u64,
    surface_id: SurfaceId,
    access: ClipboardAccess,
    // preview는 사용자 확인 UI와 debug artifact용이다. 원문 전체를 넣으면
    // clipboard secret이 trace나 로그로 새기 쉬우므로 redaction된 짧은 값만 허용한다.
    preview: []const u8,
};

pub const ClipboardAccess = enum {
    read,
    write,
};

pub const ClipboardDecision = union(enum) {
    deny,
    allow_read: []const u8,
    allow_write,
};

pub const ShellIntegrationEvent = union(enum) {
    cwd_changed: struct {
        surface_id: SurfaceId,
        cwd: []const u8,
    },
    prompt_start: struct { surface_id: SurfaceId },
    prompt_end: struct { surface_id: SurfaceId },
    command_start: struct { surface_id: SurfaceId },
    command_end: struct {
        surface_id: SurfaceId,
        exit_code: ?u8,
    },
};
```

## 초기 함수

```zig
pub const SurfaceRuntime = struct {
    pub fn init(allocator: std.mem.Allocator) SurfaceRuntime;
    pub fn deinit(self: *SurfaceRuntime) void;

    pub fn attach(
        self: *SurfaceRuntime,
        surface_id: SurfaceId,
        surface: *Surface,
        pty_id: PtyId,
        pty: *PtySession,
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
        size: TerminalSize,
    ) RuntimeError!void;

    pub fn applyPtyEvent(
        self: *SurfaceRuntime,
        event: PtyEvent,
    ) RuntimeError!void;

    pub fn drainAppRequests(self: *SurfaceRuntime, buffer: []AppRequest) []const AppRequest;

    pub fn completeClipboardRequest(
        self: *SurfaceRuntime,
        request_id: u64,
        decision: ClipboardDecision,
    ) RuntimeError!void;
};
```

## 함수별 의도

`attach`:

- 하나의 `Surface`와 하나의 `PtySession`을 연결한다.
- 이미 연결된 surface나 pty를 다시 연결하면 오류다.
- 이 함수는 workspace 저장 포맷을 만들지 않는다.

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
- `PtyEvent`는 `surface_id`를 직접 들고 있지 않다. event의 `pty_id`로 attach 매핑을 거꾸로 조회해 대상 surface를 찾는다. 매핑에 없는 `pty_id`면 `UnknownPty`다.
- `output`은 해당 surface의 `TerminalCore.write`로 들어간다.
- `exited`는 surface metadata와 artifact에 반영한다. 이 event를 trace로 남길 때의 이름은 `process-exit`이며, 둘은 같은 사건의 두 이름이다(대응표는 [Facade 계약](facade-contracts.md)의 `Trace/Event` 절).
- `read_error`는 실패 artifact에 남긴다. 환경 의존적 실패라 trace에는 기록하지 않는다.

`drainAppRequests`:

- `TerminalCore.write` 중 나온 clipboard 요청이나 shell integration event를 app layer로 올린다.
- 이 함수는 platform API를 호출하지 않는다. 사용자 확인 UI, macOS pasteboard, 알림은 app/platform layer 책임이다.
- 요청 payload에는 redaction된 preview만 들어가야 한다.

`completeClipboardRequest`:

- app/platform layer가 `ask` UI나 policy 판단을 끝낸 뒤 결과를 돌려준다.
- `deny`는 running program에 아무 민감 데이터를 보내지 않는다.
- `allow_read`는 app/platform이 읽은 clipboard text를 terminal 응답으로 encode할 수 있게 한다.
- `allow_write`는 이미 app/platform이 write를 승인했다는 뜻이다.

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
- `PtyEvent.output`이 올바른 surface의 `TerminalCore.write`로 전달된다.
- `resize`는 core resize와 PTY resize를 모두 호출한다.
- `detachSurface` 이후 `RestorableSurfaceMetadata`에는 live handle이 남지 않는다.
- OSC52 read/write는 `AppRequest.clipboard`로 올라가고, 직접 clipboard API를 호출하지 않는다.
- shell integration escape는 `AppRequest.shell_integration` domain event로 올라간다.
