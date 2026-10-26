#!/usr/bin/env python3
"""Recheck saved wire/native evidence and source snapshots without running SDKs."""
import argparse
import hashlib
import json
from pathlib import Path
from oracle import InvalidEvidence, PROFILES, require, verify_directory


def verify_run(root):
    report = json.loads((root / 'result.json').read_text())
    require(report.get('schema') == 'maru.lsp-real.run.v1', 'unsupported run schema')
    require(report.get('optimize') in PROFILES, 'unsupported build profile')
    tool_hashes = report.get('tool_sources', {})
    scenario = report.get('scenario', 'single-file')
    require(scenario in ('single-file', 'multi-file', 'rename'), 'unsupported scenario')
    expected_tools = {'run.py', 'oracle.py', 'verify.py', 'lsp_proxy.py'}
    if scenario == 'multi-file':
        expected_tools |= {'multi_fixture.py', 'multi_oracle.py'}
    if scenario == 'rename':
        expected_tools |= {'rename_fixture.py', 'rename_oracle.py'}
    require(set(tool_hashes) == expected_tools, 'tool source inventory incomplete')
    for name, expected in tool_hashes.items():
        require(hashlib.sha256((root / 'tool-sources' / name).read_bytes()).hexdigest() == expected, 'tool source hash mismatch: ' + name)
    require(hashlib.sha256((root / 'judge').read_bytes()).hexdigest() == report.get('judge_sha256'), 'judge binary hash mismatch')
    names = [r.get('language') for r in report.get('languages', [])]
    require(names and len(names) == len(set(names)), 'missing or duplicate language results')
    output = {}
    for language, result in zip(names, report['languages']):
        require(language in ('rust', 'go', 'kotlin', 'dart', 'scala'), 'unknown language')
        case_root = root / ('case-' + language)
        case = json.loads((case_root / 'case.json').read_text())
        require(case.get('scenario', 'single-file') == scenario, 'run/case scenario mismatch')
        if scenario in ('multi-file', 'rename'):
            require(language in ('rust', 'go') and case.get('language') == language, 'multi-document language mismatch')
        require(result.get('exit_code') == 0 and not result.get('failure'), 'recorded product run failed: ' + language)
        hashes = result.get('artifacts', {})
        require({'case.json', 'product.json', 'wire.ndjson', 'protocol.ndjson', 'judge.log', 'server.stderr'} <= hashes.keys(), 'artifact inventory incomplete')
        for name, expected in hashes.items():
            require(Path(name).name == name, 'artifact path escapes fixture')
            require(hashlib.sha256((case_root / name).read_bytes()).hexdigest() == expected, 'artifact hash mismatch: ' + name)
        native = json.loads((case_root / 'product.json').read_text())
        require(native.get('build_mode') == PROFILES[report['optimize']], 'compiled build mode differs from run profile')
        output[language] = verify_directory(case_root, result['exit_code'])
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify_run(args.output.resolve()), indent=2))
    except (InvalidEvidence, OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, 'evidence rejected: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()
