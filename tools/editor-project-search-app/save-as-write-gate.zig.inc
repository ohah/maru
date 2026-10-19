// 격리 앱에만 주입한다. 시간 지연 대신 실제 writer 진입과 입력 완료를 파일로 동기화한다.
fn saveAsWriteGate(self: *const Prepared, io: std.Io) editor.SaveError!void {
    const scenario = std.mem.span(std.c.getenv("MARU_EDITOR_SAVE_AS_SCENARIO") orelse return);
    if (!std.mem.eql(u8, scenario, "edit-during-write") or !self.create_new or !std.mem.endsWith(u8, self.path, "save-as-destination.txt")) return;
    const root = std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_OUTPUT") orelse return error.WriteFailed);
    var entered_buf: [std.fs.max_path_bytes]u8 = undefined;
    var temporary_buf: [std.fs.max_path_bytes]u8 = undefined;
    var release_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entered = std.fmt.bufPrint(&entered_buf, "{s}/save-as-writer-entered", .{root}) catch return error.WriteFailed;
    const temporary = std.fmt.bufPrint(&temporary_buf, "{s}/save-as-writer-entering", .{root}) catch return error.WriteFailed;
    const release = std.fmt.bufPrint(&release_buf, "{s}/save-as-writer-release", .{root}) catch return error.WriteFailed;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = self.content() }) catch return error.WriteFailed;
    std.Io.Dir.renameAbsolute(temporary, entered, io) catch return error.WriteFailed;
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        std.Io.Dir.cwd().access(io, release, .{}) catch {
            if (std.Io.Clock.awake.now(io).nanoseconds - started > 15 * std.time.ns_per_s) return error.WriteFailed;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch return error.WriteFailed;
            continue;
        };
        break;
    }
}
