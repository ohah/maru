//! AppKit wake source 의 감시 집합이 pump 집합을 벗어나지 않는지 지킨다.
//!
//! **왜 있는가.** `fea286c1 perf(session-host): wake AppKit on remote output` 이 원격 출력 지연을
//! 줄이려고 host 소켓에 `DispatchSourceRead` 를 붙였다. 그 소스는 **레벨 트리거**이고 Apple 이 계약을
//! 명시한다 — *"schedules its event handler repeatedly while there is still data to read"*. 즉 핸들러가
//! **읽어갈 것**을 전제한다.
//!
//! 그런데 이 코드의 핸들러는 **의도적으로 fd 를 읽지 않는다**. 소켓 소유는 Zig `Client` 이고 Swift 가
//! 중간에서 읽으면 프레이밍이 깨지기 때문이다(persistent-session-host.md 의 "빌려서 감시할 뿐 읽거나
//! 닫지 않는다"). 그 설계가 성립하려면 **누군가는 읽어야** 한다.
//!
//! 그 "누군가" 는 `maintenanceEventTick` 이 도는 `self.runtimes` 다. 그런데 `wakeSources` 는
//! `host_pool` 의 **모든 adapter** 를 감시 대상으로 냈다. runtime 이 붙지 않은 연결은 아무도 읽지
//! 않는데 감시되어, 그 fd 하나가 메인 큐를 영원히 깨웠다:
//!
//!     소켓에 데이터가 남는다 → 레벨 트리거가 깨운다 → tick 한 바퀴(pump·seal·poll)
//!       → 그 fd 를 읽는 runtime 이 없다 → 데이터 그대로 → 즉시 다시 깨운다 → …
//!
//! 실측(유휴 CPU): 회귀 전 10% → 회귀 후 **84%** → 이 가드 복원 후 **4%**. 노트북이면 배터리·발열로
//! 직결되는 종류다.
//!
//! **왜 기존 게이트가 못 잡았나.** 함께 들어온 `client_idle_pump_validator` 는 별도 client 프로세스를
//! `proc_pid_rusage` 로 재는 구조라 **실제 AppKit `DispatchSource` 경로를 타지 않는다**. 그 게이트는
//! 회귀 내내 초록이었다. 그래서 여기서는 CPU 수치가 아니라 **두 집합이 같아야 한다는 계약** 자체를
//! 소스에서 고정한다 — 수치 게이트보다 약하지만, 이 회귀가 다시 들어오는 **정확히 그 자리**를 막는다.
//!
//! ⚠️ 이 파일이 고정하지 못하는 것: 실제 앱 프로세스의 유휴 CPU. 그 판정자는 실제 AppKit 앱을 띄워
//! 재야 하고 CI 러너 부하에 민감하다. 별도 작업으로 남긴다.

const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// `source` 안에서 `start` 로 시작하는 함수 본문(다음 `\n    pub fn ` 또는 `\n    fn ` 까지).
fn functionBody(source: []const u8, start: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const rest = source[from + start.len ..];
    const next_pub = std.mem.indexOf(u8, rest, "\n    pub fn ");
    const next_priv = std.mem.indexOf(u8, rest, "\n    fn ");
    const end = if (next_pub) |p| (if (next_priv) |v| @min(p, v) else p) else next_priv;
    return rest[0 .. end orelse rest.len];
}

test "wake source 는 읽을 주체가 있는 연결만 감시한다" {
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 1024 * 1024);
    defer allocator.free(backend);

    // ⑴ **감시 쪽**: `wakeSources` 는 adapter 를 훑되 runtime 유무를 반드시 확인한다. 이 한 줄이
    //    사라지면 읽을 주체 없는 fd 가 다시 감시 대상이 되고 회귀가 돌아온다.
    const wake = functionBody(backend, "pub fn wakeSources(") orelse
        return error.WakeSourcesNotFound;
    try std.testing.expectEqual(@as(usize, 1), count(wake, "hasRuntimeForHost"));
    try std.testing.expect(std.mem.indexOf(u8, wake, "adapter.wakeSource()") != null);

    // ⑵ **그 판정의 근거**: 헬퍼가 실제로 `self.runtimes` 를 본다. 이름만 같고 다른 집합을 보면
    //    ⑴ 은 통과하는데 계약은 깨진다.
    const helper = functionBody(backend, "fn hasRuntimeForHost(") orelse
        return error.HelperNotFound;
    try std.testing.expect(std.mem.indexOf(u8, helper, "self.runtimes.iterator()") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper, "host_id") != null);

    // ⑶ **읽기 쪽**: pump 가 도는 집합도 `self.runtimes` 다. 두 축이 같은 집합을 봐야 한다는 것이
    //    이 파일이 지키는 계약의 전부다 — 한쪽이 넓어지는 순간 아무도 안 읽는 fd 가 생긴다.
    const tick = functionBody(backend, "pub fn maintenanceEventTick(") orelse
        return error.MaintenanceTickNotFound;
    try std.testing.expect(std.mem.indexOf(u8, tick, "self.runtimes.iterator()") != null);
}

test "대조군: 검사가 실제로 그 자리를 보고 있다" {
    // 위 테스트가 공허하지 않은지 본다. 함수 본문 추출이 조용히 빈 슬라이스를 주면 `indexOf` 가 전부
    // null 이 되어 단언이 통과해 버린다(실제로 초기 구현에서 그렇게 됐다).
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig", 1024 * 1024);
    defer allocator.free(backend);

    const wake = functionBody(backend, "pub fn wakeSources(") orelse return error.WakeSourcesNotFound;
    const helper = functionBody(backend, "fn hasRuntimeForHost(") orelse return error.HelperNotFound;
    const tick = functionBody(backend, "pub fn maintenanceEventTick(") orelse return error.MaintenanceTickNotFound;

    // 본문이 비어 있지 않고, 서로 다른 자리를 가리킨다.
    try std.testing.expect(wake.len > 100);
    try std.testing.expect(helper.len > 40);
    try std.testing.expect(tick.len > 100);
    try std.testing.expect(!std.mem.eql(u8, wake, helper));
    try std.testing.expect(!std.mem.eql(u8, wake, tick));

    // 그리고 없는 문자열은 실제로 못 찾는다(추출이 파일 전체를 주고 있지 않다는 증거).
    try std.testing.expect(std.mem.indexOf(u8, helper, "adapter.wakeSource()") == null);
}

test "Swift wake 핸들러는 fd 를 읽지 않는다 — 그래서 감시 집합 제한이 유일한 방어다" {
    const allocator = std.testing.allocator;
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift", 2048 * 1024);
    defer allocator.free(swift);

    // 소스를 만드는 자리와 그 핸들러가 `tickAppSession` 만 부른다는 사실을 고정한다. 핸들러가 직접
    // 읽도록 바뀌면(= Apple 계약을 정공법으로 지키면) 이 파일의 전제가 달라지므로 함께 갱신해야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(swift, "DispatchSource.makeReadSource(fileDescriptor: observedFd"));
    // fd 는 빌린 것을 dup 해 소스가 소유한다 — 원본을 직접 감시하면 ClientSlot close 뒤 번호 재사용에
    // 걸린다(그 주석이 코드에 있다).
    try std.testing.expectEqual(@as(usize, 1), count(swift, "F_DUPFD_CLOEXEC"));
}
