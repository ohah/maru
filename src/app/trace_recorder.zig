//! `MARU_TRACE` 라이브 trace 레코더 — 실제 세션의 base kind 이벤트(output/resize/process-exit)를 `maru.trace.v1`
//! 텍스트로 누적한다. 세션 종료 시 파일로 굳혀, `observability/replay.zig`의 `replayTrace`로 GUI 없이 화면을
//! byte-for-byte 재생할 수 있다(관측 가능성 원칙 — 같은 도메인 데이터를 producer가 여기서 append).
//!
//! 설계: **opt-in**(MARU_TRACE 미설정이면 SurfaceRuntime의 `?*TraceRecorder`가 null — 분기 한 번, 오버헤드 0).
//! 라인 포맷은 `observability/trace.zig` writer 함수 단일 출처를 그대로 쓴다(escape 규칙 공유). in-memory 누적 +
//! 종료 시 1회 파일 write라, 핫패스에 파일 I/O를 넣지 않는다(폭주 세션 OOM은 `cap_bytes`로 상한 — 초과 시 기록
//! 중단하고 `capped`로 표시). 한계(후속): 크래시 시 미기록(증분 flush는 후속), 입력 이벤트 미기록(화면 무영향).

const std = @import("std");
const observability = @import("../observability.zig");

pub const TraceRecorder = struct {
    out: std.Io.Writer.Allocating,
    index: usize = 0,
    capped: bool = false,

    /// 8 MB 상한 — output-heavy 세션(cat 대용량)에서 무한 성장 방지. 초과하면 기록을 멈춘다(부분 trace라도 앞부분은 재생 가능).
    pub const cap_bytes: usize = 8 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) TraceRecorder {
        return .{ .out = .init(allocator) };
    }

    pub fn deinit(self: *TraceRecorder) void {
        self.out.deinit();
    }

    /// 지금 기록해도 되면 writer를 준다(헤더를 한 번 쓰고). capped거나 상한 초과·헤더 실패면 null(호출자는 조용히 skip).
    fn gate(self: *TraceRecorder) ?*std.Io.Writer {
        if (self.capped) return null;
        if (self.out.written().len >= cap_bytes) {
            self.capped = true;
            return null;
        }
        if (self.out.written().len == 0) observability.trace.writeHeader(&self.out.writer) catch return null;
        return &self.out.writer;
    }

    /// 원시 PTY 출력을 기록(재생의 권위 — 파서가 화면·셸 이벤트·cwd를 재도출한다).
    pub fn recordOutput(self: *TraceRecorder, surface_id: u64, bytes: []const u8) void {
        const w = self.gate() orelse return;
        observability.trace.writeOutputEvent(w, self.index, surface_id, bytes) catch return;
        self.index += 1;
    }

    /// 터미널 크기 변경을 기록(재생이 core.resize로 reflow까지 재구성).
    pub fn recordResize(self: *TraceRecorder, surface_id: u64, cols: u16, rows: u16) void {
        const w = self.gate() orelse return;
        observability.trace.writeResizeEvent(w, self.index, surface_id, cols, rows) catch return;
        self.index += 1;
    }

    /// child 종료를 기록. exited→code, signaled→128+sig(셸 관례), unknown→none.
    pub fn recordProcessExit(self: *TraceRecorder, surface_id: u64, code: ?i32) void {
        const w = self.gate() orelse return;
        observability.trace.writeProcessExitEvent(w, self.index, surface_id, code) catch return;
        self.index += 1;
    }

    /// 누적된 trace 텍스트(비파괴). 세션 종료 시 파일로 쓴다.
    pub fn text(self: *TraceRecorder) []const u8 {
        return self.out.written();
    }
};

test "TraceRecorder: base kind를 maru.trace.v1로 누적하고 상한을 지킨다" {
    const a = std.testing.allocator;
    var rec = TraceRecorder.init(a);
    defer rec.deinit();

    rec.recordOutput(1, "hi\r\n");
    rec.recordResize(1, 80, 24);
    rec.recordProcessExit(1, 0);

    // 헤더 + 3 이벤트가 순서·인덱스대로 누적된다.
    const t = rec.text();
    try std.testing.expect(std.mem.startsWith(u8, t, "maru.trace.v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, t, "event 0 output surface=1 bytes=\"hi\\r\\n\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "event 1 resize surface=1 cols=80 rows=24\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "event 2 process-exit surface=1 code=0\n") != null);
}

test "TraceRecorder round-trip: 누적한 trace를 replay하면 화면이 재구성된다" {
    const a = std.testing.allocator;
    const terminal = @import("../terminal.zig");
    const replay = observability.replay;

    // 원 세션 흉내: 출력 청크를 core에 흘리며 recorder에도 기록.
    var src = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 2 });
    defer src.deinit();
    var rec = TraceRecorder.init(a);
    defer rec.deinit();
    const chunks = [_][]const u8{ "\x1b]7;file://h/w\x07", "ab\x1b[1mC\x1b[0m\r\n" };
    for (chunks) |c| {
        try src.write(c);
        rec.recordOutput(3, c);
    }

    // recorder 텍스트를 replay → 화면·cwd byte-for-byte 재구성.
    var replayed = try replay.replayTrace(a, rec.text(), .{ .cols = 8, .rows = 2 });
    defer replayed.deinit();
    const src_screen = try src.dumpUtf8(a);
    defer a.free(src_screen);
    const rep_screen = try replayed.dumpUtf8(a);
    defer a.free(rep_screen);
    try std.testing.expectEqualStrings(src_screen, rep_screen);
    try std.testing.expectEqualStrings("/w", replayed.currentCwd());
}
