//! 모바일 host 가 SSH 세션을 쓰는 C ABI(계약 [docs/mobile-platform.md](../../../docs/mobile-platform.md) §3,
//! [docs/ssh-client.md](../../../docs/ssh-client.md) §2·§3.5).
//!
//! **이 층에 OS 호출이 0이다.** 소켓은 host 가 든다 — 읽은 바이트를 `feed` 로 밀어 넣고, 쌓인
//! 바이트를 `out` 에서 가져가 보낸다. 프로토콜 판단은 전부 코어(`session.ssh.client`)가 한다.
//!
//! **여기만 핸들을 쓴다.** 나머지 모바일 ABI 는 화면이 하나라는 전제의 싱글턴인데, 원격 세션은
//! 여러 개일 수 있고 재접속은 새 세션이다(SSH 에 재개가 없다 — 계약 §4.1). 핸들에 세대를 섞어
//! **닫은 뒤 남은 옛 핸들이 새 세션을 건드리지 못하게** 한다: 이 부류(stale handle)는 조용히
//! 남의 세션에 바이트를 쓰는 모양이라 증상이 원인과 멀다.
//!
//! **양방향에 배압이 있다.** `out`·`screen` 이 차면 `feed` 는 먹은 만큼만 알려 주고 멈춘다 —
//! 넘치게 두면 잃고, 잃으면 세션이 조용히 깨진다.

const std = @import("std");
const maru = @import("maru");
const client = maru.session.ssh.client;
/// **계약 테스트가 서버 답을 지어내는 데 쓴다.** 그쪽은 `maru` 모듈을 못 보고(이 파일만 본다),
/// 바이트를 손으로 적으면 프레이밍이 바뀔 때 테스트만 조용히 낡는다.
pub const test_client = client;
pub const test_wire = maru.session.ssh.wire;
pub const test_packet = maru.session.ssh.packet;
const private_key = maru.session.ssh.private_key;
const userauth = maru.session.ssh.userauth;
const hostkey = maru.session.ssh.hostkey;

// 숫자의 단일 출처는 `mobile_host_abi.h` 다. 여기 상수는 그 값을 **그대로** 든다 —
// 계약 테스트가 헤더를 읽어 대조한다(한쪽만 고치면 링크는 되고 동작만 어긋난다).
pub const max_sessions = 4;
pub const secret_key_bytes = 64;
pub const entropy_bytes = 32;
pub const max_user = 64;
pub const max_term = 32;
pub const out_bytes = 32768;
pub const screen_bytes = 65536;
/// 컨트롤 채널이 받아 둘 자리. 코어가 광고하는 한 패킷(`client.control_max_packet` = 8KiB)의
/// **두 배**다 — 한 패킷 몫만 대면 `feed` 한 번에 패킷 하나씩만 지난다(계약 §3.4.1).
pub const control_bytes = 16384;
/// 컨트롤 명령의 최대 길이. **숫자를 옮겨 적지 않고 코어 것을 그대로 든다** — 두 벌이면
/// 코어가 상한을 바꿀 때 이쪽만 옛 값으로 남아 "왜인지 긴 명령이 거절된다" 가 된다.
pub const control_command_bytes = client.max_control_command;

/// 컨트롤 채널 상태(`MARU_SSH_CONTROL_*`). **터미널 상태와 다른 축이다** — 컨트롤이 어떻게 되든
/// 터미널은 산다(계약 §3.4.1).
pub const control_none: u32 = 0;
pub const control_opening: u32 = 1;
pub const control_requesting_exec: u32 = 2;
pub const control_ready: u32 = 3;
pub const control_closed: u32 = 4;

pub const state_invalid: u32 = 0xFFFF_FFFF;

pub const ok: c_int = 0;
pub const err_bad_handle: c_int = -1;
pub const err_no_slot: c_int = -2;
pub const err_bad_arg: c_int = -3;
pub const err_host_key: c_int = -4;
pub const err_auth: c_int = -5;
pub const err_protocol: c_int = -6;
pub const err_not_ready: c_int = -7;
pub const err_buffer: c_int = -8;
pub const err_password_change: c_int = -9;

/// 세션 하나. **자리를 고정해서 든다** — `client.Client` 는 교환 해시에 쓸 원문을 안에 들고 있어
/// 복사·이동하면 어긋난다(계약 §3.5). 그래서 전역 배열이고, 핸들은 그 자리의 번호다.
const Slot = struct {
    used: bool = false,
    /// 닫을 때마다 오른다. 핸들 상위 16비트에 실려 **옛 핸들을 구별**한다.
    gen: u16 = 0,
    /// 난수원. **host 가 준 씨앗으로만** 선다 — 이 층은 OS 를 못 부른다.
    csprng: std.Random.DefaultCsprng = undefined,
    cl: client.Client = undefined,
    user: [max_user]u8 = undefined,
    user_len: usize = 0,
    term: [max_term]u8 = undefined,
    term_len: usize = 0,

    out: [out_bytes]u8 = undefined,
    out_len: usize = 0,
    screen: [screen_bytes]u8 = undefined,
    screen_len: usize = 0,
    /// 컨트롤 채널의 stdout. **화면과 다른 자리여야** ndjson 파서가 사람 화면을 안 읽는다.
    control: [control_bytes]u8 = undefined,
    control_len: usize = 0,
    /// 컨트롤 stderr 의 NUL 로 끝나는 사본. 코어 것은 다음 `feed` 까지만 사는 값이 아니지만
    /// (코어 안에 남는다) host 는 C 문자열을 기대하므로 여기서 끝을 붙인다.
    control_stderr: [288]u8 = @splat(0),

    /// 지문·배너·끊긴 설명·신호 이름은 **코어 안을 가리키는 값이라 다음 `feed` 까지만 산다**
    /// (계약 §3.5). host 가 나중에 읽어도 맞도록 여기 복사해 둔다.
    fp: [96]u8 = @splat(0),
    banner: [512]u8 = @splat(0),
    disconnect_desc: [512]u8 = @splat(0),
    disconnect_reason: u32 = 0,
    exit_signal: [32]u8 = @splat(0),
    exit_status: ?u32 = null,
    err_name: [64]u8 = @splat(0),
};

/// **테스트가 들여다본다.** 닫을 때 비밀을 정말 지웠는지는 바깥에서 행동만으로 못 재고,
/// 못 재면 그 한 줄은 있으나 마나다.
pub var slots: [max_sessions]Slot = @splat(.{});

/// 빈 문자열 하나를 돌려줄 자리. 핸들이 틀렸을 때 null 을 주면 host 가 그것을 문자열로 읽는다.
const empty: [1:0]u8 = .{0};

fn handleOf(index: usize, gen: u16) u32 {
    return (@as(u32, gen) << 16) | @as(u32, @intCast(index + 1));
}

/// 핸들 → 슬롯. **세대까지 맞아야 한다.** 번호만 보면 닫힌 뒤 재사용된 자리를 옛 핸들이
/// 건드린다 — 그 세션의 바이트가 남의 화면에 섞여 나가는 모양이고, 원인을 짚기 아주 어렵다.
fn slotOf(handle: u32) ?*Slot {
    const index = (handle & 0xFFFF);
    if (index == 0 or index > max_sessions) return null;
    const s = &slots[index - 1];
    if (!s.used) return null;
    if (s.gen != @as(u16, @truncate(handle >> 16))) return null;
    return s;
}

fn setError(s: *Slot, name: []const u8) void {
    // **먼저 난 실패를 남긴다**(브리지 관례) — 뒤에 난 것으로 덮으면 원인이 결과에 가린다.
    if (s.err_name[0] != 0) return;
    @memset(&s.err_name, 0);
    const n = @min(name.len, s.err_name.len - 1);
    @memcpy(s.err_name[0..n], name[0..n]);
}

/// 코어 오류를 host 가 **분기할 수 있는** 범주로 낮춘다. **테스트가 전수로 본다** — 이 표가
/// 틀리면 사용자는 엉뚱한 것을 고치려 든다(인증 실패를 호스트키 문제로 보여 주는 식).
///
/// **`else` 가 없다.** 코어에 오류가 하나 늘면 여기서 컴파일이 깨지고, 그때 "이건 host 가 어떻게
/// 다뤄야 하나" 를 정하게 된다 — `else` 를 두면 새 오류가 조용히 "프로토콜 오류" 로 접힌다.
pub fn statusOf(e: client.Error) c_int {
    return switch (e) {
        // 호스트키: 사용자에게 지문을 보이고 물어야 하는 자리 + 서버 신원 증명 실패.
        // `HostKeyChanged` 는 **세션 도중** 키가 바뀐 것이라 특히 사용자에게 보여야 한다 —
        // 승인한 지문과 지금 상대가 다르다는 뜻이다.
        error.HostKeyNotAccepted,
        error.HostKeyRejected,
        error.HostKeyChanged,
        error.BadSignature,
        => err_host_key,
        // 인증.
        error.AuthFailed, error.UnexpectedService => err_auth,
        // **비밀번호 만료는 인증 실패와 다르다** — 다시 쳐도 안 되고 서버에서 바꿔야 한다.
        error.PasswordChangeRequired => err_password_change,
        // host 가 준 값이 이상하다(키 바이트).
        error.BadSeed, error.BadPrivateKey => err_bad_arg,
        // 아직 못 쓴다.
        error.NotReady, error.NotStarted => err_not_ready,
        // 자리 부족 — 비우고 다시 부르면 된다.
        error.ShortBuffer, error.NoSpace => err_buffer,
        // 나머지는 전부 프로토콜·암호 실패다. 세션은 못 산다.
        error.UnexpectedMessage,
        error.ChannelRefused,
        error.RequestFailed,
        error.NonKexMessageDuringInitialKex,
        error.FirstMessageNotKexInit,
        error.SequenceWrapBeforeKexComplete,
        error.DuplicateKexMessage,
        error.WrongPhase,
        error.NotAllowedDuringRekey,
        error.PacketTooLarge,
        error.MalformedPacket,
        error.Incomplete,
        error.BadTag,
        error.NotKexInit,
        error.NoCommonKex,
        error.NoCommonHostKey,
        error.NoCommonCipherC2s,
        error.NoCommonCipherS2c,
        error.NoCommonCompressionC2s,
        error.NoCommonCompressionS2c,
        error.Truncated,
        error.TooLarge,
        error.MalformedMpint,
        error.NotKexEcdhReply,
        error.BadPublicKeyLength,
        error.WeakPublicKey,
        error.UnsupportedAlgorithm,
        error.MalformedBlob,
        error.NotChannelMessage,
        error.WrongChannel,
        error.WouldExceedWindow,
        error.WindowOverflow,
        error.WindowExhausted,
        error.DataExceedsMaxPacket,
        error.LineTooLong,
        error.UnsupportedProtocol,
        error.MalformedVersion,
        => err_protocol,
    };
}

/// 코어 상태를 **헤더가 정한 숫자**로 옮긴다. `@intFromEnum` 을 쓰지 않는 것이 요점이다 —
/// 코어 enum 에 값을 하나 끼워 넣으면 host 가 읽는 뜻이 통째로 밀린다.
fn stateOf(st: client.State) u32 {
    return switch (st) {
        .idle => 0,
        .version_exchange => 1,
        .negotiating => 2,
        .key_exchange => 3,
        .host_key_decision => 4,
        .awaiting_new_keys => 5,
        .requesting_service => 6,
        .authenticating => 7,
        .password_needed => 13,
        .opening_channel => 8,
        .requesting_pty => 9,
        .starting_shell => 10,
        .ready => 11,
        .closed => 12,
    };
}

fn copyZ(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
}

/// `feed` 한 걸음이 낸 것을 슬롯에 챙긴다. **다음 `feed` 면 사라지는 값들이라 여기서 복사한다.**
///
/// **여기서 안 챙긴 필드는 조용히 사라진다.** 이 저장소가 여러 번 겪은 부류라(관측 필드가
/// `view()` 를 안 타서 제품이 무동작이던 자리), 코어가 `Step` 에 필드를 더하면 **컴파일이
/// 멈추게** 해 둔다. 늘어난 필드를 여기서 챙길지 정하고 이 숫자를 옮기면 된다.
///
/// 지금 안 챙기는 것: `state`(호출자가 `maru_mobile_ssh_state` 로 따로 읽는다),
/// `consumed`(`feed` 가 그 자리에서 돌려준다).
fn absorb(s: *Slot, step: client.Step) void {
    // **아래 문구는 표시가 아니라 컴파일 진단이다**(i18n §7 — 화면에 안 간다).
    // `tests/boundary/i18n_literals.zig` 원장이 그 사실과 함께 이 한 개를 적어 둔다.
    s.control_len += step.control.len;
    comptime {
        const fields = @typeInfo(client.Step).@"struct".fields.len;
        if (fields != 9) @compileError(
            "client.Step 의 필드 수가 바뀌었다 — 새 필드를 absorb 가 흘리고 있지 않은지 보고 이 숫자를 고쳐라",
        );
    }
    s.out_len += step.wire.len;
    s.screen_len += step.screen.len;
    if (step.banner) |b| {
        if (s.banner[0] == 0) copyZ(&s.banner, b);
    }
    if (step.exit_status) |code| s.exit_status = code;
    if (step.exit_signal) |sig| copyZ(&s.exit_signal, sig);
    if (step.disconnect) |d| {
        s.disconnect_reason = @intFromEnum(d.reason);
        copyZ(&s.disconnect_desc, d.description);
    }
}

/// 컨트롤 채널이 받아 둘 남은 자리. **채널을 안 열었으면 빈 슬라이스여도 된다** — 코어가
/// 살아 있는 채널에만 자리를 요구한다(계약 §3.4.1).
fn controlFree(s: *Slot) []u8 {
    return s.control[s.control_len..];
}

/// 선에 낼 자리. **한 걸음이 필요한 만큼 없으면 배압이다**(계약 §3.5).
fn outFree(s: *Slot) []u8 {
    return s.out[s.out_len..];
}

fn screenFree(s: *Slot) []u8 {
    return s.screen[s.screen_len..];
}

/// PEM 본문을 벗기고 base64 를 푼 뒤 `openssh-key-v1` 로 파싱할 자리. **할당이 없다** —
/// 이 층은 allocator 를 안 든다(계약 §2). 키 하나가 이 안에 들어가야 한다.
var key_scratch: [16 * 1024]u8 = undefined;
var key_blob: [16 * 1024]u8 = undefined;

// ── 진입점 ──────────────────────────────────────────────────────────────────

/// 개인키 파일 내용(PEM 텍스트)에서 `seed(32) ‖ public(32)` 를 만든다.
///
/// **파일은 host 가 읽는다**(이 층은 OS 를 모른다). host 는 Keychain·Keystore 나 앱 저장소에서
/// 바이트를 꺼내 여기 넣고, 나온 64바이트를 `open` 에 그대로 넘긴 뒤 **자기 사본을 지운다**.
///
/// **암호 걸린 키도 받는다** — `passphrase` 가 비면 평문 키만 열린다. KDF 비용 상한은 호출자
/// 정책이라 여기서 기본값을 쓴다(계약 §4.4.3.1).
pub export fn maru_mobile_ssh_load_key(
    pem: [*]const u8,
    pem_len: u32,
    passphrase: [*]const u8,
    pass_len: u32,
    out_secret: [*]u8,
) c_int {
    @memset(out_secret[0..secret_key_bytes], 0);
    if (pem_len == 0) {
        last_load_error = "key_empty";
        return err_bad_arg;
    }

    // **PEM 껍데기를 벗긴다.** `-----BEGIN/END-----` 줄과 줄바꿈을 뺀 나머지가 base64 다.
    var b64_len: usize = 0;
    var lines = std.mem.splitScalar(u8, pem[0..pem_len], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "-----")) continue;
        if (b64_len + trimmed.len > key_scratch.len) {
            last_load_error = "key_too_large";
            return err_bad_arg;
        }
        @memcpy(key_scratch[b64_len..][0..trimmed.len], trimmed);
        b64_len += trimmed.len;
    }
    const decoder = std.base64.standard.Decoder;
    const blob_len = decoder.calcSizeForSlice(key_scratch[0..b64_len]) catch {
        last_load_error = "key_not_base64";
        return err_bad_arg;
    };
    if (blob_len > key_blob.len) {
        last_load_error = "key_too_large";
        return err_bad_arg;
    }
    decoder.decode(key_blob[0..blob_len], key_scratch[0..b64_len]) catch {
        last_load_error = "key_not_base64";
        return err_bad_arg;
    };

    var parsed = private_key.parse(key_blob[0..blob_len], passphrase[0..pass_len], &key_scratch, .{}) catch |e| {
        last_load_error = @errorName(e);
        // **실패해도 남기지 않는다** — 중간 산물에 키 재료가 들어 있다.
        std.crypto.secureZero(u8, &key_scratch);
        std.crypto.secureZero(u8, &key_blob);
        return err_bad_arg;
    };
    @memcpy(out_secret[0..secret_key_bytes], &parsed.secret);
    parsed.clear();
    std.crypto.secureZero(u8, &key_scratch);
    std.crypto.secureZero(u8, &key_blob);
    last_load_error = "";
    return ok;
}

/// 기기에서 키쌍을 만든다(계약 §3.4 — **키는 앱이 만든다**).
///
/// **씨앗은 host 가 준다**(`open` 과 같은 규칙 — 이 층은 OS 난수를 못 부른다). 그 32바이트가
/// 곧 개인키의 씨앗이므로, 예측 가능한 값을 주면 **그 키로 지킬 수 있는 것이 아무것도 없다** —
/// 0 은 거절한다.
///
/// 나오는 것은 둘이다: `open` 에 그대로 넘길 **64바이트**(`seed ‖ public`)와, 사용자가 서버
/// `authorized_keys` 에 붙일 **한 줄**(`ssh-ed25519 <base64> maru`). 개인키는 이 함수 밖으로
/// 안 나가고, 나간 한 줄에는 공개키만 들어 있다.
pub export fn maru_mobile_ssh_generate_key(
    entropy: [*]const u8,
    out_secret: [*]u8,
    out_line: [*]u8,
    line_cap: u32,
) c_int {
    @memset(out_secret[0..secret_key_bytes], 0);
    if (line_cap > 0) out_line[0] = 0;

    var seed: [32]u8 = undefined;
    @memcpy(&seed, entropy[0..32]);
    var any: u8 = 0;
    for (seed) |b| any |= b;
    if (any == 0) {
        last_load_error = "entropy_zero";
        return err_bad_arg;
    }

    const pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch {
        last_load_error = "key_generate_failed";
        std.crypto.secureZero(u8, &seed);
        return err_bad_arg;
    };
    var secret: [secret_key_bytes]u8 = undefined;
    @memcpy(secret[0..32], &seed);
    @memcpy(secret[32..64], &pair.public_key.toBytes());
    std.crypto.secureZero(u8, &seed);

    if (writeLine(secret, out_line, line_cap) != ok) {
        std.crypto.secureZero(u8, &secret);
        return err_bad_arg;
    }

    @memcpy(out_secret[0..secret_key_bytes], &secret);
    std.crypto.secureZero(u8, &secret);
    last_load_error = "";
    return ok;
}

/// `authorized_keys` 한 줄을 적는다(끝에 0). **형식은 한 곳에서만 만든다** — 만드는 자리와
/// 보여 주는 자리가 각자 조립하면 두 벌이 되고, 사용자는 어느 쪽이 진짜인지 모른다.
fn writeLine(secret: [secret_key_bytes]u8, out_line: [*]u8, line_cap: u32) c_int {
    // **blob 은 코어가 만든다** — 형식이 두 벌이 되면 갈린다.
    var blob_buf: [128]u8 = undefined;
    const blob = userauth.publicKeyBlob(&blob_buf, secret) catch {
        last_load_error = "public_blob_failed";
        return err_bad_arg;
    };
    const encoder = std.base64.standard.Encoder;
    const need = hostkey.alg_name.len + 1 + encoder.calcSize(blob.len) + " maru".len + 1;
    if (line_cap < need) {
        last_load_error = "line_too_small";
        return err_bad_arg;
    }
    var n: usize = 0;
    @memcpy(out_line[0..hostkey.alg_name.len], hostkey.alg_name);
    n += hostkey.alg_name.len;
    out_line[n] = ' ';
    n += 1;
    const encoded = encoder.encode(out_line[n .. n + encoder.calcSize(blob.len)], blob);
    n += encoded.len;
    @memcpy(out_line[n..][0..5], " maru");
    n += 5;
    out_line[n] = 0;
    last_load_error = "";
    return ok;
}

/// **이미 있는 키의 한 줄**을 만든다(`seed ‖ public` 64바이트 → `ssh-ed25519 <base64> maru`).
///
/// 만들 때(`generate_key`)만 한 줄을 내주면 **다시 켠 기기에서는 그 줄을 영영 못 본다** —
/// Android 는 Keystore 에 봉인해 둔 것을 풀어 쓰고 iOS 는 파일을 읽으므로, 그때는 만드는 일이
/// 안 일어난다. 사용자는 그 한 줄을 서버 `authorized_keys` 에 붙여야 접속을 시작할 수 있다.
///
/// **개인키는 안 나간다** — 씨앗 32바이트는 blob 에 안 들어간다.
pub export fn maru_mobile_ssh_public_key_line(
    secret: [*]const u8,
    out_line: [*]u8,
    line_cap: u32,
) c_int {
    if (line_cap > 0) out_line[0] = 0;
    var copy: [secret_key_bytes]u8 = undefined;
    @memcpy(&copy, secret[0..secret_key_bytes]);
    defer std.crypto.secureZero(u8, &copy);
    return writeLine(copy, out_line, line_cap);
}

/// 키 읽기 실패 이름. **세션이 아직 없으므로 세션별 자리에 못 남긴다** — 이 자리가 그것을 든다.
var last_load_error: []const u8 = "";
var load_error_buf: [64]u8 = @splat(0);

pub export fn maru_mobile_ssh_last_load_error() [*:0]const u8 {
    @memset(&load_error_buf, 0);
    const n = @min(last_load_error.len, load_error_buf.len - 1);
    @memcpy(load_error_buf[0..n], last_load_error[0..n]);
    return @ptrCast(&load_error_buf);
}

pub export fn maru_mobile_ssh_open(
    user: [*]const u8,
    user_len: u32,
    secret_key: ?[*]const u8,
    entropy: [*]const u8,
    term: [*]const u8,
    term_len: u32,
    cols: u32,
    rows: u32,
    window: u32,
    pty: u32,
    out_handle: *u32,
) c_int {
    out_handle.* = 0;
    if (user_len == 0 or user_len > max_user) return err_bad_arg;
    if (term_len == 0 or term_len > max_term) return err_bad_arg;
    if (cols == 0 or rows == 0) return err_bad_arg;

    // **0 씨앗은 받지 않는다.** host 가 난수를 못 채웠는데 그대로 열면 임시키·cookie 가 예측
    // 가능해져 그 세션의 비밀이 통째로 깨진다 — 그리고 화면은 멀쩡해서 아무도 모른다.
    var seed: [entropy_bytes]u8 = undefined;
    @memcpy(&seed, entropy[0..entropy_bytes]);
    var any: u8 = 0;
    for (seed) |b| any |= b;
    if (any == 0) return err_bad_arg;

    const s = free: {
        for (&slots) |*cand| {
            if (!cand.used) break :free cand;
        }
        break :free null;
    } orelse return err_no_slot;

    // **자리는 다 되고 나서 표시한다.** 중간에 실패하고 되돌리는 가지를 두면, 그 가지는 거의
    // 안 돌아 변이 검사에서 살아남고(테스트가 못 밟는다) 언젠가 틀린 채로 남는다.
    s.* = .{ .used = false, .gen = s.gen +% 1 };
    @memcpy(s.user[0..user_len], user[0..user_len]);
    s.user_len = user_len;
    @memcpy(s.term[0..term_len], term[0..term_len]);
    s.term_len = term_len;
    s.csprng = std.Random.DefaultCsprng.init(seed);
    std.crypto.secureZero(u8, &seed);

    // **키는 없을 수 있다**(`NULL`). 키가 없는 기기도 비밀번호만 여는 서버에는 붙어야 한다 —
    // 코어가 그때는 `none` 으로 방법 목록만 묻는다(SSH 계약 §3.4).
    var key: ?[secret_key_bytes]u8 = null;
    if (secret_key) |ptr| {
        var k: [secret_key_bytes]u8 = undefined;
        @memcpy(&k, ptr[0..secret_key_bytes]);
        key = k;
    }
    defer if (key) |*k| std.crypto.secureZero(u8, k);
    s.cl = client.Client.init(.{
        .user = s.user[0..s.user_len],
        .secret_key = key,
        .term = s.term[0..s.term_len],
        .size = .{ .cols = cols, .rows = rows },
        .window = window,
        .pty = pty != 0,
    }, s.csprng.random());

    // **여는 것과 첫 바이트를 내는 것을 안 나눈다.** 나누면 host 가 한쪽을 잊고, 잊으면 서버는
    // 우리 버전 줄을 영영 못 받아 "연결은 됐는데 아무 일도 안 난다" 가 된다.
    const line = s.cl.start(outFree(s)) catch |e| {
        setError(s, @errorName(e));
        s.cl.clear(); // 비밀은 남기지 않는다
        return statusOf(e);
    };
    s.out_len += line.len;
    s.used = true;
    out_handle.* = handleOf(indexOf(s), s.gen);
    return ok;
}

fn indexOf(s: *Slot) usize {
    return (@intFromPtr(s) - @intFromPtr(&slots[0])) / @sizeOf(Slot);
}

pub export fn maru_mobile_ssh_close(handle: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    // **비밀을 지운다** — 개인키와 세션키가 여기 있었다. 슬롯은 재사용되므로 남은 바이트는
    // 다음 세션의 메모리가 된다.
    s.cl.clear();
    std.crypto.secureZero(u8, &s.out);
    std.crypto.secureZero(u8, &s.screen);
    s.used = false;
    s.out_len = 0;
    s.screen_len = 0;
    return ok;
}

pub export fn maru_mobile_ssh_state(handle: u32) u32 {
    const s = slotOf(handle) orelse return state_invalid;
    return stateOf(s.cl.state);
}

pub export fn maru_mobile_ssh_feed(handle: u32, bytes: [*]const u8, len: u32, consumed: *u32) c_int {
    consumed.* = 0;
    const s = slotOf(handle) orelse return err_bad_handle;
    // **자리 검사는 코어가 한다** — 한 걸음이 못 들어가면 `ShortBuffer` 다(계약 §3.5). 여기서
    // 같은 검사를 또 하면 두 벌이 되어 갈리고(코어가 상한을 바꾸면 이쪽만 옛 값이다), 이름도
    // 안 남아 §5 의 "왜 실패했나" 가 사라진다. 그 오류를 `MARU_SSH_ERR_BUFFER` 로 낮춘다 —
    // **오류가 아니라 배압이다**: 비우고 다시 부르면 된다.
    const step = s.cl.feedBuffers(bytes[0..len], .{
        .wire = outFree(s),
        .screen = screenFree(s),
        .control = controlFree(s),
    }) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    absorb(s, step);
    consumed.* = @intCast(step.consumed);
    return ok;
}

/// 채널 데이터 한 개가 payload 위에 더 쓰는 바이트(채널 머리 9 + 패킷 프레이밍·태그).
///
/// **넉넉히 잡는다** — 모자라면 마지막 한 조각에서 `NoSpace` 가 나고, 그 경계는 버퍼가 얼마나
/// 찼느냐에 따라 걸리기도 안 걸리기도 해서 테스트로 잡히지 않는다.
const frame_overhead = 128;

pub export fn maru_mobile_ssh_write(handle: u32, bytes: [*]const u8, len: u32, sent: *u32) c_int {
    sent.* = 0;
    const s = slotOf(handle) orelse return err_bad_handle;
    // **여기만 미리 잰다.** `write` 는 코어가 우리 버퍼를 안 보고 창·길이로만 자르므로(아래),
    // 자를 값을 계산하려면 남은 자리를 알아야 한다.
    const room = outFree(s).len;
    if (room <= frame_overhead) {
        setError(s, "ssh_out_full");
        return err_buffer;
    }
    // **코어는 우리 버퍼 크기를 모른다** — 창과 데이터 길이로만 자른다. 그대로 넘기면 자리가
    // 모자랄 때 한 바이트도 못 보내고(`NoSpace`), host 는 자기 버퍼 사정을 짐작해 스스로 잘라야
    // 한다. 버퍼를 아는 쪽이 자른다. 나머지는 `sent` 를 보고 호출자가 다시 준다(계약 §3.1 과
    // 같은 규약이다 — 흐름 제어로 못 보내는 것과 구별할 필요가 없다).
    const capped = @min(len, @as(u32, @intCast(room - frame_overhead)));
    const r = s.cl.write(bytes[0..capped], outFree(s)) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += r.wire.len;
    sent.* = @intCast(r.sent);
    return ok;
}

pub export fn maru_mobile_ssh_resize(handle: u32, cols: u32, rows: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    if (cols == 0 or rows == 0) return err_bad_arg;
    const wire = s.cl.resize(.{ .cols = cols, .rows = rows }, outFree(s)) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += wire.len;
    return ok;
}

pub export fn maru_mobile_ssh_eof(handle: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    const wire = s.cl.eof(outFree(s)) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += wire.len;
    return ok;
}

pub export fn maru_mobile_ssh_out_ptr(handle: u32) [*]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return &s.out;
}

pub export fn maru_mobile_ssh_out_len(handle: u32) u32 {
    const s = slotOf(handle) orelse return 0;
    return @intCast(s.out_len);
}

pub export fn maru_mobile_ssh_out_consume(handle: u32, n: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    if (n > s.out_len) return err_bad_arg;
    std.mem.copyForwards(u8, s.out[0 .. s.out_len - n], s.out[n..s.out_len]);
    s.out_len -= n;
    return ok;
}

pub export fn maru_mobile_ssh_screen_ptr(handle: u32) [*]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return &s.screen;
}

pub export fn maru_mobile_ssh_screen_len(handle: u32) u32 {
    const s = slotOf(handle) orelse return 0;
    return @intCast(s.screen_len);
}

pub export fn maru_mobile_ssh_screen_consume(handle: u32, n: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    if (n > s.screen_len) return err_bad_arg;
    std.mem.copyForwards(u8, s.screen[0 .. s.screen_len - n], s.screen[n..s.screen_len]);
    s.screen_len -= n;
    return ok;
}

/// **두 번째 채널을 연다** — 원격에서 명령 하나를 돌린다(계약 [컨트롤 플레인 §4a]).
///
/// **터미널이 떠 있어야 한다**(`MARU_SSH_STATE_READY`). 재키잉 중이면 아무것도 안 나가고
/// 상태도 안 옮긴다 — 그때는 `MARU_SSH_ERR_NOT_READY` 로 알려 host 가 **다시 부르게** 한다.
/// 조용히 성공을 돌려주면 host 는 열렸다고 믿는데 선에는 아무것도 없다.
pub export fn maru_mobile_ssh_open_control(handle: u32, cmd: [*]const u8, cmd_len: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    if (cmd_len == 0 or cmd_len > control_command_bytes) return err_bad_arg;
    const before = s.cl.controlState();
    // **이미 열려 있는데 또 여는 것은 호출자의 순서 실수다.** 코어는 그것을
    // `UnexpectedMessage` 로 내는데, 그대로 흘리면 `MARU_SSH_ERR_PROTOCOL`("세션은 못 산다")
    // 이 되어 host 가 **멀쩡한 연결을 접는다**. 여기서 가려 `BAD_ARG` 로 답한다.
    switch (before) {
        .opening, .requesting_exec, .ready => {
            setError(s, "control_already_open");
            return err_bad_arg;
        },
        .none, .closed => {},
    }
    const bytes = s.cl.openControl(cmd[0..cmd_len], outFree(s)) catch |e| {
        // **닫는 중인 번호는 다시 못 쓴다**(§5.3 — 양쪽이 오가야 끝난다). 그것도 세션 실패가
        // 아니라 **조금 뒤에 다시 부르면 되는** 자리다.
        //
        // **이름을 먼저 정하고 한 번만 적는다** — `setError` 는 먼저 난 것을 남기므로
        // (§5 의 "먼저 난 실패가 남는다"), 코어 이름을 적고 나서 덮으려 하면 안 덮인다.
        if (e == client.Error.UnexpectedMessage) {
            setError(s, "control_closing");
            return err_not_ready;
        }
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += bytes.len;
    // **안 나갔으면 안 열린 것이다.** 재키잉 중이 그 자리다(코어가 0 바이트를 돌려준다).
    if (bytes.len == 0 and s.cl.controlState() == before) {
        setError(s, "ssh_rekeying");
        return err_not_ready;
    }
    return ok;
}

/// 컨트롤 채널로 보낸다(ndjson 한 조각). 터미널 `write` 와 같은 규약이다 — **보낸 만큼**을
/// 알려 주고 나머지는 host 가 다시 준다.
pub export fn maru_mobile_ssh_write_control(handle: u32, bytes: [*]const u8, len: u32, sent: *u32) c_int {
    sent.* = 0;
    const s = slotOf(handle) orelse return err_bad_handle;
    const room = outFree(s).len;
    if (room <= frame_overhead) {
        setError(s, "ssh_out_full");
        return err_buffer;
    }
    const cut = @min(@as(usize, len), room - frame_overhead);
    const r = s.cl.writeControl(bytes[0..cut], outFree(s)) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += r.wire.len;
    sent.* = @intCast(r.sent);
    return ok;
}

/// 컨트롤 채널을 닫는다. **터미널은 그대로 산다.**
pub export fn maru_mobile_ssh_close_control(handle: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    const bytes = s.cl.closeControl(outFree(s)) catch |e| {
        setError(s, @errorName(e));
        return statusOf(e);
    };
    s.out_len += bytes.len;
    return ok;
}

/// 컨트롤 채널이 어디까지 왔나(`MARU_SSH_CONTROL_*`). 핸들이 틀리면 `MARU_SSH_STATE_INVALID`.
pub export fn maru_mobile_ssh_control_state(handle: u32) u32 {
    const s = slotOf(handle) orelse return state_invalid;
    return switch (s.cl.controlState()) {
        .none => control_none,
        .opening => control_opening,
        .requesting_exec => control_requesting_exec,
        .ready => control_ready,
        .closed => control_closed,
    };
}

pub export fn maru_mobile_ssh_control_ptr(handle: u32) [*]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return &s.control;
}

pub export fn maru_mobile_ssh_control_len(handle: u32) u32 {
    const s = slotOf(handle) orelse return 0;
    return @intCast(s.control_len);
}

/// 가져간 만큼 지운다. **`n` 이 있는 것보다 크면 아무것도 안 지우고 실패다** — 조용히 다 지우면
/// 아직 안 읽은 줄이 사라진다.
pub export fn maru_mobile_ssh_control_consume(handle: u32, n: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    if (n > s.control_len) return err_bad_arg;
    std.mem.copyForwards(u8, s.control[0 .. s.control_len - n], s.control[n..s.control_len]);
    s.control_len -= n;
    return ok;
}

/// 컨트롤 명령의 종료 코드. **`127` 이면 그 서버에 `maru` 가 없다**(계약 §4a).
/// 아직 안 끝났으면 `MARU_SSH_ERR_NOT_READY`.
pub export fn maru_mobile_ssh_control_exit_status(handle: u32, code: *u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    const got = s.cl.controlExitStatus() orelse return err_not_ready;
    code.* = got;
    return ok;
}

/// 컨트롤 명령이 stderr 로 낸 첫 조각(진단용, NUL 로 끝난다). 비어 있을 수 있다.
///
/// **화면에도 wire 에도 안 섞인 것이다**(계약 §4a) — 사용자에게 "왜 안 되나" 를 말할 유일한 재료다.
pub export fn maru_mobile_ssh_control_stderr(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    const src = s.cl.controlStderr();
    const n = @min(src.len, s.control_stderr.len - 1);
    @memcpy(s.control_stderr[0..n], src[0..n]);
    s.control_stderr[n] = 0;
    return @ptrCast(&s.control_stderr);
}

pub export fn maru_mobile_ssh_host_key_fingerprint(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    if (s.cl.state != .host_key_decision and s.fp[0] == 0) return &empty;
    if (s.fp[0] == 0) {
        var buf: [96]u8 = undefined;
        const fp = s.cl.hostKeyFingerprint(&buf) catch |e| {
            setError(s, @errorName(e));
            return &empty;
        };
        copyZ(&s.fp, fp);
    }
    return @ptrCast(&s.fp);
}

pub export fn maru_mobile_ssh_accept_host_key(handle: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    s.cl.acceptHostKey();
    return ok;
}

/// **사용자가 친 비밀번호를 넣는다**(`password_needed` 에서만). 코어가 요청 패킷으로 만들어
/// `out` 에 쌓고, 만든 자리를 지운다 — 이 층에도 남기지 않는다(계약 §3.4).
pub export fn maru_mobile_ssh_password(handle: u32, password: [*]const u8, len: u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    // **`out` 에 쌓는다** — 다른 걸음과 같은 자리로 나가야 host 가 보내는 코드를 한 벌만 든다.
    var scratch: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch); // 요청에는 비밀번호가 들어 있다
    const wire = s.cl.providePassword(password[0..len], &scratch) catch |e| {
        setError(s, @errorName(e));
        // 그 자리가 아니면 "아직 아니다" 다 — 비밀번호가 틀렸다는 뜻이 아니다.
        return if (e == client.Error.UnexpectedMessage) err_not_ready else statusOf(e);
    };
    if (s.out_len + wire.len > s.out.len) {
        setError(s, "out_full");
        return err_buffer;
    }
    @memcpy(s.out[s.out_len..][0..wire.len], wire);
    s.out_len += wire.len;
    return ok;
}

/// 지금까지 키를 몇 번 갈았나(재키잉 — 계약 §3.0.1). **오래 산 세션은 반드시 이 길을 지난다**
/// (OpenSSH 기본 1GB/1시간). 0 이면 그 길을 한 번도 안 밟은 것이라, 검증에서 "쟀다" 고 말할 수
/// 없다 — 기기 로그로도 "이 세션이 얼마나 오래 살았나" 를 가늠하는 값이다.
pub export fn maru_mobile_ssh_rekeys(handle: u32) u32 {
    const s = slotOf(handle) orelse return 0;
    return @intCast(s.cl.rekeys);
}

pub export fn maru_mobile_ssh_disconnect_reason(handle: u32) u32 {
    const s = slotOf(handle) orelse return 0;
    return s.disconnect_reason;
}

pub export fn maru_mobile_ssh_disconnect_description(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return @ptrCast(&s.disconnect_desc);
}

pub export fn maru_mobile_ssh_banner(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return @ptrCast(&s.banner);
}

pub export fn maru_mobile_ssh_exit_status(handle: u32, code: *u32) c_int {
    const s = slotOf(handle) orelse return err_bad_handle;
    const got = s.exit_status orelse return err_not_ready;
    code.* = got;
    return ok;
}

pub export fn maru_mobile_ssh_exit_signal(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return @ptrCast(&s.exit_signal);
}

pub export fn maru_mobile_ssh_last_error(handle: u32) [*:0]const u8 {
    const s = slotOf(handle) orelse return &empty;
    return @ptrCast(&s.err_name);
}

pub export fn maru_mobile_ssh_clear_error(handle: u32) void {
    const s = slotOf(handle) orelse return;
    @memset(&s.err_name, 0);
}
