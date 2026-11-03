"""외부 worker 사본의 겹치지 않는 단계 경과를 계측하고 수락한다. 제품은 변경하지 않는다."""
import re

NAMES = ('current_copy', 'prior_copy', 'leaf_copy', 'change', 'shift', 'native', 'refresh', 'summary', 'folds', 'brackets')


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('stage anchor changed: ' + old[:90])
    return text.replace(old, new)


def instrument(text):
    # 이름과 위치를 한 곳에서 정의한다. 각 구간은 순차적이며 서로 포함하지 않는다.
    def wrap(source, name, first, last=None):
        index = NAMES.index(name)
        start = f'const stage_{name}_start = workerStageNow(state);\n'
        end = f'\n        stage_values[{index}] += @intCast(workerStageNow(state) - stage_{name}_start);\n        stage_mask |= {1 << index};'
        if last is None:
            return once(source, first, start + first + end)
        source = once(source, first, start + first)
        return once(source, last, last + end)

    fields = ' '.join(f'{name}_ns={{d}}' for name in NAMES)
    values = ', '.join(f'stage_values[{i}]' for i in range(len(NAMES)))
    setup = '''        const stage_begin = workerStageNow(state);
        var stage_values: [10]u64 = @splat(0);
        var stage_mask: u16 = 0;
        defer if (self.outcome == .ready) {
            const stage_total: u64 = @intCast(workerStageNow(state) - stage_begin);
            var stage_sum: u64 = 0;
            for (stage_values) |value| stage_sum += value;
            std.debug.print("WORKER_STAGE revision={d} mode={s} mask={d} total_ns={d} FIELDS other_ns={d}\\n", .{ self.tag.input.revision, @tagName(self.mode), stage_mask, stage_total, VALUES, stage_total - stage_sum });
        };
'''.replace('FIELDS', fields).replace('VALUES', values)
    text = once(text, '        const allocator = state.options.copy_allocator;', setup + '        const allocator = state.options.copy_allocator;')
    text = wrap(text, 'current_copy', '        const bytes = self.snapshot.copyRange', '        defer allocator.free(bytes);')
    text = wrap(text, 'prior_copy', '            const old_bytes = base.snapshot.copyRange', '            defer allocator.free(old_bytes);')
    text = wrap(text, 'leaf_copy', '                self.brackets = (source.brackets.copyMatched(allocator, original.parser, original.tree_gen, parsed.parser, parsed.tree_gen) catch null) orelse .{};')
    text = wrap(text, 'change', '                const span = maru.session.editor.edit_ops.reloadChange(old_bytes, bytes);', '                    .new_end_point = syntax.pointAt(bytes, span.start + span.text.len),\n                };')
    text = wrap(text, 'shift', '                self.brackets.shift(allocator, edit.start_byte, edit.old_end_byte, edit.new_end_byte);')
    text = wrap(text, 'native', '                complete = parsed.onEditCancellable(bytes, edit, &self.cancellation) == .done;')
    # 초기 열기와 후속 편집은 같은 슬롯에 기록하지만 서로 다른 모집단이다.
    text = wrap(text, 'native', '            parsed = syntax.Provider.initCancellable(bytes, self.language, &self.cancellation) orelse {', '            complete = bytes.len == 0 or parsed.tree != null;')
    text = wrap(text, 'refresh', '                    self.brackets.refreshCancellable(allocator, &parsed, bytes, .{ .start = edit.start_byte, .end = edit.new_end_byte }, &self.cancellation) catch self.brackets.invalidate();')
    for name, call in [('summary', 'prepareStickySummary(allocator, &self.cancellation)'), ('folds', 'prepareFoldCache(allocator, &self.folds, &self.cancellation)'), ('brackets', 'prepareBracketIndex(allocator, &self.brackets, bytes, &self.cancellation)')]:
        anchor = f'        if (complete and !self.cancellation.isRequested()) parsed.{call} catch {{}};'
        text = wrap(text, name, anchor)
    return text + '\nfn workerStageNow(state: *State) i128 {\n    return std.Io.Clock.awake.now(state.io()).nanoseconds;\n}\n'


PATTERN = re.compile(r'WORKER_STAGE revision=(\d+) mode=(cold|incremental) mask=(\d+) total_ns=(\d+) ' + ' '.join(f'{name}_ns=(\\d+)' for name in NAMES) + r' other_ns=(\d+)$', re.MULTILINE)


def read(text, measures, full):
    names = ('revision', 'mode', 'mask', 'total_ns', *(name + '_ns' for name in NAMES), 'other_ns')
    rows = [dict(zip(names, [value if i == 1 else int(value) for i, value in enumerate(match)])) for match in PATTERN.findall(text)]
    if text.count('WORKER_STAGE ') != len(rows):
        raise ValueError('malformed worker stage row')
    if [row['revision'] for row in rows] != list(range(1, 22)):
        raise ValueError('missing, duplicate or unordered worker stage rows')
    for row in rows:
        if any(not 0 <= value < 2**64 for key, value in row.items() if key != 'mode'):
            raise ValueError('worker stage value overflow')
        if row['mode'] != ('cold' if row['revision'] == 1 else 'incremental'):
            raise ValueError('worker stage mode mismatch')
        if row['total_ns'] <= 0 or sum(row[name + '_ns'] for name in NAMES) + row['other_ns'] != row['total_ns']:
            raise ValueError('worker stage accounting mismatch')
        cold = row['revision'] == 1
        expected_mask = 929 if cold else (1019 if full else 1023)
        if row['mask'] != expected_mask:
            raise ValueError('worker stage call mask mismatch')
        if cold:
            if any(row[name + '_ns'] for name in ('prior_copy', 'leaf_copy', 'change', 'shift', 'refresh')):
                raise ValueError('cold row contains incremental work')
        else:
            if full and row['leaf_copy_ns'] != 0:
                raise ValueError('leaf copy branch mismatch')
            if row['total_ns'] > measures[row['revision'] - 2]['complete_ns']:
                raise ValueError('worker duration exceeds service duration')
    return rows
