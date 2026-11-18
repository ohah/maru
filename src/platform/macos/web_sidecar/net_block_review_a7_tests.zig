//! W9d③ 7 차 적대 검증(A7 — 2baa301cd 를 친 판)의 순수 탐침: 메서드 이름 꼴(대소문자·공백·NUL·유니코드 동형·긴 이름)을 wire 가 거절하는가.
//! 읽기 목록(옛 D2 토큰을 남기는 문 — `devtools_table.read_only_methods`)의 판정은 2026-11-18 「막기도 넓히기」 로 목록과 함께 지웠다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const msg = protocol.message;
const fields = protocol.fields;
const codec = protocol.codec;
const testing = std.testing;

test "A7-name: getProperties 의 이름 꼴(대소문자·앞뒤 공백·NUL·유니코드 동형·매우 긴 이름)은 wire 가 거절하거나, 지나는 꼴은 영숫자와 `.` 뿐이다" {
    const long = "Runtime.getProperties" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 128 B — wire 상한 안
    const too_long = "Runtime.getProperties" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 129 B
    const forms = [_][]const u8{
        "runtime.getProperties",  "Runtime.GetProperties",  "Runtime.getproperties",     "RUNTIME.GETPROPERTIES",
        " Runtime.getProperties", "Runtime.getProperties ", "Runtime.getProperties\x00", "\x00Runtime.getProperties",
        "Runtime.getPropertie\xd1\x95", // Cyrillic ѕ
        "Runtime\xe2\x80\xa4getProperties", // ONE DOT LEADER
        "Runtime.getProperties.",
        ".Runtime.getProperties",
        "Runtime..getProperties",
        "Runtime.getProperties\t",
        "Runtime.getProperties\"",
        long,
        too_long,
    };
    var wire_ok: usize = 0;
    for (forms) |m| {
        const valid = if (fields.checkDevtoolsMethod(m)) |_| true else |_| false;
        if (valid) {
            wire_ok += 1;
            // wire 를 지나는 꼴은 영숫자와 `.` 뿐.
            for (m) |ch| try testing.expect(std.ascii.isAlphanumeric(ch) or ch == '.');
        } else {
            // 거절되는 꼴은 codec 의 decode 도 거절한다(인코드한 frame 을 손으로 만들 수 없다 — encode 도 같은 검사).
            var buf: [512]u8 = undefined;
            const enc = codec.encode(.{ .devtools_call = .{ .browser = 1, .call = 1, .method = m, .params_size = 0 } }, &buf);
            try testing.expect(std.meta.isError(enc));
        }
    }
    // 대소문자 넷·`..`·긴 이름(128) 만 wire 를 지난다.
    try testing.expectEqual(@as(usize, 6), wire_ok);
    // 손으로 만든 frame(인코드한 뒤 이름 바이트를 공백·NUL·0x80 으로 바꾼다)도 decode 가 거절한다 — sidecar 의 검사 앞에서 끊긴다.
    var fb: [512]u8 = undefined;
    const name = "Runtime.getPropertiesZ";
    const len = try codec.encode(.{ .devtools_call = .{ .browser = 1, .call = 1, .method = name, .params_size = 0 } }, &fb);
    const at = std.mem.indexOf(u8, fb[0..len], name).?;
    _ = try codec.decodeExact(fb[0..len]);
    for ([_]u8{ ' ', 0, 0x80, '"', '\\' }) |bad| {
        var copy = fb;
        copy[at + name.len - 1] = bad;
        try testing.expect(std.meta.isError(codec.decodeExact(copy[0..len])));
    }
}
