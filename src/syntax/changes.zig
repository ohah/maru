//! 같은 Provider의 직전 파싱 결과를 동기 조회 동안 빌리는 비소비형 byte 범위다.
pub const Range = struct { lo: u32, hi: u32 };

pub const Batch = struct {
    before: u64,
    after: u64,
    ranges: []const Range,

    /// 소유자/트리 수명은 호출자가 확인한다. 늦은 조회와 여러 편집에는 이 범위를 쓸 수 없다.
    pub fn borrow(self: Batch, previous: u64, current: u64, edits: u64) ?[]const Range {
        if (edits != 1 or previous != self.before or current != self.after or self.before >= self.after or self.after - self.before != 1) return null;
        return self.ranges;
    }
};
