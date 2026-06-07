const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const terminal = maru.terminal;

pub const CoreTextGlyphRecord = struct {
    row: u16 = 0,
    col: u16,
    cell_width: u2 = 1,
    codepoint: u21,
    combining: ?u21 = null,
    glyph_id: renderer.GlyphId,
    font_name: []const u8,
    fallback: bool = false,
    replacement: bool = false,
    style: terminal.Style = .{},
    color_glyph_kind: renderer.ColorGlyphKind = .monochrome,
    // CoreText는 공백도 font run 안에 포함할 수 있다. 이 값을 필수로 두면 caller가
    // "실제로 bitmap을 만들 glyph인가"를 명시해야 해서, 공백을 실수로 rasterizer
    // 입력에 섞는 버그를 컴파일 단계에서 더 빨리 발견할 수 있다.
    drawable: bool,
};

pub fn shapedRecordFromCoreTextGlyph(
    record: CoreTextGlyphRecord,
    font_registry: *renderer.FontIdentityRegistry,
) !renderer.ShapedGlyphRecord {
    const font_id: renderer.FontId = if (needsFontIdentity(record))
        try font_registry.intern(.{ .postscript_name = record.font_name })
    else
        0;

    return .{
        .row = record.row,
        .col = record.col,
        .cell_width = record.cell_width,
        .codepoint = record.codepoint,
        .combining = record.combining,
        .font_id = font_id,
        .glyph_id = record.glyph_id,
        .fallback = record.fallback,
        .replacement = record.replacement,
        .style = record.style,
        .color_glyph_kind = record.color_glyph_kind,
        .drawable = record.drawable,
    };
}

fn needsFontIdentity(record: CoreTextGlyphRecord) bool {
    // CoreText glyph id는 font face 안에서만 의미가 있다. 그래서 실제 bitmap을 만들
    // drawable glyph만 registry에 넣는다. 공백, .notdef, width 0 record까지 intern하면
    // `font_identity_count`가 rasterizer 조회 대상보다 커져 디버깅 신호가 흐려진다.
    //
    // 이 intern 정책은 adapter 내부 규칙이라 비공개로 둔다. 외부 caller는 분기 없이
    // `shapedRecordFromCoreTextGlyph` 한 진입점만 쓰게 해, 같은 규칙이 여러 곳으로
    // 갈라지지 않게 한다.
    return record.drawable and record.glyph_id != 0 and record.cell_width != 0;
}

test "CoreText font bridge interns only drawable glyph faces" {
    // 이 테스트는 smoke record ABI가 아니라 제품 후보 경계 자체를 검증한다. 나중에
    // CoreText 제품 shaper가 들어와도 공백 record가 font identity count를 부풀리지
    // 않아야 wrong-glyph 원인을 좁힐 수 있다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const drawable = try shapedRecordFromCoreTextGlyph(.{
        .col = 0,
        .codepoint = 'A',
        .glyph_id = 42,
        .font_name = "Menlo-Regular",
        .drawable = true,
    }, &registry);
    const space = try shapedRecordFromCoreTextGlyph(.{
        .col = 1,
        .codepoint = ' ',
        .glyph_id = 5,
        .font_name = "SpaceOnlyFallback-Regular",
        .drawable = false,
    }, &registry);

    try std.testing.expect(drawable.drawable);
    try std.testing.expect(!space.drawable);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "CoreText font bridge rejects missing face names only when rasterizing would need them" {
    // non-drawable record는 rasterizer에 도달하지 않으므로 빈 이름을 허용한다. 반대로
    // drawable glyph는 PostScript name 없이 어떤 CTFont에 glyph id를 적용해야 하는지
    // 알 수 없어서 즉시 실패해야 한다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const space = try shapedRecordFromCoreTextGlyph(.{
        .col = 0,
        .codepoint = ' ',
        .glyph_id = 5,
        .font_name = "",
        .drawable = false,
    }, &registry);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);

    try std.testing.expectError(
        renderer.FontIdentityError.EmptyPostScriptName,
        shapedRecordFromCoreTextGlyph(.{
            .col = 1,
            .codepoint = 'A',
            .glyph_id = 42,
            .font_name = "",
            .drawable = true,
        }, &registry),
    );
}

test "CoreText font bridge preserves renderer-neutral glyph metadata" {
    // 제품 CoreText shaper가 만든 row/col/style/color metadata는 renderer domain으로
    // 그대로 넘어가야 한다. 이 값이 여기서 사라지면 이후 Metal backend가 CoreText
    // private 타입을 다시 해석해야 한다.
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const shaped = try shapedRecordFromCoreTextGlyph(.{
        .row = 2,
        .col = 3,
        .cell_width = 2,
        .codepoint = '한',
        .combining = 0x0301,
        .glyph_id = 84,
        .font_name = "AppleSDGothicNeo-Regular",
        .fallback = true,
        .style = .{ .bold = true, .underline = true },
        .color_glyph_kind = .color,
        .drawable = true,
    }, &registry);

    try std.testing.expectEqual(@as(u16, 2), shaped.row);
    try std.testing.expectEqual(@as(u16, 3), shaped.col);
    try std.testing.expectEqual(@as(u2, 2), shaped.cell_width);
    try std.testing.expectEqual(@as(?u21, 0x0301), shaped.combining);
    try std.testing.expect(shaped.fallback);
    try std.testing.expect(shaped.style.bold);
    try std.testing.expect(shaped.style.underline);
    try std.testing.expectEqual(renderer.ColorGlyphKind.color, shaped.color_glyph_kind);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}
