//! LSP seam 1단의 제품 쪽(docs/editor-surface-tooling.md §8.2a) — 서버 수명·신뢰 프롬프트·문서 동기화·진단 합치기·상태바 상태.
//!
//! 한 클라이언트 = `(root, 서버 실행 파일)`. 세션 tick 마다 `pump` 가 ① 죽은 자식·재시작 예약 ② 밀린 쓰기 ③ 비차단 읽기 → 프레임 →
//! JSON-RPC 갈래 ④ 열린 편집기 Term 의 동기화(didOpen / 이 프레임에 바뀐 문서의 didChange 한 번)를 돈다. 스레드는 없다 — 원격
//! 에이전트 스트리머와 같은 결이다.
//!
//! **신뢰가 먼저다.** 서버가 PATH 에 있어도 그 root 의 결정이 없으면 confirm 모달로 묻고(`pending_confirm = .lsp_trust`), 답을
//! `~/.config/maru/lsp-trust` 에 root 별로 적는다. 거부한 root 는 안 띄우고 안 묻는다 — 상태바 항목을 누르면 다시 묻는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const lsp_process = @import("../lsp_process.zig");
const lsp = maru.session.editor.lsp;
const diagnostic = maru.session.editor.diagnostic;
const language = maru.session.editor.language;
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");
const input_ops = @import("input.zig");
const term_ops = @import("term.zig");
const file_tree_backend = @import("../file_tree_backend.zig");

pub const Phase = enum {
    /// 실행 파일이 PATH 에 없다 — 상태바 「설치」.
    missing,
    /// 신뢰를 묻는 중(모달이 떠 있다).
    asking,
    /// 사용자가 거부했다(기억됨) — 상태바 「거부됨 — 다시 묻기」.
    denied,
    /// 띄웠고 `initialize` 응답을 기다린다.
    starting,
    /// 연결됐다.
    ready,
    /// 죽어서 재시작을 기다린다(backoff).
    restarting,
    /// 세 번 죽었다 — 클릭으로 재시도.
    failed,
};

pub const max_restarts: u8 = 3;
pub const backoff_ms = [_]u64{ 1000, 2000, 4000 };
/// 한 tick 에 읽는 상한 — 서버가 폭주해도 프레임을 안 잡아먹는다(§8.2 「bounded push」).
const read_budget_per_tick: usize = 1 << 20;
/// 마지막 문서가 닫힌 뒤 서버를 얼마나 살려 두나(§8.2a).
pub const idle_shutdown_ms: u64 = 30_000;
const kill_grace_ms: u64 = 5_000;

const OpenDoc = struct {
    surface_id: u64,
    uri: []u8,
    /// 서버에 보낸 마지막 version.
    sent_version: u64,
};

pub const Client = struct {
    root: []u8,
    server: lsp.servers.Server,
    phase: Phase = .missing,
    proc: ?lsp_process.Process = null,
    inbuf: std.ArrayList(u8) = .empty,
    encoding: lsp.rpc.PositionEncoding = .utf16,
    restarts: u8 = 0,
    retry_at_ms: u64 = 0,
    docs: std.ArrayList(OpenDoc) = .empty,
    /// 마지막 문서가 닫힌 시각(0 = 열린 문서가 있다).
    idle_since_ms: u64 = 0,
    /// `shutdown` 을 보낸 시각(0 = 아니다). 응답이 오거나 시간이 지나면 `exit`/SIGKILL.
    shutdown_at_ms: u64 = 0,
    /// 신뢰 결정을 기다린다(이 root 의 모달이 떠 있거나, 다른 root 의 모달이 먼저다) — 띄우지 않는다.
    trust_pending: bool = false,

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        if (self.proc) |*p| {
            lsp_process.kill(p, .KILL);
            lsp_process.reapBlocking(p);
            p.deinit(allocator);
        }
        for (self.docs.items) |d| allocator.free(d.uri);
        self.docs.deinit(allocator);
        self.inbuf.deinit(allocator);
        allocator.free(self.root);
    }

    fn findDoc(self: *Client, surface_id: u64) ?*OpenDoc {
        for (self.docs.items) |*d| if (d.surface_id == surface_id) return d;
        return null;
    }
};

pub const TrustEntry = struct { root: []u8, decision: lsp.trust.Decision };

pub const State = struct {
    clients: std.ArrayList(Client) = .empty,
    trust: std.ArrayList(TrustEntry) = .empty,
    trust_loaded: bool = false,
    /// 묻는 중인 root(모달의 주인). 답이 오면 그 root 의 클라이언트가 움직인다.
    asking_root: ?[]u8 = null,
    /// 판정자가 켜는 스위치 — 프롬프트 없이 이 답으로 간주한다(하니스 전용). `null` 이면 정상(모달).
    auto_trust_answer: ?lsp.trust.Decision = null,
    /// 판정자 관측: 보낸 didChange 수·받은 publishDiagnostics 수·거부한 서버 요청 수.
    sent_changes: u64 = 0,
    received_diagnostics: u64 = 0,
    rejected_requests: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.clients.items) |*c| c.deinit(allocator);
        self.clients.deinit(allocator);
        for (self.trust.items) |t| allocator.free(t.root);
        self.trust.deinit(allocator);
        if (self.asking_root) |r| allocator.free(r);
        self.* = .{};
    }
};

// ── root·문서 ─────────────────────────────────────────────────────────────────

/// 그 Term 의 문서가 속한 root(§8.2a). 파일 트리 root 가 없거나 문서가 그 밖이면 `null` — 서버를 안 띄운다.
fn rootFor(self: *AppSession, term: *Term) ?[]const u8 {
    if (term.rt.editor_lsp_root) |r| return r;
    const path = termPath(term) orelse return null;
    // 파일 트리와 **같은 규칙**(`projectRootForFile`): 가장 가까운 `.git` 의 디렉터리, 없으면 파일의 디렉터리. 한 번 정해 굳힌다.
    const root = file_tree_backend.projectRootForFile(self.allocator, self.io, path) catch return null;
    if (root.len == 0 or !maru.session.repo_path.underRoot(path, root)) {
        self.allocator.free(root);
        return null;
    }
    term.rt.editor_lsp_root = root;
    return root;
}

/// 문서의 절대 경로 — 편집기 Term 이 여는 순간 굳힌 `editor_path`(탭 라벨·컨트롤 플레인이 읽는 그것).
fn termPath(term: *const Term) ?[]const u8 {
    return term.rt.editor_path;
}

// ── 신뢰 ──────────────────────────────────────────────────────────────────────

fn trustFilePath(self: *AppSession, buf: []u8) ?[]const u8 {
    const cfg = self.configPath();
    const dir = std.fs.path.dirname(cfg) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/lsp-trust", .{dir}) catch null;
}

fn loadTrust(self: *AppSession) void {
    const st = &self.editor_lsp;
    if (st.trust_loaded) return;
    st.trust_loaded = true;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = trustFilePath(self, &pbuf) orelse return;
    const contents = readSmallFile(self.allocator, path) orelse return;
    defer self.allocator.free(contents);
    // 파일의 결정을 표로 — root 마다 마지막 줄이 이긴다(`lookup` 이 그렇게 읽는다). 표는 root 별로 한 번씩 묻는 캐시다.
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const root = line[tab + 1 ..];
        if (root.len == 0) continue;
        const decision = lsp.trust.lookup(contents, root) orelse continue;
        setTrustCached(self, root, decision);
    }
}

fn setTrustCached(self: *AppSession, root: []const u8, decision: lsp.trust.Decision) void {
    const st = &self.editor_lsp;
    for (st.trust.items) |*t| {
        if (std.mem.eql(u8, t.root, root)) {
            t.decision = decision;
            return;
        }
    }
    const owned = self.allocator.dupe(u8, root) catch return;
    st.trust.append(self.allocator, .{ .root = owned, .decision = decision }) catch {
        self.allocator.free(owned);
    };
}

fn trustOf(self: *AppSession, root: []const u8) ?lsp.trust.Decision {
    loadTrust(self);
    for (self.editor_lsp.trust.items) |t| if (std.mem.eql(u8, t.root, root)) return t.decision;
    return null;
}

/// 결정을 파일에 **덧붙인다**(마지막 줄이 이긴다) — 캐시도 갱신.
fn recordTrust(self: *AppSession, root: []const u8, decision: lsp.trust.Decision) void {
    setTrustCached(self, root, decision);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = trustFilePath(self, &pbuf) orelse return;
    var lbuf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const line = lsp.trust.line(decision, root, &lbuf) orelse return;
    appendSmallFile(path, line);
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return null;
    const fd = std.c.open(z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(allocator, chunk[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
        if (out.items.len > 1 << 20) break; // 신뢰 파일이 1 MB 를 넘을 이유가 없다
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn appendSmallFile(path: []const u8, line: []const u8) void {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    const fd = std.c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < line.len) {
        const n = std.c.write(fd, line[off..].ptr, line.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// 모달이 **답 없이** 닫혔다(다른 모달이 덮었다·앱이 끝난다) — 기억하지 않는다. 클라이언트는 다시 물을 수 있게 되돌린다.
/// 캡처 하니스가 이것을 잡았다: 종료 경로의 `cancelPendingConfirm` 이 「거부」를 파일에 적어 다음 실행이 서버를 안 띄웠다.
pub fn dismissTrustPrompt(self: *AppSession) void {
    const st = &self.editor_lsp;
    const root = st.asking_root orelse return;
    defer {
        self.allocator.free(root);
        st.asking_root = null;
    }
    for (st.clients.items) |*c| {
        if (!std.mem.eql(u8, c.root, root) or c.phase != .asking) continue;
        c.phase = .restarting;
        c.trust_pending = true; // 띄우지 않는다 — 다음 gate 가 다시 묻는다
    }
}

/// 신뢰 모달의 답(`confirm_accept` / 사용자의 취소) — `app_session` 의 pending_confirm 갈래가 부른다.
pub fn answerTrust(self: *AppSession, allow: bool) void {
    const st = &self.editor_lsp;
    const root = st.asking_root orelse return;
    defer {
        self.allocator.free(root);
        st.asking_root = null;
    }
    recordTrust(self, root, if (allow) .allow else .deny);
    for (st.clients.items) |*c| {
        if (!std.mem.eql(u8, c.root, root)) continue;
        if (c.phase != .asking) continue;
        c.trust_pending = false;
        c.phase = if (allow) .restarting else .denied; // allow 면 다음 pump 가 띄운다
        c.retry_at_ms = 0;
        c.restarts = 0;
    }
    self.metal_dirty = true;
}

// ── 클라이언트 찾기·띄우기 ───────────────────────────────────────────────────

fn clientFor(self: *AppSession, root: []const u8, server: lsp.servers.Server) ?*Client {
    for (self.editor_lsp.clients.items) |*c| {
        if (std.mem.eql(u8, c.root, root) and std.mem.eql(u8, c.server.exe, server.exe)) return c;
    }
    return null;
}

fn ensureClient(self: *AppSession, root: []const u8, server: lsp.servers.Server) ?*Client {
    if (clientFor(self, root, server)) |c| return c;
    const owned = self.allocator.dupe(u8, root) catch return null;
    self.editor_lsp.clients.append(self.allocator, .{ .root = owned, .server = server, .phase = .restarting }) catch {
        self.allocator.free(owned);
        return null;
    };
    return &self.editor_lsp.clients.items[self.editor_lsp.clients.items.len - 1];
}

fn spawnClient(self: *AppSession, c: *Client, now_ms: u64) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = lsp_process.locate(c.server.exe, &pbuf) orelse {
        c.phase = .missing;
        return;
    };
    const proc = lsp_process.spawn(self.allocator, exe, c.server.args, c.root) catch {
        scheduleRestart(self, c, now_ms);
        return;
    };
    c.proc = proc;
    c.inbuf.clearRetainingCapacity();
    c.encoding = .utf16;
    c.shutdown_at_ms = 0;
    c.phase = .starting;
    // 열려 있던 문서는 다시 열어야 한다(새 프로세스는 모른다).
    for (c.docs.items) |*d| d.sent_version = 0;
    var uri_buf: [std.fs.max_path_bytes * 3]u8 = undefined;
    const root_uri = fileUriBuf(c.root, &uri_buf) orelse return;
    const msg = lsp.rpc.initializeRequest(self.allocator, root_uri, @intCast(std.c.getpid())) catch return;
    defer self.allocator.free(msg);
    _ = send(self, c, msg);
}

fn scheduleRestart(self: *AppSession, c: *Client, now_ms: u64) void {
    _ = self;
    if (c.restarts >= max_restarts) {
        c.phase = .failed;
        return;
    }
    c.retry_at_ms = now_ms + backoff_ms[@min(c.restarts, backoff_ms.len - 1)];
    c.restarts += 1;
    c.phase = .restarting;
}

fn dropProcess(self: *AppSession, c: *Client) void {
    if (c.proc) |*p| {
        lsp_process.kill(p, .KILL);
        lsp_process.reapBlocking(p);
        p.deinit(self.allocator);
        c.proc = null;
    }
    c.inbuf.clearRetainingCapacity();
}

fn fileUriBuf(path: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    const prefix = "file://";
    if (buf.len < prefix.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    n = prefix.len;
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (keep) {
            if (n >= buf.len) return null;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[n..], "%{X:0>2}", .{ch}) catch return null;
            n += 3;
        }
    }
    return buf[0..n];
}

/// 프레임을 씌워 보낸다. 자식이 죽었으면 `false`.
fn send(self: *AppSession, c: *Client, body: []const u8) bool {
    const p = &(c.proc orelse return false);
    var hdr: [64]u8 = undefined;
    const hn = lsp.framing.writeHeader(body.len, &hdr) orelse return false;
    if (!(lsp_process.write(p, self.allocator, hdr[0..hn]) catch return false)) return false;
    return lsp_process.write(p, self.allocator, body) catch false;
}

// ── tick ──────────────────────────────────────────────────────────────────────

/// 세션 tick — `AppSession.tick` 이 부른다.
pub fn pump(self: *AppSession) void {
    if (!self.loaded_config.config.lsp.enabled) return;
    const now_ms = self.awakeMs();
    syncDocuments(self, now_ms);
    var i: usize = 0;
    while (i < self.editor_lsp.clients.items.len) : (i += 1) {
        const c = &self.editor_lsp.clients.items[i];
        pumpClient(self, c, now_ms);
    }
}

fn pumpClient(self: *AppSession, c: *Client, now_ms: u64) void {
    switch (c.phase) {
        .restarting => if (!c.trust_pending and now_ms >= c.retry_at_ms) spawnClient(self, c, now_ms),
        .starting, .ready => {},
        .missing, .asking, .denied, .failed => return,
    }
    const p = &(c.proc orelse return);
    // 유휴 종료(§8.2a): 마지막 문서가 닫힌 지 30 초면 shutdown → exit. 응답이 없으면 5 초 뒤 SIGKILL.
    if (c.docs.items.len == 0 and c.idle_since_ms != 0 and c.shutdown_at_ms == 0 and now_ms - c.idle_since_ms >= idle_shutdown_ms) {
        const msg = lsp.rpc.shutdownRequest(self.allocator) catch return;
        defer self.allocator.free(msg);
        _ = send(self, c, msg);
        c.shutdown_at_ms = now_ms;
    }
    if (c.shutdown_at_ms != 0 and now_ms - c.shutdown_at_ms >= kill_grace_ms) {
        dropProcess(self, c);
        c.phase = .restarting;
        c.retry_at_ms = std.math.maxInt(u64); // 문서가 열리면 다시 띄운다(`syncDocuments` 가 0 으로 되돌린다)
        c.restarts = 0;
        return;
    }
    if (!(lsp_process.flush(p, self.allocator) catch false)) {
        onDied(self, c, now_ms);
        return;
    }
    const r = lsp_process.readInto(p, self.allocator, &c.inbuf, read_budget_per_tick) catch return;
    if (r == .eof or lsp_process.reapIfExited(p)) {
        onDied(self, c, now_ms);
        return;
    }
    drainFrames(self, c, now_ms);
}

fn onDied(self: *AppSession, c: *Client, now_ms: u64) void {
    const was_shutting_down = c.shutdown_at_ms != 0;
    dropProcess(self, c);
    if (was_shutting_down) {
        // 우리가 끝낸 것 — 재시작 예약 없이 잠든다. 문서가 열리면 `syncDocuments` 가 깨운다.
        c.phase = .restarting;
        c.retry_at_ms = std.math.maxInt(u64);
        c.restarts = 0;
        c.shutdown_at_ms = 0;
        return;
    }
    scheduleRestart(self, c, now_ms);
    self.metal_dirty = true;
}

fn drainFrames(self: *AppSession, c: *Client, now_ms: u64) void {
    _ = now_ms;
    while (true) {
        const frame = lsp.framing.next(c.inbuf.items) catch {
            // 못 믿는 스트림 — 죽이고 재시작 경로로.
            dropProcess(self, c);
            scheduleRestart(self, c, self.awakeMs());
            return;
        } orelse break;
        handleFrame(self, c, frame.body);
        const rest = c.inbuf.items.len - frame.consumed;
        std.mem.copyForwards(u8, c.inbuf.items[0..rest], c.inbuf.items[frame.consumed..]);
        c.inbuf.shrinkRetainingCapacity(rest);
        if (c.proc == null) return; // handleFrame 이 죽였을 수 있다
    }
}

fn handleFrame(self: *AppSession, c: *Client, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
    defer parsed.deinit();
    switch (lsp.rpc.classify(parsed.value)) {
        .response => |r| switch (r.id) {
            .initialize => {
                if (r.is_error) return; // 다음 tick 의 읽기가 EOF 를 보거나, 서버가 살아 있으면 그대로 둔다(진단은 안 온다)
                c.encoding = lsp.rpc.positionEncodingFromResult(r.result);
                c.phase = .ready;
                c.restarts = 0;
                const msg = lsp.rpc.initializedNotification(self.allocator) catch return;
                defer self.allocator.free(msg);
                _ = send(self, c, msg);
                self.metal_dirty = true;
            },
            .shutdown => {
                const msg = lsp.rpc.exitNotification(self.allocator) catch return;
                defer self.allocator.free(msg);
                _ = send(self, c, msg);
            },
        },
        .notification => |n| {
            if (std.mem.eql(u8, n.method, "textDocument/publishDiagnostics")) onPublishDiagnostics(self, c, n.params);
        },
        .request => |q| {
            // §8.2a 「하지 않는 것」 — 전부 거부.
            self.editor_lsp.rejected_requests += 1;
            const msg = lsp.rpc.methodNotFound(self.allocator, q.id) catch return;
            defer self.allocator.free(msg);
            _ = send(self, c, msg);
        },
        .ignore => {},
    }
}

fn onPublishDiagnostics(self: *AppSession, c: *Client, params: ?std.json.Value) void {
    const p = params orelse return;
    const obj = switch (p) {
        .object => |o| o,
        else => return,
    };
    const uri = switch (obj.get("uri") orelse return) {
        .string => |s| s,
        else => return,
    };
    const doc = for (c.docs.items) |*d| {
        if (std.mem.eql(u8, d.uri, uri)) break d;
    } else return; // 모르는 문서(root 밖·닫힌 것) — 무시(§8.2a)
    const term = term_ops.termBySurfaceId(self, doc.surface_id) orelse return;
    const opened = term.rt.editor_doc orelse return;
    // version 이 오면 지금 것과 같아야 한다(§5 「revision 으로 폐기」).
    if (obj.get("version")) |v| switch (v) {
        .integer => |n| if (n != @as(i64, @intCast(term.rt.editor_lsp_version))) return,
        else => {},
    };
    self.editor_lsp.received_diagnostics += 1;
    const st = &term.rt.editor_diagnostics;
    st.lsp.clearRetainingCapacity();
    st.lsp_messages.clearRetainingCapacity();
    _ = lsp.position.appendDiagnostics(self.allocator, p, opened.file.content, opened.file.lines, c.encoding, &st.lsp, &st.lsp_messages) catch {};
    st.lsp_dirty = true;
    self.metal_dirty = true;
}

// ── 문서 동기화 ───────────────────────────────────────────────────────────────

fn syncDocuments(self: *AppSession, now_ms: u64) void {
    // 열린 편집기 Term 을 전부 훑는다 — 서버가 필요한 것에 클라이언트를 붙이고(신뢰 거쳐), 문서를 연다/바뀐 것을 보낸다.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(self.allocator);
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.kind != .editor or term.rt.editor_doc == null or term.rt.editor_diff != null) continue;
                const server = lsp.servers.forGrammar(term.rt.editor_grammar) orelse continue;
                const root = rootFor(self, term) orelse continue;
                const c = ensureClient(self, root, server) orelse continue;
                seen.put(self.allocator, term.surfaceId(), {}) catch {};
                if (c.docs.items.len == 0 and c.idle_since_ms != 0) c.idle_since_ms = 0;
                if (c.retry_at_ms == std.math.maxInt(u64)) c.retry_at_ms = 0; // 잠들어 있던 서버를 깨운다
                gateTrust(self, c);
                if (c.phase != .ready) continue;
                syncOne(self, c, term);
            }
        }
    }
    // 닫힌 문서 → didClose. 마지막 문서가 닫히면 유휴 시계를 켠다.
    for (self.editor_lsp.clients.items) |*c| {
        var i: usize = 0;
        while (i < c.docs.items.len) {
            const d = c.docs.items[i];
            if (seen.contains(d.surface_id)) {
                i += 1;
                continue;
            }
            if (c.phase == .ready) {
                const msg = lsp.rpc.didClose(self.allocator, d.uri) catch null;
                if (msg) |m| {
                    defer self.allocator.free(m);
                    _ = send(self, c, m);
                }
            }
            self.allocator.free(d.uri);
            _ = c.docs.swapRemove(i);
        }
        if (c.docs.items.len == 0 and c.idle_since_ms == 0) c.idle_since_ms = now_ms;
    }
}

/// 신뢰 게이트(§8.2a): 결정이 없으면 묻고(모달 하나만 — 다른 root 는 기다린다), 거부면 `denied`, 허용이면 띄울 수 있게 둔다.
fn gateTrust(self: *AppSession, c: *Client) void {
    switch (c.phase) {
        .restarting, .missing => {},
        else => return,
    }
    if (c.proc != null) return;
    // 실행 파일이 없으면 신뢰를 묻지 않는다 — 「설치」가 먼저다.
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (lsp_process.locate(c.server.exe, &pbuf) == null) {
        c.phase = .missing;
        return;
    }
    if (c.phase == .missing) c.phase = .restarting; // 설치된 것을 이제 봤다
    const decision = trustOf(self, c.root) orelse {
        if (self.editor_lsp.auto_trust_answer) |ans| {
            recordTrust(self, c.root, ans);
            c.trust_pending = false;
            if (ans == .deny) c.phase = .denied;
            return;
        }
        c.trust_pending = true; // 답이 올 때까지 **띄우지 않는다** — 다른 root 의 모달이 먼저라도 같다
        if (self.editor_lsp.asking_root) |asking| {
            if (std.mem.eql(u8, asking, c.root)) c.phase = .asking; // 같은 root 의 다른 서버 — 그 모달이 답이다
            return; // 한 번에 하나
        }
        // 다른 오버레이(알림 토스트·팔레트·설정)가 떠 있으면 **기다린다** — 지금 띄우면 그쪽이 우리 모달을 닫고(`showNotice` →
        // `cancelPendingClose`) 다음 tick 에 또 띄워 깜빡인다(캡처 하니스에서 실측: 작업 공간 복원 알림과 겹쳤다).
        if (self.anyOverlayOpen()) return;
        const owned = self.allocator.dupe(u8, c.root) catch return;
        self.editor_lsp.asking_root = owned;
        c.phase = .asking;
        var msg_buf: [512]u8 = undefined;
        const text = fillName(maru.i18n.t(.lsp_trust_prompt), c.server.exe, &msg_buf) orelse return;
        self.showConfirmText(.lsp_trust, text, .{ .confirm = .lsp_trust_allow, .cancel = .lsp_trust_deny });
        return;
    };
    c.trust_pending = false;
    if (decision == .deny) c.phase = .denied;
}

fn syncOne(self: *AppSession, c: *Client, term: *Term) void {
    const opened = term.rt.editor_doc orelse return;
    if (opened.file.content.len > max_sync_bytes) return; // §8.2a: 상한 넘는 문서는 안 보낸다
    const version: u64 = term.rt.editor_lsp_version;
    if (c.findDoc(term.surfaceId())) |d| {
        if (d.sent_version == version) return;
        if (d.sent_version == 0) {
            const msg = lsp.rpc.didOpen(self.allocator, d.uri, c.server.language_id, @intCast(version), opened.file.content) catch return;
            defer self.allocator.free(msg);
            if (!send(self, c, msg)) return;
        } else {
            const msg = lsp.rpc.didChangeFull(self.allocator, d.uri, @intCast(version), opened.file.content) catch return;
            defer self.allocator.free(msg);
            if (!send(self, c, msg)) return;
            self.editor_lsp.sent_changes += 1;
        }
        d.sent_version = version;
        return;
    }
    const path = termPath(term) orelse return;
    const uri = lsp.rpc.fileUri(self.allocator, path) catch return;
    if (term.rt.editor_lsp_version == 0) term.rt.editor_lsp_version = 1; // version 0 은 「안 보냈다」의 자리
    const v: u64 = term.rt.editor_lsp_version;
    const msg = lsp.rpc.didOpen(self.allocator, uri, c.server.language_id, @intCast(v), opened.file.content) catch {
        self.allocator.free(uri);
        return;
    };
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) {
        self.allocator.free(uri);
        return;
    }
    c.docs.append(self.allocator, .{ .surface_id = term.surfaceId(), .uri = uri, .sent_version = v }) catch {
        self.allocator.free(uri);
    };
}

/// 문서 크기 상한(§3.0 의 상한과 같은 자리 — Full sync 라 전문이 프레임마다 갈 수 있다).
pub const max_sync_bytes: usize = 4 * 1024 * 1024;

/// 편집이 일어났다 — `refreshAfterEdit` 가 부른다. version 을 올려 다음 pump 가 didChange 를 보내게.
pub fn noteEdited(term: *Term) void {
    if (term.rt.editor_lsp_version == 0) term.rt.editor_lsp_version = 1;
    term.rt.editor_lsp_version += 1;
}

/// i18n 문장의 첫 `{s}` 에 이름을 끼운다(서식 문자열이 런타임이라 `bufPrint` 를 못 쓴다). `{s}` 가 없으면 그대로.
pub fn fillName(template: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, template, "{s}") orelse {
        if (template.len > buf.len) return null;
        @memcpy(buf[0..template.len], template);
        return buf[0..template.len];
    };
    const total = template.len - 3 + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..at], template[0..at]);
    @memcpy(buf[at..][0..name.len], name);
    @memcpy(buf[at + name.len ..][0 .. template.len - at - 3], template[at + 3 ..]);
    return buf[0..total];
}

/// 상태바 문구(§8.2a) — phase 마다 하나.
pub fn statusText(view: StatusView, buf: []u8) ?[]const u8 {
    const key: maru.i18n.Key = switch (view.phase) {
        .missing => .lsp_status_missing,
        .asking => .lsp_status_asking,
        .starting => .lsp_status_starting,
        .restarting => .lsp_status_restarting,
        .failed => .lsp_status_failed,
        .denied => .lsp_status_denied,
        .ready => return fillName("{s}", view.exe, buf),
    };
    return fillName(maru.i18n.t(key), view.exe, buf);
}

// ── 상태바·클릭 ───────────────────────────────────────────────────────────────

pub const StatusView = struct { phase: Phase, exe: []const u8 };

/// 활성 편집기 Term 의 서버 상태(상태바 항목 — §8.2a). 서버 이름표가 없거나 root 밖이면 `null`(항목 없음).
pub fn statusFor(self: *AppSession, term: *Term) ?StatusView {
    if (!self.loaded_config.config.lsp.enabled) return null;
    if (term.kind != .editor or term.rt.editor_doc == null or term.rt.editor_diff != null) return null;
    const server = lsp.servers.forGrammar(term.rt.editor_grammar) orelse return null;
    const root = rootFor(self, term) orelse return null;
    const c = clientFor(self, root, server) orelse return .{ .phase = .missing, .exe = server.exe };
    // 답을 기다리는 동안(모달이 다른 오버레이 뒤에서 순서를 기다리거나 떠 있는 동안)은 「허락 대기」다 — 「다시 시작 중」이 아니다.
    if (c.trust_pending and c.phase == .restarting) return .{ .phase = .asking, .exe = server.exe };
    return .{ .phase = c.phase, .exe = server.exe };
}

/// 상태바 항목 클릭(§8.2a): 없음 → 새 탭에 설치 명령 입력 · 거부됨 → 다시 묻기 · 실패 → 재시작. 나머지는 무동작.
pub fn activateStatus(self: *AppSession) void {
    const pane = pane_ops.activePane(self);
    if (pane.terms.items.len == 0) return;
    const term = pane.activeTerm();
    const view = statusFor(self, term) orelse return;
    const server = lsp.servers.forGrammar(term.rt.editor_grammar) orelse return;
    switch (view.phase) {
        .missing => {
            // §8.1a 흐름 4: **새 탭**에 입력만 — Enter 는 사용자.
            _ = tab_ops.newTab(self) catch return;
            input_ops.sendTextAsKeys(self, server.install);
        },
        .denied => {
            const root = rootFor(self, term) orelse return;
            const c = clientFor(self, root, server) orelse return;
            // 캐시의 거부를 지워 다음 pump 가 다시 묻게 한다(파일에는 새 답이 덧붙는다).
            for (self.editor_lsp.trust.items, 0..) |t, i| {
                if (std.mem.eql(u8, t.root, root)) {
                    self.allocator.free(t.root);
                    _ = self.editor_lsp.trust.swapRemove(i);
                    break;
                }
            }
            c.phase = .restarting;
            c.retry_at_ms = 0;
        },
        .failed => {
            const root = rootFor(self, term) orelse return;
            const c = clientFor(self, root, server) orelse return;
            c.restarts = 0;
            c.phase = .restarting;
            c.retry_at_ms = 0;
        },
        .asking, .starting, .ready, .restarting => {},
    }
    self.metal_dirty = true;
}

/// Term 이 닫힐 때 — 그 문서를 서버에서 닫는다(다음 pump 가 `seen` 에 없어 didClose 를 보낸다). 여기서는 진단 저장소만.
pub fn noteTermClosing(self: *AppSession, term: *Term) void {
    _ = self;
    _ = term;
}

/// 앱 종료 — 서버들을 거둔다(§8.2a: shutdown 을 기다리지 않는다 — 종료 경로는 짧아야 한다).
pub fn deinit(self: *AppSession) void {
    self.editor_lsp.deinit(self.allocator);
}
