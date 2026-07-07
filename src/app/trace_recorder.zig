//! `MARU_TRACE` 라이브 trace 레코더 — 실제 세션의 base kind 이벤트(output/resize/process-exit)를 `maru.trace.v1`
//! 텍스트로 **증분 기록**한다. `observability/replay.zig`의 `replayTrace`로 GUI 없이 화면을 byte-for-byte 재생할 수
//! 있다(관측 가능성 원칙 — 같은 도메인 데이터를 producer가 여기서 append).
//!
//! 설계: **opt-in**(MARU_TRACE 미설정이면 SurfaceRuntime의 `?*TraceRecorder`가 null — 분기 한 번, 오버헤드 0).
//! 라인 포맷은 `observability/trace.zig` writer 함수 단일 출처를 쓴다(escape 규칙 공유). 레코더는 **sink를 소유하지
//! 않고** 주입받은 `*std.Io.Writer`에 쓴다 — 프로덕션은 host(app_session)가 준 file writer(파일로 증분 append →
//! **크래시 복원**: 크래시 직전까지의 이벤트가 디스크에 남는다), 테스트는 in-memory `Allocating`. **이벤트마다
//! flush**하므로 file sink면 OS로 밀려난다. 파일/버퍼 수명과 최종 flush/sync/close는 host 몫. 폭주 세션은 `cap_bytes`
//! 상한으로 막는다(초과 시 기록 중단·`capped`). write 중간 실패로 부분 줄이 남아도 reader(parseEvents)가 잘린 tail을
//! 관대 처리한다. output/resize/process-exit(SurfaceRuntime.applyPtyEvent·resize)와 input(writeInput/NonBlocking)을
//! 기록한다 — input은 재생 화면엔 안 쓰이지만(화면은 output echo로 재구성) 완전한 세션 기록·분석용이고 타이핑된
//! 비밀까지 담을 수 있어 output보다 민감하다(recordInput 참고).

const std = @import("std");
const observability = @import("../observability.zig");

pub const TraceRecorder = struct {
    /// 소유하지 않음 — host가 file/buffer 수명 + 최종 flush/sync/close를 관리한다. 레코더는 이벤트만 흘리고 flush한다.
    writer: *std.Io.Writer,
    index: usize = 0,
    /// 대략적 누적 바이트(cap 판정 — safety limit라 정확할 필요 없음).
    written: usize = 0,
    capped: bool = false,
    header_done: bool = false,

    /// 8 MB 상한 — output-heavy 세션(cat 대용량)에서 파일/버퍼 무한 성장 방지. 초과하면 기록을 멈춘다(앞부분은 재생 가능).
    pub const cap_bytes: usize = 8 * 1024 * 1024;
    /// 이벤트당 라인 오버헤드 추정(`event N kind surface=… ` prefix + escape) — cap 카운트용 근사.
    const line_overhead = 48;

    pub fn init(writer: *std.Io.Writer) TraceRecorder {
        return .{ .writer = writer };
    }

    /// 지금 기록해도 되면 writer를 준다(헤더를 한 번 쓰고). capped·상한 초과·헤더 실패면 null(호출자는 조용히 skip).
    fn gate(self: *TraceRecorder) ?*std.Io.Writer {
        if (self.capped) return null;
        if (self.written >= cap_bytes) {
            self.capped = true;
            return null;
        }
        if (!self.header_done) {
            observability.trace.writeHeader(self.writer) catch return self.gateFail();
            self.header_done = true;
            self.written += observability.trace.header.len + 1;
        }
        return self.writer;
    }

    fn gateFail(self: *TraceRecorder) ?*std.Io.Writer {
        self.capped = true;
        return null;
    }

    /// write가 중간에 실패하면(OOM·I/O 에러) 부분 줄이 남을 수 있다 — 더 기록하지 않도록 capped로 막는다. 남은 부분
    /// 줄(개행으로 안 끝난 마지막 줄)은 reader가 잘린 tail로 관대 처리하므로, 앞부분은 유효한 trace로 재생된다.
    fn markFailed(self: *TraceRecorder) void {
        self.capped = true;
    }

    /// 이벤트 하나를 쓴 뒤: **증분 flush**(file sink면 OS로 밀어 크래시 복원; in-memory면 사실상 no-op) + 카운트 전진.
    fn afterEvent(self: *TraceRecorder, approx_bytes: usize) void {
        self.writer.flush() catch return self.markFailed();
        self.index += 1;
        self.written += approx_bytes;
    }

    /// 원시 PTY 출력을 기록(재생의 권위 — 파서가 화면·셸 이벤트·cwd를 재도출한다).
    pub fn recordOutput(self: *TraceRecorder, surface_id: u64, bytes: []const u8) void {
        const w = self.gate() orelse return;
        observability.trace.writeOutputEvent(w, self.index, surface_id, bytes) catch return self.markFailed();
        self.afterEvent(bytes.len + line_overhead);
    }

    /// 사용자 입력(core→pty로 실제 전송된 바이트)을 기록한다. **재생 화면엔 직접 영향 없음**(입력은 child로 가고,
    /// 화면은 child가 되돌린 output에 담긴 echo로 재구성됨) — 완전한 세션 기록·입력 타이밍 분석용. ⚠️입력은 화면에
    /// 안 뜨는 타이핑(비밀번호 프롬프트 등)까지 담을 수 있어 output보다 민감하다. guardFixture/anonymize가 할당·PII를
    /// 처리하지만 bare 비밀은 못 잡으니 fixture 승격 전 사람 검토가 최종 안전망(docs/trace-replay.md §민감정보).
    pub fn recordInput(self: *TraceRecorder, surface_id: u64, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const w = self.gate() orelse return;
        observability.trace.writeInputEvent(w, self.index, surface_id, bytes) catch return self.markFailed();
        self.afterEvent(bytes.len + line_overhead);
    }

    /// 터미널 크기 변경을 기록(재생이 core.resize로 reflow까지 재구성).
    pub fn recordResize(self: *TraceRecorder, surface_id: u64, cols: u16, rows: u16) void {
        const w = self.gate() orelse return;
        observability.trace.writeResizeEvent(w, self.index, surface_id, cols, rows) catch return self.markFailed();
        self.afterEvent(line_overhead);
    }

    /// child 종료를 기록. exited→code, signaled→128+sig(셸 관례), unknown→none.
    pub fn recordProcessExit(self: *TraceRecorder, surface_id: u64, code: ?i32) void {
        const w = self.gate() orelse return;
        observability.trace.writeProcessExitEvent(w, self.index, surface_id, code) catch return self.markFailed();
        self.afterEvent(line_overhead);
    }
};

test "TraceRecorder: base kind를 maru.trace.v1로 이벤트마다 flush하며 누적한다" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a); // 테스트 sink(in-memory) — flush는 no-op
    defer out.deinit();
    var rec = TraceRecorder.init(&out.writer);

    rec.recordOutput(1, "hi\r\n");
    rec.recordResize(1, 80, 24);
    rec.recordProcessExit(1, 0);

    // 헤더 + 3 이벤트가 순서·인덱스대로 누적된다.
    const t = out.written();
    try std.testing.expect(std.mem.startsWith(u8, t, "maru.trace.v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, t, "event 0 output surface=1 bytes=\"hi\\r\\n\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "event 1 resize surface=1 cols=80 rows=24\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "event 2 process-exit surface=1 code=0\n") != null);
}

test "TraceRecorder round-trip: 기록한 trace를 replay하면 화면이 재구성된다" {
    const a = std.testing.allocator;
    const terminal = @import("../terminal.zig");
    const replay = observability.replay;

    // 원 세션 흉내: 출력 청크를 core에 흘리며 recorder에도 기록.
    var src = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 2 });
    defer src.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var rec = TraceRecorder.init(&out.writer);
    const chunks = [_][]const u8{ "\x1b]7;file://h/w\x07", "ab\x1b[1mC\x1b[0m\r\n" };
    for (chunks) |c| {
        try src.write(c);
        rec.recordOutput(3, c);
    }

    // recorder 텍스트를 replay → 화면·cwd byte-for-byte 재구성.
    var replayed = try replay.replayTrace(a, out.written(), .{ .cols = 8, .rows = 2 });
    defer replayed.deinit();
    const src_screen = try src.dumpUtf8(a);
    defer a.free(src_screen);
    const rep_screen = try replayed.dumpUtf8(a);
    defer a.free(rep_screen);
    try std.testing.expectEqualStrings(src_screen, rep_screen);
    try std.testing.expectEqualStrings("/w", replayed.currentCwd());
}

// write 실패(OOM·I/O) 회귀: 어느 write가 중간에 끊겨 부분 줄이 남아도, sink 내용은 항상 파싱 가능해야 한다 —
// 레코더가 실패 시 기록을 멈추고(capped), 마지막 잘린 줄은 reader(parseEvents)가 관대 처리한다(code-review [13]).
test "TraceRecorder: 어떤 write 실패 지점에서도 sink는 파싱 가능한 prefix" {
    var idx: usize = 0;
    while (idx < 60) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
        var out: std.Io.Writer.Allocating = .init(failing.allocator());
        defer out.deinit();
        var rec = TraceRecorder.init(&out.writer);
        rec.recordOutput(1, "hello world output chunk one");
        rec.recordResize(1, 80, 24);
        rec.recordOutput(1, "second chunk of output bytes");
        rec.recordProcessExit(1, 0);

        // 핵심 불변식: **BadLine(중간 줄 손상)은 절대 없어야** 한다 — 부분 tail은 reader가 떨구므로. 헤더조차 못 쓴
        // 아주 이른 절단은 BadHeader(재생할 것 없음), 파싱 자체 OOM은 OutOfMemory — 둘 다 허용.
        const parsed = observability.trace.parseEvents(std.testing.allocator, out.written()) catch |e| {
            try std.testing.expect(e == error.OutOfMemory or e == error.BadHeader);
            continue;
        };
        observability.trace.freeParsedEvents(std.testing.allocator, parsed);
    }
}
