//! 판정자가 띄우는 로컬 HTTP 서버(W1c). 쿠키 유지는 http 출처에서만 잴 수 있어(file: 은 쿠키가 없다) 페이지를
//! 메모리에서 바로 내보낸다. 127.0.0.1 의 빈 포트에만 묶는다.
//!
//!   /title?t=X    제목을 X 로
//!   /size         제목을 `w=<innerWidth>` 로, 크기가 바뀔 때마다 다시
//!   /cookie?v=N   제목을 `cookie=[<document.cookie>]` 로 한 뒤 쿠키 `maru_judge=N` 을 한 시간짜리로 심는다
//!   /popup        `window.open` 을 부른 뒤 제목을 `popup-tried` 로
//!   /pa           팝업 이어 받기 판정(W6f①) — 팝업·이름 창·닫기·빈 팝업·10 번 단추, `/pa-popup` 은 원래 페이지에 `postMessage` 하고
//!                 온 화면 단추로 또 연다(`popupadopt_check.zig`)
//!   /newtab       새 탭 판정(W6e) — `_blank`·보통·`mailto:` 링크와 `window.open` 단추들(`newtab_check.zig`). `-focus` 는 `_blank`
//!                 링크에 포커스, `-auto` 는 입력 없이 열기를 시도한다
//!   /vis          제목을 `vis=<document.visibilityState>` 로, 바뀔 때마다 다시
//!   /print        `window.print()` 를 부른 뒤 제목을 `print-tried` 로(인쇄 창이 뜨면 그 창이 닫힐 때까지 안 온다)
//!   /dialog       `alert`·`confirm`·`prompt` 를 부른 뒤 제목을 `dialog-<confirm>-<prompt>` 로
//!   /dialog-hold  `alert('hold')` 에서 멈춘다(W5a — 떠 있을 때 이동)
//!   /unload       누르면 떠나기 확인을 건다(`unload-armed-<누른 수>`) — 사용자 동작 없이 건 확인은 Chromium 이 묻지 않는다. 준비는
//!                 `unload-ready`
//!   /dialog-loop  `alert` 를 다섯 번 부른 뒤 제목을 `loop-done` 으로(억제 판정)
//!   /dialog-reload `alert` 뒤 스스로 새로고침 — 세 번 뒤 `reload-done`(억제 우회 판정)
//!   /file·/files·/folder  화면 왼쪽 위(0,0 300×100)의 파일 입력칸(받을 형식 `image/*,.txt` · 여러 개 · 폴더). 준비는 `file-ready`, 고르면
//!                 렌더러가 내용을 읽어 `file-<수>-<이름들,정렬>-<바이트 합>`, 취소면 `file-cancel`
//!   /perm?a=X     권한 판정(W5b) — 누르면 X 를 청한다(`notif` 알림 · `midi` MIDI sysex · `fonts` 로컬 글꼴 · `screens` 창 관리 ·
//!                 `idle` 유휴 감지 · `geo` 위치 · `geox` 위치(`at<위도>,<경도>,<정확도>` — 시한 8 초) · `geolater` 한 문서에서 위치를 두 번 — 1.5 초 뒤 둘째(`at…|at…` 또는 `…|geo-err<코드>`) ·
//!                 `geoframe` 같은 출처 iframe(`allow=geolocation`)이 `geolater` 를 하고 결과를 위 문서 제목에(`geoframe:…`) ·
//!                 `nshow` 알림을 띄운다(누르면 `clicked<누른 횟수>`) · `nauto` 같은 것을 페이지가 뜨자마자 · `nforge` 권한을 `granted` 로 속여 알림을 띄우고 `maru` 가 든 전역 수를 제목에(`forged<이 문서>-<about:blank iframe>-g<다른 사이트 iframe>-g<sandbox iframe>-g<같은 출처 iframe>-g<다른 사이트 iframe 안의 iframe>`, 뒤 넷은 도착 순 — `nglobals`·`nnest` 가 맨 위에 postMessage) · `nxtop<포트>` 그 포트의 `nxframe`(같은 사이트·다른 출처 iframe)이 알림을 띄우고 제 `Notification.permission` 을 맨 위 제목에(`x<권한>`) · `nprerender` speculation rules 로 `nactivated` 를 미리 그리고 2 초 뒤 그리로 간다(`nactivated:g<전역 수>-a<미리 그렸으면 1>`) · `nsandbox` CSP `sandbox` 헤더로 불투명 출처가 된 주 프레임이 권한을 속여 알림을
//!                 띄운다(`sandboxed<maru 전역 수>-<self.origin>`) ·
//!                 `nflood` 페이지가 뜨자마자 알림 열 개 · `watch` 위치 지켜보기(3 초 뒤
//!                 `n<받은 수>-<위도·오류들>`) · `cam` 카메라 · `display` 화면 공유 · `displayleave` 화면 공유를 청하고 1.5 초 뒤 스스로
//!                 `/title?t=perm-left` 로 떠난다 · `displayfail` 같은데 닿지 않는 주소(`127.0.0.1:9`)로 떠난다 — 실패한 이동). 준비는 `X:ready`, 결과는 `X:<결과>`(`granted`·`ok`·`err-<이름>` — 글꼴은 `ok<수>`, 거절이면 빈 목록 `ok0`)
//!   /dnd          W6d① 끌어 놓기(`drag_check.zig` — 아래 `drag_page`)
//!   /ctl          제목을 `a<BEL>b<DEL>c` 로(제어 문자가 든 제목)
//!   /flood        2 초 동안 제목을 1ms 마다 200 번씩 바꾼 뒤 `flood-done` 으로
//!   /tear         매 프레임 화면 전체를 프레임 번호 색(`rgb(n&255, n>>8&255, 200)`)으로 칠한다(W2 — 한 장 안의 줄 색이
//!                 다르면 찢어진 것, 쥔 장의 색이 바뀌면 덮어쓴 것. 두 색만 번갈면 두 프레임 뒤의 덮어쓰기를 놓쳤다)
//!   /static       한 번 칠하고 멈춘 페이지(W2 — 그리기가 없어도 못 알린 링을 다시 알리는지)
//!   /input        입력 판정(W4) — 입력칸(0,0 300×40)·문단(y 100)·링크(y 200)·긴 본문. 첫 프레임 뒤에 `input-ready`(그 전의
//!                 입력은 렌더러가 버린다 — 실측). 입력이 만든 마지막 상태를 제목으로
//!                 (`click:x,y,button,detail` · `dbl:2` · `val:` · `comp-val:` · `end:조합:값` · `key:e:ctrl:KeyE` · `blur` ·
//!                 `ctx:x,y` · `aux:1` · `sel:yes|no` · `leave` · `scroll:down`). 제목은 조절돼 마지막 것만 오므로 한 입력이
//!                 제목을 둘 바꾸지 않게 이벤트를 골랐다
//!   /sel          팝업 판정(W6a) — `<select>` 하나. 고르면 `sel:<값>` 제목, 첫 프레임 뒤 `sel-ready`
//!   /keys?칸      특수 키 판정(W4c) — textarea(t)·폼 입력칸 둘(j·k). 칸(`t`·`j`)을 누르면 준비. 초점 칸·값(줄바꿈은 `NL`)·
//!                 캐럿을 제목으로(`focus=… val=… caret=…`)

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
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
const sol_socket: c_int = 0xffff;
const so_rcvtimeo: c_int = 0x1006;
const Timeval = extern struct { sec: i64, usec: i32 };

/// 팝업 페이지(`/title?t=opened`)가 실제로 요청된 수. 창 없는 모드에서는 허용된 팝업이 **보이지 않는 브라우저**로
/// 뜨므로 창 수로는 못 잡는다(변이 실측) — 페이지가 불렸는지로 본다.
pub var opened_requests = std.atomic.Value(u32).init(0);
/// 새 탭 판정(W6e)의 주소(`/title?t=nt-…`)가 요청된 수 — sidecar 가 팝업 브라우저를 만들었다면 그 주소를 불렀을 것이다.
pub var newtab_requests = std.atomic.Value(u32).init(0);
/// `/flaky.svg` 를 받은 수(W6c) — 첫 요청은 HTML(깨진 이미지), 그 뒤는 진짜 SVG. 못 받은 이미지의 「이미지 복사」가 다시 받으면
/// 성공하게 만들어, 허용 규칙이 그 명령을 막는지를 판정이 가를 수 있게 한다.
pub var flaky_requests = std.atomic.Value(u32).init(0);
const flaky_svg = "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'><rect width='60' height='60' fill='blue'/></svg>";

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
        // 요청 없이 미리 열어 둔 연결(Chromium 의 preconnect — speculation rules 판정에서 실측)에 한 스레드 서버가 묶이지 않게.
        const timeout: Timeval = .{ .sec = 1, .usec = 0 };
        _ = setsockopt(conn, sol_socket, so_rcvtimeo, &timeout, @sizeOf(Timeval));
        handle(conn);
        _ = std.c.close(conn);
    }
}

/// W6d③ 이미지 — 48×48 빨간 PNG(판정자가 끌어낸 파일 내용과 바이트로 대조한다).
pub const red_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x30\x00\x00\x00\x30\x08\x02\x00\x00\x00\xd8\x60\x6e\xd0\x00\x00\x00\x41\x49\x44\x41\x54\x78\x9c\xed\xce\x41\x0d\x00\x30\x10\x04\xa1\xf3\x6f\xba\x95\xb1\xf3\x20\x41\x00\xf7\xee\x52\xf6\x03\x21\x21\x21\xa1\x98\xfd\x40\x48\x48\x48\x28\x66\x3f\x10\x12\x12\x12\x8a\xd9\x0f\x84\x84\x84\x84\x62\xf6\x03\x21\x21\x21\xa1\x98\xfd\xa0\x1e\xfa\xdf\x13\xf7\x79\x5f\x8b\x00\x88\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
var big_svgs: [2]?[]u8 = .{ null, null };

/// `/img/<종류>/<이름>`(W6d③): `png` PNG, `pngcd` PNG + `Content-Disposition: attachment; filename="../../evil.command"`,
/// `big6`·`big40` 그만큼 MiB 의 SVG(주석으로 채운다 — 파일 상한 32 MiB 안과 밖).
fn image(conn: c_int, rest: []const u8) void {
    var hb: [512]u8 = undefined;
    var body: []const u8 = red_png;
    var ctype: []const u8 = "image/png";
    var extra: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "pngcd/")) extra = "Content-Disposition: attachment; filename=\"../../evil.command\"\r\n";
    const big: ?usize = if (std.mem.startsWith(u8, rest, "big6/")) 0 else if (std.mem.startsWith(u8, rest, "big40/")) 1 else null;
    if (big) |i| {
        ctype = "image/svg+xml";
        if (big_svgs[i] == null) {
            const mib: usize = if (i == 0) 6 else 40;
            const size = mib * 1024 * 1024;
            const b = std.heap.c_allocator.alloc(u8, size) catch return;
            const head_s = "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'><rect width='48' height='48' fill='green'/><!--";
            const tail_s = "--></svg>";
            @memcpy(b[0..head_s.len], head_s);
            @memset(b[head_s.len .. size - tail_s.len], 'x');
            @memcpy(b[size - tail_s.len ..], tail_s);
            big_svgs[i] = b;
        }
        body = big_svgs[i].?;
    }
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n", .{ ctype, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    var off: usize = 0;
    while (off < body.len) {
        const w = std.c.write(conn, body[off..].ptr, body.len - off);
        if (w <= 0) break;
        off += @intCast(w);
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
    if (std.mem.startsWith(u8, path, "/img/")) return image(conn, path["/img/".len..]);
    if (std.mem.eql(u8, path, "/dl/tone.wav")) return tone(conn);
    if (std.mem.startsWith(u8, path, "/dl/f/")) return download(conn, path["/dl/f/".len..]);

    var body_buf: [8192]u8 = undefined;
    const flaky_image = std.mem.eql(u8, path, "/flaky.svg") and flaky_requests.fetchAdd(1, .monotonic) > 0;
    const body = if (flaky_image) flaky_svg else page(path, query, &body_buf) catch "<!doctype html><title>not-found</title>";
    const content_type = if (flaky_image) "image/svg+xml" else "text/html; charset=utf-8";
    var head_buf: [320]u8 = undefined;
    // `/perm?a=nsandbox` 는 CSP sandbox 로 — 주 프레임이 불투명 출처가 된다(같은 프로세스에 남는다).
    const csp = if (std.mem.eql(u8, path, "/perm") and std.mem.eql(u8, query, "nsandbox")) "Content-Security-Policy: sandbox allow-scripts\r\n" else "";
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ content_type, body.len, csp }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

/// W10a 판정의 받을 파일(`download_check.zig`) — 첨부로 내려 보낸다.
pub const download_body = "maru-download-report\n" ** 40;
/// `slow` 의 크기와 조각 — 64 KiB 를 0.1 초마다(약 5 초). 받는 동안 진행 갱신·취소·닫기를 본다.
pub const slow_bytes: usize = 50 * slow_chunk;
const slow_chunk: usize = 64 * 1024;

/// `/dl/f/<종류>`: `attach` 첨부 report.txt, `ctl` 제어 문자·`/`·`..` 를 품은 `filename*` 이름, `slow` 느린 3 MiB slow.bin
/// (한 스레드 서버를 묶지 않게 따로 스레드에서 보낸다).
fn download(conn: c_int, kind: []const u8) void {
    var hb: [512]u8 = undefined;
    if (std.mem.eql(u8, kind, "slow")) {
        const own = std.c.dup(conn);
        if (own < 0) return;
        const thread = std.Thread.spawn(.{}, slowDownload, .{own}) catch {
            _ = std.c.close(own);
            return;
        };
        thread.detach();
        return;
    }
    const disposition = if (std.mem.eql(u8, kind, "ctl"))
        "attachment; filename*=UTF-8''a%01b%0Ac%2F..%2Fd.txt"
    else
        "attachment; filename=\"report.txt\"";
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nContent-Disposition: {s}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ download_body.len, disposition }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, download_body.ptr, download_body.len);
}

fn slowDownload(conn: c_int) void {
    defer _ = std.c.close(conn);
    var hb: [320]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nContent-Disposition: attachment; filename=\"slow.bin\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{slow_bytes}) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    const chunk = [_]u8{'s'} ** slow_chunk;
    var sent: usize = 0;
    while (sent < slow_bytes) : (sent += slow_chunk) {
        if (std.c.write(conn, &chunk, chunk.len) != @as(isize, @intCast(chunk.len))) return; // 받는 쪽이 끊었다
        @import("os.zig").sleepMs(100);
    }
}

/// W6h② 판정의 소리 — 0.2 초 무음 WAV(8 kHz 모노 16 비트).
fn tone(conn: c_int) void {
    const samples = 1600;
    var wav: [44 + samples * 2]u8 = [_]u8{0} ** (44 + samples * 2);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + samples * 2, .little);
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 8000, .little);
    std.mem.writeInt(u32, wav[28..32], 16000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], samples * 2, .little);
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{wav.len}) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, &wav, wav.len);
}

/// W6h② 판정 페이지 — 자리는 `media_check.zig` 와 맞춘다. 0.1 초마다 상태를 제목으로(iframe 은 `postMessage`). `?s=1` 이면 d1 을
/// 우클릭하고 0.2 초 뒤 같은 주소의 d1·d2 자리를 바꾼다(주소로는 가를 수 없다 — 우클릭 때 찾아 둔 요소여야 한다).
const media_page =
    "<!doctype html><title>loading</title><style>body{margin:0}audio,iframe,video{position:absolute;border:0}</style><body>" ++
    "<audio id=a controls src='/dl/tone.wav?a' style='left:10px;top:10px;width:300px;height:40px'></audio>" ++
    "<audio id=b controls src='/dl/tone.wav?b' style='left:330px;top:10px;width:300px;height:40px'></audio>" ++
    "<iframe src='/media-inner?id=f' style='left:10px;top:70px;width:320px;height:60px'></iframe>" ++
    "<iframe id=x style='left:10px;top:150px;width:320px;height:60px'></iframe>" ++
    "<video id=v style='left:10px;top:230px;width:320px;height:180px;background:#000'></video>" ++
    // 같은 주소 둘(d1·d2 — 주소로 찾는 보조 경로로는 어느 것인지 모른다, DevTools 경로가 있어야 한다)과 같은 출처 iframe 의 같은 주소 둘,
    // 다른 사이트 iframe 의 같은 주소 둘(보조 경로는 아무것도 하지 않아야 한다).
    "<audio id=d1 controls src='/dl/tone.wav?dup' style='left:340px;top:230px;width:290px;height:40px'></audio>" ++
    "<audio id=d2 controls src='/dl/tone.wav?dup' style='left:340px;top:290px;width:290px;height:40px'></audio>" ++
    "<iframe src='/media-inner?id=g' style='left:340px;top:70px;width:290px;height:150px'></iframe>" ++
    "<iframe id=y style='left:10px;top:420px;width:620px;height:55px'></iframe><script>" ++
    "document.getElementById('y').src='http://localhost:'+location.port+'/media-inner?id=y';" ++
    "document.getElementById('x').src='http://localhost:'+location.port+'/media-inner?id=x';" ++
    "var st={},ready=false,swapped=false,a=document.getElementById('a'),b=document.getElementById('b'),v=document.getElementById('v'),d1=document.getElementById('d1'),d2=document.getElementById('d2');" ++
    "addEventListener('message',function(e){st[e.data.id]=e.data.v});" ++
    "if(location.search.indexOf('s=1')>=0)d1.addEventListener('contextmenu',function(){setTimeout(function(){d1.style.top='290px';d2.style.top='230px';swapped=true},200)});" ++
    "var c=document.createElement('canvas');c.width=64;c.height=36;var g=c.getContext('2d'),t=0;setInterval(function(){g.fillStyle='hsl('+(t++*9%360)+',70%,50%)';g.fillRect(0,0,64,36)},40);" ++
    "var r=new MediaRecorder(c.captureStream(25),{mimeType:'video/webm'}),parts=[];r.ondataavailable=function(e){parts.push(e.data)};" ++
    "r.onstop=function(){v.src=URL.createObjectURL(new Blob(parts,{type:'video/webm'}));v.onloadedmetadata=function(){ready=true}};r.start();setTimeout(function(){r.stop()},1200);" ++
    "function q(k){return st[k]===undefined?'-':st[k]}" ++
    "setInterval(function(){document.title='m a'+(+a.loop)+' b'+(+b.loop)+' f'+q('f')+' x'+q('x')+' vl'+(+v.loop)+' vc'+(+v.controls)+' d'+(+d1.loop)+(+d2.loop)+' g'+q('g')+' y'+q('y')+(ready&&st.f!==undefined&&st.x!==undefined&&st.g!==undefined&&st.y!==undefined?'':' wait')+(swapped?' swapped':'')},100)" ++
    "</script>";

/// 새 탭 판정(W6e)의 페이지 — 자리는 `newtab_check.zig` 와 맞춘다(140×30 칸).
const newtab_page =
    "<!doctype html><title>loading</title><style>body{margin:0;font:12px sans-serif}a,button{position:absolute;width:120px;height:30px;display:block;box-sizing:border-box;border:1px solid #888;padding:0;margin:0;background:#eee}</style><body>" ++
    "<a id=ab style='left:0;top:10px' href='/title?t=nt-ab' target=_blank>ab</a>" ++
    "<a id=pl style='left:140px;top:10px' href='/title?t=nt-pl'>pl</a>" ++
    "<a id=ml style='left:280px;top:10px' href='mailto:a@b.example'>ml</a>" ++
    "<button style='left:0;top:60px' onclick=\"window.open('/title?t=nt-w1')\">w1</button>" ++
    "<button style='left:140px;top:60px' onclick=\"window.open('/title?t=nt-wf','f','width=300,height=200')\">wf</button>" ++
    "<button style='left:280px;top:60px' onclick=\"for(var i=0;i<10;i++)window.open('/title?t=nt-m'+i)\">m10</button>" ++
    "<button style='left:0;top:110px' onclick=\"window.open()\">bl</button>" ++
    "<button style='left:140px;top:110px' onclick=\"window.open('javascript:void(0)')\">js</button>" ++
    "<a style='left:280px;top:110px' href='data:text/html,hi' target=_blank>dl</a>" ++
    "<button style='left:0;top:160px' onclick=\"setTimeout(function(){window.open('/title?t=nt-late')},2500)\">late</button>" ++
    "<button style='left:420px;top:160px' onclick=\"var n=0,t=setInterval(function(){window.open('/title?t=nt-r'+(n++));if(n>11)clearInterval(t)},400)\">rep</button>" ++
    // W6h①: 새 탭에서 이미지 열기 — http 이미지와 `data:` 이미지(열 수 없다).
    "<img style='position:absolute;left:140px;top:160px;width:120px;height:30px' src='/img/png/nt-image.png'>" ++
    "<img style='position:absolute;left:280px;top:160px;width:120px;height:30px' src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='>" ++
    // 놓기를 받는 칸 — 받은 뒤(이동 없음) 입력 없이 만든 ⌘ 클릭을 보낸다(W6e 적대 검증 2 차 — 놓기 표시가 그 클릭을 지금 탭 이동으로 두지 않게).
    "<div style='position:absolute;left:420px;top:60px;width:120px;height:80px;background:#fcc' ondragenter='event.preventDefault()' ondragover='event.preventDefault()' " ++
    "ondrop=\"event.preventDefault();setTimeout(function(){document.getElementById('pl').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}));document.title='nt-dropped'},300)\">dz</div>" ++
    // 같은 것을 2.5 초 뒤에 — 놓은 주소와 같은 링크여도 놓기 뒤 2 초가 지나면 놓기 이동이 아니다.
    "<div style='position:absolute;left:560px;top:60px;width:70px;height:80px;background:#cfc' ondragenter='event.preventDefault()' ondragover='event.preventDefault()' " ++
    "ondrop=\"event.preventDefault();setTimeout(function(){document.getElementById('pl').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}));document.title='nt-dropped-late'},2500)\">dz2</div>";

const frame_page_head = "<!doctype html><title>loading</title><style>html,body{margin:0}body{height:3000px}#m{position:fixed;left:480px;top:200px;width:150px;height:40px}" ++
    "iframe{position:absolute;left:50px;top:150px;width:400px;height:300px;border:4px solid #000;padding:6px}</style><body><input id=m list=l><datalist id=l><option value=a><option value=b></datalist>";
const frame_page_tail = "<script>addEventListener('message',function(e){if(e.data==='scrollme')scrollBy(0,100)});document.getElementById('m').addEventListener('keydown',function(e){if(e.key!=='a')return;var x=document.getElementById('x');if(x)x.contentWindow.postMessage('steal','*')});addEventListener('scroll',function(){document.title='sy:'+scrollY});addEventListener('message',function(e){if(e.data==='remove'){var x=document.getElementById('x');if(x)x.remove();document.title='removed'}else if(typeof e.data==='string')document.title=e.data})</script>";

fn page(path: []const u8, query: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/title")) {
        if (std.mem.eql(u8, query, "opened")) _ = opened_requests.fetchAdd(1, .monotonic);
        if (std.mem.startsWith(u8, query, "nt-")) _ = newtab_requests.fetchAdd(1, .monotonic);
        return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><script>document.title='{s}'</script>", .{query});
    }
    if (std.mem.eql(u8, path, "/size")) {
        return "<!doctype html><title>loading</title><script>function t(){document.title='w='+innerWidth}t();addEventListener('resize',t)</script>";
    }
    if (std.mem.eql(u8, path, "/cookie")) {
        return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><script>document.title='cookie=['+document.cookie+']';document.cookie='maru_judge={s}; max-age=3600; path=/'</script>", .{query});
    }
    if (std.mem.eql(u8, path, "/tear")) {
        return "<!doctype html><title>tear</title><style>html,body{margin:0;height:100%}</style><body><script>let n=0;function f(){n++;document.body.style.background='rgb('+(n&255)+','+((n>>8)&255)+',200)';requestAnimationFrame(f)}f()</script>";
    }
    if (std.mem.eql(u8, path, "/static")) {
        return "<!doctype html><title>static</title><style>html,body{margin:0;height:100%;background:#20a060}</style><body>";
    }
    if (std.mem.eql(u8, path, "/input")) return input_page;
    if (std.mem.eql(u8, path, "/keys")) return keys_page;
    if (std.mem.eql(u8, path, "/sel")) return select_page;
    if (std.mem.eql(u8, path, "/tip") or std.mem.eql(u8, path, "/tip2")) return tooltip_page;
    if (std.mem.eql(u8, path, "/cm")) return context_menu_page;
    // 팝업 이어 받기 판정(W6f①) — 자리는 `popupadopt_check.zig` 와 맞춘다.
    if (std.mem.eql(u8, path, "/pa")) return "<!doctype html><title>loading</title><style>body{margin:0}button{position:absolute;width:120px;height:30px}</style><body>" ++
        "<button style='left:0;top:10px' onclick=\"window.w=window.open('/pa-popup','pp')\">op</button>" ++
        "<button style='left:140px;top:10px' onclick=\"window.nm=window.open('/title?t=pa-n1','nm');setTimeout(function(){var b=window.open('/title?t=pa-n2','nm');r('same='+(window.nm===b))},1000)\">nm</button>" ++
        "<button style='left:280px;top:10px' onclick=\"window.w.close();setTimeout(function(){r('afterclose='+window.w.closed)},1500)\">cl</button>" ++
        "<button style='left:420px;top:10px' onclick=\"var x=window.open('','_blank');if(x){x.document.write('<title>written</title>');r('wtitle='+x.document.title)}\">bw</button>" ++
        "<button style='left:0;top:60px' onclick=\"for(var i=0;i<10;i++)window.open('/pa-popup?'+i)\">m10</button>" ++
        "<button style='left:140px;top:60px' onclick=\"window.open('/title?t='+'x'.repeat(40000))\">lg</button>" ++
        "<script>function r(s){document.title+=' '+s}addEventListener('message',function(e){r('msg='+e.data)});onload=function(){document.title='pa ready'}</script>";
    // 이어 받은 팝업 — 원래 페이지에 알리고, 온 화면 단추로 또 연다(중첩).
    if (std.mem.eql(u8, path, "/pa-popup")) return "<!doctype html><title>loading</title><style>body{margin:0}button{position:absolute;left:0;top:0;width:100%;height:100%}</style><body>" ++
        "<button onclick=\"window.open('/title?t=pa-nested')\">nest</button>" ++
        "<script>if(window.opener)window.opener.postMessage('from-popup','*');document.title='pa-popup opener='+(!!window.opener)</script>";
    if (std.mem.eql(u8, path, "/newtab")) return newtab_page ++ "<script>onload=function(){document.title='nt-ready'}</script>";
    if (std.mem.eql(u8, path, "/newtab-focus")) return newtab_page ++ "<script>onload=function(){document.getElementById('ab').focus();document.title='nt-focused'}</script>";
    // 입력 없이 연다 — `window.open`(Chromium 이 막는다), 만든 ⌘ 클릭(제스처 0 으로 sidecar 에 온다 — 착수 전 실측), `click()`.
    if (std.mem.eql(u8, path, "/newtab-auto")) return newtab_page ++
        "<script>onload=function(){setTimeout(function(){window.open('/title?t=nt-a1');" ++
        "document.getElementById('pl').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}));" ++
        "document.getElementById('ab').click();document.title='nt-auto-done'},300)}</script>";
    if (std.mem.eql(u8, path, "/dnd")) return drag_page;
    if (std.mem.eql(u8, path, "/media")) return media_page;
    // 안쪽 frame — `id=g`·`id=y` 는 같은 주소 오디오 둘(위·아래, 상태는 두 자리 숫자), 그 밖은 하나.
    if (std.mem.eql(u8, path, "/media-inner")) return std.fmt.bufPrint(buf, "<!doctype html><title>inner</title><style>body{{margin:0}}audio{{display:block;width:280px;height:40px;margin:0 0 20px}}</style>" ++
        "<audio controls src='/dl/tone.wav?{s}'></audio><script>var two=(location.search.indexOf('id=g')>=0||location.search.indexOf('id=y')>=0);" ++
        "if(two){{var x=document.createElement('audio');x.controls=true;x.src='/dl/tone.wav?{s}';document.body.appendChild(x)}}" ++
        "var ms=document.querySelectorAll('audio');setInterval(function(){{var v='';for(var i=0;i<ms.length;i++)v+=(+ms[i].loop);parent.postMessage({{id:'{s}',v:v}},'*')}},100)</script>", .{ query, query, query });
    // W6h② 1 회차: 1.5 KB 주소의 같은 주소 오디오 둘(서명 URL 처럼 긴 주소 — DevTools 경로가 필요하다).
    if (std.mem.eql(u8, path, "/media-long")) return "<!doctype html><title>loading</title><style>body{margin:0}audio{position:absolute;left:10px;width:300px;height:40px}</style>" ++
        "<audio id=l1 controls style='top:10px'></audio><audio id=l2 controls style='top:80px'></audio><script>" ++
        "var u='/dl/tone.wav?'+new Array(1501).join('x');var l1=document.getElementById('l1'),l2=document.getElementById('l2');l1.src=u;l2.src=u;" ++
        "setInterval(function(){document.title='l '+(+l1.loop)+(+l2.loop)+(l1.readyState>0&&l2.readyState>0?'':' wait')},100)</script>";
    // W6h② 2 회차: 우클릭하면 0.2 초 뒤 페이지가 스스로 연속 재생을 켠다 — 메뉴는 꺼짐으로 보였으니 「연속 재생」은 켜짐으로 둔다(뒤집으면 꺼진다).
    if (std.mem.eql(u8, path, "/media-want")) return "<!doctype html><title>loading</title><style>body{margin:0}audio{position:absolute;left:10px;top:10px;width:300px;height:40px}</style>" ++
        "<audio id=w controls src='/dl/tone.wav?w'></audio><script>var w=document.getElementById('w');" ++
        "w.addEventListener('contextmenu',function(){setTimeout(function(){w.loop=true},200)});" ++
        "setInterval(function(){document.title='w '+(+w.loop)+(w.readyState>0?'':' wait')},100)</script>";
    // W6h② 4 회차: 우클릭하면 0.2 초 뒤 플레이어처럼 해시를 바꾼다 — 같은 출처라 「연속 재생」은 그대로 된다.
    if (std.mem.eql(u8, path, "/media-hash")) return "<!doctype html><title>loading</title><style>body{margin:0}audio{position:absolute;left:10px;top:10px;width:300px;height:40px}</style>" ++
        "<audio id=h controls src='/dl/tone.wav?h'></audio><script>var h=document.getElementById('h');" ++
        "h.addEventListener('contextmenu',function(){setTimeout(function(){history.replaceState(null,'','#t=12')},200)});" ++
        "setInterval(function(){document.title='h '+(+h.loop)+(location.hash?' hashed':'')+(h.readyState>0?'':' wait')},100)</script>";
    // W6h② 5 회차: 불러오지 못하는 오디오(404 — 오류 상태) — 연속 재생·새 탭이 꺼진다(Chrome — `IN_ERROR`·`CAN_SAVE`).
    if (std.mem.eql(u8, path, "/media-err")) return "<!doctype html><title>loading</title><style>body{margin:0}audio{position:absolute;left:10px;top:10px;width:300px;height:40px}</style>" ++
        "<audio id=e controls src='/missing.wav'></audio><script>var e=document.getElementById('e');" ++
        "setInterval(function(){document.title='e '+(e.error?'error':'wait')},100)</script>";
    if (std.mem.eql(u8, path, "/media-scroll")) return "<!doctype html><title>loading</title><style>body{margin:0;height:3000px}audio{position:absolute;left:10px;width:300px;height:40px}</style>" ++
        "<audio id=s1 controls src='/dl/tone.wav?s' style='top:30px'></audio><audio id=s2 controls src='/dl/tone.wav?s' style='top:530px'></audio><script>" ++
        "onload=function(){scrollTo(0,500);setInterval(function(){document.title='s y'+scrollY+' s'+(+document.getElementById('s1').loop)+(+document.getElementById('s2').loop)},100)}</script>";
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
    if (std.mem.eql(u8, path, "/dialog-hold")) {
        return "<!doctype html><title>loading</title><script>alert('hold');document.title='after-hold'</script>";
    }
    // W6m①: 제안 목록 — 왼쪽 열 a(목록)·b(목록 없음 — 누르면 페이지가 a 에 가짜 `input` 을 보낸다)·c(search + 목록)·d(date + 목록),
    // 오른쪽 열 e(readonly + 목록)·f(안이 스크롤되는 상자). 300×40 칸을 100 px 간격으로, 문서도 스크롤된다. 입력·고르기의 `input`·
    // `change` 는 제목으로 보인다(`종류:칸:값`).
    if (std.mem.eql(u8, path, "/datalist")) return "<!doctype html><title>loading</title><style>html,body{margin:0}body{height:3000px}input{position:fixed;left:0;width:300px;height:40px;font-size:20px;border:0;padding:0}" ++
        "#f{position:fixed;left:320px;top:100px;width:300px;height:80px;overflow:scroll}</style><body>" ++
        "<input id=a list=l style='top:0'><input id=b style='top:100px'><input id=c type=search list=l style='top:200px'><input id=d type=date list=l style='top:300px'>" ++
        "<input id=e readonly list=l style='top:0;left:320px'><div id=f><div style='height:1000px'>scroll</div></div>" ++
        "<input id=g list=k style='top:200px;left:320px;width:60px'><datalist id=k><option value='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'></datalist>" ++
        "<datalist id=l><option value='apple'><option value='Apple pie'><option value='pineapple'><option value=''>empty value</option><option value='banana' label='yellow fruit'><option value='APRICOT'>" ++
        "<option value='cherry'>Cherry text</option><option value='avocado' disabled><option value='grape' label='purple'>purple text</option></datalist>" ++
        "<script>['input','change'].forEach(function(t){document.addEventListener(t,function(e){document.title=t+':'+e.target.id+':'+e.target.value},true)});" ++
        "document.getElementById('f').addEventListener('scroll',function(){document.title='f-scrolled'});document.getElementById('g').addEventListener('scroll',function(){document.title='g-scrolled'});" ++
        "document.getElementById('b').addEventListener('mousedown',function(){var a=document.getElementById('a');a.value='p';a.dispatchEvent(new Event('input',{bubbles:true}))});document.title='dl-ready'</script>";
    if (std.mem.eql(u8, path, "/datalist-many")) return "<!doctype html><title>loading</title><style>html,body{margin:0}input{position:fixed;left:0;top:0;width:300px;height:40px}</style><body><input id=a list=l><datalist id=l></datalist>" ++
        "<script>var l=document.getElementById('l');for(var i=0;i<300;i++){var o=document.createElement('option');o.value='item '+i;l.appendChild(o)}document.title='dl-many-ready'</script>";
    // 레이블 600 자 옵션 256 개 — 보이는 글을 자르고 모아 둔 한도에서 멈춘다(적대 검증 — 글 상한을 넘어 목록이 아예 안 떴다).
    if (std.mem.eql(u8, path, "/datalist-long")) return "<!doctype html><title>loading</title><style>html,body{margin:0}input{position:fixed;left:0;top:0;width:300px;height:40px}</style><body><input id=a list=l><datalist id=l></datalist>" ++
        "<script>var l=document.getElementById('l'),x='x'.repeat(600);for(var i=0;i<256;i++){var o=document.createElement('option');o.value='v'+i;o.label=x;l.appendChild(o)}document.title='dl-long-ready'</script>";
    // 같은 출처 http iframe(스크립트가 돈다 — srcdoc 은 http 가 아니라 처음부터 빠져 판정이 저절로 통과했다)과 주 프레임 칸(양성 대조).
    // W6m③: iframe 안의 칸 — 내용 상자 원점은 (60,160)(left 50·top 150 + 테두리 4 + 안쪽 여백 6), 문서는 길다(최상위 스크롤).
    // 같은 출처(`/datalist-frame`)와 다른 출처(`/datalist-xframe` — localhost)는 같은 모양. 안쪽 칸의 input·change 와 「떼어 내기」는
    // 바깥에 postMessage 로 알린다(바깥 페이지가 제목으로 — 다른 출처도). 주 프레임 칸은 오른쪽(480,200).
    if (std.mem.eql(u8, path, "/datalist-zframe")) return frame_page_head ++ "<style>iframe{transform:scale(1.5);transform-origin:0 0}</style><iframe id=x src='/datalist-inner' onload=\"document.title='dl-frame-ready'\"></iframe>" ++ frame_page_tail;
    if (std.mem.eql(u8, path, "/datalist-frame") or std.mem.eql(u8, path, "/datalist-xframe")) {
        const cross = std.mem.eql(u8, path, "/datalist-xframe");
        return if (cross) frame_page_head ++ "<iframe id=x></iframe><script>var x=document.getElementById('x');x.onload=function(){document.title='dl-frame-ready'};x.src='http://localhost:'+location.port+'/datalist-inner'</script>" ++ frame_page_tail else frame_page_head ++ "<iframe id=x src='/datalist-inner' onload=\"document.title='dl-frame-ready'\"></iframe>" ++ frame_page_tail;
    }
    if (std.mem.eql(u8, path, "/datalist-inner")) return "<!doctype html><title>inner</title><style>html,body{margin:0}input{width:300px;height:40px;border:0;padding:0}</style><input id=f list=l><datalist id=l><option value=a><option value=b><option value=zebra><option value=nut><option value=scroll></datalist>" ++
        "<script>var f=document.getElementById('f');function tell(m){parent.postMessage(m,'*')}f.addEventListener('input',function(){tell('in-input:'+f.value);if(f.value==='z')setTimeout(function(){tell('remove')},400);if(f.value==='n')setTimeout(function(){location.href='/datalist-inner?moved'},400);if(f.value==='s')setTimeout(function(){tell('scrollme')},400)});f.addEventListener('change',function(){tell('in-change:'+f.value)});" ++
        // 페이지가 보낸 가짜 포인터 사건 — 원점을 view 안의 (300,100) 으로 속이려 한다(대리 스크립트는 신뢰된 사건만 본다 — view 밖이면
        // 받아들여도 sidecar 가 버려 가리지 못했다, 변이 1 묶음).
        "dispatchEvent(new MouseEvent('mousemove',{screenX:300,screenY:100,clientX:0,clientY:0,bubbles:true}));" ++
        // 바깥이 시키면 스스로 초점을 주고 칸을 비운 뒤 일치하는 글(b — b·zebra)을 넣고, 그 결과(초점·값)를 알린다(사용자가 바깥에 치는
        // 동안 — 목록이 뜨면 안 된다).
        "addEventListener('message',function(e){if(e.data==='steal')setTimeout(function(){f.focus();f.value='';document.execCommand('insertText',false,'b');tell('stolen:'+document.hasFocus()+':'+(document.activeElement===f)+':'+f.value)},300)})</script>";
    // W6m③: 열린 shadow DOM — h(0,0) 안의 칸과 목록, s2(0,60) 안의 스크롤 상자 속 칸, s3(0,140) 안의 칸은 목록이 바깥(light DOM)에
    // 있다(Chrome 도 안 연다), s4(0,200) 는 선언형 닫힌 shadow(하지 않는다 — 사용자 결정). 그 뒤 칸 t(0,260) 는 Tab 이 갈 곳. host 의
    // input(composed)과 안쪽 칸의 change 를 제목으로.
    if (std.mem.eql(u8, path, "/datalist-shadow")) return "<!doctype html><title>loading</title><style>html,body{margin:0}body{height:3000px}div.h{position:absolute;left:0;width:320px}#t{position:absolute;left:0;top:260px;width:300px;height:40px}</style><body>" ++
        "<div class=h id=h style='top:0;height:40px'></div><div class=h id=s2 style='top:60px;height:60px'></div><div class=h id=s3 style='top:140px;height:40px'></div>" ++
        "<div class=h style='top:200px;height:40px'><template shadowrootmode=closed><input list=l4 style='width:300px;height:40px;border:0;padding:0'><datalist id=l4><option value=apple></datalist></template></div>" ++
        "<input id=t><datalist id=lx><option value=apple></datalist><script>var I='width:300px;height:40px;border:0;padding:0;margin:0;display:block';" ++
        "var h=document.getElementById('h'),r=h.attachShadow({mode:'open'});r.innerHTML='<input id=f list=l style='+I+'><datalist id=l><option value=apple><option value=apricot></datalist>';" ++
        "h.addEventListener('input',function(){document.title='host-input:'+r.getElementById('f').value});r.getElementById('f').addEventListener('change',function(e){document.title='sh-change:'+e.target.value});" ++
        "var r2=document.getElementById('s2').attachShadow({mode:'open'});r2.innerHTML='<div id=box style=height:60px;width:320px;overflow:auto><input list=l2 style='+I+'><div style=height:400px></div></div><datalist id=l2><option value=apple></datalist>';" ++
        "var r3=document.getElementById('s3').attachShadow({mode:'open'});r3.innerHTML='<input list=lx style='+I+'>';" ++
        "var n1=document.createElement('div');n1.className='h';n1.style.top='320px';n1.style.height='40px';document.body.appendChild(n1);var q1=n1.attachShadow({mode:'open'});q1.innerHTML='<div id=n2></div>';" ++
        "var q2=q1.getElementById('n2').attachShadow({mode:'open'});q2.innerHTML='<input list=l style='+I+'><datalist id=l><option value=apple><option value=apricot></datalist>';" ++
        "requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='dl-shadow-ready'})})</script>";
    if (std.mem.eql(u8, path, "/unload")) {
        return "<!doctype html><title>loading</title><body style='margin:0;height:100%'><script>var n=0;addEventListener('click',function(){window.onbeforeunload=function(e){e.preventDefault();e.returnValue='leave?';return 'leave?'};document.title='unload-armed-'+(++n)});requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='unload-ready'})})</script>";
    }
    if (std.mem.eql(u8, path, "/unload-hang")) {
        // W6j: 클릭하면 떠나기 확인 처리기가 20 초 멈춘다(물어보고 닫기의 시한).
        return "<!doctype html><title>loading</title><body style='margin:0;height:100%'><script>addEventListener('click',function(){window.onbeforeunload=function(e){var t=Date.now();while(Date.now()-t<20000);e.preventDefault();e.returnValue='x';return 'x'};document.title='hang-armed'});requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='hang-ready'})})</script>";
    }
    if (std.mem.eql(u8, path, "/dialog-reload")) {
        return "<!doctype html><title>loading</title><script>var n=+(sessionStorage.n||0);sessionStorage.n=n+1;if(n<3){alert('again');location.reload()}else document.title='reload-done'</script>";
    }
    if (std.mem.eql(u8, path, "/dialog-loop")) {
        return "<!doctype html><title>loading</title><script>for(var i=0;i<5;i++)alert('loop '+i);document.title='loop-done'</script>";
    }
    // W10a: 불러지면 제목을 `dlp-ready` 로 바꾸고 0.3 초 뒤 받는다(begin 이 제목 대기에 묻히지 않게 — 사용자 동작 없이 — 첫 자동 다운로드는 Chromium 이 묻지 않는다). `?a=attach|ctl|slow|data|two`.
    // `data` 는 5000 바이트 data: 주소(주소 상한 2048 을 넘는다), `two` 는 0.6 초 간격으로 둘(둘째는 「여러 파일 받기」 권한을 묻는다),
    // `push` 는 pushState 로 주소만 바꾼 뒤 첨부를 받는다(새 문서 표지가 오지 않아야 한다).
    if (std.mem.eql(u8, path, "/dlp")) return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><body><script>" ++
        "function go(h,n){{var a=document.createElement('a');a.href=h;if(n)a.download=n;document.body.appendChild(a);a.click()}}" ++
        "onload=function(){{document.title='dlp-ready';setTimeout(function(){{var k='{s}';if(k==='data')go('data:text/plain,'+'x'.repeat(5000),'big.txt');" ++
        "else if(k==='two'){{go('/dl/f/attach');setTimeout(function(){{go('/dl/f/ctl')}},600)}}" ++
        "else if(k==='push'){{history.pushState({{}},'','/dlp-pushed');go('/dl/f/attach')}}else go('/dl/f/'+k)}},300)}}</script>", .{query});
    if (std.mem.eql(u8, path, "/file")) return filePage("accept=\"image/*,.txt\"", buf);
    if (std.mem.eql(u8, path, "/files")) return filePage("multiple", buf);
    if (std.mem.eql(u8, path, "/folder")) return filePage("webkitdirectory", buf);
    if (std.mem.eql(u8, path, "/perm")) {
        return std.fmt.bufPrint(buf, "<!doctype html><title>loading</title><body style='margin:0;height:100%'><script>" ++
            "var A='{s}',I=A=='geoinner',C=0;function T(x){{(I?top:window).document.title=(I?'geoframe':A)+':'+x}}function E(e){{T('err-'+e.name)}}function K(){{T('ok')}}" ++
            "function G(w){{return Object.getOwnPropertyNames(w).filter(function(k){{return /maru/i.test(k)}}).length}}" ++
            "function go(){{if(A=='notif')Notification.requestPermission().then(T);" ++
            "else if(A=='midi')navigator.requestMIDIAccess({{sysex:true}}).then(K,E);" ++
            "else if(A=='fonts')queryLocalFonts().then(function(f){{T('ok'+f.length)}},E);" ++
            "else if(A=='screens')getScreenDetails().then(K,E);" ++
            "else if(A=='idle')IdleDetector.requestPermission().then(T,E);" ++
            "else if(A=='geo')navigator.geolocation.getCurrentPosition(K,function(e){{T('geo-err'+e.code)}},{{timeout:3000}});" ++
            "else if(A=='geox')navigator.geolocation.getCurrentPosition(function(p){{T('at'+p.coords.latitude.toFixed(3)+','+p.coords.longitude.toFixed(3)+','+p.coords.accuracy)}},function(e){{T('geo-err'+e.code)}},{{timeout:8000}});" ++
            "else if(A=='geoframe'){{var f=document.createElement('iframe');f.allow='geolocation';f.src='/perm?a=geoinner';document.body.appendChild(f)}}" ++
            "else if(A=='nshow'||A=='nauto'){{var n=new Notification('제목',{{body:'본문\\n둘',tag:'t1'}});n.onclick=function(){{T('clicked'+(++C))}};n.onshow=function(){{T('shown')}}}}" ++
            "else if(A=='nglobals')top.postMessage('g'+G(window),'*');" ++
            "else if(A.indexOf('nxtop')==0){{addEventListener('message',function(e){{setTimeout(function(){{T(e.data)}},800)}});var f=document.createElement('iframe');f.src='http://127.0.0.1:'+A.slice(5)+'/perm?a=nxframe';document.body.appendChild(f)}}" ++
            "else if(A=='nxframe'){{var m='';try{{new Notification('xframe')}}catch(e){{m='-'+e.name}}top.postMessage('x'+Notification.permission+m,'*')}}" ++
            "else if(A=='nnest'){{top.postMessage('g'+G(window),'*');var c=document.createElement('iframe');c.src='/perm?a=nglobals';document.body.appendChild(c)}}" ++
            "else if(A=='nprerender'){{var r=document.createElement('script');r.type='speculationrules';r.textContent=JSON.stringify({{prerender:[{{source:'list',urls:['/perm?a=nactivated']}}]}});document.head.appendChild(r);setTimeout(function(){{location.href='/perm?a=nactivated'}},2000)}}" ++
            "else if(A=='nactivated'){{var e=performance.getEntriesByType('navigation')[0];setTimeout(function(){{T('g'+G(window)+'-a'+(e&&e.activationStart>0?1:0))}},600)}}" ++
            "else if(A=='nsandbox'){{try{{Object.defineProperty(Notification,'permission',{{get:function(){{return 'granted'}}}})}}catch(e){{}}new Notification('가짜');T('sandboxed'+G(window)+'-'+self.origin)}}" ++
            "else if(A=='nforge'){{var g=G(window),b=document.createElement('iframe');document.body.appendChild(b);var bl=G(b.contentWindow),got=[];" ++
            "addEventListener('message',function(e){{got.push(e.data);if(got.length==4)T('forged'+g+'-'+bl+'-'+got.join('-'))}});" ++
            "var x=document.createElement('iframe');x.src='http://127.0.0.1:'+location.port+'/perm?a=nnest';document.body.appendChild(x);" ++
            "var sb=document.createElement('iframe');sb.sandbox='allow-scripts';sb.src='/perm?a=nglobals';document.body.appendChild(sb);" ++
            "var so=document.createElement('iframe');so.src='/perm?a=nglobals';document.body.appendChild(so);" ++
            "try{{Object.defineProperty(Notification,'permission',{{get:function(){{return 'granted'}}}})}}catch(e){{}}new Notification('가짜')}}" ++
            "else if(A=='nflood'){{for(var i=0;i<10;i++)new Notification('f'+i);T('flooded')}}" ++
            "else if(A=='geolater'||I){{var g=navigator.geolocation,o={{timeout:5000}},f=function(p){{return 'at'+p.coords.latitude.toFixed(3)}},e=function(x){{return 'geo-err'+x.code}};" ++
            "g.getCurrentPosition(function(p){{var a=f(p);setTimeout(function(){{g.getCurrentPosition(function(q){{T(a+'|'+f(q))}},function(x){{T(a+'|'+e(x))}},o)}},1500)}},function(x){{T(e(x))}},o)}}" ++
            "else if(A=='watch'){{var n=0,l=[];navigator.geolocation.watchPosition(function(p){{n++;l.push(p.coords.latitude.toFixed(3))}},function(e){{l.push('e'+e.code)}});setTimeout(function(){{T('n'+n+'-'+l.join('/'))}},3000)}}" ++
            "else if(A=='cam')navigator.mediaDevices.getUserMedia({{video:true}}).then(K,E);" ++
            "else if(A=='display')navigator.mediaDevices.getDisplayMedia({{video:true}}).then(K,E);" ++
            "else if(A=='displayleave'){{navigator.mediaDevices.getDisplayMedia({{video:true}}).then(K,E);setTimeout(function(){{location.href='/title?t=perm-left'}},1500)}}" ++
            "else if(A=='displayfail'){{navigator.mediaDevices.getDisplayMedia({{video:true}}).then(K,E);setTimeout(function(){{location.href='http://127.0.0.1:9/'}},1500)}}}}" ++
            "addEventListener('click',go);if(I||A=='nauto'||A=='nflood'||A=='nglobals'||A=='nnest'||A=='nprerender'||A=='nactivated'||A=='nxframe'||A.indexOf('nxtop')==0)go();requestAnimationFrame(function(){{requestAnimationFrame(function(){{T('ready')}})}})</script>", .{query});
    }
    if (std.mem.eql(u8, path, "/ctl")) {
        return "<!doctype html><title>loading</title><script>document.title='a\\x07b\\x7fc'</script>";
    }
    if (std.mem.eql(u8, path, "/flood")) {
        return "<!doctype html><title>loading</title><script>var i=0;var h=setInterval(function(){for(var k=0;k<200;k++)document.title='f'+(i++)},1);setTimeout(function(){clearInterval(h);document.title='flood-done'},2000)</script>";
    }
    return error.NotFound;
}

fn filePage(attr: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><title>loading</title><style>html,body{{margin:0;height:100%}}input{{position:absolute;left:0;top:0;width:300px;height:100px}}</style>
        \\<input type=file id=f {s}><script>var f=document.getElementById('f');
        \\f.addEventListener('change',function(){{var fs=Array.from(f.files);var n=fs.map(function(x){{return x.name}}).sort();
        \\Promise.all(fs.map(function(x){{return x.arrayBuffer()}})).then(function(bs){{var t=0;bs.forEach(function(b){{t+=b.byteLength}});document.title='file-'+fs.length+'-'+n.join(',')+'-'+t}},function(){{document.title='file-readerr'}})}});
        \\f.addEventListener('cancel',function(){{document.title='file-cancel'}});
        \\requestAnimationFrame(function(){{requestAnimationFrame(function(){{document.title='file-ready'}})}})</script>
    , .{attr});
}

const input_page =
    \\<!doctype html><title>loading</title>
    \\<style>body{margin:0;height:3000px;font:16px sans-serif}#i{position:absolute;left:0;top:0;width:300px;height:40px;box-sizing:border-box}
    \\#p{position:absolute;left:0;top:100px;width:600px;margin:0;line-height:20px}#a{position:absolute;left:0;top:200px;display:block;width:200px;height:30px}#d{position:absolute;left:0;top:300px;width:200px;height:40px}</style>
    \\<input id=i><p id=p>maru selects this paragraph text by dragging across it</p><a id=a href="#x">link</a><div id=d></div>
    \\<script>var i=document.getElementById('i');function t(s){document.title=s}
    \\addEventListener('click',function(e){if(e.target.id!='p')t('click:'+e.clientX+','+e.clientY+','+e.button+','+e.detail)});
    \\i.addEventListener('input',function(e){t((e.isComposing?'comp-val:':'val:')+i.value)});
    \\i.addEventListener('compositionend',function(e){t('end:'+e.data+':'+i.value)});
    \\i.addEventListener('keydown',function(e){if(e.ctrlKey)t('key:'+e.key+':ctrl:'+e.code)});
    \\i.addEventListener('blur',function(){t('blur')});
    \\addEventListener('contextmenu',function(e){t('ctx:'+e.clientX+','+e.clientY)});
    \\addEventListener('auxclick',function(e){if(e.button==1)t('aux:1')});
    \\document.getElementById('d').addEventListener('dblclick',function(e){t('dbl:'+e.detail)});
    \\addEventListener('mouseup',function(e){if(e.button==0&&e.target.id=='p')t('sel:'+(getSelection().toString().length>=5?'yes':'no'))});
    \\addEventListener('scroll',function(){if(scrollY>0)t('scroll:down')});
    \\document.documentElement.addEventListener('mouseleave',function(){t('leave')});
    \\requestAnimationFrame(function(){requestAnimationFrame(function(){t('input-ready')})});
    \\</script>
;

/// W6a 팝업 판정(`popup_check.zig`) — `<select>` 하나(view 10,10 200×30). 고르면 `sel:<값>` 제목, 첫 프레임 뒤 `sel-ready`.
const select_page =
    \\<!doctype html><title>loading</title><style>body{margin:0}#s{position:absolute;left:10px;top:10px;width:200px;height:30px;font-size:16px}</style>
    \\<select id=s><option value=a>alpha</option><option value=b>bravo</option><option value=c>charlie</option><option value=d>delta</option><option value=e>echo</option></select>
    \\<script>var s=document.getElementById('s');s.addEventListener('change',function(){document.title='sel:'+s.value});requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='sel-ready'})});</script>
;

/// W6b 툴팁 — A·B(여러 줄)·제어 문자·5000 자 title. `#push` 해시로 오면 pushState 도 한다(주소만 바뀌는 경우), `#busy` 면
/// 렌더러를 1.5 초 붙잡는다(CEF 의 빈 글이 늦게 오게 — sidecar 의 떠남 초기화를 따로 보려고).
/// W6c 우클릭 메뉴 — 자리마다 한 요소(`contextmenu_check.zig` 의 좌표). 제목은 이 탭에서 문서를 불러온 횟수(「cm N」 —
/// 새로고침·이동을 센다), 입력 칸·iframe 칸은 값을 제목으로, 막힌 자리는 「prevented」. 긴 글은 「가」 5000 자(15 KB — 4 KiB
/// 상한을 글자 경계에서 자르는지).
/// W6d① 끌어 놓기 — 자리마다 한 요소(`drag_check.zig` 의 좌표). 제목은 `dnd <상태 JSON>`(키는 마지막 값 — `n` 은 바뀐 수).
/// 받는 칸(`z` — 끄는 동안 본 종류·파일 수·읽힌 글 길이, 놓으면 이름:크기·종류·글·주소, 첫 파일 내용, 폴더면 안 이름과 첫 파일 내용), 글 칸(`ta` —
/// 들어간 값), 이동을 고르는 목록(`L` — 놓인 글|사용자 정의 형식 `application/x-maru`). W6d② 끌어내기: 끌 요소(`d` — 글과 사용자
/// 정의 형식을 싣는다, `dend` 는 끝난 동작+횟수), 링크(`aend`), 글(`p`), 긴 글(`g` — 「가」 6000 자), 페이지가 받은 mouseup 수(`up`).
/// W6d③: 오른쪽 위에 이미지 넷(`/img/` — PNG·`Content-Disposition` 이름·6 MiB·40 MiB SVG).
const drag_page =
    "<!doctype html><title>loading</title><style>html,body{margin:0;font:16px sans-serif;width:640px;height:480px}body>*{position:absolute;margin:0;box-sizing:border-box}</style><body>" ++
    "<div id=z style='left:20px;top:20px;width:280px;height:160px;background:#cfc'>zone</div>" ++
    "<textarea id=t style='left:20px;top:220px;width:280px;height:60px'></textarea>" ++
    "<div id=L style='left:360px;top:150px;width:120px;height:80px;background:#fcc'>list</div>" ++
    "<div id=d draggable=true style='left:360px;top:20px;width:120px;height:50px;background:#ccf'>drag me</div>" ++
    "<a id=a href='/title?t=linked' title='link title' style='left:360px;top:300px;width:120px;height:24px'>a link</a>" ++
    "<p id=p style='left:20px;top:330px;width:300px;height:24px'>select these words</p>" ++
    "<div id=g style='left:20px;top:380px;width:300px;height:40px;overflow:hidden;font-size:4px'>" ++ ("가" ** 6000) ++ "</div>" ++
    "<img style='left:520px;top:20px;width:48px;height:48px' src='/img/png/cat.png'>" ++
    "<img style='left:520px;top:100px;width:48px;height:48px' src='/img/pngcd/plain.png'>" ++
    "<img style='left:520px;top:180px;width:48px;height:48px' src='/img/big6/six.svg'>" ++
    "<img style='left:520px;top:260px;width:48px;height:48px' src='/img/big40/forty.svg'>" ++
    \\<script>
    \\var S={n:0};function put(k,v){S[k]=v;S.n++;document.title='dnd '+JSON.stringify(S).slice(0,900)}
    \\var z=document.getElementById('z');
    \\z.addEventListener('dragenter',function(e){e.preventDefault()});
    \\z.addEventListener('dragover',function(e){e.preventDefault();e.dataTransfer.dropEffect='copy';put('zover',e.dataTransfer.types.join('+')+'/f'+e.dataTransfer.files.length+'/t'+e.dataTransfer.getData('text/plain').length)});
    \\z.addEventListener('dragleave',function(e){if(e.target===z)put('zleave',1)});
    \\z.addEventListener('drop',function(e){e.preventDefault();var dt=e.dataTransfer,f=dt.files,names=[];for(var i=0;i<f.length;i++)names.push(f[i].name+':'+f[i].size);put('zdrop',names.join(',')+'/types='+dt.types.join('+')+'/text='+dt.getData('text/plain').slice(0,40)+'/uri='+dt.getData('text/uri-list').slice(0,60)+'/html='+dt.getData('text/html').slice(0,80));
    \\ if(f.length){var r=new FileReader();r.onload=function(){put('zcontent',String(r.result).slice(0,40))};r.onerror=function(){put('zcontent','ERR')};r.readAsText(f[0])}
    \\ for(var j=0;j<dt.items.length;j++){var en=dt.items[j].webkitGetAsEntry&&dt.items[j].webkitGetAsEntry();if(en&&en.isDirectory){en.createReader().readEntries(function(es){put('zdir',es.map(function(x){return x.name}).sort().join(','));var fe=es.filter(function(x){return x.isFile})[0];if(fe)fe.file(function(ff){var r2=new FileReader();r2.onload=function(){put('zdircontent',String(r2.result).slice(0,40))};r2.readAsText(ff)},function(){put('zdircontent','ERR')})},function(){put('zdir','ERR')})}}});
    \\var t=document.getElementById('t');t.addEventListener('input',function(){put('ta',t.value.slice(0,60))});
    \\var L=document.getElementById('L');L.addEventListener('dragenter',function(e){e.preventDefault()});L.addEventListener('dragover',function(e){e.preventDefault();e.dataTransfer.dropEffect='move'});L.addEventListener('drop',function(e){e.preventDefault();put('Ldrop',e.dataTransfer.getData('text/plain')+'|'+e.dataTransfer.getData('application/x-maru'))});
    \\var d=document.getElementById('d');d.addEventListener('dragstart',function(e){e.dataTransfer.setData('text/plain','hello-drag');e.dataTransfer.setData('application/x-maru','secret-type');e.dataTransfer.effectAllowed='copyMove';put('dstart',(S.dstart||0)+1)});d.addEventListener('dragend',function(e){put('dend',e.dataTransfer.dropEffect+(S.dendn=(S.dendn||0)+1))});
    \\document.getElementById('a').addEventListener('dragend',function(e){put('aend',e.dataTransfer.dropEffect)});
    \\document.addEventListener('mouseup',function(){put('up',(S.up||0)+1)});
    \\put('ready',1);
    \\</script>
    ;

const context_menu_page =
    "<!doctype html><title>loading</title><style>html,body{margin:0;font:16px sans-serif}body>*{position:absolute;margin:0}</style><body>" ++
    "<a href='/cm-target?x=1' style='left:20px;top:20px;width:200px;height:24px'>a link here</a>" ++
    "<img style='left:20px;top:70px;width:120px;height:60px' src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22120%22 height=%2260%22%3E%3Crect width=%22120%22 height=%2260%22 fill=%22red%22/%3E%3C/svg%3E'>" ++
    "<img style='left:160px;top:70px;width:60px;height:60px' src='/flaky.svg'>" ++
    "<input style='left:20px;top:215px;width:200px' value='some input text' oninput='document.title=\"val:\"+this.value'>" ++
    "<iframe style='left:300px;top:220px;width:200px;height:60px' srcdoc=\"<input value='frame text' oninput='parent.document.title=&quot;frame:&quot;+this.value'>\"></iframe>" ++
    "<div oncontextmenu='event.preventDefault();document.title=\"prevented\"' style='left:300px;top:150px;width:160px;height:40px;background:#cfc'>no menu here</div>" ++
    "<div id=long style='left:480px;top:40px;width:150px;height:90px;overflow:hidden'></div>" ++
    "<script>document.getElementById('long').textContent='\u{AC00}'.repeat(5000);sessionStorage.n=(+sessionStorage.n||0)+1;document.title='cm '+sessionStorage.n</script>";

const tooltip_page =
    \\<!doctype html><title>loading</title><style>body{margin:0}div{position:absolute}#a{left:0;top:0;width:300px;height:200px}#b{left:320px;top:0;width:300px;height:200px}#x{left:0;top:220px;width:300px;height:80px}#y{left:320px;top:220px;width:300px;height:80px}</style>
    \\<div id=a title="A tip">a</div><div id=b title="B line1&#13;&#10;B line2">b</div><div id=x>x</div><div id=y>y</div>
    \\<script>document.getElementById('x').title='ctl\x1bchar';document.getElementById('y').title='L'.repeat(5000);
    \\addEventListener('hashchange',function(){if(location.hash=='#push')history.pushState({},'','/tip?pushed');if(location.hash=='#busy'){document.title='busy';var t=Date.now();while(Date.now()-t<1500){}}});
    \\requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='tip-ready'})});</script>
;

const keys_page =
    \\<!doctype html><title>loading</title><style>body{margin:0}#t{position:absolute;left:0;top:0;width:300px;height:100px}#j{position:absolute;left:0;top:120px;width:300px;height:30px}#k{position:absolute;left:0;top:170px;width:300px;height:30px}</style>
    \\<textarea id=t></textarea><form id=f onsubmit="t2('submit');return false"><input id=j><input id=k></form>
    \\<script>function st(){var a=document.activeElement;var v=a&&a.value!==undefined?a.value.split(String.fromCharCode(10)).join('NL'):'';document.title='focus='+(a&&a.id)+' val='+v+' caret='+(a&&a.selectionStart)}
    \\addEventListener('input',function(){setTimeout(st,0)});addEventListener('keyup',function(){setTimeout(st,0)});document.addEventListener('focusin',function(){setTimeout(st,0)});
    \\requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='keys-ready'})});</script>
;
