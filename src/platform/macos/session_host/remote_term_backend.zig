//! remote_term_backend — host-backed `TermRuntimeBackend`(P2 계약의 원격 구현) — P3-e3-2.
//!
//! `app.InProcessTermBackend`의 형제다: 같은 `TermRuntimeBackend` vtable을 구현하되, 로컬 PTY를 소유하는 대신 client
//! RPC로 별도 host(`maru-sessiond`)에 runtime을 띄우고(그래야 GUI가 죽어도 PTY 생존) host가 push하는 화면 stream을
//! `RemoteRuntime`(조립기+원격-backed Surface)으로 조립한다. GUI는 이 backend를 in-process와 **똑같은 계약으로** 다뤄
//! spawn/attach/pump/입력/resize/close 한다 — 그래서 app_session의 spawn 체인·teardown은 backend가 로컬인지 원격인지
//! 모른다(§13 seam, e3-4 배선이 `termBackend()`가 이걸 반환하게 한다).
//!
//! 매핑: spawn→`RemoteRuntime.spawn`(runtime.spawn+attach+첫 snapshot)이 원격-backed Surface를 만들어 반환, pump→
//! `RuntimeEventPump.initRemote`(delta stream을 `DrainSummary`로 소비, e3-1), write_input→`sendInput`, resize→
//! `runtime.resize` RPC, close/remove→host terminate + client-side 회수. handle(u64)↔`RemoteRuntime`를 map으로 잇는다.
//!
//! metadata observation(cwd/title/SSH/foreground process/mode/size)은 host full-state event+fresh barrier로 읽고, 원격
//! scroll command는 `runtime.core_command` RPC로 host core에 보낸다. 일반 key/paste/mouse/focus input-mode와 direct
//! `TermRuntimeBackend.enqueueCoreCommand` parity는 아직 후속 gate다. macOS 전용(client·Surface·app 계약).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const client_mod = @import("client.zig");
const remote_runtime = @import("remote_runtime.zig");
const core_command = maru.session.core_command; // §6a 원격 스크롤 명령 라우팅

const Surface = maru.session.Surface;
const term_backend = maru.app.term_runtime_backend;
const TermRuntimeBackend = term_backend.TermRuntimeBackend;
const RuntimeHandle = term_backend.RuntimeHandle;
const SpawnParams = term_backend.SpawnParams;
const RuntimeLink = maru.app.RuntimeLink;
const SurfaceRuntime = maru.app.SurfaceRuntime;
const PtyIo = maru.app.runtime.PtyIo;
const runtime_pump = maru.app.runtime_pump;
const RuntimeEventPump = runtime_pump.RuntimeEventPump;
const DrainSummary = runtime_pump.DrainSummary;
const CoreCommand = maru.session.core_command.CoreCommand;
const ForegroundProcessName = maru.pty.types.ForegroundProcessName;
const nonblocking_input_chunk: usize = 16 * 1024;
const RemoteRuntime = remote_runtime.RemoteRuntime;

/// 한 host connection 위의 원격 term backend. `client`는 borrowed(수명은 caller — app_session이 discovery/connect로 만든
/// connection). `runtimes`가 handle(=surface_id)↔`RemoteRuntime`를 잇는다. **`RemoteRuntime`은 self-referential**(surface.
/// remote가 자기 조립기를 가리킴)이라 heap에 개별 할당해 안정 주소를 준다(map value = `*RemoteRuntime`).
pub const RemoteTermBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.Client,
    // 앱의 in-process 라우팅 표(borrowed — 소유는 AppRuntime). attach가 원격 Term을 여기에 **원격 PtyIo**로 등록해,
    // GUI 입력 hot path(self.runtime.writeInput/resize/enqueueCoreCommand, surface.id 라우팅)가 in-process와 똑같이
    // 원격 Term에 도달하게 한다 — sink만 write_queue→client.sendInput/resize RPC로 갈린다(app_session hot path 무변경).
    // in-process Term은 write_queue PtyIo로 등록되는 것과 대칭. `remove`가 뗀다.
    surface_runtime: *SurfaceRuntime,
    runtimes: std.AutoHashMapUnmanaged(RuntimeHandle, *RemoteRuntime) = .empty,

    const vtable = term_backend.VTable{
        .spawn = spawn,
        .attach = attach,
        .pump = pump,
        .write_input = writeInput,
        .write_input_nonblocking = writeInputNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .resize = resize,
        .close_and_detach = closeAndDetach,
        .close = close,
        .finish_after_termination = finishAfterTermination,
        .remove = remove,
        .foreground_process_group = foregroundProcessGroup,
        .foreground_process_names = foregroundProcessNames,
        .read_observation = readObservation,
        .refresh_observation = refreshObservation,
        .dump_recent_text = dumpRecentText,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *client_mod.Client, surface_runtime: *SurfaceRuntime) RemoteTermBackend {
        return .{ .allocator = allocator, .io = io, .client = client, .surface_runtime = surface_runtime };
    }

    /// 남은 원격 runtime을 회수한다(각각 라우팅 표에서 detach + host terminate + client-side deinit). client connection과
    /// surface_runtime은 borrowed라 안 건드린다(소유는 caller).
    pub fn deinit(self: *RemoteTermBackend) void {
        var it = self.runtimes.iterator();
        while (it.next()) |kv| {
            self.surface_runtime.detachSurface(kv.key_ptr.*); // link(원격 PtyIo)를 먼저 뗀다 — rr.surface가 곧 무효.
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.runtimes.deinit(self.allocator);
        self.* = undefined;
    }

    /// GUI가 쓰는 계약 값(in-process와 동일 표면). ctx는 heap-pin된 backend를 가리켜야 한다(caller가 안정 주소 보장).
    pub fn backend(self: *RemoteTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// **이미 host에 있는 runtime에 재접속**해 원격-backed Surface를 만든다(§7 GUI 재접속, e3-5). spawn과 달리 새 runtime을
    /// 안 띄우고 저장된 `runtime_id_hex`에 붙는다. runtime이 없으면(host 재시작 등) attachExisting이 error를 내고
    /// app_session restore는 동일 세션인 척 fresh spawn하지 않고 fail-closed한다. **vtable 밖 — host 전용**이라
    /// app_session이 restore 경로에서 직접 부른다. spawn과 동일하게 반환 뒤 `attach`(vtable)로 원격 PtyIo를
    /// 라우팅 표에 등록해야 입력이 흐른다.
    pub fn attachTerm(self: *RemoteTermBackend, handle: RuntimeHandle, runtime_id_hex: [32]u8, size: maru.terminal.Size) anyerror!*Surface {
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        try rr.attachExisting(self.client, self.allocator, self.io, handle, runtime_id_hex, size);
        // 재접속은 **기존** host runtime이라 이후 단계(map put)가 실패해도 terminate 금지(§7 attach는 terminate 안 함) —
        // client-side(surface/screen)만 회수한다. spawn 경로는 방금 우리가 띄운 runtime이라 deinit(terminate)이 맞지만
        // attach는 남의 runtime이므로 detachClientSide로 되돌려야 재접속 실패가 세션을 죽이지 않는다.
        errdefer rr.detachClientSide();
        try self.runtimes.put(self.allocator, handle, rr);
        return &rr.surface;
    }

    /// handle의 host runtime_id(hex)를 돌려준다 — workspace capture가 저장해 재실행 시 `attachTerm`으로 재접속한다(§7, e3-5).
    /// 없으면(원격 아님·미등록) null.
    pub fn runtimeIdFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?[32]u8 {
        const rr = self.runtimes.get(handle) orelse return null;
        return rr.runtimeIdHex();
    }

    /// host-backed Term(handle)의 대기 OSC 9/777 데스크톱 알림을 host에서 pull한다(§6.32 GUI surfacing). 없거나 연결 오류면
    /// null(**best-effort** — 알림은 부가 기능이라 오류를 세션에 전파하지 않는다). 반환 `Notification.title/body`는 이 backend의
    /// allocator 소유(caller가 `deinit`). host core가 파싱한 알림(placeholder client core엔 없음)을 app_session 알림 경로에 잇는다.
    pub fn takeNotificationFor(self: *RemoteTermBackend, handle: RuntimeHandle) ?remote_runtime.Notification {
        const rr = self.runtimes.get(handle) orelse return null;
        return rr.takeNotification() catch return null;
    }

    /// host-backed Term(handle)의 현재 뷰포트 선택 텍스트를 host에서 뽑는다(§6b — host의 `extractSelection` 재사용). 없거나
    /// 연결 오류면 null(best-effort — 복사는 부가라 세션에 전파 않음). caller가 free. 선택 span은 placeholder core가 렌더용으로
    /// 든 것을 app_session이 넘긴다(하이라이트=client 좌표, 복사 콘텐츠=host 해석).
    pub fn selectedTextFor(self: *RemoteTermBackend, handle: RuntimeHandle, span: maru.terminal.SelectionSpan) ?[]u8 {
        const rr = self.runtimes.get(handle) orelse return null;
        return (rr.selectedText(span) catch return null) orelse null;
    }

    /// host-backed Term(handle)에서 검색어 매치를 host가 찾게 하고(§6c — `findMatches` 재사용) 보이는 매치 뷰포트 span을
    /// `out_spans`에 채운다. 전체 매치 수를 돌려준다. 없거나 오류면 null(best-effort). 검색 의미론은 host core 단일 출처.
    pub fn findFor(self: *RemoteTermBackend, handle: RuntimeHandle, query: []const u8, cur_index: u32, scroll: bool, out_spans: *std.ArrayList(maru.terminal.SelectionSpan)) ?remote_runtime.RemoteRuntime.FindResult {
        const rr = self.runtimes.get(handle) orelse return null;
        return rr.find(query, cur_index, scroll, out_spans) catch null;
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*Surface {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = try self.allocator.create(RemoteRuntime);
        errdefer self.allocator.destroy(rr);
        const request = persistentSpawnRequest(params.request);
        try rr.spawn(self.client, self.allocator, self.io, params.handle, request, params.size);
        errdefer rr.deinit(); // spawn 성공 후 map 삽입이 실패하면 방금 띄운 host runtime을 회수한다(orphan 방지).
        try self.runtimes.put(self.allocator, params.handle, rr);
        return &rr.surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!RuntimeLink {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = process_in_reader; // 원격은 spawn이 이미 host에 controller attach했다(output은 host가 처리, 로컬 reader 없음).
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        // 원격 Term을 앱 라우팅 표에 **원격 PtyIo**로 등록한다(in-process가 write_queue PtyIo로 등록되는 것과 대칭).
        // 이후 self.runtime.writeInput/resize/enqueueCoreCommand(handle)가 이 PtyIo로 갈려 sendInput/resize RPC로 간다 —
        // GUI 입력 hot path는 로컬/원격을 모른다. handle=surface_id=pty_id라 라우팅 키 변환이 없다.
        return self.surface_runtime.attach(&rr.surface, handle, remotePtyIo(rr));
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!RuntimeEventPump {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        // 원격 pump: frame loop의 drainAvailable이 delta stream을 소비하도록 vtable을 심는다(e3-1). ctx=이 RemoteRuntime.
        return RuntimeEventPump.initRemote(self.allocator, .{ .ctx = rr, .drain = drainRemote });
    }

    /// `RemotePump.drain` — 원격 delta stream을 논블로킹으로 다 비워 `DrainSummary`를 만든다(로컬 큐 drain과 같은 의미).
    /// 적용된 배치 수만큼 output_events(→ metal_dirty), wire/apply 오류는 error로 던지지 않고 ended(read_error)로 바꿔
    /// frame loop가 surface를 exited로 표시하게 한다(로컬 read_error 계약과 동형 — host 연결 끊김 = 세션 종료).
    fn drainRemote(ctx: *anyopaque) DrainSummary {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        var summary: DrainSummary = .{};
        while (true) {
            const result = rr.pumpDelta() catch |err| {
                switch (err) {
                    // 복구 가능 desync(§9 — 조립기가 "reject-and-request-fresh"로 표시): host에 fresh snapshot을 재요청한다.
                    // 다음 tick에 snapshot_chunk가 와 applySnapshot이 generation을 리셋해 복구한다. read_error로 종료하지 **않는다**
                    // (예전엔 여기서 read_error로 뭉개 터미널이 영구 멈췄다 — code-review #7). resync 실패(연결 죽음)는 무시하되,
                    // 다음 pumpDelta가 그 연결 오류를 read_error로 잡아 세션을 정상 종료시킨다.
                    error.GenerationGap, error.MalformedRow => {
                        rr.requestResync() catch {};
                        break;
                    },
                    // 그 외(연결 끊김·codec DecodeError 등)는 세션 종료로 본다(로컬 read_error 계약과 동형). @errorName은 정적
                    // 문자열이라 DrainSummary.ended가 소비될 때까지 산다(runtime_pump.Termination 계약).
                    else => {
                        if (summary.ended == null) summary.ended = .{ .read_error = @errorName(err) };
                        break;
                    },
                }
            };
            switch (result) {
                .idle => break,
                .metadata => continue,
                .screen => summary.output_events += 1,
            }
        }
        return summary;
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return rr.sendInput(bytes);
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return writeInputChunk(rr, bytes);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: CoreCommand, io: std.Io) anyerror!void {
        _ = ctx;
        _ = handle;
        _ = cmd;
        _ = io;
        // 원격은 host가 core를 소유한다 — core command(scrollback/clear 등)를 host로 보내는 wire RPC는 후속(e3-3).
        // 지금은 no-op(계약 표면만 채운다). app_session은 아직 이 경로를 계약이 아니라 self.runtime으로 직접 부르므로
        // (e3 탐색이 확인한 우회) 현재 배선에선 원격 Term에 core command가 도달하지도 않는다.
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: maru.terminal.Size, io: std.Io) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = io;
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return rr.resize(size.cols, size.rows);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.get(handle)) |rr| rr.terminate(); // host runtime kill(멱등). client 객체는 remove가 회수.
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.get(handle)) |rr| rr.terminate();
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) void {
        _ = ctx;
        _ = handle;
        // 원격은 join할 로컬 reader 스레드가 없다(host가 소유). 종료는 drainRemote의 ended로 관측된다 — no-op.
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        if (self.runtimes.fetchRemove(handle)) |kv| {
            self.surface_runtime.detachSurface(handle); // 라우팅 link(원격 PtyIo)를 먼저 뗀다 — rr.surface가 곧 무효.
            kv.value.deinit(); // host terminate(멱등) + surface/remote_screen 회수. 이후 handle과 surface 포인터는 무효.
            self.allocator.destroy(kv.value);
        }
    }

    /// 원격 Term을 **terminate 없이** 회수한다(§6 app-quit=detach, e3-6). `remove`와 대칭이되 host `runtime.terminate`를 안
    /// 보낸다 — 라우팅 link를 떼고 client-side rr만 free하므로 runtime이 host에 남아 재접속 대상이 된다(연결이 닫히면 host가
    /// controller를 detach로 처리해 유지). 앱 quit 시 host-backed Term에 쓴다(윈도우/탭 명시 close는 `remove`=terminate).
    /// **vtable 밖** — app_session deinit이 app_quitting일 때 직접 부른다.
    pub fn detachTerm(self: *RemoteTermBackend, handle: RuntimeHandle) void {
        if (self.runtimes.fetchRemove(handle)) |kv| {
            self.surface_runtime.detachSurface(handle);
            kv.value.detachClientSide(); // surface/remote_screen만 회수 — terminate 안 함(runtime 생존).
            self.allocator.destroy(kv.value);
        }
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return null;
        if (rr.observation.availability != .current or !rr.observation.foreground_available) return null;
        return rr.observation.foreground_pgid;
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []ForegroundProcessName) usize {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return 0;
        if (rr.observation.availability != .current or !rr.observation.foreground_available) return 0;
        const count = @min(out.len, rr.observation.foreground_processes.items.len);
        @memcpy(out[0..count], rr.observation.foreground_processes.items[0..count]);
        return count;
    }

    fn readObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground; // host event가 bounded cadence로 foreground까지 coherent하게 갱신한다.
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        if (out.availability == rr.observation.availability and
            out.revision == rr.observation.revision and
            out.size.cols == rr.observation.size.cols and
            out.size.rows == rr.observation.size.rows)
            return;
        try out.replace(allocator, rr.observation.view());
    }

    fn refreshObservation(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, out: *term_backend.RuntimeObservation, include_foreground: bool) anyerror!void {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        _ = include_foreground;
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        try rr.refreshObservation();
        try out.replace(allocator, rr.observation.view());
    }

    fn dumpRecentText(ctx: *anyopaque, handle: RuntimeHandle, allocator: std.mem.Allocator, max_rows: usize, max_bytes: usize) anyerror![]u8 {
        const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));
        const rr = self.runtimes.get(handle) orelse return error.UnknownSurface;
        return rr.remote_screen.dumpRecentTextUtf8(allocator, self.io, max_rows, max_bytes);
    }

    // ── 원격 PtyIo(SurfaceRuntime link의 input/resize sink) ─────────────────────────
    //
    // in-process는 link의 PtyIo가 live_pty write_queue를 가리키지만, 원격은 여기 세 함수가 그 자리를 채워 sendInput/
    // resize RPC로 보낸다. ctx=*RemoteRuntime. `enqueue_command`는 null로 둔다 — 원격 core command wire RPC가 없어
    // SurfaceRuntime이 placeholder core에 직접 적용으로 폴백한다(후속 e3; placeholder는 렌더 안 되므로 무해하나 config
    // 명령이 host core엔 도달 안 함). `write_input_nb`는 채운다(paste 논블로킹 계약 — socket write는 전량 전송으로 본다).

    fn remotePtyIo(rr: *RemoteRuntime) PtyIo {
        return .{
            .ctx = rr,
            .write_input = ioWriteInput,
            .resize_fn = ioResize,
            .write_input_nb = ioWriteInputNonBlocking,
            .enqueue_command = ioEnqueueCommand, // §6a: 스크롤 core command를 host로 라우팅(원격 스크롤백).
        };
    }

    /// §6a 원격 스크롤백: SurfaceRuntime.enqueueCoreCommand가 host-backed Term에 부르는 hook. **스크롤 계열만** host로
    /// 라우팅한다(host가 자기 core view_offset을 바꿔 스크롤백 화면을 투영→RemoteScreen이 렌더). 선택(select_*)·config·IME는
    /// placeholder core에 적용해도 렌더 안 되므로 **drop**(후속 #6b/config). arg는 signed(scroll delta 음수).
    fn ioEnqueueCommand(ctx: *anyopaque, cmd: core_command.CoreCommand) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        const max_i64: usize = @intCast(std.math.maxInt(i64)); // usize→i64 방어(스크롤백 abs가 i64 초과=비현실적, 패닉 회피).
        switch (cmd) {
            .scroll => |d| try rr.sendCoreCommand("scroll", @intCast(d)),
            .scroll_to_bottom => try rr.sendCoreCommand("scroll_to_bottom", 0),
            .scroll_to_abs => |a| try rr.sendCoreCommand("scroll_to_abs", @intCast(@min(a, max_i64))),
            .scroll_to_offset => |o| try rr.sendCoreCommand("scroll_to_offset", @intCast(@min(o, max_i64))),
            // §6b-1 드래그 선택: 하이라이트 span은 client 좌표라 **placeholder core에 적용해 즉시** 반영한다(렌더가 이미
            // surface.core.selectionViewportSpan을 읽음 — 새 렌더 배선/span-push 불요, 왕복 지연 없음). 복사(콘텐츠 연산)는
            // app_session.copyText가 이 span을 host로 보내 host의 extractSelection으로 한다(선택 의미론=host 단일 출처).
            // 콘텐츠 인지 경계(word/line)는 빈 placeholder에선 부정확하므로 후속(#6b-2, host 계산). scroll_and_extend(autoscroll
            // 드래그)도 후속. select_all은 placeholder 뷰포트 전체 선택 → 보이는 화면 복사(host가 스크롤백까지는 후속).
            .select_start, .select_extend, .select_extend_or_collapse, .select_all => core_command.apply(&rr.surface.core, cmd),
            // §6b-2 단어/줄 선택: 콘텐츠 인지 경계는 빈 placeholder가 모르므로 **host가 계산해 span을 돌려준다**(selectContentAware).
            // 그 span을 placeholder에 적용해 하이라이트(렌더가 selectionViewportSpan을 읽음). 복사는 #6b-1이 그 span으로 host 추출.
            .select_word => |s| {
                if (rr.selectContentAware("word", s.row, s.col) catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            .select_line => |row| {
                if (rr.selectContentAware("line", row, 0) catch null) |span| {
                    rr.surface.core.selectionStart(span.start.row, span.start.col);
                    rr.surface.core.selectionExtend(span.end.row, span.end.col);
                }
            },
            // §입력 패리티: 마우스 리포트는 host core가 자기 mouse_tracking/format으로 인코딩·PTY 주입해야 하므로
            // (인코딩 모드가 host에만 있음) raw 이벤트를 host로 보낸다(방식 B). placeholder core에 적용하면 응답이
            // client PTY로 안 가고(빈 placeholder) 인코딩 모드도 없어 무효다.
            .report_mouse => |m| try rr.sendMouseReport(m),
            else => {}, // scroll_and_extend(autoscroll)/focus/config/IME는 후속 — 무시.
        }
    }

    fn ioWriteInput(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.sendInput(bytes);
    }

    fn ioWriteInputNonBlocking(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return writeInputChunk(rr, bytes);
    }

    fn ioResize(ctx: *anyopaque, size: maru.terminal.Size) anyerror!void {
        const rr: *RemoteRuntime = @ptrCast(@alignCast(ctx));
        return rr.resize(size.cols, size.rows);
    }
};

fn persistentSpawnRequest(request_in: maru.pty.SpawnRequest) maru.pty.SpawnRequest {
    var request = request_in;
    // MARU_PANE_ID는 GUI process-local surface id라 재실행 후 같은 persistent child 안에서 stale selector가 된다.
    // runtime↔새 surface rebinding 프로토콜 전에는 주입하지 않아 잘못된 다른 pane을 self로 선택하는 것보다 fail-closed한다.
    request.pane_id = null;
    return request;
}

test "persistent spawn omits process-local MARU_PANE_ID without mutating local fallback request" {
    const local: maru.pty.SpawnRequest = .{ .command = "/bin/zsh", .pane_id = 42 };
    const persistent = persistentSpawnRequest(local);
    try std.testing.expectEqual(@as(?u64, 42), local.pane_id);
    try std.testing.expectEqual(@as(?u64, null), persistent.pane_id);
}

/// vtable 직접 호출과 SurfaceRuntime의 PtyIo 호출이 공유하는 paste 정책점. socket 자체는 아직 blocking이지만 한 UI
/// tick의 전송량을 고정 상한으로 제한하고, caller는 반환 길이 뒤의 나머지를 다음 tick에 이어 보낸다.
fn writeInputChunk(rr: *RemoteRuntime, bytes: []const u8) anyerror!usize {
    const chunk = bytes[0..boundedInputLen(bytes.len)];
    try rr.sendInput(chunk);
    return chunk.len;
}

fn boundedInputLen(len: usize) usize {
    return @min(len, nonblocking_input_chunk);
}

test "remote nonblocking input policy consumes at most one bounded chunk per tick" {
    try std.testing.expectEqual(@as(usize, 0), boundedInputLen(0));
    try std.testing.expectEqual(nonblocking_input_chunk, boundedInputLen(nonblocking_input_chunk));
    try std.testing.expectEqual(nonblocking_input_chunk, boundedInputLen(nonblocking_input_chunk + 1));
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork된 host에 TermRuntimeBackend **계약으로** 원격 runtime을 몬다)
//
// 이 테스트가 증명하는 것(그리고 왜 e3에서 중요한가): GUI는 backend가 로컬인지 원격인지 모르고 `TermRuntimeBackend`
// 계약만 부른다. 그 계약(spawn→attach→pump→writeInput→close/remove)이 실 host runtime을 실제로 구동하고, pump가
// delta stream을 drainAvailable로 소비해 Surface에 입력 echo가 반영되는지 고정한다 — 즉 app_session이 이 backend를
// 꽂기만 하면(e3-4) host-backed 터미널이 in-process와 같은 코드로 도는지 검증. 실 forkpty·socket이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const c = std.c;
const posix = std.posix;
const daemon = @import("daemon.zig");

extern "c" fn usleep(usec: c_uint) c_int;

test "remote term backend: drives a real host runtime through the TermRuntimeBackend contract" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-rtb-{d}", .{c.getpid()}) catch return error.SkipZigTest;
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

    // 앱 라우팅 표(GUI 입력 hot path가 쓰는 그 표). backend가 원격 Term을 여기 등록한다.
    var surface_runtime = maru.app.SurfaceRuntime.init(allocator);
    defer surface_runtime.deinit();

    var be_impl = RemoteTermBackend.init(allocator, io, &client, &surface_runtime);
    defer be_impl.deinit();
    const be = be_impl.backend();

    // 계약으로 원격 runtime을 띄운다: /bin/cat, 40x10. 반환 Surface는 원격-backed(surface.remote 세팅).
    const size = maru.terminal.Size{ .cols = 40, .rows = 10 };
    const surface = try be.spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/cat", .size = size },
        .size = size,
        .queue_capacity = 16,
    });

    // Surface가 원격 화면을 렌더한다(초기 cat 화면 = 빈 40x10).
    surface.lockCore(io);
    const cols0 = surface.renderSnapshot().size.cols;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u16, 40), cols0);

    const link = try be.attach(1, true); // 원격 Term을 SurfaceRuntime에 원격 PtyIo로 등록한다(RuntimeLink 반환).
    try testing.expectEqual(@as(u64, 1), link.surface_id);
    var frame_pump = try be.pump(1); // 원격 모드 RuntimeEventPump.

    // **핵심**: GUI 키 입력 hot path와 **똑같이** self.runtime.writeInput(surface.id, ...)로 보낸다 — 계약 vtable을 우회해도
    // 원격 PtyIo→client.sendInput→host로 라우팅된다(app_session 무변경으로 원격 입력이 도달함을 증명). host가 echo → delta →
    // pump.drainAvailable()(원격 drain)로 소비해 Surface에 "h"가 반영되는지 폴링(host delta tick ~20ms).
    try surface_runtime.writeInput(1, .{ .bytes = "hello\n" });
    var found = false;
    var attempts: usize = 0;
    while (attempts < 100 and !found) : (attempts += 1) {
        const ds = try frame_pump.drainAvailable();
        surface.lockCore(io);
        const c0 = surface.renderSnapshot().cells[0].codepoint;
        surface.unlockCore(io);
        if (c0 == 'h') {
            found = true;
            try testing.expect(ds.output_events > 0); // 배치가 적용된 tick은 렌더 트리거를 낸다.
        } else _ = usleep(20 * 1000);
    }
    try testing.expect(found); // hot path(SurfaceRuntime)를 통한 원격 입력이 host를 거쳐 Surface에 반영됐다.

    // resize도 hot path(self.runtime.resize)로 원격 PtyIo→resize RPC에 도달한다(에러 없이 위임).
    try surface_runtime.resize(1, .{ .cols = 80, .rows = 24 }, io);

    be.closeAndDetach(1);
    be.remove(1); // client-side 회수(map 제거 + SurfaceRuntime detach + host terminate 멱등).
    try testing.expectEqual(@as(usize, 0), be_impl.runtimes.count());
    // remove가 라우팅 표에서도 뗐다 — 이제 hot path 입력은 UnknownSurface(dangling link 없음).
    try testing.expectError(error.UnknownSurface, surface_runtime.writeInput(1, .{ .bytes = "x" }));
}
