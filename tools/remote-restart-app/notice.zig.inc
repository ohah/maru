    if (std.c.getenv("MARU_REMOTE_RESTART_PHASE")) |phase| {
        if (std.mem.eql(u8, std.mem.span(phase), "restore"))
            std.debug.print("REMOTE_RESTART_DELIVER kind={s}\n", .{@tagName(kind)});
    }
