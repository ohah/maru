#!/usr/bin/env python3
"""원본 Git·실험 사본·생산자·바이너리·40개 로그를 대조한다."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile

import contract
from run import FIXTURES, FOLDERS, ROOT, inventory, sha, write


def load(path):
    return json.loads(path.read_text())


def digest(path, value):
    contract.require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None and sha(path) == value,
                     'File hash differs: ' + path.name)


def git_sources(head):
    contract.require(type(head) is str and re.fullmatch('[0-9a-f]{40}', head) is not None, 'Invalid source head')
    child = subprocess.Popen(['git','archive',head,'src','build.zig','build.zig.zon'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    result = {}
    with tarfile.open(fileobj=child.stdout, mode='r|') as archive:
        for member in archive:
            if member.isfile():
                result[member.name] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    error = child.stderr.read()
    contract.require(child.wait() == 0, 'Cannot read original Git source: ' + error.decode(errors='replace'))
    return result


def verify(out, expected_head):
    result = load(out / 'result.json')
    contract.strict(result.get('schema'), 1, 'schema')
    contract.strict(result.get('processes'), 40, 'process population')
    contract.strict(result.get('performance_inputs'), 600, 'performance population')
    contract.strict(result.get('accuracy_inputs'), 200, 'accuracy population')
    contract.require(result.get('complete') is True and result.get('kind') == 'native-edit-budget'
                     and result.get('head') == expected_head, 'Incomplete or wrong dataset')
    digest(out / 'producer.json', result.get('producer_sha256'))
    digest(out / 'source.json', result.get('source_sha256'))
    producer, source = load(out / 'producer.json'), load(out / 'source.json')
    contract.require(producer['head'] == source['head'] == expected_head, 'Mixed source heads')
    contract.require(source['original'] == git_sources(expected_head), 'Original product differs from Git')
    contract.require(source['instrumented'] == inventory(out / 'source-1'), 'Instrumented product differs')
    # src 바깥의 실제 빌드 입력도 핀한 Git과 대조한다. 이 두 파일은 실험 변환 대상이 아니다.
    build_inputs={}
    for name in ('tools/simple_test_runner.zig','.mise.toml'):
        original=subprocess.check_output(['git','show',expected_head+':'+name],cwd=ROOT)
        expected=hashlib.sha256(original).hexdigest()
        digest(out/'source-1'/name,expected)
        build_inputs[name]=expected
    required = {'tools/editor-parse-budget/' + name for name in ('run.py','prepare.py','probe.zig.inc','state.zig.inc')}
    required |= {str(p.relative_to(ROOT)) for folder in FOLDERS[1:] for p in (ROOT/'tools'/folder).rglob('*')
                 if p.is_file() and p.suffix in ('.py','.inc')}
    contract.require(required <= set(producer['tools_sha256']), 'Missing executed producer dependency')
    for name, value in producer['tools_sha256'].items():
        contract.require(name.startswith('tools/') and '..' not in Path(name).parts, 'Invalid tool snapshot path')
        digest(out / 'tool-snapshot' / name, value)
    contract.require(set(producer['inputs']) == set(FIXTURES), 'Wrong fixed fixtures')
    for name, info in producer['inputs'].items():
        digest(out / 'fixtures' / name, info['sha256'])
        contract.strict(info['bytes'], (out/'fixtures'/name).stat().st_size, 'fixture byte size')
    contract.require(set(result['binaries']) == {'measure','state'}, 'Missing selected binary')
    for name, tests in [('measure',4),('state',2)]:
        contract.strict(result['binaries'][name]['tests'], tests, 'selected tests')
        digest(out / ('archived-'+name), result['binaries'][name]['sha256'])
        digest(out / f'build-{name}.log', result['build_logs_sha256'][name])
        wanted = ['mise','exec','--','zig','build','test-native-budget-'+('measure' if name=='measure' else 'state'),
                  '-Doptimize=ReleaseFast','-j2','--verbose']
        contract.require(result['build_commands'][name] == wanted, 'Wrong build target')
    # 서로 다른 root/filter로 만든 두 실행 파일을 같은 사본으로 바꾸고 해시까지 고친 경우도 거절한다.
    contract.require(result['binaries']['measure']['sha256'] != result['binaries']['state']['sha256'],
                     'Measurement and state binaries must differ')
    state_report = contract.state((out/'build-state.log').read_text())
    wanted = {f'run-{accuracy}-{rep}-{name}-{budget}': (accuracy,rep,name,budget)
              for accuracy,reps in [(0,3),(1,1)] for rep in range(reps) for name in FIXTURES for budget in (0,4000000)}
    contract.require(set(result['runs']) == set(wanted), 'Missing or extra run population')
    contract.require({p.stem for p in out.glob('run-*.log')} == set(wanted), 'Missing or extra raw run logs')
    reports = {}
    for key, (accuracy,rep,name,budget) in wanted.items():
        meta = result['runs'][key]
        for field,value in [('accuracy',accuracy),('repetition',rep),('budget_ns',budget),('exit',0)]:
            contract.strict(meta.get(field), value, field)
        contract.require(meta['fixture'] == name and meta['command'] == [str(out/'archived-measure'),
                '--maru-expect-tests=4','--maru-expect-passed=4'], 'Wrong executed target')
        contract.require(meta['environment'] == dict(MARU_BUDGET_FILE=str(out/'fixtures'/name),
                MARU_BUDGET_NS=str(budget), MARU_BUDGET_ACCURACY=str(accuracy)), 'Wrong actual input metadata')
        digest(out / (key+'.log'), meta['log_sha256'])
        reports[key] = contract.measure((out/(key+'.log')).read_text(), budget, accuracy)
    return dict(complete=True, head=expected_head, reports=reports, state=state_report,
                build_inputs_sha256=build_inputs,
                reader_sha256={name:sha(Path(__file__).with_name(name)) for name in ('verify.py','contract.py')},
                source_receipt_sha256=sha(out/'source.json'), result_sha256=sha(out/'result.json'),
                scope='Boundary-instrumented Provider timing and existing syntax-state API guards; not a product budget policy or GUI result')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset', type=Path)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    contract.require(not output.exists() and output != ROOT and ROOT not in output.parents, 'Use a new external receipt')
    write(output, verify(args.dataset.resolve(), args.expected_head))
    print('BUDGET_VERIFIED_40_PROCESSES')


if __name__ == '__main__':
    main()
