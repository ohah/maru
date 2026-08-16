//! `maru.screen-stream` — session-host의 화면 snapshot/delta record codec(§12).
//!
//! `snapshot_chunk`/`delta_chunk`(MRSH kind 6/7)의 payload는 native struct memory dump가 **아니라** 이 파일의
//! versioned record codec이다. renderer의 `RenderSnapshot`이나 debug용 `maru.snapshot.v3`을 그대로 IPC ABI로 쓰지
//! 않는 이유는 그것들이 in-process view/부분 직렬화라 Zig/Swift padding·pointer·palette 참조에 묶여 있기 때문이다.
//! 이 codec은 **resolved** 화면 상태만 중립 wire로 나른다(padding/pointer 없음, 색은 이미 resolve된 RGB).
//!
//! 단일 출처는 [영속 터미널 세션 호스트](../../../../docs/persistent-session-host.md) §12다. §12는 record **필드
//! 목록**을 정하고 "모든 정수 network byte order, 문자열 `length:u32 + UTF-8`, blob은 문자열 field에 넣지 않는다"를
//! 못박는다. 각 필드의 정확한 바이트 크기·순서는 이 구현이 확정하며(§12에 반영), 아래 record 주석이 그 레이아웃의
//! 미러다. 순수 OS-중립 codec(platform import 0)이라 non-macOS에서 wire 회귀를 고정한다.
//!
//! record 하나 = **28-byte record header + record body**:
//!   codec_version:u16=2(current; capability-tagged frozen N-1은 1) | record_kind:u16 |
//!   generation:u64 | sequence:u64 | chunk_index:u32 | chunk_count:u32
//!   = 2 + 2 + 8 + 8 + 4 + 4 = 28.
//! initial attach snapshot record는 `sequence=0`과 한 generation을 갖는다. 같은 stream의 resync/fallback snapshot과
//! delta는 직전 committed frontier exact +1이며, delta body는 `base_generation`을 더한다(§12). chunk_index는 0부터
//! 연속이고 마지막 chunk의 count가 맞아야 상위가 publish한다.

const std = @import("std");

/// codec 버전. decode가 다른 값을 보면 `BadCodecVersion`(상위가 fresh snapshot 재요청). **v2**(리뷰 #3): Run 색(resolved RGB→
/// 태그드 Color intent)·ImageBlob/ImagePlacement 레이아웃이 비호환 변경돼, 구 codec 레코드를 신 client가 조용히 오해석하지
/// 않게 올렸다. protocol.version_major와 화면 codec은 둘 다 v2이며, full spawn은 새 command 이름으로 capability를 가른다.
pub const codec_version: u16 = 2;
/// Frozen MRSH v1 boundary (`66a78614^`) already used the current record body layout; the major bump changed the
/// explicit record version from 1→2. Therefore v1 can be normalized by accepting only this exact header-version
/// difference. Older, pre-layout v1 artifacts are not in the supported N-1 release set.
pub const reader_min: u16 = 1;
pub const reader_max: u16 = codec_version;

/// record header 크기(바이트). body는 이 뒤에 이어진다.
pub const record_header_size = 28;

/// snapshot/delta record 종류. `enum(u16)` + `_`로 open enum — 모르는 값도 decode되어 상위가 optional/required로
/// 처리를 가른다(§12: unknown optional은 length로 skip, unknown required는 snapshot 전체 reject). 값은 wire 약속이라 고정.
/// snapshot record는 1~9, delta record는 10~19로 대역을 나눠 사람이 로그에서 구분하기 쉽게 한다.
pub const RecordKind = enum(u16) {
    // snapshot records (full screen 조립)
    screen_meta = 1,
    row = 2,
    image_placement = 3,
    image_blob = 4,
    prompt_marks = 5, // OSC 133 행별 semantic prompt(분류+종료코드). full-replace라 snapshot·delta 공용.
    link_spans = 6, // 뷰포트 링크(자동 감지 + OSC 8). full-replace라 snapshot·delta 공용.
    // delta records (증분 변경)
    set_runs = 10,
    clear_rect = 11,
    scroll_rect = 12,
    cursor = 13,
    modes = 14,
    image_place = 15,
    image_remove = 16,
    scroll_state = 17, // 스크롤백 길이·view offset 변화(스크롤바 thumb). screen_meta는 snapshot에만 실리므로 delta 전용.
    _,

    pub fn isKnown(self: RecordKind) bool {
        return switch (self) {
            .screen_meta, .row, .image_placement, .image_blob, .prompt_marks, .link_spans, .set_runs, .clear_rect, .scroll_rect, .cursor, .modes, .image_place, .image_remove, .scroll_state => true,
            _ => false,
        };
    }
};

/// resolved cell 스타일 비트(§12 "resolved ... style flags"). palette 참조가 아니라 이미 해석된 표현이다.
/// underline은 스타일 존재(single/double/curly)와 색(`underline_color`)을 분리한다.
pub const StyleFlags = struct {
    pub const bold: u32 = 1 << 0;
    pub const dim: u32 = 1 << 1;
    pub const italic: u32 = 1 << 2;
    pub const underline: u32 = 1 << 3;
    pub const underline_double: u32 = 1 << 4;
    pub const underline_curly: u32 = 1 << 5;
    pub const blink: u32 = 1 << 6;
    pub const inverse: u32 = 1 << 7;
    pub const invisible: u32 = 1 << 8;
    pub const strikethrough: u32 = 1 << 9;
    pub const overline: u32 = 1 << 10;
    pub const known_mask: u32 = (1 << 11) - 1;
};

/// `ScreenMeta.modes`/`ModesDelta.modes` 비트 배치. host projector와 client renderer가 함께 쓰는
/// wire SSOT이며 새 비트는 구 client가 무시할 수 있게 additive로만 확장한다.
pub const ModeBit = struct {
    pub const app_cursor_keys: u32 = 1 << 0;
    pub const app_keypad: u32 = 1 << 1;
    pub const bracketed_paste: u32 = 1 << 2;
    pub const alternate_scroll: u32 = 1 << 3;
    pub const focus_events: u32 = 1 << 4;
    pub const origin_mode: u32 = 1 << 5;
    pub const mouse_tracking: u32 = 1 << 6;
    pub const sync_output: u32 = 1 << 7;
    pub const grapheme_cluster: u32 = 1 << 8;
    pub const viewport_scrolled: u32 = 1 << 9;
    pub const ambiguous_wide: u32 = 1 << 10;
};

/// 커서 상태. `shape`는 0=block,1=underline,2=bar(§ terminal DECSCUSR 관례) — 상위가 매핑한다.
pub const Cursor = struct {
    col: u16 = 0,
    row: u16 = 0,
    visible: bool = true,
    shape: u8 = 0,
};

/// 화면 좌표 사각형(cell 단위). delta clear/scroll/image 배치에 쓴다.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

/// 같은 스타일·같은 grapheme의 연속 묶음. `width`는 grapheme 셀 폭(1/2), `count`는 그 grapheme의 **반복 수**다.
/// 이 run이 채우는 grid cell 수 = `width * count`(wide "한" 하나면 width=2·count=1·cell=2, "aaa"면 width=1·count=3·cell=3).
/// 조립기는 Σ(width*count)==cols로 wide-cell continuation 불일치를 검증한다(rowWidthMatches). `grapheme`은 UTF-8이고
/// codec 버퍼를 참조한다(decode 후 caller가 버퍼를 유지하는 zero-copy). 색(fg/bg/underline_color)은 resolved RGB가
/// 아니라 **태그드 Color intent**다(§ColorTag) — client가 자기 theme로 해석한다(config 16색·bold-is-bright·min-contrast).
pub const Run = struct {
    grapheme: []const u8,
    width: u8 = 1,
    count: u32 = 1,
    fg: u32 = 0,
    bg: u32 = 0,
    underline_color: u32 = 0,
    style_flags: u32 = 0,
};

/// Run.fg/bg/underline_color 색 인코딩: resolved RGB가 아니라 **Color intent**를 태그드 u32로 싣는다. host가 색을 굽지
/// 않고 의도(default/indexed/rgb)를 실어, client가 자기 theme로 해석하게 한다(config 16색 base·bold-is-bright·min-contrast·
/// default 색 — in-process 렌더와 동일). 상위 바이트(비트 24~25)가 태그, 하위 24비트가 payload다.
/// host(`screen_snapshot.packColorIntent`)가 싣고 client(`remote_screen.unpackColorIntent`)가 푼다. OSC4 override된 indexed는
/// override가 host per-terminal 상태(client가 못 가짐)라 host가 rgb로 구워 실어 회귀를 막는다. 이 모듈은 순수 codec이라
/// terminal.Color를 모른다 — 태그 값만 SSOT로 정의하고 매핑은 host/client 경계가 각자 한다.
pub const ColorTag = struct {
    pub const shift: u5 = 24;
    pub const default: u32 = 0; // payload 없음(v == 0)
    pub const indexed: u32 = 1; // payload = index(하위 8비트)
    pub const rgb: u32 = 2; // payload = 0xRRGGBB(하위 24비트)
    pub const index_mask: u32 = 0xFF;
    pub const rgb_mask: u32 = 0xFFFFFF;
};

/// 화면 메타(snapshot의 첫 record). cols/rows·active/alternate screen·커서·mode bitmask.
/// wire: cols:u16 | rows:u16 | active_screen:u8 | cursor(col:u16,row:u16,visible:u8,shape:u8) | modes:u32.
pub const ScreenMeta = struct {
    cols: u16,
    rows: u16,
    active_screen: u8 = 0, // 0=primary, 1=alternate
    cursor: Cursor = .{},
    modes: u32 = 0,
    /// 스크롤바 thumb 근거. client는 화면만 받고 스크롤백 **길이**를 알 방법이 없어(placeholder core는 0) 원격
    /// 세션에 스크롤바가 뜨지 않았다. `modes`의 viewport_scrolled 비트는 "스크롤됐는가"만 알려줘 크기 계산에 부족하다.
    /// 끝에 추가한 optional 필드라 구 decoder는 length로 무시하고(기존 동작), 구 host가 안 보내면 0으로 남는다.
    scrollback_len: u32 = 0,
    view_offset: u32 = 0,
};

/// 한 행의 run 목록. wire: row_index:u16 | run_count:u32 | run*. `runs`는 decode가 allocator로 소유(caller가 `deinit`).
pub const Row = struct {
    row_index: u16,
    runs: []Run,

    pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
    }
};

/// 화면 위 kitty graphics placement(표시 중인 이미지 인스턴스). client가 `terminal.KittyPlacement`로 1:1 매핑한다.
/// 좌표는 뷰포트 상대(row는 i32라 화면 위로 벗어난 앵커도 노출 — 셀 span을 아는 렌더러가 가시성/클립 결정). crop/offset/
/// columns/rows까지 실어 kitty display 의미를 보존한다(픽셀→셀 환산은 셀 메트릭을 가진 렌더러 몫). wire: image_id:u32 |
/// placement_id:u32 | row:i32 | col:u16 | cell_x_offset:u32 | cell_y_offset:u32 | src_x:u32 | src_y:u32 | src_width:u32 |
/// src_height:u32 | columns:u32 | rows:u32 | z:i32.
pub const ImagePlacement = struct {
    image_id: u32,
    placement_id: u32 = 0,
    row: i32,
    col: u16,
    cell_x_offset: u32 = 0,
    cell_y_offset: u32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_width: u32 = 0,
    src_height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    z: i32 = 0,
};

/// kitty graphics 이미지의 **디코드된 픽셀**(host가 굽지 않고 raw RGB/RGBA 그대로 — client 디코더 불필요). client가
/// `terminal.KittyImageView`로 1:1 매핑해 렌더러가 image_id로 GPU 텍스처를 캐시하고 `generation`이 바뀔 때만 업로드한다.
/// per-record cap(1 MiB)을 넘는 이미지는 record header의 chunk_index/chunk_count로 청크해 나른다 — `pixels`는 이 청크의
/// 슬라이스이고, 메타(width/height/bpp/generation)는 자기서술을 위해 **매 청크 반복**한다(재조립은 소비자 몫, §12). blob은
/// 문자열 field가 아니라 전용 record로 나른다. wire: image_id:u32 | generation:u64 | width:u32 | height:u32 | bpp:u8 |
/// pixel_len:u32 | pixels.
pub const ImageBlob = struct {
    image_id: u32,
    generation: u64 = 0,
    width: u32,
    height: u32,
    bpp: u8,
    pixels: []const u8,
};

/// 한 행의 OSC 133 semantic prompt(분류 + 그 프롬프트의 명령 종료코드). `terminal.RowPrompt`의 wire 대응이다 — 순수 codec은
/// terminal을 모르므로 `kind`를 u8(SemanticPrompt @intFromEnum)로, `exit`를 `?i16`로 든다. client(remote_screen)가 core 타입으로 환산.
pub const RowPromptWire = struct {
    kind: u8 = 0, // 0=unknown
    exit: ?i16 = null,
};

/// 화면 전체의 행별 prompt 마크(dense — 행당 하나, positional). full-replace라 record 하나가 현재 전체를 싣는다(마크가 전혀
/// 없으면 producer가 방출을 생략해 common case 무비용). wire: row_count:u16 | (kind:u8 | has_exit:u8 | exit:u16(bitcast i16))*.
pub const PromptMarks = struct {
    rows: []RowPromptWire,

    pub fn deinit(self: PromptMarks, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
    }
};

/// 뷰포트 링크 하나 — 밑줄 범위(뷰포트 상대 행/열, 양끝 포함) + 종류 + 그 매치를 만든 감지 종류.
/// `kind`는 `selection.LinkKind`(0=url, 1=file_path), `scope`는 `selection.LinkScope`의 **비트 위치**다
/// (0 web … 5 bare_relative, 6 osc8). host는 client config를 모르므로 최대 집합으로 계산해 전부 싣고,
/// client가 자기 `input.link-detection`으로 거른다(docs/link-detection.md §원격(host-backed) 세션).
/// 이 모듈은 순수 codec이라 terminal 타입을 모른다 — 숫자 약속만 SSOT로 두고 매핑은 host/client 경계가 한다
/// (`ColorTag`와 같은 규율).
pub const link_kind_max: u8 = 1;
pub const link_scope_max: u8 = 6;

pub const LinkSpanWire = struct {
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    kind: u8 = 0,
    scope: u8 = 0,
};

/// 화면 전체의 링크 목록. full-replace라 record 하나가 현재 전체를 싣는다(링크가 하나도 없으면 producer가
/// 방출을 생략해 common case 무비용 — `PromptMarks`와 같은 패턴).
/// wire: span_count:u16 | (start_row:u16 | start_col:u16 | end_row:u16 | end_col:u16 | kind:u8 | scope:u8)*.
pub const LinkSpans = struct {
    spans: []LinkSpanWire,

    pub fn deinit(self: LinkSpans, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
    }
};

/// 28-byte record header. body는 record_kind에 따라 이 뒤에 이어진다.
pub const RecordHeader = struct {
    kind: RecordKind,
    generation: u64 = 0,
    sequence: u64 = 0,
    chunk_index: u32 = 0,
    chunk_count: u32 = 1,
    version: u16 = codec_version,

    pub fn encode(self: RecordHeader) [record_header_size]u8 {
        var buf: [record_header_size]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.version, .big);
        std.mem.writeInt(u16, buf[2..4], @intFromEnum(self.kind), .big);
        std.mem.writeInt(u64, buf[4..12], self.generation, .big);
        std.mem.writeInt(u64, buf[12..20], self.sequence, .big);
        std.mem.writeInt(u32, buf[20..24], self.chunk_index, .big);
        std.mem.writeInt(u32, buf[24..28], self.chunk_count, .big);
        return buf;
    }

    pub fn decode(bytes: *const [record_header_size]u8) DecodeError!RecordHeader {
        const version = std.mem.readInt(u16, bytes[0..2], .big);
        if (version < reader_min or version > reader_max) return error.BadCodecVersion;
        return .{
            .version = version,
            .kind = @enumFromInt(std.mem.readInt(u16, bytes[2..4], .big)),
            .generation = std.mem.readInt(u64, bytes[4..12], .big),
            .sequence = std.mem.readInt(u64, bytes[12..20], .big),
            .chunk_index = std.mem.readInt(u32, bytes[20..24], .big),
            .chunk_count = std.mem.readInt(u32, bytes[24..28], .big),
        };
    }

    pub fn decodeExact(bytes: *const [record_header_size]u8, expected_version: u16) DecodeError!RecordHeader {
        const decoded = try decode(bytes);
        if (decoded.version != expected_version) return error.BadCodecVersion;
        return decoded;
    }
};

pub const DecodeError = error{
    /// 지원 reader 범위 밖 codec이다 — 상위가 fresh snapshot을 재요청한다.
    BadCodecVersion,
    /// body가 선언된 필드보다 짧다(truncated). 손상/부분 chunk.
    Truncated,
    /// str/blob length가 남은 바이트나 cap을 넘는다.
    LengthOverflow,
    /// grapheme/mime 문자열이 valid UTF-8이 아니다(§12: UTF-8 손상은 reject).
    InvalidUtf8,
    /// run count·row 등 선언 수가 cap을 넘는다(메모리 폭주 방지).
    TooManyItems,
    /// 필드 자체는 읽혔으나 값이 record 불변식을 깬다(예: link span의 끝이 시작보다 앞). 조용히 고치면 소비자가
    /// 무한 루프/OOB를 낼 수 있어 §12 "손상은 reject" 규율대로 record를 버린다.
    MalformedRecord,
    OutOfMemory,
};

/// str(grapheme·mime) length cap(바이트). 단일 grapheme·mime는 이보다 훨씬 작지만, 손상 length가 거대 alloc을 유발하지 않게 막는다.
pub const max_string_len: usize = 64 * 1024;
/// image_blob 원본 바이트 cap. grapheme/mime과 달리 kitty/sixel 이미지 원본은 수백 KiB라, str cap(64 KiB)이 아니라 단일
/// binary chunk 상한(1 MiB)에 맞춘다 — 64 KiB로 막으면 큰 인라인 이미지가 있는 화면을 재접속 시 직렬화하지 못한다.
/// screen_stream은 protocol을 import하지 않으므로 그 `max_binary_chunk`(1 MiB)를 자체 상수로 미러한다.
pub const max_image_blob: usize = 1024 * 1024;
/// 한 row의 run 수 cap. 폭 8K 화면도 8K run 미만이라 넉넉하며 손상 count를 막는다.
pub const max_runs_per_row: usize = 65536;
/// Host/client viewport snapshot and delta base ceiling. Projection allocators and MRSH chunking
/// compile-check against this codec-level record-stream bound.
pub const max_record_stream_bytes: usize = 16 * 1024 * 1024;

// ── record stream framing ─────────────────────────────────────────────────────
//
// snapshot/delta payload은 여러 record(각 28-byte header + body)를 이어 담는다. record header에는 body 길이가 없어
// 그대로 이어 붙이면 경계를 못 찾으므로, stream 레벨에서 record마다 `u32 length`(record 전체 = header+body 바이트 수)를
// 앞세운다. 이렇게 하면 (1) chunk(1 MiB) 경계와 무관하게 record를 자르고, (2) **모르는 record kind도 length만큼 건너뛴다**
// (MRSH frame의 unknown-skip과 같은 forward-compat). client는 여러 snapshot_chunk payload를 이어 붙인 뒤 이 reader로 순회한다.

/// record(header+body 완성 바이트)를 length-prefixed로 stream 버퍼에 덧붙인다. caller가 버퍼를 소유한다.
pub fn appendRecord(stream: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, record: []const u8) DecodeError!void {
    if (record.len > std.math.maxInt(u32)) return error.LengthOverflow;
    const total = std.math.add(usize, stream.items.len, 4 + record.len) catch
        return error.LengthOverflow;
    if (total > max_record_stream_bytes) return error.OutOfMemory;
    // Keep amortized growth on the hot delta path. A capped projection allocator may reject the
    // geometric capacity even though the exact logical total still fits; only then retry precise.
    stream.ensureTotalCapacity(allocator, total) catch
        stream.ensureTotalCapacityPrecise(allocator, total) catch return error.OutOfMemory;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(record.len), .big);
    stream.appendSliceAssumeCapacity(&len_buf);
    stream.appendSliceAssumeCapacity(record);
}

/// length-prefixed record stream을 순회한다(빌린 슬라이스 — 원본 버퍼 수명 안에서 유효). `next`가 record(header+body)
/// 슬라이스를 하나씩 준다. `split`으로 header/body를 가른 뒤 kind별 `decode*`를 부른다.
pub const RecordStream = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *RecordStream) DecodeError!?[]const u8 {
        if (self.pos == self.bytes.len) return null;
        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        const len = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;
        if (self.pos + len > self.bytes.len) return error.Truncated;
        const rec = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return rec;
    }

    /// record 슬라이스에서 28-byte header를 떼고 body를 준다.
    pub fn split(record: []const u8) DecodeError!struct { header: RecordHeader, body: []const u8 } {
        if (record.len < record_header_size) return error.Truncated;
        const header = try RecordHeader.decode(record[0..record_header_size]);
        return .{ .header = header, .body = record[record_header_size..] };
    }

    pub fn splitExact(record: []const u8, expected_version: u16) DecodeError!struct { header: RecordHeader, body: []const u8 } {
        if (record.len < record_header_size) return error.Truncated;
        const header = try RecordHeader.decodeExact(record[0..record_header_size], expected_version);
        return .{ .header = header, .body = record[record_header_size..] };
    }
};

// ── primitive writer/reader ──────────────────────────────────────────────────

/// body를 big-endian으로 쌓는다. 문자열은 `length:u32 + UTF-8`. 실패는 OOM만(cap은 caller가 확인).
const BodyWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn u8v(self: BodyWriter, v: u8) DecodeError!void {
        self.buf.append(self.allocator, v) catch return error.OutOfMemory;
    }
    fn u16v(self: BodyWriter, v: u16) DecodeError!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn u32v(self: BodyWriter, v: u32) DecodeError!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn i32v(self: BodyWriter, v: i32) DecodeError!void {
        return self.u32v(@bitCast(v));
    }
    fn u64v(self: BodyWriter, v: u64) DecodeError!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn str(self: BodyWriter, s: []const u8) DecodeError!void {
        if (s.len > max_string_len) return error.LengthOverflow;
        try self.u32v(@intCast(s.len));
        self.buf.appendSlice(self.allocator, s) catch return error.OutOfMemory;
    }
    fn cursor(self: BodyWriter, c: Cursor) DecodeError!void {
        try self.u16v(c.col);
        try self.u16v(c.row);
        try self.u8v(@intFromBool(c.visible));
        try self.u8v(c.shape);
    }
    fn rect(self: BodyWriter, r: Rect) DecodeError!void {
        try self.u16v(r.x);
        try self.u16v(r.y);
        try self.u16v(r.w);
        try self.u16v(r.h);
    }
    fn run(self: BodyWriter, r: Run) DecodeError!void {
        try self.str(r.grapheme);
        try self.u8v(r.width);
        try self.u32v(r.count);
        try self.u32v(r.fg);
        try self.u32v(r.bg);
        try self.u32v(r.underline_color);
        try self.u32v(r.style_flags);
    }
};

/// body를 big-endian으로 읽는다. OOB는 `Truncated`. str은 codec 버퍼를 참조(zero-copy)하고 UTF-8을 검증한다.
const BodyReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *BodyReader, n: usize) DecodeError!void {
        if (self.pos + n > self.bytes.len) return error.Truncated;
    }
    fn u8v(self: *BodyReader) DecodeError!u8 {
        try self.need(1);
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    fn u16v(self: *BodyReader) DecodeError!u16 {
        try self.need(2);
        defer self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
    }
    fn u32v(self: *BodyReader) DecodeError!u32 {
        try self.need(4);
        defer self.pos += 4;
        return std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
    }
    fn i32v(self: *BodyReader) DecodeError!i32 {
        return @bitCast(try self.u32v());
    }
    fn u64v(self: *BodyReader) DecodeError!u64 {
        try self.need(8);
        defer self.pos += 8;
        return std.mem.readInt(u64, self.bytes[self.pos..][0..8], .big);
    }
    /// UTF-8 검증된 문자열(codec 버퍼 참조). caller가 버퍼를 유지하는 동안만 유효하다.
    fn str(self: *BodyReader) DecodeError![]const u8 {
        const len = try self.u32v();
        if (len > max_string_len) return error.LengthOverflow;
        try self.need(len);
        const s = self.bytes[self.pos .. self.pos + len];
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        self.pos += len;
        return s;
    }
    /// 임의 바이트 blob(UTF-8 검증 안 함 — image 원본). length는 별도 u32. cap은 image 전용(1 MiB), str(64 KiB) 아님.
    fn bytesField(self: *BodyReader) DecodeError![]const u8 {
        const len = try self.u32v();
        if (len > max_image_blob) return error.LengthOverflow;
        try self.need(len);
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
    fn cursor(self: *BodyReader) DecodeError!Cursor {
        return .{
            .col = try self.u16v(),
            .row = try self.u16v(),
            .visible = (try self.u8v()) != 0,
            .shape = try self.u8v(),
        };
    }
    fn rect(self: *BodyReader) DecodeError!Rect {
        return .{ .x = try self.u16v(), .y = try self.u16v(), .w = try self.u16v(), .h = try self.u16v() };
    }
    fn run(self: *BodyReader) DecodeError!Run {
        return .{
            .grapheme = try self.str(),
            .width = try self.u8v(),
            .count = try self.u32v(),
            .fg = try self.u32v(),
            .bg = try self.u32v(),
            .underline_color = try self.u32v(),
            .style_flags = try self.u32v(),
        };
    }
};

// ── snapshot record encode/decode ────────────────────────────────────────────

/// full record 하나(header + body)를 한 버퍼로 직렬화한다(caller 소유). `encodeScreenMeta`/`encodeRow` 등이 이 helper로 수렴한다.
fn finishRecord(allocator: std.mem.Allocator, header: RecordHeader, body: []const u8) DecodeError![]u8 {
    var out = allocator.alloc(u8, record_header_size + body.len) catch return error.OutOfMemory;
    @memcpy(out[0..record_header_size], &header.encode());
    @memcpy(out[record_header_size..], body);
    return out;
}

pub fn encodeScreenMeta(allocator: std.mem.Allocator, header: RecordHeader, meta: ScreenMeta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(meta.cols);
    try w.u16v(meta.rows);
    try w.u8v(meta.active_screen);
    try w.cursor(meta.cursor);
    try w.u32v(meta.modes);
    try w.u32v(meta.scrollback_len);
    try w.u32v(meta.view_offset);
    return finishRecord(allocator, .{ .kind = .screen_meta, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeScreenMeta(body: []const u8) DecodeError!ScreenMeta {
    var r = BodyReader{ .bytes = body };
    return .{
        .cols = try r.u16v(),
        .rows = try r.u16v(),
        .active_screen = try r.u8v(),
        .cursor = try r.cursor(),
        .modes = try r.u32v(),
        // 끝에 붙은 optional 필드 — 구 host의 짧은 body는 0으로 남긴다(스크롤바 미표시 = 기존 동작).
        .scrollback_len = r.u32v() catch 0,
        .view_offset = r.u32v() catch 0,
    };
}

pub fn encodeRow(allocator: std.mem.Allocator, header: RecordHeader, row: Row) DecodeError![]u8 {
    if (row.runs.len > max_runs_per_row) return error.TooManyItems;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(row.row_index);
    try w.u32v(@intCast(row.runs.len));
    for (row.runs) |rn| try w.run(rn);
    return finishRecord(allocator, .{ .kind = .row, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

/// row body를 decode한다. `runs`는 allocator 소유(caller가 `Row.deinit`). run 수 cap과 UTF-8을 검증한다.
pub fn decodeRow(allocator: std.mem.Allocator, body: []const u8) DecodeError!Row {
    var r = BodyReader{ .bytes = body };
    const row_index = try r.u16v();
    const count = try r.u32v();
    if (count > max_runs_per_row) return error.TooManyItems;
    const runs = allocator.alloc(Run, count) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    for (runs) |*slot| slot.* = try r.run();
    return .{ .row_index = row_index, .runs = runs };
}

/// 한 row의 run 폭 합이 `cols`와 정확히 맞는지 검증한다(§12: run이 row 폭을 넘거나 wide-cell continuation이 어긋나면
/// snapshot 전체 reject). 조립기(P3-c)가 `ScreenMeta.cols`로 각 row를 통과시킨다. codec의 row decode 자체는 cols를 몰라
/// 여기서 분리한다. width*count 누적이 cols를 넘으면 overflow, 부족하면 underfill이다.
pub fn rowWidthMatches(row: Row, cols: u16) bool {
    var total: usize = 0;
    for (row.runs) |rn| {
        total += @as(usize, rn.width) * @as(usize, rn.count);
        if (total > cols) return false; // wide cell이 경계를 넘음 = continuation 불일치
    }
    return total == cols;
}

/// Catch-up accounting용 allocation-free text-cell projection이다. 화면 mutation 전에 전체
/// record를 decode해 `row`/`set_runs`가 기술하는 cell 수만 checked 누적한다. 이미지·cursor·
/// metadata는 encoded-byte cap으로 별도 제한되며 text cell budget을 소비하지 않는다.
pub fn decodedCellCount(bytes: []const u8, expected_codec_version: u16) DecodeError!u64 {
    var total: u64 = 0;
    var records = RecordStream{ .bytes = bytes };
    while (try records.next()) |record| {
        const split = try RecordStream.splitExact(record, expected_codec_version);
        var reader = BodyReader{ .bytes = split.body };
        const run_count = switch (split.header.kind) {
            .row => blk: {
                _ = try reader.u16v();
                break :blk try reader.u32v();
            },
            .set_runs => blk: {
                _ = try reader.u64v();
                _ = try reader.u16v();
                _ = try reader.u16v();
                break :blk try reader.u32v();
            },
            else => continue,
        };
        if (run_count > max_runs_per_row) return error.TooManyItems;
        var index: u32 = 0;
        while (index < run_count) : (index += 1) {
            const run = try reader.run();
            const cells = std.math.mul(u64, run.width, run.count) catch
                return error.LengthOverflow;
            total = std.math.add(u64, total, cells) catch return error.LengthOverflow;
        }
        if (reader.pos != reader.bytes.len) return error.MalformedRecord;
    }
    return total;
}

pub fn encodeImagePlacement(allocator: std.mem.Allocator, header: RecordHeader, p: ImagePlacement) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u32v(p.image_id);
    try w.u32v(p.placement_id);
    try w.i32v(p.row);
    try w.u16v(p.col);
    try w.u32v(p.cell_x_offset);
    try w.u32v(p.cell_y_offset);
    try w.u32v(p.src_x);
    try w.u32v(p.src_y);
    try w.u32v(p.src_width);
    try w.u32v(p.src_height);
    try w.u32v(p.columns);
    try w.u32v(p.rows);
    try w.i32v(p.z);
    return finishRecord(allocator, .{ .kind = header.kind, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImagePlacement(body: []const u8) DecodeError!ImagePlacement {
    var r = BodyReader{ .bytes = body };
    // 필드 순서 = encode wire 순서(struct 리터럴 초기화는 소스 순으로 평가된다 — decodeRun 등과 같은 규약).
    return .{
        .image_id = try r.u32v(),
        .placement_id = try r.u32v(),
        .row = try r.i32v(),
        .col = try r.u16v(),
        .cell_x_offset = try r.u32v(),
        .cell_y_offset = try r.u32v(),
        .src_x = try r.u32v(),
        .src_y = try r.u32v(),
        .src_width = try r.u32v(),
        .src_height = try r.u32v(),
        .columns = try r.u32v(),
        .rows = try r.u32v(),
        .z = try r.i32v(),
    };
}

pub fn encodeImageBlob(allocator: std.mem.Allocator, header: RecordHeader, blob: ImageBlob) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u32v(blob.image_id);
    try w.u64v(blob.generation);
    try w.u32v(blob.width);
    try w.u32v(blob.height);
    try w.u8v(blob.bpp);
    if (blob.pixels.len > max_image_blob) return error.LengthOverflow; // 청크당 cap(1 MiB) — 초과 이미지는 caller가 청크한다
    try w.u32v(@intCast(blob.pixels.len));
    body.appendSlice(allocator, blob.pixels) catch return error.OutOfMemory;
    return finishRecord(allocator, .{ .kind = .image_blob, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImageBlob(body: []const u8) DecodeError!ImageBlob {
    var r = BodyReader{ .bytes = body };
    return .{
        .image_id = try r.u32v(),
        .generation = try r.u64v(),
        .width = try r.u32v(),
        .height = try r.u32v(),
        .bpp = try r.u8v(),
        .pixels = try r.bytesField(),
    };
}

pub fn encodePromptMarks(allocator: std.mem.Allocator, header: RecordHeader, pm: PromptMarks) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(@intCast(pm.rows.len));
    for (pm.rows) |r| {
        try w.u8v(r.kind);
        try w.u8v(if (r.exit != null) 1 else 0);
        try w.u16v(@bitCast(r.exit orelse 0)); // i16→u16 bitcast(has_exit=0이면 값 무의미).
    }
    return finishRecord(allocator, .{ .kind = .prompt_marks, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodePromptMarks(allocator: std.mem.Allocator, body: []const u8) DecodeError!PromptMarks {
    var r = BodyReader{ .bytes = body };
    const count = try r.u16v();
    const rows = allocator.alloc(RowPromptWire, count) catch return error.OutOfMemory;
    errdefer allocator.free(rows);
    for (rows) |*row| {
        const kind = try r.u8v();
        const has_exit = try r.u8v();
        const exit_raw: i16 = @bitCast(try r.u16v());
        row.* = .{ .kind = kind, .exit = if (has_exit != 0) exit_raw else null };
    }
    return .{ .rows = rows };
}

/// 뷰포트 링크 목록을 record로 굽는다. 손상 방어 cap은 span 65535개(u16 count 상한 — 화면 셀 수보다 훨씬 크다).
pub fn encodeLinkSpans(allocator: std.mem.Allocator, header: RecordHeader, ls: LinkSpans) DecodeError![]u8 {
    if (ls.spans.len > std.math.maxInt(u16)) return error.MalformedRecord;
    // producer가 raw wire DTO를 직접 만들더라도 current codec이 해석할 수 없는 enum을 송신하지 않는다.
    for (ls.spans) |s| if (s.kind > link_kind_max or s.scope > link_scope_max) return error.MalformedRecord;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(@intCast(ls.spans.len));
    for (ls.spans) |s| {
        try w.u16v(s.start_row);
        try w.u16v(s.start_col);
        try w.u16v(s.end_row);
        try w.u16v(s.end_col);
        try w.u8v(s.kind);
        try w.u8v(s.scope);
    }
    return finishRecord(allocator, .{ .kind = .link_spans, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeLinkSpans(allocator: std.mem.Allocator, body: []const u8) DecodeError!LinkSpans {
    var r = BodyReader{ .bytes = body };
    const count = try r.u16v();
    const spans = allocator.alloc(LinkSpanWire, count) catch return error.OutOfMemory;
    errdefer allocator.free(spans);
    for (spans) |*s| {
        const start_row = try r.u16v();
        const start_col = try r.u16v();
        const end_row = try r.u16v();
        const end_col = try r.u16v();
        const kind = try r.u8v();
        const scope = try r.u8v();
        // 뒤집힌 범위는 소비자가 무한 루프/OOB를 낼 수 있는 손상이다. 조용히 고치지 않고 record를 reject한다
        // (§12 "손상은 snapshot 전체 reject" — 현재 remote pump 정책은 codec 손상으로 stream을 종료한다).
        if (end_row < start_row or (end_row == start_row and end_col < start_col)) return error.MalformedRecord;
        // wire의 닫힌 enum 범위를 미래 값으로 추측해 URL/web으로 보정하면 schema drift가 정상 hover로 보인다.
        // current codec 범위 밖은 record 손상으로 reject해 정상 화면 상태로 공개하지 않는다.
        if (kind > link_kind_max or scope > link_scope_max) return error.MalformedRecord;
        s.* = .{ .start_row = start_row, .start_col = start_col, .end_row = end_row, .end_col = end_col, .kind = kind, .scope = scope };
    }
    return .{ .spans = spans };
}

// ── delta record encode/decode ───────────────────────────────────────────────

/// set_runs: 한 행의 특정 컬럼부터 run들을 덮어쓴다. wire: base_generation:u64 | row_index:u16 | start_col:u16 | run_count:u32 | run*.
pub const SetRuns = struct {
    base_generation: u64,
    row_index: u16,
    start_col: u16,
    runs: []Run,

    pub fn deinit(self: SetRuns, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
    }
};

pub fn encodeSetRuns(allocator: std.mem.Allocator, header: RecordHeader, op: SetRuns) DecodeError![]u8 {
    if (op.runs.len > max_runs_per_row) return error.TooManyItems;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u16v(op.row_index);
    try w.u16v(op.start_col);
    try w.u32v(@intCast(op.runs.len));
    for (op.runs) |rn| try w.run(rn);
    return finishRecord(allocator, .{ .kind = .set_runs, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeSetRuns(allocator: std.mem.Allocator, body: []const u8) DecodeError!SetRuns {
    var r = BodyReader{ .bytes = body };
    const base_generation = try r.u64v();
    const row_index = try r.u16v();
    const start_col = try r.u16v();
    const count = try r.u32v();
    if (count > max_runs_per_row) return error.TooManyItems;
    const runs = allocator.alloc(Run, count) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    for (runs) |*slot| slot.* = try r.run();
    return .{ .base_generation = base_generation, .row_index = row_index, .start_col = start_col, .runs = runs };
}

/// scroll_rect: 사각형 안 내용을 `dy` 행만큼(양수=위로) 이동한다. wire: base_generation:u64 | rect | dy:i32.
pub const ScrollRect = struct { base_generation: u64, rect: Rect, dy: i32 };
/// clear_rect: 사각형을 default cell로 지운다. wire: base_generation:u64 | rect.
pub const ClearRect = struct { base_generation: u64, rect: Rect };

pub fn encodeScrollRect(allocator: std.mem.Allocator, header: RecordHeader, op: ScrollRect) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.rect(op.rect);
    try w.i32v(op.dy);
    return finishRecord(allocator, .{ .kind = .scroll_rect, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeScrollRect(body: []const u8) DecodeError!ScrollRect {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .rect = try r.rect(), .dy = try r.i32v() };
}

pub fn encodeClearRect(allocator: std.mem.Allocator, header: RecordHeader, op: ClearRect) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.rect(op.rect);
    return finishRecord(allocator, .{ .kind = .clear_rect, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeClearRect(body: []const u8) DecodeError!ClearRect {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .rect = try r.rect() };
}

/// cursor delta: 커서만 바꾼다. wire: base_generation:u64 | cursor.
pub const CursorDelta = struct { base_generation: u64, cursor: Cursor };
/// modes delta: mode bitmask만 바꾼다. wire: base_generation:u64 | modes:u32.
pub const ModesDelta = struct { base_generation: u64, modes: u32 };

pub fn encodeCursor(allocator: std.mem.Allocator, header: RecordHeader, op: CursorDelta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.cursor(op.cursor);
    return finishRecord(allocator, .{ .kind = .cursor, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeCursor(body: []const u8) DecodeError!CursorDelta {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .cursor = try r.cursor() };
}

/// 스크롤 상태 변화(delta). `screen_meta`는 snapshot에만 실려서, 스크롤만 바뀐 프레임에서는 client의 값이
/// stale로 남았다 — 스크롤바가 안 뜨거나 thumb 위치가 화면과 어긋나던 원인이다(재동기화가 일어나야 겨우 맞았다).
pub const ScrollStateDelta = struct {
    base_generation: u64,
    scrollback_len: u32,
    view_offset: u32,
};

pub fn encodeScrollState(allocator: std.mem.Allocator, header: RecordHeader, op: ScrollStateDelta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u32v(op.scrollback_len);
    try w.u32v(op.view_offset);
    return finishRecord(allocator, .{ .kind = .scroll_state, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeScrollState(body: []const u8) DecodeError!ScrollStateDelta {
    var r = BodyReader{ .bytes = body };
    return .{
        .base_generation = try r.u64v(),
        .scrollback_len = try r.u32v(),
        .view_offset = try r.u32v(),
    };
}

pub fn encodeModes(allocator: std.mem.Allocator, header: RecordHeader, op: ModesDelta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u32v(op.modes);
    return finishRecord(allocator, .{ .kind = .modes, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeModes(body: []const u8) DecodeError!ModesDelta {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .modes = try r.u32v() };
}

/// image_remove: 배치된 이미지를 지운다. wire: base_generation:u64 | blob_id:u64.
pub const ImageRemove = struct { base_generation: u64, blob_id: u64 };

pub fn encodeImageRemove(allocator: std.mem.Allocator, header: RecordHeader, op: ImageRemove) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u64v(op.blob_id);
    return finishRecord(allocator, .{ .kind = .image_remove, .generation = header.generation, .version = header.version, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImageRemove(body: []const u8) DecodeError!ImageRemove {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .blob_id = try r.u64v() };
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속·다른 terminal attach는 host의 화면 상태를 이
// codec으로만 받는다. record 한 필드라도 어긋나면 재접속 첫 화면이 깨지거나 wide CJK/이미지가 밀린다. 28-byte
// header, resolved run(grapheme·width·count·색·style), 커서/rect/이미지, delta op, 그리고 row 폭 검증·UTF-8/truncation/
// cap 거부를 왕복으로 고정한다. 순수 codec이라 non-macOS에서 wire 회귀를 잡는다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "screen-stream: record header round-trips with 28-byte big-endian layout" {
    const h = RecordHeader{ .kind = .row, .generation = 0x1122334455667788, .sequence = 5, .chunk_index = 2, .chunk_count = 9 };
    const bytes = h.encode();
    try testing.expectEqual(@as(usize, 28), bytes.len);
    try testing.expectEqual(codec_version, std.mem.readInt(u16, bytes[0..2], .big)); // codec_version(리뷰 #3로 v2)
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[2..4], .big)); // row=2
    const back = try RecordHeader.decode(&bytes);
    try testing.expectEqual(h.kind, back.kind);
    try testing.expectEqual(h.generation, back.generation);
    try testing.expectEqual(h.sequence, back.sequence);
    try testing.expectEqual(h.chunk_index, back.chunk_index);
    try testing.expectEqual(h.chunk_count, back.chunk_count);
}

test "screen-stream: header rejects a foreign codec version" {
    var bytes = (RecordHeader{ .kind = .screen_meta }).encode();
    std.mem.writeInt(u16, bytes[0..2], 99, .big); // 현재 codec_version(2)과 다른 이물질 값(리뷰 #3로 2가 유효해짐).
    try testing.expectError(error.BadCodecVersion, RecordHeader.decode(&bytes));
}

test "screen-stream: frozen N-1 header normalizes the same record body into current DTO" {
    const allocator = testing.allocator;
    const expected = ScreenMeta{
        .cols = 80,
        .rows = 24,
        .active_screen = 1,
        .cursor = .{ .col = 7, .row = 3, .visible = true, .shape = 2 },
        .modes = 0x55,
    };
    const record = try encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 9 }, expected);
    defer allocator.free(record);
    std.mem.writeInt(u16, record[0..2], reader_min, .big);
    const header = try RecordHeader.decode(record[0..record_header_size]);
    try testing.expectEqual(reader_min, header.version);
    const decoded = try decodeScreenMeta(record[record_header_size..]);
    try testing.expectEqual(expected.cols, decoded.cols);
    try testing.expectEqual(expected.rows, decoded.rows);
    try testing.expectEqual(expected.cursor, decoded.cursor);
    try testing.expectEqual(expected.modes, decoded.modes);
}

test "screen-stream: record kind is an open enum for future records" {
    var bytes = (RecordHeader{ .kind = .row }).encode();
    std.mem.writeInt(u16, bytes[2..4], 9999, .big);
    const back = try RecordHeader.decode(&bytes);
    try testing.expect(!back.kind.isKnown()); // 상위가 optional/required로 처리
}

test "screen-stream: screen_meta round-trips through the full record" {
    const allocator = testing.allocator;
    const meta = ScreenMeta{ .cols = 120, .rows = 40, .active_screen = 1, .cursor = .{ .col = 10, .row = 3, .visible = false, .shape = 2 }, .modes = 0xDEAD };
    const rec = try encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 7 }, meta);
    defer allocator.free(rec);
    const header = try RecordHeader.decode(rec[0..record_header_size]);
    try testing.expectEqual(RecordKind.screen_meta, header.kind);
    try testing.expectEqual(@as(u64, 7), header.generation);
    const back = try decodeScreenMeta(rec[record_header_size..]);
    try testing.expectEqual(meta.cols, back.cols);
    try testing.expectEqual(meta.rows, back.rows);
    try testing.expectEqual(meta.active_screen, back.active_screen);
    try testing.expectEqual(meta.cursor.col, back.cursor.col);
    try testing.expectEqual(meta.cursor.visible, back.cursor.visible);
    try testing.expectEqual(meta.cursor.shape, back.cursor.shape);
    try testing.expectEqual(meta.modes, back.modes);
}

test "screen-stream: row of resolved runs round-trips including wide CJK" {
    const allocator = testing.allocator;
    var runs = [_]Run{
        .{ .grapheme = "a", .width = 1, .count = 3, .fg = 0xFF0000, .bg = 0x000000, .style_flags = StyleFlags.bold },
        .{ .grapheme = "한", .width = 2, .count = 1, .fg = 0x00FF00, .underline_color = 0x0000FF, .style_flags = StyleFlags.underline | StyleFlags.underline_curly },
    };
    const rec = try encodeRow(allocator, .{ .kind = .row, .generation = 1 }, .{ .row_index = 4, .runs = &runs });
    defer allocator.free(rec);
    const row = try decodeRow(allocator, rec[record_header_size..]);
    defer row.deinit(allocator);
    try testing.expectEqual(@as(u16, 4), row.row_index);
    try testing.expectEqual(@as(usize, 2), row.runs.len);
    try testing.expectEqualStrings("a", row.runs[0].grapheme);
    try testing.expectEqual(@as(u32, 3), row.runs[0].count);
    try testing.expectEqual(StyleFlags.bold, row.runs[0].style_flags);
    try testing.expectEqualStrings("한", row.runs[1].grapheme);
    try testing.expectEqual(@as(u8, 2), row.runs[1].width);
    try testing.expectEqual(@as(u32, 0x0000FF), row.runs[1].underline_color);
}

test "screen-stream: rowWidthMatches enforces cols and catches wide-cell continuation overflow" {
    // 폭 5: "a"(1x3) + "한"(2x1) = 3 + 2 = 5 → 정확히 맞음.
    var ok_runs = [_]Run{
        .{ .grapheme = "a", .width = 1, .count = 3 },
        .{ .grapheme = "한", .width = 2, .count = 1 },
    };
    try testing.expect(rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 5));
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 4)); // 넘침(continuation 불일치)
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 6)); // 부족(underfill)
    // wide cell이 폭 경계를 1칸 넘김: "한"(2x1)이 폭 1에 안 들어감.
    var wide = [_]Run{.{ .grapheme = "한", .width = 2, .count = 1 }};
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &wide }, 1));
}

test "screen-stream: decode rejects truncated body and invalid UTF-8 grapheme" {
    const allocator = testing.allocator;
    // truncated: screen_meta body를 잘라 낸다.
    try testing.expectError(error.Truncated, decodeScreenMeta(&[_]u8{ 0, 120 })); // cols만 있고 나머지 없음
    // invalid UTF-8 grapheme in a row run.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(0); // row_index
    try w.u32v(1); // run_count
    try w.u32v(2); // grapheme len = 2
    try body.appendSlice(allocator, &[_]u8{ 0xFF, 0xFE }); // invalid UTF-8
    try testing.expectError(error.InvalidUtf8, decodeRow(allocator, body.items));
}

test "screen-stream: delta ops round-trip (set_runs, scroll_rect, clear_rect, cursor, modes, image)" {
    const allocator = testing.allocator;

    var runs = [_]Run{.{ .grapheme = "x", .width = 1, .count = 2, .fg = 0x123456 }};
    const sr = try encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = 11, .sequence = 3 }, .{ .base_generation = 10, .row_index = 2, .start_col = 5, .runs = &runs });
    defer allocator.free(sr);
    {
        const h = try RecordHeader.decode(sr[0..record_header_size]);
        try testing.expectEqual(RecordKind.set_runs, h.kind);
        try testing.expectEqual(@as(u64, 3), h.sequence);
        const op = try decodeSetRuns(allocator, sr[record_header_size..]);
        defer op.deinit(allocator);
        try testing.expectEqual(@as(u64, 10), op.base_generation);
        try testing.expectEqual(@as(u16, 5), op.start_col);
        try testing.expectEqualStrings("x", op.runs[0].grapheme);
    }

    const sc = try encodeScrollRect(allocator, .{ .kind = .scroll_rect }, .{ .base_generation = 10, .rect = .{ .x = 0, .y = 1, .w = 80, .h = 20 }, .dy = -3 });
    defer allocator.free(sc);
    try testing.expectEqual(@as(i32, -3), (try decodeScrollRect(sc[record_header_size..])).dy);

    const cl = try encodeClearRect(allocator, .{ .kind = .clear_rect }, .{ .base_generation = 10, .rect = .{ .x = 2, .y = 2, .w = 4, .h = 1 } });
    defer allocator.free(cl);
    try testing.expectEqual(@as(u16, 4), (try decodeClearRect(cl[record_header_size..])).rect.w);

    const cu = try encodeCursor(allocator, .{ .kind = .cursor }, .{ .base_generation = 10, .cursor = .{ .col = 7, .row = 9, .visible = true, .shape = 1 } });
    defer allocator.free(cu);
    try testing.expectEqual(@as(u16, 7), (try decodeCursor(cu[record_header_size..])).cursor.col);

    const mo = try encodeModes(allocator, .{ .kind = .modes }, .{ .base_generation = 10, .modes = 0xBEEF });
    defer allocator.free(mo);
    try testing.expectEqual(@as(u32, 0xBEEF), (try decodeModes(mo[record_header_size..])).modes);

    const ip = try encodeImagePlacement(allocator, .{ .kind = .image_place }, .{ .image_id = 5, .placement_id = 3, .row = 1, .col = 2, .src_width = 64, .columns = 10, .rows = 5, .z = 2 });
    defer allocator.free(ip);
    const ip_dec = try decodeImagePlacement(ip[record_header_size..]);
    try testing.expectEqual(@as(u32, 5), ip_dec.image_id);
    try testing.expectEqual(@as(u32, 3), ip_dec.placement_id);
    try testing.expectEqual(@as(i32, 1), ip_dec.row);
    try testing.expectEqual(@as(u16, 2), ip_dec.col);
    try testing.expectEqual(@as(u32, 64), ip_dec.src_width);
    try testing.expectEqual(@as(u32, 10), ip_dec.columns);
    try testing.expectEqual(@as(i32, 2), ip_dec.z);

    const ir = try encodeImageRemove(allocator, .{ .kind = .image_remove }, .{ .base_generation = 10, .blob_id = 5 });
    defer allocator.free(ir);
    try testing.expectEqual(@as(u64, 5), (try decodeImageRemove(ir[record_header_size..])).blob_id);
}

test "screen-stream: catchup decoded cell accounting counts row and set-runs before apply" {
    const allocator = std.testing.allocator;
    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(allocator);
    var row_runs = [_]Run{
        .{ .grapheme = "a", .width = 1, .count = 2 },
        .{ .grapheme = "界", .width = 2, .count = 1 },
    };
    const row = try encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &row_runs },
    );
    defer allocator.free(row);
    try appendRecord(&records, allocator, row);
    var delta_runs = [_]Run{.{ .grapheme = "b", .width = 1, .count = 3 }};
    const delta = try encodeSetRuns(
        allocator,
        .{ .kind = .set_runs, .generation = 1, .sequence = 1 },
        .{ .base_generation = 1, .row_index = 0, .start_col = 0, .runs = &delta_runs },
    );
    defer allocator.free(delta);
    try appendRecord(&records, allocator, delta);
    try std.testing.expectEqual(@as(u64, 7), try decodedCellCount(records.items, codec_version));

    try records.append(allocator, 0xff);
    try std.testing.expectError(error.Truncated, decodedCellCount(records.items, codec_version));
}

test "screen-stream: image_blob round-trips decoded pixels + chunk header, rejects oversized chunk" {
    const allocator = testing.allocator;
    const pixels = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04 }; // 2px RGBA(디코드된 raw)
    // 청크 헤더(chunk_index/count)와 디코드 픽셀 메타(image_id/generation/w/h/bpp)가 왕복한다.
    const rec = try encodeImageBlob(allocator, .{ .kind = .image_blob, .chunk_index = 1, .chunk_count = 3 }, .{
        .image_id = 42,
        .generation = 7,
        .width = 2,
        .height = 1,
        .bpp = 4,
        .pixels = &pixels,
    });
    defer allocator.free(rec);
    const hdr = try RecordHeader.decode(rec[0..record_header_size]);
    try testing.expectEqual(@as(u32, 1), hdr.chunk_index);
    try testing.expectEqual(@as(u32, 3), hdr.chunk_count);
    const blob = try decodeImageBlob(rec[record_header_size..]);
    try testing.expectEqual(@as(u32, 42), blob.image_id);
    try testing.expectEqual(@as(u64, 7), blob.generation);
    try testing.expectEqual(@as(u32, 2), blob.width);
    try testing.expectEqual(@as(u32, 1), blob.height);
    try testing.expectEqual(@as(u8, 4), blob.bpp);
    try testing.expectEqualSlices(u8, &pixels, blob.pixels);

    // per-record cap 초과 픽셀은 alloc 전에 거부(손상/폭주 방어) — 초과 이미지는 caller가 청크로 나눠야 한다.
    const big = try allocator.alloc(u8, max_image_blob + 1);
    defer allocator.free(big);
    try testing.expectError(error.LengthOverflow, encodeImageBlob(allocator, .{ .kind = .image_blob }, .{
        .image_id = 1,
        .width = 1,
        .height = 1,
        .bpp = 4,
        .pixels = big,
    }));
}

test "screen-stream: prompt_marks round-trips dense per-row semantic + exit code" {
    const allocator = testing.allocator;
    var rows = [_]RowPromptWire{
        .{ .kind = 1, .exit = null }, // prompt(A~B)
        .{ .kind = 3, .exit = -2 }, // command, 종료코드 -2(음수도 왕복)
        .{ .kind = 0, .exit = null }, // unknown
    };
    const rec = try encodePromptMarks(allocator, .{ .kind = .prompt_marks, .generation = 4 }, .{ .rows = &rows });
    defer allocator.free(rec);
    const pm = try decodePromptMarks(allocator, rec[record_header_size..]);
    defer pm.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), pm.rows.len);
    try testing.expectEqual(@as(u8, 1), pm.rows[0].kind);
    try testing.expectEqual(@as(?i16, null), pm.rows[0].exit);
    try testing.expectEqual(@as(u8, 3), pm.rows[1].kind);
    try testing.expectEqual(@as(?i16, -2), pm.rows[1].exit);
    try testing.expectEqual(@as(?i16, null), pm.rows[2].exit);
}

// 원격 client는 이 record 하나로 Cmd+hover 밑줄을 그린다(docs/link-detection.md §원격(host-backed) 세션).
// 좌표·종류·scope가 한 비트라도 왕복에서 어긋나면 밑줄이 엉뚱한 칸에 그어지거나 client의 config 필터가
// 잘못 걸러 링크가 사라진다. full-replace라 "링크 0개"도 유효한 상태다(host가 방출을 생략하는 것과 구분).
test "screen-stream: link_spans round-trips coordinates, kind and scope" {
    const allocator = testing.allocator;
    var spans = [_]LinkSpanWire{
        .{ .start_row = 0, .start_col = 3, .end_row = 0, .end_col = 26, .kind = 0, .scope = 0 }, // url/web
        .{ .start_row = 2, .start_col = 4, .end_row = 3, .end_col = 9, .kind = 1, .scope = 5 }, // file_path/bare(soft-wrap)
        .{ .start_row = 4, .start_col = 0, .end_row = 4, .end_col = 3, .kind = 0, .scope = 6 }, // osc8
    };
    const rec = try encodeLinkSpans(allocator, .{ .kind = .link_spans, .generation = 7 }, .{ .spans = &spans });
    defer allocator.free(rec);
    const ls = try decodeLinkSpans(allocator, rec[record_header_size..]);
    defer ls.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), ls.spans.len);
    try testing.expectEqualDeep(spans[0], ls.spans[0]);
    try testing.expectEqualDeep(spans[1], ls.spans[1]); // 여러 행에 걸친 span도 그대로
    try testing.expectEqual(@as(u8, 6), ls.spans[2].scope); // osc8 비트

    // 빈 목록도 유효한 full-replace(= "지금 화면에 링크 없음")다 — 소비자가 이전 목록을 지우는 근거.
    const empty = try encodeLinkSpans(allocator, .{ .kind = .link_spans, .generation = 8 }, .{ .spans = &.{} });
    defer allocator.free(empty);
    const none = try decodeLinkSpans(allocator, empty[record_header_size..]);
    defer none.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), none.spans.len);
}

// 뒤집힌 범위를 그대로 받아들이면 소비자가 start..end를 순회하다 무한 루프/OOB에 빠진다. 손상은 조용히
// 고치지 않고 record를 reject해 client가 full 재동기화하게 한다(§12).
test "screen-stream: link_spans rejects a reversed span" {
    const allocator = testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(1);
    try w.u16v(5); // start_row
    try w.u16v(0); // start_col
    try w.u16v(2); // end_row < start_row → 손상
    try w.u16v(0);
    try w.u8v(0);
    try w.u8v(0);
    try testing.expectError(error.MalformedRecord, decodeLinkSpans(allocator, body.items));
}

test "screen-stream: link_spans rejects unknown kind and scope instead of clamping" {
    const allocator = testing.allocator;
    const Case = struct { kind: u8, scope: u8 };
    const cases = [_]Case{
        .{ .kind = 2, .scope = 0 },
        .{ .kind = 0, .scope = 7 },
        .{ .kind = 255, .scope = 255 },
    };
    for (cases) |case| {
        var invalid = [_]LinkSpanWire{.{
            .start_row = 0,
            .start_col = 0,
            .end_row = 0,
            .end_col = 1,
            .kind = case.kind,
            .scope = case.scope,
        }};
        try testing.expectError(
            error.MalformedRecord,
            encodeLinkSpans(allocator, .{ .kind = .link_spans }, .{ .spans = invalid[0..] }),
        );

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        const w = BodyWriter{ .buf = &body, .allocator = allocator };
        try w.u16v(1);
        try w.u16v(0);
        try w.u16v(0);
        try w.u16v(0);
        try w.u16v(1);
        try w.u8v(case.kind);
        try w.u8v(case.scope);
        try testing.expectError(error.MalformedRecord, decodeLinkSpans(allocator, body.items));
    }
}

test "screen-stream: run count cap rejects a corrupt declared count before allocating" {
    const allocator = testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(0); // row_index
    try w.u32v(@intCast(max_runs_per_row + 1)); // 손상된 거대 run_count
    try testing.expectError(error.TooManyItems, decodeRow(allocator, body.items));
}

test "screen-stream: length-prefixed record stream splits records across chunk boundaries" {
    const allocator = testing.allocator;
    // 여러 record(screen_meta + row 2개)를 length-prefix로 한 stream에 담는다.
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);

    const meta_rec = try encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 5 }, .{ .cols = 4, .rows = 2, .cursor = .{ .col = 1, .row = 0 } });
    defer allocator.free(meta_rec);
    try appendRecord(&stream, allocator, meta_rec);

    var runs0 = [_]Run{.{ .grapheme = "x", .width = 1, .count = 4 }};
    const row0 = try encodeRow(allocator, .{ .kind = .row, .generation = 5 }, .{ .row_index = 0, .runs = &runs0 });
    defer allocator.free(row0);
    try appendRecord(&stream, allocator, row0);

    var runs1 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 4 }};
    const row1 = try encodeRow(allocator, .{ .kind = .row, .generation = 5 }, .{ .row_index = 1, .runs = &runs1 });
    defer allocator.free(row1);
    try appendRecord(&stream, allocator, row1);

    // reader가 세 record를 순서대로 돌려주고, header/body 분리 후 kind별 decode가 원본과 일치한다.
    var rs = RecordStream{ .bytes = stream.items };

    const r0 = (try rs.next()).?;
    const s0 = try RecordStream.split(r0);
    try testing.expectEqual(RecordKind.screen_meta, s0.header.kind);
    try testing.expectEqual(@as(u64, 5), s0.header.generation);
    const meta = try decodeScreenMeta(s0.body);
    try testing.expectEqual(@as(u16, 4), meta.cols);
    try testing.expectEqual(@as(u16, 1), meta.cursor.col);

    const r1 = (try rs.next()).?;
    const s1 = try RecordStream.split(r1);
    try testing.expectEqual(RecordKind.row, s1.header.kind);
    const dr0 = try decodeRow(allocator, s1.body);
    defer dr0.deinit(allocator);
    try testing.expectEqual(@as(u16, 0), dr0.row_index);
    try testing.expectEqualStrings("x", dr0.runs[0].grapheme);
    try testing.expectEqual(@as(u32, 4), dr0.runs[0].count);

    const r2 = (try rs.next()).?;
    const s2 = try RecordStream.split(r2);
    const dr1 = try decodeRow(allocator, s2.body);
    defer dr1.deinit(allocator);
    try testing.expectEqual(@as(u16, 1), dr1.row_index);

    try testing.expect((try rs.next()) == null); // 더 없음

    // 잘린 length는 Truncated(부분 chunk).
    var bad = RecordStream{ .bytes = stream.items[0 .. stream.items.len - 2] };
    _ = try bad.next(); // 첫 record는 온전
    _ = try bad.next(); // 둘째도 온전
    try testing.expectError(error.Truncated, bad.next()); // 셋째 length가 남은 바이트를 넘음
}
