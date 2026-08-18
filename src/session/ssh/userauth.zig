//! 사용자 인증(RFC 4252) — `publickey`(ed25519)와 `password`.
//!
//! **sans-io 다**(계약 §2). 키를 파일에서 읽는 것도, 비밀번호를 묻는 것도 L4·UI 의 일이다.
//!
//! 순서는 이렇다:
//!
//! ```text
//!   C→S  SSH_MSG_SERVICE_REQUEST (5)   string "ssh-userauth"
//!   S→C  SSH_MSG_SERVICE_ACCEPT  (6)   string "ssh-userauth"
//!   C→S  SSH_MSG_USERAUTH_REQUEST (50) …
//!   S→C  SUCCESS(52) · FAILURE(51) · BANNER(53) · PK_OK(60)
//! ```
//!
//! **서명은 `session_id` 를 덮는다**(§7). `session_id` 는 **첫 KEX 의 교환 해시 `H`** 이므로
//! (계약 §4.2), 그 서명은 "이 연결에서" 개인키를 가졌다는 증거가 된다 — 다른 연결로 옮겨 붙일
//! 수 없다. 그래서 재키잉이 일어나도 `session_id` 는 안 바뀐다.
//!
//! **개인키는 여기서만 잠깐 산다.** host 가 OS 저장소에서 꺼내 메모리로 넘기고(계약 §4), 서명
//! 직후 호출자가 그 버퍼를 지운다 — 이 층은 복사해 두지 않는다.

const std = @import("std");
const wire = @import("wire.zig");
const hostkey = @import("hostkey.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const msg_service_request: u8 = 5;
pub const msg_service_accept: u8 = 6;
pub const msg_userauth_request: u8 = 50;
pub const msg_userauth_failure: u8 = 51;
pub const msg_userauth_success: u8 = 52;
pub const msg_userauth_banner: u8 = 53;
/// **번호 60 은 방법마다 뜻이 다르다**(RFC 4252 §5.4 — "method specific"). 우리가 하는 두 방법에서
/// 이미 갈린다: `publickey` 면 `PK_OK`(§7), `password` 면 **`PASSWD_CHANGEREQ`**(§8) 다.
/// (`keyboard-interactive` 에서는 또 `INFO_REQUEST` 다 — 방법을 늘리면 여기부터 갈라야 한다.)
///
/// 그래서 `parseResponse` 는 **어느 방법으로 요청했는지**를 받는다. 처음에는 안 받고 무조건 `PK_OK`
/// 로 읽었는데, 그러면 만료된 비밀번호에 서버가 보내는 변경 요구가 "이 키를 받아 줄 테니 서명을
/// 보내라" 로 읽히고, 그 **공격자가 고른 프롬프트 텍스트가 `sanitizeBanner` 를 안 거쳐** 배너에
/// 대해 닫아 둔 OSC 0/2/52 구멍이 다시 열린다.
pub const msg_userauth_method_specific: u8 = 60;

pub const service_name = "ssh-userauth";
pub const method_publickey = "publickey";
pub const method_password = "password";
/// 인증이 끝나면 열 서비스. 요청의 'service name' 자리에 들어간다(§7 의 서명에도 포함된다).
pub const connection_service = "ssh-connection";

/// ed25519 개인키의 SSH 표현 — `seed(32) ‖ public(32)`. `openssh-key-v1` 이 그렇게 담고(S6b),
/// `std.crypto` 의 `SecretKey` 와도 같은 모양이다.
pub const secret_key_len = Ed25519.SecretKey.encoded_length;

pub const Error = error{
    /// 서버가 다른 서비스를 수락했다 — 요청한 것과 다르면 진행하면 안 된다.
    UnexpectedService,
    /// 응답 메시지 번호를 모른다.
    UnexpectedMessage,
    /// 개인키가 유효한 ed25519 키가 아니다.
    BadPrivateKey,
} || wire.Error || wire.Writer.WriteError || hostkey.Error;

/// `SSH_MSG_SERVICE_REQUEST` — 인증 서비스를 열어 달라고 한다.
pub fn writeServiceRequest(out: []u8) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_service_request);
    try w.string(service_name);
    return w.written();
}

/// `SSH_MSG_SERVICE_ACCEPT` 를 확인한다. **이름이 우리가 청한 것과 같아야 한다** — 서버가 다른
/// 서비스를 열어 줬는데 우리가 인증을 밀어 넣으면 그 뒤 응답을 엉뚱하게 읽는다.
pub fn parseServiceAccept(payload: []const u8) Error!void {
    var r = wire.Reader.init(payload);
    if ((try r.byte()) != msg_service_accept) return Error.UnexpectedMessage;
    if (!std.mem.eql(u8, try r.string(), service_name)) return Error.UnexpectedService;
}

/// ed25519 개인키에서 SSH 공개키 blob 을 만든다(`string "ssh-ed25519" · string key`).
pub fn publicKeyBlob(out: []u8, secret: [secret_key_len]u8) Error![]const u8 {
    var pair = keyPair(secret) catch return Error.BadPrivateKey;
    defer wipe(&pair);
    var w = wire.Writer.init(out);
    try w.string(hostkey.alg_name);
    try w.string(&pair.public_key.toBytes());
    return w.written();
}

/// **서명 대상**(RFC 4252 §7). 요청 패킷과 **필드가 같되 앞에 `session_id` 가 붙고 서명 자체는
/// 빠진** 바이트 열이다 — 그래서 요청을 그대로 재사용하지 않고 따로 만든다(같은 것으로 착각해
/// 요청 바이트에 서명하면 서버가 거절하고, 왜인지 알기 어렵다).
pub fn signedData(
    out: []u8,
    session_id: []const u8,
    user: []const u8,
    key_blob: []const u8,
) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.string(session_id);
    try w.byte(msg_userauth_request);
    try w.string(user);
    try w.string(connection_service);
    try w.string(method_publickey);
    try w.boolean(true);
    try w.string(hostkey.alg_name);
    try w.string(key_blob);
    return w.written();
}

/// 서명 blob(`string "ssh-ed25519" · string signature`)을 만든다.
///
/// **개인키를 복사해 두지 않는다.** 호출자는 이 함수가 끝난 뒤 자기 버퍼를 지운다(계약 §4).
pub fn signBlob(out: []u8, secret: [secret_key_len]u8, data: []const u8) Error![]const u8 {
    var pair = keyPair(secret) catch return Error.BadPrivateKey;
    defer wipe(&pair);
    const sig = pair.sign(data, null) catch return Error.BadPrivateKey;
    var w = wire.Writer.init(out);
    try w.string(hostkey.alg_name);
    try w.string(&sig.toBytes());
    return w.written();
}

/// `publickey` 인증 요청. `signature_blob` 은 `signBlob` 이 만든 것이다.
pub fn writePublicKeyRequest(
    out: []u8,
    user: []const u8,
    key_blob: []const u8,
    signature_blob: []const u8,
) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_userauth_request);
    try w.string(user);
    try w.string(connection_service);
    try w.string(method_publickey);
    try w.boolean(true);
    try w.string(hostkey.alg_name);
    try w.string(key_blob);
    try w.string(signature_blob);
    return w.written();
}

/// `password` 인증 요청(§8).
///
/// **비밀번호가 이 바이트 열에 그대로 들어간다.** 암호 계층 아래로 나가므로 선에서는 안 보이지만,
/// 이 버퍼는 호출자가 다 쓴 뒤 **지워야 한다**(계약 §3.4 — 저장하지 않는다).
pub fn writePasswordRequest(out: []u8, user: []const u8, password: []const u8) Error![]const u8 {
    var w = wire.Writer.init(out);
    try w.byte(msg_userauth_request);
    try w.string(user);
    try w.string(connection_service);
    try w.string(method_password);
    try w.boolean(false); // 비밀번호 **변경**이 아니다(true 면 새 비밀번호가 하나 더 붙는다)
    try w.string(password);
    return w.written();
}

/// 서버 응답.
pub const Response = union(enum) {
    success,
    failure: struct {
        /// 아직 시도할 수 있는 방법들. **비어 있으면 더 해 볼 것이 없다.**
        methods: wire.NameList,
        /// 참이면 이 방법은 통했고 **다른 방법이 더 필요하다**(2FA). 실패로 읽으면 안 된다.
        partial_success: bool,
    },
    /// 서버가 보여 주라는 문구. **원문 그대로다** — 보여 주기 전에 `sanitizeBanner` 를 거친다
    /// (RFC 4252 §5.4: "control character filtering ... SHOULD be used").
    banner: struct { message: []const u8, language: []const u8 },
    /// 이 키로 인증해도 된다는 뜻(§7). 우리는 서명을 바로 보내므로 보통 안 온다.
    pk_ok: struct { algorithm: []const u8, key_blob: []const u8 },
    /// **비밀번호가 만료돼 바꾸라는 요구**(§8 — 서버가 SHOULD 로 보낸다). `prompt` 는 **원문**이라
    /// 보여 주기 전에 `sanitizeBanner` 를 거친다(배너와 같은 이유 — 검증 안 된 상대의 텍스트다).
    /// 우리는 비밀번호 변경을 안 하므로 상위는 이것을 실패로 다루되 그 문구는 보여 준다.
    passwd_change_req: struct { prompt: []const u8, language: []const u8 },
};

/// 어느 방법으로 요청했나 — **번호 60 의 해석이 여기 달렸다**(위 상수 주석).
pub const Method = enum { publickey, password };

pub fn parseResponse(payload: []const u8, method: Method) Error!Response {
    var r = wire.Reader.init(payload);
    return switch (try r.byte()) {
        msg_userauth_success => .success,
        msg_userauth_failure => .{ .failure = .{
            .methods = try r.nameList(),
            .partial_success = try r.boolean(),
        } },
        msg_userauth_banner => .{ .banner = .{
            .message = try r.string(),
            .language = try r.string(),
        } },
        msg_userauth_method_specific => switch (method) {
            .publickey => .{ .pk_ok = .{
                .algorithm = try r.string(),
                .key_blob = try r.string(),
            } },
            .password => .{ .passwd_change_req = .{
                .prompt = try r.string(),
                .language = try r.string(),
            } },
        },
        else => Error.UnexpectedMessage,
    };
}

/// 키쌍 안의 비밀 바이트를 지운다.
///
/// **계약 §4 는 소거를 코어의 일로 정한다.** 모듈 주석이 "개인키를 복사해 두지 않는다" 고 적었지만
/// 그것은 사실이 아니었다 — 값으로 받은 인자와 `SecretKey`·`KeyPair` 가 **세 겹 스택 프레임**에
/// 남는다. 호출자가 자기 버퍼를 지워도 그것들은 그대로라, 계약이 걱정하는 바로 그 플랫폼에서
/// 코어 덤프·스왑이 키를 유출한다.
/// 키쌍의 **비밀만** 지운다.
///
/// **호출부의 `defer wipe(&pair)` 는 변이 검사로 못 잡는다 — 스택 지역이라 테스트가 그것을 볼
/// 방법이 없다**(실측: 세 자리 모두 지우기를 빼도 전 테스트가 통과한다). 그래서 검정력은 여기,
/// 헬퍼에 건다: "무엇을 지우고 무엇을 남기나" 가 틀리면(예: 통째로 밀어 공개키까지 날리기, 또는
/// 아무것도 안 지우기) 아래 테스트가 죽는다. 호출부가 빠진 것은 코드 리뷰가 볼 몫이다.
fn wipe(pair: *Ed25519.KeyPair) void {
    std.crypto.secureZero(u8, &pair.secret_key.bytes);
}

/// 배너를 화면에 올리기 전에 거르는 정책(RFC 4252 §5.4 — "control character filtering ...
/// SHOULD be used to avoid attacks by sending terminal control characters").
///
/// **이것은 인증도 하기 전에, 아직 아무것도 검증되지 않은 상대가 보낸 텍스트다.** 걸러 내지 않으면
/// maru 코어가 처리하는 OSC 0/2(제목)·OSC 52(클립보드)가 열린다 — 버전 줄에서와 같은 위험이고
/// (계약 §3.2.2), 다른 점은 배너는 **교환 해시에 안 들어가서 씻어 낼 수 있다**는 것뿐이다.
///
/// **여러 줄은 정상이다**(§5.4 — "may consist of multiple lines ... CRLF"). 그래서 `\n` 과 `\t` 는
/// 남기고 나머지 C0·DEL 만 버린다. CR 도 버리므로 CRLF 는 LF 가 된다 — 터미널이 원하는 모양이고,
/// 홀로 남은 CR 로 앞 줄을 덮어쓰는 수법도 같이 막힌다.
///
/// 출력은 입력보다 길어지지 않는다. `out` 이 그보다 작으면 **자르지 않고 실패한다** — 잘린 법적
/// 고지를 보여 주는 것은 안 보여 주는 것보다 나쁠 수 있다.
pub fn sanitizeBanner(out: []u8, message: []const u8) Error![]const u8 {
    if (out.len < message.len) return hostkey.Error.ShortBuffer;
    var n: usize = 0;
    for (message) |c| {
        if (c == '\n' or c == '\t') {
            out[n] = c;
            n += 1;
        } else if (c < 0x20 or c == 0x7F) {
            continue; // CR 포함 — 나머지 제어문자는 버린다
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

/// 개인키에서 키쌍을 만든다. **공개키가 씨앗에서 유도된 것인지 여기서 직접 잰다.**
///
/// `Ed25519.KeyPair.fromSecretKey` 안에도 같은 검사가 있지만 그것은 `if (std.debug.runtime_safety)`
/// 뒤에 있어 **배포 `.dmg` 가 쓰는 ReleaseFast 에서 사라진다**(실측: 그 모드에서만 테스트가 깨졌고,
/// `zig build test` 는 Debug 라 CI 가 못 봤다). 그러면 씨앗과 안 맞는 공개키를 광고하면서 서명해
/// 서버만 USERAUTH_FAILURE 를 내고, 계약 §4.4.3 이 약속한 "왜 인증이 안 되는지" 가 사라진다.
///
/// **`private_key` 에도 같은 대조가 있는데 중복이 아니다.** 그쪽은 *파일*이 일관적인지 보고, 여기는
/// *건네받은 씨앗*이 그런지 본다 — 이 함수의 입력은 파일에서만 오지 않는다(Keychain·Keystore·
/// 테스트). 신뢰 경계가 둘이라 검사도 둘이고, 그래서 오류 이름도 각 호출자에 맞게 다르다.
fn keyPair(secret: [secret_key_len]u8) !Ed25519.KeyPair {
    const derived = try Ed25519.KeyPair.generateDeterministic(secret[0..32].*);
    if (!std.mem.eql(u8, secret[32..64], &derived.public_key.toBytes())) return error.KeyMismatch;
    return derived;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

/// RFC 8032 §7.1 TEST 2 의 씨앗·공개키 — 서명이 그 벡터와 맞는지 확인하는 데 쓴다.
const seed = [_]u8{
    0x4c, 0xcd, 0x08, 0x9b, 0x28, 0xff, 0x96, 0xda, 0x9d, 0xb6, 0xc3, 0x46, 0xec, 0x11, 0x4e, 0x0f,
    0x5b, 0x8a, 0x31, 0x9f, 0x35, 0xab, 0xa6, 0x24, 0xda, 0x8c, 0xf6, 0xed, 0x4f, 0xb8, 0xa6, 0xfb,
};
const public = [_]u8{
    0x3d, 0x40, 0x17, 0xc3, 0xe8, 0x43, 0x89, 0x5a, 0x92, 0xb7, 0x0a, 0xa7, 0x4d, 0x1b, 0x7e, 0xbc,
    0x9c, 0x98, 0x2c, 0xcf, 0x2e, 0xc4, 0x96, 0x8c, 0xc0, 0xcd, 0x55, 0xf1, 0x2a, 0xf4, 0x66, 0x0c,
};
/// 같은 벡터의 메시지 `0x72` 에 대한 서명.
const sig_of_72 = [_]u8{
    0x92, 0xa0, 0x09, 0xa9, 0xf0, 0xd4, 0xca, 0xb8, 0x72, 0x0e, 0x82, 0x0b, 0x5f, 0x64, 0x25, 0x40,
    0xa2, 0xb2, 0x7b, 0x54, 0x16, 0x50, 0x3f, 0x8f, 0xb3, 0x76, 0x22, 0x23, 0xeb, 0xdb, 0x69, 0xda,
    0x08, 0x5a, 0xc1, 0xe4, 0x3e, 0x15, 0x99, 0x6e, 0x45, 0x8f, 0x36, 0x13, 0xd0, 0xf1, 0x1d, 0x8c,
    0x38, 0x7b, 0x2e, 0xae, 0xb4, 0x30, 0x2a, 0xee, 0xb0, 0x0d, 0x29, 0x16, 0x12, 0xbb, 0x0c, 0x00,
};

fn secretKey() [secret_key_len]u8 {
    var sk: [secret_key_len]u8 = undefined;
    @memcpy(sk[0..32], &seed);
    @memcpy(sk[32..64], &public);
    return sk;
}

test "서비스 요청과 수락" {
    var out: [64]u8 = undefined;
    const req = try writeServiceRequest(&out);
    try std.testing.expectEqual(msg_service_request, req[0]);
    var r = wire.Reader.init(req[1..]);
    try std.testing.expectEqualStrings(service_name, try r.string());

    // 수락은 **같은 이름**이어야 한다.
    var ok: [64]u8 = undefined;
    var w = wire.Writer.init(&ok);
    try w.byte(msg_service_accept);
    try w.string(service_name);
    try parseServiceAccept(w.written());

    // 다른 서비스를 열어 줬으면 진행하면 안 된다 — 그 뒤 응답을 엉뚱하게 읽는다.
    var other = wire.Writer.init(&ok);
    try other.byte(msg_service_accept);
    try other.string("ssh-connection");
    try std.testing.expectError(Error.UnexpectedService, parseServiceAccept(other.written()));

    // 메시지 번호가 다르면 거절한다.
    var wrong = wire.Writer.init(&ok);
    try wrong.byte(msg_userauth_success);
    try wrong.string(service_name);
    try std.testing.expectError(Error.UnexpectedMessage, parseServiceAccept(wrong.written()));
}

test "공개키 blob 이 개인키에서 나온다" {
    var out: [128]u8 = undefined;
    const blob = try publicKeyBlob(&out, secretKey());
    try std.testing.expectEqualSlices(u8, &public, &(try hostkey.parsePublicKey(blob)));
}

test "서명은 RFC 8032 벡터와 맞는다" {
    // **우리가 만든 값끼리 맞추면 자기충족이다.** 공개 벡터의 메시지에 서명해 같은 바이트가
    // 나오는지 본다(ed25519 는 결정론이라 이 대조가 성립한다).
    var out: [128]u8 = undefined;
    const blob = try signBlob(&out, secretKey(), &[_]u8{0x72});
    try std.testing.expectEqualSlices(u8, &sig_of_72, &(try hostkey.parseSignature(blob)));
}

test "서명 대상은 session_id 를 덮는다" {
    // **§7 의 순서 그대로다.** 하나만 어긋나도 서버가 거절하고, 그때 이유를 알 방법이 없다.
    var out: [512]u8 = undefined;
    const key_blob = try publicKeyBlob(out[256..], secretKey());
    const data = try signedData(out[0..256], "SESSION-ID", "alice", key_blob);

    var expect: [512]u8 = undefined;
    var w = wire.Writer.init(&expect);
    try w.string("SESSION-ID");
    try w.byte(msg_userauth_request);
    try w.string("alice");
    try w.string("ssh-connection");
    try w.string("publickey");
    try w.boolean(true);
    try w.string("ssh-ed25519");
    try w.string(key_blob);
    try std.testing.expectEqualSlices(u8, w.written(), data);

    // **session_id 가 다르면 다른 바이트다** — 다른 연결로 서명을 옮겨 붙일 수 없다는 뜻이다.
    var other: [256]u8 = undefined;
    const data2 = try signedData(&other, "OTHER-SESSION", "alice", key_blob);
    try std.testing.expect(!std.mem.eql(u8, data, data2));

    // 사용자 이름이 달라도 다르다.
    var third: [256]u8 = undefined;
    const data3 = try signedData(&third, "SESSION-ID", "bob", key_blob);
    try std.testing.expect(!std.mem.eql(u8, data, data3));
}

test "publickey 요청은 서명 대상과 필드가 같다" {
    // 요청과 서명 대상은 **`session_id` 와 서명 자리만** 다르다. 그 관계가 깨지면 서버가 우리
    // 서명을 다른 바이트에 대해 검증하게 된다.
    var buf: [1024]u8 = undefined;
    const key_blob = try publicKeyBlob(buf[768..], secretKey());
    const data = try signedData(buf[0..256], "SID", "alice", key_blob);
    const sig = try signBlob(buf[256..384], secretKey(), data);
    const req = try writePublicKeyRequest(buf[384..768], "alice", key_blob, sig);

    var r = wire.Reader.init(req);
    try std.testing.expectEqual(msg_userauth_request, try r.byte());
    try std.testing.expectEqualStrings("alice", try r.string());
    try std.testing.expectEqualStrings("ssh-connection", try r.string());
    try std.testing.expectEqualStrings("publickey", try r.string());
    try std.testing.expect(try r.boolean());
    try std.testing.expectEqualStrings("ssh-ed25519", try r.string());
    try std.testing.expectEqualSlices(u8, key_blob, try r.string());
    try std.testing.expectEqualSlices(u8, sig, try r.string());

    // **서명이 그 대상에 대해 실제로 검증된다** — 서버가 하는 일을 우리가 흉내 내 본다.
    try hostkey.verifyExchangeHash(key_blob, sig, data);
    // 대상이 한 바이트만 달라도 안 맞는다.
    var tampered: [256]u8 = undefined;
    @memcpy(tampered[0..data.len], data);
    tampered[data.len - 1] ^= 1;
    try std.testing.expectError(
        hostkey.Error.BadSignature,
        hostkey.verifyExchangeHash(key_blob, sig, tampered[0..data.len]),
    );
}

test "password 요청" {
    var out: [256]u8 = undefined;
    const req = try writePasswordRequest(&out, "alice", "hunter2");
    var r = wire.Reader.init(req);
    try std.testing.expectEqual(msg_userauth_request, try r.byte());
    try std.testing.expectEqualStrings("alice", try r.string());
    try std.testing.expectEqualStrings("ssh-connection", try r.string());
    try std.testing.expectEqualStrings("password", try r.string());
    // **false 여야 한다.** true 면 비밀번호 **변경** 요청이 되어 새 비밀번호가 하나 더 붙는다.
    try std.testing.expect(!(try r.boolean()));
    try std.testing.expectEqualStrings("hunter2", try r.string());

    // 빈 비밀번호도 그대로 실어 보낸다(서버가 판단할 일이다).
    const empty = try writePasswordRequest(&out, "alice", "");
    var r2 = wire.Reader.init(empty[1..]);
    _ = try r2.string();
    _ = try r2.string();
    _ = try r2.string();
    _ = try r2.boolean();
    try std.testing.expectEqual(@as(usize, 0), (try r2.string()).len);
}

test "응답을 읽는다" {
    var buf: [256]u8 = undefined;

    var w = wire.Writer.init(&buf);
    try w.byte(msg_userauth_success);
    try std.testing.expectEqual(Response.success, try parseResponse(w.written(), .publickey));

    var f = wire.Writer.init(&buf);
    try f.byte(msg_userauth_failure);
    try f.nameList(&.{ "publickey", "password" });
    try f.boolean(false);
    switch (try parseResponse(f.written(), .publickey)) {
        .failure => |fail| {
            try std.testing.expect(fail.methods.has("password"));
            try std.testing.expect(!fail.partial_success);
        },
        else => return error.WrongVariant,
    }

    // **partial success 는 실패가 아니다**(2FA) — 실패로 읽으면 붙을 수 있는 서버를 포기한다.
    var p = wire.Writer.init(&buf);
    try p.byte(msg_userauth_failure);
    try p.nameList(&.{"password"});
    try p.boolean(true);
    switch (try parseResponse(p.written(), .publickey)) {
        .failure => |fail| try std.testing.expect(fail.partial_success),
        else => return error.WrongVariant,
    }

    var b = wire.Writer.init(&buf);
    try b.byte(msg_userauth_banner);
    try b.string("welcome");
    try b.string("en");
    switch (try parseResponse(b.written(), .publickey)) {
        .banner => |banner| {
            try std.testing.expectEqualStrings("welcome", banner.message);
            try std.testing.expectEqualStrings("en", banner.language);
        },
        else => return error.WrongVariant,
    }

    var k = wire.Writer.init(&buf);
    try k.byte(msg_userauth_method_specific);
    try k.string("ssh-ed25519");
    try k.string("blob");
    switch (try parseResponse(k.written(), .publickey)) {
        .pk_ok => |ok| {
            try std.testing.expectEqualStrings("ssh-ed25519", ok.algorithm);
            try std.testing.expectEqualStrings("blob", ok.key_blob);
        },
        else => return error.WrongVariant,
    }

    // 모르는 번호는 거절한다.
    var u = wire.Writer.init(&buf);
    try u.byte(99);
    try std.testing.expectError(Error.UnexpectedMessage, parseResponse(u.written(), .publickey));
}

test "번호 60 은 방법마다 다르게 읽는다" {
    // RFC 4252 §5.4 — 60 은 "method specific" 이고, **우리가 하는 두 방법에서 이미 갈린다**:
    // `publickey` 면 PK_OK(§7), `password` 면 PASSWD_CHANGEREQ(§8 — 만료된 비밀번호에 서버가
    // SHOULD 로 보낸다). 무조건 PK_OK 로 읽으면 비밀번호 변경 요구가 "서명을 보내라" 로 읽힌다.
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_userauth_method_specific);
    try w.string("your password has expired");
    try w.string("en");
    const bytes = w.written();

    switch (try parseResponse(bytes, .publickey)) {
        .pk_ok => |ok| try std.testing.expectEqualStrings("your password has expired", ok.algorithm),
        else => return error.WrongVariant,
    }
    switch (try parseResponse(bytes, .password)) {
        .passwd_change_req => |req| {
            try std.testing.expectEqualStrings("your password has expired", req.prompt);
            try std.testing.expectEqualStrings("en", req.language);
        },
        else => return error.WrongVariant,
    }

    // **그 프롬프트도 검증 안 된 상대의 텍스트다** — 배너와 같이 걸러야 한다. 원문은 그대로
    // 주되(계약대로), `sanitizeBanner` 가 실제로 걸러 내는지 여기서 잇는다.
    var evil = wire.Writer.init(&buf);
    try evil.byte(msg_userauth_method_specific);
    try evil.string("\x1b]0;pwned\x07expired");
    try evil.string("");
    switch (try parseResponse(evil.written(), .password)) {
        .passwd_change_req => |req| {
            try std.testing.expect(std.mem.indexOfScalar(u8, req.prompt, 0x1b) != null); // 원문 그대로
            var clean: [128]u8 = undefined;
            const shown = try sanitizeBanner(&clean, req.prompt);
            try std.testing.expectEqualStrings("]0;pwnedexpired", shown);
        },
        else => return error.WrongVariant,
    }
}

test "배너의 제어문자를 걸러 낸다" {
    // **인증도 하기 전에, 검증되지 않은 상대가 보낸 텍스트다**(RFC 4252 §5.4 — 걸러 쓰라고 한다).
    // 안 거르면 maru 코어가 처리하는 OSC 0/2·52 가 열린다(계약 §3.2.2 의 버전 줄과 같은 위험).
    var out: [256]u8 = undefined;
    const evil = "\x1b]0;pwned\x07\x1b[2Jwarning\x00\x7f";
    const clean = try sanitizeBanner(&out, evil);
    try std.testing.expectEqualStrings("]0;pwned[2Jwarning", clean);
    for (clean) |c| try std.testing.expect(c >= 0x20 and c != 0x7F);

    // **여러 줄은 정상이다**(§5.4) — `\n`·`\t` 는 남고 CR 은 버려 CRLF 가 LF 가 된다.
    try std.testing.expectEqualStrings(
        "line1\nline2\n\tindented",
        try sanitizeBanner(&out, "line1\r\nline2\r\n\tindented"),
    );
    // 0x80 이상(UTF-8 본문)은 그대로 둔다 — 법적 고지가 영어만인 것은 아니다.
    try std.testing.expectEqualStrings("경고: 허가된 사용자만", try sanitizeBanner(&out, "경고: 허가된 사용자만"));
    // 빈 배너.
    try std.testing.expectEqual(@as(usize, 0), (try sanitizeBanner(&out, "")).len);

    // **자르지 않고 실패한다** — 잘린 법적 고지는 안 보여 주느니만 못할 수 있다.
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(hostkey.Error.ShortBuffer, sanitizeBanner(&tiny, "1234"));
}

test "잘린 응답은 거절한다" {
    // **네트워크에서 온 바이트다** — 어느 자리에서 끊겨도 안 죽고 거절해야 한다.
    var buf: [256]u8 = undefined;
    var w = wire.Writer.init(&buf);
    try w.byte(msg_userauth_failure);
    try w.nameList(&.{ "publickey", "password" });
    try w.boolean(false);
    const full = w.written();
    var i: usize = 1;
    while (i < full.len) : (i += 1) {
        if (parseResponse(full[0..i], .publickey)) |_| return error.TruncatedResponseAccepted else |_| {}
    }
    _ = try parseResponse(full, .publickey);
}

test "개인키가 이상하면 거절한다" {
    // 공개키 부분이 스칼라와 안 맞는 키(host 저장소가 깨졌거나 파싱이 틀린 경우).
    var bad = secretKey();
    bad[40] ^= 1;
    var out: [128]u8 = undefined;
    try std.testing.expectError(Error.BadPrivateKey, signBlob(&out, bad, "data"));
}

test "메시지 번호와 이름은 명세 값 그대로다" {
    // 상수를 쓰는 쪽과 읽는 쪽에 함께 쓰면 자기충족이다(앞선 슬라이스들에서 실제로 겪었다).
    try std.testing.expectEqual(@as(u8, 5), msg_service_request); // RFC 4253 §12
    try std.testing.expectEqual(@as(u8, 6), msg_service_accept);
    try std.testing.expectEqual(@as(u8, 50), msg_userauth_request); // RFC 4252 §6
    try std.testing.expectEqual(@as(u8, 51), msg_userauth_failure);
    try std.testing.expectEqual(@as(u8, 52), msg_userauth_success);
    try std.testing.expectEqual(@as(u8, 53), msg_userauth_banner);
    try std.testing.expectEqual(@as(u8, 60), msg_userauth_method_specific); // §7 (방법별 번호)
    try std.testing.expectEqualStrings("ssh-userauth", service_name);
    try std.testing.expectEqualStrings("ssh-connection", connection_service);
    try std.testing.expectEqualStrings("publickey", method_publickey);
    try std.testing.expectEqualStrings("password", method_password);
    try std.testing.expectEqual(@as(usize, 64), secret_key_len);
}

test "wipe 는 비밀만 지우고 공개키는 남긴다" {
    var pair = try Ed25519.KeyPair.generateDeterministic(@as([32]u8, @splat(7)));
    const pub_before = pair.public_key.toBytes();
    try std.testing.expect(!std.mem.allEqual(u8, &pair.secret_key.bytes, 0));

    wipe(&pair);
    try std.testing.expect(std.mem.allEqual(u8, &pair.secret_key.bytes, 0));
    // **공개키는 살아 있어야 한다** — 서명 뒤에도 어느 키였는지 말할 수 있어야 하고, 공개키는
    // 애초에 비밀이 아니다. 통째로 미는 구현이면 여기서 죽는다.
    try std.testing.expectEqualSlices(u8, &pub_before, &pair.public_key.toBytes());
}
