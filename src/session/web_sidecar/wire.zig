//! 웹 OSR sidecar 제어 채널의 frame 머리와 바이트 커서(W1a). frame 은 `[u32 길이][MWEB][u16 버전][u8 tag][본문]`
//! 이고 전부 빅엔디언이다. 메시지 모양은 `message.zig`, 필드 규칙은 `fields.zig`, 조립은 `codec.zig` 가 든다.
//!
//! sidecar 는 신뢰할 수 없는 웹을 띄우는 프로세스 트리의 뿌리라, maru 쪽은 sidecar 가 보낸 바이트를 공격
//! 입력으로 다룬다 — 고정 저장소, 상한 초과·방향 위반·닫힌 필드 위반은 전부 거절한다(docs/plans/web-osr-backend.md C2).

const std = @import("std");

pub const magic = "MWEB".*;
/// maru 와 sidecar 는 따로 설치될 수 있다(D8 — formula 가 sidecar 만 올릴 수 있다). 그래서 Mermaid 처럼
/// 「항상 같은 버전」을 전제하지 않고, 버전이 다르면 첫 frame(hello)에서 `UnsupportedVersion` 으로 드러난다.
pub const version: u16 = 1;

/// maru 가 보내는 URL 상한. 사용자가 친 주소·링크를 싣는 자리라 이 크기면 넉넉하고, 고정 decoder 저장소를
/// 작게 둔다. 이보다 긴 URL(큰 data: URL 등)은 maru 가 보내지 않는다.
pub const max_url_bytes: usize = 32 * 1024;
/// sidecar 가 보내는 글(제목·실패 설명) 상한. sidecar 는 `clampUtf8` 로 잘라서 보낸다.
pub const max_text_bytes: usize = 4 * 1024;
/// bootstrap 이름 상한 — launchd 이름(`name_t`)이 128 바이트다.
pub const max_service_bytes: usize = 127;
/// 가장 큰 메시지(`create_browser` + URL 상한)의 frame 크기 — 상한을 따로 두면 그 사이 크기의 frame 이 끝까지 쌓였다가
/// 필드 검사에서야 거절된다(적대 검증). 메시지를 더할 때 이보다 크면 `codec.zig` 의 comptime 이 멈춘다.
pub const max_frame_bytes: usize = prefix_len + common_len + largest_body_bytes;
const largest_body_bytes = 8 + 12 + 1 + 4 + max_url_bytes;
/// 스트리밍 저장소 — 가장 큰 frame 하나가 딱 들어간다. 그래서 frame 을 비우는 한 `feed` 는 늘 진행한다.
pub const max_retained_bytes: usize = max_frame_bytes;

pub const prefix_len = 4;
pub const common_len = magic.len + @sizeOf(u16) + @sizeOf(u8);

pub const Error = error{
    InvalidServiceName,
    OutputTooSmall,
    FrameTooLarge,
    UrlTooLarge,
    EmptyUrl,
    TextTooLarge,
    InvalidUtf8,
    InvalidMagic,
    UnsupportedVersion,
    UnknownTag,
    WrongDirection,
    UnknownReason,
    UnknownFailureCode,
    UnknownNavAction,
    InvalidBool,
    InvalidBrowserId,
    InvalidViewSize,
    InvalidLength,
    TrailingBytes,
    ControlCharacter,
    IncompleteFrame,
};

pub const Cursor = struct {
    bytes: []u8,
    pos: usize = 0,

    pub fn init(bytes: []u8) Cursor {
        return .{ .bytes = bytes };
    }

    pub fn skip(self: *Cursor, len: usize) Error!void {
        _ = try self.reserve(len);
    }

    pub fn writeByte(self: *Cursor, value: u8) Error!void {
        (try self.reserve(1))[0] = value;
    }

    pub fn writeU16(self: *Cursor, value: u16) Error!void {
        std.mem.writeInt(u16, (try self.reserve(2))[0..2], value, .big);
    }

    pub fn writeU32(self: *Cursor, value: u32) Error!void {
        std.mem.writeInt(u32, (try self.reserve(4))[0..4], value, .big);
    }

    pub fn writeU64(self: *Cursor, value: u64) Error!void {
        std.mem.writeInt(u64, (try self.reserve(8))[0..8], value, .big);
    }

    pub fn writeBytes(self: *Cursor, value: []const u8) Error!void {
        @memcpy(try self.reserve(value.len), value);
    }

    pub fn reserve(self: *Cursor, len: usize) Error![]u8 {
        if (len > self.bytes.len -| self.pos) return error.OutputTooSmall;
        const start = self.pos;
        self.pos += len;
        return self.bytes[start..self.pos];
    }
};

pub const ReadCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) ReadCursor {
        return .{ .bytes = bytes };
    }

    pub fn readByte(self: *ReadCursor) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    pub fn readU16(self: *ReadCursor) Error!u16 {
        return std.mem.readInt(u16, (try self.readBytes(2))[0..2], .big);
    }

    pub fn readU32(self: *ReadCursor) Error!u32 {
        return std.mem.readInt(u32, (try self.readBytes(4))[0..4], .big);
    }

    pub fn readU64(self: *ReadCursor) Error!u64 {
        return std.mem.readInt(u64, (try self.readBytes(8))[0..8], .big);
    }

    pub fn readBytes(self: *ReadCursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.InvalidLength;
        const start = self.pos;
        self.pos += len;
        return self.bytes[start..self.pos];
    }
};
