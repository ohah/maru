const std = @import("std");
const glyph_layout = @import("glyph_layout.zig");

pub const FontIdentityError = error{
    EmptyPostScriptName,
    FontIdentityOverflow,
};

pub const FontIdentityKey = struct {
    postscript_name: []const u8,
    family_name: []const u8 = "",

    pub fn normalizedPostScriptName(self: FontIdentityKey) []const u8 {
        return trimIdentityText(self.postscript_name);
    }

    pub fn normalizedFamilyName(self: FontIdentityKey) []const u8 {
        return trimIdentityText(self.family_name);
    }
};

pub const FontIdentity = struct {
    id: glyph_layout.FontId,
    postscript_name: []const u8,
    family_name: []const u8,
};

const FontIdentityEntry = struct {
    identity: FontIdentity,
};

pub const FontIdentityRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(FontIdentityEntry) = .empty,
    next_id: glyph_layout.FontId = 1,

    pub fn init(allocator: std.mem.Allocator) FontIdentityRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FontIdentityRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.identity.postscript_name);
            self.allocator.free(entry.identity.family_name);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn intern(self: *FontIdentityRegistry, key: FontIdentityKey) !glyph_layout.FontId {
        const postscript_name = key.normalizedPostScriptName();
        if (postscript_name.len == 0) return FontIdentityError.EmptyPostScriptName;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.identity.postscript_name, postscript_name)) {
                return entry.identity.id;
            }
        }

        if (self.next_id == std.math.maxInt(glyph_layout.FontId)) {
            return FontIdentityError.FontIdentityOverflow;
        }

        // CoreText의 glyph id는 CTFont 안에서만 의미가 있다. 그래서 renderer는
        // native CTFont 포인터를 직접 들고 있지 않더라도, 같은 PostScript name이 같은
        // FontId로 재사용된다는 계약을 먼저 고정한다.
        const owned_postscript_name = try self.allocator.dupe(u8, postscript_name);
        errdefer self.allocator.free(owned_postscript_name);

        const family_name = key.normalizedFamilyName();
        const owned_family_name = try self.allocator.dupe(u8, family_name);
        errdefer self.allocator.free(owned_family_name);

        const id = self.next_id;

        try self.entries.append(self.allocator, .{
            .identity = .{
                .id = id,
                .postscript_name = owned_postscript_name,
                .family_name = owned_family_name,
            },
        });
        self.next_id += 1;

        return id;
    }

    pub fn get(self: *const FontIdentityRegistry, id: glyph_layout.FontId) ?FontIdentity {
        for (self.entries.items) |entry| {
            if (entry.identity.id == id) return entry.identity;
        }
        return null;
    }

    pub fn count(self: *const FontIdentityRegistry) usize {
        return self.entries.items.len;
    }
};

fn trimIdentityText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

test "font identity registry reuses the same PostScript name" {
    var registry = FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 이 테스트는 native shaper가 같은 CTFont를 두 번 만났을 때 glyph atlas key가
    // 매번 새 font id로 흔들리지 않는다는 계약을 증명한다.
    const first = try registry.intern(.{
        .postscript_name = "JetBrainsMono-Regular",
        .family_name = "JetBrains Mono",
    });
    const second = try registry.intern(.{
        .postscript_name = "JetBrainsMono-Regular",
        .family_name = "JetBrains Mono",
    });

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "font identity registry separates fallback faces" {
    var registry = FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 같은 codepoint라도 fallback face가 바뀌면 glyph id의 의미가 달라진다. 그래서
    // fallback 여부 자체보다 실제 face identity가 다른 font id를 만들어야 한다.
    const primary = try registry.intern(.{ .postscript_name = "JetBrainsMono-Regular" });
    const cjk_fallback = try registry.intern(.{ .postscript_name = "AppleSDGothicNeo-Regular" });
    const emoji_fallback = try registry.intern(.{ .postscript_name = "AppleColorEmoji" });

    try std.testing.expect(primary != cjk_fallback);
    try std.testing.expect(cjk_fallback != emoji_fallback);
    try std.testing.expectEqual(@as(usize, 3), registry.count());
    try std.testing.expectEqualStrings(
        "AppleSDGothicNeo-Regular",
        registry.get(cjk_fallback).?.postscript_name,
    );
}

test "font identity registry owns caller-provided names" {
    var registry = FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const mutable_name = try std.testing.allocator.dupe(u8, "MutableFont-Regular");
    defer std.testing.allocator.free(mutable_name);

    const id = try registry.intern(.{ .postscript_name = mutable_name });
    @memcpy(mutable_name, "ChangedFont-Regular");

    // CoreText smoke와 제품 backend는 native buffer 수명에 묶이면 안 된다. registry가
    // 이름을 복사해 소유해야 나중에 rasterizer가 같은 font id를 안정적으로 조회할 수 있다.
    try std.testing.expectEqualStrings("MutableFont-Regular", registry.get(id).?.postscript_name);
}

test "font identity registry rejects empty PostScript names" {
    var registry = FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // 빈 이름을 임시 font id로 받아들이면 glyph cache가 어떤 native face를 뜻하는지
    // 알 수 없는 상태가 된다. 이런 입력은 fallback이 아니라 명시적 오류여야 한다.
    try std.testing.expectError(
        FontIdentityError.EmptyPostScriptName,
        registry.intern(.{ .postscript_name = " \t\n" }),
    );
}

test "font identity keeps glyph cache keys font-relative" {
    var registry = FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const primary = try registry.intern(.{ .postscript_name = "JetBrainsMono-Regular" });
    const fallback = try registry.intern(.{ .postscript_name = "AppleSDGothicNeo-Regular" });

    const primary_key = glyph_layout.GlyphCacheKey{
        .font_id = primary,
        .glyph_id = 42,
        .font_size_px = 14,
        .device_scale = 2,
    };
    const fallback_key = glyph_layout.GlyphCacheKey{
        .font_id = fallback,
        .glyph_id = 42,
        .font_size_px = 14,
        .device_scale = 2,
    };

    // glyph_id 42는 두 font 안에서 서로 다른 모양일 수 있다. cache key가 font id를
    // 포함해야 fallback glyph가 primary glyph처럼 재사용되는 버그를 막는다.
    try std.testing.expect(!std.meta.eql(primary_key, fallback_key));
}
