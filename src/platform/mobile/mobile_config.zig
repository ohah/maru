//! 모바일 config — 스키마와 파싱. 계약은 [모바일 config](../../../docs/mobile-config.md)가 소유한다.
//!
//! **데스크톱과 파일도 스키마도 나누되 기계는 공유한다**(계약 §1·§3). 줄 문법은 `loader.parse` 를
//! 부를 수가 없어(그 함수는 데스크톱 `Config` 에 묶여 있고 keybind·env 목록까지 만든다) 같은 규칙의
//! 짧은 루프를 여기 둔다. 키→필드 파싱은 `schema.tryParse` 를 **그대로** 쓴다 — 그 함수는 Config
//! 타입에 안 묶여 있어(M10b0) 이 구조체의 `schema` 메타를 comptime 에 그대로 읽는다.
//!
//! **계열마다 빌릴지 새로 쓸지 정한다**(계약 §3). 통째로 뜻이 있는 것은 데스크톱 sub-struct 를
//! 빌리고(`ThemeConfig`·`CursorConfig` — 색은 색이고 커서는 커서다), 한 조각만 필요한 계열은
//! 모바일 것으로 둔다. 빌리면 스키마 메타가 이미 달려 있어 키가 저절로 파싱되고, `presetColors()`
//! 가 **바로 그 타입**을 돌려줘 프리셋도 그대로 대입된다.
const std = @import("std");
const maru = @import("maru");

const theme = maru.config.theme;
const loader = maru.config.loader;
const schema = maru.config.schema;

/// 스크롤백 — 데스크톱 `ScrollbackConfig` 를 안 빌린다. 그쪽은 `sticky-command`(chrome 표시)를
/// 함께 들고 있는데 모바일엔 그 화면이 없다(계약 §4.2).
pub const ScrollbackConfig = struct {
    lines: u32 = 1000,

    pub const schema = .{
        .lines = theme.Meta{ .doc = .cfg_scrollback_lines, .range = .{ 0, 100_000 }, .widget = .number },
    };
};

pub const Config = struct {
    /// 빌린다 — 색 세트는 데스크톱과 뜻이 같고, `theme.preset` 이 이 타입을 통째로 돌려준다.
    ///
    /// **기본값은 모바일 것으로 못박는다.** 빌린 타입의 기본값을 그대로 쓰면 config 를 읽기
    /// 시작한 순간 **설정을 한 번도 안 건드린 기기의 화면이 바뀐다**(배경이 #1E1E2E → #101010
    /// 으로 어두워지는 것을 픽셀로 확인했다). 기기가 다르면 기본값도 다르다는 계약(§4.5)이
    /// 색에도 그대로 적용된다.
    theme: theme.ThemeConfig = .{
        .background = "#1e1e2e",
        .foreground = "#e6e6ea",
        .cursor = "#e6e6ea",
        .selection = "#304060",
    },
    /// 빌린다 — 커서 모양·색은 뜻이 같다.
    cursor: theme.CursorConfig = .{},
    scrollback: ScrollbackConfig = .{},
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// `key = value` 한 줄에 하나, `#` 주석. **forgiving** — 없는 키·틀린 값은 기본값을 지키고 넘어간다
/// (데스크톱과 같은 규율). 파일이 없거나 비어도 정상이다.
/// 모바일 설정 행의 라벨. **comptime 에 해석한다** — 이 목록은 `inline for` 로 만드는 comptime
/// 테이블이라 런타임 언어 조회(`i18n.t`)를 쓸 수 없다(`error: unable to resolve comptime value`).
///
/// 그래서 언어가 **`ko` 로 고정**된다. 지금 모바일 화면이 한국어이므로 퇴보는 아니지만, 이 화면은
/// `ui.language` 를 따르지 못한다. 근본 원인은 번역이 아니라 **행 목록이 comptime 이라는 구조**이고,
/// 모바일이 OS 로케일을 받는 슬라이스가 그것을 함께 든다(docs/mobile-config.md §4.2).
fn mobileDocLabel(comptime doc: ?maru.i18n.Key, comptime key: []const u8) []const u8 {
    return if (doc) |k| maru.i18n.tIn(.ko, k) else key;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config: Config = .{};
    var diags: std.ArrayList(schema.Diag) = .empty;

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);

        // **프리셋은 스키마 밖이다**(계약 §3) — 색 하나가 아니라 세트를 통째로 깐다.
        if (std.mem.eql(u8, key, "theme.preset")) {
            // 이름 파싱은 공용 제너릭을 쓴다 — 프리셋이 늘어도 여기는 안 고친다.
            if (theme.parseDashedEnum(theme.ThemePreset, value)) |p| config.theme = theme.presetColors(p);
            continue;
        }
        _ = schema.tryParse(a, &config, key, value, &diags, line_no) catch continue;
    }
    return .{ .arena = arena, .config = config };
}

test "빌린 sub-struct 의 키가 스키마 엔진으로 파싱된다" {
    var p = try parse(std.testing.allocator,
        \\# 주석
        \\theme.background = #101820
        \\cursor.shape = bar
        \\scrollback.lines = 250
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("#101820", p.config.theme.background);
    try std.testing.expectEqual(theme.CursorShape.bar, p.config.cursor.shape);
    try std.testing.expectEqual(@as(u32, 250), p.config.scrollback.lines);
}

test "프리셋은 색 세트를 통째로 깐다" {
    var p = try parse(std.testing.allocator, "theme.preset = nord");
    defer p.deinit();
    const nord = theme.presetColors(.nord);
    try std.testing.expectEqualStrings(nord.background, p.config.theme.background);
}

test "없는 키·틀린 값은 기본값을 지킨다" {
    var p = try parse(std.testing.allocator,
        \\없는.키 = 값
        \\scrollback.lines = 숫자아님
        \\줄에 등호가 없다
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines);
}

// ── 설정 화면이 쓸 줄 기술자 ──────────────────────────────────────────────────
//
// **줄을 손으로 적지 않는다.** PoC 는 라벨 58개를 코드에 박아 뒀는데 그 대부분은 뒤에 키가
// 없어 눌러도 아무 일이 안 났다(계약 §6). 스키마에서 만들면 **키가 있는 줄만** 생긴다 —
// 스키마에 키를 더하면 줄이 생기고, 빼면 사라진다.
//
// **섹션은 모바일이 소유한다.** 데스크톱 `Section` 은 config 이름 공간에 가깝고(`bell.*` 이
// `.terminal`) 모바일 화면은 사용자가 찾는 주제로 묶는다 — 부분집합이 아니라 다른 체계다
// (계약 §3). 그래서 namespace → 헤더를 여기서 정한다.

pub const Kind = enum { toggle, choice, number };

/// "고른 프리셋이 없다" — 색이 어느 프리셋과도 안 맞는 상태(개별 색을 손댔거나 기본값 그대로).
/// 화면은 이 값을 **빈 자리**로 그린다. 아무 이름이나 적으면 고르지도 않은 것을 고른 것처럼 보인다.
pub const preset_none: i64 = -1;

pub const Row = struct {
    key: []const u8,
    label: []const u8,
    kind: Kind,
    /// choice 일 때만 — enum 태그를 dashed 로(파일에 적히는 그 표기).
    items: []const []const u8 = &.{},
    section: []const u8,
};

fn dashed(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const out = buf;
        return &out;
    }
}

/// namespace(Config 필드명) → 화면 헤더. **여기가 모바일 섹션의 단일 출처다.**
fn sectionOf(comptime ns: []const u8) []const u8 {
    if (std.mem.eql(u8, ns, "theme")) return "모양";
    if (std.mem.eql(u8, ns, "cursor")) return "커서";
    if (std.mem.eql(u8, ns, "scrollback")) return "터미널";
    return "기타";
}

/// 스키마에서 줄을 만든다. **색·문자열 필드는 아직 안 낸다** — 16진 편집 UI 가 없어서,
/// 내면 눌러도 아무 일이 안 나는 줄이 된다(그게 PoC 의 문제였다). 그 줄은 편집 수단이
/// 생기는 슬라이스에서 함께 낸다.
pub const rows: []const Row = blk: {
    // **스키마 밖의 키 하나를 손으로 낸다.** `theme.preset` 은 색 하나가 아니라 세트를 통째로
    // 까는 명시 가지라(계약 §3) 스키마 반영으로는 안 나온다. 그런데 사용자가 가장 먼저 찾는
    // 설정이고 파서가 이미 받으므로, 여기 한 줄만 예외로 둔다 — 예외가 늘면 그때 스키마 쪽에
    // 표현을 만든다.
    var preset_items: []const []const u8 = &.{};
    for (@typeInfo(theme.ThemePreset).@"enum".fields) |ef| {
        preset_items = preset_items ++ [_][]const u8{dashed(ef.name)};
    }
    var list: []const Row = &[_]Row{.{
        .key = "theme.preset",
        .label = "테마 프리셋",
        .kind = .choice,
        .items = preset_items,
        .section = "모양",
    }};
    for (@typeInfo(Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) != .@"struct" or !@hasDecl(Container, "schema")) continue;
        const sch = Container.schema;
        for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
            const meta: theme.Meta = @field(sch, sf.name);
            const FieldT = @TypeOf(@field(@as(Container, .{}), sf.name));
            const seg = meta.key_seg orelse dashed(sf.name);
            const key = if (meta.key) |k| k else cf.name ++ "." ++ seg;
            const row: ?Row = switch (@typeInfo(FieldT)) {
                .bool => Row{ .key = key, .label = mobileDocLabel(meta.doc, key), .kind = .toggle, .section = sectionOf(cf.name) },
                .int => Row{ .key = key, .label = mobileDocLabel(meta.doc, key), .kind = .number, .section = sectionOf(cf.name) },
                .@"enum" => e: {
                    var items: []const []const u8 = &.{};
                    for (@typeInfo(FieldT).@"enum".fields) |ef| items = items ++ [_][]const u8{dashed(ef.name)};
                    break :e Row{ .key = key, .label = mobileDocLabel(meta.doc, key), .kind = .choice, .items = items, .section = sectionOf(cf.name) };
                },
                else => null, // []const u8(색·문자열) — 편집 수단이 없다
            };
            if (row) |r| list = list ++ [_]Row{r};
        }
    }
    break :blk list;
};

test "줄은 스키마에서 나오고, 편집 수단이 없는 것은 안 나온다" {
    try std.testing.expect(rows.len >= 6);
    var saw_toggle = false;
    var saw_choice = false;
    var saw_number = false;
    for (rows) |r| {
        // 색은 안 나온다 — 눌러도 아무 일이 안 나는 줄을 만들지 않는다.
        try std.testing.expect(!std.mem.eql(u8, r.key, "theme.background"));
        try std.testing.expect(r.label.len > 0);
        switch (r.kind) {
            .toggle => saw_toggle = true,
            .choice => {
                saw_choice = true;
                try std.testing.expect(r.items.len > 0);
            },
            .number => saw_number = true,
        }
    }
    try std.testing.expect(saw_toggle and saw_choice and saw_number);
}

// ── 값 읽기·쓰기 (화면이 쓴다) ────────────────────────────────────────────────
//
// **줄과 값을 같은 키로 잇는다.** 화면이 자기 상태를 따로 들면 파일과 갈린다("파일이 단일
// 출처", 계약 §1) — 그릴 때마다 config 에서 읽고, 바꿀 때는 config 를 고친다.

/// 그 키의 현재 값을 화면 표기로. choice 는 `Row.items` 의 색인, toggle 은 0/1, number 는 값.
pub fn valueOf(cfg: Config, key: []const u8) i64 {
    if (std.mem.eql(u8, key, "theme.preset")) {
        // 프리셋은 config 에 이름이 안 남는다(파싱 때 색으로 펼쳐진다) — 색으로 되짚는다.
        //
        // **네 색을 다 본다.** 배경 하나만 비교하면 남의 이름을 뒤집어씌운다 — 모바일 기본값이
        // catppuccin-mocha 와 배경만 같아서(전경·커서는 다르다) 아무것도 안 고른 기기가
        // "catppuccin-mocha" 로 보였다(화면으로 잡았다).
        //
        // 어느 것과도 안 맞으면 **고른 것이 없다**(`preset_none`) — 사용자가 개별 색을 손댔거나
        // 기본값 그대로인 상태다. 그 자리에 아무 프리셋 이름이나 적으면 화면이 거짓말을 한다.
        inline for (@typeInfo(theme.ThemePreset).@"enum".fields, 0..) |ef, i| {
            const p: theme.ThemePreset = @enumFromInt(ef.value);
            const c = theme.presetColors(p);
            if (std.mem.eql(u8, c.background, cfg.theme.background) and
                std.mem.eql(u8, c.foreground, cfg.theme.foreground) and
                std.mem.eql(u8, c.cursor, cfg.theme.cursor) and
                std.mem.eql(u8, c.selection, cfg.theme.selection)) return @intCast(i);
        }
        return preset_none;
    }
    inline for (@typeInfo(Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            inline for (@typeInfo(@TypeOf(Container.schema)).@"struct".fields) |sf| {
                const meta: theme.Meta = @field(Container.schema, sf.name);
                const seg = comptime (meta.key_seg orelse dashed(sf.name));
                const full = comptime (meta.key orelse (cf.name ++ "." ++ seg));
                if (std.mem.eql(u8, key, full)) {
                    const v = @field(@field(cfg, cf.name), sf.name);
                    return switch (@typeInfo(@TypeOf(v))) {
                        .bool => @intFromBool(v),
                        .int => @intCast(v),
                        .@"enum" => @intFromEnum(v),
                        else => 0,
                    };
                }
            }
        }
    }
    return 0;
}

/// 값을 config 에 쓴다(화면 표기 → 필드). 파일에 적을 문자열은 `textOf` 가 낸다.
pub fn setValue(cfg: *Config, key: []const u8, v: i64) void {
    if (std.mem.eql(u8, key, "theme.preset")) {
        inline for (@typeInfo(theme.ThemePreset).@"enum".fields, 0..) |ef, i| {
            if (v == i) cfg.theme = theme.presetColors(@as(theme.ThemePreset, @enumFromInt(ef.value)));
        }
        return;
    }
    inline for (@typeInfo(Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            inline for (@typeInfo(@TypeOf(Container.schema)).@"struct".fields) |sf| {
                const meta: theme.Meta = @field(Container.schema, sf.name);
                const seg = comptime (meta.key_seg orelse dashed(sf.name));
                const full = comptime (meta.key orelse (cf.name ++ "." ++ seg));
                if (std.mem.eql(u8, key, full)) {
                    const ptr = &@field(@field(cfg, cf.name), sf.name);
                    const T = @TypeOf(ptr.*);
                    switch (@typeInfo(T)) {
                        .bool => ptr.* = v != 0,
                        .int => ptr.* = @intCast(@max(0, v)),
                        .@"enum" => ptr.* = @enumFromInt(v),
                        else => {},
                    }
                }
            }
        }
    }
}

/// 파일에 적을 값 문자열. **파서가 받아들이는 정확한 표기**여야 한다(dashed enum·숫자·bool).
pub fn textOf(row: Row, v: i64, buf: []u8) []const u8 {
    return switch (row.kind) {
        .toggle => if (v != 0) "true" else "false",
        .choice => if (v >= 0 and v < row.items.len) row.items[@intCast(v)] else row.items[0],
        .number => std.fmt.bufPrint(buf, "{d}", .{v}) catch "0",
    };
}

test "값을 읽고 쓰는 것이 같은 키로 돈다" {
    var c: Config = .{};
    setValue(&c, "scrollback.lines", 321);
    try std.testing.expectEqual(@as(i64, 321), valueOf(c, "scrollback.lines"));
    setValue(&c, "cursor.blink", 0);
    try std.testing.expectEqual(@as(i64, 0), valueOf(c, "cursor.blink"));

    // 프리셋은 색으로 펼쳐지고, 되짚으면 그 프리셋이 나온다.
    var idx: i64 = 0;
    for (rows) |r| if (std.mem.eql(u8, r.key, "theme.preset")) {
        for (r.items, 0..) |it, i| if (std.mem.eql(u8, it, "nord")) {
            idx = @intCast(i);
        };
    };
    setValue(&c, "theme.preset", idx);
    try std.testing.expectEqualStrings(theme.presetColors(.nord).background, c.theme.background);
    try std.testing.expectEqual(idx, valueOf(c, "theme.preset"));
}

/// 바뀐 키 하나를 원본 본문에 반영한 **새 본문**을 만든다. 통째로 다시 쓰지 않는다 —
/// `loader.updateConfigText` 가 주석과 **모르는 키**를 보존한다(계약 §7). 데스크톱 config 를
/// 복사해 넣은 사용자가 그 줄들을 잃으면 안 된다.
///
/// `serialize.updateForKeys` 는 못 쓴다 — 그것도 데스크톱 `Config` 를 받는다(계약 §3). 우리는
/// 키/값 쌍을 직접 만들어 그 아래(Config 를 모르는 층)를 부른다.
pub fn withKey(allocator: std.mem.Allocator, original: []const u8, key: []const u8, value: []const u8) ![]u8 {
    const kv = [_]loader.KeyValue{.{ .key = key, .value = value }};
    return loader.updateConfigText(allocator, original, &kv);
}

test "저장은 주석과 모르는 키를 지키고 그 줄만 고친다" {
    const original =
        \\# 내 설정
        \\theme.preset = nord
        \\window.padding-x = 8
        \\scrollback.lines = 1000
    ;
    const out = try withKey(std.testing.allocator, original, "scrollback.lines", "250");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 내 설정") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "window.padding-x = 8") != null); // 모바일이 모르는 키
    try std.testing.expect(std.mem.indexOf(u8, out, "scrollback.lines = 250") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "scrollback.lines = 1000") == null);
}

test "없던 키는 새로 붙는다" {
    const out = try withKey(std.testing.allocator, "# 비어 있다\n", "cursor.blink", "false");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cursor.blink = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 비어 있다") != null);
}

/// 그 키의 스키마 범위 밖인가. **범위는 스키마가 소유한다** — 화면이 숫자를 따로 적으면
/// 파일 파싱과 GUI 가 다른 값을 받아들인다.
pub fn outOfRange(key: []const u8, v: i64) bool {
    inline for (@typeInfo(Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            inline for (@typeInfo(@TypeOf(Container.schema)).@"struct".fields) |sf| {
                const meta: theme.Meta = @field(Container.schema, sf.name);
                const seg = comptime (meta.key_seg orelse dashed(sf.name));
                const full = comptime (meta.key orelse (cf.name ++ "." ++ seg));
                if (std.mem.eql(u8, key, full)) {
                    const r = meta.parse_range orelse meta.range orelse return false;
                    return @as(f64, @floatFromInt(v)) < r[0] or @as(f64, @floatFromInt(v)) > r[1];
                }
            }
        }
    }
    return false;
}

test "범위는 스키마가 정한다" {
    try std.testing.expect(!outOfRange("scrollback.lines", 250));
    try std.testing.expect(outOfRange("cursor.blink-interval-ms", 50)); // 최소 100
    try std.testing.expect(outOfRange("cursor.blink-interval-ms", 20000)); // 최대 10000
    try std.testing.expect(!outOfRange("cursor.blink-interval-ms", 500));
}
