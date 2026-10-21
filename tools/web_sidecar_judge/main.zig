//! 웹 OSR sidecar W1b·W1c 판정자 — `maru-web-judge <설치 디렉터리> <프로필 뿌리>`.
//!
//! 실제 `maru-web-host` 를 maru 처럼 띄워 docs/plans/web-osr-backend.md 「W1b」 완료 판정을 잰다:
//!   handshake        hello → 같은 instance·nonce 의 hello_ack
//!   version-mismatch 다른 제어 채널 버전의 hello → 제 버전의 hello_ack(0·0) 하나와 exit 18(W7a1 —
//!                    따로 설치된 maru 와 `maru-chromium` 이 어긋나면 maru 는 이 머리로 「버전 불일치」를 알아본다)
//!   helper-sandbox   host 의 자식이 모두 `maru-web-helper` 이고 `sandbox_check` 1(host 자신은 샌드박스 밖)
//!   shutdown-clean   shutdown → 알림이 끝까지 frame 으로만 풀리고(stdout 오염 없음) exit 0, helper 도 사라진다
//!   parent-death     maru 역할 프로세스를 SIGKILL 하면 host 와 helper 가 모두 사라진다(고아 Chromium 없음) — 명령 pipe 의
//!                    쓰기 끝을 손자(maru 가 띄운 셸 흉내)가 쥐고 있어 EOF 가 오지 않아도
//!   no-crash         판정 동안 `maru-web-*` 크래시 보고가 하나도 새로 생기지 않는다
//! W1c 판정은 `browsers_check.zig`, W2 판정은 `frames_check.zig`, W4 입력 판정은 `input_check.zig`, W5a 대화상자·파일 선택
//! 판정은 `dialogs_check.zig`, W5b 권한 판정은 `permissions_check.zig` 가 든다. 하나라도 틀리면 exit 1.
//! `maru-web-judge --input <설치 디렉터리> <프로필 뿌리>` 는 입력 판정만, `--dialogs` 는 대화상자 판정만, `--permissions` 는 권한
//! 판정만 돈다. `--upload` 는 W9c③ 업로드가 기대는 Chromium 의 성질(`upload_check.zig`)만 본다. `--network` 는 W9d① 네트워크 기록
//! (`network_check.zig` — 지켜보는 탭의 갈래·헤더·리다이렉트·서비스 워커·쏟아짐·설정 끔, 적대 리뷰 5 회차 항목은 `network_r9d5_check.zig`)와
//! W9d② 응답 본문 기록(`network_body_check.zig` — 잡기·상한·글 아님·끊김·맞추기·서비스 워커·UB1·설정 끔·쓰는 스레드·렌더러 죽음·끄기, 적대 리뷰
//! 1·2 회차 항목은 `network_body_r1_check.zig`, 3 회차 항목은 `network_body_r3_check.zig`, 4 회차 항목은 `network_body_r4_check.zig`, 5 회차 항목은
//! `network_body_r5_check.zig`)만 본다. `--network-body` 는 본문 판정(적대 리뷰 1–5 회차 항목 포함)만, `--review-body-r3`·`--review-body-r4`·
//! `--review-body-r5` 는 그 회차 항목만. `--review-body-v20a`·`--review-body-v20b` 는 W9d② 20 회 적대 검증의 판정(`network_body_v20a_check.zig`
//! 1–10 회차·`network_body_v20b_check.zig` 11–20 회차 — `--network` 에는 들지 않는다)만. `--network-block` 은 W9d③ 요청 막기
//! (`network_block_check.zig` — 탭 길·서비스 워커 길·엄격 모드·재시작·비용)만 본다. `--review-block-v20a`·`--review-block-v20b` 는 W9d③ 20 회
//! 적대 검증의 판정(`network_block_v20a_check.zig` 1–10 회차·`network_block_check.zig` 의 `runV20b` 11–20 회차 — `--network-block` 에는
//! 들지 않는다)만, `--review-block-v20a2` 는 2 차 검증 1–10 회차(`network_block_v20a2_check.zig` — 2 차 11–20 회차는 `runV20b` 에 더했다)만,
//! `--review-block-v20a3`·`--review-block-v20c` 는 3 차 검증 1–10 회차(`network_block_v20a3_check.zig`)·11–20 회차(`network_block_check.zig` 의
//! `runV20c`)만.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const sandbox = @import("sandbox.zig");
const http = @import("http.zig");
const browsers_check = @import("browsers_check.zig");
const frames_check = @import("frames_check.zig");
const input_check = @import("input_check.zig");
const dialogs_check = @import("dialogs_check.zig");
const permissions_check = @import("permissions_check.zig");
const popup_check = @import("popup_check.zig");
const tooltip_check = @import("tooltip_check.zig");
const contextmenu_check = @import("contextmenu_check.zig");
const drag_check = @import("drag_check.zig");
const newtab_check = @import("newtab_check.zig");
const popupadopt_check = @import("popupadopt_check.zig");
const media_check = @import("media_check.zig");
const close_check = @import("close_check.zig");
const datalist_check = @import("datalist_check.zig");
const download_check = @import("download_check.zig");
const devtools_check = @import("devtools_check.zig");
const upload_check = @import("upload_check.zig"); // W9c③
const network_check = @import("network_check.zig"); // W9d①
const network_r9d5_check = @import("network_r9d5_check.zig"); // W9d① 적대 리뷰 5 회차
const network_body_check = @import("network_body_check.zig"); // W9d② 응답 본문 기록
const network_body_r1_check = @import("network_body_r1_check.zig"); // W9d② 적대 리뷰 1 회차
const network_body_r3_check = @import("network_body_r3_check.zig"); // W9d② 적대 리뷰 3 회차
const network_body_r4_check = @import("network_body_r4_check.zig"); // W9d② 적대 리뷰 4 회차
const network_body_r5_check = @import("network_body_r5_check.zig"); // W9d② 적대 리뷰 5 회차
const network_body_v20a_check = @import("network_body_v20a_check.zig"); // W9d② 적대적 검증 20 회 중 1–10(A)
const network_body_swcdp_check = @import("network_body_swcdp_check.zig"); // W9d② 서비스 워커 갈래 새 설계(재검증 5 차)
const network_body_swwait_check = @import("network_body_swwait_check.zig"); // W9d② 새로 뜨는 워커를 멈춰 붙이기(재검증 12 차)
const network_body_v20l_check = @import("network_body_v20l_check.zig"); // 탐침: 재검증 5 차 적대 검증 11–20 회차
const network_body_v20m_check = @import("network_body_v20m_check.zig"); // 탐침: 재검증 6 차 적대 검증 11–20 회차(v20m-B)
const network_body_v20fa_check = @import("network_body_v20fa_check.zig"); // W9d② 최종 재검증 1–10 회차(검증자 v20f A)
const network_body_v20fb_check = @import("network_body_v20fb_check.zig"); // W9d② 최종 재검증 11–20 회차(검증자 v20f B)
const network_body_v20b_check = @import("network_body_v20b_check.zig"); // W9d② 적대 검증 11–20 회차

const network_block_check = @import("network_block_check.zig"); // W9d③ 요청 막기
const network_block_v20a_check = @import("network_block_v20a_check.zig"); // W9d③ 20 회 적대 검증 1–10 회차
const network_block_v20a2_check = @import("network_block_v20a2_check.zig"); // W9d③ 2 차 20 회 적대 검증 1–10 회차
const network_block_v20a3_check = @import("network_block_v20a3_check.zig"); // W9d③ 3 차 20 회 적대 검증 1–10 회차
const attacks = @import("attacks.zig");

const helper_wait_ms = 20_000;
const exit_wait_ms = 20_000;
/// 알림 하나를 기다리는 상한 — 초기화 직후의 답도 이 안에 온다.
const reply_wait_ms = 15_000;

var failures: u32 = 0;

extern "c" fn signal(sig: c_int, handler: usize) usize;

fn report(ok: bool, name: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!ok) failures += 1;
    std.debug.print("{s} {s}: " ++ fmt ++ "\n", .{ if (ok) "PASS" else "FAIL", name } ++ args);
}

fn reportText(ok: bool, name: []const u8, detail: []const u8) void {
    report(ok, name, "{s}", .{detail});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--rogue")) return frames_check.rogueMain(std.mem.span(argv[2]), std.mem.span(argv[3]));
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--attack")) return attacks.main(std.mem.span(argv[2]), std.mem.span(argv[3]));
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--input")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        var profile_buf: [1024]u8 = undefined;
        const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/e", .{std.mem.span(argv[3])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        inputChecks(host, profile);
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--dialogs")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        dialogChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--popup")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        popupChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--drag")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        dragChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--datalist")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        datalistChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--download")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        downloadChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--devtools")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        devtoolsChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--upload")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        uploadChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    // W9d② 적대 리뷰 3 회차 판정만(`body-r3-*` — `--network`·`--network-body` 끝에서도 돈다).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-r3")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        bodyR3Checks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    // W9d② 적대적 검증 1–10 회차(A) 판정만(`v20a-*` — 고른 항목만 `V20_ONLY`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20a")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20a", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20a_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20a", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // 탐침(재검증 5 차 적대 검증 11–20 회차 — `V20L_ONLY`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20l")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20l", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20l_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20l", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // 탐침(재검증 6 차 적대 검증 11–20 회차 — `V20M_ONLY`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20m")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20m", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20m_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20m", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d② 서비스 워커 CDP 판정(`swcdp-*` — 따로만: `--review-body-swcdp`, 고른 항목은 `SWCDP_ONLY`; 재검증 5 차).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-swcdp")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_swcdp", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_swcdp_check.run(&reportText, host, prof) catch |err| report(false, "network-body-swcdp", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d② 새로 뜨는 워커를 멈춰 붙이기 판정(`swwait-*` — 따로만: `--review-body-swwait`, 고른 항목은 `SWWAIT_ONLY`; 재검증 12 차).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-swwait")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_swwait", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_swwait_check.run(&reportText, host, prof) catch |err| report(false, "network-body-swwait", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d② 최종 재검증 판정(`v20f-*` — 따로만: `--review-body-v20fa`·`--review-body-v20fb`, 고른 항목은 `V20F_ONLY`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20fa")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20fa", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20fa_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20fa", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20fb")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20fb", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20fb_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20fb", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d② 적대 검증 11–20 회차 판정만(`v20b-*` — 이것만은 따로: `--review-body-v20b`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-v20b")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var pb: [1024]u8 = undefined;
        const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_v20b", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_v20b_check.run(&reportText, host, prof) catch |err| report(false, "network-body-v20b", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d② 적대 리뷰 5 회차 판정만(`body-r5-*` — `--network`·`--network-body` 끝에서도 돈다).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-r5")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        bodyR5Checks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    // W9d② 적대 리뷰 4 회차 판정만(`body-r4-*` — `--network`·`--network-body` 끝에서도 돈다).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-body-r4")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        bodyR4Checks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    // W9d②: 본문 기록 판정만(빠르게 다시 돌릴 때).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--network-body")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var profile_body_buf: [1024]u8 = undefined;
        const profile_body = std.fmt.bufPrintSentinel(&profile_body_buf, "--profile-dir={s}/netbody", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_check.run(&reportText, host, profile_body) catch |err| report(false, "network-body", "{s}", .{@errorName(err)});
        bodyR1Checks(host, std.mem.span(argv[3]));
        bodyR3Checks(host, std.mem.span(argv[3]));
        bodyR4Checks(host, std.mem.span(argv[3]));
        bodyR5Checks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--network")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        var profile_buf: [1024]u8 = undefined;
        const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/net", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_check.run(&reportText, host, profile) catch |err| report(false, "network", "{s}", .{@errorName(err)});
        // W9d① 적대 리뷰 5 회차(`R9d5-*`): 따로 띄운 sidecar·프로필로(앞 판정의 지켜보기·쿠키가 섞이지 않게).
        var profile5_buf: [1024]u8 = undefined;
        const profile5 = std.fmt.bufPrintSentinel(&profile5_buf, "--profile-dir={s}/net5", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_r9d5_check.run(&reportText, host, profile5) catch |err| report(false, "network-r9d5", "{s}", .{@errorName(err)});
        // W9d②: 응답 본문 기록 — 따로 띄운 sidecar·프로필로.
        var profile_body_buf: [1024]u8 = undefined;
        const profile_body = std.fmt.bufPrintSentinel(&profile_body_buf, "--profile-dir={s}/netbody", .{std.mem.span(argv[3])}, 0) catch return 2;
        network_body_check.run(&reportText, host, profile_body) catch |err| report(false, "network-body", "{s}", .{@errorName(err)});
        bodyR1Checks(host, std.mem.span(argv[3]));
        bodyR3Checks(host, std.mem.span(argv[3]));
        bodyR4Checks(host, std.mem.span(argv[3]));
        bodyR5Checks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    // W9d③: 요청 막기 판정만(`block-*` — 탭 길·서비스 워커 길·엄격 모드·재시작·비용, 시나리오마다 따로 띄운 sidecar·프로필).
    // W9d③ 20 회 적대 검증 1–10 회차 판정만(`A-*` — 이것만은 따로: `--review-block-v20a`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20a")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a_check.run(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20a", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 2 차 20 회 적대 검증 1–10 회차 판정만(`A2-*` — `--review-block-v20a2`, `V20A2_ONLY=strict,d2,sw,imp,canon` 으로 고른다).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20a2")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a2_check.run(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20a2", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 3 차 20 회 적대 검증 1–10 회차 판정만(`A3-*` — `--review-block-v20a3`, `A3_ONLY=r6,r8,r10,canon` 으로 고른다): 끝나지 않은 iframe 이동·
    // 들어오는 서비스 워커 이동·오래 도는 beforeunload·iframe 의 같은 문서 뒤로.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20a3")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.run(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20a3", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 4 차 검증 A4 의 판정(`A4-*` — `--review-block-v20a4`, `A4_ONLY=r6,r10`): 남은 막은 하위 프레임 표시·옛 문서의 같은 주소 하위 자원·
    // 같은 사이트 iframe 의 떨어져 나감·건너뛰는 기록 항목·CDP 로 답한 떠나기 확인.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20a4")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.runA4(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20a4", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--network-block")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_check.run(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "network-block", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 20 회 적대 검증 11–20 회차 판정만(`v20b-*` — 이것만은 따로: `--review-block-v20b`).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20b")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_check.runV20b(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20b", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 3 차 20 회 적대 검증 11–20 회차 판정만(`v20c-*` — `--review-block-v20c`): 늦은 수의 세대·DevTools 지킴 훑기.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20c")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_check.runV20c(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20c", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 8 차 적대 검증 A8(`A8-*` — `--review-block-v20h`, `A8_ONLY=tgt,hid,dstrict,drule,drec`, `A8_M=<메서드 이름 조각>`) — 읽기 목록에 남은 28 개를 다른 강제 계산·로드 갈래로
    // (늦은 iframe·그림, c-v:hidden 안 iframe·shadow·font-display, print, image-set·srcset, 상위 레이어, 닫힌 select·details, 숨긴 iframe, 숨은 탭). 회귀 판정(8 차 2 판 기준 199/0).
    // 9 차(`A9-*` — dstrict·drule·drec): 렌더러가 죽은 동안 보낸 엄격 켬·끔·막기 규칙 지우기·기록 끔·켬이 되살린 렌더러에 맞는가.
    // 10 차(`Z-*` — 기본: zbrecoff·zbstrict·zbrecon·zkill·zslots·z204·zpopup·zsrec·zkeeprec, `A8_ONLY` 에 이름이 있을 때만: zcrashurl·zrecrash·zearly·zrace):
    // 바쁜 렌더러가 처리하지 못한 채 죽은 명령, 탭마다 짝 자리, 되살린 문서의 머리 하위 자원(남는 틈 — 적기만).
    // 11 차(`ZJ-*` — 기본: zjnofail·zjsuper·zjrec·zjpop·zjclose·zjxnav, `A8_ONLY` 에 이름이 있을 때만: zjnav(관찰)): 죽음을 맞은 엄격 켬의 거짓 `failed`,
    // 같은 종류 명령의 덮기, 기록과 섞기, 렌더러를 나눈 팝업, 닫은 탭의 번호를 다시 씀, 죽음 아닌 렌더러 바꾸기.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20h")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.runA8(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20h", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 7 차 적대 검증 A7(`A7-*` — `--review-block-v20g`, `A7_ONLY=forced,hidden,name,rel,sub,tok`) — 읽기 목록에 남은 메서드가 페이지 스크립트를 돌리는가.
    // 7 차 고침 뒤 기준: getBoxModel·getComputedStyleForNode 는 토큰을 거둔다, 숨은 탭 화면 찍기·releaseObject 뒤 FinalizationRegistry 는 남는 틈(적기만).
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20g")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.runA7(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20g", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 6 차 적대 검증 A6(`A6-*` — `--review-block-v20f`, `A6_ONLY=stale,mainerr,ro,tok,lazy`) — 6 차 고침(getProperties 는 토큰을 거둔다) 뒤 모두 단언.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20f")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.runA6(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20f", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 5 차 적대 검증 A5(`A5-*` — `--review-block-v20e`, `A5_ONLY=eov,leak,bfc,swi,nc,ro,tok,hist,strict`) — 5 차 고침 뒤 모두 단언.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20e")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_v20a3_check.runA5(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20e", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    // W9d③ 4 차 적대 검증 B4(`v20d-*` — `--review-block-v20d`): IO 스레드 맞추기 비용.
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--review-block-v20d")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        network_block_check.runV20d(&reportText, host, std.mem.span(argv[3])) catch |err| report(false, "review-block-v20d", "{s}", .{@errorName(err)});
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--closeask")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        closeAskChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--media")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        mediaChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--popupadopt")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        popupAdoptChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--newtab")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        newTabChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--contextmenu")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        contextMenuChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--tooltip")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        tooltipChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--permissions")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintSentinel(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}, 0) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        permissionChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len != 3) {
        std.debug.print("사용: maru-web-judge <설치 디렉터리> <프로필 뿌리>\n", .{});
        return 2;
    }
    // 판정자 자신이 닫힌 파이프에 써도 신호로 죽지 않고 실패로 보고하게 한다.
    _ = signal(13, 1);
    const started_at = os.unixNow();
    const install_dir = std.mem.span(argv[1]);
    const profile_root = std.mem.span(argv[2]);

    var host_path_buf: [1024]u8 = undefined;
    const host_path = std.fmt.bufPrintSentinel(&host_path_buf, "{s}/maru-web-host", .{install_dir}, 0) catch return 2;
    var profile_a_buf: [1024]u8 = undefined;
    const profile_a = std.fmt.bufPrintSentinel(&profile_a_buf, "--profile-dir={s}/a", .{profile_root}, 0) catch return 2;
    var profile_b_buf: [1024]u8 = undefined;
    const profile_b = std.fmt.bufPrintSentinel(&profile_b_buf, "--profile-dir={s}/b", .{profile_root}, 0) catch return 2;

    sessionChecks(host_path, profile_a) catch |err| report(false, "session", "{s}", .{@errorName(err)});
    versionMismatch(host_path, profile_a) catch |err| report(false, "version-mismatch", "{s}", .{@errorName(err)});
    var profile_c_dir_buf: [1024]u8 = undefined;
    const profile_c_dir = std.fmt.bufPrintSentinel(&profile_c_dir_buf, "{s}/c", .{profile_root}, 0) catch return 2;
    var profile_c_buf: [1024]u8 = undefined;
    const profile_c = std.fmt.bufPrintSentinel(&profile_c_buf, "--profile-dir={s}", .{profile_c_dir}, 0) catch return 2;
    if (http.Server.start()) |server| {
        browsers_check.run(&reportText, host_path, profile_c_dir, profile_c, server.port) catch |err| report(false, "browsers", "{s}", .{@errorName(err)});
        var profile_d_buf: [1024]u8 = undefined;
        const profile_d = std.fmt.bufPrintSentinel(&profile_d_buf, "--profile-dir={s}/d", .{profile_root}, 0) catch return 2;
        var frames_log_buf: [1024]u8 = undefined;
        const frames_log = std.fmt.bufPrintSentinel(&frames_log_buf, "{s}/frames-host.log", .{profile_root}, 0) catch return 2;
        frames_check.run(&reportText, argv[0], host_path, profile_d, frames_log, server.port) catch |err| report(false, "frames", "{s}", .{@errorName(err)});
    } else |err| report(false, "browsers", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_e_buf: [1024]u8 = undefined;
    const profile_e = std.fmt.bufPrintSentinel(&profile_e_buf, "--profile-dir={s}/e", .{profile_root}, 0) catch return 2;
    inputChecks(host_path, profile_e);
    dialogChecks(host_path, profile_root);
    permissionChecks(host_path, profile_root);
    popupChecks(host_path, profile_root);
    tooltipChecks(host_path, profile_root);
    contextMenuChecks(host_path, profile_root);
    dragChecks(host_path, profile_root);
    newTabChecks(host_path, profile_root);
    popupAdoptChecks(host_path, profile_root);
    mediaChecks(host_path, profile_root);
    closeAskChecks(host_path, profile_root);
    datalistChecks(host_path, profile_root);
    downloadChecks(host_path, profile_root);
    devtoolsChecks(host_path, profile_root);
    parentDeath(host_path, profile_b) catch |err| report(false, "parent-death", "{s}", .{@errorName(err)});

    // 크래시 보고는 ReportCrash 가 몇 초 늦게 쓴다.
    os.sleepMs(5000);
    var helper_path_buf: [1024]u8 = undefined;
    const helper_path = std.fmt.bufPrintSentinel(&helper_path_buf, "{s}/maru-web-helper", .{install_dir}, 0) catch return 2;
    var host_uuid: [36]u8 = undefined;
    var helper_uuid: [36]u8 = undefined;
    if (os.machoUuid(host_path, &host_uuid)) |host_id| {
        if (os.machoUuid(helper_path, &helper_uuid)) |helper_id| {
            const crashes = os.crashReportsSince(started_at, &.{ host_id, helper_id });
            report(crashes == 0, "no-crash", "이 빌드(host {s} · helper {s})의 새 크래시 보고 {d} 개", .{ host_id[0..8], helper_id[0..8], crashes });
        } else report(false, "no-crash", "helper UUID 를 못 읽음", .{});
    } else report(false, "no-crash", "host UUID 를 못 읽음", .{});

    std.debug.print("{s}: 틀림 {d} 건\n", .{ if (failures == 0) "통과" else "실패", failures });
    return if (failures == 0) 0 else 1;
}

fn versionMismatch(host_path: [:0]const u8, profile: [:0]const u8) !void {
    var host = try Host.spawn(host_path, profile);
    defer {
        _ = std.c.close(host.commands);
        _ = std.c.close(host.events);
    }
    // 머리의 버전만 다른 hello(다음 버전의 maru 흉내).
    var buf: [64]u8 = undefined;
    const len = try protocol.codec.encode(.{ .hello = .{ .instance = 7, .nonce = 9 } }, &buf);
    std.mem.writeInt(u16, buf[protocol.wire.prefix_len + protocol.wire.magic.len ..][0..2], protocol.wire.version + 1, .big);
    if (std.c.write(host.commands, &buf, len) != @as(isize, @intCast(len))) return error.WriteFailed;
    const reply = host.next(reply_wait_ms) catch null;
    const acked = reply != null and reply.? == .hello_ack and reply.?.hello_ack.instance == 0 and reply.?.hello_ack.nonce == 0;
    const code = host.wait(exit_wait_ms);
    report(acked and code == 18, "version-mismatch", "제 버전 hello_ack(0·0) {} · exit {?d}(18 이어야)", .{ acked, code });
}

fn handshake(host: *Host) !void {
    const hello: protocol.message.Hello = .{ .instance = @intCast(std.c.getpid()), .nonce = os.random64() };
    try host.send(.{ .hello = hello });
    const reply = (try host.next(reply_wait_ms)) orelse return error.ClosedBeforeAck;
    const ok = reply == .hello_ack and reply.hello_ack.instance == hello.instance and reply.hello_ack.nonce == hello.nonce;
    report(ok, "handshake", "nonce {x}", .{hello.nonce});
    if (!ok) return error.HandshakeMismatch;
}

/// helper 가 적어도 `min` 개 뜰 때까지 기다린다(GPU·네트워크 유틸리티는 초기화 직후 뜬다).
fn waitForHelpers(host_pid: c_int, out: []c_int, min: usize) []c_int {
    var waited: u32 = 0;
    while (waited < helper_wait_ms) : (waited += 200) {
        const kids = os.children(host_pid, out);
        if (kids.len >= min) return kids;
        os.sleepMs(200);
    }
    return os.children(host_pid, out);
}

fn sessionChecks(host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    var host = try Host.spawn(host_path, profile_arg);
    try handshake(&host);

    var kids_buf: [64]c_int = undefined;
    const kids = waitForHelpers(host.pid, &kids_buf, 2);
    const state = sandbox.settle(host.pid, 2, helper_wait_ms);
    const host_outside = os.sandbox_check(host.pid, null, 0) == 0;
    report(state.all(2) and host_outside, "helper-sandbox", "helper {d} 개 · 샌드박스 {d} · 이름 일치 {d} · host 샌드박스 밖 {}", .{ state.total, state.sandboxed, state.named, host_outside });

    var remembered: [64]c_int = undefined;
    const remembered_len = os.children(host.pid, &remembered).len;
    _ = kids;
    try host.send(.shutdown);
    var extra: usize = 0;
    while (try host.next(exit_wait_ms)) |_| extra += 1;
    const code = host.wait(exit_wait_ms);
    const gone = allGone(remembered[0..remembered_len], exit_wait_ms);
    report(host.clean and extra == 0 and code != null and code.? == 0 and gone, "shutdown-clean", "stdout frame 만 {} · 남은 알림 {d} · exit {?d} · helper 모두 사라짐 {}", .{ host.clean, extra, code, gone });
}

/// maru 역할의 중간 프로세스가 host 를 띄우고 handshake 한 뒤 host pid 를 알려 온다. 그 프로세스를 SIGKILL 한다.
fn parentDeath(host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    var report_pipe: [2]c_int = undefined;
    if (std.c.pipe(&report_pipe) != 0) return error.PipeFailed;
    const parent = os.fork();
    if (parent < 0) return error.ForkFailed;
    if (parent == 0) {
        _ = std.c.close(report_pipe[0]);
        var host = Host.spawn(host_path, profile_arg) catch std.c._exit(3);
        const hello: protocol.message.Hello = .{ .instance = 1, .nonce = os.random64() };
        host.send(.{ .hello = hello }) catch std.c._exit(4);
        _ = (host.next(reply_wait_ms) catch std.c._exit(5)) orelse std.c._exit(6);
        // maru 가 띄운 셸처럼 명령 pipe 의 쓰기 끝을 물려받은 손자 — 부모가 죽어도 이것이 살아 있으면 EOF 가 오지 않는다.
        const grandchild = os.fork();
        if (grandchild == 0) {
            while (true) os.sleepMs(1000);
        }
        const pids = [2]c_int{ host.pid, grandchild };
        const pid_bytes = std.mem.asBytes(&pids);
        _ = std.c.write(report_pipe[1], pid_bytes.ptr, pid_bytes.len);
        while (true) os.sleepMs(1000);
    }
    _ = std.c.close(report_pipe[1]);
    var pids: [2]c_int = undefined;
    if (std.c.read(report_pipe[0], std.mem.asBytes(&pids).ptr, @sizeOf([2]c_int)) != @sizeOf([2]c_int)) return error.NoHostPid;
    const host_pid = pids[0];
    const grandchild = pids[1];
    defer _ = std.c.kill(grandchild, .KILL);

    var kids_buf: [64]c_int = undefined;
    const kids = waitForHelpers(host_pid, &kids_buf, 2);
    var watched: [65]c_int = undefined;
    watched[0] = host_pid;
    @memcpy(watched[1..][0..kids.len], kids);

    _ = std.c.kill(parent, .KILL);
    _ = std.c.waitpid(parent, null, 0);
    const gone = allGone(watched[0 .. kids.len + 1], exit_wait_ms);
    report(kids.len >= 2 and gone, "parent-death", "helper {d} 개 · 부모 SIGKILL 뒤 host·helper 모두 사라짐 {}", .{ kids.len, gone });
    if (!gone) for (watched[0 .. kids.len + 1]) |pid| {
        if (os.alive(pid)) _ = std.c.kill(pid, .KILL);
    };
}

fn allGone(pids: []const c_int, timeout_ms: u32) bool {
    return os.survivors(pids, timeout_ms) == 0;
}

/// 대화상자·파일 선택 판정(W5a) — 프로필은 `<뿌리>/f`, 고를 파일은 뿌리 아래에 만든다.
fn dialogChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "dialogs", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/f", .{profile_root}, 0) catch return report(false, "dialogs", "프로필 경로가 길다", .{});
    dialogs_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "dialogs", "{s}", .{@errorName(err)});
}

/// 권한 판정(W5b) — 프로필은 `<뿌리>/g`(다시 띄워 기억을 잰다 — 같은 HTTP 서버라 출처가 같다).
fn permissionChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "permissions", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/g", .{profile_root}, 0) catch return report(false, "permissions", "프로필 경로가 길다", .{});
    permissions_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "permissions", "{s}", .{@errorName(err)});
    var orphan_buf: [1024]u8 = undefined;
    const orphan_profile = std.fmt.bufPrintSentinel(&orphan_buf, "--profile-dir={s}/h", .{profile_root}, 0) catch return report(false, "perm-camera-orphan", "프로필 경로가 길다", .{});
    permissions_check.cameraOrphan(&reportText, host_path, orphan_profile, server.port) catch |err| report(false, "perm-camera-orphan", "{s}", .{@errorName(err)});
}

/// 단독 모드의 첫 판정 전에 host 를 한 번 띄워 빈 브라우저를 만들고 끝낸다(프로필 `<뿌리>/w`) — 판정이 아니다. 새로 빌드한
/// x86_64 설치물의 첫 실행은 Rosetta 번역으로 느려 첫 페이지 준비가 15 초를 넘겼다(W6a① 실측 27 초, 다음부터 6~7 초).
/// 전체 판정은 앞의 판정들이 이 비용을 치른다. 걸린 시간을 출력해 정말 느려진 것은 보이게 한다(W6a① 적대 검증 5 차).
/// W9d② 적대 리뷰 1·2 회차(`body-r1-*`·`body-r2-*`) — 따로 띄운 sidecar·프로필로(앞 판정의 지켜보기·쿠키가 섞이지 않게).
fn bodyR1Checks(host: [:0]const u8, profile_root: []const u8) void {
    var pb: [1024]u8 = undefined;
    const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_r1", .{profile_root}, 0) catch return;
    network_body_r1_check.run(&reportText, host, prof) catch |err| report(false, "network-body-r1", "{s}", .{@errorName(err)});
}

/// W9d② 적대 리뷰 3 회차(`body-r3-*` — 맞추기의 물 높이·abort 한 요청·답이 없는 호출의 끝) — 따로 띄운 sidecar·프로필로.
fn bodyR3Checks(host: [:0]const u8, profile_root: []const u8) void {
    var pb: [1024]u8 = undefined;
    const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_r3", .{profile_root}, 0) catch return;
    network_body_r3_check.run(&reportText, host, prof) catch |err| report(false, "network-body-r3", "{s}", .{@errorName(err)});
}

/// W9d② 적대 리뷰 4 회차(`body-r4-*` — 서비스 워커의 캐시·만든 응답, 프레임·캐시가 섞인 같은 주소, SPA 의 잡은 비율, 이동으로 기다리던 본문) —
/// 따로 띄운 sidecar·프로필로.
fn bodyR4Checks(host: [:0]const u8, profile_root: []const u8) void {
    var pb: [1024]u8 = undefined;
    const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_r4", .{profile_root}, 0) catch return;
    network_body_r4_check.run(&reportText, host, prof) catch |err| report(false, "network-body-r4", "{s}", .{@errorName(err)});
}

/// W9d② 적대 리뷰 5 회차(`body-r5-*` — abort 한 뒤 다시 받기 150 번, 서비스 워커의 남은 꼴, 적대 탭·큰 주소, 종료, 무거운 페이지의 잡은 비율) —
/// 따로 띄운 sidecar·프로필로.
fn bodyR5Checks(host: [:0]const u8, profile_root: []const u8) void {
    var pb: [1024]u8 = undefined;
    const prof = std.fmt.bufPrintSentinel(&pb, "--profile-dir={s}/netbody_r5", .{profile_root}, 0) catch return;
    network_body_r5_check.run(&reportText, host, prof) catch |err| report(false, "network-body-r5", "{s}", .{@errorName(err)});
}

fn warmUp(host_path: [:0]const u8, profile_root: []const u8) void {
    const started = os.nowMs();
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/w", .{profile_root}, 0) catch return;
    var host = Host.spawn(host_path, profile) catch return;
    var created = false;
    if (browsers_check.handshake(&host)) |_| {
        if (host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 64, .height = 64, .scale = 1 }, .hidden = false, .url = "about:blank" } })) |_| {
            const deadline = os.nowMs() + 120_000;
            while (!created and os.nowMs() < deadline) {
                const message = (host.next(1_000) catch |err| if (err == error.Timeout) continue else break) orelse break;
                if (message == .load_finished) created = true;
            }
        } else |_| {}
    } else |_| {}
    host.send(.shutdown) catch {};
    if (host.wait(15_000) == null) {
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(15_000);
    }
    _ = std.c.close(host.commands);
    _ = std.c.close(host.events);
    std.debug.print("warm-up: host 첫 실행과 빈 페이지 {d} ms(판정 아님 — 불러옴 {})\n", .{ os.nowMs() - started, created });
}

/// 우클릭 메뉴 판정(W6c①) — 프로필은 `<뿌리>/k`.
fn contextMenuChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "contextmenu", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/k", .{profile_root}, 0) catch return report(false, "contextmenu", "프로필 경로가 길다", .{});
    contextmenu_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "contextmenu", "{s}", .{@errorName(err)});
}

/// 끌어 놓기 판정(W6d①) — 프로필은 `<뿌리>/m`, 끌어 올 파일은 `<뿌리>/drag-files`.
fn dragChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "drag", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/m", .{profile_root}, 0) catch return report(false, "drag", "프로필 경로가 길다", .{});
    drag_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "drag", "{s}", .{@errorName(err)});
}

/// 동영상·오디오 우클릭 메뉴 판정(W6h②) — 프로필은 `<뿌리>/q`.
fn mediaChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "media", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/q", .{profile_root}, 0) catch return report(false, "media", "프로필 경로가 길다", .{});
    media_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "media", "{s}", .{@errorName(err)});
}

/// 물어보고 닫기 판정(W6j) — 프로필은 `<뿌리>/r`.
fn closeAskChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "close-ask", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/r", .{profile_root}, 0) catch return report(false, "close-ask", "프로필 경로가 길다", .{});
    close_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "close-ask", "{s}", .{@errorName(err)});
}

/// 제안 목록 판정(W6m①) — 프로필은 `<뿌리>/l`.
fn datalistChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "datalist", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/l", .{profile_root}, 0) catch return report(false, "datalist", "프로필 경로가 길다", .{});
    datalist_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "datalist", "{s}", .{@errorName(err)});
}

/// 다운로드 판정(W10a) — 프로필은 `<뿌리>/s`, 받은 파일은 `<뿌리>/dl-out`.
fn downloadChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "download", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/s", .{profile_root}, 0) catch return report(false, "download", "프로필 경로가 길다", .{});
    download_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "download", "{s}", .{@errorName(err)});
}

/// DevTools 호출 판정(W9-0b) — 프로필은 `<뿌리>/t`, 시한을 줄인 host 는 `<뿌리>/u`.
fn devtoolsChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "devtools", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/t", .{profile_root}, 0) catch return report(false, "devtools", "프로필 경로가 길다", .{});
    var expired_buf: [1024]u8 = undefined;
    const expired_profile = std.fmt.bufPrintSentinel(&expired_buf, "--profile-dir={s}/u", .{profile_root}, 0) catch return report(false, "devtools", "프로필 경로가 길다", .{});
    devtools_check.run(&reportText, host_path, profile, expired_profile, server.port) catch |err| report(false, "devtools", "{s}", .{@errorName(err)});
}

/// 업로드 판정(W9c③) — 프로필은 `<뿌리>/w`, 넣을 파일은 `<뿌리>` 에 만든다.
fn uploadChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "upload", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/w", .{profile_root}, 0) catch return report(false, "upload", "프로필 경로가 길다", .{});
    upload_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "upload", "{s}", .{@errorName(err)});
}

/// 팝업 이어 받기 판정(W6f①) — 프로필은 `<뿌리>/o`.
fn popupAdoptChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "popupadopt", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/o", .{profile_root}, 0) catch return report(false, "popupadopt", "프로필 경로가 길다", .{});
    popupadopt_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "popupadopt", "{s}", .{@errorName(err)});
}

/// 새 탭 판정(W6e) — 프로필은 `<뿌리>/n`.
fn newTabChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "newtab", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/n", .{profile_root}, 0) catch return report(false, "newtab", "프로필 경로가 길다", .{});
    newtab_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "newtab", "{s}", .{@errorName(err)});
}

/// 툴팁 판정(W6b) — 프로필은 `<뿌리>/j`.
fn tooltipChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "tooltip", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/j", .{profile_root}, 0) catch return report(false, "tooltip", "프로필 경로가 길다", .{});
    tooltip_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "tooltip", "{s}", .{@errorName(err)});
}

/// 팝업 판정(W6a) — 프로필은 `<뿌리>/i`.
fn popupChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "popup", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintSentinel(&profile_buf, "--profile-dir={s}/i", .{profile_root}, 0) catch return report(false, "popup", "프로필 경로가 길다", .{});
    popup_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "popup", "{s}", .{@errorName(err)});
}

/// 입력 판정(W4). HTTP 서버는 판정마다 새로 연다(입력만 돌 때도 같은 페이지를 쓴다).
fn inputChecks(host_path: [:0]const u8, profile: [:0]const u8) void {
    const server = http.Server.start() catch |err| return report(false, "input", "HTTP 서버: {s}", .{@errorName(err)});
    input_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "input", "{s}", .{@errorName(err)});
}
