//! 판정자가 띄우는 로컬 HTTP 서버(W1c). 쿠키 유지는 http 출처에서만 잴 수 있어(file: 은 쿠키가 없다) 페이지를
//! 메모리에서 바로 내보낸다. 127.0.0.1 의 빈 포트에만 묶는다.
//!
//!   /title?t=X    제목을 X 로
//!   /size         제목을 `w=<innerWidth>` 로, 크기가 바뀔 때마다 다시
//!   /cookie?v=N   제목을 `cookie=[<document.cookie>]` 로 한 뒤 쿠키 `maru_judge=N` 을 한 시간짜리로 심는다
//!   /popup        `window.open` 을 부른 뒤 제목을 `popup-tried` 로
//!   /vis          제목을 `vis=<document.visibilityState>` 로, 바뀔 때마다 다시
//!   /print        `window.print()` 를 부른 뒤 제목을 `print-tried` 로(인쇄 창이 뜨면 그 창이 닫힐 때까지 안 온다)
//!   /dialog       `alert`·`confirm`·`prompt` 를 부른 뒤 제목을 `dialog-<confirm>-<prompt>` 로
//!   /ctl          제목을 `a<BEL>b<DEL>c` 로(제어 문자가 든 제목)
//!   /flood        2 초 동안 제목을 1ms 마다 200 번씩 바꾼 뒤 `flood-done` 으로
//!   /tear         매 프레임 화면 전체를 빨강↔파랑으로 바꾼다(W2 찢어짐 판정 — 한 장 안의 줄 색이 달라지면 찢어진 것)

const std = @import("std");

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;

const SockaddrIn = extern struct {
    len: u8 = @sizeOf(SockaddrIn),
    family: u8 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;

/// 팝업 페이지(`/title?t=opened`)가 실제로 요청된 수. 창 없는 모드에서는 허용된 팝업이 **보이지 않는 브라우저**로
/// 뜨므로 창 수로는 못 잡는다(변이 실측) — 페이지가 불렸는지로 본다.
pub var opened_requests = std.atomic.Value(u32).init(0);

pub const Server = struct {
    fd: c_int,
    port: u16,

    pub fn start() !Server {
        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
        if (listen(fd, 16) != 0) return error.ListenFailed;
        var len: u32 = @sizeOf(SockaddrIn);
        if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
        const server: Server = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        const thread = try std.Thread.spawn(.{}, serve, .{fd});
        thread.detach();
        return server;
    }
};

fn serve(fd: c_int) void {
    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        handle(conn);
        _ = std.c.close(conn);
    }
}

fn handle(conn: c_int) void {
    var req: [4096]u8 = undefined;
    const n = std.c.read(conn, &req, req.len);
    if (n <= 0) return;
    const line_end = std.mem.indexOfScalar(u8, req[0..@intCast(n)], '\r') orelse return;
    var parts = std.mem.splitScalar(u8, req[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const query = if (std.mem.indexOfScalar(u8, target, '=')) |eq| target[eq + 1 ..] else "";

    var body_buf: [2048]u8 = undefined;
    const body = page(path, query, &body_buf) catch "<!doctype html><title>not-found</title>";
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn page(path: []const u8, query: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/title")) {
        if (std.mem.eql(u8, query, "opened")) _ = opened_requests.fetchAdd(1, .monotonic);
        return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><script>document.title='{s}'</script>", .{query});
    }
    if (std.mem.eql(u8, path, "/size")) {
        return "<!doctype html><title>loading</title><script>function t(){document.title='w='+innerWidth}t();addEventListener('resize',t)</script>";
    }
    if (std.mem.eql(u8, path, "/cookie")) {
        return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><script>document.title='cookie=['+document.cookie+']';document.cookie='maru_judge={s}; max-age=3600; path=/'</script>", .{query});
    }
    if (std.mem.eql(u8, path, "/tear")) {
        return "<!doctype html><title>tear</title><style>html,body{margin:0;height:100%}</style><body><script>let r=0;function f(){r^=1;document.body.style.background=r?'#ff0000':'#0000ff';requestAnimationFrame(f)}f()</script>";
    }
    if (std.mem.eql(u8, path, "/popup")) {
        return "<!doctype html><title>loading</title><script>window.open('/title?t=opened','_blank');document.title='popup-tried'</script>";
    }
    if (std.mem.eql(u8, path, "/vis")) {
        return "<!doctype html><title>loading</title><script>function t(){document.title='vis='+document.visibilityState}t();document.addEventListener('visibilitychange',t)</script>";
    }
    if (std.mem.eql(u8, path, "/print")) {
        return "<!doctype html><title>loading</title><body>print me<script>window.print();document.title='print-tried'</script>";
    }
    if (std.mem.eql(u8, path, "/dialog")) {
        return "<!doctype html><title>loading</title><script>alert('a');var r=confirm('b');var p=prompt('c','d');document.title='dialog-'+r+'-'+p</script>";
    }
    if (std.mem.eql(u8, path, "/ctl")) {
        return "<!doctype html><title>loading</title><script>document.title='a\\x07b\\x7fc'</script>";
    }
    if (std.mem.eql(u8, path, "/flood")) {
        return "<!doctype html><title>loading</title><script>var i=0;var h=setInterval(function(){for(var k=0;k<200;k++)document.title='f'+(i++)},1);setTimeout(function(){clearInterval(h);document.title='flood-done'},2000)</script>";
    }
    return error.NotFound;
}
