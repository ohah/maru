//! 앱 쪽 이미지 채널 세그먼트 표 — 채널로 받은 공유 메모리 세그먼트 fd 를 `image_ref` 가 가리킬 때까지 쥐고, 해석·정리·반환한다.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §3.3·§6 이다. 연결마다 하나를
//! `Client.image_segments` 가 가리킨다(채널이 묶일 때 heap 에 잡는다 — 표를 값으로 들면 Client 를 값으로 든 external pump
//! cleanup scratch 가 예산을 넘는다). 연결 축이라 앱이 여러 host 에 붙어도 `segment_id` 가 섞이지 않는다. 채널 끝 fd 는
//! `Client.image_channel` 이 쥐고 이 표는 받은 세그먼트 fd 만 쥔다.
//!
//! - **크기는 고정이다.** host 는 연결당 미반환 세그먼트를 `image_segment_max_per_connection` 개까지만 둔다(원장). host 가 보기에
//!   미반환인 것은 이 표의 항목 + 아직 못 보낸 release 라, 둘의 합이 상한을 넘으면 host 가 계약을 어긴 것이다.
//! - **채널 리더(`drain`)**: 논블로킹 recvmsg 로 비운다. host → 앱 채널에는 세그먼트 메시지만 온다(`bind_ack` 는 수립 때 읽었다).
//!   fd 는 메시지 첫 바이트와 함께 정확히 하나 온다 — 아니면 host 위반이다. 앱 fd 가 바닥나면(EMFILE) 커널은 재시도한 recvmsg
//!   에서 fd 를 **조용히 버리므로**(§10) 재시도하지 않고 연결을 끊는다. 받은 fd 는 CLOEXEC 가 꺼져 있어 바로 켠다(§7 의 잠금은 IC4).
//! - **닫힌 stream**: host 는 연결마다 stream id 를 1 씩 늘려 매기고 재사용하지 않는다(`Connection.next_stream_id`). 그래서 「본 적
//!   있는 가장 큰 id 이하이면서 지금 붙어 있지 않은 stream」이 닫힌 stream 이다 — 연결 수명 동안 자라는 집합 없이 지금 붙은
//!   stream(동시 상한)만 든다. 그 stream 의 세그먼트는 받는 즉시 반환한다. 더 큰 id 는 아직 attach 응답을 못 읽은 stream 일 수 있어
//!   (첫 snapshot 의 세그먼트가 응답보다 먼저 온다) 표에 둔다.
//! - **해석(`resolve`)**: 표에서 찾아 stream·메타를 레코드와 대조하고 `fstat` 크기 하한 → `mmap(PROT_READ)` → fd close → 표에서
//!   제거 → release 적재. 해석하지 못한 이유는 로그로 남기고 항목은 그대로 둔다(다른 stream 의 항목을 지우면 그 stream 의 이미지가
//!   빈다 — hwm 정리나 stream 닫힘이 치운다). 매핑 실패는 `OutOfMemory` 다(로컬 자원 — 상대 계약 위반이 아니다).
//! - **죽은 항목 정리(`sweep`)**: 같은 stream 의 배치를 적용한 뒤 그 배치의 `image_seg_hwm` 이하 항목은 버려진 배치의 것이다.
//! - **release(`flush`)**: 채널에 직접 논블로킹으로 쓴다. 막히면 남겨 다음에 다시 쓴다(부분 쓰기 포함).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const image_channel_wire = @import("image_channel_wire.zig");
const image_segment_ledger = @import("image_segment_ledger.zig");
const client_queue_limits = @import("client_queue_limits.zig");

const log = std.log.scoped(.image_channel);

/// host 가 연결에 둘 수 있는 미반환 세그먼트 수와 같다 — 이 표는 그 이상을 들 일이 없다.
pub const capacity: usize = image_segment_ledger.image_segment_max_per_connection;
/// 한 연결에 동시에 붙는 stream 상한(host `max_screen_trackers_per_slot` 과 같은 값 — `connection_slot` 이 comptime 으로 잠근다).
pub const max_live_streams: usize = client_queue_limits.max_recovery_streams;

/// 받은 SCM_RIGHTS 를 **전부** 담는 제어 버퍼 — 잘리면 커널은 fd 를 설치하고 잘린 만큼은 알려 주지 않아 닫을 수 없다(§10).
/// host 쪽 `connection_turn.image_channel_control_bytes` 와 같은 근거다.
pub const control_bytes: usize = 2048;
const max_fds_per_message: usize = 254;

comptime {
    const header = std.mem.alignForward(usize, @sizeOf(c.cmsghdr), @sizeOf(u32));
    const data = std.mem.alignForward(usize, max_fds_per_message * @sizeOf(c.fd_t), @sizeOf(u32));
    if (control_bytes < header + data)
        @compileError("image channel control buffer must hold the largest SCM_RIGHTS message the kernel accepts");
}

pub const DrainError = error{
    /// 채널이 닫혔거나(EOF·오류) 메시지 머리가 어긋났다 — 채널 상실(§3.2). 주 연결은 그대로다.
    ChannelLost,
    /// host 가 「메시지당 fd 하나」나 미반환 개수 상한을 어겼다 — 연결을 poison 한다(`peer_contract_violation`).
    PeerContractViolation,
    /// 앱 fd 가 바닥났다(EMFILE·ENFILE) — 다시 읽으면 커널이 fd 를 조용히 버린다. 연결을 poison 한다(`local_resource_exhausted`).
    LocalResourceExhausted,
};

pub const FlushError = error{
    /// release 를 쓸 수 없다(EPIPE 등) — 채널 상실이다.
    ChannelLost,
};

/// `image_ref` 레코드가 말하는 세그먼트. 표의 항목과 모두 같아야 해석한다.
pub const Ref = struct {
    segment_id: u64,
    image_id: u32,
    generation: u64,
    byte_len: u32,
};

/// 매핑된 픽셀. 소유는 받는 쪽(조립기)으로 넘어가고 `unmapPixels` 로 푼다.
pub const Mapping = struct {
    pixels: []const u8,
};

pub const Entry = struct {
    segment: image_channel_wire.Segment,
    fd: c.fd_t,
};

const empty_entry: Entry = .{
    .segment = .{ .segment_id = 0, .stream_id = 0, .image_id = 0, .generation = 0, .byte_len = 0 },
    .fd = -1,
};

/// 해석이 실패한 이유 — 로그로만 나간다(조립기에서는 모두 `MalformedRow` 다).
pub const Miss = enum { missing, stream_mismatch, metadata_mismatch, too_small, stat_failed, map_failed };

pub const Table = struct {
    entries: [capacity]Entry = @splat(empty_entry),
    len: usize = 0,
    /// 아직 덜 받은 세그먼트 메시지의 앞부분과, 그 첫 바이트에 붙어 온 fd.
    rx: [image_channel_wire.segment_len]u8 = @splat(0),
    rx_len: usize = 0,
    rx_fd: c.fd_t = -1,
    /// 아직 못 쓴 release 바이트(부분 쓰기의 나머지 포함).
    tx: [capacity * image_channel_wire.release_len]u8 = @splat(0),
    tx_len: usize = 0,
    live: [max_live_streams]u64 = @splat(0),
    live_len: usize = 0,
    /// attach 응답으로 알게 된 가장 큰 stream id. 이하이면서 `live` 에 없으면 닫힌 stream 이다.
    max_known_stream: u64 = 0,

    /// 표가 쥔 fd 를 모두 닫는다. 연결 종료와 채널 상실이 여기를 지난다 — host 는 채널 EOF 로 원장을 전부 반환하므로 못 보낸
    /// release 는 버린다.
    pub fn deinit(self: *Table) void {
        self.dropSegments();
        self.* = .{};
    }

    /// 채널 상실(§3.2): 세그먼트와 못 보낸 release 를 버린다. stream 추적은 남긴다 — 주 연결은 산다.
    pub fn dropSegments(self: *Table) void {
        for (self.entries[0..self.len]) |entry| _ = c.close(entry.fd);
        if (self.rx_fd >= 0) _ = c.close(self.rx_fd);
        self.entries = @splat(empty_entry);
        self.len = 0;
        self.rx_len = 0;
        self.rx_fd = -1;
        self.tx_len = 0;
    }

    /// host 가 보기에 이 연결의 미반환 세그먼트 수(표 + 아직 못 보낸 release).
    pub fn outstanding(self: *const Table) usize {
        return self.len + self.tx_len / image_channel_wire.release_len + @intFromBool(self.tx_len % image_channel_wire.release_len != 0);
    }

    pub fn entriesSlice(self: *const Table) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn liveStreams(self: *const Table) []const u64 {
        return self.live[0..self.live_len];
    }

    /// 표 상태의 지문. 외부 adoption 스냅샷은 표(약 4 KiB)를 값으로 들지 않고 이것을 든다 — 스냅샷 사본이 external pump cleanup
    /// scratch(1 MiB 예산) 안에 여러 번 들어간다. 쓰는 칸만 덮는다(빈 칸은 상태가 아니다). fd 는 값 그대로 — 스냅샷은 같은 Client
    /// 의 전후를 비교한다.
    pub fn fingerprint(self: *const Table) [32]u8 {
        // 필드를 더하면 여기도 덮는다.
        comptime std.debug.assert(std.meta.fields(Table).len == 10);
        comptime std.debug.assert(std.meta.fields(image_channel_wire.Segment).len == 5);
        var hasher = std.crypto.hash.Blake3.init(.{});
        hashInt(&hasher, self.len);
        for (self.entriesSlice()) |entry| {
            hashInt(&hasher, entry.segment.segment_id);
            hashInt(&hasher, entry.segment.stream_id);
            hashInt(&hasher, entry.segment.image_id);
            hashInt(&hasher, entry.segment.generation);
            hashInt(&hasher, entry.segment.byte_len);
            hashInt(&hasher, entry.fd);
        }
        hashInt(&hasher, self.rx_len);
        hasher.update(self.rx[0..self.rx_len]);
        hashInt(&hasher, self.rx_fd);
        hashInt(&hasher, self.tx_len);
        hasher.update(self.tx[0..self.tx_len]);
        hashInt(&hasher, self.live_len);
        for (self.liveStreams()) |stream| hashInt(&hasher, stream);
        hashInt(&hasher, self.max_known_stream);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// attach 응답으로 stream 을 알게 됐다. 지금 붙은 stream 이 상한이면 `error.LiveStreamsFull`(host 상한과 같아 정상은 안 난다).
    pub fn openStream(self: *Table, stream_id: u64) error{LiveStreamsFull}!void {
        if (self.isLive(stream_id)) return;
        if (self.live_len == self.live.len) return error.LiveStreamsFull;
        self.live[self.live_len] = stream_id;
        self.live_len += 1;
        self.raiseKnown(stream_id);
    }

    /// stream 이 detach·종료됐다. 그 stream 의 항목을 반환하고, 이후 그 stream 의 세그먼트는 받는 즉시 반환한다. 부르기 전에
    /// 채널을 best-effort 로 비우는 것은 호출자 몫이다(§6).
    pub fn closeStream(self: *Table, stream_id: u64) void {
        if (std.mem.indexOfScalar(u64, self.live[0..self.live_len], stream_id)) |i| {
            self.live[i] = self.live[self.live_len - 1];
            self.live_len -= 1;
        }
        self.raiseKnown(stream_id);
        var i: usize = 0;
        while (i < self.len) {
            if (self.entries[i].segment.stream_id == stream_id) self.releaseAt(i) else i += 1;
        }
    }

    /// 아는 최대 id 를 올리고, 그 때문에 닫힌 것이 된 stream 의 항목을 반환한다 — 응답을 못 읽은 채 표에 들어온 stream 이 끝내
    /// 열리지 않고 지나가면(앱 쪽 실패 경로) 그 항목이 sweep 대상도 아닌 채 원장 자리를 영구히 쥐지 않게.
    fn raiseKnown(self: *Table, stream_id: u64) void {
        if (stream_id <= self.max_known_stream) return;
        self.max_known_stream = stream_id;
        var i: usize = 0;
        while (i < self.len) {
            if (self.isClosed(self.entries[i].segment.stream_id)) self.releaseAt(i) else i += 1;
        }
    }

    fn isLive(self: *const Table, stream_id: u64) bool {
        return std.mem.indexOfScalar(u64, self.live[0..self.live_len], stream_id) != null;
    }

    fn isClosed(self: *const Table, stream_id: u64) bool {
        return stream_id <= self.max_known_stream and !self.isLive(stream_id);
    }

    /// 같은 stream 의 배치를 적용한 뒤 그 배치의 `image_seg_hwm` 이하로 남은 항목을 반환한다 — 그 항목을 가리키는 레코드는
    /// 이 배치나 그 앞 배치에만 있을 수 있었으므로 버려진 배치의 것이다(§6).
    pub fn sweep(self: *Table, stream_id: u64, hwm: u64) void {
        var i: usize = 0;
        while (i < self.len) {
            const segment = self.entries[i].segment;
            if (segment.stream_id == stream_id and segment.segment_id <= hwm) self.releaseAt(i) else i += 1;
        }
    }

    /// `image_ref` 하나를 해석한다. null 은 「표에 맞는 세그먼트가 없다」(이유는 로그), `OutOfMemory` 는 매핑 실패다.
    pub fn resolve(self: *Table, stream_id: u64, ref: Ref) error{OutOfMemory}!?Mapping {
        const index = self.indexOf(ref.segment_id) orelse return miss(.missing, stream_id, ref);
        const entry = self.entries[index];
        // 다른 stream 의 항목은 건드리지 않는다 — 그 stream 이 곧 쓸 수 있다.
        if (entry.segment.stream_id != stream_id) return miss(.stream_mismatch, stream_id, ref);
        if (entry.segment.image_id != ref.image_id or entry.segment.generation != ref.generation or
            entry.segment.byte_len != ref.byte_len) return miss(.metadata_mismatch, stream_id, ref);
        var st: c.Stat = undefined;
        if (c.fstat(entry.fd, &st) != 0) return miss(.stat_failed, stream_id, ref);
        if (st.size < ref.byte_len) return miss(.too_small, stream_id, ref);
        const mapped = posix.mmap(null, ref.byte_len, .{ .READ = true }, .{ .TYPE = .SHARED }, entry.fd, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return miss(.map_failed, stream_id, ref),
        };
        // 매핑은 fd 와 무관하게 산다(§10) — fd 를 닫고 반환한다.
        self.releaseAt(index);
        return .{ .pixels = mapped[0..ref.byte_len] };
    }

    fn indexOf(self: *const Table, segment_id: u64) ?usize {
        for (self.entries[0..self.len], 0..) |entry, i| if (entry.segment.segment_id == segment_id) return i;
        return null;
    }

    /// 항목 하나를 닫고 표에서 빼고 release 를 쌓는다. 항목과 쌓인 release 의 합은 `capacity` 이하라(`drain` 이 지킨다)
    /// release 버퍼는 넘치지 않는다.
    fn releaseAt(self: *Table, index: usize) void {
        const entry = self.entries[index];
        _ = c.close(entry.fd);
        self.entries[index] = self.entries[self.len - 1];
        self.entries[self.len - 1] = empty_entry;
        self.len -= 1;
        self.queueRelease(entry.segment.segment_id);
    }

    fn queueRelease(self: *Table, segment_id: u64) void {
        const message = image_channel_wire.encodeRelease(segment_id) catch unreachable; // 표의 id 는 0 이 아니다(decodeSegment).
        std.debug.assert(self.tx_len + message.len <= self.tx.len);
        @memcpy(self.tx[self.tx_len..][0..message.len], &message);
        self.tx_len += message.len;
    }

    /// 쌓인 release 를 채널에 논블로킹으로 쓴다. 막히면(EAGAIN) 남은 바이트를 다음 호출로 미룬다.
    pub fn flush(self: *Table, fd: c.fd_t) FlushError!void {
        while (self.tx_len != 0) {
            const n = c.write(fd, &self.tx, self.tx_len);
            if (n < 0) switch (posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return,
                else => return error.ChannelLost,
            };
            if (n == 0) return error.ChannelLost;
            const written: usize = @intCast(n);
            std.mem.copyForwards(u8, self.tx[0 .. self.tx_len - written], self.tx[written..self.tx_len]);
            self.tx_len -= written;
        }
    }

    /// 채널을 논블로킹으로 비운다(§6 — 매 tick 과 배치 적용 직전). 막히면(EAGAIN) 돌아온다.
    pub fn drain(self: *Table, fd: c.fd_t) DrainError!void {
        while (try self.readOnce(fd)) {}
    }

    /// recvmsg 한 번. 더 읽을 것이 있을 수 있으면 true.
    fn readOnce(self: *Table, fd: c.fd_t) DrainError!bool {
        var control: [control_bytes]u8 align(@alignOf(c.cmsghdr)) = undefined;
        // 메시지 하나의 나머지까지만 읽는다 — fd 는 메시지 첫 바이트와 함께 오므로 경계를 넘겨 읽으면 다음 메시지의 fd 를 이
        // 메시지 몫으로 잘못 셀 수 있다.
        var iov = [_]posix.iovec{.{ .base = self.rx[self.rx_len..].ptr, .len = self.rx.len - self.rx_len }};
        var msg: c.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const rc = while (true) {
            const n = c.recvmsg(fd, &msg, posix.MSG.DONTWAIT);
            if (n < 0 and posix.errno(n) == .INTR) continue;
            break n;
        };
        if (rc < 0) return switch (posix.errno(rc)) {
            .AGAIN => false,
            // 재시도하면 커널이 fd 를 조용히 버린다(§10) — 다시 읽지 않는다.
            .MFILE, .NFILE => error.LocalResourceExhausted,
            else => error.ChannelLost,
        };
        var received: [max_fds_per_message]c.fd_t = undefined;
        const fd_count = collectReceivedFds(control[0..@min(msg.controllen, control.len)], &received);
        const fds = received[0..fd_count];
        if (msg.flags & c.MSG.CTRUNC != 0) {
            closeAll(fds);
            return error.PeerContractViolation;
        }
        if (rc == 0) {
            closeAll(fds);
            return error.ChannelLost;
        }
        // fd 는 메시지 첫 바이트와 함께 정확히 하나. 이어 읽는 조각에는 없다.
        const expected: usize = if (self.rx_len == 0) 1 else 0;
        if (fds.len != expected) {
            closeAll(fds);
            return error.PeerContractViolation;
        }
        if (fds.len == 1) {
            // macOS 에는 `MSG_CMSG_CLOEXEC` 가 없다 — 받은 fd 는 CLOEXEC 가 꺼진 채 설치된다(§7).
            _ = c.fcntl(fds[0], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
            self.rx_fd = fds[0];
        }
        self.rx_len += @intCast(rc);
        if (self.rx_len < self.rx.len) return true;
        try self.accept();
        return true;
    }

    /// 다 받은 세그먼트 메시지 하나를 표에 넣는다(닫힌 stream 이면 바로 반환).
    fn accept(self: *Table) DrainError!void {
        const fd = self.rx_fd;
        self.rx_fd = -1;
        self.rx_len = 0;
        const segment = image_channel_wire.decodeSegment(&self.rx) catch {
            _ = c.close(fd);
            // 머리가 어긋나면 그 채널은 더 해석하지 않는다(§3.3).
            return error.ChannelLost;
        };
        if (self.indexOf(segment.segment_id) != null or self.outstanding() >= capacity) {
            _ = c.close(fd);
            return error.PeerContractViolation;
        }
        self.entries[self.len] = .{ .segment = segment, .fd = fd };
        self.len += 1;
        if (self.isClosed(segment.stream_id)) self.releaseAt(self.len - 1);
    }
};

/// `Mapping.pixels` 를 푼다 — 조립기에 주입하는 해제 함수(`screen_assembler.PixelRelease`).
pub fn unmapPixels(pixels: []const u8) void {
    if (pixels.len == 0) return;
    const page: [*]align(std.heap.page_size_min) const u8 = @alignCast(pixels.ptr);
    posix.munmap(page[0..pixels.len]);
}

fn hashInt(hasher: *std.crypto.hash.Blake3, value: anytype) void {
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(value), value));
    hasher.update(&bytes);
}

fn miss(reason: Miss, stream_id: u64, ref: Ref) ?Mapping {
    if (!builtin.is_test)
        log.warn("image segment unresolved: reason={s} stream={d} segment={d} image={d} generation={d} bytes={d}", .{
            @tagName(reason), stream_id, ref.segment_id, ref.image_id, ref.generation, ref.byte_len,
        });
    return null;
}

fn closeAll(fds: []const c.fd_t) void {
    for (fds) |fd| _ = c.close(fd);
}

/// 제어 버퍼의 SCM_RIGHTS fd 를 모두 꺼낸다. 잘린 헤더는 원래 길이를 들고 있으므로 버퍼 끝에서 자른다.
fn collectReceivedFds(control: []const u8, out: []c.fd_t) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + @sizeOf(c.cmsghdr) <= control.len) {
        const header = std.mem.bytesToValue(c.cmsghdr, control[offset..][0..@sizeOf(c.cmsghdr)]);
        if (header.len < @sizeOf(c.cmsghdr)) break;
        const end = @min(offset + header.len, control.len);
        if (header.level == c.SOL.SOCKET and header.type == c.SCM.RIGHTS) {
            const data = control[offset + @sizeOf(c.cmsghdr) .. end];
            var i: usize = 0;
            while (i + @sizeOf(c.fd_t) <= data.len and count < out.len) : (i += @sizeOf(c.fd_t)) {
                out[count] = std.mem.bytesToValue(c.fd_t, data[i..][0..@sizeOf(c.fd_t)]);
                count += 1;
            }
        }
        offset += std.mem.alignForward(usize, header.len, @sizeOf(u32));
    }
    return count;
}

// ─── 판정자(docs/session-host-image-channel.md §6, 계획 IC3b) ───
//
// 실제 socketpair 와 실제 공유 메모리 세그먼트(`image_segment.create`)로 잰다. host 쪽 끝은 테스트가 sendmsg 로 직접 쓴다.

const testing = std.testing;
const image_segment = @import("image_segment.zig");

const Pair = struct {
    app: c.fd_t,
    host: c.fd_t,

    fn init() !Pair {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.TestUnexpectedResult;
        for (fds) |fd| {
            const one: c_int = 1;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, std.mem.asBytes(&one), @sizeOf(c_int));
        }
        // host 끝도 논블로킹 — release 가 안 오는 결함에서 판정자가 멈추지 않고 실패하게.
        for (fds) |fd| _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        return .{ .app = fds[0], .host = fds[1] };
    }

    fn deinit(self: Pair) void {
        if (self.app >= 0) _ = c.close(self.app);
        if (self.host >= 0) _ = c.close(self.host);
    }
};

/// host 쪽 끝에 바이트와 fd 들을 한 번의 sendmsg 로 쓴다.
fn sendWithFds(host: c.fd_t, bytes: []const u8, fds: []const c.fd_t) !void {
    var control: [64]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
    const control_len = std.mem.alignForward(usize, @sizeOf(c.cmsghdr) + fds.len * @sizeOf(c.fd_t), @sizeOf(u32));
    if (fds.len != 0) {
        const header: c.cmsghdr = .{ .len = @intCast(@sizeOf(c.cmsghdr) + fds.len * @sizeOf(c.fd_t)), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS };
        @memcpy(control[0..@sizeOf(c.cmsghdr)], std.mem.asBytes(&header));
        @memcpy(control[@sizeOf(c.cmsghdr)..][0 .. fds.len * @sizeOf(c.fd_t)], std.mem.sliceAsBytes(fds));
    }
    var iov = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const msg: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = if (fds.len != 0) &control else null,
        .controllen = if (fds.len != 0) @intCast(control_len) else 0,
        .flags = 0,
    };
    if (c.sendmsg(host, &msg, 0) != bytes.len) return error.TestUnexpectedResult;
}

/// 픽셀을 담은 세그먼트를 만들어 그 메시지를 fd 하나와 함께 보낸다. 보낸 쪽 fd 는 닫는다(host 와 같다).
fn sendSegment(host: c.fd_t, segment: image_channel_wire.Segment, pixels: []const u8) !void {
    const created = (try image_segment.create(pixels)).?;
    defer _ = c.close(created.fd);
    try sendWithFds(host, &(try image_channel_wire.encodeSegment(segment)), &.{created.fd});
}

fn seg(segment_id: u64, stream_id: u64, pixels: []const u8) image_channel_wire.Segment {
    return .{ .segment_id = segment_id, .stream_id = stream_id, .image_id = 7, .generation = 0x900 + segment_id, .byte_len = @intCast(pixels.len) };
}

fn refOf(segment: image_channel_wire.Segment) Ref {
    return .{ .segment_id = segment.segment_id, .image_id = segment.image_id, .generation = segment.generation, .byte_len = segment.byte_len };
}

/// 이 프로세스에 열린 fd 수 — 표가 fd 를 새거나 덜 닫는지 잰다.
fn openFdCount() usize {
    var count: usize = 0;
    var fd: c.fd_t = 0;
    while (fd < 4096) : (fd += 1) {
        if (c.fcntl(fd, c.F.GETFD) != -1) count += 1;
    }
    return count;
}

/// host 쪽 끝에서 release 들을 읽는다.
fn readReleases(host: c.fd_t, out: []u64) !usize {
    var buf: [capacity * image_channel_wire.release_len]u8 = undefined;
    const n = c.read(host, &buf, buf.len);
    if (n < 0) return error.TestUnexpectedResult;
    var split: image_channel_wire.ReleaseSplit = .{ .bytes = buf[0..@intCast(n)] };
    var count: usize = 0;
    while (try split.next()) |id| : (count += 1) out[count] = id;
    try testing.expectEqual(@as(usize, 0), split.rest().len);
    return count;
}

test "client image segments: a segment arrives with one close-on-exec fd, resolves to its pixels, and is released exactly once" {
    const pair = try Pair.init();
    defer pair.deinit();
    const baseline = openFdCount();
    var table: Table = .{};
    defer table.deinit();
    try table.openStream(1);
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const s = seg(5, 1, &pixels);
    try sendSegment(pair.host, s, &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 1), table.len);
    const fd = table.entries[0].fd;
    try testing.expect(c.fcntl(fd, c.F.GETFD) & c.FD_CLOEXEC != 0);
    try testing.expectEqual(baseline + 1, openFdCount());

    const mapping = (try table.resolve(1, refOf(s))).?;
    defer unmapPixels(mapping.pixels);
    try testing.expectEqualSlices(u8, &pixels, mapping.pixels);
    try testing.expectEqual(@as(usize, 0), table.len);
    try testing.expectEqual(baseline, openFdCount()); // fd 는 닫혔고 매핑은 산다.
    // 두 번째 해석은 없다 — 반환은 한 번이다.
    try testing.expect((try table.resolve(1, refOf(s))) == null);

    try table.flush(pair.app);
    var ids: [capacity]u64 = undefined;
    try testing.expectEqual(@as(usize, 1), try readReleases(pair.host, &ids));
    try testing.expectEqual(@as(u64, 5), ids[0]);
    try testing.expectEqual(@as(usize, 0), table.tx_len);
}

test "client image segments: a message split across reads keeps its fd, and an fd on a continuation or a missing or extra fd is a host violation" {
    const pixels = [_]u8{ 9, 9, 9, 9 };
    // 나뉘어 와도 첫 조각의 fd 가 그 메시지 몫이다.
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var table: Table = .{};
        defer table.deinit();
        try table.openStream(1);
        const created = (try image_segment.create(&pixels)).?;
        defer _ = c.close(created.fd);
        const bytes = try image_channel_wire.encodeSegment(seg(3, 1, &pixels));
        try sendWithFds(pair.host, bytes[0..11], &.{created.fd});
        try table.drain(pair.app);
        try testing.expectEqual(@as(usize, 0), table.len);
        try testing.expect(table.rx_fd >= 0);
        try sendWithFds(pair.host, bytes[11..], &.{});
        try table.drain(pair.app);
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(@as(u64, 3), table.entries[0].segment.segment_id);
    }
    const Case = struct { first: usize, first_fds: usize, rest_fds: usize };
    for ([_]Case{
        .{ .first = image_channel_wire.segment_len, .first_fds = 0, .rest_fds = 0 }, // fd 없음(EMFILE 이 조용히 버린 꼴)
        .{ .first = image_channel_wire.segment_len, .first_fds = 2, .rest_fds = 0 }, // fd 둘
        .{ .first = 11, .first_fds = 1, .rest_fds = 1 }, // 이어 읽는 조각에 fd
    }) |case| {
        const pair = try Pair.init();
        defer pair.deinit();
        const baseline = openFdCount();
        var table: Table = .{};
        defer table.deinit();
        try table.openStream(1);
        const a = (try image_segment.create(&pixels)).?;
        const b = (try image_segment.create(&pixels)).?;
        const bytes = try image_channel_wire.encodeSegment(seg(4, 1, &pixels));
        const both = [_]c.fd_t{ a.fd, b.fd };
        try sendWithFds(pair.host, bytes[0..case.first], both[0..case.first_fds]);
        if (case.first < bytes.len) try sendWithFds(pair.host, bytes[case.first..], both[1..][0..case.rest_fds]);
        _ = c.close(a.fd);
        _ = c.close(b.fd);
        try testing.expectError(error.PeerContractViolation, table.drain(pair.app));
        table.deinit();
        // 받은 fd 는 거부해도 전부 닫혔다.
        try testing.expectEqual(baseline, openFdCount());
    }
}

test "client image segments: a closed stream's segments are returned on arrival while an unknown higher stream's are kept" {
    const pair = try Pair.init();
    defer pair.deinit();
    var table: Table = .{};
    defer table.deinit();
    const pixels = [_]u8{ 1, 1, 1, 1 };
    try table.openStream(1);
    try table.openStream(2);
    try sendSegment(pair.host, seg(10, 1, &pixels), &pixels);
    try sendSegment(pair.host, seg(11, 2, &pixels), &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 2), table.len);

    // stream 1 이 닫히면 그 항목을 반환한다.
    table.closeStream(1);
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(@as(u64, 11), table.entries[0].segment.segment_id);
    // 닫힌 뒤 늦게 온 stream 1 세그먼트는 즉시 반환한다. 아직 attach 응답을 못 읽은 stream 3 은 남긴다.
    try sendSegment(pair.host, seg(12, 1, &pixels), &pixels);
    try sendSegment(pair.host, seg(13, 3, &pixels), &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 2), table.len);
    try testing.expect(table.indexOf(12) == null);
    try testing.expect(table.indexOf(13) != null);

    try table.flush(pair.app);
    var ids: [capacity]u64 = undefined;
    const n = try readReleases(pair.host, &ids);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOfScalar(u64, ids[0..n], 10) != null);
    try testing.expect(std.mem.indexOfScalar(u64, ids[0..n], 12) != null);
}

test "client image segments: an unresolvable ref leaves the entry for the hwm sweep, which returns only its stream at or below the mark" {
    const pair = try Pair.init();
    defer pair.deinit();
    var table: Table = .{};
    defer table.deinit();
    const pixels = [_]u8{ 4, 4, 4, 4 };
    try table.openStream(1);
    try table.openStream(2);
    try sendSegment(pair.host, seg(20, 1, &pixels), &pixels);
    try sendSegment(pair.host, seg(21, 1, &pixels), &pixels);
    try sendSegment(pair.host, seg(22, 2, &pixels), &pixels);
    try table.drain(pair.app);

    // 다른 stream·메타 불일치·없음 — 모두 null 이고 항목은 남는다.
    try testing.expect((try table.resolve(2, refOf(seg(20, 1, &pixels)))) == null);
    var other_generation = refOf(seg(20, 1, &pixels));
    other_generation.generation += 1;
    try testing.expect((try table.resolve(1, other_generation)) == null);
    var other_image = refOf(seg(20, 1, &pixels));
    other_image.image_id += 1;
    try testing.expect((try table.resolve(1, other_image)) == null);
    var other_len = refOf(seg(20, 1, &pixels));
    other_len.byte_len += 1;
    try testing.expect((try table.resolve(1, other_len)) == null);
    try testing.expect((try table.resolve(1, refOf(seg(99, 1, &pixels)))) == null);
    try testing.expectEqual(@as(usize, 3), table.len);
    // 공유 메모리가 메시지·레코드의 크기보다 작으면 매핑하지 않는다(넘겨 읽으면 SIGBUS 다). macOS 는 공유 메모리 크기를 페이지
    // 단위로 올리므로 페이지를 넘는 차이로 잰다.
    {
        const created = (try image_segment.create(&pixels)).?;
        defer _ = c.close(created.fd);
        try table.openStream(4);
        var short = seg(23, 4, &pixels);
        short.byte_len = 4 * 1024 * 1024;
        try sendWithFds(pair.host, &(try image_channel_wire.encodeSegment(short)), &.{created.fd});
        try table.drain(pair.app);
        try testing.expect((try table.resolve(4, refOf(short))) == null);
        try testing.expect(table.indexOf(23) != null);
        table.sweep(4, 23);
        try table.flush(pair.app);
        var drained: [capacity]u64 = undefined;
        _ = try readReleases(pair.host, &drained);
    }
    try testing.expectEqual(@as(usize, 0), table.tx_len);

    // stream 1 의 hwm 20: 20 만 반환. 21(더 큼)과 stream 2 의 22 는 남는다.
    table.sweep(1, 20);
    try testing.expectEqual(@as(usize, 2), table.len);
    try testing.expect(table.indexOf(20) == null);
    try testing.expect(table.indexOf(21) != null);
    try testing.expect(table.indexOf(22) != null);
    try table.flush(pair.app);
    var ids: [capacity]u64 = undefined;
    try testing.expectEqual(@as(usize, 1), try readReleases(pair.host, &ids));
    try testing.expectEqual(@as(u64, 20), ids[0]);
}

test "client image segments: more outstanding segments than the host ledger allows, or a repeated id, is a host violation" {
    const pixels = [_]u8{ 2, 2, 2, 2 };
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var table: Table = .{};
        defer table.deinit();
        try table.openStream(1);
        var id: u64 = 1;
        while (id <= capacity) : (id += 1) try sendSegment(pair.host, seg(id, 1, &pixels), &pixels);
        try table.drain(pair.app);
        try testing.expectEqual(capacity, table.len);
        // 반환해도 아직 못 보낸 release 는 host 에게 미반환이다 — 상한은 그 합으로 잰다.
        table.sweep(1, 1);
        try sendSegment(pair.host, seg(capacity + 1, 1, &pixels), &pixels);
        try testing.expectError(error.PeerContractViolation, table.drain(pair.app));
    }
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var table: Table = .{};
        defer table.deinit();
        try table.openStream(1);
        try sendSegment(pair.host, seg(1, 1, &pixels), &pixels);
        try sendSegment(pair.host, seg(1, 1, &pixels), &pixels);
        try testing.expectError(error.PeerContractViolation, table.drain(pair.app));
    }
}

test "client image segments: EOF and a bad header lose the channel, and dropping the table closes every fd it held" {
    const pixels = [_]u8{ 3, 3, 3, 3 };
    {
        var pair = try Pair.init();
        defer pair.deinit();
        const baseline = openFdCount();
        var table: Table = .{};
        defer table.deinit();
        try table.openStream(1);
        try sendSegment(pair.host, seg(1, 1, &pixels), &pixels);
        try sendSegment(pair.host, seg(2, 1, &pixels), &pixels);
        // 반쪽만 온 셋째 메시지의 fd 도 표가 쥔다.
        const created = (try image_segment.create(&pixels)).?;
        const bytes = try image_channel_wire.encodeSegment(seg(3, 1, &pixels));
        try sendWithFds(pair.host, bytes[0..5], &.{created.fd});
        _ = c.close(created.fd);
        try table.drain(pair.app);
        _ = c.close(pair.host);
        pair.host = -1;
        try testing.expectError(error.ChannelLost, table.drain(pair.app));
        // 세그먼트 셋(반쪽 포함)을 쥐고 있다 — host 끝 하나는 테스트가 닫았다.
        try testing.expectEqual(baseline + 3 - 1, openFdCount());
        table.dropSegments();
        try testing.expectEqual(baseline - 1, openFdCount());
        try testing.expectEqual(@as(usize, 0), table.outstanding());
        try testing.expectEqual(@as(usize, 1), table.liveStreams().len); // 주 연결은 살아 stream 추적은 남는다.
    }
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var table: Table = .{};
        defer table.deinit();
        const created = (try image_segment.create(&pixels)).?;
        defer _ = c.close(created.fd);
        var bytes = try image_channel_wire.encodeSegment(seg(1, 1, &pixels));
        bytes[0] = 'X';
        try sendWithFds(pair.host, &bytes, &.{created.fd});
        try testing.expectError(error.ChannelLost, table.drain(pair.app));
    }
}

test "client image segments: a release the peer cannot take is a lost channel, and a mapping outlives its closed fd" {
    var pair = try Pair.init();
    defer pair.deinit();
    var table: Table = .{};
    defer table.deinit();
    try table.openStream(1);
    const pixels = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01 };
    try sendSegment(pair.host, seg(1, 1, &pixels), &pixels);
    try table.drain(pair.app);
    const mapping = (try table.resolve(1, refOf(seg(1, 1, &pixels)))).?;
    _ = c.close(pair.host);
    pair.host = -1;
    try testing.expectError(error.ChannelLost, table.flush(pair.app));
    // host 가 채널을 닫아도(원장 반환) 앱의 매핑은 유효하다(§10).
    try testing.expectEqualSlices(u8, &pixels, mapping.pixels);
    unmapPixels(mapping.pixels);
}

test "client image segments: learning a higher stream id retires entries of streams that never opened, and the newest closed stream is closed" {
    const pair = try Pair.init();
    defer pair.deinit();
    var table: Table = .{};
    defer table.deinit();
    const pixels = [_]u8{ 5, 5, 5, 5 };
    // 응답을 못 읽은 stream 3 의 세그먼트는 남는다.
    try sendSegment(pair.host, seg(30, 3, &pixels), &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 1), table.len);
    // stream 3 이 열리지 않은 채 5 가 열리면 3 은 지나간 stream 이다 — 그 항목이 원장 자리를 영구히 쥐면 안 된다.
    try table.openStream(5);
    try testing.expectEqual(@as(usize, 0), table.len);
    // 가장 최근 stream 을 닫아도 닫힌 것이다(최대 id 와 같은 id).
    table.closeStream(5);
    try sendSegment(pair.host, seg(31, 5, &pixels), &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 0), table.len);
    // 열린 적 없는 더 큰 stream 을 닫아도 그 이하가 닫힌 것이 된다.
    table.closeStream(7);
    try sendSegment(pair.host, seg(32, 6, &pixels), &pixels);
    try table.drain(pair.app);
    try testing.expectEqual(@as(usize, 0), table.len);
    try table.flush(pair.app);
    var ids: [capacity]u64 = undefined;
    try testing.expectEqual(@as(usize, 3), try readReleases(pair.host, &ids));
}

test "client image segments: a release that does not fit waits whole and arrives intact after the peer drains" {
    const pair = try Pair.init();
    defer pair.deinit();
    var table: Table = .{};
    defer table.deinit();
    const pixels = [_]u8{ 6, 6, 6, 6 };
    try table.openStream(1);
    try sendSegment(pair.host, seg(40, 1, &pixels), &pixels);
    try sendSegment(pair.host, seg(41, 1, &pixels), &pixels);
    try table.drain(pair.app);
    // host 가 안 읽어 채널이 찬 상태를 만든다(앱 → host 방향). 남는 자리를 한 바이트까지 채운다.
    var junk: usize = 0;
    var filler: [1]u8 = .{0};
    var chunk: [4096]u8 = @splat(0);
    while (true) {
        const n = c.write(pair.app, &chunk, chunk.len);
        if (n <= 0) break;
        junk += @intCast(n);
    }
    while (c.write(pair.app, &filler, 1) == 1) junk += 1;
    table.sweep(1, 41);
    try testing.expectEqual(@as(usize, 2 * image_channel_wire.release_len), table.tx_len);
    try table.flush(pair.app);
    try testing.expect(table.tx_len != 0);
    try testing.expectEqual(@as(usize, 2), table.outstanding());
    // host 가 밀린 것을 비우면 남은 release 가 이어 쓰여 경계가 맞는 채로 도착한다.
    var drained: usize = 0;
    while (drained < junk) {
        const n = c.read(pair.host, &chunk, @min(chunk.len, junk - drained));
        if (n <= 0) break;
        drained += @intCast(n);
    }
    try testing.expectEqual(junk, drained);
    const written_before: usize = 2 * image_channel_wire.release_len - table.tx_len;
    var head: [2 * image_channel_wire.release_len]u8 = undefined;
    if (written_before != 0) {
        const n = c.read(pair.host, &head, written_before);
        try testing.expectEqual(@as(isize, @intCast(written_before)), n);
    }
    try table.flush(pair.app);
    try testing.expectEqual(@as(usize, 0), table.tx_len);
    const rest = c.read(pair.host, head[written_before..].ptr, head.len - written_before);
    try testing.expectEqual(@as(isize, @intCast(head.len - written_before)), rest);
    var split: image_channel_wire.ReleaseSplit = .{ .bytes = &head };
    var got: [2]u64 = undefined;
    var count: usize = 0;
    while (try split.next()) |id| : (count += 1) got[count] = id;
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.indexOfScalar(u64, &got, 40) != null);
    try testing.expect(std.mem.indexOfScalar(u64, &got, 41) != null);
}

test "client image segments: the fingerprint moves with every live field and ignores unused slots" {
    const empty: Table = .{};
    const base = empty.fingerprint();
    // 빈 칸은 상태가 아니다 — 쓰지 않는 칸이 달라도 지문은 같다(스냅샷 전후 비교가 거짓으로 어긋나지 않게).
    var unused: Table = .{};
    unused.entries[3].fd = 99;
    unused.rx[5] = 1;
    unused.tx[7] = 1;
    unused.live[9] = 1;
    try testing.expectEqualSlices(u8, &base, &unused.fingerprint());
    const Change = *const fn (*Table) void;
    const changes = [_]Change{
        struct {
            fn f(t: *Table) void {
                t.entries[0] = .{ .segment = .{ .segment_id = 1, .stream_id = 2, .image_id = 3, .generation = 4, .byte_len = 5 }, .fd = -1 };
                t.len = 1;
            }
        }.f,
        struct {
            fn f(t: *Table) void {
                t.rx[0] = 1;
                t.rx_len = 1;
            }
        }.f,
        struct {
            fn f(t: *Table) void {
                t.rx_fd = 7;
            }
        }.f,
        struct {
            fn f(t: *Table) void {
                t.tx[0] = 1;
                t.tx_len = 1;
            }
        }.f,
        struct {
            fn f(t: *Table) void {
                t.live[0] = 4;
                t.live_len = 1;
            }
        }.f,
        struct {
            fn f(t: *Table) void {
                t.max_known_stream = 4;
            }
        }.f,
    };
    for (changes) |change| {
        var table: Table = .{};
        change(&table);
        try testing.expect(!std.mem.eql(u8, &base, &table.fingerprint()));
    }
    // 항목의 각 칸도 덮는다.
    const one: Entry = .{ .segment = .{ .segment_id = 1, .stream_id = 2, .image_id = 3, .generation = 4, .byte_len = 5 }, .fd = 6 };
    var reference: Table = .{};
    reference.entries[0] = one;
    reference.len = 1;
    const with_one = reference.fingerprint();
    inline for (.{ "segment_id", "stream_id", "image_id", "generation", "byte_len" }) |name| {
        var table = reference;
        @field(table.entries[0].segment, name) += 1;
        try testing.expect(!std.mem.eql(u8, &with_one, &table.fingerprint()));
    }
    var other_fd = reference;
    other_fd.entries[0].fd = 8;
    try testing.expect(!std.mem.eql(u8, &with_one, &other_fd.fingerprint()));
    // 길이가 같아도 쓰는 칸의 내용이 다르면 다르다(길이만 덮으면 위 판정은 초록이다).
    var filled: Table = .{};
    filled.rx[0] = 1;
    filled.rx_len = 1;
    filled.tx[0] = 1;
    filled.tx_len = 1;
    filled.live[0] = 4;
    filled.live_len = 1;
    const with_filled = filled.fingerprint();
    var changed = filled;
    changed.rx[0] = 2;
    try testing.expect(!std.mem.eql(u8, &with_filled, &changed.fingerprint()));
    changed = filled;
    changed.tx[0] = 2;
    try testing.expect(!std.mem.eql(u8, &with_filled, &changed.fingerprint()));
    changed = filled;
    changed.live[0] = 5;
    try testing.expect(!std.mem.eql(u8, &with_filled, &changed.fingerprint()));
}
