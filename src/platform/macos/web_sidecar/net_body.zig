//! 응답 본문 기록(W9d② — docs/plans/web-osr-backend.md 「W9d② 결정」). maru 가 `net_record` 로 켠 탭에만 CDP `Network.enable` 을 걸고,
//! 그 탭의 CDP 이벤트와 CEF 처리기의 요청을 맞춰(`net_body_table` — CEF 를 모르는 표) 글 응답의 본문을 `Network.getResponseBody` 로 받아
//! `net_body_data`·`net_body_end` 로 보낸다. 다른 탭은 CDP 이벤트를 켜지 않는다(쏟아질 때 요청마다 이벤트 여섯 — J7).
//!
//! - 관찰자는 기록하는 탭에만 따로 단다(`devtools.zig` 의 것과 나눈다 — 이벤트 콜백은 이 관찰자에만). 결과는 그 브라우저의 모든 관찰자에게
//!   가므로 제 번호 대역 `[1<<28, 1<<29)` 만 고른다(J13 — 비었다). 등록은 끄는 명령·브라우저 닫힘에서 놓는다(콜백 안에서는 놓지 않는다).
//! - `Network.enable {maxResourceBufferSize 2 MiB, maxTotalBufferSize 8 MiB, maxPostDataSize 1}` — 2 MiB 인 까닭: Chromium 은 Latin-1
//!   밖의 글자가 하나라도 있으면 글을 UTF-16 으로 센다(J4 — 1 MiB 면 0.6 MB JSON 이 밀렸다). 우리 상한(1 MiB)은 `dataReceived` 합으로 따로
//!   본다(스크립트·스타일은 CDP 상한이 듣지 않았다 — 11 MB). `maxPostDataSize` 는 1(0 은 「상한 없음」 이다 — J10).
//! - 끌 때는 `Network.disable` 을 보내며 곧 세대를 바꾼다 — 그 답이 쏟아짐 뒤로 2.8 초 늦을 수 있다(J6). 렌더러가 죽으면 보낸 호출은 다음
//!   이동까지 답이 없다(J5) — `detached` 로 곧 끝낸다. 렌더러가 바뀌거나 다시 떠도 다시 켤 필요는 없다(J5).
//! - 본문 frame 은 보내는 줄에 본문 하나의 자리를 먼저 잡는다(`events.Writer.reserveBody`) — 없으면 `busy`(maru 가 읽지 않는 동안 UI 스레드가
//!   서지 않는다 — J7).
//! - 시각은 mach_absolute_time 의 µs — Chromium 의 TimeTicks(CDP `timestamp`)와 같은 시계다(J1). `network.zig` 의 IO 스레드도 이것으로 찍는다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("net_body_table.zig");
const events = @import("events.zig");

const msg = protocol.message;
const BrowserId = msg.BrowserId;
const gpa = std.heap.c_allocator;

var table: table_mod.Table = .{};
var registrations: [registry_mod.capacity]?struct { cef_id: c_int, browser: BrowserId, reg: [*c]c.cef_registration_t } = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var ready = false;
var tick_task: c.cef_task_t = undefined;
var tick_posted = false;
/// 어느 탭이든 기록하는가 — IO 스레드(`network.zig`)가 값싸게 본다(주소 해시를 낼지).
pub var any_recording = std.atomic.Value(bool).init(false);
/// `Network.enable`·`Network.disable` 의 번호 — 결과가 오면 켜짐을 알린다(본문 호출과 같은 대역).
var control_ids: [registry_mod.capacity]struct { id: i32 = 0, browser: BrowserId = 0, session: u32 = 0, enable: bool = false } = @splat(.{});

const tick_ms: i64 = 50;

extern "c" fn mach_absolute_time() u64;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *Timebase) c_int;
var timebase: Timebase = .{ .numer = 0, .denom = 0 };

/// mach_absolute_time 의 µs(CDP `timestamp` 와 같은 시계 — J1). 어느 스레드에서나.
pub fn machUs() i64 {
    if (@atomicLoad(u32, &timebase.denom, .acquire) == 0) {
        var tb: Timebase = undefined;
        _ = mach_timebase_info(&tb);
        @atomicStore(u32, &timebase.numer, tb.numer, .release);
        @atomicStore(u32, &timebase.denom, tb.denom, .release);
    }
    const numer = @atomicLoad(u32, &timebase.numer, .acquire);
    const denom = @atomicLoad(u32, &timebase.denom, .acquire);
    return @intCast(@as(u128, mach_absolute_time()) * numer / denom / 1000);
}

/// 판정자 전용 진단(`MARU_WEB_TEST_BODY_LOG`) — 맞추기의 사건을 stderr 에 한 줄씩. 제품에서는 켜지 않는다(UI 스레드에서 이벤트마다 쓰면 느려진다 — J7).
var debug_log = false;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (!debug_log) return;
    std.debug.print("body: " ++ fmt ++ "\n", args);
}

fn init() void {
    if (ready) return;
    ready = true;
    debug_log = std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null;
    observer = object.zeroed(c.cef_dev_tools_message_observer_t);
    object.staticRefCounted(&observer.base);
    observer.on_dev_tools_event = &onEvent;
    observer.on_dev_tools_method_result = &onResult;
    observer.on_dev_tools_agent_detached = &onDetached;
    tick_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&tick_task.base);
    tick_task.execute = &tick;
}

fn api() *const library.Api {
    return browsers.state.api;
}

fn writer() *events.Writer {
    return browsers.state.writer;
}

fn refreshAny() void {
    any_recording.store(table.anyRecording(), .release);
}

/// 기록하는 탭인가(UI 스레드 — `network.zig` 가 `body_expected` 를 정할 때).
pub fn recording(browser: BrowserId) bool {
    return table.recording(browser);
}

// ── maru 의 명령 ──────────────────────────────────────────────────────────────────────────────────────────

/// `net_record` — 켜면 그 탭에 관찰자를 달고 `Network.enable`, 끄면 `Network.disable` 과 기다리던 본문의 `recording_stopped`.
pub fn record(v: msg.NetRecord) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse {
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = v.session, .status = if (v.on) .failed else .off } }) catch {};
        return;
    };
    if (!v.on) {
        const was = table.tabOf(v.browser) != null;
        table.stop(gpa, v.browser) catch {};
        runActions();
        if (was) sendCdp(entry, "Network.disable", "{}", v.browser, 0, false);
        unregister(entry.cef_id);
        refreshAny();
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = 0, .status = .off } }) catch {};
        return;
    }
    const ok = table.start(gpa, v.browser, v.session) catch false;
    runActions();
    if (!ok or !register(entry)) {
        table.stop(gpa, v.browser) catch {};
        runActions();
        refreshAny();
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = v.session, .status = .failed } }) catch {};
        return;
    }
    refreshAny();
    sendCdp(entry, "Network.enable", "{\"maxResourceBufferSize\":2097152,\"maxTotalBufferSize\":8388608,\"maxPostDataSize\":1}", v.browser, v.session, true);
    ensureTick();
}

/// 렌더러가 죽었다(`on_render_process_terminated` — `renderer_gone` 보다 먼저). 보낸 호출은 답이 없다(J5) — 곧 `detached`.
pub fn rendererGone(browser: BrowserId) void {
    table.rendererGone(gpa, browser) catch {};
    runActions();
}

/// 브라우저가 닫힌다(`browser_closed` 보다 먼저) — 기다리던 본문은 `detached`, 등록을 놓는다.
pub fn browserClosed(cef_id: c_int, browser: BrowserId) void {
    table.closed(gpa, browser) catch {};
    runActions();
    unregister(cef_id);
    refreshAny();
}

// ── CEF 쪽(network.zig 의 보내는 task — UI 스레드) ────────────────────────────────────────────────────────

/// 기록하는 탭의 CEF 시작 — 후보로 적었으면 참(`body_expected`).
pub fn cefBegin(browser: BrowserId, cand: table_mod.Candidate) bool {
    const ok = table.cefBegin(gpa, browser, cand) catch false;
    dbg("cef-begin b={d} req={d} url={x} m={x} sw={} t={d} ok={}", .{ browser, cand.request, cand.key.url, cand.key.method, cand.key.sw, cand.t_io_us, ok });
    runActions();
    if (ok) ensureTick();
    return ok;
}

/// CEF 응답 — 설정이 꺼졌을 때 응답 호스트가 덮이는가(`net_response` 헤더와 같은 결정).
pub fn cefCovered(browser: BrowserId, request: u64, covered: bool) void {
    table.cefCovered(browser, request, covered);
}

pub fn cefEnd(browser: BrowserId, request: u64) void {
    dbg("cef-end b={d} req={d} t={d}", .{ browser, request, machUs() });
    table.cefEnd(browser, request, machUs());
    ensureTick();
}

pub fn noteDrop(browser: BrowserId, url_hash: u64, t_us: i64) void {
    table.noteDrop(browser, url_hash, t_us);
}

pub fn noteDropOverflow(browser: BrowserId, t_us: i64) void {
    table.noteDropOverflow(browser, t_us);
}

// ── 관찰자 ────────────────────────────────────────────────────────────────────────────────────────────────

fn register(entry: *const registry_mod.Entry) bool {
    for (registrations) |r| if (r) |v| if (v.cef_id == entry.cef_id) return true;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = browser.*.get_host.?(browser);
    if (host == null) return false;
    defer object.release(host);
    for (&registrations) |*r| if (r.* == null) {
        const reg = host.*.add_dev_tools_message_observer.?(host, &observer);
        if (reg == null) return false;
        r.* = .{ .cef_id = entry.cef_id, .browser = entry.id, .reg = reg };
        return true;
    };
    return false;
}

fn unregister(cef_id: c_int) void {
    for (&registrations) |*r| if (r.*) |v| if (v.cef_id == cef_id) {
        object.release(v.reg);
        r.* = null;
    };
}

fn browserOfCef(cef_id: c_int) ?BrowserId {
    for (registrations) |r| if (r) |v| if (v.cef_id == cef_id) return v.browser;
    return null;
}

fn nextId() i32 {
    // 본문 호출과 같은 대역을 쓴다(표가 매기는 번호와 겹치지 않게 표의 차례를 함께 쓴다).
    const id = table.next_id;
    table.next_id = if (table.next_id + 1 >= table_mod.id_end) table_mod.id_base else table.next_id + 1;
    return id;
}

fn sendCdp(entry: *const registry_mod.Entry, method: []const u8, params: []const u8, browser: BrowserId, session: u32, enable: bool) void {
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = b.*.get_host.?(b);
    if (host == null) return;
    defer object.release(host);
    const id = nextId();
    var jb: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch return;
    for (&control_ids) |*slot| if (slot.id == 0 or slot.browser == browser) {
        slot.* = .{ .id = id, .browser = browser, .session = session, .enable = enable };
        break;
    };
    _ = host.*.send_dev_tools_message.?(host, json.ptr, json.len);
}

fn onEvent(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, method_s: [*c]const c.cef_string_t, params: ?*const anyopaque, params_size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const id = browserOfCef(browser.*.get_identifier.?(browser)) orelse return;
    if (!table.recording(id)) return;
    var mb: [64]u8 = undefined;
    const method = library.readString(api(), method_s, &mb);
    if (!std.mem.startsWith(u8, method, "Network.")) return; // Page.* 도 온다(권한이 Page.enable 을 건다 — J7)
    const p: []const u8 = if (params != null) @as([*]const u8, @ptrCast(params.?))[0..params_size] else "";
    const now = machUs();
    if (std.mem.eql(u8, method, "Network.dataReceived")) {
        table.cdpEvent(gpa, id, table_mod.scanData(p), now) catch {};
    } else if (table_mod.wanted(method)) {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, p, .{}) catch {
            table.cdpEvent(gpa, id, null, now) catch {};
            runActions();
            return;
        };
        defer parsed.deinit();
        const ev = table_mod.parseEvent(method, parsed.value);
        if (debug_log) if (ev) |e| switch (e) {
            .will_be_sent => |v| dbg("cdp-sent rid={s} url={x} m={x} ts={d} redirect={} now={d}", .{ v.rid, v.url_hash, v.method_hash, v.ts_us, v.redirect, now }),
            .response => |v| dbg("cdp-resp rid={s} mime={s} sw={}", .{ v.rid, v.mime, v.from_sw }),
            .finished => |v| dbg("cdp-fin rid={s} now={d}", .{ v.rid, now }),
            .failed => |v| dbg("cdp-fail rid={s}", .{v.rid}),
            .from_cache => |v| dbg("cdp-cache rid={s}", .{v.rid}),
            else => {},
        } else dbg("cdp-unparsed {s}", .{method});
        table.cdpEvent(gpa, id, ev, now) catch {};
    } else {
        table.cdpEvent(gpa, id, null, now) catch {}; // 쏟아짐만 센다
    }
    runActions();
    ensureTick();
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < table_mod.id_base or id >= table_mod.id_end) return; // 다른 사용처(devtools·권한·알림·미디어)의 결과
    for (&control_ids) |*slot| if (slot.id == id) {
        const s = slot.*;
        slot.* = .{};
        // 켬의 답 — 그 사이 끄거나 다시 켜지 않았을 때만 알린다.
        if (s.enable) {
            const t = table.tabOf(s.browser);
            if (t != null and t.?.session == s.session) {
                writer().send(.{ .net_record_state = .{ .browser = s.browser, .session = s.session, .status = if (success != 0) .on else .failed } }) catch {};
                if (success == 0) {
                    table.stop(gpa, s.browser) catch {};
                    runActions();
                    refreshAny();
                }
            }
        }
        return;
    };
    dbg("result id={d} ok={} size={d}", .{ id, success, size });
    const f = table.takeInflight(id) orelse return; // 끄거나 다시 켠 뒤의 늦은 답(세대)
    const bytes: []const u8 = if (result != null) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
    sendBody(f, success != 0, bytes);
    table.bodyDone(gpa, f, machUs()) catch {};
    runActions();
}

fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const id = browserOfCef(browser.*.get_identifier.?(browser)) orelse return;
    // DevTools 가 떨어졌다 — 보낸 호출의 답은 오지 않는다. 기록은 다시 켜야 한다(이벤트가 끊겼다) — maru 에 알린다.
    const session = if (table.tabOf(id)) |t| t.session else 0;
    table.closed(gpa, id) catch {};
    runActions();
    refreshAny();
    if (session != 0) writer().send(.{ .net_record_state = .{ .browser = id, .session = session, .status = .failed } }) catch {};
}

/// 받은 결과를 풀어 보낸다 — 잡았으면 조각들과 끝(보내는 줄에 자리가 없으면 `busy`), 아니면 끝 하나.
fn sendBody(f: table_mod.Inflight, ok: bool, json: []const u8) void {
    var flags: msg.NetBodyFlags = .{ .credentialed = f.credentialed };
    const d = table_mod.decodeResult(gpa, ok, json, f.mimeSlice(), f.charset) catch table_mod.Decoded{ .state = .busy };
    defer if (d.bytes.len > 0) gpa.free(d.bytes);
    const end: msg.NetBodyEnd = .{ .browser = f.browser, .session = f.session, .request = f.request, .state = d.state, .flags = flags, .decoded = f.decoded };
    if (d.state != .captured) return writer().send(.{ .net_body_end = end }) catch {};
    const total = events.bodyFrameBytes(d.bytes.len);
    if (!writer().reserveBody(total)) {
        var busy = end;
        busy.state = .busy;
        return writer().send(.{ .net_body_end = busy }) catch {};
    }
    // 쓰지 못한 몫은 돌려준다(관이 닫혀 중간에 그만뒀다).
    var used: usize = 0;
    defer writer().releaseBody(total -| used);
    var off: usize = 0;
    while (off < d.bytes.len) {
        const k = @min(msg.net_body_chunk_bytes, d.bytes.len - off);
        writer().sendBody(.{ .net_body_data = .{ .browser = f.browser, .session = f.session, .request = f.request, .offset = @intCast(off), .bytes = d.bytes[off..][0..k] } }) catch return;
        used += events.body_data_head_bytes + k;
        off += k;
    }
    flags.binary = d.flags.binary;
    flags.redecoded = d.flags.redecoded;
    flags.chromium_decoded = d.flags.chromium_decoded;
    var done = end;
    done.flags = flags;
    done.size = @intCast(d.bytes.len);
    writer().sendBody(.{ .net_body_end = done }) catch return;
    used = total;
}

// ── 일 하기 ───────────────────────────────────────────────────────────────────────────────────────────────

/// 표가 쌓은 일을 한다 — 일이 새 일을 쌓으면(보내지 못한 호출의 끝 → 다음 기다림) 빌 때까지 되풀이한다.
fn runActions() void {
    var list: std.ArrayList(table_mod.Action) = .empty;
    defer list.deinit(gpa);
    while (true) {
        table.swapActions(&list);
        if (list.items.len == 0) return;
        for (list.items) |a| switch (a) {
            .end => |e| {
                dbg("end req={d} state={s}", .{ e.request, @tagName(e.state) });
                writer().send(.{ .net_body_end = .{ .browser = e.browser, .session = e.session, .request = e.request, .state = e.state, .flags = e.flags, .decoded = e.decoded } }) catch {};
            },
            .fetch => |f| {
                dbg("fetch id={d} rid={s}", .{ f.id, f.rid.slice() });
                fetch(f.browser, f.id, f.rid.slice());
            },
            .pause => |p| {
                // 쏟아짐 밸브(J7) — 이벤트를 끈다(관찰자는 남긴다 — 콜백 안이다). maru 가 다시 켜야 풀린다.
                if (browsers.state.registry.byId(p.browser)) |entry| sendCdp(entry, "Network.disable", "{}", p.browser, 0, false);
                refreshAny();
                writer().send(.{ .net_record_state = .{ .browser = p.browser, .session = p.session, .status = .paused } }) catch {};
            },
        };
        list.clearRetainingCapacity();
    }
}

/// `Network.getResponseBody` 를 보낸다. 요청 번호는 CDP 가 준 글이라 JSON 에 그대로 넣을 수 있는 글자만 받는다(아니면 그 호출은 `unavailable`).
fn fetch(browser: BrowserId, id: i32, rid: []const u8) void {
    const safe = for (rid) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') break false;
    } else rid.len > 0;
    const entry = browsers.state.registry.byId(browser);
    if (!safe or entry == null) return failFetch(id);
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.?.handle));
    const host = b.*.get_host.?(b);
    if (host == null) return failFetch(id);
    defer object.release(host);
    var jb: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.getResponseBody\",\"params\":{{\"requestId\":\"{s}\"}}}}", .{ id, rid }) catch return failFetch(id);
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) failFetch(id);
}

fn failFetch(id: i32) void {
    const f = table.takeInflight(id) orelse return;
    sendBody(f, false, "");
    table.bodyDone(gpa, f, machUs()) catch {}; // 새 일은 부른 `runActions` 의 다음 바퀴가 한다
}

fn ensureTick() void {
    if (tick_posted or !table.busy()) return;
    tick_posted = api().post_delayed_task(c.TID_UI, &tick_task, tick_ms) != 0;
}

fn tick(_: [*c]c.cef_task_t) callconv(.c) void {
    tick_posted = false;
    dbg("tick", .{});
    table.tick(gpa, machUs()) catch {};
    runActions();
    ensureTick();
}
