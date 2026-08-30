//! 이미지 **문맥 복원** — 「이 이미지가 무엇이었는지」를 한 줄로 — 계약 [docs/agent-image-gallery.md](../../docs/agent-image-gallery.md) §2.2.
//!
//! 순수 계산이다. 파일을 열지 않고, 호출자가 읽어 준 두 조각만 본다:
//!
//! - `image_line_prefix` — 이미지가 든 줄의 시작부터 **base64 시작 전까지**. payload 는 수 MB 라
//!   절대 넘겨받지 않는다.
//! - `prev_lines` — 그 앞의 **줄 몇 개**(없으면 빈 슬라이스). 줄로 쪼개 뒤에서부터 본다.
//!
//! ## 왜 직전 줄 하나인가 (2026-08-29 실측, 실제 트랜스크립트 2,548 파일)
//!
//! 초안은 «±6줄 창» 을 적어 두었고, 그 전에는 «같은 줄 앞부분» 으로 충분할 줄 알았다. 둘 다 실측이
//! 깼다 — 같은 줄만 보면 **11.0%** 만 라벨이 나온다(Claude 이미지의 89% 가 `tool_result` 레코드이고
//! 그 줄에는 경로도 텍스트도 없다). 구조를 따라가 보니 답은 한 곳에 있었다:
//!
//! | 잰 것 | 값 |
//! | --- | --- |
//! | `tool_use_id` → assistant `tool_use` 매칭 | 1,074 / 1,074 = **100%** |
//! | 그 레코드가 **몇 줄 뒤**인가 | **언제나 1줄** (누적 100%) |
//! | 그 줄의 `tool_use` 블록 개수 | **언제나 1개** (짝을 고를 필요가 없다) |
//! | `input.file_path` 가 있는 비율 | 1,072 / 1,074 |
//! | `tool_use_id` 가 base64 **앞**에 오는 비율 | 1,076 / 1,076 |
//! | 직전 줄 크기 | 중앙 1.5 KB, 최대 2.3 KB |
//!
//! 그래서 id 맵이 없다. 그리고 마지막 줄(직전 줄 크기)이 «호출자가 64 KiB 만 거슬러 읽으면 된다» 를
//! 정한다 — 실측 최대의 28배 여유다.
//!
//! ## Codex 는 «직전 줄 하나» 가 아니다 (2026-08-30 실측)
//!
//! Claude 는 언제나 1줄 뒤였지만 Codex 의 `view_image` 는 다르다:
//!
//! | 잰 것 | 값 |
//! | --- | --- |
//! | `view_image` 결과 레코드 | 16 |
//! | 그 줄에 텍스트가 **없는** 것 | 13 — 옛 규칙으로는 **빈 라벨** |
//! | 호출이 **2줄 뒤** | 12 |
//! | 호출이 1줄 뒤 | 4 |
//! | 호출 줄에 `payload.path` | 13 |
//!
//! 그래서 창을 «앞선 줄들» 로 넓히고, **id 가 든 줄 안에서만** 경로를 뽑는다. 창을 통째로 훑어
//! `path` 를 집으면 id 는 A 레코드에서, 경로는 B 레코드에서 나올 수 있다 — 그것이 바로 이 모듈이
//! 처음부터 막으려던 «틀린 라벨» 이다.
//!
//! **그래도 id 를 대조한다.** 「언제나 1개」에 기대어 직전 줄의 `file_path` 를 그냥 집으면, 그 가정이
//! 깨지는 날 **엉뚱한 파일 이름**이 이미지에 붙는다. 빈 라벨은 아무 말도 안 하지만 틀린 라벨은
//! 거짓말이다.

const std = @import("std");

/// 라벨 상한. 도크 한 줄에 들어갈 길이면 충분하고, 렌더러가 다시 줄인다(ellipsize).
pub const max_label_bytes: usize = 160;

/// 이미지 줄에서 이 바이트까지만 본다. `tool_use_id` 는 레코드 머리에 있으므로(실측 100%) 넉넉하다.
pub const max_prefix_bytes: usize = 64 * 1024;

/// 직전 줄을 거슬러 읽을 때의 상한. 실측 최대 2.3 KB 의 28배.
pub const max_prev_line_bytes: usize = 64 * 1024;

/// 라벨이 **어디서** 왔는가. 표시가 아니라 진단·테스트용이다 — 규칙이 조용히 다른 갈래로 새면
/// 「라벨은 나오는데 엉뚱하다」가 되는데, 그 차이는 문자열만 봐서는 안 보인다.
pub const Source = enum {
    /// 직전 줄의 `tool_use.input.file_path` — 에이전트가 읽은 이미지.
    tool_file_path,
    /// 같은 줄의 사용자 텍스트 — 붙여넣은 이미지.
    message_text,
    /// codex `<image … path="…">` 래퍼의 경로. 질문 텍스트가 없을 때만.
    codex_wrapper_path,
    none,
};

pub const Label = struct {
    buf: [max_label_bytes]u8 = undefined,
    len: usize = 0,
    source: Source = .none,
    /// 이 이미지가 트랜스크립트에 적힌 **시각**(Unix 초, UTC). **0 이면 모른다** — 그때는 안 그린다.
    ///
    /// 라벨과 한 몸으로 다닌다. 따로 배열을 들면 `hits` 를 건드리는 자리마다 «셋» 을 맞춰야 하고,
    /// 어긋나면 남의 이미지에 남의 시각이 붙는다.
    time_s: i64 = 0,

    pub fn text(self: *const Label) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Label) bool {
        return self.len == 0;
    }
};

/// 이 라벨이 검색어에 걸리는가. **대소문자를 가리지 않고 부분 일치**다.
///
/// 파일명(`dock-layout.png`)과 사람이 쓴 문장(「이 배치가 이상합니다」)이 한 목록에 섞여 있으므로,
/// 접두사 일치로 좁히면 문장 쪽을 못 찾는다. 반대로 fuzzy 로 넓히면 151 장에서 관계없는 것이 잔뜩
/// 걸린다 — 부분 일치가 그 사이다.
///
/// **빈 검색어는 전부 통과**다(필터가 꺼진 상태와 같다).
///
/// 대소문자 접기는 ASCII 만 한다. 한글에는 대소문자가 없고, 그 밖의 문자를 제대로 접으려면 유니코드
/// 케이스 테이블이 필요한데 이 기능이 그것을 정당화하지 않는다.
pub fn matches(label_text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (label_text.len < query.len) return false;
    var i: usize = 0;
    while (i + query.len <= label_text.len) : (i += 1) {
        var j: usize = 0;
        while (j < query.len) : (j += 1) {
            if (foldAscii(label_text[i + j]) != foldAscii(query[j])) break;
        } else return true;
    }
    return false;
}

fn foldAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

const tool_use_id_key = "\"tool_use_id\":\"";
const id_key = "\"id\":\"";
const file_path_key = "\"file_path\":\"";
/// Codex `view_image` 는 Claude 와 다른 이름을 쓴다 — 호출 상관 키도, 경로 키도.
const call_id_key = "\"call_id\":\"";
const path_key = "\"path\":\"";
const text_key = "\"text\":\"";
const wrapper_open = "<image ";
const wrapper_path_key = "path=\\\"";

/// 이 이미지의 한 줄 설명. 못 만들면 **빈 라벨**이다 — 지어내지 않는다(계약 1).
pub fn label(image_line_prefix: []const u8, prev_lines: []const u8) Label {
    const prefix = image_line_prefix[0..@min(image_line_prefix.len, max_prefix_bytes)];
    const prev = prev_lines[0..@min(prev_lines.len, max_prev_line_bytes)];

    // ① 에이전트가 읽은 이미지 — 앞선 도구 호출이 그 정체다. provider 마다 키가 다르다.
    //    Claude: `tool_use_id` → `"id"` 가 같은 줄의 `file_path`
    //    Codex : `call_id`     → 그 id 가 든 줄의 `path`
    if (findValue(prefix, tool_use_id_key)) |tid| {
        if (tid.len > 0) {
            if (pathInLineWith(prev, tid, file_path_key)) |raw| {
                var out: Label = .{ .source = .tool_file_path };
                out.len = writeText(&out.buf, basenameOf(raw));
                if (out.len > 0) return out;
            }
        }
    }
    if (findValue(prefix, call_id_key)) |cid| {
        if (cid.len > 0) {
            if (pathInLineWith(prev, cid, path_key)) |raw| {
                var out: Label = .{ .source = .tool_file_path };
                out.len = writeText(&out.buf, basenameOf(raw));
                if (out.len > 0) return out;
            }
        }
    }

    // ② 사용자가 붙여넣은 이미지 — 같은 메시지의 텍스트가 그 정체다.
    //    codex 는 `<image …>` 래퍼와 질문이 **둘 다** `text` 로 들어오므로 래퍼가 아닌 쪽을 고른다.
    var best: ?[]const u8 = null;
    var wrapper: ?[]const u8 = null;
    var i: usize = 0;
    while (findValueFrom(prefix, text_key, i)) |found| {
        i = found.end;
        const raw = found.value;
        if (isWrapper(raw)) {
            if (wrapper == null) wrapper = raw;
            continue;
        }
        if (isClosingTag(raw)) continue;
        if (!isBlank(raw)) best = raw; // 마지막 것이 이긴다 — codex 는 질문이 래퍼 뒤에 온다
    }
    if (best) |raw| {
        var out: Label = .{ .source = .message_text };
        out.len = writeText(&out.buf, stripImageMarkers(raw));
        if (out.len > 0) return out;
    }

    // ③ 질문 없이 이미지만 보낸 codex — 래퍼의 경로라도 말한다.
    if (wrapper) |raw| {
        if (std.mem.indexOf(u8, raw, wrapper_path_key)) |at| {
            const start = at + wrapper_path_key.len;
            const end = std.mem.indexOfPos(u8, raw, start, "\\\"") orelse raw.len;
            var out: Label = .{ .source = .codex_wrapper_path };
            out.len = writeText(&out.buf, basenameOf(raw[start..end]));
            if (out.len > 0) return out;
        }
    }
    return .{};
}

/// 앞선 줄들 중 **그 id 가 든 줄**에서만 경로를 뽑는다. 뒤에서부터 본다(가까운 호출이 그 이미지의 것이다).
///
/// **줄을 넘나들지 않는 것이 핵심이다.** 창을 통째로 훑어 경로를 집으면 id 는 A 레코드에서, 경로는
/// B 레코드에서 나올 수 있다 — 빈 라벨은 아무 말도 안 하지만 틀린 라벨은 거짓말이다.
///
/// 창의 첫 줄은 잘려 있을 수 있는데, 잘린 값은 `findValueFrom` 이 닫는 따옴표가 없어 거부한다.
fn pathInLineWith(prev: []const u8, id: []const u8, key: []const u8) ?[]const u8 {
    var end: usize = prev.len;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, prev[0 .. end - 1], '\n')) |at| at + 1 else 0;
        const line = prev[start .. end - 1 + @intFromBool(prev[end - 1] != '\n')];
        if (lineHasId(line, id)) return findValue(line, key);
        if (start == 0) break;
        end = start;
    }
    return null;
}

/// 그 줄이 이 id 의 레코드인가. `"id":"<v>"` 와 `"call_id":"<v>"` 둘 다 본다 — Claude 는 앞을,
/// Codex 는 뒤를 쓴다.
fn lineHasId(line: []const u8, id: []const u8) bool {
    for ([_][]const u8{ id_key, call_id_key }) |k| {
        var i: usize = 0;
        while (findValueFrom(line, k, i)) |found| {
            i = found.end;
            if (std.mem.eql(u8, found.value, id)) return true;
        }
    }
    return false;
}

const Found = struct { value: []const u8, end: usize };

/// `"key":"…"` 의 **이스케이프 그대로인** 값. 닫는 따옴표는 `\"` 를 건너뛰며 찾는다.
fn findValueFrom(hay: []const u8, key: []const u8, from: usize) ?Found {
    const at = std.mem.indexOfPos(u8, hay, from, key) orelse return null;
    const start = at + key.len;
    var i = start;
    while (i < hay.len) : (i += 1) {
        switch (hay[i]) {
            '\\' => i += 1, // 이스케이프된 한 글자를 건너뛴다(닫는 따옴표를 오인하지 않게)
            '"' => return .{ .value = hay[start..i], .end = i + 1 },
            else => {},
        }
    }
    return null; // 잘린 줄 — 반쪽 값을 쓰지 않는다
}

fn findValue(hay: []const u8, key: []const u8) ?[]const u8 {
    const f = findValueFrom(hay, key, 0) orelse return null;
    return f.value;
}

fn isWrapper(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, wrapper_open);
}

fn isClosingTag(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "</image>");
}

/// provider 상용구 `[Image #1] ` 를 벗긴다. 사용자가 쓴 말이 아니라 **포장**이고, 160 px 라벨에서
/// 열한 칸을 먹으면 정작 정체가 밀려난다. 여러 개 붙어 오면(`[Image #1] [Image #2] `) 다 벗긴다.
fn stripImageMarkers(text: []const u8) []const u8 {
    var s = text;
    while (std.mem.startsWith(u8, s, "[Image #")) {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse break;
        if (close > 16) break; // `]` 가 멀면 그건 마커가 아니라 본문이다
        var next = s[close + 1 ..];
        while (next.len > 0 and next[0] == ' ') next = next[1..];
        if (next.len == 0) break; // 마커뿐이면 벗기지 않는다 — 빈 라벨보다 낫다
        s = next;
    }
    return s;
}

fn isBlank(raw: []const u8) bool {
    for (raw) |c| {
        if (c != ' ' and c != '\t' and c != 'n' and c != '\\') return false;
    }
    return true;
}

/// 경로의 마지막 조각. **이스케이프 이전** 문자열에서도 `/` 는 그대로라 안전하다.
fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| {
        if (at + 1 < path.len) return path[at + 1 ..];
    }
    return path;
}

/// JSON 이스케이프를 풀고, 연속 공백을 하나로 접고, 상한에서 **글자 경계**로 자른다.
/// 글자 경계를 안 지키면 반쪽 UTF-8 이 남아 렌더러가 깨진 글자를 그린다.
fn writeText(out: []u8, raw: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < raw.len) {
        var cp_buf: [4]u8 = undefined;
        var chunk: []const u8 = undefined;
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const c = raw[i + 1];
            i += 2;
            switch (c) {
                'n', 't', 'r', 'b', 'f' => {
                    pending_space = w > 0;
                    continue;
                },
                'u' => {
                    const cp = parseHex4(raw, i) orelse continue;
                    i += 4;
                    // 서로게이트는 짝을 맞춰야 뜻이 선다. 못 맞추면 그 글자를 버린다(깨진 글자보다 낫다).
                    var code: u21 = cp;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                            const lo = parseHex4(raw, i + 2) orelse continue;
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                code = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                                i += 6;
                            } else continue;
                        } else continue;
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) continue;
                    if (isControl(code)) {
                        pending_space = w > 0;
                        continue;
                    }
                    const n = std.unicode.utf8Encode(code, &cp_buf) catch continue;
                    chunk = cp_buf[0..n];
                },
                '"', '\\', '/' => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
                else => {
                    cp_buf[0] = c;
                    chunk = cp_buf[0..1];
                },
            }
        } else {
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                i += 1;
                continue; // 깨진 바이트는 버린다
            };
            if (i + n > raw.len) break;
            chunk = raw[i .. i + n];
            i += n;
            if (n == 1 and (chunk[0] == ' ' or chunk[0] == '\t' or chunk[0] == '\n' or chunk[0] == '\r')) {
                pending_space = w > 0;
                continue;
            }
        }
        if (pending_space) {
            if (w + 1 > out.len) break;
            out[w] = ' ';
            w += 1;
            pending_space = false;
        }
        if (w + chunk.len > out.len) break; // 글자 **경계**에서 멈춘다
        @memcpy(out[w .. w + chunk.len], chunk);
        w += chunk.len;
    }
    return w;
}

/// 제어문자인가(C0 · DEL · C1). **라벨은 사용자 대화 본문**이라 무엇이든 들어올 수 있고, JSON 은
/// 제어문자를 `\uXXXX` 로 실어 나른다. 그대로 두면 그리기 경로에 코드포인트로 들어가 글자가 아닌
/// 것을 그리려 하고, `U+0000` 은 빈 칸으로 읽혀 **라벨이 거기서 잘린 것처럼** 보인다.
fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

fn parseHex4(raw: []const u8, at: usize) ?u16 {
    if (at + 4 > raw.len) return null;
    return std.fmt.parseInt(u16, raw[at .. at + 4], 16) catch null;
}

// ── 테스트 ─────────────────────────────────────────────────────────────────────
//
// 픽스처는 **실측한 구조**를 따르되 값은 합성이다(사용자 대화를 커밋하지 않는다).

const testing = std.testing;

test "에이전트가 읽은 이미지: 직전 줄의 도구 호출이 정체다" {
    // 실측 구조: tool_result 줄에 `tool_use_id` 가 base64 앞에 오고, 직전 줄이 그 `tool_use` 다.
    const prev =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Read","input":{"file_path":"/Users/me/shots/screen.png"}}]}}
    ;
    const prefix =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_01AB","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"
    ;
    const l = label(prefix, prev);
    try testing.expectEqual(Source.tool_file_path, l.source);
    try testing.expectEqualStrings("screen.png", l.text());
}

test "id 가 안 맞으면 라벨을 붙이지 않는다 — 빈 라벨보다 틀린 라벨이 나쁘다" {
    const prev =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_OTHER","name":"Read","input":{"file_path":"/x/other.png"}}]}}
    ;
    const prefix =
        \\{"message":{"content":[{"tool_use_id":"toolu_01AB","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expect(label(prefix, prev).isEmpty());
    // 직전 줄이 아예 없어도 같다.
    try testing.expect(label(prefix, "").isEmpty());
}

test "사용자가 붙여넣은 이미지: 같은 메시지의 텍스트가 정체다" {
    const prefix =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #1] 이 화면 색이 이상해요"},{"type":"image","source":{"type":"base64","data":"
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.message_text, l.source);
    // provider 상용구 `[Image #1] ` 는 벗긴다 — 사용자가 쓴 말만 남는다.
    try testing.expectEqualStrings("이 화면 색이 이상해요", l.text());
}

test "codex: 래퍼가 아니라 질문을 고른다" {
    // 실측 구조: `<image …>` 래퍼 · `</image>` 닫기 · 질문이 각각 별개 `input_text` 로 온다.
    const prefix =
        \\{"content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/pasted-1.png\">"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"이 배치가 맞나요?"},{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.message_text, l.source);
    try testing.expectEqualStrings("이 배치가 맞나요?", l.text());
}

test "codex: 질문이 없으면 래퍼의 경로라도 말한다" {
    const prefix =
        \\{"content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/dropped/pasted-54737-2.png\">"},{"type":"input_text","text":"</image>"},{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, "");
    try testing.expectEqual(Source.codex_wrapper_path, l.source);
    try testing.expectEqualStrings("pasted-54737-2.png", l.text());
}

test "이스케이프를 풀고 줄바꿈·연속 공백을 접는다" {
    const prefix =
        \\{"content":[{"type":"text","text":"첫 줄\n\n  둘째   줄 \"따옴표\" 와 \\ 역슬래시"},{"type":"image","source":{"type":"base64","data":"
    ;
    const l = label(prefix, "");
    try testing.expectEqualStrings("첫 줄 둘째 줄 \"따옴표\" 와 \\ 역슬래시", l.text());
}

test "\\u 이스케이프: 짝이 맞는 서로게이트는 살리고 홀로 남은 것은 버린다" {
    // 짝 맞음(U+1F600). 깨진 글자를 그리느니 버리는 편이 낫다는 규율은 홀로 남은 쪽이 지킨다.
    const ok =
        \\{"content":[{"type":"text","text":"웃음 \ud83d\ude00 끝"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("웃음 😀 끝", label(ok, "").text());
    const lone =
        \\{"content":[{"type":"text","text":"홀로 \ud83d 끝"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("홀로 끝", label(lone, "").text());
}

test "상한에서 글자 경계로 자른다 — 반쪽 UTF-8 을 남기지 않는다" {
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const head = "{\"content\":[{\"type\":\"text\",\"text\":\"";
    @memcpy(buf[0..head.len], head);
    w = head.len;
    while (w + 3 < 1000) : (w += 3) @memcpy(buf[w .. w + 3], "가");
    const tail = "\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"";
    @memcpy(buf[w .. w + tail.len], tail);
    w += tail.len;

    const l = label(buf[0..w], "");
    try testing.expect(l.len <= max_label_bytes);
    try testing.expect(l.len > 0);
    try testing.expect(std.unicode.utf8ValidateSlice(l.text()));
    try testing.expectEqual(@as(usize, 0), l.len % 3); // '가' 는 3바이트 — 반쪽이 없다
}

test "아무 단서도 없으면 빈 라벨 — 지어내지 않는다" {
    const prefix =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_X","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expect(label(prefix, "{\"type\":\"assistant\"}").isEmpty());
    try testing.expect(label("", "").isEmpty());
}

test "잘린 값은 쓰지 않는다 — 닫는 따옴표가 없으면 없는 것이다" {
    // 앞부분 상한에 걸려 잘린 줄. 반쪽 텍스트를 라벨로 쓰면 문장이 중간에서 끊긴 채 굳는다.
    const prefix =
        \\{"content":[{"type":"text","text":"여기서 잘린
    ;
    try testing.expect(label(prefix, "").isEmpty());
}

test "provider 상용구 `[Image #N] ` 는 벗긴다 — 사용자가 쓴 말이 아니다" {
    const one =
        \\{"content":[{"type":"text","text":"[Image #1] 이 배치가 이상해요"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("이 배치가 이상해요", label(one, "").text());
    const many =
        \\{"content":[{"type":"text","text":"[Image #1] [Image #2] 둘 다 보세요"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("둘 다 보세요", label(many, "").text());
    // 마커뿐이면 벗기지 않는다 — 빈 라벨보다 「[Image #1]」이라도 낫다.
    const only =
        \\{"content":[{"type":"text","text":"[Image #1]"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("[Image #1]", label(only, "").text());
    // 대괄호가 멀면 마커가 아니라 본문이다.
    const not_marker =
        \\{"content":[{"type":"text","text":"[Image #1 아주 긴 무언가] 뒤"},{"type":"image","source":{"type":"base64","data":"
    ;
    try testing.expectEqualStrings("[Image #1 아주 긴 무언가] 뒤", label(not_marker, "").text());
}

test "제어문자는 그리기 경로로 새지 않는다 — 공백으로 접는다" {
    // JSON 은 제어문자를 \uXXXX 로 싣는다. 그대로 두면 U+0000 이 빈 칸으로 읽혀 라벨이 거기서
    // 잘린 것처럼 보이고, ESC 는 글자가 아닌 것을 그리려 한다.
    const prefix =
        \\{"content":[{"type":"text","text":"AA \\u001b[31m BB \\u0000 \\u0007 CC"},{"type":"image","source":{"type":"base64","data":"
    ;
    const got = label(prefix, "").text();
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x00) == null);
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x07) == null);
    // 내용은 남는다 — 통째로 버리지 않는다.
    try testing.expect(std.mem.indexOf(u8, got, "AA") != null);
    try testing.expect(std.mem.indexOf(u8, got, "CC") != null);
}

test "codex 가 읽은 이미지: 앞선 `view_image` 호출의 path 가 정체다" {
    // 실측(2026-08-30): `view_image` 결과 16건 중 13건이 그 줄에 텍스트가 없어 옛 규칙으로는 빈 라벨이었다.
    // 그리고 호출이 **2줄 뒤**인 것이 12건이라 「직전 줄 하나」로는 못 잡았다.
    const prev =
        \\{"type":"response_item","payload":{"type":"function_call","call_id":"call_77","name":"view_image","path":"/Users/me/shots/wide.png"}}
        \\{"type":"event_msg","payload":{"type":"token_count","info":{}}}
    ;
    const prefix =
        \\{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_77","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    const l = label(prefix, prev);
    try testing.expectEqual(Source.tool_file_path, l.source);
    try testing.expectEqualStrings("wide.png", l.text());
}

test "id 는 맞는데 경로가 **다른 줄**에 있으면 쓰지 않는다 — 줄을 넘나들지 않는다" {
    // 창을 통째로 훑어 `path` 를 집으면 id 는 A 레코드에서, 경로는 B 레코드에서 나온다.
    // 그것이 이 모듈이 처음부터 막으려던 「틀린 라벨」이다.
    const prev =
        \\{"payload":{"type":"function_call","call_id":"call_77","name":"view_image"}}
        \\{"payload":{"type":"other","path":"/Users/me/shots/NOT-MINE.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_77","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expect(label(prefix, prev).isEmpty());
}

test "여러 호출이 쌓여 있으면 **가까운** 것을 쓴다" {
    const prev =
        \\{"payload":{"type":"function_call","call_id":"call_1","name":"view_image","path":"/a/old.png"}}
        \\{"payload":{"type":"function_call","call_id":"call_2","name":"view_image","path":"/a/near.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_2","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("near.png", label(prefix, prev).text());
    // 앞쪽 호출을 가리키면 그것을 쓴다(가까운 것만 보는 게 아니라 **맞는 것**을 본다).
    const prefix1 =
        \\{"payload":{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("old.png", label(prefix1, prev).text());
}

test "창의 첫 줄이 잘려 있어도 안전하다 — 반쪽 값을 쓰지 않는다" {
    // 64 KiB 창은 레코드 한가운데서 시작할 수 있다.
    const prev =
        \\path":"/a/truncated
        \\{"payload":{"type":"function_call","call_id":"call_9","name":"view_image","path":"/a/ok.png"}}
    ;
    const prefix =
        \\{"payload":{"type":"function_call_output","call_id":"call_9","output":[{"type":"input_image","image_url":"data:image/png;base64,
    ;
    try testing.expectEqualStrings("ok.png", label(prefix, prev).text());
}

test "검색: 대소문자 없이 부분 일치, 빈 검색어는 전부" {
    // 파일명과 사람이 쓴 문장이 한 목록에 섞여 있다 — 접두사만 보면 문장 쪽을 못 찾는다.
    try testing.expect(matches("dock-layout.png", "dock"));
    try testing.expect(matches("dock-layout.png", "LAYOUT")); // 대소문자 무시
    try testing.expect(matches("dock-layout.png", ".png")); // 가운데·끝도 걸린다
    try testing.expect(matches("이 화면 배치가 이상합니다", "배치"));
    try testing.expect(!matches("dock-layout.png", "sidebar"));
    // 빈 검색어 = 필터 꺼짐.
    try testing.expect(matches("아무거나", ""));
    try testing.expect(matches("", ""));
    // 라벨이 비면(설명을 못 만든 이미지) 검색어가 있는 한 안 걸린다 — 지어내지 않는다.
    try testing.expect(!matches("", "dock"));
    // 검색어가 라벨보다 길면 걸릴 수 없다.
    try testing.expect(!matches("ab", "abc"));
}

test "검색: 한글은 접지 않는다 — 바이트 그대로 본다" {
    // 한글에는 대소문자가 없다. ASCII 접기가 한글 바이트를 건드리면 엉뚱한 것이 걸린다.
    try testing.expect(matches("배치가 이상합니다", "이상"));
    try testing.expect(!matches("배치가 이상합니다", "정상"));
}

/// 시각을 찾을 창 크기(2026-08-30 실측, 위 모듈 주석).
pub const time_window_after: usize = 256;
pub const time_window_before: usize = 16 * 1024;

const timestamp_key = "\"timestamp\":\"";

/// `"timestamp":"2026-08-30T09:13:22.123Z"` → Unix 초. 못 읽으면 **0**(모름).
///
/// **UTC 로만 읽는다.** 두 provider 다 `Z` 로 끝나는 것을 실측으로 확인했고, 오프셋이 붙은 표기는
/// 여기서 0 을 준다 — 틀린 시각을 그리는 것보다 안 그리는 편이 낫다.
pub fn timestampSeconds(window: []const u8) i64 {
    const raw = findValue(window, timestamp_key) orelse return 0;
    return parseIso8601(raw);
}

/// `YYYY-MM-DDThh:mm:ss` 앞부분만 본다(소수 초·`Z` 는 무시). 모양이 어긋나면 0.
pub fn parseIso8601(raw: []const u8) i64 {
    if (raw.len < 19) return 0;
    if (raw[4] != '-' or raw[7] != '-' or raw[13] != ':' or raw[16] != ':') return 0;
    if (raw[10] != 'T' and raw[10] != ' ') return 0;
    const year = twoOrFour(raw[0..4]) orelse return 0;
    const month = twoOrFour(raw[5..7]) orelse return 0;
    const day = twoOrFour(raw[8..10]) orelse return 0;
    const hour = twoOrFour(raw[11..13]) orelse return 0;
    const minute = twoOrFour(raw[14..16]) orelse return 0;
    const second = twoOrFour(raw[17..19]) orelse return 0;
    if (year < 1970 or year > 9999) return 0;
    if (month < 1 or month > 12 or day < 1 or day > 31) return 0;
    if (hour > 23 or minute > 59 or second > 60) return 0; // 윤초 60 을 거절하지 않는다

    // 1970-01-01 부터의 날 수. `std.time.epoch` 의 윤년 규칙을 쓴다.
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += if (std.time.epoch.isLeapYear(y)) 366 else 365;
    var mo: u16 = 1;
    while (mo < month) : (mo += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(@as(u4, @intCast(mo))));
    }
    days += @as(i64, day) - 1;
    return days * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn twoOrFour(digits: []const u8) ?u16 {
    var v: u16 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

test "시각: 두 provider 의 실제 모양을 읽는다" {
    // Claude(소수 초 3자리)·Codex(소수 초 6자리) 둘 다 `Z` 로 끝난다.
    const claude = "{\"type\":\"user\",\"timestamp\":\"2026-08-30T09:13:22.123Z\"}";
    const codex = "{\"timestamp\":\"2026-08-30T09:13:22.123456Z\",\"payload\":{}}";
    const want: i64 = 1788081202; // 2026-08-30T09:13:22Z
    try std.testing.expectEqual(want, timestampSeconds(claude));
    try std.testing.expectEqual(want, timestampSeconds(codex));
}

test "시각: 모양이 어긋나면 0 — 없는 시각을 지어내지 않는다" {
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{}"));
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"어제\"}"));
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"2026-13-01T00:00:00Z\"}")); // 13월
    try std.testing.expectEqual(@as(i64, 0), timestampSeconds("{\"timestamp\":\"1969-12-31T23:59:59Z\"}")); // epoch 이전
    try std.testing.expectEqual(@as(i64, 0), parseIso8601("2026-08-30"));
}

test "시각: 윤년과 연·월 경계를 넘는다" {
    // 2028 은 윤년이라 2-29 가 있다. 하루를 잘못 세면 여기서 걸린다.
    try std.testing.expectEqual(@as(i64, 1835395200), parseIso8601("2028-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), parseIso8601("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 86399), parseIso8601("1970-01-01T23:59:59Z"));
    // 연 경계 — 12-31 다음이 다음 해 01-01 이다.
    const dec = parseIso8601("2026-12-31T23:59:59Z");
    const jan = parseIso8601("2027-01-01T00:00:00Z");
    try std.testing.expectEqual(dec + 1, jan);
}
