//! **미저장 편집이 크래시를 넘어 살아남는다 — 파일을 여는 쪽**(U4a).
//! 계약은 [문서 모델](../../../../docs/native-editor-document-model.md) §3.10 이 소유하고,
//! **레코드의 모양·이름·주기 정책은 L2 `session.editor.backup`** 가 소유한다. 이 파일이 아는 것은
//! 셋뿐이다 — 어느 Term 이 대상인가 · 언제 시계가 만기인가 · 어디에 쓰는가.
//!
//! **지우는 자리와 남기는 자리가 다르다**(§3.10): 저장 성공과 **사용자가 수락한 닫기**는 지우고,
//! **앱 종료**는 남긴다. 그래서 지우기를 teardown 층에 두지 않는다 — 창 닫기와 앱 종료가 같은
//! teardown 함수를 지나므로 거기서는 두 뜻을 가를 수 없다.
//!
//! **이 슬라이스는 읽지 않는다.** 크래시가 남긴 레코드를 앱이 소비하는 것은 U4b·U4c 다
//! (계획서 참조) — 그때까지 그 파일은 앱 전용 디렉터리에 쌓이고, **소비하는 쪽이 지우는 주인**이다.

const std = @import("std");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
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
    const doc = term.rt.editor_doc orelse return null;
    // **순서가 계약이다**: 저쪽 신원이 있으면 그 문서는 저쪽 파일이고(U3) 로컬 경로가 없다.
    if (term.rt.editor_remote) |r| return .{ .remote = .{ .dest = r.dest, .path = r.path } };
    if (term.rt.editor_path) |p| return .{ .path = .{ .path = p, .disk_hash = doc.disk_hash } };
    if (term.rt.editor_untitled) |u| return .{ .untitled = u.n };
    return null;
}

/// 백업 디렉터리 절대 경로를 `buf` 에 담는다.
fn dirPath(buf: []u8) ?[]const u8 {
    if (dir_override) |d| {
        if (d.len == 0 or d.len > buf.len) return null;
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/maru/editor-backups", .{
        std.mem.trimEnd(u8, home, "/"),
    }) catch null;
}

/// 편집 통지 — **시계만 되감는다**(§3.10 「편집 후 debounce」). 부르는 자리는 `refreshAfterEdit`
/// 하나다: 제품의 편집 경로 여섯이 전부 그 함수를 지난다(그 함수의 주석이 그 사실을 소유한다).
pub fn noteEdit(self: *AppSession, term: *Term) void {
    if (identity(term) == null) return;
    term.rt.editor_backup_dirty = true;
    term.rt.editor_backup_due_ns = std.Io.Clock.awake.now(self.io).nanoseconds + backup.debounce_ns;
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
                if (!term.rt.editor_backup_dirty) continue;
                if (now_ns < term.rt.editor_backup_due_ns) continue;
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
                if (!term.rt.editor_backup_dirty) continue;
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
    term.rt.editor_doc.?.saved_hash = editor_ops.contentHash(content);
    if (previous_identity) |prev| {
        if (term.rt.editor_backup_on_disk) {
            term.rt.editor_backup_on_disk = false;
            dropDoc(self, prev);
        }
    }
    if (term.rt.editor_doc.?.isDirty()) {
        noteEdit(self, term);
        return;
    }
    drop(self, term);
}

/// 이 문서의 백업을 **없는 상태로 만든다** — 저장 성공과 수락된 닫기가 부른다.
pub fn drop(self: *AppSession, term: *Term) void {
    term.rt.editor_backup_dirty = false;
    term.rt.editor_backup_paused = false;
    if (!term.rt.editor_backup_on_disk) return;
    term.rt.editor_backup_on_disk = false;
    const doc = identity(term) orelse return; // 신원이 이미 바뀌었으면 그 경로가 옛 신원으로 지운다
    dropDoc(self, doc);
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
    term.rt.editor_backup_dirty = false;
    const doc = identity(term) orelse return;
    const opened = term.rt.editor_doc orelse return;
    if (!opened.isDirty()) {
        if (term.rt.editor_backup_on_disk) {
            term.rt.editor_backup_on_disk = false;
            dropDoc(self, doc);
        }
        term.rt.editor_backup_paused = false;
        return;
    }
    // **상한을 넘는 문서는 백업하지 않고 그 사실을 화면에 남긴다**(§3.10 — 조용히 멈추면 사용자는
    // 보호받고 있다고 오해한다). 상태바 저하 칸이 그 자리다.
    if (opened.file.content.len > backup.pause_bytes) {
        if (!term.rt.editor_backup_paused) self.metal_dirty = true;
        term.rt.editor_backup_paused = true;
        return;
    }
    term.rt.editor_backup_paused = false;
    if (write(self, doc, opened.file.content)) {
        term.rt.editor_backup_on_disk = true;
    } else {
        // 쓰지 못했으면 **다음 만기에 다시 시도한다** — 한 번 실패로 보호를 놓지 않는다(디스크가
        // 잠시 찼거나 자리를 못 만든 경우가 영구 포기일 이유가 없다).
        term.rt.editor_backup_dirty = true;
        term.rt.editor_backup_due_ns = std.Io.Clock.awake.now(self.io).nanoseconds + backup.debounce_ns;
    }
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
    if (!term.rt.editor_backup_on_disk) return null;
    const doc = identity(term) orelse return null;
    return backup.fileName(buf, doc);
}

/// 이름으로 지운다 — `fileNameIfOnDisk` 로 떠 둔 이름을 **닫힌 뒤에** 소비한다.
pub fn dropName(self: *AppSession, name: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
}
