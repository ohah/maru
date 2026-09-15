//! host 가 내보낸 이미지가 앱에서 **어느 칸에서 사라지는지** 세는 프로세스 전역 계수기.
//!
//! 「이미지가 안 뜨기도 한다」는 관측에 답하려는데, host 의 거절 계수기(`kitty` 저장소의 상한·evict)는
//! 그 아래 경로를 못 본다. blob 이 소켓을 지나 앱에 닿은 뒤에도 사라질 자리가 셋 있고 전부 **아무 말
//! 없이** `return`/`continue` 였다:
//!
//!   - 0 번 청크 없이 온 청크 → 스킵 (`screen_assembler.handleImageBlob`)
//!   - 청크 순서·개수가 어긋남 → 폐기 (같은 곳)
//!   - placement 는 왔는데 그 `image_id` 의 blob 이 없음 → 안 그림 (`metal_frame.planImageUploads`)
//!
//! 그래서 칸마다 센다. host 는 `maru-metrics` 의 `imgs=` 로 내보낸 **개수**를 남기고, 앱은 5 초마다
//! 이 계수를 델타로 한 줄 남긴다 — 단 **버려진 것이 하나라도 있을 때만**. 정상 흐름은 침묵이다(같은 규칙:
//! `noteIdleTurn`, `maru-metrics` 의 조용한 구간 억제). 재현을 기다릴 필요 없이, 다음에 안 뜨는 순간
//! 로그가 「어느 칸에서」를 답한다.
//!
//! 레이어: **레이어 무관 중립 leaf**(`width.zig`·`redact.zig` 와 동격). 조립기(L2 session)와 렌더러(L1
//! renderer)가 둘 다 여기에 쓰는데 L1 은 L2 를 import 하지 못하므로 어느 층에도 둘 수 없다. 원자 계수만
//! 있고 식별자·경로·페이로드는 남기지 않는다.
const std = @import("std");

pub const Counters = struct {
    /// 조립기가 완성해 image_store 에 넣은 이미지 수(단일 청크 + 마지막 청크 완성).
    received_complete: std.atomic.Value(u64) = .init(0),
    /// 0 번 청크 없이 온 청크 — 이전 것이 폐기됐거나 순서가 뒤집힌 것.
    dropped_no_head: std.atomic.Value(u64) = .init(0),
    /// 청크 순서나 개수가 pending 과 어긋나 통째로 버린 이미지.
    dropped_order: std.atomic.Value(u64) = .init(0),
    /// 메모리 부족으로 못 받은 이미지.
    dropped_oom: std.atomic.Value(u64) = .init(0),
    /// placement 가 가리키는 image_id 의 blob 이 없어 안 그린 횟수(프레임마다 센다).
    placement_without_blob: std.atomic.Value(u64) = .init(0),
    /// GPU 에 실제로 올린 이미지 수.
    uploaded: std.atomic.Value(u64) = .init(0),
    /// 같은 generation 이라 업로드를 건너뛴 횟수(정상 캐시 적중).
    upload_skipped_same_generation: std.atomic.Value(u64) = .init(0),
};

var counters: Counters = .{};

pub fn recordReceivedComplete() void {
    _ = counters.received_complete.fetchAdd(1, .monotonic);
}
pub fn recordDroppedNoHead() void {
    _ = counters.dropped_no_head.fetchAdd(1, .monotonic);
}
pub fn recordDroppedOrder() void {
    _ = counters.dropped_order.fetchAdd(1, .monotonic);
}
pub fn recordDroppedOom() void {
    _ = counters.dropped_oom.fetchAdd(1, .monotonic);
}
pub fn recordPlacementWithoutBlob() void {
    _ = counters.placement_without_blob.fetchAdd(1, .monotonic);
}
pub fn recordUploaded() void {
    _ = counters.uploaded.fetchAdd(1, .monotonic);
}
pub fn recordUploadSkippedSameGeneration() void {
    _ = counters.upload_skipped_same_generation.fetchAdd(1, .monotonic);
}

pub const Snapshot = struct {
    received_complete: u64,
    dropped_no_head: u64,
    dropped_order: u64,
    dropped_oom: u64,
    placement_without_blob: u64,
    uploaded: u64,
    upload_skipped_same_generation: u64,

    pub fn delta(now: Snapshot, prev: Snapshot) Snapshot {
        return .{
            .received_complete = now.received_complete -% prev.received_complete,
            .dropped_no_head = now.dropped_no_head -% prev.dropped_no_head,
            .dropped_order = now.dropped_order -% prev.dropped_order,
            .dropped_oom = now.dropped_oom -% prev.dropped_oom,
            .placement_without_blob = now.placement_without_blob -% prev.placement_without_blob,
            .uploaded = now.uploaded -% prev.uploaded,
            .upload_skipped_same_generation = now.upload_skipped_same_generation -% prev.upload_skipped_same_generation,
        };
    }

    /// 이 구간에 **사라진 것이 있는가.** 정상 흐름(받고·올리고·캐시 적중)은 조용해야 하므로 이것만 본다.
    pub fn anyLoss(d: Snapshot) bool {
        return d.dropped_no_head != 0 or d.dropped_order != 0 or d.dropped_oom != 0 or
            d.placement_without_blob != 0;
    }
};

pub fn snapshot() Snapshot {
    return .{
        .received_complete = counters.received_complete.load(.monotonic),
        .dropped_no_head = counters.dropped_no_head.load(.monotonic),
        .dropped_order = counters.dropped_order.load(.monotonic),
        .dropped_oom = counters.dropped_oom.load(.monotonic),
        .placement_without_blob = counters.placement_without_blob.load(.monotonic),
        .uploaded = counters.uploaded.load(.monotonic),
        .upload_skipped_same_generation = counters.upload_skipped_same_generation.load(.monotonic),
    };
}

/// 한 줄로 찍는다. 호출자가 `anyLoss` 로 걸러 정상 구간에는 부르지 않는다.
pub fn formatLine(buf: []u8, d: Snapshot) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "image reconciliation: complete={d} drop_no_head={d} drop_order={d} drop_oom={d} placement_without_blob={d} uploaded={d} skip_same_gen={d}",
        .{ d.received_complete, d.dropped_no_head, d.dropped_order, d.dropped_oom, d.placement_without_blob, d.uploaded, d.upload_skipped_same_generation },
    );
}

/// 가장 긴 줄 — 모든 칸이 u64 최대값일 때. 호출자의 버퍼가 이보다 커야 한다. **실측값**이다 — 처음에 216 으로
/// 어림했다가 판정자가 256 을 보여 줬다(접두 89 B + u64 최대 20 자리 × 7 + 구분자).
pub const line_worst_case_bytes: usize = 256;

test "정상 흐름(받고·올리고·캐시 적중)은 loss 가 아니다 — 부정 대조" {
    const before = snapshot();
    recordReceivedComplete();
    recordUploaded();
    recordUploadSkippedSameGeneration();
    const d = snapshot().delta(before);
    try std.testing.expectEqual(@as(u64, 1), d.received_complete);
    try std.testing.expectEqual(@as(u64, 1), d.uploaded);
    try std.testing.expect(!d.anyLoss());
}

test "사라짐 네 칸은 각각 loss 다 — 하나라도 빠지면 그 칸은 영영 조용하다" {
    inline for (.{ recordDroppedNoHead, recordDroppedOrder, recordDroppedOom, recordPlacementWithoutBlob }) |record| {
        const before = snapshot();
        record();
        try std.testing.expect(snapshot().delta(before).anyLoss());
    }
}

test "가장 긴 줄의 길이는 실측값과 같다" {
    var buf: [512]u8 = undefined;
    const max: Snapshot = .{
        .received_complete = std.math.maxInt(u64),
        .dropped_no_head = std.math.maxInt(u64),
        .dropped_order = std.math.maxInt(u64),
        .dropped_oom = std.math.maxInt(u64),
        .placement_without_blob = std.math.maxInt(u64),
        .uploaded = std.math.maxInt(u64),
        .upload_skipped_same_generation = std.math.maxInt(u64),
    };
    const line = try formatLine(&buf, max);
    try std.testing.expectEqual(line_worst_case_bytes, line.len);
}
