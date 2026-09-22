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
const git_ops = @import("git.zig");
const file_panel_ops = @import("file_panel.zig");
const workspace_ops = @import("workspace.zig");

/// **저쪽 목적지를 굳힌 값**(U3). 목록·diff·쓰기가 같은 판정을 공유하도록 `remoteScmTargetFor` 가
/// 주는 셋을 그대로 든다 — 목적지·control socket·**저쪽 cwd(= base)**.
///
/// **왜 굳히나**: 물음과 이름 상자 사이에 사용자가 pane 을 옮길 수 있다. 그때 세션에서 다시 읽으면
/// **남의 기계에 쓴다**(`RemoteEndpoint` 가 같은 이유로 같은 모양을 쓴다).
pub const RemotePin = struct {
    dest_buf: [git_ops.max_remote_dest_bytes]u8 = undefined,
    dest_len: usize = 0,
    ctl_buf: [std.fs.max_path_bytes]u8 = undefined,
    ctl_len: usize = 0,
    base_buf: [std.fs.max_path_bytes]u8 = undefined,
    base_len: usize = 0,

    pub fn dest(self: *const RemotePin) []const u8 {
        return self.dest_buf[0..self.dest_len];
    }
    pub fn ctl(self: *const RemotePin) []const u8 {
        return self.ctl_buf[0..self.ctl_len];
    }
    pub fn base(self: *const RemotePin) []const u8 {
        return self.base_buf[0..self.base_len];
    }
};

/// 활성 pane 의 **터미널** Term 이 원격이면 그 목적지를 굳힌다(U3). 로컬이면 `null` — 그때는 묻지
/// 않는다(못 쓸 선택지를 보여 주면 고른 뒤에 실패한다).
///
/// ⚠️ **편집기 Term 을 묻지 않는다.** 그것은 sentinel surface 라 관측이 늘 비어 있어(판정자 U2D)
/// SSH pane 에서도 언제나 「이쪽」이 나온다. 그래서 그 pane 의 **터미널** Term 을 고른다.
pub fn pinRemote(self: *AppSession) ?RemotePin {
    if (comptime builtin.os.tag != .macos) return null;
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const pane = pane_ops.activePane(self);
    var out: RemotePin = .{};
    for (pane.terms.items) |t| {
        if (t.kind != .terminal) continue;
        const target = git_ops.remoteScmTargetFor(self, t, &out.dest_buf, &out.ctl_buf, &out.base_buf) orelse continue;
        out.dest_len = target.dest.len;
        out.ctl_len = target.ctl.len;
        out.base_len = target.cwd.len;
        return out;
    }
    return null;
}

/// 확인을 사이에 두고 **고른 이름을 들고 있는 자리**. 오버레이는 한 번에 하나뿐이라 이름 상자를 닫고
/// 확인을 띄우므로, 그 사이 경로를 어딘가 둬야 한다 — 안 두면 확인을 수락한 순간 쓸 곳을 잃는다.
///
/// **포인터가 아니라 `surface_id` 다**(심볼 이름 바꾸기와 같은 이유) — 확인이 떠 있는 동안 그 Term 이
/// 닫히면 포인터는 낡는다. 못 찾으면 그냥 아무 일도 안 한다.
pub const Pending = struct {
    surface_id: u64 = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// **저쪽에 저장하는 중이면** 굳힌 목적지(U3). `null` 이면 이쪽이다 — 목적지는 이름을 받기
    /// **전에** 정해지고(base 가 그것에 달렸다) 이름 상자·확인을 지나 쓰기까지 이 값이 따라간다.
    remote: ?RemotePin = null,

    pub fn path(self: *const Pending) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// 이름 없는 문서의 `⌘S` — 이름을 묻는다(§3.11). 물을 수 없으면 **그 이유를 말하고** 거짓을 준다.
pub fn begin(self: *AppSession, term: *Term) bool {
    if (term.rt.editor_untitled == null) return false;
    // ⚠️ **저쪽 왕복이 도는 동안에는 다시 시작하지 않는다**(U3 적대적 6회차). 이 함수는 보류를
    // **세우는** 자리라, 첫 요청이 결말을 기다리는 사이에 들어오면 그 경로를 지운다 — 그러면 결말이
    // 왔을 때 **빈 경로**를 그 문서의 신원으로 붙인다.
    //
    // **보내는 쪽도 같은 답을 한다**(in-flight 면 거절) — 그러니 여기서 멈추는 것은 규칙의 반복이
    // 아니라 **그 규칙이 보류를 지키는 자리**다. 그리고 그 사실을 말한다: 조용하면 `⌘S` 가 죽은 줄 안다.
    //
    // `remote_rename_inflight` 는 **트리 편집과 공유**하므로 「우리 것인가」를 함께 본다 —
    // 트리에서 이름을 바꾸는 중에 로컬 저장을 막으면 그것은 남의 이유로 막는 것이다.
    if (self.remote_rename_inflight and self.pending_untitled_save.remote != null) {
        self.showNoticeKey(.fp_remote_file_busy);
        return false;
    }
    // ⚠️ **저쪽 왕복이 도는 동안에는 다시 시작하지 않는다**(U3 적대적 6회차). 이 함수는 보류를
    // **세우는** 자리라, 첫 요청이 결말을 기다리는 사이에 들어오면 그 경로를 지운다 — 그러면 결말이
    // 왔을 때 **빈 경로**를 그 문서의 신원으로 붙인다(실측: `ok` 에 `path=""` 가 붙었다).
    //
    // **보내는 쪽도 같은 답을 한다**(in-flight 면 거절) — 그러니 여기서 멈추는 것이 규칙의 반복이
    // 아니라 **그 규칙이 보류를 지키는 자리**다. 그리고 그 사실을 말한다: 조용하면 `⌘S` 가 죽은 줄 안다.
    //
    // `remote_rename_inflight` 는 **트리 편집과 공유**하므로 「우리 것인가」를 함께 본다 —
    // 트리에서 이름을 바꾸는 중에 로컬 저장을 막으면 그것은 남의 이유로 막는 것이다.

    // **저쪽이 있으면 먼저 어디에 쓸지 묻는다**(U3 — §3.11 「저장 — 어디에」). 목적지가 base 를 정하므로
    // 이름보다 **앞**이다: 이름을 먼저 받으면 무엇을 기준으로 검증할지 모르는 채로 받는다.
    if (pinRemote(self)) |pin| {
        self.pending_untitled_save = .{ .surface_id = term.surface.id, .remote = pin };
        // `primary` = **저쪽**이다(그 pane 이 저쪽이라 물음이 떴다) — `primary` 가 곧 Enter 이므로
        // 「기본값이 pane 을 따른다」는 **자리 순서**로 세운다(editor-surface.md §4 의 그 규칙).
        self.showConfirmChoiceKeys(
            .{ .untitled_where = term.surface.id },
            .editor_save_where,
            .{ .primary = .btn_save_there, .alternate = .btn_save_here, .cancel = .common_cancel },
        );
        return true;
    }
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

/// 「저쪽에 저장한다」를 골랐다(U3) — 굳힌 목적지를 그대로 들고 이름 상자를 연다.
pub fn chooseThere(self: *AppSession, surface_id: u64) void {
    const p = self.pending_untitled_save;
    if (p.surface_id != surface_id or p.remote == null) return;
    const term = termFor(self, surface_id) orelse return;
    if (term.rt.editor_untitled == null) return;
    settings_ops.startRename(self, .{ .untitled_save = surface_id });
}

/// 「이 기계에 저장한다」를 골랐다 — 굳힌 목적지를 **버리고** 이쪽 base 로 간다.
pub fn chooseHere(self: *AppSession, surface_id: u64) void {
    const p = self.pending_untitled_save;
    if (p.surface_id != surface_id) return;
    self.pending_untitled_save = .{};
    const term = termFor(self, surface_id) orelse return;
    if (term.rt.editor_untitled == null) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (baseDir(self, &buf) == null) {
        self.showNoticeKey(.editor_untitled_no_base);
        return;
    }
    settings_ops.startRename(self, .{ .untitled_save = surface_id });
}

/// base 디렉터리 — **세 단계**다: 파일 트리의 첫 루트 → 활성 pane 의 작업 디렉터리 → 워크스페이스
/// 루트(§3.11).
///
/// ⚠️ **원격 cwd 는 여기서 거르지 않는다 — 아래 층이 이미 거른다.** `focusedTermCwd` 가 같은 술어
/// (`termCwdIsRemote`)로 원격 pane 의 cwd 에 `null` 을 내고, 근거도 같다(저쪽 경로를 이쪽에 쓰면 엉뚱한
/// 자리가 된다 — ssh-integration.md §9.4). 같은 판정을 여기서 한 번 더 적었다가 적대적 18회차에서
/// **관측되지 않는 중복**임이 드러났다: 지워도 아무 판정자가 죽지 않았고, 두 자리가 갈리면 한쪽이 낡는다.
/// 저쪽에 쓰는 일은 U3 이 소유한다.
///
/// **원격이어도 멈추지 않는다.** 그 단계가 `null` 이면 「저장할 폴더가 없다」가 아니라 **다음 단계로
/// 물러난다** — 로컬 워크스페이스 루트가 늘 있다(설정값 → launch cwd → HOME). 물러날 자리가 있는데
/// 거절하면 사용자는 이유 없이 막힌다. `null` 은 그 셋이 전부 없을 때뿐이다.
pub fn baseDir(self: *AppSession, buf: []u8) ?[]const u8 {
    if (self.file_tree.roots.items.len > 0) {
        const root = self.file_tree.roots.items[0].path;
        if (root.len > 0 and root.len <= buf.len) {
            @memcpy(buf[0..root.len], root);
            return buf[0..root.len];
        }
    }
    if (self.surface_initialized and self.tabs.items.len > 0) {
        if (term_ops.newSurfaceCwd(self, buf, true)) |c| return c;
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
    // ⚠️ **NUL 이 든 경로는 거절한다.** 경로 syscall 은 NUL 에서 끊기므로 `a\0b.txt` 는 실제로 **`a`** 에
    // 쓴다 — 그러면 위아래 판정(base 아래인가·이미 열려 있나·파일이 있나)이 전부 **다른 경로**를 보고
    // 지나가고, 사용자가 준 이름과 다른 파일이 덮인다. 「이름을 다듬어」 통과시키지 않는 이유는 그
    // 다듬은 이름이 사용자가 준 것이 아니기 때문이다(적대적 6회차).
    if (std.mem.indexOfScalar(u8, norm, 0) != null) return null;
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

    // **저쪽이면 base 가 그 호스트의 cwd 다**(U3). 이름 규칙은 **같은 순수 함수**가 판정한다 —
    // `resolve` 는 파일시스템을 만지지 않으므로(어휘적 정규화 + `underRoot`) 저쪽 경로에도 그대로 선다.
    if (self.pending_untitled_save.remote) |pin| {
        if (self.pending_untitled_save.surface_id != surface_id) return;
        var rpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rabs = resolve(pin.base(), std.mem.trim(u8, text, " \t"), &rpath_buf) orelse {
            self.showNoticeKey(.editor_untitled_bad_name);
            return;
        };
        // 고른 경로를 같은 자리에 굳혀 둔다 — 결말이 올 때까지 들고 있어야 그 문서에 이름을 붙일 수 있다.
        self.pending_untitled_save.path_len = rabs.len;
        @memcpy(self.pending_untitled_save.path_buf[0..rabs.len], rabs);
        // **첫 저장은 비대체다** — 있으면 저쪽이 `collision` 로 답하고 그때 묻는다(로컬 `stat` 으로
        // 미리 묻지 않는 이유: 그 사이가 창이고, 애초에 이 기계의 파일을 보게 된다).
        enqueueRemoteWrite(self, term, false);
        return;
    }
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

    // **한 번 분류한다.** 「있나」와 「종류가 무엇인가」를 따로 물으면 뒤의 검사가 앞의 관문에 가려
    // 관측되지 않는 방어가 된다(적대적 11회차: 변이가 살아남아 드러났다). 그리고 syscall 도 한 번이다.
    switch (classify(self, abs)) {
        // ⚠️ **보통 파일이 아니면 덮어쓸지 묻지 않는다.** 디렉터리에도 `openFile` 은 성공하므로 「있다」로만
        // 재면 폴더에 대고 「덮어쓸까요?」를 묻는다 — 사용자는 「덮어쓰면 된다」로 읽는데 실제로는 못 쓴다
        // (실측으로 그 확인이 떴다). 다른 질문이므로 확인이 아니라 그 사실을 말한다.
        .not_regular => {
            self.showNoticeKey(.editor_untitled_name_not_file);
            return;
        },
        .absent => writeAndAdopt(self, term, abs, false),
        .regular => {
            // 두 단계다 — 상자를 닫고(위 defer) 확인을 띄우며 **고른 경로를 들고 있는다**.
            self.pending_untitled_save = .{ .surface_id = surface_id, .path_len = abs.len };
            @memcpy(self.pending_untitled_save.path_buf[0..abs.len], abs);
            // 버튼은 기본(확인/취소)이다 — 문구가 이미 「덮어쓸까요?」라 버튼이 그 말을 되풀이하지 않는다.
            self.showConfirmKeys(.{ .untitled_overwrite = surface_id }, .editor_untitled_overwrite, .{});
        },
    }
}

/// 굳힌 목적지·경로로 **저쪽에 쓴다**(U3). 바이트는 문서에서 **지금** 뜬다 — 상자·확인이 떠 있는
/// 동안에도 사용자는 계속 칠 수 있고, 그때 보낼 것은 **누른 시점의 내용**이다(§4 의 그 규칙과 같은 자리).
fn enqueueRemoteWrite(self: *AppSession, term: *Term, overwrite: bool) void {
    const pin = self.pending_untitled_save.remote orelse return;
    const p = self.pending_untitled_save;
    if (p.path_len == 0) return;
    const doc = term.rt.editor_doc orelse return;
    const bytes = doc.file.saveBytes(self.allocator) catch {
        self.showNoticeKey(.app_save_failed);
        return;
    };
    defer self.allocator.free(bytes);
    // **상한은 이쪽과 같다**(§3.11) — 저쪽이 더 크게 받는다고 해서 여기서 느슨해지면 「저쪽엔
    // 저장되는데 이쪽엔 안 되는 문서」가 생긴다.
    if (bytes.len > maru.session.file_panel_bridge.max_file_bytes) {
        self.showNoticeKey(.app_save_too_large);
        return;
    }
    var endpoint: file_panel_ops.RemoteEndpoint = .{};
    @memcpy(endpoint.dest_buf[0..pin.dest_len], pin.dest());
    endpoint.dest_len = pin.dest_len;
    @memcpy(endpoint.ctl_buf[0..pin.ctl_len], pin.ctl());
    endpoint.ctl_len = pin.ctl_len;
    const parent = std.fs.path.dirname(p.path()) orelse "/";
    const name = std.fs.path.basename(p.path());
    _ = file_panel_ops.beginRemoteWrite(self, endpoint, parent, name, bytes, overwrite);
}

/// **저쪽 쓰기의 결말**(U3). 성공이면 그 문서는 **저쪽의 그 파일**이 된다(§3.11 의 그 결정) — 이름을
/// 버리고 신원을 들고 clean 이 된다. 실패면 **이름도 안 붙고 dirty 로 남는다**(U2 와 같은 규율:
/// 「이름은 정해졌는데 내용은 없는」 중간 상태를 만들지 않는다).
pub fn finishRemoteWrite(self: *AppSession, outcome: maru.session.remote_file_mutation.Outcome) void {
    const p = self.pending_untitled_save;
    const pin = p.remote orelse return;
    const term = termFor(self, p.surface_id) orelse {
        self.pending_untitled_save = .{};
        return;
    };
    switch (outcome) {
        .ok => {
            self.pending_untitled_save = .{};
            // 첫 저장이면 신원을 붙이고, 이미 저쪽 파일이면 **같은 값을 다시 세운다**(같은 길을 쓰는
            // 대가이고, clean 판정은 어느 쪽이든 여기서 한 번만 일어난다).
            adoptRemote(self, term, pin.dest(), p.path());
        },
        // **저쪽에 그 이름이 이미 있다** — 비대체 rename 이 그것을 판정했다(미리 묻지 않는 이유가 그것이다).
        // 보류를 **그대로 들고** 확인을 띄운다: 수락하면 같은 경로에 덮어쓴다.
        .collision => self.showConfirmKeys(
            .{ .untitled_remote_overwrite = p.surface_id },
            .editor_remote_save_exists,
            .{},
        ),
        .stale, .not_found => {
            self.pending_untitled_save = .{};
            self.showNoticeKey(.editor_remote_save_stale);
        },
        .unsupported => {
            self.pending_untitled_save = .{};
            self.showNoticeKey(.editor_remote_save_unsupported);
        },
        .invalid => {
            self.pending_untitled_save = .{};
            self.showNoticeKey(.editor_untitled_bad_name);
        },
        .denied, .io => {
            self.pending_untitled_save = .{};
            self.showNoticeKey(.editor_remote_save_failed);
        },
    }
}

/// **이미 저쪽 파일인 문서의 `⌘S`**(U3). 목적지·경로가 문서에 있으므로 묻지 않고 그대로 덮어쓴다 —
/// 「저장했는데 또 물어본다」를 남기지 않는 것이 이 신원의 이유다.
///
/// **보류를 그 값으로 세운다**: 결말 소비처가 같은 자리를 읽으므로(`finishRemoteWrite`) 첫 저장과
/// 이후 저장이 **같은 길**을 쓴다 — 두 길이면 한쪽이 낡는다.
pub fn saveRemoteAgain(self: *AppSession, term: *Term) bool {
    const r = term.rt.editor_remote orelse return false;
    if (r.path.len == 0 or r.path.len > std.fs.max_path_bytes) return false;
    var pin: RemotePin = .{};
    if (r.dest.len > pin.dest_buf.len) return false;
    @memcpy(pin.dest_buf[0..r.dest.len], r.dest);
    pin.dest_len = r.dest.len;
    // control socket 은 **지금** 다시 구한다 — 목적지는 문서의 것이지만 소켓은 세션의 것이고,
    // 끊겼다면 여기서 멈추는 것이 맞다(살아 있는지 확인하는 자리가 그 함수다).
    const failed = struct {
        fn f(s: *AppSession) bool {
            s.showNoticeKey(.editor_remote_save_failed);
            return false;
        }
    }.f;
    const home_z = std.c.getenv("HOME") orelse return failed(self);
    const home = std.mem.span(home_z);
    if (home.len == 0) return failed(self);
    const ctl = maru.cli.ssh.controlSocketPath(self.allocator, home, r.dest) catch return failed(self);
    defer self.allocator.free(ctl);
    if (ctl.len > pin.ctl_buf.len) return failed(self);
    _ = std.Io.Dir.cwd().statFile(self.io, ctl, .{ .follow_symlinks = false }) catch return failed(self);
    @memcpy(pin.ctl_buf[0..ctl.len], ctl);
    pin.ctl_len = ctl.len;
    // base 는 그 경로의 부모다(이번에는 이름을 묻지 않으므로 base 를 검증에 쓰지 않는다).
    const parent = std.fs.path.dirname(r.path) orelse "/";
    @memcpy(pin.base_buf[0..parent.len], parent);
    pin.base_len = parent.len;

    self.pending_untitled_save = .{ .surface_id = term.surface.id, .remote = pin, .path_len = r.path.len };
    @memcpy(self.pending_untitled_save.path_buf[0..r.path.len], r.path);
    enqueueRemoteWrite(self, term, true);
    return true;
}

/// 저쪽 덮어쓰기 확인을 수락했다(U3) — 같은 경로에 **덮어쓰기 모드**로 다시 보낸다.
pub fn confirmRemoteOverwrite(self: *AppSession, surface_id: u64) void {
    const p = self.pending_untitled_save;
    if (p.surface_id != surface_id or p.remote == null or p.path_len == 0) return;
    const term = termFor(self, surface_id) orelse {
        self.pending_untitled_save = .{};
        return;
    };
    enqueueRemoteWrite(self, term, true);
}

/// 그 문서를 **저쪽의 그 파일**로 만든다. 이름(untitled)을 버리고 신원을 들고 clean 이 된다.
fn adoptRemote(self: *AppSession, term: *Term, dest: []const u8, path: []const u8) void {
    const doc = term.rt.editor_doc orelse return;
    // **신원이 바뀌기 «전에» 떠 둔다**(§3.10) — 아래에서 이름을 버리면 옛 백업 파일의 이름을 더는
    // 만들 수 없다. 그러면 저쪽에 저장한 뒤에도 `untitled-N` 백업이 남아 다음 실행에서 되살아난다.
    const prev_backup = app_session_mod.editor_backup_ops.identity(term);
    const owned_dest = self.allocator.dupe(u8, dest) catch {
        self.showNoticeKey(.editor_untitled_written_not_adopted);
        return;
    };
    const owned_path = self.allocator.dupe(u8, path) catch {
        self.allocator.free(owned_dest);
        self.showNoticeKey(.editor_untitled_written_not_adopted);
        return;
    };
    if (term.rt.editor_remote) |*old| old.deinit(self.allocator);
    term.rt.editor_remote = .{ .dest = owned_dest, .path = owned_path };
    // **이름과 배타다** — 이 순서(신원을 세운 뒤 이름을 버린다)여야 중간 프레임에 둘 다 없는 문서가 없다.
    term.rt.editor_untitled = null;
    // **clean 이다** — 저쪽이 `ok` 를 줬고 그 내용이 곧 저쪽 파일이다. 「그 사이 더 친 것」은 dirty 로
    // 남는 것이 맞다(§1 의 「저장 중 재편집」과 같은 규칙). 백업은 **옛 신원으로** 지운다.
    app_session_mod.editor_backup_ops.markClean(self, term, doc.file.content, prev_backup);
    self.metal_dirty = true;
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

    // ⚠️ **저장 상한은 덮어쓰기 경로가 정한 것과 같아야 한다.** 덮어쓰기는 CAS 를 위해 원본을 읽고
    // `maru.session.file_panel_bridge.max_file_bytes` 를 넘으면 거절한다 — 그런데 **새 파일 경로에는
    // 상한이 없어서**, 큰 문서를 한 번 만들면 그 뒤 모든 `⌘S` 가 **조용히 실패**했다(다음 저장은
    // 덮어쓰기 경로이고 원본이 이미 상한을 넘는다). 만들 수 있는데 다시 저장할 수 없는 문서를 만들지
    // 않는다 — 적대적 13회차에서 잡았다.
    if (bytes.len > maru.session.file_panel_bridge.max_file_bytes) {
        self.showNoticeKey(.app_save_too_large);
        return;
    }
    const saved_content = doc.file.content;

    // **새 파일과 덮어쓰기는 다른 함수다.** 새 파일은 원본이 없어 CAS 를 걸 수 없고 대신 **배타 생성**
    // 으로 「그 사이에 생긴 파일」을 커널이 막는다. 덮어쓰기는 원본이 있으니 기존 CAS 경로를 그대로
    // 탄다 — 그쪽 방어(부모 핀·RENAME_SWAP·inode 검증)를 다시 짜지 않는다.
    if (overwriting)
        // 덮어쓰기는 **사용자가 그 자리에서 고른 것**이라 「연 뒤 바뀌었나」를 다시 묻지 않는다
        // (`null`) — 방금 「있다」를 보고 「덮어쓴다」고 답했다. 쓰는 동안의 보호는 그대로 돈다.
        editor_ops.writeDocumentBytes(self, abs, bytes, null) catch |e| {
            // **이유별로 말한다**(§3.9d) — 여기서 뭉개면 C0 이 올린 것을 다시 지우는 셈이다.
            self.showNoticeKey(editor_ops.saveFailureNoticeKey(e));
            return;
        }
    else
        editor_ops.createDocumentBytes(self, abs, bytes) catch |e| {
            self.showNoticeKey(editor_ops.saveFailureNoticeKey(e));
            return;
        };

    // **여기부터 실패해도 파일은 이미 있다** — 그래서 실패할 수 있는 일(경로 복사·entry 생성)을
    // 쓰기 **앞에** 둘 수 없다: 그것이 성공하고 쓰기가 실패하면 「경로는 붙었는데 파일이 없는」
    // 중간 상태가 된다. 순서를 뒤집는 대가는 아래 OOM 갈래가 **파일은 남기고 표식만 못 옮기는** 것이고,
    // 그때는 그 사실을 말한다(다시 `⌘S` 하면 같은 이름으로 이어진다).
    // ⚠️ **경로를 두 벌 소유한다.** `editor_path` 는 `releaseEditorTerm` 이 놓고 `entry.path` 는 세션이
    // 놓는다 — 하나를 둘이 가리키면 **이중 해제**다(파일을 여는 길도 그래서 각자 dupe 한다).
    // ⚠️ **여기부터의 실패는 「저장하지 못했다」가 아니다 — 파일은 이미 있다.** 같은 문구를 쓰면
    // 사용자는 아무 일도 없었다고 읽고, 디스크에는 자기 내용이 담긴 파일이 남는다(적대적 17회차).
    // 무엇이 됐고 무엇이 안 됐는지, 그리고 **다음에 무엇을 하면 되는지**를 말한다.
    const owned = self.allocator.dupe(u8, abs) catch {
        self.showNoticeKey(.editor_untitled_written_not_adopted);
        return;
    };
    const entry_path = self.allocator.dupe(u8, abs) catch {
        self.allocator.free(owned);
        self.showNoticeKey(.editor_untitled_written_not_adopted);
        return;
    };
    _ = attachEntry(self, term, entry_path) catch {
        self.allocator.free(entry_path);
        self.allocator.free(owned);
        self.showNoticeKey(.editor_untitled_written_not_adopted);
        return;
    };

    const prev_backup = app_session_mod.editor_backup_ops.identity(term); // 이름이 붙기 «전»의 신원
    term.rt.editor_path = owned;
    term.rt.editor_untitled = null; // **배타다**(§3.11) — 안 지우면 영원히 「저장 안 한 문서」다
    app_session_mod.editor_backup_ops.markClean(self, term, saved_content, prev_backup);
    // ⚠️ **디스크 지문도 여기서 처음 선다**(§3.9d). 이름 없는 문서는 볼 디스크가 없어 `null` 이었고,
    // 이름이 붙는 이 순간이 그 값을 얻는 유일한 자리다 — 안 세우면 **그 문서는 영영 외부 변경을 못
    // 본다**(저장할 때 비교할 과거가 없다). 적대적 3회차에서 잡았다: U2 로 만든 문서만 C0·C1 의
    // 보호 밖에 남는다.
    term.rt.editor_doc.?.disk_hash = editor_ops.contentHash(bytes);

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

/// 그 경로에 **무엇이 있나** — 저장이 가르는 세 갈래. 한 번 열어 한 번 `stat` 한다.
///
/// `not_regular` 를 「폴더」로 좁히지 않는다: 디렉터리뿐 아니라 FIFO·디바이스도 **덮어쓸 수 있는 파일이
/// 아니고**, 갈래를 늘리면 실제로 오지 않는 자리에 문구가 하나씩 생긴다. 하나의 참인 문장으로 답한다.
const Existing = enum { absent, regular, not_regular };

fn classify(self: *AppSession, abs: []const u8) Existing {
    var f = std.Io.Dir.cwd().openFile(self.io, abs, .{}) catch return .absent;
    defer f.close(self.io);
    const st = f.stat(self.io) catch return .not_regular;
    return if (st.kind == .file) .regular else .not_regular;
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

test "U2t 적대적 이름: 아주 길거나 이상한 문자도 조용히 통과하지 않는다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // **UTF-8 이름은 받는다** — 파일 이름은 바이트열이고 한글도 정당하다.
    try testing.expectEqualStrings("/w/\xed\x95\x9c.txt", resolve("/w", "\xed\x95\x9c.txt", &buf).?);
    // 공백이 든 이름도 받는다(macOS 에서 정당하다). 호출자가 앞뒤 공백을 다듬는다.
    try testing.expectEqualStrings("/w/a b.txt", resolve("/w", "a b.txt", &buf).?);
    // 점으로 시작하는 이름(숨김)도 받는다 — 거절할 근거가 없다.
    try testing.expectEqualStrings("/w/.env", resolve("/w", ".env", &buf).?);
    // 중복 슬래시는 접힌다.
    try testing.expectEqualStrings("/w/a/b", resolve("/w", "a//b", &buf).?);

    // **base 가 `/` 인 경우** — `underRoot` 가 그 자리를 특별히 다룬다(모든 절대 경로가 아래다).
    try testing.expectEqualStrings("/x.txt", resolve("/", "x.txt", &buf).?);

    // **아주 긴 이름은 거절한다** — 버퍼를 넘기면 `bufPrint` 가 실패하고, 그것이 곧 거절이다.
    //   조용히 자르면 **사용자가 준 이름과 다른 파일**에 쓴다.
    var long: [std.fs.max_path_bytes + 64]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(resolve("/w", &long, &buf) == null);

    // **구간이 아주 많은 이름도 거절한다**(`normalize` 의 구간 상한) — 잘리면 위와 같은 사고다.
    var many: std.ArrayListUnmanaged(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..400) |_| many.appendSlice(testing.allocator, "a/") catch unreachable;
    many.appendSlice(testing.allocator, "x") catch unreachable;
    try testing.expect(resolve("/w", many.items, &buf) == null);

    // **공백만 있는 이름**은 호출자가 다듬어 빈 이름이 되므로 거절된다(여기서는 그 뒤를 잰다).
    try testing.expect(resolve("/w", "", &buf) == null);
    // 점 하나·둘은 파일 이름이 아니다(이미 U2r 이 재지만 기호 조합도 본다).
    try testing.expect(resolve("/w", "./", &buf) == null);
    try testing.expect(resolve("/w", "a/./", &buf) == null);
    // **NUL 이 든 이름은 거절한다** — 경로 syscall 은 NUL 에서 끊기므로 통과시키면 **다른 파일**에 쓴다.
    try testing.expect(resolve("/w", "a\x00b.txt", &buf) == null);
}
