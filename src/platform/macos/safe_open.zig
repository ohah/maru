//! 경로 요소마다 `O_NOFOLLOW` 를 강제하는 **안전한 열기**(L4).
//!
//! **이 규율의 단일 출처다.** 원래 `git_backend` 안의 private 함수였는데, 턴 캡처가 같은 적대 조건
//! (밖에서 온 경로를 그대로 연다)에 놓이면서 두 벌이 됐고 **곧바로 갈렸다** — 한쪽에만 `O_NONBLOCK` 이
//! 붙어 다른 쪽은 FIFO 에서 멈추는 채로 남았다(적대적 검증 4회차에서 잡았다). 그래서 여기로 올린다.
//!
//! 읽는 정책(무엇을 담고 무엇을 접나)은 호출자가 갖는다 — 이 모듈은 **여는 것**만 한다.

const std = @import("std");

/// 저장소 루트에서 시작해 경로 요소를 하나씩 `openat`으로 내려가며 연다. **각 단계가 `O_NOFOLLOW`**라
/// 어느 요소든 symlink면 그 자리에서 실패한다(ELOOP). 마지막 요소만 파일로 연다.
///
/// **마지막 요소만 막으면 안 되는 이유**: 중간 디렉터리가 링크면 저장소 밖이 열린다.
///
/// `error.NotFound` 를 따로 낸다 — 「그때 없었다」와 「못 읽었다」는 화면에서 다른 말이 되어야 한다
/// (`Write` 로 새 파일을 만드는 흐름이 전자다).
pub fn openNoFollow(root: []const u8, rel_path: []const u8) !c_int {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_z = std.fmt.bufPrintZ(&root_buf, "{s}", .{root}) catch return error.PathTooLong;
    // 루트 자체는 사용자가 연 폴더라 따라가도 된다(그 경로를 고른 것이 사용자다) — 그 **아래**부터 막는다.
    var dir_fd = std.c.open(root_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true });
    if (dir_fd < 0) return error.OpenFailed;

    var it = std.mem.splitScalar(u8, rel_path, '/');
    var pending: ?[]const u8 = it.next();
    while (pending) |segment| {
        const next = it.next();
        var seg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seg_z = std.fmt.bufPrintZ(&seg_buf, "{s}", .{segment}) catch {
            _ = std.c.close(dir_fd);
            return error.PathTooLong;
        };
        const is_last = next == null;
        // ⚠️ **마지막 요소는 `O_NONBLOCK` 으로 연다.** 저장소 안에 FIFO(named pipe)나 일부 장치 파일이
        // 있으면 `open(O_RDONLY)` 이 **쓰는 쪽이 나타날 때까지 블록한다** — 그리고 캡처는 **frame tick
        // 안에서** 돌므로 그 블록이 곧 **UI 정지**다(diff 의 `worktreeSide` 는 worker 스레드라 그 worker
        // 하나만 멈췄다 — 읽기를 tick 으로 옮기면서 성질이 바뀐 자리다).
        //
        // 정규 파일에서는 `O_NONBLOCK` 이 읽기 의미를 바꾸지 않는다. 정규 파일이 아닌 것은 호출자가
        // `fstat` 으로 걸러 낸다 — 여는 것과 읽는 것은 다른 판정이다.
        const flags: std.c.O = if (is_last)
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }
        else
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true };
        const opened = std.c.openat(dir_fd, seg_z.ptr, flags, @as(std.c.mode_t, 0));
        // **errno 를 close 전에 읽는다** — close 가 실패하면 errno 를 덮어써 «없다»가 «못 읽었다»로 바뀐다.
        const err = std.c._errno().*;
        _ = std.c.close(dir_fd);
        if (opened < 0) {
            // ⚠️ **`ENOTDIR` 을 «없다» 로 접으면 안 된다.** 중간 요소가 **디렉터리를 가리키는 심링크**면
            // `O_DIRECTORY|O_NOFOLLOW` 가 그 심링크를 디렉터리가 아니라고 보아 `ENOTDIR` 을 낸다 —
            // 「막았다」이지 「없다」가 아니다. 접으면 캡처가 **차단된 경로를 «그때 없었다»(`.absent`)로
            // 적어**, 그 파일이 «새로 생겼다» 로 둔갑한다. (실제로 `git_backend` 의 심링크 테스트가 이
            // 오분류를 잡았다 — 적대적 검증 5회차.)
            return if (err == @intFromEnum(std.c.E.NOENT)) error.NotFound else error.OpenFailed;
        }
        if (is_last) return opened;
        dir_fd = opened;
        pending = next;
    }
    _ = std.c.close(dir_fd);
    return error.OpenFailed; // rel_path가 비어 있었다(isSafeRelative가 이미 막지만 경로를 열어 두지 않는다)
}

/// 신뢰할 별도 root capability가 없는 absolute path용 변형이다. `/`부터 모든 component를
/// descriptor-relative로 내려가므로 중간 symlink도 따라가지 않는다. 마지막 component는 regular-file
/// 판정 전에 FIFO에서 멈추지 않도록 nonblocking으로 열며, `final_directory`이면 directory로 제한한다.
pub fn openAbsoluteNoFollow(path: [:0]const u8, final_directory: bool) !c_int {
    if (path.len == 0 or path[0] != '/') return error.UnsafePath;
    var current = std.c.open("/", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    });
    if (current < 0) return error.UnsafePath;
    errdefer _ = std.c.close(current);

    var iterator = std.mem.splitScalar(u8, path[1..], '/');
    while (iterator.next()) |component| {
        if (component.len == 0) {
            if (iterator.peek() == null) break;
            return error.UnsafePath;
        }
        if (!validAbsoluteComponent(component)) return error.UnsafePath;
        var name_buf: [std.fs.max_name_bytes:0]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{component}) catch return error.UnsafePath;
        const is_last = iterator.peek() == null;
        const flags: std.c.O = if (!is_last or final_directory)
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }
        else
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true };
        const next = std.c.openat(current, name.ptr, flags, @as(std.c.mode_t, 0));
        if (next < 0) return error.UnsafePath;
        _ = std.c.close(current);
        current = next;
    }
    return current;
}

fn validAbsoluteComponent(component: []const u8) bool {
    return component.len != 0 and component.len <= std.fs.max_name_bytes and
        !std.mem.eql(u8, component, ".") and !std.mem.eql(u8, component, "..") and
        std.mem.indexOfScalar(u8, component, 0) == null;
}
