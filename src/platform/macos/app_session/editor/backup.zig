//! **미저장 편집이 크래시를 넘어 살아남는다 — 파일을 여는 쪽**(U4a).
//! 계약은 [문서 모델](../../../../../docs/native-editor-document-model.md) §3.10 이 소유하고,
//! **레코드의 모양·이름·주기 정책은 L2 `session.editor.backup`** 가 소유한다. 이 파일이 아는 것은
//! 셋뿐이다 — 어느 Term 이 대상인가 · 언제 시계가 만기인가 · 어디에 쓰는가.
//!
//! **지우는 자리와 남기는 자리가 다르다**(§3.10): 저장 성공과 **사용자가 수락한 닫기**는 지우고,
//! **앱 종료**는 남긴다. 그래서 지우기를 teardown 층에 두지 않는다 — 창 닫기와 앱 종료가 같은
//! teardown 함수를 지나므로 거기서는 두 뜻을 가를 수 없다.
//!
//! U4b·U4c가 레코드를 읽고 복원하며, **성공적으로 소비하는 쪽이 지우는 주인**이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const editor_selection = maru.session.editor.selection;
const backup = maru.session.editor.backup;

/// **테스트 주입 자리**(비공개 — `test_config_text` 와 같은 관례). 실제 자리는 앱 전역이므로 이
/// 주입도 앱 전역이다. `null` 이면 `$HOME/Library/Application Support/maru/editor-backups`.
///
/// 주입 없이 검사하면 **사용자의 실제 백업 디렉터리에 쓴다** — 그 사고는 이미 한 번 있었다
/// (config 를 덮어쓴 테스트).
var dir_override: ?[]const u8 = null;

pub fn setDirForTest(path: ?[]const u8) void {
    dir_override = path;
}

/// 이 문서의 백업 신원. **없으면 백업하지 않는다** — 문서가 아니거나(비교 뷰) 아직 열리는 중이다.
///
/// **공개인 이유**: 이름이 붙거나 저쪽으로 가는 순간 신원이 «바뀐다». 그 순간의 옛 파일을 지우려면
/// 부르는 쪽이 **바뀌기 전에** 신원을 떠 둬야 한다(`markClean` 의 `previous_identity`).
pub fn identity(term: *const Term) ?backup.Doc {
    if (term.kind != .editor) return null;
    if (term.rt.editor_diff != null) return null; // 비교 뷰는 편집이 아니다
    const doc = term.rt.editorDocument().opened orelse return null;
    // **순서가 계약이다**: 저쪽 신원이 있으면 그 문서는 저쪽 파일이고(U3) 로컬 경로가 없다.
    if (term.rt.editorDocument().remote) |r| return .{ .remote = .{ .dest = r.dest, .path = r.path } };
    if (term.rt.editorDocument().path) |p| return .{ .path = .{ .path = p, .disk_hash = doc.disk_hash } };
    if (term.rt.editorDocument().untitled) |u| return .{ .untitled = u.n };
    return null;
}

/// 백업 디렉터리 절대 경로를 `buf` 에 담는다.
pub fn dirPath(buf: []u8) ?[]const u8 {
    if (dir_override) |d| {
        if (d.len == 0 or d.len > buf.len) return null;
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    // Product-process smoke cannot use the in-process test override. An explicit absolute
    // root isolates fixture recovery records without changing HOME or touching user backups.
    // A malformed override disables backup access; falling back would defeat that isolation.
    if (std.c.getenv("MARU_EDITOR_BACKUP_ROOT")) |raw| return explicitRoot(buf, std.mem.span(raw));
    // **테스트 빌드는 사용자 자리로 떨어지지 않는다** — 주입(`setDirForTest`)도 명시 경로도 없으면 백업을 끈다.
    // 예전에는 주입을 잊은 테스트가 그대로 `$HOME/Library/Application Support/maru/editor-backups` 에 썼다:
    // 2026-10-04 실측 4,200 개 레코드가 전부 테스트 산물(`.zig-cache/tmp/…` 경로)이었고, 앱 호스트 스위트 한 번에
    // 3 개씩(LSP·시맨틱 판정자의 `r.c`·`im.c`·`h.c`) 늘었다. 관례(「잊지 말고 주입하라」)가 아니라 여기서 막는다.
    if (builtin.is_test) return null;
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/maru/editor-backups", .{
        std.mem.trimEnd(u8, home, "/"),
    }) catch null;
}

fn explicitRoot(buf: []u8, path: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path) or path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

test "테스트 빌드는 주입·명시 경로 없이 사용자 백업 자리로 떨어지지 않는다" {
    const saved_override = dir_override;
    defer dir_override = saved_override;
    dir_override = null;
    // 명시 경로(제품 스모크의 격리 수단)가 이 프로세스에 걸려 있으면 그 갈래를 타므로 이 판정과 무관하다.
    if (std.c.getenv("MARU_EDITOR_BACKUP_ROOT") != null) return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(dirPath(&buf) == null);
}

test "IME backup smoke root requires an absolute path and never truncates into a user directory" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/maru-ime/backups", explicitRoot(&buf, "/tmp/maru-ime/backups").?);
    try std.testing.expect(explicitRoot(&buf, "relative/backups") == null);
    try std.testing.expect(explicitRoot(&buf, "") == null);
    try std.testing.expect(explicitRoot(buf[0..4], "/tmp/maru-ime/backups") == null);
}

/// 문서 편집의 debounce. notifyDocumentEdit가 revision마다 한 번 호출한다.
/// 저장 중 재편집은 markClean이 별도로 다음 만기를 준비한다.
pub fn noteEdit(self: *AppSession, term: *Term) void {
    if (identity(term) == null) return;
    term.rt.editorDocument().notifications.backup_dirty = true;
    term.rt.editorDocument().notifications.backup_due_ns = std.Io.Clock.awake.now(self.io).nanoseconds + backup.debounce_ns;
}

/// 만기가 된 문서를 쓴다 — 프레임 tick 이 부른다.
///
/// **한 프레임에 하나만 쓴다.** 백업은 문서 전체 사본이라(최대 8 MiB) 여러 문서의 만기가 같은
/// 프레임에 겹치면 그 프레임이 통째로 I/O 가 된다 — 사용자는 타이핑 중에 그 멈춤을 본다.
/// 남은 문서는 **다음 프레임**이 쓴다(만기는 이미 지났으므로 미뤄지는 것은 프레임 하나다).
/// 종료 flush 는 이 제한을 쓰지 않는다 — 그쪽은 화면이 이미 없고 전부 굳혀야 한다.
pub fn tick(self: *AppSession) void {
    const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.editorDocument().notifications.backup_dirty) continue;
                if (now_ns < term.rt.editorDocument().notifications.backup_due_ns) continue;
                settle(self, term);
                return;
            }
        }
    }
}

/// **종료 직전** — 만기를 기다리지 않고 전부 쓴다(§3.10). debounce 만으로는 **마지막 몇 초의
/// 편집이 빠진다**: 종료가 그 사이에 오면 사용자가 방금 친 것이 백업에 없다.
pub fn flushAll(self: *AppSession) void {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.editorDocument().notifications.backup_dirty) continue;
                settle(self, term);
            }
        }
    }
}

/// **문서가 clean 이 되는 순간을 한 자리로 모은다**(§3.10) — 내용 해시를 굳히고 백업을 없앤다.
/// 부르는 자리 넷: 보통 저장 · 저쪽 저장 · 이름이 붙는 저장 · 「다시 읽기」 수락. 자리마다 따로
/// 지우면 한 자리가 낡아 **저장했는데 백업이 남는** 문서가 생긴다(그 백업이 다음 실행에서 되살아난다).
///
/// `previous_identity` 는 그 순간 신원이 **바뀌는** 경우의 옛 신원이다(이름이 붙었다 · 저쪽으로 갔다):
/// 새 신원으로 지우면 옛 이름의 파일이 그대로 남는다.
///
/// ⚠️ **저장이 끝난 뒤에도 dirty 일 수 있다** — 쓰는 동안 사용자가 더 쳤으면 그렇다(file-panel §1 의
/// 「저장 중 재편집은 dirty 를 유지한다」). 그때 백업을 지우고 시계까지 끄면 **방금 친 것이 보호
/// 밖으로 나간다**. 그래서 여전히 dirty 면 지우는 대신 **다음 만기를 세운다**.
pub fn markClean(self: *AppSession, term: *Term, content: []const u8, previous_identity: ?backup.Doc) void {
    // **`.?` 다** — 네 호출자 모두 방금 그 문서를 저장/받아들인 자리라 문서가 없을 수 없다.
    // `orelse return` 으로 접으면 「저장했는데 clean 이 안 됐다」가 조용한 갈래가 된다.
    //
    // ⚠️ **`&(… orelse …)` 로 잡지 않는다** — 그 형태는 optional 의 «사본»에 포인터를 주므로
    // 저장 해시가 임시 값에 쓰이고 문서는 영원히 dirty 로 남는다(적대적 1회차에서 그 형태를 지웠다).
    term.rt.editorDocument().opened.?.saved_hash = editor_ops.contentHash(content);
    term.rt.editorDocument().opened.?.needs_save = false;
    dropRecoverySource(self, term);
    if (previous_identity) |prev| {
        if (term.rt.editorDocument().notifications.backup_on_disk) {
            term.rt.editorDocument().notifications.backup_on_disk = false;
            if (prev == .path and term.rt.editor_recovery != null)
                term.rt.editor_recovery.?.drop() catch {}
            else
                dropDoc(self, prev);
        }
    }
    if (term.rt.editorDocument().opened.?.isDirty()) {
        noteEdit(self, term);
        return;
    }
    drop(self, term);
}

/// 이 문서의 백업을 **없는 상태로 만든다** — 저장 성공과 수락된 닫기가 부른다.
pub fn drop(self: *AppSession, term: *Term) void {
    term.rt.editorDocument().notifications.backup_dirty = false;
    term.rt.editorDocument().notifications.backup_paused = false;
    dropRecoverySource(self, term);
    if (!term.rt.editorDocument().notifications.backup_on_disk) return;
    term.rt.editorDocument().notifications.backup_on_disk = false;
    const doc = identity(term) orelse return; // 신원이 이미 바뀌었으면 그 경로가 옛 신원으로 지운다
    dropCurrent(self, term, doc);
}

fn dropCurrent(self: *AppSession, term: *Term, doc: backup.Doc) void {
    if (doc == .path and term.rt.editor_recovery != null) {
        term.rt.editor_recovery.?.drop() catch {};
    } else dropDoc(self, doc);
}

/// **신원으로 지운다** — 이름이 붙어 신원이 바뀐 뒤에도(U2·U3) 옛 파일을 지울 수 있어야 한다.
pub fn dropDoc(self: *AppSession, doc: backup.Doc) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    var name_buf: [backup.max_file_name_len]u8 = undefined;
    const name = backup.fileName(&name_buf, doc);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(self.io, path) catch {}; // 없으면 그만이다
}

/// 이 Term 의 백업을 **지금 상태에 맞춘다**: dirty 면 쓰고, clean 이면 지운다.
///
/// **clean 이면 지우는 것이 규칙이다** — undo 로 저장 시점 내용에 돌아온 문서에는 미저장 편집이
/// 없다(§3.10 이 기대는 dirty 계약). 남겨 두면 다음 실행이 「디스크와 같은 내용」을 dirty 로
/// 되살려, 사용자는 **바꾼 것이 없는데 저장하라는 표시**를 본다.
fn settle(self: *AppSession, term: *Term) void {
    term.rt.editorDocument().notifications.backup_dirty = false;
    const doc = identity(term) orelse return;
    const opened = term.rt.editorDocument().opened orelse return;
    if (!opened.isDirty()) {
        if (term.rt.editorDocument().notifications.backup_on_disk) {
            term.rt.editorDocument().notifications.backup_on_disk = false;
            dropCurrent(self, term, doc);
        }
        term.rt.editorDocument().notifications.backup_paused = false;
        dropRecoverySource(self, term);
        return;
    }
    // **상한을 넘는 문서는 백업하지 않고 그 사실을 화면에 남긴다**(§3.10 — 조용히 멈추면 사용자는
    // 보호받고 있다고 오해한다). 상태바 저하 칸이 그 자리다.
    if (opened.file.content.len > backup.pause_bytes) {
        if (!term.rt.editorDocument().notifications.backup_paused) self.metal_dirty = true;
        term.rt.editorDocument().notifications.backup_paused = true;
        return;
    }
    term.rt.editorDocument().notifications.backup_paused = false;
    if (writeCurrent(self, term, doc, opened.file.content)) {
        dropRecoverySource(self, term);
        term.rt.editorDocument().notifications.backup_on_disk = true;
    } else {
        // 쓰지 못했으면 **다음 만기에 다시 시도한다** — 한 번 실패로 보호를 놓지 않는다(디스크가
        // 잠시 찼거나 자리를 못 만든 경우가 영구 포기일 이유가 없다).
        term.rt.editorDocument().notifications.backup_dirty = true;
        term.rt.editorDocument().notifications.backup_due_ns = std.Io.Clock.awake.now(self.io).nanoseconds + backup.debounce_ns;
    }
}

fn writeCurrent(self: *AppSession, term: *Term, doc: backup.Doc, content: []const u8) bool {
    if (doc == .path) {
        if (term.rt.editor_recovery) |owner| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const root = dirPath(&buffer) orelse return false;
            owner.write(root, doc.path.path, doc.path.disk_hash, content) catch |err| {
                std.log.scoped(.app).warn("editor backup failed: reason={s}", .{@errorName(err)});
                return false;
            };
            return true;
        }
    }
    return write(self, doc, content);
}

fn write(self: *AppSession, doc: backup.Doc, content: []const u8) bool {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return false;
    var name_buf: [backup.max_file_name_len]u8 = undefined;
    const name = backup.fileName(&name_buf, doc);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return false;

    const bytes = backup.encode(self.allocator, doc, content) catch return false;
    defer self.allocator.free(bytes);

    // **자리를 먼저 만들고 소유자만으로 잠근다**(§3.10 — 「소유자만 읽을 수 있는 권한」). 디렉터리를
    // `make_path` 에 맡기면 umask 를 탄 기본 권한(보통 `0755`)이 되어 **이름 목록이 남에게 보인다**.
    std.Io.Dir.cwd().createDirPath(self.io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return false,
    };
    std.Io.Dir.cwd().setFilePermissions(self.io, dir, @enumFromInt(0o700), .{}) catch {};

    // **임시 이름 → 원자 교체는 std 가 소유한다** — 우리가 그 순서를 또 적으면 같은 지식이 두 벌이
    // 된다(`settings.zig` 의 config 쓰기가 쓰는 그 부품).
    var af = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
        .replace = true,
        .permissions = @enumFromInt(0o600),
    }) catch return false;
    defer af.deinit(self.io);
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(self.io, &buf);
    w.interface.writeAll(bytes) catch return false;
    w.interface.flush() catch return false;
    af.replace(self.io) catch return false;
    return true;
}

/// 이 Term 의 백업 **파일 이름** — 디스크에 있을 때만. 닫기 경로가 이것을 쓴다: 신원의 문자열은
/// Term 이 소유하므로 teardown 이 해제해 버리고, 그 뒤에는 `dropDoc` 로 이름을 만들 수 없다
/// (해제된 메모리를 읽는다). 이름은 값이라 살아남는다.
pub fn fileNameIfOnDisk(term: *const Term, buf: *[backup.max_file_name_len]u8) ?[]const u8 {
    const state = &term.rt.editorDocument().notifications;
    if (state.recovery_backup_len > 0) {
        const name = state.recovery_backup_name[0..state.recovery_backup_len];
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    if (!term.rt.editorDocument().notifications.backup_on_disk) return null;
    const doc = identity(term) orelse return null;
    if (doc == .path) if (term.rt.editor_recovery) |owner| {
        const name = maru.session.editor.recovery_id.fileName(owner.id) catch return null;
        @memcpy(buf[0..name.len], &name);
        return buf[0..name.len];
    };
    return backup.fileName(buf, doc);
}

/// 이름 없는 문서로 옮긴 복구 원본은 새 보호가 성공한 뒤 정리한다.
fn dropRecoverySource(self: *AppSession, term: *Term) void {
    const state = &term.rt.editorDocument().notifications;
    if (state.recovery_backup_len == 0) return;
    if (term.rt.editor_recovery) |owner| if (owner.source != null) {
        owner.dropSource() catch return;
        state.recovery_backup_len = 0;
        return;
    };
    dropName(self, state.recovery_backup_name[0..state.recovery_backup_len]);
    state.recovery_backup_len = 0;
}

/// 이름으로 지운다 — `fileNameIfOnDisk` 로 떠 둔 이름을 **닫힌 뒤에** 소비한다.
/// 복원이 **소비한** 레코드를 지운다 — 창 복원 apply 안이면 **확정까지 미룬다**. apply 는 트랜잭션이라 뒤에서
/// 실패하면 방금 내용을 넣은 Term 이 롤백되는데, 그때 레코드까지 지워져 있으면 미저장 내용이 사라진다.
/// 목록에 못 넣으면(OOM) **지우지 않는다** — 다음 실행이 같은 레코드를 다시 보는 쪽이 잃는 쪽보다 낫다.
fn dropConsumed(self: *AppSession, doc: backup.Doc) void {
    if (!self.workspace_restore_staging) return dropDoc(self, doc);
    var deferred: AppSession.DeferredBackupDrop = .{};
    const name = backup.fileName(&deferred.name, doc);
    deferred.len = @intCast(name.len);
    self.deferred_backup_drops.append(self.allocator, deferred) catch {};
}

/// 창 복원이 **확정됐다** — 미뤄 둔 레코드를 이제 지운다(내용은 살아 있는 Term 에 있다).
pub fn commitDeferredDrops(self: *AppSession) void {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.rt.editor_recovery) |owner| if (owner.consume_on_publish) owner.dropSelected() catch {};
    };
    for (self.deferred_backup_drops.items) |*deferred| dropName(self, deferred.slice());
    self.deferred_backup_drops.clearRetainingCapacity();
}

/// 창 복원이 **실패해 롤백됐다** — 미뤄 둔 삭제를 버린다. 레코드는 디스크에 그대로 남는다.
pub fn discardDeferredDrops(self: *AppSession) void {
    self.deferred_backup_drops.clearRetainingCapacity();
}

/// 백업 폴더에 남은 **이름 없는 문서 레코드의 번호**(`u-<16진수>.bak`)를 발급기에 알린다 — 새 번호가 그 위에서
/// 나오게. 발급기는 실행마다 0 부터 시작하고 **되살린** 번호만 보아서, 되살리지 못한 레코드(실패한 창 복원·크래시
/// 뒤 고아)가 있으면 새 문서가 같은 번호를 받았다. 레코드 이름은 번호로 정해지므로 그 문서의 백업이 남겨 둔
/// 레코드를 **덮어썼다**(2026-10-02 실험: 실패한 복원 뒤 새 문서가 `untitled-1` 을 받고 `u-1.bak` 이 새 내용이 됨).
/// 새 번호를 낼 때마다 훑는다 — 사용자 행동이라 드물고, 한 번만 훑으면 그 뒤에 생긴 레코드를 놓친다.
/// 폴더를 못 읽으면 아무것도 안 한다.
pub fn observeRecordedUntitledNumbers(self: *AppSession) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dirPath(&dir_buf) orelse return;
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    var it = dir.iterate();
    while (it.next(self.io) catch return) |entry| {
        if (recordedUntitledNumber(entry.name)) |n| app_session_mod.app_runtime.untitled_docs.observe(n);
    }
}

/// `u-<16진수>.bak` 의 번호. 그 모양이 아니거나 0 이면 null — 임시 파일·경로 레코드는 건너뛴다.
fn recordedUntitledNumber(name: []const u8) ?u32 {
    const prefix = "u-";
    const suffix = ".bak";
    if (name.len <= prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    const n = std.fmt.parseInt(u32, name[prefix.len .. name.len - suffix.len], 16) catch return null;
    return if (n == 0) null else n;
}

test "recorded untitled numbers parse only the record name shape" {
    try std.testing.expectEqual(@as(?u32, 1), recordedUntitledNumber("u-1.bak"));
    try std.testing.expectEqual(@as(?u32, 0x1f), recordedUntitledNumber("u-1f.bak"));
    // 파일 이름은 `backup.fileName` 이 정한다 — 같은 모양을 읽어야 한다.
    var buf: [backup.max_file_name_len]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 0xabc), recordedUntitledNumber(backup.fileName(&buf, .{ .untitled = 0xabc })));
    for ([_][]const u8{ "u-0.bak", "u-.bak", "u-zz.bak", "u-1.bak.tmp", "p-0123456789abcdef.bak", "u-1", "x-1.bak" }) |name|
        try std.testing.expectEqual(@as(?u32, null), recordedUntitledNumber(name));
}

pub fn dropName(self: *AppSession, name: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
}

/// **지난 세션이 남긴 미저장 편집을 되살린다**(§3.10 — U4b). 조용히, dirty 로, **한 편집으로**.
///
/// 묻지 않는 이유는 계약에 있다: 복원은 디스크를 건드리지 않고, 레코드의 지문을 문서에 실어 주므로
/// **첫 저장이 §4 의 CAS 에 걸려** 덮어쓰기·다시 로드·비교를 묻는다. 열 때 묻는 규칙은 재시작 복원에서
/// 물음이 겹쳐 앞의 것이 조용히 취소된다(`showConfirmButtons` 가 `cancelPendingConfirm` 을 부른다).
///
/// **이름 없는 문서와 저쪽 신원 문서는 대상이 아니다**(U4c) — 그 둘은 「어느 창이 되살리나」와
/// 디렉터리 훑기가 함께 필요하다.
pub fn restoreIfAny(self: *AppSession, term: *Term) void {
    // 새 local ID는 checkpoint가 지목한 record만 복원한다. 경로가 같은 개발 v1 record를
    // 신규 문서에 자동 귀속시키면 독립 A/B의 분리가 다시 깨진다.
    if (term.rt.editor_recovery != null) return;
    // **경로가 있는 문서만이다.** 이름 없는 문서를 여기서 받으면 **새로 만든 빈 문서**가 옛 번호의
    // 레코드를 조용히 삼킨다(번호는 재시작마다 1 부터 다시 난다 — U4b-7 이 그 사고를 못 박는다).
    // 그래서 이름 없는 문서는 **되살리는 자리 하나**(`restoreUntitled` — workspace 가 번호를 실어 온
    // 그 자리)에서만 복원한다. 저쪽 신원 문서는 아직 대상이 아니다(U4d).
    if (term.rt.editorDocument().remote != null) return;
    const path = term.rt.editorDocument().path orelse return;
    restoreFromRecord(self, term, .{ .path = .{ .path = path } });
}

/// checkpoint가 명시한 ID만 복원한다. absence와 읽기/신원 실패를 분리해 창 staging이
/// 실패를 성공으로 저장하지 않게 한다. dirty record는 다음 백업 전 종료에도 남는다.
pub fn restoreRecovery(self: *AppSession, term: *Term) !bool {
    const owner = term.rt.editor_recovery orelse return error.MissingRecoveryOwner;
    const path = term.rt.editorDocument().path orelse return error.MissingRecoveryPath;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = dirPath(&buffer) orelse return error.InvalidRecoveryRoot;
    var record = (try owner.read(root, path)) orelse return false;
    defer record.deinit(owner.allocator);
    const opened = term.rt.editorDocument().opened.?;
    if (std.mem.eql(u8, opened.file.content, record.parsed.content)) {
        try owner.selectDrop();
        owner.consume_on_publish = true;
        return false;
    }
    term.rt.editor_selection = editor_selection.Selection.at(0);
    var changes = [_]maru.session.editor.delta.Change{.{ .start = 0, .end = opened.file.content.len, .text = record.parsed.content }};
    if (!editor_ops.applyEditAsOne(self, term, &changes)) return error.OutOfMemory;
    term.rt.editorDocument().opened.?.disk_hash = record.parsed.doc.disk_hash;
    term.rt.editorDocument().notifications.backup_on_disk = true;
    return true;
}

/// **되살린 이름 없는 문서의 내용을 넣는다**(U4c). 부르는 자리는 `createRestoredUntitledTerm` 하나 —
/// workspace 가 실어 온 번호가 곧 그 문서의 신원이고, **새로 만든 문서는 이 길로 오지 않는다**.
pub fn restoreUntitled(self: *AppSession, term: *Term) void {
    const name = term.rt.editorDocument().untitled orelse return;
    restoreFromRecord(self, term, .{ .untitled = name.n });
}

fn restoreFromRecord(self: *AppSession, term: *Term, want: backup.Doc) void {
    const doc = term.rt.editorDocument().opened orelse return;

    const record = read(self, want) orelse return;
    defer self.allocator.free(record.bytes);
    var parsed = record.parsed;
    defer parsed.deinit(self.allocator);

    // **신원을 다시 확인한다** — 이름은 해시라 충돌이 가능하고(경로), 번호는 파일 이름에 그대로
    // 들어가지만 **레코드가 말하는 신원**과 다를 수 있다(손으로 옮긴 파일). 남의 내용을 되살리는 것은
    // 「조용히 다른 문서로 연다」가 된다.
    switch (want) {
        .path => |w| switch (parsed.doc) {
            .path => |p| if (!std.mem.eql(u8, p.path, w.path)) return,
            else => return,
        },
        .untitled => |n| switch (parsed.doc) {
            .untitled => |m| if (m != n) return,
            else => return,
        },
        .remote => return, // 위에서 걸렀다 — 여기 오면 갈래가 갈린 것이다
    }
    // **적대적 입력으로 본다**(§3.8 — 문서 내용은 신뢰 입력이 아니다). 레코드는 앱 전용 자리에 있지만
    // 파일이고, 우리가 쓴 것과 다른 바이트가 들어 있을 수 있다. 여는 경로는 UTF-8 을 검증하는데
    // (`document.zig` → `error.NotUtf8`) **편집 경로는 검증하지 않는다** — IME·붙여넣기가 UTF-8 이기
    // 때문이다. 그래서 여기서 막는다: 아니면 손상 레코드와 같은 대우(무시하고 파일 그대로)다.
    if (!std.unicode.utf8ValidateSlice(parsed.content)) return;
    // **되쓸 수 없는 내용은 되살리지 않는다** — 저장 상한을 넘는 문서는 `⌘S` 가 `TooLarge` 라, 되살리면
    // 「지울 수도 저장할 수도 없는 dirty」가 된다(레코드 상한은 그보다 조금 크다).
    if (parsed.content.len > backup.pause_bytes) return;
    // 내용이 이미 같으면 되살릴 것이 없다 — 레코드만 걷는다(다음 실행이 또 보지 않게).
    if (std.mem.eql(u8, parsed.content, doc.file.content)) {
        // 이름 없는 백업은 저장 이력이 없다. 빈 본문을 clean과 혼동해 없애지 않는다.
        if (want == .untitled) {
            term.rt.editorDocument().opened.?.needs_save = true;
            term.rt.editorDocument().notifications.backup_on_disk = true;
        } else dropConsumed(self, parsed.doc);
        return;
    }

    // **커서를 먼저 세운다** — 파일을 열 때 커서는 클릭이 세우므로(그 규칙은 `openPathInActivePane`
    // 의 주석이 소유한다) 지금은 없고, 편집은 커서 없이 들어가지 않는다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    var changes = [_]maru.session.editor.delta.Change{.{
        .start = 0,
        .end = doc.file.content.len,
        .text = parsed.content,
    }};
    // **한 편집이다** — 통짜로 문서를 갈아치우면 `⌘Z` 로 디스크 내용에 돌아갈 길이 없다(C1a 의
    // 「다시 로드」가 같은 이유로 편집이 됐다). 실패하면 **레코드를 남긴다**: 다음 기회에 또 시도한다.
    if (!editor_ops.applyEditAsOne(self, term, &changes)) return;
    if (want == .untitled) term.rt.editorDocument().opened.?.needs_save = true;

    // **지문은 레코드의 것이다** — 「내가 마지막으로 본 디스크」. 지금 디스크의 지문으로 덮으면 첫
    // 저장이 CAS 를 통과해 **외부 변경을 조용히 지운다**(그것이 §3.10 이 막으려던 그 손실이다).
    // 이름 없는 문서에는 볼 디스크가 없어 지문도 없다(`null` 그대로 — U2 가 이름이 붙는 순간 세운다).
    switch (parsed.doc) {
        .path => |p| {
            if (p.disk_hash) |h| term.rt.editorDocument().opened.?.disk_hash = h;
        },
        else => {},
    }
    // 같은 신원 dirty 복구는 재백업 전에도 원본이 보호한다. clean 복구만 위에서 소비한다.
    term.rt.editorDocument().notifications.backup_on_disk = true;
    // **알림 한 줄**(모달이 아니다) — 크래시를 몰랐던 사용자는 dirty 를 버그로 읽는다.
    self.showNoticeKey(.editor_backup_restored);
}

const ReadRecord = struct { bytes: []u8, parsed: backup.Parsed };

/// 이 신원의 레코드를 읽는다. 없거나 **손상·잘림이면 `null`** — 그때는 파일을 그대로 연다(조용히).
fn read(self: *AppSession, doc: backup.Doc) ?ReadRecord {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return null;
    var name_buf: [backup.max_file_name_len]u8 = undefined;
    const name = backup.fileName(&name_buf, doc);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;

    return switch (readAt(self.allocator, self.io, path)) {
        .record => |record| record,
        else => null,
    };
}

/// 공유 복원 준비가 부재와 실패를 구분할 수 있는 읽기 결과. 기존 caller의 복원 정책은 유지한다.
const ReadOutcome = union(enum) {
    record: ReadRecord,
    missing,
    invalid: anyerror,
    failed: anyerror,
};

fn readAt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ReadOutcome {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(backup.max_record_bytes)) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        error.StreamTooLong => .{ .invalid = err },
        else => .{ .failed = err },
    };
    const parsed = backup.parse(allocator, bytes) catch |err| {
        allocator.free(bytes);
        return if (err == error.OutOfMemory) .{ .failed = err } else .{ .invalid = err };
    };
    return .{ .record = .{ .bytes = bytes, .parsed = parsed } };
}

/// **신원을 잃은 문서를 이름 없는 문서로 되살린다**(U4d). 입구는 둘이고 규칙은 하나다 —
/// ⑴ 저쪽에 저장한 문서(재시작엔 control socket 이 없어 그 신원을 못 세운다)
/// ⑵ 원본이 사라진 경로 문서(그 경로는 아예 열리지 않는다).
///
/// **새 번호를 받는다** — 그 문서는 「지난 실행에서 이름이 없던 것」이 아니라 **신원을 잃은 것**이라
/// 옛 번호가 없다. 그리고 **알린다**: 조용히 하면 사용자는 「왜 이 탭이 생겼지」를 묻는다(U4b 의 조용한
/// 복원과 다른 이유는 신원이 바뀐다는 점이다).
///
/// 레코드가 없거나 읽히지 않으면 **아무것도 만들지 않는다**(빈 탭을 만들 이유가 없다).
pub fn reviveAsUntitled(self: *AppSession, lost: backup.Doc) void {
    if (lost == .untitled) return; // 번호가 있는 workspace 복원은 restoreUntitled가 담당한다.
    var source_buf: [backup.max_file_name_len]u8 = undefined;
    if (self.editor_documents.hasRecoveryBackupSource(backup.fileName(&source_buf, lost))) return;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = dirPath(&root_buffer) orelse return;
    var source: ?editor_ops.recovery_store.Source = editor_ops.recovery_store.Source.open(self.allocator, self.io, root, backup.fileName(&source_buf, lost)) catch return;
    defer if (source) |*retained| retained.deinit();
    var record = source.?.read() catch return;
    defer record.deinit(self.allocator);
    // 수동 목록과 달리 자동 복구는 요청한 원본이 있다. 파일명 해시가 같아도 정확한 신원을 대조한다.
    switch (lost) {
        .path => |w| switch (record.parsed.doc) {
            .path => |p| if (!std.mem.eql(u8, p.path, w.path)) return,
            else => return,
        },
        .remote => |w| switch (record.parsed.doc) {
            .remote => |r| if (!std.mem.eql(u8, r.dest, w.dest) or !std.mem.eql(u8, r.path, w.path)) return,
            else => return,
        },
        .untitled => unreachable,
    }
    // 본문·줄 준비 실패는 원본을 소비하지 않는다. 성공한 source의 수명은 새 문서가 가진다.
    _ = editor_ops.openRecoveredSource(self, &source.?) catch return;
    source = null;
    self.showNoticeKey(.editor_backup_revived);
}

/// 예약된 되살리기를 **한 프레임에 하나** 소비한다(U4d). 예약은 복원 트리 staging 과 dock prune 이
/// 넣는다 — 그 자리들에는 pane 이 아직/이미 없어 Term 을 만들 수 없기 때문이다.
pub fn drainRevivals(self: *AppSession) void {
    if (self.pending_backup_revivals.items.len == 0) return;
    // **앞에서부터 하나** — 예약 순서가 곧 탭 순서다(뒤에서 빼면 순서가 뒤집힌다).
    const entry = self.pending_backup_revivals.orderedRemove(0);
    reviveAsUntitled(self, entry.doc());
}

test "U4b-10 backup reader distinguishes absent invalid and valid records without deleting source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/record.bak", .{buf[0..len]});
    defer std.testing.allocator.free(path);
    try std.testing.expect(readAt(std.testing.allocator, std.testing.io, path) == .missing);
    try std.testing.expect(readAt(std.testing.allocator, std.testing.io, buf[0..len]) == .failed);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "record.bak", .data = "broken" });
    try std.testing.expect(readAt(std.testing.allocator, std.testing.io, path) == .invalid);
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "record.bak", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("broken", unchanged);
    const encoded = try backup.encode(std.testing.allocator, .{ .path = .{ .path = "/tmp/test", .disk_hash = 7 } }, "dirty content");
    defer std.testing.allocator.free(encoded);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "record.bak", .data = encoded });
    var record = switch (readAt(std.testing.allocator, std.testing.io, path)) {
        .record => |record| record,
        else => return error.ExpectedRecord,
    };
    defer std.testing.allocator.free(record.bytes);
    defer record.parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dirty content", record.parsed.content);
    try std.testing.expectEqual(@as(?u64, 7), record.parsed.doc.path.disk_hash);
}

test "U4b-11 backup reader allocation failure is not absence or corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/record.bak", .{buf[0..len]});
    defer std.testing.allocator.free(path);
    const encoded = try backup.encode(std.testing.allocator, .{ .path = .{ .path = "/tmp/test" } }, "dirty content");
    defer std.testing.allocator.free(encoded);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "record.bak", .data = encoded });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readRecordAllocationProbe, .{path});
}

fn readRecordAllocationProbe(allocator: std.mem.Allocator, path: []const u8) !void {
    var record = switch (readAt(allocator, std.testing.io, path)) {
        .record => |record| record,
        .failed => |err| return err,
        else => return error.MisclassifiedAllocationFailure,
    };
    defer allocator.free(record.bytes);
    defer record.parsed.deinit(allocator);
    try std.testing.expectEqualStrings("dirty content", record.parsed.content);
}
