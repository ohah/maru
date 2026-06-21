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
    // 최상위 스칼라(Config.schema — Config 직속 필드, namespace 없음, meta.key로 전체 키).
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            const meta: theme.Meta = @field(theme.Config.schema, sf.name);
            const full_key = comptime topKey(sf.name, meta);
            if (std.mem.eql(u8, key, full_key)) {
                try parseAndSet(a, &@field(config, sf.name), full_key, meta, value, diags, line_no);
                return true;
            }
        }
    }
    // sub-struct 스칼라(@hasDecl로 schema decl을 가진 sub-struct 자동 발견; namespace=Config 필드명).
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
    // 최상위 스칼라(Config.schema) 먼저.
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            const meta: theme.Meta = @field(theme.Config.schema, sf.name);
            const full_key = comptime topKey(sf.name, meta);
            try list.append(arena, .{ .key = full_key, .value = try serializeValue(arena, @field(config, sf.name)) });
        }
    }
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

// ── 위젯(세팅 GUI)용 스키마 순회 — bool 필드 열거 + 키로 설정 (CS-4-4) ──────────────────────────────
// 세팅 화면(config-gui.md §2)이 "메타가 곧 UI": platform이 스키마를 순회해 위젯 행을 만든다. parse/serialize와
// 같은 comptime 순회(topKey/keyOf 단일 출처)를 재사용해, 새 bool 키를 추가하면 GUI에도 자동으로 뜬다(코드 0줄).

/// 한 bool 스키마 필드의 GUI 행 기술자 — key(전체 키, 정적 리터럴)·doc(라벨, 정적)·현재 value. 문자열은 전부
/// comptime 리터럴(schema decl·키 유도)이라 별도 수명 관리가 필요 없다(프로그램 수명).
pub const BoolField = struct { key: []const u8, doc: []const u8, value: bool, section: ?theme.Section = null };

/// 스키마'd **bool 필드**를 전부 GUI 행으로 emit한다(appendSerialized의 bool 한정 변형 — 세팅 폼 행 빌드).
/// 순서는 parse/serialize와 같은 Config 필드 순회 순. list는 호출자(arena) 소유.
pub fn appendBoolFields(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(BoolField)) !void {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == bool) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                const full_key = comptime topKey(sf.name, meta);
                try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(config, sf.name), .section = meta.section });
            }
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == bool) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    const full_key = comptime keyOf(cf.name, sf.name, meta);
                    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(@field(config, cf.name), sf.name), .section = meta.section });
                }
            }
        }
    }
}

/// 키로 bool 스키마 필드를 설정한다(세팅 GUI 토글 → config flip). 매칭하는 bool 필드가 있으면 set하고 true,
/// 없으면(키 오타·非bool·非스키마) false. parse/serialize와 같은 키 순회라 키 규약이 단일 출처.
pub fn setBool(config: *theme.Config, key: []const u8, value: bool) bool {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == bool) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                const full_key = comptime topKey(sf.name, meta);
                if (std.mem.eql(u8, key, full_key)) {
                    @field(config, sf.name) = value;
                    return true;
                }
            }
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == bool) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    const full_key = comptime keyOf(cf.name, sf.name, meta);
                    if (std.mem.eql(u8, key, full_key)) {
                        @field(@field(config, cf.name), sf.name) = value;
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

/// 한 숫자(f32/u32 + range) 스키마 필드의 GUI 슬라이더 행 기술자. value/min/max는 f64로 통일(슬라이더 ratio
/// 계산 공용), is_int면 u32(정수 스텝·표시). key/doc는 comptime 리터럴.
pub const NumberField = struct { key: []const u8, doc: []const u8, value: f64, min: f64, max: f64, is_int: bool, section: ?theme.Section = null };

/// 스키마'd **숫자 필드(f32/u32, range 필수)**를 전부 슬라이더 행으로 emit한다(appendBoolFields의 숫자 짝). range
/// 메타가 슬라이더 min/max를 준다(파서 검증과 같은 출처). 순서는 parse/serialize와 같은 Config 필드 순회 순.
pub fn appendNumberFields(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(NumberField)) !void {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            try appendNumberField(arena, config, theme.Config, theme.Config.schema, sf, comptime topKey(sf.name, @field(theme.Config.schema, sf.name)), list);
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                try appendNumberFieldSub(arena, config, cf, Container, sch, sf, comptime keyOf(cf.name, sf.name, @field(sch, sf.name)), list);
            }
        }
    }
}

// 최상위(Config 직속) 숫자 필드 한 개를 append(있으면). comptime 분기를 함수로 빼 inline for 본문을 짧게 유지.
fn appendNumberField(arena: std.mem.Allocator, config: theme.Config, comptime C: type, comptime sch: anytype, comptime sf: anytype, comptime full_key: []const u8, list: *std.ArrayList(NumberField)) !void {
    _ = C;
    const FieldT = @TypeOf(@field(config, sf.name));
    if (FieldT != f32 and FieldT != u32) return;
    const meta: theme.Meta = @field(sch, sf.name);
    const r = comptime (meta.range orelse @compileError(full_key ++ ": 숫자 필드엔 range 필수"));
    const v: f64 = if (FieldT == u32) @floatFromInt(@field(config, sf.name)) else @field(config, sf.name);
    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = v, .min = r[0], .max = r[1], .is_int = FieldT == u32, .section = meta.section });
}

// sub-struct 숫자 필드 한 개를 append(있으면).
fn appendNumberFieldSub(arena: std.mem.Allocator, config: theme.Config, comptime cf: anytype, comptime C: type, comptime sch: anytype, comptime sf: anytype, comptime full_key: []const u8, list: *std.ArrayList(NumberField)) !void {
    _ = C;
    const FieldT = @TypeOf(@field(@field(config, cf.name), sf.name));
    if (FieldT != f32 and FieldT != u32) return;
    const meta: theme.Meta = @field(sch, sf.name);
    const r = comptime (meta.range orelse @compileError(full_key ++ ": 숫자 필드엔 range 필수"));
    const v: f64 = if (FieldT == u32) @floatFromInt(@field(@field(config, cf.name), sf.name)) else @field(@field(config, cf.name), sf.name);
    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = v, .min = r[0], .max = r[1], .is_int = FieldT == u32, .section = meta.section });
}

/// 키로 숫자(f32/u32) 스키마 필드를 설정한다(세팅 슬라이더 → config). value는 range로 클램프, u32면 반올림 정수화.
/// 매칭하는 숫자 필드가 있으면 set하고 true. parse/serialize와 같은 키 순회(단일 출처).
pub fn setNumber(config: *theme.Config, key: []const u8, value: f64) bool {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (setNumberField(&@field(config, sf.name), @field(theme.Config.schema, sf.name), comptime topKey(sf.name, @field(theme.Config.schema, sf.name)), key, value)) return true;
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (setNumberField(&@field(@field(config, cf.name), sf.name), @field(sch, sf.name), comptime keyOf(cf.name, sf.name, @field(sch, sf.name)), key, value)) return true;
            }
        }
    }
    return false;
}

// 한 필드 포인터가 숫자(f32/u32)이고 키가 맞으면 클램프해 설정하고 true. 그 외 false.
fn setNumberField(ptr: anytype, comptime meta: theme.Meta, comptime full_key: []const u8, key: []const u8, value: f64) bool {
    const T = @TypeOf(ptr.*);
    if (T != f32 and T != u32) return false;
    if (!std.mem.eql(u8, key, full_key)) return false;
    const r = comptime (meta.range orelse @compileError(full_key ++ ": 숫자 필드엔 range 필수"));
    const clamped = std.math.clamp(value, r[0], r[1]);
    ptr.* = if (T == u32) @intFromFloat(@round(clamped)) else @floatCast(clamped);
    return true;
}

/// 한 enum 스키마 필드의 GUI dropdown 행 기술자. current는 현재 변형의 표시 토큰(dashed — config 파일 규약).
/// CS-4-1c는 사이클러(현재값 표시 + 클릭/←→로 변형 순환)라 옵션 목록은 안 싣는다(팝업 목록은 후속).
pub const EnumField = struct { key: []const u8, doc: []const u8, current: []const u8, section: ?theme.Section = null };

/// 스키마'd **enum 필드**를 전부 dropdown 행으로 emit한다(appendBoolFields의 enum 짝). current=현재 변형 dashed 토큰.
pub fn appendEnumFields(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(EnumField)) !void {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            try appendEnumField(arena, @field(config, sf.name), @field(theme.Config.schema, sf.name), comptime topKey(sf.name, @field(theme.Config.schema, sf.name)), list);
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                try appendEnumField(arena, @field(@field(config, cf.name), sf.name), @field(sch, sf.name), comptime keyOf(cf.name, sf.name, @field(sch, sf.name)), list);
            }
        }
    }
}

fn appendEnumField(arena: std.mem.Allocator, value: anytype, comptime meta: theme.Meta, comptime full_key: []const u8, list: *std.ArrayList(EnumField)) !void {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"enum") return;
    // current는 정적 @tagName(소유/해제 불요 — 핸들러가 self.allocator로 호출해도 누수 없음). 표시 토큰의 '_'→'-'
    // 변환(config 규약)은 표시 시점(dropdown.view, frame arena)에 한다 — 여기서 dupe하면 핸들러 경로가 누수된다.
    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .current = @tagName(value), .section = meta.section });
}

/// 키로 enum 스키마 필드를 한 변형 순환한다(dropdown 사이클러 — dir=+1 다음/-1 이전, wrap). 매칭하는 enum 필드가
/// 있으면 변형을 바꾸고 true. 변형 순서는 선언 순(ordinal). default 값 enum(0..n-1)을 가정한다(config enum 전부 해당).
pub fn cycleEnum(config: *theme.Config, key: []const u8, dir: i8) bool {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (cycleEnumField(&@field(config, sf.name), comptime topKey(sf.name, @field(theme.Config.schema, sf.name)), key, dir)) return true;
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (cycleEnumField(&@field(@field(config, cf.name), sf.name), comptime keyOf(cf.name, sf.name, @field(sch, sf.name)), key, dir)) return true;
            }
        }
    }
    return false;
}

fn cycleEnumField(ptr: anytype, comptime full_key: []const u8, key: []const u8, dir: i8) bool {
    const T = @TypeOf(ptr.*);
    if (@typeInfo(T) != .@"enum") return false;
    if (!std.mem.eql(u8, key, full_key)) return false;
    const n: i64 = @typeInfo(T).@"enum".fields.len;
    const cur: i64 = @intFromEnum(ptr.*);
    const next: i64 = @mod(cur + dir + n, n);
    ptr.* = @enumFromInt(next);
    return true;
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

/// sub-struct 필드의 전체 키 = `<namespace>.<segment>`(meta.key가 있으면 그걸 통째로). namespace=Config 필드명(dashed),
/// segment=key_seg ?? 필드명(dashed). comptime-only.
fn keyOf(comptime ns: []const u8, comptime field: []const u8, comptime meta: theme.Meta) []const u8 {
    const k = meta.key orelse (dashed(ns) ++ "." ++ (meta.key_seg orelse dashed(field)));
    if (k.len == 0) @compileError("스키마 키가 비어 있음: " ++ ns ++ "." ++ field ++ " (Meta.key=\"\" 오타?)"); // 빈 키는 어떤 config 키와도 매칭 안 돼 필드가 조용히 무시됨 — comptime 차단(code-review 후속)
    return k;
}

/// 최상위 스칼라(Config.schema) 필드의 전체 키 — namespace가 없어 meta.key 필수. comptime-only.
fn topKey(comptime field: []const u8, comptime meta: theme.Meta) []const u8 {
    const k = meta.key orelse @compileError("Config.schema 항목 '" ++ field ++ "'는 Meta.key 필수(최상위 필드는 namespace 없음)");
    if (k.len == 0) @compileError("Config.schema 항목 '" ++ field ++ "'의 Meta.key가 비어 있음 (오타?)");
    return k;
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
    // 최상위(Config.schema) 항목 → Config 필드.
    if (@hasDecl(theme.Config, "schema")) {
        for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (!@hasField(theme.Config, sf.name)) {
                @compileError("Config.schema 항목 '" ++ sf.name ++ "'는 Config의 필드가 아님");
            }
        }
    }
    // sub-struct schema 항목 → 그 struct 필드.
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

test "schema tryParse: 최상위 스칼라(Config.schema) — Meta.key 전체 키로 매칭(bool·u32·enum·text)" {
    const a = std.testing.allocator;
    var diags: std.ArrayList(Diag) = .empty;
    defer diags.deinit(a);
    var cfg: theme.Config = .{};

    try std.testing.expect(try tryParse(a, &cfg, "text.blink", "true", &diags, 1)); // bool, key=text.blink
    try std.testing.expectEqual(true, cfg.blink_text);
    try std.testing.expect(try tryParse(a, &cfg, "window.padding-top", "12", &diags, 2)); // u32 range
    try std.testing.expectEqual(@as(u32, 12), cfg.window_padding_top);
    try std.testing.expect(try tryParse(a, &cfg, "text.ambiguous-width", "wide", &diags, 3)); // enum
    try std.testing.expectEqual(theme.AmbiguousWidth.wide, cfg.ambiguous_width);
    try std.testing.expect(try tryParse(a, &cfg, "term", "xterm-256color", &diags, 4)); // text
    try std.testing.expectEqualStrings("xterm-256color", cfg.term);
    a.free(cfg.term); // 위 dupe 회수(테스트 한정)
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    // 범위 밖 padding → diagnostic + 기본 유지
    try std.testing.expect(try tryParse(a, &cfg, "window.padding-right", "999", &diags, 5));
    try std.testing.expectEqual(@as(u32, 8), cfg.window_padding_right); // 기본 유지
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
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

test "schema appendBoolFields/setBool: bool 필드만 열거하고 키로 설정(세팅 GUI)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};
    cfg.cursor.blink = true;

    var list: std.ArrayList(BoolField) = .empty;
    try appendBoolFields(arena.allocator(), cfg, &list);
    // cursor.blink(sub-struct bool)와 text.blink(최상위 bool)가 포함된다(둘 다 스키마'd bool).
    var saw_cursor_blink = false;
    var saw_text_blink = false;
    for (list.items) |f| {
        if (std.mem.eql(u8, f.key, "cursor.blink")) {
            saw_cursor_blink = true;
            try std.testing.expectEqual(true, f.value); // 위에서 true로 설정
            try std.testing.expect(f.doc.len > 0); // 라벨(doc) 있음
        }
        if (std.mem.eql(u8, f.key, "text.blink")) saw_text_blink = true;
    }
    try std.testing.expect(saw_cursor_blink and saw_text_blink);

    // setBool: 키로 flip.
    try std.testing.expect(setBool(&cfg, "cursor.blink", false));
    try std.testing.expectEqual(false, cfg.cursor.blink);
    try std.testing.expect(setBool(&cfg, "text.blink", true));
    try std.testing.expectEqual(true, cfg.blink_text);
    // 非bool 키(font.size=f32)·非스키마 키 → false(설정 안 함).
    try std.testing.expect(!setBool(&cfg, "font.size", true));
    try std.testing.expect(!setBool(&cfg, "no.such.key", true));
}

test "schema appendNumberFields/setNumber: f32/u32+range 열거·클램프 설정(세팅 슬라이더)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};

    var list: std.ArrayList(NumberField) = .empty;
    try appendNumberFields(arena.allocator(), cfg, &list);
    var saw_font_size = false; // f32 + range
    var saw_pad_top = false; // u32 + range(최상위 window.padding-top)
    for (list.items) |f| {
        if (std.mem.eql(u8, f.key, "font.size")) {
            saw_font_size = true;
            try std.testing.expect(!f.is_int);
            try std.testing.expectEqual(@as(f64, 14), f.value); // 기본 font.size
            try std.testing.expect(f.min < f.max);
        }
        if (std.mem.eql(u8, f.key, "window.padding-top")) {
            saw_pad_top = true;
            try std.testing.expect(f.is_int);
        }
    }
    try std.testing.expect(saw_font_size and saw_pad_top);

    // setNumber: f32 클램프 + u32 반올림 정수화.
    try std.testing.expect(setNumber(&cfg, "font.size", 22.5));
    try std.testing.expectEqual(@as(f32, 22.5), cfg.font.size);
    try std.testing.expect(setNumber(&cfg, "font.size", 99999)); // range 밖 → max 클램프
    try std.testing.expect(cfg.font.size < 99999);
    try std.testing.expect(setNumber(&cfg, "window.padding-top", 7.6)); // u32 → 반올림 8
    try std.testing.expectEqual(@as(u32, 8), cfg.window_padding_top);
    // bool 키·非스키마 → false.
    try std.testing.expect(!setNumber(&cfg, "cursor.blink", 1));
    try std.testing.expect(!setNumber(&cfg, "no.such.key", 1));
}

test "schema appendEnumFields/cycleEnum: enum 열거·순환(dropdown 사이클러)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};

    var list: std.ArrayList(EnumField) = .empty;
    try appendEnumFields(arena.allocator(), cfg, &list);
    var saw_shape = false;
    for (list.items) |f| {
        if (std.mem.eql(u8, f.key, "cursor.shape")) {
            saw_shape = true;
            try std.testing.expectEqualStrings("block", f.current); // 기본 cursor.shape=block
            try std.testing.expect(f.doc.len > 0);
        }
    }
    try std.testing.expect(saw_shape);

    // cycleEnum: block → 다음(bar) → 다음(underline). dashed 토큰 비교는 appendEnumFields로 재확인.
    try std.testing.expect(cycleEnum(&cfg, "cursor.shape", 1));
    try std.testing.expect(cfg.cursor.shape != .block);
    // 이전(-1)으로 되돌리면 block.
    try std.testing.expect(cycleEnum(&cfg, "cursor.shape", -1));
    try std.testing.expectEqual(theme.CursorShape.block, cfg.cursor.shape);
    // wrap: -1이면 마지막 변형.
    try std.testing.expect(cycleEnum(&cfg, "cursor.shape", -1));
    try std.testing.expect(cfg.cursor.shape != .block);
    // bool·非스키마 키 → false.
    try std.testing.expect(!cycleEnum(&cfg, "cursor.blink", 1));
    try std.testing.expect(!cycleEnum(&cfg, "no.such.key", 1));
}

// ── doc-drift 가드(CS-3): 모든 스키마 키가 configuration.md 키 표에 문서화돼 있어야 한다 ──────────────
// configuration.md를 @embedFile로 컴파일 타임에 박아, 스키마 키를 추가하고 문서 표 행을 깜빡하면 이 테스트가
// 깨진다(키·동작·기본값이 사용자와의 공개 계약이라 문서 누락을 CI가 잡는다). 전체 표 *생성*(마커 블록)은 풍부한
// 주석(비고 열)을 meta.doc로 옮겨야 해 별도(CS-3b) — 여기선 풍부한 손-주석 표를 유지하며 누락만 막는다.
fn docHasKeyRow(comptime full_key: []const u8) bool {
    const doc = @embedFile("config_doc_md"); // build.zig 익명 import(docs/configuration.md — src/ 밖이라 import로 등록)
    // 표 셀 경계(`| `key` |`)로 앵커한다 — 산문에 우연히 `| `key`` 패턴이 있어도 *행 누락*을 가리지 않게(code-review 후속).
    return std.mem.indexOf(u8, doc, "| `" ++ full_key ++ "` |") != null;
}

test "doc 정합성: 모든 스키마 키가 configuration.md 표에 문서화됨 (drift guard)" {
    var missing: usize = 0;
    // 최상위(Config.schema)
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            const full_key = comptime topKey(sf.name, @field(theme.Config.schema, sf.name));
            if (!docHasKeyRow(full_key)) {
                std.debug.print("미문서 스키마 키: '{s}' (configuration.md 표에 '| `{s}` | …' 행 추가 필요)\n", .{ full_key, full_key });
                missing += 1;
            }
        }
    }
    // sub-struct
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            inline for (@typeInfo(@TypeOf(Container.schema)).@"struct".fields) |sf| {
                const full_key = comptime keyOf(cf.name, sf.name, @field(Container.schema, sf.name));
                if (!docHasKeyRow(full_key)) {
                    std.debug.print("미문서 스키마 키: '{s}'\n", .{full_key});
                    missing += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}
