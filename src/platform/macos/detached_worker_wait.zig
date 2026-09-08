//! **판정자가 detached worker 보다 먼저 끝나는 것을 막는다** — 판정자 전용 대기.
//!
//! ## 왜 있나
//!
//! 이 층의 backend 들은 느린 FS·프로세스 I/O 를 detached thread 로 돌리고, 물러날 때 **기다리지
//! 않는다**(refcount 가 마지막 하나를 파괴한다). 제품에서는 그게 맞다 — 멈춘 I/O 로 창 닫기가 굳는 것이
//! 훨씬 나쁘고, `file_tree_backend` 는 그 계약을 판정자로 못 박아 두기까지 했다.
//!
//! **판정자에서는 그 대가를 다른 판정자가 문다.** 스캔을 던져 놓고 세션이 끝나면 아직 도는 job 의 경로
//! 사본이 테스트 할당자 결산에 **누수로 잡히고**, 그 워커가 뒤이어 해제된 자리를 만지면 누수 트레이스를
//! 찍는 도중에 죽는다. 2026-09-08 CI 샤드가 정확히 그 모양으로 abort 했다 —
//! `dupe` 누수 한 줄 → `writeTrace` 에서 Segmentation fault → 종료 코드 134. **판정자 이름이 안 남아**
//! 원인이 엉뚱한 커밋으로 귀속됐고, 흘린 판정자와 잡힌 판정자가 애초에 다르다(결산은 매 판정자 끝에
//! 돌므로 앞선 판정자가 남긴 워커가 뒤엣것의 실패로 보고된다). 빠른 기계에서는 워커가 먼저 끝나 안
//! 보인다 — 로컬 4 샤드 전부 초록인데 CI 만 빨간 모양이 그것이다.
//!
//! ## 규율
//!
//! 부르는 자리는 **세션이 backend 를 놓는 곳**이지 판정자 하나하나가 아니다. 이 backend 들을 쓰는
//! 판정자가 수십 개인데 규율을 그만큼 나눠 두면 새로 쓰는 사람이 반드시 빠뜨린다.
//!
//! `inflight == 0` 이 아니라 **참조수**를 본다. 워커는 자기 카운터를 줄인 **뒤에도** `state.release()` 를
//! 한 번 더 만지므로, 카운터만 보고 나가면 그 사이에 판정자가 끝나 state 자체가 누수로 잡히는 좁은 창이
//! 남는다. 참조수 1(= 소유자 것 하나)까지 기다리면 돌아온 뒤 그 state 를 만지는 스레드가 없다.

const std = @import("std");

/// 벽시계 상한. **반복 상한(`spins < N`)으로 재지 않는다** — 부하 걸린 기계에서 먼저 끊어져,
/// 정작 느려서 생기는 이 결함을 못 잡는다(IG14 와 같은 실패다).
pub const timeout_ns: i128 = 30 * std.time.ns_per_s;

/// backend 의 detached worker 가 **전부 자기 참조를 놓을 때까지** 기다린다.
///
/// `backend` 는 `state` 필드를 든 아무 backend 다 — `?*State` 든 `*State` 든 받는다. state 는
/// `refs: std.atomic.Value(...)` 를 들어야 한다.
///
/// **상한을 넘기면 그냥 돌아온다.** 그때는 누수가 **정직하게** 잡힌다 — 조용한 통과를 만들지 않는다.
pub fn quiet(backend: anytype, io: std.Io) void {
    const field = backend.state;
    const state = switch (@typeInfo(@TypeOf(field))) {
        .optional => field orelse return,
        else => field,
    };
    const deadline_ns = std.Io.Clock.awake.now(io).nanoseconds + timeout_ns;
    var spins: usize = 0;
    while (state.refs.load(.acquire) != 1) {
        spins += 1;
        if (spins & 0xff == 0 and std.Io.Clock.awake.now(io).nanoseconds >= deadline_ns) return;
        std.Thread.yield() catch {};
    }
}
