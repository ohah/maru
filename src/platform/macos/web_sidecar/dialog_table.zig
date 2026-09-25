//! 답을 기다리는 대화상자·파일 선택(W5a)·권한(W5b) 요청 — C6 — 의 표. CEF 를 모르는 순수 부분이라 CEF 없이 시험한다 — 콜백·경로 목록은
//! 불투명 포인터로만 든다(푸는 것은 `dialogs.zig`).
//!
//! 번호는 sidecar 전체에서 매긴다(0 은 「없음」이라 건너뛴다). 답은 (브라우저, 번호, 종류)가 모두 맞아야 짝을 찾는다 — 다른
//! 브라우저·다른 종류의 번호로 온 답(늦게 온 답·위조)은 버린다. 표가 차면 새 요청을 받지 않는다(호출자가 억제로 답한다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;
const RequestId = protocol.message.RequestId;

/// 동시에 답을 기다리는 요청 상한. JS 대화상자는 브라우저마다 한 번에 하나라(페이지가 멈춘다) 브라우저 상한(registry)보다
/// 넉넉하면 된다.
pub const capacity = 64;
/// 파일 선택 하나에 받는 경로 상한 — maru 가 이보다 많이 보내면 뒤는 버린다(끝없이 쌓지 않게).
pub const max_paths = 4096;

/// 권한 요청(프롬프트·미디어)은 한 브라우저가 이만큼만 동시에 기다리게 한다 — 페이지가 요청을 쏟아 표를 채우면 다른 탭의 JS
/// 대화상자까지 못 묻는다(표는 sidecar 전체가 나눠 쓴다).
pub const max_permissions_per_browser = 8;

pub const Kind = enum {
    js,
    file,
    /// `on_show_permission_prompt` — CEF 가 준 `prompt_id` 를 `extra` 에 둔다(닫힘 알림이 이 번호로 온다).
    prompt,
    /// `on_request_media_access_permission` — 청한 미디어 비트를 `extra` 에 둔다(허용하면 그대로 돌려준다).
    media,

    pub fn isPermission(self: Kind) bool {
        return self == .prompt or self == .media;
    }
};

pub const Entry = struct {
    browser: BrowserId,
    request: RequestId,
    kind: Kind,
    /// CEF 콜백(`cef_jsdialog_callback_t` 또는 `cef_file_dialog_callback_t`) — 참조 하나를 쥔다.
    callback: *anyopaque,
    /// 파일 선택이 받은 경로 목록(`cef_string_list_t`) — 첫 경로에 만든다.
    paths: ?*anyopaque = null,
    path_count: u32 = 0,
    extra: u64 = 0,
};

pub const Table = struct {
    entries: [capacity]?Entry = [_]?Entry{null} ** capacity,
    next: RequestId = 1,

    /// 새 요청을 적고 번호를 돌려준다. 가득 차면 null.
    pub fn add(self: *Table, browser: BrowserId, kind: Kind, callback: *anyopaque) ?RequestId {
        const slot = for (&self.entries) |*slot| {
            if (slot.* == null) break slot;
        } else return null;
        const request = self.next;
        self.next +%= 1;
        if (self.next == 0) self.next = 1;
        slot.* = .{ .browser = browser, .request = request, .kind = kind, .callback = callback };
        return request;
    }

    /// 권한 요청을 적는다 — 그 브라우저가 이미 `max_permissions_per_browser` 만큼 기다리면 받지 않는다.
    pub fn addPermission(self: *Table, browser: BrowserId, kind: Kind, callback: *anyopaque, extra: u64) ?RequestId {
        std.debug.assert(kind.isPermission());
        var waiting: usize = 0;
        for (self.entries) |slot| {
            if (slot) |entry| if (entry.browser == browser and entry.kind.isPermission()) {
                waiting += 1;
            };
        }
        if (waiting >= max_permissions_per_browser) return null;
        const request = self.add(browser, kind, callback) orelse return null;
        self.find(browser, request, kind).?.extra = extra;
        return request;
    }

    /// CEF 가 닫은 프롬프트(`prompt_id`)를 찾는다.
    pub fn findPrompt(self: *Table, browser: BrowserId, prompt_id: u64) ?*Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.browser == browser and entry.kind == .prompt and entry.extra == prompt_id) return entry;
            }
        }
        return null;
    }

    pub fn find(self: *Table, browser: BrowserId, request: RequestId, kind: Kind) ?*Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.browser == browser and entry.request == request and entry.kind == kind) return entry;
            }
        }
        return null;
    }

    /// 표에서 빼고 돌려준다(콜백·목록을 푸는 것은 호출자).
    pub fn take(self: *Table, entry: *Entry) Entry {
        const value = entry.*;
        for (&self.entries) |*slot| {
            if (slot.*) |*candidate| if (candidate == entry) {
                slot.* = null;
                break;
            };
        }
        return value;
    }

    /// 그 브라우저의 `kind` 요청을 하나 빼서 돌려준다(없으면 null) — 브라우저를 닫거나 대화상자 상태를 비울 때 되풀이해 부른다.
    /// `kind` 가 null 이면 종류를 가리지 않는다.
    pub fn takeFor(self: *Table, browser: BrowserId, kind: ?Kind) ?Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (entry.browser == browser and (kind == null or entry.kind == kind.?)) {
                    slot.* = null;
                    return entry;
                }
            }
        }
        return null;
    }

    /// 브라우저를 가리지 않고 하나 뺀다(종료).
    pub fn takeAny(self: *Table) ?Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                slot.* = null;
                return entry;
            }
        }
        return null;
    }

    pub fn count(self: *const Table) usize {
        var n: usize = 0;
        for (self.entries) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }
};

var fake_callbacks: [capacity + 1]u8 = undefined;
fn fake(i: usize) *anyopaque {
    return @ptrCast(&fake_callbacks[i]);
}

test "requests get non-zero numbers, answers must match browser, number and kind, and a full table refuses" {
    var table: Table = .{};
    const a = table.add(7, .js, fake(0)).?;
    const b = table.add(8, .file, fake(1)).?;
    try std.testing.expect(a != 0 and b != 0 and a != b);
    // 다른 브라우저·다른 종류로 온 답은 짝이 없다(늦은 답·위조).
    try std.testing.expect(table.find(8, a, .js) == null);
    try std.testing.expect(table.find(7, a, .file) == null);
    const entry = table.find(7, a, .js).?;
    try std.testing.expectEqual(fake(0), table.take(entry).callback);
    try std.testing.expect(table.find(7, a, .js) == null);
    // 가득 차면 null — 빈자리가 생기면 다시 받는다.
    var i: usize = 0;
    while (table.count() < capacity) : (i += 1) _ = table.add(9, .js, fake(0)).?;
    try std.testing.expect(table.add(9, .js, fake(0)) == null);
    _ = table.takeFor(9, .js).?;
    try std.testing.expect(table.add(9, .js, fake(0)) != null);
}

test "permission requests are capped per browser so one page cannot fill the shared table, and prompts are found by CEF's id" {
    var table: Table = .{};
    for (0..max_permissions_per_browser) |i| _ = table.addPermission(1, if (i % 2 == 0) .prompt else .media, fake(0), 100 + i).?;
    try std.testing.expect(table.addPermission(1, .prompt, fake(0), 999) == null);
    // 다른 브라우저·JS 대화상자는 여전히 받는다.
    try std.testing.expect(table.addPermission(2, .media, fake(0), 3) != null);
    try std.testing.expect(table.add(1, .js, fake(0)) != null);
    // 프롬프트 번호로 찾는다 — 미디어의 `extra`(비트)나 다른 브라우저의 같은 값에 걸리지 않는다.
    try std.testing.expectEqual(@as(u64, 102), table.findPrompt(1, 102).?.extra);
    try std.testing.expect(table.findPrompt(1, 101) == null);
    try std.testing.expect(table.findPrompt(2, 102) == null);
    _ = table.take(table.findPrompt(1, 102).?);
    try std.testing.expect(table.addPermission(1, .prompt, fake(0), 7) != null);
}

test "numbering wraps past zero, and closing a browser takes only its requests" {
    var table: Table = .{ .next = std.math.maxInt(RequestId) };
    try std.testing.expectEqual(std.math.maxInt(RequestId), table.add(1, .js, fake(0)).?);
    try std.testing.expectEqual(@as(RequestId, 1), table.add(2, .js, fake(1)).?);
    _ = table.add(1, .file, fake(2)).?;
    // 대화상자 상태 비우기는 JS 요청만, 브라우저 닫기는 전부.
    try std.testing.expectEqual(Kind.js, table.takeFor(1, .js).?.kind);
    try std.testing.expect(table.takeFor(1, .js) == null);
    try std.testing.expectEqual(Kind.file, table.takeFor(1, null).?.kind);
    try std.testing.expect(table.takeFor(1, null) == null);
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expectEqual(@as(BrowserId, 2), table.takeAny().?.browser);
    try std.testing.expect(table.takeAny() == null);
}
