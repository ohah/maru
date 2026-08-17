//! 컨트롤 플레인 **소켓 클라이언트** — 발견 → connect → `auth.self` → 요청 전송 → 응답 수신.
//!
//! **`cli/`에서 유일하게 impure한 모듈이다.** 나머지 `cli/*`(sessions·browser·runtime·trace)는 "파싱과
//! wire만, 소켓/OS 0"을 계약으로 선언한다. 그 계약을 지키려면 syscall 접착이 갈 곳이 필요한데, 예전에는
//! 그 자리가 `main.zig`였다 — 그래서 `main.zig`가 얇은 디스패처여야 한다는 규칙
//! ([docs/project-structure.md](../../docs/project-structure.md) `src/cli/`)과 정면으로 부딪쳤다.
//! 접착을 여기로 모으면 **두 규칙이 동시에 성립한다**: 순수 모듈은 계속 순수하고, main은 디스패치만 한다.
//!
//! **왜 `cli/` 안인가.** 이 코드의 소비자가 CLI 서브커맨드뿐이기 때문이다(`sessions`·`session`·`browser`).
//! GUI 쪽 컨트롤 플레인은 서버이고 `platform/macos/control_socket.zig`가 따로 소유한다 — 클라이언트와
//! 서버를 한 파일에 두면 "누가 누구에게 말하는가"가 흐려진다.
//!
//! 순수 정책(경로 규칙·소켓 선택 판정)은 여전히 [`sessions.zig`](sessions.zig)가 소유한다. 여기는
//! getenv·readdir·socket·connect·read·write **syscall만** 한다(§11 L4).
const std = @import("std");
const cp = @import("../session/control_plane.zig");
const sessions = @import("sessions.zig");
const builtin = @import("builtin");
const user_paths = @import("../user_paths.zig"); // 캐시 base·홈 판정(OS 인자 순수 정책 — 계약 §5.3)
const path_shape = @import("../path_shape.zig"); // 입구 구분자 정규화(계약 §5)

/// 컨트롤 소켓이 막힌 호스트에서 **사용자에게 보일 이유**. OS와 무관한 문구 그 자체이며, 단일 출처는 여기다 —
/// `main.zig`의 `HostGatedFeature.control_socket`이 이 값을 되돌려 준다(그 함수는 OS를 인자로 받아 Windows가
/// 아닌 호스트에서도 Windows 갈래를 답해야 하므로 아래 `gate`를 쓸 수 없다).
pub const gate_reason: []const u8 = "Windows에서는 컨트롤 소켓이 아직 지원되지 않습니다";

/// **이 빌드**에서 컨트롤 소켓이 막혀 있으면 이유, 열려 있으면 null.
///
/// **파일 스코프 const라 comptime으로 평가된다.** 그래서 `if (gate) |reason| return ...` 뒤의 POSIX 본문이
/// Windows에서 **의미 분석조차 되지 않고**, `socket`·`connect`가 undefined symbol이 되지 않는다(실측). 이것이
/// named pipe 이식 없이 Windows 빌드를 뚫는 방법이라, 런타임 분기로 바꾸면 링크가 깨진다.
pub const gate: ?[]const u8 = if (builtin.os.tag == .windows) gate_reason else null;

/// 살아있는 maru 인스턴스가 없거나 connect가 실패했을 때의 graceful 종료. stderr에 안내를 쓰고
/// `error.UnknownCommand`(main이 트레이스 없이 exit 1로 접는 sentinel)를 돌려준다 — 사용자 오타/부재에
/// crash처럼 보이지 않게. `detail`은 있으면 괄호로 덧붙인다.
pub fn noInstance(stderr: *std.Io.Writer, detail: ?[]const u8) error{UnknownCommand} {
    stderr.writeAll("실행 중인 maru 인스턴스를 찾지 못했습니다") catch {};
    if (detail) |d| stderr.print(" ({s})", .{d}) catch {};
    stderr.writeAll(".\n") catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

/// 부분 write를 처리하는 blocking write-all(소켓 stream). 성공하면 true.
/// `platform/macos/control_socket.zig`의 writeAll과 같은 결이지만, 그 파일은 서버 쪽이라 여기 둔다.
pub fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) bool {
    const c = std.c;
    const posix = std.posix;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// **컨트롤 소켓 발견→connect→auth→요청 전송(sessions/browser/screenshot CLI 공유)**: 결정론 경로(§4.2)에서 살아있는
/// 인스턴스 소켓 하나를 찾아 connect → `auth.self`(selector=`MARU_PANE_ID`·cap_nonce=null) → `request_bytes` 전송까지 한다.
/// 성공 시 **열린 fd**를 반환한다 — caller가 응답/chunk를 읽고 **close**한다(단일 응답=`fetchResponse`, chunk
/// 스트림=screenshot). 인스턴스 없음/connect 실패는 `noInstance`(graceful exit 1); 에러 반환 전 이미 만든 fd는
/// `errdefer`로 닫는다(성공 반환 시엔 caller 소유). 순수 정책(경로·발견 판정)은 `sessions.zig`, 여긴 getenv/readdir/소켓
/// syscall 접착만(§11 L4).
pub fn connectSend(io: std.Io, allocator: std.mem.Allocator, request_bytes: []const u8, stderr: *std.Io.Writer) !std.c.fd_t {
    // Windows에는 이 transport가 아직 없다(백로그 — 계약 §8 "컨트롤 플레인 transport"). **인스턴스 없음으로
    // 접는다**: 그것이 이미 있는 graceful 경로이고(소켓 디렉터리가 없을 때와 같은 결과), CLI가 crash 대신
    // exit 1로 끝난다. 이 early return은 comptime 참이라 아래 POSIX 본문이 **의미 분석조차 되지 않아**
    // `c.socket`이 undefined symbol이 되지 않는다(실측 확인) — 이것이 named pipe 이식 없이 빌드를 뚫는 방법이다.
    if (gate) |reason|
        return noInstance(stderr, reason);

    const c = std.c;
    const posix = std.posix;

    // ── 소켓 발견: 결정론 경로 <cache>/maru/control에서 살아있는 인스턴스 소켓 하나를 찾는다(§4.2) ──
    // base 판정은 `user_paths`가 소유한다 — terminfo 캐시와 **같은 규칙**이라야 두 캐시가 같은 뿌리에
    // 산다(계약 §5.3: Windows는 `%LOCALAPPDATA%`, 그 위로 `$XDG_CACHE_HOME`이 최우선).
    const home_env: ?[]const u8 = if (c.getenv("HOME")) |h| std.mem.span(h) else null;
    const local: ?[]const u8 = if (c.getenv("LOCALAPPDATA")) |l| std.mem.span(l) else null;
    const xdg: ?[]const u8 = if (c.getenv("XDG_CACHE_HOME")) |x| std.mem.span(x) else null;
    const base_raw = user_paths.cacheBaseFor(builtin.os.tag, xdg, local);
    const home_raw = user_paths.homeDirFor(builtin.os.tag, home_env, local) orelse
        return noInstance(stderr, "홈 디렉터리를 찾지 못해 컨트롤 소켓 위치를 정할 수 없습니다");
    // **입구 정규화**(계약 §5). 환경변수 값은 native 구분자다 — `%LOCALAPPDATA%`는 역슬래시라 안 하면
    // 같은 뿌리가 두 철자로 갈린다(`…\Local/maru/control`). `main.zig`의 terminfo 경로는 하고 있었고
    // 여기만 빠져 있었다 — 적대적 검증에서 잡았다.
    const base: ?[]const u8 = if (base_raw) |b| try path_shape.normalizeSeparators(allocator, b) else null;
    defer if (base) |b| allocator.free(b);
    const home = try path_shape.normalizeSeparators(allocator, home_raw);
    defer allocator.free(home);
    const control_dir = try sessions.controlDir(allocator, base, home);
    defer allocator.free(control_dir);

    // control dir을 열어 `.sock` 엔트리 이름을 모은다(못 열면 = 인스턴스 없음). readdir는 L4 I/O라 여기서 한다.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        var dir = std.Io.Dir.cwd().openDir(io, control_dir, .{ .iterate = true }) catch
            return noInstance(stderr, null);
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            // kind로 거르지 않는다 — 소켓 파일의 dir 엔트리 kind는 `.unix_domain_socket`(≠`.file`)이라 `.file`만
            // 받으면 소켓을 놓친다. `.sock` 접미사로만 거르고(같은 dir의 `<key>.lock`은 제외), 최종 판정은 pickSocket이 한다.
            if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name)); // entry.name은 iterator 버퍼(transient) → 복사
        }
    }

    // 발견 정책은 순수(1d pickSocket): 정확히 하나면 그 소켓, 없으면/여럿이면 graceful.
    const chosen = switch (sessions.pickSocket(names.items)) {
        .none => return noInstance(stderr, null),
        .multiple => return noInstance(stderr, "여러 maru 인스턴스가 있습니다 — 인스턴스 선택은 아직 지원되지 않습니다"),
        .single => |name| name,
    };
    const socket_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ control_dir, chosen }, 0);
    defer allocator.free(socket_path);

    // ── connect(L4 syscall — 1b가 std.c로 소켓을 쓰는 선례) ──
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return noInstance(stderr, "소켓을 만들 수 없습니다");
    errdefer _ = c.close(fd); // 에러 반환 시 닫는다 — 성공 반환(return fd) 시엔 caller가 소유·close
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return noInstance(stderr, null); // 경로가 sun_path 초과(비정상) → graceful
    @memcpy(addr.path[0..socket_path.len], socket_path);
    // 서버 부재(ENOENT)·stale 소켓(ECONNREFUSED) 등은 전부 graceful "인스턴스 없음"으로 접는다(crash·트레이스 금지).
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return noInstance(stderr, null);

    // ── A2b auth 셀렉터 전송(§8.4 1단계): caller가 자기 surface를 주장한다. maru 팬 셸엔 MARU_PANE_ID=<surface.id>가
    // 주입돼 있으므로(pty/macos appendParentEnv) 그 값을 self 셀렉터로 보낸다. maru 밖 shell엔 없어 null. cap_nonce=null:
    // CLI는 상속 capability fd(§8.5)를 안 읽는다 — browser 요청은 세션 cap 없이 §9.2 Model B needs_grant→확인 모달로 인가받는다. ──
    const selector: ?u64 = if (c.getenv("MARU_PANE_ID")) |pane|
        (std.fmt.parseInt(u64, std.mem.span(pane), 10) catch null)
    else
        null;
    const auth_bytes = try cp.serializeAuthSelf(allocator, selector, null);
    defer allocator.free(auth_bytes);
    if (!writeAllFd(fd, auth_bytes) or !writeAllFd(fd, "\n"))
        return noInstance(stderr, "auth 셀렉터 전송에 실패했습니다");

    // ── 요청 전송(응답/chunk 읽기는 caller) ──
    if (!writeAllFd(fd, request_bytes) or !writeAllFd(fd, "\n"))
        return noInstance(stderr, "요청 전송에 실패했습니다");
    return fd; // 성공 — caller가 읽고 close(errdefer 미발동)
}

/// **단일 응답 소켓 왕복(sessions/browser 단일-응답 CLI 공유)**: `connectSend`로 열고 hello notification skip 후
/// **첫 응답 프레임**을 alloc 소유 슬라이스로 반환(caller free·자기 kind로 render). EOF는 `noInstance`(graceful).
/// browser 요청은 grant 모달로 held될 수 있어 read가 오래 블록될 수 있다(짧은 타임아웃 금지 — §9.6).
pub fn fetchResponse(io: std.Io, allocator: std.mem.Allocator, request_bytes: []const u8, stderr: *std.Io.Writer) ![]u8 {
    const c = std.c;
    const fd = try connectSend(io, allocator, request_bytes, stderr);
    defer _ = c.close(fd);

    var framer: cp.Framer = .{};
    defer framer.deinit(allocator);
    while (true) {
        // 완결 프레임을 소비한다: hello(notification)는 서버가 accept 시 먼저 보내므로 skip, 그 밖(응답)이면 반환.
        while (framer.next() catch null) |line| {
            var pm = cp.parseMessage(allocator, line) catch
                return allocator.dupe(u8, line); // 손상 응답도 caller renderResponse가 안전하게 접는다
            const is_notification = pm.message == .notification;
            pm.deinit();
            if (is_notification) continue; // hello notification skip
            return allocator.dupe(u8, line); // 첫 응답(line은 framer 버퍼라 반환 전 복사)
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len); // browser grant held면 사용자 클릭까지 블록(§9.6)
        if (n <= 0) break; // EOF/에러 — 응답 없이 종료(grant 무응답 timeout 서버 reap 포함)
        framer.push(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    return noInstance(stderr, "서버가 응답하지 않았습니다");
}

test "컨트롤 소켓 gate는 Windows에서만 닫히고, 닫혔으면 이유가 비어 있지 않다" {
    // `gate`는 comptime 값이라 이 단언은 **이 빌드의 호스트**에 대해서만 돈다. 두 갈래를 모두 도는 검증은
    // OS를 인자로 받는 `main.zig`의 `hostGateReason` 테스트가 소유한다(공허참 회피는 거기서 한 번만).
    if (builtin.os.tag == .windows) {
        try std.testing.expect(gate != null);
        try std.testing.expect(gate.?.len > 0);
    } else {
        try std.testing.expect(gate == null);
    }
}
