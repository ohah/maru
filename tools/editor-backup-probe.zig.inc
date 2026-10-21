// 소스 사본에서만 제품의 동기 백업 경로를 부른다. 문서 준비·되읽기는 계측 밖이다.
fn backupProbeNow() i128 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

fn backupProbeMeasure(session: *AppSession, term: *Term, root: []const u8, route: []const u8, size: usize) !void {
    const ops = app_session_mod.editor_backup_ops;
    const store = @import("recovery_store.zig");
    const expected = term.rt.editorDocument().opened.?.file.content;
    try testing.expectEqual(size, expected.len);
    try testing.expect(isDirty(term));
    for (0..4) |sample| {
        ops.noteEdit(session, term);
        expireBackupClock(term);
        backup_rules.probe_encode_ns = 0;
        backup_rules.probe_encode_calls = 0;
        store.probe_read_ns = 0;
        ops.probe_write_ns = 0;
        const start = backupProbeNow();
        ops.tick(session);
        const total = backupProbeNow() - start;
        const encode = backup_rules.probe_encode_ns;
        const read = store.probe_read_ns;
        const write = ops.probe_write_ns;
        try testing.expectEqual(@as(usize, 1), backup_rules.probe_encode_calls);
        try testing.expect(total >= write and write >= encode + read);
        try testing.expect(!term.rt.editorDocument().notifications.backup_dirty);
        try testing.expect(term.rt.editorDocument().notifications.backup_on_disk);
        var name_buf: [backup_rules.max_file_name_len]u8 = undefined;
        const name = ops.fileNameIfOnDisk(term, &name_buf).?;
        const path = try std.fs.path.join(testing.allocator, &.{ root, name });
        defer testing.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(backup_rules.max_record_bytes));
        defer testing.allocator.free(bytes);
        if (term.rt.editorDocument().path != null) {
            const owner = term.rt.editor_recovery.?;
            var record = try backup_rules.parseRecovery(testing.allocator, bytes);
            defer record.deinit(testing.allocator);
            try testing.expect(record.matches(name, owner.id, term.rt.editorDocument().path.?));
            try testing.expectEqualStrings(expected, record.content);
        } else {
            var record = try backup_rules.parse(testing.allocator, bytes);
            defer record.deinit(testing.allocator);
            try testing.expectEqualStrings(expected, record.content);
        }
        std.debug.print("\nBACKUP_PROBE {{\"route\":\"{s}\",\"bytes\":{d},\"sample\":{d},\"action\":\"{s}\",\"total_ns\":{d},\"write_ns\":{d},\"encode_ns\":{d},\"read_ns\":{d},\"verified\":true}}\n", .{ route, size, sample, if (sample == 0) "first" else "rewrite", total, write, encode, read });
    }
    var name_buf: [backup_rules.max_file_name_len]u8 = undefined;
    const name = ops.fileNameIfOnDisk(term, &name_buf).?;
    const path = try std.fs.path.join(testing.allocator, &.{ root, name });
    defer testing.allocator.free(path);
    const start = backupProbeNow();
    ops.drop(session, term);
    const elapsed = backupProbeNow() - start;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
    try testing.expect(isDirty(term));
    std.debug.print("\nBACKUP_PROBE {{\"route\":\"{s}\",\"bytes\":{d},\"sample\":0,\"action\":\"drop\",\"total_ns\":{d},\"write_ns\":0,\"encode_ns\":0,\"read_ns\":0,\"verified\":true}}\n", .{ route, size, elapsed });
}

test "BACKUPPROBE 실제 백업 tick의 직렬화·기존 기록 검증·쓰기·삭제를 구분한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    for ([_]usize{ 64 * 1024, 1024 * 1024, 8 * 1024 * 1024 }) |size| {
        const content = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(content);
        @memset(content, 'x');
        for (0..size / 128) |i| content[i * 128 + 127] = '\n';
        for ([_]bool{ false, true }) |local| {
            // 실제 macOS 앱의 allocator와 맞춰 테스트 allocator의 할당 추적 비용을 제외한다.
            const fx = try ConflictFixture.init(std.heap.smp_allocator, "probe.txt", "base");
            defer fx.deinit(std.heap.smp_allocator);
            const term = if (local) fx.term else try openUntitledInActivePane(fx.fx.session);
            var dir = testing.tmpDir(.{});
            defer dir.cleanup();
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const root = try pinBackupDir(&buf, &dir);
            defer app_session_mod.editor_backup_ops.setDirForTest(null);
            try testing.expect(selectAll(fx.fx.session, term));
            try testing.expect(insertText(fx.fx.session, term, content));
            try backupProbeMeasure(fx.fx.session, term, root, if (local) "local-id" else "untitled", size);
        }
    }
}
