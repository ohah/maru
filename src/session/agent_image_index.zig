//! 에이전트 트랜스크립트(JSONL)에서 **이미지의 위치**를 찾는 순수 모듈 — 계약은
//! [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §3·§4가 소유한다.
//!
//! **바이트를 옮기지 않는다.** 이미지 하나가 수 MB인데 인덱스가 그것을 들고 있으면 목록 하나에
//! 수백 MB가 앉는다. 그래서 이 모듈이 돌려주는 것은 `(줄 오프셋, 데이터 오프셋, 길이)`뿐이고,
//! 실제 픽셀은 화면에 보일 때 그 구간만 다시 읽어 디코드한다(§5.2 — 장당 ~20 ms라 어차피 가상화가 강제된다).
//!
//! **왜 JSON 파서를 쓰지 않는가**: 후보를 찾는 데 필요 없다. JSON은 문자열 안의 따옴표를 이스케이프하므로
//! `"type":"image"`(이스케이프되지 않은 따옴표)는 **구조로만** 나타난다 — 본문이 그 글자를 언급해도 파일에는
//! `\"type\":\"image\"`로 들어간다. 실측 오탐 0(엄격 패턴 364 = `grep` 364, §3.2). 파일 하나가 1.6 GB까지
//! 가므로 줄마다 JSON을 파싱하는 비용을 치를 이유가 없다.
//!
//! **플랫폼을 모른다.** `std`만 쓰고 파일을 열지 않는다 — 바이트 슬라이스를 받아 위치를 돌려준다.
//! 그래서 Linux 타깃으로도 컴파일·테스트된다.

const std = @import("std");

/// 한 줄의 상한. 넘으면 그 줄을 **버린다**(잘라서 반쪽 JSON을 만들지 않는다). 아카이브 스캐너와 같은 값이며,
/// 근거도 같다 — Codex `compacted` 레코드가 실측 7.2 MB까지 간다(§4.2).
pub const max_line_bytes: usize = 16 * 1024 * 1024;

pub const Provider = enum { claude, codex };

/// 이미지가 어떤 레코드로 들어 있는가. **표시가 아니라 중복 판정과 문맥 복원에 쓰인다** —
/// `claude_tool_file`은 `claude_image`와 같은 이미지의 2중 저장이라(§4.3) 해시가 같으면 접힌다.
pub const Kind = enum {
    /// Claude `{"type":"image","source":{"type":"base64",…,"data":"…"}}` — user 메시지와 `tool_result` 양쪽.
    claude_image,
    /// Claude `toolUseResult.file.base64` — 바로 위 레코드와 **같은 이미지의 두 번째 사본**.
    claude_tool_file,
    /// Codex `{"type":"input_image","image_url":"data:<mime>;base64,…"}`.
    codex_input_image,

    pub fn provider(self: Kind) Provider {
        return switch (self) {
            .claude_image, .claude_tool_file => .claude,
            .codex_input_image => .codex,
        };
    }
};

/// 인덱스가 아는 mime. 디코드는 ImageIO가 스스로 sniff하므로 **표시와 진단용**이다.
/// 모르는 값을 지어내지 않는다 — 레코드가 안 밝히면 `unknown`이다.
pub const Mime = enum {
    unknown,
    png,
    jpeg,
    gif,
    webp,
    other,

    fn parse(s: []const u8) Mime {
        if (std.mem.eql(u8, s, "image/png")) return .png;
        if (std.mem.eql(u8, s, "image/jpeg") or std.mem.eql(u8, s, "image/jpg")) return .jpeg;
        if (std.mem.eql(u8, s, "image/gif")) return .gif;
        if (std.mem.eql(u8, s, "image/webp")) return .webp;
        if (std.mem.startsWith(u8, s, "image/")) return .other;
        return .unknown;
    }
};

/// 이미지 하나의 **자리**. 바이트는 담지 않는다.
pub const Hit = struct {
    /// 이 이미지가 든 줄의 시작(파일 절대). 문맥 복원(§2.2)이 이 값으로 앞뒤 줄을 찾는다.
    line_offset: u64,
    /// base64 payload의 첫 바이트(파일 절대). data URL이면 `,` **다음**을 가리킨다.
    data_offset: u64,
    data_len: u32,
    kind: Kind,
    mime: Mime,
};

/// 이 Term 이 읽을 트랜스크립트의 **절대 경로**. 훅 `SessionStart`/`UserPromptSubmit` 이 `transcript_path` 로
/// 통째로 주므로(계약 §4.4) 디렉터리를 조립하거나 추측하지 않는다.
///
/// 힙을 잡지 않는 고정 버퍼다 — `agent_transcript.Cache` 와 같은 규율이라 Term 파괴가 따로 해제하지 않는다.
///
/// **512인 근거(2026-08-29 실측)**: 이 기계의 트랜스크립트 경로 4,155개에서 최대 **215자**, p99 205자였고
/// 256자를 넘는 것이 하나도 없었다. 길이는 사실상 cwd 가 정하는데(claude 는 cwd 를 인코딩한 디렉터리 이름을
/// 쓴다), 512면 cwd 400자까지 담는다. **넘치면 담지 않는다 — 자르지 않는다**: 자른 경로는 없는 파일이거나,
/// 더 나쁘게는 **다른 파일**을 가리킨다.
pub const max_source_path_bytes: usize = 512;

/// 갤러리가 읽는 대상 하나.
pub const Source = struct {
    buf: [max_source_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn path(self: *const Source) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Source) bool {
        return self.len == 0;
    }

    /// 경로를 바꾼다. 바뀌었으면 true — 호출자가 그때만 인덱스를 버린다.
    /// 상한을 넘거나 절대 경로가 아니면 **비운다**(추측한 경로로 남의 파일을 읽지 않는다).
    pub fn set(self: *Source, value: []const u8) bool {
        if (value.len == 0 or value.len > max_source_path_bytes or value[0] != '/') {
            const had = self.len != 0;
            self.len = 0;
            return had;
        }
        if (self.len == value.len and std.mem.eql(u8, self.buf[0..self.len], value)) return false;
        @memcpy(self.buf[0..value.len], value);
        self.len = value.len;
        return true;
    }

    pub fn clear(self: *Source) void {
        self.len = 0;
    }
};

const claude_image_marker = "\"type\":\"image\",\"source\":{\"type\":\"base64\"";
const claude_tool_file_marker = "\"file\":{\"base64\":\"";
const codex_marker = "\"type\":\"input_image\"";
const compacted_marker = "\"type\":\"compacted\"";

const data_key = "\"data\":\"";
const image_url_key = "\"image_url\":\"";
const media_type_key = "\"media_type\":\"";

/// 마커 뒤에서 키를 찾을 때 훑는 최대 바이트. 레코드 머리는 짧고(실측 수십 바이트) payload는 그 뒤에 오므로,
/// 이 창을 넘어가면 그것은 **다른 레코드의 키**다 — 무한정 앞을 보면 엉뚱한 이미지를 짝지어 준다.
const key_search_window: usize = 512;

/// 한 줄을 훑어 이미지 자리를 `out`에 덧붙인다. `line_offset`은 그 줄의 파일 절대 시작이다.
///
/// **Codex `compacted`는 통째로 건너뛴다**(§3.3). 그 레코드는 이전 대화를 이미지째 재수록하므로,
/// 세지 않으면 실측처럼 15,140개 대 실제 151개가 된다. 원본이 같은 파일 앞쪽에 이미 있어 잃는 것이 없다.
pub fn scanLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    if (line.len == 0 or line.len > max_line_bytes) return;
    if (std.mem.indexOf(u8, line, compacted_marker) != null) return;

    try scanClaudeImages(allocator, line, line_offset, out);
    try scanClaudeToolFiles(allocator, line, line_offset, out);
    try scanCodexImages(allocator, line, line_offset, out);
}

fn scanClaudeImages(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, claude_image_marker)) |m| {
        i = m + claude_image_marker.len;
        const span = findQuotedValue(line, i, data_key) orelse continue;
        const mime = blk: {
            const mt = findQuotedValue(line, i, media_type_key) orelse break :blk Mime.unknown;
            // media_type 은 data 보다 **앞**에 와야 이 레코드의 것이다. 뒤에 있으면 다음 레코드의 값이다.
            if (mt.start > span.start) break :blk Mime.unknown;
            break :blk Mime.parse(line[mt.start .. mt.start + mt.len]);
        };
        try append(allocator, out, line_offset, span, .claude_image, mime);
        i = span.start + span.len;
    }
}

fn scanClaudeToolFiles(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, claude_tool_file_marker)) |m| {
        const start = m + claude_tool_file_marker.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse {
            i = start;
            continue;
        };
        try append(allocator, out, line_offset, .{ .start = start, .len = end - start }, .claude_tool_file, .unknown);
        i = end;
    }
}

fn scanCodexImages(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, codex_marker)) |m| {
        i = m + codex_marker.len;
        const url = findQuotedValue(line, i, image_url_key) orelse continue;
        // `data:<mime>;base64,` 접두를 벗긴다. 그 모양이 아니면 인덱싱하지 않는다 — 원격 URL 이미지는
        // 바이트가 파일에 없으므로 갤러리가 보여 줄 수 있는 것이 아니다.
        const value = line[url.start .. url.start + url.len];
        if (!std.mem.startsWith(u8, value, "data:")) {
            i = url.start + url.len;
            continue;
        }
        const comma = std.mem.indexOfScalar(u8, value, ',') orelse {
            i = url.start + url.len;
            continue;
        };
        const header = value[5..comma]; // "data:" 다음부터 `,` 앞까지 = `<mime>;base64`
        const semi = std.mem.indexOfScalar(u8, header, ';') orelse header.len;
        const mime = Mime.parse(header[0..semi]);
        const payload_start = url.start + comma + 1;
        try append(allocator, out, line_offset, .{
            .start = payload_start,
            .len = url.start + url.len - payload_start,
        }, .codex_input_image, mime);
        i = url.start + url.len;
    }
}

const Span = struct { start: usize, len: usize };

/// `from`부터 `key_search_window` 안에서 `key`를 찾고, 그 뒤 따옴표 값의 범위를 돌려준다.
/// base64와 mime 문자열에는 JSON 이스케이프가 없으므로 다음 `"`가 곧 끝이다.
fn findQuotedValue(line: []const u8, from: usize, key: []const u8) ?Span {
    const limit = @min(line.len, from + key_search_window);
    const k = std.mem.indexOfPos(u8, line[0..limit], from, key) orelse return null;
    const start = k + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return .{ .start = start, .len = end - start };
}

fn append(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Hit),
    line_offset: u64,
    span: Span,
    kind: Kind,
    mime: Mime,
) !void {
    if (span.len == 0) return;
    if (span.len > std.math.maxInt(u32)) return; // 방어 — 한 줄 상한 안이면 도달하지 않는다
    try out.append(allocator, .{
        .line_offset = line_offset,
        .data_offset = line_offset + span.start,
        .data_len = @intCast(span.len),
        .kind = kind,
        .mime = mime,
    });
}

/// 완결된 줄들로 채워진 버퍼 전체를 훑는다. **마지막 줄이 개행으로 끝나지 않으면 그 줄은 보지 않는다** —
/// 잘린 꼬리를 파싱하면 반쪽 base64를 이미지로 셀 수 있다. 증분 읽기의 `last_offset` 규율(§4.2)과 같은 이유다.
///
/// 돌려주는 값은 **소비한 바이트 수**(= 마지막 개행 다음 위치)다. 호출자는 그것을 `last_offset`에 더한다.
pub fn scanBuffer(
    allocator: std.mem.Allocator,
    buf: []const u8,
    base_offset: u64,
    out: *std.ArrayList(Hit),
) !usize {
    var consumed: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, consumed, '\n')) |nl| {
        const line = buf[consumed..nl];
        try scanLine(allocator, line, base_offset + consumed, out);
        consumed = nl + 1;
    }
    return consumed;
}

/// 한 파일에서 담는 이미지 자리의 상한. **악의적/손상 파일이 메모리를 무한히 먹지 않게** 하는 방어다.
/// 실측(2026-08-29)에서 한 파일 최대가 770개(Codex rollout)였으므로 4096이면 실사용을 자르지 않는다.
/// 넘치면 `partial` 로 표시하고 더 담지 않는다 — 조용히 자르지 않는다.
pub const max_hits_per_file: usize = 4096;

/// 청크로 흘러오는 파일을 줄 경계로 이어 붙여 훑는다.
///
/// **이 타입이 있는 이유는 청크 경계다.** 64 KiB 씩 읽으면 마커도 base64 도 경계에 걸린다. 걸친 조각을
/// 다음 청크 앞에 이어 붙이지 않으면 그 이미지는 **없는 것이 된다**. 반대로 걸친 조각을 그대로 훑으면
/// 반쪽을 세거나, 다음 회차가 같은 것을 또 센다(§4.2 의 `last_offset` 규율과 같은 이유).
///
/// I/O 를 모른다 — 호출자가 읽어서 `feed` 한다. 그래서 경계 처리를 파일 없이 시험할 수 있다.
pub const StreamScanner = struct {
    /// 개행을 못 만난 꼬리. 다음 청크 앞에 붙는다.
    carry: std.ArrayList(u8) = .empty,
    /// 파일에서 **소비한** 바이트(= 마지막 개행 다음). 이어읽기(IG2)가 `last_offset` 으로 쓴다.
    consumed: u64 = 0,
    /// 상한에 걸려 못 본 것이 있다. 「비었다」와 「못 봤다」는 다른 사실이라 나눠 든다.
    partial: bool = false,

    pub fn deinit(self: *StreamScanner, allocator: std.mem.Allocator) void {
        self.carry.deinit(allocator);
        self.* = .{};
    }

    /// 청크 하나를 먹인다. `chunk` 는 `self.consumed + self.carry.len` 위치부터의 바이트여야 한다.
    pub fn feed(
        self: *StreamScanner,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        out: *std.ArrayList(Hit),
    ) !void {
        if (chunk.len == 0) return;
        try self.carry.appendSlice(allocator, chunk);
        const base = self.consumed;
        const buf = self.carry.items;

        var used: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf, used, '\n')) |nl| {
            if (out.items.len < max_hits_per_file) {
                const before = out.items.len;
                try scanLine(allocator, buf[used..nl], base + used, out);
                if (out.items.len > max_hits_per_file) {
                    out.shrinkRetainingCapacity(max_hits_per_file);
                    self.partial = true;
                }
                _ = before;
            } else {
                self.partial = true;
            }
            used = nl + 1;
        }

        // 소비한 만큼 앞을 버리고 꼬리만 남긴다.
        self.consumed += used;
        const rest = buf.len - used;
        std.mem.copyForwards(u8, self.carry.items[0..rest], buf[used..]);
        self.carry.shrinkRetainingCapacity(rest);

        // **꼬리가 한 줄 상한을 넘으면 그 줄을 버린다.** 개행 없는 바이트가 무한히 오면(손상 파일·바이너리)
        // 이 버퍼가 파일 크기만큼 자란다. 버리는 대신 `partial` 로 밝힌다.
        if (self.carry.items.len > max_line_bytes) {
            self.consumed += self.carry.items.len;
            self.carry.clearRetainingCapacity();
            self.partial = true;
        }
    }
};

// ── 테스트 ─────────────────────────────────────────────────────────────────────
//
// **구조는 실측, 값은 합성**(계획 §P2). 아래 fixture 의 레코드 모양은 2026-08-29 에 실제 provider 기록에서
// 확인한 것이고, base64 payload 와 문구만 합성이다. 사용자 기록을 fixture 로 커밋하지 않는다(계약 §6).

const testing = std.testing;

fn collect(src: []const u8) !std.ArrayList(Hit) {
    var out: std.ArrayList(Hit) = .empty;
    errdefer out.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, src, 0, &out);
    return out;
}

test "Claude user 메시지의 이미지를 찾는다 — 실측 레코드 모양" {
    const line =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"이거 봐주세요"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAABBBBCCCC"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_image, hits.items[0].kind);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqual(@as(u32, 12), hits.items[0].data_len);
    try testing.expectEqualStrings(
        "AAAABBBBCCCC",
        line[hits.items[0].data_offset .. hits.items[0].data_offset + hits.items[0].data_len],
    );
    try testing.expectEqual(@as(u64, 0), hits.items[0].line_offset);
}

test "media_type 이 없는 tool_result 이미지도 찾는다" {
    // 실측: tool_result 안의 image 는 media_type 없이 오기도 한다.
    const line =
        \\{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"ZZZZ"}}]}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Mime.unknown, hits.items[0].mime);
    try testing.expectEqualStrings("ZZZZ", line[hits.items[0].data_offset..][0..4]);
}

test "toolUseResult 2중 저장을 별도 kind 로 잡는다" {
    const line =
        \\{"type":"user","toolUseResult":{"type":"image","file":{"base64":"DUPDUPDUP","type":"image/png"}}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_file, hits.items[0].kind);
    try testing.expectEqualStrings("DUPDUPDUP", line[hits.items[0].data_offset..][0..9]);
}

test "Codex input_image 는 data URL 접두를 벗기고 payload 만 가리킨다" {
    // 실측 모양(통제 입력으로 확인): input_text(<image name=… path=…>) → input_image → input_text(</image>) → input_text(질문)
    const line =
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/x/y.png\">"},{"type":"input_image","image_url":"data:image/png;base64,QQQQRRRR"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"이거 뭐예요"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.codex_input_image, hits.items[0].kind);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqualStrings("QQQQRRRR", line[hits.items[0].data_offset..][0..8]);
}

test "Codex compacted 줄은 통째로 건너뛴다 — 이미지가 들어 있어도" {
    // 실측: compacted 레코드가 이전 대화를 이미지째 재수록한다(한 레코드 7.2 MB, 한 파일 376개).
    const line =
        \\{"type":"compacted","payload":{"message":"…{\"type\": \"input_image\", \"image_url\": \"data:image/png;base64,XXXX\"}…","content":[{"type":"input_image","image_url":"data:image/png;base64,YYYY"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "한 줄에 이미지가 여럿이면 각각 잡고 오프셋이 겹치지 않는다" {
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"BBBBBB"}}]}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    try testing.expectEqual(Mime.png, hits.items[0].mime);
    try testing.expectEqual(Mime.jpeg, hits.items[1].mime);
    try testing.expect(hits.items[0].data_offset + hits.items[0].data_len <= hits.items[1].data_offset);
}

test "줄 오프셋은 파일 절대값이다 — 여러 줄" {
    const first =
        \\{"type":"user","message":{"content":[{"type":"text","text":"앞줄"}]}}
    ;
    const second =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"CCCC"}}]}
    ;
    const src = first ++ "\n" ++ second ++ "\n";
    var hits = try collect(src);
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(@as(u64, first.len + 1), hits.items[0].line_offset);
    try testing.expectEqualStrings("CCCC", src[hits.items[0].data_offset..][0..4]);
}

test "개행으로 끝나지 않은 꼬리는 보지 않는다 — 안 그러면 다음 회차가 같은 이미지를 또 센다" {
    const complete =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    // **위험은 반쪽 base64 가 아니라 중복이다.** 꼬리가 잘렸어도 그 안에 이미 **완결된** 이미지 레코드가
    // 들어 있을 수 있다(한 줄에 이미지가 여럿인 경우). 그것을 세면, 다음 회차가 이 줄을 처음부터 다시
    // 읽을 때 같은 이미지를 두 번째로 센다 — `last_offset` 을 개행까지만 전진시키는 이유다(§4.2).
    const partial = "{\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"TAIL\"}},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"CUT";
    const src = complete ++ "\n" ++ partial;

    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    const consumed = try scanBuffer(testing.allocator, src, 0, &out);

    // 완결된 첫 줄의 하나만 센다. 꼬리의 "TAIL" 은 **완결돼 있어도** 세지 않는다.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("AAAA", src[out.items[0].data_offset..][0..4]);
    try testing.expectEqual(@as(usize, complete.len + 1), consumed);
}

test "본문이 마커 글자를 언급해도 오탐이 없다 — JSON 이스케이프가 막는다" {
    // 이 대화 자체가 그렇다: 마커를 설명하는 텍스트가 트랜스크립트에 들어간다.
    const line =
        \\{"type":"user","message":{"content":[{"type":"text","text":"마커는 \"type\":\"image\",\"source\":{\"type\":\"base64\" 이고 data 키를 본다"}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "빈 줄과 상한을 넘는 줄은 조용히 건너뛴다" {
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine(testing.allocator, "", 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    const huge = try testing.allocator.alloc(u8, max_line_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try scanLine(testing.allocator, huge, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Kind 는 provider 를 안다" {
    try testing.expectEqual(Provider.claude, Kind.claude_image.provider());
    try testing.expectEqual(Provider.claude, Kind.claude_tool_file.provider());
    try testing.expectEqual(Provider.codex, Kind.codex_input_image.provider());
}

test "Source: 경로를 담고, 바뀔 때만 true 를 돌려준다" {
    var src: Source = .{};
    try testing.expect(src.isEmpty());
    try testing.expect(src.set("/Users/u/.claude/projects/p/a.jsonl"));
    try testing.expectEqualStrings("/Users/u/.claude/projects/p/a.jsonl", src.path());
    // 같은 값이면 바뀐 것이 아니다 — 인덱스를 헛되이 버리지 않는다.
    try testing.expect(!src.set("/Users/u/.claude/projects/p/a.jsonl"));
    try testing.expect(src.set("/Users/u/.claude/projects/p/b.jsonl"));
    try testing.expectEqualStrings("/Users/u/.claude/projects/p/b.jsonl", src.path());
}

test "Source: 상한 초과·상대 경로·빈 값은 담지 않고 비운다 — 자르지 않는다" {
    var src: Source = .{};
    _ = src.set("/ok/a.jsonl");

    // 자르면 없는 파일이거나 **다른 파일**이 된다.
    const too_long = "/" ++ ("x" ** max_source_path_bytes);
    try testing.expect(src.set(too_long)); // 바뀌었다(비워졌다)
    try testing.expect(src.isEmpty());

    _ = src.set("/ok/a.jsonl");
    try testing.expect(src.set("relative/a.jsonl"));
    try testing.expect(src.isEmpty());

    _ = src.set("/ok/a.jsonl");
    try testing.expect(src.set(""));
    try testing.expect(src.isEmpty());

    // 이미 비어 있으면 바뀐 것이 아니다.
    try testing.expect(!src.set(""));
}

fn feedInChunks(src: []const u8, chunk: usize, out: *std.ArrayList(Hit)) !StreamScanner {
    var sc: StreamScanner = .{};
    errdefer sc.deinit(testing.allocator);
    var i: usize = 0;
    while (i < src.len) {
        const end = @min(src.len, i + chunk);
        try sc.feed(testing.allocator, src[i..end], out);
        i = end;
    }
    return sc;
}

test "StreamScanner: 청크가 이미지 한가운데를 갈라도 결과가 같다 — 1바이트씩 먹여도" {
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAABBBB"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"CCCC"}}]}
    ;
    const src = line ++ "\n";

    // 기준: 통째로 훑은 결과.
    var whole: std.ArrayList(Hit) = .empty;
    defer whole.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, src, 0, &whole);
    try testing.expectEqual(@as(usize, 2), whole.items.len);

    // **1바이트씩** 먹여도 같아야 한다. 경계 처리가 틀리면 여기서 개수나 오프셋이 갈린다.
    for ([_]usize{ 1, 2, 7, 64, 4096 }) |chunk| {
        var got: std.ArrayList(Hit) = .empty;
        defer got.deinit(testing.allocator);
        var sc = try feedInChunks(src, chunk, &got);
        defer sc.deinit(testing.allocator);

        try testing.expectEqual(whole.items.len, got.items.len);
        for (whole.items, got.items) |w, g| {
            try testing.expectEqual(w.data_offset, g.data_offset);
            try testing.expectEqual(w.data_len, g.data_len);
            try testing.expectEqual(w.kind, g.kind);
            try testing.expectEqual(w.mime, g.mime);
            try testing.expectEqual(w.line_offset, g.line_offset);
        }
        // 오프셋이 **파일 절대값**인지도 함께 본다 — 청크 상대값이면 여기서 갈린다.
        try testing.expectEqualStrings("AAAABBBB", src[got.items[0].data_offset..][0..8]);
        try testing.expectEqualStrings("CCCC", src[got.items[1].data_offset..][0..4]);
        try testing.expectEqual(@as(u64, src.len), sc.consumed);
        try testing.expect(!sc.partial);
    }
}

test "StreamScanner: consumed 는 마지막 개행까지만 간다 — 잘린 꼬리는 남겨 둔다" {
    const complete =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    const partial_tail = "{\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"TAIL\"}},{\"type\":\"image\"";
    const src = complete ++ "\n" ++ partial_tail;

    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(testing.allocator);
    var sc = try feedInChunks(src, 8, &got);
    defer sc.deinit(testing.allocator);

    // 완결된 줄의 하나만 센다. 꼬리의 "TAIL" 은 **완결돼 있어도** 아직 세지 않는다 —
    // 세면 다음 회차가 그 줄을 처음부터 다시 읽을 때 같은 이미지를 두 번 센다.
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqual(@as(u64, complete.len + 1), sc.consumed);
    try testing.expectEqual(partial_tail.len, sc.carry.items.len);
}

test "StreamScanner: 개행 없는 거대 꼬리는 버리고 partial 로 밝힌다" {
    var sc: StreamScanner = .{};
    defer sc.deinit(testing.allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);

    const blob = try testing.allocator.alloc(u8, max_line_bytes + 1024);
    defer testing.allocator.free(blob);
    @memset(blob, 'x'); // 개행이 하나도 없다 — 손상 파일·바이너리가 이렇게 온다

    try sc.feed(testing.allocator, blob, &out);
    // 버퍼가 파일 크기만큼 자라지 않는다.
    try testing.expectEqual(@as(usize, 0), sc.carry.items.len);
    try testing.expect(sc.partial);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "StreamScanner: 이미지가 상한을 넘으면 더 담지 않고 partial 이다" {
    var sc: StreamScanner = .{};
    defer sc.deinit(testing.allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);

    const one =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}
    ;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: usize = 0;
    while (i < max_hits_per_file + 5) : (i += 1) {
        try src.appendSlice(testing.allocator, one);
        try src.append(testing.allocator, '\n');
    }
    try sc.feed(testing.allocator, src.items, &out);

    try testing.expectEqual(max_hits_per_file, out.items.len);
    try testing.expect(sc.partial); // 「비었다」가 아니라 「못 봤다」임을 밝힌다
}
