//! Chromium(OSR) 탭의 localStorage·쿠키·clearStorage(W9a③ — WebKit 탭에 있던 `browser.*` 를 Chromium 으로). `web_cdp_ops.Op` 가 이
//! 종류를 여기로 넘긴다(같은 `Step`·`Reply` — 보내기·받기·완료는 `app_host_abi`). 계획과 실측은 docs/plans/web-osr-backend.md 「W9a」.
//!
//! 부른 쪽이 시작 전에 **확인한 문서 주소**(`doc_url` — maru 가 아는 그 탭의 주소)를 넣는다. 이후 호출은 그 주소로만 한다 — 그사이 탭이
//! 다른 사이트로 옮겨 가도 다른 사이트의 쿠키를 읽거나 지우지 않는다.
//! - localStorage: `Page.getFrameTree` 로 주 프레임의 출처가 그 주소의 출처인지 본 뒤(about:blank·data: 는 거절), 격리 world 에서
//!   `Storage.prototype.*.call(localStorage, …)` — 페이지가 덮어쓴 `localStorage`·`getItem` 을 타지 않는다(계획 공격 1 회차 실측).
//! - 쿠키 읽기: `Network.getCookies {urls:[문서 주소]}` 만 — 그 문서에 가는 쿠키(RFC 6265, WebKit 의 `cookieVisibleToHost` 와 같다).
//!   `getAllCookies`·urls 없는 getCookies 는 다른 사이트의 HttpOnly 쿠키까지 maru 로 건넸다. 다른 path 의 쿠키는 보이지 않는다(문서).
//! - 쿠키 쓰기: domain 은 그 페이지의 **호스트 자신만**(작성자 선택 D6 — 공개 접미사 목록이 없어 foo.github.io 로 github.io 에 심을 수
//!   있었다). `success:false` 는 실패.
//! - 쿠키 지우기: 보이는 쿠키를 읽어 이름·path·호스트로 거른 뒤 받은 정확한 키(`name·domain·path·partitionKey`)로 하나씩(CDP 의
//!   deleteCookies 는 domain 을 글자 그대로 맞춘다 — 점·대소문자).
//! - clearStorage: `Storage.clearDataForOrigin "all"`(그 출처의 저장소 전부) + 그 호스트의 쿠키를 정확한 키로(작성자 선택 D7 — "all" 은
//!   도메인 쿠키를 남겼다).

const std = @import("std");
const ops = @import("web_cdp_ops.zig");

const Step = ops.Step;
const Reply = ops.Reply;
const Status = ops.Status;

pub const Kind = enum { get_local_storage, set_local_storage, remove_local_storage, get_cookies, set_cookie, delete_cookie, clear_storage };

pub const not_http_reason = "this page has no web origin (about:blank, data: or similar) — localStorage and cookies are not available";
pub const origin_moved_reason = "the page moved to another origin while the request waited — try again";
pub const cookie_domain_reason = "on a Chromium tab the cookie domain must be the page's own host";
pub const set_cookie_failed = "setCookie failed (Chromium refused the cookie)";
pub const storage_too_large = "the localStorage key and value are too large for a Chromium tab (64 KiB after JSON escaping)";
/// DevTools 호출 인자 상한(sidecar — `app_host_abi` 가 컴파일 때 맞춘다).
pub const max_params_bytes: usize = 64 * 1024;

/// 격리 world 이름(요청마다 새로 만든다 — 이동 뒤 옛 context 를 쓰지 않게).
const world_name = "maru-w9a-storage";

/// 지울 쿠키 상한(한 요청에서) — 넘으면 앞에서부터만 지우고 끝낸다(페이지가 쿠키를 수천 개 만들어도 op 하나가 끝없이 돌지 않게).
pub const max_cookie_deletes: usize = 512;

const Stage = enum { frame_tree, world, storage, cookies_read, cookie_set, cookie_delete, clear_origin, done_stage };

const CookieKey = struct { name: []u8, domain: []u8, path: []u8, partition: ?[]u8 };

pub const Op = struct {
    kind: Kind,
    stage: Stage = .frame_tree,
    /// L2 가 준 인자(소유).
    key: ?[]u8 = null,
    value: ?[]u8 = null,
    name: ?[]u8 = null,
    domain: ?[]u8 = null,
    path: ?[]u8 = null,
    secure: bool = false,
    /// 부른 쪽이 start 전에 넣는 확인한 문서 주소(빌림 — 그 op 동안 산다: 부른 쪽이 복사해 둔다).
    doc_url: []const u8 = "",
    /// 지울 쿠키(소유).
    pending: std.ArrayList(CookieKey) = .empty,
    frame_id: ?[]u8 = null,
    context_id: i64 = 0,
    /// 지우기 — 보낸 수와 실패한 수(하나라도 실패하면 끝에 실패로 답한다 — 적대 리뷰 1 회차: 엔진이 다시 뜨는 사이 102 개가 남았는데 ok).
    delete_total: usize = 0,
    delete_failed: usize = 0,

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        for ([_]?[]u8{ self.key, self.value, self.name, self.domain, self.path, self.frame_id }) |v| if (v) |b| gpa.free(b);
        for (self.pending.items) |c| freeKey(gpa, c);
        self.pending.deinit(gpa);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg — localStorage `{key, value?}`, setCookie `{name, value, domain?, path?, secure?}`,
    /// deleteCookie `{name, domain?, path?}`, getCookies·clearStorage 는 빈 것.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8) !Op {
        var op: Op = .{ .kind = kind };
        errdefer op.deinit(gpa);
        switch (kind) {
            .get_cookies, .clear_storage => return op,
            else => {},
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArg;
        const o = parsed.value.object;
        switch (kind) {
            .get_local_storage, .remove_local_storage, .set_local_storage => {
                op.key = try dupeString(gpa, o.get("key") orelse return error.InvalidArg);
                if (kind == .set_local_storage) op.value = try dupeString(gpa, o.get("value") orelse return error.InvalidArg);
                // 평가 식은 키·값을 JSON 으로 두 번 이스케이프한 DevTools 인자에 싣는다 — 넘으면 엉뚱한 「selector」 글로 실패했다(적대 리뷰 1 회차).
                op.context_id = std.math.maxInt(i64);
                const probe = try op.storageStep(gpa);
                defer gpa.free(probe.call.params);
                op.context_id = 0;
                if (probe.call.params.len > max_params_bytes) return error.StorageValueTooLarge;
            },
            .set_cookie, .delete_cookie => {
                op.name = try dupeString(gpa, o.get("name") orelse return error.InvalidArg);
                if (kind == .set_cookie) op.value = try dupeString(gpa, o.get("value") orelse return error.InvalidArg);
                if (o.get("domain")) |d| op.domain = try dupeString(gpa, d);
                if (o.get("path")) |p| op.path = try dupeString(gpa, p);
                if (o.get("secure")) |v| {
                    if (v != .bool) return error.InvalidArg;
                    op.secure = v.bool;
                }
            },
            .get_cookies, .clear_storage => unreachable,
        }
        return op;
    }

    pub fn committed(self: *const Op) bool {
        // 지우기를 시작했으면(하나라도 보냈으면) 끝까지 — 반쯤 지운 채 두지 않는다.
        return self.stage == .cookie_delete;
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        const origin = originOf(self.doc_url);
        switch (self.kind) {
            .get_local_storage, .set_local_storage, .remove_local_storage => {
                if (origin == null) return done(gpa, .failed, not_http_reason);
                self.stage = .frame_tree;
                return call(gpa, "Page.getFrameTree", "{}");
            },
            .get_cookies => {
                // 웹 출처가 없는 문서(about:blank 등)는 보이는 쿠키가 없다 — WebKit 과 같이 빈 목록.
                if (origin == null) return done(gpa, .success, "[]");
                self.stage = .cookies_read;
                return self.readCookies(gpa, &.{self.doc_url});
            },
            .set_cookie => {
                const host = hostOf(self.doc_url) orelse return done(gpa, .failed, not_http_reason);
                if (self.domain) |d| if (!sameHost(d, host)) return done(gpa, .failed, cookie_domain_reason);
                self.stage = .cookie_set;
                return self.setCookieStep(gpa);
            },
            .delete_cookie => {
                const host = hostOf(self.doc_url) orelse return done(gpa, .success, ""); // 지울 것이 없다(멱등)
                if (self.domain) |d| if (!sameHost(d, host)) return done(gpa, .failed, cookie_domain_reason);
                // 지울 path 의 쿠키를 보려면 그 path 로 묻는다(문서 주소로 물으면 `Path=/p` 쿠키가 안 보였다 — 계획 공격 3 회차).
                const u = try std.fmt.allocPrint(gpa, "{s}{s}", .{ origin.?, self.path orelse "/" });
                defer gpa.free(u);
                self.stage = .cookies_read;
                return self.readCookies(gpa, &.{u});
            },
            .clear_storage => {
                const o = origin orelse return done(gpa, .success, ""); // 웹 출처가 없다 — 지울 것이 없다(WebKit 과 같다, 멱등)
                self.stage = .clear_origin;
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                std.json.Stringify.value(.{ .origin = o, .storageTypes = "all" }, .{}, &aw.writer) catch return error.OutOfMemory;
                return .{ .call = .{ .method = "Storage.clearDataForOrigin", .params = try aw.toOwnedSlice() } };
            },
        }
    }

    pub fn wake(self: *Op, gpa: std.mem.Allocator) !Step {
        _ = self;
        return done(gpa, .failed, "internal DevTools request error");
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        const body = switch (reply) {
            .ok => |b| b,
            .cdp_error => |e| return self.failOrContinue(gpa, cdpMessage(e)),
            .failed => |why| return self.failOrContinue(gpa, why),
            .timed_out => |why| return done(gpa, .timeout, why),
            .not_sent => |why| return self.failOrContinue(gpa, why),
        };
        switch (self.stage) {
            .frame_tree => {
                const Frame = struct { id: []const u8, securityOrigin: []const u8 = "" };
                const parsed = std.json.parseFromSlice(struct { frameTree: struct { frame: Frame } }, gpa, body, .{ .ignore_unknown_fields = true }) catch
                    return done(gpa, .failed, "the page frame could not be read");
                defer parsed.deinit();
                const f = parsed.value.frameTree.frame;
                // 주 프레임의 출처가 확인한 주소의 출처인가 — 그사이 옮겨 갔으면 다른 출처의 저장소를 만지지 않는다. about:blank·data: 는
                // "://"(실측).
                const want = originOf(self.doc_url) orelse return done(gpa, .failed, not_http_reason);
                if (!std.ascii.eqlIgnoreCase(stripDefaultPort(f.securityOrigin), stripDefaultPort(want))) return done(gpa, .failed, origin_moved_reason);
                self.frame_id = try gpa.dupe(u8, f.id);
                self.stage = .world;
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                std.json.Stringify.value(.{ .frameId = f.id, .worldName = world_name, .grantUniveralAccess = false }, .{}, &aw.writer) catch return error.OutOfMemory;
                return .{ .call = .{ .method = "Page.createIsolatedWorld", .params = try aw.toOwnedSlice() } };
            },
            .world => {
                const parsed = std.json.parseFromSlice(struct { executionContextId: i64 }, gpa, body, .{ .ignore_unknown_fields = true }) catch
                    return done(gpa, .failed, "an isolated world could not be made");
                defer parsed.deinit();
                self.context_id = parsed.value.executionContextId;
                self.stage = .storage;
                return self.storageStep(gpa);
            },
            .storage => return storageResult(gpa, self.kind, body),
            .cookies_read => return self.afterRead(gpa, body),
            .cookie_set => {
                const parsed = std.json.parseFromSlice(struct { success: bool = false }, gpa, body, .{ .ignore_unknown_fields = true }) catch
                    return done(gpa, .failed, set_cookie_failed);
                defer parsed.deinit();
                return if (parsed.value.success) done(gpa, .success, "") else done(gpa, .failed, set_cookie_failed);
            },
            .cookie_delete => return self.nextDelete(gpa),
            .clear_origin => {
                // 저장소를 지웠다 — 이제 그 호스트의 쿠키(문서 주소와 출처의 뿌리에 보이는 것)를 하나씩.
                const o = originOf(self.doc_url).?;
                const root = try std.fmt.allocPrint(gpa, "{s}/", .{o});
                defer gpa.free(root);
                self.stage = .cookies_read;
                return self.readCookies(gpa, &.{ self.doc_url, root });
            },
            .done_stage => return done(gpa, .success, ""),
        }
    }

    /// 지우기 중의 실패는 세고 다음 쿠키로(하나를 못 지웠다고 나머지를 남기지 않는다) — 엔진·탭이 사라졌으면 곧 실패(뒤도 다 실패한다).
    /// 그 밖은 곧 실패.
    fn failOrContinue(self: *Op, gpa: std.mem.Allocator, why: []const u8) !Step {
        if (self.stage == .cookie_delete) {
            self.delete_failed += 1;
            if (std.mem.indexOf(u8, why, "not ready") != null or std.mem.indexOf(u8, why, "engine stopped") != null or std.mem.indexOf(u8, why, "tab closed") != null) {
                self.delete_failed += self.pending.items.len;
                return self.deleteSummary(gpa, why);
            }
            return self.nextDelete(gpa);
        }
        if (self.stage == .storage) if (std.mem.indexOf(u8, why, "SecurityError") != null) return done(gpa, .failed, not_http_reason);
        return done(gpa, .failed, why);
    }

    fn readCookies(self: *Op, gpa: std.mem.Allocator, urls: []const []const u8) !Step {
        _ = self;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(.{ .urls = urls }, .{}, &aw.writer) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Network.getCookies", .params = try aw.toOwnedSlice() } };
    }

    fn setCookieStep(self: *Op, gpa: std.mem.Allocator) !Step {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(self.name.?) catch return error.OutOfMemory;
        s.objectField("value") catch return error.OutOfMemory;
        s.write(self.value.?) catch return error.OutOfMemory;
        s.objectField("url") catch return error.OutOfMemory;
        s.write(self.doc_url) catch return error.OutOfMemory;
        // domain 은 글자 그대로(`host` 는 그 호스트만, `.host` 는 하위 호스트까지 — 실측), 없으면 그 호스트만(url 로).
        if (self.domain) |d| {
            s.objectField("domain") catch return error.OutOfMemory;
            s.write(d) catch return error.OutOfMemory;
        }
        s.objectField("path") catch return error.OutOfMemory;
        s.write(self.path orelse "/") catch return error.OutOfMemory;
        if (self.secure) {
            s.objectField("secure") catch return error.OutOfMemory;
            s.write(true) catch return error.OutOfMemory;
        }
        s.endObject() catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Network.setCookie", .params = try aw.toOwnedSlice() } };
    }

    fn storageStep(self: *Op, gpa: std.mem.Allocator) !Step {
        var expr: std.Io.Writer.Allocating = .init(gpa);
        defer expr.deinit();
        const w = &expr.writer;
        try w.writeAll("(()=>{const k=");
        try std.json.Stringify.encodeJsonString(self.key.?, .{}, w);
        switch (self.kind) {
            .get_local_storage => try w.writeAll(";return Storage.prototype.getItem.call(localStorage,k)})()"),
            .remove_local_storage => try w.writeAll(";Storage.prototype.removeItem.call(localStorage,k);return true})()"),
            .set_local_storage => {
                try w.writeAll(",v=");
                try std.json.Stringify.encodeJsonString(self.value.?, .{}, w);
                try w.writeAll(";Storage.prototype.setItem.call(localStorage,k,v);return true})()");
            },
            else => unreachable,
        }
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(.{ .expression = expr.written(), .contextId = self.context_id, .returnByValue = true }, .{}, &aw.writer) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Runtime.evaluate", .params = try aw.toOwnedSlice() } };
    }

    fn afterRead(self: *Op, gpa: std.mem.Allocator, body: []const u8) !Step {
        const CdpCookie = struct {
            name: []const u8,
            value: []const u8 = "",
            domain: []const u8 = "",
            path: []const u8 = "/",
            expires: f64 = -1,
            httpOnly: bool = false,
            secure: bool = false,
            session: bool = true,
            sameSite: ?[]const u8 = null,
            partitionKey: ?std.json.Value = null,
        };
        const parsed = std.json.parseFromSlice(struct { cookies: []const CdpCookie }, gpa, body, .{ .ignore_unknown_fields = true }) catch
            return done(gpa, .failed, "the cookies could not be read");
        defer parsed.deinit();
        if (self.kind == .get_cookies) {
            // WebKit 과 같은 모양 `{name,value,domain,path,secure,httpOnly,expires?,sameSite?}`(세션 쿠키는 expires 가 없다).
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
            s.beginArray() catch return error.OutOfMemory;
            for (parsed.value.cookies) |c| {
                s.beginObject() catch return error.OutOfMemory;
                for ([_][]const u8{ "name", "value", "domain", "path" }, [_][]const u8{ c.name, c.value, c.domain, c.path }) |f, v| {
                    s.objectField(f) catch return error.OutOfMemory;
                    s.write(v) catch return error.OutOfMemory;
                }
                s.objectField("secure") catch return error.OutOfMemory;
                s.write(c.secure) catch return error.OutOfMemory;
                s.objectField("httpOnly") catch return error.OutOfMemory;
                s.write(c.httpOnly) catch return error.OutOfMemory;
                if (!c.session and c.expires >= 0) {
                    s.objectField("expires") catch return error.OutOfMemory;
                    s.write(c.expires) catch return error.OutOfMemory;
                }
                if (c.sameSite) |ss| {
                    // WebKit(`HTTPCookieStringPolicy`)처럼 소문자(적대 리뷰 1 회차).
                    var lower: [16]u8 = undefined;
                    const n = @min(ss.len, lower.len);
                    s.objectField("sameSite") catch return error.OutOfMemory;
                    s.write(std.ascii.lowerString(lower[0..n], ss[0..n])) catch return error.OutOfMemory;
                }
                s.endObject() catch return error.OutOfMemory;
            }
            s.endArray() catch return error.OutOfMemory;
            return .{ .done = .{ .status = .success, .result = try aw.toOwnedSlice() } };
        }
        // 지우기·clearStorage — 그 호스트(`host`·`.host`)의 쿠키만(부모 도메인 쿠키는 grant 의 호스트 밖이다 — 계획 공격 3 회차).
        const host = hostOf(self.doc_url).?;
        for (parsed.value.cookies) |c| {
            if (self.pending.items.len >= max_cookie_deletes) break;
            if (!sameHost(c.domain, host)) continue;
            if (self.kind == .delete_cookie) {
                if (!std.mem.eql(u8, c.name, self.name.?)) continue;
                if (!std.mem.eql(u8, c.path, self.path orelse "/")) continue;
                // domain 을 주면 WebKit 처럼 그 글자 그대로나 앞에 점을 붙인 것만(`.a.test` 는 호스트 전용 `a.test` 쿠키를 지우지 않는다 — 적대 리뷰 1 회차).
                if (self.domain) |d| if (!std.ascii.eqlIgnoreCase(c.domain, d) and !(c.domain.len > 0 and c.domain[0] == '.' and std.ascii.eqlIgnoreCase(c.domain[1..], d))) continue;
            }
            const partition: ?[]u8 = if (c.partitionKey) |pk| try std.json.Stringify.valueAlloc(gpa, pk, .{}) else null;
            // 같은 쿠키가 두 url 에서 겹쳐 보일 수 있다(clearStorage) — 한 번만. 분할(CHIPS)이 다르면 다른 쿠키다(적대 리뷰 1 회차: 하나만 지웠다).
            var dup = false;
            for (self.pending.items) |p| if (std.mem.eql(u8, p.name, c.name) and std.mem.eql(u8, p.domain, c.domain) and std.mem.eql(u8, p.path, c.path) and
                std.mem.eql(u8, p.partition orelse "", partition orelse ""))
            {
                dup = true;
            };
            if (dup) {
                if (partition) |p| gpa.free(p);
                continue;
            }
            errdefer if (partition) |p| gpa.free(p);
            const key: CookieKey = .{ .name = try gpa.dupe(u8, c.name), .domain = try gpa.dupe(u8, c.domain), .path = try gpa.dupe(u8, c.path), .partition = partition };
            self.pending.append(gpa, key) catch |e| {
                freeKey(gpa, key);
                return e;
            };
        }
        self.stage = .cookie_delete;
        self.delete_total = self.pending.items.len;
        return self.nextDelete(gpa);
    }

    fn deleteSummary(self: *Op, gpa: std.mem.Allocator, why: []const u8) !Step {
        self.stage = .done_stage;
        if (self.delete_failed == 0) return done(gpa, .success, "");
        const msg = try std.fmt.allocPrint(gpa, "{d} of {d} cookies could not be deleted ({s})", .{ self.delete_failed, self.delete_total, why });
        return .{ .done = .{ .status = .failed, .result = msg } };
    }

    fn nextDelete(self: *Op, gpa: std.mem.Allocator) !Step {
        const c = self.pending.pop() orelse return self.deleteSummary(gpa, "DevTools refused the delete");
        defer freeKey(gpa, c);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(c.name) catch return error.OutOfMemory;
        s.objectField("domain") catch return error.OutOfMemory;
        s.write(c.domain) catch return error.OutOfMemory;
        s.objectField("path") catch return error.OutOfMemory;
        s.write(c.path) catch return error.OutOfMemory;
        if (c.partition) |p| {
            s.objectField("partitionKey") catch return error.OutOfMemory;
            s.beginWriteRaw() catch return error.OutOfMemory;
            aw.writer.writeAll(p) catch return error.OutOfMemory;
            s.endWriteRaw();
        }
        s.endObject() catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Network.deleteCookies", .params = try aw.toOwnedSlice() } };
    }
};

fn storageResult(gpa: std.mem.Allocator, kind: Kind, body: []const u8) !Step {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return done(gpa, .failed, "the localStorage result could not be read");
    defer parsed.deinit();
    if (parsed.value != .object) return done(gpa, .failed, "the localStorage result could not be read");
    if (parsed.value.object.get("exceptionDetails")) |ex| {
        // about:blank·data: 의 SecurityError(실측) — 그 밖은 그 글로.
        const text = blk: {
            if (ex == .object) if (ex.object.get("exception")) |e| if (e == .object) if (e.object.get("description")) |d| if (d == .string) break :blk d.string;
            break :blk "localStorage failed";
        };
        if (std.mem.indexOf(u8, text, "SecurityError") != null) return done(gpa, .failed, not_http_reason);
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        return done(gpa, .failed, line[0..@min(line.len, 512)]);
    }
    if (kind != .get_local_storage) return done(gpa, .success, "");
    const r = parsed.value.object.get("result") orelse return done(gpa, .success, "");
    if (r != .object) return done(gpa, .success, "");
    // 없는 키(null)는 WebKit 과 같이 빈 글.
    const v = r.object.get("value") orelse return done(gpa, .success, "");
    return switch (v) {
        .string => |str| done(gpa, .success, str),
        else => done(gpa, .success, ""),
    };
}

/// http(s) 주소의 출처 `scheme://host[:port]`(문서 주소의 앞부분 — 기본 포트도 주소에 있는 그대로). 다른 스킴이면 null.
pub fn originOf(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..colon];
    if (!(std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))) return null;
    const rest = url[colon + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    // userinfo 는 출처가 아니다 — 있으면 받지 않는다(출처 비교가 틀린다).
    if (std.mem.indexOfScalar(u8, rest[0..end], '@') != null) return null;
    return url[0 .. colon + 3 + end];
}

/// 출처의 기본 포트(`:80` http·`:443` https)를 뺀 꼴 — securityOrigin 은 기본 포트를 적지 않는다.
fn stripDefaultPort(origin: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(origin, "http://") and std.mem.endsWith(u8, origin, ":80")) return origin[0 .. origin.len - 3];
    if (std.ascii.startsWithIgnoreCase(origin, "https://") and std.mem.endsWith(u8, origin, ":443")) return origin[0 .. origin.len - 4];
    return origin;
}

pub fn hostOf(url: []const u8) ?[]const u8 {
    const o = originOf(url) orelse return null;
    var h = o[std.mem.indexOf(u8, o, "://").? + 3 ..];
    if (h.len > 0 and h[0] == '[') {
        const close = std.mem.indexOfScalar(u8, h, ']') orelse return null;
        return h[0 .. close + 1];
    }
    if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| h = h[0..c];
    return if (h.len == 0) null else h;
}

/// 쿠키 domain 이 그 호스트 자신인가(`host`·`.host` — 대소문자 무시).
fn sameHost(domain: []const u8, host: []const u8) bool {
    const d = if (domain.len > 0 and domain[0] == '.') domain[1..] else domain;
    return d.len > 0 and std.ascii.eqlIgnoreCase(d, host);
}

fn freeKey(gpa: std.mem.Allocator, c: CookieKey) void {
    gpa.free(c.name);
    gpa.free(c.domain);
    gpa.free(c.path);
    if (c.partition) |p| gpa.free(p);
}

fn dupeString(gpa: std.mem.Allocator, v: std.json.Value) ![]u8 {
    if (v != .string) return error.InvalidArg;
    return gpa.dupe(u8, v.string);
}

fn call(gpa: std.mem.Allocator, method: []const u8, params: []const u8) !Step {
    return .{ .call = .{ .method = method, .params = try gpa.dupe(u8, params) } };
}

fn cdpMessage(e: []const u8) []const u8 {
    const key = "\"message\":\"";
    const at = std.mem.indexOf(u8, e, key) orelse return e;
    const rest = e[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return e;
    return rest[0..end];
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectDone(step: Step, status: Status, result: []const u8) !void {
    try testing.expect(step == .done);
    defer testing.allocator.free(step.done.result);
    try testing.expectEqual(status, step.done.status);
    try testing.expectEqualStrings(result, step.done.result);
}

fn expectCall(step: Step, method: []const u8) ![]u8 {
    try testing.expect(step == .call);
    try testing.expectEqualStrings(method, step.call.method);
    return step.call.params;
}

test "W9a③ 출처·호스트: http(s) 만, 기본 포트·IPv6·userinfo" {
    try testing.expectEqualStrings("https://a.test", originOf("https://a.test/x?y").?);
    try testing.expectEqualStrings("http://127.0.0.1:8080", originOf("http://127.0.0.1:8080/").?);
    try testing.expect(originOf("about:blank") == null and originOf("data:text/html,x") == null and originOf("http://u@a.test/") == null);
    try testing.expectEqualStrings("a.test", hostOf("https://a.test:8443/").?);
    try testing.expectEqualStrings("[::1]", hostOf("http://[::1]:8080/").?);
    try testing.expectEqualStrings("http://a.test", stripDefaultPort("http://a.test:80"));
    try testing.expect(sameHost(".A.test", "a.test") and sameHost("a.test", "a.test") and !sameHost("test", "a.test") and !sameHost(".b.a.test", "a.test"));
}

test "W9a③ localStorage: 출처를 본 뒤 격리 world 에서 Storage.prototype 으로 — 없는 키는 빈 글, 다른 출처로 옮겼으면 실패, about:blank 는 거절" {
    const gpa = testing.allocator;
    {
        var op = try Op.init(gpa, .get_local_storage, "{\"key\":\"k\\\"q\"}");
        defer op.deinit(gpa);
        op.doc_url = "http://a.test:8080/p";
        gpa.free(try expectCall(try op.start(gpa), "Page.getFrameTree"));
        const w = try expectCall(try op.feed(gpa, .{ .ok = "{\"frameTree\":{\"frame\":{\"id\":\"F1\",\"securityOrigin\":\"http://a.test:8080\"}}}" }), "Page.createIsolatedWorld");
        defer gpa.free(w);
        try testing.expect(std.mem.indexOf(u8, w, "\"frameId\":\"F1\"") != null);
        const e = try expectCall(try op.feed(gpa, .{ .ok = "{\"executionContextId\":7}" }), "Runtime.evaluate");
        defer gpa.free(e);
        try testing.expect(std.mem.indexOf(u8, e, "Storage.prototype.getItem.call(localStorage,k)") != null);
        try testing.expect(std.mem.indexOf(u8, e, "\"contextId\":7") != null);
        try expectDone(try op.feed(gpa, .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"v1\"}}" }), .success, "v1");
    }
    {
        var op = try Op.init(gpa, .get_local_storage, "{\"key\":\"k\"}");
        defer op.deinit(gpa);
        op.doc_url = "https://a.test/";
        gpa.free((try op.start(gpa)).call.params);
        gpa.free((try op.feed(gpa, .{ .ok = "{\"frameTree\":{\"frame\":{\"id\":\"F\",\"securityOrigin\":\"https://a.test\"}}}" })).call.params);
        gpa.free((try op.feed(gpa, .{ .ok = "{\"executionContextId\":1}" })).call.params);
        try expectDone(try op.feed(gpa, .{ .ok = "{\"result\":{\"type\":\"object\",\"subtype\":\"null\",\"value\":null}}" }), .success, "");
    }
    {
        var op = try Op.init(gpa, .set_local_storage, "{\"key\":\"k\",\"value\":\"v\"}");
        defer op.deinit(gpa);
        op.doc_url = "https://a.test/";
        gpa.free((try op.start(gpa)).call.params);
        // 그사이 다른 출처로 옮겨 갔다.
        try expectDone(try op.feed(gpa, .{ .ok = "{\"frameTree\":{\"frame\":{\"id\":\"F\",\"securityOrigin\":\"https://b.test\"}}}" }), .failed, origin_moved_reason);
    }
    {
        var op = try Op.init(gpa, .remove_local_storage, "{\"key\":\"k\"}");
        defer op.deinit(gpa);
        op.doc_url = "about:blank";
        try expectDone(try op.start(gpa), .failed, not_http_reason);
    }
    try testing.expectError(error.InvalidArg, Op.init(gpa, .set_local_storage, "{\"key\":\"k\"}"));
}

test "W9a③ 쿠키 읽기: 문서 주소로만 묻고 WebKit 모양으로 — 세션 쿠키는 expires 없음" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .get_cookies, "");
    defer op.deinit(gpa);
    op.doc_url = "http://a.test/p/q";
    const p = try expectCall(try op.start(gpa), "Network.getCookies");
    defer gpa.free(p);
    try testing.expectEqualStrings("{\"urls\":[\"http://a.test/p/q\"]}", p);
    try expectDone(try op.feed(gpa, .{ .ok = "{\"cookies\":[{\"name\":\"s\",\"value\":\"1\",\"domain\":\"a.test\",\"path\":\"/\",\"expires\":-1,\"size\":2,\"httpOnly\":true,\"secure\":false,\"session\":true,\"sameSite\":\"Lax\",\"priority\":\"Medium\"},{\"name\":\"p\",\"value\":\"2\",\"domain\":\".a.test\",\"path\":\"/p\",\"expires\":1900000000.5,\"httpOnly\":false,\"secure\":true,\"session\":false}]}" }), .success, "[{\"name\":\"s\",\"value\":\"1\",\"domain\":\"a.test\",\"path\":\"/\",\"secure\":false,\"httpOnly\":true,\"sameSite\":\"lax\"},{\"name\":\"p\",\"value\":\"2\",\"domain\":\".a.test\",\"path\":\"/p\",\"secure\":true,\"httpOnly\":false,\"expires\":1900000000.5}]");
    var blank = try Op.init(gpa, .get_cookies, "");
    defer blank.deinit(gpa);
    blank.doc_url = "about:blank";
    try expectDone(try blank.start(gpa), .success, "[]");
}

test "W9a③ 쿠키 쓰기: domain 은 그 호스트 자신만, path 기본 /, success:false 는 실패" {
    const gpa = testing.allocator;
    {
        var op = try Op.init(gpa, .set_cookie, "{\"name\":\"n\",\"value\":\"v\",\"domain\":\".A.test\",\"secure\":true}");
        defer op.deinit(gpa);
        op.doc_url = "https://a.test/x";
        const p = try expectCall(try op.start(gpa), "Network.setCookie");
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"name\":\"n\",\"value\":\"v\",\"url\":\"https://a.test/x\",\"domain\":\".A.test\",\"path\":\"/\",\"secure\":true}", p);
        try expectDone(try op.feed(gpa, .{ .ok = "{\"success\":true}" }), .success, "");
    }
    {
        var op = try Op.init(gpa, .set_cookie, "{\"name\":\"n\",\"value\":\"v\"}");
        defer op.deinit(gpa);
        op.doc_url = "https://a.test/x";
        gpa.free((try op.start(gpa)).call.params);
        try expectDone(try op.feed(gpa, .{ .ok = "{\"success\":false}" }), .failed, set_cookie_failed);
    }
    for ([_][]const u8{ "test", "b.a.test", ".github.io" }) |d| {
        const arg = try std.fmt.allocPrint(gpa, "{{\"name\":\"n\",\"value\":\"v\",\"domain\":\"{s}\"}}", .{d});
        defer gpa.free(arg);
        var op = try Op.init(gpa, .set_cookie, arg);
        defer op.deinit(gpa);
        op.doc_url = "https://a.test/";
        try expectDone(try op.start(gpa), .failed, cookie_domain_reason);
    }
}

test "W9a③ 쿠키 지우기: 그 path 로 읽어 이름·path·호스트로 거른 뒤 받은 정확한 키로 하나씩 — 부모 도메인 쿠키는 두고, 하나를 못 지워도 나머지는 지운 뒤 실패로 답한다" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .delete_cookie, "{\"name\":\"s\",\"path\":\"/p\"}");
    defer op.deinit(gpa);
    op.doc_url = "https://a.test/x";
    const r = try expectCall(try op.start(gpa), "Network.getCookies");
    defer gpa.free(r);
    try testing.expectEqualStrings("{\"urls\":[\"https://a.test/p\"]}", r);
    const cookies = "{\"cookies\":[{\"name\":\"s\",\"domain\":\"a.test\",\"path\":\"/p\"},{\"name\":\"s\",\"domain\":\".a.test\",\"path\":\"/p\",\"partitionKey\":{\"topLevelSite\":\"https://a.test\",\"hasCrossSiteAncestor\":false}},{\"name\":\"s\",\"domain\":\".test\",\"path\":\"/p\"},{\"name\":\"s\",\"domain\":\"a.test\",\"path\":\"/\"},{\"name\":\"t\",\"domain\":\"a.test\",\"path\":\"/p\"}]}";
    const d1 = try expectCall(try op.feed(gpa, .{ .ok = cookies }), "Network.deleteCookies");
    defer gpa.free(d1);
    try testing.expect(op.committed());
    try testing.expectEqualStrings("{\"name\":\"s\",\"domain\":\".a.test\",\"path\":\"/p\",\"partitionKey\":{\"topLevelSite\":\"https://a.test\",\"hasCrossSiteAncestor\":false}}", d1);
    const d2 = try expectCall(try op.feed(gpa, .{ .cdp_error = "{\"code\":-32000,\"message\":\"x\"}" }), "Network.deleteCookies");
    defer gpa.free(d2);
    try testing.expectEqualStrings("{\"name\":\"s\",\"domain\":\"a.test\",\"path\":\"/p\"}", d2);
    // 하나를 못 지웠다 — 나머지는 지우고 끝에 실패로(적대 리뷰 1 회차: 전에는 ok).
    try expectDone(try op.feed(gpa, .{ .ok = "{}" }), .failed, "1 of 2 cookies could not be deleted (DevTools refused the delete)");
    var parent = try Op.init(gpa, .delete_cookie, "{\"name\":\"s\",\"domain\":\"test\"}");
    defer parent.deinit(gpa);
    parent.doc_url = "https://a.test/";
    try expectDone(try parent.start(gpa), .failed, cookie_domain_reason);
}

test "W9a③ clearStorage: 그 출처의 저장소 전부 + 문서 주소·뿌리에 보이는 그 호스트의 쿠키를 한 번씩, 웹 출처가 없으면 할 것 없음" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .clear_storage, "");
    defer op.deinit(gpa);
    op.doc_url = "https://a.test:8443/x/y";
    const c = try expectCall(try op.start(gpa), "Storage.clearDataForOrigin");
    defer gpa.free(c);
    try testing.expectEqualStrings("{\"origin\":\"https://a.test:8443\",\"storageTypes\":\"all\"}", c);
    const r = try expectCall(try op.feed(gpa, .{ .ok = "{}" }), "Network.getCookies");
    defer gpa.free(r);
    try testing.expectEqualStrings("{\"urls\":[\"https://a.test:8443/x/y\",\"https://a.test:8443/\"]}", r);
    const d1 = try expectCall(try op.feed(gpa, .{ .ok = "{\"cookies\":[{\"name\":\"a\",\"domain\":\"a.test\",\"path\":\"/\"},{\"name\":\"a\",\"domain\":\"a.test\",\"path\":\"/\"},{\"name\":\"p\",\"domain\":\".test\",\"path\":\"/\"},{\"name\":\"b\",\"domain\":\".a.test\",\"path\":\"/x\"}]}" }), "Network.deleteCookies");
    gpa.free(d1);
    const d2 = try expectCall(try op.feed(gpa, .{ .ok = "{}" }), "Network.deleteCookies");
    gpa.free(d2);
    try expectDone(try op.feed(gpa, .{ .ok = "{}" }), .success, "");
    var blank = try Op.init(gpa, .clear_storage, "");
    defer blank.deinit(gpa);
    blank.doc_url = "about:blank";
    try expectDone(try blank.start(gpa), .success, "");
}

fn r1FreeStep(s: Step) void {
    switch (s) {
        .call => |c| testing.allocator.free(c.params),
        .done => |d| testing.allocator.free(d.result),
        else => {},
    }
}

test "W9a③ 적대 리뷰 1 회차 재현 R1-A: every deleteCookies fails (sidecar gone / tab busy) but deleteCookie answers success" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .delete_cookie, "{\"name\":\"s\"}");
    defer op.deinit(gpa);
    op.doc_url = "https://a.test/";
    r1FreeStep(try op.start(gpa));
    const cookies = "{\"cookies\":[{\"name\":\"s\",\"domain\":\"a.test\",\"path\":\"/\"},{\"name\":\"s\",\"domain\":\".a.test\",\"path\":\"/\"}]}";
    var step = try op.feed(gpa, .{ .ok = cookies });
    while (step == .call) {
        r1FreeStep(step);
        step = try op.feed(gpa, .{ .not_sent = "the Chromium tab is not ready (it has not been shown yet, or its engine is restarting)" });
    }
    defer r1FreeStep(step);
    try testing.expectEqual(Status.failed, step.done.status); // expected: not success — nothing was deleted
}

test "W9a③ 적대 리뷰 1 회차 재현 R1-A2: clearStorage — every delete fails yet success" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .clear_storage, "");
    defer op.deinit(gpa);
    op.doc_url = "https://a.test/";
    r1FreeStep(try op.start(gpa));
    r1FreeStep(try op.feed(gpa, .{ .ok = "{}" }));
    var step = try op.feed(gpa, .{ .ok = "{\"cookies\":[{\"name\":\"sid\",\"domain\":\".a.test\",\"path\":\"/\"}]}" });
    while (step == .call) {
        r1FreeStep(step);
        step = try op.feed(gpa, .{ .failed = "the Chromium engine stopped" });
    }
    defer r1FreeStep(step);
    try testing.expectEqual(Status.failed, step.done.status);
}

test "W9a③ 적대 리뷰 1 회차 재현 R1-B: same name/domain/path in two partitions — only one deleteCookies is sent" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .delete_cookie, "{\"name\":\"dup\"}");
    defer op.deinit(gpa);
    op.doc_url = "http://a.test/";
    r1FreeStep(try op.start(gpa));
    const cookies = "{\"cookies\":[{\"name\":\"dup\",\"domain\":\"a.test\",\"path\":\"/\"},{\"name\":\"dup\",\"domain\":\"a.test\",\"path\":\"/\",\"partitionKey\":{\"topLevelSite\":\"http://a.test\",\"hasCrossSiteAncestor\":false}}]}";
    var step = try op.feed(gpa, .{ .ok = cookies });
    var n: usize = 0;
    while (step == .call) {
        n += 1;
        r1FreeStep(step);
        step = try op.feed(gpa, .{ .ok = "{}" });
    }
    r1FreeStep(step);
    try testing.expectEqual(@as(usize, 2), n);
}

test "W9a③ 적대 리뷰 1 회차 재현 R1-C: deleteCookie domain \".a.test\" also deletes the host-only a.test cookie (WebKit keeps it)" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .delete_cookie, "{\"name\":\"s\",\"domain\":\".a.test\"}");
    defer op.deinit(gpa);
    op.doc_url = "https://a.test/";
    r1FreeStep(try op.start(gpa));
    const step = try op.feed(gpa, .{ .ok = "{\"cookies\":[{\"name\":\"s\",\"domain\":\"a.test\",\"path\":\"/\"}]}" });
    defer r1FreeStep(step);
    if (step == .call)
        try testing.expect(step == .done); // WebKit: c.domain != rd && c.domain != "."+rd -> not matched
}

test "W9a③ 적대 리뷰 1 회차 재현: sameSite 는 WebKit 처럼 소문자, 긴 localStorage 값은 그것의 상한 글로" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .get_cookies, "");
    defer op.deinit(gpa);
    op.doc_url = "http://a.test/";
    gpa.free((try op.start(gpa)).call.params);
    try expectDone(try op.feed(gpa, .{ .ok = "{\"cookies\":[{\"name\":\"s\",\"value\":\"1\",\"domain\":\"a.test\",\"path\":\"/\",\"httpOnly\":false,\"secure\":false,\"session\":true,\"sameSite\":\"Strict\"}]}" }), .success, "[{\"name\":\"s\",\"value\":\"1\",\"domain\":\"a.test\",\"path\":\"/\",\"secure\":false,\"httpOnly\":false,\"sameSite\":\"strict\"}]");
    const big = try gpa.alloc(u8, 70 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    const arg = try std.fmt.allocPrint(gpa, "{{\"key\":\"k\",\"value\":\"{s}\"}}", .{big});
    defer gpa.free(arg);
    try testing.expectError(error.StorageValueTooLarge, Op.init(gpa, .set_local_storage, arg));
}
