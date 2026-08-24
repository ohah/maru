//! 에이전트 **턴 경계 스냅샷** 정책(L2 순수, docs/editor-surface-tooling.md §6.1).
//!
//! "에이전트가 방금 바꾼 것"은 git 개념이 아니라 **턴 경계**가 있어야 성립한다. maru는 에이전트를 소유하지 않지만
//! transcript로 turn 상태(running/idle)를 이미 알므로, **running → idle 전이**를 턴 완료로 보고 그 순간의 작업트리를
//! tree OID 하나로 굳힌다(`git write-tree` — 임시 index를 써서 진짜 index·작업트리를 건드리지 않는다).
//!
//! 이 모듈은 **언제 찍고 무엇을 남길지**만 정한다. 실제 git 실행은 L4, 명령 조립은 `git_command`가 한다.
//!
//! **왜 ring buffer인가**: "마지막 턴"만 남기면 두 턴 전과 비교할 수 없고, 무한히 쌓으면 그 자체가 누수다. tree OID는
//! 40바이트짜리 이름이라 몇 개를 들고 있어도 싸다 — 대신 개수를 못 박아 상한을 코드에 둔다.

const std = @import("std");

/// 보관할 턴 스냅샷 수. 리뷰는 보통 "직전 턴"을 보지만, 에이전트가 연달아 여러 턴을 돌린 뒤 훑는 경우가 있어
/// 몇 개는 남긴다. 넘으면 가장 오래된 것부터 버린다(그 시점 tree는 git GC 대상이 되므로 붙들지 않는다).
pub const capacity: usize = 8;

/// git object id 문자열 길이(sha1 40 / sha256 64 모두 담게).
pub const max_oid_len: usize = 64;

pub const Snapshot = struct {
    /// `git write-tree` 결과. 이 tree가 그 턴이 끝난 순간의 작업트리다.
    tree: [max_oid_len]u8 = undefined,
    tree_len: usize = 0,
    /// 그 턴을 만든 세션(같은 창에 에이전트가 여럿이면 어느 쪽 턴인지 구분해야 한다).
    surface_id: u64 = 0,
    /// 그 턴이 **끝난 시각**(UNIX 초, 벽시계). 목록이 "언제"를 말하려면 필요하다 — 링은 순서만 알고
    /// 시간을 모른다. 0이면 모르는 것이고, 그때 화면은 그 자리를 비운다(1970년으로 그리지 않는다).
    captured_s: i64 = 0,
    /// 그 턴을 돌린 에이전트 종류(claude/codex/…). 값 집합은 host가 소유하므로 **정수로 받는다** —
    /// 이 모듈은 순수 층이라 그 enum을 import하지 않는다(같은 규율: `AgentState`도 값만 받는다).
    agent_kind: u8 = 0,
    /// 그 턴이 바꾼 파일 수. **`head` 스냅샷에 싣는다** — 턴은 두 스냅샷의 쌍이고 그 오른쪽이 턴의
    /// 신원이기 때문이다(선택·펼침 키도 그 쌍으로 만든다).
    changed_files: u32 = 0,
    /// 위 값을 실제로 읽었는가. **0(바꾼 것 없음)과 «아직 모름»은 다른 사실이라** 플래그로 가른다 —
    /// 하나로 합치면 읽기 전 화면이 `0개 파일` 이라고 거짓을 말한다.
    files_known: bool = false,

    pub fn oid(self: *const Snapshot) []const u8 {
        return self.tree[0..self.tree_len];
    }
};

/// 한 저장소의 턴 스냅샷 링. 할당하지 않는다 — 세션이 값으로 들고 있는다.
pub const Ring = struct {
    items: [capacity]Snapshot = @splat(.{}),
    len: usize = 0,
    /// **기록하지 못한 턴 수.** 백엔드의 스냅샷 자리가 하나라, 다른 세션의 캡처가 도는 중에 이 세션의
    /// 턴이 끝나면 그 요청이 거절되고 그 턴은 영영 안 찍힌다. 재시도는 하지 않는다 — 스냅샷 시점이
    /// 어긋나 **내용이 틀린 턴**이 되고, 그것은 없는 것보다 나쁘다. 대신 **몇 개를 놓쳤는지 화면이
    /// 말한다**(한계를 숨기지 않는다 — project-rules.md).
    missed: u32 = 0,
    /// **이 세션의 이전 기록이 축출로 사라졌다.** 밀려난 세션이 턴을 더 돌려 맵에 다시 들어오면 링이
    /// 빈 채로 새로 서는데, 그 사실을 여기 싣지 않으면 화면은 새 턴 몇 개를 **전부인 것처럼** 보인다.
    ///
    /// `missed` 와 같은 규율이다 — 그쪽이 「목록이 비어 있든 아니든 말한다」인 것과 같은 이유로, 이 값도
    /// 목록이 찬 뒤까지 남는다. 한 번 서면 그 세션이 사는 동안 안 내린다(되찾은 기록이 없으므로).
    history_evicted: bool = false,
    /// 다음에 덮어쓸 자리(가득 찼을 때).
    next: usize = 0,

    /// 스냅샷을 넣는다. **같은 tree가 연달아 오면 넣지 않는다** — 에이전트가 파일을 안 건드린 턴까지 쌓으면
    /// "마지막 턴"이 빈 비교가 되어 사용자가 "왜 아무것도 없지"를 겪는다.
    pub fn push(self: *Ring, tree_oid: []const u8, surface_id: u64, captured_s: i64, agent_kind: u8) void {
        if (tree_oid.len == 0 or tree_oid.len > max_oid_len) return;
        if (self.latest()) |last| {
            if (std.mem.eql(u8, last.oid(), tree_oid)) return;
        }
        var entry: Snapshot = .{
            .surface_id = surface_id,
            .tree_len = tree_oid.len,
            .captured_s = captured_s,
            .agent_kind = agent_kind,
        };
        @memcpy(entry.tree[0..tree_oid.len], tree_oid);
        self.items[self.next] = entry;
        self.next = (self.next + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    /// 가장 최근 스냅샷(없으면 null). "마지막 턴" 기준이 이 값이다.
    pub fn latest(self: *const Ring) ?*const Snapshot {
        if (self.len == 0) return null;
        const idx = (self.next + capacity - 1) % capacity;
        return &self.items[idx];
    }

    /// 타임라인 행 하나(§3.5.4). **비교 기준을 그대로 든다** — 화면이 그 두 값을 다시 계산하지 않게.
    pub const TimelineRow = struct {
        /// **그 세션 안에서** 몇 턴 전인가. 0 = 진행 중, 1 = 그 세션의 마지막 턴, 2 = 그 이전…
        ///
        /// **링 전역이 아니라 세션별로 센다.** 같은 저장소에서 세션이 둘 돌면 링에는 두 세션의 스냅샷이
        /// 번갈아 쌓이는데, 전역으로 세면 «2턴 전» 이 그 세션의 2턴 전이 아니다 — 사이에 낀 남의 턴이
        /// 숫자를 민다. 화면 문구가 곧 이 값이므로(`turnTitle`) 전역으로 세면 화면이 거짓을 말한다.
        back: usize,
        /// 왼쪽(옛 쪽) tree. **바로 앞 스냅샷이다** — 세션이 같은지는 보지 않는다.
        ///
        /// `back` 과 기준이 다른 것이 의도다. 비교는 **가장 좁은 구간**이어야 남의 변경이 덜 섞이는데,
        /// 같은 세션의 이전 스냅샷까지 건너뛰면 그 사이 모든 변경이 이 턴 것으로 보인다. 숫자는 세션
        /// 기준으로, 비교는 인접 기준으로 — 둘 다 각자의 자리에서 가장 정직한 선택이다.
        base: *const Snapshot,
        /// 오른쪽(새 쪽) tree. **`진행 중`은 없다**(작업트리와 비교한다).
        head: ?*const Snapshot,
        /// 이 턴을 돌린 세션. 진행 중은 «마지막 스냅샷을 남긴 세션» 이다.
        surface_id: u64,
    };

    /// 타임라인을 편다. **진행 중이 맨 위**이고, 그 아래로 완료된 턴이 최신순이다.
    ///
    /// 링이 N개면 완료된 턴은 **N−1개**다(가장 오래된 스냅샷은 짝이 될 이전 스냅샷이 없어 그 턴을
    /// 만들 수 없다 — 없는 턴을 "전부 새로 생김"으로 그리면 거짓말이다).
    ///
    /// **행을 세션으로 거르지 않는다.** 목록에서 남의 턴을 빼면 그 시간에 무슨 일이 있었는지가 사라져,
    /// 「내 턴 사이에 낀 변경」이 설명 없이 내 diff 에 나타난다. 대신 각 행이 **어느 세션인지 싣고**
    /// (`surface_id`) 번호를 세션별로 매긴다 — 숨기지 않고 구분한다.
    pub fn timeline(self: *const Ring, out: []TimelineRow) []const TimelineRow {
        var n: usize = 0;
        if (self.latest()) |head| {
            if (n < out.len) {
                // 진행 중: 마지막 스냅샷 ↔ 작업트리. 사용자가 손댄 것도 여기 든다(그게 사실이다).
                out[n] = .{ .back = 0, .base = head, .head = null, .surface_id = head.surface_id };
                n += 1;
            }
        }
        var back: usize = 0;
        while (back + 1 < self.len) : (back += 1) {
            if (n == out.len) break;
            const head = self.nth(back) orelse break;
            const base = self.nth(back + 1) orelse break;
            // 그 세션의 몇 번째 턴인가 — 이 스냅샷보다 **새로운** 같은 세션 스냅샷 수 + 1.
            // (`nth(0)` 이 가장 새 것이므로 0..back 이 «더 새로운» 구간이다.)
            var same: usize = 0;
            var newer: usize = 0;
            while (newer < back) : (newer += 1) {
                const s = self.nth(newer) orelse break;
                if (s.surface_id == head.surface_id) same += 1;
            }
            out[n] = .{ .back = same + 1, .base = base, .head = head, .surface_id = head.surface_id };
            n += 1;
        }
        return out[0..n];
    }

    /// 그 tree 를 `head` 로 하는 턴의 파일 수를 채운다. **tree OID 로 찾는다** — 결과가 도착하는
    /// 사이에 링이 밀릴 수 있고, 그때 자리로 찾으면 남의 턴에 숫자를 적는다. 못 찾으면 조용히 버린다
    /// (그 턴은 이미 화면에 없다).
    pub fn markFiles(self: *Ring, tree_oid: []const u8, count: u32) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.next + capacity - 1 - i) % capacity;
            if (std.mem.eql(u8, self.items[idx].oid(), tree_oid)) {
                self.items[idx].changed_files = count;
                self.items[idx].files_known = true;
                return;
            }
        }
    }

    /// 아직 파일 수를 모르는 턴 하나(없으면 null). **최신 턴부터** 준다 — 사용자가 보는 순서다.
    ///
    /// 화면에 서는 턴만 본다(`back + 1 < len` — `timeline` 과 같은 경계). 목록에 없는 턴을 위해
    /// 프로세스를 띄우지 않는다.
    pub const UnknownTurn = struct {
        /// 왼쪽(옛 쪽) tree.
        base: []const u8,
        /// 오른쪽(새 쪽) tree. **결과를 이 tree 에 적는다**(`markFiles`).
        head: []const u8,
    };

    pub fn nextUnknownFiles(self: *const Ring) ?UnknownTurn {
        var back: usize = 0;
        while (back + 1 < self.len) : (back += 1) {
            const head = self.nth(back) orelse return null;
            const base = self.nth(back + 1) orelse return null;
            if (!head.files_known) return .{ .base = base.oid(), .head = head.oid() };
        }
        return null;
    }

    /// `back`턴 전 스냅샷(0=마지막). 범위를 벗어나면 null — 없는 턴을 0번째로 접지 않는다.
    pub fn nth(self: *const Ring, back: usize) ?*const Snapshot {
        if (back >= self.len) return null;
        const idx = (self.next + capacity - 1 - back) % capacity;
        return &self.items[idx];
    }
};

/// 동시에 기억하는 **세션 수**. 링이 세션당 하나이므로 이 값이 곧 «몇 세션까지 되짚을 수 있나» 다.
///
/// Term 이 링을 소유하던 때는 `destroyTerm` 이 정리를 공짜로 해 줬지만, 키가 세션 id 가 되면서 **아무도
/// 안 지운다** — 그래서 상한이 필요하다(계약 §6.1). 넘으면 **가장 오래 안 쓴 세션**부터 버린다.
///
/// ⚠️ **«동시 세션 8개» 가 아니라 «최근 세션 신원 8개» 다.** `/clear` 는 provider 세션을 새로 시작해 **새 id 를
/// 발급하므로**(같은 프로세스가 새 id 를 내려준다 — `refreshAgentSessionIdentity`), 터미널 하나에서만 일해도 여덟 번 지우면 가장 오래된 기록이 밀린다.
/// 밀리는 것 자체는 계약이 정한 동작이고, **말없이 밀리지 않는다** — `evicted` 가 그 신원을 남겨 화면이
/// 「밀려났다」와 「원래 없었다」를 갈라 말한다.
pub const max_sessions: usize = 8;

/// 자취를 남길 **밀려난 신원 수**. 링을 들지 않고 id 만 남기므로(64 B 남짓) 세션 수와 같은 값으로 둔다 —
/// 밀린 직후가 가장 헷갈리는 구간이고, 그보다 더 오래된 것까지 기억해야 할 이유는 아직 없다.
pub const max_evicted: usize = max_sessions;

/// provider 세션 신원 문자열의 상한. claude·codex 둘 다 UUID(36자)지만 여유를 둔다.
pub const max_session_id_len: usize = 64;

/// 세션이 기억하는 저장소 경로의 상한. 넘는 경로는 **기억하지 않는다**(그 세션은 저장소 전환을 감지하지
/// 못하고 링을 유지한다 — 잘라 담으면 다른 저장소를 같다고 볼 수 있어 그쪽이 더 나쁘다).
pub const max_repo_len: usize = 512;

/// 세션 id → 링. **할당하지 않는다** — 고정 배열이라 세션이 값으로 들고 있는다(`Ring` 과 같은 규율).
///
/// **키가 하나다**(계약 §6.1). 살아 있는 동안은 `surface_id`, 영속할 땐 세션 id 로 키가 둘이던 이원성을
/// 없앤 자리다. 그래서 한 터미널에서 에이전트를 갈아타도 키가 달라 자동으로 갈리고, 앱을 재시작해
/// `surface_id` 가 재발급돼도 같은 키이며, `--resume` 이 Term 을 새로 만들어도 그 링을 찾는다.
pub const RingMap = struct {
    pub const Entry = struct {
        id: [max_session_id_len]u8 = undefined,
        id_len: usize = 0,
        ring: Ring = .{},
        /// 그 세션이 마지막으로 보던 저장소. **저장소 축은 세션 안에 남는다**(계약 §6.1) — 한 세션이
        /// `cd` 로 옮기면 그 링만 비운다. 다른 저장소의 tree 로 비교하면 전부 삭제로 보이기 때문이고,
        /// 초판과 달라진 것은 그 범위가 전역이 아니라 세션이라는 점뿐이다.
        repo: [max_repo_len]u8 = undefined,
        repo_len: usize = 0,
        /// 마지막으로 쓰인 순서(단조 증가). 0이면 빈 자리다. **시계가 아니라 카운터**인 이유는 순수
        /// 층이라 시각을 모르기 때문이다 — 축출은 «오래된 시각» 이 아니라 «오래 안 쓴 순서» 로 정한다.
        used: u64 = 0,

        pub fn sessionId(self: *const Entry) []const u8 {
            return self.id[0..self.id_len];
        }

        pub fn repoPath(self: *const Entry) []const u8 {
            return self.repo[0..self.repo_len];
        }
    };

    /// 밀려난 세션의 **신원만** 담는 자리. 링은 담지 않는다 — 기록을 되살릴 수는 없고, 되살릴 수 없다는
    /// 사실을 말할 수만 있다.
    const Id = struct {
        buf: [max_session_id_len]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Id) []const u8 {
            return self.buf[0..self.len];
        }
    };

    entries: [max_sessions]Entry = @splat(.{}),
    /// 다음에 찍을 사용 순서. 단조 증가라 넘칠 걱정이 없다(u64).
    tick: u64 = 0,
    /// **밀려난 신원의 자취**(원형 버퍼). 슬롯을 통째로 덮으면 그 세션의 턴 기록과 `missed` 가 함께
    /// 사라지는데, 자취가 없으면 화면은 「밀려났다」를 「원래 없었다」로 말한다 — `Ring.missed` 가 한 층
    /// 위에서 막는 것과 **같은 실패 방식**이라 같은 규율로 막는다(한계를 숨기지 않는다 — project-rules.md).
    ///
    /// 자취도 `max_evicted` 를 넘으면 오래된 것부터 잊는다. 그때는 다시 「원래 없었다」로 보이지만, 밀려난
    /// 뒤로 이미 그만큼의 다른 세션이 지난 뒤다.
    evicted: [max_evicted]Id = @splat(.{}),
    /// 다음에 자취를 쓸 자리.
    evicted_next: usize = 0,

    /// 그 세션의 링(**없으면 만든다**). 자리가 없으면 가장 오래 안 쓴 것을 버리고 그 자리를 쓴다.
    ///
    /// 빈 id 는 거절한다 — 신원 없는 세션은 링을 갖지 않는다(계약 §6.1: 확실히 알 수 없으면 말하지 않는다).
    pub fn ringFor(self: *RingMap, session_id: []const u8, repo: []const u8) ?*Ring {
        if (session_id.len == 0 or session_id.len > max_session_id_len) return null;
        self.tick +|= 1;
        if (self.findEntry(session_id)) |e| {
            e.used = self.tick;
            // **저장소가 바뀌었으면 그 세션의 링만 비운다.** 경로가 상한을 넘어 기억하지 못한 경우
            // (`repo_len == 0`)는 비교할 근거가 없으므로 건드리지 않는다.
            if (e.repo_len != 0 and repo.len != 0 and !std.mem.eql(u8, e.repoPath(), repo)) {
                // 링은 비우되 **밀렸다는 사실은 남긴다** — 그 손실은 저장소와 무관하고, 여기서 지우면
                // `cd` 한 번에 화면이 다시 조용해진다.
                const evicted_before = e.ring.history_evicted;
                e.ring = .{ .history_evicted = evicted_before };
                e.repo_len = 0;
            }
            if (e.repo_len == 0) setRepo(e, repo);
            return &e.ring;
        }
        const slot = self.victim();
        // **덮기 전에** 자취를 남긴다 — 슬롯을 덮고 나면 그 세션이 여기 있었다는 사실을 아는 자리가 없다.
        if (slot.used != 0) self.noteEvicted(slot.sessionId());
        // 전에 밀렸던 신원이 다시 들어왔다 — 자취는 **지우고 그 사실은 링으로 옮긴다**. 자취를 남겨 두면
        // 화면이 「밀려났다」와 「지금 여기 있다」를 동시에 말하고, 그냥 지우면 새 턴이 쌓인 뒤 잃은
        // 기록을 **영영 말하지 못한다**(`Ring.history_evicted`).
        const returning = self.forgetEvicted(session_id);
        slot.* = .{ .id_len = session_id.len, .used = self.tick };
        @memcpy(slot.id[0..session_id.len], session_id);
        setRepo(slot, repo);
        slot.ring.history_evicted = returning;
        return &slot.ring;
    }

    fn setRepo(e: *Entry, repo: []const u8) void {
        if (repo.len == 0 or repo.len > max_repo_len) return; // 못 담으면 아예 기억하지 않는다
        @memcpy(e.repo[0..repo.len], repo);
        e.repo_len = repo.len;
    }

    /// 그 세션의 링(**만들지 않는다**). 화면이 쓴다 — 그리기만 하는 자리가 맵을 늘리면 안 된다.
    pub fn find(self: *const RingMap, session_id: []const u8) ?*const Ring {
        if (session_id.len == 0) return null;
        for (&self.entries) |*e| {
            if (e.used == 0) continue;
            if (std.mem.eql(u8, e.sessionId(), session_id)) return &e.ring;
        }
        return null;
    }

    /// `find` 의 쓰기 변형. **결과가 늦게 도착하는 자리**가 쓴다 — 요청할 때 기억해 둔 세션 id 로
    /// 되찾아 적는다(그 사이 활성 세션이 바뀌어도 남의 링에 적지 않는다).
    pub fn findMut(self: *RingMap, session_id: []const u8) ?*Ring {
        if (session_id.len == 0) return null;
        for (&self.entries) |*e| {
            if (e.used == 0) continue;
            if (std.mem.eql(u8, e.sessionId(), session_id)) return &e.ring;
        }
        return null;
    }

    /// 그 세션이 마지막으로 보던 저장소(모르면 빈 슬라이스). 소비 쪽이 «지금 이 저장소가 맞나» 를
    /// 확인할 때 쓴다 — 링을 비우는 판정은 `ringFor` 가 이미 했고, 여기서는 읽기만 한다.
    pub fn repoFor(self: *const RingMap, session_id: []const u8) []const u8 {
        if (session_id.len == 0) return "";
        for (&self.entries) |*e| {
            if (e.used == 0) continue;
            if (std.mem.eql(u8, e.sessionId(), session_id)) return e.repoPath();
        }
        return "";
    }

    /// 지금 들고 있는 세션 수.
    pub fn len(self: *const RingMap) usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            if (e.used != 0) n += 1;
        }
        return n;
    }

    fn findEntry(self: *RingMap, session_id: []const u8) ?*Entry {
        for (&self.entries) |*e| {
            if (e.used == 0) continue;
            if (std.mem.eql(u8, e.sessionId(), session_id)) return e;
        }
        return null;
    }

    /// 빈 자리, 없으면 **가장 오래 안 쓴** 자리.
    fn victim(self: *RingMap) *Entry {
        var oldest: *Entry = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.used == 0) return e;
            if (e.used < oldest.used) oldest = e;
        }
        return oldest;
    }

    /// 그 세션이 **밀려나서** 없는가. `find` 가 null 을 준 자리가 «왜 없나» 를 물을 때 쓴다 — 화면이
    /// 「관측한 턴이 없다」와 「있었는데 밀려났다」를 갈라 말하는 유일한 근거다.
    ///
    /// 지금 맵에 있는 세션은 거짓이다(다시 들어올 때 자취를 지운다). 따라서 `find` 와 함께 물어도 두 답이
    /// 어긋나지 않는다.
    pub fn wasEvicted(self: *const RingMap, session_id: []const u8) bool {
        if (session_id.len == 0) return false;
        return self.evictedIndex(session_id) != null;
    }

    /// 밀려난 신원을 자취에 남긴다. **이미 있으면 다시 넣지 않는다** — 같은 신원이 두 자리를 먹으면 남의
    /// 자취를 대신 밀어낸다.
    fn noteEvicted(self: *RingMap, session_id: []const u8) void {
        if (session_id.len == 0 or session_id.len > max_session_id_len) return;
        if (self.evictedIndex(session_id) != null) return;
        const e = &self.evicted[self.evicted_next];
        @memcpy(e.buf[0..session_id.len], session_id);
        e.len = session_id.len;
        self.evicted_next = (self.evicted_next + 1) % max_evicted;
    }

    /// 그 신원의 자취를 지우고 **있었는지**를 답한다. 호출자가 그 사실을 새 링으로 옮긴다.
    fn forgetEvicted(self: *RingMap, session_id: []const u8) bool {
        const i = self.evictedIndex(session_id) orelse return false;
        self.evicted[i].len = 0;
        return true;
    }

    fn evictedIndex(self: *const RingMap, session_id: []const u8) ?usize {
        for (&self.evicted, 0..) |*e, i| {
            if (e.len == 0) continue;
            if (std.mem.eql(u8, e.slice(), session_id)) return i;
        }
        return null;
    }
};

/// 상태 전이가 **턴 완료**인가. `running` → `idle`만 완료다.
///
/// **`blocked`는 완료가 아니다.** 에이전트가 사용자에게 묻느라 멈춘 것이지 턴이 끝난 게 아니고, 답하면 이어서
/// 같은 턴을 계속한다. 여기서 찍으면 "마지막 턴"이 "마지막 질문 이후"라는 다른 뜻이 된다(그것대로 쓸모는 있지만
/// §6.1이 말하는 턴 경계가 아니다 — 필요해지면 별도 기준으로 추가할 일이다).
///
/// **`unknown`도 완료가 아니다.** 화면을 못 읽는 상태라 "안 돌고 있다"가 아니라 "모른다"이고, 그걸 턴 끝으로
/// 삼으면 에이전트가 도는 중에 스냅샷이 찍혀 기준이 턴 중간으로 어긋난다.
pub fn isTurnEnd(previous: AgentState, current: AgentState) bool {
    if (previous != .running) return false;
    return switch (current) {
        .idle => true,
        .running, .blocked, .unknown => false,
    };
}

/// `agent_observer.State`와 **같은 값 집합**(이 모듈은 순수라 그쪽을 import하지 않고 값만 받는다).
/// 값이 갈리면 platform의 변환 함수가 컴파일에서 걸린다(exhaustive switch).
pub const AgentState = enum { unknown, running, blocked, idle };

const testing = std.testing;

test "running → idle만 턴 완료다(blocked·unknown은 아니다)" {
    try testing.expect(isTurnEnd(.running, .idle));
    // 사용자에게 묻느라 멈춘 것은 턴이 끝난 게 아니다 — 답하면 같은 턴이 이어진다.
    try testing.expect(!isTurnEnd(.running, .blocked));
    try testing.expect(!isTurnEnd(.running, .running));
    // unknown은 "안 돈다"가 아니라 "모른다" — 여기서 찍으면 턴 중간이 기준이 된다.
    try testing.expect(!isTurnEnd(.running, .unknown));
    // 애초에 안 돌던 상태에서의 전이는 턴이 아니다.
    try testing.expect(!isTurnEnd(.idle, .idle));
    try testing.expect(!isTurnEnd(.unknown, .idle));
}

test "링은 최근 것부터 되짚고 상한을 넘으면 오래된 것을 버린다" {
    var ring: Ring = .{};
    try testing.expect(ring.latest() == null);
    try testing.expect(ring.nth(0) == null);

    ring.push("aaa1", 1, 0, 0);
    ring.push("bbb2", 1, 0, 0);
    try testing.expectEqualStrings("bbb2", ring.latest().?.oid());
    try testing.expectEqualStrings("aaa1", ring.nth(1).?.oid());
    try testing.expect(ring.nth(2) == null); // 없는 턴을 0번째로 접지 않는다

    // 상한을 넘겨 채우면 가장 오래된 것부터 사라진다.
    for (0..capacity + 3) |i| {
        var buf: [8]u8 = undefined;
        ring.push(std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable, 2, 0, 0);
    }
    try testing.expectEqual(capacity, ring.len);
    try testing.expectEqualStrings("t10", ring.latest().?.oid());
    try testing.expect(ring.nth(capacity) == null);
}

test "같은 tree가 연달아 오면 넣지 않는다(빈 비교를 만들지 않으려고)" {
    var ring: Ring = .{};
    ring.push("same", 1, 0, 0);
    ring.push("same", 1, 0, 0);
    try testing.expectEqual(@as(usize, 1), ring.len);
    // 다른 tree가 오면 정상적으로 쌓이고, 그 뒤 같은 값이 또 와도 안 쌓인다.
    ring.push("other", 1, 0, 0);
    ring.push("other", 1, 0, 0);
    try testing.expectEqual(@as(usize, 2), ring.len);
}

test "빈 oid나 너무 긴 oid는 무시한다" {
    var ring: Ring = .{};
    ring.push("", 1, 0, 0);
    ring.push("x" ** (max_oid_len + 1), 1, 0, 0);
    try testing.expectEqual(@as(usize, 0), ring.len);
}

test "타임라인: 진행 중이 맨 위이고 완료된 턴은 N−1개다" {
    // 가장 오래된 스냅샷은 짝이 될 이전 스냅샷이 없다 — 그 턴을 "전부 새로 생김"으로 그리면 거짓말이다.
    var ring: Ring = .{};
    ring.push("aaaa111", 1, 100, 0);
    ring.push("bbbb222", 1, 200, 0);
    ring.push("cccc333", 2, 300, 1);

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 3), rows.len); // 진행 중 + 턴 둘

    // ① 진행 중: 마지막 스냅샷 ↔ 작업트리(오른쪽 없음).
    try std.testing.expectEqual(@as(usize, 0), rows[0].back);
    try std.testing.expectEqualStrings("cccc333", rows[0].base.oid());
    try std.testing.expect(rows[0].head == null);

    // ② 마지막 턴: [1] ↔ [0] — **양쪽 다 tree라 고정**이다.
    try std.testing.expectEqual(@as(usize, 1), rows[1].back);
    try std.testing.expectEqualStrings("bbbb222", rows[1].base.oid());
    try std.testing.expectEqualStrings("cccc333", rows[1].head.?.oid());
    // 그 턴을 만든 에이전트·시각은 **오른쪽**(그 턴이 끝난 순간)이 든다.
    try std.testing.expectEqual(@as(i64, 300), rows[1].head.?.captured_s);
    try std.testing.expectEqual(@as(u8, 1), rows[1].head.?.agent_kind);

    // ③ 그 이전 턴.
    try std.testing.expectEqualStrings("aaaa111", rows[2].base.oid());
    try std.testing.expectEqualStrings("bbbb222", rows[2].head.?.oid());
}

test "타임라인: 스냅샷이 하나면 완료된 턴이 없다(진행 중만)" {
    var ring: Ring = .{};
    ring.push("aaaa111", 1, 100, 0);
    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].head == null);
}

test "타임라인: 링이 비면 행도 없다(오류가 아니다)" {
    // 이번 실행에서 관측한 턴이 없다 — 앱을 막 켠 정상 상태다.
    const ring: Ring = .{};
    var buf: [8]Ring.TimelineRow = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.timeline(&buf).len);
}

test "타임라인: 상한을 넘겨도 out 크기까지만 채운다" {
    var ring: Ring = .{};
    var i: u8 = 0;
    while (i < capacity) : (i += 1) {
        var oid_buf: [8]u8 = undefined;
        const oid_str = std.fmt.bufPrint(&oid_buf, "tree{d:0>3}", .{i}) catch unreachable;
        ring.push(oid_str, 1, @intCast(i), 0);
    }
    var small: [3]Ring.TimelineRow = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.timeline(&small).len);
}

test "타임라인: `N턴 전`은 그 세션 기준이다(남의 턴이 숫자를 밀지 않는다)" {
    // 같은 저장소를 세션 둘이 번갈아 쓰는 상황. 링 전역으로 세면 A 의 두 번째 턴이 «3턴 전» 이 되는데,
    // 그 사용자에게 그것은 자기 2턴 전이다 — 화면 문구가 곧 이 값이라 전역으로 세면 화면이 거짓을 말한다.
    var ring: Ring = .{};
    ring.push("a1", 1, 100, 1); // A
    ring.push("b1", 2, 200, 2); // B
    ring.push("a2", 1, 300, 1); // A
    ring.push("b2", 2, 400, 2); // B
    ring.push("a3", 1, 500, 1); // A

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 5), rows.len); // 진행 중 + 완료 4

    // 진행 중은 마지막 스냅샷을 남긴 세션의 것이다.
    try std.testing.expectEqual(@as(u64, 1), rows[0].surface_id);

    // 완료된 턴들: 최신순으로 a3(A) · b2(B) · a2(A) · b1(B).
    try std.testing.expectEqual(@as(u64, 1), rows[1].surface_id);
    try std.testing.expectEqual(@as(usize, 1), rows[1].back); // A 의 마지막 턴
    try std.testing.expectEqual(@as(u64, 2), rows[2].surface_id);
    try std.testing.expectEqual(@as(usize, 1), rows[2].back); // **B 의 마지막 턴도 1이다**
    try std.testing.expectEqual(@as(u64, 1), rows[3].surface_id);
    try std.testing.expectEqual(@as(usize, 2), rows[3].back); // A 의 2턴 전(전역이면 3이었다)
    try std.testing.expectEqual(@as(u64, 2), rows[4].surface_id);
    try std.testing.expectEqual(@as(usize, 2), rows[4].back); // B 의 2턴 전

    // **비교 구간은 인접 스냅샷 그대로다** — 세션이 같은 이전 스냅샷까지 건너뛰면 그 사이 남의 변경이
    // 전부 이 턴 것으로 보인다. 숫자는 세션 기준, 비교는 인접 기준.
    try std.testing.expectEqualStrings("b2", rows[1].base.oid());
    try std.testing.expectEqualStrings("a3", rows[1].head.?.oid());
}

test "타임라인: 세션이 하나면 `N턴 전`이 링 순서와 같다(회귀 없음)" {
    var ring: Ring = .{};
    ring.push("s1", 7, 100, 1);
    ring.push("s2", 7, 200, 1);
    ring.push("s3", 7, 300, 1);

    var buf: [8]Ring.TimelineRow = undefined;
    const rows = ring.timeline(&buf);
    try std.testing.expectEqual(@as(usize, 1), rows[1].back);
    try std.testing.expectEqual(@as(usize, 2), rows[2].back);
    try std.testing.expectEqual(@as(u64, 7), rows[2].surface_id);
}

test "턴 파일 수: 모르는 턴을 최신부터 하나씩 주고, 채우면 다음으로 넘어간다" {
    var ring: Ring = .{};
    ring.push("t1", 1, 100, 1);
    ring.push("t2", 1, 200, 1);
    ring.push("t3", 1, 300, 1);

    // 최신 턴(head=t3)이 먼저다 — 사용자가 보는 순서.
    const first = ring.nextUnknownFiles().?;
    try std.testing.expectEqualStrings("t2", first.base);
    try std.testing.expectEqualStrings("t3", first.head);

    ring.markFiles("t3", 5);
    const second = ring.nextUnknownFiles().?;
    try std.testing.expectEqualStrings("t1", second.base);
    try std.testing.expectEqualStrings("t2", second.head);

    ring.markFiles("t2", 0);
    try std.testing.expect(ring.nextUnknownFiles() == null); // 화면에 서는 턴을 다 채웠다

    // 가장 오래된 t1 은 `head` 로 서지 않으므로 영영 묻지 않는다(목록에 그 줄이 없다).
    try std.testing.expect(!ring.nth(2).?.files_known);
}

test "턴 파일 수: tree OID 로 찾아 적는다(결과가 늦게 와도 남의 턴을 안 건드린다)" {
    var ring: Ring = .{};
    ring.push("aaa", 1, 100, 1);
    ring.push("bbb", 1, 200, 1);

    // 링에 없는 tree 로 오면 조용히 버린다 — 그 턴은 이미 화면에 없다.
    ring.markFiles("zzz", 9);
    try std.testing.expect(!ring.nth(0).?.files_known);

    ring.markFiles("bbb", 3);
    try std.testing.expect(ring.nth(0).?.files_known);
    try std.testing.expectEqual(@as(u32, 3), ring.nth(0).?.changed_files);
    // 0 도 «읽었다» 다 — «아직 모름» 과 구별된다.
    ring.markFiles("aaa", 0);
    try std.testing.expect(ring.nth(1).?.files_known);
    try std.testing.expectEqual(@as(u32, 0), ring.nth(1).?.changed_files);
}

test "세션 맵: 같은 id 는 같은 링을 주고, 새 id 는 새 링을 만든다" {
    var map: RingMap = .{};
    try std.testing.expectEqual(@as(usize, 0), map.len());

    const a = map.ringFor("sess-a", "/repo").?;
    a.push("t1", 1, 100, 1);
    const a_again = map.ringFor("sess-a", "/repo").?;
    try std.testing.expectEqual(@as(usize, 1), a_again.len); // 같은 링이다
    try std.testing.expectEqual(@as(usize, 1), map.len());

    const b = map.ringFor("sess-b", "/repo").?;
    try std.testing.expectEqual(@as(usize, 0), b.len); // 새 링이라 비어 있다
    try std.testing.expectEqual(@as(usize, 2), map.len());
}

test "세션 맵: 신원이 없으면 링을 만들지 않는다(확실히 알 수 없으면 말하지 않는다)" {
    var map: RingMap = .{};
    try std.testing.expect(map.ringFor("", "/repo") == null);
    try std.testing.expectEqual(@as(usize, 0), map.len());

    var too_long: [max_session_id_len + 1]u8 = @splat('x');
    try std.testing.expect(map.ringFor(&too_long, "/repo") == null);
}

test "세션 맵: `find` 는 만들지 않는다(그리기만 하는 자리가 맵을 늘리면 안 된다)" {
    var map: RingMap = .{};
    try std.testing.expect(map.find("sess-a") == null);
    try std.testing.expectEqual(@as(usize, 0), map.len());

    _ = map.ringFor("sess-a", "/repo");
    try std.testing.expect(map.find("sess-a") != null);
}

test "세션 맵: 상한을 넘으면 가장 오래 안 쓴 세션부터 버린다" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        _ = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
    }
    try std.testing.expectEqual(max_sessions, map.len());

    // `s0` 를 다시 써서 **가장 최근**으로 만든다 — 그러면 다음 축출 대상은 `s1` 이다.
    _ = map.ringFor("s0", "/repo").?;
    _ = map.ringFor("newcomer", "/repo").?;

    try std.testing.expectEqual(max_sessions, map.len()); // 늘지 않는다
    try std.testing.expect(map.find("s0") != null); // 방금 썼으니 살아 있다
    try std.testing.expect(map.find("s1") == null); // 가장 오래 안 쓴 것이 밀렸다
    try std.testing.expect(map.find("newcomer") != null);
}

test "세션 맵: 밀려난 자리는 옛 링을 물려주지 않는다" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        const r = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
        r.push("tree", 1, 100, 1); // 전부 스냅샷 하나씩
    }
    const fresh = map.ringFor("newcomer", "/repo").?;
    try std.testing.expectEqual(@as(usize, 0), fresh.len); // 옛 세션의 턴이 새 세션에 붙지 않는다
}

test "세션 맵: 밀려난 세션은 «밀려났다» 고 말한다(«원래 없었다» 와 구별한다)" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        const r = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
        r.push("tree", 1, 100, 1);
    }
    _ = map.ringFor("newcomer", "/repo").?; // `s0` 이 밀린다

    try std.testing.expect(map.find("s0") == null); // 기록은 되살릴 수 없다
    try std.testing.expect(map.wasEvicted("s0")); // 없어진 **이유**는 남는다
    try std.testing.expect(!map.wasEvicted("한번도-없던-세션")); // 원래 없던 것은 밀린 것이 아니다
    try std.testing.expect(!map.wasEvicted("newcomer")); // 지금 여기 있는 것도 아니다
    try std.testing.expect(!map.wasEvicted("")); // 신원 없는 세션은 링을 가진 적이 없다
}

test "세션 맵: 밀렸던 세션이 다시 들어오면 자취를 지운다" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        _ = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
    }
    _ = map.ringFor("newcomer", "/repo").?; // `s0` 이 밀린다
    try std.testing.expect(map.wasEvicted("s0"));

    const back = map.ringFor("s0", "/repo").?; // 그 세션이 턴을 하나 더 돌렸다
    try std.testing.expect(map.find("s0") != null);
    try std.testing.expect(!map.wasEvicted("s0")); // 「밀려났다」와 「지금 여기 있다」를 동시에 말하지 않는다
    // **자취는 지우되 사실은 링으로 옮긴다.** 안 옮기면 새 턴이 쌓인 뒤 잃은 기록을 영영 말하지 못한다.
    try std.testing.expect(back.history_evicted);

    back.push("tree", 1, 100, 1); // 목록이 다시 차도 그 사실은 안 내린다
    try std.testing.expect(map.find("s0").?.history_evicted);
}

test "세션 맵: 한 번도 안 밀린 세션의 링은 «밀렸다» 고 말하지 않는다" {
    var map: RingMap = .{};
    const fresh = map.ringFor("only", "/repo").?;
    try std.testing.expect(!fresh.history_evicted);
}

test "세션 맵: 저장소를 옮겨 링을 비워도 «밀렸다» 는 남는다" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        _ = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
    }
    _ = map.ringFor("newcomer", "/repo").?; // `s0` 이 밀린다
    const back = map.ringFor("s0", "/repo").?;
    back.push("tree", 1, 100, 1);
    try std.testing.expect(back.history_evicted);

    const moved = map.ringFor("s0", "/other").?; // 그 세션이 `cd` 했다
    try std.testing.expectEqual(@as(usize, 0), moved.len); // 링은 비운다(기존 계약)
    try std.testing.expect(moved.history_evicted); // 손실은 저장소와 무관하다 — `cd` 로 조용해지지 않는다
}

test "세션 맵: 자취도 상한이 있다(가장 오래된 자취부터 잊는다)" {
    var map: RingMap = .{};
    var i: usize = 0;
    while (i < max_sessions) : (i += 1) {
        var buf: [8]u8 = undefined;
        _ = map.ringFor(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, "/repo").?;
    }
    // `s0`~`s7` 을 차례로 밀어내 자취를 가득 채운다.
    i = 0;
    while (i < max_evicted) : (i += 1) {
        var buf: [8]u8 = undefined;
        _ = map.ringFor(std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable, "/repo").?;
    }
    try std.testing.expect(map.wasEvicted("s0"));

    _ = map.ringFor("last", "/repo").?; // `n0` 이 밀리며 가장 오래된 자취(`s0`)를 덮는다
    try std.testing.expect(map.wasEvicted("n0"));
    try std.testing.expect(!map.wasEvicted("s0")); // 자취까지 잊으면 다시 «원래 없었다» 로 보인다
}

test "세션 맵: 그 세션이 저장소를 옮기면 그 링만 비운다(다른 세션은 그대로)" {
    var map: RingMap = .{};
    const a = map.ringFor("sess-a", "/repo/one").?;
    a.push("t1", 1, 100, 1);
    const b = map.ringFor("sess-b", "/repo/one").?;
    b.push("t2", 2, 200, 1);

    // A 가 다른 저장소로 옮겼다 — 그 tree 로 비교하면 전부 삭제로 보인다.
    const a2 = map.ringFor("sess-a", "/repo/two").?;
    try std.testing.expectEqual(@as(usize, 0), a2.len);
    // B 는 건드리지 않는다(초판과 달라진 점이 정확히 이것이다).
    try std.testing.expectEqual(@as(usize, 1), map.find("sess-b").?.len);

    // 같은 저장소로 다시 물으면 비우지 않는다.
    a2.push("t3", 1, 300, 1);
    const a3 = map.ringFor("sess-a", "/repo/two").?;
    try std.testing.expectEqual(@as(usize, 1), a3.len);
}

test "세션 맵: 저장소 경로가 상한을 넘으면 기억하지 않고 링도 안 비운다" {
    var map: RingMap = .{};
    var long: [max_repo_len + 1]u8 = @splat('p');
    const r = map.ringFor("sess", &long).?;
    r.push("t1", 1, 100, 1);
    // 기억하지 못했으므로 «바뀌었다» 를 판정할 근거가 없다 — 잘라 담아 남의 저장소를 같다고 보는 것보다 낫다.
    const again = map.ringFor("sess", "/other").?;
    try std.testing.expectEqual(@as(usize, 1), again.len);
}
