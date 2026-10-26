"""첫 호출·재개·정확성 모집단을 원시 행에서 판정한다. 시간 상한으로 성공을 고르지 않는다."""
import re

SLICE = {'key', 'slice', 'ns', 'native_ns', 'range_ns', 'done'}
EDIT = {'key', 'budget_ns', 'first_ns', 'call_ns', 'max_ns', 'wall_ns', 'resumes',
        'changed_all', 'changed_len', 'oracle_nodes', 'color_ns', 'accuracy'}
STATE = {'pending_rejected', 'peer_preserved', 'resume_stamp_absent', 'restamped',
         'shared_reused', 'brackets_equal', 'folds_equal', 'owner_released'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strict(value, expected, name):
    require(type(value) is int and value == expected, 'Invalid ' + name)


def fields(text):
    result = {}
    for token in text.split(' '):
        match = re.fullmatch(r'([a-z_]+)=(0|[1-9][0-9]*)', token)
        require(match is not None, 'Invalid integer field')
        name, value = match.groups()
        require(name not in result, 'Duplicate field')
        number = int(value)
        require(number < 2**64, 'Counter exceeds u64')
        result[name] = number
    return result


def markers(text):
    rows = []
    for line in text.splitlines():
        found = re.search(r'\b(BUDGET_[A-Z]+) (.*)$', line)
        if found:
            rows.append((found[1], fields(found[2])))
    return rows


def measure(text, budget, accuracy):
    strict(budget, budget, 'budget type')
    require(budget in (0, 4000000), 'Unknown budget')
    require(type(accuracy) is int and accuracy in (0, 1), 'Unknown accuracy population')
    require(text.count('All 4 tests passed.') == 1, 'Missing complete test execution')
    slices, edits, controls, chain = [], [], [], []
    pending = []
    for kind, row in markers(text):
        if kind == 'BUDGET_SLICE':
            require(set(row) == SLICE, 'Wrong slice fields')
            require(row['key'] == len(edits) and row['slice'] == len(pending), 'Reordered or missing slice')
            require(row['done'] in (0, 1), 'Invalid slice completion')
            require(not pending or pending[-1]['done'] == 0, 'Slice after completion')
            require(row['native_ns'] + row['range_ns'] <= row['ns'], 'Unbalanced slice timing')
            pending.append(row)
            slices.append(row)
        elif kind == 'BUDGET_EDIT':
            require(set(row) == EDIT, 'Wrong edit fields')
            require(row['key'] == len(edits) and bool(pending), 'Reordered or missing edit')
            require(pending[-1]['done'] == 1, 'Edit never completed')
            require(row['budget_ns'] == budget and row['accuracy'] == accuracy, 'Wrong run population')
            require(row['resumes'] == len(pending) - 1, 'Wrong resume population')
            require(row['first_ns'] == pending[0]['ns'] and row['call_ns'] == sum(x['ns'] for x in pending)
                    and row['max_ns'] == max(x['ns'] for x in pending), 'Wrong timing aggregate')
            require(row['wall_ns'] >= row['call_ns'], 'Completion wall time excludes calls')
            require(row['changed_all'] in (0, 1), 'Invalid changed-range state')
            require((row['oracle_nodes'] > 0) if accuracy else row['oracle_nodes'] == 0, 'Missing or mixed tree oracle')
            if budget == 0:
                require(len(pending) == 1, 'Unbudgeted parse unexpectedly resumed')
            edits.append(row)
            pending = []
        elif kind == 'BUDGET_ORACLE':
            require(row == dict(normal=1, shifted_rejected=1), 'Missing native oracle control')
            controls.append(row)
        elif kind == 'BUDGET_CHAIN':
            chain.append(row)
        else:
            raise ValueError('Unknown budget marker')
    require(not pending and len(edits) == 20 and len(controls) == 1, 'Incomplete edit population')
    if accuracy:
        require(len(chain) == 3 and chain[:2] == [dict(stage=0, pending=1), dict(stage=1, pending=1)],
                'Missing real pending input chain')
        last = chain[-1]
        require(set(last) == {'stage','inverse_nodes','replacement_nodes','latest_equal'}
                and last['stage'] == 2 and last['latest_equal'] == 1
                and min(last['inverse_nodes'], last['replacement_nodes']) > 0, 'Missing latest-input oracle')
    else:
        require(chain == [dict(skipped=1)], 'Accuracy chain mixed into timing population')
    return dict(edits=edits, slices=slices, oracle_control=controls[0], pending_chain=chain)


def state(text):
    require(text.count('All 2 tests passed.') == 1, 'Missing state execution')
    rows = markers(text)
    require(len(rows) == 1 and rows[0][0] == 'BUDGET_STATE' and set(rows[0][1]) == STATE,
            'Missing syntax-state contract')
    require(all(value == 1 for value in rows[0][1].values()), 'Failed syntax-state contract')
    return rows[0][1]


def semantic_failure(text, witness):
    # 진단 출력은 test 제목 뒤에 여러 줄로 나온다. 다음 test의 실패를 가져오지 않는다.
    starts=list(re.finditer(r'(?m)^\d+/\d+ [^\n]*',text))
    for index,match in enumerate(starts):
        if witness not in match.group():
            continue
        end=starts[index+1].start() if index+1<len(starts) else len(text)
        if 'FAIL (' in text[match.start():end]:
            return True
    return False
