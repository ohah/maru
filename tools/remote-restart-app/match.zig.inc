                if (std.c.getenv("MARU_REMOTE_RESTART_PHASE") != null)
                    std.debug.print("REMOTE_RESTART_APPLIED replay={}\n", .{e.replay});
                if (std.c.getenv("MARU_REMOTE_PROVIDER_GUI") != null)
                    std.debug.print("PROVIDER_APPLIED provider={s} event={s} session={s} replay={} state={s}\n", .{
                        ev.provider, @tagName(ev.kind), ev.session_id, e.replay, @tagName(slot.state),
                    });
