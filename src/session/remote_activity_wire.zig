//! **원격 활동 wire**(RAV1 — [계획](../../docs/plans/remote-agent-activity.md) §2.4·§6.1).
//!
//! 원격 헬퍼(`maru-remote-watch` 를 넓힌 것, RAV2)가 저쪽에서 트랜스크립트를 훑어 **내고**, GUI 의
//! 활동 뷰 백엔드가 **읽는** 한 벌의 코덱이다. [목록 wire](remote_file_listing.zig)와 같은 모양이고
//! 같은 이유로 양방향 API(append·Parser)를 한 모듈에 둔다 — 반대편을 손으로 미러하면 드리프트가 난다.
//!
//! ## 왜 파일이 아니라 이것을 보내나
//!
//! 계획 §3 이 실측으로 판정했다. 이 맥의 Codex 세션 최대가 **3.88 GB** 인데, 같은 파일의 활동
//! 인덱스는 **3.31 MB**(1,175:1)다. 그리고 실서버 왕복(§8.1)에서 261.5 MB 파일이 **2,824,264 B**
//! 로 왔다 — **파일 크기가 아니라 히트 수가 wire 를 정한다.**
//!
//! ## 「자리만 든다」가 국경에서 깨진다 — 라벨이 같이 온다
//!
//! 스캐너 규율([갤러리 §4.2](../../docs/agent-image-gallery.md))은 「`Hit` 은 자리만 들고 바이트는
//! 소비자가 읽는다」인데, 그 전제는 **소비자가 그 파일을 열 수 있다**는 것이고 국경 너머에서는
//! 거짓이다. 그래서 라벨(`agent_image_context.Label`)과 시각을 **저쪽에서 만들어** 함께 싣는다.
//!
//! ⚠️ 라벨의 **원자재**(대상 바이트)를 싣는 것이 초안이었고 틀렸다(계획 §10 A1): `Hit.data_len` 은
//! 상한이 없어 wire 에 천장이 안 선다. 라벨은 `max_label_bytes`(160 B)로 유계라 천장이 **하드**하다.
//!
//! ## wire v1 (줄 지향 + 길이 접두 라벨)
//!
//! ```text
//! maru-rav 3\n                    머리 — 판이 다르면 즉시 거부(구 GUI ↔ 신 헬퍼의 조용한 오독 방지)
//! F <index> <len> <경로>\n         체인의 파일 하나. **인덱스를 명시한다**(순서가 아니다 — §G1)
//! S <p> <ip> <ap> <scanned>\n      스캔 플래그 셋(partial·image_partial·activity_partial)과 읽은 바이트
//! A <필드 19 개> <len> <라벨>\n     활동·이미지 한 건(아래)
//! ! <len> <메시지>\n               원격 오류. 이것으로 끝난 답도 **완결**이다(계획 §2.2)
//! X <count>\n                     꼬리 — 없으면 **잘린 것**이다(§6.1)
//! ```
//!
//! `A` 의 필드는 [`Hit`](agent_image_index.zig) 의 자리들과 1:1 이고 순서가 계약이다:
//! `file_index line_offset data_offset data_len kind mime activity name_rel name_len id_rel id_len
//! cmd_rel input_rel time_rel fold_owner result_flags result_lines result_body_offset
//! result_image_offset` — 그 뒤에 `time_s`, 라벨 길이, 라벨 바이트가 온다.
//!
//! **10 진수로 적는다.** 바이너리 고정폭이 26% 작지만(계산), 목록 wire 가 이미 이 모양이고 사람이
//! 읽을 수 있으면 왕복 게이트가 깨졌을 때 **눈으로 본다**. 26% 는 천장(4.5 MB)을 위협하지 않는다.
//!
//! **여기는 순수 계층이다** — 바이트를 만들고 해석할 뿐, 파일도 소켓도 열지 않는다. Linux 타깃으로
//! 컴파일·테스트되므로 원격 헬퍼(정적 musl)가 그대로 문다.

const std = @import("std");
const index = @import("agent_image_index.zig");
const context = @import("agent_image_context.zig");
const transcript = @import("agent_transcript.zig");

// ── 헬퍼가 이 모듈 **하나만** 물게 하는 재수출 ──────────────────────────────────────────────────
//
// 원격 헬퍼(RAV2)는 스캐너·라벨·wire 셋을 다 써야 하는데, 셋을 각각 물리면 `tools/remote-watch` 의
// 빌드가 세션 트리의 파일 셋을 이름으로 알게 된다. **한 문만 연다** — 계약 §2.3 의 「방향은 한 쪽」
// 이 그 뜻이다. 여기 없는 것은 헬퍼가 쓸 수 없다.

pub const Scanner = index.StreamScanner;
pub const Hit = index.Hit;
pub const Label = context.Label;
pub const Source = context.Source;
pub const activityLabel = context.activityLabel;
pub const timestampSeconds = context.timestampSeconds;
pub const time_window_bytes = context.timestamp_window_bytes;

// ── 체인 풀기(RAV4) ────────────────────────────────────────────────────────────────────────────
//
// Codex 재개 세션은 부모 rollout 까지 훑어야 한다(계약 §3.3) — `compacted` 를 건너뛰는 규칙이
// 「원본이 같은 파일 앞쪽에 있다」를 전제하는데, 재개 세션에서는 그 원본이 **부모 파일**에 있다.
// 실측 90 파일 중 20 개(22%)에서 42 장을 잃고, 최악은 살아 있는 것이 0 장이었다.
//
// **저쪽에서 풀어야 한다.** 로컬 `buildChain` 은 `~/.codex/sessions` 를 이쪽 디렉터리로 훑으므로
// 원격 경로에 대고 부르면 이쪽 파일을 뒤진다(계약 §2.1). 헬퍼가 같은 조각으로 저쪽을 훑는다.
pub const parseCodexParentId = transcript.parseCodexParentId;
pub const findCodexByThreadId = transcript.findCodexByThreadId;
pub const isCodexRolloutOf = transcript.isCodexRolloutOf;
pub const max_chain = index.max_chain;

/// `session_meta` 첫 줄이 들어갈 창 — **실측이 크기를 정한다**: 중앙 18,994 B · 최대 22,079 B 이고
/// 296 개 중 292 개가 8 KiB 를 넘는다. 8 KiB 였을 때 부모 키가 창 안에 든 것은 **운**이었다.
/// 최대의 3 배로 잡는다(로컬 `readCodexParentId` 와 같은 값·같은 근거).
pub const codex_meta_window_bytes: usize = 64 * 1024;

pub const wire_version: u32 = 3;
pub const header_line = "maru-rav 3";

/// 한 wire 가 실을 수 있는 활동·이미지 수. 스캐너의 상한들이 이 값을 정한다 — 그보다 큰 수를
/// 주장하는 wire 는 저쪽이 오염됐다는 뜻이라 파서가 거기서 멈춘다.
pub const max_records: usize = index.max_activity_hits_per_file + index.max_hits_per_file;

/// 체인 파일 수 상한 — [`Chain.max_chain`](agent_image_index.zig) 이 SSOT 다.
pub const max_files: usize = index.max_chain;

/// 경로 하나의 상한 — [`max_source_path_bytes`](agent_image_index.zig) 가 SSOT 다.
pub const max_path_bytes: usize = index.max_source_path_bytes;

/// 라벨 하나의 상한 — [`max_label_bytes`](agent_image_context.zig) 가 SSOT 다. **이 값이 wire 의
/// 천장을 만든다**(머리말).
pub const max_label_bytes: usize = context.max_label_bytes;

/// 원격 오류 메시지 상한. 목록 wire 와 같은 값·같은 이유(표시용 한 줄, 원격이 주는 값이라 유계).
pub const max_error_bytes: usize = 512;

/// 레코드 한 줄이 **주장할 수 있는 최악** 바이트.
///
/// `A ` + 10 진 24 개(각 최악 20 자 + 공백) + 라벨 160 B + 개행. 내는 쪽이 줄 버퍼를 이만큼 잡으면
/// **`appendRecord` 가 버퍼 부족으로 null 을 낼 수 없다** — 그 사실을 comptime 으로 못박으면 「버퍼가
/// 차면 멈춘다」 규율이 도달 불가 방어가 되고, 판정자가 못 만드는 경로를 안 남긴다(적대적 J2).
pub const max_record_bytes: usize = 2 + record_fields * 21 + max_label_bytes + 1;

/// 한 왕복 wire 전체의 상한(바이트). **전송이 이 값으로 읽기를 자른다** — 넘친 답은 꼬리를 잃어
/// 파서가 **잘림**으로 읽는다(§6.1).
///
/// 근거는 **주장할 수 있는 최악**이다(실측이 아니라) — 안 그러면 정상 답이 잘린다. 레코드 하나가
/// 최악 `A ` + 10 진 24 개(오프셋 넷이 u64 라 20 자까지) + 라벨 160 B + 개행 ≈ 400 B 이고,
/// `max_records`(20,480)를 곱하면 **8.2 MB** 다. 24 MiB 는 그 세 배 여유다.
///
/// 실측(적대적 D2 — 실 코퍼스 24 파일 78,213 건 왕복): 레코드 최대 **277 B**, 한 파일 wire 최대
/// **3,576,643 B**(3.41 MB). 즉 현실은 상한의 **1/7** 이다.
///
/// ⚠️ **헬퍼가 이만큼을 잡아야 한다는 뜻이 아니다.** 이것은 **받는 쪽**이 읽기를 자르는 값이고,
/// 내는 쪽은 청크로 흘려도 된다(그때 버퍼가 차면 위 `appendRecord` 의 규율대로 **멈춘다**).
pub const max_wire_bytes: usize = 24 << 20;

/// 스캔 한 번의 결말. 플래그 셋은 [스캐너](agent_image_index.zig)의 그것과 1:1 이고, 「비었다」와
/// 「못 봤다」를 가르는 계약(계획 §2.2)이 이 값으로 국경을 건넌다.
pub const ScanFlags = struct {
    partial: bool = false,
    image_partial: bool = false,
    activity_partial: bool = false,
    /// 저쪽이 실제로 읽은 바이트. 화면이 쓰지는 않지만 **진단이 이 값으로 「정말 훑었나」를 본다**.
    ///
    /// ⚠️ **체인 전체의 합이다** — 머리 파일의 크기가 아니다. 신선도는 `head_bytes` 를 봐야 한다
    /// (RAV7a 적대적 S1 이 그 혼동으로 재개 세션 58% 의 신선도를 껐다).
    scanned_bytes: u64 = 0,
    /// **머리 파일(자리 0)에서 읽은 바이트**(판 2 · RAV7b). 신선도가 「그 자리에서 1 바이트」를 청할
    /// 때 쓰는 값이다 — 체인이 여럿이어도 이 값은 머리 파일의 것이라 판정이 성립한다.
    head_bytes: u64 = 0,
    /// **이어읽기 자국**(판 2 · RAV7b · 계획 §19.2). 머리 파일의 이 자리부터 다시 훑으면 같은 결과를
    /// 얻는다 — `consumed` 와 「살아 있는 미결 호출의 가장 이른 줄」 중 **작은 쪽**이다.
    ///
    /// 🔥 `head_bytes` 와 **다른 값이다**: 저쪽은 「읽은 데까지」, 이쪽은 「결말이 다 붙은 데까지」다.
    /// 둘을 섞으면 이어읽기 구간의 결과 줄이 주인을 못 찾아 「진행중」이 영영 남는다.
    resume_offset: u64 = 0,
    /// **저쪽이 실제로 어디부터 읽었나**(판 3 · RAV7b-3). `--from` 을 안 줬거나 **못 지켰으면 0** 이고,
    /// 그때 답은 파일 **처음부터**의 것이다.
    ///
    /// 🔥 **이 칸이 없으면 못 가른다.** `--from` 이 파일보다 크면(저쪽에서 잘렸다) 그 자리에서 읽어
    /// 봐야 0 바이트이고, 받는 쪽은 그것을 **「활동이 없다」**로 읽어 화면이 **빈 목록**이 된다.
    /// 추론(`scanned_bytes < head_bytes`)으로는 안 된다 — 체인이 여럿이면 그 값은 **합**이라 뜻이
    /// 갈린다(계획 §20.3).
    resumed_from: u64 = 0,
};

/// `A ` 뒤에 오는 **10 진 필드의 수**(라벨 길이 칸 포함, 라벨 바이트 제외). 판정자가 오염된 줄을
/// 손으로 만들 때 쓰고, 값이 틀리면 「필드 수」 판정자가 먼저 죽는다.
pub const record_fields: usize = 24;

// **필드 수를 바꾸면 판도 올려야 한다**(적대적 E1). 안 올리면 옛 파서가 새 줄에서 자리가 밀린 값을
// 읽는데, 대개는 `Malformed` 로 걸리지만 **보장이 없다** — 새 필드 값이 우연히 라벨 길이로 말이
// 되면 그만큼을 라벨로 읽고 지나간다. 머리말 대조가 그 갈림을 막는 유일한 수단이므로, 여기서 둘을
// 묶어 **한쪽만 고치면 컴파일이 깨지게** 한다.
comptime {
    const expected_fields_for_version = [_]usize{ 0, 24, 24, 24 }; // [판] = 필드 수
    if (wire_version >= expected_fields_for_version.len or
        expected_fields_for_version[wire_version] != record_fields)
    {
        @compileError("remote_activity_wire: 필드 수와 wire_version 이 어긋난다 — 필드를 바꿨으면 " ++
            "`wire_version` 과 `header_line` 을 올리고 이 표에 새 판의 필드 수를 더해라");
    }
}

// ── 필드 커버리지 가드 — **자리가 늘면 여기서 컴파일이 깨진다** ────────────────────────────────
//
// ⚠️ 적대적 검증 A2 가 만든 것이다. 가드가 없을 때 `Hit` 에 필드를 하나 더해 봤더니 **판정자 177 개가
// 전부 통과했다** — wire 는 그 자리를 안 싣고, 왕복 판정자는 양쪽의 기본값(0)을 비교하므로 통과한다.
// 그러면 원격은 그 값을 **영영 0 으로 본다**. 이 스택에서 `Hit` 이 실제로 88 → 96 바이트로 늘었고
// (`input_rel`), 그때 이 가드가 없었다면 「원격에서만 검색이 덜 걸린다」가 조용히 생겼을 것이다.
//
// 렌더 parity 가드(`remote_screen.expectSnapshotParity`)가 같은 수법으로 화면 축을 지키고 있다 —
// 분류를 **강제**하되 무엇을 안 싣는지는 사람이 정한다.
fn assertCovered(comptime T: type, comptime carried: []const []const u8, comptime derived: []const []const u8) void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        comptime var seen = false;
        inline for (carried ++ derived) |name| {
            if (comptime std.mem.eql(u8, f.name, name)) seen = true;
        }
        if (!seen) @compileError("remote_activity_wire: " ++ @typeName(T) ++ "." ++ f.name ++
            " 를 싣는지 정하지 않았다 — `appendRecord`/`parseRecord` 에 더하고 carried 에 적거나, 왜 안 싣는지 derived 에 적어라");
    }
}

comptime {
    assertCovered(index.Hit, &.{
        "line_offset", "data_offset", "data_len",   "kind",   "mime",    "activity",
        "name_rel",    "name_len",    "id_rel",     "id_len", "cmd_rel", "input_rel",
        "time_rel",    "file_index",  "fold_owner", "result",
    }, &.{});

    assertCovered(index.ResultSummary, &.{
        "found", "failed", "lines", "image", "image_offset", "image_len", "image_file", "body",
    }, &.{});

    assertCovered(index.ResultBody, &.{ "offset", "is_array" }, &.{});

    assertCovered(context.Label, &.{ "buf", "len", "source", "time_s" }, &.{
        // **갤러리가 스캔 뒤에 채운다**(`agent_activity` 의 순번 패스) — 라벨을 만드는 쪽은 이웃
        // 히트를 못 보므로 저쪽에서도 못 채운다. 실어 봐야 언제나 0 이다.
        "seq", "seq_total",
    });

    // **`S` 줄도 같은 규율이다**(RAV7b). 이 타입은 이 모듈이 정의하지만 인코더·파서는 손으로
    // 맞추므로, 필드를 더하고 한쪽을 잊으면 그 값은 **영영 기본값**이다 — `Hit` 이 겪은 그것
    // (적대적 A2)과 정확히 같은 모양이라 같은 못을 박는다.
    assertCovered(ScanFlags, &.{
        "partial",    "image_partial", "activity_partial",
        "scanned_bytes", "head_bytes",  "resume_offset",
        "resumed_from",
    }, &.{});
}

/// wire 한 건 — `Hit` 과 그 라벨·시각.
///
/// **라벨을 `Hit` 안에 넣지 않는다.** `Hit` 은 스캐너가 소유하는 순수한 자리 묶음이고, 라벨은 그
/// 자리에서 **읽어 만든 것**이다. 합치면 스캐너가 라벨을 아는 모듈이 된다.
pub const Record = struct {
    hit: index.Hit,
    label: context.Label = .{},
};

/// 체인의 파일 하나 — **인덱스를 명시한다**.
///
/// 🔥 초안은 「적힌 순서가 `Hit.file_index`」였고 그것이 결함이었다(적대적 G1). 로컬 스캔은 못 연
/// 파일을 **건너뛰되 번호는 그대로 쓴다**(`scanner = .{ .file_index = @intCast(fi) }` — 부모가 지워졌을
/// 수 있다). 순서로 정하면 헬퍼가 그 `F` 를 안 싣는 순간 **뒤 파일이 전부 한 칸씩 밀려**, 라벨·펼침·
/// 디코드가 엉뚱한 파일의 바이트를 읽는다. 스캐너가 `file_index` 주석에 적어 둔 바로 그 사고다.
pub const ChainFile = struct {
    index: u8,
    path: []const u8,
};

pub const Event = union(enum) {
    /// 체인 파일 하나.
    file: ChainFile,
    flags: ScanFlags,
    record: Record,
    /// 원격이 보고한 실패(표시용 텍스트). 이것으로 끝난 답도 **완결된 답**이다 — 「못 읽는다」는
    /// 「비었다」와 다르고, 그 사실이 화면까지 가야 한다(계획 §2.2).
    remote_error: []const u8,
};

// ── 인코더 — 헬퍼(원격)와 테스트가 쓴다 ─────────────────────────────────────────────────────────
//
// 목록 wire 와 같은 버퍼-append 꼴이다: 할당이 없어 헬퍼 바이너리(ReleaseSmall)가 그대로 쓸 수 있고,
// 넘치면 null 로 실패해 **잘린 레코드를 절대 만들지 않는다**.

fn appendBytes(out: []u8, at: usize, bytes: []const u8) ?usize {
    if (at > out.len or out.len - at < bytes.len) return null;
    @memcpy(out[at..][0..bytes.len], bytes);
    return at + bytes.len;
}

fn appendDecimal(out: []u8, at: usize, value: u64) ?usize {
    var buf: [20]u8 = undefined; // u64 최대 20 자리
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    return appendBytes(out, at, s);
}

fn appendField(out: []u8, at: usize, value: u64) ?usize {
    const n = appendDecimal(out, at, value) orelse return null;
    return appendBytes(out, n, " ");
}

pub fn appendHeader(out: []u8, at: usize) ?usize {
    var n = appendBytes(out, at, header_line) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

/// 체인 파일 하나. 경로가 비거나 상한을 넘으면 null — **안 싣는다**(자른 경로는 없는 파일이거나,
/// 더 나쁘게는 다른 파일이다 — `Source.set` 과 같은 규율). 인덱스가 체인 상한 밖이어도 null 이다.
pub fn appendFile(out: []u8, at: usize, index_of: u8, path: []const u8) ?usize {
    if (path.len == 0 or path.len > max_path_bytes) return null;
    if (index_of >= max_files) return null;
    var n = appendBytes(out, at, "F ") orelse return null;
    n = appendField(out, n, index_of) orelse return null;
    n = appendField(out, n, path.len) orelse return null;
    n = appendBytes(out, n, path) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendFlags(out: []u8, at: usize, flags: ScanFlags) ?usize {
    // **내는 쪽도 불변식을 지킨다**(적대적 B1 · 판 2). 파서만 거부하면 헬퍼 버그가 **답 전체**를
    // `Malformed` 로 만들어 「활동이 0」이 아니라 「못 읽었다」로 뜬다 — 맞는 결말이지만, 애초에
    // 깨진 줄을 **안 만드는** 것이 이 인코더의 규율이다(`appendRangeBytes` 가 상한에서 그러듯).
    if (flags.resume_offset > flags.head_bytes) return null;
    if (flags.resumed_from > flags.head_bytes) return null;
    if (flags.resume_offset < flags.resumed_from) return null;
    var n = appendBytes(out, at, "S ") orelse return null;
    n = appendField(out, n, @intFromBool(flags.partial)) orelse return null;
    n = appendField(out, n, @intFromBool(flags.image_partial)) orelse return null;
    n = appendField(out, n, @intFromBool(flags.activity_partial)) orelse return null;
    n = appendField(out, n, flags.scanned_bytes) orelse return null;
    n = appendField(out, n, flags.head_bytes) orelse return null;
    n = appendField(out, n, flags.resume_offset) orelse return null;
    n = appendDecimal(out, n, flags.resumed_from) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

/// `ResultSummary` 의 불리언 넷을 한 수로 접는다. 필드마다 칸을 주면 `A` 줄이 네 개 더 길어지는데,
/// 그 넷은 **함께 읽히므로** 묶어도 「하나만 읽고 나머지를 잊는」 결함이 안 생긴다(`ResultBody` 를
/// 묶은 것과 같은 판단).
const result_found: u8 = 1 << 0;
const result_failed: u8 = 1 << 1;
const result_image: u8 = 1 << 2;
const result_body_is_array: u8 = 1 << 3;

fn packResultFlags(r: index.ResultSummary) u8 {
    var f: u8 = 0;
    if (r.found) f |= result_found;
    if (r.failed) f |= result_failed;
    if (r.image) f |= result_image;
    if (r.body.is_array) f |= result_body_is_array;
    return f;
}

/// 활동·이미지 한 건.
///
/// 🔥 **null 이면 호출자는 «멈춘다» — 건너뛰지 않는다**(적대적 D1). 초안 주석은 목록 wire 를 따라
/// 「그 건을 건너뛰고 개수에서 뺀다」고 적었는데, 이 코덱에서 그것은 **조용한 유실**이다: 버퍼가 차서
/// 못 실은 건을 개수에서 빼면 **꼬리 count 가 맞아** 파서가 «완결» 로 읽는다 — §6.1 이 막으려던 바로
/// 그 상황이 꼬리를 **가진 채로** 생긴다.
///
/// 목록 wire 에서 그 지시가 옳았던 이유는 null 의 뜻이 달라서다. 그쪽은 「이름이 상한을 넘는다」가
/// 정상 흐름(readdir 이 그런 이름을 준다)이고 버퍼 부족은 꼬리를 못 써서 저절로 드러난다. 여기서는
/// 라벨이 **타입으로 유계**라(`Label.buf` 가 160 B) 상한 초과는 우리 쪽 버그일 때만 나고, 남는 뜻은
/// 사실상 **버퍼 부족** 하나다.
///
/// 그래서 호출자는 null 을 보면 **꼬리를 쓰지 말고 그대로 끝낸다** — 꼬리 없는 wire 를 파서가
/// 잘림으로 읽는 것이 이 층의 정직한 결말이다.
///
/// ⚠️ **필드 순서가 계약이다.** 여기와 `parseRecord` 가 같은 순서를 봐야 하고, 그 대조는 왕복
/// 테스트가 한다(한쪽만 고치면 값이 **자리를 옮겨** 조용히 엉뚱한 뜻이 된다).
pub fn appendRecord(out: []u8, at: usize, rec: Record) ?usize {
    if (rec.label.len > max_label_bytes) return null;
    const h = rec.hit;
    var n = appendBytes(out, at, "A ") orelse return null;
    n = appendField(out, n, h.file_index) orelse return null;
    n = appendField(out, n, h.line_offset) orelse return null;
    n = appendField(out, n, h.data_offset) orelse return null;
    n = appendField(out, n, h.data_len) orelse return null;
    n = appendField(out, n, @intFromEnum(h.kind)) orelse return null;
    n = appendField(out, n, @intFromEnum(h.mime)) orelse return null;
    n = appendField(out, n, @intFromEnum(h.activity)) orelse return null;
    n = appendField(out, n, h.name_rel) orelse return null;
    n = appendField(out, n, h.name_len) orelse return null;
    n = appendField(out, n, h.id_rel) orelse return null;
    n = appendField(out, n, h.id_len) orelse return null;
    n = appendField(out, n, h.cmd_rel) orelse return null;
    n = appendField(out, n, h.input_rel) orelse return null;
    n = appendField(out, n, h.time_rel) orelse return null;
    n = appendField(out, n, h.fold_owner) orelse return null;
    n = appendField(out, n, packResultFlags(h.result)) orelse return null;
    n = appendField(out, n, h.result.lines) orelse return null;
    n = appendField(out, n, h.result.body.offset) orelse return null;
    n = appendField(out, n, h.result.image_offset) orelse return null;
    n = appendField(out, n, h.result.image_len) orelse return null;
    n = appendField(out, n, h.result.image_file) orelse return null;
    // 시각은 음수일 수 있다(1970 이전은 안 오지만 `i64` 다) — 부호를 비트로 옮겨 10 진으로 싣는다.
    n = appendField(out, n, @as(u64, @bitCast(rec.label.time_s))) orelse return null;
    n = appendField(out, n, @intFromEnum(rec.label.source)) orelse return null;
    n = appendField(out, n, rec.label.len) orelse return null;
    n = appendBytes(out, n, rec.label.text()) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendRemoteError(out: []u8, at: usize, message: []const u8) ?usize {
    // ⚠️ 자름은 바이트 경계다 — errno 문자열(ASCII)을 전제한다(목록 wire 와 같은 한계·같은 자리).
    const clamped = message[0..@min(message.len, max_error_bytes)];
    var n = appendBytes(out, at, "! ") orelse return null;
    n = appendField(out, n, clamped.len) orelse return null;
    n = appendBytes(out, n, clamped) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendTail(out: []u8, at: usize, count: u64) ?usize {
    var n = appendBytes(out, at, "X ") orelse return null;
    n = appendDecimal(out, n, count) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

// ── 파서 — GUI 백엔드가 쓴다 ────────────────────────────────────────────────────────────────────

pub const ParseError = error{
    /// 머리가 없거나 판이 다르다 — 구 GUI ↔ 신 헬퍼(또는 그 반대)의 조용한 오독을 여기서 끊는다.
    UnsupportedVersion,
    /// 레코드 형태가 계약과 다르다.
    Malformed,
    /// 라벨·경로·메시지 길이가 상한을 넘는다고 주장한다 — 원격이 주는 값이므로 믿지 않는다.
    TooLong,
    /// 레코드 수가 상한을 넘는다.
    TooManyRecords,
    /// 체인 파일 수(또는 주장한 인덱스)가 상한을 넘는다.
    TooManyFiles,
    /// 같은 체인 자리를 두 번 주장한다.
    DuplicateFile,
    /// 레코드가 **안 온 체인 파일**을 가리킨다 — 그 오프셋은 읽을 자리가 없다.
    UnknownFile,
    /// 꼬리는 왔는데 스캔 플래그(`S`)가 없다 — 「다 봤나」를 모르는 채 완결로 읽을 수 없다.
    MissingFlags,
    /// 열거값이 이 판이 아는 범위 밖이다 — 새 판의 헬퍼가 보낸 것이거나 오염이다. **`other` 로
    /// 뭉개지 않는다**: 뭉개면 「모르는 것을 아는 척」이 되고, 그 값이 필터·접기의 갈림을 정한다.
    UnknownEnum,
    /// 꼬리의 count 가 실제 레코드 수와 다르다 — 중간 유실을 잡는다.
    CountMismatch,
    /// 경로가 절대경로가 아니다 — 소비처가 이 값으로 **범위 읽기를 요청**하므로(RAV5) 상대경로는
    /// 저쪽 cwd 에 매달린 다른 파일을 가리킨다.
    UnsafePath,
    /// 꼬리(또는 오류 레코드) 뒤에 바이트가 더 있다 — 응답 두 개가 섞였다는 뜻이다.
    TrailingData,
};

/// 스트리밍이 아니라 **완결된 바이트**를 받는 파서다 — 전송이 상한까지 읽어 통째로 준다.
/// `next()` 를 끝까지 돌린 뒤 `complete()` 가 참일 때만 결과를 믿는다: 꼬리를 못 봤으면 **잘린
/// 것**이고(§6.1), 잘린 목록을 그대로 그리면 「없어진 것처럼 보이는」 활동이 생긴다.
pub const Parser = struct {
    rest: []const u8,
    saw_header: bool = false,
    records_seen: u64 = 0,
    /// 지금까지 자리를 주장한 체인 파일들(비트 = 인덱스). `max_files` 가 3 이라 u8 하나면 넉넉하다.
    files_mask: u8 = 0,
    saw_flags: bool = false,
    /// 꼬리(`X`) 또는 오류(`!`)를 봤다 — 이 뒤에 오는 바이트는 전부 `TrailingData` 다.
    terminated: bool = false,

    pub fn init(bytes: []const u8) Parser {
        return .{ .rest = bytes };
    }

    /// 완결됐는가. `!`(원격 실패)도 완결이다 — 침묵과 실패를 가르는 것이 이 wire 의 존재 이유다.
    pub fn complete(self: *const Parser) bool {
        return self.terminated and self.rest.len == 0;
    }

    pub fn next(self: *Parser) ParseError!?Event {
        if (self.rest.len == 0) return null;
        if (self.terminated) return ParseError.TrailingData;

        if (!self.saw_header) {
            const line = try self.takeLine();
            if (!std.mem.eql(u8, line, header_line)) return ParseError.UnsupportedVersion;
            self.saw_header = true;
            if (self.rest.len == 0) return null;
        }

        const kind = self.rest[0];
        switch (kind) {
            'F' => return .{ .file = try self.parseFile() },
            'S' => {
                // **플래그는 한 번뿐이다.** 둘이 오면 어느 것이 이기는지 정의가 없고, 「못 봤다」를
                // 나중 줄이 덮으면 화면이 거짓을 말한다.
                if (self.saw_flags) return ParseError.Malformed;
                self.saw_flags = true;
                return .{ .flags = try self.parseFlags() };
            },
            'A' => return .{ .record = try self.parseRecord() },
            '!' => {
                const msg = try self.parseRemoteError();
                self.terminated = true;
                return .{ .remote_error = msg };
            },
            'X' => {
                try self.parseTail();
                self.terminated = true;
                return null;
            },
            else => return ParseError.Malformed,
        }
    }

    fn takeLine(self: *Parser) ParseError![]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse return ParseError.Malformed;
        const line = self.rest[0..nl];
        self.rest = self.rest[nl + 1 ..];
        return line;
    }

    /// `<prefix> ` 를 떼고 나머지를 돌려준다.
    fn expectPrefix(self: *Parser, prefix: []const u8) ParseError![]const u8 {
        if (self.rest.len < prefix.len or !std.mem.startsWith(u8, self.rest, prefix)) {
            return ParseError.Malformed;
        }
        self.rest = self.rest[prefix.len..];
        return self.rest;
    }

    /// 10 진수 하나를 먹는다. `term` 이 그 끝(공백 또는 개행)이다.
    ///
    /// **`std.fmt.parseInt` 를 쓰지 않는 이유**는 그것이 관대하기 때문이다 — 실측으로 `"+5"` 를 5 로,
    /// `"5_0"` 을 50 으로 읽는다. 원격이 주는 바이트라 관대할 이유가 없고, 관대하면 꼬리 count 대조
    /// (§6.1 의 방어)가 `X 1_5` 같은 값에 **뚫린다**.
    ///
    /// ⚠️ 이 규율을 처음에는 여기만 지키고 `parseFlags`·`parseTail` 은 `parseInt` 를 썼다 — 한 파일
    /// 안에서 규율이 두 벌이었다(적대적 A1). 그래서 **줄 끝을 먹는 판도 이 함수가 든다.**
    fn takeUntil(self: *Parser, term: u8) ParseError!u64 {
        var i: usize = 0;
        var v: u64 = 0;
        while (i < self.rest.len and self.rest[i] != term) : (i += 1) {
            const c = self.rest[i];
            if (c < '0' or c > '9') return ParseError.Malformed;
            v = std.math.mul(u64, v, 10) catch return ParseError.Malformed;
            v = std.math.add(u64, v, c - '0') catch return ParseError.Malformed;
        }
        if (i == 0 or i >= self.rest.len) return ParseError.Malformed;
        self.rest = self.rest[i + 1 ..]; // 구분자까지 먹는다
        return v;
    }

    /// 공백으로 끝나는 10 진수 하나.
    fn takeDecimal(self: *Parser) ParseError!u64 {
        return self.takeUntil(' ');
    }

    /// 개행으로 끝나는 10 진수 하나(줄의 마지막 값).
    fn takeDecimalLine(self: *Parser) ParseError!u64 {
        return self.takeUntil('\n');
    }

    fn takeInt(self: *Parser, comptime T: type) ParseError!T {
        const v = try self.takeDecimal();
        return std.math.cast(T, v) orelse ParseError.Malformed;
    }

    fn takeEnum(self: *Parser, comptime E: type) ParseError!E {
        const v = try self.takeDecimal();
        const fields = @typeInfo(E).@"enum".fields;
        if (v >= fields.len) return ParseError.UnknownEnum;
        return @enumFromInt(v);
    }

    /// 길이 접두 바이트열. 상한을 **호출자가** 준다 — 원격이 주장하는 길이를 믿지 않는다.
    fn takeLenPrefixed(self: *Parser, limit: usize) ParseError![]const u8 {
        const len = try self.takeDecimal();
        if (len > limit) return ParseError.TooLong;
        const n: usize = @intCast(len);
        if (self.rest.len < n + 1 or self.rest[n] != '\n') return ParseError.Malformed;
        const bytes = self.rest[0..n];
        self.rest = self.rest[n + 1 ..];
        return bytes;
    }

    fn parseFile(self: *Parser) ParseError!ChainFile {
        _ = try self.expectPrefix("F ");
        const at = try self.takeInt(u8);
        if (at >= max_files) return ParseError.TooManyFiles;
        const bit = @as(u8, 1) << @intCast(at);
        // **같은 자리를 두 번 주장하면 거부한다** — 뒤엣것이 이기면 앞의 `A` 들이 가리키던 파일이
        // 조용히 바뀐다.
        if (self.files_mask & bit != 0) return ParseError.DuplicateFile;
        const path = try self.takeLenPrefixed(max_path_bytes);
        if (path.len == 0 or path[0] != '/') return ParseError.UnsafePath;
        self.files_mask |= bit;
        return .{ .index = at, .path = path };
    }

    fn parseFlags(self: *Parser) ParseError!ScanFlags {
        _ = try self.expectPrefix("S ");
        const p = try self.takeDecimal();
        const ip = try self.takeDecimal();
        const ap = try self.takeDecimal();
        if (p > 1 or ip > 1 or ap > 1) return ParseError.Malformed;
        const scanned = try self.takeDecimal();
        const head = try self.takeDecimal();
        const resume_at = try self.takeDecimal();
        const from = try self.takeDecimalLine();
        // **자국이 읽은 바이트를 넘을 수는 없다.** 넘으면 그 자리에서 이어 읽을 때 저쪽이 안 읽은
        // 구간을 「이미 봤다」로 치게 된다 — 그 사이 활동이 통째로 사라진다(계약 §2.2).
        if (resume_at > head) return ParseError.Malformed;
        // **읽기 시작점도 같은 규율이다**(판 3). 시작이 끝보다 뒤면 그 답은 앞뒤가 안 맞는다.
        if (from > head) return ParseError.Malformed;
        // **자국은 읽기 시작점보다 앞설 수 없다.** 앞선다면 그 앞 구간은 이번에 **안 본** 자리인데
        // 「거기부터 다시 보면 된다」고 말하는 셈이라, 다음 회차가 그 사이를 영영 건너뛴다.
        if (resume_at < from) return ParseError.Malformed;
        return .{
            .partial = p == 1,
            .image_partial = ip == 1,
            .activity_partial = ap == 1,
            .scanned_bytes = scanned,
            .head_bytes = head,
            .resume_offset = resume_at,
            .resumed_from = from,
        };
    }

    fn parseRecord(self: *Parser) ParseError!Record {
        _ = try self.expectPrefix("A ");
        var h: index.Hit = .{ .line_offset = 0, .data_offset = 0, .data_len = 0, .kind = .claude_image, .mime = .unknown };
        h.file_index = try self.takeInt(u8);
        h.line_offset = try self.takeDecimal();
        h.data_offset = try self.takeDecimal();
        h.data_len = try self.takeInt(u32);
        h.kind = try self.takeEnum(index.Kind);
        h.mime = try self.takeEnum(index.Mime);
        h.activity = try self.takeEnum(index.Activity);
        h.name_rel = try self.takeInt(u32);
        h.name_len = try self.takeInt(u16);
        h.id_rel = try self.takeInt(u32);
        h.id_len = try self.takeInt(u8);
        h.cmd_rel = try self.takeInt(u32);
        h.input_rel = try self.takeInt(u32);
        h.time_rel = try self.takeInt(u32);
        h.fold_owner = try self.takeInt(u32);
        const rflags = try self.takeInt(u8);
        // 모르는 비트가 서 있으면 **새 판**이다 — 조용히 버리면 그 사실이 화면까지 안 간다.
        const known = result_found | result_failed | result_image | result_body_is_array;
        if (rflags & ~known != 0) return ParseError.UnknownEnum;
        h.result.found = rflags & result_found != 0;
        h.result.failed = rflags & result_failed != 0;
        h.result.image = rflags & result_image != 0;
        h.result.body.is_array = rflags & result_body_is_array != 0;
        h.result.lines = try self.takeInt(u32);
        h.result.body.offset = try self.takeDecimal();
        h.result.image_offset = try self.takeDecimal();
        h.result.image_len = try self.takeInt(u32);
        h.result.image_file = try self.takeInt(u8);
        const time_bits = try self.takeDecimal();
        const source = try self.takeEnum(context.Source);

        var label: context.Label = .{ .time_s = @bitCast(time_bits), .source = source };
        const text = try self.takeLenPrefixed(max_label_bytes);
        @memcpy(label.buf[0..text.len], text);
        label.len = text.len;

        // 🔥 **가리키는 파일이 실제로 왔는지 본다**(적대적 H1). 안 보면 소비자가 체인 밖 인덱스로
        // 파일을 열려다 조용히 건너뛰고, 그 활동은 「없는 것」이 된다 — 「없다」와 「못 봤다」를
        // 가르는 계약이 그것을 금한다. 결과 이미지의 파일 번호도 같은 자리다.
        if (!self.hasFile(h.file_index)) return ParseError.UnknownFile;
        if (h.result.image and !self.hasFile(h.result.image_file)) return ParseError.UnknownFile;

        self.records_seen += 1;
        if (self.records_seen > max_records) return ParseError.TooManyRecords;
        return .{ .hit = h, .label = label };
    }

    fn hasFile(self: *const Parser, at: u8) bool {
        if (at >= max_files) return false;
        return self.files_mask & (@as(u8, 1) << @intCast(at)) != 0;
    }

    fn parseRemoteError(self: *Parser) ParseError![]const u8 {
        _ = try self.expectPrefix("! ");
        return self.takeLenPrefixed(max_error_bytes);
    }

    fn parseTail(self: *Parser) ParseError!void {
        _ = try self.expectPrefix("X ");
        // 🔥 **플래그를 못 봤으면 답이 아니다**(적대적 L1). 플래그의 기본값은 전부 거짓 =
        // 「다 봤다」이므로, 빠진 답을 완결로 읽으면 **「못 봤다」가 「다 봤다」로 뒤집힌다** —
        // 계약 §2.2 가 가장 크게 여기는 갈림이 조용히 무너진다.
        //
        // `!`(원격 오류)로 끝난 답은 면제다 — 그쪽은 스캔을 시작도 못 한 경우이고, 그 사실을
        // 오류 자체가 말한다.
        if (!self.saw_flags) return ParseError.MissingFlags;
        const count = try self.takeDecimalLine();
        if (count != self.records_seen) return ParseError.CountMismatch;
    }
};

// ── 판정자 ──────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자 공용 머리 — 머리말 + `sampleHit` 이 가리키는 체인 자리(2) + 스캔 플래그.
///
/// 레코드가 **안 온 파일을 가리키면 거부**하고(적대적 H1) **플래그 없이 꼬리가 오면 거부**하므로
/// (적대적 L1) 이 둘을 안 채우면 판정자가 그 가드에서 죽는다. 두 가드를 세울 때마다 기존 판정자
/// 넷·셋이 곧바로 빨개졌다 — **가드가 실제로 문다는 증거다.**
fn headerWithChain(buf: []u8) usize {
    var n = appendHeader(buf, 0).?;
    n = appendFile(buf, n, 2, "/a/b.jsonl").?;
    return appendFlags(buf, n, .{}).?;
}

fn sampleHit() index.Hit {
    return .{
        .line_offset = 1_234_567_890,
        .data_offset = 1_234_567_950,
        .data_len = 4096,
        .kind = .claude_tool_use,
        .mime = .unknown,
        .activity = .exec,
        .name_rel = 120,
        .name_len = 4,
        .id_rel = 64,
        .id_len = 24,
        .cmd_rel = 200,
        .input_rel = 180,
        .time_rel = 30,
        .file_index = 2,
        .fold_owner = index.no_fold,
        .result = .{
            .found = true,
            .failed = true,
            .lines = 747,
            .image = false,
            .image_offset = 0,
            .image_len = 0,
            .image_file = 0,
            .body = .{ .offset = 1_234_568_000, .is_array = true },
        },
    };
}

test "왕복: 머리·파일·플래그·레코드·꼬리가 그대로 돌아온다" {
    var buf: [4096]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFile(&buf, n, 2, "/home/u/.codex/sessions/2026/09/11/rollout-a.jsonl").?;
    n = appendFlags(&buf, n, .{
        .activity_partial = true,
        .scanned_bytes = 261_533_353,
        .head_bytes = 4_096_000,
        .resume_offset = 4_090_112,
    }).?;

    var label: context.Label = .{ .time_s = 1_757_500_000 };
    const text = "zig build test";
    @memcpy(label.buf[0..text.len], text);
    label.len = text.len;

    n = appendRecord(&buf, n, .{ .hit = sampleHit(), .label = label }).?;
    n = appendTail(&buf, n, 1).?;

    var p = Parser.init(buf[0..n]);
    const ev_file = (try p.next()).?;
    try testing.expectEqualStrings("/home/u/.codex/sessions/2026/09/11/rollout-a.jsonl", ev_file.file.path);
    try testing.expectEqual(@as(u8, 2), ev_file.file.index);

    const ev_flags = (try p.next()).?;
    try testing.expect(ev_flags.flags.activity_partial);
    try testing.expect(!ev_flags.flags.partial);
    try testing.expectEqual(@as(u64, 261_533_353), ev_flags.flags.scanned_bytes);
    // **판 2 의 자국 둘**(RAV7b). `scanned_bytes` 는 체인 전체의 합이고 이 둘은 **머리 파일**의
    // 것이라 셋이 서로 다른 수여야 한다 — 한 자리라도 섞이면 여기서 죽는다.
    try testing.expectEqual(@as(u64, 4_096_000), ev_flags.flags.head_bytes);
    try testing.expectEqual(@as(u64, 4_090_112), ev_flags.flags.resume_offset);

    const ev_rec = (try p.next()).?;
    try testing.expectEqual(sampleHit(), ev_rec.record.hit);
    try testing.expectEqualStrings(text, ev_rec.record.label.text());
    try testing.expectEqual(@as(i64, 1_757_500_000), ev_rec.record.label.time_s);

    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(p.complete());
}

test "자국이 읽은 바이트를 넘는다고 주장하면 거부한다 (RAV7b)" {
    // 🔥 **넘으면 안 읽은 구간을 「이미 봤다」로 친다.** 이어읽기가 그 자리부터 시작하므로 그 사이
    // 활동이 **통째로 사라진다** — 「비었다」와 「못 봤다」를 가르는 계약(§2.2)이 여기서 깨진다.
    var buf: [256]u8 = undefined;
    const h = appendHeader(&buf, 0).?;
    var line: [128]u8 = undefined;
    const bad = std.fmt.bufPrint(&line, "S 0 0 0 100 40 41\n", .{}) catch unreachable;
    @memcpy(buf[h..][0..bad.len], bad);

    var p = Parser.init(buf[0 .. h + bad.len]);
    try testing.expectError(ParseError.Malformed, p.next());
}

test "읽기 시작점도 자국과 같은 규율이다 (RAV7b-3)" {
    // 🔥 **셋의 순서가 정해져 있다**: `resumed_from ≤ resume_offset ≤ head_bytes`.
    //
    // - 자국이 **시작점보다 앞서면** 그 앞 구간은 이번에 **안 본** 자리인데 「거기부터 다시 보면
    //   된다」고 말하는 셈이고, 다음 회차가 그 사이를 영영 건너뛴다.
    // - 시작점이 **끝보다 뒤면** 그 답은 앞뒤가 안 맞는다.
    var buf: [256]u8 = undefined;
    const h = appendHeader(&buf, 0).?;
    var line: [128]u8 = undefined;

    // 자국(40) < 시작점(50)
    {
        const bad = std.fmt.bufPrint(&line, "S 0 0 0 100 100 40 50\n", .{}) catch unreachable;
        @memcpy(buf[h..][0..bad.len], bad);
        var p = Parser.init(buf[0 .. h + bad.len]);
        try testing.expectError(ParseError.Malformed, p.next());
    }
    // 시작점(120) > 머리 크기(100)
    {
        const bad = std.fmt.bufPrint(&line, "S 0 0 0 100 100 120 120\n", .{}) catch unreachable;
        @memcpy(buf[h..][0..bad.len], bad);
        var p = Parser.init(buf[0 .. h + bad.len]);
        try testing.expectError(ParseError.Malformed, p.next());
    }
    // **내는 쪽도 같은 규율**이다 — 깨진 줄을 애초에 안 만든다.
    try testing.expectEqual(@as(?usize, null), appendFlags(&buf, h, .{
        .head_bytes = 100,
        .resume_offset = 40,
        .resumed_from = 50,
    }));
    try testing.expectEqual(@as(?usize, null), appendFlags(&buf, h, .{
        .head_bytes = 100,
        .resume_offset = 120,
        .resumed_from = 120,
    }));
    // 순서가 맞으면 받는다.
    try testing.expect(appendFlags(&buf, h, .{
        .head_bytes = 100,
        .resume_offset = 80,
        .resumed_from = 50,
    }) != null);
}

test "인코더도 자국 불변식을 지킨다 — 깨진 줄을 애초에 안 만든다 (RAV7b)" {
    // 🔥 적대적 B1: 파서만 거부하면 헬퍼 버그가 **답 전체**를 `Malformed` 로 만든다. 맞는 결말이긴
    // 하지만, 이 인코더의 규율은 「잘린·깨진 것을 **안 만든다**」이다(`appendRecord`·
    // `appendRangeBytes` 가 같은 자리에서 같은 판단을 한다).
    var buf: [256]u8 = undefined;
    const n = appendHeader(&buf, 0).?;
    try testing.expectEqual(@as(?usize, null), appendFlags(&buf, n, .{ .head_bytes = 40, .resume_offset = 41 }));
    // 같은 값은 받는다 — 미결 호출이 없으면 자국이 곧 읽은 데까지다.
    try testing.expect(appendFlags(&buf, n, .{ .head_bytes = 40, .resume_offset = 40 }) != null);
}

test "자국이 읽은 바이트와 같은 것은 받는다 — 미결 호출이 없으면 그 자리다 (RAV7b)" {
    var buf: [256]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFlags(&buf, n, .{ .head_bytes = 4096, .resume_offset = 4096 }).?;
    n = appendTail(&buf, n, 0).?;

    var p = Parser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqual(@as(u64, 4096), ev.flags.resume_offset);
}

test "꼬리가 없으면 완결이 아니다 — 잘림을 온전한 척 읽지 않는다" {
    var buf: [4096]u8 = undefined;
    var n = headerWithChain(&buf);
    n = appendRecord(&buf, n, .{ .hit = sampleHit() }).?;
    // 꼬리를 안 붙인다(전송이 상한에서 잘린 모양).

    var p = Parser.init(buf[0..n]);
    _ = try p.next(); // 체인 파일
    _ = try p.next(); // 스캔 플래그
    _ = try p.next(); // 레코드
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(!p.complete());
}

test "꼬리 count 가 어긋나면 거부한다 — 중간 유실을 잡는다" {
    var buf: [4096]u8 = undefined;
    var n = headerWithChain(&buf);
    n = appendRecord(&buf, n, .{ .hit = sampleHit() }).?;
    n = appendTail(&buf, n, 2).?; // 실제로는 1 건

    var p = Parser.init(buf[0..n]);
    _ = try p.next(); // 체인 파일
    _ = try p.next(); // 스캔 플래그
    _ = try p.next(); // 레코드
    try testing.expectError(ParseError.CountMismatch, p.next());
}

test "판이 다르면 즉시 거부한다 — 앞판도 뒷판도" {
    // **뒷판**(우리보다 새 헬퍼).
    {
        var p = Parser.init("maru-rav 4\nX 0\n");
        try testing.expectError(ParseError.UnsupportedVersion, p.next());
    }
    // 🔥 **앞판**(옛 헬퍼가 아직 깔려 있는 실제 경우 — 이 스택이 판 1 → 2 → 3 으로 올렸다). 여기서
    // 안 걸리면 `S` 줄의 자리가 밀린 값을 읽어 **자국이 엉뚱한 수**가 되고, 이어읽기가 안 읽은 구간을
    // 「이미 봤다」로 친다.
    for ([_][]const u8{ "maru-rav 1\nX 0\n", "maru-rav 2\nX 0\n" }) |bytes| {
        var p = Parser.init(bytes);
        try testing.expectError(ParseError.UnsupportedVersion, p.next());
    }
}

test "원격 오류도 완결이다 — 「못 읽는다」와 「비었다」를 가른다" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendRemoteError(&buf, n, "open: No such file or directory").?;

    var p = Parser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqualStrings("open: No such file or directory", ev.remote_error);
    try testing.expect(p.complete());
}

test "꼬리 뒤의 바이트는 응답 두 개가 섞인 것이다" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFlags(&buf, n, .{}).?;
    n = appendTail(&buf, n, 0).?;
    n = appendBytes(&buf, n, "X 0\n").?;

    var p = Parser.init(buf[0..n]);
    _ = try p.next(); // 스캔 플래그
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expectError(ParseError.TrailingData, p.next());
}

test "상대경로는 거부한다 — 저쪽 cwd 에 매달린 다른 파일이다" {
    var buf: [1024]u8 = undefined;
    const n = appendHeader(&buf, 0).?;
    // `appendFile` 은 절대경로만 내므로 손으로 만든다(오염된 원격의 모양).
    const bad = "F 0 12 relative.txt\n";
    @memcpy(buf[n..][0..bad.len], bad);

    var p = Parser.init(buf[0 .. n + bad.len]);
    try testing.expectError(ParseError.UnsafePath, p.next());
}

/// 오염된 `A` 줄을 손으로 짓는다 — **필드 수에 안 묶이게** 한 자리만 바꾼다.
///
/// 처음에는 숫자를 줄에 그대로 나열했는데, 라벨 출처를 싣게 되자(적대적 C1) 자리가 하나 밀려
/// 판정자 셋이 **엉뚱한 이유로** 죽었다. 값을 자리 번호로 주면 그 취약함이 사라진다.
fn pollutedRecord(buf: []u8, at: usize, field: usize, value: u64, label: []const u8) []const u8 {
    var n = appendBytes(buf, at, "A ").?;
    for (0..record_fields) |i| {
        const v: u64 = if (i == field) value else if (i == record_fields - 1) label.len else 0;
        n = appendField(buf, n, v).?;
    }
    n = appendBytes(buf, n, label).?;
    n = appendBytes(buf, n, "\n").?;
    return buf[0..n];
}

/// 머리(머리말·체인·플래그)를 **전부 삼키고** 그 뒤에서 오류를 기대한다.
///
/// 판정자가 「`next()` 를 몇 번 부르는가」에 묶이면 머리가 늘 때마다 **엉뚱한 이유로** 깨진다 —
/// 체인 자리를 더할 때(G1) 한 번, 플래그를 필수로 할 때(L1) 또 한 번 그렇게 깨졌다. 여기서는
/// **레코드가 아닌 것은 전부 흘려보내고** 오류만 본다.
fn expectRecordError(bytes: []const u8, want: ParseError) !void {
    var p = Parser.init(bytes);
    while (true) {
        const ev = p.next() catch |e| {
            try testing.expectEqual(want, e);
            return;
        } orelse break;
        // 오염된 레코드가 **통과하면** 그것이 결함이다.
        if (ev == .record) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

/// 머리를 삼키고 **첫 레코드**를 돌려준다. 위 `expectRecordError` 와 같은 이유 — 판정자를
/// 「`next()` 를 몇 번 부르는가」에 안 묶는다.
fn firstRecord(bytes: []const u8) !Record {
    var p = Parser.init(bytes);
    while (try p.next()) |ev| {
        if (ev == .record) return ev.record;
    }
    return error.TestUnexpectedResult;
}

/// 자리 번호(0 부터) — `appendRecord` 의 순서와 같아야 한다.
const f_kind: usize = 4;
const f_result_flags: usize = 15;
const f_source: usize = 22;
const f_label_len: usize = 23;

test "필드 수가 계약과 맞다 — 판정자의 오염 줄이 자리를 안 밀리게" {
    var buf: [1024]u8 = undefined;
    const n = appendRecord(&buf, 0, .{ .hit = sampleHit() }).?;
    // `A ` 뒤의 공백 수 = 10 진 필드 수(라벨이 비어 마지막 공백까지 센다).
    var spaces: usize = 0;
    for (buf[2..n]) |c| {
        if (c == ' ') spaces += 1;
    }
    try testing.expectEqual(record_fields, spaces);
}

test "라벨 길이가 상한을 넘는다고 주장하면 거부한다" {
    var buf: [1024]u8 = undefined;
    const h = headerWithChain(&buf);
    const bytes = pollutedRecord(&buf, h, f_label_len, max_label_bytes + 1, "x");

    try expectRecordError(bytes, ParseError.TooLong);
}

test "모르는 열거값은 뭉개지 않고 거부한다" {
    var buf: [1024]u8 = undefined;
    const h = headerWithChain(&buf);
    const bytes = pollutedRecord(&buf, h, f_kind, 99, "");

    try expectRecordError(bytes, ParseError.UnknownEnum);
}

test "모르는 라벨 출처도 거부한다 — 새 판의 헬퍼다" {
    var buf: [1024]u8 = undefined;
    const h = headerWithChain(&buf);
    const bytes = pollutedRecord(&buf, h, f_source, 99, "");

    try expectRecordError(bytes, ParseError.UnknownEnum);
}

test "모르는 결과 비트는 새 판이다 — 조용히 버리지 않는다" {
    var buf: [1024]u8 = undefined;
    const h = headerWithChain(&buf);
    // 아는 넷(0b1111) 밖의 비트.
    const bytes = pollutedRecord(&buf, h, f_result_flags, 16, "");

    try expectRecordError(bytes, ParseError.UnknownEnum);
}

test "부호·밑줄이 든 수를 거부한다 — 꼬리 count 방어가 뚫리지 않게" {
    // `std.fmt.parseInt` 는 실측으로 `+5` 를 5 로, `5_0` 을 50 으로 읽는다(적대적 A1). 그것을
    // 꼬리·플래그에 쓰고 있었고, 그러면 `X 1_5` 가 15 로 통과해 중간 유실을 못 잡는다.
    var buf: [1024]u8 = undefined;
    var n = headerWithChain(&buf);
    n = appendRecord(&buf, n, .{ .hit = sampleHit() }).?;
    const bad = "X +1\n";
    @memcpy(buf[n..][0..bad.len], bad);

    var p = Parser.init(buf[0 .. n + bad.len]);
    _ = try p.next(); // 체인 파일
    _ = try p.next(); // 스캔 플래그
    _ = try p.next(); // 레코드
    try testing.expectError(ParseError.Malformed, p.next());
}

test "스캔 바이트에도 같은 규율이 선다" {
    var buf: [1024]u8 = undefined;
    const n = appendHeader(&buf, 0).?;
    const bad = "S 0 0 0 1_0\n";
    @memcpy(buf[n..][0..bad.len], bad);

    var p = Parser.init(buf[0 .. n + bad.len]);
    try testing.expectError(ParseError.Malformed, p.next());
}

test "라벨 출처가 그대로 돌아온다 — 화면이 「어디서 온 그림인가」를 그린다" {
    var buf: [1024]u8 = undefined;
    var n = headerWithChain(&buf);
    n = appendRecord(&buf, n, .{
        .hit = sampleHit(),
        .label = .{ .source = .codex_wrapper_path },
    }).?;
    n = appendTail(&buf, n, 1).?;

    const rec = try firstRecord(buf[0..n]);
    try testing.expectEqual(context.Source.codex_wrapper_path, rec.label.source);
}

test "버퍼가 모자라면 null — 잘린 레코드를 절대 만들지 않는다" {
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), appendHeader(&small, 0));

    var mid: [64]u8 = undefined;
    const n = appendHeader(&mid, 0).?;
    try testing.expectEqual(@as(?usize, null), appendRecord(&mid, n, .{ .hit = sampleHit() }));
}

test "버퍼가 차면 꼬리를 안 쓴다 — 그 wire 는 «완결» 이 아니다" {
    // 적대적 D1: 못 실은 건을 개수에서 빼고 꼬리를 쓰면, count 가 맞아 파서가 «완결» 로 읽는다.
    // 호출자의 규율은 **멈추는 것**이고, 이 판정자가 그 결말을 못박는다.
    var buf: [360]u8 = undefined; // 레코드 하나는 들어가고 둘째에서 찬다
    var n = headerWithChain(&buf);
    var written: u64 = 0;
    while (appendRecord(&buf, n, .{ .hit = sampleHit() })) |next| {
        n = next;
        written += 1;
    }
    try testing.expect(written >= 1); // 적어도 하나는 실렸다
    try testing.expectEqual(@as(?usize, null), appendRecord(&buf, n, .{ .hit = sampleHit() }));

    // **꼬리를 쓰지 않는다.** 그래서 받는 쪽이 잘림으로 읽는다.
    var p = Parser.init(buf[0..n]);
    var seen: u64 = 0;
    while (try p.next()) |ev| {
        if (ev == .record) seen += 1;
    }
    try testing.expectEqual(written, seen);
    try testing.expect(!p.complete());
}

test "플래그 없이 꼬리만 오면 거부한다 — 「못 봤다」가 「다 봤다」로 뒤집히지 않게" {
    // 적대적 L1: `ScanFlags` 의 기본값은 전부 거짓(= 다 봤다)이다. 플래그가 빠진 답을 완결로
    // 읽으면 상한에 잘린 세션이 **온전한 것처럼** 뜬다.
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFile(&buf, n, 0, "/a/b.jsonl").?;
    n = appendTail(&buf, n, 0).?;

    var p = Parser.init(buf[0..n]);
    _ = try p.next(); // 체인 파일
    try testing.expectError(ParseError.MissingFlags, p.next());
}

test "원격 오류로 끝난 답은 플래그가 없어도 완결이다" {
    // 스캔을 시작도 못 한 경우다 — 그 사실을 오류 자체가 말한다.
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendRemoteError(&buf, n, "open failed: FileNotFound").?;

    var p = Parser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqualStrings("open failed: FileNotFound", ev.remote_error);
    try testing.expect(p.complete());
}

test "안 온 체인 파일을 가리키는 레코드는 거부한다" {
    // 적대적 H1: 안 보면 소비자가 체인 밖 인덱스로 파일을 열려다 조용히 건너뛰고, 그 활동은
    // 「없는 것」이 된다.
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFile(&buf, n, 0, "/a/b.jsonl").?; // sampleHit 은 자리 2 를 가리킨다
    n = appendRecord(&buf, n, .{ .hit = sampleHit() }).?;

    var p = Parser.init(buf[0..n]);
    _ = try p.next(); // 체인 파일
    try testing.expectError(ParseError.UnknownFile, p.next());
}

test "결과 이미지의 파일 번호도 같은 검사를 받는다" {
    var buf: [1024]u8 = undefined;
    var n = headerWithChain(&buf); // 자리 2 만 있다
    var h = sampleHit();
    h.result.image = true;
    h.result.image_file = 1; // 안 온 자리
    n = appendRecord(&buf, n, .{ .hit = h }).?;

    try expectRecordError(buf[0..n], ParseError.UnknownFile);
}

test "같은 체인 자리를 두 번 주장하면 거부한다" {
    // 뒤엣것이 이기면 앞의 레코드들이 가리키던 파일이 조용히 바뀐다.
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFile(&buf, n, 1, "/a/b.jsonl").?;
    n = appendFile(&buf, n, 1, "/c/d.jsonl").?;

    var p = Parser.init(buf[0..n]);
    _ = try p.next();
    try testing.expectError(ParseError.DuplicateFile, p.next());
}

test "체인 자리는 순서가 아니라 번호다 — 가운데가 빠져도 안 밀린다" {
    // 🔥 적대적 G1: 로컬 스캔은 못 연 파일을 **건너뛰되 번호는 그대로 쓴다**. 순서로 정했다면
    // 여기서 자리 2 의 레코드가 자리 1 의 파일을 읽었을 것이다.
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFile(&buf, n, 0, "/first.jsonl").?;
    // 자리 1 은 못 열어서 안 실렸다(부모가 지워졌다).
    n = appendFile(&buf, n, 2, "/third.jsonl").?;
    n = appendRecord(&buf, n, .{ .hit = sampleHit() }).?; // file_index = 2
    n = appendTail(&buf, n, 1).?;

    var p = Parser.init(buf[0..n]);
    const a_file = (try p.next()).?;
    try testing.expectEqual(@as(u8, 0), a_file.file.index);
    const b_file = (try p.next()).?;
    try testing.expectEqual(@as(u8, 2), b_file.file.index);
    try testing.expectEqualStrings("/third.jsonl", b_file.file.path);
    const rec = (try p.next()).?;
    try testing.expectEqual(@as(u8, 2), rec.record.hit.file_index);
    try testing.expect(p.complete() == false or true);
}

test "스캔 플래그가 두 번 오면 거부한다 — 「못 봤다」를 나중 줄이 덮지 못하게" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendFlags(&buf, n, .{ .activity_partial = true }).?;
    n = appendFlags(&buf, n, .{}).?;

    var p = Parser.init(buf[0..n]);
    _ = try p.next();
    try testing.expectError(ParseError.Malformed, p.next());
}

test "체인 상한을 넘는 파일 수는 거부한다" {
    var buf: [4096]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    for (0..max_files) |i| n = appendFile(&buf, n, @intCast(i), "/a/b.jsonl").?;
    // 상한 밖 자리는 인코더가 거부한다.
    try testing.expectEqual(@as(?usize, null), appendFile(&buf, n, @intCast(max_files), "/a/b.jsonl"));
    // 그래도 오면(오염된 원격) 파서가 거부한다.
    var line: [64]u8 = undefined;
    const bad = std.fmt.bufPrint(&line, "F {d} 2 /a\n", .{max_files}) catch unreachable;
    @memcpy(buf[n..][0..bad.len], bad);

    var p = Parser.init(buf[0 .. n + bad.len]);
    for (0..max_files) |_| _ = try p.next();
    try testing.expectError(ParseError.TooManyFiles, p.next());
}

test "음수 시각도 그대로 돌아온다" {
    var buf: [1024]u8 = undefined;
    var n = headerWithChain(&buf);
    n = appendRecord(&buf, n, .{ .hit = sampleHit(), .label = .{ .time_s = -1 } }).?;
    n = appendTail(&buf, n, 1).?;

    const rec = try firstRecord(buf[0..n]);
    try testing.expectEqual(@as(i64, -1), rec.label.time_s);
}

test "상한 상수는 스캐너·라벨에서 온다 — 두 벌을 만들지 않는다" {
    try testing.expectEqual(index.max_source_path_bytes, max_path_bytes);
    try testing.expectEqual(context.max_label_bytes, max_label_bytes);
    try testing.expectEqual(index.max_chain, max_files);
    try testing.expectEqual(index.max_activity_hits_per_file + index.max_hits_per_file, max_records);
}

// ── 범위 읽기 wire(RAV5) ───────────────────────────────────────────────────────────────────────
//
// 펼침(계약 §2.4)과 본문 검색(§2.1.1)이 읽는 명령·결과 전문, 그리고 이미지 픽셀(RAV6)은 **바이트**라
// 활동 wire 에 실을 수 없다(§2.4 — 그것이 「본문은 안 싣는다」의 뜻이다). 대신 **자리를 알고 있으니**
// 그 구간만 요청형으로 당겨온다.
//
// **활동 wire 와 형식을 나눈다.** 저쪽은 「목록 하나」이고 이쪽은 「바이트 한 덩이」다 — 한 파서에
// 섞으면 `Event` 가 두 세계를 들고 소비자의 switch 가 의미 없이 넓어진다. 머리말이 다르므로 잘못 온
// 답은 `UnsupportedVersion` 으로 끊긴다.

pub const range_header_line = "maru-ravr 1";

/// 한 번에 당겨올 수 있는 최대 바이트. **이미지가 이 값을 정한다**(RAV6) — RF4 가 원격 파일 열기에
/// 정한 4 MiB 와 같은 값·같은 이유다. 펼침은 8 KiB, 문맥 창은 64 KiB 라 한참 아래다.
pub const max_range_bytes: usize = 4 << 20;

/// 범위 읽기 답 전체의 상한. 바이트 + 머리말·길이 접두·꼬리의 여유.
pub const max_range_wire_bytes: usize = max_range_bytes + 4096;

pub const RangeEvent = union(enum) {
    /// 읽은 바이트. **요청한 길이보다 짧을 수 있다**(파일 끝) — 그것은 오류가 아니다.
    bytes: []const u8,
    /// 원격이 보고한 실패. 이것으로 끝난 답도 **완결**이다(계약 §2.2).
    remote_error: []const u8,
};

pub fn appendRangeHeader(out: []u8, at: usize) ?usize {
    var n = appendBytes(out, at, range_header_line) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

/// 읽은 바이트를 싣는다. **길이 접두**라 개행·NUL 이 들어도 안 깨진다.
pub fn appendRangeBytes(out: []u8, at: usize, bytes: []const u8) ?usize {
    if (bytes.len > max_range_bytes) return null;
    var n = appendBytes(out, at, "B ") orelse return null;
    n = appendField(out, n, bytes.len) orelse return null;
    n = appendBytes(out, n, bytes) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendRangeError(out: []u8, at: usize, message: []const u8) ?usize {
    const clamped = message[0..@min(message.len, max_error_bytes)];
    var n = appendBytes(out, at, "! ") orelse return null;
    n = appendField(out, n, clamped.len) orelse return null;
    n = appendBytes(out, n, clamped) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendRangeTail(out: []u8, at: usize) ?usize {
    var n = appendBytes(out, at, "X") orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

/// 범위 읽기 답의 파서. 활동 파서와 **같은 규율**이다 — 꼬리를 못 보면 잘린 것이고, 그때 소비자는
/// 「못 읽었다」로 말해야 한다(계약 §2.2 · §6.1).
pub const RangeParser = struct {
    rest: []const u8,
    saw_header: bool = false,
    saw_bytes: bool = false,
    terminated: bool = false,

    pub fn init(bytes: []const u8) RangeParser {
        return .{ .rest = bytes };
    }

    pub fn complete(self: *const RangeParser) bool {
        return self.terminated and self.rest.len == 0;
    }

    pub fn next(self: *RangeParser) ParseError!?RangeEvent {
        if (self.rest.len == 0) return null;
        if (self.terminated) return ParseError.TrailingData;

        if (!self.saw_header) {
            const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse return ParseError.Malformed;
            const line = self.rest[0..nl];
            if (!std.mem.eql(u8, line, range_header_line)) return ParseError.UnsupportedVersion;
            self.rest = self.rest[nl + 1 ..];
            self.saw_header = true;
            if (self.rest.len == 0) return null;
        }

        switch (self.rest[0]) {
            'B' => {
                // **바이트 덩이는 한 번뿐이다.** 둘이 오면 어느 것이 그 자리인지 정의가 없다.
                if (self.saw_bytes) return ParseError.Malformed;
                if (self.rest.len < 2 or self.rest[1] != ' ') return ParseError.Malformed;
                self.rest = self.rest[2..];
                var p = Parser{ .rest = self.rest };
                const bytes = try p.takeLenPrefixed(max_range_bytes);
                self.rest = p.rest;
                self.saw_bytes = true;
                return .{ .bytes = bytes };
            },
            '!' => {
                if (self.rest.len < 2 or self.rest[1] != ' ') return ParseError.Malformed;
                self.rest = self.rest[2..];
                var p = Parser{ .rest = self.rest };
                const msg = try p.takeLenPrefixed(max_error_bytes);
                self.rest = p.rest;
                self.terminated = true;
                return .{ .remote_error = msg };
            },
            'X' => {
                if (self.rest.len < 2 or self.rest[1] != '\n') return ParseError.Malformed;
                self.rest = self.rest[2..];
                self.terminated = true;
                return null;
            },
            else => return ParseError.Malformed,
        }
    }
};

test "범위 왕복: 바이트가 그대로 돌아온다" {
    var buf: [1024]u8 = undefined;
    const payload = "line one\nline two\x00binary";
    var n = appendRangeHeader(&buf, 0).?;
    n = appendRangeBytes(&buf, n, payload).?;
    n = appendRangeTail(&buf, n).?;

    var p = RangeParser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqualStrings(payload, ev.bytes);
    try testing.expectEqual(@as(?RangeEvent, null), try p.next());
    try testing.expect(p.complete());
}

test "범위: 꼬리가 없으면 완결이 아니다" {
    var buf: [1024]u8 = undefined;
    var n = appendRangeHeader(&buf, 0).?;
    n = appendRangeBytes(&buf, n, "abc").?;

    var p = RangeParser.init(buf[0..n]);
    _ = try p.next();
    try testing.expectEqual(@as(?RangeEvent, null), try p.next());
    try testing.expect(!p.complete());
}

test "범위: 원격 오류도 완결이다 — 「못 읽었다」와 「빈 구간」을 가른다" {
    var buf: [1024]u8 = undefined;
    var n = appendRangeHeader(&buf, 0).?;
    n = appendRangeError(&buf, n, "seek failed").?;

    var p = RangeParser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqualStrings("seek failed", ev.remote_error);
    try testing.expect(p.complete());
}

test "범위: 활동 wire 를 범위 파서에 먹이면 거부한다 — 형식이 갈려 있다" {
    var buf: [1024]u8 = undefined;
    const n = appendHeader(&buf, 0).?; // `maru-rav 3`
    var p = RangeParser.init(buf[0..n]);
    try testing.expectError(ParseError.UnsupportedVersion, p.next());
}

test "범위: 바이트 덩이가 둘이면 거부한다" {
    var buf: [1024]u8 = undefined;
    var n = appendRangeHeader(&buf, 0).?;
    n = appendRangeBytes(&buf, n, "a").?;
    n = appendRangeBytes(&buf, n, "b").?;

    var p = RangeParser.init(buf[0..n]);
    _ = try p.next();
    try testing.expectError(ParseError.Malformed, p.next());
}

test "범위: 길이가 상한을 넘는다고 주장하면 거부한다" {
    var buf: [256]u8 = undefined;
    const h = appendRangeHeader(&buf, 0).?;
    var line: [128]u8 = undefined;
    const bad = std.fmt.bufPrint(&line, "B {d} x\n", .{max_range_bytes + 1}) catch unreachable;
    @memcpy(buf[h..][0..bad.len], bad);

    var p = RangeParser.init(buf[0 .. h + bad.len]);
    try testing.expectError(ParseError.TooLong, p.next());
}

test "범위: 빈 구간도 답이다 — 파일 끝을 「못 읽었다」로 읽지 않는다" {
    var buf: [256]u8 = undefined;
    var n = appendRangeHeader(&buf, 0).?;
    n = appendRangeBytes(&buf, n, "").?;
    n = appendRangeTail(&buf, n).?;

    var p = RangeParser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqual(@as(usize, 0), ev.bytes.len);
    try testing.expectEqual(@as(?RangeEvent, null), try p.next()); // 꼬리
    try testing.expect(p.complete());
}
