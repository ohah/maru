//! P4 C3b의 첫 committed-mutation inventory가 제품 함수 꼬리에 실제로 연결됐는지 고정한다.

const std = @import("std");

test "P4 C3b topology selection naming SCM mutation은 app-global owner 하나로 모인다" {
    const allocator = std.testing.allocator;
    const app_session = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const tab = try read(allocator, "src/platform/macos/app_session/tab.zig");
    defer allocator.free(tab);
    const pane = try read(allocator, "src/platform/macos/app_session/pane.zig");
    defer allocator.free(pane);
    const term = try read(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term);
    const settings = try read(allocator, "src/platform/macos/app_session/settings.zig");
    defer allocator.free(settings);
    const scm = try read(allocator, "src/platform/macos/app_session/scm_dock.zig");
    defer allocator.free(scm);
    const dock = try read(allocator, "src/platform/macos/app_session/dock.zig");
    defer allocator.free(dock);
    const file_panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig");
    defer allocator.free(file_panel);
    const web = try read(allocator, "src/platform/macos/app_session/web.zig");
    defer allocator.free(web);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, app_session, "app_runtime.workspace_checkpoint.markChanged(kind)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, app_session, "target.workspaceChanged(.runtime_binding)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, app_session, "self.workspaceChanged(.runtime_binding)"));
    try std.testing.expect(std.mem.indexOf(u8, app_session, "if (!self.workspace_checkpoint_mutations_enabled) return;") != null);
    try std.testing.expectEqual(@as(usize, 14), std.mem.count(u8, tab, "self.workspaceChanged("));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, pane, "self.workspaceChanged("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, term, "self.workspaceChanged(.selection)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, settings, "self.workspaceChanged(.naming)"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, scm, "self.workspaceChanged(.scm_base)"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, dock, "self.workspaceChanged(.dock)"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, file_panel, "self.workspaceChanged(.dock)"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, file_panel, "self.workspaceChanged(.explorer_roots)"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, file_panel, "self.workspaceChanged(.persisted_surface)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, web, "self.workspaceChanged(.persisted_surface)"));
    try std.testing.expect(std.mem.indexOf(u8, web, "persisted_url_changed and app_session_mod.app_runtime.workspace_checkpoint.armed") != null);
}

test "P4 C3b projection inventory는 dock explorer SCM과 volatile observation을 구분한다" {
    const allocator = std.testing.allocator;
    const workspace = try read(allocator, "src/platform/macos/app_session/workspace.zig");
    defer allocator.free(workspace);
    const product = try read(allocator, "src/app/workspace_checkpoint_product.zig");
    defer allocator.free(product);
    for ([_][]const u8{ "persistFilePanelState", "rootMode() == .explicit", "scm_base_entries", ".active_tab" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, workspace, needle) != null);
    for ([_][]const u8{ "topology", "selection", "scm_base", "runtime_binding", "window_frame", "active_window" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, product, needle) != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, product, "window_title"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, product, "observation.cwd"));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
