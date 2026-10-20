//! `maru mcp` 의 **순수 절반**(W9f) — MCP(Model Context Protocol) stdio 서버가 받는 JSON-RPC 한 줄을 풀고, 도구 표를 내고,
//! 도구 인자를 `maru browser` CLI 인자로 옮긴다. 소켓·표준 입출력은 짝인 [`mcp/run.zig`](mcp/run.zig)가 한다(`browser.zig` ↔
//! `browser/run.zig` 와 같은 분할 — 순수 규칙은 `tests/boundary/cli_purity.zig`).
//!
//! **도구는 CLI 하위 명령 그대로다.** 인자를 CLI 인자로 옮겨 `browser.parse` 가 검사하게 한다 — 검사 규칙(로케이터 배타·상한·
//! 시한 범위)이 CLI 한 곳에만 있다. 도구 결과는 CLI 가 낼 글 그대로(사람과 에이전트가 같은 글을 본다), 실패면 `isError`.
//! 원격 디버깅 포트를 열지 않는다 — 요청은 같은 컨트롤 소켓으로 간다(pane 신원 1g 가 이 프로세스의 조상 사슬로 pane 을 찾는다).
const std = @import("std");
const cp = @import("../session/control_plane.zig");

/// 우리가 아는 MCP 판(새 것부터). 클라이언트가 청한 판이 이 안에 있으면 그것으로, 아니면 첫 것으로 답한다(스펙의 협상).
/// 받는 MCP 판 — 2025-03-26 은 batch 받기를 요구해(이 서버는 받지 않는다) 알리지 않는다(W9f 적대 리뷰 1 회차). 클라이언트가 그 판을 청하면
/// 최신으로 답한다(규약: 서버가 다른 판을 내면 클라이언트가 고른다).
pub const protocol_versions = [_][]const u8{ "2025-06-18", "2024-11-05" };
pub const server_name = "maru";

/// 도구 인자 하나가 CLI 에서 어떤 모양인가.
pub const ArgKind = enum {
    /// `--flag <문자열>`
    string,
    /// `--flag <정수>`(0 이상)
    int,
    /// 참이면 `--flag`(거짓이면 없음)
    flag,
    /// 위치 인자(문자열) — 맨 뒤에
    positional,
    /// JSON 배열을 글로 펴서 `--flag <json>`
    json_array,
    /// 수(소수 가능) — `--flag <수>`
    number,
    /// 참·거짓이 서로 다른 플래그로 — 참이면 `flag`, 거짓이면 `flag_false`(W9c② — `accept` → `--accept`·`--dismiss`). 스키마는 boolean.
    bool_choice,
    /// 문자열 배열 — 위치 인자 여럿으로(`--` 뒤). W9c③ 업로드의 파일 경로: **절대 경로만**(이 서버의 현재 폴더는 에이전트가 모른다 — CLI 는
    /// 자기 현재 폴더로 붙이지만 MCP 서버의 것은 에이전트의 것과 다를 수 있다). 스키마는 `minItems`·`maxItems`.
    path_list,
};

pub const Arg = struct {
    key: []const u8,
    kind: ArgKind,
    /// CLI 의 옵션 이름(`positional` 이면 빈 글).
    flag: []const u8 = "",
    /// `bool_choice` 가 거짓일 때의 옵션 이름.
    flag_false: []const u8 = "",
    description: []const u8,
    required: bool = false,
    /// 정수 인자의 최솟값·최댓값(스키마 `minimum`·`maximum` — 파서가 지키는 값과 같게, W9f 적대 리뷰 2 회차).
    min: i64 = 0,
    max: ?i64 = null,
    /// 수(소수) 인자가 0 보다 커야 하는가(스키마 `exclusiveMinimum: 0`).
    positive: bool = false,
    /// `path_list` 의 개수 상한(스키마 `maxItems` — 파서의 상한과 같게).
    max_items: usize = 0,
};

pub const Tool = struct {
    name: []const u8,
    /// `maru browser` 하위 명령.
    subcommand: []const u8,
    description: []const u8,
    args: []const Arg,
};

const surface: Arg = .{ .key = "surface", .kind = .int, .flag = "--surface", .description = "tab id from browser_list or browser_open", .required = true };
const locator_args = [_]Arg{
    .{ .key = "selector", .kind = .string, .flag = "--selector", .description = "CSS selector" },
    .{ .key = "ref", .kind = .string, .flag = "--ref", .description = "element ref from browser_snapshot (like n123)" },
    .{ .key = "role", .kind = .string, .flag = "--role", .description = "ARIA role (Chromium tabs), with name/level" },
    .{ .key = "name", .kind = .string, .flag = "--name", .description = "accessible name for role" },
    .{ .key = "level", .kind = .int, .flag = "--level", .description = "heading level for role=heading", .min = 1, .max = 100 },
    .{ .key = "by_text", .kind = .string, .flag = "--by-text", .description = "visible text (Chromium tabs)" },
    .{ .key = "by_label", .kind = .string, .flag = "--by-label", .description = "form label text (Chromium tabs)" },
    .{ .key = "exact", .kind = .flag, .flag = "--exact", .description = "match the name/text exactly" },
    .{ .key = "nth", .kind = .int, .flag = "--nth", .description = "pick the nth match (0-based)", .max = 1_000_000 },
};

/// wait 의 로케이터 — CLI wait 는 `--ref` 를 받지 않는다(W9f 적대 리뷰 1 회차: 스키마가 내보였는데 파서가 거절했다).
const wait_locator_args = blk: {
    var out: [locator_args.len - 1]Arg = undefined;
    var n: usize = 0;
    for (locator_args) |a| if (!std.mem.eql(u8, a.key, "ref")) {
        out[n] = a;
        n += 1;
    };
    break :blk out;
};

fn withSurface(comptime extra: []const Arg) []const Arg {
    return &([_]Arg{surface} ++ extra[0..extra.len].*);
}

pub const tools = [_]Tool{
    .{ .name = "browser_list", .subcommand = "list", .description = "List the browser tabs of this maru instance (id, url, title, engine, controllable methods).", .args = &.{} },
    .{ .name = "browser_open", .subcommand = "open", .description = "Open a Chromium tab behind the current one in this pane and wait for its first load. Returns the new tab id. Only from a maru pane; up to 8 tabs per pane.", .args = &.{
        .{ .key = "url", .kind = .string, .flag = "--url", .description = "http(s) address to load (omit for a blank tab)" },
        .{ .key = "timeout_ms", .kind = .int, .flag = "--timeout", .description = "how long to wait for the first load (1-25000, default 25000)", .min = 1, .max = 25000 },
    } },
    .{ .name = "browser_close", .subcommand = "close", .description = "Close a tab this pane opened (asks the page; a page that asks before leaving is not closed — answer its question with browser_handle_dialog).", .args = withSurface(&.{}) },
    .{ .name = "browser_dialog", .subcommand = "dialog", .description = "Show the JS dialogs (alert, confirm, prompt, leave-page question) or file chooser blocking this tab or a tab in its popup family, with a token, who caused it and whether you may answer it (Chromium tabs).", .args = withSurface(&.{}) },
    .{ .name = "browser_handle_dialog", .subcommand = "handle-dialog", .description = "Accept or dismiss the tab's alert, confirm, prompt or leave-page question (Chromium tabs). Pass the token from browser_dialog. Dialogs the user opened are refused; file choosers can only be dismissed.", .args = withSurface(&.{
        .{ .key = "accept", .kind = .bool_choice, .flag = "--accept", .flag_false = "--dismiss", .description = "true accepts (OK / leave), false dismisses (Cancel / stay)", .required = true },
        .{ .key = "text", .kind = .string, .flag = "--text", .description = "answer text for a prompt" },
        .{ .key = "dialog", .kind = .int, .flag = "--dialog", .description = "dialog token from browser_dialog", .min = 1, .max = 9_007_199_254_740_991 },
    }) },
    .{ .name = "browser_upload", .subcommand = "upload", .description = "Put files into a file input (<input type=file>) on a Chromium tab. Every call asks the user in a dialog that lists each file with a peek of its content (never remembered — allow up to 2 minutes for the answer); a declined dialog is an error and nothing is uploaded. Give one locator (selector, ref, role, by_text or by_label) and absolute file paths (up to 10; folders are refused). The page gets a copy made when the user approves. The result's kept:false means the page received the files and then cleared or replaced the input itself; navigated:true means the page started loading a new page right after the files were set, or stopped answering (was busy) after they were set (its handler most likely received them); dialog:true means the page showed a dialog right after the files were set (answer it with browser_handle_dialog if you may, see browser_dialog) — in all these cases check the page and do not upload again.", .args = withSurface(&(locator_args ++ [_]Arg{.{ .key = "files", .kind = .path_list, .description = "absolute paths of the files to upload (1-10)", .required = true, .max_items = browser.max_upload_files }})) },
    .{ .name = "browser_network_requests", .subcommand = "network", .description = "List a Chromium tab's network requests, newest first (50 per page, up to 200): req number, method, status, type, URL, time, size, and marks for other-site, cross-site iframe and service-worker requests, and for attempts Chromium restarted (the retry is a separate, newer req). Needs a separate permission per site (the user is asked once; tabs you opened with browser_open need none). You see requests from your permission on (tabs you opened: from their creation); earlier ones are counted as hidden, and so are requests made while the tab showed a site your permission does not cover and navigations that started on or passed through such a site (even when redirected back). Request bodies are not recorded; response bodies are recorded only while browser_network_record is on (each line then shows its body state). WebSocket, CORS preflight, data:/blob: and service-worker script requests are not shown. Use browser_network_request with a req number for headers and redirects.", .args = withSurface(&.{
        .{ .key = "types", .kind = .string, .flag = "--type", .description = "request types separated by commas: document, iframe, stylesheet, script, image, font, xhr (fetch and XHR), media, worker, shared_worker, service_worker, prefetch, favicon, ping, csp_report, object, plugin, preload, other" },
        .{ .key = "method", .kind = .string, .flag = "--method", .description = "HTTP method, like GET or POST" },
        .{ .key = "status", .kind = .string, .flag = "--status", .description = "status code (100-599) or a class like 4xx" },
        .{ .key = "url_contains", .kind = .string, .flag = "--url-contains", .description = "only URLs containing this text (case-insensitive)" },
        .{ .key = "before_req", .kind = .int, .flag = "--before-req", .description = "only requests older than this req — pass next_before_req from the previous result to get the next page (stays put while new requests arrive)", .min = 1, .max = 9_007_199_254_740_991 },
        .{ .key = "page", .kind = .int, .flag = "--page", .description = "page number from the newest (0-10000; next_page in the result — shifts while new requests arrive, prefer before_req)", .max = 10_000 },
        .{ .key = "page_size", .kind = .int, .flag = "--page-size", .description = "requests per page (1-200, default 50)", .min = 1, .max = 200 },
        .{ .key = "clear", .kind = .flag, .flag = "--clear", .description = "after this read, show you only newer requests" },
    }) },
    .{ .name = "browser_network_request", .subcommand = "network-request", .description = "Show one network request of a Chromium tab in detail: request and response headers, redirects, timing and size. Cookie, Set-Cookie and Authorization values (and passwords in addresses) are shown only for sites whose cookie permission you also hold on that tab (the user grants it when you run maru browser get-cookies on that site), even in tabs you opened; otherwise only their names. With browser.agent-network-full off they are never shown. With body:true it also prints one piece of the recorded response body (text only, at most 64 KiB per call, on one line — line breaks in the body show as ' ⏎ ', so the 'more: --offset' line after it is always maru's own; body_offset continues from that line; or out writes the whole body as it is, also a binary one, to a 0600 file, replacing an existing one — not together with body_offset). Bodies exist only for requests made while browser_network_record was on, at most 1 MiB each (8 MiB per tab, 32 MiB for all tabs, in memory only); a body sent with another site's cookies or login needs that site's cookie permission too (navigate the tab to that site and run maru browser get-cookies). The body state says why there is none (needs_body_permission, over_cap, not_text, unmatched for cross-process iframes and workers — ambiguous when a worker fetched the same URL as the page at about the same time, restarted when Chromium restarted the request and the retry is a newer req, …).", .args = withSurface(&.{
        .{ .key = "req", .kind = .int, .flag = "--req", .description = "req number from browser_network_requests", .required = true, .min = 1, .max = 9_007_199_254_740_991 },
        .{ .key = "body", .kind = .flag, .flag = "--body", .description = "also print the recorded response body (one piece of up to body_max_bytes)" },
        .{ .key = "body_offset", .kind = .int, .flag = "--offset", .description = "byte offset into the body (0-1048576) — from the 'more: --offset' line of the previous piece (implies body)", .max = 1024 * 1024 },
        .{ .key = "body_max_bytes", .kind = .int, .flag = "--max-bytes", .description = "bytes per piece (1-65536, default 65536; implies body)", .min = 1, .max = 64 * 1024 },
        .{ .key = "out", .kind = .string, .flag = "--out", .description = "file path for the whole body (written 0600; replaces an existing file; a relative path is resolved against the MCP server's working directory, so prefer an absolute path; read in 64 KiB pieces whatever body_max_bytes says; a binary body can only be read this way; not together with body_offset; implies body)" },
    }) },
    .{ .name = "browser_network_record", .subcommand = "network-record", .description = "Turn recording of a Chromium tab's response bodies on or off. While on, the tab title shows a red ◉ and maru keeps the text bodies (JSON, HTML, scripts, …) of the requests the tab makes, up to 1 MiB each, in memory only. Needs the tab's network permission first (browser_network_requests asks for it); on the user's tabs the user is asked once per site, tabs you opened need no permission. Turning it off stops recording and keeps the bodies already recorded; revoking the permission, closing the tab or the user turning browser.agent-network-full off drops them. Requests from cross-process iframes and workers have no body (unmatched, or ambiguous when a worker fetched the same URL as the page at about the same time).", .args = withSurface(&.{
        .{ .key = "on", .kind = .bool_choice, .flag = "--on", .flag_false = "--off", .description = "true to record, false to stop", .required = true },
    }) },
    .{ .name = "browser_navigate", .subcommand = "navigate", .description = "Navigate a tab to an address. On Chromium tabs only http, https and about:blank, and it waits up to 25 seconds for the first load (loaded:false when no page loaded — a download, an empty response, a same-page link, or the time ran out).", .args = withSurface(&.{.{ .key = "url", .kind = .positional, .description = "address", .required = true }}) },
    .{ .name = "browser_get_url", .subcommand = "get-url", .description = "Print the tab's current document address.", .args = withSurface(&.{}) },
    .{ .name = "browser_click", .subcommand = "click", .description = "Click an element with real mouse input (Chromium tabs). Give one locator: selector, ref, role (+name/level), by_text or by_label.", .args = withSurface(&locator_args) },
    .{ .name = "browser_type", .subcommand = "type", .description = "Type text into an element (replaces its text; real input on Chromium tabs).", .args = withSurface(&(locator_args ++ [_]Arg{.{ .key = "text", .kind = .string, .flag = "--text", .description = "text to type", .required = true }})) },
    .{ .name = "browser_scroll", .subcommand = "scroll", .description = "Scroll an element into view.", .args = withSurface(&locator_args) },
    .{ .name = "browser_hover", .subcommand = "hover", .description = "Move the pointer onto an element (real input; Chromium tabs).", .args = withSurface(&locator_args) },
    .{ .name = "browser_press", .subcommand = "press", .description = "Press a key like Enter, Shift+Tab or Meta+a (on the element, or where the focus is; Chromium tabs).", .args = withSurface(&([_]Arg{.{ .key = "key", .kind = .string, .flag = "--key", .description = "key spec", .required = true }} ++ locator_args)) },
    .{ .name = "browser_wait", .subcommand = "wait", .description = "Wait for a selector, the page load, or a locator to be visible (default and max 25000 ms).", .args = withSurface(&(wait_locator_args ++ [_]Arg{
        .{ .key = "load", .kind = .flag, .flag = "--load", .description = "wait until the page is loaded" },
        .{ .key = "visible", .kind = .flag, .flag = "--visible", .description = "with a locator: wait until it is visible" },
        .{ .key = "timeout_ms", .kind = .int, .flag = "--timeout", .description = "1-25000", .min = 1, .max = 25000 },
    })) },
    .{ .name = "browser_snapshot", .subcommand = "snapshot", .description = "Print the page accessibility tree with refs for later actions. On big pages pass interactive, max_depth or selector to keep the result small.", .args = withSurface(&.{
        .{ .key = "interactive", .kind = .flag, .flag = "--interactive", .description = "only interactive elements" },
        .{ .key = "max_depth", .kind = .int, .flag = "--max-depth", .description = "tree depth limit", .max = std.math.maxInt(u32) },
        .{ .key = "selector", .kind = .string, .flag = "--selector", .description = "only under this element" },
    }) },
    .{ .name = "browser_console", .subcommand = "console", .description = "Print page console logs.", .args = withSurface(&.{.{ .key = "clear", .kind = .flag, .flag = "--clear", .description = "empty the log after reading" }}) },
    .{ .name = "browser_back", .subcommand = "back", .description = "Go back in the tab's history (Chromium tabs). Answers not ok when there is nothing to go back to.", .args = withSurface(&.{}) },
    .{ .name = "browser_forward", .subcommand = "forward", .description = "Go forward in the tab's history (Chromium tabs). Answers not ok when there is nothing to go forward to.", .args = withSurface(&.{}) },
    .{ .name = "browser_reload", .subcommand = "reload", .description = "Reload the page (Chromium tabs).", .args = withSurface(&.{}) },
    .{ .name = "browser_exec", .subcommand = "exec", .description = "Run and await a JavaScript expression in the page; prints its result.", .args = withSurface(&.{
        .{ .key = "expression", .kind = .positional, .description = "JavaScript expression", .required = true },
        .{ .key = "args", .kind = .json_array, .flag = "--args", .description = "JSON array passed to the expression as the variable `args` (up to 128 levels of nesting inside the array)" },
        .{ .key = "max_result_bytes", .kind = .int, .flag = "--max-result-bytes", .description = "result size limit in bytes (default and max 16777216)", .min = 1, .max = 16 * 1024 * 1024 },
    }) },
    .{ .name = "browser_screenshot", .subcommand = "screenshot", .description = "Capture the visible part of the tab as a PNG image (at device scale, or a region of the view with an optional scale).", .args = withSurface(&.{
        .{ .key = "rect", .kind = .string, .flag = "--rect", .description = "region x,y,w,h in CSS pixels" },
        .{ .key = "scale", .kind = .number, .flag = "--scale", .description = "scale factor (for example 0.5 for a smaller image)", .positive = true },
    }) },
};

/// 결과를 그림으로 돌려주는 도구(CLI 가 표준 출력에 PNG 바이트를 쓴다).
pub fn returnsImage(tool: *const Tool) bool {
    return std.mem.eql(u8, tool.subcommand, "screenshot");
}

/// exec 인자(배열)의 어느 값이 서버 셈법의 깊이 `limit` 을 넘는가 — 원소가 깊이 0(서버 `validExecuteScriptArg` 와 같다, W9f 적대 리뷰 3 회차).
/// `limit` 을 넘는 순간 멈춘다(재귀 깊이도 그만큼 — std.json 의 값 파서는 깊이 상한이 없어 끝까지 재는 재귀는 수십만 단에서 스택을 넘겨
/// 서버째 죽었다, 2 회차).
fn argsDeeperThan(args: std.json.Value, limit: usize) bool {
    const items = switch (args) {
        .array => |a| a.items,
        else => return false,
    };
    for (items) |x| if (valueDeeperThan(x, 0, limit)) return true;
    return false;
}

fn valueDeeperThan(v: std.json.Value, depth: usize, limit: usize) bool {
    if (depth > limit) return true;
    const children: []const std.json.Value = switch (v) {
        .array => |a| a.items,
        .object => |o| o.values(),
        else => return false,
    };
    for (children) |x| if (valueDeeperThan(x, depth + 1, limit)) return true;
    return false;
}

/// `maru mcp` 의 인자 — 없으면 서버, `--help`·`-h` 면 사용법, 그 밖은 usage 오류(W9f 적대 리뷰 2 회차: 모두 무시해 터미널에서 `--help` 를
/// 치면 말없이 입력을 기다렸다).
pub const Invocation = enum { serve, help, bad };

pub fn invocation(args: []const []const u8) Invocation {
    if (args.len == 0) return .serve;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    return .bad;
}

pub const usage =
    \\usage: maru mcp
    \\Serve the browser commands as MCP tools over stdio (one JSON-RPC message per line).
    \\Add it to an agent, for example: claude mcp add maru -- maru mcp
    \\Run it from a maru pane — requests act for that pane (see `maru browser --help`).
    \\
;

pub fn findTool(name: []const u8) ?*const Tool {
    for (&tools) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

pub const ArgError = error{ UnknownArgument, WrongType, MissingArgument, RelativePath, OutOfMemory };

/// 도구 인자(JSON 객체)를 `maru browser` CLI 인자로 옮긴다 — 하위 명령이 맨 앞, 위치 인자는 맨 뒤. 모르는 키·틀린 형은 거절한다
/// (CLI 가 모르는 옵션을 거절하는 것과 같다 — 오타가 조용히 무시되지 않게). 값의 범위·배타는 `browser.parse` 가 본다. 돌려준 글은
/// `arena` 소유.
pub fn argv(arena: std.mem.Allocator, tool: *const Tool, arguments: ?std.json.Value) ArgError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, tool.subcommand);
    var positional: ?[]const u8 = null;
    var positional_list: []const std.json.Value = &.{};
    const obj: ?std.json.ObjectMap = if (arguments) |a| switch (a) {
        .object => |o| o,
        .null => null,
        else => return error.WrongType,
    } else null;
    if (obj) |o| {
        var it = o.iterator();
        while (it.next()) |e| {
            const spec = for (tool.args) |*a| {
                if (std.mem.eql(u8, a.key, e.key_ptr.*)) break a;
            } else return error.UnknownArgument;
            const v = e.value_ptr.*;
            switch (spec.kind) {
                // 값은 `--flag=값` 한 토큰으로 — 값이 `-` 로 시작하거나 `--help` 여도 옵션·도움말로 읽히지 않는다.
                .string => switch (v) {
                    .string => |s| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ spec.flag, s })),
                    else => return error.WrongType,
                },
                .int => {
                    // JSON Schema 의 integer 는 7.0 도 받는다(W9f 적대 리뷰 1 회차).
                    const n: i64 = switch (v) {
                        .integer => |n| n,
                        .float => |f| if (f == @trunc(f) and f >= 0 and f < 9.007199254740992e15) @intFromFloat(f) else return error.WrongType,
                        else => return error.WrongType,
                    };
                    if (n < 0) return error.WrongType;
                    try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, n }));
                },
                .number => switch (v) {
                    .integer => |n| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, n })),
                    .float => |f| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, f })),
                    else => return error.WrongType,
                },
                .flag => switch (v) {
                    .bool => |b| if (b) try out.append(arena, spec.flag),
                    else => return error.WrongType,
                },
                .bool_choice => switch (v) {
                    .bool => |b| try out.append(arena, if (b) spec.flag else spec.flag_false),
                    else => return error.WrongType,
                },
                .positional => switch (v) {
                    .string => |s| positional = s,
                    else => return error.WrongType,
                },
                .path_list => switch (v) {
                    .array => |a| {
                        if (a.items.len == 0 or a.items.len > spec.max_items) return error.WrongType;
                        for (a.items) |item| switch (item) {
                            .string => |p| if (p.len == 0 or p[0] != '/') return error.RelativePath,
                            else => return error.WrongType,
                        };
                        positional_list = a.items;
                    },
                    else => return error.WrongType,
                },
                .json_array => switch (v) {
                    .array => {
                        // 깊게 중첩된 배열은 글로 펼 때 쓰개의 중첩 한도(256)에서 서버째 panic 했다(W9f 적대 리뷰 1 회차).
                        if (argsDeeperThan(v, browser.max_args_depth)) return error.WrongType;
                        var aw: std.Io.Writer.Allocating = .init(arena);
                        std.json.Stringify.value(v, .{}, &aw.writer) catch return error.OutOfMemory;
                        try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ spec.flag, aw.written() }));
                    },
                    else => return error.WrongType,
                },
            }
        }
    }
    for (tool.args) |a| if (a.required) {
        const present = if (obj) |o| o.contains(a.key) else false;
        if (!present) return error.MissingArgument;
    };
    // 위치 인자는 `--` 뒤에 — `-` 로 시작해도(`-1`·`-h`) 옵션·도움말로 읽히지 않는다.
    if (positional) |p| try out.appendSlice(arena, &.{ "--", p });
    if (positional_list.len > 0) {
        try out.append(arena, "--");
        for (positional_list) |p| try out.append(arena, p.string);
    }
    return out.toOwnedSlice(arena);
}

/// 받은 한 줄이 무엇인가.
pub const Incoming = union(enum) {
    /// 곧 돌려줄 응답(소유 — 부른 쪽이 놓는다).
    reply: []u8,
    /// 도구를 부른다 — 부른 쪽이 CLI 를 돌리고 `toolResult` 로 답한다. `id`·`argv` 는 `arena` 소유.
    call: struct { id: cp.Id, tool: *const Tool, argv: []const []const u8 },
    /// 답하지 않는다(알림·응답).
    none,
};

/// JSON-RPC 한 줄을 처리한다. `arena` 는 이 줄의 수명(부른 쪽이 줄마다 비운다), 응답 글은 `gpa` 소유.
pub fn handleLine(gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!Incoming {
    const pm = cp.parseMessage(arena, line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .reply = try cp.serializeError(gpa, .null, cp.parseFailureCode(e), "invalid JSON-RPC message", null) },
    };
    const req = switch (pm.message) {
        .request => |r| r,
        .notification, .response => return .none, // notifications/initialized·cancelled 등 — 답하지 않는다
    };
    // MCP 는 요청 id 가 null 이면 안 된다(W9f 적대 리뷰 1 회차 — 답하고 있었다).
    if (req.id == .null) return .{ .reply = try cp.serializeError(gpa, .null, .invalid_request, "request id must not be null", null) };
    const id = try dupeId(arena, req.id);
    if (std.mem.eql(u8, req.method, "initialize")) return .{ .reply = try initializeResult(gpa, id, req.params) };
    if (std.mem.eql(u8, req.method, "ping")) return .{ .reply = try emptyResult(gpa, id) };
    if (std.mem.eql(u8, req.method, "tools/list")) return .{ .reply = try toolsListResult(gpa, id) };
    if (std.mem.eql(u8, req.method, "tools/call")) {
        const params = if (req.params) |p| switch (p) {
            .object => |o| o,
            else => return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tools/call params must be an object", null) },
        } else return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tools/call needs params", null) };
        const name = if (params.get("name")) |n| switch (n) {
            .string => |s| s,
            else => return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tool name must be a string", null) },
        } else return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tool name is missing", null) };
        const tool = findTool(name) orelse return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "unknown tool", null) };
        const args = argv(arena, tool, params.get("arguments")) catch |e| return .{ .reply = try toolResult(gpa, id, switch (e) {
            error.UnknownArgument => "error: unknown argument for this tool (see its input schema)",
            error.WrongType => "error: an argument has the wrong type (see the tool's input schema)",
            error.MissingArgument => "error: a required argument is missing",
            error.RelativePath => "error: file paths must be absolute (this server cannot know your working directory)",
            error.OutOfMemory => return error.OutOfMemory,
        }, true) };
        return .{ .call = .{ .id = id, .tool = tool, .argv = args } };
    }
    return .{ .reply = try cp.serializeError(gpa, id, .method_not_found, "method not found", null) };
}

fn dupeId(arena: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error!cp.Id {
    return switch (id) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        else => id,
    };
}

fn beginResult(s: *std.json.Stringify, id: cp.Id) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    switch (id) {
        .null => try s.write(null),
        .number => |n| try s.write(n),
        .string => |str| try s.write(str),
    }
    try s.objectField("result");
}

fn emptyResult(gpa: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn initializeResult(gpa: std.mem.Allocator, id: cp.Id, params: ?std.json.Value) std.mem.Allocator.Error![]u8 {
    var version: []const u8 = protocol_versions[0];
    if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
        for (protocol_versions) |known| if (std.mem.eql(u8, known, v.string)) {
            version = known;
        };
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("protocolVersion") catch |e| break :blk e;
        s.write(version) catch |e| break :blk e;
        s.objectField("capabilities") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("tools") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.objectField("serverInfo") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("name") catch |e| break :blk e;
        s.write(server_name) catch |e| break :blk e;
        s.objectField("version") catch |e| break :blk e;
        s.write("0") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.objectField("instructions") catch |e| break :blk e;
        s.write("Control the browser tabs of the maru terminal this agent runs in. Find tabs with browser_list or open one with browser_open, " ++
            "then act on them by id (surface). Prefer locators (role/by_text/by_label) or refs from browser_snapshot over CSS selectors. " ++
            "Requests come from the maru pane this process runs in; controlling a tab you did not open asks the user once. " ++
            "While the user answers that confirmation a call can take up to about 150 seconds (2 minutes for the answer, then the action), " ++
            "so give this server a tool timeout of at least 150 seconds. Calls run one at a time. " ++
            "On Chromium tabs (engine=chromium in browser_list) browser_console also holds lines from iframes and workers, " ++
            "and the first read after you are allowed a tab shows only the current page's lines (earlier lines are deleted, " ++
            "including pages the tab went through after the permission but before that read), except tabs you opened with browser_open " ++
            "(and tabs their pages opened), whose first read shows everything since the tab was created " ++
            "unless the user clicked, typed or navigated in that tab before it. " ++
            "A read from another pane (another agent, or the user running maru browser console there) takes the console over: " ++
            "your next read again shows only the current page's lines, and lines logged in between are gone for you. " ++
            "browser_upload asks the user every time, listing each file with a peek of its content; pass absolute paths of files " ++
            "(not folders) you mean to send, and expect it to wait for the user's answer. " ++
            "browser_network_requests and browser_network_request (Chromium tabs) need their own permission for the site the tab shows " ++
            "(asked once per site; tabs you opened need none); you see requests made after that permission (tabs you opened: since they were created, " ++
            "unless the user clicked, typed or navigated in that tab before your first read). Cookie, Set-Cookie and Authorization values are " ++
            "shown only for sites whose cookie permission you also hold on that tab (the user grants it when you run maru browser get-cookies " ++
            "on that site), and never when the " ++
            "user turned browser.agent-network-full off; request bodies are not recorded. " ++
            "browser_network_record turns recording of a tab's response bodies on (the tab title shows a red ◉; asked once per site on the user's tabs, " ++
            "not on tabs you opened); read a body with browser_network_request body:true, 64 KiB per call (or out for the whole body). " ++
            "A body sent with another site's cookies or login also needs that site's cookie permission.") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSchema(s: *std.json.Stringify, tool: *const Tool) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (tool.args) |a| {
        try s.objectField(a.key);
        try s.beginObject();
        try s.objectField("type");
        try s.write(switch (a.kind) {
            .string, .positional => "string",
            .int => "integer",
            .number => "number",
            .flag, .bool_choice => "boolean",
            .json_array, .path_list => "array",
        });
        if (a.kind == .path_list) {
            try s.objectField("items");
            try s.beginObject();
            try s.objectField("type");
            try s.write("string");
            try s.endObject();
            try s.objectField("minItems");
            try s.write(1);
            try s.objectField("maxItems");
            try s.write(a.max_items);
        }
        if (a.kind == .int) {
            try s.objectField("minimum");
            try s.write(a.min);
            if (a.max) |m| {
                try s.objectField("maximum");
                try s.write(m);
            }
        }
        if (a.positive) {
            try s.objectField("exclusiveMinimum");
            try s.write(0);
        }
        try s.objectField("description");
        try s.write(a.description);
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    for (tool.args) |a| if (a.required) try s.write(a.key);
    try s.endArray();
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
}

fn toolsListResult(gpa: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("tools") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        for (&tools) |*t| {
            s.beginObject() catch |e| break :blk e;
            s.objectField("name") catch |e| break :blk e;
            s.write(t.name) catch |e| break :blk e;
            s.objectField("description") catch |e| break :blk e;
            s.write(t.description) catch |e| break :blk e;
            s.objectField("inputSchema") catch |e| break :blk e;
            writeSchema(&s, t) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
        }
        s.endArray() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// 도구 결과 — CLI 가 낸 글 그대로(`text`), 실패면 `isError`.
/// 그림 도구 결과 — `content:[{type:"image", data:<base64>, mimeType:"image/png"}]`.
pub fn imageResult(gpa: std.mem.Allocator, id: cp.Id, png: []const u8) std.mem.Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const data = try gpa.alloc(u8, enc.calcSize(png.len));
    defer gpa.free(data);
    _ = enc.encode(data, png);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("content") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("type") catch |e| break :blk e;
        s.write("image") catch |e| break :blk e;
        s.objectField("data") catch |e| break :blk e;
        s.write(data) catch |e| break :blk e;
        s.objectField("mimeType") catch |e| break :blk e;
        s.write("image/png") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endArray() catch |e| break :blk e;
        s.objectField("isError") catch |e| break :blk e;
        s.write(false) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn toolResult(gpa: std.mem.Allocator, id: cp.Id, text: []const u8, is_error: bool) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("content") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("type") catch |e| break :blk e;
        s.write("text") catch |e| break :blk e;
        s.objectField("text") catch |e| break :blk e;
        s.write(text) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endArray() catch |e| break :blk e;
        s.objectField("isError") catch |e| break :blk e;
        s.write(is_error) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const browser = @import("browser.zig");

test "W9f: 도구 인자는 CLI 인자로 — 로케이터·플래그·위치 인자, 모르는 키·틀린 형·빠진 필수는 거절" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = struct {
        fn f(a: std.mem.Allocator, json: []const u8) !std.json.Value {
            return (try std.json.parseFromSlice(std.json.Value, a, json, .{})).value;
        }
    }.f;
    const click = findTool("browser_click").?;
    const a = try argv(arena, click, try parse(arena, "{\"surface\":7,\"role\":\"button\",\"name\":\"Save\",\"exact\":true,\"nth\":1}"));
    // 인자 순서는 JSON 객체 순서 — browser.parse 가 받는지가 중요하다.
    const p = try browser.parse(a);
    try testing.expectEqual(@as(u64, 7), p.request.click.surface_id);
    try testing.expectEqualStrings("click", a[0]);
    const nav = findTool("browser_navigate").?;
    const n = try argv(arena, nav, try parse(arena, "{\"url\":\"https://e.test/\",\"surface\":3}"));
    try testing.expectEqualStrings("https://e.test/", n[n.len - 1]); // 위치 인자는 맨 뒤(`--` 뒤)
    try testing.expectEqualStrings("--", n[n.len - 2]);
    try testing.expectEqualStrings("https://e.test/", (try browser.parse(n)).request.navigate.url);
    const open = findTool("browser_open").?;
    try testing.expectEqualStrings("open", (try argv(arena, open, null))[0]);
    try testing.expectError(error.UnknownArgument, argv(arena, click, try parse(arena, "{\"surface\":7,\"selectr\":\"#a\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "{\"surface\":\"7\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "{\"surface\":-1}")));
    try testing.expectError(error.MissingArgument, argv(arena, click, try parse(arena, "{\"selector\":\"#a\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "[1]")));
    const exec = findTool("browser_exec").?;
    const e = try argv(arena, exec, try parse(arena, "{\"surface\":2,\"expression\":\"1+1\",\"args\":[1,\"x\"]}"));
    const at = for (e, 0..) |tok, i| {
        if (std.mem.startsWith(u8, tok, "--args=")) break i;
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("--args=[1,\"x\"]", e[at]);
    try testing.expectEqualStrings("1+1", e[e.len - 1]);
}

test "W9f: 도구 표의 모든 도구는 CLI 하위 명령이고, 필수 인자만 준 호출을 browser.parse 가 받는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (&tools) |*t| {
        var obj: std.json.ObjectMap = .empty;
        for (t.args) |a| if (a.required) try obj.put(arena, a.key, switch (a.kind) {
            .int => .{ .integer = 4 },
            .string, .positional => .{ .string = if (std.mem.eql(u8, a.key, "key")) "Enter" else if (std.mem.eql(u8, a.key, "url")) "https://e.test/" else "x" },
            .path_list => try jsonOf(arena, "[\"/tmp/a.txt\"]"),
            else => .{ .bool = true },
        });
        const extra: ?[]const u8 = if (std.mem.eql(u8, t.subcommand, "click") or std.mem.eql(u8, t.subcommand, "type") or std.mem.eql(u8, t.subcommand, "scroll") or std.mem.eql(u8, t.subcommand, "hover") or std.mem.eql(u8, t.subcommand, "upload"))
            "selector"
        else if (std.mem.eql(u8, t.subcommand, "wait")) "selector" else null;
        if (extra) |k| try obj.put(arena, k, .{ .string = "#a" });
        const a = try argv(arena, t, .{ .object = obj });
        _ = browser.parse(a) catch |err| {
            std.debug.print("tool {s} → {any}\n", .{ t.name, err });
            return err;
        };
    }
}

test "W9c①: initialize 의 안내는 Chromium 탭의 console 을 「아직 안 됨」 이라 하지 않고, 무엇이 담기는지 알린다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = (try handleLine(testing.allocator, arena_state.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).reply;
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "not available yet") == null);
    try testing.expect(std.mem.indexOf(u8, r, "browser_console") != null);
    try testing.expect(std.mem.indexOf(u8, r, "iframes and workers") != null);
    // 다른 pane 의 읽기가 묶음을 가져간다는 것도(W9c① 적대 리뷰 2 회차 F3).
    try testing.expect(std.mem.indexOf(u8, r, "A read from another pane") != null);
    // 에이전트가 연 탭은 처음부터 다 본다는 것과 첫 읽기가 앞 줄을 지운다는 것도(3 회차 F1).
    try testing.expect(std.mem.indexOf(u8, r, "everything since the tab was created") != null);
    // 첫 읽기 전에 사용자가 그 탭을 몰면 그 예외가 풀린다는 것도(4 회차 D).
    try testing.expect(std.mem.indexOf(u8, r, "unless the user clicked, typed or navigated in that tab before it") != null);
    try testing.expect(std.mem.indexOf(u8, r, "earlier lines are deleted") != null);
}

test "W9f: JSON-RPC — initialize 는 아는 판으로, tools/list·ping·모르는 메서드·알림, tools/call 은 CLI 인자로" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"protocolVersion\":\"2024-11-05\"") != null);
        try testing.expect(std.mem.indexOf(u8, r, "\"tools\":{}") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"id\":\"a\"") != null);
        try testing.expect(std.mem.indexOf(u8, r, protocol_versions[0]) != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).reply;
        defer testing.allocator.free(r);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
        defer parsed.deinit();
        try testing.expectEqual(tools.len, parsed.value.object.get("result").?.object.get("tools").?.array.items.len);
    }
    try testing.expect(try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == .none);
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32601") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "not json")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32700") != null);
    }
    {
        const c = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_close\",\"arguments\":{\"surface\":12}}}")).call;
        try testing.expectEqualStrings("close", c.argv[0]);
        try testing.expectEqual(@as(i64, 4), c.id.number);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_close\",\"arguments\":{\"id\":12}}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"isError\":true") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }
}

test "W9f: 도구 결과는 MCP content 한 글과 isError" {
    const r = try toolResult(testing.allocator, .{ .number = 9 }, "opened 7 https://e.test/\n", false);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"opened 7 https://e.test/\\n\"}],\"isError\":false}}", r);
}

test "W9f: 스크린샷은 그림 결과(base64 PNG), rect·scale 은 CLI 인자로" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shot = findTool("browser_screenshot").?;
    try testing.expect(returnsImage(shot));
    try testing.expect(!returnsImage(findTool("browser_snapshot").?));
    const v = (try std.json.parseFromSlice(std.json.Value, arena, "{\"surface\":3,\"rect\":\"0,0,10,10\",\"scale\":0.5}", .{})).value;
    const p = try browser.parse(try argv(arena, shot, v));
    try testing.expectEqual(@as(u64, 3), p.screenshot.surface_id);
    const r = try imageResult(testing.allocator, .{ .number = 9 }, "\x89PNG");
    defer testing.allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer parsed.deinit();
    const c = parsed.value.object.get("result").?.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("image", c.get("type").?.string);
    try testing.expectEqualStrings("iVBORw==", c.get("data").?.string);
    try testing.expectEqualStrings("image/png", c.get("mimeType").?.string);
}

test "W9f: `-` 로 시작하는 exec 식도 식으로 간다(옵션으로 읽히지 않는다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exec = findTool("browser_exec").?;
    for ([_][]const u8{ "-1", "--x", "-document.body.scrollHeight" }) |expr| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "surface", .{ .integer = 2 });
        try obj.put(arena, "expression", .{ .string = expr });
        const p = try browser.parse(try argv(arena, exec, .{ .object = obj }));
        try testing.expectEqualStrings(expr, std.mem.trimStart(u8, p.request.exec.script, " "));
    }
}

test "W9f: `-` 로 시작하거나 `--help` 인 값도 값으로 간다(도움말·옵션으로 읽히지 않는다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { tool: []const u8, key: []const u8, value: []const u8 };
    for ([_]Case{
        .{ .tool = "browser_type", .key = "text", .value = "--help" },
        .{ .tool = "browser_type", .key = "text", .value = "-h" },
        .{ .tool = "browser_type", .key = "text", .value = "-5" },
        .{ .tool = "browser_press", .key = "key", .value = "-" },
        .{ .tool = "browser_click", .key = "by_text", .value = "-" },
        .{ .tool = "browser_exec", .key = "expression", .value = "-h" },
    }) |c| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "surface", .{ .integer = 2 });
        try obj.put(arena, c.key, .{ .string = c.value });
        if (std.mem.eql(u8, c.tool, "browser_type")) try obj.put(arena, "selector", .{ .string = "#a" });
        const cmd = browser.parse(try argv(arena, findTool(c.tool).?, .{ .object = obj })) catch |e| {
            std.debug.print("{s} {s}={s} → {any}\n", .{ c.tool, c.key, c.value, e });
            return e;
        };
        if (cmd != .request) {
            std.debug.print("{s} {s}={s} → {s}\n", .{ c.tool, c.key, c.value, @tagName(cmd) });
            return error.TestUnexpectedResult;
        }
    }
}

fn jsonOf(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, arena, text, .{})).value;
}

test "W9f 적대 리뷰 1 회차: 아주 깊게 중첩된 exec args 는 서버를 죽이지 않고 거절한다(전에는 256 단에서 panic — 세션의 도구가 모두 사라졌다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]usize{ 200, 255, 300, 2000 }) |depth| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "{\"surface\":2,\"expression\":\"1\",\"args\":[");
        for (0..depth) |_| try buf.append(arena, '[');
        for (0..depth) |_| try buf.append(arena, ']');
        try buf.appendSlice(arena, "]}");
        // 파싱 자체가 깊이를 거절할 수도 있다 — 그러면 handleLine 이 -32700 으로 답한다(죽지 않는다).
        const v = std.json.parseFromSlice(std.json.Value, arena, buf.items, .{}) catch continue;
        const a = argv(arena, findTool("browser_exec").?, v.value) catch |e| {
            try testing.expect(e == error.WrongType);
            continue;
        };
        // 받았다면 CLI 파서도 받아야 하고, 요청을 만들 수 있어야 한다.
        const cmd = try browser.parse(a);
        const bytes = try browser.buildRequestBytes(arena, cmd.request, .{ .number = 1 });
        try testing.expect(bytes.len > 0);
    }
}

test "W9f 적대 리뷰 1 회차: 모든 도구의 선택 인자 하나하나가 browser.parse 를 지난다(스키마가 내보인 인자를 파서가 거절하지 않는다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (&tools) |*t| for (t.args) |opt| {
        if (opt.required) continue;
        var obj: std.json.ObjectMap = .empty;
        for (t.args) |a| if (a.required) try obj.put(arena, a.key, switch (a.kind) {
            .int => .{ .integer = 4 },
            .bool_choice => .{ .bool = true },
            .path_list => try jsonOf(arena, "[\"/tmp/a.txt\"]"),
            else => .{ .string = if (std.mem.eql(u8, a.key, "key")) "Enter" else if (std.mem.eql(u8, a.key, "url")) "https://e.test/" else "x" },
        });
        // 이 인자와 함께 써야 하는 짝(로케이터는 하나가 있어야, --name·--exact 는 role 과).
        const needs_locator = std.mem.eql(u8, t.subcommand, "click") or std.mem.eql(u8, t.subcommand, "type") or std.mem.eql(u8, t.subcommand, "scroll") or std.mem.eql(u8, t.subcommand, "hover") or std.mem.eql(u8, t.subcommand, "wait") or std.mem.eql(u8, t.subcommand, "upload");
        const is_locator = std.mem.eql(u8, opt.key, "selector") or std.mem.eql(u8, opt.key, "ref") or std.mem.eql(u8, opt.key, "role") or std.mem.eql(u8, opt.key, "by_text") or std.mem.eql(u8, opt.key, "by_label");
        const with_role = std.mem.eql(u8, opt.key, "name") or std.mem.eql(u8, opt.key, "level") or std.mem.eql(u8, opt.key, "exact") or std.mem.eql(u8, opt.key, "nth");
        if (with_role) {
            try obj.put(arena, "role", .{ .string = "button" });
            if (std.mem.eql(u8, opt.key, "exact")) try obj.put(arena, "name", .{ .string = "Go" });
        } else if (needs_locator and !is_locator and !std.mem.eql(u8, opt.key, "load")) try obj.put(arena, "selector", .{ .string = "#a" });
        if (std.mem.eql(u8, opt.key, "visible")) _ = obj.swapRemove("selector");
        if (std.mem.eql(u8, opt.key, "visible")) try obj.put(arena, "role", .{ .string = "button" });
        try obj.put(arena, opt.key, switch (opt.kind) {
            .int => .{ .integer = 3 },
            .number => .{ .float = 0.5 },
            .flag => .{ .bool = true },
            .json_array => try jsonOf(arena, "[1]"),
            else => .{ .string = if (std.mem.eql(u8, opt.key, "rect")) "0,0,10,10" else if (std.mem.eql(u8, opt.key, "role")) "button" else if (std.mem.eql(u8, opt.key, "url")) "https://e.test/" else if (std.mem.eql(u8, opt.key, "types")) "xhr,image" else if (std.mem.eql(u8, opt.key, "status")) "4xx" else if (std.mem.eql(u8, opt.key, "out")) "/tmp/body" else "x" },
        });
        const a = try argv(arena, t, .{ .object = obj });
        _ = browser.parse(a) catch |err| {
            std.debug.print("tool {s} arg {s} → {any}\n", .{ t.name, opt.key, err });
            return err;
        };
    };
}

test "W9f 적대 리뷰 1 회차: 거짓 플래그는 싣지 않고, 정수 값의 부동소수(7.0)는 정수로, 스키마는 모르는 키를 막고 파서의 최솟값을 알린다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const snap = findTool("browser_snapshot").?;
    const a = try argv(arena, snap, try jsonOf(arena, "{\"surface\":7.0,\"interactive\":false}"));
    try testing.expectEqual(@as(usize, 2), a.len); // snapshot --surface=7
    try testing.expectEqualStrings("--surface=7", a[1]);
    try testing.expectError(error.WrongType, argv(arena, snap, try jsonOf(arena, "{\"surface\":7.5}")));
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).reply;
    defer testing.allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |t| {
        const schema = t.object.get("inputSchema").?.object;
        try testing.expect(!schema.get("additionalProperties").?.bool);
        if (std.mem.eql(u8, t.object.get("name").?.string, "browser_wait")) {
            const props = schema.get("properties").?.object;
            try testing.expectEqual(@as(i64, 1), props.get("timeout_ms").?.object.get("minimum").?.integer);
            try testing.expectEqual(@as(i64, 1), props.get("level").?.object.get("minimum").?.integer);
        }
    }
}

test "W9f 적대 리뷰 1 회차: id 가 null 인 요청은 -32600(MCP 는 null id 를 금한다), batch 를 받지 않으니 batch 가 있는 2025-03-26 은 알리지 않는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}")).reply;
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "-32600") != null);
    for (protocol_versions) |v| try testing.expect(!std.mem.eql(u8, v, "2025-03-26"));
    const i = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}")).reply;
    defer testing.allocator.free(i);
    try testing.expect(std.mem.indexOf(u8, i, "\"protocolVersion\":\"2025-06-18\"") != null);
}

test "W9f 적대 리뷰 2 회차: 수십만 단으로 중첩된 args 도 스택을 넘지 않고 거절한다(깊이 재기 재귀가 서버를 죽였다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depth = 300_000;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"surface\":2,\"expression\":\"1\",\"args\":");
    try buf.appendNTimes(arena, '[', depth);
    try buf.appendNTimes(arena, ']', depth);
    try buf.append(arena, '}');
    const v = try std.json.parseFromSlice(std.json.Value, arena, buf.items, .{});
    try testing.expectError(error.WrongType, argv(arena, findTool("browser_exec").?, v.value));
}

test "W9f 적대 리뷰 2 회차: 스키마가 파서의 최댓값과 scale 의 양수 조건을 알린다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).reply;
    defer testing.allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer parsed.deinit();
    var seen: usize = 0;
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |t| {
        const props = t.object.get("inputSchema").?.object.get("properties").?.object;
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "browser_wait")) {
            try testing.expectEqual(@as(i64, 25000), props.get("timeout_ms").?.object.get("maximum").?.integer);
            try testing.expectEqual(@as(i64, 100), props.get("level").?.object.get("maximum").?.integer);
            try testing.expectEqual(@as(i64, 1_000_000), props.get("nth").?.object.get("maximum").?.integer);
            seen += 1;
        }
        if (std.mem.eql(u8, name, "browser_exec")) {
            try testing.expectEqual(@as(i64, 16 * 1024 * 1024), props.get("max_result_bytes").?.object.get("maximum").?.integer);
            try testing.expect(std.mem.indexOf(u8, props.get("args").?.object.get("description").?.string, "`args`") != null);
            seen += 1;
        }
        if (std.mem.eql(u8, name, "browser_screenshot")) {
            try testing.expectEqual(@as(i64, 0), props.get("scale").?.object.get("exclusiveMinimum").?.integer);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "W9f 적대 리뷰 2 회차: `maru mcp` 의 인자 — 없으면 서버, --help·-h 는 사용법, 그 밖은 오류" {
    try testing.expectEqual(Invocation.serve, invocation(&.{}));
    try testing.expectEqual(Invocation.help, invocation(&.{"--help"}));
    try testing.expectEqual(Invocation.help, invocation(&.{"-h"}));
    try testing.expectEqual(Invocation.bad, invocation(&.{"bogus"}));
    try testing.expectEqual(Invocation.bad, invocation(&.{ "--help", "x" }));
}

test "W9f 적대 리뷰 3 회차: MCP 도 exec args 를 서버 셈법으로 — 129 단 스칼라는 받고 130 단은 거절, 가장 안쪽 빈 배열은 한 단 더" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { brackets: usize, inner: []const u8, ok: bool };
    for ([_]Case{
        .{ .brackets = 129, .inner = "1", .ok = true },
        .{ .brackets = 130, .inner = "1", .ok = false },
        .{ .brackets = 130, .inner = "", .ok = true },
        .{ .brackets = 131, .inner = "", .ok = false },
    }) |c| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "{\"surface\":2,\"expression\":\"1\",\"args\":");
        try buf.appendNTimes(arena, '[', c.brackets);
        try buf.appendSlice(arena, c.inner);
        try buf.appendNTimes(arena, ']', c.brackets);
        try buf.append(arena, '}');
        const v = try std.json.parseFromSlice(std.json.Value, arena, buf.items, .{});
        const r = argv(arena, findTool("browser_exec").?, v.value);
        if (c.ok) {
            const a = try r;
            _ = try browser.parse(a); // CLI 파서도 같은 셈
        } else try testing.expectError(error.WrongType, r);
    }
}

test "W9f 적대 리뷰 3 회차: 모든 정수 인자의 스키마 상한은 파서와 같다 — 상한은 받고 상한+1 은 거절" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (&tools) |*t| for (t.args) |arg| {
        if (arg.kind != .int or std.mem.eql(u8, arg.key, "surface")) continue;
        const max = arg.max orelse {
            std.debug.print("int arg {s}.{s} has no maximum\n", .{ t.name, arg.key });
            return error.TestUnexpectedResult;
        };
        for ([_]i64{ max, max + 1 }) |value| {
            var obj: std.json.ObjectMap = .empty;
            var one_path = std.json.Array.init(arena);
            try one_path.append(.{ .string = "/tmp/a.txt" });
            for (t.args) |a| if (a.required) try obj.put(arena, a.key, switch (a.kind) {
                .int => .{ .integer = 4 },
                .bool_choice => .{ .bool = true },
                .path_list => .{ .array = one_path },
                else => .{ .string = if (std.mem.eql(u8, a.key, "key")) "Enter" else if (std.mem.eql(u8, a.key, "url")) "https://e.test/" else "x" },
            });
            if (std.mem.eql(u8, arg.key, "level") or std.mem.eql(u8, arg.key, "nth")) try obj.put(arena, "role", .{ .string = "button" });
            if (std.mem.eql(u8, t.subcommand, "wait") and std.mem.eql(u8, arg.key, "timeout_ms")) try obj.put(arena, "selector", .{ .string = "#a" });
            if ((std.mem.eql(u8, t.subcommand, "click") or std.mem.eql(u8, t.subcommand, "type") or std.mem.eql(u8, t.subcommand, "scroll") or std.mem.eql(u8, t.subcommand, "hover") or std.mem.eql(u8, t.subcommand, "upload")) and !obj.contains("role")) try obj.put(arena, "selector", .{ .string = "#a" });
            try obj.put(arena, arg.key, .{ .integer = value });
            const a = try argv(arena, t, .{ .object = obj });
            const ok = if (browser.parse(a)) |_| true else |_| false;
            if (ok != (value == max)) {
                std.debug.print("{s}.{s}={d}: parse ok={}\n", .{ t.name, arg.key, value, ok });
                return error.TestUnexpectedResult;
            }
        }
    };
}

test "W9f 적대 리뷰 4 회차: 인자가 틀린 도구 호출은 isError 결과, 스키마의 required 는 파서의 필수와 같다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 모르는 인자 — argv 에서 거절 → isError 결과(JSON-RPC 오류가 아니다).
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_click\",\"arguments\":{\"surface\":1,\"bogus\":1}}}")).reply;
    defer testing.allocator.free(r);
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer p.deinit();
    try testing.expect(p.value.object.get("result").?.object.get("isError").?.bool);
    // required — 도구마다 스키마의 required 와 표의 required 가 같고, 빼면 파서가 거절한다.
    const l = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\"}")).reply;
    defer testing.allocator.free(l);
    const lp = try std.json.parseFromSlice(std.json.Value, testing.allocator, l, .{});
    defer lp.deinit();
    for (lp.value.object.get("result").?.object.get("tools").?.array.items, 0..) |t, i| {
        const req = t.object.get("inputSchema").?.object.get("required").?.array.items;
        var n: usize = 0;
        for (tools[i].args) |a| if (a.required) {
            n += 1;
        };
        try testing.expectEqual(n, req.len);
        for (req) |k| {
            const arg = for (tools[i].args) |a| {
                if (std.mem.eql(u8, a.key, k.string)) break a;
            } else return error.TestUnexpectedResult;
            try testing.expect(arg.required);
        }
    }
}

test "W9c②: browser_dialog·browser_handle_dialog — accept(참·거짓)는 --accept·--dismiss 로, 스키마는 boolean·필수, text·dialog 는 선택이고 browser.parse 가 받는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = findTool("browser_dialog").?;
    try testing.expectEqual(@as(u64, 4), (try browser.parse(try argv(arena, list, try jsonOf(arena, "{\"surface\":4}")))).request.dialog.surface_id);
    const handle = findTool("browser_handle_dialog").?;
    const yes = try browser.parse(try argv(arena, handle, try jsonOf(arena, "{\"surface\":4,\"accept\":true,\"text\":\"-maru\",\"dialog\":9}")));
    try testing.expect(yes.request.handle_dialog.accept);
    try testing.expectEqualStrings("-maru", yes.request.handle_dialog.text.?);
    try testing.expectEqual(@as(u64, 9), yes.request.handle_dialog.dialog.?);
    const no = try browser.parse(try argv(arena, handle, try jsonOf(arena, "{\"surface\":4,\"accept\":false}")));
    try testing.expect(!no.request.handle_dialog.accept);
    try testing.expectError(error.MissingArgument, argv(arena, handle, try jsonOf(arena, "{\"surface\":4}")));
    try testing.expectError(error.WrongType, argv(arena, handle, try jsonOf(arena, "{\"surface\":4,\"accept\":\"yes\"}")));
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).reply;
    defer testing.allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |t| {
        if (!std.mem.eql(u8, t.object.get("name").?.string, "browser_handle_dialog")) continue;
        const schema = t.object.get("inputSchema").?.object;
        try testing.expectEqualStrings("boolean", schema.get("properties").?.object.get("accept").?.object.get("type").?.string);
        try testing.expectEqual(@as(usize, 2), schema.get("required").?.array.items.len); // surface·accept
        return;
    }
    return error.TestUnexpectedResult;
}

test "W9c③: browser_upload — 파일은 절대 경로 배열(1..10)로 `--` 뒤 위치 인자가 되고 browser.parse 가 받는다, 상대 경로는 MCP 가 거절한다(isError)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool = findTool("browser_upload").?;
    const a = try argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"by_label\":\"Resume\",\"files\":[\"/tmp/a.txt\",\"/tmp/-h\"]}"));
    const cmd = (try browser.parse(a)).request.upload;
    try testing.expectEqual(@as(u64, 4), cmd.surface_id);
    try testing.expectEqualStrings("Resume", cmd.locator.label.value);
    try testing.expectEqual(@as(usize, 2), cmd.count);
    try testing.expectEqualStrings("/tmp/-h", cmd.paths()[1]); // `--` 뒤라 도움말이 아니다
    try testing.expectError(error.RelativePath, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\",\"files\":[\"a.txt\"]}")));
    try testing.expectError(error.RelativePath, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\",\"files\":[\"~/a.txt\"]}")));
    try testing.expectError(error.WrongType, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\",\"files\":[]}")));
    try testing.expectError(error.WrongType, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\",\"files\":\"/tmp/a\"}")));
    try testing.expectError(error.WrongType, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\",\"files\":[\"/1\",\"/2\",\"/3\",\"/4\",\"/5\",\"/6\",\"/7\",\"/8\",\"/9\",\"/10\",\"/11\"]}")));
    try testing.expectError(error.MissingArgument, argv(arena, tool, try jsonOf(arena, "{\"surface\":4,\"selector\":\"#f\"}")));
    // 상대 경로의 도구 호출은 JSON-RPC 오류가 아니라 isError 결과 — 왜인지 말한다.
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_upload\",\"arguments\":{\"surface\":1,\"selector\":\"#f\",\"files\":[\"a.txt\"]}}}")).reply;
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "must be absolute") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\"isError\":true") != null);
    // 스키마 — 문자열 배열, 1..10 개, 필수.
    const l = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\"}")).reply;
    defer testing.allocator.free(l);
    const lp = try std.json.parseFromSlice(std.json.Value, testing.allocator, l, .{});
    defer lp.deinit();
    for (lp.value.object.get("result").?.object.get("tools").?.array.items) |t| {
        if (!std.mem.eql(u8, t.object.get("name").?.string, "browser_upload")) continue;
        const files = t.object.get("inputSchema").?.object.get("properties").?.object.get("files").?.object;
        try testing.expectEqualStrings("array", files.get("type").?.string);
        try testing.expectEqualStrings("string", files.get("items").?.object.get("type").?.string);
        try testing.expectEqual(@as(i64, 1), files.get("minItems").?.integer);
        try testing.expectEqual(@as(i64, browser.max_upload_files), files.get("maxItems").?.integer);
        return;
    }
    return error.TestUnexpectedResult;
}

test "W9d① 변이 생존 MC1: 네트워크 도구의 번호·크기 인자는 스키마 최솟값도 1 이다 — CLI 파서가 0 을 거절하는 범위와 같게(에이전트가 스키마를 믿고 0 을 보내 실패하지 않게)" {
    var seen: usize = 0;
    for ([_][]const u8{ "browser_network_requests", "browser_network_request" }) |name| {
        for (findTool(name).?.args) |a| if (std.mem.eql(u8, a.key, "req") or std.mem.eql(u8, a.key, "before_req") or std.mem.eql(u8, a.key, "page_size")) {
            try testing.expectEqual(@as(i64, 1), a.min);
            seen += 1;
        };
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectError(error.InvalidRequestId, browser.parse(&.{ "network-request", "--surface", "4", "--req", "0" }));
}

test "W9d①: browser_network_requests·browser_network_request — 인자가 CLI 의 network·network-request 로, 범위는 파서와 같고, 안내는 권한·보이는 범위를 말한다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = findTool("browser_network_requests").?;
    const a = try argv(arena, list, try jsonOf(arena, "{\"surface\":4,\"types\":\"xhr,document\",\"status\":\"404\",\"page_size\":10,\"clear\":true}"));
    const cmd = (try browser.parse(a)).request.network;
    try testing.expectEqual(@as(u64, 4), cmd.surface_id);
    try testing.expectEqual(@as(usize, 2), cmd.type_count);
    try testing.expectEqual(@as(?u16, 404), cmd.status);
    try testing.expectEqual(@as(?u32, 10), cmd.page_size);
    try testing.expect(cmd.clear);
    // W9d① 적대 리뷰 1 회차 F7: 커서.
    const cur = (try browser.parse(try argv(arena, list, try jsonOf(arena, "{\"surface\":4,\"before_req\":11}")))).request.network;
    try testing.expectEqual(@as(?u64, 11), cur.before_req);
    const one = findTool("browser_network_request").?;
    const d = (try browser.parse(try argv(arena, one, try jsonOf(arena, "{\"surface\":4,\"req\":12}")))).request.network_request;
    try testing.expect(d.surface_id == 4 and d.req == 12);
    try testing.expectError(error.MissingArgument, argv(arena, one, try jsonOf(arena, "{\"surface\":4}")));
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).reply;
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "browser_network_requests") != null);
    try testing.expect(std.mem.indexOf(u8, r, "browser.agent-network-full") != null);
    try testing.expect(std.mem.indexOf(u8, r, "request bodies are not recorded") != null);
    // W9d① 적대 리뷰 3 회차 D1·M1: 자격 증명 값은 쿠키 권한이 있을 때만, 숨긴 이동은 덮이지 않는 사이트에서 시작했거나 지나간 것.
    try testing.expect(std.mem.indexOf(u8, r, "cookie permission") != null);
    try testing.expect(std.mem.indexOf(u8, list.description, "started on or passed through such a site") != null);
    try testing.expect(std.mem.indexOf(u8, one.description, "cookie permission") != null);
}

test "W9d②: browser_network_record·browser_network_request 의 본문 인자 — CLI 의 network-record --on/--off·--body --offset --max-bytes --out 으로, 범위는 파서와 같고, 안내는 상한·권한을 말한다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rec = findTool("browser_network_record").?;
    try testing.expect((try browser.parse(try argv(arena, rec, try jsonOf(arena, "{\"surface\":4,\"on\":true}")))).request.network_record.on);
    try testing.expect(!(try browser.parse(try argv(arena, rec, try jsonOf(arena, "{\"surface\":4,\"on\":false}")))).request.network_record.on);
    try testing.expectError(error.MissingArgument, argv(arena, rec, try jsonOf(arena, "{\"surface\":4}")));
    const one = findTool("browser_network_request").?;
    const d = (try browser.parse(try argv(arena, one, try jsonOf(arena, "{\"surface\":4,\"req\":2,\"body\":true,\"body_offset\":65536,\"body_max_bytes\":1000}")))).request.network_request;
    try testing.expect(d.body and d.offset.? == 65536 and d.max_bytes.? == 1000);
    const o = (try browser.parse(try argv(arena, one, try jsonOf(arena, "{\"surface\":4,\"req\":2,\"body_max_bytes\":1000,\"out\":\"/tmp/b.bin\"}")))).request.network_request;
    try testing.expectEqualStrings("/tmp/b.bin", o.out.?);
    // W9d② 적대 리뷰 3 회차: out 은 본문 전부 — body_offset 과 함께면 파서가 거절한다(설명이 말한다).
    try testing.expectError(error.OutWithOffset, browser.parse(try argv(arena, one, try jsonOf(arena, "{\"surface\":4,\"req\":2,\"body_offset\":0,\"out\":\"/tmp/b.bin\"}"))));
    try testing.expect(std.mem.indexOf(u8, one.description, "not together with body_offset") != null);
    try testing.expect(std.mem.indexOf(u8, one.description, "' ⏎ '") != null);
    // 스키마 범위 = 파서 범위.
    for (one.args) |a| {
        if (std.mem.eql(u8, a.key, "body_max_bytes")) try testing.expect(a.min == 1 and a.max.? == browser.max_network_body_read);
        if (std.mem.eql(u8, a.key, "body_offset")) try testing.expect(a.min == 0 and a.max.? == browser.max_network_body_bytes);
    }
    try testing.expect(std.mem.indexOf(u8, one.description, "64 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, one.description, "1 MiB") != null);
    try testing.expect(std.mem.indexOf(u8, rec.description, "◉") != null);
    const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).reply;
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "browser_network_record") != null);
}
