//! 글리프 배치 트랜잭션 — 「배치했지만 GPU 로 넘기지 않은」 결과를 아틀라스가 잊게 한다.
//!
//! ## 왜 있나
//!
//! 글리프 아틀라스(`glyph_atlas.GlyphAtlas`)는 글리프를 처음 배치하는 순간 그 슬롯을 **이미 올라간 것**으로
//! 기록한다(`ensureGlyph` 가 hit 이면 `uploaded = false`). 실제 GPU 업로드는 그 배치로 만든 프레임이 백엔드로
//! 넘어갈 때 일어난다. 그런데 호출자가 배치 결과를 **버리는** 길이 있다 — 부분 투영 중 아틀라스 세대가 바뀌어
//! 다음 tick 전체 투영으로 미룰 때, 활성 프레임이 실패해 교체를 건너뛸 때, 교체 자체가 실패할 때.
//!
//! 그러면 버린 배치의 글리프는 아틀라스에는 「올라감」, GPU 텍스처에는 「없음」이 된다. 다음 프레임은 그 글리프를
//! hit 로 처리해 올리지 않고, 텍스처의 그 좌표에 남아 있던 **다른 글리프의 픽셀**을 샘플한다. 2026-09-29 사용자
//! 화면에서 한글 여러 자가 엉뚱한 글리프로 그려졌다(터미널 본문과 사이드바 모두 — 둘은 한 아틀라스를 쓴다).
//!
//! ## 규칙
//!
//! 버리는 길을 하나하나 막으면 다음에 생기는 길이 또 샌다. 그래서 **기본값을 안전하게** 뒤집는다:
//! 배치를 시작할 때(`begin`) 직전 배치가 커밋(`commit`)되지 않았으면 아틀라스를 무효화한다 — 다음 프레임이
//! 모든 글리프를 다시 올린다. 커밋은 결과가 실제로 백엔드로 넘어간 자리에서만 부른다. 결과의 **일부**만 못 가면
//! `taint` 로 표시해 그 배치를 커밋하지 않는다.
//!
//! **이 규칙이 요구하는 것 둘**(적대적 검증 2026-09-29): ① 배치 **뒤에서** 아틀라스 세대 변화를 보고 재시도하는
//! 호출자는 `begin` 의 무효화도 세대 변화로 본다 — 그 재시도가 커밋 없이 끝나면 다음 `begin` 이 또 무효화해
//! 영영 못 그린다(livelock). 그런 호출자는 세대 검사를 `begin` 뒤에 두거나 없애야 한다. ② 무효화는 비용이다 —
//! 매 프레임 커밋 없이 끝나는 길이 있으면 매 프레임 전부 다시 래스터한다.

const std = @import("std");
const glyph_atlas = @import("glyph_atlas.zig");

pub const PlacementTransaction = struct {
    /// 직전 배치가 아직 커밋되지 않았다.
    uncommitted: bool = false,
    /// 이번 배치의 **일부**가 백엔드로 못 간다(pane 하나의 조립 실패·OOM, 호출자가 일부 프레임을 안 넘김).
    /// 같은 배치에서 그 pane 에 처음 놓인 글리프를 다른 pane 이 hit 로 쓸 수 있어, 그 배치 전체를 커밋하지 않는다.
    tainted: bool = false,
    /// 버린 배치 때문에 아틀라스를 무효화한 횟수(진단).
    discarded: usize = 0,

    /// 배치를 시작한다. 직전 배치가 커밋되지 않았으면 그 업로드는 백엔드로 안 갔다 — 아틀라스가 그 글리프들을
    /// 「올라감」으로 기억하지 않게 무효화하고 true 를 돌려준다(호출자가 한 줄 남길 수 있게).
    pub fn begin(self: *PlacementTransaction, atlas: *glyph_atlas.GlyphAtlas) bool {
        const discard = self.uncommitted;
        if (discard) {
            _ = atlas.invalidate(.placement_discarded);
            self.discarded += 1;
        }
        self.uncommitted = true;
        self.tainted = false;
        return discard;
    }

    /// 이번 배치의 일부 결과가 백엔드로 못 간다 — `commit` 이 커밋하지 않게 한다(다음 `begin` 이 무효화한다).
    pub fn taint(self: *PlacementTransaction) void {
        self.tainted = true;
    }

    /// 이번 배치의 결과(업로드 포함)가 백엔드로 넘어갔다. 일부라도 못 갔으면(`taint`) 커밋하지 않는다.
    pub fn commit(self: *PlacementTransaction) void {
        self.uncommitted = self.tainted;
        self.tainted = false;
    }
};

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const terminal = @import("../terminal.zig");
const draw_list = @import("draw_list.zig");
const glyph_layout = @import("glyph_layout.zig");
const glyph_frame = @import("glyph_frame.zig");

/// GPU 텍스처 흉내 — 좌표마다 **마지막으로 올린** 글리프 키. 백엔드가 받은 업로드만 여기에 쓴다.
const FakeTexture = struct {
    cells: std.AutoHashMap([2]u32, glyph_layout.GlyphCacheKey),

    fn init() FakeTexture {
        return .{ .cells = std.AutoHashMap([2]u32, glyph_layout.GlyphCacheKey).init(testing.allocator) };
    }
    fn deinit(self: *FakeTexture) void {
        self.cells.deinit();
    }
    fn apply(self: *FakeTexture, frame: glyph_frame.GlyphFrame) !void {
        for (frame.uploads) |u| try self.cells.put(.{ u.slot.x_px, u.slot.y_px }, u.slot.key);
    }
    /// 이 프레임의 모든 글리프가 텍스처의 제 좌표에서 **제 글리프**를 샘플하는가.
    fn mismatches(self: *const FakeTexture, frame: glyph_frame.GlyphFrame) usize {
        var bad: usize = 0;
        for (frame.glyphs) |g| {
            const on_gpu = self.cells.get(.{ g.slot.x_px, g.slot.y_px }) orelse {
                bad += 1;
                continue;
            };
            if (!std.meta.eql(on_gpu, g.slot.key)) bad += 1;
        }
        return bad;
    }
};

fn runsFor(text: []const u8, cols: u16) !struct { core: terminal.TerminalCore, list: draw_list.DrawList, runs: glyph_layout.GlyphRunList } {
    var core = try terminal.TerminalCore.init(testing.allocator, .{ .cols = cols, .rows = 1 });
    errdefer core.deinit();
    core.clearDirty();
    try core.write(text);
    var list = try draw_list.buildDrawList(testing.allocator, core.snapshot());
    errdefer list.deinit(testing.allocator);
    const runs = try glyph_layout.buildGlyphRunList(testing.allocator, list, .{ .font_size_px = 14, .device_scale = 1 }, glyph_layout.FakeFontBackend{});
    return .{ .core = core, .list = list, .runs = runs };
}

/// 버그의 모양 그대로 — 14px 글리프 8칸짜리 아틀라스(`glyph_frame` 의 소진 판정자와 같은 구성).
///   1. 터미널이 6칸을 채우고 올린다(커밋).
///   2. 부분 투영(사이드바)이 3칸을 더 배치 → 9 > 8 소진 → 무효화·재시작 — **그리고 결과를 버린다.**
///   3. 다음 전체 투영이 터미널 4 + 사이드바 3 을 배치하고 올린다.
/// `use_transaction` 이 거짓이면 3 에서 사이드바 글리프가 hit 로 처리돼 안 올라가고, 텍스처의 그 좌표에는
/// 1 에서 올린 터미널 글리프가 남아 있다 — 사용자 화면의 엉뚱한 글리프다.
fn scenario(use_transaction: bool) !usize {
    const allocator = testing.allocator;
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{ .atlas_width_px = 28, .atlas_height_px = 56 });
    defer atlas.deinit();
    var texture = FakeTexture.init();
    defer texture.deinit();
    var tx: PlacementTransaction = .{};

    var warm = try runsFor("ijklmn", 6);
    defer {
        warm.runs.deinit(allocator);
        warm.list.deinit(allocator);
        warm.core.deinit();
    }
    var side = try runsFor("xyz", 3);
    defer {
        side.runs.deinit(allocator);
        side.list.deinit(allocator);
        side.core.deinit();
    }
    var term4 = try runsFor("ijkl", 4);
    defer {
        term4.runs.deinit(allocator);
        term4.list.deinit(allocator);
        term4.core.deinit();
    }

    // 1. warm — 올리고 커밋.
    if (use_transaction) _ = tx.begin(&atlas);
    {
        var f = try glyph_frame.prepareGlyphFrame(allocator, warm.runs, &atlas);
        defer f.deinit(allocator);
        try texture.apply(f);
        try testing.expectEqual(@as(usize, 0), texture.mismatches(f));
    }
    if (use_transaction) tx.commit();

    // 2. 부분 투영 — 소진(세대 변경) 후 결과를 버린다(백엔드로 안 간다).
    const generation_before = atlas.generation;
    if (use_transaction) _ = tx.begin(&atlas);
    {
        var f = try glyph_frame.prepareGlyphFrame(allocator, side.runs, &atlas);
        f.deinit(allocator); // 버림 — 업로드도 사라진다
    }
    try testing.expect(atlas.generation != generation_before); // 버그가 나는 조건(세대 변경)이 실제로 났다

    // 3. 전체 투영 — 두 목록을 한 세대로 배치하고 올린다.
    if (use_transaction) try testing.expect(tx.begin(&atlas)); // 직전 배치 미커밋 → 무효화
    const lists = [_]glyph_layout.GlyphRunList{ term4.runs, side.runs };
    const frames = try glyph_frame.prepareMultiPaneGlyphFrame(allocator, &lists, &atlas);
    defer {
        for (frames) |*f| f.deinit(allocator);
        allocator.free(frames);
    }
    for (frames) |f| try texture.apply(f);
    if (use_transaction) tx.commit();
    var bad: usize = 0;
    for (frames) |f| bad += texture.mismatches(f);
    return bad;
}

test "배치 트랜잭션: 버린 배치 뒤에도 모든 글리프가 텍스처의 제 좌표에서 제 글리프를 샘플한다" {
    try testing.expectEqual(@as(usize, 0), try scenario(true));
}

test "배치 트랜잭션: 트랜잭션이 없으면 버린 배치의 글리프가 남의 픽셀을 샘플한다 (2026-09-29 증상)" {
    // 대조군 — 이 판정자가 재는 위험이 실제로 있다는 것을 고정한다. 이것이 0 이면 위 판정자는 아무것도
    // 재지 않는다(구성이 소진을 못 일으키는 등).
    try testing.expect(try scenario(false) > 0);
}

test "배치 트랜잭션: 커밋된 배치 뒤의 begin 은 아틀라스를 건드리지 않는다" {
    // 커밋이 제대로 불리면 평상시 비용은 0 이다 — 매 프레임 전체 재업로드가 되면 안 된다.
    var atlas = glyph_atlas.GlyphAtlas.init(testing.allocator, .{});
    defer atlas.deinit();
    var tx: PlacementTransaction = .{};
    try testing.expect(!tx.begin(&atlas));
    tx.commit();
    const generation = atlas.generation;
    try testing.expect(!tx.begin(&atlas));
    try testing.expectEqual(generation, atlas.generation);
    try testing.expectEqual(@as(usize, 0), tx.discarded);
    // 커밋 없이 다시 시작하면 그때만 무효화한다.
    try testing.expect(tx.begin(&atlas));
    try testing.expectEqual(generation + 1, atlas.generation);
    try testing.expectEqual(@as(usize, 1), tx.discarded);
}

test "배치 트랜잭션: 일부가 못 간 배치(taint)는 커밋해도 커밋되지 않는다" {
    // pane 하나의 조립이 실패해도 나머지는 교체된다 — 그 pane 에 처음 놓인 글리프를 다른 pane 이 hit 로 쓰면
    // 그쪽도 남의 픽셀을 샘플한다. 그래서 그 배치 전체를 미커밋으로 둔다.
    var atlas = glyph_atlas.GlyphAtlas.init(testing.allocator, .{});
    defer atlas.deinit();
    var tx: PlacementTransaction = .{};
    _ = tx.begin(&atlas);
    tx.taint();
    tx.commit();
    const generation = atlas.generation;
    try testing.expect(tx.begin(&atlas)); // 다음 배치가 무효화한다
    try testing.expectEqual(generation + 1, atlas.generation);
    // taint 는 그 배치에만 — 새 배치는 깨끗하게 시작한다.
    tx.commit();
    try testing.expect(!tx.begin(&atlas));
}
