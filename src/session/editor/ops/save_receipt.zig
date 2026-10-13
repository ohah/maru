//! 화면과 저장 요청이 각각 소유하는 완료 결과다. 메인 actor에서만 접근한다.
const std = @import("std");
pub const Result = union(enum) { pending, saved, failed: anyerror };
pub const Receipt = struct {
    a: std.mem.Allocator,
    references: usize = 1,
    result: Result = .pending,
    pub fn create(a: std.mem.Allocator) !*Receipt {
        const self = try a.create(Receipt);
        self.* = .{ .a = a };
        return self;
    }
    pub fn ensureUnused(self: *const Receipt) !void {
        if (self.result != .pending) return error.CompletedReceipt;
        if (self.references != 1) return error.ReceiptInUse;
    }
    pub fn hasConsumer(self: *const Receipt) bool {
        return self.references > 1;
    }
    pub fn retain(self: *Receipt) void {
        if (self.references == 0 or self.references == std.math.maxInt(usize)) unreachable;
        self.references += 1;
    }
    pub fn release(self: *Receipt) void {
        if (self.references == 0) unreachable;
        self.references -= 1;
        if (self.references == 0) self.a.destroy(self);
    }
    /// 실제 완료를 한 번만 게시한다. 후속 실패가 이미 게시한 결과를 덮지 않는다.
    pub fn complete(self: *Receipt, failure: ?anyerror) void {
        if (self.result != .pending) return;
        self.result = if (failure) |err| .{ .failed = err } else .saved;
    }
};
