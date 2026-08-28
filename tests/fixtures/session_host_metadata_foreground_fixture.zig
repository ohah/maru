//! Controlled executable identity for P3-e4d-2a. The build emits this same source as `claude`
//! and `codex`; macOS `proc_name` therefore observes the real executable basename rather than a
//! shell-script label. It only emits bounded synthetic OSC metadata and blocks on harness FIFOs.

const std = @import("std");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

fn writeAll(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0) std.c._exit(121);
        offset += @intCast(written);
    }
}

fn waitFifo(path: [:0]const u8) void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) std.c._exit(122);
    defer _ = std.c.close(fd);
    var byte: u8 = 0;
    if (std.c.read(fd, @ptrCast(&byte), 1) != 1) std.c._exit(123);
}

pub fn main(init: std.process.Init.Minimal) void {
    var args = std.process.Args.Iterator.init(init.args);
    const argv0 = args.next() orelse std.c._exit(124);
    const role = std.fs.path.basename(argv0);
    if (std.mem.eql(u8, role, "claude")) {
        const repo = args.next() orelse std.c._exit(124);
        const fifo = args.next() orelse std.c._exit(124);
        const codex = args.next() orelse std.c._exit(124);
        const codex_fifo = args.next() orelse std.c._exit(124);
        const plain = args.next() orelse std.c._exit(124);
        var out: [std.fs.max_path_bytes + 64]u8 = undefined;
        const osc = std.fmt.bufPrint(&out, "\x1b]7;file://localhost{s}\x07", .{repo}) catch
            std.c._exit(124);
        writeAll(osc);
        waitFifo(fifo);
        const next_argv = [_:null]?[*:0]const u8{ codex.ptr, codex_fifo.ptr, plain.ptr };
        _ = execv(codex.ptr, &next_argv);
        std.c._exit(125);
    }
    if (std.mem.eql(u8, role, "codex")) {
        const fifo = args.next() orelse std.c._exit(124);
        const plain = args.next() orelse std.c._exit(124);
        writeAll("\x1b]5379;ssh;e4d2a-remote\x07");
        waitFifo(fifo);
        var out: [std.fs.max_path_bytes + 96]u8 = undefined;
        const osc = std.fmt.bufPrint(
            &out,
            "\x1b]5379;ssh-end\x07\x1b]7;file://localhost{s}\x07",
            .{plain},
        ) catch std.c._exit(124);
        writeAll(osc);
        const cat_argv = [_:null]?[*:0]const u8{"/bin/cat"};
        _ = execv("/bin/cat", &cat_argv);
        std.c._exit(125);
    }
    std.c._exit(124);
}
