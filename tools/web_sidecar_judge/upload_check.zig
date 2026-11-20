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
//!   up-folder-path-silent (2026-11-20 폴더) `webkitdirectory` 칸에 폴더 경로를 주면 `{}` 이고 아무것도 안 들어간다(CEF 는 폴더를 펼치지 않는다),
//!                     보통 칸에 주면 그 폴더가 파일 하나로 들어간다 — maru 는 앱이 펼친 파일 목록을 넣는다
//!   up-folder-toggle  격리 world 에서 `webkitdirectory` 를 떼고 `multiple` 을 붙여 넣으면 칸이 파일 둘을 진짜 이벤트로 받고(`webkitRelativePath`
//!                     빈 글), maru 의 캡처 듣는 이가 첫 `input` 에서 되돌리면 칸의 보통 처리기는 `webkitdirectory` 참을 보고 넣은 뒤 속성은 처음대로다
//!   up-frame-describe (2026-11-20 iframe) iframe 요소의 `DOM.describeNode{objectId}` 는 같은 출처 iframe 이면 `frameId`(프레임 트리의 자식)와
//!                     `contentDocument` 를, 다른 사이트 iframe(OOPIF)이면 `frameId` 만 싣는다 — maru 의 걷기가 같은 프로세스인지 이것으로 가른다
//!   up-frame-oopif    다른 사이트 iframe 의 칸: wire 30 `frame` 호출로 sidecar 가 그 frame 의 세션을 붙여 격리 world·찾기·넣기가 되고 칸은 진짜
//!                     `change` 를 받는다, 그 세션의 프레임 트리 뿌리는 그 frame — 세션이 없을 때 객체를 실은 호출은 보내지 않고(send_failed),
//!                     허용 목록 밖의 메서드는 거절(invalid_request)
//!   up-frame-oopif-recording 본문 기록을 켠 탭(net_body 의 관찰자가 root 의 붙음 사건을 본다)에서도 그 세션이 살아 넣기가 된다
//!   up-maru-js        앱의 격리 world 함수(`web_cdp_upload_js.zig`) 그대로 — 칸 종류 판정, 폴더 넣기의 속성 바꾸기·첫 input 에서 되돌리기·읽기 'ok',
//!                     넣지 않고 끝나면 떼기가 되돌린다
//!   up-frame-other-tab 다른 탭의 다른 사이트 iframe 의 frame id 로는 이 탭에서 붙지 않는다(그 탭에서는 붙는다)
//!   up-frame-session-gone 그 iframe 이 바쁜 사이 지우면 보낸 호출은 CDP 오류로(갔다 — 「안 갔다」 가 아니다), 지운 뒤의 호출은 send_failed
//!   up-frame-same     같은 출처 iframe 의 격리 world 에서 잡은 칸에 페이지 세션의 `DOM.setFileInputFiles` 가 넣는다(진짜 `change`)
//!   up-no-picker      위 어느 것도 파일 고르개(`file_dialog`)를 띄우지 않았다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
/// 앱이 보내는 격리 world 함수 그대로(`src/platform/macos/web_cdp_upload_js.zig`) — 폴더 칸의 속성 바꾸기·되돌리기와 칸 종류 판정을 실제 CEF 에서 잰다.
const upload_js = @import("web_cdp_upload_js");

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
        return self.callIn(browser, "", method, params);
    }

    /// wire 30: 그 frame(다른 사이트 iframe)의 세션으로 — sidecar 가 붙인다.
    fn callIn(self: *Run, browser: u64, frame: []const u8, method: []const u8, params: []const u8) !?protocol.message.DevtoolsStatus {
        self.next_call += 1;
        const id = self.next_call;
        try self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len), .frame = frame } });
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

    /// 그 원격 객체에 함수를 인자와 함께(`arguments` JSON 배열 글) — `returnByValue` 의 글 값을 `buf` 에(실패면 빈 글).
    fn callOnArgs(self: *Run, browser: u64, buf: []u8, object: []const u8, function: []const u8, args: []const u8) ![]const u8 {
        var pb: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        try w.writeAll("{\"returnByValue\":true,\"objectId\":");
        try std.json.Stringify.value(object, .{}, &w);
        try w.writeAll(",\"functionDeclaration\":");
        try std.json.Stringify.value(function, .{}, &w);
        try w.print(",\"arguments\":{s}}}", .{args});
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

/// 그 frame 의 격리 world 에서 식 하나의 원격 객체(`objectId` 를 `out` 에). 실패면 빈 글.
fn isolatedObject(r: *Run, browser: u64, out: []u8, frame: []const u8, world: []const u8, expr: []const u8) ![]const u8 {
    var pb: [512]u8 = undefined;
    if ((try r.call(browser, "Page.createIsolatedWorld", try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"{s}\"}}", .{ frame, world }))) != .ok) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return "";
    const ctx: i64 = if (parsed.value.object.get("executionContextId")) |v| v.integer else 0;
    parsed.deinit();
    var w: std.Io.Writer = .fixed(&pb);
    try w.writeAll("{\"expression\":");
    try std.json.Stringify.value(expr, .{}, &w);
    try w.print(",\"contextId\":{d}}}", .{ctx});
    if ((try r.call(browser, "Runtime.evaluate", w.buffered())) != .ok) return "";
    return r.objectIdOfResult(out, &.{ "result", "objectId" });
}

/// `Page.getFrameTree` 의 첫 자식 frame id(같은 프로세스의 하위 frame — 다른 사이트 iframe 은 싣지 않는다).
fn childFrame(r: *Run, browser: u64, out: []u8) ![]const u8 {
    if ((try r.call(browser, "Page.getFrameTree", "")) != .ok) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return "";
    defer parsed.deinit();
    const tree = parsed.value.object.get("frameTree") orelse return "";
    const kids = tree.object.get("childFrames") orelse return "";
    if (kids != .array or kids.array.items.len == 0) return "";
    const id = kids.array.items[0].object.get("frame").?.object.get("id") orelse return "";
    return std.fmt.bufPrint(out, "{s}", .{id.string}) catch "";
}

fn mainFrame(r: *Run, browser: u64, out: []u8) ![]const u8 {
    if ((try r.call(browser, "Page.getFrameTree", "")) != .ok) return "";
    return r.objectIdOfResult(out, &.{ "frameTree", "frame", "id" });
}

/// 사용자 결정 2026-11-20 「iframe·폴더 둘 다」 — maru 의 폴더 넣기·iframe 걷기가 기대는 성질.
fn folderAndFrameChecks(r: *Run, report: Report, files_dir: []const u8, a: []const u8, b: []const u8, port: u16) !void {
    var detail: [1200]u8 = undefined;
    var u: [256]u8 = undefined;
    var vb: [1200]u8 = undefined;
    var ob: [256]u8 = undefined;
    var db: [1024]u8 = undefined;
    const d = try std.fmt.bufPrintSentinel(&db, "{s}/updir", .{files_dir}, 0);
    _ = std.c.mkdir(d.ptr, 0o700);
    var pb2: [1024]u8 = undefined;
    try writeFile(try std.fmt.bufPrintSentinel(&pb2, "{s}/a1.txt", .{d}, 0), "A1\n");
    // up-folder-path-silent — `webkitdirectory` 칸에 폴더 경로를 주면 `{}` 이고 아무것도 안 들어간다(CEF 는 폴더를 펼치지 않는다), 보통 칸에
    // 주면 그 폴더 자체가 파일 하나로 들어간다 — maru 는 폴더를 앱이 펼쳐 파일 목록으로 넣는다.
    try r.host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload?folder") } });
    var loads: u32 = r.loads[0] + 1;
    _ = r.untilLoads(0, loads);
    {
        const obj = try r.objectOf(visible_id, &ob, "dir");
        const st = try r.setFiles(visible_id, obj, &.{d});
        const empty = st == .ok and std.mem.eql(u8, r.result.items, "{}");
        r.pump(800);
        const n_dir = try r.eval(visible_id, &vb, "String(document.getElementById('dir').files.length)");
        var nd: [16]u8 = undefined;
        const n_dir_s = std.fmt.bufPrint(&nd, "{s}", .{n_dir}) catch "";
        const obj2 = try r.objectOf(visible_id, &ob, "one");
        _ = try r.setFiles(visible_id, obj2, &.{d});
        r.pump(300);
        const one = try r.eval(visible_id, &vb, "(function(f){return f.length+':'+(f.length?f[0].name:'')})(document.getElementById('one').files)");
        report(empty and std.mem.eql(u8, n_dir_s, "0") and std.mem.eql(u8, one, "1:updir"), "up-folder-path-silent", std.fmt.bufPrint(&detail, "폴더 칸에 폴더 경로 → {s}·{s} 개 · 보통 칸에 폴더 경로 → 「{s}」", .{ statusName(st), n_dir_s, one }) catch "");
    }
    // up-folder-toggle — maru 의 승인 뒤 확인처럼 격리 world 에서 `webkitdirectory` 를 떼고 `multiple` 을 붙여 넣고, maru 의 캡처 듣는 이가 첫 진짜
    // `input` 에서 되돌린다: 칸은 파일 둘을 진짜 이벤트로 받고(`webkitRelativePath` 빈 글 — 사람의 고르개와 같다), 칸의 보통 처리기는
    // `webkitdirectory` 참을 보고, 넣은 뒤 속성은 처음대로다.
    try r.host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload?toggle") } });
    loads = r.loads[0] + 1;
    _ = r.untilLoads(0, loads);
    {
        _ = try r.eval(visible_id, &vb, "(function(){var d=document.getElementById('dir');window.__dl=[];d.addEventListener('input',function(e){__dl.push('input:'+e.isTrusted+':dir='+d.webkitdirectory+':mul='+d.multiple)});d.addEventListener('change',function(e){__dl.push('change:'+e.isTrusted+':'+d.files.length+':dir='+d.webkitdirectory)});return 'ok'})()");
        var fb: [128]u8 = undefined;
        const main = try mainFrame(r, visible_id, &fb);
        var iso: [256]u8 = undefined;
        const obj = try isolatedObject(r, visible_id, &iso, main, "judge-toggle", "document.getElementById('dir')");
        var tb: [64]u8 = undefined;
        const armed = try r.callOn(visible_id, &tb, obj, "function(){var t=this,HA=Element.prototype.hasAttribute,SA=Element.prototype.setAttribute,RA=Element.prototype.removeAttribute;var mul=HA.call(t,'multiple');" ++
            "var back=function(){if(globalThis.__done)return;globalThis.__done=true;if(!HA.call(t,'webkitdirectory'))SA.call(t,'webkitdirectory','');if(!mul&&HA.call(t,'multiple'))RA.call(t,'multiple')};" ++
            "var h=function(e){if(e.isTrusted===true&&e.target===t)back()};EventTarget.prototype.addEventListener.call(t,'input',h,true);RA.call(t,'webkitdirectory');if(!mul)SA.call(t,'multiple','');return 'ok'}");
        const st = try r.setFiles(visible_id, obj, &.{ a, b });
        r.pump(500);
        const got = try r.eval(visible_id, &vb, "(function(d){var f=d.files,l=[];for(var i=0;i<f.length;i++)l.push(f[i].name+':['+f[i].webkitRelativePath+']');return f.length+'|'+l.join(',')+'|'+__dl.join(',')+'|dir='+d.webkitdirectory+'|mul='+d.multiple})(document.getElementById('dir'))");
        const want = "2|up-a.txt:[],up-b.txt:[]|input:true:dir=true:mul=false,change:true:2:dir=true|dir=true|mul=false";
        report(std.mem.eql(u8, armed, "ok") and st == .ok and std.mem.eql(u8, got, want), "up-folder-toggle", std.fmt.bufPrint(&detail, "준비 {s} · 넣기 {s} · 「{s}」", .{ armed, statusName(st), got }) catch "");
    }
    // up-maru-js — 앱의 격리 world 함수 그대로: 칸 종류 판정(파일 칸에 폴더 → 'not directory', 폴더 칸에 파일 → 'directory'), 폴더 넣기의 arm(속성
    // 바꾸기) → 넣기 → 읽기('ok' — 페이지의 보통 처리기는 `webkitdirectory` 참을 보고 속성이 처음대로), arm 뒤 넣지 않고 끝나면 떼기가 되돌린다.
    try r.host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload?js") } });
    loads = r.loads[0] + 1;
    _ = r.untilLoads(0, loads);
    {
        _ = try r.eval(visible_id, &vb, "(function(){var d=document.getElementById('dir');window.__jl=[];d.addEventListener('input',function(e){__jl.push('input:'+e.isTrusted+':dir='+d.webkitdirectory+':mul='+d.multiple)});return 'ok'})()");
        var mfb: [128]u8 = undefined;
        const mf = try mainFrame(r, visible_id, &mfb);
        var ob1: [256]u8 = undefined;
        const one = try isolatedObject(r, visible_id, &ob1, mf, "judge-js1", "document.getElementById('one')");
        var ob2: [256]u8 = undefined;
        const dir = try isolatedObject(r, visible_id, &ob2, mf, "judge-js2", "document.getElementById('dir')");
        var b1: [64]u8 = undefined;
        const v_notdir = try r.callOnArgs(visible_id, &b1, one, upload_js.check_js, "[{\"value\":0},{\"value\":false},{\"value\":\"\"},{\"value\":true}]");
        var b2: [64]u8 = undefined;
        const v_dir = try r.callOnArgs(visible_id, &b2, dir, upload_js.check_js, "[{\"value\":1}]");
        var b3: [64]u8 = undefined;
        const v_arm = try r.callOnArgs(visible_id, &b3, dir, upload_js.check_js, "[{\"value\":2},{\"value\":true},{\"value\":\"maru-w9c-upload-77\"},{\"value\":true}]");
        const st = try r.setFiles(visible_id, dir, &.{ a, b });
        var b4: [64]u8 = undefined;
        const v_verify = try r.callOnArgs(visible_id, &b4, dir, upload_js.verify_js, "[{\"value\":[\"up-a.txt\",\"up-b.txt\"]},{\"value\":[6,6]},{\"value\":\"maru-w9c-upload-77\"}]");
        var pg: [256]u8 = undefined;
        const page = std.fmt.bufPrint(&pg, "{s}", .{try r.eval(visible_id, &vb, "(function(d){return __jl.join(',')+'|dir='+d.webkitdirectory+'|mul='+d.multiple+'|'+d.files.length})(document.getElementById('dir'))")}) catch "";
        // arm 만 하고(바꾼 채) 넣지 않고 끝나면 떼기가 되돌린다.
        var b5: [64]u8 = undefined;
        const v_arm2 = try r.callOnArgs(visible_id, &b5, dir, upload_js.check_js, "[{\"value\":1},{\"value\":true},{\"value\":\"maru-w9c-upload-78\"},{\"value\":true}]");
        var mid: [64]u8 = undefined;
        const armed_state = std.fmt.bufPrint(&mid, "{s}", .{try r.eval(visible_id, &vb, "(function(d){return 'dir='+d.webkitdirectory+'|mul='+d.multiple})(document.getElementById('dir'))")}) catch "";
        var b6: [64]u8 = undefined;
        _ = try r.callOnArgs(visible_id, &b6, dir, upload_js.disarm_js, "[{\"value\":\"maru-w9c-upload-78\"}]");
        const after = try r.eval(visible_id, &vb, "(function(d){return 'dir='+d.webkitdirectory+'|mul='+d.multiple})(document.getElementById('dir'))");
        const ok = std.mem.eql(u8, v_notdir, "not directory") and std.mem.eql(u8, v_dir, "directory") and std.mem.eql(u8, v_arm, "ok") and st == .ok and
            std.mem.eql(u8, v_verify, "ok") and std.mem.eql(u8, page, "input:true:dir=true:mul=false|dir=true|mul=false|2") and std.mem.eql(u8, v_arm2, "ok") and
            std.mem.eql(u8, armed_state, "dir=false|mul=true") and std.mem.eql(u8, after, "dir=true|mul=false");
        report(ok, "up-maru-js", std.fmt.bufPrint(&detail, "파일 칸·폴더 「{s}」 · 폴더 칸·파일 「{s}」 · arm 「{s}」 · 넣기 {s} · 읽기 「{s}」 · 페이지 「{s}」 · arm 만 「{s}」→「{s}」 · 떼기 뒤 「{s}」", .{ v_notdir, v_dir, v_arm, statusName(st), v_verify, page, v_arm2, armed_state, after }) catch "");
    }
    // 프레임: 같은 출처 iframe(`same`)과 다른 사이트 iframe(`cross` — localhost↔127.0.0.1).
    try r.host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload-frames") } });
    loads = r.loads[0] + 1;
    _ = r.untilLoads(0, loads);
    r.pump(1500);
    var fb: [128]u8 = undefined;
    const main = try mainFrame(r, visible_id, &fb);
    // up-frame-describe — maru 의 걷기는 iframe 요소의 `DOM.describeNode{objectId}` 로 그 frame id 와 같은 프로세스인지(`contentDocument`)를 본다.
    var same_frame_buf: [128]u8 = undefined;
    var same_frame: []const u8 = "";
    {
        var o1: [256]u8 = undefined;
        const same_el = try isolatedObject(r, visible_id, &o1, main, "judge-walk", "document.getElementById('same')");
        var pb: [512]u8 = undefined;
        _ = try r.call(visible_id, "DOM.describeNode", try std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{same_el}));
        const same_desc_has_doc = std.mem.indexOf(u8, r.result.items, "\"contentDocument\"") != null;
        same_frame = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk "";
            defer parsed.deinit();
            const node = parsed.value.object.get("node") orelse break :blk "";
            const f = node.object.get("frameId") orelse break :blk "";
            break :blk std.fmt.bufPrint(&same_frame_buf, "{s}", .{f.string}) catch "";
        };
        var o2: [256]u8 = undefined;
        const cross_el = try isolatedObject(r, visible_id, &o2, main, "judge-walk2", "document.getElementById('cross')");
        _ = try r.call(visible_id, "DOM.describeNode", try std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{cross_el}));
        const cross_has_frame = std.mem.indexOf(u8, r.result.items, "\"frameId\"") != null;
        const cross_has_doc = std.mem.indexOf(u8, r.result.items, "\"contentDocument\"") != null;
        var tf: [128]u8 = undefined;
        const tree_child = try childFrame(r, visible_id, &tf);
        report(same_desc_has_doc and same_frame.len > 0 and std.mem.eql(u8, same_frame, tree_child) and cross_has_frame and !cross_has_doc, "up-frame-describe", std.fmt.bufPrint(&detail, "같은 출처: 문서 {} · frame {s}(트리의 자식 {s}) · 다른 사이트: frame {} · 문서 {}", .{ same_desc_has_doc, same_frame, tree_child, cross_has_frame, cross_has_doc }) catch "");
    }
    // up-frame-same — 그 frame 의 격리 world 에서 잡은 칸에 페이지 세션의 `DOM.setFileInputFiles` 가 넣는다: 칸은 진짜 `change` 로 파일 둘을 받는다.
    {
        var o3: [256]u8 = undefined;
        const fi = try isolatedObject(r, visible_id, &o3, same_frame, "judge-in", "document.getElementById('fi')");
        const st = try r.setFiles(visible_id, fi, &.{ a, b });
        r.pump(800);
        const msgs = try r.eval(visible_id, &vb, "window.__msgs.join(' ## ')");
        report(fi.len > 0 and st == .ok and std.mem.indexOf(u8, msgs, "fi:true:up-a.txt:6:,up-b.txt:6:") != null, "up-frame-same", std.fmt.bufPrint(&detail, "칸 {d} · 넣기 {s} · 메시지 「{s}」", .{ fi.len, statusName(st), msgs }) catch "");
    }
    // up-frame-oopif — 다른 사이트 iframe(OOPIF)의 칸: 그 frame 의 세션(wire 30 `frame`)으로 격리 world·찾기·넣기 — sidecar 가 getTargets → attach 로 붙인다.
    // 칸은 진짜 `change` 로 파일 둘을 받는다. 그 세션의 프레임 트리는 그 frame 이 뿌리다(maru 의 tree 단계가 그 frame 의 loaderId·출처를 읽는다).
    var cross_frame_buf: [128]u8 = undefined;
    var cross_frame: []const u8 = "";
    {
        var o2: [256]u8 = undefined;
        const cross_el = try isolatedObject(r, visible_id, &o2, main, "judge-walk3", "document.getElementById('cross')");
        var pb: [512]u8 = undefined;
        _ = try r.call(visible_id, "DOM.describeNode", try std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{cross_el}));
        cross_frame = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk "";
            defer parsed.deinit();
            const node = parsed.value.object.get("node") orelse break :blk "";
            const f = node.object.get("frameId") orelse break :blk "";
            break :blk std.fmt.bufPrint(&cross_frame_buf, "{s}", .{f.string}) catch "";
        };
        // 원격 객체를 싣는 호출은 새로 붙지 않는다(새 세션은 그 객체를 모른다 — 공격 A1-3): 세션이 없을 때 넣기는 보내지 않는다.
        const st_cold = try r.callIn(visible_id, cross_frame, "DOM.setFileInputFiles", "{\"files\":[],\"objectId\":\"x\"}");
        // 허용 목록 밖의 메서드는 frame 세션으로 보낼 수 없다.
        const st_forbid = try r.callIn(visible_id, cross_frame, "Network.getCookies", "{}");
        const st_w = try r.callIn(visible_id, cross_frame, "Page.createIsolatedWorld", try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"judge-oopif\"}}", .{cross_frame}));
        const ctx: i64 = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk 0;
            defer parsed.deinit();
            break :blk if (parsed.value.object.get("executionContextId")) |v| v.integer else 0;
        };
        _ = try r.callIn(visible_id, cross_frame, "Runtime.evaluate", try std.fmt.bufPrint(&pb, "{{\"expression\":\"document.getElementById('fi')\",\"contextId\":{d}}}", .{ctx}));
        var fo: [256]u8 = undefined;
        const fi = r.objectIdOfResult(&fo, &.{ "result", "objectId" });
        var w: std.Io.Writer = .fixed(&pb);
        try w.print("{{\"files\":[\"{s}\",\"{s}\"],\"objectId\":\"{s}\"}}", .{ a, b, fi });
        const st = try r.callIn(visible_id, cross_frame, "DOM.setFileInputFiles", w.buffered());
        r.pump(800);
        const msgs = try r.eval(visible_id, &vb, "window.__msgs.join(' ## ')");
        var mb: [600]u8 = undefined;
        const msgs_s = std.fmt.bufPrint(&mb, "{s}", .{msgs}) catch "";
        _ = try r.callIn(visible_id, cross_frame, "Page.getFrameTree", "");
        const root_is_frame = std.mem.indexOf(u8, r.result.items, cross_frame) != null and std.mem.indexOf(u8, r.result.items, "\"securityOrigin\":\"http://localhost:") != null;
        const ok = cross_frame.len > 0 and st_cold == .send_failed and st_forbid == .invalid_request and st_w == .ok and fi.len > 0 and st == .ok and
            std.mem.indexOf(u8, msgs_s, "ev|localhost:") != null and std.mem.indexOf(u8, msgs_s, "fi:true:up-a.txt:6:,up-b.txt:6:") != null and root_is_frame;
        report(ok, "up-frame-oopif", std.fmt.bufPrint(&detail, "frame {s} · 세션 없을 때 넣기 {s} · 막힌 메서드 {s} · world {s} · 칸 {d} · 넣기 {s} · 트리 뿌리 {} · 메시지 「{s}」", .{ cross_frame, statusName(st_cold), statusName(st_forbid), statusName(st_w), fi.len, statusName(st), root_is_frame, msgs_s }) catch "");
    }
    // up-frame-oopif-recording — 본문 기록을 켠 탭(net_body 의 관찰자가 root 의 `Target.attachedToTarget` 을 본다 — 공격 A1-1: 서비스 워커가 아닌 붙음을
    // 떼던 갈래)에서도 다른 사이트 iframe 의 세션이 살아 넣기가 된다.
    {
        try r.host.send(.{ .net_watch = .{ .browser = visible_id, .on = true, .full = true, .any_host = true } });
        try r.host.send(.{ .net_record = .{ .browser = visible_id, .on = true, .session = 9 } });
        try r.host.send(.{ .navigate = .{ .browser = visible_id, .url = browsers_check.url(&u, port, "/upload-frames?rec") } });
        loads = r.loads[0] + 1;
        _ = r.untilLoads(0, loads);
        r.pump(1500);
        var fb2: [128]u8 = undefined;
        const main2 = try mainFrame(r, visible_id, &fb2);
        var o2: [256]u8 = undefined;
        const cross_el = try isolatedObject(r, visible_id, &o2, main2, "judge-rec", "document.getElementById('cross')");
        var pb: [512]u8 = undefined;
        _ = try r.call(visible_id, "DOM.describeNode", try std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{cross_el}));
        cross_frame = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk "";
            defer parsed.deinit();
            const node = parsed.value.object.get("node") orelse break :blk "";
            const f = node.object.get("frameId") orelse break :blk "";
            break :blk std.fmt.bufPrint(&cross_frame_buf, "{s}", .{f.string}) catch "";
        };
        const st_w = try r.callIn(visible_id, cross_frame, "Page.createIsolatedWorld", try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"judge-oopif2\"}}", .{cross_frame}));
        const ctx: i64 = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk 0;
            defer parsed.deinit();
            break :blk if (parsed.value.object.get("executionContextId")) |v| v.integer else 0;
        };
        r.pump(500); // net_body 가 붙음 사건을 보고 떼려 했다면 그 사이에
        _ = try r.callIn(visible_id, cross_frame, "Runtime.evaluate", try std.fmt.bufPrint(&pb, "{{\"expression\":\"document.getElementById('fi')\",\"contextId\":{d}}}", .{ctx}));
        var fo: [256]u8 = undefined;
        const fi = r.objectIdOfResult(&fo, &.{ "result", "objectId" });
        var w: std.Io.Writer = .fixed(&pb);
        try w.print("{{\"files\":[\"{s}\"],\"objectId\":\"{s}\"}}", .{ a, fi });
        const st = try r.callIn(visible_id, cross_frame, "DOM.setFileInputFiles", w.buffered());
        r.pump(800);
        const msgs = try r.eval(visible_id, &vb, "window.__msgs.join(' ## ')");
        const ok = st_w == .ok and fi.len > 0 and st == .ok and std.mem.indexOf(u8, msgs, "ev|localhost:") != null and std.mem.indexOf(u8, msgs, "fi:true:up-a.txt:6:") != null;
        report(ok, "up-frame-oopif-recording", std.fmt.bufPrint(&detail, "world {s} · 칸 {d} · 넣기 {s} · 메시지 「{s}」", .{ statusName(st_w), fi.len, statusName(st), msgs }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = visible_id, .on = false } });
        try r.host.send(.{ .net_watch = .{ .browser = visible_id, .on = false } });
        r.pump(300);
    }
    // up-frame-other-tab — 다른 탭(숨긴 탭)의 다른 사이트 iframe 의 frame id 로는 이 탭에서 붙지 않는다(`getTargets` 는 브라우저 전체의 목록이다 — 부모
    // 사슬이 이 탭의 page 타깃에 닿아야 붙는다, 적대 검증 3·4 회차). 그 탭에서는 붙는다(대조).
    {
        try r.host.send(.{ .navigate = .{ .browser = hidden_id, .url = browsers_check.url(&u, port, "/upload-frames?other") } });
        const hl = r.loads[1] + 1;
        _ = r.untilLoads(1, hl);
        r.pump(1500);
        var hfb: [128]u8 = undefined;
        const hmain = try mainFrame(r, hidden_id, &hfb);
        var ho: [256]u8 = undefined;
        const hcross = try isolatedObject(r, hidden_id, &ho, hmain, "judge-other", "document.getElementById('cross')");
        var pb: [512]u8 = undefined;
        _ = try r.call(hidden_id, "DOM.describeNode", try std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{hcross}));
        var off_buf: [128]u8 = undefined;
        const other_frame: []const u8 = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch break :blk "";
            defer parsed.deinit();
            const node = parsed.value.object.get("node") orelse break :blk "";
            const f = node.object.get("frameId") orelse break :blk "";
            break :blk std.fmt.bufPrint(&off_buf, "{s}", .{f.string}) catch "";
        };
        const params = try std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\",\"worldName\":\"judge-x\"}}", .{other_frame});
        const st_cross = try r.callIn(visible_id, other_frame, "Page.createIsolatedWorld", params);
        var eb: [200]u8 = undefined;
        const es = std.fmt.bufPrint(&eb, "{s}", .{r.result.items[0..@min(r.result.items.len, 160)]}) catch "";
        const refused = st_cross == .cdp_error and std.mem.indexOf(u8, r.result.items, "No frame for given id found in this tab") != null;
        const st_own = try r.callIn(hidden_id, other_frame, "Page.createIsolatedWorld", params);
        report(other_frame.len > 0 and refused and st_own == .ok, "up-frame-other-tab", std.fmt.bufPrint(&detail, "다른 탭의 frame {s} · 이 탭에서 {s} 「{s}」 · 그 탭에서 {s}", .{ other_frame, statusName(st_cross), es, statusName(st_own) }) catch "");
    }
    // up-frame-session-gone — 위젯이 그 iframe 을 지우면 그 세션은 사라진다: 그 뒤의 frame 호출은 답한다(매달리지 않는다) — 세션을 잃은 오류(보냈던 것)나
    // send_failed(세션이 없어 보내지 않은 것). maru 의 엔진은 넣기 뒤의 세션 잃음을 「넣었다 — 읽을 수 없다」 로 읽는다.
    {
        // ① 보낸 채 매달린 호출 — 그 iframe 이 바쁜 사이 바깥 문서가 지운다(다른 프로세스라 바깥의 타이머가 돈다): 그 호출은 갔다 — 「안 갔다」
        // (send_failed)가 아니라 CDP 오류로 답한다(적대 검증 14 회차: 넣기면 「넣지 않았다」 로 읽어 다시 올렸다).
        _ = try r.callIn(visible_id, cross_frame, "Page.getFrameTree", "{}"); // 세션이 있게(쉬어 떼어졌으면 다시 붙는다)
        _ = try r.eval(visible_id, &vb, "(function(){var x=document.getElementById('cross');setTimeout(function(){x.parentNode.removeChild(x)},300);return 'ok'})()");
        const st1 = try r.callIn(visible_id, cross_frame, "Runtime.evaluate", "{\"expression\":\"(function(){var t=Date.now();while(Date.now()<t+2500){}return 1})()\"}");
        var eb1: [200]u8 = undefined;
        const es1 = std.fmt.bufPrint(&eb1, "{s}", .{r.result.items[0..@min(r.result.items.len, 180)]}) catch "";
        r.pump(600);
        // ② 지운 뒤 — 세션이 없고 원격 객체를 싣지 않는 호출이라도 새로 붙지 않는 호출(evaluate)은 보내지 않는다.
        const st = try r.callIn(visible_id, cross_frame, "Runtime.evaluate", "{\"expression\":\"1\"}");
        var eb: [200]u8 = undefined;
        const es = std.fmt.bufPrint(&eb, "{s}", .{r.result.items[0..@min(r.result.items.len, 180)]}) catch "";
        const ok = st1 == .cdp_error and st == .send_failed;
        report(ok, "up-frame-session-gone", std.fmt.bufPrint(&detail, "바쁜 사이 지움 {s} 「{s}」 · 지운 뒤 {s} 「{s}」", .{ statusName(st1), es1, statusName(st), es }) catch "");
    }
}

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
    folderAndFrameChecks(&r, report, files_dir, a, b, port) catch |e| report(false, "up-folder-frame", @errorName(e));
    report(r.pickers == 0, "up-no-picker", std.fmt.bufPrint(&detail, "파일 고르개 {d} 번", .{r.pickers}) catch "");
}
