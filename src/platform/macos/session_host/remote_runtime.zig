//! remote_runtime — **client 쪽 원격 runtime**(host runtime의 client-side 상대) — P3-e2e-2c-2.
//!
//! host의 `runtime_manager`(host 프로세스가 실 PTY/`TerminalCore`를 소유)와 대칭이다: 이쪽은 client RPC로 그 host runtime을
//! spawn/제어하고, host가 보내는 snapshot/delta stream을 `RemoteScreen`(조립기+cell 격자)으로 조립해 **원격-backed `Surface`**
//! 로 노출한다. GUI는 이 `Surface`를 in-process runtime과 똑같이 렌더한다(`surface.renderSnapshot()` — SSOT). 즉 이 파일이
//! "원격 runtime = client가 든 Surface 하나"라는 client-side 소유 모델을 만든다.
//!
//! 범위(e2e-2c-2): client-side runtime 소유·제어·화면까지다. P2 `TermRuntimeBackend` **vtable 어댑터**와 GUI **frame-loop
//! pump 배선**(delta stream을 매 프레임 소비, `RuntimeEventPump` 재해석)은 app_session이 프레임 루프를 만지는 **e3**에서 이
//! 위에 얹는다 — 여기 `pumpDelta`는 그 배선이 부를 수 있는 최소 단위(한 delta batch 소비)다. macOS 전용(client·Surface·terminal).

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const Surface = maru.session.Surface;
const client_mod = @import("client.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("screen_assembler.zig");

/// host에서 가져온 대기 OSC 9/777 데스크톱 알림 한 건(§6.32). title/body는 owned(caller가 deinit).
pub const Notification = struct {
    title: []u8,
    body: []u8,
    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

/// 한 원격 runtime. self-referential(`surface.remote`가 `&self.remote_screen`을 가리킴)이라 **in-place `spawn`**을 쓴다
/// (caller가 `var rr: RemoteRuntime = undefined; try rr.spawn(...)`). spawn 후 이 값을 이동하면 안 된다.
pub const RemoteRuntime = struct {
    client: *client_mod.Client, // borrowed — 여러 runtime이 한 connection을 공유한다(stream_id로 구분).
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id_hex: [32]u8, // host 발급 runtime_id(hex) — terminate에 되먹인다.
    stream_id: u64, // attach가 발급한 stream — input/resize/delta 라우팅.
    resize_seq: u64, // 단조 증가 client_sequence — registry가 이하 sequence를 stale로 거부하므로 매 resize마다 올린다.
    remote_screen: remote_screen.RemoteScreen, // 조립기+cell 격자(surface의 화면 소스).
    surface: Surface, // 원격-backed(surface.remote = remote_screen.screenSource()). GUI가 이걸 렌더.

    /// host에 runtime을 띄우고(`runtime.spawn`) controller로 attach한 뒤 첫 snapshot을 조립해 원격 Surface를 세운다.
    /// 실패 시 이미 띄운 host runtime을 회수한다(orphan 방지). `argv`/`size`는 spawn할 셸 스펙이다.
    pub fn spawn(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        argv: []const []const u8,
        size: terminal.Size,
    ) anyerror!void {
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;

        // 1. runtime.spawn — host가 실 PTY를 띄우고 runtime_id를 준다.
        const spawn_params = buildSpawnParams(allocator, argv, size) catch return error.OutOfMemory;
        defer allocator.free(spawn_params);
        const spawn_resp = try client.call("runtime.spawn", spawn_params);
        defer allocator.free(spawn_resp);
        self.runtime_id_hex = client_mod.extractRuntimeId(spawn_resp) orelse return error.SpawnFailed;
        // 이 지점부터 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지) — spawn한 건 우리 소유다.
        errdefer self.terminateBestEffort();

        try self.attachAndAssemble(surface_id, size);
    }

    /// **이미 host에 있는 runtime에 재접속**한다(spawn 없이) — GUI를 재실행하면 workspace가 저장한 `runtime_id_hex`로 같은
    /// host runtime에 붙어 화면·PID·scrollback을 잇는다(§7). runtime이 없으면(host 재시작·runtime 종료 등) attach가
    /// `error.AttachFailed`(host RuntimeNotFound → 응답에 stream_id 없음)를 내고, caller가 fresh `spawn`으로 폴백한다.
    /// **`spawn`과 달리 실패해도 runtime을 terminate하지 않는다** — 우리가 띄운 게 아니라 pre-existing이므로(남의 runtime을
    /// attach 실패로 죽이면 안 됨). 성공 뒤 이 RemoteRuntime은 spawn한 것과 동일하게 다룬다(input/resize/pump/terminate).
    pub fn attachExisting(
        self: *RemoteRuntime,
        client: *client_mod.Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        surface_id: u64,
        runtime_id_hex: [32]u8,
        size: terminal.Size,
    ) anyerror!void {
        self.client = client;
        self.allocator = allocator;
        self.io = io;
        self.resize_seq = 0;
        self.runtime_id_hex = runtime_id_hex;
        // terminate errdefer 없음(pre-existing runtime을 attach 실패로 죽이지 않는다).
        try self.attachAndAssemble(surface_id, size);
    }

    /// spawn/attachExisting 공통(§10 attach 순서): controller attach(stream_id) → 첫 snapshot 조립 → 원격-backed Surface.
    /// `self.runtime_id_hex`가 이미 채워져 있어야 한다(spawn=runtime.spawn 응답, attachExisting=저장된 값).
    fn attachAndAssemble(self: *RemoteRuntime, surface_id: u64, size: terminal.Size) anyerror!void {
        // 2. runtime.attach(controller) — stream_id + snapshot 순서(§10).
        var attach_buf: [96]u8 = undefined;
        const attach_params = std.fmt.bufPrint(&attach_buf, "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}", .{self.runtime_id_hex}) catch return error.AttachFailed;
        const attach_resp = try self.client.call("runtime.attach", attach_params);
        defer self.allocator.free(attach_resp);
        self.stream_id = client_mod.extractU64Field(attach_resp, "\"stream_id\":") orelse return error.AttachFailed;

        // 3. 첫 snapshot을 읽어 원격 화면을 조립한다.
        const snap = try self.client.readSnapshot(self.stream_id);
        defer self.allocator.free(snap);
        self.remote_screen = try remote_screen.RemoteScreen.init(self.allocator);
        errdefer self.remote_screen.deinit();
        try self.remote_screen.applySnapshot(snap, self.io);

        // 4. 원격-backed Surface를 세운다(로컬 core는 placeholder — 렌더는 remote 소스로 간다).
        self.surface = try Surface.init(self.allocator, surface_id, size);
        self.surface.remote = self.remote_screen.screenSource();
    }

    /// host가 발급한 runtime_id(hex)를 돌려준다 — workspace가 저장해 재실행 시 `attachExisting`으로 재접속한다(§7, e3-5).
    pub fn runtimeIdHex(self: *const RemoteRuntime) [32]u8 {
        return self.runtime_id_hex;
    }

    /// runtime을 종료하고(host `runtime.terminate`) client-side 자원을 회수한다. 멱등 시도(종료 실패는 무시).
    pub fn deinit(self: *RemoteRuntime) void {
        self.client.dropBufferedStream(self.stream_id); // 이 stream 앞으로 남은 demux 배치 회수(더는 pump 안 함 — §멀티 runtime).
        self.terminateBestEffort();
        self.surface.deinit();
        self.remote_screen.deinit();
        self.* = undefined;
    }

    /// client-side 자원만 회수한다(surface/screen) — **host runtime은 안 죽인다**(terminate 안 보냄). 앱 quit 시 host-backed
    /// Term을 이걸로 정리하면 runtime이 host에 남아(연결 EOF를 host가 detach로 처리해 유지, §6 app-quit=detach) GUI 재실행 시
    /// `attachExisting`으로 재접속한다. `deinit`과 대칭이되 terminate만 뺀다.
    pub fn detachClientSide(self: *RemoteRuntime) void {
        self.client.dropBufferedStream(self.stream_id); // 이 stream 앞으로 남은 demux 배치 회수(더는 pump 안 함 — §멀티 runtime).
        self.surface.deinit();
        self.remote_screen.deinit();
        self.* = undefined;
    }

    /// 렌더/입력 라우팅에 쓸 Surface(GUI가 in-process처럼 다룬다).
    pub fn surfacePtr(self: *RemoteRuntime) *Surface {
        return &self.surface;
    }

    /// terminal input을 host runtime으로 보낸다(controller). 응답 없는 fire-and-forget.
    pub fn sendInput(self: *RemoteRuntime, bytes: []const u8) client_mod.ClientError!void {
        return self.client.sendInput(self.stream_id, bytes);
    }

    /// canonical PTY size를 바꾼다(host `runtime.resize`). host가 실 `TerminalCore`+`TIOCSWINSZ`에 적용한다.
    pub fn resize(self: *RemoteRuntime, cols: u16, rows: u16) client_mod.ClientError!void {
        self.resize_seq += 1; // 단조 증가 — registry가 이하 sequence를 stale로 거부(첫 resize만 적용되는 버그 방지).
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d},\"client_sequence\":{d}}}", .{ self.stream_id, cols, rows, self.resize_seq }) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.resize", params);
        self.allocator.free(resp);
    }

    /// 내 stream(§멀티 runtime demux)의 다음 화면 배치 하나를 소비해 원격 화면에 반영한다(§9/§10). **논블로킹** — 내 배치가
    /// 없으면(idle) `false`를, 하나 소비했으면 `true`를 돌려준다(caller가 있는 동안 반복해 다 비운다 — `RemoteTermBackend`의
    /// drain이 이걸로 `RuntimeEventPump.drainAvailable`과 같은 의미를 만든다). client가 `stream_id`로 demux하므로 여기 도달한
    /// 배치는 **항상 내 것**이다(예전엔 남의 배치를 free해 유실 — code-review #1; 이제 client가 남의 것은 버퍼해 그 runtime pump로
    /// 보낸다). host가 grid/alt 변화 시 delta 대신 fresh snapshot을 push하므로 둘 다 처리한다(is_snapshot이면 리셋, 아니면 증분).
    pub fn pumpDelta(self: *RemoteRuntime) (client_mod.ClientError || screen_assembler.ApplyError)!bool {
        const batch = (try self.client.readStreamBatch(self.allocator, self.stream_id)) orelse return false; // idle — 내 배치 없음.
        defer self.allocator.free(batch.bytes);
        if (batch.is_snapshot) {
            try self.remote_screen.applySnapshot(batch.bytes, self.io); // §9 fresh snapshot(grid/alt 변화) → 화면 리셋.
        } else {
            try self.remote_screen.applyDelta(batch.bytes, self.io);
        }
        return true;
    }

    /// host runtime을 종료한다(client-side 자원은 남긴다 — 회수는 `deinit`). `TermRuntimeBackend.close_and_detach`/`close`가
    /// 부른다(계약: routing 끊고 프로세스 kill). 멱등(host가 없는 id 무시). client 객체는 이후 `remove`→`deinit`에서 회수한다.
    pub fn terminate(self: *RemoteRuntime) void {
        self.terminateBestEffort();
    }

    /// host에 fresh snapshot 재요청(§9 desync 복구) — 조립기가 `GenerationGap`/`MalformedRow`로 뒤처졌을 때 `pumpDelta` 실패
    /// 경로가 부른다. host가 다음 delta tick에 현재 full snapshot을 snapshot_chunk로 push하고, 그걸 `pumpDelta`의 applySnapshot이
    /// 받아 generation을 리셋해 복구한다(delta는 base_generation이 현재라 stale client를 못 고쳐 snapshot이 유일한 복구). 응답 무시.
    pub fn requestResync(self: *RemoteRuntime) client_mod.ClientError!void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d}}}", .{self.stream_id}) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.resync", params);
        self.allocator.free(resp);
    }

    /// host에 뷰포트 선택 span을 보내 host의 `extractSelection`(로컬과 같은 함수)으로 뽑은 텍스트를 받는다(§6b 원격 선택 복사).
    /// **선택 의미론은 host core 단일 출처** — client는 렌더용 span만 보내고 콘텐츠 추출(soft-wrap 이음·블록·스크롤백)은 host가
    /// 한다. 반환 텍스트는 caller 소유(빈 선택/오류면 null). `block`은 std.fmt가 true/false로 찍어 유효 JSON.
    pub fn selectedText(self: *RemoteRuntime, span: terminal.SelectionSpan) client_mod.ClientError!?[]u8 {
        var buf: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"sr\":{d},\"sc\":{d},\"er\":{d},\"ec\":{d},\"block\":{}}}", .{ self.stream_id, span.start.row, span.start.col, span.end.row, span.end.col, span.block }) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.selected_text", params);
        defer self.allocator.free(resp);
        const text = (decodeJsonStringField(self.allocator, resp, "text") catch return error.OutOfMemory) orelse return null;
        if (text.len == 0) {
            self.allocator.free(text);
            return null;
        }
        return text;
    }

    /// 스크롤 core command를 host로 보낸다(§6a 원격 스크롤백). `op`=scroll 계열 태그(코드 내부 고정 리터럴 — JSON escape 불요),
    /// `arg`=정수 인자(delta/절대행/offset). host가 자기 `TerminalCore`에 적용해 view_offset을 바꾸면 다음 snapshot/delta
    /// (renderSnapshot=뷰포트)가 그 스크롤 화면을 투영하고, 이 RemoteRuntime의 Surface(RemoteScreen)가 렌더한다. 응답 무시.
    pub fn sendCoreCommand(self: *RemoteRuntime, op: []const u8, arg: i64) client_mod.ClientError!void {
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"stream_id\":{d},\"op\":\"{s}\",\"arg\":{d}}}", .{ self.stream_id, op, arg }) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.core_command", params);
        self.allocator.free(resp);
    }

    /// host에 대기 중인 OSC 9/777 데스크톱 알림을 뺀다(§6.32 — host가 core와 함께 알림을 소유·전달). 없으면 null. host-backed
    /// 터미널의 알림은 host의 `TerminalCore`가 파싱하므로 client가 이걸로 가져와 GUI 알림 funnel에 넣는다(app_session이 surfacing).
    /// 반환 title/body는 caller 소유(Notification.deinit로 회수). 둘 다 빈 값이면(host 대기 없음) null.
    pub fn takeNotification(self: *RemoteRuntime) client_mod.ClientError!?Notification {
        var buf: [96]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return error.OutOfMemory;
        const resp = try self.client.call("runtime.notification", params);
        defer self.allocator.free(resp);
        // std.json.parseFromSlice 대신 **수동 디코드** — parseFromSlice가 숫자 파서(f128 소프트플로트 ___divtf3/___fixtfti
        // 등)를 링크로 끌어와, 이 경로가 live가 되면 ReleaseSafe 제품 빌드(macos-live-preview-perf)가 undefined symbol로
        // 깨진다(code-review 후속). client는 이미 extractU64Field 등 수동 파싱 관례라 여기서도 그 관례를 따른다.
        const title = (decodeJsonStringField(self.allocator, resp, "title") catch return error.OutOfMemory) orelse return null;
        errdefer self.allocator.free(title);
        const body = (decodeJsonStringField(self.allocator, resp, "body") catch return error.OutOfMemory) orelse {
            self.allocator.free(title);
            return null;
        };
        errdefer self.allocator.free(body);
        if (title.len == 0 and body.len == 0) { // host에 대기 알림 없음(빈 {title,body}).
            self.allocator.free(title);
            self.allocator.free(body);
            return null;
        }
        return .{ .title = title, .body = body };
    }

    /// `{"key":"<json-string>", ...}`에서 `key`의 문자열 값을 디코드해 owned 바이트로 돌려준다(키 없으면 null). host는
    /// `std.json.Stringify`로 escape하므로 그 역(표준 JSON string escape)만 처리한다: `\" \\ \/ \n \r \t \b \f \u00XX`.
    /// Stringify 기본은 non-ASCII를 raw로 두므로 `\uXXXX`는 제어문자(≤0x1F)뿐이라 surrogate pair는 없다. **std.json.parseFromSlice를
    /// 안 쓴다** — 그 숫자 파서가 f128 소프트플로트를 링크로 끌어와 ReleaseSafe 제품 빌드를 깬다(takeNotification 참고).
    fn decodeJsonStringField(allocator: std.mem.Allocator, json: []const u8, key: []const u8) error{OutOfMemory}!?[]u8 {
        var pat_buf: [64]u8 = undefined;
        const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
        const k = std.mem.indexOf(u8, json, pat) orelse return null;
        var i = k + pat.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1; // `:` + 공백 스킵
        if (i >= json.len or json[i] != '"') return null;
        i += 1; // 여는 따옴표 뒤
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        while (i < json.len) : (i += 1) {
            const ch = json[i];
            if (ch == '"') return try out.toOwnedSlice(allocator); // 닫는 따옴표 = 끝
            if (ch != '\\') {
                try out.append(allocator, ch);
                continue;
            }
            i += 1; // escape 문자
            if (i >= json.len) break;
            switch (json[i]) {
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                '/' => try out.append(allocator, '/'),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                'b' => try out.append(allocator, 0x08),
                'f' => try out.append(allocator, 0x0c),
                'u' => {
                    if (i + 4 >= json.len) break;
                    const cp = std.fmt.parseInt(u21, json[i + 1 .. i + 5], 16) catch break;
                    var u8buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &u8buf) catch break;
                    try out.appendSlice(allocator, u8buf[0..n]);
                    i += 4; // 4 hex 소비(루프 증가가 'u'를 넘긴다)
                },
                else => |e| try out.append(allocator, e), // 알 수 없는 escape는 그대로(best-effort)
            }
        }
        return try out.toOwnedSlice(allocator); // 닫는 따옴표 못 만남(손상) — 여기까지 best-effort
    }

    fn terminateBestEffort(self: *RemoteRuntime) void {
        var buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"runtime_id\":\"{s}\"}}", .{self.runtime_id_hex}) catch return;
        const resp = self.client.call("runtime.terminate", params) catch return;
        self.allocator.free(resp);
    }
};

/// `{argv:[...], cols, rows}` spawn params를 JSON으로 만든다(caller free). argv는 임의 바이트라 실 JSON encoder로 escape한다
/// (client hand-built JSON의 신뢰 계약 밖 — client.zig 주석대로 임의 argv는 stringify로).
fn buildSpawnParams(allocator: std.mem.Allocator, argv: []const []const u8, size: terminal.Size) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(.{ .argv = argv, .cols = size.cols, .rows = size.rows }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host에 client-side 원격 runtime을 띄우고 화면을 몬다)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 원격 runtime이 client 쪽에서 **하나의 Surface**로 다뤄져야
// GUI가 in-process와 같은 코드로 렌더한다(SSOT). fork한 host에 RemoteRuntime.spawn으로 셸을 띄우면 그 Surface가 host
// 화면을 반영하고, 입력→delta→Surface 갱신이 도는지, terminate로 회수되는지 고정한다. 실 forkpty·socket이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const daemon = @import("daemon.zig");

extern "c" fn usleep(usec: c_uint) c_int;

test "remote runtime: spawns over the wire, renders host screen into a Surface, and reflects input via delta" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // client-side 원격 runtime: /bin/cat을 띄우고 원격-backed Surface를 세운다.
    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

    // 입력을 보내면 host가 echo → 화면 row0이 바뀌고 delta가 온다. pumpDelta는 논블로킹이라 delta가 도착할 때까지 폴링한다
    // (host delta tick ~20ms). Surface에 "h"가 반영되는지 본다.
    try rr.sendInput("hello\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // 원격 runtime의 화면 변화가 client Surface에 반영됐다.
}

// code-review #1 회귀 — 두 원격 runtime이 **connection 하나**를 공유할 때, 예전엔 한 runtime의 pump가 소켓에서 다른
// runtime의 배치를 읽어 free해(discard) 두 번째 화면이 영구 유실됐다. client의 stream_id demux가 남의 배치를 버퍼해 그
// runtime pump로 보내므로 **둘 다** 자기 echo를 화면에 반영해야 한다. 실 fork host + 실 socket이라 macOS opt-in.
test "remote runtime: two runtimes sharing one connection both receive their own screen updates (demux)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-mux-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // 한 client에 두 원격 runtime을 띄운다(둘 다 /bin/cat). 서로 다른 host runtime → 서로 다른 stream_id로 attach된다.
    var rr1: RemoteRuntime = undefined;
    try rr1.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr1.deinit();
    var rr2: RemoteRuntime = undefined;
    try rr2.spawn(&client, allocator, io, 2, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr2.deinit();
    try testing.expect(rr1.stream_id != rr2.stream_id); // 공유 connection이지만 stream이 갈린다(demux 대상).

    const s1 = rr1.surfacePtr();
    const s2 = rr2.surfacePtr();

    // 각 runtime에 **다른** 입력을 보낸다 → host가 각자 echo → 각 stream에 delta가 온다. 두 pump를 매 tick 함께 돌려
    // (frame loop처럼) 둘 다 자기 echo('h'/'w')를 반영하는지 본다. demux 없으면 먼저 도는 pump가 남의 배치를 삼켜 하나는
    // 영영 못 받는다.
    try rr1.sendInput("hello\n");
    try rr2.sendInput("world\n");
    var f1 = false;
    var f2 = false;
    var attempts: usize = 0;
    while (attempts < 200 and !(f1 and f2)) : (attempts += 1) {
        _ = rr1.pumpDelta() catch break;
        _ = rr2.pumpDelta() catch break;
        s1.lockCore(io);
        const a = s1.renderSnapshot().cells[0].codepoint;
        s1.unlockCore(io);
        s2.lockCore(io);
        const b = s2.renderSnapshot().cells[0].codepoint;
        s2.unlockCore(io);
        if (a == 'h') f1 = true;
        if (b == 'w') f2 = true;
        if (!(f1 and f2)) _ = usleep(20 * 1000);
    }
    try testing.expect(f1); // rr1 화면이 자기 echo를 받았다.
    try testing.expect(f2); // rr2도 — 남의 pump에 배치를 뺏기지 않았다(demux).
}

test "remote runtime: attachExisting reconnects to a pre-existing host runtime and renders its screen" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-att-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    // host에 runtime을 하나 띄운다(raw runtime.spawn — client controller 없이). runtime_id를 얻어 "재실행 후 재접속" 상황을 만든다.
    const spawn_resp = try client.call("runtime.spawn", "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}");
    defer allocator.free(spawn_resp);
    const rid = client_mod.extractRuntimeId(spawn_resp) orelse {
        try testing.expect(false);
        return;
    };

    // **재접속**: attachExisting으로 그 runtime에 붙어 원격-backed Surface를 세운다(spawn 없이 — 저장된 runtime_id로).
    var rr: RemoteRuntime = undefined;
    try rr.attachExisting(&client, allocator, io, 1, rid, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();
    try testing.expectEqual(rid, rr.runtimeIdHex()); // 재접속한 runtime_id가 저장한 값과 같다.

    const surface = rr.surfacePtr();
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0); // 그 runtime의 화면(빈 40x10 cat)을 조립했다.

    // 재접속한 controller로 입력→echo→화면 반영(재접속이 실제 제어권을 얻었다).
    try rr.sendInput("hi\n");
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') found = true else _ = usleep(20 * 1000);
    }
    try testing.expect(found);

    // 없는 runtime_id에 attachExisting → error.AttachFailed(host RuntimeNotFound). app_session restore가 이 신호로 fresh
    // spawn 폴백한다. 실패해도 남의 runtime을 안 죽인다(terminate errdefer 없음).
    var bogus: RemoteRuntime = undefined;
    const bogus_id: [32]u8 = "deadbeefdeadbeefdeadbeefdeadbeef".*;
    try testing.expectError(error.AttachFailed, bogus.attachExisting(&client, allocator, io, 2, bogus_id, .{ .cols = 40, .rows = 10 }));
}

test "remote runtime: takeNotification pulls a host-side OSC 9/777 desktop notification (§6.32)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-notif-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // 처음엔 대기 알림 없음(fresh cat).
    if (try rr.takeNotification()) |n| {
        n.deinit(allocator);
        try testing.expect(false);
    }

    // OSC 777 알림 시퀀스를 입력 → cat이 raw로 echo → host core가 파싱 → notification pending. 폴링으로 뺀다(host tick·echo 대기).
    try rr.sendInput("\x1b]777;notify;Deploy;done in 3s\x1b\\\n");
    var got: ?Notification = null;
    var attempts: usize = 0;
    while (attempts < 100 and got == null) : (attempts += 1) {
        got = try rr.takeNotification();
        if (got == null) _ = usleep(20 * 1000);
    }
    const n = got orelse {
        try testing.expect(false);
        return;
    };
    defer n.deinit(allocator);
    // host의 TerminalCore가 파싱한 OSC 777 title/body가 client로 전달됐다(host-backed 터미널의 알림이 유실 안 됨).
    try testing.expectEqualStrings("Deploy", n.title);
    try testing.expectEqualStrings("done in 3s", n.body);
}

// takeNotification의 수동 JSON 문자열 디코더(std.json.parseFromSlice의 f128 링크 회피). host의 std.json.Stringify escape를
// 되돈다 — 순수 함수라 fork host 없이 escape 처리를 고정한다(제어문자 \u00XX·\" \\ \n \t \uXXXX·키 부재·빈 값·둘째 필드).
test "remote runtime: decodeJsonStringField unescapes JSON string fields (parseFromSlice 대체)" {
    const allocator = testing.allocator;
    const decode = RemoteRuntime.decodeJsonStringField;

    // 단순 값 + 둘째 필드.
    const j1 = "{\"title\":\"Build\",\"body\":\"ok\"}";
    const t1 = (try decode(allocator, j1, "title")).?;
    defer allocator.free(t1);
    try testing.expectEqualStrings("Build", t1);
    const b1 = (try decode(allocator, j1, "body")).?;
    defer allocator.free(b1);
    try testing.expectEqualStrings("ok", b1);

    // escape: quote/backslash/newline/tab + 제어문자 u0007.
    const j2 = "{\"title\":\"a\\\"b\\\\c\\nd\\te\\u0007f\"}";
    const t2 = (try decode(allocator, j2, "title")).?;
    defer allocator.free(t2);
    try testing.expectEqualStrings("a\"b\\c\nd\te\x07f", t2);

    // 키 부재 → null.
    try testing.expect((try decode(allocator, j1, "nope")) == null);

    // 빈 값 → 빈 슬라이스(대기 알림 없음 판정용).
    const j3 = "{\"title\":\"\",\"body\":\"\"}";
    const t3 = (try decode(allocator, j3, "title")).?;
    defer allocator.free(t3);
    try testing.expectEqual(@as(usize, 0), t3.len);

    // 비-ASCII(UTF-8 passthrough — Stringify 기본은 raw).
    const j4 = "{\"body\":\"빌드 완료\"}";
    const b4 = (try decode(allocator, j4, "body")).?;
    defer allocator.free(b4);
    try testing.expectEqualStrings("빌드 완료", b4);
}

// code-review #7 end-to-end — requestResync(§9 desync 복구)가 host에 fresh snapshot을 재요청하면, host가 delta가 아니라
// **snapshot_chunk**(is_snapshot)를 push하는지 실 fork host로 고정한다. drainRemote가 GenerationGap/MalformedRow에서 이걸
// 불러 조립기 generation을 리셋해 "영구 멈춤" 대신 복구한다. macOS opt-in(실 forkpty·socket).
test "remote runtime: requestResync makes the host push a fresh snapshot (desync 복구)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-rsy-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 10 });
    defer rr.deinit();

    // attach가 첫 snapshot을 이미 소비했다 — 이제 fresh snapshot을 **재요청**한다.
    try rr.requestResync();

    // host가 다음 delta tick에 snapshot_chunk를 push한다(delta 아님). 그 배치가 is_snapshot인지 확인한다(input 없어 delta는 안 옴).
    var saw_snapshot = false;
    var attempts: usize = 0;
    while (attempts < 150 and !saw_snapshot) : (attempts += 1) {
        if (try rr.client.readStreamBatch(allocator, rr.stream_id)) |batch| {
            defer allocator.free(batch.bytes);
            if (batch.is_snapshot) saw_snapshot = true;
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_snapshot); // resync 요청이 host의 fresh snapshot push를 유발했다(generation 리셋 = 복구 경로).
}

// code-review #6a end-to-end — 원격 스크롤백. 스크롤 core command를 host로 라우팅하면 host가 자기 core view_offset을 바꾸고,
// projectSnapshot/computeDelta가 renderSnapshot(뷰포트)을 써서 그 스크롤백 윈도를 client에 투영한다. TOPMARKER를 화면 밖
// (스크롤백)으로 민 뒤 위로 스크롤 → client 화면 최상단에 TOPMARKER가 나타나는지 실 fork host로 고정. macOS opt-in.
test "remote runtime: scroll core command routes to host so client sees scrolled-back content (§6a)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-scr-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // TOPMARKER 한 줄 + 8행을 넘기는 filler → TOPMARKER는 스크롤백으로 밀려 화면 밖(host 기본 scrollback 1000행).
    try rr.sendInput("TOPMARKER\n");
    var k: usize = 0;
    while (k < 20) : (k += 1) try rr.sendInput("filler\n");

    // host echo가 화면에 반영될 때까지 pump — 바닥엔 filler(row0 시작이 'f', TOPMARKER는 안 보임).
    var settled = false;
    var attempts: usize = 0;
    while (attempts < 200 and !settled) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'f') settled = true else _ = usleep(20 * 1000);
    }
    try testing.expect(settled); // 바닥 화면은 filler(TOPMARKER는 스크롤백)

    // **위로 스크롤**(host core view_offset 이동 → renderSnapshot 뷰포트가 스크롤백 윈도로) → 최상단에 TOPMARKER.
    try rr.sendCoreCommand("scroll", 100); // 위로 100(스크롤백 top으로 cap)

    var saw_marker = false;
    attempts = 0;
    while (attempts < 200 and !saw_marker) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'T') saw_marker = true else _ = usleep(20 * 1000);
    }
    try testing.expect(saw_marker); // 스크롤 명령이 host를 거쳐 client 화면을 스크롤백(TOPMARKER)으로 이동시켰다(#6a).
}

// code-review #6b end-to-end — 원격 선택 복사. client가 뷰포트 선택 span을 host로 보내면, host가 자기 core에 적용해
// **로컬과 같은 `extractSelection`**(선택 의미론 단일 출처)으로 텍스트를 뽑아 돌려주는지 실 fork host로 고정한다. 하이라이트는
// placeholder core(app_session)가 즉시 그리고, 이 복사만 host가 해석한다("client 렌더/host 해석"). macOS opt-in.
test "remote runtime: selectedText extracts the selection text on the host (§6b, extractSelection 재사용)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rr-sel-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        daemon.runSessionHost(std.heap.page_allocator, io, dir_path, socket_path) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket_path.ptr);
        _ = c.rmdir(dir_path.ptr);
    }

    var client: client_mod.Client = blk: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (client_mod.Client.connect(allocator, socket_path, "gui")) |cl| break :blk cl else |_| _ = usleep(20 * 1000);
        }
        try testing.expect(false);
        return;
    };
    defer client.deinit();

    var rr: RemoteRuntime = undefined;
    try rr.spawn(&client, allocator, io, 1, &.{"/bin/cat"}, .{ .cols = 40, .rows = 8 });
    defer rr.deinit();
    const surface = rr.surfacePtr();

    // "HELLO"를 입력 → cat echo → host core row0 = "HELLO". RemoteScreen에 반영될 때까지 pump(= host가 처리 완료).
    try rr.sendInput("HELLO\n");
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 200 and !ready) : (attempts += 1) {
        _ = rr.pumpDelta() catch break;
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'H') ready = true else _ = usleep(20 * 1000);
    }
    try testing.expect(ready);

    // 뷰포트 선택 span (0,0)~(0,4) = row0의 "HELLO"를 host에 보내 host가 extractSelection으로 뽑는다.
    const span: terminal.SelectionSpan = .{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 4 }, .block = false };
    const text = (try rr.selectedText(span)) orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(text);
    try testing.expectEqualStrings("HELLO", text); // host가 자기 core에서 선택 텍스트를 뽑아 client로 전달했다(선택 의미론=host).
}
