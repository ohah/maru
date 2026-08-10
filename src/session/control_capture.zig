//! control_capture — 컨트롤 플레인 **session.capture 프로토콜 코어**(L2 순수, OS-중립, 헤드리스).
//! Track C slice 1f. 단일 출처: docs/control-plane-protocol.md §4.3(대형 응답 chunk 계약)·§6(`session.capture {id, scrollback?}`)·
//! §8.3(read-output scope)·§8.5(in-flight capture revoke 종료)·§11(slice 1f)·§16(코어 L2 = src/session/).
//!
//! **1a/1c/1d/1e와의 관계**: 1a(control_plane.zig)=wire 프리미티브(JSON-RPC parse/serialize/framer/error-model),
//! 1c(control_surface.zig)=Surface DTO + read-only 응답, 1d(control_dispatch.zig)=바이트→바이트 라우터(metadata),
//! 1e(control_capability.zig)=capability fd 인가(`session.capture`→`read_output`는 이미 `methodRequiredScope`가 매핑).
//! **1f는 그 위에 capture 스트림 프로토콜 상태머신**을 얹는다: chunk 분할·base64·generation 고정/불일치 검출·
//! 완료 마커·capture-invalidated·revoke 종료·재시도 상한 fallback + capture 요청 authz 게이트(ack). 에러 코드·
//! 봉투·id 표현은 1a를 재사용한다(재구현 금지).
//!
//! **capture = chunk 스트림 프로토콜(§4.3)**: 큰 스크롤백을 단일 ndjson 라인으로 못 싣는다 →
//!   1. `session.capture` 요청이 오면 **capture_id + 스냅샷 generation을 고정**하고 ack 응답(`{capture_id, generation}`).
//!   2. 이후 서버가 **chunk notification**을 순서대로 push한다: 각 `{capture_id, seq, generation, encoding, data}`.
//!      `data`는 **base64**(§4.3 — JSON 문자열은 valid UTF-8만 담으므로 임의 바이트/이스케이프 시퀀스/깨진 UTF-8은
//!      base64로만 안전하고, raw-byte chunk 경계가 UTF-8 codepoint를 쪼갤 수 있어 per-chunk UTF-8 통과는 위험하다 →
//!      **항상 base64**로 고정. `encoding` 필드는 forward-compat용이나 현재 값은 base64 하나뿐).
//!   3. 전부 보내면 **완료 마커** notification(`session.capture.complete {capture_id, generation, chunks}`).
//!   4. chunk 경계에서 generation이 바뀌면 **완료 마커 대신** `capture-invalidated` notification으로 종료(client 재시도).
//!
//! **generation 정의 엄수(§4.3, 혼동 금지)**: 여기서 "generation"은 **스크롤백 evict/rewrap 카운터**이지
//! surface 재생성 카운터(§3 `SurfaceDto.generation`)가 **아니다**. 리더 스레드의 evict가 chunk 사이 내용을 shift
//! 시키면 미검출 torn capture가 성공 완료되므로, 스크롤백이 evict/rewrap될 때마다 증가하는 카운터를 chunk 경계마다
//! 재확인한다. 이 카운터가 고정되어 있는 동안만 offset 기반 chunk 슬라이싱이 일관된다(§4.3의 핵심 불변식).
//!
//! **락 규율 모델(§4.3·§5)**: 실 시스템에서 chunk **복사**는 surface `core_mutex` 아래에서, **직렬화**(base64+JSON)는
//! 락 밖에서 한다. 이 코어는 그 데이터 흐름만 모델한다 — `Capture.next`가 "락 아래 읽은 generation·revoked·bytes"를
//! `Boundary`로 받아 다음 `RawChunk`(복사 대상 슬라이스)를 정하고, `serializeChunk`(락 밖)가 base64+notification으로 만든다.
//!
//! **재시도 상한 fallback(§4.3)**: 바쁜 surface에서 매 chunk마다 evict가 나면 영원히 완료 불가·무한 재시도가 된다.
//! 재시도 상한을 넘으면 **"첫 락에서 전체 스크롤백을 1회 복사"**(atomic) 경로로 fallback한다 — 한 번의 락 홀드로 통째
//! 복사하므로 chunk 사이 generation 변경 자체가 없어 capture-invalidated가 불가능하다(메모리 상한 = 전체 스크롤백 1회).
//!
//! **범위(1f, 순수·헤드리스)**: capture 상태머신(chunk 분할·seq·generation 고정/검출·완료/invalidated/revoked 종료)·
//! base64 chunk/완료/invalidated/revoked 직렬화·capture_id 발급기·재시도 상한 strategy·capture 요청 authz 게이트(ack).
//! **주입 스크롤백 소스**(fake byte buffer + generation 카운터)로 구동한다.
//!
//! **범위 밖(구현 금지)**: 실 core 스크롤백 읽기(collector/L4가 `core_mutex` 아래 복사), 실 read-output auth grant
//! (1e fd·1g self-origin — 여기선 **주입 bool**로만 테스트), subscribeOutput 출력 직송(§5 Track 3), outbound 큐·
//! accept-loop 스레드·메인 marshal(§5·L4), app_session. 이것들이 얽히면 넓히지 않는다.
//!
//! **L2 순수:** std + control_plane(1a)만 import한다(app/pty/platform import 0 — tests/boundary/imports.zig가 강제).
//! OS 타입 0. base64는 std.base64만.

const std = @import("std");
const cp = @import("control_plane.zig");

// ── 상수(§4.3·§6) ────────────────────────────────────────────────────────────────────────────────────────
/// 한 chunk의 **raw 스크롤백 바이트** 상한(§4.3 "64 KiB/chunk"). base64 인코딩은 이 raw 경계 위에서 이뤄진다
/// (인코딩 후 크기가 아니라 raw 바이트로 쪼개 결정론적 경계·codepoint 쪼갬 무관하게 한다).
pub const default_chunk_size: usize = 64 * 1024;
/// generation 불일치로 인한 재시도 상한(§4.3). 이 횟수만큼 invalidated된 뒤엔 atomic fallback으로 전환한다.
pub const default_retry_cap: u32 = 3;

/// chunk notification의 method 이름(server→client push). `session.capture.*` 계열로 request `session.capture`와 묶는다.
pub const chunk_method = "session.capture.chunk";
/// 완료 마커 notification의 method 이름(§4.3).
pub const complete_method = "session.capture.complete";
/// capture-invalidated notification의 method 이름(§4.3 — generation 불일치, 완료 마커 대신).
pub const invalidated_method = "session.capture.invalidated";
/// capability revoke로 in-flight capture를 종료하는 notification의 method 이름(§8.5).
pub const revoked_method = "session.capture.revoked";

/// chunk payload 인코딩(§4.3). **항상 base64** — JSON 문자열은 valid UTF-8만 담으므로 임의 바이트/이스케이프
/// 시퀀스/깨진 UTF-8은 base64로만 안전하고, raw-byte chunk 경계가 UTF-8 codepoint를 쪼갤 수 있어 per-chunk UTF-8
/// 통과는 위험하다. `encoding` 필드는 forward-compat용이나 현재 값은 이 하나뿐(document-basis-and-decision).
pub const ChunkEncoding = enum {
    base64,

    pub fn wire(self: ChunkEncoding) []const u8 {
        return switch (self) {
            .base64 => "base64",
        };
    }
};

// ── capture_id 발급기(§4.3 "capture 시작 시 capture_id 고정") ──────────────────────────────────────────────
/// capture_id 발급기(SurfaceIdAllocator 선례). 단조 증가·비재사용 opaque u64. 인스턴스 소유·스레드 계약은 L4
/// (surface_id와 동일 — 메인/dispatch 스레드 전용). 실 시스템에선 capture 시작 시 하나 발급해 그 스트림 전체에 싣는다.
pub const CaptureIdAllocator = struct {
    /// 다음 발급값. 1부터 시작(0은 "미할당" sentinel).
    next_id: u64 = 1,

    pub fn next(self: *CaptureIdAllocator) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

// ── capture 상태머신(§4.3) ────────────────────────────────────────────────────────────────────────────────
/// 한 chunk 경계에서 **락 아래 읽은** 값(§4.3·§5). 실 시스템에선 collector가 `core_mutex` 아래에서 generation·
/// revoked를 읽고(§8.5 chunk 경계마다 재검증) `bytes`를 복사 대상으로 넘긴다 — 이 코어는 그 주입값으로 판정만 한다.
pub const Boundary = struct {
    /// 이 경계에서 읽은 스크롤백 evict/rewrap generation(§4.3 — surface 재생성 아님).
    generation: u64,
    /// capability가 revoke됐는가(§8.5 — dispatch·chunk 경계마다 재검증). true면 완료 마커 없이 즉시 종료.
    revoked: bool = false,
};

/// 락 아래 복사할 다음 chunk(§4.3). `data`는 소스 스냅샷을 **빌린** 슬라이스다(직렬화가 base64로 복사) — DTO는
/// 소유하지 않는다. `generation`은 capture 시작 시 고정된 값(모든 chunk가 같은 값을 싣는다 — 일관성 §4.3).
pub const RawChunk = struct {
    capture_id: u64,
    seq: u32,
    generation: u64,
    data: []const u8,
};

/// capture 스트림의 종단 사유(§4.3·§8.5). 셋 다 스트림을 끝내지만 **완료 마커는 complete뿐**이다.
pub const Terminal = union(enum) {
    /// 전 스크롤백을 다 보냄(§4.3 완료 마커). `chunks`=보낸 총 chunk 수.
    complete: struct { chunks: u32 },
    /// chunk 경계에서 generation이 바뀜(§4.3) — 완료 마커 금지, client 재시도. expected=고정값, actual=바뀐 값.
    invalidated: struct { expected_generation: u64, actual_generation: u64 },
    /// capability revoke(§8.5) — 완료 마커 금지, 구독 종료.
    revoked,
};

/// `Capture.next`의 한 스텝 결과: 다음 chunk이거나 스트림 종단.
pub const Step = union(enum) {
    chunk: RawChunk,
    terminal: Terminal,
};

/// capture 스트림 상태머신(§4.3). `next`를 반복 호출해 chunk를 순서대로 뽑고, 종단(complete/invalidated/revoked)
/// 에서 멈춘다. **순수**: 상태(offset·seq·고정 generation)만 갖고, 소스 bytes·경계값(generation·revoked)은 매 스텝
/// **주입**받는다(실 시스템의 "락 아래 읽기"를 모델).
///
/// 두 모드:
///   - **chunked**(기본): 매 경계에서 generation을 고정값과 대조 → 불일치면 invalidated(§4.3 torn-read 방어).
///   - **atomic**(재시도 상한 fallback): 소스 bytes는 이미 **한 락 홀드로 통째 복사한 스냅샷**이므로 generation
///     검사를 건너뛴다(chunk 사이 변경이 구조적으로 불가 → invalidated 불가). revoked는 여전히 종료시킨다(보안 우선).
pub const Capture = struct {
    capture_id: u64,
    /// capture 시작 시 고정한 스크롤백 generation(§4.3). 모든 chunk가 이 값을 싣고, chunked 모드는 경계마다 이 값과 대조.
    fixed_generation: u64,
    /// raw 바이트 chunk 상한(§4.3 64KiB 기본, 테스트는 작게).
    chunk_size: usize,
    /// atomic fallback 모드인가(§4.3 재시도 상한 — pinned 스냅샷, generation 검사 skip).
    atomic: bool,
    offset: usize = 0,
    seq: u32 = 0,

    /// chunked capture(§4.3 기본 경로). 매 chunk 경계에서 generation을 대조해 torn-read를 검출한다(`atomic=false`).
    pub fn initChunked(capture_id: u64, start_generation: u64, chunk_size: usize) Capture {
        // chunk_size 0이면 next()의 `end = @min(offset+0, len) == offset`이라 offset이 안 늘고 seq만 증가 →
        // 무한 빈 chunk 스트림(never-complete, /code-review max 지적). 최소 1을 보장해 항상 전진·종료한다.
        return .{ .capture_id = capture_id, .fixed_generation = start_generation, .chunk_size = @max(chunk_size, 1), .atomic = false };
    }

    /// atomic fallback capture(§4.3 재시도 상한 초과). 소스 bytes는 한 락 홀드로 통째 복사한 스냅샷이라 generation
    /// 검사를 건너뛴다(invalidated 불가) — 항상 완료한다(revoke는 예외로 종료). `atomic=true`.
    pub fn initAtomic(capture_id: u64, snapshot_generation: u64, chunk_size: usize) Capture {
        // chunk_size 최소 1 보장(initChunked 참조 — 0이면 무한 빈 chunk).
        return .{ .capture_id = capture_id, .fixed_generation = snapshot_generation, .chunk_size = @max(chunk_size, 1), .atomic = true };
    }

    /// 다음 chunk 또는 종단을 돌려준다(§4.3). 확인 순서(§8.5 "경계마다 재검증"): **revoked 먼저**(보안 우선) →
    /// generation(chunked 모드만, torn-read) → 남은 바이트 있으면 chunk, 없으면 complete. `bytes`는 이 경계에서
    /// 읽은 소스(chunked=live 스크롤백, atomic=pinned 스냅샷), `b`는 경계에서 읽은 generation·revoked.
    pub fn next(self: *Capture, bytes: []const u8, b: Boundary) Step {
        if (b.revoked) return .{ .terminal = .revoked };
        if (!self.atomic and b.generation != self.fixed_generation) {
            return .{ .terminal = .{ .invalidated = .{
                .expected_generation = self.fixed_generation,
                .actual_generation = b.generation,
            } } };
        }
        if (self.offset >= bytes.len) return .{ .terminal = .{ .complete = .{ .chunks = self.seq } } };
        const end = @min(self.offset + self.chunk_size, bytes.len);
        const chunk: RawChunk = .{
            .capture_id = self.capture_id,
            .seq = self.seq,
            .generation = self.fixed_generation,
            .data = bytes[self.offset..end],
        };
        self.offset = end;
        self.seq += 1;
        return .{ .chunk = chunk };
    }
};

// ── 재시도 상한 strategy(§4.3) ───────────────────────────────────────────────────────────────────────────
/// capture 시도 전략(§4.3). chunked는 invalidated 가능, atomic_fallback은 한 락 홀드 통째 복사라 항상 완료.
pub const CaptureStrategy = enum { chunked, atomic_fallback };

/// invalidated 누적 횟수가 상한 이상이면 atomic fallback을 택한다(§4.3 무한 재시도 방지).
pub fn strategyForAttempt(invalidations: u32, retry_cap: u32) CaptureStrategy {
    return if (invalidations >= retry_cap) .atomic_fallback else .chunked;
}

/// 한 surface에 대한 capture 재시도 조율기(§4.3). client/server가 capture-invalidated를 받을 때마다 `onInvalidated`
/// 하고, `beginCapture`가 현재 전략에 맞는 `Capture`를 만든다. 상한 초과 시 atomic fallback으로 자동 전환된다.
pub const RetryCoordinator = struct {
    invalidations: u32 = 0,
    retry_cap: u32 = default_retry_cap,

    pub fn onInvalidated(self: *RetryCoordinator) void {
        self.invalidations += 1;
    }

    pub fn strategy(self: RetryCoordinator) CaptureStrategy {
        return strategyForAttempt(self.invalidations, self.retry_cap);
    }

    /// 현재 전략에 맞는 capture 상태머신을 시작한다(§4.3). chunked면 경계마다 generation 대조, atomic이면 pinned.
    pub fn beginCapture(self: RetryCoordinator, capture_id: u64, generation: u64, chunk_size: usize) Capture {
        return switch (self.strategy()) {
            .chunked => Capture.initChunked(capture_id, generation, chunk_size),
            .atomic_fallback => Capture.initAtomic(capture_id, generation, chunk_size),
        };
    }
};

// ── 직렬화(§4.3, base64 + 1a JSON 스타일 재사용) ──────────────────────────────────────────────────────────
// 모든 직렬화는 minified 한 줄(1a와 동일 — ndjson frame 경계 안전). 종단 `\n`은 프레이밍(1b)이 붙인다.

/// chunk를 notification으로 직렬화한다(§4.3): `{"jsonrpc":"2.0","method":"session.capture.chunk","params":
/// {"capture_id":N,"seq":M,"generation":G,"encoding":"base64","data":"<base64>"}}`. `data`는 raw 바이트를 base64로
/// 인코딩한 것(임의 바이트 안전, §4.3). caller가 free.
pub fn serializeChunk(gpa: std.mem.Allocator, chunk: RawChunk) std.mem.Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, encoder.calcSize(chunk.data.len));
    defer gpa.free(b64);
    _ = encoder.encode(b64, chunk.data);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeChunk(&s, chunk, b64) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeChunk(s: *std.json.Stringify, chunk: RawChunk, b64_data: []const u8) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("method");
    try s.write(chunk_method);
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("capture_id");
    try s.write(chunk.capture_id);
    try s.objectField("seq");
    try s.write(chunk.seq);
    try s.objectField("generation");
    try s.write(chunk.generation);
    try s.objectField("encoding");
    try s.write(ChunkEncoding.base64.wire());
    try s.objectField("data");
    try s.write(b64_data);
    try s.endObject();
    try s.endObject();
}

/// 완료 마커 notification(§4.3): `{...,"method":"session.capture.complete","params":{"capture_id":N,"generation":G,
/// "chunks":K}}`. **generation 불일치·revoke로 종료된 스트림엔 절대 보내지 않는다**(§4.3). caller free.
pub fn serializeComplete(gpa: std.mem.Allocator, capture_id: u64, generation: u64, chunks: u32) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeMarker(&s, complete_method, capture_id, .{ .complete = .{ .generation = generation, .chunks = chunks } }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// capture-invalidated notification(§4.3): `{...,"method":"session.capture.invalidated","params":{"capture_id":N,
/// "generation":expected,"actual_generation":actual}}`. generation 불일치로 스트림을 종료(완료 마커 대신). caller free.
pub fn serializeInvalidated(gpa: std.mem.Allocator, capture_id: u64, expected_generation: u64, actual_generation: u64) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeMarker(&s, invalidated_method, capture_id, .{ .invalidated = .{ .expected = expected_generation, .actual = actual_generation } }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// capability-revoked notification(§8.5): `{...,"method":"session.capture.revoked","params":{"capture_id":N}}`.
/// in-flight capture를 완료 마커 없이 종료한다. caller free.
pub fn serializeRevoked(gpa: std.mem.Allocator, capture_id: u64) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeMarker(&s, revoked_method, capture_id, .revoked) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const MarkerParams = union(enum) {
    complete: struct { generation: u64, chunks: u32 },
    invalidated: struct { expected: u64, actual: u64 },
    revoked,
};

fn writeMarker(s: *std.json.Stringify, method: []const u8, capture_id: u64, params: MarkerParams) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("capture_id");
    try s.write(capture_id);
    switch (params) {
        .complete => |c| {
            try s.objectField("generation");
            try s.write(c.generation);
            try s.objectField("chunks");
            try s.write(c.chunks);
        },
        .invalidated => |iv| {
            try s.objectField("generation");
            try s.write(iv.expected);
            try s.objectField("actual_generation");
            try s.write(iv.actual);
        },
        .revoked => {},
    }
    try s.endObject();
    try s.endObject();
}

/// 종단 사유를 그에 맞는 wire notification으로 직렬화한다(§4.3·§8.5 — L4 pump 편의). complete는 완료 마커,
/// invalidated/revoked는 종료 마커. `generation`은 capture의 고정값(complete/invalidated 마커가 싣는다). caller free.
pub fn serializeTerminal(gpa: std.mem.Allocator, capture_id: u64, generation: u64, terminal: Terminal) std.mem.Allocator.Error![]u8 {
    return switch (terminal) {
        .complete => |c| serializeComplete(gpa, capture_id, generation, c.chunks),
        .invalidated => |iv| serializeInvalidated(gpa, capture_id, iv.expected_generation, iv.actual_generation),
        .revoked => serializeRevoked(gpa, capture_id),
    };
}

// ── capture 요청 authz 게이트(§6·§8.3) ────────────────────────────────────────────────────────────────────
const CaptureParamError = error{InvalidParams};

/// `session.capture`의 params `{id, scrollback?}`를 읽는다. id 부재/비정수/음수, scrollback 비-불리언 → InvalidParams.
/// 셀렉터는 surface_id만(generation 한정은 후속 — 1c/1d와 동일 결정).
fn readCaptureParams(params: ?std.json.Value) CaptureParamError!struct { target: u64, scrollback: bool } {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const target = switch (obj.get("id") orelse return error.InvalidParams) {
        .integer => |i| if (i < 0) return error.InvalidParams else @as(u64, @intCast(i)),
        else => return error.InvalidParams,
    };
    const scrollback = switch (obj.get("scrollback") orelse std.json.Value{ .bool = false }) {
        .bool => |bv| bv,
        .null => false,
        else => return error.InvalidParams,
    };
    return .{ .target = target, .scrollback = scrollback };
}

/// `session.capture` 요청 한 줄을 처리해 **ack 응답 바이트**(byte→byte)를 만든다(§6·§8.3). read-output 인가는
/// **주입**(`read_output_authorized` — 실 grant는 1e fd·1g self-origin, 여기선 판정만). `capture_id`·`start_generation`
/// 도 주입(실 시스템에선 L4가 capture 시작 시 발급·`core_mutex` 아래 읽음). 흐름:
///   1. parse 실패 → id=null parse/invalid_request(1a).
///   2. request 아님(notification/response) → invalid_request.
///   3. method != `session.capture` → method_not_found.
///   4. params 오류 → invalid_params.
///   5. **read-output 미인가 → §8.3 균일 unauthorized**(존재검사 이전 — target 존재 여부 무관, oracle 방지).
///   6. 인가 → ack `{"result":{"capture_id":N,"generation":G,"scrollback":bool}}`.
/// ack 이후 chunk 스트림은 `Capture` 상태머신이 별도로 구동한다(L4가 `core_mutex` 아래 pump — §5). caller free.
///
/// **범위 밖(정직)**: target surface 존재 확인(process_exited)은 여기서 안 한다 — snapshot이 필요한 collector/1d
/// 관심사라, L4가 capture 시작 전에 1c/collector로 존재를 확인한 뒤 이 게이트를 부른다(L2 capture 코어는 프로토콜만).
///
/// **tracked follow-up(/code-review max)**: parse→request 추출→parseMethod→method-eql 분류 preamble이
/// `control_dispatch.dispatchReadOnly`와 병렬 중복이다. 분류 계약이 바뀌면 둘을 lockstep 수정해야 하므로,
/// 공유 `classifyRequest` 헬퍼로 추출하는 건 별도 정리 작업(지금은 read-only 라우터와 capture 게이트의
/// downstream이 달라 preamble만 겹침 — 재작성 리스크 대비 가치 낮아 분리).
pub fn dispatchCaptureAck(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    read_output_authorized: bool,
    capture_id: u64,
    start_generation: u64,
) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResp(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResp(gpa, .null, .invalid_request),
    };

    const method = cp.parseMethod(req.method);
    if (!(method.core == .session and std.mem.eql(u8, method.rest, "capture"))) {
        return errorResp(gpa, req.id, .method_not_found);
    }

    const parsed = readCaptureParams(req.params) catch return errorResp(gpa, req.id, .invalid_params);

    // §8.3: read-output 미인가면 존재검사 이전에 균일 unauthorized(surface_id 열거 oracle 방지).
    if (!read_output_authorized) return errorResp(gpa, req.id, .unauthorized);

    return serializeAck(gpa, req.id, capture_id, start_generation, parsed.scrollback);
}

fn errorResp(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

fn serializeAck(gpa: std.mem.Allocator, id: cp.Id, capture_id: u64, generation: u64, scrollback: bool) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeAck(&s, id, capture_id, generation, scrollback) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeAck(s: *std.json.Stringify, id: cp.Id, capture_id: u64, generation: u64, scrollback: bool) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("id");
    try cp.writeId(s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("capture_id");
    try s.write(capture_id);
    try s.objectField("generation");
    try s.write(generation);
    try s.objectField("scrollback");
    try s.write(scrollback);
    try s.endObject();
    try s.endObject();
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓/실 스크롤백/실 auth 0) ═══════════════════════════════════
const testing = std.testing;

// ── 테스트 pump 헬퍼: capture 상태머신을 종단까지 몰아 wire 프레임 목록을 만든다(L4 pump 루프 모델) ──────────
// 실 시스템에선 L4가 tick마다 `next`(락 아래 읽기)→`serialize`(락 밖)를 반복한다. 여기선 고정 소스로 한 번에 몬다.
// `gen_at` = seq번째 next 경계에서 읽을 generation(chunked torn-read 시뮬), `revoke_at` = 그 경계에서 revoked.
const PumpResult = struct {
    frames: std.ArrayList([]u8),
    terminal: Terminal,

    fn deinit(self: *PumpResult, gpa: std.mem.Allocator) void {
        for (self.frames.items) |f| gpa.free(f);
        self.frames.deinit(gpa);
    }
};

const PumpSchedule = struct {
    /// 각 경계에서 읽을 generation(index=경계 순번). 모자라면 마지막 값을 유지. 빈 슬라이스면 항상 base_gen.
    gens: []const u64 = &.{},
    base_gen: u64,
    /// 이 경계 순번(0-based)에서 revoked=true. null이면 revoke 없음.
    revoke_at: ?usize = null,
};

fn genAt(sched: PumpSchedule, boundary_index: usize) u64 {
    if (sched.gens.len == 0) return sched.base_gen;
    if (boundary_index < sched.gens.len) return sched.gens[boundary_index];
    return sched.gens[sched.gens.len - 1];
}

fn pump(gpa: std.mem.Allocator, cap: *Capture, bytes: []const u8, sched: PumpSchedule) !PumpResult {
    var frames: std.ArrayList([]u8) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f);
        frames.deinit(gpa);
    }
    var boundary: usize = 0;
    while (true) : (boundary += 1) {
        const b: Boundary = .{ .generation = genAt(sched, boundary), .revoked = sched.revoke_at == boundary };
        switch (cap.next(bytes, b)) {
            .chunk => |c| try frames.append(gpa, try serializeChunk(gpa, c)),
            .terminal => |t| {
                // 종단 마커도 wire로 실어 스트림을 완성한다(complete/invalidated/revoked).
                try frames.append(gpa, try serializeTerminal(gpa, cap.capture_id, cap.fixed_generation, t));
                return .{ .frames = frames, .terminal = t };
            },
        }
    }
}

// 한 chunk notification wire에서 (seq, generation, base64-디코드된 data)를 뽑는다.
fn decodeChunk(gpa: std.mem.Allocator, wire: []const u8, out_seq: *u64, out_gen: *u64) ![]u8 {
    var pm = try cp.parseMessage(gpa, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    try testing.expectEqualStrings(chunk_method, pm.message.notification.method);
    const p = pm.message.notification.params.?.object;
    out_seq.* = @intCast(p.get("seq").?.integer);
    out_gen.* = @intCast(p.get("generation").?.integer);
    try testing.expectEqualStrings("base64", p.get("encoding").?.string);
    const b64 = p.get("data").?.string;
    const decoder = std.base64.standard.Decoder;
    const raw = try gpa.alloc(u8, try decoder.calcSizeForSlice(b64));
    errdefer gpa.free(raw);
    try decoder.decode(raw, b64);
    return raw;
}

// ── 1) chunk seq 순서 + generation 고정 + base64 round-trip(핵심 계약) ──
test "capture: 다중 chunk가 seq 오름차순·같은 generation·base64로 원문을 무손실 재조립한다" {
    const scrollback = "ABCDEFGHIJ0123456789xyz"; // 23바이트
    var cap = Capture.initChunked(7, 42, 10); // chunk_size=10 → 10,10,3 = 3 chunk
    var res = try pump(testing.allocator, &cap, scrollback, .{ .base_gen = 42 });
    defer res.deinit(testing.allocator);

    // 마지막 프레임은 complete, 앞 3개는 chunk.
    try testing.expect(res.terminal == .complete);
    try testing.expectEqual(@as(u32, 3), res.terminal.complete.chunks);
    try testing.expectEqual(@as(usize, 4), res.frames.items.len); // chunk×3 + complete

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(testing.allocator);
    var expected_seq: u64 = 0;
    for (res.frames.items[0..3]) |wire| {
        var seq: u64 = undefined;
        var gen: u64 = undefined;
        const raw = try decodeChunk(testing.allocator, wire, &seq, &gen);
        defer testing.allocator.free(raw);
        try testing.expectEqual(expected_seq, seq); // seq 오름차순
        try testing.expectEqual(@as(u64, 42), gen); // 모든 chunk가 같은 고정 generation
        try reassembled.appendSlice(testing.allocator, raw);
        expected_seq += 1;
    }
    try testing.expectEqualStrings(scrollback, reassembled.items); // 무손실

    // complete 마커 검증.
    var pm = try cp.parseMessage(testing.allocator, res.frames.items[3]);
    defer pm.deinit();
    try testing.expectEqualStrings(complete_method, pm.message.notification.method);
    const cparams = pm.message.notification.params.?.object;
    try testing.expectEqual(@as(i64, 3), cparams.get("chunks").?.integer);
    try testing.expectEqual(@as(i64, 42), cparams.get("generation").?.integer);
}

// ── 2) base64가 임의(비-UTF8) 바이트를 안전하게 싣는다(§4.3 핵심) ──
test "capture base64: 비-UTF8·이스케이프 시퀀스·NUL 바이트가 base64로 무손실 왕복된다" {
    // 깨진 UTF-8(0xFF,0xFE), ESC(0x1B), NUL, 개행 — JSON 문자열에 raw로 못 담는 바이트들.
    const raw_bytes = [_]u8{ 0xFF, 0xFE, 0x1B, '[', '3', '1', 'm', 0x00, '\n', 0x80, 0xC0 };
    var cap = Capture.initChunked(1, 5, 1024); // 한 chunk에 다 담김
    var res = try pump(testing.allocator, &cap, &raw_bytes, .{ .base_gen = 5 });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), res.frames.items.len); // chunk 1 + complete

    // wire는 valid JSON(raw 개행·NUL 없음 — base64라 ASCII만).
    const chunk_wire = res.frames.items[0];
    try testing.expect(std.mem.indexOfScalar(u8, chunk_wire, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, chunk_wire, 0x00) == null);
    try testing.expect(std.mem.indexOfScalar(u8, chunk_wire, 0x1B) == null);

    var seq: u64 = undefined;
    var gen: u64 = undefined;
    const decoded = try decodeChunk(testing.allocator, chunk_wire, &seq, &gen);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &raw_bytes, decoded); // 무손실
}

// ── 3) 빈 스크롤백 → chunk 0개, 즉시 complete(chunks=0) ──
test "capture 빈 스크롤백: chunk 없이 즉시 complete(chunks=0), invalidated 아님" {
    const empty = "";
    var cap = Capture.initChunked(9, 0, 64);
    var res = try pump(testing.allocator, &cap, empty, .{ .base_gen = 0 });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res.frames.items.len); // complete만
    try testing.expect(res.terminal == .complete);
    try testing.expectEqual(@as(u32, 0), res.terminal.complete.chunks);
    var pm = try cp.parseMessage(testing.allocator, res.frames.items[0]);
    defer pm.deinit();
    try testing.expectEqualStrings(complete_method, pm.message.notification.method);
}

// ── 3b) chunk_size 0 가드: 클램프(최소 1) 없으면 offset이 안 늘어 무한 빈 chunk(never-complete) — /code-review max 지적 ──
test "capture chunk_size 0: 최소 1로 클램프돼 무한루프 없이 종료(바이트당 1 chunk + complete)" {
    const scrollback = "AB"; // 2바이트
    var cap = Capture.initChunked(1, 3, 0); // chunk_size=0 주입 → 클램프 안 하면 pump가 무한루프
    var res = try pump(testing.allocator, &cap, scrollback, .{ .base_gen = 3 });
    defer res.deinit(testing.allocator);
    // 클램프(0→1)로 1바이트 chunk 2개 + complete = 3 프레임, chunks=2. (무한루프면 이 지점에 도달 못 함.)
    try testing.expect(res.terminal == .complete);
    try testing.expectEqual(@as(u32, 2), res.terminal.complete.chunks);
    try testing.expectEqual(@as(usize, 3), res.frames.items.len);
    // 원문 무손실 재조립 확인.
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(testing.allocator);
    for (res.frames.items[0..2]) |wire| {
        var seq: u64 = undefined;
        var gen: u64 = undefined;
        const raw = try decodeChunk(testing.allocator, wire, &seq, &gen);
        defer testing.allocator.free(raw);
        try reassembled.appendSlice(testing.allocator, raw);
    }
    try testing.expectEqualStrings(scrollback, reassembled.items);
}

// ── 4) generation 불일치(중간 chunk 경계에서 변경) → capture-invalidated, 완료 마커 금지(§4.3 핵심 불변식) ──
test "capture-invalidated: chunk 경계에서 generation이 바뀌면 완료 마커 대신 invalidated로 종료" {
    const scrollback = "0123456789ABCDEFGHIJ"; // 20바이트, chunk_size=8 → 8,8,4 = 3 chunk
    var cap = Capture.initChunked(3, 100, 8);
    // 경계 0,1은 generation 100(유효), 경계 2에서 101로 evict 발생 → 마지막 chunk 전에 invalidated.
    const gens = [_]u64{ 100, 100, 101 };
    var res = try pump(testing.allocator, &cap, scrollback, .{ .gens = &gens, .base_gen = 100 });
    defer res.deinit(testing.allocator);

    // chunk 2개(seq0,1) 후 invalidated. complete는 절대 없어야 한다.
    try testing.expect(res.terminal == .invalidated);
    try testing.expectEqual(@as(u64, 100), res.terminal.invalidated.expected_generation);
    try testing.expectEqual(@as(u64, 101), res.terminal.invalidated.actual_generation);
    try testing.expectEqual(@as(usize, 3), res.frames.items.len); // chunk×2 + invalidated

    // 마지막 프레임 = invalidated 마커, complete 아님.
    var pm = try cp.parseMessage(testing.allocator, res.frames.items[2]);
    defer pm.deinit();
    try testing.expectEqualStrings(invalidated_method, pm.message.notification.method);
    const ip = pm.message.notification.params.?.object;
    try testing.expectEqual(@as(i64, 100), ip.get("generation").?.integer);
    try testing.expectEqual(@as(i64, 101), ip.get("actual_generation").?.integer);

    // 어떤 프레임도 complete 마커가 아니어야 한다(§4.3 "완료 마커 금지").
    for (res.frames.items) |f| {
        try testing.expect(std.mem.indexOf(u8, f, complete_method) == null);
    }
}

// ── 4b) generation이 마지막 chunk 직후(완료 경계)에 바뀌어도 invalidated(torn-read 미검출 방지) ──
test "capture-invalidated: 마지막 chunk 뒤 완료 경계에서 generation이 바뀌면 complete 대신 invalidated" {
    const scrollback = "0123456789"; // 10바이트, chunk_size=10 → 1 chunk
    var cap = Capture.initChunked(4, 7, 10);
    // 경계0: gen 7(chunk 방출). 경계1(완료 확인): gen 8로 변경 → complete 대신 invalidated.
    const gens = [_]u64{ 7, 8 };
    var res = try pump(testing.allocator, &cap, scrollback, .{ .gens = &gens, .base_gen = 7 });
    defer res.deinit(testing.allocator);
    try testing.expect(res.terminal == .invalidated);
    try testing.expectEqual(@as(u64, 8), res.terminal.invalidated.actual_generation);
    // chunk 1개는 이미 방출됐지만 완료 마커는 없다.
    for (res.frames.items) |f| try testing.expect(std.mem.indexOf(u8, f, complete_method) == null);
}

// ── 5) revoke: chunk 경계에서 revoked=true면 완료 마커 없이 revoked 종료(§8.5, generation보다 우선) ──
test "capture revoke: chunk 경계 revoked면 완료/invalidated 없이 revoked 마커로 종료(보안 우선)" {
    const scrollback = "0123456789ABCDEF"; // 16, chunk_size=8 → 8,8 = 2 chunk
    var cap = Capture.initChunked(6, 3, 8);
    // 경계1에서 revoked(+동시에 generation도 바뀌지만 revoke가 우선 — 보안).
    const gens = [_]u64{ 3, 99 };
    var res = try pump(testing.allocator, &cap, scrollback, .{ .gens = &gens, .base_gen = 3, .revoke_at = 1 });
    defer res.deinit(testing.allocator);
    try testing.expect(res.terminal == .revoked); // invalidated 아님(revoke 우선)
    var pm = try cp.parseMessage(testing.allocator, res.frames.items[res.frames.items.len - 1]);
    defer pm.deinit();
    try testing.expectEqualStrings(revoked_method, pm.message.notification.method);
    try testing.expectEqual(@as(i64, 6), pm.message.notification.params.?.object.get("capture_id").?.integer);
    // complete/invalidated 마커는 없어야.
    for (res.frames.items) |f| {
        try testing.expect(std.mem.indexOf(u8, f, complete_method) == null);
        try testing.expect(std.mem.indexOf(u8, f, invalidated_method) == null);
    }
}

// ── 6) 재시도 상한 → atomic fallback: generation이 매 경계 바뀌어도 fallback은 항상 complete ──
test "재시도 상한 fallback: 상한 초과 시 atomic capture는 generation 변경을 무시하고 완료한다(무한 재시도 방지)" {
    // 전략 순수 함수.
    try testing.expectEqual(CaptureStrategy.chunked, strategyForAttempt(0, 3));
    try testing.expectEqual(CaptureStrategy.chunked, strategyForAttempt(2, 3));
    try testing.expectEqual(CaptureStrategy.atomic_fallback, strategyForAttempt(3, 3));
    try testing.expectEqual(CaptureStrategy.atomic_fallback, strategyForAttempt(9, 3));

    // 조율기: 상한만큼 invalidated → atomic_fallback으로 전환.
    var coord: RetryCoordinator = .{ .retry_cap = 3 };
    try testing.expectEqual(CaptureStrategy.chunked, coord.strategy());
    coord.onInvalidated();
    coord.onInvalidated();
    coord.onInvalidated();
    try testing.expectEqual(CaptureStrategy.atomic_fallback, coord.strategy());

    // atomic capture는 매 경계 generation이 바뀌어도(gens=1,2,3,…) invalidated 없이 complete.
    const scrollback = "0123456789ABCDEF"; // 16, chunk_size=4 → 4 chunk
    var cap = coord.beginCapture(11, 50, 4);
    try testing.expect(cap.atomic);
    const gens = [_]u64{ 50, 51, 52, 53, 54 }; // 매 경계 다른 generation(chunked였다면 즉시 invalidated)
    var res = try pump(testing.allocator, &cap, scrollback, .{ .gens = &gens, .base_gen = 50 });
    defer res.deinit(testing.allocator);
    try testing.expect(res.terminal == .complete); // atomic은 generation 무시 → 완료
    try testing.expectEqual(@as(u32, 4), res.terminal.complete.chunks);

    // 무손실 재조립(atomic도 chunk 방식은 동일).
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(testing.allocator);
    for (res.frames.items[0..4]) |wire| {
        var seq: u64 = undefined;
        var gen: u64 = undefined;
        const rawc = try decodeChunk(testing.allocator, wire, &seq, &gen);
        defer testing.allocator.free(rawc);
        try reassembled.appendSlice(testing.allocator, rawc);
    }
    try testing.expectEqualStrings(scrollback, reassembled.items);
}

// ── 6b) atomic 모드도 revoke는 종료시킨다(보안은 fallback에서도 유효) ──
test "atomic fallback도 revoke는 존중한다(보안 우선 — generation만 무시)" {
    const scrollback = "0123456789";
    var cap = Capture.initAtomic(12, 1, 4);
    var res = try pump(testing.allocator, &cap, scrollback, .{ .base_gen = 1, .revoke_at = 1 });
    defer res.deinit(testing.allocator);
    try testing.expect(res.terminal == .revoked);
}

// ── 7) capture_id 발급기: 단조·비재사용 ──
test "CaptureIdAllocator: 단조 증가·비재사용(1부터)" {
    var a: CaptureIdAllocator = .{};
    try testing.expectEqual(@as(u64, 1), a.next());
    try testing.expectEqual(@as(u64, 2), a.next());
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const id = a.next();
        try testing.expect(!seen.contains(id));
        try seen.put(id, {});
    }
}

// ── 8) dispatch authz 게이트: 주입 read-output 인가면 ack, 미인가면 §8.3 균일 unauthorized ──
test "dispatchCaptureAck: read-output 인가 → ack(capture_id·generation·scrollback), 미인가 → unauthorized" {
    // 인가 + scrollback=true.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session.capture\",\"params\":{\"id\":10,\"scrollback\":true}}", true, 77, 42);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expect(pm.message == .response);
        try testing.expect(pm.message.response.err == null);
        try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 5 }));
        const r = pm.message.response.result.?.object;
        try testing.expectEqual(@as(i64, 77), r.get("capture_id").?.integer);
        try testing.expectEqual(@as(i64, 42), r.get("generation").?.integer);
        try testing.expect(r.get("scrollback").?.bool == true);
    }
    // 미인가 → §8.3 unauthorized(-32002), target 존재 여부 무관.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session.capture\",\"params\":{\"id\":10}}", false, 77, 42);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), pm.message.response.err.?.code);
    }
}

// ── 8b) dispatch: scrollback 생략 → 기본 false(가시 화면) ──
test "dispatchCaptureAck: scrollback 생략 시 ack의 scrollback=false(가시 화면 기본)" {
    const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", true, 1, 0);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message.response.result.?.object.get("scrollback").?.bool == false);
}

// ── 8c) dispatch 오류 경로: 미지 method·params 오류·비-request ──
test "dispatchCaptureAck 오류: 미지 method→method_not_found, params 오류→invalid_params, notification→invalid_request" {
    // 미지 method(capture 아님).
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}", true, 1, 0);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.method_not_found)), try respErr(wire));
    }
    // params id 없음.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{}}", true, 1, 0);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try respErr(wire));
    }
    // params id 음수.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":-1}}", true, 1, 0);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try respErr(wire));
    }
    // scrollback 비-불리언.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10,\"scrollback\":\"yes\"}}", true, 1, 0);
        defer testing.allocator.free(wire);
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_params)), try respErr(wire));
    }
    // notification(id 없음) → invalid_request.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"session.capture\",\"params\":{\"id\":10}}", true, 1, 0);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.invalid_request)), pm.message.response.err.?.code);
        try testing.expect(pm.message.response.id == .null);
    }
    // malformed JSON → parse_error, id=null.
    {
        const wire = try dispatchCaptureAck(testing.allocator, "{not json", true, 1, 0);
        defer testing.allocator.free(wire);
        var pm = try cp.parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.parse_error)), pm.message.response.err.?.code);
    }
}

// ── 8d) §8.3 oracle 방지: 미인가는 target 존재 여부와 무관하게 균일 unauthorized 바이트 ──
test "dispatchCaptureAck §8.3: 미인가 응답은 target surface_id가 달라도 바이트 동일(존재 oracle 없음)" {
    const w_low = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":10}}", false, 1, 0);
    defer testing.allocator.free(w_low);
    const w_high = try dispatchCaptureAck(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.capture\",\"params\":{\"id\":999999}}", false, 1, 0);
    defer testing.allocator.free(w_high);
    try testing.expectEqualStrings(w_low, w_high); // 존재/부재가 응답으로 새지 않는다
}

// ── 9) 직렬화 단품: chunk/complete/invalidated/revoked wire 스키마 못박기 ──
test "직렬화 스키마: chunk는 capture_id·seq·generation·encoding·data 필드, 한 줄" {
    const chunk: RawChunk = .{ .capture_id = 3, .seq = 2, .generation = 9, .data = "hi" };
    const wire = try serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    const p = pm.message.notification.params.?.object;
    try testing.expectEqual(@as(i64, 3), p.get("capture_id").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("seq").?.integer);
    try testing.expectEqual(@as(i64, 9), p.get("generation").?.integer);
    try testing.expectEqualStrings("base64", p.get("encoding").?.string);
    // "hi"의 base64 = "aGk=".
    try testing.expectEqualStrings("aGk=", p.get("data").?.string);
}

// 응답 wire의 에러 코드를 뽑는다(성공이면 실패).
fn respErr(wire: []const u8) !i64 {
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    return pm.message.response.err.?.code;
}

test {
    testing.refAllDecls(@This());
}
