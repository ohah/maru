//! 다이제스트 자리별 진단이 **사람이 기다릴 수 있는 주기**로 나오는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 앱이 BLAKE3 로 CPU 를 태우는 것은 총량 줄(`observation cost`)이 보여 줬다 — 이벤트 하나당
//! 다이제스트 **49 개**, 300 틱에 **12.3 MB** 해싱. 그런데 **어느 자리**가 그러는지는 못 물어봤다.
//! 답을 줄 계측(`digest site: name=… calls=… bytes=…`)이 이미 있었는데도 그랬다.
//!
//! 그 줄이 **로그에 한 번도 나오지 않았다.** 게이트가 이랬다.
//!
//! ```zig
//! const digest_site_interval_ticks: u32 = 3600;   // 이름은 «틱»
//! diag_site_tick +%= 1;                            // 그런데 세는 건 «호출»
//! if (diag_site_tick % digest_site_interval_ticks != 0) return;
//! ```
//!
//! `logDigestSiteDiag` 는 `logObservationEventDiag` 의 게이트(300 틱 ≈ 5 초)를 **통과한 뒤** 불린다.
//! 그래서 한 번 증가가 300 틱이고, 실효 주기는 `3600 × 300 = 1,080,000` 틱 ≈ **5 시간**이었다.
//! 바로 위 주석은 「내역은 **1 분**마다면 충분하다」라고 적고 있었다 — **300 배 어긋났다.**
//!
//! 앱은 하루에도 여러 번 재시작하고 카운터는 프로세스마다 0 부터라, 3600 에 도달한 적이 없다.
//!
//! ## 이 판정자가 재는 것
//!
//! 상수 **값**이 아니라 **실효 주기**(`interval × 바깥 게이트`)를 잰다. 리터럴을 잠그면 나중에
//! 바깥 게이트가 바뀔 때 이 판정자만 초록인 채로 주기가 다시 늘어난다 — 오늘 하루에 다섯 번 겪은
//! 모양이다(`judge-asserts-intent-not-spelling`).

const std = @import("std");

const source_path = "src/platform/macos/app_session.zig";
const max_source_bytes = 16 * 1024 * 1024;

/// 진단은 **한 틱 ≈ 16 ms** 로 돈다. 사람이 증상을 재현하고 로그를 확인하는 한 세션 안에 최소 한 번은
/// 나와야 한다 — 2 분을 상한으로 둔다(주석이 말한 의도는 1 분).
const max_effective_ticks: u64 = 7_500;

fn constValue(src: []const u8, name: []const u8) !u64 {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "{s}: u32 = ", .{name});
    const at = std.mem.indexOf(u8, src, needle) orelse return error.ConstantMissing;
    const i = at + needle.len;
    var end = i;
    while (end < src.len and src[end] >= '0' and src[end] <= '9') end += 1;
    if (end == i) return error.ConstantMissing;
    return std.fmt.parseInt(u64, src[i..end], 10);
}

test "자리별 다이제스트 진단은 한 세션 안에 최소 한 번 나온다" {
    const a = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source_path, a, .limited(max_source_bytes));
    defer a.free(src);

    // ① 바깥 게이트(틱 단위)와 안쪽 게이트(호출 단위)를 각각 읽는다.
    const outer = try constValue(src, "notify_diag_interval_ticks");
    const inner = try constValue(src, "digest_site_interval_calls");
    const effective = outer * inner;

    if (effective > max_effective_ticks) {
        std.debug.print(
            "자리별 진단 주기가 너무 길다: {d} × {d} = {d} 틱 (상한 {d}) — 로그에 안 나온다\n",
            .{ outer, inner, effective, max_effective_ticks },
        );
        return error.DigestSiteDiagTooRare;
    }

    // ② **이름이 단위를 말해야 한다.** `_ticks` 로 두면 다음 사람이 「3600 틱 = 1 분」을 다시 계산한다.
    //    실제로 그렇게 5 시간이 됐다.
    if (std.mem.indexOf(u8, src, "digest_site_interval_ticks") != null) {
        std.debug.print("상수 이름이 «틱»이라 말하는데 세는 건 호출이다 — 그 착각이 원래 버그다\n", .{});
        return error.UnitNameLies;
    }

    // ③ 안쪽 게이트가 **바깥 게이트를 통과한 뒤에** 불린다는 전제 자체를 고정한다. 호출 위치가
    //    바뀌어 매 틱 불리게 되면 ①의 계산이 틀리므로, 그때는 이 판정자도 함께 고쳐야 한다.
    const outer_fn = std.mem.indexOf(u8, src, "fn logObservationEventDiag") orelse
        return error.OuterFnMissing;
    const outer_end = std.mem.indexOfPos(u8, src, outer_fn, "\n    fn ") orelse src.len;
    const body = src[outer_fn..outer_end];
    const gate_at = std.mem.indexOf(u8, body, "% notify_diag_interval_ticks != 0) return;") orelse
        return error.OuterGateMissing;
    const call_at = std.mem.indexOf(u8, body, "logDigestSiteDiag();") orelse
        return error.InnerCallMoved;
    if (call_at < gate_at) {
        std.debug.print("안쪽 진단이 바깥 게이트 «앞» 에서 불린다 — 주기 계산이 달라진다\n", .{});
        return error.InnerCallBeforeGate;
    }
}
