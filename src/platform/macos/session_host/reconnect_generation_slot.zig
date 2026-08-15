//! CR2e-c reconnect generation 저장소 substrate.
//!
//! stable shell 안의 최초 inline node와 reconnect별 heap node가 같은 payload 타입을 소유한다.
//! 실제 `RemoteGeneration` prepare/publish/destructor 배선은 CR2e-d가 이 generic owner를 사용해 닫는다.

const std = @import("std");
const process_identity = @import("process_identity.zig");

pub const NodeLifecycle = enum(u8) { pristine, building, candidate, current, retiring, tombstone, reclaimed };
pub const SlotLifecycle = enum(u8) { pristine, live, closed };

pub fn GenerationSlot(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const PayloadSource = struct {
            present: bool = false,
            value: Payload = undefined,

            pub fn init(value: Payload) PayloadSource {
                return .{ .present = true, .value = value };
            }
        };

        pub const Node = struct {
            self_addr: usize = 0,
            slot_addr: usize = 0,
            generation: u64 = 0,
            heap_owned: bool = false,
            lifecycle: NodeLifecycle = .pristine,
            payload_present: bool = false,
            payload: Payload = undefined,
        };

        pub const PreparedCandidate = struct {
            self_addr: usize = 0,
            slot_addr: usize = 0,
            node_addr: usize = 0,
            generation: u64 = 0,
            active: bool = false,
        };

        self_addr: usize = 0,
        owner_pid: u32 = 0,
        owner_thread: ?std.Thread.Id = null,
        allocator: ?std.mem.Allocator = null,
        lifecycle: SlotLifecycle = .pristine,
        next_generation: u64 = 0,
        inline_node: Node = .{},
        current: ?*Node = null,
        retiring: ?*Node = null,
        candidate: ?*Node = null,

        pub fn initInPlace(
            self: *Self,
            allocator: std.mem.Allocator,
            initial_generation: u64,
            args: anytype,
            comptime initializer: anytype,
        ) !void {
            if (!self.pristine()) return error.InvalidAuthority;
            if (initial_generation == 0 or initial_generation == std.math.maxInt(u64))
                return error.InvalidAuthority;
            const owner_pid = process_identity.currentProcessId();
            if (owner_pid == 0) return error.InvalidAuthority;

            self.* = .{
                .self_addr = @intFromPtr(self),
                .owner_pid = owner_pid,
                .owner_thread = std.Thread.getCurrentId(),
                .allocator = allocator,
                .lifecycle = .live,
                .next_generation = initial_generation + 1,
            };
            self.inline_node = .{
                .self_addr = @intFromPtr(&self.inline_node),
                .slot_addr = self.self_addr,
                .generation = initial_generation,
                .heap_owned = false,
                .lifecycle = .building,
                .payload_present = false,
            };
            self.current = &self.inline_node;
            initializer(&self.inline_node.payload, args) catch |err| {
                self.* = .{};
                return err;
            };
            self.inline_node.payload_present = true;
            self.inline_node.lifecycle = .current;
        }

        pub fn beginCandidate(self: *Self, out: *PreparedCandidate) !void {
            try self.validateLive();
            if (rangesOverlap(self, @sizeOf(Self), out, @sizeOf(PreparedCandidate)))
                return error.InvalidAuthority;
            if (!std.meta.eql(out.*, PreparedCandidate{})) return error.InvalidAuthority;
            if (self.retiring != null) return error.RetiringBusy;
            if (self.candidate != null) return error.Busy;
            const generation = self.next_generation;
            const next = std.math.add(u64, generation, 1) catch return error.Exhausted;
            const allocator = self.allocator.?;
            const node = try allocator.create(Node);
            errdefer allocator.destroy(node);
            node.* = .{
                .self_addr = @intFromPtr(node),
                .slot_addr = self.self_addr,
                .generation = generation,
                .heap_owned = true,
                .lifecycle = .building,
                .payload_present = false,
            };
            out.* = .{
                .self_addr = @intFromPtr(out),
                .slot_addr = self.self_addr,
                .node_addr = @intFromPtr(node),
                .generation = generation,
                .active = true,
            };
            self.next_generation = next;
            self.candidate = node;
        }

        pub fn initializeCandidate(
            self: *Self,
            prepared: *PreparedCandidate,
            args: anytype,
            comptime initializer: anytype,
        ) !void {
            try self.validateLive();
            const node = try self.validateBuildingCandidate(prepared);
            try initializer(&node.payload, args);
            node.payload_present = true;
            node.lifecycle = .candidate;
        }

        pub fn abortEmptyCandidate(self: *Self, prepared: *PreparedCandidate) !void {
            try self.validateLive();
            const node = try self.validateBuildingCandidate(prepared);
            node.lifecycle = .reclaimed;
            self.allocator.?.destroy(node);
            self.candidate = null;
            prepared.* = .{};
        }

        pub fn publishCandidate(self: *Self, prepared: *PreparedCandidate) !void {
            try self.preflightPublishCandidate(prepared);
            self.publishCandidateNoFail(prepared);
        }

        /// Stable screen writer gate처럼 더 큰 publication 임계구역을 소유한 caller가 mutation 전에
        /// candidate와 retiring capacity를 검증할 때 사용한다. payload의 mutable borrow는 열지 않는다.
        pub fn preflightPublishCandidate(self: *Self, prepared: *PreparedCandidate) !void {
            try self.validateLive();
            const node = try self.validateCandidate(prepared);
            if (self.retiring != null) return error.RetiringBusy;
            const old = self.current orelse return error.InvalidAuthority;
            if (!validNode(self, old, .current) or old == node) return error.InvalidAuthority;
        }

        /// `preflightPublishCandidate` 직후 같은 owner thread의 외부 writer gate 안에서만 호출한다.
        /// checked preflight 뒤에는 실패 분기가 없어 slot current와 외부 target을 한 publication으로 묶을 수 있다.
        pub fn publishCandidateNoFail(self: *Self, prepared: *PreparedCandidate) void {
            self.preflightPublishCandidate(prepared) catch
                @panic("generation slot publish proof lost after preflight");
            const node = self.candidate.?;
            const old = self.current.?;
            old.lifecycle = .retiring;
            node.lifecycle = .current;
            self.retiring = old;
            self.current = node;
            self.candidate = null;
            prepared.* = .{};
        }

        pub fn candidatePayload(
            self: *Self,
            prepared: *PreparedCandidate,
        ) !*const Payload {
            try self.validateLive();
            const node = try self.validateCandidate(prepared);
            return &node.payload;
        }

        pub fn abortCandidate(
            self: *Self,
            prepared: *PreparedCandidate,
            out: *PayloadSource,
        ) !void {
            try self.validateLive();
            if (rangesOverlap(self, @sizeOf(Self), out, @sizeOf(PayloadSource)) or
                rangesOverlap(prepared, @sizeOf(PreparedCandidate), out, @sizeOf(PayloadSource)))
                return error.InvalidAuthority;
            if (out.present) return error.InvalidAuthority;
            const node = try self.validateCandidate(prepared);
            out.* = .{ .present = true, .value = node.payload };
            node.payload_present = false;
            node.lifecycle = .reclaimed;
            self.allocator.?.destroy(node);
            self.candidate = null;
            prepared.* = .{};
        }

        pub fn reclaimRetiring(self: *Self, out: *PayloadSource) !void {
            try self.validateLive();
            if (rangesOverlap(self, @sizeOf(Self), out, @sizeOf(PayloadSource)))
                return error.InvalidAuthority;
            if (out.present) return error.InvalidAuthority;
            const node = self.retiring orelse return error.NoRetiringGeneration;
            if (!validNode(self, node, .retiring) or !node.payload_present) return error.InvalidAuthority;
            out.* = .{ .present = true, .value = node.payload };
            node.payload_present = false;
            self.retiring = null;
            if (node.heap_owned) {
                node.lifecycle = .reclaimed;
                self.allocator.?.destroy(node);
            } else {
                if (node != &self.inline_node) return error.InvalidAuthority;
                node.lifecycle = .tombstone;
            }
        }

        /// final-address payload를 값으로 move하지 않고 canonical node 주소에서 exact once 파괴한다.
        pub fn reclaimRetiringInPlace(
            self: *Self,
            context: anytype,
            comptime deinitializer: anytype,
        ) !void {
            try self.validateLive();
            const node = self.retiring orelse return error.NoRetiringGeneration;
            if (!validNode(self, node, .retiring) or !node.payload_present) return error.InvalidAuthority;
            deinitializer(&node.payload, context);
            node.payload_present = false;
            self.retiring = null;
            if (node.heap_owned) {
                node.lifecycle = .reclaimed;
                self.allocator.?.destroy(node);
            } else {
                if (node != &self.inline_node) return error.InvalidAuthority;
                node.lifecycle = .tombstone;
            }
        }

        pub fn abortCandidateInPlace(
            self: *Self,
            prepared: *PreparedCandidate,
            context: anytype,
            comptime deinitializer: anytype,
        ) !void {
            try self.validateLive();
            const node = try self.validateCandidate(prepared);
            deinitializer(&node.payload, context);
            node.payload_present = false;
            node.lifecycle = .reclaimed;
            self.allocator.?.destroy(node);
            self.candidate = null;
            prepared.* = .{};
        }

        pub fn deinit(self: *Self, out: *PayloadSource) !void {
            try self.validateLive();
            if (rangesOverlap(self, @sizeOf(Self), out, @sizeOf(PayloadSource))) return error.InvalidAuthority;
            if (self.retiring != null or self.candidate != null or out.present) return error.Busy;
            const node = self.current orelse return error.InvalidAuthority;
            if (!validNode(self, node, .current) or !node.payload_present) return error.InvalidAuthority;
            out.* = .{ .present = true, .value = node.payload };
            node.payload_present = false;
            self.current = null;
            if (node.heap_owned) {
                node.lifecycle = .reclaimed;
                self.allocator.?.destroy(node);
            } else {
                node.lifecycle = .tombstone;
            }
            self.lifecycle = .closed;
        }

        pub fn deinitInPlace(
            self: *Self,
            context: anytype,
            comptime deinitializer: anytype,
        ) !void {
            try self.validateLive();
            if (self.retiring != null or self.candidate != null) return error.Busy;
            const node = self.current orelse return error.InvalidAuthority;
            if (!validNode(self, node, .current) or !node.payload_present) return error.InvalidAuthority;
            deinitializer(&node.payload, context);
            node.payload_present = false;
            self.current = null;
            if (node.heap_owned) {
                node.lifecycle = .reclaimed;
                self.allocator.?.destroy(node);
            } else {
                node.lifecycle = .tombstone;
            }
            self.lifecycle = .closed;
        }

        pub fn currentGeneration(self: *const Self) !u64 {
            try self.validateLive();
            return self.current.?.generation;
        }

        pub fn currentPayload(self: *const Self) !*const Payload {
            try self.validateLive();
            const node = self.current.?;
            if (!validNode(self, node, .current) or !node.payload_present) return error.InvalidAuthority;
            return &node.payload;
        }

        pub fn hasRetiring(self: *const Self) !bool {
            try self.validateLive();
            return self.retiring != null;
        }

        fn validateLive(self: *const Self) !void {
            if (self.self_addr != @intFromPtr(self) or self.owner_pid == 0 or
                self.owner_pid != process_identity.currentProcessId() or self.owner_thread == null or
                self.owner_thread.? != std.Thread.getCurrentId() or self.lifecycle != .live or
                self.allocator == null or self.next_generation == 0 or self.current == null)
                return error.InvalidAuthority;
            if (!validNode(self, self.current.?, .current)) return error.InvalidAuthority;
            if (self.retiring) |node| {
                if (node == self.current.? or !validNode(self, node, .retiring)) return error.InvalidAuthority;
            }
            if (self.candidate) |node| {
                if (node == self.current.? or node == self.retiring or
                    (!validNode(self, node, .building) and !validNode(self, node, .candidate)))
                    return error.InvalidAuthority;
            }
        }

        fn validateCandidate(self: *const Self, prepared: *const PreparedCandidate) !*Node {
            const node = try self.validateCandidateIdentity(prepared);
            if (!validNode(self, node, .candidate) or !node.payload_present) return error.InvalidAuthority;
            return node;
        }

        fn validateBuildingCandidate(self: *const Self, prepared: *const PreparedCandidate) !*Node {
            const node = try self.validateCandidateIdentity(prepared);
            if (!validNode(self, node, .building) or node.payload_present) return error.InvalidAuthority;
            return node;
        }

        fn validateCandidateIdentity(self: *const Self, prepared: *const PreparedCandidate) !*Node {
            if (!prepared.active or prepared.self_addr != @intFromPtr(prepared) or
                prepared.slot_addr != self.self_addr or prepared.node_addr == 0 or self.candidate == null or
                prepared.generation == 0 or prepared.generation >= self.next_generation)
                return error.InvalidAuthority;
            const node = self.candidate.?;
            if (prepared.node_addr != @intFromPtr(node)) return error.InvalidAuthority;
            if (node.generation != prepared.generation or !node.heap_owned) return error.InvalidAuthority;
            return node;
        }

        fn validNode(self: *const Self, node: *const Node, expected: NodeLifecycle) bool {
            return node.self_addr == @intFromPtr(node) and node.slot_addr == self.self_addr and
                node.generation != 0 and node.generation < self.next_generation and
                (node.heap_owned or node == &self.inline_node) and
                node.lifecycle == expected;
        }

        fn pristine(self: *const Self) bool {
            return self.self_addr == 0 and self.owner_pid == 0 and self.owner_thread == null and self.allocator == null and
                self.lifecycle == .pristine and self.next_generation == 0 and self.current == null and
                self.retiring == null and self.candidate == null and self.inline_node.self_addr == 0 and
                self.inline_node.slot_addr == 0 and self.inline_node.generation == 0 and
                !self.inline_node.heap_owned and self.inline_node.lifecycle == .pristine and
                !self.inline_node.payload_present;
        }
    };
}

fn rangesOverlap(a: anytype, a_len: usize, b: anytype, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}
