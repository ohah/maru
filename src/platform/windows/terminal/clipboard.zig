//! Native terminal clipboard actions. All entry points share the existing paste
//! protection and encoding path; popup actions revalidate their stable surface ID.
const std = @import("std");
const maru = @import("maru");
const win32_clipboard = maru.win32_clipboard;
const menu = @import("../../../app/terminal_clipboard_menu.zig");

pub const PasteOutcome = struct {
    pastes: usize = 0,
    paste_bytes: usize = 0,
    bracketed: usize = 0,
    blocked: usize = 0,
    errors: usize = 0,
};

/// 클립보드를 읽어 활성 표면에 붙여넣는다 — W7.4b 의 규칙 그대로다.
///
/// **화음(`Ctrl+Shift+V`)과 우클릭이 이 함수를 공유한다.** 두 자리에 같은 규칙을 복사하면 한쪽만 고쳐져
/// 어긋난다 — 그리고 그 규칙이 하필 **보안 규칙**이다(raw 바이트를 셸에 보내지 않는다: bracketed 래핑·
/// 개행 정규화·ESC 치환. 클립보드의 `\x1b[201~` 이 래핑을 빠져나오면 명령이 실행된다).
pub fn pasteIntoActive(
    allocator: std.mem.Allocator,
    io: std.Io,
    hwnd: ?*anyopaque,
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    stderr: *std.Io.Writer,
    paste_protection: bool,
    bracketed_paste_is_safe: bool,
    out: *PasteOutcome,
) !void {
    const maybe = win32_clipboard.read(allocator, hwnd) catch |err| {
        try stderr.print("  warning: clipboard read failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
        out.errors += 1;
        return;
    };
    const text = maybe orelse return;
    defer allocator.free(text);

    var needs_confirm = false;
    var bracketed = false;
    if (app_window.active()) |active| {
        // 판정과 bracketed 읽기만 락 안에서 — 인코딩(할당·복사)은 밖에서 한다(macOS `submitPaste` 순서).
        active.lockCore(io);
        needs_confirm = active.core.pasteNeedsConfirmation(text, paste_protection, bracketed_paste_is_safe);
        bracketed = active.core.bracketedPasteEnabled();
        active.unlockCore(io);
    }
    if (needs_confirm) {
        // **확인 모달이 없으면 붙여넣지 않는다.** 모달이 없다고 보호를 건너뛰면 위험한 붙여넣기가
        // 조용히 실행된다 — 거절하고 세는 편이 맞다(확인 UI 는 W8).
        try stderr.writeAll("  paste held: the content is risky (the confirm UI is W8). Nothing was pasted\n");
        out.blocked += 1;
        return;
    }
    const encoded = maru.terminal.encodePasteWith(bracketed, allocator, text) catch |err| {
        try stderr.print("  warning: paste encoding failed({s})\n", .{@errorName(err)});
        out.errors += 1;
        return;
    };
    defer allocator.free(encoded);
    maru.app.host.sendInputToActiveSurface(app_window, runtime, .{ .bytes = encoded }) catch |err| {
        try stderr.print("  warning: paste send failed({s})\n", .{@errorName(err)});
        out.errors += 1;
        return;
    };
    out.pastes += 1;
    out.paste_bytes += encoded.len;
    if (bracketed) out.bracketed += 1;
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    hwnd: ?*anyopaque,
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    stderr: *std.Io.Writer,
    paste_protection: bool,
    bracketed_paste_is_safe: bool,
    paste_out: *PasteOutcome,
    copies: *usize,
    copy_bytes: *usize,
    errors: *usize,

    pub fn current(self: Host, terminal_visible: bool) ?u64 {
        if (!terminal_visible) return null;
        return if (self.app_window.active()) |active| active.id else null;
    }

    pub fn perform(self: Host, request: menu.Request, terminal_visible: bool) !bool {
        if (self.current(terminal_visible) != request.surface_id) return false;
        switch (request.action) {
            .copy => try self.copy(),
            .paste => try pasteIntoActive(self.allocator, self.io, self.hwnd, self.app_window, self.runtime, self.stderr, self.paste_protection, self.bracketed_paste_is_safe, self.paste_out),
        }
        return true;
    }

    pub fn copy(self: Host) !void {
        const active = self.app_window.active() orelse return;
        const maybe_text: ?[]u8 = blk: {
            active.lockCore(self.io);
            defer active.unlockCore(self.io);
            break :blk active.core.extractSelection(self.allocator) catch null;
        };
        if (maybe_text) |text| {
            defer self.allocator.free(text);
            if (text.len > 0) {
                if (win32_clipboard.write(self.allocator, self.hwnd, text)) |_| {
                    self.copies.* += 1;
                    self.copy_bytes.* += text.len;
                } else |err| {
                    try self.stderr.print("  warning: copy failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
                    self.errors.* += 1;
                }
            }
        }
    }
};

test "Terminal clipboard popup host refuses stale targets and hidden terminals before OS access" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var surface = try maru.session.surface.Surface.init(a, 41, .{ .cols = 4, .rows = 2 });
    defer surface.deinit();
    var tabs = [_]*maru.session.surface.Surface{&surface};
    var window: maru.session.window.AppWindow = .{ .tabs = &tabs };
    var runtime = maru.app.SurfaceRuntime.init(a);
    defer runtime.deinit();
    var output: PasteOutcome = .{};
    var copies: usize = 0;
    var bytes: usize = 0;
    var errors: usize = 0;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const host: Host = .{ .allocator = a, .io = std.testing.io, .hwnd = null, .app_window = &window, .runtime = &runtime, .stderr = &writer, .paste_protection = true, .bracketed_paste_is_safe = false, .paste_out = &output, .copies = &copies, .copy_bytes = &bytes, .errors = &errors };
    try std.testing.expect(!(try host.perform(.{ .surface_id = 42, .action = .copy }, true)));
    try std.testing.expect(!(try host.perform(.{ .surface_id = 41, .action = .copy }, false)));
    try std.testing.expectEqual(@as(usize, 0), copies + bytes + errors + output.pastes);
}
