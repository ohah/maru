const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const coretext_font = @import("coretext_font.zig");

pub const font_name_capacity = 128;
pub const glyph_record_capacity = 64;
pub const CoreTextGlyphRecord = coretext_font.CoreTextGlyphRecord;

pub const NativeCoreTextSmokeResult = extern struct {
    status: c_int,
    primary_font_found: u32,
    requested_font_matched: u32,
    line_created: u32,
    run_count: u32,
    glyph_count: u32,
    fallback_run_count: u32,
    ascii_glyph_present: u32,
    cjk_glyph_present: u32,
    emoji_glyph_present: u32,
    missing_glyph_count: u32,
    glyph_record_count: u32,
    glyph_record_overflow: u32,
    glyph_rasterized: u32,
    raster_width: u32,
    raster_height: u32,
    raster_non_clear_pixels: u32,
    raster_failures: u32,
    primary_font_name: [font_name_capacity]u8,
    first_fallback_font_name: [font_name_capacity]u8,
};

pub const NativeGlyphCategory = enum(u32) {
    ascii = 1,
    cjk = 2,
    emoji = 3,
    space = 4,
    other = 5,
};

pub const NativeGlyphRecord = extern struct {
    font_id: u32,
    glyph_id: u32,
    string_index: u32,
    category: u32,
    fallback: u32,
    font_name: [font_name_capacity]u8,
};

pub fn emptyNativeResult() NativeCoreTextSmokeResult {
    return .{
        .status = -1,
        .primary_font_found = 0,
        .requested_font_matched = 0,
        .line_created = 0,
        .run_count = 0,
        .glyph_count = 0,
        .fallback_run_count = 0,
        .ascii_glyph_present = 0,
        .cjk_glyph_present = 0,
        .emoji_glyph_present = 0,
        .missing_glyph_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 0,
        .glyph_rasterized = 0,
        .raster_width = 0,
        .raster_height = 0,
        .raster_non_clear_pixels = 0,
        .raster_failures = 0,
        .primary_font_name = [_]u8{0} ** font_name_capacity,
        .first_fallback_font_name = [_]u8{0} ** font_name_capacity,
    };
}

pub fn emptyGlyphRecord() NativeGlyphRecord {
    return .{
        .font_id = 0,
        .glyph_id = 0,
        .string_index = 0,
        .category = 0,
        .fallback = 0,
        .font_name = [_]u8{0} ** font_name_capacity,
    };
}

pub fn hasCompleteShapeFields(native: NativeCoreTextSmokeResult) bool {
    // status 7은 native 고정 record buffer가 넘친 경우다. 먼저 기록된 run만 보면 shape가
    // 성공한 것처럼 보일 수 있으므로, downstream Metal/CoreText probe는 이 상태를
    // incomplete shape로 닫아야 한다.
    return native.status != 7 and
        native.primary_font_found != 0 and
        native.line_created != 0 and
        native.run_count > 0 and
        native.glyph_count > 0 and
        native.ascii_glyph_present != 0 and
        native.cjk_glyph_present != 0 and
        native.emoji_glyph_present != 0 and
        native.missing_glyph_count == 0 and
        native.glyph_record_count > 0 and
        native.glyph_record_overflow == 0;
}

pub fn coreTextGlyphRecord(record: *const NativeGlyphRecord) CoreTextGlyphRecord {
    // NativeGlyphRecord는 C ABI buffer이고, font_name은 고정 배열이다. 반환하는
    // CoreTextGlyphRecord.font_name은 문자열을 소유하지 않는 slice라 caller가 가진 record
    // storage를 직접 가리켜야 한다. by-value 복사본을 가리키면 나중에 registry가 깨진
    // PostScript name을 intern해 CoreText rasterizer가 전부 실패한다.
    return .{
        .row = 0,
        .col = @intCast(@min(record.string_index, std.math.maxInt(u16))),
        .cell_width = cellWidthForCategory(record.category),
        .codepoint = codepointForRecord(record),
        .glyph_id = record.glyph_id,
        .font_name = cStringField(&record.font_name),
        .fallback = record.fallback != 0,
        .color_glyph_kind = colorGlyphKindForCategory(record.category),
        .drawable = record.glyph_id != 0 and record.category != @intFromEnum(NativeGlyphCategory.space),
    };
}

pub fn shapedRecordFromNativeGlyph(
    record: NativeGlyphRecord,
    font_registry: *renderer.FontIdentityRegistry,
) !renderer.ShapedGlyphRecord {
    // by-value record는 이 함수 동안만 살아 있다. 바로 CoreText adapter를 거쳐 registry에
    // intern하면 font name은 registry가 복사해 소유하므로 안전하다. 이 helper는 테스트와
    // probe code가 변환 파이프라인을 중첩 호출로 반복하지 않게 하는 얇은 진입점이다.
    return coretext_font.shapedRecordFromCoreTextGlyph(
        coreTextGlyphRecord(&record),
        font_registry,
    );
}

pub fn cellWidthForCategory(category: u32) u2 {
    if (category == @intFromEnum(NativeGlyphCategory.cjk) or
        category == @intFromEnum(NativeGlyphCategory.emoji))
    {
        return 2;
    }
    return 1;
}

pub fn colorGlyphKindForCategory(category: u32) renderer.ColorGlyphKind {
    if (category == @intFromEnum(NativeGlyphCategory.emoji)) return .color;
    return .monochrome;
}

pub fn codepointForRecord(record: *const NativeGlyphRecord) u21 {
    return switch (record.category) {
        @intFromEnum(NativeGlyphCategory.ascii) => switch (record.string_index) {
            0 => 'M',
            1 => 'a',
            2 => 'r',
            3 => 'u',
            else => '?',
        },
        @intFromEnum(NativeGlyphCategory.cjk) => '한',
        @intFromEnum(NativeGlyphCategory.emoji) => 0x1f34e,
        @intFromEnum(NativeGlyphCategory.space) => ' ',
        else => '?',
    };
}

pub fn cStringField(bytes: *const [font_name_capacity]u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..len];
}

pub const NativeGlyphRecordFixture = struct {
    native_font_id: u32 = 1,
    glyph_id: u32,
    string_index: u32,
    category: NativeGlyphCategory,
    fallback: bool = false,
    font_name: []const u8 = "Menlo-Regular",
};

pub fn nativeGlyphRecordForTest(args: NativeGlyphRecordFixture) NativeGlyphRecord {
    // 이 helper는 실제 CoreText runtime을 흉내 내려는 것이 아니라, native C ABI record가
    // 제품 후보 adapter를 거칠 때 어떤 값이 보존되는지 단위 테스트에서 명확히 만들기 위한
    // fixture builder다.
    var record = emptyGlyphRecord();
    record.font_id = args.native_font_id;
    record.glyph_id = args.glyph_id;
    record.string_index = args.string_index;
    record.category = @intFromEnum(args.category);
    record.fallback = if (args.fallback) 1 else 0;

    const len = @min(args.font_name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], args.font_name[0..len]);
    return record;
}

test "CoreText probe record keeps font names tied to caller storage" {
    // font_name slice가 caller-owned native buffer를 가리키는지 고정한다. 이 계약이 깨지면
    // shape는 성공해도 raster 단계에서 PostScript name이 손상되어 모든 glyph가 skip된다.
    const native = nativeGlyphRecordForTest(.{
        .glyph_id = 42,
        .string_index = 0,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    });
    const record = coreTextGlyphRecord(&native);

    try std.testing.expectEqualStrings("Menlo-Regular", record.font_name);
    try std.testing.expectEqual(@intFromPtr(&native.font_name[0]), @intFromPtr(record.font_name.ptr));
}

test "CoreText probe uses font identity registry instead of native record ids" {
    // C bridge의 font_id는 smoke 내부 진단용 임시 번호일 수 있다. renderer cache key는
    // 그 숫자를 그대로 믿지 않고, native font face name을 registry에 intern한 FontId를
    // 써야 한다. 그래야 같은 glyph id가 서로 다른 fallback face에서 충돌하지 않는다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const primary = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .native_font_id = 99,
        .glyph_id = 42,
        .string_index = 0,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    }), &font_registry);
    const cjk = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .native_font_id = 99,
        .glyph_id = 42,
        .string_index = 5,
        .category = .cjk,
        .fallback = true,
        .font_name = "AppleSDGothicNeo-Regular",
    }), &font_registry);
    const primary_again = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .native_font_id = 123,
        .glyph_id = 43,
        .string_index = 1,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    }), &font_registry);

    try std.testing.expectEqual(@as(usize, 2), font_registry.count());
    try std.testing.expect(primary.font_id != cjk.font_id);
    try std.testing.expectEqual(primary.font_id, primary_again.font_id);
}

test "CoreText probe keeps non drawable records out of font identities" {
    // 공백 record는 surface bounds에는 필요하지만 rasterizer 조회 대상은 아니다. 여기서
    // registry count를 부풀리면 summary가 실제 glyph bitmap 대상보다 큰 숫자를 보고한다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const primary = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .glyph_id = 42,
        .string_index = 0,
        .category = .ascii,
    }), &font_registry);
    const space = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .glyph_id = 5,
        .string_index = 4,
        .category = .space,
        .font_name = "SpaceOnlyFallback-Regular",
    }), &font_registry);

    try std.testing.expect(primary.drawable);
    try std.testing.expect(!space.drawable);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);
    try std.testing.expectEqual(@as(usize, 1), font_registry.count());
}

test "CoreText probe ignores empty font names on non drawable records" {
    // native bridge가 공백 record의 font name을 못 적어도 rasterizer에는 도달하지 않는다.
    // 이 경우 adapter가 EmptyPostScriptName으로 summary 생성을 중단하면 진짜 원인인
    // shape/raster 단계가 아니라 진단 경계에서 smoke가 죽는다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const space = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .glyph_id = 5,
        .string_index = 4,
        .category = .space,
        .font_name = "",
    }), &font_registry);

    try std.testing.expect(!space.drawable);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);
    try std.testing.expectEqual(@as(usize, 0), font_registry.count());
}

test "CoreText probe rejects empty font names on drawable records" {
    // drawable glyph의 glyph_id는 font-relative 값이다. PostScript name 없이 임시 FontId를
    // 만들면 rasterizer가 어느 CTFont에 그 glyph_id를 적용해야 하는지 알 수 없으므로,
    // 이 입력은 fallback이 아니라 명시적인 계약 위반이다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    try std.testing.expectError(
        renderer.FontIdentityError.EmptyPostScriptName,
        shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
            .glyph_id = 42,
            .string_index = 0,
            .category = .ascii,
            .font_name = "",
        }), &font_registry),
    );
}

test "CoreText probe shaped record font id resolves back to its PostScript name" {
    // 제품 smoke rasterizer는 GlyphRun.font_id로 registry를 조회해 PostScript name을
    // 얻은 뒤 그 이름으로 CTFont를 만들어 glyph를 그린다. 이 왕복 계약이 깨지면 glyph가
    // 엉뚱한 face로 그려지므로 native CoreText 없이도 lookup 경계를 고정한다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const record = try shapedRecordFromNativeGlyph(nativeGlyphRecordForTest(.{
        .glyph_id = 42,
        .string_index = 0,
        .category = .cjk,
        .fallback = true,
        .font_name = "AppleSDGothicNeo-Regular",
    }), &font_registry);

    const identity = font_registry.get(record.font_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("AppleSDGothicNeo-Regular", identity.postscript_name);
}
