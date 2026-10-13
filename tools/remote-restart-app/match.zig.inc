                if (std.c.getenv("MARU_REMOTE_RESTART_PHASE") != null)
                    std.debug.print("REMOTE_RESTART_APPLIED replay={}\n", .{e.replay});
