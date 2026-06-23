const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_layout = @import("glyph_layout.zig");
const terminal = @import("../terminal.zig");

pub const PreparedGlyph = struct {
    run: glyph_layout.GlyphRun,
    slot: glyph_atlas.AtlasSlot,
};

pub const GlyphUpload = struct {
    glyph_index: usize,
    slot: glyph_atlas.AtlasSlot,
    upload_bytes: usize,
    evicted: ?glyph_atlas.AtlasSlot = null,
};

pub const GlyphFrameStats = struct {
    glyph_count: usize = 0,
    upload_count: usize = 0,
    upload_bytes: usize = 0,
    reused_count: usize = 0,
    evicted_count: usize = 0,
    fallback_count: usize = 0,
    replacement_count: usize = 0,
};

pub const GlyphFrame = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    glyphs: []PreparedGlyph,
    overlays: []draw_list.DrawOverlay,
    uploads: []GlyphUpload,
    stats: GlyphFrameStats,

    pub fn deinit(self: *GlyphFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.overlays);
        allocator.free(self.uploads);
        self.* = undefined;
    }
};

pub fn prepareGlyphFrame(
    allocator: std.mem.Allocator,
    glyphs: glyph_layout.GlyphRunList,
    atlas: *glyph_atlas.GlyphAtlas,
) !GlyphFrame {
    // GlyphFrame은 제품 Metal/WebGPU backend가 소비할 첫 텍스트 frame 계약이다.
    // 여기서는 GPU texture를 직접 만들지 않고, 각 glyph가 어느 atlas slot을 써야 하는지와
    // 이번 frame에서 어떤 slot을 업로드해야 하는지만 결정한다. 이 경계가 있어야 다음
    // backend 구현이 font/layout/cache 정책을 다시 해석하지 않는다.
    var prepared: std.ArrayList(PreparedGlyph) = .empty;
    errdefer prepared.deinit(allocator);
    try prepared.ensureTotalCapacity(allocator, glyphs.glyphs.len);

    var uploads: std.ArrayList(GlyphUpload) = .empty;
    errdefer uploads.deinit(allocator);
    try uploads.ensureTotalCapacity(allocator, glyphs.glyphs.len);

    var stats: GlyphFrameStats = .{
        .glyph_count = glyphs.glyphs.len,
        .fallback_count = glyphs.fallback_count,
        .replacement_count = glyphs.replacement_count,
    };

    // atlas 좌표가 frame 중간에 소진되면(lookup.invalidated) 이미 나눠준 슬롯들이 무효가 된다 —
    // 한 frame에 두 좌표 세대가 섞이면 앞 글리프들이 덮어쓰인 텍셀을 샘플해 화면이 깨진다(예: 보더라인
    // ─가 나중 글리프 ?의 비트맵을 샘플). invalidate 직후 atlas는 비어 있으므로 frame을 처음부터 다시
    // 빌드해 모든 글리프가 일관된 새 좌표를 받게 한다.
    //
    // 첫 재시작은 grow 없이 한다 — 소진이 "이전 frame들이 남긴 누적 좌표"(eviction이 좌표를 회수 안 함)
    // 때문일 수 있어, clean repack((0,0)부터)만으로 들어가는 경우가 많다(기존 동작 보존). 그래도 또
    // 소진되면(=이 frame의 고유 글리프가 현재 텍스처보다 많다) atlas.grow()로 텍스처를 키우고 재시작한다 —
    // 들어갈 때까지 반복. 이게 충돌의 근본 차단: 좌표가 모자라 두 글리프를 같은 자리에 겹치는 대신
    // **자리를 늘려** 모든 distinct 글리프가 고유 좌표를 받는다(Ghostty식 grow on full). grow가 false면
    // (이미 max(8192²) 도달 — 한 frame이 그 용량마저 초과, 현실 도달 불가) 재시작해도 못 들어가니
    // 멈추고 진행한다. 종료는 grow의 false가 보장한다 — 매번 2배라 max까지 유한 단계 뒤 반드시 false.
    var attempt: u8 = 0;
    build: while (true) {
        for (glyphs.glyphs, 0..) |glyph, index| {
            const lookup = try atlas.ensureGlyph(glyph);
            // 1회차(attempt==0)는 grow 없이 clean repack. 2회차+는 grow로 자리를 만든다 — grow가 false면
            // 더 못 키우니 재시작을 멈추고(아래로 떨어져) 진행한다(degraded, 다음 frame에 회복).
            if (lookup.invalidated and (attempt == 0 or atlas.grow())) {
                attempt += 1;
                prepared.clearRetainingCapacity();
                uploads.clearRetainingCapacity();
                stats.upload_count = 0;
                stats.upload_bytes = 0;
                stats.evicted_count = 0;
                stats.reused_count = 0;
                // invalidate를 일으킨 글리프의 슬롯은 이미 atlas에 들어가 있다 — 그대로 두면
                // 재시작 패스에서 hit이 돼 uploads에서 빠지고, Metal 텍스처엔 비트맵이 안 올라가
                // 그 글리프만 빈 칸이 된다. 한 번 더 비워 재시작 패스가 전부 miss(=업로드)가 되게.
                _ = atlas.invalidate(.atlas_full);
                continue :build;
            }
            prepared.appendAssumeCapacity(.{
                .run = glyph,
                .slot = lookup.slot,
            });

            if (lookup.uploaded) {
                stats.upload_count += 1;
                stats.upload_bytes += lookup.upload_bytes;
                if (lookup.evicted != null) stats.evicted_count += 1;
                uploads.appendAssumeCapacity(.{
                    .glyph_index = index,
                    .slot = lookup.slot,
                    .upload_bytes = lookup.upload_bytes,
                    .evicted = lookup.evicted,
                });
            } else {
                stats.reused_count += 1;
            }
        }
        break;
    }

    const overlay_copy = try allocator.dupe(draw_list.DrawOverlay, glyphs.overlays);
    errdefer allocator.free(overlay_copy);
    const prepared_slice = try prepared.toOwnedSlice(allocator);
    errdefer allocator.free(prepared_slice);
    const upload_slice = try uploads.toOwnedSlice(allocator);
    errdefer allocator.free(upload_slice);

    return .{
        .size = glyphs.size,
        .cursor = glyphs.cursor,
        .dirty = glyphs.dirty,
        .glyphs = prepared_slice,
        .overlays = overlay_copy,
        .uploads = upload_slice,
        .stats = stats,
    };
}

test "glyph frame prepares atlas slots and upload plan" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 이 테스트는 실제 GPU 없이 "frame 준비" 계약을 고정한다. 같은 glyph가 반복되면
    // atlas slot은 재사용되어야 하고, backend는 첫 miss만 upload 후보로 받아야 한다.
    core.clearDirty();
    try core.write("AA");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{ .font_size_px = 14, .device_scale = 2 },
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), frame.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), frame.stats.glyph_count);
    try std.testing.expectEqual(frame.glyphs[0].slot.id, frame.glyphs[1].slot.id);
    try std.testing.expectEqual(@as(usize, 2), frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 2), frame.stats.reused_count);
    try std.testing.expectEqual(@as(usize, 2), frame.uploads.len);
    try std.testing.expect(frame.stats.upload_bytes > 0);
    try std.testing.expectEqual(@as(usize, 2), atlas.stats.hits);
    try std.testing.expectEqual(@as(usize, 2), atlas.stats.misses);

    // upload 항목은 자기 PreparedGlyph를 glyph_index로 가리켜야 backend가 업로드한
    // bitmap을 올바른 glyph/slot에 매핑할 수 있다. "AA  "에서 첫 'A'(0)와 첫
    // space(2)만 miss이고, 그 index의 PreparedGlyph slot과 upload slot이 같아야 한다.
    try std.testing.expectEqual(@as(usize, 0), frame.uploads[0].glyph_index);
    try std.testing.expectEqual(@as(usize, 2), frame.uploads[1].glyph_index);
    try std.testing.expectEqual(
        frame.glyphs[frame.uploads[0].glyph_index].slot.id,
        frame.uploads[0].slot.id,
    );
}

test "glyph frame preserves overlays for draw-time effects" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // underline과 cursor는 glyph bitmap이 아니라 draw-time overlay다. GlyphFrame으로
    // 넘어오며 이 정보가 사라지면 Metal backend가 atlas slot은 알아도 실제 터미널
    // UI 효과를 그릴 수 없으므로, frame 계약에서 반드시 보존한다.
    core.clearDirty();
    try core.write("A");
    core.screen.cells[0].style.underline = true;

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{},
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.overlays.len);
    try std.testing.expectEqual(draw_list.LineKind.underline, frame.overlays[0].line.kind);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[0].line.row);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[0].line.col);
    try std.testing.expectEqual(@as(u16, 0), frame.overlays[1].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), frame.overlays[1].cursor.col);
}

test "glyph frame reports atlas evictions without hiding reuse stats" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // eviction은 나중에 texture 좌표 무효화와 redraw 원인을 추적할 때 필요하다.
    // frame이 이 값을 삼켜 버리면 screenshot만 보고 왜 upload가 늘었는지 알 수 없다.
    core.clearDirty();
    try core.write("ABC");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{},
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{ .max_slots = 2 });
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 1), frame.stats.evicted_count);
    try std.testing.expectEqual(@as(usize, 3), frame.uploads.len);
    // "ABC"는 셀 순서대로 모두 miss라 upload index도 0,1,2여야 한다. evict는 C(2)에서만.
    try std.testing.expectEqual(@as(usize, 0), frame.uploads[0].glyph_index);
    try std.testing.expectEqual(@as(usize, 2), frame.uploads[2].glyph_index);
    try std.testing.expect(frame.uploads[2].evicted != null);
}

test "glyph frame passes through fallback and replacement counts" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // fallback/replacement_count는 font resolve 단계의 관측값이다. GlyphFrame이 이를
    // GlyphRunList에서 그대로 전달하지 않으면, backend나 진단이 "왜 fallback/replacement가
    // 늘었나"를 추적할 때 frame 단계에서 정보가 끊긴다. 'A'(primary), U+E000(PUA →
    // replacement, fallback 포함), 'B'(primary)로 두 카운터를 0이 아니게 만들어 고정한다.
    core.clearDirty();
    try core.write("A\u{e000}B");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyph_runs = try glyph_layout.buildGlyphRunList(
        std.testing.allocator,
        list,
        .{},
        glyph_layout.FakeFontBackend{},
    );
    defer glyph_runs.deinit(std.testing.allocator);

    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    var frame = try prepareGlyphFrame(std.testing.allocator, glyph_runs, &atlas);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expect(glyph_runs.fallback_count > 0);
    try std.testing.expect(glyph_runs.replacement_count > 0);
    try std.testing.expectEqual(glyph_runs.fallback_count, frame.stats.fallback_count);
    try std.testing.expectEqual(glyph_runs.replacement_count, frame.stats.replacement_count);
}

test "glyph frame restarts once when the atlas exhausts mid-build, keeping one coordinate generation" {
    const allocator = std.testing.allocator;
    // 14px 글리프가 2×4=8개 들어가는 atlas. 이전 frame이 6칸을 채운 뒤, 8개짜리 새 frame이
    // 빌드 중간에 좌표를 소진하면 invalidate+재시작으로 8개 전부 한 세대가 돼야 한다.
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{ .atlas_width_px = 28, .atlas_height_px = 56 });
    defer atlas.deinit();

    var warm = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 1 });
    defer warm.deinit();
    warm.clearDirty();
    try warm.write("ijklmn"); // atlas를 6/8 채워두는 이전 frame
    var warm_list = try draw_list.buildDrawList(allocator, warm.snapshot());
    defer warm_list.deinit(allocator);
    var warm_runs = try glyph_layout.buildGlyphRunList(allocator, warm_list, .{ .font_size_px = 14, .device_scale = 1 }, glyph_layout.FakeFontBackend{});
    defer warm_runs.deinit(allocator);
    var warm_frame = try prepareGlyphFrame(allocator, warm_runs, &atlas);
    warm_frame.deinit(allocator);

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("abcdefgh"); // 고유 8개 — 잔여 2칸뿐이라 3번째에서 소진
    var list = try draw_list.buildDrawList(allocator, core.snapshot());
    defer list.deinit(allocator);
    var glyph_runs = try glyph_layout.buildGlyphRunList(allocator, list, .{ .font_size_px = 14, .device_scale = 1 }, glyph_layout.FakeFontBackend{});
    defer glyph_runs.deinit(allocator);

    var frame = try prepareGlyphFrame(allocator, glyph_runs, &atlas);
    defer frame.deinit(allocator);

    // 재시작 후 한 세대로 일관: 모든 슬롯이 같은 generation이고 텍스처 범위 안이어야 한다.
    // (재시작이 없으면 invalidate 이전 슬롯들이 옛 세대/충돌 좌표로 남는다.)
    try std.testing.expect(atlas.stats.invalidations > 0);
    const expect_generation = frame.glyphs[frame.glyphs.len - 1].slot.generation;
    for (frame.glyphs) |g| {
        try std.testing.expectEqual(expect_generation, g.slot.generation);
        try std.testing.expect(g.slot.x_px + g.slot.width_px <= 28);
        try std.testing.expect(g.slot.y_px + g.slot.height_px <= 56);
    }
    // 재빌드된 frame의 모든 슬롯은 이번 패스 업로드와 짝이 맞아야 한다(8개 전부 miss→업로드).
    try std.testing.expectEqual(frame.glyphs.len, frame.uploads.len);
}

test "glyph frame never maps two distinct glyphs to the same atlas coords (─→? 회귀)" {
    const allocator = std.testing.allocator;
    // 회귀 가드(원래 버그): 한 frame의 **고유 글리프 수가 atlas 물리 용량을 초과**하면, 옛 prepareGlyphFrame
    // 은 재시작이 1회뿐이라 2차 패스에서도 좌표가 소진됐다. 그때 invalidate가 좌표를 (0,0)으로 리셋한 채
    // **재시작 없이 진행**해, frame 안에서 두 좌표 세대가 섞이고 서로 다른 글리프가 같은 아틀라스 좌표를
    // 받았다. GPU 업로드는 나중 글리프가 앞 글리프의 텍셀을 덮어쓰므로, 앞 글리프(예: 보더라인 ─)가 나중
    // 글리프(예: ?)의 비트맵을 샘플해 화면에 ─ 대신 ?가 그려졌다(간헐적 TUI 깨짐).
    //
    // 수정(Ghostty식 grow on full): clean repack으로도 안 들어가면 atlas.grow()로 텍스처를 키워 모든
    // distinct 글리프가 고유 좌표를 받는다. 14px 글리프 → 28×56 atlas는 2열×4행 = 물리 용량 8개. 고유
    // 9개를 한 frame에 넣어 초과시키면, 이제 atlas가 28×112로 커져 9개가 충돌 없이 들어가야 한다.
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{ .atlas_width_px = 28, .atlas_height_px = 56 });
    defer atlas.deinit();
    const initial_height = atlas.config.atlas_height_px;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 9, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("abcdefghi"); // 고유 9개 > 물리 용량 8

    var list = try draw_list.buildDrawList(allocator, core.snapshot());
    defer list.deinit(allocator);
    var glyph_runs = try glyph_layout.buildGlyphRunList(allocator, list, .{ .font_size_px = 14, .device_scale = 1 }, glyph_layout.FakeFontBackend{});
    defer glyph_runs.deinit(allocator);

    var frame = try prepareGlyphFrame(allocator, glyph_runs, &atlas);
    defer frame.deinit(allocator);

    // grow가 실제로 일어났는지 — 텍스처가 커져야 9개가 들어간다(테스트가 우연히 통과하지 않게 고정).
    try std.testing.expect(atlas.config.atlas_height_px > initial_height);

    // 렌더링 계약: 한 frame 안에서 cache_key가 다른(=다른 비트맵) 두 글리프는 절대 같은 아틀라스
    // 좌표를 가리켜선 안 된다 — 가리키면 한쪽이 다른 쪽 텍셀을 샘플해 잘못된 글자가 그려진다.
    for (frame.glyphs, 0..) |a, i| {
        for (frame.glyphs[i + 1 ..]) |b| {
            const same_coords = a.slot.x_px == b.slot.x_px and a.slot.y_px == b.slot.y_px;
            const different_glyph = !std.meta.eql(a.slot.key, b.slot.key);
            if (same_coords and different_glyph) {
                std.debug.print(
                    "충돌: glyph[{d}](key.glyph_id={d}) 와 다른 글리프(key.glyph_id={d})가 같은 좌표 ({d},{d})\n",
                    .{ i, a.slot.key.glyph_id, b.slot.key.glyph_id, a.slot.x_px, a.slot.y_px },
                );
            }
            try std.testing.expect(!(same_coords and different_glyph));
        }
    }
}
