//! std 의 **스택 트레이스 포획 경로**가 쓰는 할당자.
//!
//! std 기본값은 `page_allocator` 위의 **전역 ArenaAllocator** 다(`std/debug.zig` `getDebugInfoAllocator`).
//! 아레나의 `free` 는 **마지막 할당일 때만** 끝 지점을 되감는다 — 그 밖에는 전부 무시한다. 그런데
//! 그 할당자를 쓰는 DWARF 언와인더는 프레임마다 `Unwind.VirtualMachine.Column` 버퍼를 잡고 놓고,
//! host 는 **스레드 여럿이 같은 전역 아레나를 동시에** 쓴다(std 의 그 아레나는 스레드 안전하지도 않다).
//! 그래서 해제는 딱 맞는 LIFO 가 아니고, 되감기는 거의 일어나지 않는다 — 포획 한 번마다 한 벌씩
//! 쌓이고 아레나 노드는 ×1.5 로 커지며 하나도 안 풀린다.
//!
//! 이게 왜 제품 문제인가: Debug 빌드에서 `std.process.Init.gpa` 는 `DebugAllocator` 이고
//! (`std/start.zig` `use_debug_allocator`), 그것은 **할당·해제마다** 6 프레임을 포획한다
//! (`stack_trace_frames`). 초당 수천 번 할당하는 세션 host 에서는 그래서 메모리가 단조 증가한다.
//!
//! 실측(같은 픽스처·같은 `made_bps` 4.47 MB/s·같은 `store`·`evict=0`):
//!   - Debug      : `rss` 525 MB 이고 5 초마다 +15 MB, `VM_ALLOCATE` 685 MB/50 영역,
//!                  영역 크기가 496K→752K→1136K→…→97.2M 의 ×1.5 사다리로 **전부 상주**
//!   - ReleaseFast: `rss` 7.5 MB 평평, `VM_ALLOCATE` 20K/2 영역
//! `mmap` 인터포저로 뜬 스택이 원인을 그대로 가리켰다:
//!   `AllocationCap.alloc → DebugAllocator → captureCurrentStackTrace → SelfInfo.MachO.unwindFrame
//!    → SelfUnwinder.computeRules → VirtualMachine.Column ArrayList → ArenaAllocator.alloc → mmap`
//!
//! std 는 이 자리를 **루트에서 덮도록 열어 뒀다** — `root.debug.getDebugInfoAllocator` 가 있으면
//! 그것을 쓴다. `src/main.zig` 가 그 자리를 이 모듈로 잇는다.
//!
//! 되돌려받는 할당자를 줘도 되는 이유: 이 할당자를 쓰는 자리들은 이미 `deinit`/`free` 를 짝맞춰
//! 부른다(`SelfUnwinder.deinit`, `writeCurrentStackTrace` 의 `text_arena` 는 `defer deinit`).
//! 아레나는 **편의**였지 계약이 아니었다. 게다가 전역 아레나는 스레드 안전하지 않은데
//! `smp_allocator` 는 안전하다 — host 는 여러 스레드에서 동시에 할당한다.
const std = @import("std");

/// 트레이스 포획이 쓸 할당자. **free 를 실제로 되돌려받아야 한다**(그것이 이 모듈의 전부다).
pub fn allocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

/// 두 벌을 잡고 **먼저 잡은 것부터 놓으며**, 서로 다른 주소가 몇 개 나오는지 센다.
///
/// 순서를 어긋나게 놓는 것이 핵심이다. 아레나의 `free` 는 **마지막 할당일 때만** 끝 지점을 되감으므로,
/// 딱 맞는 LIFO 만 보면 아레나도 자리를 재사용해 판정자가 공허해진다(처음에 그렇게 썼다가 재 보고
/// 알았다 — 단순 왕복에서는 아레나도 distinct=1 이다). 실제 host 는 스레드 여럿이 같은 전역 아레나를
/// 동시에 쓰므로 해제는 결코 딱 맞는 LIFO 가 아니다. 그 자리에서 아레나는 한 바이트도 안 돌려준다.
///
/// 실측(256 회차 × 512 B): 아레나 distinct=256·capacity 182,778 B, 이 모듈 distinct=2.
fn distinctAddresses(a: std.mem.Allocator, rounds: usize, size: usize) !usize {
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (0..rounds) |_| {
        const first = try a.alloc(u8, size);
        const second = try a.alloc(u8, size);
        try seen.put(std.testing.allocator, @intFromPtr(first.ptr), {});
        a.free(first);
        a.free(second);
    }
    return seen.count();
}

test "트레이스 할당자는 어긋난 순서로 놓아도 되돌려받는다 — 아레나는 못 한다" {
    const rounds = 256;
    const size = 512; // 언와인더의 `VirtualMachine.Column` 배열 규모

    // **부정 대조**: std 기본값이 쓰던 모양(page_allocator 위 아레나). 회차마다 새 주소가 나오고
    // 쥔 양도 같이 큰다 — 이것이 우리가 실제로 겪은 누수의 행동이다.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const arena_distinct = try distinctAddresses(arena.allocator(), rounds, size);
    try std.testing.expectEqual(@as(usize, rounds), arena_distinct);
    // 「쥔 양이 는다」까지 본다. 주소만 세면 재사용 없는 다른 할당자도 통과시킬 수 있다.
    try std.testing.expect(arena.queryCapacity() > rounds * size);

    // 제품: 놓은 자리를 다시 준다. 「조금 적다」가 아니라 **몇 자리로 수렴한다**를 요구한다.
    const ours = try distinctAddresses(allocator(), rounds, size);
    try std.testing.expect(ours <= 8);
}

test "트레이스 할당자는 언와인더가 키우는 버퍼도 되돌려받는다 — 아레나는 못 한다" {
    // 언와인더 하나는 `cfi_vm` 과 `expr_vm` **두 벌**을 함께 키운다. 한 벌만 키웠다 놓으면 그것은
    // 딱 맞는 LIFO 라 아레나도 되감아 판정자가 공허해진다(돌연변이로 확인했다 — 아레나로 바꿔도
    // 살아남았다). 두 벌을 번갈아 키우고 **잡은 순서대로** 놓아야 실제 자리를 본다.
    const rounds = 64;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, rounds), try growTwoLists(arena.allocator(), rounds));
    try std.testing.expect(try growTwoLists(allocator(), rounds) <= 8);
}

fn growTwoLists(a: std.mem.Allocator, rounds: usize) !usize {
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (0..rounds) |_| {
        var cfi: std.ArrayList(u64) = .empty;
        var expr: std.ArrayList(u64) = .empty;
        try cfi.ensureTotalCapacityPrecise(a, 8);
        try expr.ensureTotalCapacityPrecise(a, 8);
        try cfi.ensureTotalCapacityPrecise(a, 64);
        try expr.ensureTotalCapacityPrecise(a, 64);
        try cfi.ensureTotalCapacityPrecise(a, 512);
        try seen.put(std.testing.allocator, @intFromPtr(cfi.items.ptr), {});
        cfi.deinit(a);
        expr.deinit(a);
    }
    return seen.count();
}
