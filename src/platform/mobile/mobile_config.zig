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
const schema = maru.config.schema;

/// 스크롤백 — 데스크톱 `ScrollbackConfig` 를 안 빌린다. 그쪽은 `sticky-command`(chrome 표시)를
/// 함께 들고 있는데 모바일엔 그 화면이 없다(계약 §4.2).
pub const ScrollbackConfig = struct {
    lines: u32 = 1000,

    pub const schema = .{
        .lines = theme.Meta{ .doc = "스크롤백 줄 수", .range = .{ 0, 100_000 }, .widget = .number },
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
