//! macOS 앱 세션의 글리프 배치가 **배치 트랜잭션을 지나는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-29 — 몇 시간 켜 둔 앱에서 한글 여러 자가 엉뚱한 글리프로 그려졌다(터미널 본문과 사이드바 모두).
//! 사이드바만 다시 그리는 경로가 배치 중 아틀라스 세대가 바뀌자 그 배치 결과(업로드 포함)를 버렸는데, 아틀라스는
//! 그 글리프를 「올라감」으로 기억했다. 다음 프레임은 hit 로 처리해 올리지 않았고, GPU 텍스처의 그 좌표에 남아
//! 있던 다른 글리프의 픽셀을 샘플했다.
//!
//! 고친 규칙(`renderer.glyph_placement.PlacementTransaction`)은 순수 판정자가 실제 아틀라스·가짜 텍스처로 잰다.
//! 여기서는 **배선**을 잰다 — 규칙이 맞아도 배치가 트랜잭션을 우회하거나 커밋이 엉뚱한 자리에 있으면 같은 사고가
//! 난다. app_session 테스트는 macOS 잡에서만 돌아 PR 게이트로는 이것이 유일하다.

const std = @import("std");

const session_path = "src/platform/macos/app_session.zig";
const session_dir = "src/platform/macos/app_session";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

/// 주석을 **같은 길이의 공백으로** 지운다 — 위치가 그대로라 `insideTest` 를 쓸 수 있다. 주석 속 이름을 호출로 세지 않는다.
fn blankComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, src);
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) {
        if (out[i] == '/' and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        }
    }
    return out;
}

/// `at` 을 감싸는 가장 가까운 선언 머리가 테스트(`test "` 또는 `fn test…` 헬퍼)인가.
fn insideTest(src: []const u8, at: usize) bool {
    const heads = [_][]const u8{ "\ntest \"", "\nfn ", "\npub fn ", "\n    pub fn ", "\n    fn " };
    var best: usize = 0;
    var best_head: []const u8 = "";
    for (heads) |h| {
        if (std.mem.lastIndexOf(u8, src[0..at], h)) |pos| if (pos >= best) {
            best = pos;
            best_head = h;
        };
    }
    if (std.mem.eql(u8, best_head, "\ntest \"")) return true;
    const name_at = best + best_head.len;
    return std.mem.startsWith(u8, src[name_at..], "test");
}

test "앱 세션의 글리프 배치는 한 입구에서 트랜잭션을 시작하고, metal_buffer 교체가 성공한 자리에서만 커밋한다" {
    const a = std.testing.allocator;
    const raw_text = try read(a, session_path);
    defer a.free(raw_text);
    const raw = try blankComments(a, raw_text);
    defer a.free(raw);

    // ① **배치 입구가 하나다.** 제품 코드에서 공유 아틀라스에 배치하는 호출이 `placeAndDistribute` 안 하나뿐이어야
    //    트랜잭션이 모든 배치를 본다. 새 배치 경로가 생기면 여기서 빨개진다 — 그 경로도 트랜잭션을 지나게 하라.
    {
        var product_place: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, raw, at, "renderer_state.placeMultiPane(")) |pos| : (at = pos + 1) {
            if (!insideTest(raw, pos)) product_place += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), product_place);
        at = 0;
        while (std.mem.indexOfPos(u8, raw, at, "buildFromDrawList(")) |pos| : (at = pos + 1) {
            if (!insideTest(raw, pos)) {
                std.debug.print("제품 코드에 트랜잭션 밖 배치(buildFromDrawList)가 생겼다\n", .{});
                return error.PlacementOutsideTransaction;
            }
        }
    }

    const src = try normalize(a, raw);
    defer a.free(src);

    // ② **시작은 배치 바로 앞이다.** 배치 뒤에 두면 이번 배치를 무효화하고, 조건을 걸면 버린 배치를 못 잊는다.
    const fn_at = std.mem.indexOf(u8, src, "fn placeAndDistribute(") orelse return error.PlaceFnMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, " fn ") orelse src.len;
    const body = src[fn_at..fn_end];
    const begin_then_place = "if (self.glyph_placement.begin(&self.renderer_state.atlas)) noteGlyphPlacementDiscarded(self.glyph_placement.discarded); const frames = self.renderer_state.placeMultiPane(self.allocator, lists) catch {";
    try std.testing.expectEqual(@as(usize, 1), countAll(body, begin_then_place));
    try std.testing.expectEqual(@as(usize, 1), countAll(src, "self.glyph_placement.begin("));

    // ③ **커밋은 교체가 성공한 세 자리에만.** 교체 실패·스킵·세대 변경으로 버리는 길에 커밋이 있으면 그 배치를
    //    아틀라스가 「올라감」으로 기억한다 — 이번 사고 그대로다. 교체 성공 분기의 첫 문장이어야 한다.
    const commits = [_][]const u8{
        "kg_live_ids.items)) |_| { self.glyph_placement.commit();",
        "self.metal_buffer.replaceSidebar(self.allocator, sidebar_frame, sidebar_colors, self.renderer_state.atlas.config)) |_| blk: { self.glyph_placement.commit();",
        ") catch return; if (pane_frames.items.len > 0) self.glyph_placement.taint(); self.glyph_placement.commit(); self.metal_buffer.stampChromeGeometry(self.chromeGeometrySnapshot());",
    };
    for (commits) |c| {
        if (countAll(src, c) != 1) {
            std.debug.print("커밋 자리가 교체 성공 바로 뒤가 아니다: {s}\n", .{c});
            return error.CommitMisplaced;
        }
    }
    try std.testing.expectEqual(@as(usize, commits.len), countAll(src, "self.glyph_placement.commit();"));

    // ⑤ **커밋은 `commit()` 으로만.** 필드를 직접 쓰거나(`glyph_placement.uncommitted = false`) 포인터 별칭으로
    //    부르면 ③ 의 자리 판정을 우회한다(적대적 검증 G5·G6).
    for ([_][]const u8{ "glyph_placement.uncommitted", "glyph_placement.tainted", "&self.glyph_placement" }) |forbidden| {
        if (countAll(src, forbidden) != 0) {
            std.debug.print("트랜잭션을 우회하는 모양이 있다: {s}\n", .{forbidden});
            return error.TransactionBypassed;
        }
    }

    // ⑥ **일부만 못 가는 배치는 taint 한다.** pane 하나가 빠져도(조립 실패·OOM) 배치 전체가 커밋되면, 그 pane 에
    //    처음 놓인 글리프를 다른 pane 이 hit 로 쓸 때 남의 픽셀을 샘플한다.
    {
        const drop_arm = "} else |_| { self.glyph_placement.taint(); var v = rf; v.deinit(self.allocator); }";
        const drops = countAll(body, "var v = rf; v.deinit(self.allocator);");
        try std.testing.expect(drops >= 1);
        try std.testing.expectEqual(drops, countAll(body, drop_arm));
        try std.testing.expectEqual(@as(usize, 1), countAll(body, "self.renderer_state) catch { self.glyph_placement.taint();"));
        try std.testing.expectEqual(@as(usize, 1), countAll(body, "if (rich_glyph_start) |start| self.gpu_glyphs.items.len = start; self.glyph_placement.taint(); };"));
    }

    // ⑦ **복구 선택 화면은 배치 뒤 세대 검사를 하지 않고, 안 싣는 pane 프레임이 있으면 커밋하지 않는다.** 세대 검사를
    //    두면 `begin` 의 무효화까지 세대 변화로 읽어 한 번 미커밋된 뒤로 영영 못 그린다(적대적 검증 실측 livelock).
    {
        const rec_at = std.mem.indexOf(u8, src, "fn projectDeferredRecoverySidebar(") orelse return error.RecoveryMissing;
        const rec_end = std.mem.indexOfPos(u8, src, rec_at + 1, " fn ") orelse src.len;
        const rec = src[rec_at..rec_end];
        try std.testing.expectEqual(@as(usize, 0), countAll(rec, "atlas.generation"));
        try std.testing.expectEqual(@as(usize, 1), countAll(rec, "if (pane_frames.items.len > 0) self.glyph_placement.taint(); self.glyph_placement.commit();"));
    }

    // ⑧ **하위 파일도 배치하지 않는다**, 그리고 배치 프리미티브를 직접 부르지 않는다(적대적 검증 G7·G8). `app_session.zig`
    //    만 읽으면 `app_session/*.zig` 에 생긴 배치를 못 본다.
    {
        const primitives = [_][]const u8{ "placeMultiPane(", "prepareMultiPaneGlyphFrame(", "prepareGlyphFrame(", ".ensureGlyph(", "buildFromDrawList(", "atlas.grow(" };
        for (primitives) |prim| {
            var at: usize = 0;
            var product: usize = 0;
            while (std.mem.indexOfPos(u8, raw, at, prim)) |pos| : (at = pos + 1) {
                if (!insideTest(raw, pos)) product += 1;
            }
            const allowed: usize = if (std.mem.eql(u8, prim, "placeMultiPane(")) 1 else 0;
            if (product != allowed) {
                std.debug.print("app_session.zig 제품 코드의 «{s}» 가 {d} 곳 — {d} 곳이어야 한다\n", .{ prim, product, allowed });
                return error.PlacementOutsideTransaction;
            }
        }
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, session_dir, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var it = dir.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ session_dir, entry.name });
            defer a.free(path);
            const sub_text = try read(a, path);
            defer a.free(sub_text);
            const sub = try blankComments(a, sub_text);
            defer a.free(sub);
            for (primitives) |prim| {
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, sub, at, prim)) |pos| : (at = pos + 1) {
                    if (insideTest(sub, pos)) continue;
                    std.debug.print("{s} 제품 코드에 트랜잭션 밖 배치 «{s}» 가 있다\n", .{ path, prim });
                    return error.PlacementOutsideTransaction;
                }
            }
        }
    }

    // ④ **세대 변경으로 버리는 분기는 커밋하지 않는다.** 그 분기가 사고의 출발점이다.
    const gen_branch_at = std.mem.indexOf(u8, src, "if (self.renderer_state.atlas.generation != gen_before) {") orelse
        return error.GenerationBranchMissing;
    const gen_branch_end = std.mem.indexOfPos(u8, src, gen_branch_at, "} else if (sidebar_frame)") orelse
        return error.GenerationBranchEnd;
    try std.testing.expectEqual(@as(usize, 0), countAll(src[gen_branch_at..gen_branch_end], "glyph_placement.commit"));
}
