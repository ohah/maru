//! W9c③ 판정 — maru 의 `browser.upload` 가 기대는 실제 CEF(Chromium) 의 성질을 고정한다(docs/plans/web-osr-backend.md 「W9c③ 결정」). 판정자가
//! **maru 역할**로 DevTools(`devtools_call`)만 부른다 — `DOM.enable`·`Runtime.enable`·`Page.enable` 없이(maru 처럼). CEF 를 올릴 때 여기서
//! 하나라도 바뀌면 maru 의 차례(모달 전 거절·같은 objectId 로 읽어 확인·승인 뒤 다시 찾기)를 다시 본다.
//!
//!   up-trusted        objectId 로 `DOM.setFileInputFiles` → `{}`, 페이지는 `input`·`change` 를 진짜(`isTrusted`)로 받고 이름·내용을 읽는다,
//!                     사용자 몸짓은 생기지 않는다(`navigator.userActivation.isActive` 거짓 — 넣은 파일로 팝업을 열 수 없다)
//!   up-silent-dir     `webkitdirectory` 칸에 파일을 주면 `{}` 인데 아무것도 들어가지 않는다(조용한 실패 — maru 는 모달 전에 거절한다)
//!   up-silent-single  한 파일 칸에 둘을 주면 `{}` 이고 첫 것만 들어간다(조용히 버린다 — maru 는 모달 전에 거절한다)
//!   up-silent-empty   빈 목록은 `{}` 이고 칸을 비우지 않는다(maru 는 빈 목록을 받지 않는다)
//!   up-disabled       꺼진 칸에도 넣고 진짜 이벤트를 낸다(사람은 못 한다 — maru 는 모달 전에 거절한다)
//!   up-stale-object   이동 뒤(같은 사이트)에는 옛 문서의 objectId(주 world·격리 world)로 넣지 못한다 — 「Cannot find context」(maru 가 넣기를
//!                     objectId 로 하는 까닭: backendNodeId 는 다른 사이트로 옮기면 다시 쓰였다)
//!   up-hidden         숨긴 탭에서도 곧 들어간다(깨우는 kick 이 필요 없다)
//!   up-isolated-listener (적대 리뷰 1 회차) maru 의 격리 world 가 그 칸에 단 캡처 듣는 이가 넣기의 진짜 `input`·`change` 를 받고, 그때 목록은
//!                     넣은 파일이다 — 페이지의 보통 듣는 이가 `change` 에서 칸을 비우기 전, 그 기록은 넣기의 답이 오기 **전에** 이미 있다(같은
//!                     차례 안에서 낸다). 차례는 창의 캡처 → maru(칸의 캡처) → 칸의 보통 듣는 이 — 페이지가 창의 캡처에서 먼저 비우면 maru 는
//!                     빈 목록을 본다(그때 maru 는 「받았다」 고 하지 않는다)
//!   up-no-picker      위 어느 것도 파일 고르개(`file_dialog`)를 띄우지 않았다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const visible_id: u64 = 41;
const hidden_id: u64 = 42;
const wait_ms = 15_000;
const chunk = protocol.message.devtools_chunk_bytes;

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    next_call: u32 = 0,
    result: std.ArrayList(u8) = .empty,
    created: [2]bool = .{ false, false },
    loads: [2]u32 = .{ 0, 0 },
    pickers: u32 = 0,

    fn deinit(self: *Run) void {
        self.result.deinit(self.gpa);
    }

    fn slot(id: u64) ?usize {
        return if (id == visible_id) 0 else if (id == hidden_id) 1 else null;
    }

    fn other(self: *Run, message: protocol.message.Message) void {
        switch (message) {
            .browser_created => |id| if (slot(id)) |i| {
                self.created[i] = true;
            },
            .load_finished => |v| if (slot(v.browser)) |i| {
                self.loads[i] += 1;
            },
            // 파일 고르개가 떴다 — maru 의 업로드는 고르개를 거치지 않는다(여기서 세어 0 이어야 한다). 닫아 준다.
            .file_dialog => |v| {
                self.pickers += 1;
                self.host.send(.{ .file_dialog_reply = .{ .browser = v.browser, .request = v.request, .accept = false } }) catch {};
            },
            else => {},
        }
    }

    fn untilCreated(self: *Run, i: usize) bool {
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and !self.created[i]) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.other(m);
        }
        return self.created[i];
    }

    /// 불러오기가 `n` 번이 될 때까지.
    fn untilLoads(self: *Run, i: usize, n: u32) bool {
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and self.loads[i] < n) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.other(m);
        }
        return self.loads[i] >= n;
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.other(m);
        }
    }

    /// 부르고 끝까지 기다린다 — 결과는 `result`(ok 면 CDP 의 result, cdp_error 면 error 객체). 시간 안에 안 오면 null.
    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8) !?protocol.message.DevtoolsStatus {
        self.next_call += 1;
        const id = self.next_call;
        try self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len) } });
        var off: usize = 0;
        while (off < params.len) {
            const n = @min(chunk, params.len - off);
            try self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = params[off..][0..n] } });
            off += n;
        }
        self.result.clearRetainingCapacity();
        const deadline = os.nowMs() + 10_000;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(50) catch null) orelse continue;
            switch (m) {
                .devtools_result_data => |v| if (v.call == id) {
                    try self.result.appendSlice(self.gpa, v.bytes);
                    continue;
                },
                .devtools_result => |v| if (v.call == id) return v.status,
                else => {},
            }
            self.other(m);
        }
        return null;
    }

    /// 페이지 world 의 식 하나 — `returnByValue` 의 값(글로). 실패면 빈 글.
    fn eval(self: *Run, browser: u64, buf: []u8, expr: []const u8) ![]const u8 {
        var pb: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        try w.writeAll("{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":");
        try std.json.Stringify.value(expr, .{}, &w);
        try w.writeAll("}");
        const st = try self.call(browser, "Runtime.evaluate", w.buffered());
        if (st != .ok) return "";
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch return "";
        defer parsed.deinit();
        const v = (parsed.value.object.get("result") orelse return "").object.get("value") orelse return "";
        return switch (v) {
            .string => |s| std.fmt.bufPrint(buf, "{s}", .{s[0..@min(s.len, buf.len)]}) catch "",
            .bool => |b| if (b) "true" else "false",
            .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "",
            else => "",
        };
    }

    /// 그 칸의 원격 객체(페이지 world) — `objectId` 를 `out` 에.
    fn objectOf(self: *Run, browser: u64, out: []u8, id: []const u8) ![]const u8 {
        var pb: [256]u8 = undefined;
        const params = try std.fmt.bufPrint(&pb, "{{\"expression\":\"document.getElementById('{s}')\"}}", .{id});
        if ((try self.call(browser, "Runtime.evaluate", params)) != .ok) return "";
        return self.objectIdOfResult(out, &.{ "result", "objectId" });
    }

    fn objectIdOfResult(self: *Run, out: []u8, path: []const []const u8) []const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch return "";
        defer parsed.deinit();
        var v = parsed.value;
        for (path) |k| {
            if (v != .object) return "";
            v = v.object.get(k) orelse return "";
        }
        if (v != .string) return "";
        return std.fmt.bufPrint(out, "{s}", .{v.string}) catch "";
    }

    /// 그 원격 객체에 함수를 불러 `returnByValue` 의 글 값을 `buf` 에(실패면 빈 글).
    fn callOn(self: *Run, browser: u64, buf: []u8, object: []const u8, function: []const u8) ![]const u8 {
        var pb: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        try w.writeAll("{\"returnByValue\":true,\"objectId\":");
        try std.json.Stringify.value(object, .{}, &w);
        try w.writeAll(",\"functionDeclaration\":");
        try std.json.Stringify.value(function, .{}, &w);
        try w.writeAll("}");
        if ((try self.call(browser, "Runtime.callFunctionOn", w.buffered())) != .ok) return "";
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch return "";
        defer parsed.deinit();
        const v = (parsed.value.object.get("result") orelse return "").object.get("value") orelse return "";
        return if (v == .string) std.fmt.bufPrint(buf, "{s}", .{v.string[0..@min(v.string.len, buf.len)]}) catch "" else "";
    }

    /// `DOM.setFileInputFiles{files, objectId}` — 상태와 결과 글.
    fn setFiles(self: *Run, browser: u64, object: []const u8, files: []const []const u8) !?protocol.message.DevtoolsStatus {
        var pb: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        try w.writeAll("{\"files\":[");
        for (files, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try std.json.Stringify.value(f, .{}, &w);
        }
        try w.writeAll("],\"objectId\":");
        try std.json.Stringify.value(object, .{}, &w);
        try w.writeAll("}");
        return self.call(browser, "DOM.setFileInputFiles", w.buffered());
    }
};

fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}

fn statusName(st: ?protocol.message.DevtoolsStatus) []const u8 {
    return if (st) |s| @tagName(s) else "답 없음";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, files_dir: []const u8, port: u16) !void {
    var detail: [600]u8 = undefined;
    var u: [256]u8 = undefined;
    const gpa = std.heap.c_allocator;
    var a_buf: [1024]u8 = undefined;
    var b_buf: [1024]u8 = undefined;
    const a = try std.fmt.bufPrintSentinel(&a_buf, "{s}/up-a.txt", .{files_dir}, 0);
    const b = try std.fmt.bufPrintSentinel(&b_buf, "{s}/up-b.txt", .{files_dir}, 0);
    try writeFile(a, "alpha\n");
    try writeFile(b, "bravo\n");

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var r: Run = .{ .host = &host, .gpa = gpa };
    defer r.deinit();
    try host.send(.{ .create_browser = .{ .browser = visible_id, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/upload") } });
    if (!r.untilCreated(0)) return error.BrowserNotCreated;
    if (!r.untilLoads(0, 1)) return error.PageNotLoaded;
    var vb: [512]u8 = undefined;
    var ob: [256]u8 = undefined;

    // up-trusted
    {
        const obj = try r.objectOf(visible_id, &ob, "one");
        const st = try r.setFiles(visible_id, obj, &.{a});
        const empty = st == .ok and std.mem.eql(u8, r.result.items, "{}");
        var set_text: [120]u8 = undefined;
        const set_shown = std.fmt.bufPrint(&set_text, "{s}", .{r.result.items[0..@min(r.result.items.len, 100)]}) catch "";
        r.pump(300);
        const got = try r.eval(visible_id, &vb, "new Promise(function(res){var t=Date.now();(function w(){if(window.__got||Date.now()-t>3000)return res(String(window.__got)+'|'+window.__log.join(',')+'|'+navigator.userActivation.isActive);setTimeout(w,50)})()})");
        const ok = empty and std.mem.eql(u8, got, "one:up-a.txt:6:alpha|input:true,change:true|false");
        report(ok, "up-trusted", std.fmt.bufPrint(&detail, "상태 {s} 「{s}」 · 페이지 「{s}」", .{ statusName(st), set_shown, got }) catch "");
    }
    // up-silent-dir
    {
        const obj = try r.objectOf(visible_id, &ob, "dir");
        const st = try r.setFiles(visible_id, obj, &.{a});
        const empty = st == .ok and std.mem.eql(u8, r.result.items, "{}");
        r.pump(200);
        const n = try r.eval(visible_id, &vb, "document.getElementById('dir').files.length");
        report(empty and std.mem.eql(u8, n, "0"), "up-silent-dir", std.fmt.bufPrint(&detail, "상태 {s}(결과 {{}} {}) · 들어간 수 {s}", .{ statusName(st), empty, n }) catch "");
    }
    // up-silent-single
    {
        const obj = try r.objectOf(visible_id, &ob, "two");
        const st = try r.setFiles(visible_id, obj, &.{ a, b });
        const empty = st == .ok and std.mem.eql(u8, r.result.items, "{}");
        r.pump(200);
        const got = try r.eval(visible_id, &vb, "(function(f){return f.length+':'+(f.length?f[0].name:'')})(document.getElementById('two').files)");
        report(empty and std.mem.eql(u8, got, "1:up-a.txt"), "up-silent-single", std.fmt.bufPrint(&detail, "상태 {s} · 칸 「{s}」", .{ statusName(st), got }) catch "");
    }
    // up-silent-empty
    {
        const obj = try r.objectOf(visible_id, &ob, "one");
        const st = try r.setFiles(visible_id, obj, &.{});
        const empty = st == .ok and std.mem.eql(u8, r.result.items, "{}");
        r.pump(200);
        const n = try r.eval(visible_id, &vb, "document.getElementById('one').files.length");
        report(empty and std.mem.eql(u8, n, "1"), "up-silent-empty", std.fmt.bufPrint(&detail, "상태 {s} · 남은 수 {s}", .{ statusName(st), n }) catch "");
    }
    // up-disabled
    {
        const obj = try r.objectOf(visible_id, &ob, "dis");
        const st = try r.setFiles(visible_id, obj, &.{a});
        r.pump(300);
        const got = try r.eval(visible_id, &vb, "document.getElementById('dis').files.length+'|'+window.__dis");
        report(st == .ok and std.mem.eql(u8, got, "1|change:true"), "up-disabled", std.fmt.bufPrint(&detail, "상태 {s} · 「{s}」", .{ statusName(st), got }) catch "");
    }
    // up-isolated-listener — maru 처럼 격리 world 에서 그 칸의 objectId 를 잡아 캡처 듣는 이를 달고, 그 objectId 로 넣은 **바로 뒤**(펌프 없이) 기록을
    // 읽는다. 페이지의 보통 `change` 듣는 이는 칸을 비운다(받은 뒤 지우는 위젯).
    {
        var iso_buf: [256]u8 = undefined;
        var iso_obj: []const u8 = "";
        if ((try r.call(visible_id, "Page.getFrameTree", "")) == .ok) {
            var fb: [128]u8 = undefined;
            const frame = r.objectIdOfResult(&fb, &.{ "frameTree", "frame", "id" });
            var pb: [256]u8 = undefined;
            if ((try r.call(visible_id, "Page.createIsolatedWorld", try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"judge-up-listen\"}}", .{frame}))) == .ok) {
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, r.result.items, .{}) catch null;
                const ctx: i64 = if (parsed) |p| (if (p.value.object.get("executionContextId")) |v| v.integer else 0) else 0;
                if (parsed) |p| p.deinit();
                const ep = try std.fmt.bufPrint(&pb, "{{\"expression\":\"document.getElementById('clr')\",\"contextId\":{d}}}", .{ctx});
                if ((try r.call(visible_id, "Runtime.evaluate", ep)) == .ok) iso_obj = r.objectIdOfResult(&iso_buf, &.{ "result", "objectId" });
            }
        }
        var ib: [64]u8 = undefined;
        const installed = try r.callOn(visible_id, &ib, iso_obj, "function(){var t=this,de=document.documentElement;globalThis.__rec=[];" ++
            "var h=function(e){var f=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files').get.call(t);" ++
            "globalThis.__rec.push(e.type+':'+e.isTrusted+':'+(f?f.length:-1)+':'+(f&&f.length?f[0].name:''));de.dataset.order+='M:'+e.type+',';};" ++
            "t.addEventListener('input',h,true);t.addEventListener('change',h,true);return 'ok'}");
        const st = try r.setFiles(visible_id, iso_obj, &.{a});
        var rb: [256]u8 = undefined;
        const rec = try r.callOn(visible_id, &rb, iso_obj, "function(){return globalThis.__rec.join('|')}");
        const order = try r.eval(visible_id, &vb, "document.documentElement.dataset.order+'|'+document.getElementById('clr').files.length");
        const m_change = std.mem.indexOf(u8, order, "M:change") orelse std.math.maxInt(usize);
        const p_change = std.mem.indexOf(u8, order, "P-change-bubble:1") orelse 0;
        const ok = std.mem.eql(u8, installed, "ok") and st == .ok and std.mem.eql(u8, rec, "input:true:1:up-a.txt|change:true:1:up-a.txt") and
            m_change < p_change and std.mem.endsWith(u8, order, "|0");
        report(ok, "up-isolated-listener", std.fmt.bufPrint(&detail, "설치 {s} · 상태 {s} · 넣기 바로 뒤 maru 기록 「{s}」 · 차례 「{s}」", .{ installed, statusName(st), rec, order }) catch "");
    }
    // up-stale-object — 주 world 와 격리 world 의 objectId 를 잡고 같은 사이트의 다른 문서로 옮긴다.
    {
        var main_buf: [256]u8 = undefined;
        const main_obj = try r.objectOf(visible_id, &main_buf, "one");
        var iso_buf: [256]u8 = undefined;
        var iso_obj: []const u8 = "";
        if ((try r.call(visible_id, "Page.getFrameTree", "")) == .ok) {
            var fb: [128]u8 = undefined;
            const frame = r.objectIdOfResult(&fb, &.{ "frameTree", "frame", "id" });
            var pb: [256]u8 = undefined;
            if ((try r.call(visible_id, "Page.createIsolatedWorld", try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"judge-up\"}}", .{frame}))) == .ok) {
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, r.result.items, .{}) catch null;
                const ctx: i64 = if (parsed) |p| (if (p.value.object.get("executionContextId")) |v| v.integer else 0) else 0;
                if (parsed) |p| p.deinit();
                const ep = try std.fmt.bufPrint(&pb, "{{\"expression\":\"document.getElementById('one')\",\"contextId\":{d}}}", .{ctx});
                if ((try r.call(visible_id, "Runtime.evaluate", ep)) == .ok) iso_obj = r.objectIdOfResult(&iso_buf, &.{ "result", "objectId" });
            }
        }
        try host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload?second") } });
        const moved = r.untilLoads(0, 2);
        const st_main = try r.setFiles(visible_id, main_obj, &.{b});
        const main_err = st_main == .cdp_error and std.mem.indexOf(u8, r.result.items, "Cannot find context") != null;
        var main_text: [120]u8 = undefined;
        const mt = std.fmt.bufPrint(&main_text, "{s}", .{r.result.items[0..@min(r.result.items.len, 100)]}) catch "";
        const st_iso = try r.setFiles(visible_id, iso_obj, &.{b});
        const iso_err = st_iso == .cdp_error and std.mem.indexOf(u8, r.result.items, "Cannot find context") != null;
        var iso_text: [120]u8 = undefined;
        const it = std.fmt.bufPrint(&iso_text, "{s}", .{r.result.items[0..@min(r.result.items.len, 100)]}) catch "";
        r.pump(200);
        const n = try r.eval(visible_id, &vb, "document.getElementById('one').files.length");
        report(moved and iso_obj.len > 0 and main_err and iso_err and std.mem.eql(u8, n, "0"), "up-stale-object", std.fmt.bufPrint(&detail, "옮김 {} · 주 world {s} 「{s}」 · 격리 world({d}) {s} 「{s}」 · 새 문서의 칸 {s}", .{ moved, statusName(st_main), mt, iso_obj.len, statusName(st_iso), it, n }) catch "");
    }
    // up-hidden — 숨긴 채 만든 탭.
    {
        try host.send(.{ .create_browser = .{ .browser = hidden_id, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = true, .url = browsers_check.url(&u, port, "/upload") } });
        const ready = r.untilCreated(1) and r.untilLoads(1, 1);
        const obj = try r.objectOf(hidden_id, &ob, "one");
        const t0 = os.nowMs();
        const st = try r.setFiles(hidden_id, obj, &.{a});
        const took = os.nowMs() - t0;
        const n = try r.eval(hidden_id, &vb, "document.visibilityState+':'+document.getElementById('one').files.length");
        report(ready and st == .ok and std.mem.eql(u8, n, "hidden:1") and took < 2_000, "up-hidden", std.fmt.bufPrint(&detail, "준비 {} · 상태 {s} · {d} ms · 「{s}」", .{ ready, statusName(st), took, n }) catch "");
    }
    report(r.pickers == 0, "up-no-picker", std.fmt.bufPrint(&detail, "파일 고르개 {d} 번", .{r.pickers}) catch "");
}
