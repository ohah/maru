//! `session` 채널 하나 — 열기·`pty-req`·`shell`·`exec`·데이터·`window-change`·종료(RFC 4254 §5·§6).
//!
//! **이 파일은 채널 하나를 든다** — 채널 표가 아니다. 여러 채널을 여는 것은 드라이버
//! (`client.zig`)가 이 구조체를 여러 개 들고 **받은 번호로 골라 주는** 일이고, 여기서는 우리 것이
//! 아닌 번호로 온 메시지를 받지 않는 것으로 그 규율을 받친다.
//!
//! 지금 열리는 채널은 둘이다: 터미널(`pty-req`+`shell`)과 컨트롤(`exec`, pty 없음 —
//! [컨트롤 플레인 §4a](../../../docs/control-plane.md)).
//!
//! **흐름 제어는 양방향 다 여기 있다.**
//!
//! *보내는 쪽*: 상대가 광고한 윈도·최대 패킷을 넘겨 보내는 것은 명세 위반이고(§5.2 "MUST NOT
//! generate data packets larger than..."), 어기면 서버가 흘려도 되므로 **조용히 데이터가 사라진다**.
//!
//! *받는 쪽*: 우리가 광고한 윈도는 상대가 보낼 때마다 줄고, `WINDOW_ADJUST` 로 채워 주지 않으면
//! **상대가 멈춘다**(계약 §3.1). 이 실패는 처음에 안 보인다 — 로그인하고 몇 줄 치는 동안은 초기
//! 윈도 안이라 멀쩡하고, `cat 큰파일` 에서 갑자기 멈춘다.
//!
//! **잊으면 조용히 멈추는 대신 시끄럽게 틀리게 만들었다.** 소비는 `receive` 가 자동으로 하므로
//! 잊을 수 없고, 채워 주기를 잊은 채 윈도가 바닥나면 그다음 데이터에서 `WindowExhausted` 로
//! 죽는다. 멈춤은 원인을 짚기 어렵지만 오류는 자리를 알려 준다.

const std = @import("std");
const wire = @import("wire.zig");

/// RFC 4250 §4.1.2. `SSH_MSG_CHANNEL_*` 와 연결 프로토콜의 전역 요청.
pub const msg_global_request: u8 = 80;
pub const msg_request_success: u8 = 81;
pub const msg_request_failure: u8 = 82;
pub const msg_channel_open: u8 = 90;
pub const msg_channel_open_confirmation: u8 = 91;
pub const msg_channel_open_failure: u8 = 92;
pub const msg_channel_window_adjust: u8 = 93;
pub const msg_channel_data: u8 = 94;
pub const msg_channel_extended_data: u8 = 95;
pub const msg_channel_eof: u8 = 96;
pub const msg_channel_close: u8 = 97;
pub const msg_channel_request: u8 = 98;
pub const msg_channel_success: u8 = 99;
pub const msg_channel_failure: u8 = 100;

/// 우리가 여는 유일한 채널 종류(RFC 4254 §6.1).
pub const channel_type_session = "session";

/// 채널 요청 이름(§6.2·§6.5·§6.7·§6.10).
pub const request_pty = "pty-req";
pub const request_shell = "shell";
pub const request_exec = "exec";
pub const request_window_change = "window-change";
pub const request_exit_status = "exit-status";
pub const request_exit_signal = "exit-signal";

/// `SSH_MSG_CHANNEL_EXTENDED_DATA` 의 유일한 정의된 종류(§5.2) — 원격의 stderr 다.
pub const extended_data_stderr: u32 = 1;

/// 열기 실패 사유(§5.1). 값을 그대로 사용자에게 보여 줄 수 있게 이름을 든다.
pub const OpenFailureReason = enum(u32) {
    administratively_prohibited = 1,
    connect_failed = 2,
    unknown_channel_type = 3,
    resource_shortage = 4,
    _,
};

pub const Error = error{
    /// 이 메시지는 채널 메시지가 아니다.
    NotChannelMessage,
    /// **우리 채널 번호가 아니다.** 채널이 하나뿐인데 다른 번호가 왔다 — 상대가 헷갈렸거나
    /// 우리를 헷갈리게 하려는 것이다. 둘 다 이어 갈 이유가 없다.
    WrongChannel,
    /// 지금 상태에서 올 수 없는 메시지다(예: 열기 전에 데이터).
    UnexpectedMessage,
    /// 상대가 광고한 윈도나 최대 패킷을 넘겨 보내려 한다(§5.2 — 우리가 어기면 안 된다).
    WouldExceedWindow,
    /// 윈도가 `2^32 - 1` 을 넘게 늘어난다(§5.2 — "MUST NOT be increased above").
    WindowOverflow,
    /// **상대가 우리 윈도를 넘겨 보냈다.** §5.2 는 "Both parties MAY ignore all extra data" 라
    /// 하지만 우리는 **흘리지 않고 오류를 낸다** — 터미널 출력이 조용히 사라지면 화면이 깨진 채
    /// 남고, 그 증상은 우리 렌더 결함과 구별되지 않는다. 게다가 이 자리는 우리가 채워 주기를
    /// 잊었을 때 나는 자리이기도 하다(잊으면 상대가 멈추는 대신 여기서 죽는다).
    WindowExhausted,
    /// 상대가 우리가 광고한 최대 패킷보다 큰 데이터를 보냈다(§5.2).
    DataExceedsMaxPacket,
} || wire.Error || wire.Writer.WriteError;

/// 채널이 어디까지 왔나.
///
/// **`opening` 과 `open` 을 가르는 이유.** 열기를 보낸 뒤 확인을 받기 전에는 상대 채널 번호도
/// 상대 윈도도 모른다 — 그 사이에 데이터를 쓰려는 드라이버는 **번호 0 으로 아무 데나** 보내게
/// 된다. 상태로 갈라 두면 그것이 컴파일이 아니라 오류로 막힌다.
pub const State = enum {
    /// 아직 아무것도 안 보냈다.
    idle,
    /// `CHANNEL_OPEN` 을 보냈고 확인을 기다린다.
    opening,
    /// 양쪽 번호와 윈도가 정해졌다 — 데이터가 오간다.
    open,
    /// 우리가 `CHANNEL_EOF` 를 보냈다. **채널은 아직 열려 있다**(§5.3 — 반대 방향은 계속 온다).
    eof_sent,
    /// 우리가 `CHANNEL_CLOSE` 를 보냈고 상대 것을 기다린다.
    close_sent,
    /// 양쪽 `CHANNEL_CLOSE` 가 오갔다.
    closed,
    /// 열기가 거절됐다.
    open_failed,
};

/// 우리가 광고하는 기본값.
///
/// **윈도를 크게 잡는 이유.** 이 값이 "상대가 `WINDOW_ADJUST` 를 기다리지 않고 보낼 수 있는 양"
/// 이다. 작게 잡으면 대량 출력에서 왕복이 잦아져 느려지고, 크게 잡으면 그만큼 우리가 받아 둘
/// 각오를 한다는 뜻이다. OpenSSH 도 이 자릿수(2MiB)를 쓴다.
pub const default_window: u32 = 2 * 1024 * 1024;

/// 우리가 받겠다고 광고하는 한 패킷 최대 크기.
///
/// **`packet.max_packet` 보다 작아야 한다**(§5.2 — "MUST NOT advertise a maximum packet size that
/// would result in transport packets larger than its transport layer is willing to receive").
/// 전송 계층 상한이 256KiB 이고 채널 데이터에는 머리(메시지 번호·채널 번호·길이)와 패딩·태그가
/// 붙으므로 32KiB 로 넉넉히 둔다 — §5.2 가 요구하는 하한(32768)과 같은 자릿수다.
pub const default_max_packet: u32 = 32 * 1024;

/// 상대에게서 받은 채널 사건. **union 이라 무시할 수 없다** — 드라이버는 `switch` 를 써야 한다.
pub const Event = union(enum) {
    /// 열기가 받아들여졌다. 번호와 윈도는 이미 `Channel` 에 반영돼 있다.
    opened,
    /// 열기가 거절됐다. `description` 은 **서버가 고른 문자열**이다(아래 주의).
    open_failed: OpenFailure,
    /// 상대가 우리 송신 윈도를 늘렸다. 반영은 이미 끝났다.
    window_adjusted: u32,
    /// 채널 데이터(원격의 stdout).
    data: []const u8,
    /// 확장 데이터. `type_code == extended_data_stderr` 면 원격의 stderr 다.
    extended_data: ExtendedData,
    /// 상대가 더 보낼 것이 없다. **채널은 아직 열려 있다.**
    eof,
    /// 상대가 채널을 닫았다.
    closed,
    /// 원격 명령이 끝났다(§6.10).
    exit_status: u32,
    /// 원격 명령이 신호로 죽었다(§6.10).
    exit_signal: ExitSignal,
    /// 우리가 보낸 요청이 받아들여졌다(`want_reply` 를 켠 것에만 온다).
    request_success,
    /// 우리가 보낸 요청이 거절됐다.
    request_failure,
    /// 우리가 모르는 채널 요청. **`want_reply` 가 참이면 답해야 한다**(§5.4) —
    /// `writeChannelFailure` 가 그 답이다.
    unknown_request: UnknownRequest,

    pub const OpenFailure = struct {
        reason: OpenFailureReason,
        /// **서버가 고른 문자열이다.** 화면에 올리기 전에 반드시 거른다 — 배너와 같은 이유이고
        /// 같은 거름망(`userauth.sanitizeBanner`)을 쓴다. 여기서 안 거르는 것은 이 층이 표시
        /// 정책을 모르기 때문이고, 그래서 그 사실을 타입 옆에 적어 둔다.
        description: []const u8,
        language: []const u8,
    };

    pub const ExtendedData = struct {
        type_code: u32,
        data: []const u8,
    };

    pub const ExitSignal = struct {
        /// `SIG` 접두 없이 온다(예: `TERM`).
        name: []const u8,
        core_dumped: bool,
        /// **서버가 고른 문자열이다** — 위 `description` 과 같은 주의가 붙는다.
        message: []const u8,
        language: []const u8,
    };

    pub const UnknownRequest = struct {
        name: []const u8,
        want_reply: bool,
    };
};

/// 터미널 크기(§6.2·§6.7). **픽셀은 0 이어도 된다** — 명세가 "Zero dimension parameters MUST be
/// ignored" 라 하고, 문자 단위 값이 픽셀을 덮는다.
pub const TerminalSize = struct {
    cols: u32,
    rows: u32,
    width_px: u32 = 0,
    height_px: u32 = 0,
};

/// `session` 채널 하나.
/// 상대가 열자고 한 채널을 **거절**한다(§5.1).
///
/// **채널이 아니라 메시지에 답하는 것이라 인스턴스가 없다.** 우리는 `session` 둘 말고는
/// 안 열므로(계약 §3), 서버가 `x11`·`forwarded-tcpip`·`auth-agent@openssh.com` 을 열자고
/// 하면 여기로 온다.
///
/// **`UNIMPLEMENTED` 로 답하면 안 된다.** 그것은 §11.4 의 "모르는 **메시지 번호**" 용이고,
/// `CHANNEL_OPEN` 은 우리가 아는 번호다. 명세는 이 메시지에 **"either
/// SSH_MSG_CHANNEL_OPEN_CONFIRMATION or SSH_MSG_CHANNEL_OPEN_FAILURE"** 로 답하라고
/// 못박는다 — 엉뚱한 답을 보내면 상대는 열린 것도 실패한 것도 아닌 채널을 붙들고 기다린다.
///
/// `recipient channel` 은 **상대가 보낸 sender channel** 이다(우리 번호가 아니다).
pub fn writeOpenFailure(out: []u8, sender_channel: u32, reason: OpenFailureReason) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_channel_open_failure);
    try w.u32be(sender_channel);
    try w.u32be(@intFromEnum(reason));
    try w.string("maru opens no channels");
    try w.string(""); // language tag (RFC 3066) — 비워 둔다
    return w.written();
}

/// 상대가 보낸 `CHANNEL_OPEN` 에서 **그쪽 채널 번호**를 읽는다(§5.1: type, sender channel, …).
pub fn readOpenSender(payload: []const u8) Error!u32 {
    var r = wire.Reader.init(payload);
    if (try r.byte() != msg_channel_open) return Error.UnexpectedMessage;
    _ = try r.string(); // channel type
    return try r.u32be();
}

pub const Channel = struct {
    /// 우리가 고른 번호. 채널이 하나뿐이라 값 자체는 아무것이나 되지만, **상대가 보낸 번호와
    /// 대조하는 데 쓴다**.
    local_id: u32 = 0,
    /// 상대가 고른 번호. `open` 이 되기 전에는 뜻이 없다.
    remote_id: u32 = 0,
    state: State = .idle,

    /// **우리가 광고한 윈도** — 상대가 우리에게 보낼 수 있는 **남은** 양. 데이터를 받을 때마다
    /// 줄고 `writeWindowAdjust` 로 는다.
    local_window: u32 = default_window,
    /// 우리가 유지하려는 윈도 크기. `local_window` 를 여기까지 채운다.
    local_window_max: u32 = default_window,
    local_max_packet: u32 = default_max_packet,

    /// **상대가 광고한 윈도** — 우리가 보낼 수 있는 양. 보낼 때마다 줄고 `WINDOW_ADJUST` 로 는다.
    remote_window: u32 = 0,
    remote_max_packet: u32 = 0,

    /// 상대의 `CHANNEL_CLOSE` 를 받았나. **`state` 만으로는 못 센다** — `close` 는 양쪽이 각자
    /// 보내야 끝나는데(§5.3), 그 순서가 둘이라서다. 우리가 먼저 보냈으면 `close_sent` 에서
    /// 상대 것을 받아 `closed` 가 되지만, **상대가 먼저 보냈을 때**는 우리가 답을 쓰는 자리에서
    /// "이미 받았다" 를 알아야 `closed` 로 갈 수 있다.
    ///
    /// 이 값이 없으면 그 경우 채널이 영영 `close_sent` 에 남고, **번호를 다시 못 쓴다** —
    /// 컨트롤 채널을 닫았다 다시 여는 길이 막힌다(적대적 검증이 이 자리를 잡았다).
    remote_closed: bool = false,

    /// `CHANNEL_OPEN` 을 쓴다(§5.1). 쓴 뒤 상태가 `opening` 이 된다.
    pub fn writeOpen(self: *Channel, out: []u8, local_id: u32) Error![]const u8 {
        if (self.state != .idle) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_open);
        try w.string(channel_type_session);
        try w.u32be(local_id);
        // **광고하는 값과 유지하려는 값은 같다.** 다르면 첫 보충 때 광고보다 커지거나 작아진다.
        self.local_window = self.local_window_max;
        try w.u32be(self.local_window);
        try w.u32be(self.local_max_packet);
        self.local_id = local_id;
        self.state = .opening;
        return w.written();
    }

    /// `pty-req` 를 쓴다(§6.2). **`want_reply` 를 켠다** — 서버가 pty 를 못 주면 알아야 한다.
    ///
    /// `modes` 는 §8 의 인코딩된 터미널 모드다. **빈 문자열이 합법이고 그것이 우리 기본**이다 —
    /// 모드를 지정하지 않으면 서버가 자기 기본을 쓴다.
    pub fn writePtyReq(
        self: *Channel,
        out: []u8,
        term: []const u8,
        size: TerminalSize,
        modes: []const u8,
    ) Error![]const u8 {
        if (self.state != .open) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_request);
        try w.u32be(self.remote_id);
        try w.string(request_pty);
        try w.boolean(true);
        try w.string(term);
        try w.u32be(size.cols);
        try w.u32be(size.rows);
        try w.u32be(size.width_px);
        try w.u32be(size.height_px);
        try w.string(modes);
        return w.written();
    }

    /// `shell` 을 쓴다(§6.5). **`want_reply` 를 켠다** — 명세도 "RECOMMENDED that the reply to
    /// these messages be requested and checked" 라고 한다. 안 켜면 셸이 안 떴는데도 우리는
    /// 기다리기만 한다.
    pub fn writeShell(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .open) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_request);
        try w.u32be(self.remote_id);
        try w.string(request_shell);
        try w.boolean(true);
        return w.written();
    }

    /// `exec` 을 쓴다(§6.5) — 셸 대신 **명령 하나**를 돌린다.
    ///
    /// 컨트롤 채널이 이것을 쓴다([컨트롤 플레인 §4a](../../../docs/control-plane.md)): 터미널
    /// 채널에 명령을 쳐 넣으면 pty 에코와 프롬프트가 섞여 ndjson 이 깨지므로, **채널을 따로 열고
    /// pty 없이** 명령을 돌린다.
    ///
    /// **`want_reply` 를 켠다** — `shell` 과 같은 이유다. 다만 성공 답이 뜻하는 것은 "명령을
    /// 시작했다" 까지이고, 그 명령이 실제로 있었는지는 `exit-status` 로 온다(없는 명령이면
    /// 셸이 127 을 낸다 — 채널 요청 자체는 성공한다).
    pub fn writeExec(self: *Channel, out: []u8, command: []const u8) Error![]const u8 {
        if (self.state != .open) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_request);
        try w.u32be(self.remote_id);
        try w.string(request_exec);
        try w.boolean(true);
        try w.string(command);
        return w.written();
    }

    /// `window-change` 를 쓴다(§6.7). **`want_reply` 는 거짓이어야 한다** — 명세가 그렇게 못박고
    /// ("A response SHOULD NOT be sent"), 켜면 오지 않을 답을 기다리게 된다.
    pub fn writeWindowChange(self: *Channel, out: []u8, size: TerminalSize) Error![]const u8 {
        if (self.state != .open and self.state != .eof_sent) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_request);
        try w.u32be(self.remote_id);
        try w.string(request_window_change);
        try w.boolean(false);
        try w.u32be(size.cols);
        try w.u32be(size.rows);
        try w.u32be(size.width_px);
        try w.u32be(size.height_px);
        return w.written();
    }

    /// 한 번에 보낼 수 있는 최대 바이트 수. **상대 윈도와 최대 패킷 중 작은 쪽**(§5.2).
    ///
    /// 드라이버는 이 값으로 잘라 보낸다. 0 이면 지금은 못 보낸다 — 상대의 `WINDOW_ADJUST` 를
    /// 기다려야 한다(그것이 흐름 제어의 전부다).
    pub fn sendableLen(self: Channel) u32 {
        if (self.state != .open and self.state != .eof_sent) return 0;
        return @min(self.remote_window, self.remote_max_packet);
    }

    /// `CHANNEL_DATA` 를 쓴다(§5.2). **윈도를 넘기면 쓰지 않고 오류를 낸다.**
    ///
    /// 넘겨 보내는 것은 명세 위반이고, 서버는 그것을 흘려도 되고 끊어도 된다("Both parties MAY
    /// ignore all extra data") — 즉 **조용히 데이터가 사라질 수 있다**. 그런 실패는 나중에
    /// "가끔 입력이 씹힌다" 로 나타나 원인을 짚기 어렵다. 여기서 막는다.
    pub fn writeData(self: *Channel, out: []u8, data: []const u8) Error![]const u8 {
        if (self.state != .open and self.state != .eof_sent) return Error.UnexpectedMessage;
        if (data.len > self.sendableLen()) return Error.WouldExceedWindow;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_data);
        try w.u32be(self.remote_id);
        try w.string(data);
        // **쓴 뒤에 줄인다.** 위에서 실패하면 윈도는 그대로여야 한다 — 안 그러면 버퍼 부족
        // 한 번에 윈도가 새고, 그 뒤로는 보낼 수 있는 양을 우리가 실제보다 적게 안다.
        self.remote_window -= @intCast(data.len);
        return w.written();
    }

    /// `CHANNEL_EOF` 를 쓴다(§5.3). **윈도를 안 먹는다** — 명세가 "does not consume window space
    /// and can be sent even if no window space is available" 라고 한다.
    pub fn writeEof(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .open) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_eof);
        try w.u32be(self.remote_id);
        self.state = .eof_sent;
        return w.written();
    }

    /// `CHANNEL_CLOSE` 를 쓴다(§5.3). 이것도 윈도를 안 먹는다.
    /// 지금 `CHANNEL_CLOSE` 를 낼 수 있나 — 세 갈래다.
    ///
    /// **번호가 있어야 닫을 수 있다.** `CHANNEL_CLOSE` 는 상대 번호를 싣는데(§5.3) 그 번호는
    /// `CHANNEL_OPEN_CONFIRMATION` 이 준다. 그래서 «아직 열리는 중» 은 실패가 아니라 **기다림**
    /// 이다 — 그것을 실패로 접으면 닫으려던 뜻이 사라지고 원격 명령이 고아로 남는다
    /// (실기 2026-09-04, `Client.closeControl` 주석 참고).
    pub const CloseDisposition = enum {
        /// 지금 낸다.
        send,
        /// 아직 번호가 없다 — 열리면 그때 낸다.
        wait,
        /// 낼 것이 없다(이미 닫았거나, 열기가 거절돼 영영 안 열린다).
        done,
    };

    pub fn closeDisposition(self: Channel) CloseDisposition {
        return switch (self.state) {
            .open, .eof_sent => .send,
            .idle, .opening => .wait,
            .close_sent, .closed, .open_failed => .done,
        };
    }

    pub fn writeClose(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .open and self.state != .eof_sent) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_close);
        try w.u32be(self.remote_id);
        // 상대 것을 이미 받았으면 이 한 번으로 끝이다 — 안 그러면 답을 기다린다.
        self.state = if (self.remote_closed) .closed else .close_sent;
        return w.written();
    }

    /// 모르는 채널 요청에 대한 답(§5.4 — "If the request is not recognized ... SSH_MSG_CHANNEL_FAILURE
    /// is returned"). `Event.unknown_request` 의 `want_reply` 가 참일 때만 보낸다.
    pub fn writeChannelFailure(self: Channel, out: []u8) Error![]const u8 {
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_failure);
        try w.u32be(self.remote_id);
        return w.written();
    }

    /// 받은 페이로드를 읽고 **상태에 반영까지 한다**.
    ///
    /// **파싱과 반영을 한 번에 하는 것이 요점이다.** 둘로 나누면 드라이버가 뒤쪽을 잊을 수 있고,
    /// 잊으면 상대 번호나 윈도가 낡은 채로 남아 그다음 전송이 조용히 틀린다. 이 층에서 같은
    /// 모양의 결함을 이미 겪었다(전송기의 협상 반영 — `transport.applyNegotiation` 주석).
    pub fn receive(self: *Channel, payload: []const u8) Error!Event {
        var r = wire.Reader.init(payload);
        const msg = try r.byte();
        return switch (msg) {
            msg_channel_open_confirmation => try self.recvOpenConfirmation(&r),
            msg_channel_open_failure => try self.recvOpenFailure(&r),
            msg_channel_window_adjust => try self.recvWindowAdjust(&r),
            msg_channel_data => try self.recvData(&r),
            msg_channel_extended_data => try self.recvExtendedData(&r),
            msg_channel_eof => blk: {
                try self.expectOurChannel(&r, &.{ .open, .eof_sent, .close_sent });
                break :blk .eof;
            },
            msg_channel_close => blk: {
                try self.expectOurChannel(&r, &.{ .open, .eof_sent, .close_sent });
                // **양쪽이 다 보내야 닫힌 것이다**(§5.3). 우리가 아직 안 보냈으면 드라이버가
                // `writeClose` 로 답해야 하고, 상태는 그때 `closed` 가 된다.
                self.remote_closed = true;
                if (self.state == .close_sent) self.state = .closed;
                break :blk .closed;
            },
            msg_channel_request => try self.recvRequest(&r),
            // **우리가 `CLOSE` 를 보낸 뒤에도 답은 온다**(§5.3 — 채널은 «양쪽» `CLOSE` 가 오가야
            // 끝난다). 그래서 `close_sent` 도 받는다. 예전에는 `.open`·`.eof_sent` 만 받아,
            // 요청을 보내 놓고 답이 오기 전에 닫으면 그 답이 **세션을 통째로 죽였다**
            // (실기 2026-09-04: `MARU_SSH state=12 error=UnexpectedMessage` — 폰이 세션 화면을
            // 열자마자 나가는 평범한 조작이 그 창을 만든다). `EOF`·`CLOSE` 는 이미 그렇게 받는다.
            msg_channel_success => blk: {
                try self.expectOurChannel(&r, &.{ .open, .eof_sent, .close_sent });
                break :blk .request_success;
            },
            msg_channel_failure => blk: {
                try self.expectOurChannel(&r, &.{ .open, .eof_sent, .close_sent });
                break :blk .request_failure;
            },
            else => Error.NotChannelMessage,
        };
    }

    /// 받은 데이터만큼 우리 윈도를 줄인다. **`receive` 가 자동으로 부르므로 잊을 수 없다.**
    fn consumeWindow(self: *Channel, len: usize) Error!void {
        if (len > self.local_max_packet) return Error.DataExceedsMaxPacket;
        if (len > self.local_window) return Error.WindowExhausted;
        self.local_window -= @intCast(len);
    }

    /// 지금 채워 줘야 할 양. `0` 이면 아직 아니다.
    ///
    /// **절반에서 채운다.** 매번 보내면 데이터 한 조각마다 패킷이 하나씩 더 붙어 대량 전송이
    /// 느려지고, 바닥까지 기다리면 그 사이에 상대가 멈춘다. 절반은 그 둘 사이이고 OpenSSH 도
    /// 같은 자리에서 채운다.
    ///
    /// **나누지 곱하지 않는다.** 처음에는 `local_window * 2 >= local_window_max` 로 썼는데,
    /// 윈도가 `2^31` 이상이면 그 곱이 `u32` 를 넘는다 — §5.2 는 "Implementations MUST correctly
    /// handle window sizes of up to 2^32 - 1 bytes" 라고 **명시적으로 요구**하는 구간이다.
    /// Debug 에서는 패닉이고 배포가 쓰는 ReleaseFast 에서는 조용히 감싸 돌아, 채울 필요가 없는데
    /// 채우는 패킷이 계속 나간다. 기본값(2MiB)에서는 안 닿아서 **큰 윈도를 광고한 드라이버에서만**
    /// 드러난다(적대적 검증이 잡았다).
    /// **닫힌 채널에는 보충할 것이 없다.** 이 물음과 `writeWindowAdjust` 는 같은 답을 해야
    /// 한다 — 여기서 "필요하다" 고 하고 저기서 `UnexpectedMessage` 를 내면, 그 말을 믿고 쓰는
    /// 드라이버가 **자기 실수도 아닌 오류로 죽는다**(실측: 서버가 끊은 직후 그 모양이 났다).
    pub fn pendingWindowAdjust(self: Channel) u32 {
        if (self.state != .open and self.state != .eof_sent and self.state != .close_sent) return 0;
        if (self.local_window >= self.local_window_max / 2) return 0;
        return self.local_window_max - self.local_window;
    }

    /// `WINDOW_ADJUST` 를 쓰고 우리 윈도를 채운다(§5.2).
    ///
    /// **채울 것이 없으면 오류다.** 조건 없이 부르는 드라이버는 채널당 패킷을 두 배로 만들고,
    /// 그 낭비는 대량 전송에서만 드러난다 — 그때는 원인이 여기라고 생각하기 어렵다.
    pub fn writeWindowAdjust(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .open and self.state != .eof_sent and self.state != .close_sent) {
            return Error.UnexpectedMessage;
        }
        const add = self.pendingWindowAdjust();
        if (add == 0) return Error.UnexpectedMessage;
        var w = wire.Writer.init(out);
        try w.byte(msg_channel_window_adjust);
        try w.u32be(self.remote_id);
        try w.u32be(add);
        // **쓴 뒤에 늘린다** — 보내는 쪽과 같은 이유다(버퍼가 모자라 실패하면 상대는 그 양을
        // 모르는데 우리만 아는 상태가 된다. 그러면 상대가 멈춘 뒤에도 우리는 여유가 있다고 믿는다).
        self.local_window += add;
        return w.written();
    }

    /// 채널 번호가 우리 것인지, 지금 상태에서 올 수 있는 메시지인지 본다.
    ///
    /// **번호부터 본다.** 상태만 보면 남의 채널 앞으로 온 메시지를 우리 상태에 반영하게 된다 —
    /// 채널이 하나뿐이라 "남의 것" 은 곧 상대가 헷갈렸거나 우리를 헷갈리게 하려는 것이다.
    fn expectOurChannel(self: *Channel, r: *wire.Reader, allowed: []const State) Error!void {
        const recipient = try r.u32be();
        if (recipient != self.local_id) return Error.WrongChannel;
        for (allowed) |s| if (self.state == s) return;
        return Error.UnexpectedMessage;
    }

    fn recvOpenConfirmation(self: *Channel, r: *wire.Reader) Error!Event {
        try self.expectOurChannel(r, &.{.opening});
        self.remote_id = try r.u32be();
        self.remote_window = try r.u32be();
        self.remote_max_packet = try r.u32be();
        self.state = .open;
        return .opened;
    }

    fn recvOpenFailure(self: *Channel, r: *wire.Reader) Error!Event {
        try self.expectOurChannel(r, &.{.opening});
        const reason: OpenFailureReason = @enumFromInt(try r.u32be());
        const description = try r.string();
        const language = try r.string();
        self.state = .open_failed;
        return .{ .open_failed = .{
            .reason = reason,
            .description = description,
            .language = language,
        } };
    }

    fn recvWindowAdjust(self: *Channel, r: *wire.Reader) Error!Event {
        try self.expectOurChannel(r, &.{ .open, .eof_sent, .close_sent });
        const add = try r.u32be();
        // **`2^32 - 1` 을 넘게 늘리지 않는다**(§5.2 — "The window MUST NOT be increased above").
        // 넘치면 감싸 돌아 **보낼 수 있는 양을 실제보다 적게** 알게 되고, 그 뒤로는 서버가 기다리는데
        // 우리는 못 보내는 교착이 된다. 상대가 그렇게 보냈다는 것 자체가 규칙 위반이다.
        const grown = @addWithOverflow(self.remote_window, add);
        if (grown[1] != 0) return Error.WindowOverflow;
        self.remote_window = grown[0];
        return .{ .window_adjusted = add };
    }

    fn recvData(self: *Channel, r: *wire.Reader) Error!Event {
        try self.expectOurChannel(r, &.{ .open, .eof_sent, .close_sent });
        const data = try r.string();
        try self.consumeWindow(data.len);
        return .{ .data = data };
    }

    fn recvExtendedData(self: *Channel, r: *wire.Reader) Error!Event {
        try self.expectOurChannel(r, &.{ .open, .eof_sent, .close_sent });
        const type_code = try r.u32be();
        const data = try r.string();
        // **확장 데이터도 같은 윈도를 먹는다**(§5.2 — "Data sent with these messages consumes the
        // same window as ordinary data"). 빼먹으면 stderr 가 많은 명령에서 회계가 어긋난다.
        try self.consumeWindow(data.len);
        return .{ .extended_data = .{ .type_code = type_code, .data = data } };
    }

    fn recvRequest(self: *Channel, r: *wire.Reader) Error!Event {
        // **`close_sent` 에서도 받는다.** 우리가 닫자고 보낸 뒤에도 상대의 `exit-status` 가
        // 지나가는 중일 수 있다 — 그것을 오류로 다루면 정상 종료가 실패로 보인다.
        try self.expectOurChannel(r, &.{ .open, .eof_sent, .close_sent });
        const name = try r.string();
        const want_reply = try r.boolean();
        if (std.mem.eql(u8, name, request_exit_status)) {
            return .{ .exit_status = try r.u32be() };
        }
        if (std.mem.eql(u8, name, request_exit_signal)) {
            return .{ .exit_signal = .{
                .name = try r.string(),
                .core_dumped = try r.boolean(),
                .message = try r.string(),
                .language = try r.string(),
            } };
        }
        return .{ .unknown_request = .{ .name = name, .want_reply = want_reply } };
    }
};

const testing = std.testing;

test "상수는 RFC 4250·4254 그대로다" {
    // **명세 숫자와 직접 맞댄다.** 쓰는 쪽과 읽는 쪽에 같은 상수를 쓰면 자기충족이라 오타가 안
    // 잡힌다 — 이 층에서 이미 겪었다.
    try testing.expectEqual(@as(u8, 80), msg_global_request);
    try testing.expectEqual(@as(u8, 90), msg_channel_open);
    try testing.expectEqual(@as(u8, 91), msg_channel_open_confirmation);
    try testing.expectEqual(@as(u8, 92), msg_channel_open_failure);
    try testing.expectEqual(@as(u8, 93), msg_channel_window_adjust);
    try testing.expectEqual(@as(u8, 94), msg_channel_data);
    try testing.expectEqual(@as(u8, 95), msg_channel_extended_data);
    try testing.expectEqual(@as(u8, 96), msg_channel_eof);
    try testing.expectEqual(@as(u8, 97), msg_channel_close);
    try testing.expectEqual(@as(u8, 98), msg_channel_request);
    try testing.expectEqual(@as(u8, 99), msg_channel_success);
    try testing.expectEqual(@as(u8, 100), msg_channel_failure);
    try testing.expectEqual(@as(u32, 1), extended_data_stderr);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(OpenFailureReason.administratively_prohibited));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(OpenFailureReason.unknown_channel_type));
    try testing.expectEqualStrings("session", channel_type_session);
    try testing.expectEqualStrings("pty-req", request_pty);
    try testing.expectEqualStrings("shell", request_shell);
    try testing.expectEqualStrings("window-change", request_window_change);
    try testing.expectEqualStrings("exit-status", request_exit_status);
    try testing.expectEqualStrings("exit-signal", request_exit_signal);
}

test "CHANNEL_OPEN 은 §5.1 의 자리 그대로다" {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    const bytes = try ch.writeOpen(&out, 7);

    // 바이트를 **손으로** 뜯어 본다 — 우리 Reader 로 읽으면 자리가 밀려도 같이 밀린다.
    try testing.expectEqual(@as(u8, 90), bytes[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 7 }, bytes[1..5]); // string 길이 7
    try testing.expectEqualStrings("session", bytes[5..12]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 7 }, bytes[12..16]); // sender channel
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0x20, 0, 0 }, bytes[16..20]); // 2MiB
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0x80, 0 }, bytes[20..24]); // 32KiB
    try testing.expectEqual(@as(usize, 24), bytes.len);

    try testing.expectEqual(State.opening, ch.state);
    try testing.expectEqual(@as(u32, 7), ch.local_id);
}

test "광고하는 최대 패킷은 전송 상한 안이다" {
    // §5.2: "MUST NOT advertise a maximum packet size that would result in transport packets
    // larger than its transport layer is willing to receive." 채널 데이터에는 머리와 패딩·태그가
    // 붙으므로 여유가 있어야 한다.
    const packet = @import("packet.zig");
    try testing.expect(default_max_packet < packet.max_packet);
    // §5.2 의 하한(32768)도 만족한다 — 이보다 작게 광고하면 상호운용이 나빠진다.
    try testing.expect(default_max_packet >= 32768);
}

test "열기 확인이 번호와 윈도를 반영한다" {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_confirmation);
    try w.u32be(7); // recipient = 우리 번호
    try w.u32be(42); // sender = 서버 번호
    try w.u32be(1000); // 서버 윈도
    try w.u32be(500); // 서버 최대 패킷

    const ev = try ch.receive(w.written());
    try testing.expect(ev == .opened);
    try testing.expectEqual(State.open, ch.state);
    try testing.expectEqual(@as(u32, 42), ch.remote_id);
    try testing.expectEqual(@as(u32, 1000), ch.remote_window);
    try testing.expectEqual(@as(u32, 500), ch.remote_max_packet);
    // 보낼 수 있는 양은 **둘 중 작은 쪽**이다.
    try testing.expectEqual(@as(u32, 500), ch.sendableLen());
}

test "우리 채널 번호가 아니면 받지 않는다" {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_confirmation);
    try w.u32be(8); // 우리 번호가 아니다
    try w.u32be(42);
    try w.u32be(1000);
    try w.u32be(500);
    try testing.expectError(Error.WrongChannel, ch.receive(w.written()));
    // 상태도 번호도 안 움직였다 — 거절은 흔적을 안 남긴다.
    try testing.expectEqual(State.opening, ch.state);
    try testing.expectEqual(@as(u32, 0), ch.remote_id);
}

test "열기 전에는 데이터를 못 쓴다" {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    // **상태로 막는 이유**: 열기 전에는 상대 번호를 모르므로 번호 0 으로 아무 데나 보내게 된다.
    try testing.expectError(Error.UnexpectedMessage, ch.writeData(&out, "x"));
    try testing.expectError(Error.UnexpectedMessage, ch.writeShell(&out));
    try testing.expectError(Error.UnexpectedMessage, ch.writePtyReq(&out, "xterm", .{ .cols = 80, .rows = 24 }, ""));
    _ = try ch.writeOpen(&out, 7);
    try testing.expectError(Error.UnexpectedMessage, ch.writeData(&out, "x"));
    try testing.expectEqual(@as(u32, 0), ch.sendableLen());
}

/// 열린 채널을 만든다(서버 윈도·최대 패킷을 지정).
fn openedChannel(window: u32, max_packet: u32) !Channel {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_confirmation);
    try w.u32be(7);
    try w.u32be(42);
    try w.u32be(window);
    try w.u32be(max_packet);
    _ = try ch.receive(w.written());
    return ch;
}

test "pty-req 는 §6.2 의 자리 그대로다" {
    var ch = try openedChannel(1000, 500);
    var out: [128]u8 = undefined;
    const bytes = try ch.writePtyReq(&out, "xterm-256color", .{ .cols = 80, .rows = 24 }, "");

    var r = wire.Reader.init(bytes);
    try testing.expectEqual(@as(u8, 98), try r.byte());
    try testing.expectEqual(@as(u32, 42), try r.u32be()); // recipient = 서버 번호
    try testing.expectEqualStrings("pty-req", try r.string());
    try testing.expectEqual(true, try r.boolean()); // want_reply — 못 주면 알아야 한다
    try testing.expectEqualStrings("xterm-256color", try r.string());
    try testing.expectEqual(@as(u32, 80), try r.u32be());
    try testing.expectEqual(@as(u32, 24), try r.u32be());
    try testing.expectEqual(@as(u32, 0), try r.u32be()); // 픽셀은 0 이어도 된다(§6.2)
    try testing.expectEqual(@as(u32, 0), try r.u32be());
    try testing.expectEqualStrings("", try r.string()); // 빈 모드가 합법이다
    try testing.expectEqual(@as(usize, 0), r.rest().len);
}

test "shell 은 want_reply 를 켠다" {
    var ch = try openedChannel(1000, 500);
    var out: [64]u8 = undefined;
    const bytes = try ch.writeShell(&out);
    var r = wire.Reader.init(bytes);
    try testing.expectEqual(@as(u8, 98), try r.byte());
    try testing.expectEqual(@as(u32, 42), try r.u32be());
    try testing.expectEqualStrings("shell", try r.string());
    // **켜야 한다.** 명세도 답을 요청해 확인하라고 하고, 안 켜면 셸이 안 떴는데 기다리기만 한다.
    try testing.expectEqual(true, try r.boolean());
    try testing.expectEqual(@as(usize, 0), r.rest().len);
}

test "window-change 는 want_reply 를 끈다" {
    var ch = try openedChannel(1000, 500);
    var out: [64]u8 = undefined;
    const bytes = try ch.writeWindowChange(&out, .{ .cols = 120, .rows = 40 });
    var r = wire.Reader.init(bytes);
    try testing.expectEqual(@as(u8, 98), try r.byte());
    try testing.expectEqual(@as(u32, 42), try r.u32be());
    try testing.expectEqualStrings("window-change", try r.string());
    // **꺼야 한다**(§6.7 "A response SHOULD NOT be sent") — 켜면 오지 않을 답을 기다린다.
    try testing.expectEqual(false, try r.boolean());
    try testing.expectEqual(@as(u32, 120), try r.u32be());
    try testing.expectEqual(@as(u32, 40), try r.u32be());
    try testing.expectEqual(@as(u32, 0), try r.u32be());
    try testing.expectEqual(@as(u32, 0), try r.u32be());
    try testing.expectEqual(@as(usize, 0), r.rest().len);
}

test "데이터는 윈도를 줄이고 넘기면 안 보낸다" {
    var ch = try openedChannel(10, 100); // 윈도가 작은 쪽이다
    var out: [128]u8 = undefined;
    try testing.expectEqual(@as(u32, 10), ch.sendableLen());

    const bytes = try ch.writeData(&out, "hello");
    var r = wire.Reader.init(bytes);
    try testing.expectEqual(@as(u8, 94), try r.byte());
    try testing.expectEqual(@as(u32, 42), try r.u32be());
    try testing.expectEqualStrings("hello", try r.string());
    try testing.expectEqual(@as(u32, 5), ch.remote_window);

    // 남은 윈도(5)를 넘기면 **쓰지 않는다** — 명세 위반이고, 서버가 흘려도 되므로 조용히
    // 사라질 수 있다.
    try testing.expectError(Error.WouldExceedWindow, ch.writeData(&out, "toolong"));
    try testing.expectEqual(@as(u32, 5), ch.remote_window); // 실패는 윈도를 안 먹는다

    _ = try ch.writeData(&out, "12345");
    try testing.expectEqual(@as(u32, 0), ch.remote_window);
    try testing.expectEqual(@as(u32, 0), ch.sendableLen());
    try testing.expectError(Error.WouldExceedWindow, ch.writeData(&out, "x"));
}

test "최대 패킷이 윈도보다 작으면 그쪽이 상한이다" {
    var ch = try openedChannel(1_000_000, 8);
    var out: [128]u8 = undefined;
    try testing.expectEqual(@as(u32, 8), ch.sendableLen());
    try testing.expectError(Error.WouldExceedWindow, ch.writeData(&out, "123456789"));
    _ = try ch.writeData(&out, "12345678");
    // 최대 패킷은 그대로고 윈도만 준다.
    try testing.expectEqual(@as(u32, 999_992), ch.remote_window);
    try testing.expectEqual(@as(u32, 8), ch.sendableLen());
}

test "쓰기가 버퍼 부족으로 실패하면 윈도가 안 샌다" {
    // **순서가 계약이다.** 윈도를 먼저 줄이면 `ShortBuffer` 한 번에 그만큼이 사라지고, 그 뒤로는
    // 보낼 수 있는 양을 실제보다 적게 알아 서버는 기다리는데 우리는 못 보내는 교착이 된다.
    var ch = try openedChannel(1000, 1000);
    var tiny: [4]u8 = undefined;
    try testing.expectError(wire.Writer.WriteError.NoSpace, ch.writeData(&tiny, "hello"));
    try testing.expectEqual(@as(u32, 1000), ch.remote_window);
}

test "WINDOW_ADJUST 는 보낼 수 있는 양을 늘린다" {
    var ch = try openedChannel(5, 1000);
    var out: [128]u8 = undefined;
    _ = try ch.writeData(&out, "12345");
    try testing.expectEqual(@as(u32, 0), ch.sendableLen());

    var buf: [32]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_window_adjust);
    try w.u32be(7);
    try w.u32be(100);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .window_adjusted);
    try testing.expectEqual(@as(u32, 100), ev.window_adjusted);
    try testing.expectEqual(@as(u32, 100), ch.remote_window);
    _ = try ch.writeData(&out, "again");
}

test "윈도는 2^32-1 을 넘게 늘지 않는다" {
    // §5.2: "The window MUST NOT be increased above 2^32 - 1 bytes." 감싸 돌면 보낼 수 있는 양을
    // 실제보다 **적게** 알게 되어, 서버는 기다리는데 우리는 못 보내는 교착이 된다.
    var ch = try openedChannel(0xFFFF_FF00, 1000);
    var buf: [32]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_window_adjust);
    try w.u32be(7);
    try w.u32be(0x200);
    try testing.expectError(Error.WindowOverflow, ch.receive(w.written()));
    try testing.expectEqual(@as(u32, 0xFFFF_FF00), ch.remote_window); // 그대로다

    // 딱 맞게 채우는 것은 합법이다.
    var w2 = wire.Writer.init(&buf);
    try w2.byte(msg_channel_window_adjust);
    try w2.u32be(7);
    try w2.u32be(0xFF);
    _ = try ch.receive(w2.written());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), ch.remote_window);
}

test "데이터와 확장 데이터를 가른다" {
    var ch = try openedChannel(1000, 1000);
    var buf: [64]u8 = undefined;

    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_data);
    try w.u32be(7);
    try w.string("stdout");
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .data);
    try testing.expectEqualStrings("stdout", ev.data);

    var w2 = wire.Writer.init(&buf);
    try w2.byte(msg_channel_extended_data);
    try w2.u32be(7);
    try w2.u32be(extended_data_stderr);
    try w2.string("oops");
    const ev2 = try ch.receive(w2.written());
    try testing.expect(ev2 == .extended_data);
    try testing.expectEqual(extended_data_stderr, ev2.extended_data.type_code);
    try testing.expectEqualStrings("oops", ev2.extended_data.data);
}

test "EOF 뒤에도 채널은 살아 있다" {
    // §5.3: "the channel remains open after this message, and more data may still be sent in the
    // other direction." EOF 를 닫힘으로 다루면 원격 출력의 마지막 조각을 잃는다.
    var ch = try openedChannel(1000, 1000);
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_eof);
    try w.u32be(7);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .eof);
    try testing.expectEqual(State.open, ch.state); // 상태는 안 바뀐다

    var w2 = wire.Writer.init(&buf);
    try w2.byte(msg_channel_data);
    try w2.u32be(7);
    try w2.string("아직 온다");
    const ev2 = try ch.receive(w2.written());
    try testing.expect(ev2 == .data);
}

test "우리가 EOF 를 보내도 받는 쪽은 계속 산다" {
    var ch = try openedChannel(1000, 1000);
    var out: [64]u8 = undefined;
    const bytes = try ch.writeEof(&out);
    try testing.expectEqual(@as(u8, 96), bytes[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 42 }, bytes[1..5]);
    try testing.expectEqual(@as(usize, 5), bytes.len);
    try testing.expectEqual(State.eof_sent, ch.state);

    // 반대 방향은 그대로다 — 받기도 하고, 크기 변경도 보낸다.
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_data);
    try w.u32be(7);
    try w.string("still");
    try testing.expect((try ch.receive(w.written())) == .data);
    _ = try ch.writeWindowChange(&out, .{ .cols = 100, .rows = 30 });
    // **EOF 를 보낸 뒤에는 데이터를 안 보낸다** — 그것이 EOF 의 뜻이다.
    try testing.expectError(Error.UnexpectedMessage, ch.writeEof(&out));
}

test "닫기는 양쪽이 보내야 끝난다" {
    // §5.3: "The channel is considered closed for a party when it has both sent and received
    // SSH_MSG_CHANNEL_CLOSE." 한쪽만 보고 끝내면 번호를 너무 일찍 재사용한다.
    var ch = try openedChannel(1000, 1000);
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_close);
    try w.u32be(7);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .closed);
    // 우리가 아직 안 보냈다 — 아직 닫힌 것이 아니다.
    try testing.expectEqual(State.open, ch.state);

    var out: [64]u8 = undefined;
    _ = try ch.writeClose(&out);
    // **이제 양쪽이 다 보냈다 — 닫힌 것이다.** 예전에는 이 자리에서 `close_sent` 로 남았는데,
    // 그러면 §5.3 이 말하는 "both sent and received" 를 만족하고도 상태가 안 따라가서 **번호를
    // 영영 못 쓴다**(컨트롤 채널을 닫았다 다시 여는 길이 막힌다 — 적대적 검증이 잡았다).
    try testing.expectEqual(State.closed, ch.state);

    // 반대 순서로도 같은 결론이다.
    var ch2 = try openedChannel(1000, 1000);
    _ = try ch2.writeClose(&out);
    try testing.expectEqual(State.close_sent, ch2.state);
    _ = try ch2.receive(w.written());
    try testing.expectEqual(State.closed, ch2.state);
}

test "exit-status 와 exit-signal 을 읽는다" {
    var ch = try openedChannel(1000, 1000);
    var buf: [128]u8 = undefined;

    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_request);
    try w.u32be(7);
    try w.string("exit-status");
    try w.boolean(false); // §6.10 은 FALSE 로 못박는다
    try w.u32be(130);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .exit_status);
    try testing.expectEqual(@as(u32, 130), ev.exit_status);

    var w2 = wire.Writer.init(&buf);
    try w2.byte(msg_channel_request);
    try w2.u32be(7);
    try w2.string("exit-signal");
    try w2.boolean(false);
    try w2.string("TERM"); // **SIG 접두 없이** 온다
    try w2.boolean(true);
    try w2.string("죽었다");
    try w2.string("ko");
    const ev2 = try ch.receive(w2.written());
    try testing.expect(ev2 == .exit_signal);
    try testing.expectEqualStrings("TERM", ev2.exit_signal.name);
    try testing.expectEqual(true, ev2.exit_signal.core_dumped);
    try testing.expectEqualStrings("죽었다", ev2.exit_signal.message);
    try testing.expectEqualStrings("ko", ev2.exit_signal.language);
}

test "닫자고 보낸 뒤에도 exit-status 를 받는다" {
    // 우리가 `CHANNEL_CLOSE` 를 보낸 뒤에도 상대의 `exit-status` 가 지나가는 중일 수 있다.
    // 그것을 오류로 다루면 **정상 종료가 실패로 보인다**.
    var ch = try openedChannel(1000, 1000);
    var out: [64]u8 = undefined;
    _ = try ch.writeClose(&out);

    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_request);
    try w.u32be(7);
    try w.string("exit-status");
    try w.boolean(false);
    try w.u32be(0);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .exit_status);
}

test "모르는 요청은 이름과 답 여부를 그대로 준다" {
    var ch = try openedChannel(1000, 1000);
    var buf: [128]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_request);
    try w.u32be(7);
    try w.string("keepalive@openssh.com");
    try w.boolean(true);
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .unknown_request);
    try testing.expectEqualStrings("keepalive@openssh.com", ev.unknown_request.name);
    try testing.expectEqual(true, ev.unknown_request.want_reply);

    // §5.4: 모르는 요청에는 `CHANNEL_FAILURE` 로 답한다. **답할 채널은 상대 번호**다.
    var out: [64]u8 = undefined;
    const reply = try ch.writeChannelFailure(&out);
    try testing.expectEqual(@as(u8, 100), reply[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 42 }, reply[1..5]);
    try testing.expectEqual(@as(usize, 5), reply.len);
}

test "요청 성공·실패를 가른다" {
    var ch = try openedChannel(1000, 1000);
    var buf: [32]u8 = undefined;

    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_success);
    try w.u32be(7);
    try testing.expect((try ch.receive(w.written())) == .request_success);

    var w2 = wire.Writer.init(&buf);
    try w2.byte(msg_channel_failure);
    try w2.u32be(7);
    try testing.expect((try ch.receive(w2.written())) == .request_failure);
}

test "열기 거절은 사유와 설명을 준다" {
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);

    var buf: [128]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_failure);
    try w.u32be(7);
    try w.u32be(@intFromEnum(OpenFailureReason.administratively_prohibited));
    try w.string("open failed");
    try w.string("en");
    const ev = try ch.receive(w.written());
    try testing.expect(ev == .open_failed);
    try testing.expectEqual(OpenFailureReason.administratively_prohibited, ev.open_failed.reason);
    try testing.expectEqualStrings("open failed", ev.open_failed.description);
    try testing.expectEqual(State.open_failed, ch.state);

    // 거절 뒤에는 아무것도 못 쓴다.
    try testing.expectError(Error.UnexpectedMessage, ch.writeData(&out, "x"));
}

test "모르는 실패 사유도 값을 잃지 않는다" {
    // 사유 코드는 IANA 가 늘린다(§5.1). 모르는 값을 오류로 다루면 **왜 못 붙었는지**를 사용자에게
    // 전할 수 없다 — 그것이 이 필드의 존재 이유다.
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);
    var buf: [128]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_failure);
    try w.u32be(7);
    try w.u32be(9999);
    try w.string("모르는 사유");
    try w.string("");
    const ev = try ch.receive(w.written());
    try testing.expectEqual(@as(u32, 9999), @intFromEnum(ev.open_failed.reason));
}

test "채널 메시지가 아니면 거절한다" {
    var ch = try openedChannel(1000, 1000);
    try testing.expectError(Error.NotChannelMessage, ch.receive(&[_]u8{ 20, 0, 0, 0, 7 }));
    try testing.expectError(Error.NotChannelMessage, ch.receive(&[_]u8{ 80, 0, 0, 0, 7 }));
}

test "잘린 메시지는 거절한다" {
    var ch = try openedChannel(1000, 1000);
    try testing.expectError(wire.Error.Truncated, ch.receive(&[_]u8{msg_channel_data}));
    try testing.expectError(wire.Error.Truncated, ch.receive(&[_]u8{ msg_channel_data, 0, 0, 0 }));
    // 채널 번호는 맞는데 길이가 잘린 경우.
    try testing.expectError(wire.Error.Truncated, ch.receive(&[_]u8{ msg_channel_data, 0, 0, 0, 7, 0, 0 }));
}

test "열리기 전 데이터는 거절한다" {
    // 번호가 우리 것이어도 **상태가 아니면** 안 받는다 — 열기 확인 전에는 상대 번호를 모르므로
    // 그 데이터를 어디에 붙일지도 모른다.
    var ch: Channel = .{};
    var out: [128]u8 = undefined;
    _ = try ch.writeOpen(&out, 7);
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_data);
    try w.u32be(7);
    try w.string("이른 데이터");
    try testing.expectError(Error.UnexpectedMessage, ch.receive(w.written()));
}

test "열기 확인은 한 번만 받는다" {
    // 두 번째 확인은 상대 번호와 윈도를 갈아 치운다 — 그러면 우리가 이미 보낸 데이터의 회계가
    // 통째로 어긋난다.
    var ch = try openedChannel(1000, 1000);
    var buf: [64]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_open_confirmation);
    try w.u32be(7);
    try w.u32be(99);
    try w.u32be(5);
    try w.u32be(5);
    try testing.expectError(Error.UnexpectedMessage, ch.receive(w.written()));
    try testing.expectEqual(@as(u32, 42), ch.remote_id);
    try testing.expectEqual(@as(u32, 1000), ch.remote_window);
}

// ---------------------------------------------------------------------------
// 받는 쪽 흐름 제어(S7b). 계약 §3.1 이 말한 **"대량 출력이 도중에 멈춘다"** 를 여기서 재현하고
// 막는다. 이 결함은 처음에 안 보인다 — 초기 윈도 안에서는 멀쩡하다.

/// 데이터 패킷 하나를 만든다.
fn dataPacket(buf: []u8, id: u32, len: usize, fill: []u8) ![]const u8 {
    @memset(fill[0..len], 'x');
    var w = wire.Writer.init(buf);
    try w.byte(msg_channel_data);
    try w.u32be(id);
    try w.string(fill[0..len]);
    return w.written();
}

test "윈도를 안 채우면 대량 출력이 멈춘다 — 그리고 조용히가 아니라 시끄럽게" {
    // **계약 §3.1 의 그 결함이다.** 예전 같으면 상대가 그냥 안 보내서 화면이 멈추고, 사용자는
    // "네트워크가 느리다" 로 오해한다. 여기서는 우리 회계가 바닥나는 순간 오류가 난다 —
    // 멈춤은 원인을 짚기 어렵지만 오류는 자리를 알려 준다.
    var ch = try openedChannel(1000, 1000);
    ch.local_window = 300; // 작게 잡아 빨리 바닥나게 한다
    ch.local_window_max = 300;
    ch.local_max_packet = 128;

    var fill: [256]u8 = undefined;
    var buf: [512]u8 = undefined;

    // 128 씩 두 번은 들어온다(총 256 ≤ 300).
    _ = try ch.receive(try dataPacket(&buf, 7, 128, &fill));
    _ = try ch.receive(try dataPacket(&buf, 7, 128, &fill));
    try testing.expectEqual(@as(u32, 44), ch.local_window);

    // 세 번째는 윈도를 넘는다 — 채워 주지 않았기 때문이다.
    try testing.expectError(Error.WindowExhausted, ch.receive(try dataPacket(&buf, 7, 128, &fill)));
    try testing.expectEqual(@as(u32, 44), ch.local_window); // 거절은 회계를 안 건드린다
}

test "채워 주면 대량 출력이 끝까지 흐른다" {
    // 같은 상황에서 드라이버가 계약대로 채우면 멈추지 않는다. **1MiB 를 128 바이트씩** 흘려
    // 보낸다 — 초기 윈도(300)의 3000 배가 넘으므로 보충 없이는 절대 못 지난다.
    var ch = try openedChannel(1000, 1000);
    ch.local_window = 300;
    ch.local_window_max = 300;
    ch.local_max_packet = 128;

    var fill: [256]u8 = undefined;
    var buf: [512]u8 = undefined;
    var out: [64]u8 = undefined;

    var received: usize = 0;
    var adjusts: usize = 0;
    while (received < 1024 * 1024) {
        const ev = try ch.receive(try dataPacket(&buf, 7, 128, &fill));
        received += ev.data.len;
        // **드라이버가 하는 일은 이 두 줄이다**(계약 §3.1 의 루프).
        if (ch.pendingWindowAdjust() != 0) {
            _ = try ch.writeWindowAdjust(&out);
            adjusts += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1024 * 1024), received);
    try testing.expect(adjusts > 3000); // 실제로 여러 번 채웠다
    try testing.expectEqual(@as(u32, 300), ch.local_window_max);
    try testing.expect(ch.local_window <= 300); // 광고한 것보다 커지지 않는다
}

test "절반에서 채운다 — 매번도 바닥에서도 아니다" {
    var ch = try openedChannel(1000, 1000);
    ch.local_window = 100;
    ch.local_window_max = 100;
    ch.local_max_packet = 100;

    var fill: [256]u8 = undefined;
    var buf: [512]u8 = undefined;

    // 40 을 받으면 60 남는다 — 아직 절반 위라 안 채운다(매번 채우면 패킷이 두 배가 된다).
    _ = try ch.receive(try dataPacket(&buf, 7, 40, &fill));
    try testing.expectEqual(@as(u32, 60), ch.local_window);
    try testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust());

    // 20 을 더 받으면 40 남는다 — 절반 아래라 채운다.
    _ = try ch.receive(try dataPacket(&buf, 7, 20, &fill));
    try testing.expectEqual(@as(u32, 40), ch.local_window);
    try testing.expectEqual(@as(u32, 60), ch.pendingWindowAdjust());

    var out: [64]u8 = undefined;
    const bytes = try ch.writeWindowAdjust(&out);
    var r = wire.Reader.init(bytes);
    try testing.expectEqual(@as(u8, 93), try r.byte());
    try testing.expectEqual(@as(u32, 42), try r.u32be()); // 상대 번호로 보낸다
    try testing.expectEqual(@as(u32, 60), try r.u32be());
    try testing.expectEqual(@as(usize, 0), r.rest().len);
    try testing.expectEqual(@as(u32, 100), ch.local_window); // 광고한 값까지 찼다
    try testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust());
}

test "채울 것이 없는데 보내면 오류다" {
    // 조건 없이 부르는 드라이버는 채널당 패킷을 두 배로 만든다. 그 낭비는 대량 전송에서만
    // 드러나고, 그때는 원인이 여기라고 생각하기 어렵다.
    var ch = try openedChannel(1000, 1000);
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust());
    try testing.expectError(Error.UnexpectedMessage, ch.writeWindowAdjust(&out));
}

test "확장 데이터도 같은 윈도를 먹는다" {
    // §5.2: "Data sent with these messages consumes the same window as ordinary data."
    // 빼먹으면 stderr 가 많은 명령에서 회계가 어긋나고, 그 어긋남은 한참 뒤에 드러난다.
    var ch = try openedChannel(1000, 1000);
    ch.local_window = 100;
    ch.local_window_max = 100;
    ch.local_max_packet = 100;

    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_channel_extended_data);
    try w.u32be(7);
    try w.u32be(extended_data_stderr);
    try w.string("0123456789");
    _ = try ch.receive(w.written());
    try testing.expectEqual(@as(u32, 90), ch.local_window);
}

test "우리가 광고한 최대 패킷보다 큰 데이터는 거절한다" {
    var ch = try openedChannel(1000, 1000);
    ch.local_max_packet = 64;
    var fill: [256]u8 = undefined;
    var buf: [512]u8 = undefined;
    try testing.expectError(Error.DataExceedsMaxPacket, ch.receive(try dataPacket(&buf, 7, 65, &fill)));
    _ = try ch.receive(try dataPacket(&buf, 7, 64, &fill));
}

test "쓰기가 실패하면 우리 윈도가 앞서 나가지 않는다" {
    // **순서가 계약이다.** 먼저 늘리면 상대는 그 양을 모르는데 우리만 아는 상태가 된다 —
    // 상대가 멈춘 뒤에도 우리는 여유가 있다고 믿어 원인을 엉뚱한 데서 찾게 된다.
    var ch = try openedChannel(1000, 1000);
    ch.local_window = 10;
    ch.local_window_max = 100;
    var tiny: [3]u8 = undefined;
    try testing.expectError(wire.Writer.WriteError.NoSpace, ch.writeWindowAdjust(&tiny));
    try testing.expectEqual(@as(u32, 10), ch.local_window);
}

test "열 때 광고하는 값과 유지하려는 값이 같다" {
    // 다르면 첫 보충에서 광고한 것보다 커지거나 작아진다 — 전자는 §5.2 위반이고 후자는 느려진다.
    var ch: Channel = .{ .local_window_max = 4096 };
    var out: [128]u8 = undefined;
    const bytes = try ch.writeOpen(&out, 7);
    var r = wire.Reader.init(bytes);
    _ = try r.byte();
    _ = try r.string();
    _ = try r.u32be();
    try testing.expectEqual(@as(u32, 4096), try r.u32be());
    try testing.expectEqual(ch.local_window_max, ch.local_window);
}

test "윈도가 2^31 이상이어도 넘치지 않는다" {
    // §5.2: "Implementations MUST correctly handle window sizes of up to 2^32 - 1 bytes."
    // 절반 판정을 곱으로 쓰면 이 구간에서 `u32` 를 넘는다 — Debug 는 패닉, ReleaseFast 는 조용히
    // 감싸 돌아 **필요 없는 보충 패킷이 계속 나간다**. 기본값(2MiB)에서는 안 닿는 자리다.
    for ([_]u32{ 0x8000_0000, 0xC000_0000, 0xFFFF_FFFF }) |big| {
        // **열린 채널로 잰다** — 닫힌 채널은 아예 "보충 없음" 이라, 상태를 안 주면 이 산수를
        // 재는 것이 아니라 상태 가지를 재게 된다.
        var ch: Channel = .{ .local_window_max = big, .local_window = big, .state = .open };
        try testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust()); // 가득 찼으면 안 채운다

        ch.local_window = big / 2;
        try testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust()); // 딱 절반도 아직 아니다

        ch.local_window = big / 2 - 1;
        try testing.expectEqual(big - (big / 2 - 1), ch.pendingWindowAdjust());
    }

    // 0 이어도 나눗셈이 안전하다(1/0 이 아니라 0/2 다).
    var zero: Channel = .{ .local_window_max = 0, .local_window = 0, .state = .open };
    try testing.expectEqual(@as(u32, 0), zero.pendingWindowAdjust());
}

test "닫힌 채널은 보충이 필요하다고 말하지 않는다" {
    // 두 함수가 같은 답을 해야 한다. 어긋나면 그 말을 믿고 쓴 쪽이 오류로 죽는다.
    var ch = Channel{};
    ch.state = .open;
    ch.local_id = 0;
    ch.remote_id = 0;
    ch.local_window = 1;
    try std.testing.expect(ch.pendingWindowAdjust() != 0);
    var buf: [64]u8 = undefined;
    _ = try ch.writeWindowAdjust(&buf);

    ch.local_window = 1;
    ch.state = .closed;
    try std.testing.expectEqual(@as(u32, 0), ch.pendingWindowAdjust());
    try std.testing.expectError(Error.UnexpectedMessage, ch.writeWindowAdjust(&buf));
}

test "exec 은 RFC 4254 §6.5 의 자리 그대로다" {
    // **`want_reply` 를 손으로 확인한다.** 드라이버 테스트는 우리가 성공 답을 먹여 주므로
    // 이 비트를 꺼도 통과한다(변이 검사에서 실제로 살아남았다) — 그러나 실제로 끄면 서버가
    // 답을 안 보내고 우리는 `requesting_exec` 에서 **영영 기다린다**.
    var ch = try openedChannel(1000, 1000);
    var out: [128]u8 = undefined;
    const bytes = try ch.writeExec(&out, "maru control --stdio");

    try testing.expectEqual(msg_channel_request, bytes[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 42 }, bytes[1..5]); // recipient
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 4 }, bytes[5..9]);
    try testing.expectEqualStrings("exec", bytes[9..13]);
    try testing.expectEqual(@as(u8, 1), bytes[13]); // want_reply
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 20 }, bytes[14..18]);
    try testing.expectEqualStrings("maru control --stdio", bytes[18..38]);
    try testing.expectEqual(@as(usize, 38), bytes.len);
}
