//! 업그레이드가 아무 host 도 새 이미지로 바꾸지 못했을 때, **살아 있는 host 를 새 탭의 spawn host 로 재사용할지,
//! 새 host 를 띄울지** — 순수 판정.
//!
//! 설계 의도는 「한 로그인 세션에 host 하나」다(`docs/persistent-session-host.md`). 새 빌드를 설치하면 기존 host 가
//! 같은 PID 로 새 이미지에 exec 교체되므로 host 는 늘 하나로 남는다. 그런데 `host_connect.connectOrLaunchDetailed`
//! 는 교체가 실패하면 「조용히 기존 spawn 경로로 떨어져 새 host 를 띄운다」였고, 그 폴백이 불변식을 깨는 **유일한
//! 경로**였다.
//!
//! 2026-09-30 실측: 9/27 빌드 host 는 매니페스트 ctime 결함으로 교체가 매번 실패했고, 설치할 때마다 새 host 가 하나씩
//! 늘어 넷이 됐다. 이미 생긴 host 는 셸 PTY 를 쥐고 있어 합칠 수 없다(호스트 간 이관 기능이 없다) — 늘지 않게 막는
//! 것이 할 수 있는 전부다.
//!
//! 그래서 교체가 실패해도 **살아 있고 호환되는 host 가 있으면 그 host 를 쓴다.** 새 host 는 새 탭을 받을 수 있는
//! 살아 있는 host 가 하나도 없을 때만 띄운다(첫 실행, 재부팅 뒤, 모든 host 가 다른 wire 이거나 spawn 계약을 모를 때).
//! 그때는 이유를 한 줄 남긴다(`SpawnReason`).
//!
//! 대가: 교체가 실패한 동안에는 새 탭도 옛 빌드 host 에서 돈다 — host 쪽 수정은 교체가 성공해야 들어온다. 같은
//! build 의 host 가 없으므로 다음 앱 실행도 업그레이드 스캔을 다시 돌려 교체를 계속 시도한다.
//!
//! 이 파일은 std 만 쓴다 — PR 필수 check-boundaries 에서 돈다. 스캔 루프가 이 판정을 제자리에서 부르는지는
//! `tests/single_host_policy_wiring_boundary.zig` 가 잰다.

const std = @import("std");

/// owner lease 관측. `owner_lease.Observation` 과 같은 세 값이다 — 이 leaf 가 std 만 쓰도록 호출자가 옮겨 준다.
pub const Lease = enum { held, free, unknown };

/// 매니페스트 한 장에서 읽은 후보. 호출자(`host_connect`)가 채운다.
pub const Observation = struct {
    host_id: u128,
    /// `protocol_major` 와 `screen_codec_version` 이 이 GUI 와 같은가. 다르면 N-1 adapter 가 attach 만 하는 host 라
    /// 새 runtime 을 받을 수 없다.
    same_wire: bool,
    /// 매니페스트 lifecycle 이 `ready` 인가. restoring(교체 도중)·draining(정리 중)은 새 runtime 을 얹지 않는다.
    ready: bool,
    lease: Lease,
    /// 이 GUI 와 같은 build 인가. 보통은 `findCurrentManifestHost` 가 먼저 가져가지만, 그때 일시적으로 못 붙었으면
    /// 여기까지 온다 — 그러면 옛 build host 보다 먼저 고른다.
    current_build: bool,
    /// 매니페스트가 마지막으로 게시된 시각(birth time, ns). 못 읽으면 `null`.
    published_ns: ?i128,
    /// 이번 실행의 업그레이드 스캔이 이 host 에 붙지 못했거나 응답·재연결이 시간 초과로 끝났다(`HostSet`). 다시 붙어
    /// 보면 같은 대기(최악 수십 초)를 **메인 스레드에서 한 번 더** 치르므로 붙어 보지 않고 뺀다.
    unreachable_this_launch: bool = false,
};

/// 이번 실행에서 붙지 못한 host 의 유한 집합. 업그레이드 스캔이 채우고 재사용 판정이 읽는다. 넘치면 더 담지 않는다 —
/// 그 host 는 다시 붙어 볼 뿐이다(느려질 수는 있어도 틀리지는 않는다).
pub const HostSet = struct {
    ids: [max_candidates]u128 = undefined,
    len: usize = 0,

    pub fn add(self: *HostSet, host_id: u128) void {
        if (self.contains(host_id) or self.len == self.ids.len) return;
        self.ids[self.len] = host_id;
        self.len += 1;
    }

    pub fn contains(self: *const HostSet, host_id: u128) bool {
        return std.mem.indexOfScalar(u128, self.ids[0..self.len], host_id) != null;
    }
};

/// 새 host 를 띄우는 이유. **뒤에 올수록 재사용에 가까웠다** — 여러 후보가 서로 다른 이유로 빠지면 가장 가까웠던
/// 이유를 남긴다(「host 가 하나도 없다」보다 「있었는데 못 붙었다」가 진단에 쓸모 있다).
pub const SpawnReason = enum {
    /// 매니페스트가 하나도 없다(첫 실행).
    no_host_manifest,
    /// 매니페스트는 있지만 owner lease 가 잡힌 host 가 없다(재부팅·crash 뒤 남은 매니페스트, 또는 우리가 lease 를 못 봄).
    no_live_host,
    /// 살아 있는 host 가 다른 wire 다(N-1 host 는 attach 만 한다).
    incompatible_wire,
    /// 살아 있는 host 가 ready 가 아니다(교체 도중·정리 중).
    host_not_ready,
    /// 후보에 붙지 못했다.
    connect_failed,
    /// 붙었지만 GUI 의 spawn 계약(`runtime.spawn_full` 의 config·알림 capability)을 모르는 옛 host 다. 여기에 새
    /// 탭을 걸면 `UnsupportedSpawnContract` 로 in-process 로 떨어진다.
    spawn_contract_missing,
};

pub const Decision = union(enum) {
    reuse: u128,
    spawn: SpawnReason,
    /// 우리 쪽 메모리 부족 — host 에 대한 증거가 아니다. 호출자가 그대로 실패로 올린다(형제 스캔과 같은 규율).
    out_of_memory,
};

/// 후보에 붙어 본 결과. `reusable` 이면 호출자가 그 연결을 이미 쥐고 있다.
pub const Probe = enum { reusable, connect_failed, spawn_contract_missing, out_of_memory };

/// 한 번의 판정이 붙드는 후보 수. 넘치는 후보는 이번 판정에서 빠진다(업그레이드 스캔과 같은 상한).
pub const max_candidates: usize = 64;

/// 매니페스트만으로 이 후보를 빼야 하는 이유. `null` 이면 붙어 볼 대상이다.
pub fn exclusionFor(observation: Observation) ?SpawnReason {
    // 살아 있다는 **긍정적 증거**(`held`)가 있을 때만 쓴다. `unknown` 에 새 탭을 걸면 우리 쪽 사정으로 죽은 host 에
    // 붙으려 하는 것이고, 그 오판 비용이 host 하나를 더 띄우는 것보다 크다(`findCurrentManifestHost` 와 같은 규율).
    if (observation.lease != .held) return .no_live_host;
    if (observation.unreachable_this_launch) return .connect_failed;
    if (!observation.same_wire) return .incompatible_wire;
    if (!observation.ready) return .host_not_ready;
    return null;
}

/// 붙은 host 가 GUI 의 새 탭을 받을 수 있는가. `RemoteTermBackend.spawn` 은 언제나 알림 bootstrap 과 초기 config 를
/// 싣고 `runtime.spawn_full` 을 부르므로, 두 capability 를 모두 광고해야 한다(`remote_runtime.spawnWithConnection`).
pub fn spawnContractSatisfied(runtime_core_command: bool, notification_delivery: bool) bool {
    return runtime_core_command and notification_delivery;
}

/// 재사용한 host 가 이 GUI 와 **다른** build 인가 — UI 가 「새 탭도 옛 이미지에서 돈다」 를 알릴지 가른다. 둘 다 알 때만
/// 같다고 말한다. 어느 쪽이든 모르면 다르다고 본다(알리지 않고 옛 이미지를 쓰는 쪽이 더 나쁘다).
pub fn reusedPreviousBuild(reused_build_id: ?[]const u8, current_build_id: ?[]const u8) bool {
    const reused = reused_build_id orelse return true;
    const current = current_build_id orelse return true;
    return !std.mem.eql(u8, reused, current);
}

fn stronger(a: SpawnReason, b: SpawnReason) SpawnReason {
    return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
}

/// 같은 build 가 먼저, 그다음 마지막 게시가 **최신인** host 부터(방금 교체됐거나 새로 뜬 host 가 가장 새 이미지다).
/// 시각이 같으면 host_id 로 결정적으로. 시각을 못 읽으면 맨 뒤.
fn preferredFirst(_: void, a: Observation, b: Observation) bool {
    if (a.current_build != b.current_build) return a.current_build;
    const a_ns = a.published_ns orelse std.math.minInt(i128);
    const b_ns = b.published_ns orelse std.math.minInt(i128);
    if (a_ns != b_ns) return a_ns > b_ns;
    return a.host_id < b.host_id;
}

/// 재사용할 host 를 고르거나, 새 host 를 띄울 이유를 돌려준다. `prober.probe(host_id)` 는 그 host 에 붙어 보고
/// `reusable` 이면 연결을 쥔 채 돌려준다 — 판정은 **첫 `reusable` 에서 멈추므로** 연결은 많아야 하나만 남는다.
pub fn choose(observations: []const Observation, prober: anytype) Decision {
    var eligible: [max_candidates]Observation = undefined;
    var eligible_count: usize = 0;
    var reason: SpawnReason = .no_host_manifest;
    for (observations) |observation| {
        if (exclusionFor(observation)) |excluded| {
            reason = stronger(reason, excluded);
            continue;
        }
        if (eligible_count == eligible.len) continue;
        eligible[eligible_count] = observation;
        eligible_count += 1;
    }
    std.mem.sort(Observation, eligible[0..eligible_count], {}, preferredFirst);
    for (eligible[0..eligible_count]) |candidate| {
        switch (prober.probe(candidate.host_id)) {
            .reusable => return .{ .reuse = candidate.host_id },
            .connect_failed => reason = stronger(reason, .connect_failed),
            .spawn_contract_missing => reason = stronger(reason, .spawn_contract_missing),
            .out_of_memory => return .out_of_memory,
        }
    }
    return .{ .spawn = reason };
}

const testing = std.testing;

const FakeResult = struct { host_id: u128, probe: Probe };

const FakeProber = struct {
    results: []const FakeResult,
    probed: [8]u128 = undefined,
    probed_count: usize = 0,

    pub fn probe(self: *FakeProber, host_id: u128) Probe {
        self.probed[self.probed_count] = host_id;
        self.probed_count += 1;
        for (self.results) |result| if (result.host_id == host_id) return result.probe;
        return .connect_failed;
    }
};

fn live(host_id: u128, published_ns: ?i128) Observation {
    return .{
        .host_id = host_id,
        .same_wire = true,
        .ready = true,
        .lease = .held,
        .current_build = false,
        .published_ns = published_ns,
    };
}

test "세션 호스트 하나 — 살아 있고 호환되는 host 가 있으면 새 host 를 띄우지 않는다" {
    const Case = struct {
        name: []const u8,
        observations: []const Observation,
        probes: []const FakeResult,
        expected: Decision,
    };
    const dead = Observation{ .host_id = 0xD, .same_wire = true, .ready = true, .lease = .free, .current_build = false, .published_ns = 9 };
    const unseen = Observation{ .host_id = 0xE, .same_wire = true, .ready = true, .lease = .unknown, .current_build = false, .published_ns = 9 };
    const n_minus_1 = Observation{ .host_id = 0xF, .same_wire = false, .ready = true, .lease = .held, .current_build = false, .published_ns = 9 };
    const restoring = Observation{ .host_id = 0xA, .same_wire = true, .ready = false, .lease = .held, .current_build = false, .published_ns = 9 };
    const cases = [_]Case{
        // 예전 규칙은 이 행에서 새 host 를 띄웠다 — 업그레이드가 실패한 옛 build host 가 멀쩡히 살아 있는데도.
        .{ .name = "업그레이드 실패한 옛 host 하나", .observations = &.{live(1, 10)}, .probes = &.{.{ .host_id = 1, .probe = .reusable }}, .expected = .{ .reuse = 1 } },
        .{ .name = "첫 실행", .observations = &.{}, .probes = &.{}, .expected = .{ .spawn = .no_host_manifest } },
        .{ .name = "재부팅 뒤 남은 매니페스트", .observations = &.{dead}, .probes = &.{}, .expected = .{ .spawn = .no_live_host } },
        .{ .name = "lease 를 못 봄", .observations = &.{unseen}, .probes = &.{}, .expected = .{ .spawn = .no_live_host } },
        .{ .name = "N-1 host 만", .observations = &.{ dead, n_minus_1 }, .probes = &.{}, .expected = .{ .spawn = .incompatible_wire } },
        .{ .name = "교체 도중인 host 만", .observations = &.{ n_minus_1, restoring }, .probes = &.{}, .expected = .{ .spawn = .host_not_ready } },
        .{ .name = "붙지 못함", .observations = &.{ restoring, live(1, 10) }, .probes = &.{}, .expected = .{ .spawn = .connect_failed } },
        .{ .name = "spawn 계약을 모르는 옛 host", .observations = &.{ live(1, 10), live(2, 20) }, .probes = &.{ .{ .host_id = 1, .probe = .connect_failed }, .{ .host_id = 2, .probe = .spawn_contract_missing } }, .expected = .{ .spawn = .spawn_contract_missing } },
        .{ .name = "죽은 host 와 산 host", .observations = &.{ dead, live(1, 10), n_minus_1 }, .probes = &.{.{ .host_id = 1, .probe = .reusable }}, .expected = .{ .reuse = 1 } },
        .{ .name = "첫 후보가 계약을 모르면 다음", .observations = &.{ live(1, 10), live(2, 20) }, .probes = &.{ .{ .host_id = 2, .probe = .spawn_contract_missing }, .{ .host_id = 1, .probe = .reusable } }, .expected = .{ .reuse = 1 } },
        .{ .name = "메모리 부족은 그대로 올린다", .observations = &.{live(1, 10)}, .probes = &.{.{ .host_id = 1, .probe = .out_of_memory }}, .expected = .out_of_memory },
    };
    for (cases) |case| {
        var prober: FakeProber = .{ .results = case.probes };
        const got = choose(case.observations, &prober);
        testing.expectEqualDeep(case.expected, got) catch |err| {
            std.debug.print("행 «{s}»\n", .{case.name});
            return err;
        };
    }
}

test "세션 호스트 하나 — 여럿이면 같은 build, 그다음 최신 게시 host 부터 붙고 첫 성공에서 멈춘다" {
    var current = live(0x30, 5);
    current.current_build = true;
    const observations = [_]Observation{ live(0x10, 100), live(0x20, 300), current, live(0x40, null), live(0x05, 300) };
    var prober: FakeProber = .{ .results = &.{} };
    try testing.expectEqualDeep(Decision{ .spawn = .connect_failed }, choose(&observations, &prober));
    try testing.expectEqualSlices(u128, &.{ 0x30, 0x05, 0x20, 0x10, 0x40 }, prober.probed[0..prober.probed_count]);

    // 판정은 입력 순서(readdir)와 무관하다.
    const reversed = [_]Observation{ live(0x05, 300), live(0x40, null), current, live(0x20, 300), live(0x10, 100) };
    var again: FakeProber = .{ .results = &.{} };
    _ = choose(&reversed, &again);
    try testing.expectEqualSlices(u128, prober.probed[0..prober.probed_count], again.probed[0..again.probed_count]);

    // 첫 `reusable` 에서 멈춘다 — 연결은 하나만 남는다.
    var stops: FakeProber = .{ .results = &.{.{ .host_id = 0x05, .probe = .reusable }} };
    try testing.expectEqualDeep(Decision{ .reuse = 0x05 }, choose(&observations, &stops));
    try testing.expectEqualSlices(u128, &.{ 0x30, 0x05 }, stops.probed[0..stops.probed_count]);
}

test "세션 호스트 하나 — 매니페스트 판정과 spawn 계약" {
    try testing.expectEqual(@as(?SpawnReason, null), exclusionFor(live(1, 1)));
    var o = live(1, 1);
    o.lease = .free;
    try testing.expectEqual(@as(?SpawnReason, .no_live_host), exclusionFor(o));
    o = live(1, 1);
    o.lease = .unknown;
    try testing.expectEqual(@as(?SpawnReason, .no_live_host), exclusionFor(o));
    o = live(1, 1);
    o.same_wire = false;
    try testing.expectEqual(@as(?SpawnReason, .incompatible_wire), exclusionFor(o));
    o = live(1, 1);
    o.ready = false;
    try testing.expectEqual(@as(?SpawnReason, .host_not_ready), exclusionFor(o));
    // 이번 실행의 스캔이 붙지 못한 host 는 다시 붙어 보지 않는다(같은 대기를 메인 스레드에서 두 번 치르지 않게).
    o = live(1, 1);
    o.unreachable_this_launch = true;
    try testing.expectEqual(@as(?SpawnReason, .connect_failed), exclusionFor(o));
    var never: FakeProber = .{ .results = &.{.{ .host_id = 1, .probe = .reusable }} };
    try testing.expectEqualDeep(Decision{ .spawn = .connect_failed }, choose(&.{o}, &never));
    try testing.expectEqual(@as(usize, 0), never.probed_count);

    var set: HostSet = .{};
    try testing.expect(!set.contains(7));
    set.add(7);
    set.add(7);
    try testing.expect(set.contains(7));
    try testing.expectEqual(@as(usize, 1), set.len);
    for (0..max_candidates + 4) |i| set.add(@as(u128, i) + 100);
    try testing.expectEqual(max_candidates, set.len);

    try testing.expect(spawnContractSatisfied(true, true));
    try testing.expect(!spawnContractSatisfied(false, true));
    try testing.expect(!spawnContractSatisfied(true, false));
    try testing.expect(!spawnContractSatisfied(false, false));

    // 알림 판정: 둘 다 알고 같을 때만 「같은 build」.
    try testing.expect(!reusedPreviousBuild("sha256:aa", "sha256:aa"));
    try testing.expect(reusedPreviousBuild("sha256:aa", "sha256:bb"));
    try testing.expect(reusedPreviousBuild(null, "sha256:aa"));
    try testing.expect(reusedPreviousBuild("sha256:aa", null));
    try testing.expect(reusedPreviousBuild(null, null));
}
