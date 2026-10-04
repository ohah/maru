//! codex 공유 데몬이 돌린 훅 이벤트를 **어느 Term 의 것인가**로 되찾는 순수 규칙([계약](../../docs/agent-hooks.md) §4.4).
//!
//! **문제**: codex 0.157 부터 TUI 는 얇은 클라이언트이고, 세션·훅·도구는 공유 데몬
//! `codex app-server --managed-daemon` 하나가 돌린다. 그 데몬은 **먼저 뜬 TUI 의 자식**이라 그 pane 의 env
//! (`MARU_HOOK_INSTANCE`·`MARU_HOOK_PANE`)를 물려받는다. 그래서 나중 pane 의 세션 훅도 **첫 pane 의 파일**에
//! 적힌다 — 파일 이름(pane)이 증거가 못 된다(2026-10-04 실측: 오른쪽 pane 의 세션 이벤트 26건이 전부 대기 중인
//! 왼쪽 pane 파일에 있었고, 사이드바는 그 세션을 왼쪽에 붙였다). openai/codex#48500 이 같은 결함이다.
//!
//! **해법**(muxa #197 · Orca #23411 과 같은 수준): codex 훅은 자기를 띄운 프로세스(`$PPID`, 셸 내장)를 줄에 싣고
//! (`agent_hook_command`), 앱이 그 pid 의 argv 가 공유 데몬(`isManagedDaemonArgs`)이면 그 이벤트의 파일 이름은
//! 믿지 않고 `session_id` 로 귀속한다:
//!
//! 1. 이미 묶인 세션이면 그 Term.
//! 2. 같은 cwd 에서 codex 가 도는 로컬 Term(후보)이 **하나**면 그 Term. 같은 cwd 후보가 없으면(`codex -C <dir>`)
//!    cwd 무관하게 codex 가 도는 Term 으로 2·3 을 같은 규칙으로 돌린다.
//! 3. 여럿이면 **프롬프트 제출** 때 그 프롬프트가 화면에 보이는 후보가 **정확히 하나**일 때만 그 Term.
//! 4. 나머지는 어느 Term 에도 붙이지 않는다 — 틀린 pane 에 붙이느니 화면 관측만 남긴다.
//!
//! ⚠️ **제어 터미널 유무로는 못 가른다.** codex 는 데몬이든 아니든 훅을 tty 에서 떼어 띄운다(0.156
//! `detach_from_tty`, 0.160 `ProcessMode::NewSession` — `codex-rs/hooks/src/engine/command_runner.rs`). 첫 판은
//! `/dev/tty` 를 열어 보고 실패하면 표식을 달았는데, 그러면 **데몬을 안 쓰는 codex 이벤트까지** 전부 재배정을 탔다.
//!
//! **이 파일은 순수하다.** 프로세스도 화면도 읽지 않는다 — 호출자가 모은 사실로 판정만 한다.

const std = @import("std");

/// 훅이 자기를 띄운 프로세스 pid(`$PPID`)를 적는 JSON 키. 훅은 이 키를 payload **맨 앞**에 끼운다
/// (`agent_hook_command.build`). 줄 형식(`<provider>\t<payload>`)을 안 바꾸므로 옛 파서는 모르는 키로 건너뛴다.
pub const parent_pid_key = "maru_hook_ppid";
/// 훅이 끼우는 칸의 **최대** 바이트(`"maru_hook_ppid":<10자리>,`). 훅의 상한 계산이 이만큼 자리를 비워 둔다.
pub const parent_pid_field_max = "\"".len + parent_pid_key.len + "\":".len + 10 + ",".len;

/// 데몬 판정을 하는 provider. claude 는 공유 데몬이 없고 그 훅 커맨드에는 이 칸 자체가 없다.
pub const daemon_provider = "codex";

/// KERN_PROCARGS2 원문(`[argc:u32 LE][exec_path\0][\0 패딩][argv0\0]…[argv{argc-1}\0][envp…]`)이 codex 공유 데몬인가.
/// **argv 만** 본다 — envp 에 같은 글자가 있어도 걸리지 않는다.
///
/// 데몬은 두 모양으로 뜬다(codex 0.160 `pid.rs` `command_args`·`pid_start.rs`):
/// - `codex app-server [--remote-control] --listen unix:// --managed-daemon` — 그 바이너리가 `--managed-daemon --help`
///   검사를 5 초 안에 통과했을 때(2026-10-04 실측 argv).
/// - `codex app-server [--remote-control] --listen unix://` — 검사가 실패하거나 늦으면 붙이는 **옛 모양**. 훅은 똑같이
///   이 프로세스가 돌린다. 그래서 `--managed-daemon` 하나만 보면 이 데몬의 이벤트가 전부 예전 규칙(파일 = pane)으로 샌다.
///
/// 데몬이 아닌 것: 데몬 보조(`app-server daemon pid-update-loop` — 훅을 안 돌린다), IDE 가 stdio 로 띄운 app-server
/// (`--listen stdio://` — pane 이 없다).
pub fn isManagedDaemonArgs(procargs: []const u8) bool {
    if (procargs.len <= 4) return false;
    const argc: u32 = @as(u32, procargs[0]) | (@as(u32, procargs[1]) << 8) | (@as(u32, procargs[2]) << 16) | (@as(u32, procargs[3]) << 24);
    if (argc < 3) return false;
    var off: usize = 4;
    while (off < procargs.len and procargs[off] != 0) off += 1; // exec_path
    while (off < procargs.len and procargs[off] == 0) off += 1; // 패딩
    var saw_codex = false;
    var saw_app_server = false;
    var saw_managed = false;
    var saw_unix_listen = false;
    var daemon_subcommand = false;
    var listen_next = false;
    var i: u32 = 0;
    while (i < argc and off < procargs.len) : (i += 1) {
        const start = off;
        while (off < procargs.len and procargs[off] != 0) off += 1;
        const arg = procargs[start..off];
        if (off < procargs.len) off += 1; // 구분 null 하나만 — 빈 인자도 자리를 센다
        const after_listen = listen_next;
        listen_next = false;
        if (i == 0) {
            const base = if (std.mem.lastIndexOfScalar(u8, arg, '/')) |s| arg[s + 1 ..] else arg;
            saw_codex = std.mem.eql(u8, base, "codex");
        } else if (i == 1) {
            saw_app_server = std.mem.eql(u8, arg, "app-server");
        } else if (i == 2 and std.mem.eql(u8, arg, "daemon")) {
            daemon_subcommand = true;
        } else if (std.mem.eql(u8, arg, "--managed-daemon")) {
            saw_managed = true;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            listen_next = true;
        } else if (after_listen and std.mem.startsWith(u8, arg, "unix://")) {
            saw_unix_listen = true;
        } else if (std.mem.startsWith(u8, arg, "--listen=unix://")) {
            saw_unix_listen = true;
        }
    }
    return saw_codex and saw_app_server and !daemon_subcommand and (saw_managed or saw_unix_listen);
}

/// 훅을 띄운 프로세스마다 «데몬이었나» 를 기억한다 — argv 읽기(sysctl)를 이벤트마다 하지 않으려고. 고정 크기, 가득 차면
/// 돌아가며 덮는다.
///
/// **키는 (pid, 시작 시각)이다.** pid 만이면 그 프로세스가 죽고 같은 pid 를 다른 프로세스가 받았을 때 옛 판정이 그대로
/// 붙는다 — 데몬이 아닌 pid 가 «데몬» 으로, 또는 그 반대로 뒤집힌다. 시작 시각이 다르면 다른 프로세스다.
/// 지금 그 pid 의 시작 시각을 못 읽으면(이미 사라졌다) 호출자가 «아니다»(= 예전 규칙)로 접는다.
pub const ParentVerdicts = struct {
    pub const capacity = 8;
    pids: [capacity]u32 = [_]u32{0} ** capacity,
    starts: [capacity]u64 = [_]u64{0} ** capacity,
    daemon: [capacity]bool = [_]bool{false} ** capacity,
    next: usize = 0,

    pub fn lookup(self: *const ParentVerdicts, pid: u32, start_us: u64) ?bool {
        if (pid == 0) return null;
        for (self.pids, self.starts, self.daemon) |p, s, d| {
            if (p == pid and s == start_us) return d;
        }
        return null;
    }

    pub fn remember(self: *ParentVerdicts, pid: u32, start_us: u64, is_daemon: bool) void {
        if (pid == 0) return;
        for (&self.pids, &self.starts, &self.daemon) |*p, *s, *d| {
            if (p.* == pid) {
                s.* = start_us;
                d.* = is_daemon;
                return;
            }
        }
        self.pids[self.next] = pid;
        self.starts[self.next] = start_us;
        self.daemon[self.next] = is_daemon;
        self.next = (self.next + 1) % capacity;
    }
};

/// 붙이지 않은 (세션, 사유)를 진단에 **한 번씩만** 남기게 하는 작은 집합. 마지막 키 하나만 기억하면 두 세션이 번갈아
/// 버려질 때 이벤트마다 한 줄씩 쌓인다. 고정 크기, 가득 차면 돌아가며 덮는다.
pub const DropLog = struct {
    pub const capacity = 16;
    keys: [capacity]u64 = [_]u64{0} ** capacity,
    next: usize = 0,

    /// 처음 보는 키면 기억하고 `true`(= 남겨라).
    pub fn first(self: *DropLog, key: u64) bool {
        for (self.keys) |k| if (k == key) return false;
        self.keys[self.next] = key;
        self.next = (self.next + 1) % capacity;
        return true;
    }
};

pub fn dropKey(session: []const u8, reason: Reason) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(session);
    h.update(@tagName(reason));
    return h.final() | 1; // 0 은 빈 칸이다
}

/// 후보가 될 수 있는 Term 인가 — 로컬 터미널에서 codex 가 돈다. **원격 pane 은 아니다**: 그 codex 는 다른 기계의 데몬이
/// 돌리고, 그 이벤트는 이 경로로 오지 않는다(원격 채널). 원격 pane 을 후보에 넣으면 «로컬 codex pane 하나» 가 «여럿» 이
/// 되어 묶어야 할 이벤트를 버린다.
pub const TermFacts = struct { terminal: bool, codex: bool, remote: bool };
pub fn eligible(t: TermFacts) bool {
    return t.terminal and t.codex and !t.remote;
}

/// 그 Term 이 이벤트와 **같은 cwd** 인가. Term cwd 를 모르거나 이벤트에 cwd 가 없으면 아니다(cwd 무관 폴백이 받는다).
pub fn sameCwdCandidate(term_cwd: ?[]const u8, event_cwd: []const u8) bool {
    const cwd = term_cwd orelse return false;
    if (event_cwd.len == 0) return false;
    return sameDir(cwd, event_cwd);
}

/// 프롬프트로 후보를 고를 때의 **최소 길이**(공백을 뺀 코드포인트 수).
///
/// 짧은 프롬프트(「계속」·「ok」·`/new`)는 다른 pane 화면에도 우연히 있을 수 있다. 유일성 요구가 1차 방어이고
/// 이 하한은 2차다. muxa #197 이 같은 자리에 12 를 쓴다 — 한글은 글자당 정보가 많아 12 코드포인트면 한 문장이다.
pub const min_prompt_codepoints: usize = 12;

/// 이 이벤트가 공유 데몬이 돌린 codex 이벤트인가. 아니면 지금 규칙(파일 이름 = pane)을 그대로 쓴다.
/// `parent_is_daemon` 은 호출자가 `$PPID` 의 argv 로 정한 값이다(`isManagedDaemonArgs`).
pub fn isDaemonEvent(provider: []const u8, parent_is_daemon: bool) bool {
    return parent_is_daemon and std.mem.eql(u8, provider, daemon_provider);
}

/// 후보 하나 — 같은 cwd 에서 codex 가 도는 로컬 Term.
pub const Candidate = struct {
    id: u64,
    /// 이번 프롬프트가 그 Term 화면에 보이는가. 프롬프트 이벤트가 아니면 쓰지 않는다.
    shows_prompt: bool = false,
};

pub const Input = struct {
    /// 이미 묶인 Term(살아 있고 codex 가 도는 것만 — 호출자가 확인한다).
    bound: ?u64 = null,
    /// 같은 cwd 에서 codex 가 도는 로컬 Term.
    candidates: []const Candidate = &.{},
    /// cwd 와 **무관하게** codex 가 도는 로컬 Term. `candidates` 가 비었을 때만 쓴다 — `codex -C <dir>` 처럼 세션 cwd 가
    /// pane 의 cwd 와 다른 경우다. 이 폴백이 없으면 codex pane 이 하나뿐일 때도 이벤트를 버린다(고치기 전에는 파일의
    /// pane 에 정확히 붙던 경우다).
    any_cwd: []const Candidate = &.{},
    /// `UserPromptSubmit` 인가.
    prompt_event: bool = false,
    /// 그 프롬프트가 `min_prompt_codepoints` 를 넘는가(`longEnough`).
    prompt_long_enough: bool = false,
};

/// 붙이지 않은 이유. 진단 한 줄에 실린다.
pub const Reason = enum {
    /// codex 가 도는 로컬 Term 이 하나도 없다(데몬이 maru 밖 클라이언트의 세션을 돌리는 경우 포함).
    no_candidate,
    /// 후보가 여럿인데 아직 프롬프트가 안 왔다(세션 시작·이어 하기 직후).
    ambiguous_before_prompt,
    /// 후보가 여럿인데 프롬프트가 짧다.
    prompt_too_short,
    /// 후보가 여럿인데 그 프롬프트가 보이는 화면이 하나가 아니다(없거나 둘 이상).
    prompt_not_unique,
};

pub const Decision = union(enum) {
    /// 그 Term 에 적용한다. `bind` 면 이 세션을 그 Term 에 묶는다.
    route: struct { target: u64, bind: bool },
    /// 어느 Term 에도 붙이지 않는다.
    drop: Reason,
};

/// 판정. 순서가 곧 계약이다 — 묶인 세션이 먼저, 후보 하나, 프롬프트 유일 일치, 그 밖은 버림.
pub fn decide(in: Input) Decision {
    if (in.bound) |t| return .{ .route = .{ .target = t, .bind = false } };
    // 같은 cwd 후보가 없으면 cwd 를 안 보는 후보로 **같은 규칙**을 돌린다.
    const pool = if (in.candidates.len != 0) in.candidates else in.any_cwd;
    if (pool.len == 0) return .{ .drop = .no_candidate };
    if (pool.len == 1) return .{ .route = .{ .target = pool[0].id, .bind = true } };
    if (!in.prompt_event) return .{ .drop = .ambiguous_before_prompt };
    if (!in.prompt_long_enough) return .{ .drop = .prompt_too_short };
    var found: ?u64 = null;
    for (pool) |c| {
        if (!c.shows_prompt) continue;
        if (found != null) return .{ .drop = .prompt_not_unique };
        found = c.id;
    }
    const t = found orelse return .{ .drop = .prompt_not_unique };
    return .{ .route = .{ .target = t, .bind = true } };
}

/// ASCII 공백을 **전부** 지운다. 화면은 프롬프트를 폭에 맞춰 줄바꿈하고 앞에 장식을 붙이므로, 공백까지 지우고
/// 부분문자열로 비교해야 줄바꿈 위치와 무관해진다. 담을 수 있는 만큼만 담는다.
pub fn compact(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    for (raw) |b| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
        if (n == out.len) break;
        out[n] = b;
        n += 1;
    }
    return out[0..n];
}

/// 공백을 지운 프롬프트가 하한을 넘는가(코드포인트로 센다 — 바이트로 세면 한글이 세 배로 길어 보인다).
pub fn longEnough(compacted: []const u8) bool {
    const count = std.unicode.utf8CountCodepoints(compacted) catch compacted.len;
    return count >= min_prompt_codepoints;
}

/// 공백을 지운 화면에 공백을 지운 프롬프트가 있는가.
pub fn screenShows(compacted_screen: []const u8, compacted_prompt: []const u8) bool {
    if (compacted_prompt.len == 0) return false;
    return std.mem.indexOf(u8, compacted_screen, compacted_prompt) != null;
}

/// 두 경로가 같은 디렉터리인가(끝의 `/` 하나는 무시한다).
pub fn sameDir(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimSlash(a), trimSlash(b));
}

fn trimSlash(p: []const u8) []const u8 {
    if (p.len > 1 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
    return p;
}

/// 세션 → Term 묶음. 고정 크기라 힙을 안 잡는다. 가득 차면 **가장 오래 쓰지 않은** 것을 밀어낸다.
pub const Bindings = struct {
    pub const capacity = 16;
    pub const max_session_bytes = 64;

    const Entry = struct {
        session: [max_session_bytes]u8 = undefined,
        session_len: u8 = 0,
        target: u64 = 0,
        used: u64 = 0,
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    clock: u64 = 0,

    pub fn lookup(self: *Bindings, session: []const u8) ?u64 {
        const e = self.find(session) orelse return null;
        self.clock += 1;
        e.used = self.clock;
        return e.target;
    }

    /// 묶음을 쓸 수 있으면 그 Term 을 준다(판정 ⑴). 못 쓰면 **풀고** null — 호출자는 새로 판정한다.
    ///
    /// - `session_start`: 그 세션이 (다시) 시작됐다. 묶음을 믿지 않는다 — B 에서 돌던 세션 S 를 C 가
    ///   `codex resume S` 로 열면 S 의 첫 이벤트가 `SessionStart` 이고, 옛 묶음을 쓰면 S 가 B 로 간다.
    /// - `live`: 지금 codex 가 도는 로컬 Term(`eligible`). 그 안에 없으면 그 Term 은 닫혔거나 codex 를 벗어났다.
    pub fn resolve(self: *Bindings, session: []const u8, session_start: bool, live: []const Candidate) ?u64 {
        if (session_start) {
            self.unbind(session);
            return null;
        }
        const target = self.lookup(session) orelse return null;
        for (live) |c| if (c.id == target) return target;
        self.unbind(session);
        return null;
    }

    /// 묶는다. 이미 있으면 대상을 바꾼다. 담을 수 없는 길이면 묶지 않는다(자르면 다른 세션과 섞인다).
    ///
    /// **한 Term 에는 세션 하나만 묶인다.** 그 Term 에 묶여 있던 다른 세션은 푼다 — pane 하나에서 동시에 도는 codex
    /// 세션은 하나뿐이고(`/new` 는 새 세션으로 갈아탄다), 옛 묶음을 남기면 그 옛 세션을 다른 pane 이 이어 열 때(`resume`)
    /// 그 이벤트가 이 Term 으로 온다.
    pub fn bind(self: *Bindings, session: []const u8, target: u64) void {
        if (session.len == 0 or session.len > max_session_bytes) return;
        self.clock += 1;
        for (&self.entries) |*e| {
            if (e.session_len != 0 and e.target == target and
                !std.mem.eql(u8, e.session[0..e.session_len], session)) e.session_len = 0;
        }
        if (self.find(session)) |e| {
            e.target = target;
            e.used = self.clock;
            return;
        }
        var slot = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.session_len == 0) {
                slot = e;
                break;
            }
            if (e.used < slot.used) slot = e;
        }
        @memcpy(slot.session[0..session.len], session);
        slot.session_len = @intCast(session.len);
        slot.target = target;
        slot.used = self.clock;
    }

    pub fn unbind(self: *Bindings, session: []const u8) void {
        if (self.find(session)) |e| e.session_len = 0;
    }

    /// 그 Term 이 닫혔거나 codex 를 벗어났다 — 그 Term 에 묶인 세션을 모두 푼다.
    pub fn dropTarget(self: *Bindings, target: u64) void {
        for (&self.entries) |*e| {
            if (e.session_len != 0 and e.target == target) e.session_len = 0;
        }
    }

    fn find(self: *Bindings, session: []const u8) ?*Entry {
        if (session.len == 0) return null;
        for (&self.entries) |*e| {
            if (e.session_len == session.len and std.mem.eql(u8, e.session[0..e.session_len], session)) return e;
        }
        return null;
    }
};

const testing = std.testing;

test "codex 데몬 귀속: 판정표 — 묶임이 먼저, 후보 하나, 프롬프트 유일 일치, 그 밖은 버림" {
    const two_one_match = [_]Candidate{ .{ .id = 89 }, .{ .id = 90, .shows_prompt = true } };
    const two_both = [_]Candidate{ .{ .id = 89, .shows_prompt = true }, .{ .id = 90, .shows_prompt = true } };
    const two_none = [_]Candidate{ .{ .id = 89 }, .{ .id = 90 } };
    const one = [_]Candidate{.{ .id = 90 }};
    const Case = struct { in: Input, want: Decision };
    const cases = [_]Case{
        // 묶인 세션은 후보가 여럿이어도 그 Term — 도구 이벤트마다 화면을 다시 볼 이유가 없다.
        .{ .in = .{ .bound = 90, .candidates = &two_none }, .want = .{ .route = .{ .target = 90, .bind = false } } },
        .{ .in = .{ .candidates = &.{} }, .want = .{ .drop = .no_candidate } },
        .{ .in = .{ .candidates = &one }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        // 2026-10-04 실측 모양: 같은 cwd 의 codex 둘, 세션 시작(프롬프트 전) — 물려받은 89 에 붙이지 않는다.
        .{ .in = .{ .candidates = &two_one_match }, .want = .{ .drop = .ambiguous_before_prompt } },
        .{ .in = .{ .candidates = &two_one_match, .prompt_event = true }, .want = .{ .drop = .prompt_too_short } },
        .{ .in = .{ .candidates = &two_one_match, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        .{ .in = .{ .candidates = &two_both, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .drop = .prompt_not_unique } },
        .{ .in = .{ .candidates = &two_none, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .drop = .prompt_not_unique } },
        // `codex -C <dir>`: 같은 cwd 후보가 없으면 cwd 무관 후보로 같은 규칙 — codex pane 이 하나면 고치기 전처럼 그 pane.
        .{ .in = .{ .any_cwd = &one }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        .{ .in = .{ .any_cwd = &two_one_match }, .want = .{ .drop = .ambiguous_before_prompt } },
        .{ .in = .{ .any_cwd = &two_one_match, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .route = .{ .target = 90, .bind = true } } },
        .{ .in = .{ .any_cwd = &two_both, .prompt_event = true, .prompt_long_enough = true }, .want = .{ .drop = .prompt_not_unique } },
        // 같은 cwd 후보가 있으면 폴백을 안 본다 — 다른 폴더의 codex 가 섞이면 하나뿐인 같은 cwd 후보가 «여럿» 이 된다.
        .{ .in = .{ .candidates = &one, .any_cwd = &two_none }, .want = .{ .route = .{ .target = 90, .bind = true } } },
    };
    for (cases) |c| try testing.expectEqualDeep(c.want, decide(c.in));
}

test "codex 데몬 귀속: 표식은 codex 에서만 믿고, 프롬프트 비교는 줄바꿈과 무관하며 짧은 것은 안 믿는다" {
    try testing.expect(isDaemonEvent("codex", true));
    try testing.expect(!isDaemonEvent("codex", false));
    try testing.expect(!isDaemonEvent("claude", true));

    var pb: [128]u8 = undefined;
    var sb: [256]u8 = undefined;
    const prompt = compact(&pb, "용량이 너무 없는데 용량 한번 체크 해주세요");
    // 화면은 폭에 맞춰 접고 장식(`›`)을 붙인다.
    const screen = compact(&sb, "› 용량이 너무 없는데 용량 한번\n  체크 해주세요\n\n• Working (18s)");
    try testing.expect(screenShows(screen, prompt));
    try testing.expect(!screenShows(compact(&sb, "› Look who's at the keyboard."), prompt));
    try testing.expect(!screenShows(screen, ""));
    try testing.expect(longEnough(prompt));
    try testing.expect(!longEnough(compact(&pb, "계속 진행해 주세요")));
    try testing.expect(!longEnough(compact(&pb, "ok")));

    try testing.expect(sameDir("/w/payhere-homepage", "/w/payhere-homepage/"));
    try testing.expect(!sameDir("/w/payhere-homepage", "/w/payhere"));
}

test "codex 데몬 귀속: 묶음은 세션마다 하나, Term 이 떠나면 풀리고, 가득 차면 오래된 것부터 밀린다" {
    var b: Bindings = .{};
    b.bind("01a105dd", 90);
    try testing.expectEqual(@as(?u64, 90), b.lookup("01a105dd"));
    // /new 로 새 세션이 와도 옛 묶음과 섞이지 않는다.
    try testing.expectEqual(@as(?u64, null), b.lookup("01a105ee"));
    b.bind("01a105dd", 91);
    try testing.expectEqual(@as(?u64, 91), b.lookup("01a105dd"));
    b.dropTarget(91);
    try testing.expectEqual(@as(?u64, null), b.lookup("01a105dd"));
    // 담을 수 없는 길이는 묶지 않는다(자르면 앞부분이 같은 두 세션이 섞인다).
    b.bind("x" ** (Bindings.max_session_bytes + 1), 1);
    try testing.expectEqual(@as(?u64, null), b.lookup("x" ** Bindings.max_session_bytes));

    var f: Bindings = .{};
    var name: [8]u8 = undefined;
    for (0..Bindings.capacity) |i| f.bind(std.fmt.bufPrint(&name, "s{d:0>3}", .{i}) catch unreachable, i);
    _ = f.lookup("s000"); // 가장 먼저 넣었지만 방금 썼다
    f.bind("new", 99);
    try testing.expectEqual(@as(?u64, 0), f.lookup("s000"));
    try testing.expectEqual(@as(?u64, null), f.lookup("s001")); // 가장 오래 안 쓴 것이 밀렸다
    try testing.expectEqual(@as(?u64, 99), f.lookup("new"));
}

fn procargsFixture(buf: []u8, argv: []const []const u8, envp: []const []const u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(argv.len), .little);
    var n: usize = 4;
    const exec_path = "/x/bin/exec";
    @memcpy(buf[n..][0..exec_path.len], exec_path);
    n += exec_path.len;
    @memset(buf[n..][0..3], 0); // exec_path 끝 + 패딩
    n += 3;
    for ([_][]const []const u8{ argv, envp }) |list| {
        for (list) |s| {
            @memcpy(buf[n..][0..s.len], s);
            n += s.len;
            buf[n] = 0;
            n += 1;
        }
    }
    return buf[0..n];
}

test "codex 데몬 귀속: 훅의 부모 argv 가 공유 데몬일 때만 데몬이고, 판정은 pid 마다 기억된다" {
    var b: [1024]u8 = undefined;
    const bin = "/Users/u/.codex/packages/app-server-daemon/releases/0.160.0-aarch64-apple-darwin/bin/codex";
    // 2026-10-04 실측 argv.
    try testing.expect(isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "--listen", "unix://", "--managed-daemon" }, &.{"HOME=/u"})));
    // 옛 모양 — `--managed-daemon --help` 검사가 실패·시간 초과하면 이 플래그 없이 뜬다(codex 0.160 `pid_start.rs`).
    try testing.expect(isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "--listen", "unix://" }, &.{})));
    try testing.expect(isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "--remote-control", "--listen", "unix://" }, &.{})));
    try testing.expect(isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "--listen=unix:///tmp/codex.sock" }, &.{})));
    // `unix://` 가 `--listen` 의 값이 아니면 아니다.
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "unix://", "--listen", "stdio://" }, &.{})));
    // 데몬 보조·IDE 의 stdio app-server·TUI(데몬 안 쓰는 codex 는 훅을 TUI 가 직접 띄운다)는 데몬이 아니다.
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "daemon", "pid-update-loop" }, &.{})));
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "daemon", "x", "--listen", "unix://" }, &.{})));
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "app-server", "--listen", "stdio://" }, &.{})));
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ "/n/codex-darwin-arm64/bin/codex", "--dangerously-bypass-approvals-and-sandbox" }, &.{})));
    // envp 의 같은 글자는 argv 가 아니다.
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ bin, "exec", "x" }, &.{ "A=app-server", "--managed-daemon" })));
    // 다른 프로그램의 같은 인자는 codex 데몬이 아니다.
    try testing.expect(!isManagedDaemonArgs(procargsFixture(&b, &.{ "/usr/bin/other", "app-server", "--managed-daemon" }, &.{})));
    try testing.expect(!isManagedDaemonArgs(&.{ 3, 0, 0 }));

    var v: ParentVerdicts = .{};
    try testing.expectEqual(@as(?bool, null), v.lookup(63831, 100));
    v.remember(63831, 100, true);
    v.remember(65639, 200, false);
    try testing.expectEqual(@as(?bool, true), v.lookup(63831, 100));
    try testing.expectEqual(@as(?bool, false), v.lookup(65639, 200));
    // 같은 pid 를 다른 프로세스가 받았다(시작 시각이 다르다) — 옛 판정을 쓰지 않는다.
    try testing.expectEqual(@as(?bool, null), v.lookup(63831, 101));
    v.remember(63831, 101, false);
    try testing.expectEqual(@as(?bool, false), v.lookup(63831, 101));
    try testing.expectEqual(@as(?bool, null), v.lookup(63831, 100));
    try testing.expectEqual(@as(?bool, null), v.lookup(0, 0)); // pid 칸이 없던 옛 줄
    for (0..ParentVerdicts.capacity) |i| v.remember(@intCast(1000 + i), 1, false);
    try testing.expectEqual(@as(?bool, null), v.lookup(63831, 101)); // 돌아가며 덮인다
}

test "codex 데몬 귀속: 한 Term 에 세션 하나만 묶이고, SessionStart 나 떠난 Term 이면 묶음을 버리고 다시 판정한다" {
    const B: u64 = 5;
    const C: u64 = 7;
    const live = [_]Candidate{ .{ .id = B }, .{ .id = C } };
    var b: Bindings = .{};
    b.bind("S", B);
    try testing.expectEqual(@as(?u64, B), b.resolve("S", false, &live));
    // B 가 `/new` — 새 세션 S2 가 B 에 묶이면 옛 S 는 풀린다.
    b.bind("S2", B);
    try testing.expectEqual(@as(?u64, B), b.resolve("S2", false, &live));
    try testing.expectEqual(@as(?u64, null), b.lookup("S"));
    // (풀리지 않았더라도) C 가 `codex resume S` — S 의 SessionStart 는 묶음을 쓰지 않고 버린다.
    b.bind("S", B);
    try testing.expectEqual(@as(?u64, null), b.resolve("S", true, &live));
    try testing.expectEqual(@as(?u64, null), b.lookup("S"));
    // 묶인 Term 이 닫혔거나 codex 를 벗어났다(live 에 없다) — 풀고 다시 판정한다.
    b.bind("S3", C);
    try testing.expectEqual(@as(?u64, null), b.resolve("S3", false, live[0..1]));
    try testing.expectEqual(@as(?u64, null), b.lookup("S3"));
    // 다른 Term 의 묶음은 건드리지 않는다.
    b.bind("S4", C);
    b.bind("S5", B);
    try testing.expectEqual(@as(?u64, C), b.resolve("S4", false, &live));
}

test "codex 데몬 귀속: 후보 자격은 로컬 codex 터미널만, 같은 cwd 는 둘 다 알 때만, 진단은 (세션, 사유)마다 한 번" {
    try testing.expect(eligible(.{ .terminal = true, .codex = true, .remote = false }));
    try testing.expect(!eligible(.{ .terminal = true, .codex = true, .remote = true }));
    try testing.expect(!eligible(.{ .terminal = true, .codex = false, .remote = false }));
    try testing.expect(!eligible(.{ .terminal = false, .codex = true, .remote = false }));

    try testing.expect(sameCwdCandidate("/w/payhere-homepage", "/w/payhere-homepage/"));
    try testing.expect(!sameCwdCandidate("/w/payhere-homepage", "/w/other"));
    try testing.expect(!sameCwdCandidate(null, "/w/payhere-homepage"));
    try testing.expect(!sameCwdCandidate("/w/payhere-homepage", ""));

    var log: DropLog = .{};
    const a = dropKey("S1", .ambiguous_before_prompt);
    const c = dropKey("S2", .ambiguous_before_prompt);
    try testing.expect(log.first(a));
    try testing.expect(log.first(c));
    // 두 세션이 번갈아 버려져도 각자 한 줄뿐이다.
    try testing.expect(!log.first(a));
    try testing.expect(!log.first(c));
    try testing.expect(log.first(dropKey("S1", .prompt_too_short)));
}
