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
};

/// `agent-events` 뒤 인자를 해석한다. **모르는 플래그는 오류다** — 조용히 무시하면 오타가 «기본값으로
/// 도는» 상태가 되고, 그 사실이 드러나는 자리는 원격 로그뿐이다.
pub fn parseArgs(args: []const []const u8) Mode {
    var dir: ?[]const u8 = null;
    var hb: u32 = 5_000;
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
        } else return .usage_error;
    }
    if (!saw_stdio) return .usage_error;
    const d = dir orelse return .usage_error;
    if (d.len == 0 or !std.fs.path.isAbsolute(d)) return .usage_error; // 상대 경로는 cwd 에 끌려간다
    return .{ .stdio = .{ .dir = d, .heartbeat_ms = hb } };
}

/// 디렉터리 항목이 **우리 로그**인가. 맞으면 그 nonce 를 돌려준다.
///
/// 이름을 그대로 믿지 않는다 — 그 값이 wire 에 실려 로컬에서 **어느 Term 인가** 를 정하기 때문이다.
/// 훅이 쓰는 가드와 **같은 클래스**로 재서, 훅이 거부했을 이름은 여기서도 거부한다.
pub fn nonceFromFileName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, log_suffix)) return null;
    const nonce = name[0 .. name.len - log_suffix.len];
    if (nonce.len == 0 or nonce.len > command.remote_pane_nonce_max) return null;
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
