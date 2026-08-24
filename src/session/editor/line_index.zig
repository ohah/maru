//! 문서 bytes에서 **논리 줄 경계**를 뽑아 byte offset ↔ (줄, 줄 안 offset)을 왕복시킨다.
//!
//! 이것이 편집기 L2의 가장 아래층이다([문서 모델](../../../docs/native-editor-document-model.md) §3.1과
//! [시각 매핑](../../../docs/native-editor-visual-mapping.md) §4).
//! 위치의 정본은 **UTF-8 byte offset**이고 `(행, 열)`이 아니다 — 랩이 켜지면 열이 뷰 폭에 종속되고
//! 접힘·가상 텍스트가 들어오면 행 번호마저 화면과 어긋나기 때문이다. 그래서 이 모듈이 내는 "줄"은
//! **논리 줄**(문서의 `\n` 경계)이지 화면 행이 아니다. 화면 행으로 가는 변환은 L3 시각 매핑이 맡는다.
//!
//! **왜 별도 모듈인가**: 줄 경계는 문서가 바뀔 때만 바뀌고, 시각 매핑은 뷰 폭·접힘·랩이 바뀔 때도
//! 바뀐다. 둘을 한 파일에 두면 서로 다른 이유로 같은 파일이 변경된다(project-rules "구조와 파일 분리").

const std = @import("std");

/// 줄바꿈 표현. 디스크 원본을 **보존**해야 하므로(§3.5) 무엇이었는지 기억한다.
///
/// 파일 하나가 두 방식을 섞어 쓰는 경우가 실제로 있어서(생성 파일·병합 결과) 문서 전체를 하나로
/// 단정하지 않고, 저장할 때 **원래 그 줄이 쓰던 것**을 되쓴다.
pub const LineEnding = enum {
    /// `\n` — Unix.
    lf,
    /// `\r\n` — Windows. byte 두 개라 줄 내용 길이 계산에서 갈린다.
    crlf,
    /// 파일 마지막 줄이 줄바꿈 없이 끝난 경우. "빈 마지막 줄"과 구별해야 한다(§3.5).
    none,

    /// 이 줄바꿈이 차지하는 byte 수. 줄 내용 끝을 구할 때 쓴다.
    pub fn byteLen(self: LineEnding) usize {
        return switch (self) {
            .lf => 1,
            .crlf => 2,
            .none => 0,
        };
    }
};

/// 논리 줄 하나. `start`는 줄 첫 byte의 문서 offset이고 `end_with_ending`은 줄바꿈까지 **포함한** 끝이다.
///
/// 두 끝을 함께 두는 이유: 표시에 쓸 내용은 줄바꿈을 빼야 하고(그리면 안 되는 문자다), 다음 줄 시작을
/// 구할 때는 포함한 값이 필요하다. 매번 `+ ending.byteLen()`을 하게 두면 한 곳만 빠뜨려도 조용히 어긋난다.
pub const Line = struct {
    start: usize,
    end_with_ending: usize,
    ending: LineEnding,

    /// 줄바꿈을 뺀 내용의 끝 offset. 표시·열 계산은 전부 이 값을 쓴다.
    pub fn contentEnd(self: Line) usize {
        return self.end_with_ending - self.ending.byteLen();
    }

    /// 줄바꿈을 뺀 내용의 byte 길이.
    pub fn contentLen(self: Line) usize {
        return self.contentEnd() - self.start;
    }
};

/// 문서의 줄 경계 표.
///
/// **소유**: `lines`는 이 구조가 할당하고 `deinit`으로 푼다. 문서 bytes는 소유하지 않는다 — 버퍼가
/// 주인이고 이 표는 그 위의 인덱스일 뿐이다.
pub const LineIndex = struct {
    lines: []Line,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LineIndex) void {
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    /// 논리 줄 수. **항상 1 이상이다** — 빈 문서도 "빈 줄 하나"로 본다.
    ///
    /// 0줄 문서를 허용하면 커서를 놓을 자리가 없어져서 모든 소비처가 빈 문서 분기를 따로 져야 한다.
    /// 편집기는 빈 파일에도 커서를 보여야 하므로 여기서 한 번 정규화한다.
    pub fn lineCount(self: LineIndex) usize {
        return self.lines.len;
    }

    /// 0-based 줄 번호로 줄을 얻는다. 범위 밖이면 null.
    pub fn line(self: LineIndex, index: usize) ?Line {
        if (index >= self.lines.len) return null;
        return self.lines[index];
    }

    /// byte offset이 속한 **0-based 논리 줄 번호**. 이분 탐색이라 큰 파일에서도 로그 시간이다.
    ///
    /// 경계 규칙: 줄바꿈 byte 자체는 **그 줄에 속한다**. 즉 `"ab\ncd"`에서 offset 2(`\n`)는 0번 줄이고
    /// offset 3(`c`)이 1번 줄이다. 이렇게 두지 않으면 줄 끝에 커서를 놓았을 때 다음 줄로 튄다.
    ///
    /// 문서 끝 offset(= 총 byte 수)은 **마지막 줄**로 답한다. 커서가 문서 맨 뒤에 있는 것은 정상 상태다.
    ///
    /// **문서 끝을 넘는 offset은 정상이 아니다.** 편집·재로드로 버퍼가 줄었는데 옛 caret offset이
    /// 남아 있으면 그렇게 되는데, 여기서 조용히 마지막 줄로 답하면 `offsetInLine`이 그 줄의 내용
    /// 길이를 넘는 열을 돌려주고, 그 값으로 만든 슬라이스가 버퍼 밖으로 넘어간다. Debug에서 즉시
    /// 멈추고(아래 assert), Release에서는 `clampOffset`을 거치도록 소비처를 유도한다.
    pub fn lineAt(self: LineIndex, offset: usize) usize {
        std.debug.assert(offset <= self.byteLen());
        var low: usize = 0;
        var high: usize = self.lines.len; // exclusive

        while (low + 1 < high) {
            const mid = low + (high - low) / 2;
            if (self.lines[mid].start <= offset) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return low;
    }

    /// offset을 문서 범위 안으로 clamp한다. 버퍼가 줄어든 뒤 남은 옛 caret을 살릴 때 쓴다.
    pub fn clampOffset(self: LineIndex, offset: usize) usize {
        return @min(offset, self.byteLen());
    }

    /// 줄 안에서의 byte offset(줄 시작으로부터). 화면 열이 **아니다** — 탭·전각·그래핌은 L3가 푼다.
    ///
    /// **줄 내용 길이를 넘지 않는다.** 넘는 값을 돌려주면 `bytes[start .. start + col]` 형태의
    /// 슬라이스가 버퍼 밖으로 나간다.
    pub fn offsetInLine(self: LineIndex, offset: usize) usize {
        const clamped = self.clampOffset(offset);
        const idx = self.lineAt(clamped);
        const l = self.lines[idx];
        if (clamped < l.start) return 0;
        return @min(clamped - l.start, l.contentLen());
    }

    /// 문서 총 byte 수. 마지막 줄의 끝이 곧 문서 끝이다.
    pub fn byteLen(self: LineIndex) usize {
        return self.lines[self.lines.len - 1].end_with_ending;
    }
};

/// 문서 bytes를 훑어 줄 경계 표를 만든다.
///
/// **한 번에 전부 훑는다.** 뷰포트만 훑고 싶은 유혹이 있지만, 줄 번호는 문서 처음부터 세지 않으면
/// 알 수 없고 스크롤바 길이도 총 줄 수를 요구한다. 큰 파일의 비용은 §3.0의 축소 단계가 다룬다.
///
/// `\r`이 홀로 오는 옛 Mac 방식(CR 단독)은 **줄바꿈으로 보지 않는다.** 현대 파일에서 사실상 사라졌고,
/// 이를 줄바꿈으로 받으면 `\r`을 데이터로 쓰는 파일(터미널 캡처 로그 등)이 잘못 쪼개진다.
pub fn build(allocator: std.mem.Allocator, bytes: []const u8) !LineIndex {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    // **줄 수를 먼저 세어 한 번에 잡는다.** 세는 비용(SIMD 한 번)보다 증설 비용이 컸다 — 실측에서
    // 이 예약이 나머지 절반을 걷어냈다. `+ 1`은 마지막 줄바꿈 뒤의 줄(문서가 비었으면 그 한 줄)이다.
    try lines.ensureTotalCapacityPrecise(allocator, std.mem.count(u8, bytes, "\n") + 1);

    // **줄바꿈을 하나씩 세지 않고 건너뛰며 찾는다.** byte 단위 루프는 편집마다 문서 전체를 다시
    // 훑는 경로에서 지배적이었다 — 실측(ReleaseFast, 1 MiB) 편집 1회 1178µs 중 대부분이 여기였고,
    // rope 편집(94µs)·평탄화(141µs)보다 한 자릿수 컸다. `indexOfScalarPos`는 같은 답을 벡터 폭으로
    // 낸다. **CRLF 판정과 경계 규칙은 그대로다**(아래 검사 순서가 옛 루프와 같다).
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |i| {
        // 앞 byte가 `\r`이면 CRLF 한 덩어리다. 줄 첫 byte에는 앞이 없으므로 `i > start`가 먼저다.
        const is_crlf = i > start and bytes[i - 1] == '\r';
        try lines.append(allocator, .{
            .start = start,
            .end_with_ending = i + 1,
            .ending = if (is_crlf) .crlf else .lf,
        });
        start = i + 1;
    }

    // 마지막 줄바꿈 뒤에 남은 것 — 또는 문서가 비었을 때의 그 한 줄.
    //
    // 파일이 `\n`으로 끝나면 여기서 **빈 줄 하나가 더 생긴다.** 이는 버그가 아니라 의도다: 편집기는
    // 그 자리에 커서를 놓을 수 있어야 하고, 그것이 "파일 끝 개행이 있다"는 사실의 시각적 표현이다.
    try lines.append(allocator, .{
        .start = start,
        .end_with_ending = bytes.len,
        .ending = .none,
    });

    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const testing = std.testing;

test "빈 문서도 줄 하나를 갖는다 — 커서를 놓을 자리가 있어야 한다" {
    var idx = try build(testing.allocator, "");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.lineCount());
    try testing.expectEqual(@as(usize, 0), idx.byteLen());

    const l = idx.line(0).?;
    try testing.expectEqual(@as(usize, 0), l.start);
    try testing.expectEqual(@as(usize, 0), l.contentLen());
    try testing.expectEqual(LineEnding.none, l.ending);
}

test "줄바꿈 없는 한 줄" {
    var idx = try build(testing.allocator, "hello");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.lineCount());
    const l = idx.line(0).?;
    try testing.expectEqual(@as(usize, 5), l.contentLen());
    try testing.expectEqual(LineEnding.none, l.ending);
}

test "파일 끝 개행은 빈 마지막 줄을 만든다 — 그 자리에 커서를 놓을 수 있어야 한다" {
    var idx = try build(testing.allocator, "a\n");
    defer idx.deinit();

    // "a" 줄 + 그 뒤 빈 줄 = 2줄. 이것이 `cat`이 보여주는 것과 편집기가 보여주는 것의 차이다.
    try testing.expectEqual(@as(usize, 2), idx.lineCount());
    try testing.expectEqual(@as(usize, 1), idx.line(0).?.contentLen());
    try testing.expectEqual(@as(usize, 0), idx.line(1).?.contentLen());
    try testing.expectEqual(@as(usize, 2), idx.line(1).?.start);
}

test "파일 끝 개행 유무가 줄 수를 가른다" {
    var with_nl = try build(testing.allocator, "a\nb\n");
    defer with_nl.deinit();
    var without_nl = try build(testing.allocator, "a\nb");
    defer without_nl.deinit();

    try testing.expectEqual(@as(usize, 3), with_nl.lineCount());
    try testing.expectEqual(@as(usize, 2), without_nl.lineCount());
}

test "CRLF는 두 byte 줄바꿈으로 인식되고 내용에서 빠진다" {
    var idx = try build(testing.allocator, "ab\r\ncd");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.lineCount());

    const first = idx.line(0).?;
    try testing.expectEqual(LineEnding.crlf, first.ending);
    // `\r`은 내용이 아니다 — 그리면 화면에 이상한 글자가 나온다.
    try testing.expectEqual(@as(usize, 2), first.contentLen());
    try testing.expectEqual(@as(usize, 2), first.contentEnd());
    try testing.expectEqual(@as(usize, 4), first.end_with_ending);
}

test "LF와 CRLF가 한 파일에 섞여도 줄마다 원본을 기억한다" {
    // 생성 파일·병합 결과에서 실제로 나온다. 문서 전체를 하나로 단정하면 저장할 때 원본이 깨진다.
    var idx = try build(testing.allocator, "a\nb\r\nc");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 3), idx.lineCount());
    try testing.expectEqual(LineEnding.lf, idx.line(0).?.ending);
    try testing.expectEqual(LineEnding.crlf, idx.line(1).?.ending);
    try testing.expectEqual(LineEnding.none, idx.line(2).?.ending);
}

test "홀로 있는 CR은 줄바꿈이 아니다 — 데이터로 쓰는 파일이 잘못 쪼개진다" {
    var idx = try build(testing.allocator, "a\rb");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.lineCount());
    try testing.expectEqual(@as(usize, 3), idx.line(0).?.contentLen());
}

test "lineAt: 줄바꿈 byte는 그 줄에 속한다 — 줄 끝 커서가 다음 줄로 튀면 안 된다" {
    //  offset: 0=a 1=b 2=\n 3=c 4=d
    var idx = try build(testing.allocator, "ab\ncd");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 0), idx.lineAt(0));
    try testing.expectEqual(@as(usize, 0), idx.lineAt(1));
    try testing.expectEqual(@as(usize, 0), idx.lineAt(2)); // `\n` 자신
    try testing.expectEqual(@as(usize, 1), idx.lineAt(3));
    try testing.expectEqual(@as(usize, 1), idx.lineAt(4));
}

test "lineAt: 문서 끝 offset은 마지막 줄이다 — 맨 뒤 커서는 정상 상태다" {
    var idx = try build(testing.allocator, "ab\ncd");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 5), idx.byteLen());
    try testing.expectEqual(@as(usize, 1), idx.lineAt(5));
}

test "lineAt: 여러 줄에서 이분 탐색이 맞는 줄을 고른다" {
    var idx = try build(testing.allocator, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n");
    defer idx.deinit();

    // 10개 내용 줄 + 파일 끝 개행이 만든 빈 줄.
    try testing.expectEqual(@as(usize, 11), idx.lineCount());

    // 각 줄이 2 byte("N\n")라 줄 n의 시작은 2n이다.
    var n: usize = 0;
    while (n < 10) : (n += 1) {
        try testing.expectEqual(n, idx.lineAt(n * 2));
        try testing.expectEqual(n, idx.lineAt(n * 2 + 1)); // 그 줄의 `\n`
    }
    try testing.expectEqual(@as(usize, 10), idx.lineAt(20)); // 마지막 빈 줄
}

test "offsetInLine: 줄 시작으로부터의 byte 거리" {
    var idx = try build(testing.allocator, "ab\ncdef");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 0), idx.offsetInLine(0));
    try testing.expectEqual(@as(usize, 1), idx.offsetInLine(1));
    try testing.expectEqual(@as(usize, 0), idx.offsetInLine(3)); // 둘째 줄 첫 글자
    try testing.expectEqual(@as(usize, 3), idx.offsetInLine(6));
}

test "offsetInLine: CRLF 줄에서도 내용 기준으로 센다" {
    var idx = try build(testing.allocator, "ab\r\ncd");
    defer idx.deinit();

    // `\r`은 offset 2, `\n`은 3. 둘 다 0번 줄이고 줄 안 offset은 그대로다.
    try testing.expectEqual(@as(usize, 2), idx.offsetInLine(2));
    try testing.expectEqual(@as(usize, 0), idx.offsetInLine(4)); // 둘째 줄 시작
}

test "UTF-8 다중 byte는 쪼개지지 않는다 — 줄 경계만 보므로 한글도 그대로 실린다" {
    // "가"는 3 byte다. 줄 인덱스는 byte만 세므로 내용 길이가 byte 단위로 나와야 한다.
    var idx = try build(testing.allocator, "가나\n다");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.lineCount());
    try testing.expectEqual(@as(usize, 6), idx.line(0).?.contentLen());
    try testing.expectEqual(@as(usize, 3), idx.line(1).?.contentLen());
    try testing.expectEqual(@as(usize, 0), idx.lineAt(5)); // "나"의 마지막 byte
    try testing.expectEqual(@as(usize, 1), idx.lineAt(7)); // "다"의 첫 byte
}

test "연속 빈 줄" {
    var idx = try build(testing.allocator, "\n\n\n");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 4), idx.lineCount());
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        try testing.expectEqual(@as(usize, 0), idx.line(n).?.contentLen());
        try testing.expectEqual(LineEnding.lf, idx.line(n).?.ending);
    }
    try testing.expectEqual(LineEnding.none, idx.line(3).?.ending);
}

test "첫 byte가 개행이어도 CRLF로 오인하지 않는다" {
    // `i > start` 가드가 없으면 bytes[-1]을 읽거나 앞 줄의 마지막 byte를 본다.
    var idx = try build(testing.allocator, "\nx");
    defer idx.deinit();

    try testing.expectEqual(LineEnding.lf, idx.line(0).?.ending);
    try testing.expectEqual(@as(usize, 0), idx.line(0).?.contentLen());
}

test "줄 끝이 `\\r`인 줄 다음에 오는 개행은 CRLF다" {
    // 앞 줄이 `\r`로 끝나고 다음 줄이 바로 `\n`으로 시작하는 경계 — `i > start` 가드가 이 경우를
    // 줄 안의 `\r`과 구별해야 한다.
    var idx = try build(testing.allocator, "a\r\n\r\nb");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 3), idx.lineCount());
    try testing.expectEqual(LineEnding.crlf, idx.line(0).?.ending);
    try testing.expectEqual(LineEnding.crlf, idx.line(1).?.ending);
    try testing.expectEqual(@as(usize, 0), idx.line(1).?.contentLen());
}

test "clampOffset: 문서가 줄어든 뒤 남은 옛 offset을 범위 안으로 되돌린다" {
    var idx = try build(testing.allocator, "ab\ncd");
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 5), idx.clampOffset(5)); // 문서 끝은 유효
    try testing.expectEqual(@as(usize, 5), idx.clampOffset(999)); // 넘으면 끝으로
}

test "offsetInLine: 줄 내용 길이를 넘지 않는다 — 슬라이스가 버퍼 밖으로 나가면 안 된다" {
    var idx = try build(testing.allocator, "ab\ncd");
    defer idx.deinit();

    // 문서 끝(5)은 마지막 줄 "cd"의 offset 2 — 내용 길이와 같다(그 뒤에 커서를 놓을 수 있다).
    try testing.expectEqual(@as(usize, 2), idx.offsetInLine(5));
    // 범위를 넘겨도 그 값을 넘지 않는다.
    try testing.expectEqual(@as(usize, 2), idx.offsetInLine(999));
}
