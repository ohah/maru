//! 문서 본문·저장 정보·편집 이력의 소유 경계. 파일 I/O와 뷰 상태는 platform에 남는다.
//! 일반 텍스트는 앱 전역 registry가 소유하며 TermRuntime은 view lease로 빌린다. State 자체는 연결 정책을 제공하지 않는다.
const std = @import("std");
const edit_doc = @import("edit_doc.zig");
const history = @import("history.zig");
const untitled = @import("untitled.zig");

pub fn contentHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// **저쪽 파일의 신원**(U3 — §3.11). 저장 목적지가 원격일 때 문서가 드는 값이고, `State.path`
/// (이쪽)와 **배타**다.
///
/// **둘 다 owned 다.** 목적지는 요청할 때 박는 규율(`RemoteEndpoint`)과 같은 이유로 들고 있어야
/// 한다 — 나중에 세션에서 읽으면 그 사이 활성 pane 이 다른 호스트로 바뀌어 **남의 기계에 쓴다**.
/// 경로는 저쪽 절대 경로이고 **로컬 파일시스템에 넘기지 않는다**(ssh-integration.md §9.4).
pub const RemoteDoc = struct {
    dest: []u8,
    path: []u8,

    pub fn deinit(self: *RemoteDoc, allocator: std.mem.Allocator) void {
        allocator.free(self.dest);
        allocator.free(self.path);
        self.* = .{ .dest = &.{}, .path = &.{} };
    }
};

pub const Opened = struct {
    /// 열린 문서. **읽어 온 bytes를 빌리지 않고 소유한다**(N2 — `edit_doc.EditableFile`).
    ///
    /// **`bytes` 필드가 없어졌다.** 읽기 전용이던 동안에는 문서가 읽기 버퍼를 빌려 썼고 그래서 그
    /// 버퍼가 문서보다 오래 살아야 했다. 이제 문서가 자기 내용을 들므로 읽기 버퍼는 `openPath`가
    /// 끝나면 놓는다 — 파일이 `stat`과 read 사이에 줄어들어 생기던 "안 쓰는 꼬리"도 함께 사라진다.
    file: edit_doc.EditableFile,

    /// **마지막으로 디스크와 같았던 내용의 해시.** dirty 판정의 유일한 근거다.
    ///
    /// **개정 번호가 아니라 내용이다**([file-panel.md](../../../docs/file-panel.md) §1이 소유하는
    /// 계약): *"편집 뒤 undo로 snapshot과 같은 내용에 돌아오면 revision이 더 높아도 clean"*.
    /// 개정 번호로 재면 열 번 고치고 열 번 되돌린 문서가 dirty로 남아, 사용자가 **바꾼 것이 없는데
    /// 저장하라는 표시**를 본다.
    ///
    /// **해시인 이유**: 사본을 들면 문서 하나에 메모리가 두 배가 되고(§3.0이 잰 2.7배 위에 또
    /// 얹힌다), 큰 파일에서 매 키 입력마다 전체 비교가 돈다. 해시는 충돌 가능성이 있지만 그 대가는
    /// *"바뀌었는데 clean으로 보인다"*가 아니라 **저장 버튼을 한 번 더 누르는 것**이다 — 저장
    /// 자체는 내용을 그대로 쓴다.
    saved_hash: u64,

    /// **마지막으로 본 «디스크» 내용의 지문**(§3.9d). `saved_hash` 가 「우리 내용」이라면 이것은
    /// 「그때 파일에 있던 것」이다 — 둘은 다른 질문이고, 이 값이 없으면 **연 뒤 남이 고친 것을 알 수
    /// 없다**. 예전에는 그 검사가 아예 없어 `ExternalConflict` 가 네이티브에서 **도달 불가**였다:
    /// 쓰기 직전 CAS 는 「쓰는 동안」의 변경만 막고, 「연 뒤」의 변경은 그 앞에서 지나간다.
    ///
    /// `null` 은 「아직 디스크를 본 적 없다」(이름 없는 문서) — 그때는 비교할 것이 없다.
    disk_hash: ?u64 = null,

    /// 지금 내용이 마지막 저장과 다른가.
    pub fn isDirty(self: Opened) bool {
        return contentHash(self.file.content) != self.saved_hash;
    }

    pub fn deinit(self: *Opened, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.file.deinit();
    }
};

/// 본문은 내부 allocator를 기억한다. 경로·원격 신원·이력은 기존 session allocator로 정산한다.
/// 파생 줄 슬라이스·선택·조합은 이 객체에 포함하지 않는다.
/// 문서 부수효과 시계를 모아 같은 revision의 뷰 갱신에서 중복 통지하지 않는다.
/// 시계·I/O는 host가 수행한다. 구문 provider와 표시 캐시는 뷰 소유를 유지한다.
pub const Notifications = struct {
    last_revision: ?u64 = null,
    lsp_version: u64 = 0,
    backup_dirty: bool = false,
    backup_due_ns: i128 = 0,
    backup_on_disk: bool = false,
    backup_paused: bool = false,
    /// 신원이 바뀐 복구의 원본 백업. 새 백업/저장/버리기 성공까지 문서가 소유한다.
    recovery_backup_name: [@import("backup.zig").max_file_name_len]u8 = undefined,
    recovery_backup_len: u8 = 0,
};

pub const State = struct {
    opened: ?Opened = null,
    path: ?[]u8 = null,
    remote: ?RemoteDoc = null,
    untitled: ?untitled.Name = null,
    history: history.State = .{},
    notifications: Notifications = .{},

    /// 기존 teardown의 본문/뷰 정산 순서를 유지할 수 있도록 본문 해제를 나눈다.
    pub fn clearOpened(self: *State, allocator: std.mem.Allocator) void {
        if (self.opened) |*opened| opened.deinit(allocator);
        self.opened = null;
    }

    /// 뷰 정산과 경로 정산의 기존 순서를 유지한다. 저장 정책은 호출자 책임이다.
    pub fn clearPath(self: *State, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.path = null;
    }

    /// 저장 정보만 놓는다. 저장·백업 삭제 같은 I/O 정책은 호출자 책임이다.
    pub fn clearIdentity(self: *State, allocator: std.mem.Allocator) void {
        self.clearPath(allocator);
        if (self.remote) |*remote| remote.deinit(allocator);
        self.remote = null;
        self.untitled = null;
    }

    /// 뷰가 빌린 본문·줄을 먼저 정산한 뒤 호출한다. 연결 참조 카운트는 아직 없다.
    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.clearOpened(allocator);
        self.history.clear(allocator);
        self.clearIdentity(allocator);
        self.notifications = .{};
    }
};

// 준비 중 어느 할당이 실패해도 이미 만든 본문·경로·원격 정보를 같은 owner가 정산한다.
fn exerciseOwnedState(allocator: std.mem.Allocator, bytes: []const u8, remote: bool) !void {
    var state: State = .{};
    defer state.clear(allocator);
    // 본문 준비가 성공하기 전에는 optional owner에 연결하지 않는다.
    const file = try edit_doc.EditableFile.init(allocator, bytes, false);
    state.opened = .{
        .file = file,
        .saved_hash = contentHash(bytes),
    };
    state.opened.?.saved_hash = contentHash(state.opened.?.file.content);
    try std.testing.expect(!state.opened.?.isDirty());
    state.opened.?.saved_hash = contentHash("different");
    try std.testing.expect(state.opened.?.isDirty());
    if (remote) {
        state.remote = remote: {
            const dest = try allocator.dupe(u8, "host");
            errdefer allocator.free(dest);
            const path = try allocator.dupe(u8, "/remote/file");
            break :remote .{ .dest = dest, .path = path };
        };
    } else {
        state.path = try allocator.dupe(u8, "/local/file");
    }
    state.history.undo = try allocator.alloc(history.Entry, 2);
    state.history.redo = try allocator.alloc(history.Entry, 1);
    // capacity만 있고 live entry는 없다. 초기화하지 않은 슬롯은 해제하지 않는다.
    state.clear(allocator);
    try std.testing.expect(state.opened == null);
    try std.testing.expect(state.path == null);
    try std.testing.expect(state.remote == null);
    try std.testing.expectEqual(@as(usize, 0), state.history.undo.len);
    try std.testing.expectEqual(@as(usize, 0), state.history.redo.len);
    state.untitled = untitled.Name.init(3);
    state.clear(allocator);
    try std.testing.expect(state.untitled == null);
}

test "document owner local and remote preparation unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnedState, .{ "한\r\n", false });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnedState, .{ "한\r\n", true });
}

test "document owner preserves borrowed view data until explicit body release" {
    var state: State = .{};
    defer state.clear(std.testing.allocator);
    state.opened = .{
        .file = try edit_doc.EditableFile.init(std.testing.allocator, "한\r\n", false),
        .saved_hash = contentHash("한\r\n"),
        .disk_hash = contentHash("disk"),
    };
    state.path = try std.testing.allocator.dupe(u8, "/local/file");
    const borrowed = state.opened.?.file.content;
    state.clearIdentity(std.testing.allocator);
    try std.testing.expectEqualStrings("한\r\n", borrowed);
    try std.testing.expectEqual(contentHash("disk"), state.opened.?.disk_hash.?);
    state.clearOpened(std.testing.allocator);
    try std.testing.expect(state.opened == null);
}

test "document owner body retains its allocator independently of identity allocator" {
    var identity_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(std.heap.Check.ok, identity_allocator.deinit()) catch @panic("identity allocator leaked");
    var state: State = .{};
    defer state.clear(identity_allocator.allocator());
    // 파일은 자기 allocator를 기억하고, 별도 allocator로 만든 저장 신원과 함께 살 수 있다.
    const file = try edit_doc.EditableFile.init(std.testing.allocator, "body\n", false);
    state.opened = .{ .file = file, .saved_hash = contentHash(file.content) };
    state.path = try identity_allocator.allocator().dupe(u8, "/local/file");
    state.clear(identity_allocator.allocator());
    try std.testing.expect(state.opened == null);
    try std.testing.expect(state.path == null);
}
