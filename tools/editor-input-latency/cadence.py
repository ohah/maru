#!/usr/bin/env python3
"""동일 실행 파일에서 요청 timer 주기만 바꾼다. 제품 기본 설정은 변경하지 않는다."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import stages
import verify

HERE = pathlib.Path(__file__).resolve().parent


def variant(source, repo, hz):
    verify.require(type(hz) is int and hz in (30, 60, 120), 'unsupported cadence')
    anchors = [(r'editor.wrap = false\n', r'editor.wrap = false\nrender.frame-rate = '+str(hz)+r'\n'),
               ("env['MARU_DEBUG']='1'", "env['MARU_LATENCY_DIAGNOSTIC']='1'"),
               ("'diagnostic':a.diagnostic,", "'diagnostic':a.diagnostic,'requested_frame_rate_hz':"+str(hz)+","),
               ("record['result_sha256']=", "record['config_sha256']=sha(d/'config');record['result_sha256']=")]
    for old, new in anchors:
        verify.require(source.count(old) == 1, 'cadence anchor changed')
        source = source.replace(old, new)
    return source.replace('pathlib.Path(__file__).resolve().parents[2]', 'pathlib.Path('+repr(str(repo))+')')


def read_case(root, hz):
    m = json.loads((root/'manifest.json').read_text())
    verify.require(m['diagnostic'] is True and type(m['requested_frame_rate_hz']) is int and m['requested_frame_rate_hz'] == hz, 'cadence identity')
    verify.require(m['sizes'] == [50000] and m['flows'] == ['typing'] and type(m['events']) is int and m['events'] == 6 and type(m['repetitions']) is int and m['repetitions'] == 3, 'cadence population')
    # 진단 표지만 명시적으로 허용하고 나머지는 일반 측정과 같은 원시 증거로 검증한다.
    verify.verify(root, diagnostic=True)
    groups = {}
    expected = 'session.keep-alive-after-quit = false\nlsp.enabled = false\neditor.wrap = false\nrender.frame-rate = '+str(hz)+'\n'
    for r in m['runs']:
        config = root/r['path']/'config'
        verify.require(config.read_text() == expected and verify.sha(config) == r['config_sha256'], 'cadence config')
        v = json.loads((root/r['path']/'result.json').read_text())
        groups.setdefault(r['mode'], []).append(stages.run_stages(v, r, m['events']))
    return {'requested_frame_rate_hz': hz, 'head': m['source']['head'], 'app_sha256': m['app_sha256'],
            'host': m['host'],
            'load_1m_range': [min(r[k][0] for r in m['runs'] for k in ['load_before', 'load_after']), max(r[k][0] for r in m['runs'] for k in ['load_before', 'load_after'])],
            'manifest_sha256': verify.sha(root/'manifest.json'),
            'groups': {k: stages.aggregate(rs) for k, rs in groups.items()}}


def read_experiment(root):
    rows = []
    for hz in [60, 30, 120]:
        target = root/('hz-'+str(hz))
        row = read_case(target, hz)
        manifest = json.loads((target/'manifest.json').read_text())
        row['runner_sha256'] = verify.sha(root/('runner-'+str(hz)+'.py'))
        verify.require(row['runner_sha256'] == manifest['runner_sha256'], 'cadence runner drift')
        rows.append(row)
    verify.require(len({(r['head'], r['app_sha256'], json.dumps(r['host'], sort_keys=True)) for r in rows}) == 1, 'mixed cadence build/host')
    return {'schema': 1, 'complete': True, 'method': 'requested timer cadence; fixed-order diagnostic, three processes per mode',
            'analyzers': {name: verify.sha(HERE/name) for name in ['cadence.py', 'stages.py', 'verify.py']}, 'variants': rows}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', required=True, type=pathlib.Path)
    p.add_argument('--output', required=True, type=pathlib.Path)
    a = p.parse_args()
    out, repo = a.output.resolve(), HERE.parents[1]
    if out.exists() or out == repo or repo in out.parents:
        p.error('new external output required')
    out.mkdir()
    source = (HERE/'run.py').read_text()
    report = {'schema': 1, 'runner_sha256': hashlib.sha256(source.encode()).hexdigest(), 'variants': []}
    for hz in [60, 30, 120]:
        runner = out/('runner-'+str(hz)+'.py')
        runner.write_text(variant(source, repo, hz))
        target = out/('hz-'+str(hz))
        subprocess.run([sys.executable, str(runner), '--build', str(a.build), '--output', str(target),
                        '--sizes', '50000', '--flows', 'typing', '--repetitions', '3', '--events', '6', '--diagnostic'], check=True)
        row = read_case(target, hz)
        row['runner_sha256'] = verify.sha(runner)
        report['variants'].append(row)
        (out/'cadence.json').write_text(json.dumps(report, indent=2)+'\n')
    (out/'validated.json').write_text(json.dumps(read_experiment(out), indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
