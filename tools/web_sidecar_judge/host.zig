//! 판정자가 `maru-web-host` 를 maru 처럼 띄우고 말한다(W1b). 파이프 두 개(명령·알림)를 쥔다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");

const Message = protocol.message.Message;

pub const Host = struct {
    pid: c_int,
    commands: c_int,
    events: c_int,
    decoder: protocol.stream.StreamingDecoder = .init(.to_maru),
    /// 지금까지 받은 알림이 모두 frame 으로 풀렸는가 — stdout 에 딴 바이트가 섞이면 거짓이 된다.
    clean: bool = true,
    /// 읽었지만 decoder 에 아직 못 들어간 바이트(decoder 는 받을 수 있는 만큼만 받는다 — W1a).
    carry: [4096]u8 = undefined,
    carry_len: usize = 0,

    pub fn spawn(host_path: [:0]const u8, profile_arg: [:0]const u8) !Host {
        var to_host: [2]c_int = undefined;
        var from_host: [2]c_int = undefined;
        if (std.c.pipe(&to_host) != 0 or std.c.pipe(&from_host) != 0) return error.PipeFailed;
        const pid = os.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = std.c.dup2(to_host[0], 0);
            _ = std.c.dup2(from_host[1], 1);
            for ([_]c_int{ to_host[0], to_host[1], from_host[0], from_host[1] }) |fd| _ = std.c.close(fd);
            const argv = [_:null]?[*:0]const u8{ host_path, profile_arg };
            const envp = [_:null]?[*:0]const u8{};
            _ = std.c.execve(host_path, &argv, &envp);
            std.c._exit(127);
        }
        _ = std.c.close(to_host[0]);
        _ = std.c.close(from_host[1]);
        return .{ .pid = pid, .commands = to_host[1], .events = from_host[0] };
    }

    pub fn send(self: *Host, message: Message) !void {
        var buf: [protocol.wire.max_frame_bytes]u8 = undefined;
        const len = try protocol.codec.encode(message, &buf);
        if (std.c.write(self.commands, &buf, len) != @as(isize, @intCast(len))) return error.WriteFailed;
    }

    /// 다음 알림 하나. 채널이 닫히면 null, `timeout_ms` 안에 아무것도 안 오면 `error.Timeout` — sidecar 가 멈춰도
    /// 판정자가 함께 멈추지 않고 실패로 끝난다. 반환한 글 slice 는 다음 호출 전까지만 유효하다.
    pub fn next(self: *Host, timeout_ms: u32) !?Message {
        var deadline_left: i64 = timeout_ms;
        while (true) {
            if (self.decoder.next()) |maybe| {
                if (maybe) |message| return message;
            } else |err| {
                self.clean = false;
                return err;
            }
            if (self.carry_len > 0) {
                const fed = self.decoder.feed(self.carry[0..self.carry_len]) catch |err| {
                    self.clean = false;
                    return err;
                };
                std.mem.copyForwards(u8, self.carry[0 .. self.carry_len - fed], self.carry[fed..self.carry_len]);
                self.carry_len -= fed;
                if (fed == 0) return error.DecoderStalled;
                continue;
            }
            if (deadline_left <= 0) return error.Timeout;
            var fds = [_]std.c.pollfd{.{ .fd = self.events, .events = std.c.POLL.IN, .revents = 0 }};
            const step: i64 = @min(deadline_left, 100);
            const ready = std.c.poll(&fds, 1, @intCast(step));
            deadline_left -= step;
            if (ready == 0) continue;
            const n = std.c.read(self.events, &self.carry, self.carry.len);
            if (n <= 0) {
                self.decoder.finish() catch {
                    self.clean = false;
                };
                return null;
            }
            self.carry_len = @intCast(n);
        }
    }

    /// 종료 코드를 기다린다. `timeout_ms` 안에 안 끝나면 null.
    pub fn wait(self: *Host, timeout_ms: u32) ?u8 {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 50) {
            var status: c_int = 0;
            const r = std.c.waitpid(self.pid, &status, 1); // WNOHANG
            if (r == self.pid) {
                const s: u32 = @bitCast(status);
                return if (s & 0x7f == 0) @intCast((s >> 8) & 0xff) else 128 + @as(u8, @intCast(s & 0x7f));
            }
            os.sleepMs(50);
        }
        return null;
    }
};
