//! `maru browser <cmd>` **러너** — 파싱된 명령을 컨트롤 소켓에 왕복시키고 결과를 사람에게 낸다(§9.6 CLI-2).
//!
//! **왜 `browser.zig`가 아니라 여기인가.** 그 파일은 "L2 순수: std + control_plane만, 소켓/OS 0"을 계약으로
//! 선언한다 — 파싱·요청 조립·응답 렌더·stream validator가 테스트 가능한 이유가 그 순수성이다. 러너는 fd에서
//! 읽고 파일을 쓰므로 그 계약을 깬다. 그래서 순수 절반은 `browser.zig`에 두고, impure 절반만 이 파일이 가진다
//! (`session_host.zig` + `session_host/`, `app_session.zig` + `app_session/`와 같은 facade+폴더 관용구).
//!
//! **연결 수립은 여기서 하지 않는다** — 소켓 발견·connect·`auth.self`·요청 전송은
//! [`control_client`](../control_client.zig)가 한 곳에서 하고, 이 파일은 그것이 돌려준 fd를 받아 쓴다.
//! 다만 **수신 쪽 `read`와 `close`는 이 파일이 직접 한다**(`std.c.read`·`std.c.close`) — 프레임을 얼마나
//! 더 읽을지는 validator의 상태가 정하므로 그 루프를 연결 계층으로 올리면 수신 상태 기계가 둘로 갈린다.
//! 즉 이 파일의 책임은 **응답 수신 상태 기계**다: 프레임을 validator에 먹이고, chunk를 재조립하고,
//! 검증이 끝난 뒤에만 stdout이나 `--out` 파일로 공개한다.
//!
//! 그래서 이 파일은 `cli/`의 순수 규칙에서 면제된 두 파일 중 하나다. 그 예외 목록은 산문이 아니라
//! [`tests/boundary/cli_purity.zig`](../../../tests/boundary/cli_purity.zig)가 기계로 고정한다.
//!
//! **grant 대기**: browser 요청은 세션 cap이 없어 needs_grant→서버 held→확인 모달이다. 아래 read들이 사용자가
//! 모달을 클릭할 때까지 블록한다(§9.2 Model B) — 짧은 타임아웃을 걸면 안 된다.
const std = @import("std");
const builtin = @import("builtin");
const browser = @import("../browser.zig");
const control_client = @import("../control_client.zig");
const control_browser = @import("../../session/control_browser.zig");
const cp = @import("../../session/control_plane.zig");

/// `maru browser <cmd>` 진입점. `runSessionCli` 동형 — 인자 수집 → `browser.parse` → help/요청 분기.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const parsed = browser.parse(collected.items) catch |err| {
        try writeUsage(stderr, err);
        return error.UnknownCommand;
    };
    switch (parsed) {
        .help => {
            try stdout.writeAll(browser.browser_help);
            try stdout.flush();
        },
        .request => |req| try runRequest(io, allocator, req, stdout, stderr),
        .screenshot => |shot| try runScreenshot(io, allocator, shot, stdout, stderr),
        .repl => |r| try runRepl(io, allocator, r.surface, null, stdout, stderr),
    }
}

/// 파싱 실패의 이유 한 줄(`writeUsage`·`maru mcp` 가 쓴다 — MCP 도구 결과에는 도움말 전체 대신 이것만).
pub fn usageReason(err: browser.ParseError) []const u8 {
    return switch (err) {
        error.MissingSubcommand => "a subcommand is required",
        error.UnknownSubcommand => "unknown subcommand",
        error.DuplicateSurface => "--surface may only be specified once",
        error.MissingSurface => "--surface <id> is required",
        error.InvalidSurface => "the surface id must be a non-negative integer",
        error.MissingSurfaceValue => "--surface needs a value",
        error.MissingUrl => "navigate needs a url",
        error.MissingScript => "exec needs a script",
        error.MissingArgsValue => "exec --args needs a JSON array value",
        error.InvalidArgs => "exec --args must be a valid JSON array",
        error.MissingMaxResultBytesValue => "exec --max-result-bytes needs a value",
        error.InvalidMaxResultBytes => "exec --max-result-bytes must be an integer in 1..16777216",
        error.MissingOutValue => "screenshot --out needs a value",
        error.MissingRectValue => "screenshot --rect needs a value",
        error.MissingScaleValue => "screenshot --scale needs a value",
        error.InvalidRect => "--rect must be x,y,w,h (four numbers, w/h > 0)",
        error.InvalidScale => "--scale must be positive",
        error.MissingName => "--name is required",
        error.MissingKey => "--key is required",
        error.MissingSelector => "--selector is required",
        error.MissingLocator => "click/type/scroll/hover needs one of --selector, --ref, --role, --by-text or --by-label",
        error.ConflictingLocator => "give only one target: --selector, --ref (not for wait), --role, --by-text or --by-label",
        error.MissingWaitCondition => "wait needs --selector, --load, --role, --by-text or --by-label",
        error.ConflictingWaitCondition => "wait takes only one of --selector and --load (--load does not go with --visible or a locator)",
        error.MissingTimeoutValue => "wait --timeout needs a value",
        error.InvalidTimeout => "wait --timeout must be an integer in 1..25000",
        error.MissingText => "type needs --text",
        error.LocatorOptionWithoutRole => "--name and --level go with --role; --exact and --nth go with --role, --by-text or --by-label",
        error.ExactWithoutName => "--exact needs --name",
        error.InvalidLocatorNumber => "--level must be 1..100 and --nth 0..1000000",
        error.MissingPressKey => "press needs --key (for example Enter, Shift+Tab or Meta+a)",
        error.MissingValue => "--value is required",
        error.MissingOptionValue => "the option needs a value",
        error.MissingMaxDepthValue => "snapshot --max-depth needs a value",
        error.InvalidMaxDepth => "--max-depth must be a non-negative integer",
        error.UnknownOption => "unknown option",
        error.UnexpectedArgument => "too many arguments",
    };
}

/// `maru browser` 파싱 실패 시 사유 + help를 stderr에 낸다(`writeSessionCliUsage` 동형).
pub fn writeUsage(stderr: *std.Io.Writer, err: browser.ParseError) !void {
    const reason = usageReason(err);
    try stderr.print("maru browser: {s}\n\n", .{reason});
    try stderr.writeAll(browser.browser_help);
    try stderr.flush();
}

/// `maru browser navigate/get-url/exec/get-cookies`를 컨트롤 소켓에 왕복한다(§9.6 CLI-2). sessions와 **동형**(같은
/// `control_client.fetchResponse` 소켓 흐름 공유) — 요청 조립·응답 렌더만 `browser.zig`.
fn runRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: browser.Request,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (req == .exec) return runExecuteScript(io, allocator, req.exec, stdout, stderr);
    // §9.5.10 통일: inline이 method-특화 wrapper인 메서드(snapshot·console)는 bounded transfer라 chunk 재조립 러너로 간다.
    if (req == .snapshot) return runWrappedResult(io, allocator, req, cp.browser_snapshot_chunk_method, "snapshot", .snapshot, stdout, stderr);
    if (req == .console) return runWrappedResult(io, allocator, req, cp.browser_console_chunk_method, "console", .console, stdout, stderr);
    const kind = req.kind();
    const request_bytes = try browser.buildRequestBytes(allocator, req, .{ .number = 1 });
    defer allocator.free(request_bytes);
    const resp = try control_client.fetchResponse(io, allocator, request_bytes, stderr);
    defer allocator.free(resp);
    if (!try browser.renderResponse(allocator, resp, kind, stdout)) return error.UnknownCommand;
    try stdout.flush();
}

fn runExecuteScript(
    io: std.Io,
    allocator: std.mem.Allocator,
    exec_cmd: browser.ExecCmd,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const request_id: cp.Id = .{ .number = 1 };
    const request_bytes = browser.buildRequestBytes(allocator, .{ .exec = exec_cmd }, request_id) catch |err| switch (err) {
        error.InvalidArgs => return executeError(stderr, "--args must be a valid JSON array"),
        else => return err,
    };
    defer allocator.free(request_bytes);
    const fd = try control_client.connectSend(io, allocator, request_bytes, stderr);
    defer _ = std.c.close(fd);

    var validator = browser.ExecuteScriptStreamValidator.init(allocator, request_id, exec_cmd.max_result_bytes);
    defer validator.deinit();
    // 결과를 메모리에 누적한다(validator가 ≤max_result_bytes로 상한). 이전엔 write-only atomic spool에 스트리밍한 뒤
    // 되읽어 검증/출력했으나, macOS는 `createFileAtomic` 핸들이 O_WRONLY(O_TMPFILE는 Linux 전용)라 pread가 EBADF로
    // 실패해 exec가 항상 에러였다. 버퍼링으로 read-back을 없앤다 — 공개는 검증 후 원자적 write로.
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var framer: cp.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;
    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (try validator.feed(line, &decode_scratch)) {
                .need_more => {},
                .chunk => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                },
                .inline_result => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                    break :done;
                },
                .done => break :done,
                .error_response => {
                    // 서버가 정상 JSON-RPC error(script_error·result_too_large·timeout·unauthorized 등) 반환 — 일반 "잘못된
                    // stream" 대신 실제 code/message를 stderr에 내고 exit 1(부분 result는 안 쓴다). renderResponse는 error
                    // 응답에서 kind를 안 쓴다(.exec는 표식일 뿐). 성공 결과만 stdout으로 나간다(계약 유지).
                    _ = browser.renderResponse(allocator, line, .exec, stderr) catch false;
                    stderr.flush() catch {};
                    return error.UnknownCommand;
                },
                .failed => return executeError(stderr, "the server returned a malformed executeScript stream"),
            }
        }
        var read_buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) return executeError(stderr, "the server did not finish the response");
        framer.push(allocator, read_buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    if (!validateJsonSlice(allocator, result.items))
        return executeError(stderr, "the executeScript result is not strict JSON");

    if (exec_cmd.out) |path| {
        publishResult(std.Io.Dir.cwd(), io, path, result.items) catch
            return executeError(stderr, "cannot publish the output file atomically");
        try stdout.print("executeScript: {d} bytes → {s}\n", .{ result.items.len, path });
    } else {
        try stdout.writeAll(result.items);
        try stdout.writeAll("\n");
    }
    try stdout.flush();
}

/// §9.5.10 통일: inline이 method-특화 wrapper(`{result:{<wrap_field>:value}}`)인 browser 메서드(snapshot·console)의 응답을
/// 스트리밍으로 받는다. 결과가 512 KiB 이하면 inline 단일 응답이라 그대로 renderResponse하고, 초과면 `chunk_method`
/// notification×N을 base64 재조립해 raw 값을 복원한 뒤 synthetic 응답 `{result:{<wrap_field>:value}}`로 감싸 렌더한다(대형
/// 결과가 프레임 상한을 넘던 결함 해소 — executeScript와 같은 transfer). 검증·재조립은 `WrappedResultStreamValidator`(L2 순수,
/// executeScript와 동형 bounded 검증). error 응답도 그대로 렌더. GUI 손 테스트로 대형 왕복 확인. `wrap_field`는 서버 잘못된
/// 스트림 에러 메시지 라벨도 겸한다.
fn runWrappedResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: browser.Request,
    chunk_method: []const u8,
    wrap_field: []const u8,
    kind: browser.ResponseKind,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const max_bytes = switch (req) {
        .snapshot => control_browser.snapshot_max_result_bytes,
        .console => control_browser.console_max_result_bytes,
        else => unreachable, // 라우터가 snapshot·console만 이리로 보냄
    };
    const request_id: cp.Id = .{ .number = 1 };
    const request_bytes = try browser.buildRequestBytes(allocator, req, request_id);
    defer allocator.free(request_bytes);
    const fd = try control_client.connectSend(io, allocator, request_bytes, stderr);
    defer _ = std.c.close(fd);

    var validator = browser.WrappedResultStreamValidator.init(allocator, request_id, chunk_method, max_bytes);
    var reassembled: std.ArrayList(u8) = .empty; // chunked면 재조립한 raw 값(트리/배열) JSON 바이트
    defer reassembled.deinit(allocator);
    var terminal_line: ?[]u8 = null; // inline/error 응답 그대로 렌더용(chunked면 null → synthetic)
    defer if (terminal_line) |l| allocator.free(l);
    var chunked = false;
    var framer: cp.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;

    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (validator.feed(line, &decode_scratch)) {
                .need_more => {},
                .chunk => |bytes| reassembled.appendSlice(allocator, bytes) catch return error.OutOfMemory,
                .inline_terminal => {
                    terminal_line = try allocator.dupe(u8, line); // inline `{<wrap_field>}` 또는 에러 — 그대로 렌더
                    break :done;
                },
                .done => {
                    chunked = true;
                    break :done;
                },
                .failed => return wrappedStreamError(stderr, wrap_field),
            }
        }
        var read_buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) return wrappedStreamError(stderr, wrap_field);
        framer.push(allocator, read_buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }

    if (chunked) {
        // 재조립한 raw 값을 synthetic 응답 `{result:{<wrap_field>:value}}`로 감싸 기존 렌더러 재사용(inline과 같은 렌더 경로).
        var synth: std.ArrayList(u8) = .empty;
        defer synth.deinit(allocator);
        synth.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"") catch return error.OutOfMemory;
        synth.appendSlice(allocator, wrap_field) catch return error.OutOfMemory;
        synth.appendSlice(allocator, "\":") catch return error.OutOfMemory;
        synth.appendSlice(allocator, reassembled.items) catch return error.OutOfMemory;
        synth.appendSlice(allocator, "}}") catch return error.OutOfMemory;
        if (!try browser.renderResponse(allocator, synth.items, kind, stdout)) return error.UnknownCommand;
    } else if (terminal_line) |line| {
        if (!try browser.renderResponse(allocator, line, kind, stdout)) return error.UnknownCommand;
    } else {
        return wrappedStreamError(stderr, wrap_field);
    }
    try stdout.flush();
}

/// `maru browser screenshot`을 컨트롤 소켓에 왕복한다(§9.6·§9.5.7). 단일 응답이 아니라 **chunk 스트림**이라
/// `control_client.fetchResponse`(첫 응답만)와 달리 `connectSend`로 열고 프레임을 고정 scratch로 검증·decode해 메모리에
/// 누적한다. 최종 metadata와 PNG header까지 검증한 뒤에만 `publishResult`(원자적 `--out`) 또는 stdout으로 공개한다.
fn runScreenshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    shot: browser.ScreenshotCmd,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const c = std.c;
    const request_bytes = try browser.buildScreenshotRequestBytes(allocator, shot, .{ .number = 1 });
    defer allocator.free(request_bytes);
    const fd = try control_client.connectSend(io, allocator, request_bytes, stderr);
    defer _ = c.close(fd);

    const request_id: cp.Id = .{ .number = 1 };
    var validator = browser.ScreenshotStreamValidator.init(request_id);
    // PNG를 메모리에 누적(validator가 chunk 상한 강제). write-only spool read-back 회피(exec와 동일 이유).
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var framer: cp.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;
    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (validator.feed(allocator, line, &decode_scratch) catch return error.OutOfMemory) {
                .need_more => {},
                .chunk => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                },
                .done => break :done,
                .error_response => {
                    // 서버가 정상 JSON-RPC error(unauthorized·surface 없음 등) 반환 — 일반 "잘못된 stream" 대신 실제
                    // code/message를 stderr에 내고 exit 1. renderResponse는 error 응답에서 kind를 안 쓴다(.ok는 표식일 뿐).
                    _ = browser.renderResponse(allocator, line, .ok, stderr) catch false;
                    stderr.flush() catch {};
                    return error.UnknownCommand;
                },
                .failed => return screenshotError(stderr, "the server returned a malformed screenshot stream"),
            }
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len); // grant held면 사용자 클릭까지 블록(§9.6)
        if (n <= 0) return screenshotError(stderr, "the server did not finish the response (incomplete stream)");
        framer.push(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }

    if (shot.out) |path| {
        publishResult(std.Io.Dir.cwd(), io, path, result.items) catch
            return screenshotError(stderr, "cannot publish the output file atomically");
        try stdout.print("screenshot: {d}x{d} PNG, {d} bytes → {s}\n", .{ validator.width, validator.height, result.items.len, path });
        try stdout.flush();
    } else {
        try stdout.writeAll(result.items);
        try stdout.flush();
    }
}

/// 결과 바이트가 완결 strict JSON인지 **메모리 슬라이스로** 검증한다(write-only spool read-back 회피).
/// 깊이 128 상한(중첩 폭발 DoS 방어). 빈 입력은 유효 JSON이 아니므로 false.
fn validateJsonSlice(allocator: std.mem.Allocator, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return false;
        if (scanner.stackHeight() > 128) return false;
        if (token == .end_of_document) return true;
    }
}

/// 검증된 결과를 `target`에 **0600 원자적으로** 공개한다(검증-전-미노출 보존). 임시 파일 핸들이 write-only여도(macOS)
/// 되읽지 않으므로 무방. `.replace=true`+`Atomic.replace`라 기존 target을 **덮어쓴다**(폴링/재실행 정상화 —
/// 옛 `.link` no-clobber 회귀 수정). caller가 에러를 사용자 메시지로 매핑.
fn publishResult(dir: std.Io.Dir, io: std.Io, target: []const u8, bytes: []const u8) !void {
    // **Windows에서는 도달할 수 없고, 도달해서도 안 된다.** 도달 불가인 이유: 이 경로는 컨트롤 소켓 왕복 뒤에만
    // 오는데 `control_client.connectSend`가 Windows에서 "인스턴스 없음"으로 접는다. 도달하면 안 되는 이유: POSIX의
    // `0o600`(소유자 전용)에 해당하는 것이 Windows에는 없고 — `Permissions`가 POSIX mode가 아니라 **ACL**을 나르는
    // `FILE.ATTRIBUTE` enum이라 `fromMode`가 아예 없다 — 무엇으로 대체할지가 아직 미결정이기 때문이다
    // (docs/windows-platform.md §8 "`publishBrowserResult`의 파일 권한": 부모 디렉터리 ACL 상속 vs 현재 사용자
    // SID만 허용하는 명시 ACL).
    //
    // 그래서 `.default_file`로 조용히 넘기지 않는다. 그것은 부모 폴더의 ACL을 물려받는다는 뜻이고, 이 파일은
    // 사용자가 `--out`으로 준 임의 경로라 공유 폴더·네트워크 드라이브면 보장이 사라진다. 컨트롤 플레인을
    // 이식하는 사람이 이 결정을 잊으면 **조용히 넓은 권한으로 쓰이는 대신 여기서 시끄럽게 실패**해야 한다.
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;

    var af = try dir.createFileAtomic(io, target, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .replace = true,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}

fn wrappedStreamError(stderr: *std.Io.Writer, cmd_label: []const u8) error{UnknownCommand} {
    stderr.print("maru browser {s}: the server returned a malformed {s} stream\n", .{ cmd_label, cmd_label }) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

fn executeError(stderr: *std.Io.Writer, message: []const u8) error{UnknownCommand} {
    stderr.print("maru browser exec: {s}\n", .{message}) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

/// screenshot 실패(재조립 오류·서버 에러·불완전 스트림)를 stderr에 내고 graceful exit 1 sentinel을 돌려준다
/// (`control_client.noInstance` 동형).
fn screenshotError(stderr: *std.Io.Writer, msg: []const u8) error{UnknownCommand} {
    stderr.print("maru browser screenshot: {s}\n", .{msg}) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

// 이 테스트는 **POSIX 파일 모드가 있는 호스트**의 것이다. Windows에는 `0o600`에 해당하는 것이 없고
// (`Permissions`가 mode가 아니라 ACL을 나르는 `FILE.ATTRIBUTE` enum이라 `toMode`가 없다), 무엇으로 대체할지가
// 미결정이라 `publishResult` 자체가 거기서 `error.UnsupportedOnWindows`로 막혀 있다
// (docs/windows-platform.md §8). **OS 이름이 아니라 없는 전제 그 자체로 skip한다** — `Permissions`에 `toMode`가
// 생기는 날 저절로 깨어나야 한다(`connection_incident`의 `currentProcessId() == 0` skip과 같은 규율,
// docs/layering-and-portability.md §4.1).
test "publishResult: 0600 원자 공개 + 기존 파일 덮어쓰기(폴링 재실행 정상화)" {
    if (!@hasDecl(std.Io.File.Permissions, "toMode")) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try publishResult(tmp.dir, io, "result.bin", "first");
    const stat = try tmp.dir.statFile(io, "result.bin", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    // 같은 경로에 재공개 = **덮어쓰기 성공**(옛 no-clobber 회귀 수정). 내용은 최신("second").
    try publishResult(tmp.dir, io, "result.bin", "second");
    var buf: [6]u8 = undefined;
    const file = try tmp.dir.openFile(io, "result.bin", .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("second", buf[0..n]);
}

test "validateJsonSlice: 완결 strict JSON만 통과하고 빈 입력·깊은 중첩은 막는다" {
    const a = std.testing.allocator;
    try std.testing.expect(validateJsonSlice(a, "{\"k\":[1,2,null]}"));
    try std.testing.expect(validateJsonSlice(a, "\"bare string\""));
    try std.testing.expect(!validateJsonSlice(a, "")); // 빈 결과를 성공으로 공개하지 않는다
    try std.testing.expect(!validateJsonSlice(a, "{\"k\":1")); // 잘린 프레임
    try std.testing.expect(!validateJsonSlice(a, "{} trailing")); // 완결 뒤 잔여물

    // 깊이 상한: 129겹은 거부, 그 아래는 통과한다(중첩 폭발 DoS 방어가 실제로 서 있는지).
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(a);
    for (0..129) |_| try deep.append(a, '[');
    for (0..129) |_| try deep.append(a, ']');
    try std.testing.expect(!validateJsonSlice(a, deep.items));
}

// ── W9f: repl ─────────────────────────────────────────────────────────────────────────────────────────────

/// fd 에서 줄을 하나씩 읽는다(`maru browser repl`·`maru mcp` 가 함께 쓴다). 상한을 넘는 줄은 `.too_long` 한 번으로 알리고 그 줄의
/// 나머지는 버린다(끝없는 입력에 메모리를 쓰지 않게). 끝의 `\n` 없는 마지막 줄도 돌려준다.
pub const LineReader = struct {
    /// null 이면 표준 입력.
    fd: ?std.c.fd_t = null,
    max: usize,
    pending: std.ArrayList(u8) = .empty,
    /// 앞서 돌려준 줄의 바이트(다음 호출 때 버린다 — 돌려준 줄은 그때까지 유효).
    consumed: usize = 0,
    dropping: bool = false,
    eof: bool = false,

    pub const Item = union(enum) { line: []const u8, too_long };

    pub fn deinit(self: *LineReader, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
    }

    pub fn next(self: *LineReader, gpa: std.mem.Allocator) !?Item {
        self.pending.replaceRangeAssumeCapacity(0, self.consumed, &.{});
        self.consumed = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
                const was_dropping = self.dropping;
                self.dropping = false;
                if (was_dropping or nl > self.max) {
                    self.pending.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                    if (was_dropping) continue;
                    return .too_long;
                }
                self.consumed = nl + 1;
                return .{ .line = self.pending.items[0..nl] };
            }
            if (self.pending.items.len > self.max) {
                self.pending.clearRetainingCapacity();
                if (!self.dropping) {
                    self.dropping = true;
                    return .too_long;
                }
            }
            if (self.eof) {
                if (self.dropping or self.pending.items.len == 0) return null;
                self.consumed = self.pending.items.len;
                return .{ .line = self.pending.items };
            }
            var buf: [16 * 1024]u8 = undefined;
            const n = std.c.read(self.fd orelse std.Io.File.stdin().handle, &buf, buf.len);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                self.eof = true;
                continue;
            }
            if (n == 0) {
                self.eof = true;
                continue;
            }
            try self.pending.appendSlice(gpa, buf[0..@intCast(n)]);
        }
    }
};

/// repl 한 줄 상한 — type 의 글·exec 의 식이 가장 크다(`maru mcp` 와 같다).
pub const repl_max_line_bytes: usize = 4 * 1024 * 1024;

const repl_help =
    \\repl: one `maru browser` command per line, without the `maru browser` prefix (quote with '…' or "…").
    \\  use <id>     pick the tab; later commands may leave out --surface (`open` picks the tab it opened)
    \\  help         show this help and the commands below
    \\  exit, quit   leave (also end of input); the exit status is 1 if any command failed
    \\
;

/// `maru browser repl` — 줄마다 하위 명령 하나를 돌린다. 한 명령이 실패해도 다음 줄로 간다(실패는 끝의 종료 상태로).
/// 표준 입력이 터미널이면 표준 오류에 프롬프트(`maru browser[7]> `)를 낸다 — 표준 출력은 명령 출력만(파이프로 넘겨도 섞이지 않게).
fn runRepl(io: std.Io, allocator: std.mem.Allocator, first: ?u64, fd: ?std.c.fd_t, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var current = first;
    var any_failed = false;
    const interactive = std.c.isatty(fd orelse std.Io.File.stdin().handle) == 1;
    var reader: LineReader = .{ .fd = fd, .max = repl_max_line_bytes };
    defer reader.deinit(allocator);
    while (true) {
        if (interactive) {
            if (current) |id| try stderr.print("maru browser[{d}]> ", .{id}) else try stderr.writeAll("maru browser> ");
            try stderr.flush();
        }
        const item = (try reader.next(allocator)) orelse break;
        const line = switch (item) {
            .too_long => {
                try stderr.writeAll("error: line too long\n");
                try stderr.flush();
                any_failed = true;
                continue;
            },
            .line => |l| l,
        };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        switch (try browser.replLine(arena_state.allocator(), line, current)) {
            .empty => {},
            .exit => break,
            .help => {
                try stdout.writeAll(repl_help);
                try stdout.writeAll(browser.browser_help);
                try stdout.flush();
            },
            .use => |id| current = id,
            .bad_use => {
                try stderr.writeAll("error: use needs one tab id (see `list`)\n");
                try stderr.flush();
                any_failed = true;
            },
            .unterminated_quote => {
                try stderr.writeAll("error: unterminated quote\n");
                try stderr.flush();
                any_failed = true;
            },
            .command => |argv| if (!try replCommand(io, allocator, argv, &current, stdout, stderr)) {
                any_failed = true;
            },
        }
    }
    if (any_failed) return error.UnknownCommand;
}

/// repl 명령 하나 — 성공이면 true. 파싱 실패는 도움말 전체 대신 이유 한 줄. `open` 은 출력을 받아 그대로 내고 연 탭을 고른다.
fn replCommand(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, current: *?u64, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const parsed = browser.parse(argv) catch |e| {
        try stderr.print("error: {s}\n", .{usageReason(e)});
        try stderr.flush();
        return false;
    };
    switch (parsed) {
        .help => {
            try stdout.writeAll(repl_help);
            try stdout.writeAll(browser.browser_help);
            try stdout.flush();
            return true;
        },
        .repl => {
            try stderr.writeAll("error: already in repl\n");
            try stderr.flush();
            return false;
        },
        .request => |req| if (req == .open) {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            const ok = if (runRequest(io, allocator, req, &out.writer, stderr)) true else |e| try replFailure(e);
            try stdout.writeAll(out.written());
            try stdout.flush();
            if (ok) if (browser.openedId(out.written())) |id| {
                current.* = id;
            };
            return ok;
        } else {
            runRequest(io, allocator, req, stdout, stderr) catch |e| return replFailure(e);
            return true;
        },
        .screenshot => |shot| {
            runScreenshot(io, allocator, shot, stdout, stderr) catch |e| return replFailure(e);
            return true;
        },
    }
}

/// 명령 하나의 실패 — 출력이 닫히는 것은 repl 을 끝내고(쓸 곳이 없다), 그 밖은 오류 줄만 남기고 다음 줄로 간다.
fn replFailure(e: anyerror) !bool {
    if (e == error.WriteFailed or e == error.OutOfMemory) return e;
    return false;
}

test "W9f LineReader: 줄·줄바꿈으로 끝나지 않는 마지막 줄·상한 넘는 줄은 한 번만 알리고 나머지를 버린다" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    const big = "x" ** 40;
    const input = "a b\n\n" ++ big ++ big ++ "\nafter\n" ++ big ++ "\nlast";
    try std.testing.expectEqual(@as(isize, input.len), std.c.write(fds[1], input, input.len));
    _ = std.c.close(fds[1]);
    var r: LineReader = .{ .fd = fds[0], .max = 64 };
    defer r.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("a b", (try r.next(gpa)).?.line);
    try std.testing.expectEqualStrings("", (try r.next(gpa)).?.line);
    try std.testing.expect((try r.next(gpa)).? == .too_long);
    try std.testing.expectEqualStrings("after", (try r.next(gpa)).?.line);
    try std.testing.expectEqualStrings(big, (try r.next(gpa)).?.line);
    try std.testing.expectEqualStrings("last", (try r.next(gpa)).?.line);
    try std.testing.expect((try r.next(gpa)) == null);
}

test "W9f LineReader: 읽기 조각을 넘어 상한을 넘는 줄 — 알림 한 번, 그 줄 끝까지 버린다" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    const gpa = std.testing.allocator;
    const long = try gpa.alloc(u8, 40 * 1024);
    defer gpa.free(long);
    @memset(long, 'y');
    // 파이프 버퍼(64 KiB 안)에 한 번에 — 읽기는 16 KiB 조각이라 상한(20 KiB)을 조각 사이에서 넘는다.
    try std.testing.expectEqual(@as(isize, @intCast(long.len)), std.c.write(fds[1], long.ptr, long.len));
    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], "\nok", 3));
    _ = std.c.close(fds[1]);
    var r: LineReader = .{ .fd = fds[0], .max = 20 * 1024 };
    defer r.deinit(gpa);
    try std.testing.expect((try r.next(gpa)).? == .too_long);
    try std.testing.expectEqualStrings("ok", (try r.next(gpa)).?.line);
    try std.testing.expect((try r.next(gpa)) == null);
}

test "W9f repl: 한 줄이라도 실패하면 종료 상태 1, exit 뒤 줄은 읽지 않는다, 오류 뒤에도 다음 줄로 간다" {
    const gpa = std.testing.allocator;
    const Case = struct { input: []const u8, fails: bool, out_has: ?[]const u8 = null, err_has: ?[]const u8 = null };
    for ([_]Case{
        .{ .input = "use x\nhelp\n", .fails = true, .out_has = "use <id>", .err_has = "use needs one tab id" },
        .{ .input = "help\nexit\nuse x\n", .fails = false, .out_has = "use <id>" },
        .{ .input = "use 5\n# c\n\n", .fails = false },
        .{ .input = "click --name 'x\n", .fails = true, .err_has = "unterminated quote" },
        .{ .input = "click --bogus\nrepl\n", .fails = true, .err_has = "already in repl" },
    }) |c| {
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        try std.testing.expectEqual(@as(isize, @intCast(c.input.len)), std.c.write(fds[1], c.input.ptr, c.input.len));
        _ = std.c.close(fds[1]);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        const r = runRepl(std.testing.io, gpa, null, fds[0], &out.writer, &err.writer);
        if (c.fails) try std.testing.expectError(error.UnknownCommand, r) else try r;
        if (c.out_has) |h| try std.testing.expect(std.mem.indexOf(u8, out.written(), h) != null);
        if (c.err_has) |h| try std.testing.expect(std.mem.indexOf(u8, err.written(), h) != null);
    }
}
