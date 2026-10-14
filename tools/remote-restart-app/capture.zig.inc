    if (std.c.getenv("MARU_REMOTE_PROVIDER_GUI") != null) {
        if (self.turn_captures.sealedTurn(capture_id)) |turn|
            std.debug.print("PROVIDER_CAPTURE session={s} capture={d} remote={} shell_calls={d}\n", .{
                facts.session, capture_id, turn.remote, turn.shell_calls,
            });
    }
