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
    // CI runner(ubuntu-latest)는 로컬보다 느리고 부하 변동이 커 1s budget을 간헐 초과했다(5000회 → budget
    // 1s면 회당 0.2ms 상한이라 여유가 없음). 다른 벤치와 같은 2s(회당 0.4ms 상한)로 둬 CI 변동을 흡수하되
    // 구조 회귀(2배+)는 잡는다 — perf는 머신 의존이라 budget 여유가 원칙(opt-in/required 양쪽).
    const core_resize_loop_ns = 2 * std.time.ns_per_s;
    const snapshot_serialize_ns = 1 * std.time.ns_per_s;
    // 재-wrap은 "resize 후 처음 과거를 보는 순간" 1회 비용이다(지연 마크). cap(1000행) 기준
    // 회당 ~30ms(행당 free+alloc+복사) — 60fps 두 프레임으로 사용자 체감이 없는 수준이고, 50회
    // 예산 2s는 회당 40ms를 상한으로 고정한다(행 버퍼 풀링 등 구조 변경으로 더 줄이는 건 후속).
    const scrollback_rewrap_ns = 2 * std.time.ns_per_s;
    // 스크롤백 Find(findMatches)는 검색어 키 입력마다, 그리고 Find가 열린 채 출력이 있는 매 tick마다
    // core lock 아래에서 스크롤백 전체를 재스캔한다(app_session/find.zig `recomputeFind`,
    // app_session.zig의 tick 재검색). 인덱스도 결과 캐시도 없는 구조라 비용이 스크롤백 깊이에 선형인지가
    // 이 게이트의 관심사다. 측정(2026-08, ReleaseFast, 120열): 기본 `scrollback.lines=1000`에서 회당
    // **0.1ms** = 30Hz(33ms) 예산의 0.3%로, kitty 파이프라인(0.87ms)보다 싸다 — 증분 결과 캐시가
    // 불필요하다는 결론의 전제가 이 값이다. 깊이에 선형이라 설정 최대 100,000행에서 14.8ms가 된다.
    // 매치 밀도의 영향은 있지만 지배적이지 않다(10,000행 40회 ReleaseFast에서 0매치 50ms vs 20,046매치
    // 57ms로 14% 차 — 스캔이 비용을 지배한다). 기본 1000행은 잡음에 묻혀 회귀 감지력이 없으므로
    // 5,000행으로 재고, needle은 매치가 다수 나오는 것을 골라 결과 append 경로까지 함께 덮는다.
    //
    // 반복 수는 **CI 실측**으로 정했다. 이 게이트는 ubuntu-latest에서만 도는데 로컬 macOS보다 2.45배
    // 느리다(같은 Debug 빌드). 처음엔 로컬 Debug 989ms=예산 50%를 근거로 40회로 뒀다가 CI에서
    // 2450ms로 **실패**했다 — 로컬 값으로 CI 예산을 정하면 안 된다는 뜻이다(항목별 로컬↔CI 비율이
    // 0.27~2.45배로 흩어져 다른 항목에서 외삽할 수도 없다). 20회·5,000행(총 스캔량 1/4)으로 줄여
    // 로컬 Debug 247ms → CI 예상 ~605ms = 예산의 30%가 된다. 여기에 CI 부하 변동(같은 코드로 12 run
    // max/avg ~1.2)을 얹은 max ~726ms = 36%로, 다른 항목의 실측 대역(max 기준 18~44%)과 같다.
    // 남은 여유가 감지 배율 ~2.75배라 구조 회귀(선형이 깨지는 제곱화, 셀당 여분 할당)를 잡는다.
    const core_find_scrollback_ns = 2 * std.time.ns_per_s;
    // kitty 이미지 파이프라인(buildGpuImages + planImageUploads)은 이미지가 있는 동안 매 frame 돈다.
    // 측정(2026-06): 최악(200 placement × 50 image)에서도 회당 ~0.87ms = 30Hz(33ms) 예산의 ~2.6%라
    // 캐시화(#10)가 불필요하다고 결론. 이 게이트는 그 비용이 조용히 회귀하지 않게 1000회 2s(회당 2ms
    // 상한 — findImage O(placements×images)가 더 나빠지거나 sort/alloc 구조가 퇴화하면 잡는다)로 고정.
    const kitty_image_pipeline_ns = 2 * std.time.ns_per_s;
    // I/O–렌더 스레딩(docs/io-render-threading.md §5): 렌더는 core_mutex를 잡은 채
    // renderSnapshot()+buildDrawList()로 dirty 셀을 DrawList로 복사한 뒤 언락한다(host.zig). 이
    // 구간이 길면 그동안 I/O 스레드(코어 write)가 대기하므로, 그 락-보유 비용의 상한을 잰다. 200회
    // 2s = 회당 10ms 상한(반복 수 근거는 measureRenderBuildDrawList 주석 — CI Debug 러너 여유;
    // ReleaseFast 실측은 회당 ~0.12ms로 30Hz tick 대비 충분히 작다). 구조 회귀(셀당 비용 증가·여분
    // 할당)는 잡는다. perf는 머신 의존이라 budget 여유가 원칙(다른 벤치와 동일한 2s).
    const render_build_drawlist_ns = 2 * std.time.ns_per_s;
    const render_build_scrolled_ns = 2 * std.time.ns_per_s;
    // I/O–렌더 스레딩 Phase 3(docs/io-render-threading.md §9.7): 메인발 코어 mutate를 I/O 스레드로 위임하는
    // CoreCommandQueue 1건 라운드트립(enqueue→pop→free) 비용 — 위임 latency의 바닥(락+append/pop+dupe).
    // UI 이벤트 빈도(스크롤·마우스 60~120Hz)에서 무시 가능해야 한다. 100k회 2s=회당 20µs 상한(구조 회귀만 잡는 여유).
    const core_command_queue_ns = 2 * std.time.ns_per_s;
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
        try measureFindScrollback(allocator, io),
        try measureKittyImagePipeline(allocator, io),
        try measureRenderBuildDrawList(allocator, io),
        try measureRenderBuildScrolled(allocator, io),
        try measureCoreCommandQueue(allocator, io),
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

fn measureFindScrollback(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 120, .rows = 24 });
    defer core.deinit();

    // 기본 cap(1000행)은 회당 0.1ms라 러너 잡음에 묻힌다 — 깊이 선형성을 실제로 볼 수 있게 5배로 둔다
    // (config `scrollback.lines` 허용 범위는 0~100,000이므로 사용자가 실제로 겪을 수 있는 구간이다).
    // 깊이×반복의 총 스캔량이 CI 소요를 정하므로, 이 값을 바꾸면 반복 수도 함께 재산정해야 한다.
    const sb_lines = 5_000;
    core.screen.sb.cap = sb_lines;
    for (0..sb_lines + 24) |line_no| { // +rows: 스크롤백을 cap까지 채우고 활성 화면도 내용으로 덮는다
        var line_buffer: [160]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("find-source-{d}-abcdefghijklmnopqrstuvwxyz0123456789\r\n", .{line_no});
        try core.write(writer.buffered());
    }

    var matches: std.ArrayList(maru.terminal.Match) = .empty;
    defer matches.deinit(allocator);

    // needle "source-1"은 line_no가 1로 시작하는 줄에 걸린다 — 1·10~19·100~199·1000~1999의 1,111줄
    // (실측)이 매치돼 스캔뿐 아니라 결과 append 경로도 함께 덮는다(논리 줄 안에서 비겹침이라 줄당 1개).
    // 스크롤백 0~4999가 cap에 정확히 들어가 eviction은 없고, 활성 화면(5000~5023)은 needle과 안 겹친다.
    const iterations = 20;
    const start = now(io);
    for (0..iterations) |_| try core.findMatches(allocator, "source-1", &matches);
    const elapsed = now(io) - start;

    // 검색이 스크롤백까지 훑었는지 확인한다 — 활성 화면(24행)만 봤다면 매치가 24개를 못 넘으므로,
    // 게이트가 "빈 스크롤백을 빠르게 훑고 통과"하는 false-green이 되지 않게 한다. 실측 1,111개보다
    // 넉넉히 낮게 잡아, setup 라인 형식을 손대도 이 가드가 먼저 깨지지 않게 한다(깊이 검증이 목적).
    if (matches.items.len <= @as(usize, core.size.rows)) return error.PerfResultMissingFindMatches;

    return .{
        .name = "core_find_scrollback",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_find_scrollback_ns,
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

fn measureRenderBuildDrawList(allocator: std.mem.Allocator, io: std.Io) !Budget {
    // I/O–렌더 스레딩 분리(docs/io-render-threading.md §5)의 "lock 보유 시간" 항목을 실측한다. 렌더
    // 스레드는 core_mutex를 잡은 채 renderSnapshot()+buildDrawList()로 dirty 셀을 DrawList로 *복사*하고
    // 언락한다(src/app/host.zig). 그 구간 동안 I/O 스레드의 core.write가 대기하므로, "큰 화면 + full-dirty +
    // 전 셀 장식"이라는 락-보유 최악으로 상한을 잡는다(셀 복사 + 셀당 underline overlay까지 방출).
    const size: maru.terminal.Size = .{ .cols = 300, .rows = 90 }; // 5K 모니터급 큰 화면(27,000 셀)
    var core = try maru.terminal.TerminalCore.init(allocator, size);
    defer core.deinit();

    // 화면을 가득 채우되 underline+전경색을 켜 둔다 — buildDrawList가 모든 셀을 복사하고 셀마다
    // underline overlay까지 내게 해 overlay 경로 비용도 상한에 포함한다. 채우는 write는 타이밍 밖이다.
    const cell_count = @as(usize, size.cols) * @as(usize, size.rows);
    const fill = try allocator.alloc(u8, cell_count);
    defer allocator.free(fill);
    @memset(fill, 'M');
    try core.write("\x1b[4;38;5;205m"); // SGR 4(underline) + 256색 전경 — 전 셀 장식
    try core.write(fill);

    // 반복은 200회로 둔다 — `mise run perf`는 기본 Debug고, 가장 느린 게이트인 CI 러너(ubuntu)는
    // 이 셀-복사 루프에서 회당 ~4ms라 500회면 budget(2s)을 아슬하게 넘긴다(실측 2039ms). 200회면
    // CI ~0.8s로 다른 벤치와 같은 ~2.5x 여유고, ReleaseFast(회당 ~0.12ms)에서도 200 표본이면 안정적이다.
    const iterations = 200;
    const start = now(io);
    for (0..iterations) |_| {
        var list = try maru.renderer.buildDrawList(allocator, core.renderSnapshot());
        list.deinit(allocator);
    }
    const elapsed = now(io) - start;

    // full-dirty 큰 화면이면 셀이 가득 나와야 한다(빈 결과면 dirty/계약 회귀를 드러낸다).
    var probe = try maru.renderer.buildDrawList(allocator, core.renderSnapshot());
    defer probe.deinit(allocator);
    if (probe.cells.len < cell_count / 2) return error.PerfResultDrawListTooSmall;

    return .{
        .name = "render_build_drawlist",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.render_build_drawlist_ns,
        .units = iterations,
    };
}

fn measureRenderBuildScrolled(allocator: std.mem.Allocator, io: std.Io) !Budget {
    // §5의 "scroll 합성" 항목: 과거를 보는 중(view_offset>0)이면 renderSnapshot이 보이는 윈도를
    // viewport_cells로 매 프레임 합성(rows×cols memcpy + 행별 prompt)한 뒤 buildDrawList가 복사한다 —
    // 둘 다 락 안이다. viewport_cells는 첫 프레임에 할당되고 이후엔 memcpy만이라, "스크롤 중 큰 화면"
    // 락-보유의 정상 상태 비용 상한을 잰다(첫 1회 할당은 워밍업으로 타이밍 밖에 둔다).
    const size: maru.terminal.Size = .{ .cols = 300, .rows = 90 };
    var core = try maru.terminal.TerminalCore.init(allocator, size);
    defer core.deinit();

    // 스크롤백을 화면보다 넉넉히 채운 뒤 과거로 스크롤한다(뷰포트가 스크롤백 윈도에 들어가게).
    for (0..2_000) |line_no| {
        var line_buffer: [320]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("scroll-src-{d}-MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM\r\n", .{line_no});
        try core.write(writer.buffered());
    }
    core.scrollViewport(45); // 화면 절반 위로
    _ = core.renderSnapshot(); // 첫 합성으로 viewport_cells 할당(이후엔 memcpy만) — 워밍업

    const iterations = 200; // render_build_drawlist와 동일한 이유(CI budget 여유)
    const start = now(io);
    for (0..iterations) |_| {
        var list = try maru.renderer.buildDrawList(allocator, core.renderSnapshot());
        list.deinit(allocator);
    }
    const elapsed = now(io) - start;

    if (core.viewOffset() == 0) return error.PerfResultNotScrolled; // 스크롤 상태가 유지돼야 합성 경로를 잰 것

    return .{
        .name = "render_build_scrolled",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.render_build_scrolled_ns,
        .units = iterations,
    };
}

fn measureCoreCommandQueue(allocator: std.mem.Allocator, io: std.Io) !Budget {
    // Phase 3(docs/io-render-threading.md §9.7): 메인이 코어 mutate를 명령으로 위임하고 reader가 빼는
    // CoreCommandQueue의 1건 라운드트립 비용을 잰다 — enqueue(락+append)→pop(락+head 전진).
    // 위임 적용 지연의 바닥이며, 이게 UI 이벤트 빈도에서 작아야 (a) 단일책임 모델이 latency를 안 만든다.
    // scroll(payload 없음)으로 큐 기계 비용 자체를 잰다. MARU_DEBUG 미설정이라 타임스탬프 클럭 읽기는 없다.
    var queue = try maru.app.CoreCommandQueue.init(io, allocator, 64);
    defer queue.deinit();

    const iterations = 100_000;
    const start = now(io);
    for (0..iterations) |i| {
        try queue.enqueueBlocking(.{ .scroll = @intCast(i) });
        _ = queue.pop() orelse return error.PerfResultQueueEmpty;
    }
    const elapsed = now(io) - start;

    if (queue.hasPending()) return error.PerfResultQueueNotDrained;

    return .{
        .name = "core_command_queue",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_command_queue_ns,
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
