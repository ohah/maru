//! 웹 OSR sidecar 제어 채널의 메시지 모양(W1a) — tag·방향·닫힌 enum·본문 구조체. 바이트 배치는 `codec.zig`.

const std = @import("std");

/// 0~31 은 maru → sidecar, 32~ 는 sidecar → maru. 받는 쪽은 `StreamingDecoder` 의 방향으로 거꾸로 온
/// frame 을 거절한다.
pub const Tag = enum(u8) {
    hello = 0,
    create_browser = 1,
    destroy_browser = 2,
    resize = 3,
    set_hidden = 4,
    set_focus = 5,
    navigate = 6,
    shutdown = 7,
    /// 픽셀 채널(W2): maru 가 연 mach 받는 port 의 bootstrap 이름과 비밀 토큰(C3). 이것으로만 건넨다.
    frame_channel = 8,

    hello_ack = 32,
    browser_created = 33,
    browser_closed = 34,
    title_changed = 35,
    load_finished = 36,
    renderer_gone = 37,
    failure = 38,

    pub fn direction(self: Tag) Direction {
        return if (@intFromEnum(self) < 32) .to_sidecar else .to_maru;
    }
};

pub const Direction = enum { to_sidecar, to_maru };

pub const RendererGoneReason = enum(u8) {
    abnormal = 0,
    killed = 1,
    crashed = 2,
    out_of_memory = 3,
    launch_failed = 4,
    /// 코드 무결성 검사 실패(CEF TS_INTEGRITY_FAILURE).
    integrity_failure = 5,
};

pub const FailureCode = enum(u8) {
    /// 같은 프로필을 다른 프로세스가 쥐고 있다(CEF process singleton — §13.1 exit 24).
    profile_in_use = 0,
    cef_initialize_failed = 1,
    browser_create_failed = 2,
    unknown_browser = 3,
    duplicate_browser = 4,
    /// sidecar 가 maru 의 frame 을 풀지 못했다. 이 뒤 sidecar 는 채널을 닫는다.
    protocol_violation = 5,
    /// `frame_channel` 의 이름으로 port 를 못 찾았다(W2).
    frame_channel_failed = 6,
};

pub const BrowserId = u64;

pub const Hello = struct {
    instance: u64,
    nonce: u64,
};

pub const ViewSize = struct {
    width: u32,
    height: u32,
    scale: f32,
};

pub const CreateBrowser = struct {
    browser: BrowserId,
    size: ViewSize,
    hidden: bool,
    url: []const u8,
};

pub const Resize = struct {
    browser: BrowserId,
    size: ViewSize,
};

pub const BrowserFlag = struct {
    browser: BrowserId,
    value: bool,
};

/// 링 알림을 받을 mach port 의 bootstrap 이름과, 알림마다 실어 보낼 128 비트 비밀 토큰(C3).
pub const FrameChannel = struct {
    service: []const u8,
    token: [16]u8,
};

pub const Navigate = struct {
    browser: BrowserId,
    url: []const u8,
};

pub const BrowserText = struct {
    browser: BrowserId,
    text: []const u8,
};

pub const LoadFinished = struct {
    browser: BrowserId,
    http_status: i32,
};

pub const RendererGone = struct {
    browser: BrowserId,
    reason: RendererGoneReason,
};

/// `browser` 가 0 이면 브라우저에 묶이지 않은 실패(초기화·프로필)다.
pub const Failure = struct {
    browser: BrowserId,
    code: FailureCode,
    detail: []const u8,
};

pub const Message = union(Tag) {
    hello: Hello,
    create_browser: CreateBrowser,
    destroy_browser: BrowserId,
    resize: Resize,
    set_hidden: BrowserFlag,
    set_focus: BrowserFlag,
    navigate: Navigate,
    shutdown: void,
    frame_channel: FrameChannel,

    hello_ack: Hello,
    browser_created: BrowserId,
    browser_closed: BrowserId,
    title_changed: BrowserText,
    load_finished: LoadFinished,
    renderer_gone: RendererGone,
    failure: Failure,
};

test "tags split by direction at 32" {
    inline for (std.meta.fields(Tag)) |field| {
        const tag: Tag = @enumFromInt(field.value);
        const expected: Direction = if (field.value < 32) .to_sidecar else .to_maru;
        try std.testing.expectEqual(expected, tag.direction());
    }
}
