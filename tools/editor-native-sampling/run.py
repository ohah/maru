#!/usr/bin/env python3
"""기존 기준 바이너리를 실행 전부터 샘플링한다. 프로파일 시간은 기준 성능에 섞지 않는다."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

import evidence
import stacks
import symbols


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base, output = args.baseline.resolve(), args.output.resolve()
    if platform.system() != 'Darwin' or output.exists() or output == evidence.ROOT or evidence.ROOT in output.parents:
        parser.error('Use macOS and a new output outside the repository')
    proof = evidence.baseline(base, args.expected_head)
    binary = base / 'archived-test'
    uid = stacks.macho_uuid(binary.read_bytes())
    producer = evidence.producer_files()
    output.mkdir(parents=True)
    for name, digest in producer.items():
        path = output / 'tool-snapshot' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(evidence.ROOT / name, path)
        evidence.native.digest(path, digest)
    write(output / 'producer.json', dict(schema=1, head=args.expected_head,
        tools_sha256=producer, baseline_result_sha256=evidence.sha(base / 'result.json')))
    symbol_command = symbols.bundle_command(output, binary)
    with (output / 'symbols.log').open('xb') as stream:
        symbol_result = subprocess.run(symbol_command, stdout=stream, stderr=subprocess.STDOUT)
    evidence.require(symbol_result.returncode == 0, 'Debug symbol archive failed; original log preserved')
    symbol = symbols.symbol_file(output, uid)
    symbol_hashes = evidence.inventory(output / 'symbols.dSYM')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('MARU_')}
    runs = {}
    for rep in range(3):
        for filename in sorted(proof['inputs']):
            for workload in ('typing', 'shared'):
                # 새 관측을 시작하기 전의 공간 확인이다. 실행 중인 편집을 시간 초과로 취소하지 않는다.
                if shutil.disk_usage(output).free < 256 * 1024 * 1024:
                    raise RuntimeError('Insufficient free disk before starting another profile')
                evidence.native.digest(binary, proof['binary_sha256'])
                name = f'profile-{rep}-{filename}-{workload}'
                folder = output / name
                folder.mkdir()
                commands = evidence.commands(folder, base, filename, workload)
                codes = []
                for command, log in zip(commands, ('recorder.log', 'export-toc.log', 'export-profile.log')):
                    with (folder / log).open('xb') as stream:
                        result = subprocess.run(command, cwd=base / 'source-1', env=environment,
                                                stdout=stream, stderr=subprocess.STDOUT)
                    codes.append(result.returncode)
                    if result.returncode != 0:
                        write(folder / 'command-failure.json', dict(command=command, exit_code=result.returncode))
                        raise RuntimeError('Recorder/exporter failed; original logs preserved: ' + name)
                target = stacks.target((folder / 'toc.xml').read_text(), str(binary), evidence.environment(base, filename, workload))
                xml = (folder / 'time-profile.xml').read_text()
                resolution = symbols.collect(folder, xml, binary, symbol, uid)
                write(folder / 'address-symbols.json', resolution)
                summary = stacks.profile(xml, target['pid'], str(binary), uid,
                                         dict(plan=resolution['plan'], names=resolution['names']))
                write(folder / 'run.json', dict(schema=1, repetition=rep, fixture=filename, workload=workload,
                    cwd=str(base / 'source-1'), commands=commands, exit_codes=codes,
                    binary_sha256=proof['binary_sha256'], files_sha256=evidence.inventory(folder), summary=summary))
                checked = evidence.read_run(folder, base, rep, filename, workload, proof['binary_sha256'], uid)
                runs[name] = evidence.sha(folder / 'run.json')
                print('PROFILE_PASS', name, checked['profile']['counts'], flush=True)
    # 수집 중 제품 사본·실행 파일·생산자가 바뀌면 완료 표시를 만들지 않는다.
    after = evidence.baseline(base, args.expected_head)
    evidence.require(after['binary_sha256'] == proof['binary_sha256'] and evidence.producer_files() == producer,
                     'Baseline or producer changed during recording')
    evidence.files(output / 'symbols.dSYM', symbol_hashes)
    write(output / 'result.json', dict(schema=1, kind='native-sampling', complete=True, head=args.expected_head,
        processes=30, inputs=600, baseline_result_sha256=evidence.sha(base / 'result.json'),
        binary_sha256=proof['binary_sha256'], binary_uuid=uid, producer_sha256=producer, runs_sha256=runs,
        producer_receipt_sha256=evidence.sha(output / 'producer.json'), symbol_command=symbol_command,
        symbol_exit=symbol_result.returncode, symbols_sha256=symbol_hashes,
        symbol_log_sha256=evidence.sha(output / 'symbols.log'),
        scope='Separate profiles of current pinned baseline; no profile timings enter baseline performance'))
    print('NATIVE_SAMPLING_COMPLETE_30_PROCESSES', flush=True)


if __name__ == '__main__':
    main()
