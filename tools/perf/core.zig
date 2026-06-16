const std = @import("std");
const maru = @import("maru");

const Budget = struct {
    name: []const u8,
    elapsed_ns: i96,
    budget_ns: i96,
    units: usize,

    fn passed(self: Budget) bool {
        return self.elapsed_ns <= self.budget_ns;
    }
};

const budgets = struct {
    const core_large_output_ns = 2 * std.time.ns_per_s;
    const core_resize_loop_ns = 1 * std.time.ns_per_s;
    const snapshot_serialize_ns = 1 * std.time.ns_per_s;
    // 재-wrap은 "resize 후 처음 과거를 보는 순간" 1회 비용이다(지연 마크). cap(1000행) 기준
    // 회당 ~30ms(행당 free+alloc+복사) — 60fps 두 프레임으로 사용자 체감이 없는 수준이고, 50회
    // 예산 2s는 회당 40ms를 상한으로 고정한다(행 버퍼 풀링 등 구조 변경으로 더 줄이는 건 후속).
    const scrollback_rewrap_ns = 2 * std.time.ns_per_s;
    // kitty 이미지 파이프라인(buildGpuImages + planImageUploads)은 이미지가 있는 동안 매 frame 돈다.
    // 측정(2026-06): 최악(200 placement × 50 image)에서도 회당 ~0.87ms = 30Hz(33ms) 예산의 ~2.6%라
    // 캐시화(#10)가 불필요하다고 결론. 이 게이트는 그 비용이 조용히 회귀하지 않게 1000회 2s(회당 2ms
    // 상한 — findImage O(placements×images)가 더 나빠지거나 sort/alloc 구조가 퇴화하면 잡는다)로 고정.
    const kitty_image_pipeline_ns = 2 * std.time.ns_per_s;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // 성능 측정은 실행 중인 머신 상태에 영향을 받기 때문에 기본 check에는 넣지 않는다.
    // 대신 큰 구조 변경 전후에 opt-in으로 실행해서 느린 구조가 조용히 들어오지 않게 한다.
    const results = [_]Budget{
        try measureLargeOutput(allocator, io),
        try measureResizeLoop(allocator, io),
        try measureSnapshotSerialization(allocator, io),
        try measureScrollbackRewrap(allocator, io),
        try measureKittyImagePipeline(allocator, io),
    };

    const report = try renderReport(allocator, &results);
    defer allocator.free(report);

    try writeText(io, "tests/artifacts/perf/core.txt", report);
    try stdout.writeAll(report);
    try stdout.flush();

    for (results) |result| {
        if (!result.passed()) return error.PerformanceBudgetExceeded;
    }
}

fn measureLargeOutput(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();

    // 터미널은 빌드 로그처럼 큰 stdout을 자주 받으므로, 많은 줄을 쓰는 경로를 먼저 지킨다.
    const line_count = 100_000;
    const start = now(io);
    for (0..line_count) |line_no| {
        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("perf-line-{d}\r\n", .{line_no});
        try core.write(writer.buffered());
    }
    const elapsed = now(io) - start;

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);
    if (std.mem.indexOf(u8, screen, "perf-line-99999") == null) {
        return error.PerfResultMissingExpectedLine;
    }

    return .{
        .name = "core_large_output",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_large_output_ns,
        .units = line_count,
    };
}

fn measureResizeLoop(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();

    // 창 크기 변경은 split, font size 변경, workspace 복구에서 자주 일어나므로 별도 예산으로 본다.
    const iterations = 5_000;
    const start = now(io);
    for (0..iterations) |iteration| {
        const cols: u16 = @intCast(20 + (iteration % 120));
        const rows: u16 = @intCast(4 + (iteration % 36));
        try core.resize(cols, rows);

        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("perf-resize-{d}", .{iteration});
        try core.write(writer.buffered());
    }
    const elapsed = now(io) - start;

    const snapshot = core.snapshot();
    const expected_cells = @as(usize, snapshot.size.cols) * @as(usize, snapshot.size.rows);
    if (snapshot.cells.len != expected_cells) {
        return error.PerfResultInvalidCellCount;
    }

    return .{
        .name = "core_resize_loop",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_resize_loop_ns,
        .units = iterations,
    };
}

fn measureScrollbackRewrap(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 120, .rows = 24 });
    defer core.deinit();

    // 스크롤백을 cap(1000행)까지 채운다 — 재-wrap은 사용자가 resize 후 처음 과거를 보는 순간
    // 1회 일어나는 비용이므로(지연 마크), "폭 변경 + 스크롤 시작"을 반복해 그 1회 비용을 잰다.
    for (0..1200) |line_no| {
        var line_buffer: [160]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("rewrap-source-{d}-abcdefghijklmnopqrstuvwxyz0123456789\r\n", .{line_no});
        try core.write(writer.buffered());
    }

    const iterations = 50;
    const start = now(io);
    for (0..iterations) |iteration| {
        const cols: u16 = @intCast(40 + (iteration % 100));
        if (iteration % 2 == 0) {
            // 지연(deferred) 경로: 바닥에서 resize -> 첫 과거 보기에서 재-wrap 1회.
            try core.resize(cols, 24);
            core.scrollViewport(5);
        } else {
            // 앵커(anchored) 경로: 과거를 보는 중 resize -> 그 자리에서 즉시 재-wrap + 뷰 보정.
            // 사용자가 스크롤백을 읽는 중 창을 끌 때 매 SIGWINCH마다 도는 경로라 함께 잰다.
            core.scrollViewport(5);
            try core.resize(cols, 24);
        }
        core.scrollToBottom();
    }
    const elapsed = now(io) - start;

    if (core.scrollbackLen() == 0) return error.PerfResultMissingScrollback;

    return .{
        .name = "scrollback_rewrap",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.scrollback_rewrap_ns,
        .units = iterations,
    };
}

fn measureSnapshotSerialization(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 120, .rows = 40 });
    defer core.deinit();

    // snapshot은 로그, E2E, 미래 inspector가 공유할 관측 데이터라서 너무 무거워지면 안 된다.
    for (0..400) |line_no| {
        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("snapshot-source-{d}\r\n", .{line_no});
        try core.write(writer.buffered());
    }

    const iterations = 200;
    const start = now(io);
    for (0..iterations) |_| {
        const rendered = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
        allocator.free(rendered);
    }
    const elapsed = now(io) - start;

    return .{
        .name = "snapshot_serialize",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.snapshot_serialize_ns,
        .units = iterations,
    };
}

fn measureKittyImagePipeline(allocator: std.mem.Allocator, io: std.Io) !Budget {
    // kitty 이미지 렌더 파이프라인이 매 frame 도는 비용(buildGpuImages가 GpuImage 슬라이스+pdq sort,
    // planImageUploads가 dedup+픽셀 수집). 캐시화(#10) 전, 이게 30Hz(33ms/frame) 예산 대비 얼마인지
    // 본다. 많은 placement·image(findImage가 O(placements×images))의 최악에 가까운 시나리오로 상한.
    const n_images = 50;
    const n_placements = 200; // cap(1024) 미만, dashboard식 다중 이미지 가정
    var dummy_pixels: [16]u8 = .{0} ** 16; // 2x2 RGBA 더미(픽셀 복사는 dedup으로 frame당 1회만)
    var images: [n_images]maru.terminal.KittyImageView = undefined;
    for (&images, 0..) |*img, i| {
        img.* = .{ .image_id = @intCast(i + 1), .width = 2, .height = 2, .bpp = 4, .generation = 1, .pixels = &dummy_pixels };
    }
    var placements: [n_placements]maru.terminal.KittyPlacement = undefined;
    for (&placements, 0..) |*p, i| {
        p.* = .{ .image_id = @intCast((i % n_images) + 1), .placement_id = 0, .row = @intCast(i % 50), .col = @intCast(i % 200) };
    }
    const size: maru.terminal.Size = .{ .cols = 200, .rows = 50 };
    var uploaded: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer uploaded.deinit(allocator);

    const iterations = 1_000;
    const start = now(io);
    for (0..iterations) |_| {
        const gpu = try maru.renderer.metal_frame.buildGpuImages(allocator, &placements, &images, size, 8, 16);
        defer allocator.free(gpu);
        const plan = try maru.renderer.metal_frame.planImageUploads(allocator, gpu, &images, &uploaded);
        allocator.free(plan.uploads);
        allocator.free(plan.pixels);
        uploaded.clearRetainingCapacity(); // frame당 첫 업로드(dedup 미스)까지 포함해 상한을 본다
    }
    const elapsed = now(io) - start;

    return .{
        .name = "kitty_image_pipeline",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.kitty_image_pipeline_ns,
        .units = iterations,
    };
}

fn renderReport(allocator: std.mem.Allocator, results: []const Budget) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.writeAll("maru.perf.v1\n");
    for (results) |result| {
        try output.writer.print(
            "name={s} elapsed_ms={d} budget_ms={d} units={d} status={s}\n",
            .{
                result.name,
                nsToMs(result.elapsed_ns),
                nsToMs(result.budget_ns),
                result.units,
                if (result.passed()) "pass" else "fail",
            },
        );
    }

    return output.toOwnedSlice();
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn nsToMs(ns: i96) i64 {
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try ensureParent(io, path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash == 0) return;
        try std.Io.Dir.cwd().createDirPath(io, path[0..slash]);
    }
}
