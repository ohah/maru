//! **SSH 클라이언트 세션 하나** — 버전 교환부터 셸까지를 잇는 sans-io 상태기계.
//!
//! **왜 이 파일이 있나.** 지금까지 만든 것은 조각이다(패킷·KEX·암호·전송·인증·채널). 그것을
//! 순서대로 엮는 코드가 검증 도구 안에만 있었는데, 모바일도 **같은 순서**가 필요하다. 두 벌을
//! 두면 갈리고, 갈리는 순간 한쪽에서만 나는 결함이 생긴다 — 이 저장소에서 여러 번 겪은 모양이다.
//!
//! **밀어 넣는 구조다.** 검증 도구는 "읽힐 때까지 막고" 짤 수 있었지만 모바일은 그럴 수 없다 —
//! host 가 소켓을 들고 바이트를 밀어 넣는다(모바일 §3: 브리지엔 OS 호출이 0). 그래서 여기는
//! `feed(입력) → (선에 보낼 바이트, 화면에 그릴 바이트)` 인 상태기계이고, 막지 않는다.
//!
//! **비밀은 호출자가 든다.** 개인키는 인자로 받는다 — 모바일에서는 host 가 Keychain·Keystore 에서
//! 꺼내 온다(계약 §3.4). 이 층은 파일도 키체인도 모른다.

const std = @import("std");
const version = @import("version.zig");
const kexinit = @import("kexinit.zig");
const kex = @import("kex.zig");
const cipher = @import("cipher.zig");
const transport = @import("transport.zig");
const hostkey = @import("hostkey.zig");
const userauth = @import("userauth.zig");
const channel = @import("channel.zig");
const wire = @import("wire.zig");
const packet = @import("packet.zig");

pub const Error = error{
    /// 상대가 우리가 기대한 것과 다른 메시지를 보냈다.
    UnexpectedMessage,
    /// 호스트키를 아직 승인받지 못했다 — `acceptHostKey` 를 부르거나 끊는다.
    HostKeyNotAccepted,
    /// 사용자가 호스트키를 거절했다(또는 `known_hosts` 가 다르다).
    HostKeyRejected,
    /// **재키잉에서 서버가 다른 호스트키를 내밀었다.** 서명은 맞을 수 있다 — 서명 검증은 "이 키가
    /// 이 `H` 에 서명했다" 만 말하지 그 키가 사용자가 승인한 키인지는 안 본다.
    HostKeyChanged,
    /// 인증이 거절됐다.
    AuthFailed,
    /// **서버가 비밀번호를 바꾸라고 한다**(RFC 4252 §8 — 만료된 계정). 우리는 바꾸는 대화를
    /// 안 하므로 여기서 끝낸다 — 다만 `AuthFailed` 와 **다른 이름**이다: 사용자가 할 일이
    /// "다시 쳐 보기" 가 아니라 "서버에서 비밀번호를 바꾸기" 라서, 같은 이름으로 묶으면
    /// 화면이 틀린 안내를 하게 된다.
    PasswordChangeRequired,
    /// 서버가 채널을 안 열어 줬다.
    ChannelRefused,
    /// 채널 요청(`pty-req`·`shell`)이 거절됐다.
    RequestFailed,
    /// 아직 셸이 안 떴는데 쓰려 한다.
    ///
    /// **`SSH_MSG_DISCONNECT` 는 여기 없다.** 서버가 끊은 것은 오류가 아니라 `Step` 으로 온다
    /// (`state == .closed` + `Step.disconnect`) — 오류에는 이유를 못 싣고, 이유 없는 "끊겼다" 는
    /// 사용자가 고칠 것을 안 준다.
    NotReady,
    /// `start` 를 안 부르고 `feed` 했다. **조용한 무동작보다 낫다** — 안 그러면 호출자가 아무
    /// 일도 안 하면서 영원히 읽는다(실측으로 그 모양을 여러 번 겪었다).
    NotStarted,
    /// 호출자 버퍼가 모자란다.
    ShortBuffer,
} || transport.Error || kexinit.Error || kex.Error || hostkey.Error ||
    userauth.Error || channel.Error || version.Error || wire.Error;

/// 지금 어디까지 왔나. **UI 가 이 값을 그대로 보여 줄 수 있게** 이름을 짓는다.
pub const State = enum {
    /// 아직 시작 안 함.
    idle,
    /// 서버 버전 줄을 기다린다.
    version_exchange,
    /// 서버 `KEXINIT` 을 기다린다.
    negotiating,
    /// 서버 `KEX_ECDH_REPLY` 를 기다린다.
    key_exchange,
    /// **호스트키를 사용자에게 물어야 한다**(계약 §4 — 자동 승인은 없다). `acceptHostKey` 를
    /// 부르기 전에는 한 발도 안 나간다.
    host_key_decision,
    /// 서버 `NEWKEYS` 를 기다린다.
    awaiting_new_keys,
    /// `ssh-userauth` 수락을 기다린다.
    requesting_service,
    /// 인증 결과를 기다린다.
    authenticating,
    /// **비밀번호를 사용자에게 물어야 한다.** 키로 거절당했고 서버가 `password` 를 열어 뒀다 —
    /// `providePassword` 를 부르기 전에는 한 발도 안 나간다(호스트키 승인과 같은 모양).
    ///
    /// 이 자리에서 멈추는 이유는 **비밀번호를 코어가 들고 있지 않기 때문**이다. 계약(§3.4)이
    /// "저장하지 않는다 — 접속할 때마다 묻고 지운다" 로 정해 두었고, 그러면 물을 수 있는 것은
    /// 화면을 가진 쪽뿐이다.
    password_needed,
    /// 채널 열기 확인을 기다린다.
    opening_channel,
    /// `pty-req` 답을 기다린다.
    requesting_pty,
    /// `shell` 답을 기다린다.
    starting_shell,
    /// **셸이 떴다** — 이제 화면 바이트가 오고 키 입력을 보낼 수 있다.
    ready,
    /// 끝났다.
    closed,
};

/// 채널 번호는 **우리가 고른다**(§5.1 — "sender channel"). 터미널이 0, 컨트롤이 1 이다.
/// 값 자체에 뜻은 없지만 **받은 메시지를 어느 채널로 보낼지 고르는 열쇠**라서 고정해 둔다.
const shell_local_id: u32 = 0;
const control_local_id: u32 = 1;

/// 컨트롤 채널이 어디까지 왔나. **터미널 상태(`State`)와 섞지 않는다** — 컨트롤이 어떻게 되든
/// 터미널은 그대로 살아야 하고, 그 규율은 상태를 따로 두는 데서 시작한다.
pub const ControlState = enum {
    /// 안 열었다.
    none,
    /// `CHANNEL_OPEN` 을 보내고 답을 기다린다.
    opening,
    /// `exec` 을 보내고 답을 기다린다.
    requesting_exec,
    /// 명령이 돌고 있다 — 이제 ndjson 이 오간다.
    ready,
    /// 끝났다(상대가 닫았거나 우리가 닫았거나, 열기·`exec` 이 거절됐거나).
    closed,
};

/// 컨트롤 채널이 광고하는 **최대 패킷**. 터미널(32KiB)보다 작게 잡는다.
///
/// **버퍼를 대는 쪽이 모바일이기 때문이다.** 받는 쪽 상한은 우리가 정하는 값이고(§5.1),
/// 호출자는 이 값 이상의 버퍼를 대야 한다(계약 §3.4.1). 터미널과 같은 32KiB 를 광고하면 폰의
/// 세션 하나가 그만큼 더 든다 — 컨트롤로 오는 것은 ndjson 줄이라 큰 패킷이 이득도 아니다.
/// 큰 답은 이 크기로 **여러 번** 나뉘어 온다.
pub const control_max_packet: u32 = 8 * 1024;

/// 컨트롤 채널이 광고하는 **윈도**. 터미널(2MiB)보다 작게 잡는다 — 같은 이유이고, 보충은
/// 절반에서 자동으로 나간다(`pendingWindowAdjust`).
pub const control_window: u32 = 256 * 1024;

/// 컨트롤 채널이 돌릴 명령의 최대 길이. 절대경로 + 인자 한둘이면 충분하고, 넘으면 조용히 자르지
/// 않고 거절한다 — 잘린 명령은 **다른 명령**이다.
pub const max_control_command = 512;

/// 연결에 필요한 것들. **비밀은 호출자가 든다.**
pub const Options = struct {
    user: []const u8,
    /// `seed(32) ‖ public(32)`. host 가 Keychain·Keystore 에서 꺼내 온다.
    ///
    /// **없을 수 있다.** 키가 아직 없는 기기(iOS 에 키 파일을 안 넣은 경우)도 **비밀번호만 여는
    /// 서버에는 붙을 수 있어야** 한다 — 예전에는 host 가 키가 없으면 아예 시작을 안 해서, 키가
    /// 필요 없는 서버조차 못 붙었다. 없으면 `none` 으로 방법 목록만 묻는다(RFC 4252 §5.2).
    secret_key: ?[userauth.secret_key_len]u8,
    /// `TERM` 값. 원격이 이것으로 terminfo 를 고른다.
    term: []const u8 = "xterm-256color",
    size: channel.TerminalSize,
    /// 우리가 광고할 채널 윈도. 0 이면 기본(2MiB).
    window: u32 = 0,
    /// **pty 를 요청하나.** 터미널이면 참이다(기본).
    ///
    /// 끄면 stdout 과 stderr 가 **따로** 온다(`CHANNEL_DATA`·`CHANNEL_EXTENDED_DATA`). 켜면 서버가
    /// 그것을 pty 로 합쳐 보내고, **우리가 보낸 것도 그대로 되돌아온다**(터미널 에코) — 검증에서
    /// 그 에코를 명령 출력으로 오해했다(실측). 즉 이 값은 화면에 무엇이 오는지를 바꾼다.
    pty: bool = true,
};

/// `feed` 한 걸음이 **선에 낼 수 있는 최대치**. 인증 요청이 가장 크다(키 blob + 서명 + 사용자 이름).
///
/// 호출자 버퍼가 이보다 작으면 한 걸음도 못 나가는데, 그것을 조용히 두면 **아무 일도 안 하면서
/// 도는 루프**가 된다 — 그래서 `feed` 가 입구에서 거절한다.
pub const min_wire_out = 4096;

/// 1 바이트 답 하나가 선에서 차지하는 크기. **어림수를 쓰지 않는다** — 모자라게 잡으면 마지막
/// 한 개에서 `NoSpace` 로 죽고, 그 경계는 버퍼 크기에 따라 걸리기도 안 걸리기도 해서 테스트로
/// 잡히지 않는다(변이 검사에서 실제로 그렇게 살아남았다). 프레이밍이 아는 값을 그대로 쓴다.
///
/// **밀린 답을 비울 때 `min_wire_out` 으로 재면 안 된다.** 최소 크기(4096) 버퍼를 준 호출자는
/// 한 번 부를 때마다 답을 하나씩만 내보내게 되어 255 개를 비우는 데 `feed` 를 255 번 부른다 —
/// 그 사이 서버는 답을 기다린다.
const max_reply_packet = cipher.Cipher.sealedLen(1);
/// 미뤄 둔 채널 메시지(`CHANNEL_CLOSE`·`CHANNEL_FAILURE`) 하나가 봉인돼 차지하는 상한.
/// **먼저 자리를 보고 쓴다** — `writeClose` 는 부르는 순간 채널 상태를 바꾸므로, 자리가
/// 모자라 `emit` 이 실패하면 「보냈다」고 굳은 채 선에는 아무것도 안 나간다(적대적 검증 2회차).
const max_channel_reply_packet = cipher.Cipher.sealedLen(16);

/// `feed` 한 번의 결과.
///
/// **`banner`·`exit_signal`·`disconnect.description` 은 `Client` 안을 가리킨다** — `wire`·`screen`
/// 이 호출자 버퍼를 가리키는 것과 다르다. 다음 `feed` 까지만 살고, `Client` 를 복사·이동하면
/// 그 순간 어긋난다.
/// 들고 있어야 하면 **복사한다**. 전송기의 `Received.payload` 와 같은 규칙이다(계약 §4.5).
pub const Step = struct {
    /// 입력에서 소비한 바이트. 호출자는 그만큼 앞으로 민다.
    consumed: usize,
    /// **선에 보낼 바이트**(호출자가 준 `wire_out` 안). 비어 있을 수 있다.
    wire: []const u8,
    /// **화면에 그릴 바이트**(호출자가 준 `screen_out` 안). 원격의 stdout·stderr 를 합친 것이다 —
    /// pty 를 쓰면 서버가 이미 합쳐 보내므로 여기서도 가르지 않는다.
    screen: []const u8,
    /// **컨트롤 채널의 stdout**(호출자가 준 `Buffers.control` 안). 컨트롤 채널을 안 열었으면 늘
    /// 비어 있다. 화면 바이트와 **섞지 않는다** — 섞으면 ndjson 파서가 사람 화면을 읽게 된다.
    ///
    /// **줄 경계가 아니다.** 여기 오는 것은 패킷이 실어 온 만큼이라, 호출자가 줄 단위로 이어
    /// 붙여야 한다(계약 §4a — 프레임 상한과 채널 배압이 만나는 자리).
    control: []const u8 = &.{},
    state: State,
    /// 셸이 끝났다면 그 코드.
    exit_status: ?u32 = null,
    /// 신호로 죽었다면 그 이름(`SIG` 접두 없이). `exit_status` 와 **둘 중 하나**만 온다(§6.10).
    exit_signal: ?[]const u8 = null,
    /// 서버가 보낸 배너(RFC 4252 §5.4 — 법적 고지 등). **이미 걸러져 있다**(제어문자 제거) —
    /// 서버가 고른 문자열이 그대로 화면에 가면 OSC 로 창 제목·클립보드에 손댈 수 있다.
    banner: ?[]const u8 = null,
    /// 서버가 끊은 이유(RFC 4253 §11.1). **끊긴 사실(`state == .closed`)과 같은 `Step` 에 온다** —
    /// 오류로 올리면 값을 못 실어 이유를 읽으러 한 번 더 불러야 하고, 오류를 받고 멈춘 호출자는
    /// 그 "왜" 를 영영 못 본다. 그리고 그 "왜" 가 사용자가 유일하게 고칠 수 있는 것이다
    /// ("Too many authentication failures" · "No supported authentication methods available").
    disconnect: ?Disconnect = null,
};

/// 서버가 끊은 이유(RFC 4253 §11.1).
pub const Disconnect = struct {
    reason: DisconnectReason,
    /// **서버가 고른 문자열이다** — 배너와 같은 거름망을 지나 온다(계약 §4.4.2).
    description: []const u8,
};

/// 끊은 사유 코드(RFC 4253 §11.1). **이름을 든다** — 숫자만 보여 주면 사용자가 못 읽는다.
pub const DisconnectReason = enum(u32) {
    host_not_allowed_to_connect = 1,
    protocol_error = 2,
    key_exchange_failed = 3,
    reserved = 4,
    mac_error = 5,
    compression_error = 6,
    service_not_available = 7,
    protocol_version_not_supported = 8,
    host_key_not_verifiable = 9,
    connection_lost = 10,
    by_application = 11,
    too_many_connections = 12,
    auth_cancelled_by_user = 13,
    no_more_auth_methods_available = 14,
    illegal_user_name = 15,
    /// 표에 없는 값. **오류로 다루지 않는다** — 사유 코드는 IANA 가 늘리고, 모르는 값 때문에
    /// 설명까지 버리면 "왜" 가 사라진다.
    _,
};

/// **약 10KiB 다.** 교환 해시에 쓸 원문(`I_C`·`I_S` 각 4KiB)을 그대로 들어야 해서 그렇다 —
/// 다시 만들면 cookie 가 달라져 해시가 안 맞는다(계약 §4.2).
///
/// **자리를 고정해서 든다**(전역·힙). 값으로 옮기면 10KiB 를 복사할 뿐 아니라, 앞선 `Step` 이
/// 가리키던 `banner`·`exit_signal` 이 옛 자리를 보게 된다.
pub const Client = struct {
    state: State = .idle,
    t: transport.Transport = .{},
    ch: channel.Channel = .{ .local_id = shell_local_id },
    /// 두 번째 채널. **`null` 이면 안 연 것이다** — 터미널만 쓰는 접속에서는 열지 않는다
    /// (계약 §4a "언제 여는가": 채널을 여는 것은 그 서버에서 명령을 하나 실행하는 일이다).
    control: ?channel.Channel = null,
    control_state: ControlState = .none,
    /// 돌릴 명령. `CHANNEL_OPEN` 을 보낸 뒤 **열렸다는 답이 올 때까지** 들고 있어야 한다.
    control_cmd_buf: [max_control_command]u8 = undefined,
    control_cmd_len: usize = 0,
    /// 컨트롤 채널의 종료 코드. **터미널 것과 따로 둔다** — 계약이 이 값으로 "그 서버에 maru 가
    /// 없다"(127)와 "다른 프로그램이 돌았다"(그 밖)를 가른다(§4a).
    control_exit_status: ?u32 = null,
    /// 컨트롤 채널의 **stderr 첫 조각**. 계약은 "stdout 은 오직 wire, 로그·경고는 stderr" 인데,
    /// 그 stderr 를 버리면 사용자는 왜 안 되는지 알 길이 없다. 첫 줄이 대개 원인이라
    /// (`maru: command not found`) **앞을 남기고 뒤를 버린다**.
    control_stderr_buf: [256]u8 = undefined,
    control_stderr_len: usize = 0,
    /// 터미널 채널이 닫혔나. **세션을 닫을지 판정하는 재료**다 — 채널 상태만 보면 "우리 close 를
    /// 아직 안 보낸" 자리와 구별이 안 된다.
    shell_closed: bool = false,
    control_deferred_close: bool = false,
    control_deferred_request_failure: bool = false,
    opts: Options,
    rand: std.Random,

    /// 교환 해시 재료. **버전 줄과 `KEXINIT` 원문은 그대로 보관해야 한다** — 다시 만들면 cookie 가
    /// 달라져 해시가 안 맞는다(계약 §4.2).
    v_c_buf: [64]u8 = undefined,
    v_c_len: usize = 0,
    v_s_buf: [version.max_line]u8 = undefined,
    v_s_len: usize = 0,
    i_c_buf: [4096]u8 = undefined,
    i_c_len: usize = 0,
    i_s_buf: [4096]u8 = undefined,
    i_s_len: usize = 0,

    eph: ?kex.Ephemeral = null,
    k: [kex.shared_len]u8 = undefined,
    h: [kex.hash_len]u8 = undefined,
    /// **첫 `H`** — 재키잉해도 안 바뀐다(RFC 4253 §7.2).
    session_id: [kex.hash_len]u8 = undefined,
    strict_kex_initial: bool = false,

    /// 호스트키 blob(사용자에게 보여 줄 지문을 여기서 뽑는다).
    host_key_buf: [512]u8 = undefined,
    host_key_len: usize = 0,
    host_key_accepted: bool = false,

    /// 방금 보낸 인증 방식. **응답 파싱이 이 값을 본다** — §7(`PK_OK`)과 §8(비밀번호 변경 요구)이
    /// 같은 번호(60)를 서로 다르게 읽으므로, 무엇을 보냈는지 모르면 답을 오해한다.
    auth_method: userauth.Method = .publickey,
    /// 비밀번호를 한 번이라도 보냈나. **다시 묻지 않기 위한 것**이다 — 서버는 틀린 비밀번호에도
    /// 같은 방법 목록을 돌려주므로(RFC 4252 §5.1), 안 세면 되묻는 고리가 된다.
    password_tried: bool = false,

    /// 재키잉 중에 미뤄 둔 채널 응답. **재키잉 중에는 채널 메시지를 못 보낸다**(계약 §3.0.1).
    deferred_close: bool = false,
    /// 모르는 채널 요청에 답할 것이 밀려 있나(§5.4 — `want_reply` 면 답해야 한다).
    deferred_request_failure: bool = false,
    /// 재키잉 중인가(우리가 시작했든 서버가 시작했든).
    rekeying: bool = false,
    exit_status: ?u32 = null,
    /// 신호로 죽었을 때 그 이름. **`exit_status` 를 `null` 로 두고 끝내면 "끝났는지" 조차 모른다** —
    /// 옛 드라이버는 이것을 오류로 올렸는데, 오류는 세션을 죽이므로 정보만 남기는 편이 낫다.
    exit_signal_buf: [32]u8 = undefined,
    exit_signal_len: usize = 0,
    /// 재키잉 횟수(진단용). 0 이면 그 경로를 안 탔다는 뜻이다.
    rekeys: usize = 0,
    /// 걸러 둔 배너. `feed` 한 번이 돌려주고 다음 호출에서 비운다.
    banner_buf: [1024]u8 = undefined,
    banner_len: usize = 0,
    /// 끊긴 이유. 상태가 `closed` 로 가는 **같은 `feed` 호출**에서 나온다.
    disconnect_buf: [512]u8 = undefined,
    /// **답을 미뤄 둔 전역 요청의 수**(§7.1). 재키잉 중에는 `REQUEST_FAILURE`(82) 를 보낼 수
    /// 없어서, 그 사이에 온 요청의 답을 여기 세어 두고 재키잉이 끝나면 내보낸다.
    pending_request_failures: u8 = 0,
    disconnect_len: usize = 0,
    disconnect_reason: DisconnectReason = @enumFromInt(0),
    disconnected: bool = false,
    /// **셸이 한 번이라도 떴나.** `state` 는 재키잉 중에 `key_exchange` 로 돌아가는데, 그때
    /// `write` 가 `NotReady` 를 내면 **호출자가 재키잉을 알아야** 한다 — 알 필요가 없어야 한다.
    /// 그래서 "쓸 수 있는 세션인가"(이 값)와 "지금 보낼 수 있나"(윈도·§7.1)를 가른다.
    shell_ready: bool = false,

    pub fn init(opts: Options, rand: std.Random) Client {
        var c: Client = .{ .opts = opts, .rand = rand };
        if (opts.window != 0) {
            c.ch.local_window_max = opts.window;
            c.ch.local_window = opts.window;
        }
        return c;
    }

    /// 비밀을 지운다. **연결이 끝나면 부른다.**
    ///
    /// **지운 뒤에는 못 쓴다.** 처음에는 상태를 그대로 뒀는데, 그러면 키가 0 인 채로 세션이
    /// 계속 굴러간다 — 그 결과는 "왜인지 서버가 다 거절한다" 로 나타나고 원인이 여기라는 것을
    /// 짚기 어렵다(실측). 그래서 `closed` 로 못박는다.
    ///
    /// **`h`·`session_id` 는 안 지운다.** 비밀이 아니다 — `H` 는 공개 값들과 `K` 의 해시이고
    /// 서버가 거기에 **서명해서 보내는** 값이며, `session_id` 는 인증 서명에 그대로 들어간다.
    /// 지울 이유가 없는 것을 지우면 다음 사람이 "이건 왜 안 지우지" 를 거꾸로 묻게 된다.
    pub fn clear(self: *Client) void {
        self.t.clear();
        if (self.eph) |*e| e.clear();
        std.crypto.secureZero(u8, &self.k);
        if (self.opts.secret_key) |*k| std.crypto.secureZero(u8, k);
        self.state = .closed;
        self.shell_ready = false;
        // **컨트롤도 함께 못박는다.** 안 그러면 `clear` 뒤에도 `control_state` 가 `ready` 로 남아
        // `writeControl` 이 오류 대신 **조용히 0 바이트**를 돌려준다 — 터미널 `write` 는 같은
        // 자리에서 `NotReady` 다. 두 축이 다르게 굴면 호출자가 한쪽에서만 실수를 발견한다.
        self.control_state = .closed;
    }

    /// 우리 버전 줄을 낸다. **`feed` 보다 먼저 한 번 부른다.**
    pub fn start(self: *Client, wire_out: []u8) Error![]const u8 {
        if (self.state != .idle) return Error.UnexpectedMessage;
        // **버전 문자열은 comptime 이다**(`version.clientLine` 이 그렇게 생겼다). 예전에는
        // `Options.app_version` 이 있었는데 **아무 데도 안 쓰였다** — 설정해도 조용히 무시되는
        // 필드였다. 작동하지 않는 옵션은 사용자를 속이므로 없앴다. 런타임으로 바꿀 이유가
        // 생기면 `clientLine` 부터 바꿔야 한다.
        const line = version.clientLine("0.1");
        if (line.len > self.v_c_buf.len) return Error.ShortBuffer;
        @memcpy(self.v_c_buf[0..line.len], line);
        self.v_c_len = line.len;
        if (line.len + 2 > wire_out.len) return Error.ShortBuffer;
        @memcpy(wire_out[0..line.len], line);
        wire_out[line.len] = '\r';
        wire_out[line.len + 1] = '\n';
        self.state = .version_exchange;
        return wire_out[0 .. line.len + 2];
    }

    /// 사용자가 호스트키를 승인했다(계약 §4 — TOFU).
    pub fn acceptHostKey(self: *Client) void {
        self.host_key_accepted = true;
    }

    /// **사용자가 친 비밀번호를 넣는다**(`password_needed` 상태에서만 뜻이 있다).
    ///
    /// 코어는 그 값을 **안 들고 있는다** — 이 함수 안에서 요청 패킷으로 만들어 선에 내보내고,
    /// 만든 자리를 지운다. 계약 §3.4 가 "저장하지 않는다" 로 정한 것을 코어에서도 지킨다
    /// (호출자가 자기 버퍼를 지우는 것은 호출자 몫이다).
    ///
    /// 선 버퍼가 모자라면 `ShortBuffer` 다 — 조용히 반만 보내면 서버가 프레이밍을 못 읽는다.
    pub fn providePassword(self: *Client, password: []const u8, wire_out: []u8) Error![]const u8 {
        if (self.state != .password_needed) return Error.UnexpectedMessage;
        if (wire_out.len < min_wire_out) return Error.ShortBuffer;
        var w: Out = .{ .buf = wire_out };
        var req: [1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &req); // 비밀번호가 스택에 남지 않게
        self.auth_method = .password;
        self.password_tried = true;
        try self.emit(&w, try userauth.writePasswordRequest(&req, self.opts.user, password));
        self.state = .authenticating;
        return w.written();
    }

    /// 사용자에게 보여 줄 지문. `host_key_decision` 상태에서 유효하다.
    pub fn hostKeyFingerprint(self: *Client, out: []u8) Error![]const u8 {
        return hostkey.fingerprint(out, self.host_key_buf[0..self.host_key_len]);
    }

    /// 선에서 읽은 바이트를 먹인다. **막지 않는다** — 더 필요하면 `consumed` 만큼만 먹고 돌아온다.
    /// `feed` 가 쓸 호출자 버퍼들. **컨트롤은 안 열었으면 안 줘도 된다.**
    pub const Buffers = struct {
        wire: []u8,
        screen: []u8,
        /// 컨트롤 채널의 stdout 이 여기로 온다. 채널을 열어 놓고 이것을 비워 두면 `ShortBuffer`
        /// 다 — **조용히 버리지 않는다**. 버리면 ndjson 이 한 줄씩 사라져 파서가 이유 없이 깨진다.
        control: []u8 = &.{},
    };

    /// 터미널만 쓰는 호출자를 위한 짧은 이름. 컨트롤 채널을 여는 호출자는 `feedBuffers` 를 쓴다.
    pub fn feed(self: *Client, input: []const u8, wire_out: []u8, screen_out: []u8) Error!Step {
        return self.feedBuffers(input, .{ .wire = wire_out, .screen = screen_out });
    }

    pub fn feedBuffers(self: *Client, input: []const u8, bufs: Buffers) Error!Step {
        const wire_out = bufs.wire;
        const screen_out = bufs.screen;
        // **버퍼가 한 걸음도 못 담으면 시작하지 않는다.** 조용히 0 을 돌려주면 호출자가 영원히
        // 맴돈다 — 이 저장소에서 "아무것도 안 하면서 초록" 을 여러 번 겪었다.
        // **`start` 를 안 불렀으면 오류다.** 조용히 아무 일도 안 하면 호출자가 영원히 읽는다.
        if (self.state == .idle) return Error.NotStarted;
        if (wire_out.len < min_wire_out) return Error.ShortBuffer;
        if (screen_out.len < self.ch.local_max_packet) return Error.ShortBuffer;
        // **컨트롤 버퍼도 같은 대접을 받는다.** 채널을 열어 놓고 한 패킷도 못 담는 버퍼를 주면
        // 첫 데이터에서 `ShortBuffer` 로 세션이 죽는다 — 화면 쪽이 입구에서 거절하는 것과 같은
        // 이유로 여기서 거절한다(조용히 흘리지도, 도중에 죽지도 않게).
        //
        // **살아 있는 채널만 요구한다.** 닫은 뒤에도 요구하면 목록 화면을 닫고 버퍼를 놓아준
        // 호출자가 **그 뒤 모든 `feed` 에서 죽는다** — 이 채널은 화면을 드나들 때마다 열고 닫는
        // 것이라 그 자리에 반드시 닿는다(적대적 검증이 잡았다).
        if (self.controlAlive()) {
            if (bufs.control.len < self.control.?.local_max_packet) return Error.ShortBuffer;
        }
        var w: Out = .{ .buf = wire_out };
        var s: Out = .{ .buf = screen_out };
        var c: Out = .{ .buf = bufs.control };
        var consumed: usize = 0;
        self.banner_len = 0; // 지난 호출의 것을 물려주지 않는다

        // **진행은 "먹었나" 만이 아니다 — "상태가 옮겨졌나" 도 진행이다.**
        //
        // 처음에는 `consumed` 만 봤는데, 그러면 호스트키 승인처럼 **입력을 안 먹고 상태만 옮기는**
        // 걸음 뒤에 루프가 끊긴다. 그때 이미 버퍼에 들어와 있던 서버 `NEWKEYS` 를 안 먹고 나가고,
        // 호출자는 더 읽으려 하는데 서버는 이미 다 보낸 뒤라 **20초를 멈춘다**(실서버에서 실측).
        while (true) {
            // **버퍼가 찰 것 같으면 멈춘다.** 호출자 버퍼는 유한하고(모바일은 특히), 한 번에
            // 다 담으려 들면 `ShortBuffer` 로 죽는다 — 실측으로 겪었다. 여기서 멈추면 호출자가
            // 비우고 다시 부르면 되고, 입력은 `consumed` 만큼만 먹었으므로 잃는 것이 없다.
            // 한 걸음이 실제로 필요한 만큼만 남겨 둔다. 넉넉히 잡으면(예: 패킷 상한 256KiB)
            // 모바일이 못 쓸 크기를 요구하게 된다.
            if (w.remaining() < min_wire_out or s.remaining() < self.ch.local_max_packet) break;
            // 컨트롤도 마찬가지다 — 차면 멈추고 호출자가 비운 뒤 다시 부른다. 이 줄이 없으면
            // 큰 답(프로토콜 프레임 상한 ≈1MiB)이 올 때 **오류로 죽는다**(화면은 안 그런다).
            if (self.controlAlive()) {
                if (c.remaining() < self.control.?.local_max_packet) break;
            }
            const before_consumed = consumed;
            const before_state = self.state;
            try self.step(input[consumed..], &consumed, &w, &s, &c);
            // **밀린 것을 비운다.** 입력이 없어도 비워야 한다 — 서버의 keepalive(채널 요청
            // `keepalive@openssh.com`, 실측)에 답하는 자리라서, 다음 패킷이 올 때까지 미루면
            // 서버가 우리를 죽은 것으로 본다. (`stepPacket` 도 끝에서 같은 것을 부르지만 그쪽은
            // **패킷이 있을 때만** 돈다.)
            //
            // **`step` 뒤에 둔다.** 앞에 두면 같은 `feed` 안에서 방금 읽은 `DISCONNECT` 를 모른
            // 채로 큐를 비워, 이미 끝난 연결에 보낼 바이트를 만들어 준다(실측: 72 바이트).
            try self.flushDeferred(&w);
            if (consumed == before_consumed and self.state == before_state) break;
        }
        return .{
            .consumed = consumed,
            .wire = w.written(),
            .screen = s.written(),
            .control = c.written(),
            .state = self.state,
            .exit_status = self.exit_status,
            .exit_signal = if (self.exit_signal_len == 0) null else self.exit_signal_buf[0..self.exit_signal_len],
            .banner = if (self.banner_len == 0) null else self.banner_buf[0..self.banner_len],
            .disconnect = if (!self.disconnected) null else .{
                .reason = self.disconnect_reason,
                .description = self.disconnect_buf[0..self.disconnect_len],
            },
        };
    }

    /// 키 입력을 보낸다. `ready` 에서만 쓸 수 있다.
    ///
    /// **상대가 허락한 만큼만 나간다**(계약 §3.1). 다 못 보내면 보낸 만큼을 알려 주고, 호출자는
    /// 나머지를 다음에 다시 준다 — 넘겨 보내면 서버가 조용히 흘린다.
    pub fn write(self: *Client, data: []const u8, wire_out: []u8) Error!struct { wire: []const u8, sent: usize } {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return .{ .wire = wire_out[0..0], .sent = 0 };
        const room = self.ch.sendableLen();
        if (room == 0) return .{ .wire = wire_out[0..0], .sent = 0 };
        const n = @min(@as(usize, room), data.len);
        var buf: [packet.max_packet]u8 = undefined;
        const payload = try self.ch.writeData(&buf, data[0..n]);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return .{ .wire = w.written(), .sent = n };
    }

    /// **더 보낼 것이 없다**(§5.3). 원격 명령이 stdin 끝을 봐야 끝나는 경우에 필요하다
    /// (`cat`·`wc` 같은 것). **채널은 아직 열려 있다** — 반대 방향 출력은 계속 온다.
    pub fn eof(self: *Client, wire_out: []u8) Error![]const u8 {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return wire_out[0..0];
        // **이미 알렸거나 채널이 닫혔으면 할 일이 없다.** 오류가 아니다 — 보내는 동안 상대가
        // 먼저 닫을 수 있고(실측), 그때 EOF 를 못 보낸다고 세션을 실패로 만들 이유는 없다.
        if (self.ch.state != .open) return wire_out[0..0];
        var buf: [64]u8 = undefined;
        const payload = try self.ch.writeEof(&buf);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return w.written();
    }

    /// 터미널 크기가 바뀌었다(§6.7).
    pub fn resize(self: *Client, size: channel.TerminalSize, wire_out: []u8) Error![]const u8 {
        if (!self.shell_ready) return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return wire_out[0..0];
        var buf: [256]u8 = undefined;
        const payload = try self.ch.writeWindowChange(&buf, size);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return w.written();
    }

    /// **두 번째 채널을 연다** — 원격에서 명령 하나를 돌린다(계약 §4a: `maru control --stdio`).
    ///
    /// **터미널이 떠 있어야 부를 수 있다.** 인증도 안 끝난 자리에서 열 수는 없고, 무엇보다 이
    /// 채널은 "세션 목록을 보려 할 때" 열리는 것이라 그 시점에는 늘 셸이 있다.
    ///
    /// **pty 를 안 붙인다.** 붙이면 개행 변환·에코가 끼어 ndjson 이 깨진다(계약 §4a).
    pub fn openControl(self: *Client, command: []const u8, wire_out: []u8) Error![]const u8 {
        if (!self.shell_ready) return Error.NotReady;
        // **두 번 열지 않는다.** 이미 열려 있는데 또 열면 채널 번호가 겹쳐 두 흐름이 섞인다.
        if (self.control_state != .none and self.control_state != .closed) return Error.UnexpectedMessage;
        // **닫는 중인 번호도 다시 쓰지 않는다.** `close` 는 양쪽이 오가야 끝나는데(§5.3),
        // 우리 것만 보낸 자리에서 같은 번호로 새 채널을 열면 **상대의 늦은 `close` 가 새 채널로
        // 배달된다** — 방금 연 채널이 이유 없이 닫힌다(적대적 검증이 잡았다).
        if (self.control) |ctl| {
            if (ctl.state != .closed) return Error.UnexpectedMessage;
        }
        // **자르지 않는다** — 잘린 명령은 다른 명령이다.
        if (command.len > self.control_cmd_buf.len) return Error.ShortBuffer;
        if (!self.t.canSendChannelMessages()) return wire_out[0..0];

        @memcpy(self.control_cmd_buf[0..command.len], command);
        self.control_cmd_len = command.len;
        self.control_exit_status = null;
        self.control_stderr_len = 0;
        // **새 채널은 옛 채널의 뜻을 물려받지 않는다.** `control_deferred_close` 는 «그» 채널을
        // 닫으려던 뜻이다 — 남겨 두면 `flushDeferred` 가 **방금 연 채널**을 열리는 순간 닫는다.
        // 남을 수 있는 길이 둘이라 여기서 지운다(적대적 검증 1회차):
        //  · 열기가 거절되면 `self.control` 이 null 이 되는데, 그 플래그를 보는 자리는
        //    `if (self.control)` 안이라 **영영 안 접힌다**.
        //  · 닫힘이 미뤄진 채(`.wait`) 채널이 `.closed` 로 끝나면 그 자리에서 접히지만, 그 전에
        //    다시 열면 옛 뜻이 새 채널로 넘어간다.
        self.control_deferred_close = false;
        self.control_deferred_request_failure = false;
        // **터미널 옵션(`Options.window`)을 따르지 않는다** — 그 값은 화면 흐름을 위한 것이고,
        // 이 채널은 다른 성질(작은 줄이 자주)이다.
        var ctl: channel.Channel = .{
            .local_window = control_window,
            .local_window_max = control_window,
            .local_max_packet = control_max_packet,
        };
        var buf: [256]u8 = undefined;
        var w: Out = .{ .buf = wire_out };
        const payload = try ctl.writeOpen(&buf, control_local_id);
        try self.emit(&w, payload);
        self.control = ctl;
        self.control_state = .opening;
        return w.written();
    }

    /// 컨트롤 채널로 보낸다(ndjson 한 조각). 터미널의 `write` 와 같은 규칙 — **상대가 허락한
    /// 만큼만** 나가고, 나머지는 호출자가 다시 준다.
    pub fn writeControl(self: *Client, data: []const u8, wire_out: []u8) Error!struct { wire: []const u8, sent: usize } {
        if (self.control_state != .ready) return Error.NotReady;
        const ctl = if (self.control) |*p| p else return Error.NotReady;
        if (!self.t.canSendChannelMessages()) return .{ .wire = wire_out[0..0], .sent = 0 };
        const room = ctl.sendableLen();
        if (room == 0) return .{ .wire = wire_out[0..0], .sent = 0 };
        const n = @min(@as(usize, room), data.len);
        var buf: [packet.max_packet]u8 = undefined;
        const payload = try ctl.writeData(&buf, data[0..n]);
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, payload);
        return .{ .wire = w.written(), .sent = n };
    }

    /// 컨트롤 채널을 닫는다. **터미널은 그대로 산다.**
    ///
    /// **아직 «열리는 중» 인 채널도 닫을 수 있어야 한다.** `CHANNEL_CLOSE` 는 상대 번호를 실어야
    /// 하는데(§5.3) 그 번호는 `CHANNEL_OPEN_CONFIRMATION` 이 준다 — 그래서 확인 전에는 못 보낸다.
    /// 예전에는 그 자리에서 `writeClose` 가 `UnexpectedMessage` 로 튀어나갔고, **그 위에서 이미
    /// `control_state` 를 `.closed` 로 바꿔 둔 뒤**였다. 그러면 이렇게 된다:
    ///
    ///  · 우리는 「닫았다」고 믿는데 **원격 채널은 그대로 열린다** — 확인이 오고 exec 가 돌아
    ///    그 명령이 **고아로 영영 산다**(실기 2026-09-04: `maru attach --stream` 이 `sshd-session`
    ///    을 부모로 4분째 살아 registry 의 observer 자리를 붙들고 있었다).
    ///  · 그 뒤 모든 열기는 `self.control` 이 아직 차 있어 `NOT_READY` 가 되고, 5초 마감 뒤
    ///    포기한다 — 화면이 **영영 「받는 중」** 이다([§4a](../../../docs/control-plane.md)
    ///    「한 번에 control 하나」). 세션을 바꾸는 길이 통째로 막힌다.
    ///
    /// 그래서 **미룬다** — 재키잉과 같은 자리(`flushDeferred`)가 채널이 열리는 순간 낸다.
    /// 빠르게 여닫는 조작(열고 곧바로 뒤로)이 정확히 이 창을 만든다.
    pub fn closeControl(self: *Client, wire_out: []u8) Error![]const u8 {
        const ctl = if (self.control) |*p| p else return wire_out[0..0];
        self.control_state = .closed;
        if (ctl.state == .closed or ctl.state == .close_sent) return wire_out[0..0];
        // **보낼 수 있을 때만 보낸다.** 못 보내는 이유는 둘이고(재키잉·아직 안 열림) 답은 하나다.
        switch (ctl.closeDisposition()) {
            .done => return wire_out[0..0],
            .wait => {
                self.control_deferred_close = true;
                return wire_out[0..0];
            },
            .send => {},
        }
        // **자리가 모자라도 미룬다.** `writeClose` 는 부르는 순간 채널을 `.close_sent` 로 굳히므로,
        // 그 뒤 `emit` 이 실패하면 선에는 아무것도 안 나간 채 「보냈다」가 된다 — 그 닫힘은 영영
        // 안 나간다(적대적 검증 2회차).
        if (!self.t.canSendChannelMessages() or wire_out.len < max_channel_reply_packet) {
            // 재키잉 중이면 못 보낸다 — 미뤄 두면 `flushDeferred` 가 낸다.
            self.control_deferred_close = true;
            return wire_out[0..0];
        }
        var buf: [64]u8 = undefined;
        var w: Out = .{ .buf = wire_out };
        try self.emit(&w, try ctl.writeClose(&buf));
        return w.written();
    }

    /// 컨트롤 채널이 어디까지 왔나.
    pub fn controlState(self: Client) ControlState {
        return self.control_state;
    }

    /// 컨트롤 명령의 종료 코드. `127` 이면 그 서버에 `maru` 가 없다(계약 §4a).
    pub fn controlExitStatus(self: Client) ?u32 {
        return self.control_exit_status;
    }

    /// 컨트롤 명령이 stderr 로 낸 첫 조각(진단용). 비어 있을 수 있다.
    pub fn controlStderr(self: *const Client) []const u8 {
        return self.control_stderr_buf[0..self.control_stderr_len];
    }

    // ---- 안쪽 ----

    const Out = struct {
        buf: []u8,
        len: usize = 0,

        fn append(self: *Out, bytes: []const u8) Error!void {
            if (self.len + bytes.len > self.buf.len) return Error.ShortBuffer;
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        fn written(self: Out) []const u8 {
            return self.buf[0..self.len];
        }

        fn remaining(self: Out) usize {
            return self.buf.len - self.len;
        }
    };

    /// payload 하나를 전송기에 태워 선 바이트로 만든다.
    fn emit(self: *Client, w: *Out, payload: []const u8) Error!void {
        var buf: [packet.max_packet + 64]u8 = undefined;
        const n = try self.t.send(&buf, payload, self.rand);
        try w.append(buf[0..n]);
    }

    /// 한 걸음. 입력에서 먹을 수 있으면 먹고, 상태를 옮긴다.
    fn step(self: *Client, input: []const u8, consumed: *usize, w: *Out, s: *Out, c: *Out) Error!void {
        switch (self.state) {
            .idle => unreachable, // `feed` 가 입구에서 막는다
            // **닫힌 뒤에 온 것은 흘려보낸다.** 세션은 끝났고 그 바이트로 할 일이 없다 — 파싱하면
            // 오류가 나는데(예: 버전 줄), 끝난 연결에서 그것을 실패로 올릴 이유가 없다.
            .closed => {
                consumed.* += input.len;
                return;
            },
            .version_exchange => {
                const p = version.parse(input) catch |e| {
                    if (e == version.Error.Incomplete) return;
                    return e;
                };
                // **길이 검사가 필요 없다 — 구조가 보장한다.** 버퍼가 `version.max_line` 이고
                // `version.parse` 가 그보다 긴 줄을 `LineTooLong` 으로 이미 거절한다. 검사를
                // 두면 영영 안 도는 가지가 되고, 그런 가지는 변이 검사에서 살아남아 "구멍" 처럼
                // 보인다(적대적 검증에서 실제로 그렇게 보였다).
                @memcpy(self.v_s_buf[0..p.line.len], p.line);
                self.v_s_len = p.line.len;
                consumed.* += p.consumed;
                // 우리 KEXINIT 을 낸다. **원문을 보관한다**(교환 해시).
                const i_c = try kexinit.write(&self.i_c_buf, self.rand);
                self.i_c_len = i_c.len;
                try self.emit(w, i_c);
                self.state = .negotiating;
            },
            .host_key_decision => {
                if (!self.host_key_accepted) return; // 답을 기다린다 — 한 발도 안 나간다
                try self.afterHostKey(w);
            },
            else => try self.stepPacket(input, consumed, w, s, c),
        }
    }

    /// 패킷 하나를 꺼내 지금 상태에 맞게 다룬다.
    fn stepPacket(self: *Client, input: []const u8, consumed: *usize, w: *Out, s: *Out, c: *Out) Error!void {
        if (input.len == 0) return;
        var pkt: [packet.max_packet]u8 = undefined;
        const got = (self.t.feed(&pkt, input) catch |e| {
            if (e == packet.Error.Incomplete) return;
            return e;
        }) orelse return;
        switch (got) {
            .discarded => |d| {
                consumed.* += d.consumed;
                return;
            },
            .packet => |p| {
                consumed.* += p.consumed;
                // **시퀀스 번호를 같이 넘긴다** — 모르는 메시지에 답할 때 그 번호를 실어야 한다
                // (§11.4: "packet sequence number of rejected message").
                try self.dispatch(p.payload, p.seq, w, s, c);
            },
        }
    }

    fn dispatch(self: *Client, payload: []const u8, seq: u32, w: *Out, s: *Out, c: *Out) Error!void {
        const msg = payload[0];
        // **전송 계층 잡 메시지는 어느 상태에서나 온다**(계약 §3.2). 분류는 S7c 가 넓히고,
        // 여기서는 세션을 죽이지 않게만 다룬다.
        // **끊긴 이유를 담고 기계를 닫는다**(RFC 4253 §11.1).
        // **오류가 아니라 `Step` 으로 올린다.** 오류에는 값을 못 싣는 언어라, 오류로 올리면
        // 이유를 읽으려고 `feed` 를 한 번 더 불러야 한다 — 오류를 받고 멈춘 호출자는 **이유를
        // 영영 못 본다**. 끊긴 사실과 그 이유는 한 번에 와야 한다. 상태는 `closed` 로 가므로
        // (`onDisconnect` 안) 이것을 성공으로 오해할 자리는 없다.
        if (msg == msg_disconnect) {
            self.onDisconnect(payload) catch {};
            return;
        }
        // `IGNORE`·`DEBUG` 는 뜻이 없다(§11.2·§11.3). `UNIMPLEMENTED` 는 **우리가 보낸 것에 대한
        // 답**이라 여기서 할 일이 없다 — 우리는 모르는 메시지를 안 보낸다.
        //
        // **`DEBUG` 의 `always_display`(SHOULD)를 안 따르는 것은 결정이다**(계약 §3.2): 이 층에서
        // 화면으로 가는 길은 원격 셸 출력 하나뿐이라, 거기 끼워 넣으면 사용자가 서버 문자열과
        // 셸 출력을 구별할 수 없다.
        if (msg == msg_ignore or msg == msg_debug or msg == msg_unimplemented) return;
        if (msg == msg_global_request) return try self.onGlobalRequest(payload, w);

        // **우리가 아무 뜻도 없는 번호는 답하고 넘어간다**(§11.4 — MUST). 예전에는 채널을 여는
        // 중일 때만 그랬는데, 그러면 인증 중에 온 확장 하나가 세션을 죽인다. 서버는 OpenSSH 만
        // 있는 것이 아니고, 모르는 번호 하나로 못 붙는 서버가 생기는 것이 훨씬 나쁘다.
        //
        // **초기 키 교환 중에는 예외로 끊는다.** strict KEX(draft §3.2)는 그 사이의 예상 밖
        // 패킷에 연결을 끊으라고 요구한다 — 여기서 답하고 살아 있으면 그 요구를 어긴다.
        //
        // **재키잉은 여기 안 든다.** 그때 상태는 `ready` 이고, 재키잉 중에도 상대의 패킷은
        // 정상적으로 온다(우리 `KEXINIT` 이 닿기 전에 떠난 것들이다). `UNIMPLEMENTED` 는
        // 3 번이라 §7.1 이 재키잉 중에도 허용하므로 그대로 답한다.
        if (!recognizedMessage(msg)) {
            switch (self.state) {
                .version_exchange, .negotiating, .key_exchange, .awaiting_new_keys, .host_key_decision => {
                    return Error.UnexpectedMessage;
                },
                else => return self.emit(w, &unimplemented(seq)),
            }
        }

        // **배너는 어느 상태에서나 온다** — RFC 4252 §5.4 는 "at any time after this
        // authentication protocol starts and before authentication is successful" 라고 못박는다.
        //
        // 예전에는 `authenticating` 에서만 받았고, 그러면 `requesting_service`(SERVICE_ACCEPT 를
        // 기다리는 사이)에 온 배너가 `UnexpectedMessage` 로 **세션을 죽인다**. **OpenSSH 는 그
        // 자리에서 안 보낸다**(실측 — 배너를 켠 sshd 로 확인했고 옛 코드도 통과했다). 즉 이것은
        // 명세가 허락하는데 우리가 안 받던 자리이지, OpenSSH 에서 재현된 결함은 아니다.
        // 그래도 받는다: 비용이 한 줄이고 서버는 OpenSSH 만 있는 것이 아니다.
        if (msg == userauth.msg_userauth_banner) return self.onBanner(payload);

        // **서버가 재키잉을 요구했다**(계약 §3.0.1). 어느 상태에서나 올 수 있다.
        if (msg == kexinit.msg_kexinit and self.state != .negotiating) return self.beginRekey(payload, w);

        switch (self.state) {
            .negotiating => try self.onKexInit(payload, w),
            .key_exchange => try self.onKexReply(payload, w),
            .awaiting_new_keys => try self.onNewKeys(payload, w),
            .requesting_service => {
                try userauth.parseServiceAccept(payload);
                try self.sendAuth(w);
            },
            .authenticating => try self.onAuthResponse(payload, w),
            .opening_channel, .requesting_pty, .starting_shell, .ready => try self.onChannel(payload, seq, w, s, c),
            else => return Error.UnexpectedMessage,
        }
    }

    fn onKexInit(self: *Client, payload: []const u8, w: *Out) Error!void {
        if (payload.len > self.i_s_buf.len) return Error.ShortBuffer;
        @memcpy(self.i_s_buf[0..payload.len], payload);
        self.i_s_len = payload.len;
        const peer = try kexinit.parse(self.i_s_buf[0..self.i_s_len]);
        const neg = try kexinit.negotiate(peer, .initial);
        self.strict_kex_initial = neg.strict_kex;
        try self.t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

        var seed: [32]u8 = undefined;
        self.rand.bytes(&seed);
        self.eph = try kex.Ephemeral.fromSeed(seed);
        var buf: [128]u8 = undefined;
        try self.emit(w, try kex.writeInit(&buf, self.eph.?.public));
        self.state = .key_exchange;
    }

    fn onKexReply(self: *Client, payload: []const u8, w: *Out) Error!void {
        const reply = try kex.parseReply(payload);
        // **재키잉에서 키가 바뀌면 여기서 끊는다 — 보관하기 전에 본다.**
        //
        // 예전에는 아래에서 "지문이 바뀌었으면 서명 검증이 이미 실패한다" 고 적어 두고 그냥
        // 넘어갔는데, **그 말이 틀렸다**: `verifyExchangeHash` 는 *제시된* 키로 서명을 확인하므로
        // 공격자가 고른 다른 키도 그대로 통과한다. 그러면 사용자에게 보여 준 지문과 지금 세션의
        // 상대가 달라지고, TOFU 가 약속한 것이 정확히 그 동일성이다.
        //
        // 비교를 **보관보다 먼저** 두는 것이 요점이다. 먼저 덮어쓰면 비교할 원본이 사라진다.
        if (self.rekeying and !std.mem.eql(u8, self.host_key_buf[0..self.host_key_len], reply.host_key)) {
            return Error.HostKeyChanged;
        }
        if (reply.host_key.len > self.host_key_buf.len) return Error.ShortBuffer;
        @memcpy(self.host_key_buf[0..reply.host_key.len], reply.host_key);
        self.host_key_len = reply.host_key.len;

        self.k = try self.eph.?.sharedSecret(reply.q_s);
        self.h = try kex.exchangeHash(.{
            .v_c = self.v_c_buf[0..self.v_c_len],
            .v_s = self.v_s_buf[0..self.v_s_len],
            .i_c = self.i_c_buf[0..self.i_c_len],
            .i_s = self.i_s_buf[0..self.i_s_len],
            .k_s = reply.host_key,
            .q_c = &self.eph.?.public,
            .q_s = reply.q_s,
            .k = self.k,
        });
        // **서명부터 본다.** 서명이 안 맞으면 지문을 보여 줄 이유도 없다 — 그 지문은 서버 것이
        // 아닐 수 있다.
        try hostkey.verifyExchangeHash(reply.host_key, reply.signature, &self.h);
        if (self.rekeying) {
            // 재키잉에서는 다시 묻지 않는다 — **키가 그대로임을 위에서 이미 확인했다**(바뀌었으면
            // `HostKeyChanged` 로 끊었다). 사용자에게 같은 지문을 또 보여 줄 이유가 없다.
            return self.afterHostKey(w);
        }
        self.session_id = self.h;
        // **여기서 멈춘다**(계약 §4 — 자동 승인은 없다).
        self.state = .host_key_decision;
    }

    /// 호스트키가 승인된 뒤 — `NEWKEYS` 를 보낸다.
    ///
    /// **키는 상대 `NEWKEYS` 를 받을 때 양쪽 다 켠다.** RFC 4253 §7.3 은 보내는 쪽을 우리
    /// `NEWKEYS` **직후**에 바꾸라고 하는데, 우리는 그 사이에 **아무것도 안 보내므로** 결과가
    /// 같다. 그 불변이 깨지면(그 창에서 무엇이든 보내면) 옛 키로 나가고 strict KEX 의 시퀀스
    /// 리셋도 어긋난다 — 아래 테스트가 그 창을 지킨다.
    fn afterHostKey(self: *Client, w: *Out) Error!void {
        try self.emit(w, &[_]u8{msg_newkeys});
        self.state = .awaiting_new_keys;
    }

    fn onNewKeys(self: *Client, payload: []const u8, w: *Out) Error!void {
        if (payload[0] != msg_newkeys) return Error.UnexpectedMessage;
        var key_c2s: [64]u8 = undefined;
        var key_s2c: [64]u8 = undefined;
        try kex.deriveKey(&key_c2s, self.k, self.h, .enc_c2s, &self.session_id);
        try kex.deriveKey(&key_s2c, self.k, self.h, .enc_s2c, &self.session_id);
        var cs = cipher.Cipher.initMove(&key_c2s);
        var cr = cipher.Cipher.initMove(&key_s2c);
        try self.t.enableSendKeys(&cs);
        try self.t.enableRecvKeys(&cr);
        if (self.eph) |*e| e.clear();
        self.eph = null;

        if (self.rekeying) {
            self.rekeying = false;
            self.rekeys += 1;
            try self.flushDeferred(w);
            self.state = .ready;
            return;
        }
        var buf: [64]u8 = undefined;
        try self.emit(w, try userauth.writeServiceRequest(&buf));
        self.state = .requesting_service;
    }

    fn sendAuth(self: *Client, w: *Out) Error!void {
        var req: [1024]u8 = undefined;
        const secret = self.opts.secret_key orelse {
            // **키가 없으면 `none` 으로 묻는다**(§5.2). 이 요청은 실패하는 것이 정상이고, 그
            // 실패에 실려 오는 **방법 목록**이 목적이다 — 그것 없이는 비밀번호를 물을지조차 모른다.
            self.auth_method = .none;
            try self.emit(w, try userauth.writeNoneRequest(&req, self.opts.user));
            self.state = .authenticating;
            return;
        };
        var kb: [128]u8 = undefined;
        const key_blob = try userauth.publicKeyBlob(&kb, secret);
        var sd: [512]u8 = undefined;
        const signed = try userauth.signedData(&sd, &self.session_id, self.opts.user, key_blob);
        var sig: [128]u8 = undefined;
        const sig_blob = try userauth.signBlob(&sig, secret, signed);
        try self.emit(w, try userauth.writePublicKeyRequest(&req, self.opts.user, key_blob, sig_blob));
        self.state = .authenticating;
    }

    /// 이 번호에 우리가 뜻을 두고 있나. **아니면 `UNIMPLEMENTED` 로 답할 대상이다**(§11.4).
    ///
    /// "이 자리에 맞나" 가 아니라 "번호를 아나" 다 — 아는 번호가 엉뚱한 자리에 오면 그것은
    /// 규약 위반이라 오류로 올려야 하고, 모르는 번호는 그냥 확장이라 답하고 넘어가야 한다.
    fn recognizedMessage(msg: u8) bool {
        return switch (msg) {
            1...6 => true, // DISCONNECT·IGNORE·UNIMPLEMENTED·DEBUG·SERVICE_REQUEST/ACCEPT
            20, 21 => true, // KEXINIT·NEWKEYS
            30, 31 => true, // KEX 방법별(ECDH init/reply)
            50...53, 60 => true, // USERAUTH 계열
            80...82 => true, // GLOBAL_REQUEST·REQUEST_SUCCESS/FAILURE
            90...100 => true, // 채널 계열
            else => false,
        };
    }

    /// 모르는 메시지에 대한 답(§11.4). **거절한 메시지의 시퀀스 번호를 싣는다.**
    fn unimplemented(seq: u32) [5]u8 {
        var out: [5]u8 = undefined;
        out[0] = msg_unimplemented;
        std.mem.writeInt(u32, out[1..5], seq, .big);
        return out;
    }

    /// 전역 요청(RFC 4254 §4). **`want_reply` 면 답해야 한다** — 안 답하면 서버가 기다린다.
    ///
    /// **실측(OpenSSH 10.2)**: 인증 직후 `hostkeys-00@openssh.com` 을 보내는데 `want_reply` 는
    /// **0** 이다. 즉 답하는 가지는 OpenSSH 로는 안 돈다 — 서버 keepalive 도 전역이 아니라
    /// *채널* 요청(`keepalive@openssh.com`, confirm 1)으로 오고 그쪽은 채널 층이 답한다.
    /// 그래도 답을 구현한다: §4 가 `want_reply` 를 정의해 뒀고, 안 답하면 그렇게 보내는 서버에
    /// 매달린 채로 멈추기 때문이다.
    fn onGlobalRequest(self: *Client, payload: []const u8, w: *Out) Error!void {
        var r = wire.Reader.init(payload);
        _ = try r.byte();
        _ = try r.string(); // 요청 이름 — 우리가 아는 것이 없다
        const want_reply = try r.boolean();
        if (!want_reply) return;
        // **우리는 어떤 전역 요청도 안 받는다**(포트 포워딩을 안 하므로). 실패로 답한다.
        //
        // 단, **지금 보낼 수 있을 때만 지금 보낸다.** `REQUEST_FAILURE` 는 82 번이라 재키잉 중에는
        // 금지된 번호이고(§7.1 은 1~49 만 허용), 그대로 보내면 전송기가 우리 쪽을 poison 해
        // **답 하나 때문에 세션이 죽는다**(실측: 테스트가 `NotAllowedDuringRekey` 로 죽었다).
        // 서버의 요청은 우리 `KEXINIT` 이 닿기 전에 떠난 것일 수 있어 이 겹침은 정상이므로,
        // §7.1 이 말한 대로 줄 세웠다가 뒤에 보낸다.
        if (!self.t.canSendChannelMessages()) {
            // 포화시킨다. 재키잉 중에 요청을 쏟아부어도 세는 값이 감싸 돌지 않는다.
            if (self.pending_request_failures < std.math.maxInt(u8)) self.pending_request_failures += 1;
            return;
        }
        try self.emit(w, &[_]u8{msg_request_failure});
    }

    /// 끊긴 이유를 담는다(§11.1). **설명은 걸러서** 담는다 — 서버가 고른 문자열이다.
    fn onDisconnect(self: *Client, payload: []const u8) Error!void {
        var r = wire.Reader.init(payload);
        _ = try r.byte();
        self.disconnect_reason = @enumFromInt(try r.u32be());
        const desc = try r.string();
        const clean = userauth.sanitizeBanner(&self.disconnect_buf, desc) catch {
            self.disconnect_len = 0;
            self.disconnected = true;
            self.closeMachine();
            return;
        };
        self.disconnect_len = clean.len;
        self.disconnected = true;
        self.closeMachine();
    }

    /// **연결을 끝내는 주체는 우리다.** 이유만 실어 주고 기계를 살려 두면, 상태를 안 보는
    /// 드라이버가 그 뒤에도 먹이고 쓸 수 있고 그러면 끝난 연결에 바이트를 짜 넣는다
    /// (RFC 4253 §11.1 은 이 메시지 뒤에 연결을 끝내라고 한다).
    fn closeMachine(self: *Client) void {
        self.state = .closed;
        self.shell_ready = false;
        // **미뤄 둔 것도 같이 버린다.** 연결이 끝났는데 큐가 남아 있으면 그 다음 `feed` 가 끝난
        // 연결에 보낼 바이트를 만들어 준다 — 드라이버는 그것을 닫힌 소켓에 쓰고 EPIPE 를 보며,
        // 증상이 "서버가 끊었다" 가 아니라 "쓰기 실패" 로 보인다(실측: 72 바이트가 나갔다).
        self.pending_request_failures = 0;
        self.deferred_request_failure = false;
        self.deferred_close = false;
        self.ch.state = .closed; // 윈도 보충도 여기서 멎는다
    }

    /// 배너를 걸러 보관한다. **거르는 것이 계약이다**(§4.4.2) — 서버가 고른 문자열이 그대로
    /// 화면에 가면 OSC 0/2·52 로 창 제목을 바꾸고 클립보드에 쓴다. 이 층이 표시를 모르므로
    /// **여기서 걸러 두고** 호출자에게는 안전한 것만 준다.
    fn onBanner(self: *Client, payload: []const u8) Error!void {
        var r = wire.Reader.init(payload);
        _ = try r.byte();
        const message = try r.string();
        const clean = userauth.sanitizeBanner(&self.banner_buf, message) catch {
            // 너무 길면 버린다 — 배너 때문에 세션을 죽일 이유는 없다.
            self.banner_len = 0;
            return;
        };
        self.banner_len = clean.len;
    }

    fn onAuthResponse(self: *Client, payload: []const u8, w: *Out) Error!void {
        // **어느 방식의 답인지는 우리가 안다** — 방금 보낸 것이 그것이다. 키를 보내 놓고
        // `password` 로 파싱하면 서버의 `PK_OK`(§7)를 비밀번호 변경 요구(§8)로 읽는다.
        switch (try userauth.parseResponse(payload, self.auth_method)) {
            .success => {
                var buf: [256]u8 = undefined;
                try self.emit(w, try self.ch.writeOpen(&buf, 0));
                self.state = .opening_channel;
            },
            .banner => {}, // 위 `onBanner` 가 이미 처리한다(여기 오지 않는다)
            // **§7 과 §8 은 같은 번호(60)를 다르게 읽는다** — 무엇을 보냈는지(`auth_method`)가
            // 그 둘을 가른다. 비밀번호 쪽은 "바꿔야 한다" 이므로 이름 있는 오류로 올린다.
            .passwd_change_req => return Error.PasswordChangeRequired,
            .failure => |f| {
                // **서버가 무엇을 열어 뒀는지 여기 적혀 있다**(RFC 4252 §5.1 — 계속 시도할 수
                // 있는 방법 목록). 키가 거절됐어도 `password` 가 있으면 아직 길이 남아 있다 —
                // 그걸 안 보고 끝내면 **서버가 열어 둔 문 앞에서 돌아서는** 셈이다.
                //
                // 비밀번호를 이미 한 번 보냈으면 다시 묻지 않는다. 서버는 틀린 비밀번호에도
                // 같은 목록을 돌려주므로(§5.1), 그대로 두면 무한히 되묻는 고리가 된다.
                if (!self.password_tried and f.methods.has(userauth.method_password)) {
                    self.state = .password_needed;
                    return;
                }
                return Error.AuthFailed;
            },
            else => return Error.UnexpectedMessage,
        }
    }

    /// 채널 메시지가 말하는 **받는 쪽 채널 번호**(§5 — 모든 `CHANNEL_*` 메시지의 첫 필드).
    /// 채널 메시지가 아니거나 너무 짧으면 `null` 이다.
    ///
    /// **여기가 다채널의 전부다.** 채널 구조체는 자기 번호가 아닌 메시지를 거절하므로, 고르는
    /// 일만 정확하면 나머지는 각 채널이 스스로 지킨다.
    fn recipientOf(payload: []const u8) ?u32 {
        if (payload.len < 5) return null;
        switch (payload[0]) {
            channel.msg_channel_open_confirmation,
            channel.msg_channel_open_failure,
            channel.msg_channel_window_adjust,
            channel.msg_channel_data,
            channel.msg_channel_extended_data,
            channel.msg_channel_eof,
            channel.msg_channel_close,
            channel.msg_channel_request,
            channel.msg_channel_success,
            channel.msg_channel_failure,
            => {},
            else => return null,
        }
        return std.mem.readInt(u32, payload[1..5], .big);
    }

    fn onChannel(self: *Client, payload: []const u8, seq: u32, w: *Out, s: *Out, c: *Out) Error!void {
        // **서버가 채널을 열자고 하면 제대로 거절한다**(§5.1). 우리는 `session` 말고는 안 열지만
        // (계약 §3), 서버는 `x11`·`forwarded-tcpip`·`auth-agent@openssh.com` 을 열자고 할 수 있다.
        // 예전에는 이 메시지가 "모르는 것" 으로 흘러 `UNIMPLEMENTED` 를 받았는데, 그것은 모르는
        // **메시지 번호**용이라 상대는 답을 못 받은 셈이 되어 **열지도 닫지도 못한 채널을 붙든다**.
        if (payload.len > 0 and payload[0] == channel.msg_channel_open) {
            var buf: [128]u8 = undefined;
            const sender = channel.readOpenSender(payload) catch return;
            try self.emit(w, try channel.writeOpenFailure(&buf, sender, .unknown_channel_type));
            return;
        }
        if (recipientOf(payload)) |id| {
            if (id == control_local_id) return self.onControlChannel(payload, w, c);
        }
        var buf: [1024]u8 = undefined;
        // **채널 메시지가 아니면 `UNIMPLEMENTED` 로 답한다**(§11.4 — MUST). 끊으면 안 된다:
        // 서버가 우리가 모르는 확장을 하나 보냈다고 세션이 죽으면, 그 서버에는 영영 못 붙는다.
        const ev = self.ch.receive(payload) catch |e| {
            if (e != channel.Error.NotChannelMessage) return e;
            try self.emit(w, &unimplemented(seq));
            return;
        };
        switch (ev) {
            .opened => {
                if (self.opts.pty) {
                    try self.emit(w, try self.ch.writePtyReq(&buf, self.opts.term, self.opts.size, ""));
                    self.state = .requesting_pty;
                } else {
                    try self.emit(w, try self.ch.writeShell(&buf));
                    self.state = .starting_shell;
                }
            },
            .open_failed => return Error.ChannelRefused,
            .request_success => switch (self.state) {
                .requesting_pty => {
                    try self.emit(w, try self.ch.writeShell(&buf));
                    self.state = .starting_shell;
                },
                .starting_shell => {
                    self.state = .ready;
                    self.shell_ready = true;
                },
                else => {},
            },
            .request_failure => return Error.RequestFailed,
            .data => |d| try s.append(d),
            .extended_data => |x| try s.append(x.data),
            .exit_status => |code| self.exit_status = code,
            .exit_signal => |sig| {
                const n = @min(sig.name.len, self.exit_signal_buf.len);
                @memcpy(self.exit_signal_buf[0..n], sig.name[0..n]);
                self.exit_signal_len = n;
            },
            .eof => {},
            .closed => {
                self.deferred_close = true;
                // **세션은 마지막 채널이 닫혀야 닫힌다**(RFC 4254 §5 — 채널은 서로 독립이다).
                // 예전에는 여기서 바로 `closed` 로 갔는데, 채널이 둘이 되면 그 규칙은 **중계
                // 프로세스가 끝나는 순간 터미널까지 죽이는** 규칙이 된다(계약 §4a 가 이 결함을
                // 적어 뒀다). 터미널이 먼저 끝났으면 남은 컨트롤 채널도 닫으라고 이르고,
                // 세션을 닫는 것은 둘 다 닫힌 뒤다.
                if (self.control_state == .opening or self.control_state == .requesting_exec or self.control_state == .ready) {
                    self.control_deferred_close = true;
                }
                self.shell_closed = true;
                self.closeIfLastChannelGone();
            },
            .window_adjusted => {},
            // **`want_reply` 면 답해야 한다**(§5.4 — "If the request is not recognized ...
            // SSH_MSG_CHANNEL_FAILURE is returned"). 안 답하면 서버가 기다린다 — OpenSSH 는
            // `keepalive@openssh.com` 을 그렇게 보내고, 답이 없으면 연결이 죽은 것으로 본다.
            .unknown_request => |u| if (u.want_reply) {
                self.deferred_request_failure = true;
            },
        }
        try self.flushDeferred(w);
    }

    /// 컨트롤 채널로 온 메시지. **터미널과 다른 규칙으로 산다** — pty 도 셸도 없고, 여기서
    /// 무슨 일이 나도 `State` 는 안 건드린다(터미널이 그 값을 쓴다).
    fn onControlChannel(self: *Client, payload: []const u8, w: *Out, c: *Out) Error!void {
        // 우리 번호로 왔는데 채널이 없다 — 열지도 않은 채널에 온 메시지다(§5 위반).
        const ch = if (self.control) |*ctl| ctl else return Error.UnexpectedMessage;
        var buf: [max_control_command + 64]u8 = undefined;
        const ev = ch.receive(payload) catch |e| {
            // 컨트롤 채널의 모르는 메시지는 **세션을 죽일 이유가 안 된다**. 터미널 쪽은 seq 를
            // 받아 `UNIMPLEMENTED` 로 답하지만, 그 답은 전송 계층의 일이라 여기서 또 하지 않는다.
            if (e != channel.Error.NotChannelMessage) return e;
            return;
        };
        switch (ev) {
            // **닫기로 정했으면 명령을 시작조차 안 한다.** 그 뜻은 이미 `control_deferred_close` 에
            // 있고, 여기서 `exec` 을 보내면 그 서버에서 명령이 한 번 돌고(감사 로그에 남는다) 그
            // 답이 우리가 닫은 뒤에 도착한다. 곧바로 `flushDeferred` 가 닫는다.
            .opened => if (!self.control_deferred_close) {
                self.control_state = .requesting_exec;
                try self.emit(w, try ch.writeExec(&buf, self.control_cmd_buf[0..self.control_cmd_len]));
            },
            // **열기 거절도 세션을 안 죽인다.** 서버가 채널 수를 제한할 수 있고(§5.1), 그때
            // 터미널까지 잃을 이유가 없다 — 컨트롤 축만 끄고 화면이 그렇게 말한다(계약 §4a).
            .open_failed => {
                self.control_state = .closed;
                self.control = null;
                // **슬롯을 비우면 그 채널을 향한 뜻도 함께 비운다.** 아래 `flushDeferred` 는
                // `if (self.control)` 안에서만 이 플래그를 보므로, 남기면 접힐 자리가 없다.
                self.control_deferred_close = false;
                self.control_deferred_request_failure = false;
            },
            // **닫기로 정한 축을 답이 되살리지 않는다.** `closeControl` 이 이미 `.closed` 로
            // 정했는데 늦게 온 `SUCCESS` 가 `.ready` 로 되돌리면, host 는 살아 있는 채널로 알고
            // 그 위에 쓴다.
            .request_success => if (self.control_state != .closed) {
                self.control_state = .ready;
            },
            // `exec` 이 거절됐다 — 명령을 시작조차 못 했다. 채널을 닫고 축을 끈다.
            .request_failure => {
                self.control_state = .closed;
                self.control_deferred_close = true;
            },
            // **닫는 중에 온 데이터는 버린다.** `close` 를 보낸 뒤에도 상대는 아직 모르고 보낼
            // 수 있다(§5.3). 그때 호출자는 이미 컨트롤 버퍼를 놓아줬을 수 있으므로 담으려 들면
            // `ShortBuffer` 로 세션이 죽는다 — 받을 사람이 없는 바이트다.
            .data => |d| if (self.control_state != .closed) try c.append(d),
            // **stderr 는 wire 가 아니다**(계약 §4a). 화면에도 안 섞고 컨트롤 흐름에도 안 섞는다 —
            // 진단으로 앞부분만 남긴다.
            .extended_data => |x| self.appendControlStderr(x.data),
            .exit_status => |code| self.control_exit_status = code,
            .exit_signal => {},
            .eof => {},
            .closed => {
                self.control_deferred_close = true;
                self.control_state = .closed;
                self.closeIfLastChannelGone();
            },
            .window_adjusted => {},
            .unknown_request => |u| if (u.want_reply) {
                self.control_deferred_request_failure = true;
            },
        }
        try self.flushDeferred(w);
    }

    /// stderr 첫 조각을 남긴다. **앞을 남기고 뒤를 버린다** — 첫 줄이 대개 원인이다.
    fn appendControlStderr(self: *Client, data: []const u8) void {
        const room = self.control_stderr_buf.len - self.control_stderr_len;
        if (room == 0) return;
        const n = @min(room, data.len);
        @memcpy(self.control_stderr_buf[self.control_stderr_len..][0..n], data[0..n]);
        self.control_stderr_len += n;
    }

    /// 컨트롤 채널이 아직 살아 있나(버퍼를 요구할 자격이 있나).
    fn controlAlive(self: Client) bool {
        if (self.control == null) return false;
        return switch (self.control_state) {
            .none, .closed => false,
            .opening, .requesting_exec, .ready => true,
        };
    }

    /// **세션은 마지막 채널이 닫혀야 닫힌다.** 터미널이 살아 있으면 컨트롤이 끝나도 세션은 산다.
    fn closeIfLastChannelGone(self: *Client) void {
        if (!self.shell_closed) return;
        switch (self.control_state) {
            .none, .closed => self.state = .closed,
            .opening, .requesting_exec, .ready => {},
        }
    }

    /// 미뤄 둔 채널 송신과 흐름 제어 보충. **재키잉 중에는 아무것도 안 보낸다**(계약 §3.0.1).
    fn flushDeferred(self: *Client, w: *Out) Error!void {
        if (!self.t.canSendChannelMessages()) return;
        var buf: [256]u8 = undefined;
        // 재키잉 때문에 미뤄 둔 전역 요청 답(§7.1). **미뤄 둔 것은 한 자리에서 나간다** —
        // 내보내는 자리가 둘이면 하나가 조용히 안 도는 상태가 생긴다.
        while (self.pending_request_failures > 0) {
            if (w.remaining() < max_reply_packet) break; // 자리가 없으면 다음 `feed` 에서
            try self.emit(w, &[_]u8{msg_request_failure});
            self.pending_request_failures -= 1;
        }
        // **뜻은 «나간 뒤에» 지운다.** 먼저 지우고 보내면 `emit` 이 `ShortBuffer` 로 튀는 순간
        // 그 뜻이 통째로 사라진다 — 다음 `feed` 가 다시 낼 근거가 없다. 이 축의 결함이 정확히
        // 그 모양이었다(적대적 검증 2회차: 내가 방금 고친 것과 같은 모양이 바로 옆에 있었다).
        if (self.deferred_request_failure and w.remaining() >= max_channel_reply_packet) {
            try self.emit(w, try self.ch.writeChannelFailure(&buf));
            self.deferred_request_failure = false;
        }
        if (self.deferred_close) switch (self.ch.closeDisposition()) {
            .done => self.deferred_close = false,
            .wait => {},
            .send => if (w.remaining() >= max_channel_reply_packet) {
                try self.emit(w, try self.ch.writeClose(&buf));
                self.deferred_close = false;
            },
        };
        if (self.ch.pendingWindowAdjust() != 0) {
            try self.emit(w, try self.ch.writeWindowAdjust(&buf));
        }
        // **컨트롤 채널도 같은 자리에서 비운다.** 내보내는 자리를 나누면 한쪽이 조용히 안 도는
        // 상태가 생긴다 — 터미널 쪽이 이미 그 이유로 한 자리에 모여 있다.
        if (self.control) |*ctl| {
            if (self.control_deferred_request_failure and w.remaining() >= max_channel_reply_packet) {
                try self.emit(w, try ctl.writeChannelFailure(&buf));
                self.control_deferred_request_failure = false;
            }
            // **아직 못 닫으면 플래그를 그대로 둔다.** 예전에는 먼저 지우고 `writeClose` 를 불러,
            // 채널이 아직 열리는 중이면 그 오류와 함께 **닫으려던 뜻이 사라졌다**(그리고 원격
            // 명령이 고아로 남았다 — `closeControl` 주석). `.wait` 면 다음 `feed` 에 다시 온다.
            if (self.control_deferred_close) switch (ctl.closeDisposition()) {
                .done => self.control_deferred_close = false, // 낼 것이 없다 — 뜻을 접는다
                .wait => {}, // 아직 번호가 없다 — 그대로 들고 있는다
                .send => if (w.remaining() >= max_channel_reply_packet) {
                    try self.emit(w, try ctl.writeClose(&buf));
                    self.control_deferred_close = false;
                },
            };
            if (ctl.pendingWindowAdjust() != 0) {
                try self.emit(w, try ctl.writeWindowAdjust(&buf));
            }
        }
    }

    /// 서버가 `KEXINIT` 을 다시 보냈다 — 재키잉을 시작한다(계약 §3.0.1).
    fn beginRekey(self: *Client, i_s: []const u8, w: *Out) Error!void {
        if (i_s.len > self.i_s_buf.len) return Error.ShortBuffer;
        @memcpy(self.i_s_buf[0..i_s.len], i_s);
        self.i_s_len = i_s.len;

        try self.t.beginRekey();
        self.rekeying = true;
        const i_c = try kexinit.write(&self.i_c_buf, self.rand);
        self.i_c_len = i_c.len;
        try self.emit(w, i_c);

        const peer = try kexinit.parse(self.i_s_buf[0..self.i_s_len]);
        const neg = try kexinit.negotiate(peer, .{ .rekey = self.strict_kex_initial });
        try self.t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

        var seed: [32]u8 = undefined;
        self.rand.bytes(&seed);
        self.eph = try kex.Ephemeral.fromSeed(seed);
        var buf: [128]u8 = undefined;
        try self.emit(w, try kex.writeInit(&buf, self.eph.?.public));
        self.state = .key_exchange;
    }
};

const msg_disconnect: u8 = 1;
const msg_ignore: u8 = 2;
const msg_unimplemented: u8 = 3;
const msg_debug: u8 = 4;
const msg_newkeys: u8 = 21;
const msg_global_request: u8 = 80;
const msg_request_failure: u8 = 82;

const testing = std.testing;

test "상수는 RFC 4253 §12 그대로다" {
    try testing.expectEqual(@as(u8, 1), msg_disconnect);
    try testing.expectEqual(@as(u8, 2), msg_ignore);
    try testing.expectEqual(@as(u8, 3), msg_unimplemented);
    try testing.expectEqual(@as(u8, 4), msg_debug);
    try testing.expectEqual(@as(u8, 21), msg_newkeys);
    try testing.expectEqual(@as(u8, 80), msg_global_request);
}

test "시작하면 버전 줄을 내고 서버 것을 기다린다" {
    var prng = std.Random.DefaultPrng.init(1);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [256]u8 = undefined;
    const line = try c.start(&out);
    try testing.expect(std.mem.startsWith(u8, line, "SSH-2.0-maru_"));
    try testing.expect(std.mem.endsWith(u8, line, "\r\n"));
    try testing.expectEqual(State.version_exchange, c.state);

    // 두 번 부르면 안 된다.
    try testing.expectError(Error.UnexpectedMessage, c.start(&out));
}

test "서버 버전 줄을 받으면 KEXINIT 을 낸다" {
    var prng = std.Random.DefaultPrng.init(2);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);

    // **배너가 앞에 와도 된다**(계약 §3.2.2).
    const input = "hello banner\r\nSSH-2.0-OpenSSH_10.2\r\n";
    const step = try c.feed(input, &out, &screen);
    try testing.expectEqual(input.len, step.consumed);
    try testing.expectEqual(State.negotiating, step.state);
    try testing.expect(step.wire.len > 0);

    // 낸 것이 KEXINIT 패킷이다.
    const dec = try packet.read(step.wire);
    try testing.expectEqual(kexinit.msg_kexinit, dec.payload[0]);
}

test "불완전한 입력은 먹지 않고 돌아온다" {
    // **막지 않는 것이 요점이다**(모바일 §3 — host 가 밀어 넣는다). 다 안 왔으면 0 을 소비하고
    // 돌아와야 호출자가 더 읽어 올 수 있다.
    var prng = std.Random.DefaultPrng.init(3);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);

    const step = try c.feed("SSH-2.0-Open", &out, &screen);
    try testing.expectEqual(@as(usize, 0), step.consumed);
    try testing.expectEqual(State.version_exchange, step.state);
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "제어문자가 든 버전 줄은 거절한다" {
    // 계약 §3.2.2 — 그 줄은 아직 아무것도 검증 안 된 상대가 보낸 것이고 TOFU 프롬프트에 그대로
    // 올라간다. 드라이버가 오류를 삼키면 그 방어가 안 보인다(검증 도구에서 그렇게 겪었다).
    var prng = std.Random.DefaultPrng.init(4);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [8192]u8 = undefined;
    var screen: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    try testing.expectError(
        version.Error.MalformedVersion,
        c.feed("SSH-2.0-evil\x1b]0;pwned\x07\r\n", &out, &screen),
    );
}

test "ready 가 아니면 쓰지 못한다" {
    var prng = std.Random.DefaultPrng.init(5);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    var out: [256]u8 = undefined;
    try testing.expectError(Error.NotReady, c.write("ls\n", &out));
    try testing.expectError(Error.NotReady, c.resize(.{ .cols = 100, .rows = 40 }, &out));
}

test "clear 는 비밀을 지운다" {
    var prng = std.Random.DefaultPrng.init(6);
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(9),
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.k = @splat(7);
    c.clear();
    try testing.expect(std.mem.allEqual(u8, &c.k, 0));
    try testing.expect(std.mem.allEqual(u8, &c.opts.secret_key.?, 0));
}

/// 셸이 뜬 클라이언트를 만든다 — 채널 사건만 시험하려는 테스트용.
///
/// **전송기를 평문으로 둔다.** 암호를 붙이면 이 테스트가 KEX 를 다시 짜야 하는데, 여기서 보려는
/// 것은 채널 사건 처리이지 암호가 아니다.
/// 테스트용 난수. **함수 안의 `var prng` 를 쓰면 안 된다** — `Client` 는 `std.Random`(그 prng 를
/// 가리키는 포인터)을 들고 나가는데, 헬퍼가 돌아가는 순간 그 자리는 죽은 스택 프레임이다.
/// 오래 초록이었지만 UB 였고, 필드 하나를 더한 것만으로 `emit` 안에서 터졌다(실측: SIGSEGV).
var test_prng = std.Random.DefaultPrng.init(99);

fn readyClient() Client {
    var c = Client.init(.{
        .user = "u",
        .secret_key = @splat(0),
        .size = .{ .cols = 80, .rows = 24 },
    }, test_prng.random());
    c.state = .ready;
    c.shell_ready = true;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    c.ch.state = .open;
    c.ch.local_id = 0;
    c.ch.remote_id = 0;
    c.ch.remote_window = 1 << 20;
    c.ch.remote_max_packet = 32768;
    return c;
}

/// 채널 페이로드 하나를 평문 패킷으로 싸서 먹인다.
fn feedChannel(c: *Client, payload: []const u8, wire_out: []u8, screen_out: []u8) !Step {
    var buf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&buf, payload, prng.random());
    return c.feed(buf[0..n], wire_out, screen_out);
}

test "모르는 채널 요청에 want_reply 면 답한다" {
    // **리팩터가 지웠던 자리다.** 검증 도구에는 있었는데 상태기계로 옮기며 빠졌다 — §5.4 는
    // "If the request is not recognized ... SSH_MSG_CHANNEL_FAILURE is returned" 라고 못박고,
    // OpenSSH 는 `keepalive@openssh.com` 을 그렇게 보낸다. 안 답하면 연결이 죽은 것으로 본다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("keepalive@openssh.com");
    try wr.boolean(true);
    const step = try feedChannel(&c, wr.written(), &w, &scr);

    // 답이 나갔다 — `CHANNEL_FAILURE`(100) 이고 상대 채널 번호로 간다.
    const dec = try packet.read(step.wire);
    try testing.expectEqual(channel.msg_channel_failure, dec.payload[0]);
}

test "want_reply 가 거짓이면 답하지 않는다" {
    // 안 물었는데 답하면 상대가 그것을 다른 요청의 답으로 읽는다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("nothing@example.com");
    try wr.boolean(false);
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "신호로 죽으면 그 이름을 잃지 않는다" {
    // §6.10 은 `exit-status` 와 `exit-signal` 중 하나만 온다고 한다. 신호 쪽을 버리면 사용자에게
    // "끝났는지" 조차 못 알려 준다 — 옛 드라이버는 오류로 올렸는데, 오류는 세션을 죽이므로
    // 정보만 남기는 편이 낫다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("exit-signal");
    try wr.boolean(false);
    try wr.string("TERM");
    try wr.boolean(false);
    try wr.string("");
    try wr.string("");
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqualStrings("TERM", step.exit_signal.?);
    try testing.expectEqual(@as(?u32, null), step.exit_status);
}

test "화면 바이트는 stdout 과 stderr 를 합친다" {
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_data);
    try wr.u32be(0);
    try wr.string("out");
    const a = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqualStrings("out", a.screen);

    var wr2 = wire.Writer.init(&buf);
    try wr2.byte(channel.msg_channel_extended_data);
    try wr2.u32be(0);
    try wr2.u32be(channel.extended_data_stderr);
    try wr2.string("err");
    const b = try feedChannel(&c, wr2.written(), &w, &scr);
    try testing.expectEqualStrings("err", b.screen);
}

test "버퍼가 한 걸음도 못 담으면 조용히 0 이 아니라 오류다" {
    // 조용히 0 을 돌려주면 호출자가 아무 일도 안 하면서 영원히 맴돈다.
    var c = readyClient();
    var tiny_wire: [16]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed("", &tiny_wire, &scr));

    var w: [8192]u8 = undefined;
    var tiny_screen: [16]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed("", &w, &tiny_screen));
}

test "재키잉 중에도 쓰기는 오류가 아니라 0 바이트다" {
    // **호출자가 재키잉을 알 필요가 없다.** `NotReady` 를 내면 모든 드라이버가 재키잉 상태를
    // 알아야 하고, 그러면 그 지식이 두 층에 생긴다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    try c.t.beginRekey();
    const r = try c.write("ls\n", &w);
    try testing.expectEqual(@as(usize, 0), r.sent);
    try testing.expectEqual(@as(usize, 0), r.wire.len);
    // 세션 자체는 여전히 쓸 수 있다 — `NotReady` 가 아니다.
    try testing.expect(c.shell_ready);
}

test "윈도가 0 이면 쓰기가 0 바이트다" {
    var c = readyClient();
    c.ch.remote_window = 0;
    var w: [8192]u8 = undefined;
    const r = try c.write("x", &w);
    try testing.expectEqual(@as(usize, 0), r.sent);
}

test "상대가 허락한 만큼만 나간다" {
    var c = readyClient();
    c.ch.remote_window = 10;
    c.ch.remote_max_packet = 10;
    var w: [8192]u8 = undefined;
    const r = try c.write("0123456789abcdef", &w);
    try testing.expectEqual(@as(usize, 10), r.sent);
    try testing.expect(r.wire.len > 0);
}

test "clear 뒤에는 못 쓴다" {
    // **적대적 검증 3회차가 찾은 것.** 지운 뒤에도 상태를 그대로 두면 키가 0 인 채로 세션이
    // 계속 굴러간다 — 결과는 "왜인지 서버가 다 거절한다" 로 나타나고 원인을 짚기 어렵다.
    var prng = std.Random.DefaultPrng.init(41);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0xAB), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    c.clear();
    try testing.expectEqual(State.closed, c.state);
    // 더 먹여도 아무 데도 안 간다(닫힘은 조용히 넘긴다 — 정상 종료 뒤 메시지가 오므로).
    const step = try c.feed("SSH-2.0-x\r\n", &out, &scr);
    try testing.expectEqual(State.closed, step.state);
    try testing.expectError(Error.NotReady, c.write("x", &out));
}

test "start 없이 feed 하면 조용히 넘기지 않는다" {
    var prng = std.Random.DefaultPrng.init(43);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.NotStarted, c.feed("SSH-2.0-x\r\n", &out, &scr));
}

test "호스트키를 승인하기 전에는 한 발도 안 나간다" {
    // 계약 §4 — 자동 승인은 없다. 여기서 새면 TOFU 가 무의미해진다.
    var prng = std.Random.DefaultPrng.init(47);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    c.state = .host_key_decision;

    for (0..5) |_| {
        const step = try c.feed("", &out, &scr);
        try testing.expectEqual(@as(usize, 0), step.wire.len);
        try testing.expectEqual(State.host_key_decision, step.state);
    }

    c.acceptHostKey();
    const step = try c.feed("", &out, &scr);
    try testing.expect(step.wire.len > 0);
    try testing.expectEqual(State.awaiting_new_keys, step.state);
}

test "서버가 거대한 KEXINIT 을 보내도 버퍼를 안 넘는다" {
    // **여기는 죽은 가지가 아니다.** `KEXINIT` 페이로드는 패킷 상한(256KiB)까지 올 수 있는데
    // 우리 보관 버퍼는 4KiB 다 — 교환 해시에 쓸 원문만 담으면 되기 때문이다. 검사를 빼면
    // 적대적 서버가 스택을 넘긴다.
    var prng = std.Random.DefaultPrng.init(51);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    _ = try c.feed("SSH-2.0-x\r\n", &out, &scr);

    var big: [8192]u8 = undefined;
    @memset(&big, 0);
    big[0] = kexinit.msg_kexinit;
    var wire_buf: [16384]u8 = undefined;
    const n = try packet.write(&wire_buf, &big, prng.random());
    try testing.expectError(Error.ShortBuffer, c.feed(wire_buf[0..n], &out, &scr));
}

test "서버가 거대한 호스트키 blob 을 보내도 버퍼를 안 넘는다" {
    // 호스트키는 wire string 이라 `max_field`(128KiB)까지 올 수 있다. 우리 버퍼는 512B —
    // ed25519 blob 은 51B 다. 검사를 빼면 적대적 서버가 스택을 넘긴다.
    var prng = std.Random.DefaultPrng.init(53);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    c.state = .key_exchange;
    c.t.phase = .initial_kex;

    var payload: [4096]u8 = undefined;
    var w = wire.Writer.init(&payload);
    try w.byte(kex.msg_kex_ecdh_reply);
    try w.string(&([_]u8{7} ** 1024)); // 512 보다 큰 호스트키
    try w.string(&([_]u8{8} ** 32));
    try w.string(&([_]u8{9} ** 64));

    var wire_buf: [8192]u8 = undefined;
    const n = try packet.write(&wire_buf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.ShortBuffer, c.feed(wire_buf[0..n], &out, &scr));
}

test "거대한 exit-signal 이름은 잘라서 담는다" {
    // 신호 이름도 wire string 이라 상한이 크다. 여기서 자르지 않으면 32B 버퍼를 넘는다.
    // **자르는 것이 맞다** — 이름은 사용자에게 보여 줄 값이고, 그것 때문에 세션을 죽일 이유는 없다.
    var c = readyClient();
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [512]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(0);
    try wr.string("exit-signal");
    try wr.boolean(false);
    try wr.string(&([_]u8{'A'} ** 200));
    try wr.boolean(false);
    try wr.string("");
    try wr.string("");
    const step = try feedChannel(&c, wr.written(), &w, &scr);
    try testing.expectEqual(@as(usize, 32), step.exit_signal.?.len);
}

/// 인증 프로토콜 중인 클라이언트를 만든다(암호는 안 붙인다 — 여기서 볼 것은 배너 처리다).
fn authPhaseClient(state: State) Client {
    // 같은 이유로 정적 prng 를 쓴다(`test_prng` 주석 참고).
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, test_prng.random());
    c.state = state;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    return c;
}

fn bannerPayload(buf: []u8, message: []const u8) ![]const u8 {
    var w = wire.Writer.init(buf);
    try w.byte(userauth.msg_userauth_banner);
    try w.string(message);
    try w.string("en");
    return w.written();
}

test "배너는 인증 중 어느 상태에서나 받는다" {
    // **적대적 검증 6회차가 찾은 것.** RFC 4252 §5.4: "at any time after this authentication
    // protocol starts and before authentication is successful". `authenticating` 에서만 받으면
    // `requesting_service` 에 온 배너가 `UnexpectedMessage` 로 세션을 죽인다.
    //
    // **OpenSSH 는 그 자리에서 안 보낸다**(실측) — 그래서 실서버 스모크로는 안 잡힌다. 명세가
    // 허락하는 자리를 우리가 안 받던 것이고, 판정은 이 테스트가 소유한다.
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "legal notice");

    for ([_]State{ .requesting_service, .authenticating }) |st| {
        var c = authPhaseClient(st);
        var w: [8192]u8 = undefined;
        var scr: [64 * 1024]u8 = undefined;
        var pbuf: [1024]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(3);
        const n = try packet.write(&pbuf, payload, prng.random());
        const step = try c.feed(pbuf[0..n], &w, &scr);
        try testing.expectEqual(st, step.state); // 상태가 안 바뀐다 — 세션이 산다
        try testing.expectEqualStrings("legal notice", step.banner.?);
    }
}

test "배너는 걸러서 준다" {
    // 계약 §4.4.2 — 서버가 고른 문자열이다. 그대로 화면에 가면 OSC 0/2·52 로 창 제목을 바꾸고
    // 클립보드에 쓴다. 이 층이 표시를 모르므로 여기서 걸러 두고 안전한 것만 준다.
    var c = authPhaseClient(.authenticating);
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "hi\x1b]0;pwned\x07 there\n");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    const n = try packet.write(&pbuf, payload, prng.random());
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &w, &scr);
    const b = step.banner.?;
    try testing.expect(std.mem.indexOfScalar(u8, b, 0x1b) == null); // ESC 가 없다
    try testing.expect(std.mem.indexOfScalar(u8, b, 0x07) == null); // BEL 도 없다
    try testing.expect(std.mem.indexOf(u8, b, "there") != null); // 본문은 남는다
    try testing.expect(std.mem.indexOfScalar(u8, b, '\n') != null); // 줄바꿈은 남긴다
}

test "배너는 다음 feed 로 물려주지 않는다" {
    // 한 번 준 것을 계속 주면 호출자가 같은 고지를 여러 번 띄운다.
    var c = authPhaseClient(.authenticating);
    var buf: [256]u8 = undefined;
    const payload = try bannerPayload(&buf, "once");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&pbuf, payload, prng.random());
    var w: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(pbuf[0..n], &w, &scr);
    const second = try c.feed("", &w, &scr);
    try testing.expectEqual(@as(?[]const u8, null), second.banner);
}

test "화면 버퍼가 차면 멈추고 나머지는 다음에 준다" {
    // **적대적 검증 8회차가 찾은 구멍.** 입구 검사(너무 작은 버퍼는 오류)는 덮여 있었지만
    // **중간에 멈추는 것**은 안 덮였다. 호출자 버퍼는 유한하고(모바일은 특히), 한 번에 다
    // 담으려 들면 `ShortBuffer` 로 죽는다 — 멈추고 `consumed` 만큼만 먹었다고 알려야 한다.
    var c = readyClient();
    c.ch.local_max_packet = 4096; // 화면 버퍼 요구치를 낮춘다
    var prng = std.Random.DefaultPrng.init(71);

    // 데이터 패킷 셋을 한 입력에 담는다.
    var payload: [2048]u8 = undefined;
    @memset(&payload, 'x');
    var one: [4096]u8 = undefined;
    var wr = wire.Writer.init(&one);
    try wr.byte(channel.msg_channel_data);
    try wr.u32be(0);
    try wr.string(&payload);
    var input: [16384]u8 = undefined;
    var len: usize = 0;
    for (0..3) |_| len += try packet.write(input[len..], wr.written(), prng.random());

    // 화면 버퍼가 둘밖에 못 담는다.
    var w: [8192]u8 = undefined;
    var scr: [5000]u8 = undefined;
    const step = try c.feed(input[0..len], &w, &scr);
    try testing.expect(step.consumed < len); // 다 안 먹었다
    try testing.expect(step.screen.len > 0); // 그래도 진행했다

    // 나머지는 다음 호출에서 나온다 — 잃는 것이 없다.
    const rest = try c.feed(input[step.consumed..len], &w, &scr);
    try testing.expect(rest.consumed > 0);
}

test "shell 수락이 세션을 쓸 수 있게 만든다" {
    // `readyClient` 는 `shell_ready` 를 손으로 세우므로 **진짜 전이**가 안 덮였다 —
    // 그것을 안 세워도 테스트가 다 통과했다(적대적 검증 8회차).
    var prng = std.Random.DefaultPrng.init(73);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    c.state = .starting_shell;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    c.ch.state = .open;
    c.ch.remote_window = 1 << 20;
    c.ch.remote_max_packet = 32768;

    var out: [8192]u8 = undefined;
    // 아직은 못 쓴다.
    try testing.expectError(Error.NotReady, c.write("x", &out));

    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_success);
    try wr.u32be(0);
    var scr: [64 * 1024]u8 = undefined;
    const step = try feedChannel(&c, wr.written(), &out, &scr);
    try testing.expectEqual(State.ready, step.state);

    // 이제 쓸 수 있다.
    const r = try c.write("ls\n", &out);
    try testing.expectEqual(@as(usize, 3), r.sent);
}

test "eof 는 채널이 열려 있을 때만 나간다" {
    // §5.3 — 더 보낼 것이 없다는 알림이다. **채널은 아직 열려 있다**(반대 방향 출력은 계속 온다).
    // 이미 알렸거나 상대가 먼저 닫았으면 할 일이 없다 — 오류가 아니다(보내는 동안 상대가 닫는
    // 것을 실서버에서 겪었고, 그때 세션을 실패로 만들 이유가 없다).
    var c = readyClient();
    var out: [8192]u8 = undefined;

    const bytes = try c.eof(&out);
    try testing.expect(bytes.len > 0);
    const dec = try packet.read(bytes);
    try testing.expectEqual(channel.msg_channel_eof, dec.payload[0]);
    try testing.expectEqual(channel.State.eof_sent, c.ch.state);

    // 두 번째는 조용히 아무것도 안 한다.
    const again = try c.eof(&out);
    try testing.expectEqual(@as(usize, 0), again.len);

    // 셸이 안 떴으면 오류다 — 그것은 호출자의 순서 실수다.
    var fresh = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, c.rand);
    try testing.expectError(Error.NotReady, fresh.eof(&out));
}

test "eof 는 재키잉 중에 안 나간다" {
    // §7.1 — 재키잉 중에는 채널 메시지를 못 보낸다. 오류가 아니라 **0 바이트**다(호출자가
    // 재키잉을 알 필요가 없다는 원칙과 같다).
    var c = readyClient();
    var out: [8192]u8 = undefined;
    try c.t.beginRekey();
    const bytes = try c.eof(&out);
    try testing.expectEqual(@as(usize, 0), bytes.len);
    try testing.expectEqual(channel.State.open, c.ch.state); // 상태도 안 움직인다
}

test "지문은 ssh-keygen 과 같은 값이다" {
    // **사용자가 대조하는 값이다**(계약 §4). 다른 값을 보여 주면 TOFU 가 무의미해진다 —
    // 이 벡터는 `hostkey.zig` 가 `ssh-keygen -lf` 와 맞대 둔 것과 같은 blob 이다.
    var prng = std.Random.DefaultPrng.init(81);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());

    var blob: [128]u8 = undefined;
    var w = wire.Writer.init(&blob);
    try w.string(hostkey.alg_name);
    try w.string(&([_]u8{7} ** 32));
    const written = w.written();
    @memcpy(c.host_key_buf[0..written.len], written);
    c.host_key_len = written.len;

    var out: [128]u8 = undefined;
    const fp = try c.hostKeyFingerprint(&out);
    // 같은 blob 을 `hostkey.fingerprint` 에 직접 넣은 것과 같아야 한다 — 두 벌이 되면 갈린다.
    var out2: [128]u8 = undefined;
    try testing.expectEqualStrings(try hostkey.fingerprint(&out2, written), fp);
    try testing.expect(std.mem.startsWith(u8, fp, "SHA256:"));
}

test "resize 는 window-change 를 낸다" {
    var c = readyClient();
    var out: [8192]u8 = undefined;
    const bytes = try c.resize(.{ .cols = 120, .rows = 40 }, &out);
    const dec = try packet.read(bytes);
    var r = wire.Reader.init(dec.payload);
    try testing.expectEqual(channel.msg_channel_request, try r.byte());
    _ = try r.u32be();
    try testing.expectEqualStrings(channel.request_window_change, try r.string());
    try testing.expectEqual(false, try r.boolean()); // §6.7 — 답을 요구하지 않는다
    try testing.expectEqual(@as(u32, 120), try r.u32be());
    try testing.expectEqual(@as(u32, 40), try r.u32be());
}

test "우리 NEWKEYS 와 상대 것 사이에는 아무것도 안 나간다" {
    // **암묵 불변을 명시로 바꾼다.** RFC 4253 §7.3 은 보내는 쪽 키를 우리 `NEWKEYS` 직후에
    // 바꾸라고 하는데, 우리는 상대 것을 받을 때 양쪽을 함께 켠다 — 그 사이에 아무것도 안
    // 보내므로 결과가 같다. 그 창에서 무엇이든 나가면 **옛 키로 나가고** strict KEX 의 시퀀스
    // 리셋도 어긋난다. 그러면 그 뒤 모든 AEAD 태그가 실패하는데 증상은 한참 뒤에 나온다.
    var prng = std.Random.DefaultPrng.init(83);
    var c = Client.init(.{ .user = "u", .secret_key = @splat(0), .size = .{ .cols = 80, .rows = 24 } }, prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.start(&out);
    c.state = .host_key_decision;
    c.acceptHostKey();

    // 승인 → `NEWKEYS` 하나가 나간다.
    const first = try c.feed("", &out, &scr);
    try testing.expectEqual(State.awaiting_new_keys, first.state);
    const dec = try packet.read(first.wire);
    try testing.expectEqual(@as(u8, msg_newkeys), dec.payload[0]);
    try testing.expectEqual(first.wire.len, packet.writtenLen(1)); // 그 하나뿐이다

    // 상대 것을 받기 전에는 **한 바이트도** 더 안 나간다.
    for (0..5) |_| {
        const step = try c.feed("", &out, &scr);
        try testing.expectEqual(@as(usize, 0), step.wire.len);
        try testing.expectEqual(State.awaiting_new_keys, step.state);
    }
    // 호출자도 못 쓴다 — 셸이 안 떴다.
    try testing.expectError(Error.NotReady, c.write("x", &out));
    try testing.expectError(Error.NotReady, c.eof(&out));
}

// ---------------------------------------------------------------------------
// 잡 메시지(S7c). 계약 §3.2 — **끊는 것이 아니라 답한다.**

test "사유 코드는 RFC 4253 §11.1 표 그대로다" {
    // 숫자를 이름으로 옮기는 자리라 표와 직접 맞댄다. 쓰는 쪽과 읽는 쪽에 같은 상수를 쓰면
    // 자기충족이라 오타가 안 잡힌다.
    try testing.expectEqual(@as(u32, 1), @intFromEnum(DisconnectReason.host_not_allowed_to_connect));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(DisconnectReason.protocol_error));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(DisconnectReason.key_exchange_failed));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(DisconnectReason.service_not_available));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(DisconnectReason.host_key_not_verifiable));
    try testing.expectEqual(@as(u32, 11), @intFromEnum(DisconnectReason.by_application));
    try testing.expectEqual(@as(u32, 14), @intFromEnum(DisconnectReason.no_more_auth_methods_available));
    try testing.expectEqual(@as(u32, 15), @intFromEnum(DisconnectReason.illegal_user_name));
    try testing.expectEqual(@as(u8, 82), msg_request_failure);
}

test "끊긴 이유를 같은 Step 에서 준다" {
    // **오류 이름만으로는 사용자가 고칠 것이 없다.** `DISCONNECT` 는 서버가 "왜 못 붙는지" 를
    // 말해 주는 유일한 통로다 — 그것을 버리면 §3.2 가 요구한 "이유를 보여 준다" 가 불가능해진다.
    var c = readyClient();
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(@intFromEnum(DisconnectReason.no_more_auth_methods_available));
    try w.string("No supported authentication methods available");
    try w.string("en");

    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);

    // **끊긴 사실과 이유가 한 번에 온다.**
    try testing.expectEqual(State.closed, step.state);
    const d = step.disconnect orelse return error.TestExpectedDisconnect;
    try testing.expectEqual(DisconnectReason.no_more_auth_methods_available, d.reason);
    try testing.expectEqualStrings("No supported authentication methods available", d.description);
}

test "모르는 사유 코드도 설명을 잃지 않는다" {
    // 사유 코드는 IANA 가 늘린다. 모르는 값 때문에 설명까지 버리면 "왜" 가 사라진다.
    var c = readyClient();
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(9999);
    try w.string("서버가 새로 만든 이유");
    try w.string("");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    const d = step.disconnect orelse return error.TestExpectedDisconnect;
    try testing.expectEqual(@as(u32, 9999), @intFromEnum(d.reason));
    try testing.expectEqualStrings("서버가 새로 만든 이유", d.description);
}

test "끊긴 이유도 걸러서 준다" {
    // 서버가 고른 문자열이다 — 배너와 같은 위험이고 같은 거름망을 쓴다(계약 §4.4.2).
    var c = readyClient();
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(2);
    try w.string("bad\x1b]0;pwned\x07 thing");
    try w.string("");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    const d = (step.disconnect orelse return error.TestExpectedDisconnect).description;
    try testing.expect(std.mem.indexOfScalar(u8, d, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, d, "thing") != null);
}

test "모르는 메시지에는 UNIMPLEMENTED 로 답한다" {
    // §11.4 는 MUST 다: "An implementation MUST respond to all unrecognized messages with an
    // SSH_MSG_UNIMPLEMENTED message". 끊으면 안 된다 — 서버가 우리가 모르는 확장을 하나
    // 보냈다고 세션이 죽으면 그 서버에는 영영 못 붙는다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var pbuf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    // **앞에 두 개를 흘려 보낸다** — 시퀀스가 0 이 아니라야 "무엇을 거절했는지" 를 진짜로
    // 싣는지 잴 수 있다. 0 이면 아무 값이나 실어도 통과한다.
    var used: usize = 0;
    used += try packet.write(pbuf[used..], &[_]u8{ msg_ignore, 0, 0, 0, 0 }, prng.random());
    used += try packet.write(pbuf[used..], &[_]u8{ msg_ignore, 0, 0, 0, 0 }, prng.random());
    used += try packet.write(pbuf[used..], &[_]u8{ 77, 1, 2, 3 }, prng.random()); // 배정 안 된 번호
    const step = try c.feed(pbuf[0..used], &out, &scr);

    const dec = try packet.read(step.wire);
    try testing.expectEqual(msg_unimplemented, dec.payload[0]);
    // **거절한 메시지의 시퀀스 번호를 싣는다**(§11.4). 세 번째로 받았으니 2 다.
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, dec.payload[1..5], .big));
    try testing.expectEqual(@as(usize, 5), dec.payload.len);
    try testing.expectEqual(State.ready, step.state); // 세션은 산다
}

test "전역 요청에 want_reply 면 실패로 답한다" {
    // RFC 4254 §4 — "The recipient will respond ... if 'want reply' is TRUE". 안 답하면 그렇게
    // 보내는 서버가 답을 기다린 채 멈춘다. **OpenSSH 10.2 는 `hostkeys-00@openssh.com` 을
    // `want_reply` 0 으로 보낸다(실측)** — 이 가지를 실서버 스모크로는 못 밟으므로 여기서 잰다.
    var c = readyClient();
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_global_request);
    try w.string("hostkeys-00@openssh.com");
    try w.boolean(true);
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(13);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    const dec = try packet.read(step.wire);
    try testing.expectEqual(msg_request_failure, dec.payload[0]);
    try testing.expectEqual(@as(usize, 1), dec.payload.len);
}

test "전역 요청이 want_reply 를 안 켰으면 답하지 않는다" {
    // 안 물었는데 답하면 상대가 그것을 다른 요청의 답으로 읽는다.
    var c = readyClient();
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_global_request);
    try w.string("hostkeys-00@openssh.com");
    try w.boolean(false);
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(17);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "IGNORE·DEBUG·UNIMPLEMENTED 는 세션을 안 건드린다" {
    // §11.2·§11.3 — 뜻이 없다. `UNIMPLEMENTED` 는 우리가 보낸 것에 대한 답이라 할 일이 없다
    // (우리는 모르는 메시지를 안 보낸다).
    for ([_]u8{ msg_ignore, msg_debug, msg_unimplemented }) |msg| {
        var c = readyClient();
        var out: [8192]u8 = undefined;
        var scr: [64 * 1024]u8 = undefined;
        var pbuf: [1024]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(19);
        const n = try packet.write(&pbuf, &[_]u8{ msg, 0, 0, 0, 0 }, prng.random());
        const step = try c.feed(pbuf[0..n], &out, &scr);
        try testing.expectEqual(@as(usize, 0), step.wire.len);
        try testing.expectEqual(State.ready, step.state);
    }
}

test "재키잉 중에 온 전역 요청은 답을 미룬다" {
    // **답이 세션을 죽이면 안 답한 것만 못하다.** `REQUEST_FAILURE`(82) 는 재키잉 중에 보낼 수
    // 없는 번호라(§7.1, 1~49 만 허용) 그대로 보내면 전송기가 `NotAllowedDuringRekey` 로
    // **우리 쪽을 poison** 한다 — 서버가 끊기 전에 우리가 먼저 죽는다.
    //
    // 서버의 `GLOBAL_REQUEST` 는 우리 `KEXINIT` 이 닿기 전에 떠난 것일 수 있으므로 이 겹침은
    // 규칙 위반이 아니라 정상이다. §7.1 이 말한 대로 **줄 세웠다가 뒤에 보낸다.**
    var c = readyClient();
    c.t.phase = .rekeying;
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_global_request);
    try w.string("hostkeys-00@openssh.com");
    try w.boolean(true);
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(23);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(@as(usize, 0), step.wire.len); // 지금은 아무것도 안 나간다
    try testing.expectEqual(@as(?transport.Error, null), c.t.poison); // 살아 있다

    // 재키잉이 끝나면 밀린 답이 나간다.
    c.t.phase = .established;
    const after = try c.feed(&[_]u8{}, &out, &scr);
    const dec = try packet.read(after.wire);
    try testing.expectEqual(msg_request_failure, dec.payload[0]);
}

test "모르는 번호는 인증 중에도 세션을 안 죽인다" {
    // 예전에는 채널 상태에서만 답했다. 그러면 인증 중에 온 확장 하나로 **그 서버에는 영영 못
    // 붙는다** — 로그에는 `UnexpectedMessage` 만 남아 원인을 짚기도 어렵다.
    var c = readyClient();
    c.state = .authenticating;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(29);
    const n = try packet.write(&pbuf, &[_]u8{ 7, 0, 0, 0, 0 }, prng.random()); // EXT_INFO — 우리는 안 쓴다
    const step = try c.feed(pbuf[0..n], &out, &scr);
    const dec = try packet.read(step.wire);
    try testing.expectEqual(msg_unimplemented, dec.payload[0]);
    try testing.expectEqual(State.authenticating, step.state); // 하던 일을 계속한다
}

test "키 교환 중 모르는 번호는 끊는다" {
    // strict KEX 는 그 사이의 예상 밖 패킷에 **연결을 끊으라**고 요구한다(draft §3.2).
    // 여기서 답하고 살아 있으면 그 요구를 어긴다 — 답하는 쪽이 늘 옳은 것이 아니다.
    var c = readyClient();
    c.state = .key_exchange;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(31);
    const n = try packet.write(&pbuf, &[_]u8{ 77, 0, 0, 0, 0 }, prng.random());
    try testing.expectError(Error.UnexpectedMessage, c.feed(pbuf[0..n], &out, &scr));
}

test "SERVICE_ACCEPT 는 인증으로 넘어간다" {
    // **아는 번호를 모르는 번호로 잘못 분류하면 `UNIMPLEMENTED` 만 보내며 영원히 기다린다.**
    // `recognizedMessage` 가 모든 메시지 앞에 서 있으므로 본 경로 하나는 여기서 직접 잰다
    // (지금까지 이 전이는 실서버 스모크만 재고 있었고, 그래서 범위를 좁히는 변이가 살아남았다).
    var prng = std.Random.DefaultPrng.init(41);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(7));
    var secret: [userauth.secret_key_len]u8 = undefined;
    @memcpy(secret[0..32], &@as([32]u8, @splat(7)));
    @memcpy(secret[32..64], &kp.public_key.toBytes());

    var c = Client.init(.{
        .user = "u",
        .secret_key = secret,
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.state = .requesting_service;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(userauth.msg_service_accept);
    try w.string("ssh-userauth");
    var pbuf: [1024]u8 = undefined;
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(State.authenticating, step.state);
    const dec = try packet.read(step.wire);
    try testing.expectEqual(userauth.msg_userauth_request, dec.payload[0]);
}

/// 인증 응답을 기다리는 자리에 세운 클라이언트(위 SERVICE_ACCEPT 테스트와 같은 준비).
fn authenticatingClient(prng: *std.Random.DefaultPrng) Client {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(7)) catch unreachable;
    var secret: [userauth.secret_key_len]u8 = undefined;
    @memcpy(secret[0..32], &@as([32]u8, @splat(7)));
    @memcpy(secret[32..64], &kp.public_key.toBytes());
    var c = Client.init(.{
        .user = "u",
        .secret_key = secret,
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.state = .authenticating;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;
    return c;
}

/// `USERAUTH_FAILURE` 한 통(계속 시도할 수 있는 방법 목록 + partial).
fn authFailure(out: []u8, methods: []const []const u8, prng: *std.Random.DefaultPrng) []const u8 {
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    w.byte(userauth.msg_userauth_failure) catch unreachable;
    w.nameList(methods) catch unreachable;
    w.boolean(false) catch unreachable;
    const n = packet.write(out, w.written(), prng.random()) catch unreachable;
    return out[0..n];
}

test "키가 없으면 none 으로 방법 목록을 묻는다" {
    // **키가 없다고 시작조차 못 하면 안 된다** — 비밀번호만 여는 서버에는 키가 필요 없다.
    // 예전에는 host 가 키 파일이 없으면 아예 접속을 안 했고(iOS), 그 서버에도 못 붙었다.
    var prng = std.Random.DefaultPrng.init(51);
    var c = Client.init(.{
        .user = "u",
        .secret_key = null, // 키 없음
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.state = .requesting_service;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(userauth.msg_service_accept);
    try w.string("ssh-userauth");
    var pbuf: [1024]u8 = undefined;
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(State.authenticating, step.state);

    // 나간 것이 **`none` 요청**이다(키가 없으니 서명할 것도 없다).
    const dec = try packet.read(step.wire);
    try testing.expectEqual(userauth.msg_userauth_request, dec.payload[0]);
    var r = wire.Reader.init(dec.payload[1..]);
    try testing.expectEqualStrings("u", try r.string());
    try testing.expectEqualStrings("ssh-connection", try r.string());
    try testing.expectEqualStrings("none", try r.string());
}

test "키 없이 물은 뒤에도 비밀번호로 이어 간다" {
    // `none` 은 실패하는 것이 정상이다(§5.2). 그 실패의 목록에 `password` 가 있으면 거기서
    // 묻는다 — 이 이음매가 없으면 키 없는 기기는 목록만 받고 끝난다.
    var prng = std.Random.DefaultPrng.init(52);
    var c = Client.init(.{
        .user = "u",
        .secret_key = null,
        .size = .{ .cols = 80, .rows = 24 },
    }, prng.random());
    c.state = .authenticating;
    c.auth_method = .none;
    c.t.phase = .established;
    c.t.kex_send_done = true;
    c.t.kex_recv_done = true;

    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(authFailure(&pbuf, &.{"password"}, &prng), &out, &scr);
    try testing.expectEqual(State.password_needed, step.state);
}

test "키가 거절돼도 서버가 비밀번호를 열어 뒀으면 물어본다" {
    // **서버가 열어 둔 문 앞에서 돌아서지 않는다.** 예전에는 `USERAUTH_FAILURE` 를 그대로
    // `AuthFailed` 로 올려, 비밀번호만 받는 서버에는 영영 못 붙었다(계약 §2 는 그 방식을
    // 지원한다고 적어 두었는데 세션이 안 쓰고 있었다).
    var prng = std.Random.DefaultPrng.init(41);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(authFailure(&pbuf, &.{ "publickey", "password" }, &prng), &out, &scr);
    try testing.expectEqual(State.password_needed, step.state);
    // **아직 아무것도 안 보낸다** — 비밀번호는 코어가 안 들고 있다(§3.4).
    try testing.expectEqual(@as(usize, 0), step.wire.len);
}

test "비밀번호를 안 여는 서버면 그대로 실패다" {
    // 물어봐도 보낼 곳이 없다 — 되묻는 화면만 띄우면 사용자는 무엇이 잘못됐는지 모른다.
    var prng = std.Random.DefaultPrng.init(42);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.AuthFailed, c.feed(authFailure(&pbuf, &.{ "publickey", "keyboard-interactive" }, &prng), &out, &scr));
}

test "친 비밀번호는 요청으로 나가고 코어에 안 남는다" {
    var prng = std.Random.DefaultPrng.init(43);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(authFailure(&pbuf, &.{"password"}, &prng), &out, &scr);

    var wire_out: [8192]u8 = undefined;
    const secret_pw = "hunter2";
    const sent = try c.providePassword(secret_pw, &wire_out);
    try testing.expect(sent.len > 0);
    try testing.expectEqual(State.authenticating, c.state);
    const dec = try packet.read(sent);
    try testing.expectEqual(userauth.msg_userauth_request, dec.payload[0]);
    // 방식 이름이 `password` 다(그 자리가 틀리면 서버가 방식을 못 고른다).
    var r = wire.Reader.init(dec.payload[1..]);
    try testing.expectEqualStrings("u", try r.string());
    try testing.expectEqualStrings("ssh-connection", try r.string());
    try testing.expectEqualStrings("password", try r.string());

    // **코어 안에는 안 남는다**(§3.4 — 저장하지 않는다). 클라이언트 구조체 바이트를 통째로 훑는다.
    const raw = std.mem.asBytes(&c);
    try testing.expect(std.mem.indexOf(u8, raw, secret_pw) == null);
}

test "비밀번호가 틀려도 되묻는 고리에 안 빠진다" {
    // 서버는 틀린 비밀번호에도 **같은 방법 목록**을 돌려준다(RFC 4252 §5.1) — 그것을 안 세면
    // 화면이 영원히 다시 묻는다.
    var prng = std.Random.DefaultPrng.init(44);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(authFailure(&pbuf, &.{"password"}, &prng), &out, &scr);
    var wire_out: [8192]u8 = undefined;
    _ = try c.providePassword("틀린값", &wire_out);
    // 서버가 또 거절한다 — 이번에는 실패로 끝난다.
    var pbuf2: [1024]u8 = undefined;
    try testing.expectError(Error.AuthFailed, c.feed(authFailure(&pbuf2, &.{"password"}, &prng), &out, &scr));
}

test "비밀번호를 바꾸라는 답은 그 이름으로 올라온다" {
    // **`AuthFailed` 와 섞으면 화면이 틀린 안내를 한다** — 사용자가 할 일은 "다시 쳐 보기" 가
    // 아니라 "서버에서 비밀번호 바꾸기" 다. 그리고 이 갈림은 **무엇을 보냈는지**로만 정해진다
    // (§7 `PK_OK` 와 §8 이 같은 번호 60 을 쓴다).
    var prng = std.Random.DefaultPrng.init(46);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(authFailure(&pbuf, &.{"password"}, &prng), &out, &scr);
    var wire_out: [8192]u8 = undefined;
    _ = try c.providePassword("x", &wire_out);

    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(userauth.msg_userauth_method_specific);
    try w.string("expired - change it"); // prompt
    try w.string("en"); // language
    var pbuf2: [1024]u8 = undefined;
    const n = try packet.write(&pbuf2, w.written(), prng.random());
    try testing.expectError(Error.PasswordChangeRequired, c.feed(pbuf2[0..n], &out, &scr));
}

test "비밀번호가 맞으면 채널을 연다" {
    // **성공 경로는 실서버로 못 잰다** — 진짜 계정 비밀번호가 필요하고 스모크는 그것을 모른다
    // (사람에게 물을 수도 없다). 그래서 여기서 닫는다: 서버가 `SUCCESS` 를 주면 그 다음 걸음
    // (채널 열기)이 실제로 나가야 한다.
    var prng = std.Random.DefaultPrng.init(47);
    var c = authenticatingClient(&prng);
    var pbuf: [1024]u8 = undefined;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(authFailure(&pbuf, &.{"password"}, &prng), &out, &scr);
    var wire_out: [8192]u8 = undefined;
    _ = try c.providePassword("맞는값", &wire_out);

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(userauth.msg_userauth_success);
    var pbuf2: [1024]u8 = undefined;
    const n = try packet.write(&pbuf2, w.written(), prng.random());
    const step = try c.feed(pbuf2[0..n], &out, &scr);
    try testing.expectEqual(State.opening_channel, step.state);
    const dec = try packet.read(step.wire);
    try testing.expectEqual(@as(u8, 90), dec.payload[0]); // CHANNEL_OPEN
}

test "비밀번호를 물어보지도 않았는데 넣으면 거절한다" {
    // 상태가 아닌데 보내면 서버가 순서를 못 읽는다(그리고 그 비밀번호는 선에 그냥 흘러간다).
    var prng = std.Random.DefaultPrng.init(45);
    var c = authenticatingClient(&prng);
    var wire_out: [8192]u8 = undefined;
    try testing.expectError(Error.UnexpectedMessage, c.providePassword("x", &wire_out));
}

test "재키잉 중 전역 요청이 쏟아져도 세는 값이 안 감싸 돈다" {
    // 답은 요청 순서대로 짝지어지므로 **수가 곧 뜻이다.** 감싸 돌면 255 개를 넘긴 순간 0 이 되어
    // 밀린 답이 통째로 사라지고, 서버는 답을 기다리다 끊는다. 넘치면 버릴지언정 되감지 않는다.
    var c = readyClient();
    c.t.phase = .rekeying;
    var pbuf: [64 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(43);
    var used: usize = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var buf: [64]u8 = undefined;
        var w = wire.Writer.init(&buf);
        try w.byte(msg_global_request);
        try w.string("hostkeys-00@openssh.com");
        try w.boolean(true);
        used += try packet.write(pbuf[used..], w.written(), prng.random());
    }
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(pbuf[0..used], &out, &scr);
    try testing.expectEqual(@as(u8, 255), c.pending_request_failures);
    try testing.expectEqual(@as(?transport.Error, null), c.t.poison);

    // 재키잉이 끝나면 **밀린 답이 하나도 안 빠지고** 나간다. 하나만 나가고 마는 것과 구별하려면
    // 세어야 한다 — 개수가 곧 짝짓기이므로 모자라면 서버는 계속 기다린다.
    c.t.phase = .established;
    var replies: usize = 0;
    var rounds: usize = 0;
    while (c.pending_request_failures > 0 and rounds < 40) : (rounds += 1) {
        const after = try c.feed(&[_]u8{}, &out, &scr);
        var rest = after.wire;
        while (rest.len > 0) {
            const dec = try packet.read(rest);
            try testing.expectEqual(msg_request_failure, dec.payload[0]);
            replies += 1;
            rest = rest[dec.consumed..];
        }
    }
    try testing.expectEqual(@as(u8, 0), c.pending_request_failures);
    try testing.expectEqual(@as(usize, 255), replies);
}

test "CHANNEL_FAILURE 는 요청 실패로 올라온다" {
    // 100 번을 모르는 번호로 분류하면 pty 를 거절당해도 `UNIMPLEMENTED` 만 보내며 영원히
    // 기다린다 — 사용자에게는 "멈춤" 으로 보인다. 아는 번호는 아는 번호로 다뤄야 한다.
    var c = readyClient();
    c.state = .requesting_pty;
    var buf: [16]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(100); // SSH_MSG_CHANNEL_FAILURE
    try w.u32be(0); // recipient channel
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(47);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    try testing.expectError(Error.RequestFailed, c.feed(pbuf[0..n], &out, &scr));
}

test "최소 크기 버퍼로도 밀린 답을 다 비운다" {
    // 계약이 약속한 최소 버퍼는 `min_wire_out` 하나다. 그 크기에서 답이 한 번에 하나씩만
    // 나가면 255 개를 비우는 데 `feed` 를 255 번 불러야 하고, 그 사이 서버는 답을 기다린다.
    var c = readyClient();
    c.t.phase = .rekeying;
    var pbuf: [64 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(53);
    var used: usize = 0;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        var buf: [64]u8 = undefined;
        var w = wire.Writer.init(&buf);
        try w.byte(msg_global_request);
        try w.string("hostkeys-00@openssh.com");
        try w.boolean(true);
        used += try packet.write(pbuf[used..], w.written(), prng.random());
    }
    // **실제 세션은 암호 프레이밍이다.** 평문으로 재면 답 하나가 16 바이트라 255 개가 4096 에
    // 다 들어가고, "자리가 없으면 다음에" 가지가 영영 안 돈다.
    var key: [cipher.key_len]u8 = @splat(1);
    var cc = cipher.Cipher.initMove(&key);
    try c.t.enableSendKeys(&cc); // 이 호출이 재키잉을 끝낸 것으로 본다 — 다시 재키잉 중으로 둔다
    c.t.phase = .rekeying;

    var out: [min_wire_out]u8 = undefined; // **딱 최소 크기**
    var scr: [64 * 1024]u8 = undefined;
    _ = try c.feed(pbuf[0..used], &out, &scr);
    try testing.expectEqual(@as(u8, 255), c.pending_request_failures);

    // 답 하나가 36 바이트이므로 4096 에는 다 안 들어간다 — 나눠 내보내야 하고, 넘겨 쓰면
    // `NoSpace` 로 죽는다.
    try testing.expect(255 * cipher.Cipher.sealedLen(1) > min_wire_out);

    c.t.phase = .established;
    var rounds: usize = 0;
    while (c.pending_request_failures > 0 and rounds < 10) : (rounds += 1) {
        _ = try c.feed(&[_]u8{}, &out, &scr);
    }
    try testing.expectEqual(@as(u8, 0), c.pending_request_failures);
    try testing.expect(rounds > 1); // 한 번에 다 못 내보낸다는 뜻 — 그 가지를 실제로 돌렸다
}

test "DISCONNECT 뒤에는 기계가 닫힌다" {
    // **오류 하나만 돌려주고 기계가 살아 있으면 호출자가 반쪽만 지킬 수 있다.** 오류를 흘려 보낸
    // 드라이버는 그 뒤에도 먹이고 쓸 수 있고, 그러면 이미 끝난 연결에 바이트를 짜 넣는다.
    // §11.1 은 이 메시지 뒤에 연결을 끝내라고 한다 — 끝내는 주체가 우리여야 한다.
    var c = readyClient();
    var buf: [128]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(11);
    try w.string("bye");
    try w.string("");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(59);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const first = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(State.closed, first.state);
    try testing.expect(first.disconnect != null);

    // 뒤에 온 바이트는 흘려보낸다 — 끝난 연결에서 파싱 오류를 올릴 이유가 없다.
    const after = try c.feed("garbage", &out, &scr);
    try testing.expectEqual(State.closed, after.state);
    try testing.expect(after.disconnect != null);
    // 쓰기도 막힌다.
    try testing.expectError(Error.NotReady, c.write("x", &out));
}

test "설명이 너무 길어도 끊긴 것은 끊긴 것이다" {
    // 설명을 못 담는 것과 세션이 안 끝나는 것은 다른 일이다. 거름망이 자리를 못 잡아 설명을
    // 버릴 때도 **연결은 끝난다** — 여기서 안 닫으면 이유 못 담은 서버 하나가 좀비를 만든다.
    var c = readyClient();
    var buf: [2048]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(2);
    const long: [1024]u8 = @splat('x'); // `disconnect_buf`(512) 보다 길다
    try w.string(&long);
    try w.string("");
    var pbuf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(61);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const first = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(State.closed, first.state);
    try testing.expectEqual(@as(usize, 0), (first.disconnect orelse return error.TestExpectedDisconnect).description.len);

    const after = try c.feed("garbage", &out, &scr);
    try testing.expectEqual(State.closed, after.state);
    try testing.expect(after.disconnect != null);
    try testing.expectEqual(DisconnectReason.protocol_error, after.disconnect.?.reason);
}

test "적대적 입력: 붙은 뒤의 상태기계도 어떤 바이트열에 안 죽는다" {
    // `ssh.zig` 의 fuzz 는 **`version_exchange` 에서 출발**한다 — 씨앗을 아무리 흔들어도 온전한
    // 핸드셰이크를 못 만들어 `ready` 뒤의 경로(잡 메시지·채널)에는 닿지 못한다. 그래서 붙은
    // 다음의 상태기계는 여기서 따로 흔든다. **닿았는지도 센다** — 전부 파싱 실패로 튕기면
    // 아무것도 안 재면서 초록이 된다.
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rand = prng.random();

    var seeds: [5][]const u8 = undefined;
    var seed_store: [5][512]u8 = undefined;
    {
        var b: [256]u8 = undefined;
        var w = wire.Writer.init(&b);
        try w.byte(msg_disconnect);
        try w.u32be(11);
        try w.string("bye now");
        try w.string("en");
        seeds[0] = seed_store[0][0..try packet.write(&seed_store[0], w.written(), rand)];
    }
    {
        var b: [256]u8 = undefined;
        var w = wire.Writer.init(&b);
        try w.byte(msg_global_request);
        try w.string("hostkeys-00@openssh.com");
        try w.boolean(true);
        seeds[1] = seed_store[1][0..try packet.write(&seed_store[1], w.written(), rand)];
    }
    seeds[2] = seed_store[2][0..try packet.write(&seed_store[2], &[_]u8{ 77, 1, 2, 3 }, rand)];
    seeds[3] = seed_store[3][0..try packet.write(&seed_store[3], &[_]u8{ msg_debug, 0, 0, 0, 1, 'x' }, rand)];
    {
        var b: [256]u8 = undefined;
        var w = wire.Writer.init(&b);
        try w.byte(94); // CHANNEL_DATA
        try w.u32be(0);
        try w.string("hello");
        seeds[4] = seed_store[4][0..try packet.write(&seed_store[4], w.written(), rand)];
    }

    var c = readyClient();
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var reached: usize = 0;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const seed = seeds[rand.uintLessThan(usize, seeds.len)];
        var mutated: [512]u8 = undefined;
        @memcpy(mutated[0..seed.len], seed);
        var m = mutated[0..seed.len];
        const flips = 1 + rand.uintLessThan(usize, 4);
        var f: usize = 0;
        while (f < flips and m.len > 0) : (f += 1) {
            m[rand.uintLessThan(usize, m.len)] ^= @as(u8, 1) << rand.int(u3);
        }
        if (i % 5 == 0 and m.len > 1) m = m[0 .. rand.uintLessThan(usize, m.len) + 1];

        if (c.feed(m, &out, &scr)) |step| {
            if (step.consumed > 0) reached += 1;
            if (step.state == .closed) c = readyClient(); // 끊긴 뒤는 다 흘려보내므로 다시 세운다
        } else |_| {
            c = readyClient();
        }
    }
    // 이 값은 실측이다 — 씨앗이나 판정을 바꿔 닿는 수가 무너지면 여기서 걸린다.
    try testing.expect(reached > 300);
}

test "끊긴 뒤에는 미뤄 둔 것도 안 나간다" {
    // 서버가 끊었으면 연결은 끝이다(§11.1). 그런데 미뤄 둔 답·윈도 보충이 큐에 남아 있으면
    // **끝난 연결에 바이트를 만들어 준다** — 드라이버는 그것을 이미 닫힌 소켓에 쓰고 EPIPE 를
    // 본다. 원인이 "서버가 끊었다" 가 아니라 "쓰기 실패" 로 보이는 것이 이 부류의 나쁜 점이다.
    var c = readyClient();
    c.ch.local_window = 1; // 보충이 필요한 상태
    c.pending_request_failures = 3; // 미뤄 둔 답도 있다
    try testing.expect(c.ch.pendingWindowAdjust() != 0);

    var buf: [128]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_disconnect);
    try w.u32be(2);
    try w.string("bye");
    try w.string("");
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(67);
    const n = try packet.write(&pbuf, w.written(), prng.random());
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    const step = try c.feed(pbuf[0..n], &out, &scr);
    try testing.expectEqual(State.closed, step.state);
    try testing.expectEqual(@as(usize, 0), step.wire.len);

    const after = try c.feed(&[_]u8{}, &out, &scr);
    try testing.expectEqual(@as(usize, 0), after.wire.len);
}

test "재키잉 중에 온 모르는 번호에는 그대로 답한다" {
    // 초기 KEX 와 재키잉을 같은 것으로 묶으면 안 된다. 재키잉 중 상대의 패킷은 정상이고
    // (§7.1 — 우리 `KEXINIT` 이 닿기 전에 떠난 것), `UNIMPLEMENTED` 는 3 번이라 그 사이에도
    // 보낼 수 있다. 여기서 끊으면 재키잉과 겹친 확장 하나가 세션을 죽인다.
    var c = readyClient();
    c.t.phase = .rekeying;
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var pbuf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(71);
    const n = try packet.write(&pbuf, &[_]u8{ 77, 0, 0, 0, 0 }, prng.random());
    const step = try c.feed(pbuf[0..n], &out, &scr);
    const dec = try packet.read(step.wire);
    try testing.expectEqual(msg_unimplemented, dec.payload[0]);
    try testing.expectEqual(@as(?transport.Error, null), c.t.poison);
}

test "재키잉에서 호스트키가 바뀌면 끊는다" {
    // **서명 검증은 "이 키가 이 H 에 서명했다" 만 말한다** — 그 키가 사용자가 승인한 키인지는
    // 안 본다. 즉 재키잉에서 다른 키로 갈아 끼워도 서명은 맞고, 그러면 우리가 사용자에게 보여
    // 준 지문이 지금 세션의 상대와 다르다 — TOFU 가 약속한 것이 바로 그 동일성이다.
    var c = readyClient();
    var key_a: [128]u8 = undefined;
    var wa = wire.Writer.init(&key_a);
    try wa.string(hostkey.alg_name);
    try wa.string(&([_]u8{7} ** 32));
    const blob_a = wa.written();
    @memcpy(c.host_key_buf[0..blob_a.len], blob_a);
    c.host_key_len = blob_a.len;

    // 다른 키 B 를 담은 재키잉 답.
    var payload: [256]u8 = undefined;
    var w = wire.Writer.init(&payload);
    try w.byte(kex.msg_kex_ecdh_reply);
    var key_b: [128]u8 = undefined;
    var wb = wire.Writer.init(&key_b);
    try wb.string(hostkey.alg_name);
    try wb.string(&([_]u8{9} ** 32)); // 다른 키
    try w.string(wb.written());
    try w.string(&([_]u8{1} ** 32)); // Q_S
    try w.string(&([_]u8{0} ** 83)); // 서명 — 여기까지 가지 않는다

    c.rekeying = true;
    c.state = .key_exchange;
    var out: [8192]u8 = undefined;
    var o: Client.Out = .{ .buf = &out };
    try testing.expectError(Error.HostKeyChanged, c.onKexReply(w.written(), &o));
    // **바뀐 키를 보관하지도 않는다** — 그 뒤에 지문을 물으면 승인한 키가 나와야 한다.
    try testing.expectEqualSlices(u8, blob_a, c.host_key_buf[0..c.host_key_len]);
}

// ---- 컨트롤 채널(S10b) ------------------------------------------------------
//
// 계약은 [컨트롤 플레인 §4a](../../../docs/control-plane.md) 다. 여기서 재는 것은 그 계약이
// **코어에서 성립하는지**다: pty 없는 `exec` 채널이 따로 열리고, 그 바이트가 화면과 안 섞이고,
// 그 채널이 끝나도 터미널이 안 죽는다.

/// 컨트롤 채널까지 연 클라이언트. `readyClient` 위에 `openControl` 을 실제로 태운다 —
/// 필드를 손으로 세우면 **여는 경로 자체가 안 덮인다**("shell 수락" 테스트가 그 교훈이다).
fn controlOpenedClient(out: []u8) !Client {
    var c = readyClient();
    _ = try c.openControl("maru control --stdio", out);
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_confirmation);
    try wr.u32be(control_local_id); // 받는 쪽 = 우리가 고른 번호
    try wr.u32be(77); // 상대 번호
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    _ = try feedChannelBuffers(&c, wr.written(), out, &scr, &ctl);
    // `exec` 성공
    var ok: [16]u8 = undefined;
    var okw = wire.Writer.init(&ok);
    try okw.byte(channel.msg_channel_success);
    try okw.u32be(control_local_id);
    _ = try feedChannelBuffers(&c, okw.written(), out, &scr, &ctl);
    return c;
}

fn feedChannelBuffers(c: *Client, payload: []const u8, wire_out: []u8, screen_out: []u8, control_out: []u8) !Step {
    var buf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const n = try packet.write(&buf, payload, prng.random());
    return c.feedBuffers(buf[0..n], .{ .wire = wire_out, .screen = screen_out, .control = control_out });
}

/// 채널 데이터 페이로드 하나.
fn channelData(buf: []u8, recipient: u32, data: []const u8) ![]const u8 {
    var wr = wire.Writer.init(buf);
    try wr.byte(channel.msg_channel_data);
    try wr.u32be(recipient);
    try wr.string(data);
    return wr.written();
}

test "컨트롤 채널은 pty 없이 exec 을 요청한다" {
    // 계약 §4a: 터미널 채널에 명령을 쳐 넣으면 에코·프롬프트가 섞이므로 **채널을 따로 열고
    // pty 를 안 붙인다**. 그래서 선에 나가야 하는 것은 `pty-req` 가 아니라 `exec` 이다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    const opened = try c.openControl("maru control --stdio", &out);
    try testing.expect(opened.len > 0);
    try testing.expectEqual(ControlState.opening, c.controlState());

    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_confirmation);
    try wr.u32be(control_local_id);
    try wr.u32be(77);
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    // 나간 것이 `exec` 이고 명령이 그대로 실려 있다. **`pty-req` 는 없다.**
    const sent = step.wire;
    try testing.expect(std.mem.indexOf(u8, sent, channel.request_exec) != null);
    try testing.expect(std.mem.indexOf(u8, sent, "maru control --stdio") != null);
    try testing.expect(std.mem.indexOf(u8, sent, channel.request_pty) == null);
    try testing.expectEqual(ControlState.requesting_exec, c.controlState());
    // **터미널은 그대로다** — 컨트롤이 열려도 세션 상태는 안 움직인다.
    try testing.expectEqual(State.ready, step.state);
}

test "컨트롤 바이트는 화면과 섞이지 않는다" {
    // 계약 §4a: "stdout 은 오직 wire 다." 섞이면 ndjson 파서가 사람 화면을 읽게 된다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    try testing.expectEqual(ControlState.ready, c.controlState());

    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;

    // 컨트롤 채널로 온 ndjson 한 줄
    const line = "{\"jsonrpc\":\"2.0\"}\n";
    const step = try feedChannelBuffers(&c, try channelData(&buf, control_local_id, line), &out, &scr, &ctl);
    try testing.expectEqualStrings(line, step.control);
    try testing.expectEqual(@as(usize, 0), step.screen.len);

    // 터미널 채널로 온 화면 바이트는 반대다.
    const step2 = try feedChannelBuffers(&c, try channelData(&buf, shell_local_id, "hi"), &out, &scr, &ctl);
    try testing.expectEqualStrings("hi", step2.screen);
    try testing.expectEqual(@as(usize, 0), step2.control.len);
}

test "컨트롤 채널이 닫혀도 터미널은 산다" {
    // 이것이 S10b 의 이유다 — 예전 코어는 **채널이 닫히면 세션을 닫았다**(계약 §4a 가 적어 둔
    // 결함). 그대로 두면 중계 프로세스가 끝나는 순간 셸까지 죽는다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);

    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_close);
    try wr.u32be(control_local_id);
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    try testing.expectEqual(ControlState.closed, c.controlState());
    try testing.expectEqual(State.ready, step.state);
    // 터미널로 계속 쓸 수 있다.
    const r = try c.write("ls\n", &out);
    try testing.expectEqual(@as(usize, 3), r.sent);
}

test "터미널이 닫히면 세션이 닫힌다 — 컨트롤이 없을 때" {
    // 채널을 늘리면서 **옛 규칙을 잃지 않았는지** 본다: 컨트롤을 안 연 접속에서는 터미널이
    // 닫히는 순간 세션이 끝난다(모바일 host 가 이 값으로 소켓을 닫는다).
    var c = readyClient();
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_close);
    try wr.u32be(shell_local_id);
    const step = try feedChannel(&c, wr.written(), &out, &scr);
    try testing.expectEqual(State.closed, step.state);
}

test "터미널이 먼저 닫혀도 컨트롤이 남아 있으면 세션은 안 닫힌다" {
    // **마지막 채널이 닫혀야 닫힌다**(RFC 4254 §5 — 채널은 서로 독립이다). 그리고 남은 채널에
    // 닫으라고 이른다 — 안 그러면 세션이 영영 안 끝난다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);

    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_close);
    try wr.u32be(shell_local_id);
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);
    try testing.expect(step.state != .closed);
    // 우리 close 가 두 채널 모두로 나갔다(터미널 것 + 컨트롤 것).
    var closes: usize = 0;
    for (step.wire) |b| if (b == channel.msg_channel_close) {
        closes += 1;
    };
    try testing.expect(closes >= 2);

    // 컨트롤까지 닫히면 그때 세션이 닫힌다.
    var wr2 = wire.Writer.init(&buf);
    try wr2.byte(channel.msg_channel_close);
    try wr2.u32be(control_local_id);
    const step2 = try feedChannelBuffers(&c, wr2.written(), &out, &scr, &ctl);
    try testing.expectEqual(State.closed, step2.state);
}

test "컨트롤 stderr 는 wire 에도 화면에도 안 섞인다" {
    // 계약 §4a: 로그·경고는 stderr 로 가고, 그것을 버리면 사용자는 왜 안 되는지 모른다 —
    // 진단으로 앞부분만 남긴다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);

    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_extended_data);
    try wr.u32be(control_local_id);
    try wr.u32be(channel.extended_data_stderr);
    try wr.string("maru: command not found\n");
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    try testing.expectEqual(@as(usize, 0), step.control.len);
    try testing.expectEqual(@as(usize, 0), step.screen.len);
    try testing.expectEqualStrings("maru: command not found\n", c.controlStderr());
}

test "127 은 exit-status 로 온다 — 채널 요청은 성공한다" {
    // 계약 §4a: OpenSSH 는 `exec` 을 사용자 셸에 물려 돌리므로 `maru` 가 없어도 **채널 요청은
    // 성공**하고 셸이 127 로 죽는다. `CHANNEL_FAILURE` 를 기다리면 영영 안 온다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    try testing.expectEqual(ControlState.ready, c.controlState());

    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(control_local_id);
    try wr.string(channel.request_exit_status);
    try wr.boolean(false);
    try wr.u32be(127);
    _ = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    try testing.expectEqual(@as(?u32, 127), c.controlExitStatus());
    // **터미널 것과 섞이지 않는다** — 셸은 아직 안 끝났다.
    try testing.expectEqual(@as(?u32, null), c.exit_status);
}

test "exec 이 거절되면 컨트롤만 접고 터미널은 안 건드린다" {
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru control --stdio", &out);
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_confirmation);
    try wr.u32be(control_local_id);
    try wr.u32be(77);
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    _ = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    var fw = wire.Writer.init(&buf);
    try fw.byte(channel.msg_channel_failure);
    try fw.u32be(control_local_id);
    const step = try feedChannelBuffers(&c, fw.written(), &out, &scr, &ctl);
    try testing.expectEqual(ControlState.closed, c.controlState());
    try testing.expectEqual(State.ready, step.state);
}

test "채널 열기를 서버가 거절해도 세션은 안 죽는다" {
    // §5.1 — 서버가 채널 수를 제한할 수 있다. 그때 터미널까지 잃을 이유가 없다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru control --stdio", &out);
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_failure);
    try wr.u32be(control_local_id);
    try wr.u32be(@intFromEnum(channel.OpenFailureReason.administratively_prohibited));
    try wr.string("no");
    try wr.string("");
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);
    try testing.expectEqual(ControlState.closed, c.controlState());
    try testing.expectEqual(State.ready, step.state);
}

test "컨트롤 채널을 두 번 열지 않는다" {
    // 두 번 열면 같은 번호를 두 흐름이 나눠 쓰게 되고, 그러면 라우팅이 무너진다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    try testing.expectError(Error.UnexpectedMessage, c.openControl("maru control --stdio", &out));
}

test "긴 명령은 자르지 않고 거절한다" {
    // 잘린 명령은 **다른 명령**이다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    const long: [max_control_command + 1]u8 = @splat('a');
    try testing.expectError(Error.ShortBuffer, c.openControl(&long, &out));
    try testing.expectEqual(ControlState.none, c.controlState());
}

test "컨트롤 버퍼를 안 주면 조용히 버리지 않는다" {
    // 버리면 ndjson 이 한 줄씩 사라져 파서가 이유 없이 깨진다 — 이 저장소가 여러 번 겪은
    // "아무것도 안 하면서 초록" 의 데이터 판이다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;
    var pkt: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const payload = try channelData(&buf, control_local_id, "{}\n");
    const n = try packet.write(&pkt, payload, prng.random());
    try testing.expectError(Error.ShortBuffer, c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr }));
}

test "컨트롤로 쓴 것은 컨트롤 채널 번호로 나간다" {
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    const r = try c.writeControl("{\"m\":1}\n", &out);
    try testing.expectEqual(@as(usize, 8), r.sent);
    // 평문 패킷이라 그대로 보인다: DATA + 상대 번호(77)
    try testing.expect(std.mem.indexOf(u8, r.wire, &[_]u8{ channel.msg_channel_data, 0, 0, 0, 77 }) != null);
}

test "컨트롤이 아직 안 열렸으면 쓰지 못한다" {
    var c = readyClient();
    var out: [8192]u8 = undefined;
    try testing.expectError(Error.NotReady, c.writeControl("{}\n", &out));
}

test "컨트롤 채널은 닫은 뒤 다시 열 수 있다" {
    // 계약 §4a "언제 여는가": 목록 화면에 들어갈 때 열고 나올 때 닫는다 — 그러면 **다시 여는
    // 것이 정상 경로**다. 닫기가 §5.3 대로 끝나야(양쪽이 다 보냄) 번호를 다시 쓸 수 있다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);

    // 우리가 닫고,
    _ = try c.closeControl(&out);
    // 상대 답이 온다.
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_close);
    try wr.u32be(control_local_id);
    _ = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);

    // 이제 다시 열린다.
    const again = try c.openControl("maru control --stdio", &out);
    try testing.expect(again.len > 0);
    try testing.expectEqual(ControlState.opening, c.controlState());
}

test "닫는 중인 번호는 다시 쓰지 않는다" {
    // 우리 `close` 만 나간 자리에서 같은 번호로 새 채널을 열면 **상대의 늦은 close 가 새 채널로
    // 배달된다** — 방금 연 채널이 이유 없이 닫힌다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    _ = try c.closeControl(&out); // 상대 답은 아직 안 왔다
    try testing.expectError(Error.UnexpectedMessage, c.openControl("maru control --stdio", &out));
}

test "재키잉 중에는 컨트롤 채널을 안 연다" {
    // 계약 §3.0.1 — 재키잉 중에는 채널 메시지를 못 보낸다. 그때 여는 시늉을 하면 **열렸다고
    // 믿는 채널이 선에는 없다**. 0 바이트를 돌려주고 상태를 안 옮겨, 호출자가 다시 부르면 된다.
    var c = readyClient();
    try c.t.beginRekey();
    var out: [8192]u8 = undefined;
    const bytes = try c.openControl("maru control --stdio", &out);
    try testing.expectEqual(@as(usize, 0), bytes.len);
    try testing.expectEqual(ControlState.none, c.controlState());
}

test "컨트롤 버퍼가 차면 죽지 않고 멈춘다" {
    // 화면 쪽은 "차면 멈추고 다음에 준다" 인데 컨트롤만 오류로 죽으면, 큰 답 한 번에 세션이
    // 끝난다. 두 축이 같은 규칙을 따라야 한다.
    //
    // **한 패킷으로는 이것을 못 잰다** — 입구 검사가 이미 한 패킷 몫을 요구하므로 첫 패킷은
    // 언제나 들어간다. 두 패킷을 **한 번에** 먹여야 두 번째에서 자리가 모자란 상황이 된다
    // (변이 검사에서 한 패킷짜리 테스트가 그대로 살아남았다).
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    // 컨트롤 채널의 한 패킷 몫(`control_max_packet`)보다 크되 둘은 못 담는 크기.
    var ctl: [12 * 1024]u8 = undefined;

    const chunk = 7 * 1024;
    var data: [chunk]u8 = @splat('x');
    var buf: [64 * 1024]u8 = undefined;
    var pkt: [128 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const n1 = try packet.write(&pkt, try channelData(&buf, control_local_id, &data), prng.random());
    const n2 = try packet.write(pkt[n1..], try channelData(&buf, control_local_id, &data), prng.random());

    const step = try c.feedBuffers(pkt[0 .. n1 + n2], .{ .wire = &out, .screen = &scr, .control = &ctl });
    // 첫 패킷만 먹고 멈췄다 — 오류가 아니다.
    try testing.expectEqual(@as(usize, chunk), step.control.len);
    try testing.expectEqual(n1, step.consumed);

    // 비우고 다시 부르면 나머지가 온다 — 잃은 바이트가 없다.
    const step2 = try c.feedBuffers(pkt[n1 .. n1 + n2], .{ .wire = &out, .screen = &scr, .control = &ctl });
    try testing.expectEqual(@as(usize, chunk), step2.control.len);
}

test "컨트롤 채널이 열렸는데 작은 버퍼를 주면 입구에서 거절한다" {
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var tiny: [16]u8 = undefined;
    var pkt: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(12);
    var buf: [256]u8 = undefined;
    const n = try packet.write(&pkt, try channelData(&buf, control_local_id, "{}\n"), prng.random());
    try testing.expectError(Error.ShortBuffer, c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr, .control = &tiny }));
}

test "clear 뒤에는 컨트롤로도 못 쓴다" {
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    c.clear();
    try testing.expectError(Error.NotReady, c.writeControl("{}\n", &out));
}

test "컨트롤을 닫으면 그 버퍼를 더 안 요구한다" {
    // 이 채널은 목록 화면을 드나들 때마다 열고 닫는다 — 닫은 뒤에도 버퍼를 요구하면 호출자가
    // 그것을 놓아주는 순간 **그 뒤 모든 `feed` 가 죽는다**.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    _ = try c.closeControl(&out);
    var scr: [64 * 1024]u8 = undefined;
    var pkt: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(13);
    var buf: [256]u8 = undefined;
    // 컨트롤 버퍼 없이 터미널 데이터를 먹인다 — 오류가 아니어야 한다.
    const n = try packet.write(&pkt, try channelData(&buf, shell_local_id, "hi"), prng.random());
    const step = try c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr });
    try testing.expectEqualStrings("hi", step.screen);
}

test "닫는 중에 온 컨트롤 데이터는 버린다" {
    // §5.3 — `close` 를 보낸 뒤에도 상대는 아직 모르고 보낸다. 받을 사람이 없는 바이트를
    // 담으려 들면(호출자는 이미 버퍼를 놓아줬다) 세션이 죽는다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    _ = try c.closeControl(&out);
    var scr: [64 * 1024]u8 = undefined;
    var pkt: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(14);
    var buf: [256]u8 = undefined;
    const n = try packet.write(&pkt, try channelData(&buf, control_local_id, "{}\n"), prng.random());
    const step = try c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr });
    try testing.expectEqual(@as(usize, 0), step.control.len);
    try testing.expect(step.state != .closed);
}

test "컨트롤 채널도 윈도를 보충한다" {
    // 보충을 잊으면 **상대가 멈춘다**(계약 §3.1). 터미널에서 겪은 그 결함이 컨트롤에서 다시
    // 나면, 목록이 작을 때는 멀쩡하고 큰 답에서 갑자기 멈춘다 — 원인을 짚기 가장 어려운 모양이다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;

    // 윈도 절반을 넘길 때까지 먹인다(기본 2MiB, 한 번에 20KiB).
    const chunk = 7 * 1024;
    var data: [chunk]u8 = @splat('y');
    var buf: [64 * 1024]u8 = undefined;
    var pkt: [64 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(21);
    var adjusts: usize = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const n = try packet.write(&pkt, try channelData(&buf, control_local_id, &data), prng.random());
        const step = try c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr, .control = &ctl });
        // 평문이라 그대로 보인다: WINDOW_ADJUST + 상대 번호(77)
        if (std.mem.indexOf(u8, step.wire, &[_]u8{ channel.msg_channel_window_adjust, 0, 0, 0, 77 }) != null) {
            adjusts += 1;
        }
    }
    try testing.expect(adjusts > 0);
}

test "컨트롤 채널의 모르는 요청에도 want_reply 면 답한다" {
    // OpenSSH 는 `keepalive@openssh.com` 을 채널 요청으로 보낸다(§5.4) — 답이 없으면 연결이
    // 죽은 것으로 본다. 터미널 채널에는 그 답이 있는데 컨트롤에만 없으면, **목록 화면을 오래
    // 열어 둔 세션이 끊긴다**.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_request);
    try wr.u32be(control_local_id);
    try wr.string("keepalive@openssh.com");
    try wr.boolean(true);
    const step = try feedChannelBuffers(&c, wr.written(), &out, &scr, &ctl);
    try testing.expect(std.mem.indexOf(u8, step.wire, &[_]u8{ channel.msg_channel_failure, 0, 0, 0, 77 }) != null);
}

test "한 feed 안에 두 채널의 데이터가 섞여 와도 각자 간다" {
    // 실서버는 두 채널의 패킷을 **한 TCP 조각에 섞어** 보낸다. 라우팅이 상태에 의존하면(예:
    // "마지막으로 본 채널") 이 자리에서 갈린다 — 우리는 받은 번호로만 고르므로 순서가 어떻든
    // 같아야 한다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    // **한 패킷 몫만 주면 한 번에 하나씩만 간다**(배압 규칙이 그렇다 — 화면 버퍼도 같다).
    // 여러 패킷을 한 걸음에 처리하려면 그만큼 여유가 있어야 한다.
    var ctl: [128 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;
    var pkt: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(31);

    var n: usize = 0;
    n += try packet.write(pkt[n..], try channelData(&buf, control_local_id, "{\"a\":1}\n"), prng.random());
    n += try packet.write(pkt[n..], try channelData(&buf, shell_local_id, "screen1"), prng.random());
    n += try packet.write(pkt[n..], try channelData(&buf, control_local_id, "{\"b\":2}\n"), prng.random());
    n += try packet.write(pkt[n..], try channelData(&buf, shell_local_id, "screen2"), prng.random());

    const step = try c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr, .control = &ctl });
    try testing.expectEqual(n, step.consumed);
    try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", step.control);
    try testing.expectEqualStrings("screen1screen2", step.screen);
}

test "같은 feed 안에서 컨트롤이 닫히고 터미널 데이터가 이어져도 잃지 않는다" {
    // 두 사건이 한 조각에 오면, 닫힘 처리가 루프를 끊거나 상태를 잘못 옮길 때 **뒤에 온 화면
    // 바이트가 사라진다**. 사라진 바이트는 "가끔 글자가 빠진다" 로만 보인다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;
    var pkt: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(32);

    var close_buf: [16]u8 = undefined;
    var cw = wire.Writer.init(&close_buf);
    try cw.byte(channel.msg_channel_close);
    try cw.u32be(control_local_id);

    var n: usize = 0;
    n += try packet.write(pkt[n..], cw.written(), prng.random());
    n += try packet.write(pkt[n..], try channelData(&buf, shell_local_id, "after"), prng.random());

    const step = try c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr, .control = &ctl });
    try testing.expectEqual(ControlState.closed, c.controlState());
    try testing.expectEqualStrings("after", step.screen);
    try testing.expect(step.state != .closed);
}

test "열지 않은 채널 번호로 온 메시지는 받지 않는다" {
    // 우리가 연 번호는 둘뿐이다(터미널 0·컨트롤 1). 그 밖의 번호로 온 채널 메시지는 프로토콜
    // 위반이라 거절한다 — 조용히 삼키면 **어느 흐름의 바이트인지 모르는 채로** 화면이나 wire 에
    // 섞일 길이 생긴다.
    //
    // (변이 검사 메모: 라우팅 조건을 `!= shell` 로 바꿔도 결과가 같다 — 어느 채널이 받든
    //  자기 번호가 아니면 거절하기 때문이다. 그 변이는 **동등**이고, 그것이 이 설계의 안전판이다.)
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [64 * 1024]u8 = undefined;
    var buf: [256]u8 = undefined;
    var pkt: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(33);
    const n = try packet.write(&pkt, try channelData(&buf, 9, "nope"), prng.random());
    // 이름이 정확하다: **틀린 채널**이지 "모르는 메시지" 가 아니다(§5 위반의 이름을 남긴다).
    try testing.expectError(
        channel.Error.WrongChannel,
        c.feedBuffers(pkt[0..n], .{ .wire = &out, .screen = &scr, .control = &ctl }),
    );
}

test "서버가 채널을 열자고 하면 UNIMPLEMENTED 가 아니라 OPEN_FAILURE 로 답한다" {
    // §5.1 — "responds with either SSH_MSG_CHANNEL_OPEN_CONFIRMATION or
    // SSH_MSG_CHANNEL_OPEN_FAILURE". 우리는 `session` 말고는 안 열지만(계약 §3), 서버는
    // `x11`·`forwarded-tcpip`·`auth-agent@openssh.com` 을 열자고 할 수 있다.
    //
    // 예전에는 이 메시지가 "모르는 것" 으로 흘러 `UNIMPLEMENTED`(§11.4 — 모르는 **번호**용)를
    // 받았다. 그러면 상대는 답을 못 받은 셈이라 **열지도 닫지도 못한 채널을 붙들고 기다린다**.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open);
    try wr.string("x11");
    try wr.u32be(31); // 상대가 고른 번호
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    const step = try feedChannel(&c, wr.written(), &out, &scr);

    const sent = try packet.read(step.wire);
    try testing.expectEqual(channel.msg_channel_open_failure, sent.payload[0]);
    // **상대가 보낸 번호로 답한다** — 우리 번호가 아니다.
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 31 }, sent.payload[1..5]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 3 }, sent.payload[5..9]); // unknown channel type
    // 세션은 그대로 산다.
    try testing.expectEqual(State.ready, step.state);
}

test "거절 답은 우리 채널 상태를 안 건드린다" {
    var c = readyClient();
    var out: [8192]u8 = undefined;
    var scr: [64 * 1024]u8 = undefined;
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open);
    try wr.string("auth-agent@openssh.com");
    try wr.u32be(0); // **우리 번호와 같은 값**을 보내도 우리 채널을 건드리면 안 된다
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    _ = try feedChannel(&c, wr.written(), &out, &scr);
    try testing.expectEqual(channel.State.open, c.ch.state);
    const r = try c.write("ls\n", &out);
    try testing.expectEqual(@as(usize, 3), r.sent);
}

test "열리는 중인 컨트롤 채널을 닫으면 «열린 뒤에» 닫힘이 나간다 — 뜻이 사라지지 않는다" {
    // **실기에서 잡았다**(2026-09-04, 시뮬레이터 + 임시 sshd). 폰에서 세션 화면을 열고 곧바로
    // 뒤로 나가면(열고 2초, 나가고 1초) 원격 `maru attach --stream` 이 **안 죽고 남았다** —
    // 부모가 `sshd-session` 인 고아가 registry 의 observer 자리를 4분째 붙들고 있었다.
    //
    // 원인은 여기다. `CHANNEL_CLOSE` 는 상대 번호를 싣는데(§5.3) 그 번호는
    // `CHANNEL_OPEN_CONFIRMATION` 이 준다 — 그래서 확인 전에는 못 보낸다. 예전에는 그 자리에서
    // `writeClose` 가 `UnexpectedMessage` 로 튀어나갔고, 호출자(`maru_mobile_ssh_close_control`)의
    // 오류를 host 가 **안 봤다**. 그러면 우리는 「닫았다」고 믿는데 원격 채널은 그대로 열려
    // exec 이 돌고, 그 뒤 모든 열기는 `self.control` 이 차 있어 `NOT_READY` → 5초 마감 → 포기라
    // **세션을 바꾸는 길이 통째로 막혔다**(§4a 「한 번에 control 하나」).
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru attach --stream " ++ ("0" ** 32), &out);
    try testing.expectEqual(ControlState.opening, c.controlState());

    // **확인이 오기 전에 닫는다** — 여기서 오류가 나면 안 되고, 선에 나갈 것도 아직 없다.
    const closed_now = try c.closeControl(&out);
    try testing.expectEqual(@as(usize, 0), closed_now.len);
    try testing.expectEqual(ControlState.closed, c.controlState());

    // 이제 상대가 채널을 열어 준다. **그 순간 닫힘이 나가야 한다.**
    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_confirmation);
    try wr.u32be(control_local_id);
    try wr.u32be(77); // 상대 번호 — 이것이 있어야 닫을 수 있다
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var wire_out: [8192]u8 = undefined;
    const step = try feedChannelBuffers(&c, wr.written(), &wire_out, &scr, &ctl);

    // 선에 `CHANNEL_CLOSE`(97) 가 상대 번호 77 로 실려 있어야 한다. 안 나가면 원격 명령이 산다.
    try testing.expect(containsChannelClose(step.wire, 77));
}

test "닫은 뒤에 온 요청 답이 세션을 죽이지 않는다 — 채널은 «양쪽» CLOSE 로 끝난다" {
    // **실기가 먼저 잡았다**(2026-09-04, 시뮬레이터): 위 「열린 뒤에 닫힘이 나간다」를 고치자
    // 이번에는 `MARU_SSH state=12 error=UnexpectedMessage` 로 **SSH 세션이 통째로 죽었다**.
    // 요청(`exec`)을 보내 놓고 답이 오기 전에 닫으면, 늦게 온 `CHANNEL_SUCCESS` 가
    // `.close_sent` 채널에 꽂혀 `expectOurChannel` 이 튀었다. §5.3 은 채널이 **양쪽** `CLOSE`
    // 로 끝난다고 하므로 그동안 오는 답은 **정상**이다 — `EOF`·`CLOSE` 는 이미 그렇게 받고 있었다.
    var out: [8192]u8 = undefined;
    var c = try controlOpenedClient(&out); // exec 까지 끝난 상태
    try testing.expectEqual(ControlState.ready, c.controlState());

    // 닫는다 — 채널이 `.open` 이라 곧바로 나간다.
    const closed = try c.closeControl(&out);
    try testing.expect(closed.len > 0);

    // **그 뒤에 답이 하나 더 온다**(우리가 닫기 전에 서버가 보낸 것). 세션이 살아야 한다.
    var ok: [16]u8 = undefined;
    var okw = wire.Writer.init(&ok);
    try okw.byte(channel.msg_channel_success);
    try okw.u32be(control_local_id);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var wire_out: [8192]u8 = undefined;
    _ = try feedChannelBuffers(&c, okw.written(), &wire_out, &scr, &ctl);
    // 그리고 **닫기로 정한 축을 되살리지 않는다.**
    try testing.expectEqual(ControlState.closed, c.controlState());
}

test "열리는 중에 닫으면 그 서버에서 명령이 «돌지 않는다»" {
    // 닫기로 정했는데 exec 을 보내면 원격에서 명령이 한 번 돌고(감사 로그에 남는다) 그 답이
    // 우리가 닫은 뒤에 온다. 여는 순간 곧바로 닫는 조작이 그 창이다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru attach --stream " ++ ("0" ** 32), &out);
    _ = try c.closeControl(&out); // 확인 전 — 미뤄진다

    var buf: [64]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_confirmation);
    try wr.u32be(control_local_id);
    try wr.u32be(77);
    try wr.u32be(1 << 20);
    try wr.u32be(32768);
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var wire_out: [8192]u8 = undefined;
    const step = try feedChannelBuffers(&c, wr.written(), &wire_out, &scr, &ctl);

    // 닫힘은 나가고, **`exec` 요청은 안 나간다**.
    try testing.expect(containsChannelClose(step.wire, 77));
    try testing.expect(!containsChannelRequest(step.wire, 77));
}

test "새 컨트롤 채널은 옛 채널의 «닫으려던 뜻» 을 물려받지 않는다" {
    // 적대적 검증 1회차가 잡았다. `control_deferred_close` 는 **그 채널**을 닫으려던 뜻인데,
    // 남은 채로 다음 채널을 열면 `flushDeferred` 가 **방금 연 채널**을 열리는 순간 닫는다 —
    // 사용자에게는 「눌렀는데 바로 꺼진다」로 보인다.
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru control --stdio", &out);
    _ = try c.closeControl(&out); // 확인 전 — 미뤄진다
    try testing.expect(c.control_deferred_close);

    // 그 채널을 접고(거절) 새로 연다.
    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_failure);
    try wr.u32be(control_local_id);
    try wr.u32be(1);
    try wr.string("no");
    try wr.string("");
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var wire_out: [8192]u8 = undefined;
    _ = try feedChannelBuffers(&c, wr.written(), &wire_out, &scr, &ctl);
    _ = try c.openControl("maru attach --stream " ++ ("0" ** 32), &out);
    try testing.expect(!c.control_deferred_close); // 새 채널은 깨끗하다

    // 열어 준다 — **닫힘이 나가면 안 된다**(그 뜻은 앞 채널 것이었다).
    var wr2 = wire.Writer.init(&buf);
    try wr2.byte(channel.msg_channel_open_confirmation);
    try wr2.u32be(control_local_id);
    try wr2.u32be(88);
    try wr2.u32be(1 << 20);
    try wr2.u32be(32768);
    const step = try feedChannelBuffers(&c, wr2.written(), &wire_out, &scr, &ctl);
    try testing.expect(!containsChannelClose(step.wire, 88));
    try testing.expectEqual(ControlState.requesting_exec, c.controlState());
}

test "열기가 거절되면 미뤄 둔 닫힘을 접는다 — 영영 안 열릴 채널을 기다리지 않는다" {
    // 위 미룸이 **영원히 남으면** 안 된다. 열기가 거절된 채널은 번호를 영영 못 받으므로 낼 것이
    // 없고, 그 뜻은 그 자리에서 접혀야 한다(안 접으면 매 `feed` 마다 헛돈다).
    var c = readyClient();
    var out: [8192]u8 = undefined;
    _ = try c.openControl("maru control --stdio", &out);
    _ = try c.closeControl(&out); // 확인 전 — 미뤄진다
    try testing.expect(c.control_deferred_close);

    var buf: [128]u8 = undefined;
    var wr = wire.Writer.init(&buf);
    try wr.byte(channel.msg_channel_open_failure);
    try wr.u32be(control_local_id);
    try wr.u32be(1); // reason: administratively prohibited
    try wr.string("no");
    try wr.string("");
    var scr: [64 * 1024]u8 = undefined;
    var ctl: [32 * 1024]u8 = undefined;
    var wire_out: [8192]u8 = undefined;
    _ = try feedChannelBuffers(&c, wr.written(), &wire_out, &scr, &ctl);
    try testing.expect(!c.control_deferred_close);
}

/// 선에 `CHANNEL_REQUEST`(= `exec`) 가 그 번호로 실려 있나.
fn containsChannelRequest(wire_bytes: []const u8, recipient: u32) bool {
    var want: [5]u8 = undefined;
    want[0] = channel.msg_channel_request;
    std.mem.writeInt(u32, want[1..5], recipient, .big);
    return std.mem.indexOf(u8, wire_bytes, &want) != null;
}

/// 선에 `CHANNEL_CLOSE` 가 그 번호로 실려 있나. **패킷을 뜯지 않고 바이트로 본다** — 이 판정이
/// 재려는 것은 「나갔나」이지 「어떻게 감쌌나」가 아니다.
fn containsChannelClose(wire_bytes: []const u8, recipient: u32) bool {
    var want: [5]u8 = undefined;
    want[0] = channel.msg_channel_close;
    std.mem.writeInt(u32, want[1..5], recipient, .big);
    return std.mem.indexOf(u8, wire_bytes, &want) != null;
}
