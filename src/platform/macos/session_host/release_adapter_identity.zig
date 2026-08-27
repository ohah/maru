//! Canonical scalar identity syntax shared by OS-neutral release-adapter observations.

const std = @import("std");

pub fn canonicalTag(tag: []const u8) bool {
    if (tag.len < 2 or tag[0] != 'v') return false;
    const version = tag[1..];
    var components: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= version.len) : (index += 1) {
        if (index != version.len and version[index] != '.') continue;
        const component = version[start..index];
        if (component.len == 0 or (component.len > 1 and component[0] == '0')) return false;
        for (component) |byte| if (!std.ascii.isDigit(byte)) return false;
        components += 1;
        start = index + 1;
    }
    return components == 3;
}

pub fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}
