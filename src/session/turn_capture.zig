//! 에이전트 턴이 만진 파일의 **그림자 사본**(before/after).
//!
//! 계약 [§4.4](../../docs/agent-turn-changes.md)가 턴 변경분의 권위를 `git write-tree` 스냅샷에서
//! **maru 가 직접 읽은 파일 내용**으로 옮겼다. 근거 셋: `write-tree` 는 작업트리 전체를 stat 해
//! 0.49 s 인데 파일 하나는 3 ms 다(§2.6) · git 이 없어도 된다 · tree 는 작업트리 전체라 **다른
//! 세션·사용자의 편집이 원리적으로 섞인다.**
//!
//! **이 층은 파일을 읽지 않는다.** 읽기(열기·stat·심링크 거부)는 L4 가 하고 여기는 **보관 정책**만
//! 갖는다 — 상한, 초과 시 접기, before 를 첫 캡처로 고정, 링과의 수명 결합.
//!
//! **할당자를 받는다.** 그림자 사본은 길이가 무계라 `agent_transcript` 식 고정 버퍼로는 못 든다.
//! 같은 층의 `agent_session_archive.Parsed` 가 선례다 — 힙을 들되 `deinit` 을 단일 회수점으로 둔다.

const std = @import("std");
const diff_payload = @import("diff_payload.zig");

/// 한 쪽(before 또는 after) 하나가 보관할 수 있는 최대 바이트.
///
/// **`diff_payload.max_side_bytes`(8 MiB)와 같게 파생하지 않는다.** 두 상한은 다른 질문에 답한다 —
/// 그쪽은 사용자가 **명시적으로 연 파일 하나**를 여는 동안만 들지만, 우리는 에이전트가 **만진 모든
/// 파일을 양쪽 다 묻지 않은 채** 링 8턴 × 세션 8 = 최대 64벌 곱해서 든다. 노출 배수가 1 대 64 인 두
/// 값이 같은 숫자를 쓰면 그 숫자는 둘 중 어느 쪽 근거도 아니게 된다.
///
/// 실측(§2.6): 파일 중앙값 12.7 KB · p90 89.6 KB · 최대 4.8 MB. 1 MiB 는 p90 의 11배를 덮고,
/// 4.8 MB 짜리 한 파일을 위해 64벌을 감수하지는 않는다 — 그건 해시로 접는다.
pub const max_capture_bytes: usize = 1 << 20;

/// 한 턴이 보관할 수 있는 바이트 합(before + after).
pub const max_turn_bytes: usize = 4 << 20;

/// 한 턴이 들 수 있는 경로 수. 실측 최대 55(턴당 중앙값 2 · p90 12)라 여유가 넉넉하다.
///
/// 바이트와 **둘 다** 두는 이유가 다르다 — 바이트는 메모리를, 경로 수는 부기(목록 길이·순회 비용)를
/// 막는다. 중앙값 12.7 KB 기준 256 × 12.7 KB ≈ 3.2 MB 라 둘이 비슷한 지점에서 걸린다.
pub const max_turn_paths: usize = 256;

// 상한 사다리에서 **우리가 맨 아래**여야 한다. 위가 내려오면(또는 우리가 올라가면) 「담았는데 못
// 보여주는」 구간이 생긴다 — 값으로 못 박아 컴파일에서 걸리게 한다.
comptime {
    std.debug.assert(max_capture_bytes <= diff_payload.max_side_bytes);
}

/// 무엇이 이 경로를 캡처하게 했나.
///
/// ⚠️ **트리거를 안 나누면 화면이 거짓말을 한다.** `Read` 도 `file_path` 를 싣는다(실측: 경로를
/// 실은 `PreToolUse` 517건 중 `Read` 360건 = 70%). 「캡처됐다」를 「편집됐다」로 읽으면 **읽기만 한
/// 파일이 «AI 편집»으로 뜬다.** `✎` 는 `.edit` 트리거 **그리고** 내용이 달라진 것만 센다.
pub const Trigger = enum {
    /// `Read` — 내용을 바꾸지 않는다. before 를 미리 확보하는 것이 목적이다(셸 편집 회수율의 핵심).
    read,
    /// `Edit`·`Write`·Codex `apply_patch` — 바꾸려고 여는 것이다.
    edit,
};

/// 내용을 못 든 이유. **지어내지 않는다** — 세 사유가 화면에서 서로 다른 말이 된다.
pub const Unknown = enum {
    /// 열거나 읽지 못했다(권한·심링크 거부·경합).
    unreadable,
    /// 워크스페이스 루트 밖이다. 경로는 적되 **내용은 읽지 않는다**(§7).
    outside_root,
    /// 턴 예산이 말랐다. 경로는 남긴다 — 조용히 빠지면 「원래 안 바뀐 파일」로 보인다.
    budget,
};

/// 내용을 접은 이유.
pub const Fold = enum { too_large, binary };

/// 한 시점의 파일 상태.
///
/// **`absent`·`empty` 를 가른다.** `Write` 로 새 파일을 만드는 흐름에서 「없었다」와 「0바이트로
/// 있었다」는 다른 사실이다(`editor.zig` 가 `readFileAlloc` 이 빈 파일을 `null` 로 주는 함정을 이미
/// 적어 뒀다). 같은 규율이 `Snapshot.files_known` 의 「0과 모름은 다르다」다.
pub const Side = union(enum) {
    absent,
    empty,
    text: []u8,
    folded: struct { hash: u64, size: u64, why: Fold },
    unknown: Unknown,

    /// 보관에 쓰는 바이트(예산 계산용). 접힌 것·없는 것은 0이다.
    pub fn heldBytes(self: Side) usize {
        return switch (self) {
            .text => |t| t.len,
            else => 0,
        };
    }

    /// 두 쪽이 **같다고 말할 수 있나.** 「모른다」는 같다고도 다르다고도 하지 않는다 — `null` 이다.
    ///
    /// 접힌 것끼리는 **해시로 답할 수 있다**(내용을 못 들어도 「만졌는데 결과가 같다」는 말할 수 있다).
    /// 그래서 초과 읽기가 전문을 해시해야 한다 — 앞부분만 해시하면 뒷부분만 다른 두 큰 파일이
    /// **거짓으로 같아진다.**
    pub fn sameAs(self: Side, other: Side) ?bool {
        if (self == .unknown or other == .unknown) return null;
        return switch (self) {
            .absent => other == .absent,
            .empty => other == .empty,
            .text => |a| switch (other) {
                .text => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            .folded => |a| switch (other) {
                .folded => |b| a.hash == b.hash and a.size == b.size,
                else => false,
            },
            .unknown => unreachable,
        };
    }
};

/// 한 경로의 before/after 한 쌍.
pub const Entry = struct {
    /// 소유한다(`Store` 의 할당자로 판다).
    path: []u8,
    trigger: Trigger,
    before: Side,
    /// 봉인 전에는 `null` — 「아직 안 읽었다」와 「읽었는데 모른다(`.unknown`)」는 다른 사실이다.
    after: ?Side = null,

    /// 이 경로가 **에이전트 편집 도구 때문에 실제로 달라졌나.**
    ///
    /// 셋을 모두 만족해야 참이다: ⑴ 트리거가 `.edit` ⑵ 양쪽을 다 안다 ⑶ 내용이 다르다.
    /// `.read` 트리거를 빼는 것이 이 함수의 존재 이유다 — 위 `Trigger` 주석의 함정.
    pub fn editedByAgent(self: Entry) bool {
        if (self.trigger != .edit) return false;
        const after = self.after orelse return false;
        const same = self.before.sameAs(after) orelse return false;
        return !same;
    }
};

/// 진행 중이거나 봉인된 턴 하나가 든 경로들.
pub const Turn = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// 지금 보관 중인 바이트 합(before + after).
    held: usize = 0,
    /// 그 턴에 에이전트가 부른 **셸 도구 호출 수**(`Bash`·`exec`).
    ///
    /// 셸은 경로를 안 주므로(계약 §2.3 — provider 구현이 그 필드를 아예 안 만든다) 사본이 없다.
    /// 그래서 이 수가 **목록의 `·` 가 왜 있는지**를 말하는 유일한 근거다 — 「그 턴에 셸 명령이 N개
    /// 있었고, 그중 무엇이 어느 파일을 고쳤는지는 확정할 수 없다」.
    ///
    /// **경로 항목과 독립이다.** 셸만 쓴 턴은 `entries` 가 비어도 이 수가 있고, `seal` 이 그 경우도
    /// 봉인한다(아래) — 고지가 **가장 필요한 자리**가 바로 그 턴이기 때문이다.
    shell_calls: u32 = 0,
    /// **봉인 때 한 번 센** 「에이전트가 실제로 고친 경로 수」(= `editedByAgent()` 가 참인 항목).
    ///
    /// 화면이 이 수를 **턴 행마다 매 프레임** 읽는다. 그때마다 세면 `sameAs` 가 `.text` 두 쪽을
    /// `mem.eql` 로 비교하는데 한 쪽이 **최대 `max_capture_bytes`(1 MiB)** 다 — 길이가 같은 편집
    /// (한 글자 치환·되돌린 편집)은 전부를 비교한다. 항목 최대 256 × 행 최대 8 이면 **프레임마다
    /// 수백 MiB** 를 훑을 수 있다. 봉인 뒤 `entries` 는 안 변하므로 그때 한 번 세는 것으로 족하다.
    edited_count: u32 = 0,

    pub fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            gpa.free(e.path);
            freeSide(gpa, e.before);
            if (e.after) |a| freeSide(gpa, a);
        }
        self.entries.deinit(gpa);
        self.* = .{};
    }

    /// 그 경로가 이미 이 턴에 있나(있으면 그 자리).
    pub fn find(self: *const Turn, path: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) return i;
        }
        return null;
    }

    /// 붙일 것이 하나라도 있나 — 경로든 셸 수든.
    pub fn hasEvidence(self: *const Turn) bool {
        return self.entries.items.len > 0 or self.shell_calls > 0;
    }

    /// **에이전트 편집 도구가 실제로 바꾼 파일 수.** 화면의 `✎ M` 이 이 값이다.
    /// 지금 항목을 **실제로 훑어** 센다 — `seal` 이 한 번 부르고, 테스트가 쓴다.
    ///
    /// ⚠️ **화면은 이것을 부르지 않는다.** 매 프레임 도는 자리에서는 `edited_count` 를 읽는다
    /// (위 그 필드의 주석에 이유를 적었다 — 여기 `mem.eql` 이 최대 1 MiB 를 훑는다).
    /// 「봉인 전엔 0을 내는 래퍼」를 두지 않는 이유는 그 래퍼가 **부르는 쪽을 속이기** 때문이다.
    pub fn countEdited(self: *const Turn) u32 {
        var n: u32 = 0;
        for (self.entries.items) |e| {
            if (e.editedByAgent()) n += 1;
        }
        return n;
    }
};

fn freeSide(gpa: std.mem.Allocator, side: Side) void {
    switch (side) {
        .text => |t| gpa.free(t),
        else => {},
    }
}

/// 링과 묶이는 캡처 식별자. `0` 은 「없음」이다(`RingMap.Entry.used` 와 같은 관례).
pub const Id = u64;

/// 진행 중 턴은 세션마다 하나, 봉인된 턴은 링이 드는 만큼.
///
/// 상한이 **링에서 파생된다** — 새 상한을 발명하지 않는다. 세션 8 × 링 8 = 64.
pub const max_open: usize = 8;

/// 봉인 자리. **링이 가리킬 수 있는 최대(64) + 2** 다.
///
/// **+1 의 이유**: 새 턴은 링에 실리기 **전에** 봉인된다. 링이 64개를 꽉 가리키는 순간 65번째를 봉인하면
/// 자리가 없어 `seal` 이 가장 오래된 것을 밀어내는데, 그 자리에서는 **아직 가리켜지는 사본**이 밀린다 —
/// 그러면 그 턴의 `✎` 가 조용히 0이 되고, 사용자는 그것을 「에이전트가 안 건드렸다」로 읽는다.
/// 한 칸을 더 두면 그 전이가 안전하고, 새 턴이 실리는 순간 밀려난 옛 턴이 고아가 되어 다음 sweep 이 푼다.
///
/// 호출자는 **봉인 전에 sweep 을 돌려** 고아를 먼저 비운다(`captureTurnSnapshot`) — 이 +1 은 그 뒤에도
/// 남는 «전부 살아 있는» 경우만 덮는 마지막 한 칸이다.
/// **+2 의 내역**(둘 다 「링에 없지만 살아 있는 것」이다):
///
/// 1. **요청 중인 사본 하나.** 봉인된 사본은 `submitSnapshot` 뒤 harvest 가 돌 때까지 링에 안 들어간다.
///    호출자는 그 id 를 살아 있는 것으로 쳐 sweep 에서 지킨다.
/// 2. **지금 봉인하는 것 하나.** 위 둘이 다 살아 있는 순간(링 64 + 요청 중 1 = 65)에도 새 턴을 담을
///    자리가 있어야 한다 — 없으면 `seal` 이 가장 오래된 것을 밀어내는데 그것이 **아직 가리켜지는 사본**
///    이고, 그러면 그 턴의 `✎` 와 고지가 조용히 0이 된다.
///
/// ⚠️ **이 값은 「살아 있는 것의 최대」와 함께 움직인다.** 요청 중 사본을 살려 두는 고침(2026-08-26)을
/// 넣으면서 이 산술을 다시 안 봐 65로 남아 있었고, 적대적 검증이 그 한 칸을 잡았다.
pub const max_sealed: usize = 64 + 2;
pub const max_session_id_len: usize = 64;

const OpenSlot = struct {
    used: bool = false,
    id: [max_session_id_len]u8 = undefined,
    id_len: usize = 0,
    turn: Turn = .{},

    fn session(self: *const OpenSlot) []const u8 {
        return self.id[0..self.id_len];
    }
};

const SealedSlot = struct {
    id: Id = 0,
    turn: Turn = .{},
};

/// 그림자 사본 저장소. 세션 하나가 하나 든다.
pub const Store = struct {
    open: [max_open]OpenSlot = @splat(.{}),
    sealed: [max_sealed]SealedSlot = @splat(.{}),
    /// 다음에 발급할 id. **재사용하지 않는다** — 밀려난 턴의 id 가 다시 나오면 화면에 남아 있던
    /// 선택·펼침이 **남의 턴에 거짓으로 붙는다.**
    next_id: Id = 1,

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (&self.open) |*s| {
            if (s.used) s.turn.deinit(gpa);
            s.* = .{};
        }
        for (&self.sealed) |*s| {
            if (s.id != 0) s.turn.deinit(gpa);
            s.* = .{};
        }
        self.next_id = 1;
    }

    fn openFor(self: *Store, session_id: []const u8) ?*OpenSlot {
        if (session_id.len == 0 or session_id.len > max_session_id_len) return null;
        var free_slot: ?*OpenSlot = null;
        for (&self.open) |*s| {
            if (s.used) {
                if (std.mem.eql(u8, s.session(), session_id)) return s;
            } else if (free_slot == null) free_slot = s;
        }
        const slot = free_slot orelse return null;
        @memcpy(slot.id[0..session_id.len], session_id);
        slot.id_len = session_id.len;
        slot.used = true;
        slot.turn = .{};
        return slot;
    }

    /// 진행 중 턴을 들여다본다(없으면 null).
    pub fn openTurn(self: *Store, session_id: []const u8) ?*Turn {
        if (session_id.len == 0) return null;
        for (&self.open) |*s| {
            if (s.used and std.mem.eql(u8, s.session(), session_id)) return &s.turn;
        }
        return null;
    }

    /// 봉인된 턴을 id 로 찾는다.
    pub fn sealedTurn(self: *Store, id: Id) ?*Turn {
        if (id == 0) return null;
        for (&self.sealed) |*s| {
            if (s.id == id) return &s.turn;
        }
        return null;
    }

    /// before 를 기록한다. **이미 있으면 아무것도 하지 않는다** — 그것이 「첫 캡처로 고정」이다.
    ///
    /// 두 번째 도구가 같은 파일을 만질 때 그 파일은 **첫 도구가 이미 고친 뒤**다. 다시 읽으면
    /// before 가 「첫 편집 후」가 되어 턴의 diff 가 **첫 편집을 통째로 숨긴다.**
    ///
    /// 트리거는 **격상만 한다**(`read` → `edit`). 읽고 나서 고치는 것이 흔한 순서인데 첫 트리거로
    /// 굳히면 그 파일이 영영 `✎` 를 못 받는다. 반대(edit → read)로는 내리지 않는다.
    ///
    /// **`side` 의 소유권은 언제나 이 함수가 가져간다** — 거절하더라도 해제는 여기서 한다. 호출자
    /// (L4)는 파일을 읽어 넘기고 잊으면 된다. 거절 경로마다 「이번엔 내가 풀어야 하나」를 따지게
    /// 만들면 그 판단이 한 곳만 틀려도 누수가 되고, 호출부는 세 곳으로 늘어난다.
    ///
    /// 반환값은 「새로 담았나」다. 예산이 말라 접혔어도 **경로는 남고 참을 돌려준다** — 조용히
    /// 빠지면 그 파일이 「원래 안 바뀐 것」으로 보인다(계약 §8 「한계를 숨기지 않는다」).
    pub fn noteBefore(
        self: *Store,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        path: []const u8,
        trigger: Trigger,
        side: Side,
    ) bool {
        const slot = self.openFor(session_id) orelse {
            freeSide(gpa, side);
            return false;
        };
        if (slot.turn.find(path)) |i| {
            // 트리거만 격상하고 내용은 **건드리지 않는다**.
            if (trigger == .edit) slot.turn.entries.items[i].trigger = .edit;
            freeSide(gpa, side);
            return false;
        }
        if (slot.turn.entries.items.len >= max_turn_paths) {
            freeSide(gpa, side);
            return false;
        }

        // **after 몫까지 예약한다.** 안 그러면 봉인 패스가 예산을 두 배로 넘긴다.
        var stored = side;
        const want = side.heldBytes();
        if (want != 0 and slot.turn.held + want * 2 > max_turn_bytes) {
            freeSide(gpa, side);
            stored = .{ .unknown = .budget };
        }

        const owned = gpa.dupe(u8, path) catch {
            freeSide(gpa, stored);
            return false;
        };
        slot.turn.entries.append(gpa, .{
            .path = owned,
            .trigger = trigger,
            .before = stored,
        }) catch {
            gpa.free(owned);
            freeSide(gpa, stored);
            return false;
        };
        slot.turn.held += stored.heldBytes();
        return true;
    }

    /// after 를 채운다(봉인 패스가 경로마다 부른다). 이미 채웠으면 새 값을 버린다.
    ///
    /// `noteBefore` 와 같은 규칙 — **소유권은 언제나 이 함수가 가져간다.**
    pub fn noteAfter(
        self: *Store,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        path: []const u8,
        side: Side,
    ) void {
        const turn = self.openTurn(session_id) orelse {
            freeSide(gpa, side);
            return;
        };
        const i = turn.find(path) orelse {
            freeSide(gpa, side);
            return;
        };
        if (turn.entries.items[i].after != null) {
            freeSide(gpa, side);
            return;
        }
        var stored = side;
        const want = side.heldBytes();
        if (want != 0 and turn.held + want > max_turn_bytes) {
            freeSide(gpa, side);
            stored = .{ .unknown = .budget };
        }
        turn.entries.items[i].after = stored;
        turn.held += stored.heldBytes();
    }

    /// 그 턴의 셸 도구 호출을 하나 센다. 경로가 없어도 진행 중 자리를 연다 — 셸만 쓴 턴도 봉인되어야
    /// 고지가 뜬다(`Turn.shell_calls` 주석).
    pub fn noteShellCall(self: *Store, session_id: []const u8) void {
        const slot = self.openFor(session_id) orelse return;
        slot.turn.shell_calls +|= 1;
    }

    /// 진행 중 턴을 봉인해 id 를 발급한다. **붙일 것이 하나도 없으면 `0`**(경로도 셸 수도 없는 턴).
    ///
    /// 봉인 자리가 없으면 **가장 오래된 것을 밀어낸다** — 그 자리는 sweep 이 곧 정리하지만, 정리
    /// 시점이 오기 전에 자리가 마를 수 있다(링은 세션당 8인데 우리는 전체 64다).
    pub fn seal(self: *Store, gpa: std.mem.Allocator, session_id: []const u8) Id {
        const slot = blk: {
            for (&self.open) |*s| {
                if (s.used and std.mem.eql(u8, s.session(), session_id)) break :blk s;
            }
            return 0;
        };
        defer {
            slot.used = false;
            slot.id_len = 0;
            slot.turn = .{};
        }
        // **셸만 쓴 턴도 봉인한다.** 경로가 없다고 거절하면 고지가 **필요한 곳에서만 사라진다** —
        // 파일 행이 전부 `·` 인 턴이야말로 「왜 그런지」를 말해 줄 것이 셸 수뿐이다. 대가는 없다:
        // 경로가 없는 버킷은 힙을 한 바이트도 안 쓰고(카운터 하나), 고아가 되어도 sweep 이 공짜로 치운다.
        if (!slot.turn.hasEvidence()) {
            slot.turn.deinit(gpa);
            return 0;
        }
        // **여기서 한 번 센다.** 봉인 뒤 `entries` 는 안 변하고, 화면은 이 수를 매 프레임 읽는다.
        // (`after` 는 이 호출 직전에 다 채워져 있다 — `sealTurnCapture` 가 그 루프를 먼저 돈다.)
        slot.turn.edited_count = slot.turn.countEdited();

        const id = self.next_id;
        self.next_id += 1;

        var victim: *SealedSlot = &self.sealed[0];
        for (&self.sealed) |*s| {
            if (s.id == 0) {
                victim = s;
                break;
            }
            if (s.id < victim.id) victim = s;
        }
        if (victim.id != 0) victim.turn.deinit(gpa);
        victim.* = .{ .id = id, .turn = slot.turn };
        return id;
    }

    /// **도달성 sweep** — 아직 가리켜지는 봉인 턴만 남긴다.
    ///
    /// 「지우는 호출」로 두지 않는 이유: 턴이 사라지는 길이 **넷**이고 호출 방식은 셋을 흘린다.
    /// ⑴ `Ring.push` 가 8칸을 넘겨 덮는다 ⑵ `RingMap.victim()` 이 세션을 통째로 밀어낸다
    /// ⑶ `ringFor` 가 저장소 전환에 링을 **대입 한 줄로** 갈아 끼운다(호출을 끼울 자리가 없다)
    /// ⑷ `push` 가 dedup 으로 거절한다(봉인·발급 **직후**라 그 순간 고아가 된다).
    ///
    /// 넷을 질문 하나로 덮는다 — 「이 캡처를 아직 가리키는 스냅샷이 있나」.
    pub fn sweep(self: *Store, gpa: std.mem.Allocator, live: []const Id) void {
        for (&self.sealed) |*s| {
            if (s.id == 0) continue;
            if (std.mem.indexOfScalar(Id, live, s.id) != null) continue;
            s.turn.deinit(gpa);
            s.* = .{};
        }
    }

    /// 진행 중 턴을 버린다(세션이 사라졌을 때).
    pub fn dropOpen(self: *Store, gpa: std.mem.Allocator, session_id: []const u8) void {
        for (&self.open) |*s| {
            if (s.used and std.mem.eql(u8, s.session(), session_id)) {
                s.turn.deinit(gpa);
                s.* = .{};
                return;
            }
        }
    }

    /// 보관 중인 총 바이트(테스트·진단용).
    pub fn heldBytes(self: *const Store) usize {
        var n: usize = 0;
        for (&self.open) |*s| {
            if (s.used) n += s.turn.held;
        }
        for (&self.sealed) |*s| {
            if (s.id != 0) n += s.turn.held;
        }
        return n;
    }
};

const testing = std.testing;

test "before 는 첫 캡처로 고정된다 — 두 번째 값이 덮지 않는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .read, .{ .text = try gpa.dupe(u8, "A") }));
    // 같은 경로를 다시 — 두 번째 내용은 **들어가면 안 된다**.
    try testing.expect(!store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .{ .text = try gpa.dupe(u8, "B") }));

    const turn = store.openTurn("S1").?;
    try testing.expectEqual(@as(usize, 1), turn.entries.items.len);
    // 「뭔가 담겼다」가 아니라 **첫 값 그대로**임을 본다 — 덮어쓰는 구현은 "B" 를 낸다.
    try testing.expectEqualStrings("A", turn.entries.items[0].before.text);
    // 트리거는 격상됐다.
    try testing.expectEqual(Trigger.edit, turn.entries.items[0].trigger);
}

test "읽기만 한 파일은 ✎ 로 세지 않는다 — 내용이 달라져도" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // `.read` 트리거인데 내용이 달라졌다(셸이 고쳤다). 편집 도구 소행이 아니다.
    try testing.expect(store.noteBefore(gpa, "S1", "/r/r.zig", .read, .{ .text = try gpa.dupe(u8, "one") }));
    store.noteAfter(gpa, "S1", "/r/r.zig", .{ .text = try gpa.dupe(u8, "two") });
    // `.edit` 트리거이고 달라졌다.
    try testing.expect(store.noteBefore(gpa, "S1", "/r/e.zig", .edit, .{ .text = try gpa.dupe(u8, "one") }));
    store.noteAfter(gpa, "S1", "/r/e.zig", .{ .text = try gpa.dupe(u8, "two") });

    const turn = store.openTurn("S1").?;
    try testing.expectEqual(@as(u32, 1), turn.countEdited());
    try testing.expect(!turn.entries.items[0].editedByAgent());
    try testing.expect(turn.entries.items[1].editedByAgent());
}

test "편집했지만 내용이 같으면 세지 않는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .{ .text = try gpa.dupe(u8, "same") }));
    store.noteAfter(gpa, "S1", "/r/a.zig", .{ .text = try gpa.dupe(u8, "same") });
    try testing.expectEqual(@as(u32, 0), store.openTurn("S1").?.countEdited());
}

test "모르는 쪽이 있으면 같다고도 다르다고도 하지 않는다" {
    const known: Side = .{ .text = @constCast("x") };
    const unknown: Side = .{ .unknown = .unreadable };
    try testing.expect(known.sameAs(unknown) == null);
    try testing.expect(unknown.sameAs(known) == null);
    // 그래서 `✎` 로도 안 센다.
    const e: Entry = .{ .path = @constCast("p"), .trigger = .edit, .before = known, .after = unknown };
    try testing.expect(!e.editedByAgent());
}

test "absent · empty · unknown 은 서로 다른 사실이다" {
    const absent: Side = .absent;
    const empty: Side = .empty;
    const unknown: Side = .{ .unknown = .unreadable };
    // 쌍마다 본다 — `x != .unknown` 만 보면 전부 `.empty` 로 접는 구현이 통과한다.
    try testing.expectEqual(@as(?bool, false), absent.sameAs(empty));
    try testing.expectEqual(@as(?bool, false), empty.sameAs(absent));
    try testing.expect(absent.sameAs(unknown) == null);
    try testing.expectEqual(@as(?bool, true), absent.sameAs(.absent));
    try testing.expectEqual(@as(?bool, true), empty.sameAs(.empty));
}

test "접힌 두 쪽은 해시로 같음을 답한다 — 크기가 같아도 내용이 다르면 다르다" {
    const a: Side = .{ .folded = .{ .hash = 1, .size = 100, .why = .too_large } };
    const b: Side = .{ .folded = .{ .hash = 2, .size = 100, .why = .too_large } };
    const c: Side = .{ .folded = .{ .hash = 1, .size = 100, .why = .too_large } };
    try testing.expectEqual(@as(?bool, false), a.sameAs(b));
    try testing.expectEqual(@as(?bool, true), a.sameAs(c));
    // 크기만 다른 경우도 다르다(해시 충돌 방어).
    const d: Side = .{ .folded = .{ .hash = 1, .size = 101, .why = .too_large } };
    try testing.expectEqual(@as(?bool, false), a.sameAs(d));
}

test "턴 예산이 마르면 그 파일만 접히고 경로는 남는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // after 몫까지 예약하므로 절반이 실질 한도다.
    const big = try gpa.alloc(u8, max_turn_bytes / 2 + 1);
    @memset(big, 'x');
    try testing.expect(store.noteBefore(gpa, "S1", "/r/big.zig", .edit, .{ .text = big }));

    const turn = store.openTurn("S1").?;
    // 경로는 **남아 있고**, 내용만 접혔다.
    try testing.expectEqual(@as(usize, 1), turn.entries.items.len);
    try testing.expectEqual(Unknown.budget, turn.entries.items[0].before.unknown);

    // 그 뒤 작은 파일은 여전히 들어간다 — 턴을 통째로 버리지 않는다.
    try testing.expect(store.noteBefore(gpa, "S1", "/r/small.zig", .edit, .{ .text = try gpa.dupe(u8, "s") }));
    try testing.expectEqual(@as(usize, 2), turn.entries.items.len);
    try testing.expectEqualStrings("s", turn.entries.items[1].before.text);
}

test "경로 수 상한을 넘으면 새 경로를 안 받되 기존 것은 유지한다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    var buf: [64]u8 = undefined;
    for (0..max_turn_paths) |i| {
        const p = try std.fmt.bufPrint(&buf, "/r/{d}.zig", .{i});
        try testing.expect(store.noteBefore(gpa, "S1", p, .edit, .empty));
    }
    try testing.expect(!store.noteBefore(gpa, "S1", "/r/over.zig", .edit, .empty));
    const turn = store.openTurn("S1").?;
    try testing.expectEqual(max_turn_paths, turn.entries.items.len);
    // 기존 것이 살아 있다.
    try testing.expect(turn.find("/r/0.zig") != null);
}

test "봉인은 id 를 발급하고 진행 중 자리를 비운다 · 빈 턴은 0" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // 경로가 없는 턴은 붙일 것이 없다.
    _ = store.openFor("S0");
    try testing.expectEqual(@as(Id, 0), store.seal(gpa, "S0"));

    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .empty));
    const id = store.seal(gpa, "S1");
    try testing.expect(id != 0);
    // 진행 중 자리는 비었고, 봉인 자리에서 찾힌다.
    try testing.expect(store.openTurn("S1") == null);
    try testing.expect(store.sealedTurn(id) != null);
}

test "sweep 은 가리켜지지 않는 것만 푼다 — 살아남은 것의 내용은 그대로다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .{ .text = try gpa.dupe(u8, "keep") }));
    const keep = store.seal(gpa, "S1");
    try testing.expect(store.noteBefore(gpa, "S2", "/r/b.zig", .edit, .{ .text = try gpa.dupe(u8, "drop") }));
    const drop = store.seal(gpa, "S2");

    store.sweep(gpa, &.{keep});

    // ⑴ 밀려난 것은 사라졌고(누수는 `testing.allocator` 가 본다)
    try testing.expect(store.sealedTurn(drop) == null);
    // ⑵ 살아남은 것은 **내용이 바이트 그대로**다 — 「전부 푸는」 구현이 여기서 죽는다.
    const kept = store.sealedTurn(keep).?;
    try testing.expectEqualStrings("keep", kept.entries.items[0].before.text);
}

test "빈 live 목록이면 봉인된 것이 전부 풀린다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .{ .text = try gpa.dupe(u8, "x") }));
    const id = store.seal(gpa, "S1");
    store.sweep(gpa, &.{});
    try testing.expect(store.sealedTurn(id) == null);
    try testing.expectEqual(@as(usize, 0), store.heldBytes());
}

test "셸 호출은 셀 때만 늘고 봉인 뒤에도 남는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // 안 세면 0이다.
    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .empty));
    try testing.expectEqual(@as(u32, 0), store.openTurn("S1").?.shell_calls);

    store.noteShellCall("S1");
    store.noteShellCall("S1");
    try testing.expectEqual(@as(u32, 2), store.openTurn("S1").?.shell_calls);

    const id = store.seal(gpa, "S1");
    try testing.expect(id != 0);
    // **봉인 뒤에도 살아 있어야** 화면이 읽는다.
    try testing.expectEqual(@as(u32, 2), store.sealedTurn(id).?.shell_calls);
}

test "셸만 쓴 턴도 봉인된다 — 그러나 아무것도 없는 턴은 여전히 0이다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // 경로가 하나도 없다. **고지가 가장 필요한 자리**이므로 봉인되어야 한다.
    store.noteShellCall("S-shell");
    store.noteShellCall("S-shell");
    store.noteShellCall("S-shell");
    const id = store.seal(gpa, "S-shell");
    try testing.expect(id != 0);
    const sealed = store.sealedTurn(id) orelse return error.NoSealed;
    try testing.expectEqual(@as(usize, 0), sealed.entries.items.len);
    try testing.expectEqual(@as(u32, 3), sealed.shell_calls);

    // **뒤 절반이 없으면 「무조건 봉인」 구현이 통과한다.** 붙일 것이 없는 턴은 여전히 0이어야 한다.
    _ = store.openFor("S-empty");
    try testing.expectEqual(@as(Id, 0), store.seal(gpa, "S-empty"));
}

test "봉인 자리가 꽉 차도 **살아 있는 사본**은 밀려나지 않는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // 링이 가리킬 수 있는 최대(64)만큼 봉인하고 전부 살아 있다고 둔다.
    var live: [64]Id = undefined;
    var buf: [32]u8 = undefined;
    for (0..64) |i| {
        const sid = std.fmt.bufPrint(&buf, "S{d}", .{i}) catch unreachable;
        try testing.expect(store.noteBefore(gpa, sid, "/r/a.zig", .edit, .empty));
        live[i] = store.seal(gpa, sid);
        try testing.expect(live[i] != 0);
    }
    // 65번째를 봉인한다 — 호출자가 이것을 «요청 중» 으로 붙들어 둘 수 있다(harvest 전까지 링에 없다).
    try testing.expect(store.noteBefore(gpa, "S-flight", "/r/b.zig", .edit, .empty));
    const in_flight = store.seal(gpa, "S-flight");
    try testing.expect(in_flight != 0);

    // **66번째**를 봉인한다 — 링 64 + 요청 중 1 이 모두 살아 있는 순간이다. `+2` 가 이 전이를 덮는다.
    try testing.expect(store.noteBefore(gpa, "S-new", "/r/c.zig", .edit, .empty));
    const fresh = store.seal(gpa, "S-new");
    try testing.expect(fresh != 0);

    // 살아 있던 65개가 **하나도 안 밀렸다** — 자리가 모자라면 `seal` 이 가장 오래된 것을 밀어내는데
    // 그것이 `live[0]` 이다. `+1` 만 두면 여기서 죽는다.
    for (live) |id| try testing.expect(store.sealedTurn(id) != null);
    try testing.expect(store.sealedTurn(in_flight) != null);
    try testing.expect(store.sealedTurn(fresh) != null);
}

test "id 는 재사용되지 않는다 — 밀려났다 돌아와도 옛 id 가 다시 나오지 않는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .empty));
    const first = store.seal(gpa, "S1");
    store.sweep(gpa, &.{}); // 밀어낸다
    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .empty));
    const second = store.seal(gpa, "S1");
    try testing.expect(second != first);
}

test "after 는 한 번만 채워진다 — 두 번째 값은 버린다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    try testing.expect(store.noteBefore(gpa, "S1", "/r/a.zig", .edit, .{ .text = try gpa.dupe(u8, "b") }));
    store.noteAfter(gpa, "S1", "/r/a.zig", .{ .text = try gpa.dupe(u8, "first") });
    store.noteAfter(gpa, "S1", "/r/a.zig", .{ .text = try gpa.dupe(u8, "second") });
    try testing.expectEqualStrings("first", store.openTurn("S1").?.entries.items[0].after.?.text);
}

test "모르는 세션의 after 는 버리되 누수하지 않는다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    store.noteAfter(gpa, "없는세션", "/r/a.zig", .{ .text = try gpa.dupe(u8, "x") });
    try testing.expectEqual(@as(usize, 0), store.heldBytes());
}

test "세션 상한을 넘는 신원은 받지 않는다 — 잘라 담으면 두 세션이 섞인다" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    const too_long = "x" ** (max_session_id_len + 1);
    try testing.expect(!store.noteBefore(gpa, too_long, "/r/a.zig", .edit, .empty));
    try testing.expect(store.openTurn(too_long) == null);
}
