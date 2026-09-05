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

/// 글자 크기. **모바일에서는 이 값이 곧 줄 높이(논리 px)** 다 — 데스크톱은 pt 를 받아 폰트
/// 메트릭으로 셀을 정하지만, 모바일은 아틀라스 셀 기하가 고정이라 브리지가 줄 높이를 직접
/// 정한다(계약 §4 "글자 상자가 곧 칸이다"). 기본값 22 는 지금 화면의 줄 높이 그대로다.
///
/// **범위는 폰에 맞춘다.** 데스크톱은 [6,72] 를 허용하지만 폰에서 6px 는 못 읽고 72px 는 한
/// 화면에 열 줄이 안 들어간다 — 기기가 다르면 기본값도 범위도 다르다는 계약(§4.5)이 여기도
/// 적용된다. 굽는 크기가 이 값을 따라가므로(M10d-2) 너무 키우면 아틀라스가 커진다.
pub const FontConfig = struct {
    size: u32 = 22,
    /// 줄 높이를 글자 크기의 **백분율**로. 100 이면 `size` 그대로(예전 동작).
    ///
    /// **왜 배수가 아니라 백분율인가**: 이 config 는 값이 전부 정수다(`valueOf`/`setValue` 가
    /// `i64`). 데스크톱은 `font.line-height = 1.2` 처럼 배수를 쓰는데 뜻은 같다 — 여기서는
    /// 120 이 그것이다.
    ///
    /// **이 손잡이가 없으면 글자 크기와 화면 밀도가 한 몸이다.** `size` 를 키우면 줄 높이가
    /// 그만큼 커져 보이는 줄 수가 반드시 준다 — 폰에서는 그 대가가 크다(사용자 요청: 폰트를
    /// 유지하면서 더 보고 싶다). 낮추면 글자는 그대로 두고 줄만 늘릴 수 있다.
    line_height: u32 = 100,

    pub const schema = .{
        .size = theme.Meta{ .doc = .cfg_font_size, .range = .{ 12, 40 }, .widget = .number },
        .line_height = theme.Meta{ .doc = .cfg_mob_font_line_height, .range = .{ 60, 200 }, .widget = .number },
    };
};

/// 시스템 외관(다크/라이트)을 따라가는 설정 셋. **데스크톱 F2-9 를 그대로 빌린다** — 키 이름도
/// 뜻도 같다(`theme.follow-system`·`theme.preset-light`·`theme.preset-dark`).
///
/// **그릇만 여기서 만든다.** 데스크톱은 이 셋이 최상위 스칼라(`config/theme.zig` 의 `Config`
/// 직속)라 통째로 빌릴 sub-struct 가 없다. `Meta.key` 로 전체 키를 명시하는 방식까지 데스크톱과
/// 같게 두어, 파일에 적히는 글자가 두 곳에서 같다.
pub const SystemThemeConfig = struct {
    follow_system: bool = false,
    preset_light: theme.ThemePreset = .solarized_light,
    /// **데스크톱은 `.maru` 인데 여기는 `catppuccin_mocha` 다.** 모바일 기본 배경(`#1e1e2e`)이
    /// 그 프리셋의 배경과 **같아서**, 켜는 순간 화면이 안 튄다 — `.maru`(`#101010`)로 두면 켜자마자
    /// 어두워진다. 「기기가 다르면 기본값도 다르다」(계약 §4.5)가 색에도 걸리는 그 자리이고,
    /// 위 `Config.theme` 이 데스크톱 기본을 안 빌린 것과 같은 이유다.
    preset_dark: theme.ThemePreset = .catppuccin_mocha,

    pub const schema = .{
        .follow_system = theme.Meta{ .key = "theme.follow-system", .doc = .cfg_theme_follow_system, .widget = .toggle },
        .preset_light = theme.Meta{ .key = "theme.preset-light", .doc = .cfg_theme_preset_light, .widget = .dropdown },
        .preset_dark = theme.Meta{ .key = "theme.preset-dark", .doc = .cfg_theme_preset_dark, .widget = .dropdown },
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
    font: FontConfig = .{},
    scrollback: ScrollbackConfig = .{},
    system_theme: SystemThemeConfig = .{},
};

/// 등록한 서버 하나. **자격증명은 없다** — 개인키는 Keystore·앱 전용 파일에 있고 여기엔 그것을
/// 가리키는 값도 없다(기기가 가진 키가 하나라서다. 계약 [모바일 config](../../../docs/mobile-config.md) §4.3).
pub const Server = struct {
    name: []const u8 = "",
    host: []const u8 = "",
    port: u16 = 22,
    user: []const u8 = "",
    fingerprint: []const u8 = "",
    /// 그 기계의 `maru` 절대경로. **비워 두면 `maru` 를 그대로 쓴다**(계약
    /// [컨트롤 플레인 §4a](../../../docs/control-plane.md)).
    ///
    /// 왜 필요한가: 비대화형 `exec` 은 로그인 셸의 rc 를 대개 안 읽어 **PATH 가 좁다** — 설치돼
    /// 있어도 127 이 난다(실측: 시뮬레이터가 붙은 맥에서 그대로 재현됐다). 우리가 설치 경로를
    /// 추측해 차례로 시도하지 않는 이유는, 맞아도 사용자는 무엇이 돌았는지 모르고 틀리면 그만큼
    /// 느려지기 때문이다.
    maru_path: []const u8 = "",

    /// 붙을 수 있는 줄인가. **반쯤 적은 줄로 붙으러 가지 않는다** — 그러면 실패 이유가
    /// "네트워크" 처럼 보여 사용자가 무엇을 안 적었는지 모른다.
    ///
    /// **지문은 여기 없다.** 처음 붙는 서버는 지문을 모르는 것이 정상이고(폰에서 미리 알아낼
    /// 길이 없다), 그때는 서버가 내민 지문을 **보여 주고 승인받는다**(S9b-3). 승인하면 그 값이
    /// 이 줄에 적히고 다음부터는 핀 고정이다. 예전에는 지문을 필수로 봐서 **지문을 미리 아는
    /// 사람만** 붙을 수 있었다.
    pub fn isComplete(self: Server) bool {
        return self.host.len > 0 and self.user.len > 0;
    }

    /// 이 줄이 **처음 붙는 서버**인가(지문이 아직 없다). 화면이 그렇게 알린다 — 오류가 아니다.
    pub fn isFirstConnect(self: Server) bool {
        return self.fingerprint.len == 0;
    }
};

/// 서버 자리 수. **미리 잡아 두므로 숫자가 곧 상주 메모리다**(브리지엔 할당이 없다).
/// 헤더의 `MARU_MAX_SERVERS` 와 같은 값이어야 한다 — 계약 테스트가 대조한다.
pub const max_servers = 16;

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    /// 앞에서부터 `server_count` 개만 뜻이 있다. **파일의 번호가 아니라 순서다** — 파일에
    /// 1·3 만 있으면 여기서는 0·1 이고, 다음 저장에서 1·2 로 다시 매겨진다.
    servers: [max_servers]Server = @splat(.{}),
    server_count: usize = 0,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// `ssh.server.<n>.<field>` 를 쪼갠다. 번호가 1..`max_servers` 밖이거나 모양이 다르면 null 이다.
/// **스키마 엔진 밖의 명시 가지**다(`theme.palette.N` 과 같은 부류 — 계약 §3).
fn parseServerKey(key: []const u8) ?struct { index: usize, field: []const u8 } {
    const prefix = "ssh.server.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const rest = key[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const n = std.fmt.parseInt(usize, rest[0..dot], 10) catch return null;
    if (n < 1 or n > max_servers) return null;
    return .{ .index = n - 1, .field = rest[dot + 1 ..] };
}

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
    var slots: [max_servers]Server = @splat(.{});
    var seen: [max_servers]bool = @splat(false);

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
        // **서버 목록도 스키마 밖이다**(§4.3) — 번호가 키에 들어 있어 comptime 반영으로는 못 닿는다.
        if (parseServerKey(key)) |sk| {
            const dst = &slots[sk.index];
            seen[sk.index] = true;
            const dup = a.dupe(u8, value) catch continue;
            if (std.mem.eql(u8, sk.field, "name")) dst.name = dup
                // 포트만 숫자다. **못 읽는 값은 기본(22)을 지킨다** — forgiving 규율(§3)이고,
                // 여기서 0 으로 떨어뜨리면 붙을 수 없는 줄이 조용히 생긴다.
            else if (std.mem.eql(u8, sk.field, "host")) dst.host = dup else if (std.mem.eql(u8, sk.field, "user")) dst.user = dup else if (std.mem.eql(u8, sk.field, "fingerprint")) dst.fingerprint = dup else if (std.mem.eql(u8, sk.field, "maru-path")) dst.maru_path = dup else if (std.mem.eql(u8, sk.field, "port")) dst.port = std.fmt.parseInt(u16, value, 10) catch dst.port;
            continue;
        }
        _ = schema.tryParse(a, &config, key, value, &diags, line_no) catch continue;
    }
    // **빈 자리를 없애고 앞으로 당긴다.** 번호는 이름이 아니라 순서다(§4.3) — 파일에 1·3 만
    // 있어도 목록은 둘이고, 다음 저장에서 1·2 가 된다.
    var out: [max_servers]Server = @splat(.{});
    var n: usize = 0;
    for (slots, seen) |srv, was_seen| {
        if (!was_seen) continue;
        out[n] = srv;
        n += 1;
    }
    return .{ .arena = arena, .config = config, .servers = out, .server_count = n };
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

test "서버 목록은 번호 키에서 나온다" {
    var p = try parse(std.testing.allocator,
        \\ssh.server.1.name = 집
        \\ssh.server.1.host = 10.0.0.5
        \\ssh.server.1.user = me
        \\ssh.server.1.port = 2222
        \\ssh.server.1.fingerprint = SHA256:abc
        \\scrollback.lines = 250
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.server_count);
    try std.testing.expectEqualStrings("집", p.servers[0].name);
    try std.testing.expectEqualStrings("10.0.0.5", p.servers[0].host);
    try std.testing.expectEqualStrings("me", p.servers[0].user);
    try std.testing.expectEqual(@as(u16, 2222), p.servers[0].port);
    try std.testing.expectEqualStrings("SHA256:abc", p.servers[0].fingerprint);
    try std.testing.expect(p.servers[0].isComplete());
    // 다른 키는 그대로 스키마 엔진이 먹는다 — 가지를 더해도 나머지가 안 막힌다.
    try std.testing.expectEqual(@as(u32, 250), p.config.scrollback.lines);
}

test "빈 번호는 앞으로 당겨진다 — 번호는 이름이 아니라 순서다" {
    // 파일에 1·3 만 있어도 목록은 둘이다. 안 당기면 화면에 **빈 줄**이 생기고, 그 줄을 눌러도
    // 아무 일이 안 난다(§4.3).
    var p = try parse(std.testing.allocator,
        \\ssh.server.1.host = a
        \\ssh.server.3.host = c
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.server_count);
    try std.testing.expectEqualStrings("a", p.servers[0].host);
    try std.testing.expectEqualStrings("c", p.servers[1].host);
}

test "포트는 없으면 22, 못 읽으면 그대로 22" {
    var p = try parse(std.testing.allocator,
        \\ssh.server.1.host = a
        \\ssh.server.2.host = b
        \\ssh.server.2.port = 숫자아님
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u16, 22), p.servers[0].port);
    try std.testing.expectEqual(@as(u16, 22), p.servers[1].port); // 기본값을 지킨다(forgiving)
}

test "지문이 없는 줄은 처음 붙는 서버다 — 못 붙는 줄이 아니다" {
    // **예전에는 지문을 필수로 봤다.** 그러면 지문을 미리 아는 사람만 붙을 수 있고, 폰에서는
    // 그것을 알아낼 길이 없다 — 이제는 서버가 내민 지문을 보여 주고 승인받는다(S9b-3).
    var p = try parse(std.testing.allocator,
        \\ssh.server.1.host = a
        \\ssh.server.1.user = me
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.server_count);
    try std.testing.expect(p.servers[0].isComplete()); // 붙을 수 있다
    try std.testing.expect(p.servers[0].isFirstConnect()); // 다만 지문은 아직 없다
}

test "주소나 사용자가 없으면 접속 대상이 아니다" {
    // 그 줄로 붙으러 가면 실패 이유가 "네트워크" 처럼 보인다 — 무엇을 안 적었는지 모른다.
    var p = try parse(std.testing.allocator, "ssh.server.1.host = a");
    defer p.deinit();
    try std.testing.expect(!p.servers[0].isComplete()); // 사용자가 없다
}

test "상한 밖 번호와 모르는 필드는 무시한다" {
    var p = try parse(std.testing.allocator,
        \\ssh.server.0.host = 영번
        \\ssh.server.17.host = 넘침
        \\ssh.server.x.host = 숫자아님
        \\ssh.server.1.host = a
        \\ssh.server.1.모르는필드 = 값
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.server_count);
    try std.testing.expectEqualStrings("a", p.servers[0].host);
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

pub const Kind = enum { toggle, choice, number, text };

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
    if (std.mem.eql(u8, ns, "theme")) return maru.i18n.tIn(.ko, .mob_appearance);
    if (std.mem.eql(u8, ns, "cursor")) return maru.i18n.tIn(.ko, .set_section_cursor);
    if (std.mem.eql(u8, ns, "font")) return maru.i18n.tIn(.ko, .mob_appearance);
    if (std.mem.eql(u8, ns, "scrollback")) return maru.i18n.tIn(.ko, .set_section_terminal);
    if (std.mem.eql(u8, ns, "system_theme")) return maru.i18n.tIn(.ko, .mob_appearance);
    return maru.i18n.tIn(.ko, .set_section_other);
}

/// 스키마에서 줄을 만든다. **색·문자열 필드는 아직 안 낸다** — 16진 편집 UI 가 없어서,
/// 내면 눌러도 아무 일이 안 나는 줄이 된다(그게 PoC 의 문제였다). 그 줄은 편집 수단이
/// 생기는 슬라이스에서 함께 낸다.
pub const rows: []const Row = blk: {
    // 스키마 줄이 늘면 comptime 분기 예산이 먼저 바닥난다(`dashed` 의 글자 순회가 줄마다 돈다).
    // **값이 아니라 한도라 넉넉히 준다** — 모자라면 컴파일이 서고, 남아도 산출물은 같다.
    @setEvalBranchQuota(20000);
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
        .label = maru.i18n.tIn(.ko, .set_theme_preset),
        .kind = .choice,
        .items = preset_items,
        .section = maru.i18n.tIn(.ko, .mob_appearance),
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
                // **문자열(색)은 이제 낸다 — 편집 수단이 생겼다.** 이 줄들이 안 나오던 이유는
                // "눌러도 아무 일이 안 나는 줄을 만들지 않는다" 였고, 텍스트 입력이 생기면서
                // 그 이유가 사라졌다(계약 §3.0 — 입력 목적지를 가르는 그 자리를 쓴다).
                //
                // **팔레트 16색은 아직 안 낸다.** 그것까지 내면 목록이 색으로 뒤덮여 나머지
                // 설정을 못 찾는다 — 색 고르개가 생기는 슬라이스에서 함께 낸다.
                .pointer => |ptr| if (ptr.child == u8 and !std.mem.startsWith(u8, key, "theme.palette"))
                    Row{ .key = key, .label = mobileDocLabel(meta.doc, key), .kind = .text, .section = sectionOf(cf.name) }
                else
                    null,
                else => null,
            };
            if (row) |r| list = list ++ [_]Row{r};
        }
    }
    break :blk list;
};

test "줄은 스키마에서 나오고, 문자열 줄도 이제 나온다" {
    try std.testing.expect(rows.len >= 6);
    var saw_toggle = false;
    var saw_choice = false;
    var saw_number = false;
    var saw_text = false;
    for (rows) |r| {
        try std.testing.expect(r.label.len > 0);
        // **팔레트는 아직 안 나온다** — 목록이 색으로 뒤덮이면 나머지를 못 찾는다.
        try std.testing.expect(!std.mem.startsWith(u8, r.key, "theme.palette"));
        switch (r.kind) {
            .toggle => saw_toggle = true,
            .choice => {
                saw_choice = true;
                try std.testing.expect(r.items.len > 0);
            },
            .number => saw_number = true,
            .text => saw_text = true,
        }
    }
    try std.testing.expect(saw_toggle and saw_choice and saw_number);
    // 배경색은 문자열 줄로 나온다 — 편집 수단이 생겼기 때문이다.
    var saw_background = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.key, "theme.background")) {
            saw_background = true;
            try std.testing.expectEqual(Kind.text, r.kind);
        }
    }
    try std.testing.expect(saw_text and saw_background);
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
        // **문자열 줄은 숫자로 표현되지 않는다.** 값은 편집기가 들고 있고 그대로 파일에 간다 —
        // 이 함수를 부르는 쪽이 그것을 알아야 해서 빈 값을 준다(그 값이 파일에 실리면 키가
        // 지워진 것과 같으므로, 호출자는 `textOf` 대신 친 문자열을 넘긴다).
        .text => "",
    };
}

/// 문자열 줄의 지금 값. **화면이 자기 상태를 들지 않는다** — 값은 config 에서만 읽는다.
pub fn textValueOf(c: Config, key: []const u8) []const u8 {
    inline for (@typeInfo(Config).@"struct".fields) |cf| {
        const Container = cf.type;
        if (@typeInfo(Container) == .@"struct" and @hasDecl(Container, "schema")) {
            const sch = Container.schema;
            inline for (@typeInfo(@TypeOf(sch)).@"struct".fields) |sf| {
                const meta: theme.Meta = comptime @field(sch, sf.name);
                const seg = comptime (meta.key_seg orelse dashed(sf.name));
                const full = comptime (if (meta.key) |k| k else cf.name ++ "." ++ seg);
                const FieldT = @TypeOf(@field(@field(c, cf.name), sf.name));
                if (@typeInfo(FieldT) == .pointer and @typeInfo(FieldT).pointer.child == u8) {
                    if (std.mem.eql(u8, full, key)) return @field(@field(c, cf.name), sf.name);
                }
            }
        }
    }
    return "";
}

test "문자열 값은 config 에서 읽는다" {
    const c: Config = .{};
    // 모바일 기본 배경(§4.5 — 기기가 다르면 기본값도 다르다).
    try std.testing.expectEqualStrings("#1e1e2e", textValueOf(c, "theme.background"));
    try std.testing.expectEqualStrings("", textValueOf(c, "없는.키"));
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

/// 서버 목록을 통째로 다시 적은 본문을 만든다. **`withKey` 로는 못 한다** — 그 함수는 값을
/// 고칠 뿐이라 지우기(삭제)와 번호 다시 매기기를 못 하고, 반쯤 지워진 줄이 남으면 다음에 읽을 때
/// 없는 서버가 되살아난다.
///
/// **`ssh.server.*` 줄만 걷어내고 나머지는 그대로 둔다**(주석·모르는 키 보존, 계약 §7). 새 줄은
/// 파일 끝에 1번부터 다시 적는다 — 번호는 이름이 아니라 순서라서(§4.3) 그래도 되고, 그래야
/// 지운 자리의 구멍이 안 남는다.
pub fn withServers(allocator: std.mem.Allocator, original: []const u8, list: []const Server) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, original, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
            if (parseServerKey(key) != null) continue; // 옛 서버 줄은 안 옮긴다
        }
        try out.appendSlice(allocator, raw);
        try out.append(allocator, '\n');
    }
    // 끝에 빈 줄이 겹치지 않게 다듬는다(원문이 개행으로 끝나면 위 루프가 빈 조각을 하나 더 낸다).
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    if (out.items.len > 0) try out.append(allocator, '\n');

    for (list, 1..) |srv, n| {
        if (srv.name.len > 0) try out.print(allocator, "ssh.server.{d}.name = {s}\n", .{ n, srv.name });
        if (srv.host.len > 0) try out.print(allocator, "ssh.server.{d}.host = {s}\n", .{ n, srv.host });
        // **포트는 늘 적는다.** 기본값(22)이라 안 적으면 사용자가 22 를 골랐는지 안 골랐는지
        // 파일만 봐서는 모른다 — 화면이 유일한 입력 경로라 파일이 그 기록이다.
        try out.print(allocator, "ssh.server.{d}.port = {d}\n", .{ n, srv.port });
        if (srv.user.len > 0) try out.print(allocator, "ssh.server.{d}.user = {s}\n", .{ n, srv.user });
        if (srv.fingerprint.len > 0) try out.print(allocator, "ssh.server.{d}.fingerprint = {s}\n", .{ n, srv.fingerprint });
        // **적혀 있으면 그대로 지킨다.** 화면에는 아직 이 칸이 없지만(S10d 백로그) 파일에 손으로
        // 적은 값을 저장 한 번에 잃으면, 그 사용자는 목록이 왜 다시 안 뜨는지 모른다.
        if (srv.maru_path.len > 0) try out.print(allocator, "ssh.server.{d}.maru-path = {s}\n", .{ n, srv.maru_path });
    }
    return out.toOwnedSlice(allocator);
}

test "서버를 다시 적으면 주석과 모르는 키는 남고 번호는 1부터다" {
    const original =
        \\# 내 설정
        \\theme.preset = nord
        \\ssh.server.1.host = 옛것
        \\ssh.server.3.host = 지운것
        \\window.padding-x = 8
    ;
    const list = [_]Server{
        .{ .name = "집", .host = "10.0.0.5", .port = 2222, .user = "me", .fingerprint = "SHA256:a" },
        .{ .host = "b", .port = 22, .user = "you", .fingerprint = "SHA256:b" },
    };
    const out = try withServers(std.testing.allocator, original, &list);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 내 설정") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "window.padding-x = 8") != null); // 모르는 키
    try std.testing.expect(std.mem.indexOf(u8, out, "옛것") == null); // 옛 서버 줄은 사라진다
    try std.testing.expect(std.mem.indexOf(u8, out, "지운것") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh.server.1.host = 10.0.0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh.server.2.host = b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh.server.2.port = 22") != null); // 기본값도 적는다
    // 이름이 없으면 그 줄은 안 적는다(빈 값을 적으면 다음에 읽을 때 빈 이름이 된다).
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh.server.2.name") == null);
}

test "다시 적은 본문을 다시 읽으면 같은 목록이다" {
    // **왕복이 맞아야 한다** — 화면이 쓴 것을 화면이 다시 읽는다(파일이 단일 출처).
    const list = [_]Server{
        .{ .name = "집", .host = "h1", .port = 2222, .user = "me", .fingerprint = "SHA256:a" },
        .{ .host = "h2", .port = 22, .user = "you", .fingerprint = "SHA256:b" },
    };
    const text = try withServers(std.testing.allocator, "", &list);
    defer std.testing.allocator.free(text);
    var p = try parse(std.testing.allocator, text);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.server_count);
    try std.testing.expectEqualStrings("집", p.servers[0].name);
    try std.testing.expectEqual(@as(u16, 2222), p.servers[0].port);
    try std.testing.expectEqualStrings("h2", p.servers[1].host);
    try std.testing.expectEqualStrings("SHA256:b", p.servers[1].fingerprint);
}

test "마지막 서버를 지우면 그 줄이 통째로 사라진다" {
    const original = "ssh.server.1.host = a\nssh.server.1.port = 22\n";
    const out = try withServers(std.testing.allocator, original, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh.server") == null);
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

test "maru 경로는 읽고 다시 쓴다 — 저장 한 번에 안 잃는다" {
    // 화면에 아직 이 칸이 없어서(S10d 백로그) **손으로 적은 값**만 있는 상태다. 저장이 그것을
    // 지우면 사용자는 목록이 왜 다시 안 뜨는지 모른다.
    const text =
        \\ssh.server.1.host = 127.0.0.1
        \\ssh.server.1.user = me
        \\ssh.server.1.maru-path = /opt/maru/bin/maru
    ;
    var p = try parse(std.testing.allocator, text);
    defer p.deinit();
    try std.testing.expectEqualStrings("/opt/maru/bin/maru", p.servers[0].maru_path);

    const rewritten = try withServers(std.testing.allocator, "", p.servers[0..p.server_count]);
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ssh.server.1.maru-path = /opt/maru/bin/maru") != null);
}

test "maru 경로가 없으면 그 줄도 없다" {
    // 빈 값을 적으면 파일이 "비워 두라" 를 값으로 기록하는 셈이고, 다음 사람이 그것을 설정으로 읽는다.
    const text = "ssh.server.1.host = h\nssh.server.1.user = u\n";
    var p = try parse(std.testing.allocator, text);
    defer p.deinit();
    const rewritten = try withServers(std.testing.allocator, "", p.servers[0..p.server_count]);
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "maru-path") == null);
}
