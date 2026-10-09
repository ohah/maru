//! 프로젝트 검색의 내용·프로토콜 경계. 프로세스와 UI 소유권은 platform/chrome에 둔다.
pub const query = @import("query.zig");
pub const event = @import("event.zig");
pub const request = @import("request.zig");
pub const presentation = @import("presentation.zig");
pub const results = @import("results.zig");
pub const preview = @import("preview.zig");
pub const stream = @import("stream.zig");
comptime {
    if (@import("builtin").is_test) @import("std").testing.refAllDecls(@This());
}
