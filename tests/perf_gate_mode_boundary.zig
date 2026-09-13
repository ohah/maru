//! 성능 예산 게이트는 **배포와 같은 최적화 모드로** 돌아야 한다.
//!
//! 실측(2026-09-13, 같은 기계·같은 하네스): `scrollback_rewrap` 이 Debug 1951ms / ReleaseFast 8ms 로
//! **244배** 갈린다. 모드가 어긋나면 게이트는 두 방향으로 거짓말을 한다 — ⑴ Debug 수치가 예산의
//! 97% 를 써서 러너가 붐빌 때 제품과 무관하게 실패하고 ⑵ 배포 빌드가 몇 배 느려져도 통과한다.
//!
//! 그래서 두 파일을 **짝으로** 묶는다: 배포가 쓰는 모드(`release.yml`)와 perf 태스크가 쓰는
//! 모드(`.mise.toml`)가 같아야 한다. 배포 모드를 바꾸면 여기서 걸려 perf 도 함께 옮기게 된다.
const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// `-Doptimize=<모드>` 의 모드 이름을 뽑는다(첫 개).
fn optimizeMode(haystack: []const u8) ?[]const u8 {
    const needle = "-Doptimize=";
    const at = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const rest = haystack[at + needle.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isAlphabetic(rest[end])) : (end += 1) {}
    return if (end == 0) null else rest[0..end];
}

/// `[tasks.<name>]` 블록의 `run = "..."` 줄을 돌려준다.
fn taskRunLine(toml: []const u8, name: []const u8) ?[]const u8 {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "[tasks.{s}]\n", .{name}) catch return null;
    const at = std.mem.indexOf(u8, toml, header) orelse return null;
    var rest = toml[at + header.len ..];
    if (std.mem.indexOf(u8, rest, "\n[tasks.")) |next| rest = rest[0..next];
    const run_at = std.mem.indexOf(u8, rest, "\nrun = ") orelse
        (if (std.mem.startsWith(u8, rest, "run = ")) @as(usize, 0) else return null);
    const line = rest[run_at..];
    const line_end = std.mem.indexOfScalar(u8, line[1..], '\n') orelse (line.len - 1);
    return line[0 .. line_end + 1];
}

test "perf 예산 게이트는 배포와 같은 최적화 모드로 돈다" {
    const allocator = std.testing.allocator;
    const release = try read(allocator, ".github/workflows/release.yml", 512 * 1024);
    defer allocator.free(release);
    const mise = try read(allocator, ".mise.toml", 256 * 1024);
    defer allocator.free(mise);

    const ship_mode = optimizeMode(release) orelse return error.TestUnexpectedResult;
    // 배포는 최적화 모드를 명시해야 한다 — 기본값(Debug)으로 떨어지면 이 판정자 자체가 무의미해진다.
    try std.testing.expect(std.mem.startsWith(u8, ship_mode, "Release"));

    const perf_run = taskRunLine(mise, "perf") orelse return error.TestUnexpectedResult;
    const perf_mode = optimizeMode(perf_run) orelse {
        std.debug.print(
            "\n[tasks.perf] 에 -Doptimize 가 없다 — 기본값 Debug 로 돈다. 배포는 {s} 다.\n",
            .{ship_mode},
        );
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, ship_mode, perf_mode)) {
        std.debug.print("\n배포={s} 인데 perf 게이트={s} 다 — 게이트가 배포와 다른 것을 잰다.\n", .{ ship_mode, perf_mode });
        return error.TestUnexpectedResult;
    }

    // 같은 함정이 이웃 perf/soak 태스크로 번지지 않게, 그것들도 모드를 **명시**하는지 본다.
    for ([_][]const u8{
        "macos-session-host-cr6e-recovery-baseline",
        "macos-app-launch-first-drawable",
        "macos-mermaid-perf",
    }) |name| {
        const line = taskRunLine(mise, name) orelse continue; // 태스크가 사라졌으면 이 판정자의 관심 밖
        if (optimizeMode(line) == null) {
            std.debug.print("\n[tasks.{s}] 에 -Doptimize 가 없다 — 성능을 재는 태스크는 모드를 명시해야 한다.\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}
