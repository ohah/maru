//! 스키마-주도 config 엔진 — `Config` sub-struct의 `pub const schema`(메타 1급 필드)에서 **파싱·직렬화**를
//! comptime으로 파생한다. 메타 타입(Meta/Widget/Section)은 `theme.zig`에 둔다(schema decl이 거기 있어 import
//! 사이클을 피한다 — theme는 schema를 import하지 않는다). 설계 단일 출처: docs/config-schema.md.
//!
//! CS-1(현재): 프레임워크 + 대표 4종(bool·범위 float·enum·색) 이주. 나머지 스칼라는 loader 옛 경로와 **공존**
//! 한다(loader가 tryParse를 먼저 보고 안 걸리면 기존 if-else로 폴백; serialize도 appendSerialized 먼저 + 미이주
//! 수동 emit). CS-2에서 스칼라 일괄 이주. 동적/특수 5종(preset·padding alias·palette.N·env.*·keybind)은 계속
//! 명시 핸들러(docs/config-schema.md §6).

const std = @import("std");
const theme = @import("theme.zig");
const appearance = @import("appearance.zig");

/// config 한 줄의 키·값 쌍(직렬화 토큰). loader.updateConfigText/serialize가 소비. loader.KeyValue가 이걸 재출력한다
/// (KeyValue를 여기 두는 이유: appendSerialized가 쓰는데 schema는 loader를 import하면 사이클이라 — loader→schema 단방향).
pub const KeyValue = struct { key: []const u8, value: []const u8 };

/// 비치명 진단(무시된 줄 번호 + 이유). loader가 `Diagnostic`으로 재출력한다(공유 타입 단일 출처 — loader→schema
/// 단방향이라 여기 둔다). message는 arena 또는 정적 리터럴 소유.
pub const Diag = struct { line: usize, message: []const u8 };

// ── 메타 1급 필드를 파싱 ──────────────────────────────────────────────────────────────────────────

/// 런타임 key가 스키마'd 필드에 매칭되면 파싱해 config에 적용하고 true. 매칭 안 되면 false(호출자가 옛 경로로 폴백).
/// 값이 잘못되면 forgiving — diagnostic 후 기본값 유지 + true(키는 스키마가 소유하므로 폴백하지 않는다).
/// comptime으로 Config의 sub-struct 중 `schema` decl을 가진 것을 자동 발견(@hasDecl)하고, 각 메타 항목의 키를
/// `namespace.segment`로 만들어 비교한다(namespace=Config 필드명, segment=key_seg ?? 필드명).
pub fn tryParse(
    a: std.mem.Allocator,
    config: *theme.Config,
    key: []const u8,
    value: []const u8,
    diags: *std.ArrayList(Diag),
    line_no: usize,
) !bool {
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                const meta: theme.Meta = @field(sch, sf.name);
                const full_key = comptime keyOf(cf.name, sf.name, meta);
                if (std.mem.eql(u8, key, full_key)) {
                    try parseAndSet(a, &@field(@field(config, cf.name), sf.name), full_key, meta, value, diags, line_no);
                    return true;
                }
            }
        }
    }
    return false;
}

/// 한 필드 포인터에 값을 파싱해 넣는다(실패면 diagnostic + 기본값 유지). 타입으로 comptime 분기:
/// bool / f32(범위 메타 필수) / enum / []const u8(widget=.color면 #RRGGBB 검증, 아니면 비-빈 dupe).
fn parseAndSet(
    a: std.mem.Allocator,
    ptr: anytype,
    comptime full_key: []const u8,
    comptime meta: theme.Meta,
    value: []const u8,
    diags: *std.ArrayList(Diag),
    line_no: usize,
) !void {
    const T = @TypeOf(ptr.*);
    if (T == bool) {
        ptr.* = parseBool(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = full_key ++ "는 true|false — 기본값 유지" });
            return;
        };
    } else if (T == f32) {
        const r = comptime (meta.range orelse @compileError(full_key ++ ": f32 필드엔 range 메타가 필수"));
        ptr.* = parseFloatRange(value, @floatCast(r[0]), @floatCast(r[1])) orelse {
            try diags.append(a, .{ .line = line_no, .message = std.fmt.comptimePrint("{s}는 {d}~{d} 범위 밖이거나 숫자가 아님 — 기본값 유지", .{ full_key, r[0], r[1] }) });
            return;
        };
    } else if (T == u32) {
        const r = comptime (meta.range orelse @compileError(full_key ++ ": u32 필드엔 range 메타가 필수"));
        ptr.* = parseUintRange(value, @intFromFloat(r[0]), @intFromFloat(r[1])) orelse {
            try diags.append(a, .{ .line = line_no, .message = std.fmt.comptimePrint("{s}는 {d}~{d} 정수여야 함 — 기본값 유지", .{ full_key, @as(u32, @intFromFloat(r[0])), @as(u32, @intFromFloat(r[1])) }) });
            return;
        };
    } else if (@typeInfo(T) == .@"enum") {
        const enum_msg = comptime full_key ++ "는 " ++ enumTokens(T) ++ " — 기본값 유지";
        ptr.* = parseEnum(T, value) orelse {
            try diags.append(a, .{ .line = line_no, .message = enum_msg });
            return;
        };
    } else if (T == []const u8) {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (meta.widget == .color) {
            _ = appearance.parseHexColor(trimmed) catch {
                try diags.append(a, .{ .line = line_no, .message = full_key ++ "는 #RRGGBB 형식이어야 함 — 기본값 유지" });
                return;
            };
            ptr.* = try a.dupe(u8, trimmed);
        } else {
            if (trimmed.len == 0) {
                try diags.append(a, .{ .line = line_no, .message = full_key ++ "가 비어 있음 — 기본값 유지" });
                return;
            }
            ptr.* = try a.dupe(u8, trimmed);
        }
    } else {
        @compileError("schema 미지원 타입: " ++ @typeName(T) ++ " (" ++ full_key ++ ")");
    }
}

// ── 메타 1급 필드를 직렬화 ────────────────────────────────────────────────────────────────────────

/// 스키마'd 필드 전부를 `key = value` 목록으로 emit한다(parse의 대칭). configKeyValues가 먼저 호출하고, 미이주
/// 필드는 그 뒤에 수동 emit한다(CS-1 공존). CS-2 후엔 이게 스칼라 전부를 담당한다.
pub fn appendSerialized(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(KeyValue)) !void {
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                const meta: theme.Meta = @field(sch, sf.name);
                const full_key = comptime keyOf(cf.name, sf.name, meta);
                const val = @field(@field(config, cf.name), sf.name);
                try list.append(arena, .{ .key = full_key, .value = try serializeValue(arena, val) });
            }
        }
    }
}

/// 필드 값을 정규 토큰으로(parse의 역). bool→true/false, f32→{d}(shortest), enum→tag('_'→'-'), 색/문자열→그대로.
fn serializeValue(arena: std.mem.Allocator, val: anytype) ![]const u8 {
    const T = @TypeOf(val);
    if (T == bool) {
        return if (val) "true" else "false";
    } else if (T == f32 or T == u32) {
        return try std.fmt.allocPrint(arena, "{d}", .{val});
    } else if (@typeInfo(T) == .@"enum") {
        // tag의 '_'를 '-'로(enum 토큰 규약 — commit_only→commit-only; 나머지는 '_' 없어 무변경).
        const tag = @tagName(val);
        const out = try arena.dupe(u8, tag);
        for (out) |*c| {
            if (c.* == '_') c.* = '-';
        }
        return out;
    } else if (T == []const u8) {
        return val;
    } else {
        @compileError("schema 미지원 직렬화 타입: " ++ @typeName(T));
    }
}

// ── 파싱 프리미티브(CS-1 한정 중복 — CS-2에서 loader와 단일화 예정) ─────────────────────────────────

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn parseFloatRange(value: []const u8, min: f32, max: f32) ?f32 {
    const n = std.fmt.parseFloat(f32, value) catch return null;
    return if (n >= min and n <= max) n else null; // NaN은 두 비교 모두 false → reject
}

fn parseUintRange(value: []const u8, min: u32, max: u32) ?u32 {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch return null;
    return if (n >= min and n <= max) n else null;
}

/// config 키 segment의 '_'를 '-'로(field명→키 토큰 규약). namespace·segment 둘 다 이걸 쓴다(maru 키는 일관되게
/// 하이픈). 예외(field명≠키 segment, 예: height_fraction→"height")만 Meta.key_seg로 명시 override. comptime-only.
fn dashed(comptime s: []const u8) []const u8 {
    var out: []const u8 = "";
    for (s) |c| out = out ++ &[_]u8{if (c == '_') '-' else c};
    return out;
}

/// 전체 키 = `<namespace>.<segment>`. namespace=Config 필드명(dashed), segment=key_seg ?? 필드명(dashed). comptime-only.
fn keyOf(comptime ns: []const u8, comptime field: []const u8, comptime meta: theme.Meta) []const u8 {
    return dashed(ns) ++ "." ++ (meta.key_seg orelse dashed(field));
}

/// enum 토큰 파싱: '-'를 '_'로 정규화 후 stringToEnum(commit-only→commit_only; 나머지는 무변경). 너무 길면 null.
fn parseEnum(comptime T: type, value: []const u8) ?T {
    var buf: [64]u8 = undefined;
    if (value.len > buf.len) return null;
    for (value, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return std.meta.stringToEnum(T, buf[0..value.len]);
}

/// enum 허용 토큰을 "a|b|c"로(diagnostic 메시지용). tag의 '_'는 '-'로 바꾼다. **호출처에서 `comptime`으로 강제**
/// (comptime-only — `@typeInfo` 필드 순회·문자열 concat은 comptime에서만).
fn enumTokens(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"enum".fields, 0..) |f, i| {
        var seg: []const u8 = "";
        for (f.name) |c| seg = seg ++ &[_]u8{if (c == '_') '-' else c};
        out = if (i == 0) seg else out ++ "|" ++ seg;
    }
    return out;
}

// ── 드리프트 차단(comptime): schema 항목은 반드시 실제 필드여야 한다 ─────────────────────────────────
// (CS-1은 한 방향만 — schema 항목→필드. "모든 필드→schema"의 역방향은 스칼라 전체 이주 CS-2에서 켠다.)
comptime {
    for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            for (@typeInfo(@TypeOf(Container.schema)).@"struct".fields) |sf| {
                if (!@hasField(Container, sf.name)) {
                    @compileError("schema 항목 '" ++ sf.name ++ "'는 " ++ @typeName(Container) ++ "의 필드가 아님");
                }
            }
        }
    }
}

test "schema tryParse: bool·enum·범위 float·색을 파싱하고 미스매치는 false" {
    const a = std.testing.allocator;
    var diags: std.ArrayList(Diag) = .empty;
    defer diags.deinit(a);
    var cfg: theme.Config = .{};

    // bool
    try std.testing.expect(try tryParse(a, &cfg, "cursor.blink", "false", &diags, 1));
    try std.testing.expectEqual(false, cfg.cursor.blink);
    // enum
    try std.testing.expect(try tryParse(a, &cfg, "cursor.shape", "underline", &diags, 2));
    try std.testing.expectEqual(theme.CursorShape.underline, cfg.cursor.shape);
    // 범위 float
    try std.testing.expect(try tryParse(a, &cfg, "font.size", "20", &diags, 3));
    try std.testing.expectEqual(@as(f32, 20), cfg.font.size);
    // 색(arena 없이 testing.allocator dupe → 끝에 free 필요. cfg.theme.background는 기본 리터럴이라 교체분만 free)
    try std.testing.expect(try tryParse(a, &cfg, "theme.background", "#abcdef", &diags, 4));
    try std.testing.expectEqualStrings("#abcdef", cfg.theme.background);
    a.free(cfg.theme.background); // 위 dupe 회수(테스트 한정)

    // 미스매치 키(스키마에 없는 키) → false(loader 옛 경로로 폴백). "no.such.key"는 영원히 비-스키마.
    try std.testing.expect(!try tryParse(a, &cfg, "no.such.key", "X", &diags, 5));
    try std.testing.expectEqual(@as(usize, 0), diags.items.len); // 위 전부 유효 → diagnostic 없음
}

test "schema tryParse: 잘못된 값은 diagnostic + 기본값 유지 + true(폴백 안 함)" {
    const a = std.testing.allocator;
    var diags: std.ArrayList(Diag) = .empty;
    defer diags.deinit(a);
    var cfg: theme.Config = .{};

    try std.testing.expect(try tryParse(a, &cfg, "cursor.shape", "diamond", &diags, 1)); // 허용 안 되는 enum
    try std.testing.expectEqual(theme.CursorShape.block, cfg.cursor.shape); // 기본 유지
    try std.testing.expect(try tryParse(a, &cfg, "font.size", "9999", &diags, 2)); // 범위 밖
    try std.testing.expectEqual(@as(f32, 14), cfg.font.size); // 기본 유지
    try std.testing.expect(try tryParse(a, &cfg, "theme.background", "red", &diags, 3)); // #RRGGBB 아님
    try std.testing.expectEqualStrings("#101010", cfg.theme.background); // 기본 유지
    try std.testing.expectEqual(@as(usize, 3), diags.items.len);
}

test "schema appendSerialized: 스키마'd 필드를 토큰으로(파싱 역대칭)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};
    cfg.cursor.blink = false;
    cfg.cursor.shape = .bar;
    cfg.font.size = 18;
    cfg.theme.background = "#001122";

    var list: std.ArrayList(KeyValue) = .empty;
    try appendSerialized(arena.allocator(), cfg, &list);

    // 4개 스키마'd 필드가 정확한 토큰으로 들어 있다(순서는 Config 필드 순회 순).
    try std.testing.expectEqualStrings("false", find(list.items, "cursor.blink").?);
    try std.testing.expectEqualStrings("bar", find(list.items, "cursor.shape").?);
    try std.testing.expectEqualStrings("18", find(list.items, "font.size").?);
    try std.testing.expectEqualStrings("#001122", find(list.items, "theme.background").?);
}

fn find(items: []const KeyValue, key: []const u8) ?[]const u8 {
    for (items) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
    return null;
}
