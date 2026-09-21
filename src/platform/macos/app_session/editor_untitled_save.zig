//! **이름 없는 문서를 저장한다**(U2 — docs/plans/editor-untitled.md).
//! 계약은 [문서 모델](../../../docs/native-editor-document-model.md) §3.11 이 소유한다.
//!
//! **왜 따로 있나.** 이 일은 「이름 묻기」 하나가 아니라 **다섯 판정**이다: base 디렉터리를 어디서
//! 얻는가 · 사용자가 준 이름이 그 아래인가 · 그 경로로 이미 열린 Term 이 있는가 · 디스크에 파일이
//! 있는가(덮어쓸지 묻는다) · 쓰기가 성공했나. `saveDocument` 안에 풀어 두면 그 함수가 두 문서 종류의
//! 규칙을 함께 들게 되고, 다섯 중 하나가 틀렸을 때 어디서 틀렸는지 판정이 서지 않는다.

const std = @import("std");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const dock_panel = maru.session.dock_panel;
const editor_ops = @import("editor.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const settings_ops = @import("settings.zig");
const file_panel_ops = @import("file_panel.zig");
const workspace_ops = @import("workspace.zig");

/// 확인을 사이에 두고 **고른 이름을 들고 있는 자리**. 오버레이는 한 번에 하나뿐이라 이름 상자를 닫고
/// 확인을 띄우므로, 그 사이 경로를 어딘가 둬야 한다 — 안 두면 확인을 수락한 순간 쓸 곳을 잃는다.
///
/// **포인터가 아니라 `surface_id` 다**(심볼 이름 바꾸기와 같은 이유) — 확인이 떠 있는 동안 그 Term 이
/// 닫히면 포인터는 낡는다. 못 찾으면 그냥 아무 일도 안 한다.
pub const Pending = struct {
    surface_id: u64 = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn path(self: *const Pending) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// 이름 없는 문서의 `⌘S` — 이름을 묻는다(§3.11). 물을 수 없으면 **그 이유를 말하고** 거짓을 준다.
pub fn begin(self: *AppSession, term: *Term) bool {
    if (term.rt.editor_untitled == null) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (baseDir(self, &buf) == null) {
        // **어디에 쓸지 모르는 채로 쓰지 않는다.** 트리 루트도 없고 활성 pane 의 cwd 도 못 쓰는 상태
        // (원격이거나 관측이 없다)면 이름을 물어도 그 이름을 놓을 자리가 없다.
        self.showNoticeKey(.editor_untitled_no_base);
        return false;
    }
    settings_ops.startRename(self, .{ .untitled_save = term.surface.id });
    return true;
}

/// base 디렉터리 — **세 단계**다: 파일 트리의 첫 루트 → 활성 pane 의 작업 디렉터리 → 워크스페이스
/// 루트(§3.11).
///
/// ⚠️ **원격 cwd 는 건너뛴다.** 활성 pane 이 SSH 면 그 cwd 는 저쪽 경로이고, 그것을 로컬 base 로 쓰면
/// 저쪽 경로를 이쪽 디스크에 만든다(워크스페이스가 「원격 cwd 는 저장하지 않는다」고 정한 그 사고와
/// 같은 모양). 저쪽에 쓰는 일은 U3 이 소유한다.
///
/// **거기서 멈추지 않는다.** 원격 pane 에서 `null` 을 내면 「저장할 폴더가 없다」가 되는데, 사실은
/// 로컬 워크스페이스 루트가 늘 있다(설정값 → launch cwd → HOME). 물러날 자리가 있는데 거절하면
/// 사용자는 이유 없이 막힌다 — 그래서 **마지막 단계까지 간다**. `null` 은 그 셋이 전부 없을 때뿐이다
/// (세션이 아직 안 섰거나 HOME 조차 없는 자리).
pub fn baseDir(self: *AppSession, buf: []u8) ?[]const u8 {
    if (self.file_tree.roots.items.len > 0) {
        const root = self.file_tree.roots.items[0].path;
        if (root.len > 0 and root.len <= buf.len) {
            @memcpy(buf[0..root.len], root);
            return buf[0..root.len];
        }
    }
    if (self.surface_initialized and self.tabs.items.len > 0) {
        const term = pane_ops.activePane(self).activeTerm();
        if (!app_session_mod.termCwdIsRemote(term)) {
            if (term_ops.newSurfaceCwd(self, buf, true)) |c| return c;
        }
    }
    if (workspace_ops.workspaceRootCwd(self, buf)) |c| return c;
    // ⚠️ **그 함수의 `null` 은 「없다」가 아니다 — 「물려받은 cwd 를 쓰라」다**(spawn 의미: 설정값이
    // 없고 launch cwd 가 정상이면 자식이 그것을 그대로 물려받으므로 명시할 필요가 없다). 그것을
    // 「폴더가 없다」로 읽으면 **가장 흔한 설정에서 ⌘S 가 아무 일도 안 한다**(workspace.root 미설정 +
    // 정상 cwd). 판정자 U1e 가 그것을 잡았다 — 그래서 여기서 그 cwd 를 **명시로** 집는다.
    // `detectLaunchCwdIsRoot` 가 쓰는 그 함수다 — 이 저장소에서 「프로세스의 cwd」를 묻는 자리는
    // 이것 하나다(`realPath` 는 테스트 환경에서 실패했다, 실측).
    const n = std.process.currentPath(self.io, buf) catch return null;
    return buf[0..n];
}

/// 사용자가 준 이름을 base 아래의 절대 경로로 푼다. **base 밖이면 `null`** — `..` 도 절대 경로도
/// 거절한다(판정은 새로 짓지 않고 `repo_path.underRoot` 를 쓴다).
pub fn resolve(base: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.fs.path.isAbsolute(name)) return null; // 절대 경로는 base 를 무시한다
    // 끝이 구분자면 디렉터리를 가리킨다 — 파일 이름이 없다.
    if (name[name.len - 1] == '/') return null;
    const joined = std.fmt.bufPrint(out, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), name }) catch return null;
    // `..` 를 문자로 거르지 않고 **푼 결과가 base 아래인지** 본다 — 문자 검사는 `a/../../b` 처럼
    // 갈아입으면 샌다. 다만 `realpath` 는 아직 없는 파일에 못 쓰므로 어휘적으로 정규화한다.
    var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const norm = normalize(joined, &norm_buf) orelse return null;
    if (!maru.session.repo_path.underRoot(norm, base)) return null;
    if (norm.len > out.len) return null;
    @memcpy(out[0..norm.len], norm);
    return out[0..norm.len];
}

/// 절대 경로를 **어휘적으로** 정규화한다(`.`·`..`·중복 `/` 제거). 파일이 아직 없어 `realpath` 를
/// 못 쓰는 자리라 여기서 푼다. 루트 위로 올라가려 하면 `null`.
fn normalize(path: []const u8, out: []u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) return null;
    var parts: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n == 0) return null; // 루트 위로 — 거절한다
            n -= 1;
            continue;
        }
        if (n >= parts.len) return null;
        parts[n] = seg;
        n += 1;
    }
    if (n == 0) return null; // `/` 자체는 파일 이름이 아니다
    var len: usize = 0;
    for (parts[0..n]) |seg| {
        if (len + 1 + seg.len > out.len) return null;
        out[len] = '/';
        len += 1;
        @memcpy(out[len .. len + seg.len], seg);
        len += seg.len;
    }
    return out[0..len];
}

/// 이름 상자를 확정했다 — 위 다섯 판정을 순서대로 지난다.
pub fn commit(self: *AppSession, surface_id: u64, text: []const u8) void {
    defer settings_ops.closeRename(self);
    const term = termFor(self, surface_id) orelse return;
    if (term.rt.editor_untitled == null) return; // 그 사이 이름이 붙었다

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = baseDir(self, &base_buf) orelse {
        self.showNoticeKey(.editor_untitled_no_base);
        return;
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = resolve(base, std.mem.trim(u8, text, " \t"), &path_buf) orelse {
        self.showNoticeKey(.editor_untitled_bad_name);
        return;
    };

    // **그 경로로 이미 열린 Term 이 있으면 저장하지 않는다.** 경로 유일성은 창 전체 불변식이라,
    // 허용하면 같은 파일을 든 Term 이 둘이 되어 서로의 저장을 지운다. 디스크를 덮어쓸지 묻는 것과
    // **다른 질문**이므로 확인을 띄우지 않고 그 사실을 말한다.
    if (file_panel_ops.fileTermForPath(self, abs) != null) {
        self.showNoticeKey(.editor_untitled_already_open);
        return;
    }

    if (fileExists(self, abs)) {
        // 두 단계다 — 상자를 닫고(위 defer) 확인을 띄우며 **고른 경로를 들고 있는다**.
        self.pending_untitled_save = .{ .surface_id = surface_id, .path_len = abs.len };
        @memcpy(self.pending_untitled_save.path_buf[0..abs.len], abs);
        // 버튼은 기본(확인/취소)이다 — 문구가 이미 「덮어쓸까요?」라 버튼이 그 말을 되풀이하지 않는다.
        self.showConfirmKeys(.{ .untitled_overwrite = surface_id }, .editor_untitled_overwrite, .{});
        return;
    }

    writeAndAdopt(self, term, abs, false);
}

/// 덮어쓰기 확인을 수락했다.
pub fn confirmOverwrite(self: *AppSession) void {
    const p = self.pending_untitled_save;
    self.pending_untitled_save = .{};
    if (p.path_len == 0) return;
    const term = termFor(self, p.surface_id) orelse return;
    if (term.rt.editor_untitled == null) return;
    writeAndAdopt(self, term, p.path(), true);
}

/// 쓰고, 성공하면 **보통 문서로 옮겨 간다**(§3.11). 실패하면 **이름도 안 붙인다** — 「이름은 정해졌는데
/// 내용은 없는」 중간 상태를 만들지 않는다.
fn writeAndAdopt(self: *AppSession, term: *Term, abs: []const u8, overwriting: bool) void {
    const doc = term.rt.editor_doc orelse return;
    const bytes = doc.file.saveBytes(self.allocator) catch {
        self.showNoticeKey(.app_save_failed);
        return;
    };
    defer self.allocator.free(bytes);
    const saved_content = doc.file.content;

    // **새 파일과 덮어쓰기는 다른 함수다.** 새 파일은 원본이 없어 CAS 를 걸 수 없고 대신 **배타 생성**
    // 으로 「그 사이에 생긴 파일」을 커널이 막는다. 덮어쓰기는 원본이 있으니 기존 CAS 경로를 그대로
    // 탄다 — 그쪽 방어(부모 핀·RENAME_SWAP·inode 검증)를 다시 짜지 않는다.
    const ok = if (overwriting)
        editor_ops.writeDocumentBytes(self, abs, bytes)
    else
        editor_ops.createDocumentBytes(self, abs, bytes);
    if (!ok) {
        self.showNoticeKey(.app_save_failed);
        return;
    }

    // **여기부터 실패해도 파일은 이미 있다** — 그래서 실패할 수 있는 일(경로 복사·entry 생성)을
    // 쓰기 **앞에** 둘 수 없다: 그것이 성공하고 쓰기가 실패하면 「경로는 붙었는데 파일이 없는」
    // 중간 상태가 된다. 순서를 뒤집는 대가는 아래 OOM 갈래가 **파일은 남기고 표식만 못 옮기는** 것이고,
    // 그때는 그 사실을 말한다(다시 `⌘S` 하면 같은 이름으로 이어진다).
    // ⚠️ **경로를 두 벌 소유한다.** `editor_path` 는 `releaseEditorTerm` 이 놓고 `entry.path` 는 세션이
    // 놓는다 — 하나를 둘이 가리키면 **이중 해제**다(파일을 여는 길도 그래서 각자 dupe 한다).
    const owned = self.allocator.dupe(u8, abs) catch {
        self.showNoticeKey(.app_save_failed);
        return;
    };
    const entry_path = self.allocator.dupe(u8, abs) catch {
        self.allocator.free(owned);
        self.showNoticeKey(.app_save_failed);
        return;
    };
    _ = attachEntry(self, term, entry_path) catch {
        self.allocator.free(entry_path);
        self.allocator.free(owned);
        self.showNoticeKey(.app_save_failed);
        return;
    };

    term.rt.editor_path = owned;
    term.rt.editor_untitled = null; // **배타다**(§3.11) — 안 지우면 영원히 「저장 안 한 문서」다
    term.rt.editor_doc.?.saved_hash = editor_ops.contentHash(saved_content);

    // **문법을 다시 판정한다**(§3.11 — 경로가 생겼다). 옛 상태는 grammar 가 없어 비어 있지만
    // 그래도 같은 자리에서 놓는다(두 벌이 되면 한쪽이 새는 길이 생긴다).
    term.rt.editor_syntax.deinit(self.allocator);
    term.rt.editor_grammar = maru.session.editor.language.grammarForPath(owned);
    term.rt.editor_syntax = editor_ops.syntax_color.open(
        term.rt.editor_doc.?.file.content,
        term.rt.editor_grammar,
    );
    self.metal_dirty = true;
    // **`.persisted_surface` 다 — `.naming` 이 아니다.** 이름이 바뀐 것이 아니라 **영속되는 surface 가
    // 하나 생겼다**(이제 workspace 저장 시퀀스에 든다). 선례는 파일 Term 생성(`openFilePanelPath` 의
    // `if (opened.created)`)이고, 축이 틀리면 checkpoint 를 소비하는 쪽이 어떤 변화였는지 잘못 읽는다.
    self.workspaceChanged(.persisted_surface);
}

/// 도크 entry 를 만들어 붙인다 — **안 붙이면 workspace 저장 시퀀스 밖**이고(그 조건이 「편집기인데
/// 도크 entry 가 없다」다) 도크 목록에도 안 보인다. 즉 「보통 문서가 된다」가 거짓이 된다.
fn attachEntry(self: *AppSession, term: *Term, owned_path: []const u8) !*dock_panel.Entry {
    var count: usize = 0;
    var it = file_panel_ops.fileEntries(self);
    while (it.next()) |_| count += 1;
    if (count >= dock_panel.max_entries) return error.TooManyEntries;

    const entry = try self.allocator.create(dock_panel.Entry);
    errdefer self.allocator.destroy(entry);
    entry.* = .{
        .id = try app_session_mod.app_runtime.entry_ids.next(),
        .path = @constCast(owned_path),
        .kind = .text,
        .mode = dock_panel.Mode.defaultFor(.text),
        .native_editor = true, // 네이티브 편집기가 든 문서다(CM6 브리지 게이트를 타지 않는다)
        .surface_id = term.surface.id,
    };
    term.file_entry = entry;
    return entry;
}

fn fileExists(self: *AppSession, abs: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(self.io, abs, .{}) catch return false;
    f.close(self.io);
    return true;
}

fn termFor(self: *AppSession, surface_id: u64) ?*Term {
    if (!self.surface_initialized) return null;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (t.kind == .editor and t.surface.id == surface_id) return t;
    };
    return null;
}

const testing = std.testing;
const builtin = @import("builtin");

test "U2r 이름 풀기: base 아래만 받고 «갈아입은 ..» 도 막는다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 허용된 자리 — 이름 하나와 **base 아래 상대 경로**.
    try testing.expectEqualStrings("/w/x.zig", resolve("/w", "x.zig", &buf).?);
    try testing.expectEqualStrings("/w/sub/x.zig", resolve("/w", "sub/x.zig", &buf).?);
    try testing.expectEqualStrings("/w/x.zig", resolve("/w/", "x.zig", &buf).?); // base 끝 구분자
    try testing.expectEqualStrings("/w/a/b.zig", resolve("/w", "./a/b.zig", &buf).?);
    // **base 안에서 오르내리는 것은 된다** — 결과가 아래이기만 하면 된다.
    try testing.expectEqualStrings("/w/b.zig", resolve("/w", "a/../b.zig", &buf).?);

    // 막히는 자리.
    try testing.expect(resolve("/w", "", &buf) == null); // 빈 이름
    try testing.expect(resolve("/w", "/etc/passwd", &buf) == null); // 절대 경로
    try testing.expect(resolve("/w", "../x", &buf) == null); // base 밖
    try testing.expect(resolve("/w", "a/../../x", &buf) == null); // **갈아입은 ..**
    try testing.expect(resolve("/w", "sub/", &buf) == null); // 디렉터리를 가리킨다
    try testing.expect(resolve("/w", ".", &buf) == null); // base 자기 자신
    try testing.expect(resolve("/w", "..", &buf) == null);
    // 경계 문자를 본다 — `/w2` 는 `/w` 아래가 아니다(`underRoot` 규약).
    try testing.expect(resolve("/w", "../w2/x", &buf) == null);
}

test "U2s 정규화는 루트 위로 못 올라간다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/a/b", normalize("/a//./b", &buf).?);
    try testing.expectEqualStrings("/b", normalize("/a/../b", &buf).?);
    try testing.expect(normalize("/../b", &buf) == null); // 루트 위
    try testing.expect(normalize("relative/x", &buf) == null); // 절대 경로가 아니다
    try testing.expect(normalize("/", &buf) == null); // 파일 이름이 아니다
}
