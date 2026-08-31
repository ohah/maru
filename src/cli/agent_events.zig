//! `maru agent-events --stdio` — **원격 훅 로그를 그 기계 밖으로 흘리는 길**([계획](../../docs/plans/remote-agent-state.md) RA4).
//!
//! 원격에서 도는 에이전트의 배지·대화 줄을 로컬 maru 가 세우려면 그 훅 payload 가 와야 한다. 훅은
//! 원격 디스크에 쌓고(RA3), 이 프로그램이 그것을 stdout 으로 흘린다. `maru ssh` 가 만든 ControlMaster
//! 위의 `exec` 채널이 그 stdout 을 로컬로 나른다.
//!
//! **`maru control --stdio` 를 재사용할 수 없다.** 그것은 그 기계의 **GUI 앱**이 연 컨트롤 소켓에 붙는
//! 중계라([SSH 클라이언트 계획](../../docs/plans/ssh-client.md) S10 — 실측 2026-08-21), 헤드리스 원격에는
//! 붙을 소켓이 없다. 그래서 별도 프로그램이다.
//!
//! **host 당 하나만 띄운다**(pane 당이 아니다). sshd `MaxSessions` 기본값이 10 이고 **다중화도 그 10 에
//! 포함**되므로(2026-08-29 실측), pane 당 채널을 열면 터미널 1 + 채널 1 로 같은 호스트 **pane 5 개가
//! 상한**이 된다. 디렉터리 전체를 훑어 pane 을 nonce 로 갈라 실으면 그 제약이 사라진다.
//!
//! **이 파일은 순수하다** — OS 를 안 부른다. 디렉터리 읽기·파일 읽기·stdout 쓰기·시계는 호출자가 한다.
//! `control_relay.zig` 의 두 규율을 그대로 물려받는다:
//!
//! 1. **stdout 은 오직 wire 다.** 로그·경고·진단은 전부 stderr 로 간다 — 한 줄만 섞여도 소비자의 ndjson
//!    파서가 그 프레임을 잃는다.
//! 2. **바이트를 해석하지 않는다.** payload 를 파싱하지 않고 줄 단위로 실어 보낸다. 프레임 조립과 `hello`
//!    판정은 **소비자 한 곳**에서 한다 — 두 곳에 두면 상한과 배압 규칙이 갈린다.

const std = @import("std");
const command = @import("../session/agent_hook_command.zig");
const hook_event = @import("../session/agent_hook_event.zig");

/// 채널이 열리면 **가장 먼저** 보내는 줄.
///
/// **소비자는 이것을 상한 안에서 찾는다**(첫 줄로 판정하지 않는다). `ForceCommand` 나 `authorized_keys`
/// 의 `command=` 가 걸린 서버는 우리 명령을 **갈아치우고 `exit 0` 을 준다**(2026-08-29 실측 — 다중화
/// exec 도 못 피한다). 그때 이 줄이 안 오는 것이 유일한 신호다. 정상 서버도 MOTD·rc 잡음을 앞에 붙이므로
/// «첫 줄» 로 재면 멀쩡한 서버를 제한 서버로 오진한다.
pub const hello_line = "{\"hello\":\"maru-agent-events\",\"v\":1}";

/// 우리 프로토콜 판(소비자가 대조한다).
pub const wire_version: u32 = 1;

/// 훅 로그 파일의 확장자. 로컬과 같은 이름이라 파서를 나누지 않는다(계약 §4).
pub const log_suffix = ".ndjson";

pub const Mode = union(enum) {
    /// stdout 으로 흘린다. `dir` 은 훅이 쌓는 디렉터리(절대 경로).
    stdio: Options,
    help,
    /// 인자가 계약과 다르다. **조용히 기본값으로 돌지 않는다** — 그러면 엉뚱한 디렉터리를 훑는다.
    usage_error,
};

pub const Options = struct {
    dir: []const u8,
    /// 하트비트 주기(ms). **0 이면 안 보낸다** — 그러면 소비자가 사망을 침묵으로 재지 못한다는 뜻이라
    /// 시험용 외에는 쓰지 않는다.
    heartbeat_ms: u32 = 5_000,
    /// 이어읽기 커서(`<이름>:<offset>` 을 `,` 로 이은 것). 비면 처음부터 읽는다.
    ///
    /// **로컬이 주는 값이다**(RA5-a). 원격 파일에 굳히지 않는 이유는 「앱을 새로 켰다」와 「채널만 죽었다
    /// 살아났다」를 구분해야 하기 때문이다 — 앞은 다시 읽어야 배지가 서고, 뒤는 다시 읽으면 알림이
    /// 재생된다. 로컬 기억은 앱과 함께 죽으므로 그 구분이 저절로 선다.
    resume_spec: []const u8 = "",
};

/// `agent-events` 뒤 인자를 해석한다. **모르는 플래그는 오류다** — 조용히 무시하면 오타가 «기본값으로
/// 도는» 상태가 되고, 그 사실이 드러나는 자리는 원격 로그뿐이다.
pub fn parseArgs(args: []const []const u8) Mode {
    var dir: ?[]const u8 = null;
    var hb: u32 = 5_000;
    // 이어읽기 커서(RA5-a). 비면 처음부터 — **앱을 새로 켠 경우가 그것**이라 기본값이 맞다.
    var resume_spec: []const u8 = "";
    var saw_stdio = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--stdio")) {
            saw_stdio = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .help;
        } else if (std.mem.startsWith(u8, a, "--dir=")) {
            dir = a["--dir=".len..];
        } else if (std.mem.startsWith(u8, a, "--heartbeat-ms=")) {
            hb = std.fmt.parseInt(u32, a["--heartbeat-ms=".len..], 10) catch return .usage_error;
        } else if (std.mem.startsWith(u8, a, "--resume=")) {
            resume_spec = a["--resume=".len..];
        } else return .usage_error;
    }
    if (!saw_stdio) return .usage_error;
    const d = dir orelse return .usage_error;
    if (d.len == 0 or !std.fs.path.isAbsolute(d)) return .usage_error; // 상대 경로는 cwd 에 끌려간다
    if (!resumeIsWellFormed(resume_spec)) return .usage_error;
    return .{ .stdio = .{ .dir = d, .heartbeat_ms = hb, .resume_spec = resume_spec } };
}

/// 디렉터리 항목이 **우리 로그**인가. 맞으면 그 nonce 를 돌려준다.
///
/// 이름을 그대로 믿지 않는다 — 그 값이 wire 에 실려 로컬에서 **어느 Term 인가** 를 정하기 때문이다.
/// 훅이 쓰는 가드와 **같은 클래스**로 재서, 훅이 거부했을 이름은 여기서도 거부한다.
pub fn nonceFromFileName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, log_suffix)) return null;
    const nonce = name[0 .. name.len - log_suffix.len];
    // ⚠️ **nonce 상한이 아니라 파일 이름 상한으로 잰다.** tmux 안에서는 `_t<pane>` 이 붙고 host 소유
    // nonce 는 이미 nonce 상한을 꽉 채운다 — nonce 상한으로 재면 그 파일이 통째로 건너뛰어진다.
    if (nonce.len == 0 or nonce.len > command.remote_log_name_max) return null;
    if (!command.instance_token_class.accepts(nonce)) return null;
    return nonce;
}

/// JSON 문자열 안에 그대로 넣어도 되게 이스케이프한다.
///
/// payload 를 **파싱하지 않고** 문자열로 감싸 보내므로(위 규율 2) 이스케이프만 정확하면 된다. 제어문자를
/// 빼먹으면 소비자의 파서가 그 줄에서 죽는다.
pub fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0x08 => try out.appendSlice(allocator, "\\b"),
        0x0c => try out.appendSlice(allocator, "\\f"),
        else => if (c < 0x20) {
            try out.print(allocator, "\\u{x:0>4}", .{c});
        } else try out.append(allocator, c),
    };
}

/// 이벤트 한 줄을 wire 프레임으로 만든다: `{"nonce":"…","line":"…"}`.
pub fn formatEvent(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    nonce: []const u8,
    line: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"nonce\":\"");
    try appendJsonEscaped(out, allocator, nonce);
    try out.appendSlice(allocator, "\",\"line\":\"");
    try appendJsonEscaped(out, allocator, line);
    try out.appendSlice(allocator, "\"}\n");
}

/// 하트비트 프레임. **침묵이 사망 신호다** — 종료 코드로는 못 가린다(정상 종료가 `0`, 원격의 진짜 실패가
/// `255` 를 이미 쓰고 다중화 경합으로도 255 가 난다. 어느 경우에도 stderr 는 비어 있었다).
pub fn formatHeartbeat(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, seq: u64) !void {
    try out.print(allocator, "{{\"hb\":{d}}}\n", .{seq});
}

/// 커서 한 조각: `{"cur":"<이름>","at":<offset>}`([계획](../../docs/plans/remote-agent-state.md) RA5-a).
///
/// **이름을 이스케이프하지 않는다** — 파일 이름 토큰 클래스(숫자·소문자·`_`)만 통과하므로 JSON 문자열에
/// 그대로 실을 수 있다. 그 클래스 밖이면 애초에 우리 로그가 아니라 훑지도 않는다(`nonceFromFileName`).
pub fn formatCursor(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    offset: u64,
) !void {
    try out.print(allocator, "{{\"cur\":\"{s}\",\"at\":{d}}}\n", .{ name, offset });
}

/// `--resume=` 한 칸(`<이름>:<offset>`)을 푼다. 모양이 틀리면 `null`.
pub const ResumeEntry = struct { name: []const u8, offset: u64 };

pub fn parseResumeEntry(field: []const u8) ?ResumeEntry {
    const sep = std.mem.indexOfScalar(u8, field, ':') orelse return null;
    const name = field[0..sep];
    if (name.len == 0 or name.len > command.remote_log_name_max) return null;
    if (!command.instance_token_class.accepts(name)) return null;
    const offset = std.fmt.parseInt(u64, field[sep + 1 ..], 10) catch return null;
    return .{ .name = name, .offset = offset };
}

/// `--resume=` 전체가 성한지. **인자 해석 때 본다** — 망가진 값으로 돌기 시작하면 「왜 처음부터 다시
/// 읽지」를 나중에 화면에서 되짚어야 한다. 빈 값은 「이어읽기 없음」이라 성한 것으로 친다.
pub fn resumeIsWellFormed(spec: []const u8) bool {
    if (spec.len == 0) return true;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |field| {
        if (parseResumeEntry(field) == null) return false;
    }
    return true;
}

/// 한 파일의 읽기 커서. **파일마다 따로 든다** — 디렉터리 전체를 훑으므로 하나로 두면 pane 이 섞인다
/// (프로토타입에서 실제로 그 자리를 만났다).
pub const Cursor = struct {
    /// 이미 흘린 바이트 수.
    offset: u64 = 0,
    /// 그때 본 파일 크기. **줄어들면 회전·재생성이므로 커서를 0 으로 되돌린다** — 안 그러면 새 파일의
    /// 앞부분을 영영 건너뛴다.
    seen_size: u64 = 0,
};

/// **다 읽은 파일을 언제 비우나**([계획](../../docs/plans/remote-agent-state.md) RA3 의 «회전·정리를
/// 누가 하나»).
///
/// 로컬은 「읽는 Term 이 소비 즉시 비우는 큐」다([계약](../../docs/agent-hooks.md) §4.2). 원격은 읽는
/// 주체가 채널 너머에 있어 그 규칙을 그대로 못 쓴다 — 그래서 **그 기계의 소비자인 스트리머가** 비운다.
///
/// 조건이 둘 다 필요하다:
/// - **다 읽었을 때만**(`offset == size`). 안 그러면 아직 안 흘린 꼬리를 버린다.
/// - **상한을 넘었을 때만**(로컬과 같은 1 MiB). 매번 비우면 훅의 `>>` 와 우리 `truncate` 가 경합해,
///   훅이 열어 둔 offset 뒤로 쓰는 순간 앞이 NUL 로 채워진 파일이 된다(append 모드가 그 경합을 줄이지만
///   빈도를 낮추는 것이 더 확실하다).
///
/// ⚠️ **스트리머가 죽어 있는 동안은 아무도 안 비운다.** 그 구간의 상한은 이 함수가 아니라 시작 시
/// 정리가 맡는다 — 로컬의 `cleanupAgentHookLogs` 와 같은 자리·같은 이유다(§4 가 «읽는 Term 이 없는
/// 파일은 상한 없이 자랐다» 로 이미 겪었다).
pub fn shouldTruncate(cur: Cursor, size: u64) bool {
    return size >= truncate_at_bytes and cur.offset == size;
}

/// 로컬 회전 상한과 **같은 값**이어야 한다. 두 축이 다른 상한을 쓰면 «원격만 디스크를 먹는다» 가 되고,
/// 그 차이는 사용자가 원격 기계를 들여다보기 전까지 안 보인다.
pub const truncate_at_bytes: u64 = hook_event.rotate_at_bytes;

/// **스트리머가 없던 동안 자란 파일을 시작할 때 거둔다**([계획](../../docs/plans/remote-agent-state.md)
/// RA3). 소비자가 없으면 아무도 안 비우므로, 그 구간의 상한은 이 판정이 맡는다.
///
/// **로컬처럼 «전부 지우지» 않는다.** 로컬의 시작 시 정리는 「지난 실행의 큐에는 옮길 곳이 없다」가
/// 근거인데([계약](../../docs/agent-hooks.md) §4.2), 원격 스트리머는 **사용자가 그 pane 을 계속 보고
/// 있는 동안에도** 다시 뜬다(채널이 죽었다 살아난 경우). 그때 전부 지우면 방금 생긴 이벤트를 버린다.
///
/// 그래서 **상한을 넘긴 것만** 거둔다. 그만큼 쌓였다는 것은 소비자가 오래 없었다는 뜻이고, 그 backlog 는
/// 배지로 옮길 값이 이미 아니다(가장 최근 상태만 뜻이 있는데 그것은 다음 이벤트가 다시 준다).
pub fn shouldDropAtStartup(size: u64) bool {
    return size >= truncate_at_bytes;
}

/// **오래 손 안 댄 파일인가.** 바이트에는 상한이 있는데 «파일 수» 에는 없었다 — 비워진 로그와 옆 파일은
/// 그 pane 이 사라져도 남고, tmux pane 번호는 단조 증가라 이름이 재사용되지 않는다. 스트리머는 매 회차
/// 디렉터리를 통째로 훑으므로 **훑는 비용 자체가 자란다**.
///
/// 저장소가 원격 드롭 디렉터리에 이미 쓰는 정책(`find … -mtime +7 -delete`)과 **같은 7 일**이다 —
/// 두 곳이 다른 값을 쓰면 「원격 파일은 언제 사라지나」에 답이 둘이 된다.
pub fn isStale(now_ns: i128, mtime_ns: i128) bool {
    if (mtime_ns > now_ns) return false; // 미래 mtime(시계 되돌림·NFS) — 지우지 않는다
    return now_ns - mtime_ns > stale_after_ns;
}

pub const stale_after_ns: i128 = 7 * 24 * 60 * 60 * @as(i128, std.time.ns_per_s);

/// tmux 역조회 결과를 얼마나 믿을 것인가.
///
/// ⚠️ **옆 파일 내용만으로는 무효화가 안 된다.** 파일 이름을 tmux pane 으로 가른 뒤(RA6) 한 파일의 옆
/// 파일은 **늘 같은 값**이다(같은 소켓·같은 pane). 그런데 그 pane 의 «진짜 주인» 은 바뀔 수 있다 —
/// 사용자가 detach 하고 **다른 maru pane 에서 attach** 하면 클라이언트 env 의 nonce 가 달라진다.
/// 그때 캐시가 안 풀리면 옛 주인에게 **영구히 오배달**된다(적대적 검증 2026-08-29 이 잡았다 — 이 결함은
/// 이름을 가르는 수정이 스스로 만든 것이다).
///
/// 그래서 시간으로도 푼다. 조회는 **이벤트가 도착했을 때만** 도므로, 조용한 pane 은 이 값과 무관하게
/// 아무 비용이 없다.
pub const route_ttl_ms: u64 = 5_000;

/// tmux 역조회 하나에 줄 수 있는 시간.
///
/// ⚠️ **하트비트 주기보다 넉넉히 짧아야 한다.** 조회는 이 프로세스의 주 루프에서 동기로 돌므로, 이
/// 값이 하트비트 주기(5 초)에 가까우면 멎은 tmux 하나가 **하트비트를 굶겨** 소비자가 침묵을 사망으로
/// 읽는다(15 초) — 그러면 그 호스트의 채널이 통째로 강등되고 tmux 와 무관한 pane 까지 함께 죽는다.
///
/// 조회는 같은 기계의 로컬 `tmux` 호출 둘이라 정상이면 수십 ms 다. 2 초는 그 100 배 가까이이고,
/// 그것을 넘겼다면 tmux 가 멎은 것이므로 **포기하는 쪽이 옳다**(훅 타임아웃이 같은 논리를 쓴다).
pub const lookup_deadline_ms: u64 = 2_000;

/// 이 pane 의 귀속을 다시 물어야 하나.
pub fn shouldRefreshRoute(now_ms: u64, last_ms: u64) bool {
    return now_ms -| last_ms >= route_ttl_ms;
}

/// 한 회차에 한 파일에서 읽는 양. **«남은 전부» 를 요구하면 안 된다** — 안 읽은 구간이 그 값을 넘긴
/// 파일은 읽기가 실패하고, 그 실패가 조용하면 그 파일은 영영 소비도 절단도 안 된다(실측으로 겪었다).
/// 조각을 고정하면 폭주한 파일도 회차를 거듭하며 따라잡는다.
///
/// 한 줄 상한(128 KiB)보다 넉넉해야 한 줄이 조각에 안 들어가 영영 못 넘어가는 일이 없다.
pub const read_chunk_bytes: usize = 256 * 1024;

/// 파일 크기를 보고 **어디부터 읽어야 하는가**. 회전을 감지해 커서를 되돌린다.
pub fn advance(cur: Cursor, size: u64) Cursor {
    if (size < cur.offset) return .{ .offset = 0, .seen_size = size }; // 잘렸다/새 파일이다
    return .{ .offset = cur.offset, .seen_size = size };
}

const testing = std.testing;

test "parseArgs: --stdio 와 절대 경로가 있어야 돈다" {
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev" }) == .stdio);
    try testing.expectEqualStrings("/tmp/ev", parseArgs(&.{ "--stdio", "--dir=/tmp/ev" }).stdio.dir);
    try testing.expectEqual(@as(u32, 5_000), parseArgs(&.{ "--stdio", "--dir=/tmp/ev" }).stdio.heartbeat_ms);
    try testing.expectEqual(@as(u32, 250), parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--heartbeat-ms=250" }).stdio.heartbeat_ms);
    try testing.expect(parseArgs(&.{"--help"}) == .help);
}

test "parseArgs: 계약과 다른 인자는 조용히 기본값으로 돌지 않는다" {
    try testing.expect(parseArgs(&.{}) == .usage_error); // --stdio 없음
    try testing.expect(parseArgs(&.{"--stdio"}) == .usage_error); // --dir 없음
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=" }) == .usage_error); // 빈 경로
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=relative/path" }) == .usage_error); // cwd 에 끌려간다
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--unknown" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--heartbeat-ms=x" }) == .usage_error);
}

test "nonceFromFileName: 훅이 거부했을 이름은 여기서도 거부한다" {
    try testing.expectEqualStrings("4331_7", nonceFromFileName("4331_7.ndjson").?);
    try testing.expectEqualStrings("host_00000000000000000000000000000001", nonceFromFileName("host_00000000000000000000000000000001.ndjson").?);
    try testing.expect(nonceFromFileName("4331_7.txt") == null); // 우리 확장자가 아니다
    try testing.expect(nonceFromFileName(".ndjson") == null); // 빈 nonce
    try testing.expect(nonceFromFileName("../x.ndjson") == null); // 경로 문자
    try testing.expect(nonceFromFileName("A.ndjson") == null); // 대문자
    try testing.expect(nonceFromFileName("a b.ndjson") == null); // 공백
}

test "formatEvent: payload 를 파싱하지 않고 문자열로 감싼다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try formatEvent(&out, testing.allocator, "4331_7", "claude\t{\"a\":\"b\\c\"}");
    try testing.expectEqualStrings(
        "{\"nonce\":\"4331_7\",\"line\":\"claude\\t{\\\"a\\\":\\\"b\\\\c\\\"}\"}\n",
        out.items,
    );
}

test "appendJsonEscaped: 제어문자를 빼먹으면 소비자 파서가 죽는다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendJsonEscaped(&out, testing.allocator, "a\x00b\x1fc\nd");
    try testing.expectEqualStrings("a\\u0000b\\u001fc\\nd", out.items);
}

test "formatHeartbeat: 침묵이 사망 신호라 주기적으로 나가야 한다" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try formatHeartbeat(&out, testing.allocator, 7);
    try testing.expectEqualStrings("{\"hb\":7}\n", out.items);
}

test "advance: 파일이 줄면 회전으로 보고 커서를 되돌린다" {
    const c: Cursor = .{ .offset = 100, .seen_size = 100 };
    try testing.expectEqual(@as(u64, 100), advance(c, 150).offset); // 자랐다 — 이어 읽는다
    try testing.expectEqual(@as(u64, 0), advance(c, 40).offset); // 줄었다 — 새 파일이다
    try testing.expectEqual(@as(u64, 0), advance(c, 0).offset);
}

test "hello 는 상한 안에서 찾는 값이라 모양이 고정이다" {
    // 소비자가 이 문자열을 찾는다. 바뀌면 제한 서버 판정이 통째로 어긋난다.
    try testing.expectEqualStrings("{\"hello\":\"maru-agent-events\",\"v\":1}", hello_line);
    try testing.expectEqual(@as(u32, 1), wire_version);
}

test "shouldTruncate: 다 읽었고 상한을 넘겼을 때만 비운다" {
    const cap = truncate_at_bytes;
    // 다 읽었지만 아직 작다 — 비우지 않는다(훅의 `>>` 와 경합할 이유가 없다).
    try testing.expect(!shouldTruncate(.{ .offset = 10, .seen_size = 10 }, 10));
    // 상한을 넘겼지만 **꼬리가 남았다** — 비우면 아직 안 흘린 이벤트를 버린다.
    try testing.expect(!shouldTruncate(.{ .offset = cap - 1, .seen_size = cap }, cap));
    // 둘 다 만족한다.
    try testing.expect(shouldTruncate(.{ .offset = cap, .seen_size = cap }, cap));
    try testing.expect(shouldTruncate(.{ .offset = cap * 3, .seen_size = cap * 3 }, cap * 3));
}

test "truncate 상한은 로컬 회전 상한과 같다 — 다르면 원격만 디스크를 먹는다" {
    try testing.expectEqual(hook_event.rotate_at_bytes, truncate_at_bytes);
}

test "한 회차 읽기 조각은 한 줄 상한보다 넉넉하다 — 아니면 긴 줄이 영영 안 넘어간다" {
    try testing.expect(read_chunk_bytes > hook_event.max_line_bytes);
}

test "시작 시 정리는 상한을 넘긴 것만 거둔다 — 방금 생긴 이벤트를 버리지 않는다" {
    try testing.expect(!shouldDropAtStartup(0));
    try testing.expect(!shouldDropAtStartup(truncate_at_bytes - 1));
    try testing.expect(shouldDropAtStartup(truncate_at_bytes));
    try testing.expect(shouldDropAtStartup(truncate_at_bytes * 9));
}

test "nonceFromFileName: tmux 칸이 붙은 host 소유 이름도 받는다 — nonce 상한으로 재면 통째로 사라진다" {
    // `host_<32hex>_<32hex>` 는 nonce 상한(70)을 꽉 채운다. tmux 안이면 거기에 `_t<pane>` 이 더 붙는다.
    const host_nonce = "host_" ++ ("0" ** 32) ++ "_" ++ ("0" ** 32);
    try testing.expectEqual(command.remote_pane_nonce_max, host_nonce.len);

    // 그 이름 그대로는 예전에도 통과했다.
    try testing.expect(nonceFromFileName(host_nonce ++ ".ndjson") != null);
    // **tmux 칸이 붙으면 nonce 상한을 넘는다** — 여기서 거르면 그 pane 의 이벤트가 조용히 사라진다.
    try testing.expect(nonceFromFileName(host_nonce ++ "_t12.ndjson") != null);
    try testing.expectEqualStrings(host_nonce ++ "_t12", nonceFromFileName(host_nonce ++ "_t12.ndjson").?);

    // 그래도 무한히 받지는 않는다 — 상한은 있다.
    const too_long = host_nonce ++ "_t" ++ ("1" ** 20);
    try testing.expect(nonceFromFileName(too_long ++ ".ndjson") == null);
}

test "isStale: 7 일이 넘으면 거두고, 미래 mtime 은 안 건드린다" {
    const day: i128 = 24 * 60 * 60 * @as(i128, std.time.ns_per_s);
    const now: i128 = 100 * day;
    try testing.expect(!isStale(now, now));
    try testing.expect(!isStale(now, now - 7 * day));
    try testing.expect(isStale(now, now - 8 * day));
    // 시계가 되돌아갔거나 NFS 가 미래 mtime 을 준 경우 — **지우지 않는다**(살아 있는 로그를 지우는
    // 쪽이 남기는 쪽보다 나쁘다는 규율은 로컬 정리와 같다).
    try testing.expect(!isStale(now, now + day));
}

test "shouldRefreshRoute: 시한이 지나면 다시 묻는다 — 옆 파일은 이제 안 바뀌므로 시간이 유일한 무효화다" {
    // ⚠️ **«처음» 은 이 함수가 다루지 않는다.** 그것은 호출자의 `asked` 플래그가 가른다 — 시각 0 을
    // «아직 안 물었다» 로 겸하면 시계가 0 근처인 순간(테스트·부팅 직후)에 두 뜻이 겹친다.
    // 이 함수는 **오직 시간**만 본다.
    try testing.expect(!shouldRefreshRoute(0, 0));
    try testing.expect(!shouldRefreshRoute(route_ttl_ms - 1, 1));
    try testing.expect(shouldRefreshRoute(route_ttl_ms + 1, 1));
    // 시계가 되돌아가도 터지지 않는다(포화 뺄셈).
    try testing.expect(!shouldRefreshRoute(1, 10_000));
}

test "역조회 시한은 하트비트를 굶기지 않는다 — 그러면 채널이 통째로 강등된다" {
    // 조회가 주 루프에서 동기로 도는 한, 이 부등식이 축의 생사다.
    const Options_default: Options = .{ .dir = "/x" };
    try testing.expect(lookup_deadline_ms < Options_default.heartbeat_ms);
    // 그리고 소비자의 침묵 시한보다 훨씬 짧아야 한 번의 지연이 강등으로 안 번진다.
    try testing.expect(lookup_deadline_ms * 3 < 15_000);
}

test "formatCursor: 이어읽기 위치를 프레임으로 싣는다" {
    const a = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try formatCursor(&out, a, "host_abc_def_t24", 4096);
    try testing.expectEqualStrings("{\"cur\":\"host_abc_def_t24\",\"at\":4096}\n", out.items);
}

test "parseResumeEntry: 이름과 offset 을 가르고, 성하지 않으면 버린다" {
    const ok = parseResumeEntry("t24:4096") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("t24", ok.name);
    try testing.expectEqual(@as(u64, 4096), ok.offset);

    // 0 은 정당한 값이다 — 「처음부터」를 명시한 것이다.
    const zero = parseResumeEntry("t24:0") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0), zero.offset);

    try testing.expect(parseResumeEntry("t24") == null); // 구분자 없음
    try testing.expect(parseResumeEntry(":4096") == null); // 이름 없음
    try testing.expect(parseResumeEntry("t24:") == null); // offset 없음
    try testing.expect(parseResumeEntry("t24:-1") == null); // 음수
    try testing.expect(parseResumeEntry("t24:99999999999999999999999") == null); // u64 초과
    // **경로를 벗어나는 글자는 이름이 될 수 없다** — 이 값이 파일 이름으로 쓰이므로 여기서 막는다.
    try testing.expect(parseResumeEntry("../etc:1") == null);
    try testing.expect(parseResumeEntry("a/b:1") == null);
}

test "parseResumeEntry: 파일 이름 상한까지 받는다 — tmux 칸이 붙어도 안 버린다" {
    // nonce 상한으로 재면 tmux 안의 host 소유 pane 이 통째로 빠진다(`nonceFromFileName` 과 같은 함정).
    const a = testing.allocator;
    var name: std.ArrayListUnmanaged(u8) = .empty;
    defer name.deinit(a);
    try name.appendNTimes(a, 'a', command.remote_log_name_max);
    const field = try std.fmt.allocPrint(a, "{s}:7", .{name.items});
    defer a.free(field);
    try testing.expect(parseResumeEntry(field) != null);

    var over: std.ArrayListUnmanaged(u8) = .empty;
    defer over.deinit(a);
    try over.appendNTimes(a, 'a', command.remote_log_name_max + 1);
    const bad = try std.fmt.allocPrint(a, "{s}:7", .{over.items});
    defer a.free(bad);
    try testing.expect(parseResumeEntry(bad) == null);
}

test "parseArgs: --resume 을 받고, 망가진 값은 시작 전에 거른다" {
    // 빈 값 = 이어읽기 없음(앱을 새로 켠 경우) — 기본값이 그것이다.
    try testing.expectEqualStrings("", parseArgs(&.{ "--stdio", "--dir=/tmp/ev" }).stdio.resume_spec);

    const m = parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--resume=t5:10,t8:20" });
    try testing.expectEqualStrings("t5:10,t8:20", m.stdio.resume_spec);

    // **망가진 값으로 돌기 시작하지 않는다** — 그러면 「왜 처음부터 다시 읽지」를 나중에 화면에서
    // 되짚어야 한다.
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--resume=t5" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--resume=t5:10," }) == .usage_error);
    try testing.expect(parseArgs(&.{ "--stdio", "--dir=/tmp/ev", "--resume=../x:1" }) == .usage_error);
}
