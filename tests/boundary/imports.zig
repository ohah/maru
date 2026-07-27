const std = @import("std");

// 이 테스트는 docs/implementation-plan.md의 facade import 경계를 강제한다.
// Maru 아키텍처 전체는 TerminalCore가 PTY/platform/renderer를 모른다는 전제 위에
// 서 있다(clean-room VT 코어를 교체 가능하고 headless로 테스트 가능하게 유지하기
// 위해서다). "리뷰에서 조심한다"는 규칙만으로는 이를 보장할 수 없으므로, 한 레이어가
// 금지된 레이어를 import하는 순간 빌드를 실패시킨다.
//
// 금지에는 두 종류가 있다(implementation-plan.md "1단계 boundary checker 최소 요구사항"의 초기 금지 규칙).
//   - 레이어 전체 금지: 공개 barrel("layer.zig")과 구현 디렉터리("layer/...") 모두 금지.
//     예) terminal -> pty/platform/renderer, renderer -> pty, plugin -> pty.
//   - private 구현만 금지: 구현 디렉터리("layer/...")만 금지하고 공개 barrel은 허용.
//     예) pty/plugin -> terminal. pty는 terminal.Size 같은 공개 타입은 써도 되지만
//     terminal/core.zig 같은 내부 구현은 만지면 안 된다.
//
// 새 파일이 추가될 때마다 이 테스트 파일을 고치는 방식은 쉽게 빠뜨린다.
// 그래서 facade barrel 파일은 명시하되, 구현 폴더는 재귀적으로 훑어 새
// `*.zig` 파일도 자동으로 경계 검사를 받게 한다.

const Forbidden = struct {
    layer: []const u8,
    // true이면 구현 디렉터리("layer/...")만 금지하고 공개 barrel("layer.zig")은 허용한다.
    private_only: bool = false,
};

const Rule = struct {
    layer: []const u8,
    barrel: []const u8,
    implementation_dir: []const u8,
    forbidden: []const Forbidden,
};

const rules = [_]Rule{
    .{
        // terminal(L1 VT 코어)의 facade 계약(docs/facade-contracts.md TerminalCore "몰라야 하는 것"): PTY/platform
        // API·renderer/GPU뿐 아니라 **workspace/tab/split·plugin runtime**도 몰라야 한다. workspace/tab/split은 3차
        // 추출로 session(L2)에 있으므로 session을, plugin runtime은 plugin을 각각 금지해 "L1은 위 레이어를 모른다"를
        // 강제한다(과거엔 pty/platform/renderer만 막아 terminal→session/plugin이 뚫려 있었다 — 문서화됐으나 미강제).
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "renderer" },
            .{ .layer = "session" }, // workspace/tab/split 모델이 사는 곳 — L1이 L2를 import하면 위상 역전
            .{ .layer = "plugin" }, // plugin runtime을 몰라야 한다(facade-contracts.md:28)
        },
    },
    .{
        // renderer(L1 중립 frame 계약)는 위상의 바닥이다 — terminal snapshot을 DrawList·Glyph*Frame으로 바꾸는
        // 백엔드-무관 도메인. OS 백엔드(platform·pty)도, 위 레이어(session·chrome)도, 앱 런타임(app)도 import하면
        // 안 된다(아래로만 의존 — terminal·color·std만 허용). WebGPU/다른 OS 백엔드가 같은 frame 계약을 재사용
        // 하려면 L1이 OS·상위에 안 묶여야 한다(docs/layering-and-portability.md §2·§8, renderer-strategy.md).
        .layer = "renderer",
        .barrel = "src/renderer.zig",
        .implementation_dir = "src/renderer",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "session" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // chrome(L3 디자인 시스템)은 플랫폼 중립이어야 한다 — semantic ChromeDraw만 뱉고 session을 **props로만**
        // 읽는다(raw *Pane/*Split·session 모듈을 import하지 않는다). OS/렌더 백엔드(platform·pty), 코어 내부
        // (terminal·renderer), 세션·앱 런타임(session·app)을 import하면 props-only seam과 이식성이 깨지므로 빌드
        // 에서 막는다(docs/layering-and-portability.md §2·§8). 허용: std, color(top-level), 자기 하위 모듈.
        // session 금지는 C1~C3 이주에서 chrome 컴포넌트가 session을 직접 만지지 않고 props만 쓰게 강제한다.
        .layer = "chrome",
        .barrel = "src/chrome.zig",
        .implementation_dir = "src/chrome",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "terminal" },
            .{ .layer = "renderer" },
            .{ .layer = "session" },
            .{ .layer = "app" },
        },
    },
    .{
        // session(L2 세션 코어)은 OS-중립이어야 한다 — 순수 모델·연산·입력 수학만. platform(L4 OS 어댑터)과
        // pty(OS 프로세스)를 직접 import하면 이식성이 깨지므로 막는다(docs/layering-and-portability.md §2·§8).
        // renderer(L1)는 의존 방향이 L2→L1이라 허용한다(금지 안 함). terminal(중립 입력 타입)도 허용. chrome(L3)은
        // 위 레이어라 금지한다(L2가 L3를 import하면 위상 역전).
        //
        // session→app 금지(D3, 3차 추출 완료): 세션 모델이 쓰던 app의 중립 타입(Surface·split_tree·workspace·
        // window·core_command)을 3차(D1·D2)로 session으로 옮겨 session→app 직접 의존이 0이 됐다. 이제 app을
        // 통째 금지해 의존 소거를 가드로 고정한다(과거엔 "app 경유 중립 타입"이 컨벤션이었으나 이제 강제 —
        // docs/app-layer-decomposition.md). app.zig는 pty·platform을 transitive로 끌어오므로, app 금지가 곧 그
        // 차단이기도 하다(직접 @import만 보는 한계는 동일하나, session→app=0이면 transitive 누수 경로가 닫힌다).
        .layer = "session",
        .barrel = "src/session.zig",
        .implementation_dir = "src/session",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // plugin(future Wasm 경계)의 facade 계약(docs/facade-contracts.md:290-291): plugin은 domain event·action
        // facade로만 상호작용하고, TerminalCore private storage·PTY handle·**renderer resource**를 직접 받지 않는다.
        // 그래서 pty(전체)·terminal(private 구현)에 더해 renderer(전체 — 프레임/atlas/GPU resource)를 금지한다
        // (문서화됐으나 pty/terminal만 막혀 plugin→renderer가 뚫려 있었다). plugin은 현재 registry stub이라 위반 0.
        .layer = "plugin",
        .barrel = "src/plugin.zig",
        .implementation_dir = "src/plugin",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "terminal", .private_only = true },
            .{ .layer = "renderer" }, // renderer resource(프레임·atlas·GPU)를 직접 받지 않는다(facade-contracts.md:291)
        },
    },
    .{
        .layer = "pty",
        .barrel = "src/pty.zig",
        .implementation_dir = "src/pty",
        .forbidden = &.{.{ .layer = "terminal", .private_only = true }},
    },
};

test "facade layers do not import forbidden layers" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;

    for (rules) |rule| {
        try checkFile(allocator, rule, rule.barrel, &violations);
        try checkDirectory(allocator, rule, rule.implementation_dir, &violations);
    }

    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "provider cleanup module remains absent" {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, "src/platform/macos/agent_hook_cleanup.zig", .{}),
    );
}

test "session host client pump policy imports only std" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_pump.zig",
    );
    defer allocator.free(source);

    var imports: usize = 0;
    var import_builtins: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import");
                if (saw_import) import_builtins += 1;
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
            },
            .string_literal => {
                if (saw_import and saw_paren) {
                    imports += 1;
                    try std.testing.expectEqualStrings(
                        "\"std\"",
                        source[token.loc.start..token.loc.end],
                    );
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                if (saw_import and token.tag != .doc_comment) {
                    saw_import = false;
                    saw_paren = false;
                }
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 1), import_builtins);
    try std.testing.expectEqual(@as(usize, 1), imports);
    try std.testing.expect(!containsForbiddenExternalBuiltin(source));
    try std.testing.expect(!containsForbiddenPumpToken(source));
    try std.testing.expect(!containsForbiddenStdChild(source));

    const forbidden_fixture: [:0]const u8 =
        \\const std = @import("std");
        \\const Leaked = std.mem.Allocator;
    ;
    try std.testing.expect(containsForbiddenPumpToken(forbidden_fixture));
    const forbidden_heap: [:0]const u8 =
        \\const std = @import("std");
        \\const allocator = std.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_heap));
    const forbidden_os: [:0]const u8 =
        \\const std = @import("std");
        \\const os = std.os;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_os));
    const forbidden_fs: [:0]const u8 =
        \\const std = @import("std");
        \\const Handle = std.fs.File.Handle;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fs));
    const forbidden_c_import: [:0]const u8 =
        \\const c = @cImport({ @cInclude("unistd.h"); });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_c_import));
    const forbidden_import_alias: [:0]const u8 =
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_import_alias));
    const forbidden_bare_alias: [:0]const u8 =
        \\const std = @import("std");
        \\const system = std;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_bare_alias));
    const forbidden_std_field: [:0]const u8 =
        \\const std = @import("std");
        \\const heap = @field(std, "heap");
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_std_field));
    const forbidden_extern: [:0]const u8 =
        \\extern fn close(fd: i32) c_int;
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern));
    const forbidden_extern_builtin: [:0]const u8 =
        \\const errno = @extern(*i32, .{ .name = "errno" });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern_builtin));
    const forbidden_fake_std: [:0]const u8 =
        \\const std = 1;
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fake_std));
}

fn containsForbiddenExternalBuiltin(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .keyword_extern, .keyword_asm => return true,
            .builtin => {
                const builtin_name = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, builtin_name, "@cImport") or
                    std.mem.eql(u8, builtin_name, "@cInclude") or
                    std.mem.eql(u8, builtin_name, "@embedFile") or
                    std.mem.eql(u8, builtin_name, "@extern"))
                    return true;
            },
            else => {},
        }
    }
}

test "session host external pump facade callsites stay in the final owner boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const allowed = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        );
        if (allowed) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expect(!containsFacadeAccess(source));
    }

    const forbidden_identifier: [:0]const u8 =
        \\const Leak = module.ExternalPumpFacade;
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_identifier));
    const forbidden_field: [:0]const u8 =
        \\const Leak = @field(module, "ExternalPumpFacade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_field));
    const forbidden_import: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/client_external_pump.zig");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_import));
    const forbidden_computed: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/" ++ "client_" ++ "external_" ++ "pump." ++ "zig");
        \\const Leak = @field(pump, "External" ++ "Pump" ++ "Facade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_computed));
}

fn containsForbiddenStdChild(source: [:0]const u8) bool {
    if (!hasExactCanonicalStdImport(source)) return true;
    const allowed = [_][]const u8{ "math", "meta", "testing" };
    var tokenizer = std.zig.Tokenizer.init(source);
    const AfterStd = enum { none, declaration, selector };
    var after_std: AfterStd = .none;
    var expect_child = false;
    var previous_const = false;
    var canonical_bindings: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (after_std != .none) {
            switch (after_std) {
                .declaration => {
                    if (token.tag != .equal) return true;
                    canonical_bindings += 1;
                },
                .selector => {
                    if (token.tag != .period) return true;
                    expect_child = true;
                },
                .none => unreachable,
            }
            after_std = .none;
            previous_const = false;
            continue;
        }
        if (expect_child) {
            if (token.tag != .identifier) return true;
            const child = source[token.loc.start..token.loc.end];
            var accepted = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, child, name)) {
                    accepted = true;
                    break;
                }
            }
            if (!accepted) return true;
            expect_child = false;
            previous_const = false;
            continue;
        }
        switch (token.tag) {
            .eof => return canonical_bindings != 1,
            .keyword_const => {
                previous_const = true;
            },
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, identifier, "std")) {
                    after_std = if (previous_const) .declaration else .selector;
                }
                previous_const = false;
            },
            else => {
                previous_const = false;
            },
        }
    }
}

fn hasExactCanonicalStdImport(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var state: u4 = 0;
    var matches: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return matches == 1 and state == 0;
        const text = source[token.loc.start..token.loc.end];
        const matched = switch (state) {
            0 => token.tag == .keyword_const,
            1 => token.tag == .identifier and std.mem.eql(u8, text, "std"),
            2 => token.tag == .equal,
            3 => token.tag == .builtin and std.mem.eql(u8, text, "@import"),
            4 => token.tag == .l_paren,
            5 => token.tag == .string_literal and std.mem.eql(u8, text, "\"std\""),
            6 => token.tag == .r_paren,
            7 => token.tag == .semicolon,
            else => unreachable,
        };
        if (matched) {
            state += 1;
            if (state == 8) {
                matches += 1;
                state = 0;
            }
        } else {
            state = if (token.tag == .keyword_const) 1 else 0;
        }
    }
}

fn containsForbiddenPumpToken(source: [:0]const u8) bool {
    const forbidden = [_][]const u8{
        "posix",
        "c",
        "json",
        "mem",
        "Allocator",
        "FrameParser",
        "ExternalInboxLedger",
    };
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                for (forbidden) |name| {
                    if (std.mem.eql(u8, identifier, name)) return true;
                }
            },
            else => {},
        }
    }
}

fn containsFacadeAccess(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_client_external = false;
    var saw_pump_file = false;
    var saw_external_pump = false;
    var saw_facade = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return (saw_client_external and saw_pump_file) or
                (saw_external_pump and saw_facade) or
                joinedStringLiteralsContain(source, "client_external_pump.zig") or
                joinedStringLiteralsContain(source, "ExternalPumpFacade"),
            .identifier => {
                if (std.mem.eql(
                    u8,
                    source[token.loc.start..token.loc.end],
                    "ExternalPumpFacade",
                )) return true;
            },
            .string_literal => {
                const literal = source[token.loc.start..token.loc.end];
                saw_client_external = saw_client_external or
                    std.mem.indexOf(u8, literal, "client_external_") != null;
                saw_pump_file = saw_pump_file or
                    std.mem.indexOf(u8, literal, "pump.zig") != null;
                saw_external_pump = saw_external_pump or
                    std.mem.indexOf(u8, literal, "ExternalPump") != null;
                saw_facade = saw_facade or
                    std.mem.indexOf(u8, literal, "Facade") != null;
            },
            else => {},
        }
    }
}

fn joinedStringLiteralsContain(source: [:0]const u8, needle: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var matched: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .string_literal => {
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                for (literal) |byte| {
                    if (byte == needle[matched]) {
                        matched += 1;
                        if (matched == needle.len) return true;
                    } else {
                        matched = if (byte == needle[0]) 1 else 0;
                    }
                }
            },
            else => {},
        }
    }
}

fn checkDirectory(
    allocator: std.mem.Allocator,
    rule: Rule,
    dir_path: []const u8,
    violations: *usize,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        try checkFile(allocator, rule, path, violations);
    }
}

// .zig 소스를 sentinel 종료 버퍼([:0]u8 — std.zig.Tokenizer가 요구)로 읽는다. 호출자가 free한다.
// 읽기 상한 4MB: core.zig가 256KB를 넘어, 이어서 app_session.zig가 1MB→2MB를 넘어 StreamTooLong이 났던 이력이라
// 넉넉히 둔다(정상적 코드 성장 — 한도는 의미 제약이 아니라 읽기 버퍼 크기일 뿐이다).
fn readZigFileZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("boundary scan could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

fn checkFile(
    allocator: std.mem.Allocator,
    rule: Rule,
    path: []const u8,
    violations: *usize,
) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanImports(text_z, rule, path, violations);
}

// @import 경로를 훑어 금지 레이어 import를 센다. 단순 부분문자열 스캔이 아니라
// std.zig.Tokenizer로 토큰화해 실제 `@import` `(` string_literal 시퀀스만 import로 본다.
// 그래야 (1) `@import`와 `(` 사이에 주석·개행·공백이 있어도 잡고(부분문자열 스캐너는
// `@import // 주석\n(...)`을 놓쳤다), (2) 주석이나 문자열 리터럴 안에 적힌
// `@import("../x")`를 오탐하지 않는다. 토크나이저는 일반 주석을 토큰으로 내보내지 않고,
// doc 주석·일반/multiline 문자열은 builtin이 아닌 단일 토큰으로 내보내므로 둘 다 자연히 처리된다.
fn scanImports(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, true);
}

fn scanImportsQuiet(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, false);
}

fn scanImportsWithDiagnostics(
    text: [:0]const u8,
    rule: Rule,
    path: []const u8,
    violations: *usize,
    emit_diagnostics: bool,
) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    // `@import` / `(` / string_literal 가 연속으로 나올 때만 실제 import로 본다.
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import");
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
                saw_import = false;
            },
            .string_literal => {
                if (saw_paren) {
                    // string_literal 토큰은 따옴표를 포함한다("..."). import 경로는
                    // 이스케이프 없는 단순 경로라 양끝 따옴표만 벗긴다.
                    const raw = text[token.loc.start..token.loc.end];
                    const import_path = raw[1 .. raw.len - 1];
                    for (rule.forbidden) |forbidden| {
                        if (importTraversesLayer(import_path, forbidden)) {
                            // 실제 파일을 검사할 때만 진단을 출력한다. 아래 unit test는 일부러
                            // 금지 import fixture를 넣기 때문에, 거기서 같은 메시지를 찍으면
                            // `mise run check`가 성공해도 실패처럼 보여 triage를 방해한다.
                            if (emit_diagnostics) {
                                std.debug.print(
                                    "boundary violation: {s} ({s} layer) imports forbidden layer '{s}' via \"{s}\"\n",
                                    .{ path, rule.layer, forbidden.layer, import_path },
                                );
                            }
                            violations.* += 1;
                        }
                    }
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                saw_import = false;
                saw_paren = false;
            },
        }
    }
}

fn importTraversesLayer(import_path: []const u8, forbidden: Forbidden) bool {
    // import 경로는 "../pty/types.zig"나 "core.zig" 같은 상대 경로다.
    var it = std.mem.splitScalar(u8, import_path, '/');
    while (it.next()) |seg| {
        // 구현 디렉터리로 진입: segment가 정확히 레이어 이름("pty", "terminal" ...).
        if (std.mem.eql(u8, seg, forbidden.layer)) return true;
        // 공개 barrel("layer.zig"): 레이어 전체 금지일 때만 위반으로 본다.
        if (!forbidden.private_only and
            std.mem.endsWith(u8, seg, ".zig") and
            std.mem.eql(u8, seg[0 .. seg.len - 4], forbidden.layer)) return true;
    }
    return false;
}

test "importTraversesLayer distinguishes barrel from private implementation" {
    // 레이어 전체 금지: barrel과 구현 디렉터리 둘 다 잡는다.
    try std.testing.expect(importTraversesLayer("../pty/types.zig", .{ .layer = "pty" }));
    try std.testing.expect(importTraversesLayer("../pty.zig", .{ .layer = "pty" }));
    // private 구현만 금지: 구현 디렉터리는 잡고 공개 barrel은 허용한다.
    try std.testing.expect(importTraversesLayer("../terminal/core.zig", .{ .layer = "terminal", .private_only = true }));
    try std.testing.expect(!importTraversesLayer("../terminal.zig", .{ .layer = "terminal", .private_only = true }));
    // 무관한 import는 잡지 않는다.
    try std.testing.expect(!importTraversesLayer("core.zig", .{ .layer = "pty" }));
    try std.testing.expect(!importTraversesLayer("std", .{ .layer = "renderer" }));
}

test "boundary rules enforce documented facade contracts (terminal↛session/plugin, plugin↛renderer)" {
    // 이 테스트가 증명하는 것: facade-contracts.md의 "몰라야 하는 것" 경계 중 예전엔 미강제였던 항목을 rules가
    // 실제로 잡는다는 것 — 규칙 추가가 no-op(영원히 안 걸림)이 아니라 위반 fixture에서 정확히 발화한다. 실제 소스는
    // 위반이 0이라(top의 "facade layers..." 테스트가 전 파일 스캔) 여기선 fixture 문자열로 규칙 자체의 발화를 고정한다.
    const findRule = struct {
        fn run(layer: []const u8) Rule {
            for (rules) |r| {
                if (std.mem.eql(u8, r.layer, layer)) return r;
            }
            unreachable;
        }
    }.run;

    // terminal → session(workspace/tab/split이 사는 L2): 위상 역전이라 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const w = @import(\"../session/workspace.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // terminal → plugin: plugin runtime을 몰라야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const p = @import(\"../plugin/registry.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // plugin → renderer(전체 — barrel도 금지): renderer resource를 직접 받지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
        var v2: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer/metal_frame.zig\");", findRule("plugin"), "fixture", &v2);
        try std.testing.expectEqual(@as(usize, 1), v2); // 구현부도
    }
    // 반대로 허용된 import는 여전히 통과 — terminal이 중립 top-level(color/width)·자기 모듈을 쓰는 건 정상.
    {
        var v: usize = 0;
        scanImportsQuiet("const c = @import(\"../color.zig\");\nconst w = @import(\"width.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // plugin이 action/config facade로 상호작용하는 건 계약상 허용(pty/terminal-private/renderer만 금지) — config는 안 막힌다.
    {
        var v: usize = 0;
        scanImportsQuiet("const cfg = @import(\"../config.zig\");\nconst t = @import(\"../terminal.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v); // config·terminal 공개 barrel은 허용(terminal은 private_only 금지)
    }
}

test "scanImports catches zig fmt-clean whitespace and multi-line @import forms" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // 단일행: 기존에도 잡혔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // trailing comma 줄바꿈 형태: zig fmt --check를 통과하면서 예전 `@import("` 마커를 빠져나갔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\n    \"../pty/types.zig\",\n);", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // @import 와 `(` 사이 공백.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 허용되는 import(std, 공개 barrel)는 잡지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s = @import(\"std\");\nconst t = @import(\"../terminal.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

test "scanImports tokenizes, so comments and string literals neither evade nor false-positive" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // `@import`와 `(` 사이 줄 주석: zig fmt-clean이고 유효한 Zig지만 부분문자열 스캐너는
    // 놓쳤다. 토크나이저는 주석을 건너뛰므로 실제 import로 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import // sneaky\n    (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 금지 경로 언급: 실제 import가 아니므로 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("// historically used @import(\"../pty/types.zig\")\nconst a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("/// see @import(\"../pty/types.zig\")\npub const a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // multiline 문자열 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s =\n    \\\\@import(\"../pty/types.zig\")\n;", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── 중립성 가드(B): OS-특정 타입명이 중립 레이어(L1~L3) 코드에 식별자로 등장하지 않음을 강제 ──────────────────
// import 금지(위 rules)는 platform을 못 끌어오게 막지만, 어떤 중립 barrel이 OS 타입을 re-export하면 import 없이도
// 이름이 샐 수 있다. 이 가드는 그 누수를 직접 막는다 — renderer-strategy.md의 WebGPU 조건 1("L1~L3가 중립 frame만
// 소비함을 테스트로 증명")의 실제 충족이자 docs/layering-and-portability.md §8의 "Metal-by-name" 규칙이다.
// std.zig.Tokenizer로 **.identifier 토큰만** 검사하므로, 중립 계약을 설명하는 주석·문자열 안의 "Metal"/"CoreText"
// 언급은 오탐하지 않는다(주석은 토큰이 아니고 doc 주석·문자열은 별도 태그).
//
// 비범위: app은 의도적으로 섞인 레이어(pty/runtime + 중립 모델)라 스캔 안 한다 — 그 중립성은 컨벤션으로 다룬다
// (위 session 규칙 주석 참고). transitive·app 규칙 강제는 후속.

const NeutralLayer = struct { layer: []const u8, barrel: []const u8, dir: []const u8 };

const neutral_layers = [_]NeutralLayer{
    .{ .layer = "terminal", .barrel = "src/terminal.zig", .dir = "src/terminal" }, // L1 VT 코어 — 가장 순수한 중립
    .{ .layer = "renderer", .barrel = "src/renderer.zig", .dir = "src/renderer" },
    .{ .layer = "session", .barrel = "src/session.zig", .dir = "src/session" },
    .{ .layer = "chrome", .barrel = "src/chrome.zig", .dir = "src/chrome" },
};

// platform/macos가 정의·노출하는 OS 경계 타입 + 대표 OS(CoreText/CoreGraphics/AppKit/Metal) 타입명. 이 이름이
// 중립 레이어 코드에 식별자로 나타나면 OS 결합이 샌 것이다. 정확 일치라 오탐 0(전부 명백한 OS 타입명 — 부분
// 문자열·소문자 변형은 안 잡는다). 누락이 있어도 import 금지가 1차로 막으므로 이건 2차(re-export) 가드다.
const forbidden_os_type_names = [_][]const u8{
    // GPU 백엔드 런타임 타입(maru_metal_renderer — 실제 Metal API). metal_frame DTO(NativeMetalCell·MetalFrame·
    // MetalFrameBuffer·NativeMetalRasterUpload)는 §8 이주로 renderer(중립 frame 계약)가 소유하므로 더는 OS 타입
    // 가드 대상이 아니다 — 이름만 "Metal"이고 OS 의존 없는 ABI 표현이다. chrome은 import 가드(chrome→renderer 금지)로 여전히 차단.
    "MetalRenderer",
    // CoreText / CoreGraphics(제품 shaper·raster 경계 — C @cImport는 platform 전용이어야 한다).
    "CTFont",
    "CTRun",
    "CTLine",
    "CGGlyph",
    "CGFloat",
    "CGRect",
    "CGSize",
    "CGPoint",
    "CGContext",
    // AppKit / Metal(OS host·GPU 백엔드 전용).
    "NSColor",
    "NSView",
    "NSWindow",
    "NSString",
    "NSEvent",
    "MTLDevice",
    "MTLBuffer",
    "MTLTexture",
};

test "neutral layers (terminal·renderer·session·chrome) do not name OS-specific types" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    for (neutral_layers) |nl| {
        try checkFileForOsTypes(allocator, nl.layer, nl.barrel, &violations); // barrel(re-export 경로)
        try checkDirectoryForOsTypes(allocator, nl, &violations); // 구현부
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

fn checkDirectoryForOsTypes(allocator: std.mem.Allocator, nl: NeutralLayer, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, nl.dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ nl.dir, entry.path });
        defer allocator.free(path);

        try checkFileForOsTypes(allocator, nl.layer, path, violations);
    }
}

fn checkFileForOsTypes(allocator: std.mem.Allocator, layer: []const u8, path: []const u8, violations: *usize) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanForbiddenIdentifiers(text_z, layer, path, violations, true);
}

// .identifier 토큰만 보고 forbidden_os_type_names와 정확 일치하면 위반으로 센다. 주석(토큰 아님)·doc 주석/
// 문자열(별도 태그)은 자연히 건너뛴다 — scanImports와 같은 토크나이저 규율.
fn scanForbiddenIdentifiers(text: [:0]const u8, layer: []const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .identifier) continue;
        const ident = text[token.loc.start..token.loc.end];
        for (forbidden_os_type_names) |name| {
            if (std.mem.eql(u8, ident, name)) {
                if (emit_diagnostics) {
                    std.debug.print(
                        "neutrality violation: {s} ({s} layer) names OS-specific type '{s}' (L1~L3는 중립이어야 한다)\n",
                        .{ path, layer, name },
                    );
                }
                violations.* += 1;
            }
        }
    }
}

test "scanForbiddenIdentifiers flags code identifiers but not comments or strings" {
    // 코드 식별자(qualified access의 끝 식별자 포함)로 등장하면 위반.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const c = shaper.CTFont;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 언급은 오탐 아님(중립 계약 설명).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("// CoreText shaper consumes CTFont\nconst x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 언급도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("/// produces CGFloat-free output\npub const x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 문자열 리터럴 안도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const s = \"NSView is OS-only\";", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 무관한/유사하지만 다른 식별자는 통과(정확 일치라 부분문자열 오탐 없음).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const cell = grid.cell; const myCTFontWrapper = 0;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── core_mutex 직접 lock/unlock 금지 가드 ────────────────────────────────────────────────────────────────
// core_mutex(Surface 소유)는 재진입을 lock 전에 감지하는 owner-추적 래퍼(`Surface.lockCore`/`unlockCore`,
// `CoreOwner.lock`/`unlock`)로만 잡아야 한다. `core_mutex.lockUncancelable`/`.unlock` 직접 호출이 새로 들어오면
// owner 추적이 비어 재진입 안전망(docs/io-render-threading.md §6-5)이 새고, 이번 IME hang 같은 self-deadlock이
// 다시 런타임에서만 드러난다. 식별자 시퀀스 `core_mutex` `.` (`lockUncancelable`|`unlock`)를 토크나이저로 잡아
// 빌드에서 막는다 — 주석·문자열 속 언급은 토큰이 아니라 오탐 0이고, 필드 선언(`core_mutex:` 뒤가 `:`)이나
// 포인터 전달(`&x.core_mutex,` 뒤가 `,`)은 `.lock*`가 아니라 통과한다.

fn scanCoreMutexDirectCalls(text: [:0]const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    var saw_core_mutex = false; // 직전 식별자가 `core_mutex`였나
    var saw_dot = false; // `core_mutex` 직후 `.`를 봤나
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .identifier => {
                const ident = text[token.loc.start..token.loc.end];
                if (saw_dot and (std.mem.eql(u8, ident, "lockUncancelable") or std.mem.eql(u8, ident, "unlock"))) {
                    if (emit_diagnostics) {
                        std.debug.print(
                            "core_mutex direct-call violation: {s} calls core_mutex.{s} directly — use Surface.lockCore/unlockCore (또는 CoreOwner.lock/unlock)\n",
                            .{ path, ident },
                        );
                    }
                    violations.* += 1;
                    saw_core_mutex = false;
                    saw_dot = false;
                } else {
                    saw_core_mutex = std.mem.eql(u8, ident, "core_mutex");
                    saw_dot = false;
                }
            },
            .period => {
                saw_dot = saw_core_mutex;
                saw_core_mutex = false;
            },
            else => {
                saw_core_mutex = false;
                saw_dot = false;
            },
        }
    }
}

fn scanTreeForCoreMutexCalls(allocator: std.mem.Allocator, dir_path: []const u8, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        const text_z = try readZigFileZ(allocator, path);
        defer allocator.free(text_z);
        scanCoreMutexDirectCalls(text_z, path, violations, true);
    }
}

test "core_mutex is acquired only via owner-tracking wrappers (no direct lockUncancelable/unlock)" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    try scanTreeForCoreMutexCalls(allocator, "src", &violations);
    try scanTreeForCoreMutexCalls(allocator, "tests", &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "scanCoreMutexDirectCalls flags direct lock but not wrappers/fields/pointers/comments" {
    // 직접 호출은 잡는다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("s.core_mutex.lockUncancelable(io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("surface.core_mutex.unlock(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 포인터 전달(owner-추적 래퍼로 넘김)은 통과 — 뒤가 `,`라 `.lock*`가 아니다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.core.owner_dbg.lock(&self.core_mutex, io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 필드 선언·optional 언랩은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("core_mutex: std.Io.Mutex = .init,\nconst m = self.core_mutex.?;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 주석 속 언급은 오탐 아님(토큰이 아니다).
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("// 옛 방식: active.core_mutex.lockUncancelable(io)\nconst x = 1;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 다른 변수의 lockUncancelable(예: 큐 mutex)은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.mutex.lockUncancelable(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}
