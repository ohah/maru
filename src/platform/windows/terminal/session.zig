//! Windows app host session ownership. Keep heap-pinned surfaces, ConPTY
//! routing, and admission rollback in the same platform namespace.
const std = @import("std");
const maru = @import("maru");

pub const Session = struct {
    surface: maru.session.surface.Surface,
    live: maru.app.LivePtySession,
    pump: maru.app.RuntimeEventPump,
    /// 사이드바 카드에 뜨는 이름. 세션이 소유한다(목록이 커져도 슬라이스가 살아 있어야 한다).
    name: [24]u8,
    name_len: usize,

    pub const SpawnOptions = struct {
        io: std.Io,
        command: []const u8,
        args: []const []const u8,
        size: maru.terminal.Size,
        cfg: maru.config.theme.Config,
        appearance: maru.config.appearance.ResolvedAppearance,
        cell_w: u32,
        cell_h: u32,
    };

    pub fn label(self: *const Session) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn destroy(self: *Session, allocator: std.mem.Allocator) void {
        // **PTY 를 먼저 내린다** — 리더 스레드가 표면 코어를 잡고 있다.
        self.live.deinit();
        self.surface.deinit();
        allocator.destroy(self);
    }
};

/// 세션 하나를 띄워 목록·탭에 붙인다.
///
/// **탭 슬라이스를 다시 건다**(`app_window.tabs = tab_ptrs.items`) — `ArrayList` 가 realloc 되면 옛
/// 슬라이스가 죽은 메모리를 가리킨다. 포인터가 가리키는 표면 본체는 힙에 고정이라 안전하다.
pub fn spawn(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(*Session),
    tab_ptrs: *std.ArrayList(*maru.session.surface.Surface),
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    /// **단조 증가 세션 번호.** 목록 길이가 아니다 — 닫으면 길이가 줄어 번호가 되살아난다.
    next_session_id: *usize,
    opts: Session.SpawnOptions,
    comptime configureCore: anytype,
) !void {
    const s = try allocator.create(Session);
    errdefer allocator.destroy(s);

    // **PTY id 는 겹치면 안 된다** — 라우팅이 그 값으로 세션을 가른다.
    //
    // **길이에서 뽑으면 안 된다.** 닫기가 생기기 전에는 길이가 단조 증가라 우연히 맞았는데(W8.16),
    // 하나를 닫으면 그 번호가 되살아나 **살아 있는 세션과 겹친다.** 런타임이 그것을 잡아
    // `SurfaceAlreadyAttached` 로 거절하므로 오배선은 없지만, **닫은 뒤에는 ＋ 가 아무 일도 안 하게
    // 된다**(적대적 검증 2회차 실측). 그래서 **단조 증가 계수기**에서 뽑는다.
    next_session_id.* += 1;
    const seq = next_session_id.*;
    const pty_id: u32 = @intCast(10 + seq);
    s.surface = try maru.session.surface.Surface.init(allocator, @intCast(1 + seq), opts.size);
    errdefer s.surface.deinit();
    s.surface.command = opts.command;

    // **폴백도 버퍼에 쓴다.** 예전 판은 실패 시 리터럴을 `written` 에 담고 `buf` 는 손도 안 댔는데,
    // 그러면 초기화 안 된 스택을 복사해 길이만 7 인 **쓰레기 이름**이 된다. 지금 폭(24)과 상한(16)
    // 에서는 `bufPrint` 가 실패하지 않지만, 형식이나 상한을 바꾸는 날 조용히 밟는 자리다.
    s.name = std.mem.zeroes([24]u8);
    const written = std.fmt.bufPrint(&s.name, "session {d}", .{seq}) catch blk: {
        const fallback = "session";
        @memcpy(s.name[0..fallback.len], fallback);
        break :blk s.name[0..fallback.len];
    };
    s.name_len = written.len;
    s.surface.title = s.label();

    // **앱 수준 config 를 코어에 한 번에 건다** — 리더가 뜨기 전에. 값마다 명령을 따로 보내면 자식의
    // 첫 출력이 그 사이에 끼어 옛 설정으로 파싱되는 자리가 생긴다.
    configureCore(&s.surface.core, opts.cfg, opts.appearance, opts.cell_w, opts.cell_h);

    try s.live.init(opts.io, allocator, pty_id, .{ .command = opts.command, .args = opts.args, .size = opts.size }, 16);
    errdefer s.live.deinit();
    _ = try s.live.attachSurface(runtime, &s.surface, true);
    // **붙였으면 실패 경로에서 떼야 한다.** `deinit()` 이 부르는 `close()` 는 **라우팅을 안 끊는다**
    // (그건 `closeAndDetach`/`detachSurface` 의 일이다). 아래 `append` 가 실패하면 표면은 해제되는데
    // runtime 은 그 포인터를 계속 들고 있어 **dangling** 이 된다 — `attachSurface` 자신도 실패
    // 경로에서 같은 detach 를 한다(그 함수가 세운 규칙을 그대로 따른다).
    errdefer s.live.detachSurface(runtime);
    s.pump = s.live.pump(runtime);

    try sessions.append(allocator, s);
    errdefer _ = sessions.pop();
    try tab_ptrs.append(allocator, &s.surface);
    app_window.tabs = tab_ptrs.items;
}

/// id 로 세션 번호를 다시 푼다. **보류한 대상은 번호가 아니라 id 다** — 모달이 떠 있는 동안 목록이
/// 밀리면 같은 번호가 다른 세션을 가리킨다(적대적 검증 3회차 실측). 사라졌으면 `null`.
pub fn indexById(sessions: []const *Session, id: ?u64) ?usize {
    const want = id orelse return null;
    for (sessions, 0..) |s, i| {
        if (s.surface.id == want) return i;
    }
    return null;
}

/// 세션 하나를 닫아 목록·탭에서 뺀다. **왜 안 닫혔는지**를 돌려준다.
///
/// **계약은 이미 있다**(`macos-app-host-boundary.md`): 사이드바 ✕ 는 `requestClose` 게이트를 타고,
/// *"실행 중 명령이 있으면 확인 모달을 띄우고 닫기를 보류, 없으면 즉시"* 다. 판정 술어도 중립이
/// 소유한다(`TerminalCore.cursorIsAtPrompt` — OSC 133 의미 상태로 단위 테스트가 고정한다).
///
/// The caller asks for confirmation when a running session cannot close safely.
/// Native teardown only follows that approval; the last session uses the window gate.
pub const CloseResult = enum {
    closed,
    /// 실행 중인 명령이 있다 — 모달이 선행이다.
    busy_needs_confirm,
    /// 마지막 하나다. macOS 는 이때 **창이 닫히고 앱이 종료**된다 — Windows 에서 그 결정을 여기서
    /// 대신 내리지 않는다.
    last_session,
    out_of_range,
};

pub fn close(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: *std.ArrayList(*Session),
    tab_ptrs: *std.ArrayList(*maru.session.surface.Surface),
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    index: usize,
    /// 확인을 이미 받았나. **`true` 는 "사용자가 예를 눌렀다" 는 뜻이지 "검사를 건너뛴다" 가 아니다**
    /// — 마지막 하나 보호는 그대로다(그것은 앱 종료 결정이라 확인의 대상이 다르다).
    confirmed: bool,
) CloseResult {
    if (index >= sessions.items.len) return .out_of_range;
    if (sessions.items.len <= 1) return .last_session;
    const s = sessions.items[index];
    // **락 아래에서 묻는다** — 리더 스레드가 같은 코어를 쓴다.
    const at_prompt = blk: {
        s.surface.lockCore(io);
        defer s.surface.unlockCore(io);
        break :blk s.surface.core.cursorIsAtPrompt();
    };
    if (!at_prompt and !confirmed) return .busy_needs_confirm;

    // **라우팅을 먼저 끊는다.** `destroy` 가 부르는 `deinit` 은 라우팅을 안 끊으므로(그 함수 주석),
    // 여기서 안 떼면 runtime 이 해제된 표면을 계속 든다.
    s.live.closeAndDetach(runtime);
    _ = sessions.orderedRemove(index);
    _ = tab_ptrs.orderedRemove(index);
    app_window.tabs = tab_ptrs.items;
    // **활성 탭을 removal 에 맞춰 당긴다.** 번호만 clamp 하면 앞쪽을 닫았을 때 **보고 있던 세션이
    // 조용히 바뀐다** — 뒤 색인이 하나씩 앞으로 당겨지기 때문이다. 화면은 멀쩡해 보이고 개수 판정도
    // 초록이라, 이름을 견주는 판정을 넣기 전까지 안 보였다(적대적 검증 1회차: `want=session 5
    // got=session 6`). 파일 목록에서 이미 같은 함정을 밟았다(W8.14).
    if (index < app_window.active_tab) {
        app_window.active_tab -= 1;
    } else if (app_window.active_tab >= sessions.items.len) {
        // 닫은 것이 활성이었고 그것이 마지막이면 앞으로 당긴다(그 외에는 같은 번호가 곧 승계자다).
        app_window.active_tab = sessions.items.len - 1;
    }
    s.destroy(allocator);
    return .closed;
}
