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
    // 놓기를 받는 칸 — 받은 뒤(이동 없음) 입력 없이 만든 ⌘ 클릭을 보낸다(W6e 적대 검증 2 차 — 놓기 표시가 그 클릭을 지금 탭 이동으로 두지 않게).
    "<div style='position:absolute;left:420px;top:60px;width:120px;height:80px;background:#fcc' ondragenter='event.preventDefault()' ondragover='event.preventDefault()' " ++
    "ondrop=\"event.preventDefault();setTimeout(function(){document.getElementById('pl').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}));document.title='nt-dropped'},300)\">dz</div>" ++
    // 같은 것을 2.5 초 뒤에 — 놓은 주소와 같은 링크여도 놓기 뒤 2 초가 지나면 놓기 이동이 아니다.
    "<div style='position:absolute;left:560px;top:60px;width:70px;height:80px;background:#cfc' ondragenter='event.preventDefault()' ondragover='event.preventDefault()' " ++
    "ondrop=\"event.preventDefault();setTimeout(function(){document.getElementById('pl').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}));document.title='nt-dropped-late'},2500)\">dz2</div>";

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
    if (std.mem.eql(u8, path, "/unload")) {
        return "<!doctype html><title>loading</title><body style='margin:0;height:100%'><script>var n=0;addEventListener('click',function(){window.onbeforeunload=function(e){e.preventDefault();e.returnValue='leave?';return 'leave?'};document.title='unload-armed-'+(++n)});requestAnimationFrame(function(){requestAnimationFrame(function(){document.title='unload-ready'})})</script>";
    }
    if (std.mem.eql(u8, path, "/dialog-reload")) {
        return "<!doctype html><title>loading</title><script>var n=+(sessionStorage.n||0);sessionStorage.n=n+1;if(n<3){alert('again');location.reload()}else document.title='reload-done'</script>";
    }
    if (std.mem.eql(u8, path, "/dialog-loop")) {
        return "<!doctype html><title>loading</title><script>for(var i=0;i<5;i++)alert('loop '+i);document.title='loop-done'</script>";
    }
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
