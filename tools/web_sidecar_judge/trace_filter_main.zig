//! W9e② 판정 보조 — `maru-web-trace-filter <디렉터리>`. 판정자(`perf_check.zig`)가 sidecar 에서 받은 trace gzip(`trace.gz`)과 프레임 집합
//! (`frames.txt` — 줄마다 id 하나)을 두면, maru 의 순수 거르기(`web_osr_trace.filter` — 앱이 쓰는 그 함수)로 걸러 `kept.gz` 와 `result.txt` 를 쓴다.
//! 따로 실행 파일인 까닭: 거르기는 maru 쪽 파일이라 와이어 정의를 상대 경로로 가져오고, 판정자는 같은 정의를 `web_sidecar_protocol` 모듈로
//! 가져온다 — 한 파일이 두 모듈에 들 수 없다.

const std = @import("std");
const trace = @import("web_osr_trace");

fn readAll(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

fn writeAll(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return error.WriteFailed;
        at += @intCast(n);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len != 2) return 2;
    run(std.mem.span(argv[1])) catch return 1;
    return 0;
}

fn run(dir: []const u8) !void {
    const gpa = std.heap.c_allocator;
    var pb: [1024]u8 = undefined;
    const gz = try readAll(gpa, try std.fmt.bufPrintSentinel(&pb, "{s}/trace.gz", .{dir}, 0));
    defer gpa.free(gz);
    const frames = try readAll(gpa, try std.fmt.bufPrintSentinel(&pb, "{s}/frames.txt", .{dir}, 0));
    defer gpa.free(frames);
    var set = trace.FrameSet.init(gpa);
    defer set.deinit();
    var it = std.mem.tokenizeScalar(u8, frames, '\n');
    while (it.next()) |id| try set.add(id);
    // v20b 탐침: `MARU_TRACE_FILTER_TRUNCATED=<sidecar 의 덮은 ms>` 면 앱처럼 「잘림」 으로 거른다(덮은 시간을 다시 잰다 — 결과 줄 끝에 싣는다).
    const trunc_env = std.c.getenv("MARU_TRACE_FILTER_TRUNCATED");
    var opts: trace.Options = if (trunc_env) |t| .{ .truncated = true, .covered_ms = std.fmt.parseInt(u32, std.mem.span(t), 10) catch 0 } else .{};
    opts.renderer_silent = set.count() == 0; // 앱처럼 — sidecar 의 프레임 집합이 비면(V-A1)
    // 결정 12: sidecar 의 프로세스 나눔 표시(판정자가 `shared.txt` 에 적는다 — 없으면 거짓).
    if (readAll(gpa, try std.fmt.bufPrintSentinel(&pb, "{s}/shared.txt", .{dir}, 0))) |sh| {
        defer gpa.free(sh);
        opts.shared_process = sh.len > 0 and sh[0] == '1';
    } else |_| {}
    var res = try trace.filter(gpa, gz, &set, opts);
    defer res.deinit();
    try writeAll(try std.fmt.bufPrintSentinel(&pb, "{s}/kept.gz", .{dir}, 0), res.gz);
    var line: [512]u8 = undefined;
    const s = res.summary;
    const text = try std.fmt.bufPrint(&line, "{s} {d} {d} {d} {d} {d} {d} {s} covered={d} truncated={} comp_dropped={d} shared={}\n", .{ @tagName(res.outcome), s.events_kept, s.events_dropped, s.screenshots, s.long_task_count, s.frames, res.gz.len, if (res.foreign.len > 0) res.foreign else "-", s.covered_ms, s.truncated, s.compositor_dropped, opts.shared_process });
    try writeAll(try std.fmt.bufPrintSentinel(&pb, "{s}/result.txt", .{dir}, 0), text);
}
