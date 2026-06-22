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

/// 한 문자열(widget .text 또는 .color, 타입 []const u8) 스키마 필드의 GUI 인라인 편집 행 기술자. text=폰트 패밀리,
/// color=#RRGGBB(1차는 hex 텍스트 편집). value=현재값(빌림 — config arena 소유). key/doc는 comptime 리터럴.
pub const TextField = struct { key: []const u8, doc: []const u8, value: []const u8, section: ?theme.Section = null };

/// 스키마'd **텍스트 필드(widget .text, 타입 []const u8)**를 전부 인라인 편집 행으로 emit한다(appendBoolFields의
/// 문자열 짝). 색(widget .color)은 appendColorFields(스와치 + 프리셋)로 따로 — text 위젯은 폰트 패밀리 등.
/// 옵셔널(?[]const u8 — sidebar 파생색)은 제외. 순서는 Config 필드 순회 순.
pub fn appendTextFields(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(TextField)) !void {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == []const u8) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                if (meta.widget == .text) {
                    const full_key = comptime topKey(sf.name, meta);
                    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(config, sf.name), .section = meta.section });
                }
            }
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == []const u8) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    if (meta.widget == .text) {
                        const full_key = comptime keyOf(cf.name, sf.name, meta);
                        try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(@field(config, cf.name), sf.name), .section = meta.section });
                    }
                }
            }
        }
    }
}

/// 한 색 필드(widget .color, 타입 []const u8 = #RRGGBB)의 GUI 스와치 행 기술자. value=현재 hex(빌림 — config arena
/// 소유). platform이 parseHexColor로 스와치 RGB를 만들고, 클릭/←→로 16색 프리셋 순환(cycleColor)·hex 클릭으로 편집.
pub const ColorField = struct { key: []const u8, doc: []const u8, value: []const u8, section: ?theme.Section = null };

/// 16색 프리셋(스와치 picker 1차 — config-gui §6.2). 중립(흑/백/회) + dracula 계열 accent + maru 앰버. cycleColor가
/// 현재값을 이 목록에서 찾아 다음/이전으로 돌린다(현재값이 프리셋 아니면 0번부터). 정적 리터럴이라 set에 dupe 불요.
pub const color_presets = [_][]const u8{
    "#000000", "#ffffff", "#101010", "#e8e8e8",
    "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9",
    "#8be9fd", "#ff79c6", "#ffb86c", "#6272a4",
    "#282a36", "#44475a", "#dda15e", "#334455",
};

/// 스키마'd **색 필드(widget .color)**를 전부 스와치 행으로 emit한다(appendTextFields의 색 짝). value=현재 hex.
pub fn appendColorFields(arena: std.mem.Allocator, config: theme.Config, list: *std.ArrayList(ColorField)) !void {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == []const u8) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                if (meta.widget == .color) {
                    const full_key = comptime topKey(sf.name, meta);
                    try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(config, sf.name), .section = meta.section });
                }
            }
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == []const u8) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    if (meta.widget == .color) {
                        const full_key = comptime keyOf(cf.name, sf.name, meta);
                        try list.append(arena, .{ .key = full_key, .doc = meta.doc, .value = @field(@field(config, cf.name), sf.name), .section = meta.section });
                    }
                }
            }
        }
    }
}

/// 키로 색 필드(widget .color)를 16색 프리셋에서 한 칸 순환한다(dir=+1 다음/-1 이전, wrap). 현재값이 프리셋이면 그
/// 다음, 아니면 0번부터. 프리셋은 정적 리터럴이라 dupe 없이 대입(라이브/직렬화가 계속 읽어도 안전). 매칭 시 true.
pub fn cycleColor(config: *theme.Config, key: []const u8, dir: i8) bool {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == []const u8) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                if (meta.widget == .color and std.mem.eql(u8, key, comptime topKey(sf.name, meta))) {
                    @field(config, sf.name) = nextPreset(@field(config, sf.name), dir);
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
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == []const u8) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    if (meta.widget == .color and std.mem.eql(u8, key, comptime keyOf(cf.name, sf.name, meta))) {
                        @field(@field(config, cf.name), sf.name) = nextPreset(@field(@field(config, cf.name), sf.name), dir);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

/// 현재 hex의 프리셋 다음/이전(현재값이 프리셋 목록에 있으면 그 이웃, 없으면 dir>=0이면 0번·아니면 마지막). 정적 리터럴.
fn nextPreset(current: []const u8, dir: i8) []const u8 {
    const n = color_presets.len;
    var idx: ?usize = null;
    for (color_presets, 0..) |p, i| {
        if (std.ascii.eqlIgnoreCase(p, current)) idx = i;
    }
    const cur: i64 = if (idx) |i| @intCast(i) else (if (dir >= 0) -1 else 0);
    const next: usize = @intCast(@mod(cur + dir + @as(i64, n), @as(i64, n)));
    return color_presets[next];
}

/// ANSI 16색 팔레트(`theme.palette.0`~`.15`)의 **정적 리터럴 키** 16개. 인덱스가 동적이라 markConfigKeyDirty가 키를
/// dupe 없이 보관하려면 안정된 포인터가 필요하다(스키마 스칼라 키처럼 정적). comptime에 펼쳐 바이너리 상수로 둔다.
/// 단일 출처: loader의 `theme.palette.N` 핸들러·serialize의 palette emit과 같은 키 표기(`theme.palette.{d}`).
pub const palette_keys: [16][]const u8 = blk: {
    var keys: [16][]const u8 = undefined;
    for (&keys, 0..) |*k, i| k.* = std.fmt.comptimePrint("theme.palette.{d}", .{i});
    break :blk keys;
};

/// 인덱스(0~15)의 팔레트 키(정적 리터럴). 범위 밖은 빈 슬라이스(호출처가 가드).
pub fn paletteKey(idx: usize) []const u8 {
    if (idx >= palette_keys.len) return &.{};
    return palette_keys[idx];
}

/// ANSI 팔레트 한 칸(`theme.palette.idx`)을 hex로 설정한다(팔레트 그리드 인라인 편집 → config). value는 **호출자가
/// config arena에 미리 소유**시킨 슬라이스여야 한다(라이브 재적용/직렬화가 계속 읽음). 파일 로드(loader)와 같은 규칙
/// (#RRGGBB 검증 — validatedText(.color))으로 검증해 GUI·파일 드리프트를 막는다. 통과면 set하고 true, 실패/범위 밖은
/// false(그 칸은 기존값 유지). null로 되돌리는 건 통합 리셋(파일 삭제)이 담당 — 여기선 override만 쓴다.
pub fn setPaletteColor(config: *theme.Config, idx: usize, value: []const u8) bool {
    if (idx >= config.theme.palette.len) return false;
    const v = validatedText(.color, value) orelse return false;
    config.theme.palette[idx] = v;
    return true;
}

/// 키로 문자열([]const u8, widget .text/.color) 스키마 필드를 설정한다(세팅 인라인 편집 → config). value는 **호출자가
/// config arena에 미리 소유**시킨 슬라이스여야 한다(setText는 슬라이스만 대입 — 라이브 재적용/직렬화가 계속 읽음).
/// 매칭하는 문자열 필드가 있으면 set하고 true. parse/serialize와 같은 키 순회(단일 출처).
/// 문자열 필드 값을 **파일 로드(parseAndSet)와 같은 규칙**으로 검증한다 — GUI·파일 드리프트 방지(docs/config-gui.md
/// §1). color=#RRGGBB(appearance.parseHexColor), text=trim 후 비어있지 않음. 통과면 trim된 슬라이스(입력의 부분
/// 슬라이스 — 호출자 소유 유지), 실패면 null. setText 단일 출처.
fn validatedText(widget: theme.Widget, value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (widget == .color) {
        _ = appearance.parseHexColor(trimmed) catch return null;
        return trimmed;
    }
    if (trimmed.len == 0) return null; // text: 빈 값 거부(기본값 유지)
    return trimmed;
}

pub fn setText(config: *theme.Config, key: []const u8, value: []const u8) bool {
    if (@hasDecl(theme.Config, "schema")) {
        inline for (@typeInfo(@TypeOf(theme.Config.schema)).@"struct".fields) |sf| {
            if (@TypeOf(@field(config, sf.name)) == []const u8) {
                const meta: theme.Meta = @field(theme.Config.schema, sf.name);
                if (meta.widget == .text or meta.widget == .color) {
                    if (std.mem.eql(u8, key, comptime topKey(sf.name, meta))) {
                        const v = validatedText(meta.widget, value) orelse return false;
                        @field(config, sf.name) = v;
                        return true;
                    }
                }
            }
        }
    }
    inline for (@typeInfo(theme.Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                if (@TypeOf(@field(@field(config, cf.name), sf.name)) == []const u8) {
                    const meta: theme.Meta = @field(sch, sf.name);
                    if (meta.widget == .text or meta.widget == .color) {
                        if (std.mem.eql(u8, key, comptime keyOf(cf.name, sf.name, meta))) {
                            const v = validatedText(meta.widget, value) orelse return false;
                            @field(@field(config, cf.name), sf.name) = v;
                            return true;
                        }
                    }
                }
            }
        }
    }
    return false;
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
    try std.testing.expect(try tryParse(a, &cfg, "window.opacity", "0.7", &diags, 5)); // f32 range 0~1
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), cfg.window_opacity, 0.001);
    try std.testing.expect(try tryParse(a, &cfg, "cursor.blink-interval-ms", "250", &diags, 6)); // sub-struct u32 range
    try std.testing.expectEqual(@as(u32, 250), cfg.cursor.blink_interval_ms);
    try std.testing.expect(try tryParse(a, &cfg, "scroll.multiplier", "2.5", &diags, 7)); // sub-struct f32 range
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), cfg.scroll.multiplier, 0.001);
    try std.testing.expect(try tryParse(a, &cfg, "input.url-click-modifier", "control", &diags, 8)); // sub-struct enum
    try std.testing.expectEqual(theme.UrlClickModifier.control, cfg.input.url_click_modifier);
    try std.testing.expect(try tryParse(a, &cfg, "input.mouse-hide-while-typing", "true", &diags, 9)); // sub-struct bool
    try std.testing.expectEqual(true, cfg.input.mouse_hide_while_typing);
    try std.testing.expect(try tryParse(a, &cfg, "font.fallback", "Apple SD Gothic Neo, Apple Color Emoji", &diags, 10)); // sub-struct text(내부 공백 보존)
    try std.testing.expectEqualStrings("Apple SD Gothic Neo, Apple Color Emoji", cfg.font.fallback);
    a.free(cfg.font.fallback); // dupe 회수(테스트 한정)
    try std.testing.expect(try tryParse(a, &cfg, "cursor.unfocused", "hollow", &diags, 11)); // sub-struct enum
    try std.testing.expectEqual(theme.UnfocusedCursor.hollow, cfg.cursor.unfocused);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    // 범위 밖 padding → diagnostic + 기본 유지
    try std.testing.expect(try tryParse(a, &cfg, "window.padding-right", "999", &diags, 6));
    try std.testing.expectEqual(@as(u32, 8), cfg.window_padding_right); // 기본 유지
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);

    // 범위 밖 opacity(>1) → diagnostic + 직전 유효값(0.7) 유지(파싱 실패는 기존값 보존)
    try std.testing.expect(try tryParse(a, &cfg, "window.opacity", "1.5", &diags, 7));
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), cfg.window_opacity, 0.001); // reject → 직전값 유지
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
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

test "schema appendTextFields/setText: 문자열(widget .text/.color) 열거·설정(인라인 편집)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: theme.Config = .{};

    // appendTextFields = text(.text)만 — color(.color)는 appendColorFields로 분리(스와치 위젯, CS-4-2).
    var list: std.ArrayList(TextField) = .empty;
    try appendTextFields(arena.allocator(), cfg, &list);
    var saw_family = false;
    var saw_bg_in_text = false;
    for (list.items) |f| {
        if (std.mem.eql(u8, f.key, "font.family")) {
            saw_family = true;
            try std.testing.expectEqualStrings("JetBrains Mono", f.value); // 기본 family
        }
        if (std.mem.eql(u8, f.key, "theme.background")) saw_bg_in_text = true;
    }
    try std.testing.expect(saw_family); // text(family) 노출
    try std.testing.expect(!saw_bg_in_text); // color는 text 목록에 없음(appendColorFields로 이동)

    // appendColorFields = color(.color)만 — theme.background 등.
    var clist: std.ArrayList(ColorField) = .empty;
    try appendColorFields(arena.allocator(), cfg, &clist);
    var saw_bg = false;
    for (clist.items) |f| {
        if (std.mem.eql(u8, f.key, "theme.background")) {
            saw_bg = true;
            try std.testing.expectEqualStrings("#101010", f.value);
        }
    }
    try std.testing.expect(saw_bg);

    // setText: family(text)·background(color hex) 설정. value는 호출자 소유(여기선 리터럴). trim 적용.
    try std.testing.expect(setText(&cfg, "font.family", "  Menlo  "));
    try std.testing.expectEqualStrings("Menlo", cfg.font.family); // trim
    try std.testing.expect(setText(&cfg, "theme.background", "#ff0000"));
    try std.testing.expectEqualStrings("#ff0000", cfg.theme.background);
    // 검증(파일 로드 parseAndSet와 같은 규칙, 리뷰 #823): 잘못된 hex·빈 text는 false + 값 불변.
    try std.testing.expect(!setText(&cfg, "theme.background", "#gggggg")); // 잘못된 hex
    try std.testing.expect(!setText(&cfg, "theme.background", "red")); // # 형식 아님
    try std.testing.expectEqualStrings("#ff0000", cfg.theme.background); // 거부 → 직전 값 유지
    try std.testing.expect(!setText(&cfg, "font.family", "   ")); // 공백뿐 → 빈 text 거부
    try std.testing.expectEqualStrings("Menlo", cfg.font.family); // 유지
    // 비스키마/비-text 키 → false.
    try std.testing.expect(!setText(&cfg, "cursor.blink", "x")); // bool 필드
    try std.testing.expect(!setText(&cfg, "no.such.key", "x"));
}

test "schema cycleColor: 16색 프리셋 순환(현재값 프리셋이면 이웃, 아니면 0번부터)" {
    var cfg: theme.Config = .{};
    // 기본 theme.background = "#101010" = color_presets[2]. +1 → presets[3].
    try std.testing.expectEqualStrings("#101010", cfg.theme.background);
    try std.testing.expect(cycleColor(&cfg, "theme.background", 1));
    try std.testing.expectEqualStrings(color_presets[3], cfg.theme.background);
    // -1 → 다시 presets[2].
    try std.testing.expect(cycleColor(&cfg, "theme.background", -1));
    try std.testing.expectEqualStrings(color_presets[2], cfg.theme.background);
    // wrap: presets[0]에서 -1 → 마지막.
    cfg.theme.background = color_presets[0];
    try std.testing.expect(cycleColor(&cfg, "theme.background", -1));
    try std.testing.expectEqualStrings(color_presets[color_presets.len - 1], cfg.theme.background);
    // 현재값이 프리셋 아니면 +1 → presets[0].
    cfg.theme.background = "#123456";
    try std.testing.expect(cycleColor(&cfg, "theme.background", 1));
    try std.testing.expectEqualStrings(color_presets[0], cfg.theme.background);
    // 비-color 키 → false.
    try std.testing.expect(!cycleColor(&cfg, "font.family", 1)); // text 필드
    try std.testing.expect(!cycleColor(&cfg, "cursor.blink", 1)); // bool 필드
    try std.testing.expect(!cycleColor(&cfg, "no.such.key", 1));
}

test "schema paletteKey/setPaletteColor: 정적 키 표기 + hex 검증 set + 범위 가드 (CS-4-5 palette grid)" {
    // 정적 리터럴 키 표기는 loader/serialize의 `theme.palette.{d}`와 같아야 한다(write-back 매칭).
    try std.testing.expectEqualStrings("theme.palette.0", paletteKey(0));
    try std.testing.expectEqualStrings("theme.palette.15", paletteKey(15));
    try std.testing.expectEqual(@as(usize, 0), paletteKey(16).len); // 범위 밖 → 빈 슬라이스
    // 두 번 부른 키 포인터가 같다(정적 — markConfigKeyDirty가 dupe 없이 보관해도 안전).
    try std.testing.expectEqual(paletteKey(3).ptr, paletteKey(3).ptr);

    var cfg: theme.Config = .{};
    try std.testing.expect(cfg.theme.palette[1] == null); // 기본 미override
    try std.testing.expect(setPaletteColor(&cfg, 1, "#d35f5f")); // 유효 hex → set
    try std.testing.expectEqualStrings("#d35f5f", cfg.theme.palette[1].?);
    try std.testing.expect(!setPaletteColor(&cfg, 1, "#gggggg")); // 잘못된 hex → false, 기존값 유지
    try std.testing.expectEqualStrings("#d35f5f", cfg.theme.palette[1].?);
    try std.testing.expect(!setPaletteColor(&cfg, 1, "red")); // # 형식 아님
    try std.testing.expect(!setPaletteColor(&cfg, 16, "#ffffff")); // 범위 밖
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
