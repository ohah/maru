//! Presentation boundary for host-owned OSC notifications (P4 N2a).
//!
//! PTY output is untrusted arbitrary bytes. The journal owns stable delivery state, not text
//! interpretation, so every product caller must pass title/body/label through this leaf before
//! admission. Keeping the sanitizer free of TerminalCore, sockets, and platform APIs makes the
//! exact byte policy executable on every test target.

const std = @import("std");

pub const fallback_title = "Maru";

/// The journal stores presentation-ready fields because both the live GUI and the GUI-less OS
/// adapter consume the same stable row. Keep the fallback here instead of duplicating it in either
/// platform sink.
pub fn titleOrFallback(normalized_title: []const u8) []const u8 {
    return if (normalized_title.len == 0) fallback_title else normalized_title;
}

pub const TextRole = enum {
    /// Notification title and runtime label: one trimmed line with whitespace runs folded.
    single_line,
    /// Notification body: CR/LF are normalized to LF; other controls are removed.
    multi_line,
};

pub const Error = std.mem.Allocator.Error || error{NormalizedTooLarge};

const replacement = "\xef\xbf\xbd";

/// Returns an independently owned, valid UTF-8 presentation string. `max_bytes` applies to the
/// normalized result, not the attacker-controlled input, and failure returns no partial buffer.
pub fn sanitizeOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    role: TextRole,
    max_bytes: usize,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte < 0x80) {
            index += 1;
            switch (byte) {
                0x1b => index = skipEscape(input, index),
                '\r' => {
                    if (index < input.len and input[index] == '\n') index += 1;
                    try appendLineBoundary(&out, allocator, role, max_bytes);
                },
                '\n' => try appendLineBoundary(&out, allocator, role, max_bytes),
                '\t', ' ' => if (role == .single_line)
                    try appendSpace(&out, allocator, max_bytes)
                else
                    try appendBounded(&out, allocator, " ", max_bytes),
                0x21...0x7e => try appendBounded(&out, allocator, &.{byte}, max_bytes),
                else => {}, // NUL, ESC, DEL, and the remaining C0 controls are not presentation text.
            }
            continue;
        }

        // Raw 8-bit C1 bytes are invalid UTF-8, but treating them as replacement text would leave
        // their parameter bytes visible. Consume CSI/string controls with the same policy as their
        // UTF-8 encoded form; discard the remaining C1 controls.
        if (byte >= 0x80 and byte <= 0x9f) {
            index += 1;
            index = switch (byte) {
                0x90, 0x98, 0x9d, 0x9e, 0x9f => skipControlString(input, index),
                0x9b => skipCsi(input, index),
                else => index,
            };
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try appendBounded(&out, allocator, replacement, max_bytes);
            index += 1;
            continue;
        };
        if (index + sequence_len > input.len) {
            try appendBounded(&out, allocator, replacement, max_bytes);
            index += 1;
            continue;
        }
        const bytes = input[index .. index + sequence_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            try appendBounded(&out, allocator, replacement, max_bytes);
            index += 1;
            continue;
        };
        index += sequence_len;
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            index = switch (codepoint) {
                0x90, 0x98, 0x9d, 0x9e, 0x9f => skipControlString(input, index),
                0x9b => skipCsi(input, index),
                else => index,
            };
            continue;
        }
        try appendBounded(&out, allocator, bytes, max_bytes);
    }

    if (role == .single_line) {
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn skipEscape(input: []const u8, start: usize) usize {
    if (start >= input.len) return input.len;
    const first = input[start];
    if (first == '[') return skipCsi(input, start + 1);
    if (first == 'P' or first == 'X' or first == ']' or first == '^' or first == '_')
        return skipControlString(input, start + 1);
    return switch (first) {
        0x20...0x2f => blk: {
            var index = start + 1;
            while (index < input.len and input[index] >= 0x20 and input[index] <= 0x2f) : (index += 1) {}
            if (index < input.len and input[index] >= 0x30 and input[index] <= 0x7e) index += 1;
            break :blk index;
        },
        0x30...0x7e => start + 1,
        else => start,
    };
}

fn skipCsi(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        if (input[index] >= 0x40 and input[index] <= 0x7e) return index + 1;
    }
    return input.len;
}

fn skipControlString(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) {
        if (input[index] == 0x07) return index + 1;
        if (input[index] == 0x1b and index + 1 < input.len and input[index + 1] == '\\') return index + 2;
        if (index + 1 < input.len and input[index] == 0xc2 and input[index + 1] == 0x9c) return index + 2;
        index += 1;
    }
    return input.len;
}

fn appendLineBoundary(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    role: TextRole,
    max_bytes: usize,
) Error!void {
    switch (role) {
        .single_line => try appendSpace(out, allocator, max_bytes),
        .multi_line => try appendBounded(out, allocator, "\n", max_bytes),
    }
}

fn appendSpace(out: *std.ArrayList(u8), allocator: std.mem.Allocator, max_bytes: usize) Error!void {
    if (out.items.len == 0 or out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\n') return;
    try appendBounded(out, allocator, " ", max_bytes);
}

fn appendBounded(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_bytes: usize,
) Error!void {
    const next = std.math.add(usize, out.items.len, bytes.len) catch return error.NormalizedTooLarge;
    if (next > max_bytes) return error.NormalizedTooLarge;
    try out.appendSlice(allocator, bytes);
}

test "P4 N2a sanitizer removes encoded and raw controls while keeping replacement valid" {
    const allocator = std.testing.allocator;
    const got = try sanitizeOwned(allocator, "a\xc2\x85b\xe2\x82", .single_line, 32);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("ab\xef\xbf\xbd", got);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}
