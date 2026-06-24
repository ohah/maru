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

fn baseStats(list: glyph_layout.GlyphRunList) GlyphFrameStats {
    return .{
        .glyph_count = list.glyphs.len,
        .fallback_count = list.fallback_count,
        .replacement_count = list.replacement_count,
    };
}

/// 한 페인의 누적 버퍼. 멀티 페인 통합 빌드가 재시작할 때 모든 페인 버퍼를 함께 비워, 어느 페인이
/// atlas를 소진하든 전 페인이 한 좌표 세대로 다시 배치되게 한다.
const PaneAccum = struct {
    prepared: std.ArrayList(PreparedGlyph) = .empty,
    uploads: std.ArrayList(GlyphUpload) = .empty,
    stats: GlyphFrameStats = .{},

    fn deinit(self: *PaneAccum, allocator: std.mem.Allocator) void {
        self.prepared.deinit(allocator);
        self.uploads.deinit(allocator);
    }
};

pub fn prepareGlyphFrame(
    allocator: std.mem.Allocator,
    glyphs: glyph_layout.GlyphRunList,
    atlas: *glyph_atlas.GlyphAtlas,
) !GlyphFrame {
    // 단일 페인은 멀티 페인 통합 빌드의 lists.len==1 특수화다. 이렇게 한 출처로 두면 단일 페인 재시작과
    // 멀티 페인 cross-pane 정합이 같은 코드를 쓴다(기존 단일 페인 동작은 lists.len==1에서 그대로다).
    const frames = try prepareMultiPaneGlyphFrame(allocator, &.{glyphs}, atlas);
    defer allocator.free(frames);
    return frames[0];
}

/// 여러 페인(GlyphRunList)을 **한 atlas 세대로** 함께 빌드한다. 멀티 페인이 한 atlas를 순차 공유할 때,
/// 어떤 페인이 atlas 좌표를 소진해 invalidate/grow를 일으키면 **모든 페인의 누적을 버리고 처음부터 다시
/// 빌드**한다 — 재시작 직후 atlas는 비어 있으므로 전 페인의 전 글리프가 miss가 되어(hit 0) 전부 uploads에
/// 실린다. 이것이 cross-pane 깨짐(앞 페인의 cache-hit 글리프가 무효화된 좌표/빈 텍스처를 샘플)의 근본
/// 차단이다: 각 페인이 독립적으로 "자기 miss만 업로드"하면 앞 페인이 빈 자리에 안 채워지지만, 통합 빌드는
/// 한 세대의 모든 글리프를 한 번에 (재)업로드한다.
///
/// 재시작 정책은 단일 페인과 같다 — 1회차(attempt==0)는 grow 없이 clean repack(누적 좌표만 비움), 그 다음
/// 또 소진되면 atlas.grow()로 텍스처를 키운다. 단일 페인과 다른 점은 **한 루프가 모든 페인의 합산 글리프를
/// 보므로**, 멀티 페인 합산이 한 텍스처를 넘으면(각 페인은 단독으로 들어가더라도) grow까지 가서 수렴한다.
/// 종료는 grow의 false(max 8192²)가 보장한다.
///
/// 성공하면 lists와 같은 길이의 GlyphFrame 슬라이스를 owned로 돌려준다(호출자가 각 frame.deinit + 슬라이스
/// free). 실패하면 내부에서 전부 정리하고 caller는 lists를 그대로 소유한다.
pub fn prepareMultiPaneGlyphFrame(
    allocator: std.mem.Allocator,
    lists: []const glyph_layout.GlyphRunList,
    atlas: *glyph_atlas.GlyphAtlas,
) ![]GlyphFrame {
    const accums = try allocator.alloc(PaneAccum, lists.len);
    var inited: usize = 0;
    errdefer {
        for (accums[0..inited]) |*a| a.deinit(allocator);
        allocator.free(accums);
    }
    for (accums, lists) |*a, list| {
        a.* = .{ .stats = baseStats(list) };
        try a.prepared.ensureTotalCapacity(allocator, list.glyphs.len);
        try a.uploads.ensureTotalCapacity(allocator, list.glyphs.len);
        inited += 1;
    }

    var attempt: u8 = 0;
    build: while (true) {
        for (lists, 0..) |list, li| {
            for (list.glyphs, 0..) |glyph, index| {
                const lookup = try atlas.ensureGlyph(glyph);
                // 1회차는 grow 없이 clean repack, 2회차+는 grow로 자리를 만든다. grow가 false면 더 못 키우니
                // 재시작을 멈추고 진행한다(degraded, 다음 frame에 회복). 어느 페인에서 일어나든 **모든** 페인을
                // 한 세대로 재시작해야 cross-pane 정합이 유지된다.
                //
                // 한계(degraded): grow가 max(8192²)에서 false면 재시작을 멈추고 진행한다. 이때 이미 append된 앞
                // 글리프는 old 세대 좌표, 이후는 invalidate 후 좌표라 두 세대가 섞여 cross-pane 충돌이 다시 가능하다.
                // 단 이는 **합산 distinct 글리프가 max(≈수만)을 넘는** 비현실적 극단에서만이다(터미널 한 화면은 수천
                // 셀 미만이라 멀티 페인 합산도 도달 불가). 기존 단일 페인 prepareGlyphFrame의 degraded 한계를 그대로
                // 상속한다 — 멀티 페인 합산이 reachability를 (비현실적으로) 높일 뿐이고, 실제 통합 후 합산 크기가
                // 현실 문제가 되면 별도로 다룬다.
                if (lookup.invalidated and (attempt == 0 or atlas.grow())) {
                    attempt += 1;
                    for (accums, lists) |*a, l| {
                        a.prepared.clearRetainingCapacity();
                        a.uploads.clearRetainingCapacity();
                        a.stats = baseStats(l);
                    }
                    // invalidate를 일으킨 글리프 슬롯이 atlas에 남아 있으면 재시작 패스에서 hit이 돼 uploads에서
                    // 빠진다 — 한 번 더 비워 재시작 패스가 전부 miss(=업로드)가 되게 한다.
                    _ = atlas.invalidate(.atlas_full);
                    continue :build;
                }
                accums[li].prepared.appendAssumeCapacity(.{ .run = glyph, .slot = lookup.slot });
                if (lookup.uploaded) {
                    accums[li].stats.upload_count += 1;
                    accums[li].stats.upload_bytes += lookup.upload_bytes;
                    if (lookup.evicted != null) accums[li].stats.evicted_count += 1;
                    accums[li].uploads.appendAssumeCapacity(.{
                        .glyph_index = index,
                        .slot = lookup.slot,
                        .upload_bytes = lookup.upload_bytes,
                        .evicted = lookup.evicted,
                    });
                } else {
                    accums[li].stats.reused_count += 1;
                }
            }
        }
        break;
    }

    const frames = try allocator.alloc(GlyphFrame, lists.len);
    var built: usize = 0;
    // 조립 실패 시: 완성된 frame은 frame.deinit으로, 아직 조립 안 된 accum은 위 accums errdefer가 정리한다
    // (toOwnedSlice로 비운 accum의 deinit은 빈 ArrayList라 무해 — double-free 없음).
    errdefer {
        for (frames[0..built]) |*f| f.deinit(allocator);
        allocator.free(frames);
    }
    for (frames, accums, lists) |*f, *a, list| {
        const overlay_copy = try allocator.dupe(draw_list.DrawOverlay, list.overlays);
        errdefer allocator.free(overlay_copy);
        const prepared_slice = try a.prepared.toOwnedSlice(allocator);
        errdefer allocator.free(prepared_slice);
        const upload_slice = try a.uploads.toOwnedSlice(allocator);
        f.* = .{
            .size = list.size,
            .cursor = list.cursor,
            .dirty = list.dirty,
            .glyphs = prepared_slice,
            .overlays = overlay_copy,
            .uploads = upload_slice,
            .stats = a.stats,
        };
        built += 1;
    }
    // 성공: accums 내용은 toOwnedSlice로 frames에 이동했으므로 구조체 배열만 free한다.
    allocator.free(accums);
    return frames;
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

/// 한 페인의 텍스트를 GlyphRunList로 만드는 테스트 헬퍼(core→DrawList→buildGlyphRunList). 14px/scale 1.
fn paneRuns(allocator: std.mem.Allocator, text: []const u8) !glyph_layout.GlyphRunList {
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = @intCast(text.len), .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write(text);
    var list = try draw_list.buildDrawList(allocator, core.snapshot());
    defer list.deinit(allocator);
    return glyph_layout.buildGlyphRunList(allocator, list, .{ .font_size_px = 14, .device_scale = 1 }, glyph_layout.FakeFontBackend{});
}

test "멀티 페인 통합 빌드: 한 페인 소진 시 전 페인 글리프가 한 세대로 재업로드된다 (cross-pane 근본 수정)" {
    const allocator = std.testing.allocator;
    // 28×56 = 14px 글리프 2열×4행 = 물리 용량 8칸. 두 페인 합산(12)이 이를 넘게 해, 한 atlas를 순차 공유하는
    // 멀티 페인에서 좌표 소진(grow/invalidate)을 유발한다. baseline(페인별 독립 prepareGlyphFrame)이라면
    // 페인1 글리프가 hit이라 uploads에서 빠져 빈 텍스처/무효 좌표에 안 채워지는 cross-pane 깨짐이 났다.
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{ .atlas_width_px = 28, .atlas_height_px = 56 });
    defer atlas.deinit();

    var p1 = try paneRuns(allocator, "abcd"); // 4개
    defer p1.deinit(allocator);
    var p2 = try paneRuns(allocator, "efghijkl"); // 8개 — 합산 12 > 8칸
    defer p2.deinit(allocator);

    const lists = [_]glyph_layout.GlyphRunList{ p1, p2 };
    const frames = try prepareMultiPaneGlyphFrame(allocator, &lists, &atlas);
    defer {
        for (frames) |*f| f.deinit(allocator);
        allocator.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 2), frames.len);

    // 불변 1(근본): 전 페인의 전 글리프가 uploads에 실린다(hit 0). 통합 재시작이 모든 글리프를 miss로 만들어
    // 빈 텍스처(grow 재할당)·무효 좌표에도 전부 (재)업로드된다 — 이게 cross-pane blank/깨짐의 차단.
    for (frames, lists) |f, list| {
        try std.testing.expectEqual(list.glyphs.len, f.glyphs.len);
        try std.testing.expectEqual(list.glyphs.len, f.uploads.len); // 전부 업로드(hit 없음)
    }

    // 불변 2: 모든 페인의 모든 슬롯이 같은 generation(한 좌표 세대) — 두 세대가 안 섞인다.
    // (빈 페인 가드: frames[0].glyphs[0]을 직접 인덱싱하지 않고 첫 글리프를 찾아 기준 gen으로 둔다 — 빈 페인이
    // 섞여도 OOB 없이 검증한다.)
    var gen: ?u32 = null;
    for (frames) |f| for (f.glyphs) |g| {
        if (gen == null) gen = g.slot.generation;
        try std.testing.expectEqual(gen.?, g.slot.generation);
    };

    // 불변 3: 페인 경계를 넘어 (같은 좌표 ∧ 다른 글리프)가 절대 없다 — cross-pane 텍셀 덮어쓰기 0.
    for (frames[0].glyphs) |a| {
        for (frames[1].glyphs) |b| {
            const same = a.slot.x_px == b.slot.x_px and a.slot.y_px == b.slot.y_px;
            const diff = !std.meta.eql(a.slot.key, b.slot.key);
            try std.testing.expect(!(same and diff));
        }
    }

    // 합산 12 > 8칸이라 clean-repack만으론 안 들어가 grow가 실제로 일어났다(텍스처가 커졌다).
    try std.testing.expect(atlas.config.atlas_height_px > 56);
}

test "prepareGlyphFrame은 prepareMultiPaneGlyphFrame의 lists.len==1 위임이다 (단일 페인 동작 보존)" {
    const allocator = std.testing.allocator;
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{});
    defer atlas.deinit();

    var runs = try paneRuns(allocator, "AAB"); // 'A' 반복(hit) + 'B'
    defer runs.deinit(allocator);

    var frame = try prepareGlyphFrame(allocator, runs, &atlas);
    defer frame.deinit(allocator);

    // 'A','A','B' → 'A' 두 번째는 hit(재사용), 'A'·'B'만 업로드. 단일 페인 dedup이 위임 후에도 그대로.
    try std.testing.expectEqual(@as(usize, 3), frame.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), frame.uploads.len);
    try std.testing.expectEqual(@as(usize, 1), frame.stats.reused_count);
    try std.testing.expectEqual(frame.glyphs[0].slot.id, frame.glyphs[1].slot.id); // 'A' 슬롯 재사용
}

test "멀티 페인 통합 빌드: 페인 간 공유 글리프도 한 세대로 정합 (cross-pane, hit 경로 포함)" {
    const allocator = std.testing.allocator;
    // distinct-only 테스트(위)가 못 보는 케이스: 두 페인이 글리프를 공유한다('a','b'). 공유 글리프는 한 슬롯을
    // 공유해야 하고(중복 업로드 없음), 소진으로 grow가 일어나도 모든 슬롯이 한 세대 + cross-pane 충돌 0이어야 한다.
    var atlas = glyph_atlas.GlyphAtlas.init(allocator, .{ .atlas_width_px = 28, .atlas_height_px = 56 });
    defer atlas.deinit();

    var p1 = try paneRuns(allocator, "abcdef"); // a b c d e f
    defer p1.deinit(allocator);
    var p2 = try paneRuns(allocator, "abghij"); // a b 공유 + g h i j → distinct 합산 10 > 8칸 → grow
    defer p2.deinit(allocator);

    const lists = [_]glyph_layout.GlyphRunList{ p1, p2 };
    const frames = try prepareMultiPaneGlyphFrame(allocator, &lists, &atlas);
    defer {
        for (frames) |*f| f.deinit(allocator);
        allocator.free(frames);
    }

    // 한 세대(빈 페인 가드 포함).
    var gen: ?u32 = null;
    for (frames) |f| for (f.glyphs) |g| {
        if (gen == null) gen = g.slot.generation;
        try std.testing.expectEqual(gen.?, g.slot.generation);
    };
    // cross-pane 충돌 0(같은 좌표 ∧ 다른 글리프 없음).
    for (frames[0].glyphs) |a| for (frames[1].glyphs) |b| {
        const same = a.slot.x_px == b.slot.x_px and a.slot.y_px == b.slot.y_px;
        const diff = !std.meta.eql(a.slot.key, b.slot.key);
        try std.testing.expect(!(same and diff));
    };
    // 공유 글리프 'a'(양 페인 첫 글자)는 같은 슬롯을 가리킨다 — 같은 atlas 세대라 한 슬롯 공유(중복 없음).
    try std.testing.expectEqual(frames[0].glyphs[0].slot.key.glyph_id, frames[1].glyphs[0].slot.key.glyph_id);
    try std.testing.expectEqual(frames[0].glyphs[0].slot.id, frames[1].glyphs[0].slot.id);
    try std.testing.expect(atlas.config.atlas_height_px > 56); // 합산 10 > 8칸이라 grow 발생
}
