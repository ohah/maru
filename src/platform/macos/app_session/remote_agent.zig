//! 원격(ssh) 에이전트 채널 — host 연결 수명, Term 에 붙이기, 줄 공급, 정리.
//!
//! 원격 «활동 뷰» 자체는 `agent_activity.zig` 가, 에이전트 관측은 `agent.zig` 가 갖는다.
//! 여기는 **채널**(어느 dest 의 어느 host 가 어느 Term 에 물려 있나)만 소유한다.
//!
//! `app_session.zig` 에서 목적별로 떼어낸 그룹이다(docs/plans/app-session-decomposition.md §4.1).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const renderer = maru.renderer;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const RemoteAgentHost = AppSession.RemoteAgentHost;
const RemoteUpload = AppSession.RemoteUpload;
const is_macos = app_session_mod.is_macos;
const ssh_upload = app_session_mod.ssh_upload;
const term_nonce_tail_buf = AppSession.term_nonce_tail_buf;
const Term = app_session_mod.Term;
const agent_ops = @import("agent.zig");
const term_ops = @import("term.zig");
const dock_ops = @import("dock.zig");
const tab_ops = @import("tab.zig");
const agent_activity_ops = @import("agent_activity.zig");

/// 원격 에이전트 이벤트 채널을 **한 tick 만큼** 돌린다([계획](../../../docs/plans/remote-agent-state.md) RA5).
///
/// 세 일을 순서대로 한다: ① 원격 Term 을 훑어 그 목적지의 채널을 보장하고 pane nonce 를 세운다,
/// ② 각 목적지의 자식 stdout 을 논블로킹으로 훑어 **완성된 줄만** 그 목적지의 Term 들에 먹인다,
/// ③ 이번 tick 에 아무 Term 도 안 쓴 목적지를 회수한다.
///
/// **전송은 host 당 하나, 파싱 상태는 Term 당 하나다.** 한 목적지에 pane 이 셋이면 ssh 자식은 하나이고
/// `Channel` 은 셋이다 — 각 Term 이 자기 hello·침묵 시한을 따로 재고 자기 nonce 만 먹는다. 전송을 Term
/// 당 두면 `MaxSessions` 에 걸리고(pane 5 개가 상한), 파싱 상태를 host 당 두면 한 Term 의 강등이 같은
/// 호스트의 남의 Term 까지 끌고 내려간다.
///
/// **읽기가 UI 를 안 멈춘다.** fd 를 `O_NONBLOCK` 으로 두고 읽을 것이 없으면 즉시 돌아온다.
pub fn pumpRemoteAgentChannels(self: *AppSession) void {
    if (!is_macos) return;

    // **게이트가 꺼져 있으면 축 자체를 접는다.** 두 이유가 있고 둘째가 더 무겁다.
    //
    // ① 사용자가 «에이전트 훅을 쓰지 않겠다» 고 한 것이다. 그런데도 목적지마다 `ssh` 를 띄우고
    //    원격에서 스트리머를 돌리는 것은 그 뜻을 정면으로 어긴다.
    // ② **더 나쁜 것은 소스가 둘이 되는 것이다.** 게이트가 꺼지면 `modeFor` 는 `.observe` 를 주고
    //    그 가지는 `pollAgentState` 가 `agent_state` 를 쓴다 — 그런데 채널을 계속 돌리면 원격
    //    소비자도 `applyHookEvent` 로 **같은 자리**에 쓴다. 계약 §1 이 금지한 «한 Term 두 소스» 이고,
    //    증상은 «배지가 가끔 틀림» 이라 재현되지 않는다.
    if (!self.loaded_config.config.sidebar.agent_hooks) {
        closeAllRemoteAgentHosts(self);
        return;
    }
    if (self.remote_agent_hosts.count() == 0 and self.tabs.items.len == 0) return;

    const now_ms = self.awakeMs();
    {
        var it = self.remote_agent_hosts.valueIterator();
        while (it.next()) |h| h.seen_this_tick = false;
    }

    // ① 원격 Term 마다 목적지 채널을 보장한다.
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.live_initialized or term.rt.terminated) continue;
                const ctx = self.remoteUploadContextFor(term) orelse {
                    // **원격이 아니게 된 Term 에서는 채널을 떼어 낸다.** 안 떼면 `modeFor` 가
                    // «채널이 열렸다» 를 맨 먼저 보므로 그 pane 은 ssh 를 빠져나온 뒤에도 **소스
                    // 없이 훅 모드에 갇힌다** — 거기서 로컬 에이전트를 띄워도 배지가 안 선다.
                    //
                    // ⚠️ **관측이 최신일 때만 판정한다.** `remoteUploadContextFor` 는 재접속 중의
                    // `stale` 에서도 null 을 준다 — 그 순간을 «원격이 아니다» 로 읽으면 잠깐 끊길
                    // 때마다 채널이 끊기고 배지가 깜빡인다.
                    if (term.rt.observation.availability == .current and
                        !term.rt.observation.ssh_remote_dest_present)
                    {
                        term.agent_remote_channel = null;
                        term.agent_remote_nonce_len = 0;
                    }
                    continue;
                };
                defer ctx.deinit(self.allocator);
                ensureRemoteAgentTerm(self, term, ctx, now_ms);
            }
        }
    }

    // ② 목적지마다 읽어 그 목적지의 Term 들에 먹인다.
    var hosts = self.remote_agent_hosts.iterator();
    while (hosts.next()) |entry| {
        const dest = entry.key_ptr.*;
        const host = entry.value_ptr;
        drainRemoteAgentHost(self, dest, host, now_ms);
    }

    // ③ 이번 tick 에 아무도 안 쓴 목적지를 회수한다. **자식을 먼저 죽이고 표에서 뗀다** — 순서를
    // 뒤집으면 키를 잃어 자식을 영영 못 죽인다.
    var dead: [8][]const u8 = undefined;
    var dead_n: usize = 0;
    var scan = self.remote_agent_hosts.iterator();
    while (scan.next()) |entry| {
        if (entry.value_ptr.seen_this_tick) continue;
        if (dead_n == dead.len) break; // 다음 tick 에 마저 회수한다(한 tick 에 여덟이면 충분하다)
        dead[dead_n] = entry.key_ptr.*;
        dead_n += 1;
    }
    for (dead[0..dead_n]) |key| closeRemoteAgentHost(self, key);
}

/// 이 Term 의 pane nonce 를 세우고, 그 목적지의 채널·파싱 상태를 보장한다.
pub fn ensureRemoteAgentTerm(self: *AppSession, term: *Term, ctx: RemoteUpload, now_ms: u64) void {
    const hc = maru.session.agent_hook_command;

    // **nonce 는 이 Term 이 원격에 실어 보낸 그 값이어야 한다.** 만드는 곳을 하나로 둔다 — `maru ssh`
    // 는 pane 셸 env 에서 읽고 이쪽은 같은 두 값을 Term 에서 읽는다(둘 다 `formatRemotePaneNonce`).
    // 출처가 둘이라 **굳히면 안 된다** — 한쪽이 움직이면 굳은 값은 영영 어긋나고, 그 Term 은 자기
    // 이벤트를 하나도 못 받는다(2026-09-07 실측: 열 세션 중 둘만 떴다). 그래서 매 tick 다시 세우고
    // 달라지면 따라간다. 세울 수 없는 순간(재부착 중 registry 공백)에는 **들고 있던 값을 지키고**,
    // 처음부터 없었을 때만 물러난다 — 지우면 그 tick 의 이벤트를 통째로 버린다.
    {
        var buf: [hc.remote_pane_nonce_max]u8 = undefined;
        if (agent_ops.remotePaneNonceFor(term, &buf)) |nonce| {
            const cur = term.agent_remote_nonce[0..term.agent_remote_nonce_len];
            if (!std.mem.eql(u8, cur, nonce)) {
                if (cur.len != 0) self.reportRemoteNonceRebind(ctx.dest, cur, nonce);
                @memcpy(term.agent_remote_nonce[0..nonce.len], nonce);
                term.agent_remote_nonce_len = @intCast(nonce.len);
            }
        } else if (term.agent_remote_nonce_len == 0) return;
    }

    const gop = self.remote_agent_hosts.getOrPut(self.allocator, ctx.dest) catch return;
    if (!gop.found_existing) {
        // 키를 우리가 소유한다 — `ctx` 는 이 호출이 끝나면 해제된다.
        const key = self.allocator.dupe(u8, ctx.dest) catch {
            _ = self.remote_agent_hosts.remove(ctx.dest);
            return;
        };
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{};
        // **먼저 훅을 깐다**(RA3). 그 기계의 maru 가 그 기계의 락으로 자기 설정을 고친다 — 로컬이
        // 원격 파일을 직접 고치면 그 기계의 claude·codex 와 경합하고, 그 파일은 사용자의 다른 설정을
        // 함께 담는다.
        self.spawnRemoteHookInstall(gop.value_ptr, ctx);
    }
    gop.value_ptr.seen_this_tick = true;

    // 끝난 목적지에는 **파싱 상태도 새로 안 연다** — 열면 hello 를 5 초 기다렸다 `no_hello` 로 닫히는
    // 헛도는 채널이 Term 마다 생긴다.
    if (gop.value_ptr.stopped) return;
    // **설치가 끝나기 전에는 채널도 안 연다.** 열면 hello 시한 5 초가 설치 왕복과 겹쳐, 느린 링크에서
    // 「설치는 됐는데 채널은 이미 죽은」 상태가 된다.
    if (!gop.value_ptr.stream_started) return;
    // **침묵으로 죽은 채널을 되살린다.** 하트비트는 5 초, 침묵 시한은 15 초라 세 번 놓치면 채널이
    // `silent` 로 닫히는데 — 그것은 EOF 가 아니라 **재시작 트리거가 없고**, 아래는 `null` 일 때만
    // 열어서 그 Term 은 스트리머가 멀쩡한데도 영영 못 받는다(적대적 검증 9 회차).
    //
    // **`saw_hello` 일 때만 되살린다.** `no_hello`·`noise_overflow` 는 제한 서버(`ForceCommand`)를
    // 가리는 신호라 되살리면 5 초마다 열고 닫는 헛돌이가 된다 — 그 둘은 `saw_hello` 가 false 다.
    // ⚠️ **값으로 먼저 묻고 나서 지운다.** `if (opt) |*ch|` 로 optional 안을 가리킨 채 그 자리에
    // `null` 을 넣으면 자기가 보던 것을 무효화한다.
    const channel_dead = if (gop.value_ptr.saw_hello)
        (if (term.agent_remote_channel) |ch| ch.isClosed() else false)
    else
        false;
    if (channel_dead) term.agent_remote_channel = null;
    if (term.agent_remote_channel == null) {
        // **이 목적지가 이미 `hello` 를 봤으면 그 상태로 연다.** 그 줄은 연결 시작에 한 번뿐이라,
        // 뒤늦게 여는 채널을 `waiting_hello` 로 두면 5 초 뒤 죽는다 — 그리고 죽은 채널도 분배
        // 셈에는 들어가 「열을 다 먹였는데 하나도 안 맞는다」가 된다(2026-09-10 실측).
        const ras = maru.session.remote_agent_stream;
        term.agent_remote_channel = if (gop.value_ptr.saw_hello)
            ras.Channel.initOpen(now_ms)
        else
            ras.Channel.init(now_ms);
    }
}

/// 이 목적지의 Term 채널을 **버린다**(닫는 게 아니라 지운다).
///
/// 새 스트리머는 `hello` 를 처음부터 다시 보내므로, 옛 채널을 들고 있으면 그 줄을 `.ignored` 로
/// 넘기거나(이미 `.open`) 아예 못 본다(이미 `.closed`). 지워야 다음 tick 이 새 상태로 연다.
pub fn clearRemoteAgentChannels(self: *AppSession, dest: []const u8) void {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.observation.ssh_remote_dest_present) continue;
                if (!std.mem.eql(u8, term.rt.observation.ssh_remote_dest.items, dest)) continue;
                term.agent_remote_channel = null;
            }
        }
    }
}

/// 한 목적지의 자식 stdout 을 훑어 **완성된 줄만** 그 목적지의 Term 들에 먹인다.
pub fn drainRemoteAgentHost(self: *AppSession, dest: []const u8, host: *RemoteAgentHost, now_ms: u64) void {
    if (host.stopped) return;
    // 설치가 아직이면 그것부터 훑는다 — 끝나면 그 안에서 스트리머가 뜬다.
    if (!host.install_done) {
        // **설치를 못 띄웠으면 다시 띄운다.** `spawnRemoteHookInstall` 은 `ctx`(dest + **ctl**)를 받는데
        // 이 경로에는 `ctl` 이 없어 `HOME` 에서 다시 만든다 — 그 배선이 없어서 #3374 가 이 자리를
        // 남겼었다. 예약이 없거나 아직 때가 아니면 그대로 기다린다.
        if (host.install == null) {
            if (host.retry_at_ms == 0 or now_ms < host.retry_at_ms) return;
            host.retry_at_ms = 0; // 예약을 먼저 지운다 — 아래에서 굳히면 매 tick 다시 오면 안 된다
            const home = std.c.getenv("HOME") orelse {
                std.log.scoped(.agent).warn("HOME 이 없어 원격 훅 설치를 다시 못 띄운다 dest={s}", .{dest});
                host.stopped = true;
                return;
            };
            const ctl = maru.cli.ssh.controlSocketPath(self.allocator, std.mem.span(home), dest) catch |err| {
                if (AppSession.controlPathErrorIsPermanent(err)) {
                    std.log.scoped(.agent).warn("control socket 경로가 규격을 넘는다 — 원격 배지는 안 선다 dest={s}", .{dest});
                    host.stopped = true;
                    return;
                }
                self.scheduleStreamerRetry(dest, host, "control socket 경로를 못 만들었다");
                return;
            };
            defer self.allocator.free(ctl);
            const dest_buf = self.allocator.dupe(u8, dest) catch {
                self.scheduleStreamerRetry(dest, host, "목적지 이름을 못 담았다");
                return;
            };
            defer self.allocator.free(dest_buf);
            self.spawnRemoteHookInstall(host, .{ .dest = dest_buf, .ctl = ctl });
            return;
        }
        self.pumpRemoteHookInstall(dest, host, now_ms);
        return;
    }
    if (!host.stream_started) {
        // 예약된 재시도가 있으면 그때 다시 띄운다(RA5-b). 없으면 예전처럼 물러난다.
        if (host.retry_at_ms == 0 or now_ms < host.retry_at_ms) return;
        // ⚠️ **예약을 먼저 지운다.** 아래 둘은 「영원히 안 된다」이고(설치 경로도 같은 조건에서
        // `stopped` 를 세운다), 예약을 남긴 채 빠져나가면 때가 이미 지났으므로 **매 tick 다시
        // 시도한다** — 로그도 notice 도 없이 영원히다(적대적 검증이 잡았다).
        host.retry_at_ms = 0;
        const home = std.c.getenv("HOME") orelse {
            std.log.scoped(.agent).warn("HOME 이 없어 원격 이벤트 채널을 못 연다 dest={s}", .{dest});
            host.stopped = true;
            return;
        };
        const ctl = maru.cli.ssh.controlSocketPath(self.allocator, std.mem.span(home), dest) catch |err| {
            if (AppSession.controlPathErrorIsPermanent(err)) {
                std.log.scoped(.agent).warn("control socket 경로가 규격을 넘는다 — 원격 배지는 안 선다 dest={s}", .{dest});
                host.stopped = true;
                return;
            }
            self.scheduleStreamerRetry(dest, host, "control socket 경로를 못 만들었다");
            return;
        };
        defer self.allocator.free(ctl);
        self.spawnStreamerFor(dest, host, ctl);
        return;
    }
    var buf: [16 * 1024]u8 = undefined;
    var eof = false;
    while (host.pending.items.len < RemoteAgentHost.pending_soft_cap) {
        const n = std.c.read(host.stream.out_fd, &buf, buf.len);
        if (n > 0) {
            host.pending.appendSlice(self.allocator, buf[0..@intCast(n)]) catch break;
            // 개행 없이 한 줄 상한을 넘겼다 — 줄이 아니라 잡음이다. 꼬리를 버리고 사유를 남긴다.
            if (host.pending.items.len > RemoteAgentHost.pending_max and
                std.mem.indexOfScalar(u8, host.pending.items, '\n') == null)
            {
                // **표시가 아니라 진단이다**(i18n §7 — 원장에 그 사실을 적어 두었다).
                std.log.scoped(.agent).warn("원격 이벤트 채널: 개행 없는 잡음이 한 줄 상한을 넘었다 — 꼬리를 버린다 dest={s}", .{dest});
                host.pending.clearRetainingCapacity();
            }
            continue;
        }
        if (n == 0) {
            eof = true;
            break;
        }
        break; // EAGAIN 을 포함한 그 밖 — 이번 tick 은 여기까지다
    }

    // 완성된 줄을 **남김없이** 훑는다(64 개씩 나눠 먹인다 — 스택에 든 배열이라 크기를 못 박는다).
    // 한 tick 상한을 두면 폭주 구간에서 꼬리가 계속 밀려 «배지가 몇 초 늦게 뜬다» 가 된다.
    var lines: [64][]const u8 = undefined;
    var consumed: usize = 0;
    while (true) {
        var count: usize = 0;
        while (count < lines.len) {
            const rest = host.pending.items[consumed..];
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            lines[count] = rest[0..nl];
            count += 1;
            consumed += nl + 1;
        }
        if (count == 0) break;
        // **줄이 왔다 = 채널이 산다.** 재시도 예산을 되돌린다(적대적 검증 3 회차).
        //
        // 안 되돌리면 `retries` 가 **오직 증가만** 해서, 슬립·빌드로 며칠에 걸쳐 여섯 번 끊긴
        // 목적지가 그 뒤로 영영 안 붙는다 — 재접속을 넣고도 오늘 이전과 같은 상태가 된다.
        // 예산은 「연달아 실패한 횟수」여야지 「살아온 동안의 총합」이면 안 된다.
        host.retries = 0;
        // **Term 에 먹이기 전에** 커서를 건진다 — 먹이는 쪽은 Term 마다 돌고 커서는 host 소유다.
        host.last_line_ms = now_ms; // 하트비트도 줄이다 — 살아 있다는 증거다
        self.recordRemoteCursors(host, lines[0..count], now_ms);
        feedRemoteAgentTerms(self, dest, lines[0..count], now_ms);
    }
    if (consumed > 0) {
        const rest_len = host.pending.items.len - consumed;
        std.mem.copyForwards(u8, host.pending.items[0..rest_len], host.pending.items[consumed..]);
        host.pending.shrinkRetainingCapacity(rest_len);
    }

    // **줄이 안 와도 시간은 간다.** `Channel` 의 hello 시한(5 초)·침묵 시한(15 초)은 `tick` 에서만
    // 판정되는데, 그것을 «줄이 왔을 때» 에만 부르면 **정확히 아무것도 안 오는 경우**에 안 불린다 —
    // 즉 죽은 채널이 영영 `open` 으로 남아 그 Term 은 훅 모드에 갇힌다(관측도 훅도 아닌 상태다).
    // 계획이 «사망 감지는 하트비트로만 한다» 로 못박은 자리가 여기다.
    if (!eof) {
        tickRemoteAgentTerms(self, dest, now_ms);
        // **조용하면 스트림이 죽은 것으로 본다**(적대적 검증 13 회차). 하트비트는 5 초마다 오므로
        // 시한을 넘긴 침묵은 정상이 아니다. 그런데 자식이 **좀비**면 `read` 가 0 을 안 줘 EOF 가 영영
        // 안 나고, 그때 채널만 되살리면 15 초마다 죽었다 살아나는 **조용한 헛돌이**가 된다.
        //
        // 다시 띄우는 것이 옳다: 좀비가 죽고, `onStreamerStarted` 가 채널을 다 버려 새 `hello` 를 보고,
        // **`--resume=` 이 그 사이 스풀에 쌓인 것까지 받는다** — 되살리기로는 못 하는 일이다.
        const silence = maru.session.remote_agent_stream.silence_deadline_ms;
        if (host.last_line_ms != 0 and now_ms -| host.last_line_ms >= silence) {
            ssh_upload.stopAgentEvents(host.stream);
            host.stream = .{ .pid = 0, .out_fd = -1 };
            host.stream_started = false;
            host.last_line_ms = 0;
            self.scheduleStreamerRetry(dest, host, "원격 이벤트가 조용하다");
        }
        return;
    }
    // **EOF 는 조용하지 않다.** 채널을 닫으면 다음 `agentHookMode` 가 관측 모드로 강등한다(§1.2) —
    // 그 전이가 곧 사용자가 보는 «훅이 죽었다» 다. 그리고 이 목적지는 **다시 안 띄운다**.
    feedRemoteAgentTerms(self, dest, &.{}, now_ms);
    ssh_upload.stopAgentEvents(host.stream);
    host.stream = .{ .pid = 0, .out_fd = -1 };
    host.stream_started = false;

    // **EOF 는 「영원히 안 된다」가 아니다**(RA5-b). 슬립·네트워크 끊김·원격 프로세스 교체로도 나고,
    // 그때 ControlMaster 는 멀쩡한 경우가 많다(실측). 예전에는 여기서 `stopped` 를 세워 앱을 껐다
    // 켜기 전까지 그 목적지가 죽었다 — 사용자에게는 「어느 순간부터 배지가 안 뜬다」로만 보였다.
    self.scheduleStreamerRetry(dest, host, "원격 이벤트 채널이 끝났다");
}

/// 줄이 없어도 그 목적지의 채널들에 **시간이 갔음을 알린다**(hello·침묵 시한 판정).
fn tickRemoteAgentTerms(self: *AppSession, dest: []const u8, now_ms: u64) void {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                var ch = &(term.agent_remote_channel orelse continue);
                if (!term.rt.observation.ssh_remote_dest_present) continue;
                if (!std.mem.eql(u8, term.rt.observation.ssh_remote_dest.items, dest)) continue;
                ch.tick(now_ms);
            }
        }
    }
}

/// 한 목적지의 Term 들에 줄을 먹인다. `lines` 가 비면 **EOF 를 알리는 호출**이다.
///
/// **왜 세는가.** 이벤트가 정확히 와도 Term 에 안 붙으면 배지는 조용히 안 뜬다 — 스트리머가
/// pane 열을 정확히 구분해 보내는데도 사이드바에서 둘만 잡히는 일이 실제로 있었다(2026-09-06).
/// 그때 「어느 조건에서 걸리는지」를 아무도 말하지 않아 로컬 앱 상태를 못 보는 쪽에서는 추측만
/// 반복됐다. 그래서 조건별로 세고, **아무도 못 받으면** 기본 레벨로 알린다(계약 §1.2 의 결).
pub fn feedRemoteAgentTerms(self: *AppSession, dest: []const u8, lines: []const []const u8, now_ms: u64) void {
    self.remote_nonce_matched = 0;
    self.remote_events_seen = 0;
    var fed: usize = 0;
    var with_nonce: usize = 0;
    // **몇이 실제로 먹을 수 있나.** `fed` 는 「분배 후보였다」일 뿐이고, 채널이 `hello` 관문을 못
    // 지났거나 닫혔으면 그 Term 은 이벤트를 **아예 못 본다** — 그러면 미매칭 기록조차 안 남아
    // 「열을 다 먹였는데 하나도 안 맞는다」로만 보인다(2026-09-11 실측).
    var open_channels: usize = 0;
    var mine_buf: [term_nonce_tail_buf]u8 = undefined;
    var mine_len: usize = 0;
    var no_channel: usize = 0;
    var no_dest: usize = 0;
    var other_dest: usize = 0;
    defer self.reportRemoteFeedShape(dest, lines.len, fed, no_channel, no_dest, other_dest);
    defer self.reportOrphanNonce(dest, lines.len, fed, with_nonce, open_channels, mine_buf[0..mine_len]);
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.agent_remote_channel == null) {
                    no_channel += 1;
                    continue;
                }
                if (!term.rt.observation.ssh_remote_dest_present) {
                    no_dest += 1;
                    continue;
                }
                if (!std.mem.eql(u8, term.rt.observation.ssh_remote_dest.items, dest)) {
                    other_dest += 1;
                    continue;
                }
                fed += 1;
                if (term.agent_remote_channel) |ch| {
                    if (ch.isOpen()) open_channels += 1;
                }
                if (term.agent_remote_nonce_len != 0) {
                    with_nonce += 1;
                    // **앱이 든 신원을 모은다.** orphan 이 뜰 때 「내가 뭘 들고 있었나」가 없으면
                    // 원격에서 손으로 대조하는 수밖에 없다(2026-09-07·09 에 세 번 그랬다). pane
                    // 부분 뒤 8 자면 한 줄에 열이 들어가고 구분에도 충분하다.
                    AppSession.appendTermNonceTail(&mine_buf, &mine_len, term.agent_remote_nonce[0..term.agent_remote_nonce_len]);
                }
                if (lines.len > 0)
                    agent_ops.consumeRemoteAgentLines(self, term, lines, now_ms)
                else
                    term.agent_remote_channel.?.eof();
            }
        }
    }
}

/// 모든 목적지의 자식을 끝내고 Term 들의 채널도 뗀다(게이트 off, 그리고 `deinit`).
///
/// **채널까지 떼는 것이 요점이다.** 자식만 죽이고 `Channel` 을 남기면 그 Term 은 `modeFor` 에서
/// 계속 «채널이 열렸다» 로 읽혀 훅 모드에 갇힌다 — 게이트를 껐는데 배지가 안 풀리는 모양이 된다.
pub fn closeAllRemoteAgentHosts(self: *AppSession) void {
    if (self.remote_agent_hosts.count() == 0) return;
    var it = self.remote_agent_hosts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.install) |st| ssh_upload.stopAgentEvents(st);
        ssh_upload.stopAgentEvents(entry.value_ptr.stream);
        entry.value_ptr.pending.deinit(self.allocator);
        entry.value_ptr.install_out.deinit(self.allocator);
        self.allocator.free(entry.key_ptr.*);
    }
    self.remote_agent_hosts.clearRetainingCapacity();
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                term.agent_remote_channel = null;
                term.agent_remote_nonce_len = 0;
            }
        }
    }
}

/// 한 목적지의 자식을 끝내고 표에서 뗀다.
pub fn closeRemoteAgentHost(self: *AppSession, dest: []const u8) void {
    const entry = self.remote_agent_hosts.fetchRemove(dest) orelse return;
    var host = entry.value;
    if (host.install) |st| ssh_upload.stopAgentEvents(st);
    ssh_upload.stopAgentEvents(host.stream);
    host.pending.deinit(self.allocator);
    host.install_out.deinit(self.allocator);
    // 커서 키는 우리가 dupe 했다 — 표를 버리기 전에 되돌려준다.
    var ck = host.cursors.keyIterator();
    while (ck.next()) |k| self.allocator.free(k.*);
    host.cursors.deinit(self.allocator);
    self.allocator.free(entry.key);
}
