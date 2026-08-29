//! config 파일 로더 — `key = value` 텍스트(Ghostty식, `#` 주석)를 raw `theme.Config`로 파싱한다.
//!
//! 설계 원칙:
//! - **순수 parser**(`parse`)와 I/O 래퍼(`loadFile`)를 분리해, 파싱 규칙은 파일시스템 없이
//!   단위 테스트로 고정한다(Linux CI 포함).
//! - **forgiving**: 알 수 없는 key, 잘못된 값, `=` 누락은 *치명적이지 않다*. 해당 필드는 기본값을
//!   쓰고 diagnostic(줄 번호 + 메시지)으로 남긴다. 한 줄 오타가 전체 설정을 깨지 않는다 — 사용자가
//!   "Maru가 망가졌다"고 느끼지 않게. 치명적 오류는 메모리 부족뿐이다.
//! - **값 검증 재사용**: 색은 `appearance.parseHexColor`, 크기 범위/family 비어있음 검사를 그대로
//!   써서, resolve가 다시 실패하지 않도록 *valid 아니면 default*만 Config에 담는다.
//! - **소유권**: 문자열 값(font.family)은 arena에 복사한다. resolve가 family 슬라이스를 빌리므로,
//!   Parsed(arena)는 그걸로 만든 ResolvedAppearance보다 오래 살아야 한다(호출자가 보관).

const std = @import("std");
const theme = @import("theme.zig");
const appearance = @import("appearance.zig");
const keybinding = @import("keybinding.zig");
const action_mod = @import("action.zig");
const terminal = @import("../terminal.zig");
const schema = @import("schema.zig");
const builtin = @import("builtin");
const path_shape = @import("../path_shape.zig"); // 입구 구분자 정규화(계약 §5)
const os_env = @import("../os_env.zig"); // 환경변수를 UTF-8 로 읽는다 — Windows 의 ANSI getenv 회피
const user_paths = @import("../user_paths.zig"); // config 자리 판정(OS 인자 순수 정책)

pub const LoadError = std.mem.Allocator.Error;

/// 비치명 진단 — 어느 줄에서 무엇이 무시됐는지. 메시지는 arena 소유. 공유 타입 단일 출처는 schema(loader→schema 단방향).
pub const Diagnostic = schema.Diag;

/// G1: 실행에 쓰는 resolved bool과 분리된 `session.keep-alive-after-quit`의 입력 출처다.
/// G2가 기본값 migration을 결정할 때만 소비하며 G1 자체는 파일을 쓰지 않는다.
pub const SessionKeepAliveProvenance = union(enum) {
    absent,
    explicit_valid: bool,
    explicit_invalid,
};

/// Config 파일을 읽은 결과. 기존 forgiving 동작은 유지하되, 안전한 기본값을 택한 이유를 잃지 않는다.
pub const FileProvenance = enum {
    missing,
    readable,
    unreadable,
    oversize,
};

const max_config_file_bytes = 1 << 20;

/// 파싱 결과. arena가 config의 문자열·키바인딩 slice·diagnostic 메시지를 소유한다 — config를 쓰는
/// 동안(특히 resolve가 family를, KeyBindingResolver가 keybindings를 빌리는 동안) 살아 있어야 한다.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    config: theme.Config,
    /// 사용자 정의 app 키바인딩(`keybind = <chord> = <action>`). chord 중복은 파싱 단계에서
    /// 걸러져(첫 줄 우선) 그대로 KeyBindingResolver.app_bindings로 넣어도 validate가 통과한다.
    keybindings: []const keybinding.AppBinding,
    /// 사용자가 끈 빌트인 기본 바인딩의 chord(`keybind = <chord> = unbind`). resolve가 이 chord에서
    /// 빌트인 테이블을 건너뛴다. keybindings와 같은 dedup 풀(chord별 한 줄)이라 둘이 겹치지 않는다.
    unbinds: []const keybinding.KeyChord,
    /// 사용자 정의 terminal 키바인딩(`keybind = <chord> = text:|esc:|ctrl:<payload>`) — 키에 셸로 보낼
    /// 바이트(매크로)를 묶는다. app 바인딩·unbind와 같은 dedup 풀이라 chord가 충돌하지 않아 그대로
    /// KeyBindingResolver.terminal_bindings로 넣어도 validate(app↔terminal 충돌 검사)가 통과한다.
    terminal_bindings: []const keybinding.TerminalBinding,
    /// 전역(OS) 단축키 바인딩(`keybind = global:<chord> = toggle_window|show_window`). OS 레벨에 등록되어
    /// 앱이 비활성이어도 동작한다 — in-app resolver를 안 거치고 별도 네임스페이스다(자기들끼리만 dedup).
    /// 플랫폼(Swift)이 이 목록을 읽어 RegisterEventHotKey로 등록한다(a2). chord→가상 키코드 매핑은 platform.
    global_bindings: []const keybinding.GlobalBinding,
    diagnostics: []const Diagnostic,
    session_keep_alive_provenance: SessionKeepAliveProvenance,
    file_provenance: FileProvenance,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    /// 파싱된 키바인딩으로 resolver를 만든다(app 바인딩 + unbind + terminal 매크로).
    pub fn keyBindingResolver(self: Parsed) keybinding.KeyBindingResolver {
        return .{
            .app_bindings = self.keybindings,
            .terminal_bindings = self.terminal_bindings,
            .unbinds = self.unbinds,
        };
    }
};

// font.* 수치 범위 const는 스키마-주도 이주(CS-1/CS-2) 후 theme.zig의 Meta.range가 직접 참조한다(단일 출처는
// 여전히 theme.zig — appearance.resolveFont도 같은 const 공유, drift 없음). loader-local 별칭은 제거.

/// 키의 **OS 접미**(`shell.command.windows`). 이름은 Zig의 `std.Target.Os.Tag`가 아니라 사용자가 쓸 말이다 —
/// `macos`는 태그와 같고, 나머지도 흔히 쓰는 철자를 고른다. VS Code가 같은 문제(한 설정 파일을 여러 OS에서
/// 공유)를 `terminal.integrated.defaultProfile.windows`/`.osx`/`.linux`로 푸는 것과 같은 모양이다.
const os_suffixes = [_]struct { suffix: []const u8, tag: std.Target.Os.Tag }{
    .{ .suffix = ".windows", .tag = .windows },
    .{ .suffix = ".macos", .tag = .macos },
    // VS Code가 macOS를 `.osx`로 쓰고 우리 문서가 그것을 선례로 인용한다 — 그 철자를 그대로 적는 사용자가
    // 나온다. 안 받아들이면 `env.EDITOR.osx` 같은 줄이 **경고 없이** 이름의 일부로 먹힌다(코드 리뷰 지적).
    .{ .suffix = ".osx", .tag = .macos },
    .{ .suffix = ".linux", .tag = .linux },
};

/// 키에서 OS 접미를 떼어 낸다. `os`가 null이면 접미가 없는 **기본 키**다.
///
/// 모르는 이름(`shell.command.freebsd`)은 접미로 보지 않는다 — 그러면 기본 키 이름이 되어 "알 수 없는 키"
/// diagnostic이 뜬다. 조용히 무시하는 것보다 낫다: 오타(`.window`)가 조용히 먹히면 사용자는 설정이 반영된 줄 안다.
fn splitOsSuffix(key: []const u8) struct { base: []const u8, os: ?std.Target.Os.Tag } {
    for (os_suffixes) |s| {
        // `key.len > s.suffix.len` — `.windows`만 있는 줄은 기본 키가 비어 버리므로 접미로 보지 않는다.
        if (key.len > s.suffix.len and std.mem.endsWith(u8, key, s.suffix))
            return .{ .base = key[0 .. key.len - s.suffix.len], .os = s.tag };
    }
    return .{ .base = key, .os = null };
}

const unknown_key_message = "알 수 없는 key — 무시";

/// **다른 OS 줄의 키 이름만** 검증한다(값은 적용도, 검증도 하지 않는다).
///
/// 값을 검증하면 안 되는 이유: `shell.command.windows = C:\pwsh.exe`는 Windows에서 완벽히 유효한데
/// macOS에서 절대경로 검사에 걸려 **가짜 경고**가 뜬다. 반대로 키 이름은 OS와 무관하므로 검증해야 한다 —
/// 안 하면 `bogus.setting.macos`가 아무 경고 없이 지나가고, doc-vs-key 게이트(`tests/config_docs/keys.zig`)가
/// "알 수 없는 key" diagnostic 유무로 실재를 판정하므로 **없는 키를 실재로 보고**한다(코드 리뷰 지적).
///
/// 키 인식 규칙을 복제하지 않으려고 버리는 config에 실제로 적용해 보고 그 진단만 골라 온다 — 규칙이 한 곳
/// (`applyKey`)에 남는다.
fn validateForeignOsKey(
    os_tag: std.Target.Os.Tag,
    a: std.mem.Allocator,
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    base_key: []const u8,
) !void {
    var scratch_config: theme.Config = .{};
    var scratch_diags: std.ArrayList(Diagnostic) = .empty;
    var scratch_binds: std.ArrayList(keybinding.AppBinding) = .empty;
    var scratch_unbinds: std.ArrayList(keybinding.KeyChord) = .empty;
    var scratch_term: std.ArrayList(keybinding.TerminalBinding) = .empty;
    var scratch_global: std.ArrayList(keybinding.GlobalBinding) = .empty;
    var scratch_env: std.ArrayList([]const u8) = .empty;
    // 값은 형식 진단을 피하려고 빈 문자열을 준다 — 우리가 볼 것은 키 인식 결과뿐이다.
    try applyKey(os_tag, a, &scratch_config, &scratch_binds, &scratch_unbinds, &scratch_term, &scratch_global, &scratch_env, &scratch_diags, line_no, base_key, "");
    for (scratch_diags.items) |d| {
        if (std.mem.eql(u8, d.message, unknown_key_message)) try diags.append(a, d);
    }
}

/// 호스트 OS의 접미(`".windows"` 등). 지원 목록에 없는 OS면 null. **테스트가 호스트에 무관하게
/// 문자열을 만들려고 쓴다** — 제품 코드 소비자는 없다(있었던 `writeBackKey`는 제거됐다).
fn hostOsSuffix() ?[]const u8 {
    const host = @import("builtin").os.tag;
    for (os_suffixes) |s| if (s.tag == host) return s.suffix;
    return null;
}

/// config 텍스트를 raw Config로 파싱한다(파일시스템 무관, 순수). 알 수 없는 key/잘못된 값은
/// 기본값 유지 + diagnostic. OOM만 에러.
///
/// **기본 키와 현재 호스트 OS 접미 키는 같은 파일 순서로 적용된다.** 다른 OS 접미가 붙은 줄은 값에는
/// 적용하지 않되 base key가 실재하는지는 검증한다. 따라서 모든 적용 가능한 줄에서 마지막 occurrence가
/// resolved 값을 소유하고 `env.<KEY>` 누적이나 keybinding 목록도 원래 파일 순서를 보존한다.
/// 호스트 OS 로 `parseFor` 를 부르는 얇은 래퍼. 프로덕션 호출자가 그대로 쓴다.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) LoadError!Parsed {
    return parseFor(@import("builtin").os.tag, allocator, source);
}

/// `parse` 의 **OS 인자 버전**. 경로 값 정규화가 호스트마다 갈리는데 저장소에 Windows CI 러너가 없다 —
/// 그 갈래를 인자로 받아야 macOS·Linux CI 에서도 두 쪽이 다 돈다(계약 §5, verification-matrix).
pub fn parseFor(os_tag: std.Target.Os.Tag, allocator: std.mem.Allocator, source: []const u8) LoadError!Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config: theme.Config = .{};
    var diags: std.ArrayList(Diagnostic) = .empty;
    var binds: std.ArrayList(keybinding.AppBinding) = .empty;
    var unbinds: std.ArrayList(keybinding.KeyChord) = .empty;
    var term_binds: std.ArrayList(keybinding.TerminalBinding) = .empty;
    var global_binds: std.ArrayList(keybinding.GlobalBinding) = .empty;
    var env_overrides: std.ArrayList([]const u8) = .empty; // env.<KEY> 줄 누적(각 "KEY=VALUE", arena 소유)
    var session_keep_alive_provenance: SessionKeepAliveProvenance = .absent;

    const host_os = @import("builtin").os.tag;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue; // 빈 줄 / 주석

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try diags.append(a, .{ .line = line_no, .message = "'=' 없음 — `key = value` 형식이어야 한다" });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);

        // OS 접미를 떼고 **그 자리에서** 적용한다. 다른 OS 줄은 값을 적용하지 않지만 **키 이름은 검증한다** —
        // 안 그러면 `bogus.setting.macos`가 아무 경고 없이 지나가 doc-vs-key 게이트(tests/config_docs)가
        // "없는 키를 실재"로 보고한다(코드 리뷰에서 실측).
        const split = splitOsSuffix(key);
        if (split.os) |os| if (os != host_os) {
            try validateForeignOsKey(os_tag, a, &diags, line_no, split.base);
            continue;
        };

        // applyKey와 같은 선택 경로 안에서 관측한다. 별도 source scan을 두면 OS suffix/중복 규칙이
        // resolved Config와 갈라질 수 있으므로, 실제 적용 직전의 마지막 occurrence만 갱신한다.
        if (std.mem.eql(u8, split.base, "session.keep-alive-after-quit")) {
            session_keep_alive_provenance = if (schema.parseBool(value)) |parsed|
                .{ .explicit_valid = parsed }
            else
                .explicit_invalid;
        }

        try applyKey(os_tag, a, &config, &binds, &unbinds, &term_binds, &global_binds, &env_overrides, &diags, line_no, split.base, value);
    }

    config.env = try env_overrides.toOwnedSlice(a); // 누적한 env.<KEY>를 Config로(arena 소유)

    return .{
        .arena = arena,
        .config = config,
        .keybindings = try binds.toOwnedSlice(a),
        .unbinds = try unbinds.toOwnedSlice(a),
        .terminal_bindings = try term_binds.toOwnedSlice(a),
        .global_bindings = try global_binds.toOwnedSlice(a),
        .diagnostics = try diags.toOwnedSlice(a),
        .session_keep_alive_provenance = session_keep_alive_provenance,
        .file_provenance = .readable,
    };
}

/// `workspace.root` **형식** 검증(순수·env 비의존): 절대경로 또는 `~`/`~/…`면 true. 상대경로·`~user`(다른 사용자)·
/// 빈 값은 false. 파일 파싱(applyKey)과 세팅 GUI 커밋(app_session `setWorkspaceRoot`)이 공유해 GUI·파일 드리프트를
/// 막는다(docs/config-gui.md §1·§6.6a). `~` 확장·존재 검증은 형식이 아니라 env/FS라 spawn 시점이 한다.
pub fn isValidWorkspaceRoot(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    const is_tilde = std.mem.eql(u8, trimmed, "~") or std.mem.startsWith(u8, trimmed, "~/");
    return is_tilde or std.fs.path.isAbsolute(trimmed);
}

fn applyKey(
    os_tag: std.Target.Os.Tag,
    a: std.mem.Allocator,
    config: *theme.Config,
    binds: *std.ArrayList(keybinding.AppBinding),
    unbinds: *std.ArrayList(keybinding.KeyChord),
    term_binds: *std.ArrayList(keybinding.TerminalBinding),
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    env_overrides: *std.ArrayList([]const u8),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    key: []const u8,
    value: []const u8,
) LoadError!void {
    if (std.mem.eql(u8, key, "keybind")) {
        return applyKeybind(a, binds, unbinds, term_binds, global_binds, diags, line_no, value);
    }
    if (std.mem.startsWith(u8, key, "env.")) {
        // env.<KEY> = value → 환경변수 주입(부모 상속 위에 upsert). KEY는 "env." 뒤 전체(빈 KEY는 무시).
        // 값은 양끝만 trim(loader 공통) — 내부 공백 보존. 여러 줄 누적, 같은 KEY 중복이면 spawn 시 last-wins.
        const name = key["env.".len..];
        if (name.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "env.<KEY>의 KEY가 비어 있음 — 무시" });
            return;
        }
        // "KEY=VALUE"로 합쳐 arena에 둔다(EnvStorage가 이 형식을 그대로 upsert). value가 비어도 유효(빈 값).
        try env_overrides.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, value }));
        return;
    }
    // shell.command는 스키마-주도로 이주(CS-2) — 아래 schema.tryParse가 처리. shell.args만 특수(공백-토큰 리스트).
    if (std.mem.eql(u8, key, "shell.args")) {
        // 공백으로 토큰 분리해 argv로(따옴표 미지원 — 셸 플래그는 단순). 빈 값이면 인자 없음(&.{}). 줄 여러 번이면 마지막이 이김.
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
        while (it.next()) |tok| try list.append(a, try a.dupe(u8, tok));
        config.shell.args = try list.toOwnedSlice(a);
        return;
    }
    // 스키마-주도 스칼라(CS-1+CS-2: font.*·theme 색·cursor.*·input.*·quick-terminal.*·sidebar.*·notifications.*·
    // scrollback.*·bell.*·shell-integration.*·workspace.{tab,split}-inherit·shell.command). 매칭되면 파싱·적용하고 끝.
    // 미매칭이면 false → 아래 if-else(특수 5종 + 최상위 스칼라)로 폴백. 단일 출처: docs/config-schema.md.
    if (try schema.tryParseFor(os_tag, a, config, key, value, diags, line_no)) return;
    if (std.mem.eql(u8, key, "theme.preset")) {
        // 이름 붙은 컬러 테마(프리셋). config.theme를 통째로 그 색 세트로 깐다(theme.presetColors가 단일 출처).
        // 개별 theme.* 키가 이 줄 *뒤에* 오면 그 색만 override한다(loader 순차 적용 — 나중 줄 우선). 프리셋 색은
        // 정적 리터럴이라 arena dupe 불필요. 알 수 없는 값은 forgiving(기본 maru 유지 + diagnostic).
        const preset = parseThemePreset(value) orelse {
            try diags.append(a, .{ .line = line_no, .message = "theme.preset은 " ++ theme.preset_names_joined ++ " — 기본값 유지" });
            return;
        };
        config.theme = theme.presetColors(preset);
        // theme.background/foreground/cursor/selection은 스키마-주도로 이주(CS-1/CS-2). palette.N만 특수(인덱스).
    } else if (std.mem.startsWith(u8, key, "theme.syntax.")) {
        // 구문 색 역할별 override: theme.syntax.<역할> = #RRGGBB(native-editor-ui.md §9.0). nullable 색이라
        // 스키마-주도에서 빠진다(cursor.color와 같은 이유) — 색 검증·arena dupe·진단은 dupValidColor 단일 출처.
        // 모르는 역할 이름·틀린 색은 forgiving(diagnostic + 기존 값 유지) — 팔레트와 같은 규율이다.
        const role = theme.parseSyntaxRole(key["theme.syntax.".len..]) orelse {
            try diags.append(a, .{ .line = line_no, .message = "theme.syntax.<역할>의 역할 이름을 모른다 — 무시" });
            return;
        };
        const validated = try dupValidColor(a, diags, line_no, key, value, "");
        if (validated.len != 0) config.theme.syntax[@intFromEnum(role)] = validated;
    } else if (std.mem.startsWith(u8, key, "theme.palette.")) {
        // ANSI 16색 override: theme.palette.0~.15 = #RRGGBB. suffix를 u8로 파싱해 0~15 범위 검사. 인덱스가 비정수·
        // 범위 밖이면 forgiving(diagnostic + 무시), 색은 dupValidColor가 검증(틀린 색도 forgiving). OSC4가 없을 때의
        // base라 per-core OSC4 표가 아니라 config에 둔다(렌더 폴백이 OSC4 → config → xterm256 우선순위로 쓴다).
        const suffix = key["theme.palette.".len..];
        const idx = std.fmt.parseInt(u8, suffix, 10) catch {
            try diags.append(a, .{ .line = line_no, .message = "theme.palette.N의 N은 0~15 정수여야 함 — 무시" });
            return;
        };
        if (idx > 15) {
            try diags.append(a, .{ .line = line_no, .message = "theme.palette.N의 N은 0~15 범위 — 무시" });
            return;
        }
        // 색 검증·arena dupe·diagnostic은 dupValidColor 재사용(단일 출처). 슬롯은 ?[]const u8라 sentinel ""을
        // current로 넘긴다 — 틀린 색이면 dupValidColor가 ""(diagnostic 후)를 돌려주므로 그때만 슬롯을 안 건드려
        // 기존(보통 null) 값을 유지한다(forgiving). 유효하면 dupe된 색으로 갱신.
        const validated = try dupValidColor(a, diags, line_no, key, value, "");
        if (validated.len != 0) config.theme.palette[idx] = validated;
        // cursor.*·input.*·quick-terminal.*(CS-1/CS-2)와 text.*·theme.bold-is-bright·window.padding-{4방}·
        // term(최상위 스칼라, CS-2b)은 스키마-주도로 이주 — 위 schema.tryParse가 처리. padding-x/y(alias)만 여기 남는다.
    } else if (std.mem.eql(u8, key, "window.padding-x")) {
        // x는 left+right 동시 alias(대칭 좌우 여백). 한 번 파싱해 두 필드에 같은 값. 명시 left/right와 혼용 시
        // loader가 줄을 순차 적용하므로 "마지막 줄 우선"이 자동(padding-x=10 다음 padding-left=20 → left=20,right=10).
        const v = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-x는 0~256 정수 — 기본값 유지" });
            return;
        };
        config.window_padding_left = v;
        config.window_padding_right = v;
    } else if (std.mem.eql(u8, key, "window.padding-y")) {
        // y는 top+bottom 동시 alias(대칭 상하 여백). x와 동일하게 순차 적용 → 마지막 줄 우선.
        const v = parseUintMax(value, 256) orelse {
            try diags.append(a, .{ .line = line_no, .message = "window.padding-y는 0~256 정수 — 기본값 유지" });
            return;
        };
        config.window_padding_top = v;
        config.window_padding_bottom = v;
        // term·shell-integration.ssh는 스키마-주도로 이주(CS-2b/CS-2) — 위 schema.tryParse가 처리.
    } else if (std.mem.eql(u8, key, "workspace.root")) {
        // 시작 창·새 탭이 열리는 디렉터리. raw 문자열만 보관한다 — `~` 확장·존재 검증은 $HOME이 필요해
        // platform layer(spawn 시점)가 한다(loader는 순수 파서라 env에 의존하지 않는다 — Linux CI). 경로는
        // 내부 공백을 가질 수 있어 value는 양끝만 trim(term과 동일 규칙). 빈 값이면 기본(상속 cwd) 유지.
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try diags.append(a, .{ .line = line_no, .message = "workspace.root가 비어 있음 — 기본값(상속 cwd) 유지" });
            return;
        }
        // 절대경로 또는 `~`/`~/…`만 받는다 — 상대경로·`~user`(다른 사용자)는 spawn 시 어차피 무시되므로 여기서
        // 미리 거른다(forgiving+diagnostic). 형식 규칙은 GUI 커밋과 공유하는 isValidWorkspaceRoot 단일 헬퍼로 — 드리프트
        // 방지. $HOME 확장은 platform layer가 하므로 loader는 형식만 본다(순수 파서 — env 비의존).
        // **정규화를 먼저 하고 그 결과를 검사한다.** 계약 §5 규칙 2 가 "정규화 이전에 역슬래시로 거르던
        // 가드는 정규화 이후에도 같은 것을 막도록 다시 쓴다" 고 못 박은 자리다. 순서를 뒤집으면 Windows
        // 사용자가 자연스럽게 적는 `~\projects` 가 **거부된다** — `isValidWorkspaceRoot` 는 `~` 나 `~/`
        // 접두만 보고, `~\projects` 는 어느 호스트에서도 절대경로가 아니다. `~/projects` 와 `C:\proj` 는
        // 되는데 그 하나만 안 되는 것은 사용자가 이유를 알 수 없다.
        //
        // 경로 값은 입구에서 구분자를 정규화한다(§5 규칙 1) — 그대로 두면 L2 가 `/` 로 이어 붙인 결과와
        // 섞여 `C:\proj/docs` 가 된다. 스키마-주도 경로 필드(`Meta.isPath`)와 **같은 규칙**을 쓴다.
        // POSIX 호스트에서는 무동작이다.
        const normalized = try path_shape.normalizeSeparatorsFor(os_tag, a, trimmed);
        if (!isValidWorkspaceRoot(normalized)) {
            try diags.append(a, .{ .line = line_no, .message = "workspace.root는 절대경로 또는 ~/… — 무시(기본값 유지)" });
            return;
        }
        config.workspace.root = normalized;
        // workspace.{tab,split}-inherit-cwd는 스키마-주도로 이주(CS-2) — 위 schema.tryParse가 처리.
    } else if (std.mem.eql(u8, key, "cursor.color") or std.mem.eql(u8, key, "cursor.text")) {
        // 커서 색 override(opt-in). nullable이라 스키마-주도에서 빠져 여기서 다룬다(palette와 동형). 색 검증·
        // arena dupe·diagnostic은 dupValidColor 재사용(단일 출처). 슬롯은 ?[]const u8라 sentinel ""을 current로
        // 넘긴다 — 틀린 색이면 dupValidColor가 ""를 돌려주므로 그때만 슬롯을 안 건드려 기존(보통 null) 값을
        // 유지한다(forgiving). 유효하면 dupe된 색으로 갱신. color=커서 칸, text=커서 위 반전 glyph.
        const validated = try dupValidColor(a, diags, line_no, key, value, "");
        if (validated.len != 0) {
            if (std.mem.eql(u8, key, "cursor.color")) {
                config.cursor.color = validated;
            } else {
                config.cursor.text = validated;
            }
        }
    } else {
        try diags.append(a, .{ .line = line_no, .message = unknown_key_message });
    }
}

// enum/bool 파싱 헬퍼(parseCursorShape·parsePageKeys·parseShiftEnter·parseImeEnter·parseQuickTerminal*·
// parseAmbiguousWidth·parseBool)는 스키마-주도 이주(CS-1/CS-2/CS-2b)로 schema의 타입 분기 파싱이 대신한다 — 전부 제거.
// loader 명시 핸들러에 남은 파싱은 parseThemePreset(theme.preset)·parseUintMax(padding alias)·dupValidColor(palette)뿐.

/// `keybind = <chord> = <rhs>` 한 줄을 처리한다. chord에 `global:` 접두사가 있으면 전역(OS) 단축키이고
/// rhs는 GlobalAction(toggle_window/show_window)이다(별도 네임스페이스 — 자기들끼리만 dedup). 접두사가
/// 없으면 in-app 바인딩이고 rhs는 셋 중 하나다:
///   - `unbind` → 그 chord의 빌트인 기본을 끈다(unbinds).
///   - `text:`/`esc:`/`ctrl:` 매크로 → 키에 셸로 보낼 바이트를 묶는다(terminal_bindings).
///   - 그 외 → app action(parseAction → keybindings).
/// chord는 KeyChord.parse(사람 표기 — 예 `Cmd+T`). 오류는 diagnostic(forgiving). 같은 chord가 이미
/// (bind/unbind/terminal 어디든) 있으면 첫 줄을 살리고 무시한다 — chord별 한 줄이라 resolver가 모순 없이
/// 본다(app 우선 → terminal → unbind로 빌트인 끄기). 세 풀을 한 dedup로 묶어 app↔terminal 충돌도 막는다.
fn applyKeybind(
    a: std.mem.Allocator,
    binds: *std.ArrayList(keybinding.AppBinding),
    unbinds: *std.ArrayList(keybinding.KeyChord),
    term_binds: *std.ArrayList(keybinding.TerminalBinding),
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    value: []const u8,
) LoadError!void {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse {
        try diags.append(a, .{ .line = line_no, .message = "keybind는 `<조합> = <action>` 형식이어야 한다" });
        return;
    };
    const chord_str = std.mem.trim(u8, value[0..eq], &std.ascii.whitespace);
    const rhs = std.mem.trim(u8, value[eq + 1 ..], &std.ascii.whitespace);

    // `global:` 접두사 → 전역(OS) 단축키. 접두사를 떼고 chord를 파싱한 뒤 GlobalAction으로 처리한다.
    if (std.mem.startsWith(u8, chord_str, "global:")) {
        return applyGlobalKeybind(a, global_binds, diags, line_no, std.mem.trim(u8, chord_str["global:".len..], &std.ascii.whitespace), rhs);
    }

    const chord = keybinding.KeyChord.parse(chord_str) catch {
        try diags.append(a, .{ .line = line_no, .message = "키 조합을 못 읽음(예: Cmd+T, Ctrl+Cmd+1) — 무시" });
        return;
    };
    // chord는 bind/unbind/terminal을 통틀어 한 번만(첫 줄 우선). 세 풀을 함께 검사해 같은 chord가
    // 갈라지지 않게 한다(app↔terminal 충돌도 여기서 막아 resolver.validate가 통과한다).
    if (chordAlreadyBound(binds.items, unbinds.items, term_binds.items, chord)) {
        try diags.append(a, .{ .line = line_no, .message = "이미 바인딩된 키 조합 — 무시(첫 줄 우선)" });
        return;
    }

    // rhs가 `unbind`면 그 chord의 빌트인 기본을 끈다(app action 아님 — 별도 목록).
    if (std.mem.eql(u8, rhs, "unbind")) {
        try unbinds.append(a, chord);
        return;
    }

    // rhs가 터미널 매크로(text:/esc:/ctrl:)면 셸로 보낼 바이트를 묶는다. `.invalid`(접두사인데 payload
    // 오류)는 parseTerminalMacro가 이미 diagnostic을 남겼고, app action으로 재해석하지 않고 그 줄을 버린다.
    switch (try parseTerminalMacro(a, diags, line_no, rhs)) {
        .macro => |macro| {
            try term_binds.append(a, .{ .chord = chord, .input = macro });
            return;
        },
        .invalid => return,
        .not_macro => {}, // 접두사 아님 — 아래 app action으로
    }

    const act = action_mod.parseAction(rhs) orelse {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 action(unbind/text:/esc:/ctrl:/new_tab/close_tab/select_tab:N 등) — 무시" });
        return;
    };
    try binds.append(a, .{ .chord = chord, .action = act });
}

/// `keybind = global:<chord> = <global action>` 한 줄을 GlobalBinding으로. chord_str은 `global:` 접두사를
/// 이미 뗀 상태다. action은 toggle_window/show_window만. 전역 chord끼리만 dedup한다(in-app과 별도
/// 네임스페이스 — OS 핫키라 같은 조합이 in-app에도 있을 수 있고 충돌이 아니다). 오류는 diagnostic(forgiving).
fn applyGlobalKeybind(
    a: std.mem.Allocator,
    global_binds: *std.ArrayList(keybinding.GlobalBinding),
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    chord_str: []const u8,
    rhs: []const u8,
) LoadError!void {
    const chord = keybinding.KeyChord.parse(chord_str) catch {
        try diags.append(a, .{ .line = line_no, .message = "전역 키 조합을 못 읽음(예: global:Cmd+Opt+Space) — 무시" });
        return;
    };
    const act = action_mod.parseGlobalAction(rhs) orelse {
        try diags.append(a, .{ .line = line_no, .message = "알 수 없는 전역 action(toggle_window/show_window) — 무시" });
        return;
    };
    for (global_binds.items) |existing| {
        if (existing.chord.eql(chord)) {
            try diags.append(a, .{ .line = line_no, .message = "이미 등록된 전역 키 조합 — 무시(첫 줄 우선)" });
            return;
        }
    }
    try global_binds.append(a, .{ .chord = chord, .action = act });
}

/// chord가 이미 묶였는가(bind/unbind/terminal 세 풀 통틀어). keybind dedup의 단일 출처 — 셋 중 한 곳에만
/// 들어가게 해 app↔terminal 충돌·중복을 파싱 단계에서 막는다(첫 줄 우선). 순수 함수.
fn chordAlreadyBound(
    binds: []const keybinding.AppBinding,
    unbinds: []const keybinding.KeyChord,
    term_binds: []const keybinding.TerminalBinding,
    chord: keybinding.KeyChord,
) bool {
    for (binds) |b| if (b.chord.eql(chord)) return true;
    for (unbinds) |c| if (c.eql(chord)) return true;
    for (term_binds) |b| if (b.chord.eql(chord)) return true;
    return false;
}

/// 터미널 매크로 접두사 종류. 접두사 리터럴의 단일 출처는 macroPrefix.
const MacroKind = enum { text, esc, ctrl };

/// rhs의 매크로 접두사를 판정해 종류 + payload(접두사 뒤)를 돌려준다 — **접두사 목록의 단일 출처**. isMacroRhs(접두사
/// 여부)와 parseTerminalMacro(payload 파싱)가 둘 다 이걸 거쳐 접두사 리터럴(text:/esc:/ctrl:)이 한 곳에만 있다.
fn macroPrefix(rhs: []const u8) ?struct { kind: MacroKind, payload: []const u8 } {
    if (std.mem.startsWith(u8, rhs, "text:")) return .{ .kind = .text, .payload = rhs["text:".len..] };
    if (std.mem.startsWith(u8, rhs, "esc:")) return .{ .kind = .esc, .payload = rhs["esc:".len..] };
    if (std.mem.startsWith(u8, rhs, "ctrl:")) return .{ .kind = .ctrl, .payload = rhs["ctrl:".len..] };
    return null;
}

/// rhs가 터미널 매크로 접두사로 시작하나 — write-back 패스가 매크로 줄만 골라 app action 줄을 안 건드리게 한다.
/// macroPrefix(단일 출처)에서 파생.
pub fn isMacroRhs(rhs: []const u8) bool {
    return macroPrefix(rhs) != null;
}

/// 세팅 GUI 매크로 행 커밋용 — rhs(`text:`/`esc:`/`ctrl:`)를 파싱해 `TerminalInputMacro`로(diags 없이; 접두사 아님·
/// payload 오류면 null). payload(text/esc)는 arena `a`가 소유한다(parseTerminalMacro와 동일). 단일 출처: parseTerminalMacro.
pub fn parseMacroRhs(a: std.mem.Allocator, rhs: []const u8) ?keybinding.TerminalInputMacro {
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(a);
    const parsed = parseTerminalMacro(a, &diags, 0, rhs) catch return null;
    return switch (parsed) {
        .macro => |m| m,
        else => null,
    };
}

/// parseTerminalMacro의 3-상태 결과 — 접두사 여부와 파싱 성공을 한 번에 표현해 호출자가 매크로 접두사
/// 목록을 다시 안 봐도 되게 한다(접두사 목록은 parseTerminalMacro 한 곳이 단일 출처).
const MacroParse = union(enum) {
    not_macro, // text:/esc:/ctrl: 접두사가 아님 — app action으로 시도하라.
    invalid, // 접두사인데 payload 오류(diagnostic 이미 남김) — 그 줄을 버려라(app action 재해석 금지).
    macro: keybinding.TerminalInputMacro,
};

/// 터미널 매크로 rhs를 파싱한다.
///   - `text:<문자열>`  → send_text(payload 그대로 셸로).
///   - `esc:<payload>`  → send_escape_sequence("\x1b" + payload — ESC를 앞에 붙인 시퀀스. 예 `esc:[2J`).
///   - `ctrl:<글자한자>` → send_control(그 글자의 C0 컨트롤 바이트. 예 `ctrl:[` = ESC).
/// payload(text/esc)는 arena에 복사해 binding이 소유한다(Parsed가 사는 동안 유효). 빈 payload·여러 글자
/// ctrl·C0 매핑 없는 ctrl은 diagnostic + `.invalid`(forgiving). 접두사가 아니면 `.not_macro`.
fn parseTerminalMacro(
    a: std.mem.Allocator,
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    rhs: []const u8,
) LoadError!MacroParse {
    const mp = macroPrefix(rhs) orelse return .not_macro;
    switch (mp.kind) {
        .text => {
            if (mp.payload.len == 0) {
                try diags.append(a, .{ .line = line_no, .message = "text: 뒤 내용이 비어 있음 — 무시" });
                return .invalid;
            }
            return .{ .macro = .{ .send_text = try a.dupe(u8, mp.payload) } };
        },
        .esc => {
            if (mp.payload.len == 0) {
                try diags.append(a, .{ .line = line_no, .message = "esc: 뒤 내용이 비어 있음 — 무시" });
                return .invalid;
            }
            // ESC(0x1b)를 앞에 붙인 시퀀스. 예 `esc:[2J` → "\x1b[2J"(화면 지우기).
            const seq = try std.fmt.allocPrint(a, "\x1b{s}", .{mp.payload});
            return .{ .macro = .{ .send_escape_sequence = seq } };
        },
        .ctrl => {
            const payload = mp.payload;
            // 정확히 한 codepoint여야 한다(Ctrl+<글자>). UTF-8 한 글자 길이와 payload 길이가 같아야 통과.
            const seq_len = std.unicode.utf8ByteSequenceLength(if (payload.len > 0) payload[0] else 0) catch {
                try diags.append(a, .{ .line = line_no, .message = "ctrl: 뒤는 글자 한 자여야 함 — 무시" });
                return .invalid;
            };
            if (payload.len != seq_len) {
                try diags.append(a, .{ .line = line_no, .message = "ctrl: 뒤는 글자 한 자여야 함 — 무시" });
                return .invalid;
            }
            const cp = std.unicode.utf8Decode(payload) catch {
                try diags.append(a, .{ .line = line_no, .message = "ctrl: 글자를 못 읽음 — 무시" });
                return .invalid;
            };
            // C0 컨트롤로 매핑되는 글자만(@A-Z[\]^_ space ?). 로드 시 걸러야 키 누를 때 resolve가 안 터진다.
            _ = terminal.input.controlByte(cp) catch {
                try diags.append(a, .{ .line = line_no, .message = "ctrl: 글자가 컨트롤 문자로 매핑 안 됨(@,A~Z,[,\\,],^,_,Space,? 가능) — 무시" });
                return .invalid;
            };
            return .{ .macro = .{ .send_control = cp } };
        },
    }
}

/// 색 문자열을 appearance.parseHexColor로 검증(값 의미 단일 출처)한 뒤 arena에 복사해 돌려준다.
/// 형식이 틀리면 diagnostic + 기존(기본) 값을 유지한다.
fn dupValidColor(
    a: std.mem.Allocator,
    diags: *std.ArrayList(Diagnostic),
    line_no: usize,
    key: []const u8,
    value: []const u8,
    current: []const u8,
) LoadError![]const u8 {
    _ = key;
    _ = appearance.parseHexColor(value) catch {
        try diags.append(a, .{ .line = line_no, .message = "색이 #RRGGBB 형식이 아님 — 기본값 유지" });
        return current;
    };
    return try a.dupe(u8, value);
}

// parseCursorShape는 cursor.shape가 스키마-주도로 이주(CS-1)해 schema의 enum 파싱이 대신한다 — 제거.

fn parseThemePreset(value: []const u8) ?theme.ThemePreset {
    // 제너릭 reflection 파서에 위임(theme.parsePreset = dash→underscore + stringToEnum). enum만 늘리면 자동 인식 —
    // 프리셋 추가 시 이 함수와 아래 diagnostic 문구(theme.preset_names_joined)는 손대지 않는다(수동 나열 drift 제거).
    return theme.parsePreset(value);
}

/// 음이 아닌 정수를 [0, max]로 파싱한다 — 음수/비정수/max 초과는 null(기본값 유지). 0은 유효.
/// padding(max=256: grid를 0으로 만드는 비정상 큰 값 가드)·scrollback(max=100000: 행당 ptr 슬롯 ring
/// 메모리 폭주 가드)이 같은 forgiving 패턴을 공유한다.
fn parseUintMax(value: []const u8, max: u32) ?u32 {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch return null;
    return if (n <= max) n else null;
}

// parseFloatInRange는 스키마-주도 이주(CS-1/CS-2)로 schema.parseFloatRange가 대신한다 — 제거(loader엔 더 이상 f32 키 없음).

/// config 한 줄을 갱신할 키·값 쌍. value는 이미 직렬화된 토큰(`true`/`false` 등). 단일 출처는 schema.KeyValue.
pub const KeyValue = schema.KeyValue;

/// 원본 config 텍스트를 줄 단위로 순회해 `updates`의 키를 `key = value`로 **in-place 교체**한다(같은 키가 여러
/// 번 나오면 **모든** 줄을 교체 — parse가 last-wins라 일부만 바꾸면 옛 값이 reload 시 이긴다). 주석·빈 줄·미파싱
/// 키·갱신 대상이 아닌 줄은 그대로 보존하고, 원본에 없던 키만 파일 끝에 append한다.
/// 앱(view options 토글)→config 부분 갱신용. 통째 재작성은 사용자 주석·미파싱 키를 전부 잃으므로 택하지
/// 않았다([document-basis-and-decision]: 보존을 우선). 교체 줄은 `key = value`로 정규화하므로 그 줄에
/// 달려 있던 인라인 주석/비표준 공백은 사라진다(round-trip 테스트가 보존 범위를 못박는다). 반환은 owned.
pub fn updateConfigText(allocator: std.mem.Allocator, original: []const u8, updates: []const KeyValue) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const applied = try allocator.alloc(bool, updates.len);
    defer allocator.free(applied);
    @memset(applied, false);

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        var replaced = false;
        if (trimmed.len > 0 and trimmed[0] != '#') {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
                for (updates, 0..) |u, i| {
                    if (std.mem.eql(u8, k, u.key)) {
                        // **모든** occurrence를 새 값으로 교체한다(첫 줄만 바꾸면 안 된다) — parse()는 같은 키가 여러
                        // 번이면 last-wins라, 뒤 중복 줄을 stale로 남기면 reload 시 그 옛 값이 이겨 토글이 되돌아간다.
                        try out.appendSlice(allocator, u.key);
                        try out.appendSlice(allocator, " = ");
                        try out.appendSlice(allocator, u.value);
                        applied[i] = true; // 발견됨 표시(끝에 append 안 하게). guard 없이 매 occurrence를 교체한다.
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) try out.appendSlice(allocator, raw_line);
    }
    // 원본에 없던 키는 끝에 append(직전 줄이 개행으로 안 끝나면 개행 먼저).
    for (updates, 0..) |u, i| {
        if (applied[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, u.key);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, u.value);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// keybind recorder write-back 한 건 — action(키)을 새 chord 표기로 다시 묶는다. action은 command_catalog 키(정적
/// 리터럴, 예: `"new_term"`), chord는 `KeyChord.toConfigString` 결과(예: `"Cmd+E"`).
pub const KeybindRebind = struct { action: []const u8, chord: []const u8 };

/// 파싱된 keybind 줄 — chord(좌측)·rhs(둘째 `=` 뒤 끝까지). `global:` 접두는 떼지 않는다(호출자가 chord로 판단·표기).
const KeybindLine = struct { chord: []const u8, rhs: []const u8 };

/// `keybind = <chord> = <rhs>` 줄을 파싱한다 — keybind write-back 패스 7개의 **공유 토크나이저(단일 출처)**. 입력은
/// 이미 trim된 줄(`std.mem.trim`된 raw_line). 비어 있거나 주석(`#`)·key가 `keybind`가 아니거나 둘째 `=`가 없으면 null.
/// chord/rhs는 각각 trim하고, rhs는 **끝까지**(매크로 `text:a=b`의 내부 `=`도 통째 rhs). 각 패스는 이 결과로 자기
/// 매칭(action/chord/`global:`/`isMacroRhs`)과 교체/삭제/append만 한다 — 줄 문법은 여기 한 곳. 같은 prologue를 7번
/// 복붙하던 것을 단일 출처로(project-rules "포맷별로 따로 두지 말고 한 출처 참조", [prefer-policy-over-codebase-mimicry]).
fn parseKeybindLine(trimmed: []const u8) ?KeybindLine {
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq1 = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq1], &std.ascii.whitespace), "keybind")) return null;
    const rest = trimmed[eq1 + 1 ..];
    const eq2 = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    return .{
        .chord = std.mem.trim(u8, rest[0..eq2], &std.ascii.whitespace),
        .rhs = std.mem.trim(u8, rest[eq2 + 1 ..], &std.ascii.whitespace),
    };
}

/// keybind 줄(`keybind = <chord> = <action>`)을 **action 기준**으로 in-place 갱신한다 — updateConfigText의 keybind 짝.
/// keybind는 `key = value`가 아니라 줄마다 같은 `keybind` 키 + 두 번째 `=`로 chord와 action을 나눠서, key 기준
/// updateConfigText로는 다룰 수 없다(모든 keybind 줄이 한 키로 충돌). 그래서 전용 패스를 둔다: rhs(두 번째 `=` 뒤,
/// 끝까지)를 trim해 action과 비교, 매칭하면 그 줄을 `keybind = <새 chord> = <action>`으로 교체한다. 원본에 그 action
/// 줄이 없으면(빌트인 기본 바인딩 등) 끝에 append한다. **매크로 줄**(rhs가 `text:`/`esc:`/`ctrl:`, `=` 포함 가능)은
/// app action 키와 절대 안 겹치므로 자연히 스킵된다(rhs를 끝까지 잡아 비교하므로 `text:a=b`도 통째로 안 매칭). 주석·다른
/// 줄·미파싱 키는 보존(updateConfigText와 같은 규율 — [document-basis-and-decision]). 반환은 owned(`allocator`).
pub fn updateKeybindLines(allocator: std.mem.Allocator, original: []const u8, rebinds: []const KeybindRebind) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const applied = try allocator.alloc(bool, rebinds.len);
    defer allocator.free(applied);
    @memset(applied, false);

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var replaced = false;
        // 좌측 chord가 `global:`면 전역 줄이라 in-app 패스가 안 건드린다(섞임 방지 — 전역은 updateGlobalKeybindLines).
        // 매크로 줄(rhs `text:`/`esc:`/`ctrl:`)은 action 키와 안 겹쳐 자연히 스킵(rhs를 끝까지 잡아 비교).
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (!std.mem.startsWith(u8, kl.chord, "global:")) {
                for (rebinds, 0..) |rb, i| {
                    if (std.mem.eql(u8, rb.action, kl.rhs)) {
                        try out.appendSlice(allocator, "keybind = ");
                        try out.appendSlice(allocator, rb.chord);
                        try out.appendSlice(allocator, " = ");
                        try out.appendSlice(allocator, kl.rhs);
                        applied[i] = true; // 같은 action 줄이 여러 개면 모두 교체(parse last-wins라 stale 방지)
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) try out.appendSlice(allocator, raw_line);
    }
    // 원본에 없던 action(빌트인 기본 등)은 끝에 append.
    for (rebinds, 0..) |rb, i| {
        if (applied[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, "keybind = ");
        try out.appendSlice(allocator, rb.chord);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, rb.action);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// `keys`에 든 키의 **줄을 통째로 삭제**한다(env 변수 삭제 등 — override-only write-back의 "제거" 짝). updateConfigText는
/// 줄을 갱신/추가만 하고 삭제는 안 하므로(주석·미파싱 키 보존 우선), 명시적 제거는 이 전용 패스로 한다. 비-주석 줄의
/// `key`(첫 `=` 앞 trim)가 `keys` 중 하나와 같으면 그 줄을 출력에서 뺀다(같은 키 중복 줄도 전부 제거 — parse last-wins라
/// 일부만 남기면 옛 값이 reload 시 부활). 주석·다른 줄은 보존. 반환은 owned(`allocator`). serializeConfig가 갱신 패스
/// 뒤에 체이닝한다(삭제가 갱신보다 우선 — 같은 키를 갱신+삭제 둘 다면 결국 삭제).
pub fn removeConfigLines(allocator: std.mem.Allocator, original: []const u8, keys: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        var drop = false;
        if (trimmed.len > 0 and trimmed[0] != '#') {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
                for (keys) |key| if (std.mem.eql(u8, k, key)) {
                    drop = true;
                    break;
                };
            }
        }
        if (drop) continue; // 줄 삭제 — 그 줄과 그에 붙은 개행이 함께 사라진다(유지 줄만 아래에서 join).
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, raw_line);
    }
    return out.toOwnedSlice(allocator);
}

/// `keybind = <chord> = <action>` 줄을 **action 기준**으로 삭제한다(keybind unbind — 사용자 지정 단축키 제거).
/// keybind는 key가 모두 `keybind`라 removeConfigLines(key 기준)로는 특정 줄만 못 빼므로, updateKeybindLines처럼 두 번째
/// `=` 뒤 rhs(action)를 비교해 `actions`에 든 것만 줄째 제거한다. 매크로 줄(rhs `text:` 등)은 action 키와 안 겹쳐 보존.
/// 주석·다른 줄 보존. 반환은 owned. serializeConfig가 keybind 갱신 패스 뒤에 체이닝(제거 우선).
pub fn removeKeybindLines(allocator: std.mem.Allocator, original: []const u8, actions: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        var drop = false;
        // 좌측 chord가 `global:`면 전역 줄 — in-app 제거 패스가 안 건드린다(removeGlobalKeybindLines가 담당).
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (!std.mem.startsWith(u8, kl.chord, "global:")) {
                for (actions) |a| if (std.mem.eql(u8, a, kl.rhs)) {
                    drop = true;
                    break;
                };
            }
        }
        if (drop) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, raw_line);
    }
    return out.toOwnedSlice(allocator);
}

/// 터미널 매크로 write-back 한 건 — `chord`(KeyChord.toConfigString 결과, 예 `"Ctrl+G"`)에 `rhs`(매크로 표기,
/// 예 `"text:hello"`)를 묶는다. updateKeybindLines의 KeybindRebind(action 기준)와 달리 **chord 기준**(매크로는 한
/// chord에 하나).
pub const TerminalMacroWrite = struct { chord: []const u8, rhs: []const u8 };

/// 두 chord 표기가 **같은 chord**인가 — 파일에 손으로 쓴 비정규 표기(소문자 `ctrl+g`·수식키 순서 다름·`Alt`/`Option`
/// 별칭)도 정규 표기(toConfigString)와 매칭되게 **파싱 후 KeyChord.eql**로 비교한다(raw 바이트 eql은 비정규 표기를
/// 놓쳐 편집이 줄을 교체 못 하고 중복을 남긴다 — code-review max). 둘 중 하나라도 파싱 실패면 raw eql로 폴백.
fn chordStrEql(left: []const u8, want: []const u8) bool {
    const lc = keybinding.KeyChord.parse(left) catch return std.mem.eql(u8, left, want);
    const wc = keybinding.KeyChord.parse(want) catch return std.mem.eql(u8, left, want);
    return lc.eql(wc);
}

/// `keybind = <chord> = <rhs>`(rhs=매크로) 줄을 **chord 기준**으로 upsert한다 — updateKeybindLines(action 기준)의 짝.
/// 매크로는 한 chord에 하나라 좌측 chord로 매칭하고, 매칭 줄의 rhs가 매크로(`isMacroRhs`)일 때만 교체해 app action 줄을
/// 안 건드린다(액션 줄은 updateKeybindLines가 담당 — 두 패스가 같은 chord를 두고 안 싸운다). `global:` chord는 스킵
/// (전역은 별도). 원본에 그 chord 매크로 줄이 없으면 끝에 append. 주석·다른 줄 보존. 반환 owned(`allocator`).
pub fn updateTerminalMacroLines(allocator: std.mem.Allocator, original: []const u8, macros: []const TerminalMacroWrite) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const applied = try allocator.alloc(bool, macros.len);
    defer allocator.free(applied);
    @memset(applied, false);

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var replaced = false;
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (!std.mem.startsWith(u8, kl.chord, "global:") and isMacroRhs(kl.rhs)) {
                for (macros, 0..) |m, i| {
                    if (chordStrEql(kl.chord, m.chord)) {
                        try out.appendSlice(allocator, "keybind = ");
                        try out.appendSlice(allocator, m.chord);
                        try out.appendSlice(allocator, " = ");
                        try out.appendSlice(allocator, m.rhs);
                        applied[i] = true; // 같은 chord 매크로 줄이 여럿이면 모두 교체(last-wins stale 방지)
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) try out.appendSlice(allocator, raw_line);
    }
    for (macros, 0..) |m, i| {
        if (applied[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, "keybind = ");
        try out.appendSlice(allocator, m.chord);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, m.rhs);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// `keybind = <chord> = <매크로 rhs>` 줄을 **chord 기준**으로 삭제한다(매크로 제거). 좌측 chord가 `chords`에 있고 rhs가
/// 매크로(`isMacroRhs`)인 줄만 드롭해 app action 줄(rhs=action 키)은 보존한다. `global:`·주석·다른 줄 보존.
/// removeKeybindLines(action 기준)의 chord-기준 짝. serializeConfig가 갱신 패스 뒤에 체이닝(제거 우선). 반환 owned.
pub fn removeTerminalMacroLines(allocator: std.mem.Allocator, original: []const u8, chords: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        var drop = false;
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (!std.mem.startsWith(u8, kl.chord, "global:") and isMacroRhs(kl.rhs)) {
                for (chords) |c| if (chordStrEql(kl.chord, c)) {
                    drop = true;
                    break;
                };
            }
        }
        if (drop) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, raw_line);
    }
    return out.toOwnedSlice(allocator);
}

/// `keybind = <chord> = unbind` 줄을 **chord(좌측) 기준**으로 제거한다 — 그 chord를 다시 **사용자 바인딩**으로 묶을 때
/// 모순되는 옛 unbind 지시어를 뺀다(stale unbind 정리). rhs가 정확히 `unbind`인 줄만, 좌측 chord가 `chords`에 있는 것만
/// 드롭한다. `global:`·매크로(rhs `text:`/`esc:`)·다른 keybind 줄·주석은 보존. removeKeybindLines(action 기준)의 chord-기준
/// 짝. serializeConfig가 unbind-append 패스 뒤에 체이닝한다(append가 안 쓴 chord를 여기서 빼 정리). 반환 owned(`allocator`).
pub fn removeKeybindUnbindLines(allocator: std.mem.Allocator, original: []const u8, chords: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        var drop = false;
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (std.mem.eql(u8, kl.rhs, "unbind")) {
                for (chords) |c| if (std.mem.eql(u8, c, kl.chord)) {
                    drop = true;
                    break;
                };
            }
        }
        if (drop) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, raw_line);
    }
    return out.toOwnedSlice(allocator);
}

/// 전역(OS) keybind recorder write-back 한 건 — 전역 action(키)을 새 chord 표기로 다시 묶는다. action은
/// command_catalog 글로벌 키(정적 리터럴, 예: `"toggle_window"`), chord는 `KeyChord.toConfigString` 결과(예: `"Cmd+Alt+Space"`).
pub const GlobalKeybindRebind = struct { action: []const u8, chord: []const u8 };

/// 전역 keybind 줄(`keybind = global:<chord> = <action>`)을 **action 기준**으로 in-place 갱신한다 — updateKeybindLines의
/// 전역 미러. **좌측 chord가 `global:`로 시작하는 줄만** 매칭한다(in-app keybind 줄·매크로·주석은 보존 — 섞임 방지).
/// 출력은 `keybind = global:<새 chord> = <action>`. 원본에 그 전역 action 줄이 없으면 끝에 append. 반환 owned(`allocator`).
pub fn updateGlobalKeybindLines(allocator: std.mem.Allocator, original: []const u8, rebinds: []const GlobalKeybindRebind) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const applied = try allocator.alloc(bool, rebinds.len);
    defer allocator.free(applied);
    @memset(applied, false);

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var replaced = false;
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            // **전역 줄만** — 좌측 chord가 `global:`로 시작해야 갱신 대상(in-app keybind 줄은 안 건드린다).
            if (std.mem.startsWith(u8, kl.chord, "global:")) {
                for (rebinds, 0..) |rb, i| {
                    if (std.mem.eql(u8, rb.action, kl.rhs)) {
                        try out.appendSlice(allocator, "keybind = global:");
                        try out.appendSlice(allocator, rb.chord);
                        try out.appendSlice(allocator, " = ");
                        try out.appendSlice(allocator, kl.rhs);
                        applied[i] = true; // 같은 action 줄이 여러 개면 모두 교체(parse last-wins라 stale 방지)
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) try out.appendSlice(allocator, raw_line);
    }
    // 원본에 없던 전역 action은 끝에 append.
    for (rebinds, 0..) |rb, i| {
        if (applied[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, "keybind = global:");
        try out.appendSlice(allocator, rb.chord);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, rb.action);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// `keybind = global:<chord> = <action>` 줄을 **action 기준**으로 삭제한다(전역 단축키 해제 — removeKeybindLines의 전역
/// 미러). **좌측 chord가 `global:`로 시작하는 줄만** 본다(in-app keybind 줄·주석·다른 줄 보존). 반환 owned.
pub fn removeGlobalKeybindLines(allocator: std.mem.Allocator, original: []const u8, actions: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        var drop = false;
        if (parseKeybindLine(std.mem.trim(u8, raw_line, &std.ascii.whitespace))) |kl| {
            if (std.mem.startsWith(u8, kl.chord, "global:")) {
                for (actions) |a| if (std.mem.eql(u8, a, kl.rhs)) {
                    drop = true;
                    break;
                };
            }
        }
        if (drop) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, raw_line);
    }
    return out.toOwnedSlice(allocator);
}

/// `keybind = <chord> = unbind` 지시어 줄을 추가한다(빌트인 단축키 죽이기 — chord를 ignored로). updateKeybindLines는
/// action 기준 교체라 rhs가 모두 `unbind`인 줄들을 한데 collapse하므로 못 쓴다(서로 다른 chord를 unbind). 그래서 단순
/// append하되 **동일 줄이 이미 있으면 스킵**(중복 누적 방지). chord는 KeyChord.toConfigString 결과("Cmd+T"). 반환 owned.
pub fn appendKeybindUnbinds(allocator: std.mem.Allocator, original: []const u8, chords: []const []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, original);
    for (chords) |chord| {
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "keybind = {s} = unbind", .{chord}) catch continue;
        // 중복 검사는 **줄 단위 정확 비교**(부분문자열 indexOf는 다른 chord 줄에 substring으로 걸려 거짓 스킵될 여지 — 리뷰 #840).
        var exists = false;
        var lit = std.mem.splitScalar(u8, out.items, '\n');
        while (lit.next()) |ln| if (std.mem.eql(u8, std.mem.trim(u8, ln, &std.ascii.whitespace), line)) {
            exists = true;
            break;
        };
        if (exists) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// 빈 기본 결과(파일 없음/HOME 없음 등). config 텍스트를 안 읽었으므로 arena도 비어 있다.
fn emptyDefault(allocator: std.mem.Allocator, file_provenance: FileProvenance) Parsed {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .config = .{},
        .keybindings = &.{},
        .unbinds = &.{},
        .terminal_bindings = &.{},
        .global_bindings = &.{},
        .diagnostics = &.{},
        .session_keep_alive_provenance = .absent,
        .file_provenance = file_provenance,
    };
}

/// 경로에서 config를 읽어 파싱한다. 파일이 없거나 읽기 실패면 기본 Config(빈 arena)를 돌려준다
/// (forgiving — 설정 파일이 없어도 터미널은 정상 동작해야 한다). OOM만 에러.
pub fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!Parsed {
    // std.Io.Limit is exclusive (reached *or* exceeded => StreamTooLong), hence +1 admits an
    // exact 1 MiB config while still reading at most that many owned bytes.
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_file_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return emptyDefault(allocator, .missing),
        error.StreamTooLong => return emptyDefault(allocator, .oversize),
        // Forgiving 기본값은 유지하지만 G2가 unreadable을 absent로 오인하지 않도록 원인을 보존한다.
        else => return emptyDefault(allocator, .unreadable),
    };
    defer allocator.free(source);
    return parse(allocator, source);
}

/// 기본 config 경로(owned). `$MARU_CONFIG`가 있으면 그것을, 없으면 OS별 기본 자리다 —
/// POSIX `$HOME/.config/maru/config`(Ghostty와 같은 관례), **Windows `%LOCALAPPDATA%\maru\config`**.
/// 정할 수 없으면 null(설정 없이 기본값).
///
/// 자리 판정은 `user_paths.defaultConfigPathFor`(순수·OS 인자)가 소유하고 여기서는 환경변수 읽기만 한다 —
/// Windows 레이아웃을 왜 `%LOCALAPPDATA%`로 정했는지는 그 모듈의 doc과 계약 §5.3에.
pub fn defaultConfigPath(allocator: std.mem.Allocator) LoadError!?[]const u8 {
    // **`getenv` 를 쓰지 않는다.** Windows 에서 그것은 CRT 의 ANSI 환경이라 사용자명이 비-ASCII 면
    // 값이 ACP 바이트로 온다(실측: `C:\Users\홍길동\…` → cp949, `valid_utf8=false`). 그 바이트로
    // 파일을 열면 실패하고, 아래 `loadFile` 의 forgiving 처리가 그것을 "파일 없음" 과 구분하지 못해
    // **사용자 config 를 통째로 잃는다**. `os_env` 가 wide 환경을 읽는 단일 출처다.
    if (os_env.allocValue(allocator, "MARU_CONFIG")) |override| {
        defer allocator.free(override);
        // **여기도 정규화한다.** 아래 `%LOCALAPPDATA%` 갈래가 하는 것과 같은 이유이고, 이쪽이 오히려
        // **우선순위가 높은 환경변수**다. 빼먹으면 사용자가 어떻게 띄웠느냐에 따라 config 경로 철자가
        // 둘로 갈려, 그 경로를 잇거나 비교하는 소비자가 어긋난다.
        return try path_shape.normalizeSeparators(allocator, override);
    }
    const home = os_env.allocValue(allocator, "HOME");
    defer if (home) |h| allocator.free(h);
    const local = os_env.allocValue(allocator, "LOCALAPPDATA");
    defer if (local) |l| allocator.free(l);
    const raw = (try user_paths.defaultConfigPathFor(allocator, builtin.os.tag, home, local)) orelse return null;
    defer allocator.free(raw);
    // 입구 정규화(계약 §5) — 환경변수에서 온 값은 native 구분자다. 중립 레이어가 `/`로 이으므로
    // 그대로 두면 `C:\Users\me/maru/config`처럼 섞인다.
    return try path_shape.normalizeSeparators(allocator, raw);
}

/// 기본 경로에서 config를 로드한다(경로 해석 + 파일 읽기 + 파싱). app session이 시작 시 호출하는
/// 단일 진입점. 경로/파일이 없으면 기본 Config. 호출자는 Parsed(arena)를 세션 동안 보관해야 한다
/// (resolve가 font.family 슬라이스를 빌린다).
pub fn loadDefault(io: std.Io, allocator: std.mem.Allocator) LoadError!Parsed {
    const path = (try defaultConfigPath(allocator)) orelse return emptyDefault(allocator, .missing);
    defer allocator.free(path);
    return loadFile(io, allocator, path);
}

// 제거된 키가 남아 있는 **옛 config 파일**을 그대로 읽을 수 있어야 한다. chrome-strategy.md가
// "기존 파일은 고치지 않는다 — forgiving 로더가 무시한다"고 약속하는데, 그 약속은 산문이 아니라
// 여기서 고정한다. tui 룩 제거(2026-08-19)로 `chrome.theme`이 사라졌고, 사용자 파일에는 남아 있다.
test "제거된 chrome.theme 줄이 있는 옛 config도 나머지 키를 잃지 않는다" {
    var p = try parse(std.testing.allocator,
        \\chrome.theme = tui
        \\chrome.tab-style = pill
        \\font.size = 15
    );
    defer p.deinit();
    // 없어진 키는 무시되고 **뒤 줄이 계속 적용된다** — 파싱이 그 줄에서 멈추면 사용자가 나머지 설정을 잃는다.
    try std.testing.expectEqual(theme.ChromeTabStyle.pill, p.config.chrome_tab_style);
    try std.testing.expectEqual(@as(f32, 15), p.config.font.size);
    // 조용히 삼키지 않는다 — 무엇이 무시됐는지 진단으로 알린다.
    try std.testing.expect(p.diagnostics.len >= 1);
}

test "parse: full config sets every field" {
    var p = try parse(std.testing.allocator,
        \\# Maru config
        \\font.family = JetBrains Mono
        \\font.size = 16
        \\font.line-height = 1.25
        \\font.letter-spacing = 1.5
        \\theme.background = #001122
        \\theme.foreground = #ffeedd
        \\cursor.shape = bar
        \\cursor.blink = false
        \\cursor.color = #ff5555
        \\cursor.text = #101010
        \\sidebar.show-branch = false
        \\editor.wrap = true
        \\sidebar.show-folder = false
        \\sidebar.agent-hooks = true
        \\text.blink = true
        \\theme.bold-is-bright = true
        \\input.shift-enter = native
        \\input.ime-enter = commit-only
        \\window.padding-x = 12
        \\window.padding-y = 6
        \\notifications.osc = false
        \\notifications.history-limit = 100
        \\keyhint.enabled = false
        \\keyhint.delay = 250
        \\keyhint.modifier = control
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("JetBrains Mono", p.config.font.family);
    try std.testing.expectEqual(@as(f32, 16), p.config.font.size);
    try std.testing.expectEqual(@as(f32, 1.25), p.config.font.line_height); // font.line-height 파싱(기본 1.0)
    try std.testing.expectEqual(@as(f32, 1.5), p.config.font.letter_spacing); // font.letter-spacing 파싱(기본 0.0)
    try std.testing.expectEqualStrings("#001122", p.config.theme.background);
    try std.testing.expectEqualStrings("#ffeedd", p.config.theme.foreground);
    try std.testing.expectEqual(theme.CursorShape.bar, p.config.cursor.shape);
    try std.testing.expectEqual(false, p.config.cursor.blink);
    try std.testing.expectEqualStrings("#ff5555", p.config.cursor.color.?);
    try std.testing.expectEqualStrings("#101010", p.config.cursor.text.?);
    try std.testing.expectEqual(false, p.config.sidebar.show_branch); // sidebar.show-branch 파싱(기본 true)
    // 편집기 랩. **기본이 `false`라** 이 테스트는 켜는 쪽을 확인한다 — 기본값과 같은 값을 넣으면
    // 파싱이 통째로 안 돌아도 통과한다. 기본값을 `true`→`false`로 되돌렸을 때(2026-08-16) 이 테스트가
    // 정확히 그 공허한 상태가 됐고, **아무도 깨지지 않아서** 알아채기 어려웠다.
    try std.testing.expectEqual(true, p.config.editor.wrap); // editor.wrap 파싱(기본 false)
    try std.testing.expectEqual(false, p.config.sidebar.show_folder); // sidebar.show-folder 파싱(기본 true)
    // 이 키가 파싱돼야 "사용자 파일을 건드리는 기능을 끌 수 있다"는 계약이 성립한다(docs/agent-session.md).
    // **켜는 쪽으로 확인한다** — 기본이 false라 false를 넣으면 파싱이 안 돌아도 통과한다(바로 위 editor.wrap과 같은 함정).
    try std.testing.expectEqual(true, p.config.sidebar.agent_hooks); // sidebar.agent-hooks 파싱(기본 false)
    try std.testing.expectEqual(true, p.config.blink_text); // text.blink 파싱(기본 false)
    try std.testing.expectEqual(true, p.config.bold_is_bright); // theme.bold-is-bright 파싱(기본 false)
    try std.testing.expectEqual(theme.ShiftEnter.native, p.config.input.shift_enter); // input.shift-enter 파싱(기본 newline)
    try std.testing.expectEqual(theme.ImeEnter.commit_only, p.config.input.ime_enter); // input.ime-enter 파싱(기본 newline)
    try std.testing.expectEqual(@as(u32, 12), p.config.window_padding_left); // window.padding-x alias → left+right
    try std.testing.expectEqual(@as(u32, 12), p.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 6), p.config.window_padding_top); // window.padding-y alias → top+bottom
    try std.testing.expectEqual(@as(u32, 6), p.config.window_padding_bottom);
    try std.testing.expectEqual(false, p.config.notifications.osc); // notifications.osc 파싱(기본 true)
    try std.testing.expectEqual(@as(u32, 100), p.config.notifications.history_limit); // notifications.history-limit 파싱(기본 64)
    try std.testing.expectEqual(false, p.config.keyhint.enabled); // keyhint.enabled 파싱(기본 true)
    try std.testing.expectEqual(@as(u32, 250), p.config.keyhint.delay); // keyhint.delay 파싱(기본 400)
    try std.testing.expectEqual(theme.HintModifier.control, p.config.keyhint.modifier); // keyhint.modifier 파싱(기본 command, enum 토큰)
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: removed compatibility settings use the generic unknown-key diagnostic" {
    const text =
        \\workspace.restore-claude = true
        \\workspace.restore-codex = true
        \\notifications.agent-complete = true
        \\workspace.restore-claude = not-a-bool
        \\workspace.restore-codex = not-a-bool
        \\notifications.agent-complete = not-a-bool
        \\font.size = 17
    ;
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 6), parsed.diagnostics.len);
    for (parsed.diagnostics, 1..) |diag, line| {
        try std.testing.expectEqual(line, diag.line);
        try std.testing.expectEqualStrings("알 수 없는 key — 무시", diag.message);
    }
    try std.testing.expectEqual(@as(f32, 17), parsed.config.font.size);
}

test "parse: file panel external link target defaults in-app and accepts system" {
    var defaults = try parse(std.testing.allocator, "font.size = 14");
    defer defaults.deinit();
    try std.testing.expectEqual(theme.ExternalLinkTarget.in_app, defaults.config.file_panel.external_link_target);

    var system = try parse(std.testing.allocator, "file-panel.external-link-target = system");
    defer system.deinit();
    try std.testing.expectEqual(theme.ExternalLinkTarget.system, system.config.file_panel.external_link_target);

    var invalid = try parse(std.testing.allocator, "file-panel.external-link-target = embedded");
    defer invalid.deinit();
    try std.testing.expectEqual(theme.ExternalLinkTarget.in_app, invalid.config.file_panel.external_link_target);
    try std.testing.expectEqual(@as(usize, 1), invalid.diagnostics.len);
}

// input.link-open-target: 터미널 웹 링크를 보이는 브라우저 패널에서 열지(auto, 기본)·없으면 새 탭까지 열지
// (in-app)·항상 시스템 브라우저로 보낼지(system). 정책 소비는 app_session.openTerminalWebLink.
// 오타는 무시하고 기본값을 유지한다(다른 dropdown 키와 같은 규율).
test "parse: input.link-open-target defaults auto and accepts in-app/system" {
    var defaults = try parse(std.testing.allocator, "font.size = 14");
    defer defaults.deinit();
    try std.testing.expectEqual(theme.LinkOpenTarget.auto, defaults.config.input.link_open_target);

    var in_app = try parse(std.testing.allocator, "input.link-open-target = in-app");
    defer in_app.deinit();
    try std.testing.expectEqual(theme.LinkOpenTarget.in_app, in_app.config.input.link_open_target);

    var system = try parse(std.testing.allocator, "input.link-open-target = system");
    defer system.deinit();
    try std.testing.expectEqual(theme.LinkOpenTarget.system, system.config.input.link_open_target);

    var invalid = try parse(std.testing.allocator, "input.link-open-target = embedded");
    defer invalid.deinit();
    try std.testing.expectEqual(theme.LinkOpenTarget.auto, invalid.config.input.link_open_target);
    try std.testing.expectEqual(@as(usize, 1), invalid.diagnostics.len);
}

test "parse: window.background-image — 경로 파싱, 미설정 시 빈 문자열(배경 없음)" {
    // F2-1: 설정하면 절대경로를 그대로 보관(loader는 디코드·존재 확인 안 함 — app_session이 frame에서 디코드).
    var p = try parse(std.testing.allocator,
        \\window.background-image = /Users/me/Pictures/bg.png
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("/Users/me/Pictures/bg.png", p.config.window_background_image);

    // 미설정이면 기본 빈 문자열(배경 이미지 없음 — 현행 동작 회귀 없음).
    var q = try parse(std.testing.allocator, "font.size = 14");
    defer q.deinit();
    try std.testing.expectEqualStrings("", q.config.window_background_image);
}

test "parse: window.blur — 반경 파싱, 미설정 시 0(끔)" {
    // F3-1: 창 뒤 데스크톱 블러 반경. loader는 반경만 파싱(opacity 게이트는 windowBlurRadius가 적용).
    var p = try parse(std.testing.allocator,
        \\window.blur = 24
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 24), p.config.window_blur);

    // 미설정이면 기본 0(블러 끔 — 현행 동작 회귀 없음).
    var q = try parse(std.testing.allocator, "font.size = 14");
    defer q.deinit();
    try std.testing.expectEqual(@as(u32, 0), q.config.window_blur);
}

test "parse: session.keep-alive-after-quit — 영속 세션 opt-in, 미설정 시 false(현행 in-process)" {
    // P3-e3: 영속 터미널 세션 게이트. true면 새 터미널을 host(maru-sessiond)에 생성한다(§10). 기본 false(현행 동작 유지).
    var p = try parse(std.testing.allocator,
        \\session.keep-alive-after-quit = true
    );
    defer p.deinit();
    try std.testing.expect(p.config.session.keep_alive_after_quit);

    // 미설정이면 기본 false(현행 in-process — GUI 종료 시 터미널도 종료).
    var q = try parse(std.testing.allocator, "font.size = 14");
    defer q.deinit();
    try std.testing.expect(!q.config.session.keep_alive_after_quit);
}

test "Session default G1 config provenance follows the last applied syntactic occurrence" {
    var absent = try parse(std.testing.allocator, "font.size = 14");
    defer absent.deinit();
    try std.testing.expect(absent.session_keep_alive_provenance == .absent);

    var invalid_last = try parse(std.testing.allocator,
        \\session.keep-alive-after-quit = true
        \\session.keep-alive-after-quit = maybe
    );
    defer invalid_last.deinit();
    try std.testing.expect(invalid_last.config.session.keep_alive_after_quit);
    try std.testing.expect(invalid_last.session_keep_alive_provenance == .explicit_invalid);

    var valid_last = try parse(std.testing.allocator,
        \\session.keep-alive-after-quit = invalid
        \\session.keep-alive-after-quit = false
    );
    defer valid_last.deinit();
    try std.testing.expect(!valid_last.config.session.keep_alive_after_quit);
    try std.testing.expectEqual(false, valid_last.session_keep_alive_provenance.explicit_valid);

    // 다른 OS 전용 occurrence는 이 host의 provenance가 아니다.
    const foreign_suffix = if (@import("builtin").os.tag == .windows) ".macos" else ".windows";
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "session.keep-alive-after-quit = true\nsession.keep-alive-after-quit{s} = invalid\n",
        .{foreign_suffix},
    );
    defer std.testing.allocator.free(source);
    var foreign = try parse(std.testing.allocator, source);
    defer foreign.deinit();
    try std.testing.expectEqual(true, foreign.session_keep_alive_provenance.explicit_valid);

    // 현재 OS suffix도 generic과 같은 occurrence 집합·파일 순서를 쓴다.
    const current_suffix = hostOsSuffix() orelse return error.SkipZigTest;
    const suffix_then_generic = try std.fmt.allocPrint(
        std.testing.allocator,
        "session.keep-alive-after-quit{s} = invalid\nsession.keep-alive-after-quit = false\n",
        .{current_suffix},
    );
    defer std.testing.allocator.free(suffix_then_generic);
    var generic_last = try parse(std.testing.allocator, suffix_then_generic);
    defer generic_last.deinit();
    try std.testing.expectEqual(false, generic_last.session_keep_alive_provenance.explicit_valid);

    const generic_then_suffix = try std.fmt.allocPrint(
        std.testing.allocator,
        "session.keep-alive-after-quit = false\nsession.keep-alive-after-quit{s} = invalid\n",
        .{current_suffix},
    );
    defer std.testing.allocator.free(generic_then_suffix);
    var suffix_last = try parse(std.testing.allocator, generic_then_suffix);
    defer suffix_last.deinit();
    try std.testing.expect(suffix_last.session_keep_alive_provenance == .explicit_invalid);
}

test "Session default G1 config provenance loadFile preserves missing readable unreadable and oversize" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const missing_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/missing", .{tmp.sub_path});
    var missing = try loadFile(io, allocator, missing_path);
    defer missing.deinit();
    try std.testing.expectEqual(FileProvenance.missing, missing.file_provenance);

    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "session.keep-alive-after-quit = false\n" });
    const readable_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/config", .{tmp.sub_path});
    var readable = try loadFile(io, allocator, readable_path);
    defer readable.deinit();
    try std.testing.expectEqual(FileProvenance.readable, readable.file_provenance);
    try std.testing.expectEqual(false, readable.session_keep_alive_provenance.explicit_valid);

    const directory_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var unreadable = try loadFile(io, allocator, directory_path);
    defer unreadable.deinit();
    try std.testing.expectEqual(FileProvenance.unreadable, unreadable.file_provenance);

    const exact = try allocator.alloc(u8, max_config_file_bytes);
    defer allocator.free(exact);
    @memset(exact, '#');
    try tmp.dir.writeFile(io, .{ .sub_path = "exact", .data = exact });
    const exact_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/exact", .{tmp.sub_path});
    var exact_loaded = try loadFile(io, allocator, exact_path);
    defer exact_loaded.deinit();
    try std.testing.expectEqual(FileProvenance.readable, exact_loaded.file_provenance);

    try tmp.dir.writeFile(io, .{ .sub_path = "oversize", .data = exact });
    const oversize_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/oversize", .{tmp.sub_path});
    var file = try tmp.dir.openFile(io, "oversize", .{ .mode = .write_only });
    defer file.close(io);
    try file.setLength(io, max_config_file_bytes + 1);
    var oversize = try loadFile(io, allocator, oversize_path);
    defer oversize.deinit();
    try std.testing.expectEqual(FileProvenance.oversize, oversize.file_provenance);
}

test "theme.preset 영속: 한 줄이 16색 팔레트까지 복원 + 개별 override 제거로 충돌 없음 (팔레트 영속 리뷰)" {
    const a = std.testing.allocator;
    // 옛 스타일 파일: 개별 4색 + 팔레트 override 하나(이전 프리셋이 4색만 써둔 잔재 모사).
    const original =
        "theme.background = #111111\ntheme.foreground = #eeeeee\ntheme.cursor = #ff0000\n" ++
        "theme.selection = #00ff00\ntheme.palette.3 = #abcdef\n";
    // serializeConfig가 하는 일을 그대로: (1) theme.preset = dracula set/update, (2) 개별 색·palette override 제거.
    const updates = [_]KeyValue{.{ .key = "theme.preset", .value = "dracula" }};
    const t1 = try updateConfigText(a, original, &updates);
    defer a.free(t1);
    var removed: std.ArrayList([]const u8) = .empty;
    defer removed.deinit(a);
    inline for (.{ "theme.background", "theme.foreground", "theme.cursor", "theme.selection" }) |k| try removed.append(a, k);
    var bufs: [16][20]u8 = undefined;
    for (0..16) |i| try removed.append(a, try std.fmt.bufPrint(&bufs[i], "theme.palette.{d}", .{i}));
    const t2 = try removeConfigLines(a, t1, removed.items);
    defer a.free(t2);

    // parse: theme.preset이 dracula 전체(16색 팔레트 포함)를 깐다. 옛 override는 제거돼 충돌 없음.
    var p = try parse(a, t2);
    defer p.deinit();
    const dr = theme.presetColors(.dracula);
    try std.testing.expectEqualStrings(dr.background, p.config.theme.background); // 주 색 복원
    try std.testing.expectEqualStrings("#f1fa8c", p.config.theme.palette[3].?); // 팔레트도 dracula 복원(옛 #abcdef 아님)
    try std.testing.expectEqualStrings(dr.palette[0].?, p.config.theme.palette[0].?); // 전 16색 영속
}

test "removeKeybindUnbindLines: chord 기준으로 unbind 지시어만 제거(다른 keybind·global·매크로·주석 보존) (stale unbind)" {
    const a = std.testing.allocator;
    const original =
        "# 주석\nkeybind = Shift+Cmd+] = unbind\nkeybind = Shift+Cmd+] = previous_tab\n" ++
        "keybind = Cmd+K = unbind\nkeybind = global:Cmd+Space = toggle_window\nkeybind = Cmd+E = text:hi\n";
    const removed = [_][]const u8{"Shift+Cmd+]"};
    const out = try removeKeybindUnbindLines(a, original, &removed);
    defer a.free(out);
    // Shift+Cmd+]의 **unbind** 줄만 빠진다 — 같은 chord의 previous_tab 바인딩, 다른 unbind(Cmd+K), global, 매크로, 주석은 보존.
    try std.testing.expect(std.mem.indexOf(u8, out, "Shift+Cmd+] = unbind") == null); // 제거됨
    try std.testing.expect(std.mem.indexOf(u8, out, "Shift+Cmd+] = previous_tab") != null); // 사용자 바인딩 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+K = unbind") != null); // 다른 chord unbind 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "global:Cmd+Space") != null); // global 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+E = text:hi") != null); // 매크로 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null); // 주석 보존
}

// OS 접미(`shell.command.windows`)는 한 config 파일을 여러 OS에서 공유할 때 필요한 축이다
// (docs/configuration.md "OS별 값"). 여기서 지키는 성질 셋: 접미 줄은 **그 자리에서** 적용되고,
// 다른 OS 줄은 값이 적용되지 않으며, 모르는 접미는 접미가 아니라 키 이름의 일부다.
test "parse: OS 접미 줄은 그 자리에서 적용된다(파일 순서가 결정한다)" {
    const host = @import("builtin").os.tag;
    const win = host == .windows;
    const mac = host == .macos;
    const a = std.testing.allocator;

    // 접미 줄을 **나중에** 두면 이긴다 — 다른 모든 키와 같은 규칙이다.
    var later = try parse(a,
        \\shell.command = /bin/sh
        \\shell.command.windows = C:\pwsh.exe
        \\shell.command.macos = /bin/zsh
    );
    defer later.deinit();
    // **Windows 기대값이 `C:/pwsh.exe` 다** — 경로 값은 입구에서 구분자를 정규화하기 때문이다(§5 규칙 1,
    // W7.5). 이 테스트는 그 전에 쓰여 native 구분자를 단언했었다. 여기서 보는 것은 "어느 줄이 이기는가"
    // 이지 구분자가 아니므로, 기대값만 새 계약에 맞춘다.
    const expected: []const u8 = if (win) "C:/pwsh.exe" else if (mac) "/bin/zsh" else "/bin/sh";
    try std.testing.expectEqualStrings(expected, later.config.shell.command);
    try std.testing.expectEqual(@as(usize, 0), later.diagnostics.len);

    // 접미 줄을 **먼저** 두면 뒤의 기본 줄이 이긴다. 한때 "순서와 무관하게 접미가 이긴다"로 만들었다가
    // 접미가 하나도 없는 기존 config의 동작까지 바꿔 버렸다(theme.preset 순서 역전) — 이 형식은 원래
    // 순서 의존이고, 그것과 싸우면 더 큰 것이 깨진다.
    var earlier = try parse(a,
        \\shell.command.windows = C:\pwsh.exe
        \\shell.command = /bin/sh
    );
    defer earlier.deinit();
    try std.testing.expectEqualStrings("/bin/sh", earlier.config.shell.command);
}

test "parse: 기본 키만 있으면 그대로, 다른 OS 키만 있으면 기본값 유지" {
    const host = @import("builtin").os.tag;

    var only_base = try parse(std.testing.allocator, "shell.command = /bin/sh");
    defer only_base.deinit();
    try std.testing.expectEqualStrings("/bin/sh", only_base.config.shell.command);

    // 호스트가 아닌 OS의 줄만 있으면 아무 일도 없어야 한다(기본값 "" 유지, diagnostic 0).
    const foreign = if (host == .windows) "shell.command.macos = /bin/zsh" else "shell.command.windows = C:\\x.exe";
    var p = try parse(std.testing.allocator, foreign);
    defer p.deinit();
    try std.testing.expectEqualStrings("", p.config.shell.command);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

// 다른 OS 줄은 **값은 적용하지 않지만 키 이름은 검증한다.** 안 하면 doc-vs-key 게이트
// (`tests/config_docs/keys.zig`)가 "알 수 없는 key" 유무로 실재를 판정하므로 **없는 키를 실재로 보고**한다.
// 반대로 값까지 검증하면 `shell.command.windows = C:\x`가 macOS에서 "절대경로 아님"으로 가짜 경고를 낸다.
test "parse: 다른 OS 줄은 키 이름만 검증한다" {
    const a = std.testing.allocator;
    const foreign = if (@import("builtin").os.tag == .windows) ".macos" else ".windows";

    // 없는 키 → 경고가 떠야 한다(게이트가 이걸로 실재를 판정한다).
    const bogus = try std.fmt.allocPrint(a, "bogus.setting{s} = 1", .{foreign});
    defer a.free(bogus);
    var p1 = try parse(a, bogus);
    defer p1.deinit();
    try std.testing.expectEqual(@as(usize, 1), p1.diagnostics.len);

    // 실재하는 키 + **그 OS에서만 유효한 값** → 경고가 없어야 한다.
    const ok = try std.fmt.allocPrint(a, "shell.command{s} = C:\\pwsh.exe", .{foreign});
    defer a.free(ok);
    var p2 = try parse(a, ok);
    defer p2.deinit();
    try std.testing.expectEqual(@as(usize, 0), p2.diagnostics.len);
    try std.testing.expectEqualStrings("", p2.config.shell.command); // 값은 적용되지 않는다
}

// `.osx`는 VS Code 철자이고 우리 문서가 그것을 선례로 인용한다 — 받아들이지 않으면 `env.EDITOR.osx`가
// 경고 없이 변수 이름의 일부로 먹힌다(코드 리뷰가 실측으로 잡았다).
test "parse: .osx도 macOS 접미로 받는다" {
    try std.testing.expectEqual(std.Target.Os.Tag.macos, splitOsSuffix("shell.command.osx").os.?);
    try std.testing.expectEqualStrings("shell.command", splitOsSuffix("shell.command.osx").base);
    try std.testing.expectEqual(std.Target.Os.Tag.macos, splitOsSuffix("env.EDITOR.osx").os.?);
}

test "parse: 모르는 OS 접미와 오타는 키 이름의 일부라 경고로 잡힌다" {
    // `.freebsd`는 지원 목록에 없고 `.window`는 오타다. 조용히 무시하면 사용자는 설정이 반영된 줄 안다.
    var p = try parse(std.testing.allocator,
        \\shell.command.freebsd = /bin/sh
        \\shell.command.window = C:\x.exe
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len);
    try std.testing.expectEqualStrings("", p.config.shell.command); // 아무것도 적용되지 않았다
}

// `theme.preset`은 색 세트를 통째로 깔아 놓는 **base 레이어**라 개별 `theme.*`보다 먼저 적용돼야 한다
// (docs/configuration.md). 단계를 "기본/OS" 둘로만 나눴을 때 `theme.preset.windows`가 개별 색보다 나중에
// 적용돼 사용자가 명시한 배경색을 조용히 덮어썼다 — 적대적 검증에서 실측으로 잡았다.
// `theme.preset`은 색 세트를 통째로 까는 base라 개별 `theme.*`보다 **먼저 와야 한다**는 순서 규약이 있다
// (docs/configuration-text.md). 접미가 붙어도 그 규약은 그대로다 — 줄을 제자리에서 적용하므로.
// 한때 접미 줄을 뒤로 몰았다가 `theme.preset.windows`가 개별 색을 덮어썼고, 그 수정이 다시 **접미 없는**
// config의 순서까지 뒤집었다(코드 리뷰가 실측으로 잡았다). 두 방향을 모두 고정한다.
test "parse: theme.preset 순서 규약은 접미 유무와 무관하다" {
    const suffix = hostOsSuffix() orelse return error.SkipZigTest;
    const a = std.testing.allocator;

    // 프리셋을 먼저 → 개별 색이 이긴다.
    const first = try std.fmt.allocPrint(a, "theme.preset{s} = nord\ntheme.background = #101010", .{suffix});
    defer a.free(first);
    var p1 = try parse(a, first);
    defer p1.deinit();
    try std.testing.expectEqualStrings("#101010", p1.config.theme.background);

    // 프리셋을 나중에 → 프리셋이 이긴다(기존 규약 — 접미 없는 config에서도 이 방향이 유지돼야 한다).
    const last = try std.fmt.allocPrint(a, "theme.background = #101010\ntheme.preset{s} = nord", .{suffix});
    defer a.free(last);
    var p2 = try parse(a, last);
    defer p2.deinit();
    var nord = try parse(a, "theme.preset = nord");
    defer nord.deinit();
    try std.testing.expectEqualStrings(nord.config.theme.background, p2.config.theme.background);

    // **접미가 하나도 없는 config**도 같은 방향이어야 한다(회귀 가드 — 여기가 깨진 적이 있다).
    var plain = try parse(a, "theme.background = #101010\ntheme.preset = nord");
    defer plain.deinit();
    try std.testing.expectEqualStrings(nord.config.theme.background, plain.config.theme.background);
}

test "parse: 형식 오류 diagnostic은 한 번만 뜬다" {
    // 줄을 두 번 훑으므로 `=` 없는 줄이 두 번 보고될 수 있다. 1차에서만 낸다.
    var p = try parse(std.testing.allocator,
        \\this line has no equals
        \\shell.command = /bin/sh
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
}

// GUI write-back(사이드바 드래그·⚙ 토글)이 **지금 이기고 있는 줄**을 갱신해야 한다. 기본 키에 쓰면 값이
// 다른 OS로 새고, 이 OS에는 반영조차 안 된다(접미 줄이 계속 이기므로 "설정이 안 먹는다"로 보인다).

test "parse: splitOsSuffix — 접미만 있는 키는 접미로 보지 않는다" {
    // `.windows`만 있는 줄은 기본 키가 비어 버리므로 접미가 아니다(빈 키 → 알 수 없는 키).
    try std.testing.expect(splitOsSuffix(".windows").os == null);
    try std.testing.expectEqualStrings(".windows", splitOsSuffix(".windows").base);

    const s = splitOsSuffix("font.size.macos");
    try std.testing.expectEqual(std.Target.Os.Tag.macos, s.os.?);
    try std.testing.expectEqualStrings("font.size", s.base);

    try std.testing.expect(splitOsSuffix("shell.command").os == null);
    // `shell.windows-shell`은 `.windows`로 끝나지 않는다 — 전용 키와 접미 메커니즘이 충돌하지 않는다.
    try std.testing.expect(splitOsSuffix("shell.windows-shell").os == null);
}

test "parse: env.<KEY>가 누적되고 빈 KEY는 무시, 값 내부 공백 보존" {
    var p = try parse(std.testing.allocator,
        \\env.EDITOR = nvim
        \\env.GREETING = hello world
        \\env. = ignored
        \\env.EMPTY =
    );
    defer p.deinit();
    // env. (빈 KEY)는 diagnostic 후 무시 — 나머지 3개만 누적(EDITOR/GREETING/EMPTY).
    try std.testing.expectEqual(@as(usize, 3), p.config.env.len);
    try std.testing.expectEqualStrings("EDITOR=nvim", p.config.env[0]);
    try std.testing.expectEqualStrings("GREETING=hello world", p.config.env[1]); // 내부 공백 보존(양끝만 trim)
    try std.testing.expectEqualStrings("EMPTY=", p.config.env[2]); // 빈 값도 유효
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len); // env. (빈 KEY) 한 건
}

test "parseFor: 경로 값은 입구에서 구분자를 정규화한다 — 두 OS 갈래가 모든 타깃에서 돈다" {
    // **`parseFor` 로 OS 를 준다.** 호스트 고정 래퍼(`parse`)로 쓰면 이 저장소에 Windows 러너가 없어
    // (verification-matrix) Windows 갈래가 **한 번도 안 돌고**, POSIX 갈래는 "안 바뀐다" 를 단언하므로
    // 정규화를 통째로 지워도 CI 가 초록이다 — 검증이 아니라 장식이 된다. `path_shape` 가 `~For` 로
    // OS 를 인자로 받는 이유가 그것이고, 그 규율이 로더 배선까지 와야 의미가 있다.
    const a = std.testing.allocator;

    // `window.background-image` — 절대경로를 요구하지 않는 순수 `path_value` 필드라 두 OS 에서 모두
    // 값이 살아남는다. 그래서 **갈리는 것이 구분자뿐**이고, 정규화 유무를 정확히 잡는다.
    {
        var w = try parseFor(.windows, a, "window.background-image = C:\\pics\\bg.png\n");
        defer w.deinit();
        try std.testing.expectEqualStrings("C:/pics/bg.png", w.config.window_background_image);

        var l = try parseFor(.linux, a, "window.background-image = C:\\pics\\bg.png\n");
        defer l.deinit();
        try std.testing.expectEqualStrings("C:\\pics\\bg.png", l.config.window_background_image);
    }

    // `shell.command` — `abs_path` 가 `path_value` 를 함의한다. **수용 검사는 호스트 규칙을 쓴다**
    // (`std.fs.path.isAbsolute`)라 `C:\…` 는 POSIX 호스트에서 거부된다. 그래서 정규화 자체는 두 OS 에서
    // 모두 통과하는 철자로 본다.
    {
        var w = try parseFor(.windows, a, "shell.command = /opt\\bin\\sh\n");
        defer w.deinit();
        try std.testing.expectEqualStrings("/opt/bin/sh", w.config.shell.command);

        var l = try parseFor(.linux, a, "shell.command = /opt\\bin\\sh\n");
        defer l.deinit();
        try std.testing.expectEqualStrings("/opt\\bin\\sh", l.config.shell.command);
    }

    // `workspace.root` — 명시 핸들러라 스키마 경로와 **같은 규칙**이어야 한다(한쪽만 걸리면 그 키만
    // 다르게 동작한다).
    {
        var w = try parseFor(.windows, a, "workspace.root = /proj\\sub\n");
        defer w.deinit();
        try std.testing.expectEqualStrings("/proj/sub", w.config.workspace.root);

        var l = try parseFor(.linux, a, "workspace.root = /proj\\sub\n");
        defer l.deinit();
        try std.testing.expectEqualStrings("/proj\\sub", l.config.workspace.root);
    }

    // **경로가 아닌 text 필드는 어느 OS 에서도 안 건드린다** — `\` 를 값으로 쓰는 설정이 깨지면 안 된다.
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |tag| {
        var p = try parseFor(tag, a, "input.word-separators = a\\b\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("a\\b", p.config.input.word_separators);
    }
}

test "parseFor: workspace.root 수용 검사는 정규화된 값을 본다 (§5 규칙 2)" {
    const a = std.testing.allocator;

    // **Windows 사용자가 자연스럽게 적는 철자다.** 정규화 전에 검사하면 `isValidWorkspaceRoot` 가
    // `~` 나 `~/` 접두만 보므로 `~\projects` 가 거부된다 — `~/projects` 와 `C:\proj` 는 되는데 이것만
    // 안 되는 것은 사용자가 이유를 알 수 없다. 계약 §5 규칙 2 가 "가드는 정규화 이후 형태를 본다" 고
    // 못 박은 자리다.
    {
        var w = try parseFor(.windows, a, "workspace.root = ~\\projects\n");
        defer w.deinit();
        try std.testing.expectEqualStrings("~/projects", w.config.workspace.root);
        try std.testing.expectEqual(@as(usize, 0), w.diagnostics.len);
    }

    // POSIX 에서는 정규화가 무동작이라 `~\projects` 가 여전히 형식에 안 맞는다 — 거기서는 `\` 가 파일
    // 이름 글자이므로 **거부가 맞다**(그 이름의 디렉터리를 만들 수는 있지만 `~` 확장 대상이 아니다).
    {
        var l = try parseFor(.linux, a, "workspace.root = ~\\projects\n");
        defer l.deinit();
        try std.testing.expectEqualStrings("", l.config.workspace.root);
        try std.testing.expectEqual(@as(usize, 1), l.diagnostics.len);
    }

    // 정규화가 수용을 넓히기만 하는 것은 아니다 — 원래 되던 철자는 그대로 된다.
    for ([_]std.Target.Os.Tag{ .windows, .linux }) |tag| {
        var p = try parseFor(tag, a, "workspace.root = ~/projects\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("~/projects", p.config.workspace.root);
    }
}

test "parse: shell.command/shell.args — 경로 + 공백 분리 argv, 빈 값 처리" {
    var p = try parse(std.testing.allocator,
        \\shell.command = /opt/homebrew/bin/fish
        \\shell.args = -i -l
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", p.config.shell.command);
    try std.testing.expectEqual(@as(usize, 2), p.config.shell.args.len);
    try std.testing.expectEqualStrings("-i", p.config.shell.args[0]);
    try std.testing.expectEqualStrings("-l", p.config.shell.args[1]);

    // 빈 shell.args → 인자 없음(&.{}); 빈 shell.command → 기본 유지("" — 셸 자동 결정) + diagnostic.
    var q = try parse(std.testing.allocator,
        \\shell.command =
        \\shell.args =
    );
    defer q.deinit();
    try std.testing.expectEqualStrings("", q.config.shell.command); // 빈 값 무시 → 기본 유지
    try std.testing.expectEqual(@as(usize, 0), q.config.shell.args.len); // 빈 값 → 인자 없음
    try std.testing.expectEqual(@as(usize, 1), q.diagnostics.len); // shell.command 빈 값 한 건

    // abs_path(A3): 비절대 shell.command(`~`·상대경로)는 파일 로드에서도 diagnostic + 기본값 유지 — GUI 안내와 같은
    // "절대경로" 규칙을 파일에도 적용해 드리프트 방지(config-gui.md §1). 저장 안 되므로 spawn 시 기본 셸로 폴백된다.
    for ([_][]const u8{ "shell.command = ~", "shell.command = ~/bin/zsh", "shell.command = bin/sh" }) |line| {
        var r = try parse(std.testing.allocator, line);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.config.shell.command); // 비절대 → 거부(기본 유지)
        try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len); // "절대경로여야 함" 한 건
    }
    // 절대경로는 (존재 여부와 무관하게) 형식 통과 — 존재·실행 검사는 spawn 시점(resolveConfiguredShell) 책임.
    var s = try parse(std.testing.allocator, "shell.command = /usr/local/bin/xonsh");
    defer s.deinit();
    try std.testing.expectEqualStrings("/usr/local/bin/xonsh", s.config.shell.command);
    try std.testing.expectEqual(@as(usize, 0), s.diagnostics.len);
}

test "updateConfigText: in-place 키 교체로 주석·다른 줄 보존, 없는 키는 append, round-trip" {
    const a = std.testing.allocator;
    const original =
        \\# 내 설정
        \\font.size = 16
        \\sidebar.show-branch = true
        \\theme.background = #001122
        \\
    ;
    const updates = [_]KeyValue{
        .{ .key = "sidebar.show-branch", .value = "false" }, // 기존 줄 교체
        .{ .key = "sidebar.show-folder", .value = "false" }, // 원본에 없음 → append
    };
    const updated = try updateConfigText(a, original, &updates);
    defer a.free(updated);
    // 주석·갱신 대상이 아닌 줄 보존
    try std.testing.expect(std.mem.indexOf(u8, updated, "# 내 설정") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "font.size = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "theme.background = #001122") != null);
    // 기존 줄 in-place 교체(true→false), append
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-branch = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-branch = true") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-folder = false") != null);
    // round-trip: 갱신 텍스트를 다시 파싱하면 새 값
    var p = try parse(a, updated);
    defer p.deinit();
    try std.testing.expectEqual(false, p.config.sidebar.show_branch);
    try std.testing.expectEqual(false, p.config.sidebar.show_folder);
}

test "updateConfigText: 같은 키가 중복이면 모든 occurrence를 교체한다(last-wins 정합 — 토글 되돌아감 방지)" {
    const a = std.testing.allocator;
    // 같은 키가 두 번(사용자가 실수로/병합으로 중복). parse는 last-wins라, 첫 줄만 바꾸면 둘째 줄(true)이 이겨
    // reload 시 토글이 되돌아간다. 모든 occurrence가 false가 돼야 한다.
    const original =
        \\sidebar.show-branch = true
        \\font.size = 16
        \\sidebar.show-branch = true
        \\
    ;
    const updates = [_]KeyValue{.{ .key = "sidebar.show-branch", .value = "false" }};
    const updated = try updateConfigText(a, original, &updates);
    defer a.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "sidebar.show-branch = true") == null); // 남은 true 없음
    // round-trip: 다시 파싱하면 last-wins로도 false(둘 다 false라 결과 동일).
    var p = try parse(a, updated);
    defer p.deinit();
    try std.testing.expectEqual(false, p.config.sidebar.show_branch);
}

test "updateConfigText: 빈 원본에도 키를 append한다(파일 없음 케이스)" {
    const a = std.testing.allocator;
    const updates = [_]KeyValue{.{ .key = "sidebar.show-branch", .value = "false" }};
    const updated = try updateConfigText(a, "", &updates);
    defer a.free(updated);
    try std.testing.expectEqualStrings("sidebar.show-branch = false\n", updated);
}

test "removeConfigLines: 키 줄 삭제(중복 포함), 주석·다른 줄 보존, 개행 정합 (env 삭제 토대)" {
    const a = std.testing.allocator;
    const original =
        "# 주석\n" ++
        "env.FOO = bar\n" ++ // 삭제 대상
        "font.size = 14\n" ++ // 보존
        "env.BAZ = qux\n" ++ // 보존(키 다름)
        "env.FOO = dup\n"; // 같은 키 중복 — 함께 삭제(last-wins 부활 방지)
    const out = try removeConfigLines(a, original, &.{"env.FOO"});
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "env.FOO") == null); // 두 줄 다 사라짐
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font.size = 14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "env.BAZ = qux") != null);
    // 파싱해 env에 FOO 없고 BAZ만 남는지.
    var p = try parse(a, out);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.config.env.len);
    try std.testing.expectEqualStrings("BAZ=qux", p.config.env[0]);
}

test "removeKeybindLines: action 기준 keybind 줄 삭제, 매크로·다른 keybind·주석 보존 (keybind unbind)" {
    const a = std.testing.allocator;
    const original =
        "# 주석\n" ++
        "keybind = Cmd+E = new_term\n" ++ // 삭제 대상(action=new_term)
        "keybind = Cmd+Shift+E = new_tab\n" ++ // 보존(action 다름)
        "keybind = Cmd+B = text:hi=there\n"; // 매크로(rhs '=') — action과 안 겹쳐 보존
    const out = try removeKeybindLines(a, original, &.{"new_term"});
    defer a.free(out);
    var p = try parse(a, out);
    defer p.deinit();
    // new_term 줄 삭제 → 사용자 바인딩에서 new_term 없음(빌트인은 남지만 parse 결과 keybindings엔 user만).
    for (p.keybindings) |b| try std.testing.expect(std.meta.activeTag(b.action) != .new_term);
    // new_tab은 유지.
    var saw_new_tab = false;
    for (p.keybindings) |b| if (std.meta.activeTag(b.action) == .new_tab) {
        saw_new_tab = true;
    };
    try std.testing.expect(saw_new_tab);
    try std.testing.expect(std.mem.indexOf(u8, out, "text:hi=there") != null); // 매크로 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+E = new_term") == null); // 삭제됨
}

test "updateKeybindLines: action 기준 교체, 없으면 append, 매크로·다른 줄·주석 보존 (keybind recorder write-back)" {
    const a = std.testing.allocator;
    const original =
        "# 사용자 주석\n" ++
        "keybind = Cmd+T = new_term\n" ++ // 교체 대상(action=new_term)
        "font.size = 14\n" ++ // 다른 줄 — 보존
        "keybind = Cmd+B = text:hello=world\n"; // 매크로(rhs에 '=') — action과 안 겹쳐 보존
    const rebinds = [_]KeybindRebind{
        .{ .action = "new_term", .chord = "Cmd+E" }, // 기존 줄 교체
        .{ .action = "new_tab", .chord = "Cmd+Shift+E" }, // 원본에 없음 → append
    };
    const out = try updateKeybindLines(a, original, &rebinds);
    defer a.free(out);

    // 파싱해서 결과 확인(텍스트 형식이 아니라 의미로 검증).
    var p = try parse(a, out);
    defer p.deinit();
    // new_term은 Cmd+E로 재바인딩됨.
    try std.testing.expect((try keybinding.KeyChord.parse("Cmd+E")).eql(p.keybindings[findBind(p.keybindings, .new_term)].chord));
    // new_tab은 append돼 Cmd+Shift+E.
    try std.testing.expect((try keybinding.KeyChord.parse("Cmd+Shift+E")).eql(p.keybindings[findBind(p.keybindings, .new_tab)].chord));
    // 매크로 줄·주석·다른 줄 보존.
    try std.testing.expect(std.mem.indexOf(u8, out, "text:hello=world") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 사용자 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font.size = 14") != null);
    // 옛 Cmd+T = new_term 줄은 사라짐(교체됨).
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+T = new_term") == null);
}

test "updateTerminalMacroLines/removeTerminalMacroLines: chord 기준 매크로 upsert·삭제, action 줄·주석 보존" {
    const a = std.testing.allocator;
    const original =
        "# 주석\n" ++
        "keybind = Ctrl+G = text:hello\n" ++ // 교체 대상(매크로, chord=Ctrl+G)
        "keybind = Cmd+T = new_term\n" ++ // app action 줄 — chord-기준 매크로 패스가 안 건드림
        "font.size = 14\n";
    const macros = [_]TerminalMacroWrite{
        .{ .chord = "Ctrl+G", .rhs = "text:goodbye" }, // 기존 매크로 rhs 교체
        .{ .chord = "Ctrl+H", .rhs = "esc:[2J" }, // 원본에 없음 → append
    };
    const out = try updateTerminalMacroLines(a, original, &macros);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Ctrl+G = text:goodbye") != null); // 교체
    try std.testing.expect(std.mem.indexOf(u8, out, "text:hello") == null); // 옛 rhs 사라짐
    try std.testing.expect(std.mem.indexOf(u8, out, "Ctrl+H = esc:[2J") != null); // append
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+T = new_term") != null); // action 줄 보존(chord 패스 무영향)
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font.size = 14") != null);
    var p = try parse(a, out);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.terminal_bindings.len); // 매크로 2개

    // 삭제 — Ctrl+G 매크로 줄만 제거(다른 매크로·action 보존).
    const chords = [_][]const u8{"Ctrl+G"};
    const removed = try removeTerminalMacroLines(a, out, &chords);
    defer a.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "Ctrl+G") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "Ctrl+H = esc:[2J") != null); // 다른 매크로 보존
    try std.testing.expect(std.mem.indexOf(u8, removed, "Cmd+T = new_term") != null); // action 보존
}

test "updateTerminalMacroLines/removeTerminalMacroLines: 비정규 표기 chord도 KeyChord.eql로 매칭(중복 줄·미삭제 방지)" {
    const a = std.testing.allocator;
    // 손으로 쓴 비정규 표기(소문자·수식키 순서 다름). GUI는 정규 표기(Ctrl+G·Ctrl+Shift+H)로 예약한다.
    const original =
        "keybind = ctrl+g = text:hello\n" ++ // 소문자
        "keybind = shift+ctrl+h = text:world\n"; // 수식키 순서 뒤바뀜
    const macros = [_]TerminalMacroWrite{.{ .chord = "Ctrl+G", .rhs = "text:bye" }};
    const out = try updateTerminalMacroLines(a, original, &macros);
    defer a.free(out);
    // 비정규 줄을 **교체**(append 아님) — text:hello 사라지고 text:bye만, 줄 1개.
    try std.testing.expect(std.mem.indexOf(u8, out, "text:bye") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "text:hello") == null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, out, (std.mem.indexOf(u8, out, "text:bye").?) + 1, "text:bye")); // 중복 줄 없음

    // 삭제도 비정규 표기 매칭 — shift+ctrl+h 줄을 정규 "Ctrl+Shift+H"로 제거.
    const chords = [_][]const u8{"Ctrl+Shift+H"};
    const removed = try removeTerminalMacroLines(a, out, &chords);
    defer a.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "text:world") == null); // 비정규 줄도 삭제됨
}

test "parseMacroRhs: text/esc/ctrl 파싱, 비매크로·빈 payload는 null" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    try std.testing.expect(parseMacroRhs(ar, "text:hi") != null);
    try std.testing.expect(parseMacroRhs(ar, "esc:[2J") != null);
    try std.testing.expect(parseMacroRhs(ar, "ctrl:G") != null);
    try std.testing.expect(parseMacroRhs(ar, "new_tab") == null); // 비매크로 접두사
    try std.testing.expect(parseMacroRhs(ar, "text:") == null); // 빈 payload
}

fn findBind(binds: []const keybinding.AppBinding, want: action_mod.Action) usize {
    for (binds, 0..) |b, i| if (std.meta.activeTag(b.action) == std.meta.activeTag(want)) return i;
    return 0;
}

test "updateGlobalKeybindLines: 전역 줄만 action 기준 교체/추가, in-app keybind·주석 보존" {
    const a = std.testing.allocator;
    const original =
        "# 사용자 주석\n" ++
        "keybind = global:Cmd+Alt+Space = toggle_window\n" ++ // 교체 대상(전역 action=toggle_window)
        "keybind = Cmd+T = new_term\n" ++ // in-app 줄 — 보존(global: 아님)
        "font.size = 14\n"; // 다른 줄 — 보존
    const rebinds = [_]GlobalKeybindRebind{
        .{ .action = "toggle_window", .chord = "Cmd+Alt+W" }, // 기존 전역 줄 교체
        .{ .action = "show_window", .chord = "Cmd+Alt+S" }, // 원본에 없음 → append
    };
    const out = try updateGlobalKeybindLines(a, original, &rebinds);
    defer a.free(out);

    // 파싱해 의미로 검증.
    var p = try parse(a, out);
    defer p.deinit();
    // toggle_window는 Cmd+Alt+W로 교체, show_window는 append돼 Cmd+Alt+S.
    var saw_toggle = false;
    var saw_show = false;
    for (p.global_bindings) |b| {
        switch (b.action) {
            .toggle_window => {
                saw_toggle = true;
                try std.testing.expect(b.chord.eql(try keybinding.KeyChord.parse("Cmd+Alt+W")));
            },
            .show_window => {
                saw_show = true;
                try std.testing.expect(b.chord.eql(try keybinding.KeyChord.parse("Cmd+Alt+S")));
            },
            else => {},
        }
    }
    try std.testing.expect(saw_toggle and saw_show);
    // in-app keybind 줄은 보존(global 패스가 안 건드림) — parse 결과 new_term이 in-app 풀에 남는다.
    var saw_new_term = false;
    for (p.keybindings) |b| if (std.meta.activeTag(b.action) == .new_term) {
        saw_new_term = true;
    };
    try std.testing.expect(saw_new_term);
    // 텍스트 보존 확인.
    try std.testing.expect(std.mem.indexOf(u8, out, "# 사용자 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+T = new_term") != null); // in-app 줄 그대로
    try std.testing.expect(std.mem.indexOf(u8, out, "font.size = 14") != null);
    // 옛 global:Cmd+Alt+Space = toggle_window 줄은 사라짐(교체됨).
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+Alt+Space = toggle_window") == null);
}

test "removeGlobalKeybindLines: 전역 줄만 action 기준 삭제, in-app keybind·주석 보존" {
    const a = std.testing.allocator;
    const original =
        "# 주석\n" ++
        "keybind = global:Cmd+Alt+Space = toggle_window\n" ++ // 삭제 대상(전역 action=toggle_window)
        "keybind = global:Cmd+Alt+T = show_window\n" ++ // 보존(전역 action 다름)
        "keybind = Cmd+T = new_term\n"; // in-app 줄 — 보존
    const out = try removeGlobalKeybindLines(a, original, &.{"toggle_window"});
    defer a.free(out);
    var p = try parse(a, out);
    defer p.deinit();
    // toggle_window 전역 줄 삭제 → global_bindings에 show_window만.
    try std.testing.expectEqual(@as(usize, 1), p.global_bindings.len);
    try std.testing.expectEqual(action_mod.GlobalAction.show_window, p.global_bindings[0].action);
    // in-app new_term은 보존.
    var saw_new_term = false;
    for (p.keybindings) |b| if (std.meta.activeTag(b.action) == .new_term) {
        saw_new_term = true;
    };
    try std.testing.expect(saw_new_term);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+T = new_term") != null); // in-app 줄 그대로
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+Alt+Space = toggle_window") == null); // 삭제됨
    try std.testing.expect(std.mem.indexOf(u8, out, "Cmd+Alt+T = show_window") != null); // 다른 전역 줄 보존
}

test "updateKeybindLines: in-app 패스는 global: 줄을 안 건드린다(섞임 방지)" {
    const a = std.testing.allocator;
    const original =
        "keybind = global:Cmd+Alt+Space = toggle_window\n"; // 전역 줄 — in-app 패스가 보존해야
    // in-app rebind 목록에 (우연히 같은 이름의) action이 와도 global: 줄은 매칭 안 됨.
    const rebinds = [_]KeybindRebind{.{ .action = "toggle_window", .chord = "Cmd+E" }};
    const out = try updateKeybindLines(a, original, &rebinds);
    defer a.free(out);
    // 전역 줄은 그대로 — 교체 안 됨. (in-app append로 끝에 toggle_window가 한 줄 더 붙긴 하지만 global 줄은 보존.)
    try std.testing.expect(std.mem.indexOf(u8, out, "global:Cmd+Alt+Space = toggle_window") != null);
}

// keybind 줄 토크나이저(parseKeybindLine 공유 추출) characterization — 공백 변형도 정상 줄과 동일하게 파싱됨을
// 고정한다(추출이 trim 동작을 깨면 안 됨). action 매칭(update) + chord 매칭(remove) 두 경로로 본다.
test "keybind 줄 파싱: 무공백·과공백 줄도 trim해 동일 매칭(토크나이저 불변식)" {
    const a = std.testing.allocator;
    const original =
        "keybind=Cmd+T=new_term\n" ++ // 무공백
        "keybind   =   Cmd+G   =   text:hi\n"; // 과공백 매크로
    // action 매칭(updateKeybindLines)이 무공백 줄을 정규 표기로 교체.
    const rb = [_]KeybindRebind{.{ .action = "new_term", .chord = "Cmd+E" }};
    const out1 = try updateKeybindLines(a, original, &rb);
    defer a.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "keybind = Cmd+E = new_term") != null); // 무공백 줄 교체됨
    // chord 매칭(removeTerminalMacroLines)이 과공백 매크로 줄을 삭제.
    const chords = [_][]const u8{"Cmd+G"};
    const out2 = try removeTerminalMacroLines(a, original, &chords);
    defer a.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "text:hi") == null); // 과공백 매크로 줄 삭제됨
}

test "appendKeybindUnbinds: chord별 unbind 지시어 추가, 정확-줄 중복 스킵, 주석 보존" {
    const a = std.testing.allocator;
    const original =
        "# 주석\n" ++
        "keybind = Cmd+T = unbind\n" ++ // 이미 있음 — 중복 스킵
        "font.size = 14\n";
    const chords = [_][]const u8{ "Cmd+T", "Cmd+W" }; // Cmd+T=중복, Cmd+W=신규
    const out = try appendKeybindUnbinds(a, original, &chords);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# 주석") != null); // 주석 보존
    try std.testing.expect(std.mem.indexOf(u8, out, "keybind = Cmd+W = unbind") != null); // 신규 추가
    var cnt: usize = 0; // Cmd+T unbind 줄은 정확히 1개(중복 누적 안 됨)
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| if (std.mem.eql(u8, std.mem.trim(u8, ln, &std.ascii.whitespace), "keybind = Cmd+T = unbind")) {
        cnt += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), cnt);
}

test "parse: window padding defaults to left/right=8, top/bottom=4; bad/out-of-range values are forgiving" {
    // 키 없으면 기본 좌우 8·상하 4(사실상 표준 inset).
    var d = try parse(std.testing.allocator, "font.size = 14");
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 8), d.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 8), d.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 4), d.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 4), d.config.window_padding_bottom);
    // 0은 유효(셀이 가장자리에 붙음). 비정수·256 초과는 기본값 유지 + diagnostic.
    var p = try parse(std.testing.allocator,
        \\window.padding-x = 0
        \\window.padding-y = abc
        \\window.padding-x = 999
    );
    defer p.deinit();
    // 첫 줄 x=0 → left=right=0; 셋째 줄 x=999는 거부돼 0 유지(left·right 둘 다).
    try std.testing.expectEqual(@as(u32, 0), p.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 0), p.config.window_padding_right);
    // y=abc 거부 → 상하 기본 4 유지.
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_bottom);
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len); // abc + 999 두 건
}

test "parse: window padding 4-way individual keys (top/right/bottom/left)" {
    var p = try parse(std.testing.allocator,
        \\window.padding-top = 1
        \\window.padding-right = 2
        \\window.padding-bottom = 3
        \\window.padding-left = 4
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 1), p.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 2), p.config.window_padding_right);
    try std.testing.expectEqual(@as(u32, 3), p.config.window_padding_bottom);
    try std.testing.expectEqual(@as(u32, 4), p.config.window_padding_left);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    // 개별 키 forgiving: 비정수는 그 한 필드만 기본 유지 + diagnostic(나머지 정상).
    var f = try parse(std.testing.allocator,
        \\window.padding-top = nope
        \\window.padding-left = 20
    );
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 4), f.config.window_padding_top); // nope 거부 → 기본 4
    try std.testing.expectEqual(@as(u32, 20), f.config.window_padding_left);
    try std.testing.expectEqual(@as(usize, 1), f.diagnostics.len);
}

test "parse: padding-x sets left+right (alias); last line wins when aliasing mixes with explicit keys" {
    // x는 left·right 둘 다 같은 값으로 설정(대칭 alias).
    var a = try parse(std.testing.allocator, "window.padding-x = 10");
    defer a.deinit();
    try std.testing.expectEqual(@as(u32, 10), a.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), a.config.window_padding_right);
    // 마지막 줄 우선(loader 순차 적용): padding-x=10 다음 padding-left=20 → left=20, right=10(x가 깐 값 유지).
    // 베이스/결정: 비대칭 padding엔 단일 표준이 없어, 사실상 표준 키 순서 의미(나중 키가 덮어씀)를 채택.
    var m = try parse(std.testing.allocator,
        \\window.padding-x = 10
        \\window.padding-left = 20
    );
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 20), m.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), m.config.window_padding_right);
    // 반대 순서: padding-left=20 먼저 깔고 padding-x=10이 left·right 둘 다 10으로 덮는다(마지막 줄 우선).
    var r = try parse(std.testing.allocator,
        \\window.padding-left = 20
        \\window.padding-x = 10
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 10), r.config.window_padding_left);
    try std.testing.expectEqual(@as(u32, 10), r.config.window_padding_right);
    // y alias도 동일하게 top+bottom 동시.
    var y = try parse(std.testing.allocator,
        \\window.padding-y = 6
        \\window.padding-bottom = 12
    );
    defer y.deinit();
    try std.testing.expectEqual(@as(u32, 6), y.config.window_padding_top);
    try std.testing.expectEqual(@as(u32, 12), y.config.window_padding_bottom);
}

test "parse: font.line-height parses valid; out-of-range/non-numeric is forgiving (keeps default 1.0)" {
    const defaults = theme.Config{};
    {
        var p = try parse(std.testing.allocator, "font.line-height = 1.5\n"); // 유효(소수 배수)
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 1.5), p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = 0.4\n"); // 0.5 미만 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = 4\n"); // 3.0 초과 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.line-height = tall\n"); // 비숫자 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.line_height, p.config.font.line_height);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: font.letter-spacing parses valid (incl. negative); out-of-range/non-numeric is forgiving" {
    const defaults = theme.Config{};
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = 2.5\n"); // 양수 유효
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 2.5), p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = -1.5\n"); // 음수 유효(칸 좁힘)
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, -1.5), p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = -16\n"); // -8 미만 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = 64\n"); // 32 초과 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "font.letter-spacing = wide\n"); // 비숫자 → 거부
        defer p.deinit();
        try std.testing.expectEqual(defaults.font.letter_spacing, p.config.font.letter_spacing);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: comments and blank lines are ignored; family keeps internal spaces" {
    var p = try parse(std.testing.allocator,
        \\
        \\   # a comment
        \\font.family =   Comic Code   Ligatures
        \\
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("Comic Code   Ligatures", p.config.font.family);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: bundled Jetendard family is accepted by font.family" {
    var p = try parse(std.testing.allocator,
        \\font.family = Jetendard
    );
    defer p.deinit();

    // 이 테스트가 증명하는 것: 번들 목록에 등록한 Jetendard를 사용자가 config 파일에
    // 직접 지정해도 일반적인 자유 문자열 font.family 경로가 값을 보존한다.
    try std.testing.expectEqualStrings("Jetendard", p.config.font.family);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: forgiving — unknown key and bad values keep defaults with diagnostics" {
    const defaults: theme.Config = .{};
    var p = try parse(std.testing.allocator,
        \\font.size = huge
        \\cursor.shape = triangle
        \\cursor.blink = maybe
        \\cursor.color = nope
        \\theme.background = not-a-color
        \\nonsense.key = 1
        \\missing equals
    );
    defer p.deinit();
    // 잘못된 값은 전부 기본값 유지.
    try std.testing.expectEqual(defaults.font.size, p.config.font.size);
    try std.testing.expectEqual(defaults.cursor.shape, p.config.cursor.shape);
    try std.testing.expectEqual(defaults.cursor.blink, p.config.cursor.blink);
    try std.testing.expectEqual(defaults.cursor.color, p.config.cursor.color); // 틀린 색은 null 유지(미지정)
    try std.testing.expectEqualStrings(defaults.theme.background, p.config.theme.background);
    // 7개 문제 줄 각각 diagnostic(cursor.color=nope·누락 '=' 포함).
    try std.testing.expectEqual(@as(usize, 7), p.diagnostics.len);
}

test "parse: theme.palette.N parses ANSI 16 overrides; out-of-range/bad index/color are forgiving" {
    const defaults: theme.Config = .{};
    var p = try parse(std.testing.allocator,
        \\theme.palette.0 = #ff0000
        \\theme.palette.15 = #00ff00
        \\theme.palette.16 = #abcdef
        \\theme.palette.7 = not-a-color
        \\theme.palette.x = #112233
    );
    defer p.deinit();
    // 유효한 인덱스(0, 15)는 색을 담는다.
    try std.testing.expectEqualStrings("#ff0000", p.config.theme.palette[0].?);
    try std.testing.expectEqualStrings("#00ff00", p.config.theme.palette[15].?);
    // 범위 밖 인덱스(16)·잘못된 색(7)·비정수 인덱스(x)는 forgiving — 그 인덱스는 null 유지(기본 xterm).
    try std.testing.expect(p.config.theme.palette[7] == null);
    // override 안 한 다른 인덱스도 기본값(null) 유지.
    try std.testing.expectEqual(defaults.theme.palette[1], p.config.theme.palette[1]);
    // 문제 줄 3개(인덱스 16 범위 밖, 인덱스 7 색 형식, 인덱스 x 비정수) 각각 diagnostic.
    try std.testing.expectEqual(@as(usize, 3), p.diagnostics.len);

    // 파싱된 config는 resolve가 실패하지 않아야 한다(valid 색만 담기므로) + override가 ResolvedTheme까지 전파.
    const ra = try appearance.resolve(p.config);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0xff, .g = 0x00, .b = 0x00 }), ra.theme.palette[0]);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }), ra.theme.palette[15]);
    try std.testing.expect(ra.theme.palette[7] == null); // 잘못된 색은 안 담겨 기본 폴백
}

test "parse: theme.preset selects a named color theme as base; individual theme.* keys override" {
    const defaults: theme.Config = .{};

    // ghostty 프리셋: 배경/전경 + ANSI 16색이 Ghostty 기본색으로 깔린다(xterm 표준과 다름).
    var g = try parse(std.testing.allocator, "theme.preset = ghostty");
    defer g.deinit();
    try std.testing.expectEqualStrings("#282c34", g.config.theme.background);
    try std.testing.expectEqualStrings("#ffffff", g.config.theme.foreground);
    try std.testing.expectEqualStrings("#1d1f21", g.config.theme.palette[0].?); // Ghostty black
    try std.testing.expectEqualStrings("#eaeaea", g.config.theme.palette[15].?); // Ghostty bright white
    try std.testing.expectEqual(@as(usize, 0), g.diagnostics.len);

    // maru 프리셋 = struct default(기본 테마). 명시해도 기본값과 같고, 팔레트는 xterm 표준 폴백(null).
    var m = try parse(std.testing.allocator, "theme.preset = maru");
    defer m.deinit();
    try std.testing.expectEqualStrings(defaults.theme.background, m.config.theme.background);
    try std.testing.expect(m.config.theme.palette[0] == null);
    try std.testing.expectEqual(@as(usize, 0), m.diagnostics.len);

    // 프리셋은 base — 그 뒤 개별 theme.* 키가 일부만 override(순차 적용, 나중 줄 우선).
    var o = try parse(std.testing.allocator,
        \\theme.preset = ghostty
        \\theme.background = #000000
    );
    defer o.deinit();
    try std.testing.expectEqualStrings("#000000", o.config.theme.background); // override
    try std.testing.expectEqualStrings("#ffffff", o.config.theme.foreground); // 프리셋 유지
    try std.testing.expectEqualStrings("#1d1f21", o.config.theme.palette[0].?); // 프리셋 팔레트 유지

    // 알 수 없는 프리셋은 forgiving — maru 기본 유지 + diagnostic 1건.
    var b = try parse(std.testing.allocator, "theme.preset = bogus");
    defer b.deinit();
    try std.testing.expectEqualStrings(defaults.theme.background, b.config.theme.background);
    try std.testing.expectEqual(@as(usize, 1), b.diagnostics.len);

    // 파싱된 ghostty config는 resolve가 성공해야 한다(색 전부 유효) + background/palette가 ResolvedTheme까지 전파.
    const ra = try appearance.resolve(g.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x28, .g = 0x2c, .b = 0x34 }, ra.theme.background);
    try std.testing.expectEqual(@as(?terminal.Rgb, terminal.Rgb{ .r = 0x1d, .g = 0x1f, .b = 0x21 }), ra.theme.palette[0]);
}

test "parse: theme.preset supports all named presets with correct palettes; light themes pin sidebar colors" {
    // 대표 다크 프리셋: 배경 + 특징 팔레트 색.
    var gv = try parse(std.testing.allocator, "theme.preset = gruvbox-dark");
    defer gv.deinit();
    try std.testing.expectEqualStrings("#282828", gv.config.theme.background);
    try std.testing.expectEqualStrings("#fb4934", gv.config.theme.palette[9].?); // gruvbox bright red

    var dr = try parse(std.testing.allocator, "theme.preset = dracula");
    defer dr.deinit();
    try std.testing.expectEqualStrings("#282a36", dr.config.theme.background);
    try std.testing.expectEqualStrings("#bd93f9", dr.config.theme.palette[4].?); // dracula purple

    var sd = try parse(std.testing.allocator, "theme.preset = solarized-dark");
    defer sd.deinit();
    try std.testing.expectEqualStrings("#002b36", sd.config.theme.background);

    var cm = try parse(std.testing.allocator, "theme.preset = catppuccin-mocha");
    defer cm.deinit();
    try std.testing.expectEqualStrings("#1e1e2e", cm.config.theme.background);
    try std.testing.expectEqualStrings("#89b4fa", cm.config.theme.palette[4].?); // mocha blue
    try std.testing.expectEqualStrings("#585b70", cm.config.theme.selection); // 가독성 위해 어두운 surface2(rosewater 아님)

    // 다크 프리셋은 사이드바 명시 안 함(배경에서 파생).
    try std.testing.expect(gv.config.theme.sidebar_background == null);

    // 라이트 프리셋: 사이드바를 배경보다 어둡게 명시(파생 lighten이 라이트 배경에서 흰색이 되는 함정 회피).
    var sl = try parse(std.testing.allocator, "theme.preset = solarized-light");
    defer sl.deinit();
    try std.testing.expectEqualStrings("#fdf6e3", sl.config.theme.background);
    try std.testing.expectEqualStrings("#eee8d5", sl.config.theme.sidebar_background.?);
    try std.testing.expectEqualStrings("#ded8c5", sl.config.theme.sidebar_active.?);

    var cl = try parse(std.testing.allocator, "theme.preset = catppuccin-latte");
    defer cl.deinit();
    try std.testing.expectEqualStrings("#eff1f5", cl.config.theme.background);
    try std.testing.expectEqualStrings("#e6e9ef", cl.config.theme.sidebar_background.?);

    var lp = try parse(std.testing.allocator, "theme.preset = light-pink");
    defer lp.deinit();
    try std.testing.expectEqualStrings("#f5f5f5", lp.config.theme.background); // editor.background
    try std.testing.expectEqualStrings("#54494b", lp.config.theme.cursor); // editorCursor.foreground
    try std.testing.expectEqualStrings("#d6d1e8", lp.config.theme.selection); // editor.selectionBackground
    try std.testing.expectEqualStrings("#f2e7ed", lp.config.theme.sidebar_background.?); // 라이트: 배경보다 핑크로 명시
    // light_pink만의 특징 — search_match*를 테마 findMatch(피치)로 override(라이트에서 다크 앰버는 안 보임). 회귀 가드.
    try std.testing.expectEqualStrings("#fbe0c5", lp.config.theme.search_match); // findMatchHighlight(뷰 안 매치, 옅음)
    try std.testing.expectEqualStrings("#f3d5b9", lp.config.theme.search_match_current); // findMatch(현재, 더 진함)
    try std.testing.expectEqualStrings("#1f6e89", lp.config.theme.palette[6].?); // cyan = strings(틸)
    // black↔white 명암 반전 가드(achromatic 4슬롯): black(0)/bright-black(8)=옅은 모브, white(7)=중간, bright-white(15)=가장 진함.
    try std.testing.expectEqualStrings("#c7b9c1", lp.config.theme.palette[0].?); // black = 옅은 모브-그레이(faint)
    try std.testing.expectEqualStrings("#b3a5ad", lp.config.theme.palette[8].?); // bright-black = 옅음
    try std.testing.expectEqualStrings("#6e6569", lp.config.theme.palette[7].?); // white = 중간-진한 그레이
    try std.testing.expectEqualStrings("#3a3034", lp.config.theme.palette[15].?); // bright-white = 가장 진한 잉크(≠ foreground)
    // light_pink도 resolve 성공(모든 색·팔레트 유효) + 명시 사이드바가 파생 아닌 그 값으로 전파.
    const rlp = try appearance.resolve(lp.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xf5, .g = 0xf5, .b = 0xf5 }, rlp.theme.background);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xf2, .g = 0xe7, .b = 0xed }, rlp.theme.sidebar_background);

    // 라이트 프리셋도 resolve 성공(모든 색 유효) + 명시 사이드바가 ResolvedTheme까지 전파(파생 아님).
    const ra = try appearance.resolve(cl.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xef, .g = 0xf1, .b = 0xf5 }, ra.theme.background);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xe6, .g = 0xe9, .b = 0xef }, ra.theme.sidebar_background);

    // dark_pink: light-pink-theme의 다크 변형. **은은한 다크 로즈**(사용자 피드백으로 톤다운 — 진한 다크 로즈에서 옅은 모브로).
    // 배경/전경 로즈 캐스트 + 커서·선택·사이드바·accent를 소프트 핑크로. accent(탭/포커스 언더바)가 테마색(#ff9ec9)임을 가드 —
    // maru 앰버 고정이 아니라 프리셋별 시그니처. search_match*만 미명시(maru 다크 앰버 — find는 핑크 크롬과 대비). 회귀 가드.
    var dp = try parse(std.testing.allocator, "theme.preset = dark-pink");
    defer dp.deinit();
    try std.testing.expectEqualStrings("#282c34", dp.config.theme.background); // 고스티 실제 배경색(로즈 틴트 없이)
    try std.testing.expectEqualStrings("#ecdce4", dp.config.theme.foreground); // 로즈-화이트
    try std.testing.expectEqualStrings("#f4a8c9", dp.config.theme.cursor); // 파스텔 핑크 커서(accent와 통일)
    try std.testing.expectEqualStrings("#46333f", dp.config.theme.selection); // 다크 로즈 선택
    try std.testing.expect(dp.config.theme.sidebar_background == null); // 사이드바 미명시 → 배경 파생(고스티와 동일 중립 톤, 사용자 요청)
    try std.testing.expectEqualStrings("#8a5369", dp.config.theme.sidebar_active.?); // 활성 카드만 더스티 로즈-핑크(자줏빛 아님·밝은 글자 가독)
    try std.testing.expectEqualStrings("#f4a8c9", dp.config.theme.accent.?); // accent=파스텔 핑크(탭 언더바·커서와 통일 — 앰버 아님)
    try std.testing.expectEqualStrings("#554a1a", dp.config.theme.search_match); // search만 maru 기본 앰버 유지(override 안 함)
    try std.testing.expectEqualStrings("#e83c92", dp.config.theme.palette[1].?); // red = invalid(핫 핑크-레드)
    try std.testing.expectEqualStrings("#f695c6", dp.config.theme.palette[13].?); // bright-magenta = 시그니처 핑크(tag/storage)
    // 다크라 반전 없음: black(0)=배경보다 밝은 웜 다크, bright-white(15)=핑크빛 화이트.
    try std.testing.expectEqualStrings("#3a3436", dp.config.theme.palette[0].?);
    try std.testing.expectEqualStrings("#f6eef2", dp.config.theme.palette[15].?);
    // 명시 사이드바·accent가 파생/기본 아닌 그 값으로 ResolvedTheme까지 전파.
    const rdp = try appearance.resolve(dp.config);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x28, .g = 0x2c, .b = 0x34 }, rdp.theme.background);
    try std.testing.expectEqual(terminal.Rgb{ .r = 0x40, .g = 0x44, .b = 0x4c }, rdp.theme.sidebar_background); // 배경 파생(+24) = 고스티와 동일
    try std.testing.expectEqual(terminal.Rgb{ .r = 0xf4, .g = 0xa8, .b = 0xc9 }, rdp.theme.accent); // 테마 accent 전파(앰버 아님)
}

test "parse: theme.preset 신규 프리셋(rose-pine·tokyo-night·nord·one-dark/light) + 라이트 override" {
    const a = std.testing.allocator;
    // 다크 프리셋: 배경/팔레트 표준값, sidebar_*는 null(배경 파생).
    var rp = try parse(a, "theme.preset = rose-pine");
    defer rp.deinit();
    try std.testing.expectEqualStrings("#191724", rp.config.theme.background);
    try std.testing.expectEqualStrings("#eb6f92", rp.config.theme.palette[1].?); // love(red)
    try std.testing.expect(rp.config.theme.sidebar_background == null); // 다크 → 파생

    var tn = try parse(a, "theme.preset = tokyo-night");
    defer tn.deinit();
    try std.testing.expectEqualStrings("#1a1b26", tn.config.theme.background);
    try std.testing.expectEqualStrings("#7aa2f7", tn.config.theme.palette[4].?); // blue

    // nord: 스킴 selection(#eceff4 밝음)을 polar night(#434c5e)로 override(밝은 글자 가독).
    var nd = try parse(a, "theme.preset = nord");
    defer nd.deinit();
    try std.testing.expectEqualStrings("#2e3440", nd.config.theme.background);
    try std.testing.expectEqualStrings("#434c5e", nd.config.theme.selection);

    var od = try parse(a, "theme.preset = one-dark");
    defer od.deinit();
    try std.testing.expectEqualStrings("#21252b", od.config.theme.background);

    // 라이트 프리셋: sidebar_*·search_match* override 명시(라이트 함정 회피).
    var rd = try parse(a, "theme.preset = rose-pine-dawn");
    defer rd.deinit();
    try std.testing.expectEqualStrings("#faf4ed", rd.config.theme.background);
    try std.testing.expectEqualStrings("#f2e9e1", rd.config.theme.sidebar_background.?);
    // override 4값 전부 가드(light_pink/solarized_light 선례 — resolve 가드는 유효 hex만 잡고 값 swap은 못 잡음).
    try std.testing.expectEqualStrings("#cecacd", rd.config.theme.sidebar_active.?);
    try std.testing.expectEqualStrings("#f2dfc9", rd.config.theme.search_match); // 골드 톤(다크 앰버 아님)
    try std.testing.expectEqualStrings("#ead0a3", rd.config.theme.search_match_current);

    var ol = try parse(a, "theme.preset = one-light");
    defer ol.deinit();
    try std.testing.expectEqualStrings("#f9f9f9", ol.config.theme.background);
    try std.testing.expectEqualStrings("#2a2c33", ol.config.theme.cursor); // 스킴 #bbbbbb 대신 진한 잉크(캐럿 가독)
    try std.testing.expectEqualStrings("#eaeaeb", ol.config.theme.sidebar_background.?);
    try std.testing.expectEqualStrings("#dbdbdc", ol.config.theme.sidebar_active.?);
    try std.testing.expectEqualStrings("#f3e6bf", ol.config.theme.search_match);
    try std.testing.expectEqualStrings("#e6cf92", ol.config.theme.search_match_current);
}

test "presetColors: 모든 프리셋이 resolve에 성공(유효 hex 가드 — 새 프리셋 오타 즉시 검출)" {
    // 새 프리셋의 색·16팔레트에 오타 hex(#zzz 등)가 있으면 resolve가 ResolveError를 던져 이 테스트가 깨진다.
    // enum을 inline for로 돌아 모든 변형을 자동 커버한다(프리셋 추가 시 이 테스트는 손대지 않아도 새 프리셋을 검증).
    inline for (@typeInfo(theme.ThemePreset).@"enum".fields) |f| {
        var cfg = theme.Config{};
        cfg.theme = theme.presetColors(@enumFromInt(f.value));
        _ = try appearance.resolve(cfg);
    }
}

test "theme.preset_names_joined: comptime 목록이 enum과 일치(diagnostic drift 가드)" {
    // 수동 나열을 comptime 생성으로 바꾼 리팩토링 가드. **순서 비결합** — 대표 이름이 dashed로 들어갔는지(언더스코어
    // →대시 변환)와 구분자 개수만 본다(enum 재정렬·rename에 안 깨짐; 순서 결합 startsWith/endsWith는 의도적으로 안 씀).
    inline for ([_][]const u8{ "maru", "gruvbox-dark", "tokyo-night", "one-light" }) |name| {
        // 단어 경계까지 본다(부분일치 오탐 방지): "|name|" 또는 양끝. inline이라 name이 comptime → `++` 가능.
        const j = theme.preset_names_joined;
        const ok = std.mem.eql(u8, j, name) or
            std.mem.startsWith(u8, j, name ++ "|") or
            std.mem.endsWith(u8, j, "|" ++ name) or
            std.mem.indexOf(u8, j, "|" ++ name ++ "|") != null;
        try std.testing.expect(ok);
    }
    // 언더스코어가 남아 있으면 변환 실패(dashed 보장).
    try std.testing.expect(std.mem.indexOfScalar(u8, theme.preset_names_joined, '_') == null);
    // 구분자 개수 = 프리셋 수 - 1(빠짐·중복 없음).
    var pipes: usize = 0;
    for (theme.preset_names_joined) |c| {
        if (c == '|') pipes += 1;
    }
    try std.testing.expectEqual(@typeInfo(theme.ThemePreset).@"enum".fields.len - 1, pipes);
}

test "presetColors: 모든 프리셋의 주 색 4-tuple(bg/fg/cursor/selection)이 유일(detectThemePreset 라운드트립 가드)" {
    // detectThemePreset이 주 색 4개로 프리셋을 역식별하므로(first-match-wins), 두 프리셋이 4-tuple을 공유하면 뒤 프리셋이
    // 앞으로 alias돼 GUI 드롭다운 표시·←→ 순환이 깨진다. 새 프리셋이 기존과 4-tuple을 겹치지 않는지 O(n²)로 검사한다.
    const fields = @typeInfo(theme.ThemePreset).@"enum".fields;
    inline for (fields, 0..) |fa, ia| {
        const a = theme.presetColors(@enumFromInt(fa.value));
        inline for (fields, 0..) |fb, ib| {
            if (ib > ia) {
                const b = theme.presetColors(@enumFromInt(fb.value));
                const same = std.ascii.eqlIgnoreCase(a.background, b.background) and
                    std.ascii.eqlIgnoreCase(a.foreground, b.foreground) and
                    std.ascii.eqlIgnoreCase(a.cursor, b.cursor) and
                    std.ascii.eqlIgnoreCase(a.selection, b.selection);
                try std.testing.expect(!same);
            }
        }
    }
}

test "parse: resolved appearance never fails on parsed config (values pre-validated)" {
    var p = try parse(std.testing.allocator,
        \\font.size = 999
        \\theme.cursor = #zzzzzz
    );
    defer p.deinit();
    // 잘못된 값은 default로 걸러졌으므로 resolve가 성공해야 한다.
    _ = try appearance.resolve(p.config);
}

test "loadFile: missing path yields default config, not an error" {
    var p = try loadFile(std.testing.io, std.testing.allocator, "/nonexistent/maru/config-xyz");
    defer p.deinit();
    const defaults: theme.Config = .{};
    try std.testing.expectEqualStrings(defaults.font.family, p.config.font.family);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
}

test "parse: keybind lines become app bindings; bad/duplicate ones are forgiving diagnostics" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+W = close_tab
        \\keybind = Ctrl+Cmd+1 = select_tab:0
        \\keybind = Cmd+T = next_tab
        \\keybind = Bogus+Z = new_tab
        \\keybind = Cmd+Q = launch_rockets
        \\keybind = missing action
    );
    defer p.deinit();
    // 유효한 3개만 바인딩(중복 Cmd+T는 첫 줄 우선, 나머지 3줄은 오류).
    try std.testing.expectEqual(@as(usize, 3), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.new_tab, p.keybindings[0].action);
    try std.testing.expectEqual(action_mod.Action.close_tab, p.keybindings[1].action);
    try std.testing.expectEqual(@as(usize, 0), p.keybindings[2].action.select_tab);
    // 중복 + 잘못된 chord + 알 수 없는 action + '=' 누락 = 4 diagnostic.
    try std.testing.expectEqual(@as(usize, 4), p.diagnostics.len);
    // 중복이 걸러졌으므로 resolver.validate가 통과한다.
    try p.keyBindingResolver().validate();
}

test "parse: keybind = <chord> = unbind collects unbinds; dedups across binds and unbinds" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = unbind
        \\keybind = Cmd+D = unbind
        \\keybind = Cmd+W = close_tab
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+W = unbind
    );
    defer p.deinit();
    // unbind 2개(Cmd+T, Cmd+D), app 바인딩 1개(Cmd+W=close_tab). 뒤의 Cmd+T(new_tab)·Cmd+W(unbind)는 중복이라 무시.
    try std.testing.expectEqual(@as(usize, 2), p.unbinds.len);
    try std.testing.expect(p.unbinds[0].eql(try keybinding.KeyChord.parse("Cmd+T")));
    try std.testing.expect(p.unbinds[1].eql(try keybinding.KeyChord.parse("Cmd+D")));
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.close_tab, p.keybindings[0].action);
    // 중복 2줄(Cmd+T 재바인딩, Cmd+W 언바인드) = 2 diagnostic.
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len);
    // resolver가 unbind를 그대로 받는다(validate 통과).
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 2), resolver.unbinds.len);
}

test "parse: text:/esc:/ctrl: become terminal macros; bad payloads are forgiving" {
    var p = try parse(std.testing.allocator,
        \\keybind = F2 = text:hello
        \\keybind = F4 = esc:[2J
        \\keybind = Cmd+E = ctrl:[
        \\keybind = Cmd+X = ctrl:1
        \\keybind = F3 = text:
        \\keybind = Cmd+Y = ctrl:ab
    );
    defer p.deinit();
    // 유효 3개(text/esc/ctrl). 나머지 3줄은 오류(C0 매핑 없는 ctrl:1, 빈 text:, 여러 글자 ctrl:ab).
    try std.testing.expectEqual(@as(usize, 3), p.terminal_bindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 3), p.diagnostics.len);

    // text:hello → send_text "hello".
    try std.testing.expectEqualStrings("hello", p.terminal_bindings[0].input.send_text);
    // esc:[2J → ESC를 앞에 붙인 send_escape_sequence "\x1b[2J".
    try std.testing.expectEqualStrings("\x1b[2J", p.terminal_bindings[1].input.send_escape_sequence);
    // ctrl:[ → send_control '[' (resolve 시 controlByte로 ESC가 된다).
    try std.testing.expectEqual(@as(u21, '['), p.terminal_bindings[2].input.send_control);

    // resolver가 매크로를 받고 app↔terminal 충돌 없이 validate 통과(세 풀이 같은 dedup).
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 3), resolver.terminal_bindings.len);

    // 실제 resolve: Cmd+E → ctrl:[ → ESC(0x1b) 한 바이트.
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolved = try resolver.resolve(.{ .key = .{ .char = 'e' }, .modifiers = .{ .command = true } }, &buffer, .{});
    try std.testing.expectEqualStrings("\x1b", resolved.terminal_input);
}

test "parse: global: prefix collects global bindings separate from in-app pools" {
    var p = try parse(std.testing.allocator,
        \\keybind = global:Cmd+Alt+Space = toggle_window
        \\keybind = global:Cmd+Alt+T = show_window
        \\keybind = Cmd+T = new_tab
        \\keybind = global:Cmd+Alt+Space = show_window
        \\keybind = global:Cmd+Alt+X = bogus_action
    );
    defer p.deinit();
    // 유효 전역 2개(Space=toggle, T=show). in-app 1개(Cmd+T=new_tab). 나머지 2줄은 오류(중복 Space, bogus action).
    try std.testing.expectEqual(@as(usize, 2), p.global_bindings.len);
    try std.testing.expectEqual(action_mod.GlobalAction.toggle_window, p.global_bindings[0].action);
    try std.testing.expectEqual(action_mod.GlobalAction.show_window, p.global_bindings[1].action);
    try std.testing.expect(p.global_bindings[0].chord.eql(try keybinding.KeyChord.parse("Cmd+Alt+Space")));
    // in-app 풀은 전역과 분리 — Cmd+T(new_tab)는 그대로.
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(action_mod.Action.new_tab, p.keybindings[0].action);
    // 중복 전역 + 알 수 없는 전역 action = 2 diagnostic.
    try std.testing.expectEqual(@as(usize, 2), p.diagnostics.len);
    // 전역은 resolver에 안 들어간다(in-app 전용) — resolver는 keybindings/unbinds/terminal만.
    const resolver = p.keyBindingResolver();
    try resolver.validate();
    try std.testing.expectEqual(@as(usize, 1), resolver.app_bindings.len);
}

test "parse: same chord can be both global and in-app (separate namespaces, no conflict)" {
    var p = try parse(std.testing.allocator,
        \\keybind = global:Cmd+T = toggle_window
        \\keybind = Cmd+T = new_tab
    );
    defer p.deinit();
    // 전역 Cmd+T와 in-app Cmd+T는 다른 네임스페이스(OS 핫키 vs 앱 키 경로) — 둘 다 살고 충돌 없음.
    try std.testing.expectEqual(@as(usize, 1), p.global_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    try p.keyBindingResolver().validate();
}

test "parse: a chord can't be both an app action and a terminal macro (first line wins)" {
    var p = try parse(std.testing.allocator,
        \\keybind = Cmd+T = new_tab
        \\keybind = Cmd+T = text:oops
    );
    defer p.deinit();
    // 첫 줄(app)만 살고 둘째(terminal)는 중복으로 무시 → app↔terminal 충돌이 안 생긴다.
    try std.testing.expectEqual(@as(usize, 1), p.keybindings.len);
    try std.testing.expectEqual(@as(usize, 0), p.terminal_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    try p.keyBindingResolver().validate(); // 충돌 없음
}

test "parse: keybindings empty when none configured; appearance keys unaffected" {
    var p = try parse(std.testing.allocator, "font.size = 13\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.keybindings.len);
    try std.testing.expectEqual(@as(f32, 13), p.config.font.size);
}

test "parse: input.page-keys scroll(default)/passthrough + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.scroll, p.config.input.page_keys); // 기본(Mac 관례)
    }
    {
        var p = try parse(std.testing.allocator, "input.page-keys = passthrough\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.passthrough, p.config.input.page_keys); // opt-in
    }
    {
        var p = try parse(std.testing.allocator, "input.page-keys = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.PageKeys.scroll, p.config.input.page_keys); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: text.ambiguous-width narrow(default)/wide + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.AmbiguousWidth.narrow, p.config.ambiguous_width); // 기본 narrow(정렬 안전)
    }
    {
        var p = try parse(std.testing.allocator, "text.ambiguous-width = wide\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.AmbiguousWidth.wide, p.config.ambiguous_width); // opt-in
    }
    {
        var p = try parse(std.testing.allocator, "text.ambiguous-width = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.AmbiguousWidth.narrow, p.config.ambiguous_width); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: ui.language auto(default)/en/ko + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.UiLanguage.auto, p.config.ui_language); // 기본 auto(현행 화면 보존)
    }
    {
        var p = try parse(std.testing.allocator, "ui.language = ko\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.UiLanguage.ko, p.config.ui_language);
    }
    {
        var p = try parse(std.testing.allocator, "ui.language = en\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.UiLanguage.en, p.config.ui_language);
    }
    {
        var p = try parse(std.testing.allocator, "ui.language = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.UiLanguage.auto, p.config.ui_language); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

// GUI 에서 고른 언어가 **파일에 남는지** 본다. 직렬화는 스키마 주도라 Meta 등록만으로 붙지만,
// 붙었다고 믿는 것과 확인하는 것은 다르다 — 안 붙으면 앱을 다시 켤 때 조용히 되돌아간다.
test "ui.language: 저장한 값이 다시 읽힌다(round-trip)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg: theme.Config = .{};
    cfg.ui_language = .ko;

    const pairs = try @import("serialize.zig").configKeyValues(arena, cfg);
    var found: ?[]const u8 = null;
    for (pairs) |kv| {
        if (std.mem.eql(u8, kv.key, "ui.language")) found = kv.value;
    }
    try std.testing.expectEqualStrings("ko", found orelse return error.KeyNotSerialized);

    var p = try parse(std.testing.allocator, "ui.language = ko\n");
    defer p.deinit();
    try std.testing.expectEqual(theme.UiLanguage.ko, p.config.ui_language);
}

test "parse: input.shift-enter newline(default)/native + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.newline, p.config.input.shift_enter); // 기본(멀티라인 줄바꿈)
    }
    {
        var p = try parse(std.testing.allocator, "input.shift-enter = native\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.native, p.config.input.shift_enter); // opt-out(기존 동작)
    }
    {
        var p = try parse(std.testing.allocator, "input.shift-enter = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ShiftEnter.newline, p.config.input.shift_enter); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: input.ime-enter newline(default)/commit-only + invalid is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.newline, p.config.input.ime_enter); // 기본(확정+개행)
    }
    {
        var p = try parse(std.testing.allocator, "input.ime-enter = commit-only\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.commit_only, p.config.input.ime_enter); // opt-out(조합만 확정)
    }
    {
        var p = try parse(std.testing.allocator, "input.ime-enter = bogus\n");
        defer p.deinit();
        try std.testing.expectEqual(theme.ImeEnter.newline, p.config.input.ime_enter); // 잘못된 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: scrollback.lines + bell.audible (defaults and forgiving)" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines); // 기본
        try std.testing.expectEqual(true, p.config.bell.audible); // 기본
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 5000\n");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 5000), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 0\n"); // 0=비활성, 유효
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 0), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = 999999\n"); // 상한 초과 → 기본 + 진단
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "scrollback.lines = abc\n"); // 비정수 → 기본
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 1000), p.config.scrollback.lines);
    }
    {
        var p = try parse(std.testing.allocator, "bell.audible = false\n");
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.bell.audible);
    }
    {
        var p = try parse(std.testing.allocator, "bell.audible = bogus\n"); // 잘못 → 기본 true + 진단
        defer p.deinit();
        try std.testing.expectEqual(true, p.config.bell.audible);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: shell-integration.ssh (opt-in, default off, forgiving)" {
    {
        var p = try parse(std.testing.allocator, ""); // 기본 off — ssh 라우팅은 명시 opt-in
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.shell_integration.ssh);
    }
    {
        var p = try parse(std.testing.allocator, "shell-integration.ssh = true\n");
        defer p.deinit();
        try std.testing.expectEqual(true, p.config.shell_integration.ssh);
    }
    {
        var p = try parse(std.testing.allocator, "shell-integration.ssh = nope\n"); // 잘못 → 기본 false + 진단
        defer p.deinit();
        try std.testing.expectEqual(false, p.config.shell_integration.ssh);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: ssh.* (maru ssh 끊김 감지·재접속) 기본값·범위·forgiving" {
    {
        var p = try parse(std.testing.allocator, ""); // 미설정 = 45초 안에 감지 + 자동 재접속
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 15), p.config.ssh.server_alive_interval);
        try std.testing.expectEqual(@as(u32, 3), p.config.ssh.server_alive_count_max);
        try std.testing.expectEqual(true, p.config.ssh.reconnect);
    }
    {
        var p = try parse(std.testing.allocator, "ssh.server-alive-interval = 30\nssh.server-alive-count-max = 5\nssh.reconnect = false\n");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 30), p.config.ssh.server_alive_interval);
        try std.testing.expectEqual(@as(u32, 5), p.config.ssh.server_alive_count_max);
        try std.testing.expectEqual(false, p.config.ssh.reconnect);
    }
    {
        // **0은 유효값이다** — "keepalive를 붙이지 마라"는 뜻이고, 그것이 사용자 `~/.ssh/config`를
        // 존중하는 유일한 탈출구다(커맨드라인 `-o`가 설정 파일보다 우선이므로).
        var p = try parse(std.testing.allocator, "ssh.server-alive-interval = 0\n");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 0), p.config.ssh.server_alive_interval);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "ssh.server-alive-interval = 99999\n"); // 범위 밖 → 기본값 + 진단
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 15), p.config.ssh.server_alive_interval);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        // count-max 하한은 1이다 — ssh에서 0은 "즉시 끊어라"라 오작동에 가깝다.
        var p = try parse(std.testing.allocator, "ssh.server-alive-count-max = 0\n");
        defer p.deinit();
        try std.testing.expectEqual(@as(u32, 3), p.config.ssh.server_alive_count_max);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: quick-terminal options (height/auto-hide/screen) with defaults and forgiving" {
    {
        // 기본값.
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.45), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(true, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.main, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.top, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.full, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(false, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(f32, 0), p.config.quick_terminal.width_fraction); // 미설정 → 0(height 따라감)
    }
    {
        var p = try parse(std.testing.allocator,
            \\quick-terminal.height = 0.6
            \\quick-terminal.width = 0.8
            \\quick-terminal.auto-hide = false
            \\quick-terminal.screen = mouse
            \\quick-terminal.position = bottom
            \\quick-terminal.chrome = minimal
            \\quick-terminal.minimal-tabs = true
        );
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.6), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(@as(f32, 0.8), p.config.quick_terminal.width_fraction);
        try std.testing.expectEqual(false, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.mouse, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.bottom, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.minimal, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(true, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
    {
        // 잘못된 값들 → 전부 기본값 유지 + diagnostic.
        var p = try parse(std.testing.allocator,
            \\quick-terminal.height = 2.0
            \\quick-terminal.height = huge
            \\quick-terminal.width = 1.5
            \\quick-terminal.auto-hide = maybe
            \\quick-terminal.screen = projector
            \\quick-terminal.position = diagonal
            \\quick-terminal.chrome = fancy
            \\quick-terminal.minimal-tabs = yes
        );
        defer p.deinit();
        try std.testing.expectEqual(@as(f32, 0.45), p.config.quick_terminal.height_fraction);
        try std.testing.expectEqual(@as(f32, 0), p.config.quick_terminal.width_fraction); // 범위 밖 → 0 유지
        try std.testing.expectEqual(true, p.config.quick_terminal.auto_hide);
        try std.testing.expectEqual(theme.QuickTerminalScreen.main, p.config.quick_terminal.screen);
        try std.testing.expectEqual(theme.QuickTerminalPosition.top, p.config.quick_terminal.position);
        try std.testing.expectEqual(theme.QuickTerminalChrome.full, p.config.quick_terminal.chrome);
        try std.testing.expectEqual(false, p.config.quick_terminal.minimal_tabs);
        try std.testing.expectEqual(@as(usize, 8), p.diagnostics.len);
    }
    {
        // center 위치(가장자리 없이 중앙 페이드).
        var p = try parse(std.testing.allocator, "quick-terminal.position = center");
        defer p.deinit();
        try std.testing.expectEqual(theme.QuickTerminalPosition.center, p.config.quick_terminal.position);
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len);
    }
}

test "parse: term default xterm-maru, override, empty is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-maru", p.config.term); // 전환된 기본값(조건부+폴백은 pty가 처리)
    }
    {
        var p = try parse(std.testing.allocator, "term = xterm-256color\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-256color", p.config.term); // 사용자가 명시로 되돌릴 수 있다
    }
    {
        var p = try parse(std.testing.allocator, "term =   \n");
        defer p.deinit();
        try std.testing.expectEqualStrings("xterm-maru", p.config.term); // 빈 값 → 기본 유지
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "parse: workspace.root default empty, override, empty is forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expectEqualStrings("", p.config.workspace.root); // 기본 = 상속 cwd(빈 문자열)
    }
    {
        // 내부 공백 보존(경로에 공백이 있을 수 있다 — term과 같은 양끝-trim 규칙). `~`는 spawn 시 platform이 확장.
        var p = try parse(std.testing.allocator, "workspace.root = ~/My Projects\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("~/My Projects", p.config.workspace.root);
    }
    {
        var p = try parse(std.testing.allocator, "workspace.root = /Users/me/work\n"); // 절대경로도 허용
        defer p.deinit();
        try std.testing.expectEqualStrings("/Users/me/work", p.config.workspace.root);
    }
    {
        var p = try parse(std.testing.allocator, "workspace.root = ~\n"); // `~` 단독 허용
        defer p.deinit();
        try std.testing.expectEqualStrings("~", p.config.workspace.root);
    }
    {
        // **구분자를 입구에서 정규화한다**(§5 규칙 1). Windows 사용자는 native 로 적는 것이 자연스러운데,
        // 그대로 두면 L2 가 `/` 로 이어 붙인 결과와 섞여 `C:\proj/docs` 가 된다.
        //
        // **호스트에 따라 답이 다르다** — POSIX 에서 `\` 는 파일 이름 글자라 바꾸면 다른 파일을 가리킨다.
        // 그래서 두 갈래를 각각 단언한다(규칙 자체는 `path_shape` 가 OS 를 인자로 받아 모든 타깃에서
        // 테스트된다 — 여기서는 로더가 그것을 **실제로 부르는지**를 본다).
        // **"어느 호스트가 이 값을 받는가" 를 손으로 적지 않는다.** 처음엔 POSIX 에서도 원본이 남을
        // 것으로 단언했다가 Linux CI 가 잡았다 — 거기서 `C:\proj\sub` 는 절대경로가 아니라
        // `isValidWorkspaceRoot` 가 **거부**하고 기본값을 유지한다(정규화까지 가지도 않는다).
        // 그래서 수용 여부는 로더가 쓰는 그 술어에서 **유도**하고, 이 테스트는 **정규화만** 단언한다.
        const windows = @import("builtin").os.tag == .windows;
        for ([_][]const u8{ "C:\\proj\\sub", "/proj\\sub" }) |raw| {
            const line = try std.fmt.allocPrint(std.testing.allocator, "workspace.root = {s}\n", .{raw});
            defer std.testing.allocator.free(line);
            var p = try parse(std.testing.allocator, line);
            defer p.deinit();
            if (!isValidWorkspaceRoot(raw)) {
                try std.testing.expectEqualStrings("", p.config.workspace.root); // 거부 → 기본값 유지
                continue;
            }
            if (windows) {
                try std.testing.expect(std.mem.indexOfScalar(u8, p.config.workspace.root, '\\') == null);
            } else {
                try std.testing.expectEqualStrings(raw, p.config.workspace.root); // POSIX 는 무동작
            }
        }
    }
    {
        var p = try parse(std.testing.allocator, "workspace.root =   \n");
        defer p.deinit();
        try std.testing.expectEqualStrings("", p.config.workspace.root); // 빈 값 → 기본 유지 + 진단
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        // 상대경로·`~user`는 spawn 시 무시되므로 parse-time에 거른다(forgiving+diagnostic) — 조용히 무동작 방지.
        var p = try parse(std.testing.allocator, "workspace.root = projects\n");
        defer p.deinit();
        try std.testing.expectEqualStrings("", p.config.workspace.root); // 형식 불량 → 기본 유지 + 진단
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
    {
        var p = try parse(std.testing.allocator, "workspace.root = ~bob/work\n"); // `~user`는 확장 불가 → 거부
        defer p.deinit();
        try std.testing.expectEqualStrings("", p.config.workspace.root);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "isValidWorkspaceRoot: 절대경로·~/…만 통과 (loader·GUI 공유 형식 규칙)" {
    // 통과: 절대경로, `~` 단독, `~/…`.
    try std.testing.expect(isValidWorkspaceRoot("/Users/me/work"));
    try std.testing.expect(isValidWorkspaceRoot("~"));
    try std.testing.expect(isValidWorkspaceRoot("~/projects"));
    try std.testing.expect(isValidWorkspaceRoot("/")); // 루트도 절대경로
    // 거부: 빈 값·상대경로·`~user`(다른 사용자).
    try std.testing.expect(!isValidWorkspaceRoot(""));
    try std.testing.expect(!isValidWorkspaceRoot("projects"));
    try std.testing.expect(!isValidWorkspaceRoot("./rel"));
    try std.testing.expect(!isValidWorkspaceRoot("~bob/work"));
}

test "parse: workspace.tab/split-inherit-cwd 기본 true, override, forgiving" {
    {
        var p = try parse(std.testing.allocator, "");
        defer p.deinit();
        try std.testing.expect(p.config.workspace.tab_inherit_cwd); // 기본 상속(Ghostty 기본과 동일)
        try std.testing.expect(p.config.workspace.split_inherit_cwd);
    }
    {
        var p = try parse(std.testing.allocator, "workspace.tab-inherit-cwd = false\nworkspace.split-inherit-cwd = false\n");
        defer p.deinit();
        try std.testing.expect(!p.config.workspace.tab_inherit_cwd); // 끄면 새 탭/Term이 root에서 열림
        try std.testing.expect(!p.config.workspace.split_inherit_cwd);
    }
    {
        var p = try parse(std.testing.allocator, "workspace.tab-inherit-cwd = nope\n"); // 비-불리언 → 기본 + 진단
        defer p.deinit();
        try std.testing.expect(p.config.workspace.tab_inherit_cwd);
        try std.testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    }
}

test "SC3 theme.syntax.<역할>: 유효 색은 실리고, 틀린 색·모르는 역할은 forgiving" {
    const a = std.testing.allocator;
    var parsed = try parse(a,
        \\theme.syntax.keyword = #c678dd
        \\theme.syntax.comment = #5c6370
        \\theme.syntax.type = #56b6c2
        \\theme.syntax.string = nope
        \\theme.syntax.bogus = #ffffff
    );
    defer parsed.deinit();
    const t = parsed.config.theme;
    try std.testing.expectEqualStrings("#c678dd", t.syntax[@intFromEnum(theme.SyntaxRole.keyword)].?);
    try std.testing.expectEqualStrings("#5c6370", t.syntax[@intFromEnum(theme.SyntaxRole.comment)].?);
    // 사용자 키는 `type`이고 필드는 `type_name`이다 — 그 사상이 여기서도 성립한다.
    try std.testing.expectEqualStrings("#56b6c2", t.syntax[@intFromEnum(theme.SyntaxRole.type_name)].?);
    // 틀린 색은 그 역할을 **파생인 채로** 둔다(끄지 않는다).
    try std.testing.expect(t.syntax[@intFromEnum(theme.SyntaxRole.string)] == null);
    // 진단이 둘(틀린 색·모르는 역할) — 조용히 삼키지 않는다.
    try std.testing.expect(parsed.diagnostics.len >= 2);
}

test "SC6 theme.preset 이 뒤 줄에 오면 구문 색 override 가 지워진다 (순차 적용)" {
    // **이 동작은 지금 우연히 성립한다** — preset 핸들러가 `config.theme`를 통째로 깔기 때문이다.
    // 누가 그것을 "필드 병합"으로 바꾸면 팔레트·구문 색의 규칙이 **말없이** 달라진다. 규칙을 고정한다
    // (native-editor-ui.md §9.0 — 팔레트와 같은 규율).
    const a = std.testing.allocator;
    var after = try parse(a,
        \\theme.syntax.keyword = #c678dd
        \\theme.preset = dracula
    );
    defer after.deinit();
    try std.testing.expect(after.config.theme.syntax[@intFromEnum(theme.SyntaxRole.keyword)] == null);

    // 앞 줄에 오면 살아남는다(나중 줄 우선).
    var before = try parse(a,
        \\theme.preset = dracula
        \\theme.syntax.keyword = #c678dd
    );
    defer before.deinit();
    try std.testing.expectEqualStrings("#c678dd", before.config.theme.syntax[@intFromEnum(theme.SyntaxRole.keyword)].?);
}

test "PAL1 팔레트는 문서가 광고하는 범위와 로더가 받는 범위가 같다" {
    // **문서 게이트가 이 열여섯을 못 본다.** `configuration.md` 키 표를 읽는 두 게이트(config 문서 정합성
    // A, 모바일 키 커버리지)는 행마다 **첫 백틱 토큰 하나만** 뽑으므로, 압축 행으로 적힌
    // `theme.palette.0`~`theme.palette.15` 중 **`.0`만** 검사된다(2026-08-29 실측). 나머지 열다섯은
    // 문서가 광고만 하고 아무도 안 지키는 상태였다.
    //
    // 키를 하나씩 문자열로 찾는 방식은 여기서 안 통한다 — 압축 행에는 양 끝(`.0`·`.15`)만 적혀 있다.
    // 그래서 **계약 자체**를 잰다: 문서가 적은 범위 표기와 로더가 실제로 받는 범위가 같은가.
    // 한쪽만 바꾸면 이 판정자가 죽는다.
    //
    // 구문 색(`SC1`)이 같은 구멍을 다른 방법으로 막는다 — 그쪽은 키가 열하나 다 적혀 있어 문자열로 센다.
    const doc = @embedFile("config_doc_md");
    try std.testing.expect(std.mem.indexOf(u8, doc, "`theme.palette.0`~`theme.palette.15`") != null);

    const a = std.testing.allocator;
    // ⑴ 문서가 적은 두 끝과 그 사이가 전부 실린다.
    for (0..16) |i| {
        const line = try std.fmt.allocPrint(a, "theme.palette.{d} = #010203", .{i});
        defer a.free(line);
        var p = try parse(a, line);
        defer p.deinit();
        if (p.config.theme.palette[i] == null) {
            std.debug.print("문서가 광고한 theme.palette.{d} 를 로더가 안 받는다\n", .{i});
            try std.testing.expect(false);
        }
        try std.testing.expectEqual(@as(usize, 0), p.diagnostics.len); // 조용히 받는다
    }
    // ⑵ 범위 밖은 받지 않고 **진단을 남긴다**(조용히 삼키면 사용자가 오타를 못 찾는다).
    var over = try parse(a, "theme.palette.16 = #010203");
    defer over.deinit();
    try std.testing.expect(over.diagnostics.len > 0);
    for (over.config.theme.palette) |c| try std.testing.expect(c == null);
}
