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
    /// Claude `{"type":"tool_use","id":…,"name":…,"input":{…}}` — 에이전트가 도구를 부른 자리.
    /// MCP 호출도 여기다(이름만 `mcp__서버__도구` 다).
    claude_tool_use,
    /// Codex `payload.type == "custom_tool_call"` 또는 `"function_call"`.
    codex_tool_call,

    pub fn provider(self: Kind) Provider {
        return switch (self) {
            .claude_image, .claude_tool_file, .claude_tool_use => .claude,
            .codex_input_image, .codex_tool_call => .codex,
        };
    }

    /// 그림인가. **디코드·격자·썸네일은 이것만 본다** — 활동 `Hit` 의 `data_offset` 은 base64 가 아니라
    /// 사람이 읽는 문자열을 가리키므로, 가르지 않으면 디코더가 명령문을 PNG 로 열려고 든다.
    pub fn isImage(self: Kind) bool {
        return switch (self) {
            .claude_image, .claude_tool_file, .codex_input_image => true,
            .claude_tool_use, .codex_tool_call => false,
        };
    }
};

/// 활동이 어떤 종류인가 — 화면의 「읽기 / 실행」 필터가 이 값을 본다(계약 §2.1).
///
/// **도구 이름으로만 가른다.** `grep` 을 「읽기」로 옮기려면 명령 문자열을 해석해야 하는데, 파이프·
/// 리다이렉트·서브셸이 섞이면 「읽기인가」에 정답이 없고 그 해석은 규칙이 두 벌이 된다(계약 §2.3).
pub const Activity = enum {
    /// 이미지 `Hit` 이다 — 활동 축이 없다.
    none,
    /// Claude `Read` · Codex `view_image`.
    read,
    /// Claude `Bash` · Codex `exec`/`shell`.
    exec,
    /// 그 밖 전부(Edit·Write·MCP·provider 가 새로 만든 도구).
    other,

    /// 도구 이름을 축으로 옮긴다. **모르는 이름은 `other`** — 없는 분류를 지어내지 않는다.
    pub fn fromToolName(name: []const u8) Activity {
        if (std.mem.eql(u8, name, "Read")) return .read;
        if (std.mem.eql(u8, name, "view_image")) return .read;
        if (std.mem.eql(u8, name, "Bash")) return .exec;
        if (std.mem.eql(u8, name, "exec")) return .exec;
        if (std.mem.eql(u8, name, "shell")) return .exec;
        return .other;
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
    /// 활동 축(계약 §2.1의 필터). 이미지는 `none` 이다.
    activity: Activity = .none,
    /// 도구 이름의 자리 — **줄 시작으로부터의 상대 오프셋**이다(`line_offset` 을 더하면 파일 절대).
    /// 절대값을 담지 않는 이유는 크기다: 이름은 언제나 같은 줄 안이므로 u32 로 충분하고, `Hit` 이
    /// 12,200개까지 가므로(계약 §4.2) 8 바이트를 아낀다. 이미지는 둘 다 0 이다.
    name_rel: u32 = 0,
    name_len: u16 = 0,
    /// **어느 파일**의 오프셋인가(`Chain` 안 위치). 재개 세션은 부모 rollout 까지 훑으므로(§3.3)
    /// 오프셋만으로는 어느 파일인지 알 수 없다 — 그 값으로 디코드·라벨이 파일을 연다.
    ///
    /// 0 이 현재 세션이다. 스캐너 자신은 이 값을 안 건드린다(파일 하나를 훑을 뿐이다) — 여러 파일을
    /// 이어 담는 호출자가 채운다.
    file_index: u8 = 0,
};

/// 같은 메시지(= 같은 줄)에 붙은 여러 장 중 **몇 번째**인가(§2.2).
///
/// **왜 필요한가**: 라벨은 그 줄의 사용자 텍스트에서 나오므로, 한 메시지에 붙인 N 장이 **글자 그대로
/// 같은 라벨**을 받는다. 실측(2026-09-05, 이 맥의 Claude 트랜스크립트 131 파일)이 그것을 못 박았다 —
/// 사용자 첨부 199 장 중 27 장(13 줄)이 다중 첨부였고, 그 **13 줄 전부** 텍스트 블록이 하나뿐이며
/// 위치도 첫 이미지보다 앞(136~188 B)이라 **예외 없이 N 장이 같은 문장을 받는다**. 순번이 없으면
/// 격자에 같은 줄이 N 개 뜨고 어느 것이 몇 번째인지 알 길이 없다.
///
/// 시각으로도 못 가른다 — 같은 레코드라 타임스탬프까지 같다.
pub const Seq = struct {
    /// 1-based. **0 이면 그리지 않는다** — 한 장뿐이거나(=「1/1」은 알려 주는 것이 없다) 묶음이
    /// 상한을 넘었다는 뜻이다.
    index: u16 = 0,
    total: u16 = 0,
};

/// 한 묶음을 넓힐 상한. 실측 최대는 3 장이다(2026-09-05). 이것은 성능 방어다 — 넘으면 `Seq{}` 를
/// 돌려준다. 「2/500」은 알려 주는 것이 없고, 그것을 세느라 O(n²) 를 치를 이유는 더 없다.
pub const max_seq_group: usize = 64;

/// `hits[i]` 의 순번. **`hits` 는 스캐너가 담은 그대로여야 한다**(같은 줄의 이미지가 연속이라는 것이
/// 이 함수의 유일한 가정이다). 걸러 낸 목록에 쓰면 묶음이 쪼개져 「1/1」이 되므로, 부르는 자리는
/// 전체 목록 하나뿐이다.
///
/// **배열 방향에 기대지 않는다.** 갤러리는 최신을 먼저 보이려고 전체를 뒤집는데(`std.mem.reverse`),
/// 순번은 **적힌 순서**여야 한다. 그래서 이웃과의 위치가 아니라 `data_offset` 의 크기로 센다.
pub fn sequenceAt(hits: []const Hit, i: usize) Seq {
    if (i >= hits.len) return .{};
    const me = hits[i];

    var start = i;
    while (start > 0 and sameRecord(hits[start - 1], me)) {
        start -= 1;
        if (i - start >= max_seq_group) return .{};
    }
    var end = i + 1; // exclusive
    while (end < hits.len and sameRecord(hits[end], me)) {
        end += 1;
        if (end - start > max_seq_group) return .{};
    }

    const total = end - start;
    if (total < 2) return .{}; // 한 장뿐이면 순번은 소음이다
    var rank: u16 = 1;
    for (hits[start..end]) |h| {
        if (h.data_offset < me.data_offset) rank += 1;
    }
    return .{ .index = rank, .total = @intCast(total) };
}

/// 같은 레코드(= 같은 파일의 같은 줄)인가. 줄이 곧 메시지 하나다.
fn sameRecord(a: Hit, b: Hit) bool {
    return a.file_index == b.file_index and a.line_offset == b.line_offset;
}

/// 활성 pane 이 읽을 트랜스크립트 **묶음**. 재개 세션이면 부모까지다(§3.3).
///
/// **상한이 3인 근거는 실측이다**(2026-08-30): 체인 깊이가 중앙 1, 최대 2 였다. 하나를 더 두어
/// 최대를 넘겨도 잘리지 않게 한다. 무한히 따라가면 1.8 GB 짜리 부모가 줄줄이 붙는다.
pub const max_chain: usize = 3;

pub const Chain = struct {
    files: [max_chain]Source = [_]Source{.{}} ** max_chain,
    len: usize = 0,

    pub fn get(self: *const Chain, i: usize) ?[]const u8 {
        if (i >= self.len) return null;
        const p = self.files[i].path();
        return if (p.len == 0) null else p;
    }

    /// 뒤에 잇는다. 이미 있는 경로면 **더하지 않는다** — 부모가 자기 자신을 가리키는 기록이 오면
    /// 같은 파일을 두 번 훑고 이미지가 두 배로 뜬다.
    pub fn append(self: *Chain, value: []const u8) bool {
        if (self.len >= max_chain) return false;
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.files[i].path(), value)) return false;
        }
        if (!self.files[self.len].set(value)) return false;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *Chain) void {
        for (&self.files) |*f| f.clear();
        self.len = 0;
    }

    pub fn isEmpty(self: *const Chain) bool {
        return self.len == 0;
    }

    /// 첫 파일(= 현재 세션). 갤러리가 「소스가 갈렸나」를 판정하는 기준이다.
    pub fn head(self: *const Chain) []const u8 {
        return if (self.len == 0) "" else self.files[0].path();
    }
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
const claude_tool_use_marker = "\"type\":\"tool_use\"";
const codex_custom_tool_call_marker = "\"type\":\"custom_tool_call\"";
const codex_function_call_marker = "\"type\":\"function_call\"";

const name_key = "\"name\":\"";
/// 대상 문자열의 자리를 정하는 키들. **순서가 계약이다**(계약 §2.2) — 앞의 것이 있으면 그것을 쓴다.
const description_key = "\"description\":\"";
const file_path_key = "\"file_path\":\"";
const command_key = "\"command\":\"";
const input_key = "\"input\":\"";
const arguments_key = "\"arguments\":\"";

/// 대상 문자열의 끝을 찾을 때 훑는 최대 바이트. 라벨 상한(160 B)의 3.2 배다 — 라벨에 들어갈 몫과
/// 「이 자리가 어디서 시작하는가」만 알면 되고, 전문은 펼칠 때 파일에서 다시 읽는다.
const max_target_scan_bytes: usize = 512;

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
    // **가장 먼저, 그리고 줄 앞부분만 본다.** 여기서 되돌아가면 아래 세 패스를 통째로 건너뛴다 —
    // 실측 파일에서 compacted 줄이 **바이트의 41%(812 MB / 871 줄)** 라 그 절약이 크다.
    if (isCompacted(line)) return;

    const before = out.items.len;
    try scanClaudeImages(allocator, line, line_offset, out);
    const after_images = out.items.len;
    try scanClaudeToolFiles(allocator, line, line_offset, out);
    dropToolFileDuplicates(out, before, after_images);
    try scanCodexImages(allocator, line, line_offset, out);
    // 활동은 이미지와 **같은 줄에 공존하지 않는다**(호출 레코드와 결과 레코드가 다른 줄이다). 그래도
    // 순서를 뒤에 두는 이유는 위 세 패스가 `dropToolFileDuplicates` 로 **자기들끼리 접기** 때문이다 —
    // 사이에 끼면 그 접기가 남의 항목을 셈에 넣는다.
    try scanClaudeToolUses(allocator, line, line_offset, out);
    try scanCodexToolCalls(allocator, line, line_offset, out);
}

/// `compacted` 레코드인가. **줄 앞부분만** 본다.
///
/// 예전에는 줄 전체를 훑었는데, 실측(1,981 MB rollout)에서 그 한 패스가 **2,817 ms · 전체의 28%**
/// 였다. 그런데 이 마커는 JSON 구조상 **줄 머리에 고정**이다 — 실측 296 파일 / **14,206 줄**에서
/// 위치가 중앙 40, **최대 55** 였다. 창을 그 74 배로 잡아도 O(1) 이다.
///
/// **창 밖에 있으면 못 잡는다**: 그 줄의 이미지가 갤러리에 다시 뜬다(compacted 는 이전 대화를
/// 이미지째 재수록하므로 실측 15,140 개 대 실제 151 개가 된다). 창을 넉넉히 두는 이유가 그것이다.
fn isCompacted(line: []const u8) bool {
    const window = line[0..@min(line.len, compacted_search_window)];
    return std.mem.indexOf(u8, window, compacted_marker) != null;
}

/// `compacted` 마커를 찾을 창(바이트). 실측 최대 55 의 **9.3 배**다.
///
/// **더 넓히면 그만큼 느려진다**: 줄마다 이 창을 훑고 이 파일에는 줄이 649,381 개라, 4 KiB 로 두면
/// 누적 1.9 GB 를 훑어 **2.0 초**가 된다(실측). 512 B 면 332 MB 라 0.4 초다. 마커가 구조상 줄 머리에
/// 고정(중앙 40 · 최대 55)이므로 이 여유로 충분하다.
const compacted_search_window: usize = 512;

/// **같은 이미지의 두 번째 사본을 접는다**(§4.3). 접지 않으면 에이전트가 읽은 이미지가 갤러리에
/// 두 번씩 뜬다 — 실측 3,226 장 중 1,424 장(44%)이 이 사본이었다.
///
/// 접는 기준은 **같은 줄에 `claude_image` 가 있는가** 하나다. 왜 그것으로 충분한지는 실측이 말한다
/// (2026-08-29, 실제 트랜스크립트 2,548 파일):
///
/// | 잰 것 | 값 | 뜻 |
/// | --- | --- | --- |
/// | `tool_file` 만 있는 줄 | **0** | 접어도 잃는 것이 없다 |
/// | 개수 불일치 줄 | **0** | 언제나 1:1 이다 |
/// | payload 가 다른 줄 | **0** | base64 바이트가 글자 그대로 같다 |
///
/// **그래도 「같은 줄에 있으면」 조건을 남긴다.** 무조건 버리면 provider 가 언젠가 `toolUseResult` 만
/// 쓰는 레코드를 내보낼 때 그 이미지가 통째로 사라지고, 증상은 「어떤 이미지는 안 보인다」라 원인을
/// 찾기 어렵다. 조건을 두면 그 경우 사본이 아니라 **유일본**이므로 그대로 남는다.
fn dropToolFileDuplicates(out: *std.ArrayList(Hit), line_start: usize, images_end: usize) void {
    if (images_end == line_start) return; // 이 줄에 `claude_image` 가 없다 = 사본이 아니라 유일본
    if (out.items.len == images_end) return; // 접을 것이 없다
    out.shrinkRetainingCapacity(images_end);
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

/// Claude 의 도구 호출 한 건을 잡는다.
///
/// **한 줄에 하나다**(실측 39,618 / 39,618 — 계약 §3.1). 병렬 호출도 provider 가 레코드를 나눠 쓰므로
/// 반복 루프가 필요 없고, 그래서 키를 **줄 전체**에서 찾아도 남의 레코드 값을 집을 수 없다. 이미지
/// 패스가 `key_search_window` 로 창을 좁히는 것과 갈리는 지점이고, 그 차이가 여기서는 필수다 —
/// `description` 은 23 KB 짜리 `command` 뒤에 올 수 있어 512 바이트 창이면 못 본다.
fn scanClaudeToolUses(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    const m = std.mem.indexOf(u8, line, claude_tool_use_marker) orelse return;
    const after = m + claude_tool_use_marker.len;
    const name = findQuotedValue(line, after, name_key) orelse return;
    const activity = Activity.fromToolName(line[name.start .. name.start + name.len]);
    // 대상이 없으면 **이름이 대상이다** — 「무엇을 했는지」를 못 적느니 도구 이름이라도 적는다.
    const target = pickClaudeTarget(line, after) orelse name;
    try appendActivity(allocator, out, line_offset, target, name, .claude_tool_use, activity);
}

/// Codex 의 도구 호출 한 건. `custom_tool_call` 과 `function_call` 두 모양을 다 본다.
///
/// **결과 레코드와 헷갈리지 않는다**: 마커가 닫는 따옴표까지 포함하므로 `"custom_tool_call_output"`
/// 에는 걸리지 않는다.
fn scanCodexToolCalls(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: u64,
    out: *std.ArrayList(Hit),
) !void {
    const m = std.mem.indexOf(u8, line, codex_custom_tool_call_marker) orelse
        std.mem.indexOf(u8, line, codex_function_call_marker) orelse return;
    const after = m;
    const name = findQuotedValue(line, after, name_key) orelse return;
    const activity = Activity.fromToolName(line[name.start .. name.start + name.len]);
    const target = pickCodexTarget(line, after) orelse name;
    try appendActivity(allocator, out, line_offset, target, name, .codex_tool_call, activity);
}

/// 화면에 적을 **대상**의 자리를 고른다. 순서가 계약이다(§2.2) — 실측이 정한 순서다:
/// `description` 은 Bash 의 68.8% 에 있고 중앙 26 B 라 라벨에 언제나 들어가는 반면, 명령 첫 줄은
/// **52.4% 가 여러 줄**이고 **27.4%** 가 라벨 상한을 넘는다.
fn pickClaudeTarget(line: []const u8, from: usize) ?Span {
    if (findEscapedValue(line, from, description_key)) |v| return v;
    if (findEscapedValue(line, from, file_path_key)) |v| return v;
    if (findEscapedValue(line, from, command_key)) |v| return v;
    return null;
}

/// Codex 호출 레코드에는 **사람이 읽는 설명 필드가 없다**(키 실측: `call_id,id,input,…,name,status,type`).
/// 그래서 언제나 명령 문자열이 대상이고, provider 사이에서 화면이 달라지는 것을 그대로 둔다(§2.2).
fn pickCodexTarget(line: []const u8, from: usize) ?Span {
    if (findEscapedValue(line, from, input_key)) |v| return v;
    if (findEscapedValue(line, from, arguments_key)) |v| return v;
    return null;
}

/// 이스케이프를 인지해 따옴표 값의 끝을 찾는다.
///
/// **base64 와 다른 점이 이것이다.** 이미지 payload 에는 이스케이프가 없어 다음 `"` 가 곧 끝이지만,
/// 사람이 쓴 명령에는 `\"` 와 `\n` 이 흔하다(명령의 52.4% 가 여러 줄이다). 그대로 `indexOfScalar`
/// 를 쓰면 명령 중간에서 잘려 **엉뚱한 자리**를 대상으로 잡는다.
fn findEscapedValue(line: []const u8, from: usize, key: []const u8) ?Span {
    const k = std.mem.indexOfPos(u8, line, from, key) orelse return null;
    const start = k + key.len;
    // **끝까지 훑지 않는다.** 이 자리는 라벨(160 B)에 들어갈 만큼만 알면 되고, 펼침은 파일에서 그
    // 자리부터 **다시** 읽는다(계약 §2.4). 명령은 최대 23 KB 라 끝을 찾자고 전부 훑으면 스캔이
    // 몇 배가 된다 — 실측으로 그 대가를 확인하고 상한을 뒀다.
    const limit = @min(line.len, start + max_target_scan_bytes);
    var i = start;
    while (i < limit) : (i += 1) {
        switch (line[i]) {
            // 이스케이프된 한 글자는 값의 일부다 — 그것이 `"` 여도 끝이 아니다.
            '\\' => i += 1,
            '"' => return .{ .start = start, .len = i - start },
            else => {},
        }
    }
    // 상한 안에서 끝을 못 봤다 = 값이 그보다 길다. **잘린 자리를 준다** — 라벨은 어차피 160 B 이고
    // 펼침은 파일에서 다시 읽으므로, 여기서 「없다」로 답하면 긴 명령이 통째로 목록에서 사라진다.
    if (limit > start) {
        var end = limit;
        // 이스케이프 한 쌍을 반으로 자르지 않는다.
        if (line[end - 1] == '\\') end -= 1;
        if (end > start) return .{ .start = start, .len = end - start };
    }
    return null;
}

fn appendActivity(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Hit),
    line_offset: u64,
    target: Span,
    name: Span,
    kind: Kind,
    activity: Activity,
) !void {
    if (target.len == 0) return;
    if (target.len > std.math.maxInt(u32)) return;
    // 이름은 줄 시작 상대라 u32/u16 에 담는다. 한 줄 상한(16 MiB) 안이면 도달하지 않는 방어다.
    if (name.start > std.math.maxInt(u32) or name.len > std.math.maxInt(u16)) return;
    try out.append(allocator, .{
        .line_offset = line_offset,
        .data_offset = line_offset + target.start,
        .data_len = @intCast(target.len),
        .kind = kind,
        .mime = .unknown,
        .activity = activity,
        .name_rel = @intCast(name.start),
        .name_len = @intCast(name.len),
    });
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

/// 한 파일에서 담는 **활동** 자리의 상한. 이미지와 **따로** 센다.
///
/// **한 통으로 세면 갤러리가 조용히 빈다.** 활동은 세션당 최대 12,200개인데(활동 뷰 계약 §4.2) 이미지는
/// 한 파일 최대 770개다. 같은 4096 을 나눠 쓰면 활동이 상한을 채운 파일에서 **이미지가 밀려나고**,
/// 사용자에게는 「이미지가 없습니다」로 보인다 — 고장과 구분되지 않는 종류의 실패다.
///
/// 값은 실측 최대(12,200)의 1.34 배다. `Hit` 이 32 바이트 미만이므로 16,384개라도 512 KB 다.
pub const max_activity_hits_per_file: usize = 16384;

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
    /// 지금까지 담은 이미지 수. **상한을 종류별로 세기 위해** 든다(`max_hits_per_file`).
    image_count: usize = 0,
    /// 지금까지 담은 활동 수(`max_activity_hits_per_file`).
    activity_count: usize = 0,
    /// 이월 버퍼를 앞으로 당긴 **횟수**. 진단용이자 회귀 가드다 — 개행을 못 만난 청크에서 이 값이
    /// 오르면 긴 줄 하나가 O(N²) 로 바이트를 옮기고 있다는 뜻이다(실측 52.9 초 → 10.1 초 수정).
    carry_moves: u64 = 0,

    pub fn deinit(self: *StreamScanner, allocator: std.mem.Allocator) void {
        self.carry.deinit(allocator);
        self.* = .{};
    }

    /// 방금 줄에서 나온 `Hit` 들을 **종류별 상한 안에서만** 받아들인다.
    ///
    /// 넘친 것은 버리고 `partial` 로 밝힌다 — 「없다」와 「못 봤다」를 가르는 계약이다. 잘라내기가
    /// 아니라 **골라 담기**인 이유는 한 줄에서 두 종류가 함께 나올 수 있기 때문이다: 한쪽이 넘쳤다고
    /// 뒤를 통째로 자르면 아직 자리가 남은 다른 종류까지 잃는다.
    fn admit(self: *StreamScanner, out: *std.ArrayList(Hit), before: usize) void {
        var w = before;
        for (out.items[before..]) |h| {
            const is_image = h.kind.isImage();
            const full = if (is_image)
                self.image_count >= max_hits_per_file
            else
                self.activity_count >= max_activity_hits_per_file;
            if (full) {
                self.partial = true;
                continue;
            }
            out.items[w] = h;
            w += 1;
            if (is_image) {
                self.image_count += 1;
            } else {
                self.activity_count += 1;
            }
        }
        out.shrinkRetainingCapacity(w);
    }

    /// 청크 하나를 먹인다. `chunk` 는 `self.consumed + self.carry.len` 위치부터의 바이트여야 한다.
    pub fn feed(
        self: *StreamScanner,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        out: *std.ArrayList(Hit),
    ) !void {
        if (chunk.len == 0) return;
        // **이전 이월 버퍼에는 개행이 없다** — 있었으면 그때 소비됐다. 그래서 새로 붙은 곳부터만 찾는다.
        //
        // 처음에는 매번 `used`(=0)부터 찾았는데, 그것이 **O(n²)** 였다: 6.9 MB 짜리 줄은 64 KiB 청크
        // 108 개로 쌓이고 그때마다 이월 전체를 다시 훑어 **한 줄에 373 MB** 를 스캔한다. 실측 파일에
        // 1 MB 넘는 줄이 17 개라 120 MB 파일 하나가 0.3 초가 아니라 십수 초였다.
        const old_len = self.carry.items.len;
        try self.carry.appendSlice(allocator, chunk);
        const base = self.consumed;
        const buf = self.carry.items;

        var used: usize = 0;
        var search: usize = old_len;
        while (std.mem.indexOfScalarPos(u8, buf, search, '\n')) |nl| {
            if (self.image_count < max_hits_per_file or self.activity_count < max_activity_hits_per_file) {
                const before = out.items.len;
                try scanLine(allocator, buf[used..nl], base + used, out);
                self.admit(out, before);
            } else {
                self.partial = true;
            }
            used = nl + 1;
            search = used;
        }

        // 소비한 만큼 앞을 버리고 꼬리만 남긴다.
        //
        // **아무것도 안 소비했으면 옮길 것도 없다.** 이 `if` 가 없으면 개행을 못 만난 청크마다 버퍼
        // **전체**를 자기 자신에게 memcpy 한다 — 긴 줄 하나가 64 KiB 청크 N 개로 쌓이는 동안
        // O(N²) 바이트를 옮긴다. 실측(1,980 MB 파일): 이 한 줄로 **52.9 초 → 아래 참조**.
        self.consumed += used;
        if (used > 0) {
            self.carry_moves += 1;
            const rest = buf.len - used;
            std.mem.copyForwards(u8, self.carry.items[0..rest], buf[used..]);
            self.carry.shrinkRetainingCapacity(rest);
        }

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

test "2중 저장은 접는다 — 같은 줄의 tool_file 사본은 세지 않는다 (§4.3)" {
    // 실측: 3,226 장 중 1,424 장(44%)이 이 사본이었다. 접지 않으면 에이전트가 읽은 이미지가 전부 두 번 뜬다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    // 실제 모양: `message.content[].content[].source.data` 와 `toolUseResult.file.base64` 가 한 줄에 있고
    // **바이트가 같다**(실측 identical 1,425 / different 0).
    const line =
        \\{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]},"toolUseResult":{"file":{"base64":"AAAA","type":"image"}}}
    ;
    try scanLine(allocator, line, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.claude_image, out.items[0].kind);
    try std.testing.expectEqual(Mime.png, out.items[0].mime);
}

test "2중 저장 접기: tool_file 만 있는 줄은 그대로 남는다 — 유일본을 버리지 않는다" {
    // 실측에서는 0건이지만 provider 가 바뀌면 생길 수 있다. 그때 무조건 버리면 그 이미지가 통째로
    // 사라지고 증상은 「어떤 이미지는 안 보인다」라 원인을 못 찾는다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line =
        \\{"type":"user","toolUseResult":{"file":{"base64":"BBBB","type":"image"}}}
    ;
    try scanLine(allocator, line, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.claude_tool_file, out.items[0].kind);
}

test "2중 저장 접기: 앞 줄에서 찾은 것은 건드리지 않는다" {
    // 접기는 **이번 줄에서 더한 것**만 본다. 버퍼 스캔은 한 `out` 에 여러 줄을 이어 담으므로,
    // 범위를 안 나누면 앞 줄들의 결과가 통째로 잘린다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const first =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"ZZZZ"}}]}
    ;
    const second =
        \\{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}],"toolUseResult":{"file":{"base64":"AAAA"}}}
    ;
    try scanLine(allocator, first, 0, &out);
    try scanLine(allocator, second, 200, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 앞 줄 1 + 이번 줄 1(사본 접힘)
    try std.testing.expectEqual(Mime.jpeg, out.items[0].mime);
    try std.testing.expectEqual(@as(u64, 0), out.items[0].line_offset);
    try std.testing.expectEqual(@as(u64, 200), out.items[1].line_offset);
}

test "Chain: 뒤에 잇고, 같은 경로는 두 번 담지 않는다" {
    // 부모가 자기 자신을 가리키는 기록이 오면 같은 파일을 두 번 훑어 이미지가 두 배로 뜬다.
    var c: Chain = .{};
    try testing.expect(c.isEmpty());
    try testing.expect(c.append("/a/one.jsonl"));
    try testing.expect(c.append("/a/two.jsonl"));
    try testing.expect(!c.append("/a/one.jsonl")); // 중복은 거부
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("/a/one.jsonl", c.get(0).?);
    try testing.expectEqualStrings("/a/two.jsonl", c.get(1).?);
    try testing.expect(c.get(2) == null);
    try testing.expectEqualStrings("/a/one.jsonl", c.head());
}

test "Chain: 상한에서 멈춘다 — 1.8 GB 부모가 줄줄이 붙지 않게" {
    var c: Chain = .{};
    try testing.expect(c.append("/a/1"));
    try testing.expect(c.append("/a/2"));
    try testing.expect(c.append("/a/3"));
    try testing.expect(!c.append("/a/4")); // max_chain = 3
    try testing.expectEqual(max_chain, c.len);
    c.clear();
    try testing.expect(c.isEmpty());
    try testing.expectEqualStrings("", c.head());
}

test "Chain: 상대 경로·빈 값은 담기지 않는다 — Source 규칙을 그대로 쓴다" {
    var c: Chain = .{};
    try testing.expect(!c.append(""));
    try testing.expect(!c.append("relative/path.jsonl"));
    try testing.expect(c.isEmpty());
}

test "Hit.file_index 기본값은 0 — 스캐너는 파일 하나만 훑는다" {
    // 스캐너가 이 값을 건드리면 여러 파일을 이어 담는 호출자와 싸운다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);
    const line =
        \\{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}
    ;
    try scanLine(allocator, line, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u8, 0), out.items[0].file_index);
}

test "긴 줄이 청크로 쪼개져 와도 이월 버퍼를 옮기지 않는다 — O(N²) 회귀 가드" {
    // **실측이 잡은 결함이다**(2026-08-30, 1,980 MB 실제 rollout): 개행을 못 만난 청크마다 이월
    // 버퍼 **전체**를 자기 자신에게 memcpy 했다. 긴 줄 하나가 64 KiB 청크 N 개로 쌓이는 동안
    // O(N²) 바이트를 옮긴다 — 그 한 줄을 고치니 **52.9 초 → 10.1 초** 였다.
    //
    // 시간으로 재면 기계마다 달라 불안정하다. **옮긴 횟수**로 못박는다: 개행이 오기 전에는 0 이다.
    const allocator = testing.allocator;
    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const chunk = "x" ** 4096;
    for (0..64) |_| try scanner.feed(allocator, chunk, &out);
    // 아직 한 줄도 안 끝났다 — 옮길 것이 없다.
    try testing.expectEqual(@as(u64, 0), scanner.carry_moves);
    try testing.expectEqual(@as(u64, 0), scanner.consumed);
    try testing.expectEqual(@as(usize, 64 * 4096), scanner.carry.items.len);

    // 개행이 오면 그때 한 번 옮긴다(꼬리만).
    try scanner.feed(allocator, "\n", &out);
    try testing.expectEqual(@as(u64, 1), scanner.carry_moves);
    try testing.expectEqual(@as(u64, 64 * 4096 + 1), scanner.consumed);
    try testing.expectEqual(@as(usize, 0), scanner.carry.items.len);
}

test "청크가 줄 여럿을 담아도 이미지를 찾고 오프셋이 파일 절대다" {
    // 위 가드가 「안 옮긴다」만 보므로, **옮기는 쪽이 여전히 맞는지**도 같이 본다 —
    // 최적화가 정확성을 깨는 자리가 정확히 여기다.
    const allocator = testing.allocator;
    var scanner: StreamScanner = .{};
    defer scanner.deinit(allocator);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(allocator);

    const filler = "{\"type\":\"user\",\"message\":{\"content\":[]}}\n";
    const img =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}}]}}\n";
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    try doc.appendSlice(allocator, filler);
    const img_at = doc.items.len;
    try doc.appendSlice(allocator, img);
    try doc.appendSlice(allocator, filler);

    // 한 바이트씩 먹여도(가장 잔인한 쪼개기) 결과가 같아야 한다.
    for (doc.items) |b| try scanner.feed(allocator, &.{b}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, img_at), out.items[0].line_offset);
    try testing.expectEqualStrings(
        "QUJD",
        doc.items[out.items[0].data_offset..][0..out.items[0].data_len],
    );
}

test "compacted 창: 경계 안팎을 정확히 가른다 — 성능 때문에 조용히 놓치지 않는다" {
    // **창 제한은 성능 최적화이고, 최적화가 결과를 바꾸면 안 된다**(적대적 검증 2026-08-30).
    // 실측 428 파일 / 14,206 줄에서 마커 위치는 중앙 40 · **최대 55** 였고, 창 512 B 가 놓친 것은 0 이다.
    // 여기서는 코퍼스에 **없는** 경계를 직접 만들어 가른다.
    const allocator = testing.allocator;
    const img = "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,QUJD\"}";

    // ① 마커가 창 **안**이면 그 줄은 통째로 건너뛴다.
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "{\"pad\":\"");
        try line.appendNTimes(allocator, 'x', compacted_search_window - 64);
        try line.appendSlice(allocator, "\",\"type\":\"compacted\",\"c\":[");
        try line.appendSlice(allocator, img);
        try line.appendSlice(allocator, "]}\n");
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        _ = try scanBuffer(allocator, line.items, 0, &out);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }

    // ② 마커가 창 **밖**이면 못 잡는다 — **알려진 한계**다(그래서 창을 실측 최대의 9.3 배로 둔다).
    //    이 단언은 「창이 실제로 제한으로 작동한다」를 못박는다.
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "{\"pad\":\"");
        try line.appendNTimes(allocator, 'x', compacted_search_window + 64);
        try line.appendSlice(allocator, "\",\"type\":\"compacted\",\"c\":[");
        try line.appendSlice(allocator, img);
        try line.appendSlice(allocator, "]}\n");
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        _ = try scanBuffer(allocator, line.items, 0, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
    }

    // ③ 창이 실측 최대(55)를 넉넉히 덮는다 — 이 부등식이 깨지면 실데이터를 놓치기 시작한다.
    try testing.expect(compacted_search_window >= 512);
}

test "compacted 판정이 청크 경계에 쪼개져도 같다" {
    // 스트리밍은 줄을 모아 판정하므로 청크 경계와 무관해야 한다. 최적화가 그 불변식을 깨는지 본다.
    const allocator = testing.allocator;
    const doc =
        "{\"timestamp\":\"x\",\"type\":\"compacted\",\"c\":[{\"type\":\"input_image\"," ++
        "\"image_url\":\"data:image/png;base64,QUJD\"}]}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"WFla\"}}]}}\n";

    for ([_]usize{ 1, 3, 17, 64, 4096 }) |step| {
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        var i: usize = 0;
        while (i < doc.len) : (i += step) {
            try scanner.feed(allocator, doc[i..@min(doc.len, i + step)], &out);
        }
        // compacted 줄의 이미지는 안 세고, 그 다음 줄의 것만 센다.
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings(
            "WFla",
            doc[out.items[0].data_offset..][0..out.items[0].data_len],
        );
    }
}

test "쓰는 도중에 읽어도 반쪽 이미지를 만들지 않는다 — 자동 갱신이 새로 만든 상황" {
    // 자동 갱신(IG2)이 붙은 뒤로 스캔은 **에이전트가 쓰는 도중에** 돈다. 한 바이트씩 자라는 파일을
    // 매 단계 처음부터 다시 훑으며, 나온 히트가 언제나 **완성된 줄** 안에 있는지 본다.
    const allocator = testing.allocator;
    const doc =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJDREVG\"}}]}}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"WFlaWFla\"}}]}}\n";

    var grown: usize = 1;
    while (grown <= doc.len) : (grown += 1) {
        const seen = doc[0..grown];
        // **제품 경로로 읽는다.** 처음에는 `scanBuffer`(전량 스캔 헬퍼)를 썼는데, 제품은
        // `StreamScanner.feed` 로 읽는다 — 뮤테이션이 그것을 짚어 줬다: `feed` 를 망가뜨렸는데
        // 이 test 가 통과했다. **테스트가 제품이 안 쓰는 길을 지키고 있었다.**
        var out: std.ArrayList(Hit) = .empty;
        defer out.deinit(allocator);
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var fed: usize = 0;
        while (fed < seen.len) : (fed += 13) {
            try scanner.feed(allocator, seen[fed..@min(seen.len, fed + 13)], &out);
        }

        // 지금까지 **완성된** 줄(마지막 개행까지)의 길이.
        const complete = if (std.mem.lastIndexOfScalar(u8, seen, '\n')) |nl| nl + 1 else 0;
        for (out.items) |hit| {
            // ① 히트는 완성된 줄 안에서만 나온다 — 반쪽 줄을 인덱싱하지 않는다.
            try testing.expect(hit.data_offset + hit.data_len <= complete);
            // ② payload 가 온전하다: 뒤에 닫는 따옴표가 있다.
            try testing.expect(hit.data_offset + hit.data_len < seen.len);
            try testing.expectEqual(@as(u8, '"'), seen[hit.data_offset + hit.data_len]);
        }
        // ③ 완성된 줄 수만큼만 나온다.
        const want: usize = if (complete >= doc.len) 2 else if (complete > 0) 1 else 0;
        try testing.expectEqual(want, out.items.len);
    }
}

test "쓰는 도중에 읽어도 스트리밍이 같은 답을 낸다 — 청크 경계와 무관" {
    // 위 test 는 「매번 처음부터」다. 제품은 청크로 먹이므로 그쪽도 같은 답을 내야 한다.
    // 자동 갱신은 파일이 자랄 때마다 **새 스캐너**로 처음부터 훑으므로 둘이 어긋나면 안 된다.
    const allocator = testing.allocator;
    const doc =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"," ++
        "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJDREVG\"}}]}}\n";

    var grown: usize = 1;
    while (grown <= doc.len) : (grown += 1) {
        const seen = doc[0..grown];

        var whole: std.ArrayList(Hit) = .empty;
        defer whole.deinit(allocator);
        _ = try scanBuffer(allocator, seen, 0, &whole);

        var streamed: std.ArrayList(Hit) = .empty;
        defer streamed.deinit(allocator);
        var scanner: StreamScanner = .{};
        defer scanner.deinit(allocator);
        var i: usize = 0;
        while (i < seen.len) : (i += 7) {
            try scanner.feed(allocator, seen[i..@min(seen.len, i + 7)], &streamed);
        }

        try testing.expectEqual(whole.items.len, streamed.items.len);
        for (whole.items, streamed.items) |a, b| {
            try testing.expectEqual(a.data_offset, b.data_offset);
            try testing.expectEqual(a.data_len, b.data_len);
        }
    }
}

test "순번: 같은 줄에 붙은 세 장은 적힌 순서로 1/3·2/3·3/3" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 400, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    for (0..3) |i| {
        const s = sequenceAt(&hits, i);
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), s.index);
        try std.testing.expectEqual(@as(u16, 3), s.total);
    }
}

test "순번: 목록을 뒤집어도 적힌 순서를 말한다" {
    // 갤러리는 최신을 먼저 보이려고 전체를 뒤집는다. 그때 순번까지 뒤집히면 「3/3」이 첫 장에 붙는다.
    var hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    std.mem.reverse(Hit, &hits);
    try std.testing.expectEqual(@as(u16, 2), sequenceAt(&hits, 0).index); // 뒤집혀 앞에 온 것이 둘째 장
    try std.testing.expectEqual(@as(u16, 1), sequenceAt(&hits, 1).index);
}

test "순번: 한 장뿐이면 0 — 「1/1」은 알려 주는 것이 없다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 900, .data_offset = 950, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
}

test "순번: 다른 줄과 섞이지 않는다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 100, .data_offset = 300, .data_len = 4, .kind = .claude_image, .mime = .png },
        .{ .line_offset = 800, .data_offset = 900, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(@as(u16, 2), sequenceAt(&hits, 1).total);
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 2));
}

test "순번: 파일이 다르면 오프셋이 같아도 남남이다" {
    // 재개 세션은 부모 파일까지 이어 담는다(§3.3). 그때 오프셋만 보면 다른 파일의 이미지가 한 묶음이 된다.
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png, .file_index = 0 },
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png, .file_index = 1 },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
}

test "순번: 묶음이 상한을 넘으면 세지 않는다" {
    var hits: [max_seq_group + 1]Hit = undefined;
    for (&hits, 0..) |*h, i| h.* = .{
        .line_offset = 100,
        .data_offset = 200 + @as(u64, i) * 10,
        .data_len = 4,
        .kind = .claude_image,
        .mime = .png,
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 0));
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, hits.len - 1));
}

test "순번: 범위 밖 인덱스는 빈 값 — 부르는 쪽이 길이를 어긋내도 죽지 않는다" {
    const hits = [_]Hit{
        .{ .line_offset = 100, .data_offset = 200, .data_len = 4, .kind = .claude_image, .mime = .png },
    };
    try std.testing.expectEqual(Seq{}, sequenceAt(&hits, 1));
    try std.testing.expectEqual(Seq{}, sequenceAt(&.{}, 0));
}

test "실제 모양의 다중 첨부: 두 장이 같은 라벨을 받고 순번으로만 갈린다" {
    // **이 테스트가 이 기능의 이유다.** 실측(2026-09-05, Claude 트랜스크립트 131 파일)에서 사용자
    // 다중 첨부 13 줄이 **전부** 텍스트 블록 하나뿐이고 그 텍스트가 첫 이미지보다 앞이었다. 그래서
    // 두 장은 글자 그대로 같은 설명을 받고, 시각까지 같다(한 레코드다) — 순번 말고는 가를 것이 없다.
    const context = @import("agent_image_context.zig");
    const allocator = std.testing.allocator;

    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"이 두 화면 비교해 주세요\"}," ++
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}}," ++
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"BBBB\"}}" ++
        "]}}\n";

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    _ = try scanBuffer(allocator, line, 0, &hits);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);

    for (hits.items, 0..) |h, i| {
        // 라벨은 payload **앞** 조각만 본다 — 스캔 백엔드가 파일에서 떼어 주는 것과 같은 구간이다.
        const prefix = line[@intCast(h.line_offset)..@intCast(h.data_offset)];
        const label = context.label(prefix, "");
        try std.testing.expectEqualStrings("이 두 화면 비교해 주세요", label.text());
        try std.testing.expectEqual(context.Source.message_text, label.source);

        const seq = sequenceAt(hits.items, i);
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), seq.index);
        try std.testing.expectEqual(@as(u16, 2), seq.total);
    }

    // 접두까지 태워 「무엇이 화면에 뜨는가」를 못 박는다 — 두 줄이 순번으로만 갈린다.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("첨부 1/2", context.originPrefix(&buf, "첨부", sequenceAt(hits.items, 0).index, 2));
    try std.testing.expectEqualStrings("첨부 2/2", context.originPrefix(&buf, "첨부", sequenceAt(hits.items, 1).index, 2));
}

test "실제 모양의 도구 읽기: 2중 저장을 접고도 출처가 「에이전트가 읽음」이다" {
    // 에이전트가 읽은 이미지는 한 줄에 마커가 둘이지만(§4.3 의 2 중 저장) 실제로는 **한 장**이다.
    // 여기서 순번이 붙으면 「1/2」라는 거짓말이 화면에 뜬다 — 접기와 순번이 같은 줄에서 만나는 자리다.
    const context = @import("agent_image_context.zig");
    const allocator = std.testing.allocator;

    const prev = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_01\"," ++
        "\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/dock-layout.png\"}}]}}";
    const line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_01\"," ++
        "\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}}]}}," ++
        "\"toolUseResult\":{\"file\":{\"base64\":\"AAAA\",\"type\":\"image\"}}}\n";

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    _ = try scanBuffer(allocator, line, 0, &hits);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len); // 사본은 접혔다
    try std.testing.expectEqual(Seq{}, sequenceAt(hits.items, 0)); // 한 장이니 순번 없음

    const prefix = line[@intCast(hits.items[0].line_offset)..@intCast(hits.items[0].data_offset)];
    const label = context.label(prefix, prev);
    try std.testing.expectEqualStrings("dock-layout.png", label.text());
    try std.testing.expectEqual(context.Source.tool_file_path, label.source);
}

// ── 활동(도구 호출) 스캔 — 계약 `docs/agent-activity-view.md` §3.1 ─────────────────────────────
//
// **구조는 실측, 값은 합성**이다(계약 §5: 트랜스크립트 내용을 fixture 에 쓰지 않는다). 아래 레코드
// 모양은 이 맥의 실제 파일에서 읽은 것이고, 그 안의 경로·명령·설명만 지어낸 것이다.

fn activityAt(hits: *const std.ArrayList(Hit), i: usize, line: []const u8) []const u8 {
    const h = hits.items[i];
    const start: usize = @intCast(h.data_offset);
    return line[start .. start + h.data_len];
}

fn toolNameAt(hits: *const std.ArrayList(Hit), i: usize, line: []const u8) []const u8 {
    const h = hits.items[i];
    return line[h.name_rel .. h.name_rel + h.name_len];
}

test "활동: Claude 도구 호출은 description 을 대상으로 잡는다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AB","name":"Bash","input":{"command":"grep -rn foo src/","description":"foo 쓰는 자리 찾기"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_use, hits.items[0].kind);
    try testing.expectEqual(Activity.exec, hits.items[0].activity);
    try testing.expect(!hits.items[0].kind.isImage());
    // **명령이 아니라 설명이다** — 실측이 정한 순서다(§2.2).
    try testing.expectEqualStrings("foo 쓰는 자리 찾기", activityAt(&hits, 0, line));
    try testing.expectEqualStrings("Bash", toolNameAt(&hits, 0, line));
}

test "활동: Read 는 description 이 없어 file_path 가 대상이다" {
    // 실측: `Read` 의 description 은 0 / 635 다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01CD","name":"Read","input":{"file_path":"/tmp/shots/dock.png"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.read, hits.items[0].activity);
    try testing.expectEqualStrings("/tmp/shots/dock.png", activityAt(&hits, 0, line));
}

test "활동: 설명도 경로도 없으면 명령이 대상이다" {
    // 실측: Bash 의 31.2% 에는 description 이 없다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01EF","name":"Bash","input":{"command":"zig build test"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings("zig build test", activityAt(&hits, 0, line));
}

test "활동: 셋 다 없으면 도구 이름이 대상이다 — 빈 줄을 남기지 않는다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01GH","name":"ListAgents","input":{}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.other, hits.items[0].activity);
    try testing.expectEqualStrings("ListAgents", activityAt(&hits, 0, line));
}

test "활동: 명령 안의 이스케이프된 따옴표에서 잘리지 않는다" {
    // base64 와 갈리는 지점이다 — 이미지 payload 에는 이스케이프가 없어 다음 `"` 가 곧 끝이지만
    // 사람이 쓴 명령에는 `\"` 가 흔하다. `indexOfScalar` 로 끊으면 `grep -n ` 에서 잘린다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01IJ","name":"Bash","input":{"command":"grep -n \"pub fn main\" src/main.zig && echo done"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings(
        \\grep -n \"pub fn main\" src/main.zig && echo done
    , activityAt(&hits, 0, line));
}

test "활동: 여러 줄 명령도 통째로 잡는다" {
    // 실측: 명령의 52.4% 가 여러 줄이다. `\n` 은 JSON 이스케이프라 값 안에 있다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01KL","name":"Bash","input":{"command":"cd /tmp\npython3 - <<'PY'\nprint(1)\nPY"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expect(std.mem.indexOf(u8, activityAt(&hits, 0, line), "PY") != null);
}

test "활동: description 이 긴 명령 뒤에 있어도 찾는다 — 창을 두지 않는 이유" {
    // 실측: 대상 문자열 최대 23,866 B. 512 바이트 창(`key_search_window`)이면 못 본다.
    // 한 줄에 호출이 하나뿐이라(실측 39,618/39,618) 줄 전체를 봐도 남의 값을 집지 않는다.
    const head =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01MN","name":"Bash","input":{"command":"
    ;
    const tail =
        \\","description":"긴 명령 뒤의 설명"}}]}}
    ;
    var long: [4096]u8 = undefined;
    @memset(&long, 'x');
    const line = try std.mem.concat(testing.allocator, u8, &.{ head, &long, tail });
    defer testing.allocator.free(line);
    const text = try std.mem.concat(testing.allocator, u8, &.{ line, "\n" });
    defer testing.allocator.free(text);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(testing.allocator);
    _ = try scanBuffer(testing.allocator, text, 0, &hits);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings("긴 명령 뒤의 설명", activityAt(&hits, 0, line));
}

test "활동: 축은 도구 이름으로만 가른다 — MCP 와 편집은 other 다" {
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01OP","name":"mcp__drive__search","input":{"query":"설계"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Activity.other, hits.items[0].activity);
    try testing.expectEqualStrings("mcp__drive__search", toolNameAt(&hits, 0, line));
    // 대상 키가 없으므로 이름이 대상이다 — MCP 인자 이름을 지어내지 않는다.
    try testing.expectEqualStrings("mcp__drive__search", activityAt(&hits, 0, line));
}

test "활동: grep 은 읽기가 아니라 실행이다 — 명령의 의미를 판정하지 않는다" {
    // 계약 §2.3. 이 판정자는 「그렇게 되면 좋겠다」가 아니라 **그렇게 하기로 한 결정**을 지킨다.
    const line =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01QR","name":"Bash","input":{"command":"sed -n '1,20p' README.md"}}]}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(Activity.exec, hits.items[0].activity);
}

test "활동: Codex custom_tool_call 은 input 이 대상이고 결과 레코드에는 안 걸린다" {
    const call =
        \\{"timestamp":"2026-09-07T00:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_AB","name":"exec","input":"sed -n '1,20p' src/main.zig","status":"completed"}}
    ;
    const output =
        \\{"timestamp":"2026-09-07T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_AB","output":"[{\"type\":\"input_text\",\"text\":\"done\"}]"}}
    ;
    var hits = try collect(call ++ "\n" ++ output ++ "\n");
    defer hits.deinit(testing.allocator);

    // **결과 줄은 활동이 아니다** — 마커가 닫는 따옴표까지라 `custom_tool_call_output` 에 안 걸린다.
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(Kind.codex_tool_call, hits.items[0].kind);
    try testing.expectEqual(Activity.exec, hits.items[0].activity);
    try testing.expectEqualStrings("sed -n '1,20p' src/main.zig", activityAt(&hits, 0, call));
}

test "활동: 상한은 종류별이다 — 활동이 넘쳐도 이미지가 밀려나지 않는다" {
    // **한 통으로 세면 갤러리가 조용히 빈다.** 활동은 세션당 최대 12,200개인데 이미지 상한은 4,096
    // 이라, 상한을 공유하면 활동이 많은 세션에서 이미지가 인덱스에 못 들어간다. 사용자에게는
    // 「이미지가 없습니다」로 보이고 그것은 고장과 구분되지 않는다.
    const call =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hi"}}]}}
    ;
    const image =
        \\{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}
    ;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 이미지 상한을 **넘기고도 남게** 활동을 쌓는다.
    var i: usize = 0;
    while (i < max_hits_per_file + 64) : (i += 1) {
        try text.appendSlice(testing.allocator, call);
        try text.append(testing.allocator, '\n');
    }
    // 그 **뒤에** 이미지를 둔다 — 상한을 공유하면 이 줄이 잘린다.
    try text.appendSlice(testing.allocator, image);
    try text.append(testing.allocator, '\n');

    var scanner: StreamScanner = .{};
    defer scanner.deinit(testing.allocator);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(testing.allocator);
    try scanner.feed(testing.allocator, text.items, &hits);

    var images: usize = 0;
    var activities: usize = 0;
    for (hits.items) |h| {
        if (h.kind.isImage()) images += 1 else activities += 1;
    }
    // **뒤에 온 이미지가 살아 있다.**
    try testing.expectEqual(@as(usize, 1), images);
    try testing.expectEqual(max_hits_per_file + 64, activities);
    try testing.expect(!scanner.partial); // 둘 다 자기 상한 안이라 자른 것이 없다
}

test "활동: Codex 호출 마커는 결과 레코드에 걸리지 않는다 — 방어를 직접 시험한다" {
    // **위 판정자만으로는 부족했다.** 뮤테이션으로 마커에서 닫는 따옴표를 빼도 그 판정자가 통과했다 —
    // 실제로 막고 있던 것은 마커가 아니라 「결과 레코드에 `name` 이 없다」는 성질이었기 때문이다
    // (실측 3,966 / 3,966 이 `call_id,id,…,output,type`). 즉 그 판정자는 **마커를 검증하지 않는다.**
    //
    // 방어가 둘이면 각각 시험해야 한다. 여기서는 마커 자신을 본다 — provider 가 나중에 결과
    // 레코드에 `name` 을 넣으면 그때부터는 이것이 유일한 방어다.
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"custom_tool_call_output\"",
        codex_custom_tool_call_marker,
    ) == null);
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"function_call_output\"",
        codex_function_call_marker,
    ) == null);
    // 반대쪽도 못박는다 — 마커가 진짜 호출 레코드에는 걸려야 한다.
    try testing.expect(std.mem.indexOf(
        u8,
        "\"type\":\"custom_tool_call\",\"call_id\":\"call_AB\"",
        codex_custom_tool_call_marker,
    ) != null);
}

test "활동: Codex compacted 줄은 활동도 건너뛴다" {
    // 이미지와 같은 이유다 — compacted 는 이전 대화를 통째로 재수록하므로 세면 몇 배가 된다.
    const line =
        \\{"type":"compacted","payload":{"type":"custom_tool_call","call_id":"call_CD","name":"exec","input":"echo hi"}}
    ;
    var hits = try collect(line ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "활동: 이미지 줄과 활동 줄은 서로를 오염시키지 않는다" {
    const call =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01ST","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}
    ;
    const result =
        \\{"type":"user","message":{"content":[{"tool_use_id":"toolu_01ST","type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}]}}
    ;
    var hits = try collect(call ++ "\n" ++ result ++ "\n");
    defer hits.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), hits.items.len);
    try testing.expectEqual(Kind.claude_tool_use, hits.items[0].kind);
    try testing.expectEqual(Activity.read, hits.items[0].activity);
    try testing.expectEqual(Kind.claude_image, hits.items[1].kind);
    // 이미지 쪽은 활동 축을 갖지 않는다 — 두 축이 섞이면 필터가 거짓말을 한다.
    try testing.expectEqual(Activity.none, hits.items[1].activity);
    try testing.expect(hits.items[1].kind.isImage());
}
