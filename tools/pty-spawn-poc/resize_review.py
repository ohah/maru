#!/usr/bin/env python3
"""Reject independent corruptions of an actual three-schedule resize recording."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
from resize_study import verify


def review(data):
    verify(data)
    def actor_write(case):
        return next(record for record in case['records'] if record.get('gated') == 1)
    def parent_write(case):
        return next(record for record in case['records'] if record.get('op') == 'parent-set')
    def case(data, name='stale'):
        return next(c for c in data['cases'] if c['scenario'] == name)
    def set_field(name, field, value):
        return lambda d: case(d, name).__setitem__(field, value)
    def set_write(field, value):
        return lambda d: actor_write(case(d)).__setitem__(field, value)
    def reverse_parent(d):
        records = case(d)['records']
        record = parent_write(case(d))
        records.remove(record)
        records.append(record)
    mutations = (
        ('observer changed errno', lambda d: d['observer_check'].__setitem__('instrumented', 'different errno')),
        ('incomplete capture', lambda d: d.__setitem__('complete', False)),
        ('boolean schema version', lambda d: d.__setitem__('schema', True)),
        ('changed executable text', lambda d: d['actors']['bash'].__setitem__('copy_text_sha256', '0' * 64)),
        ('invalid text digest', lambda d: d['actors']['bash'].__setitem__('original_text_sha256', 'bad')),
        ('missing actor', lambda d: d['actors'].pop('stty')),
        ('missing schedule', lambda d: d['cases'].pop()),
        ('duplicate schedule', lambda d: d['cases'].__setitem__(1, copy.deepcopy(d['cases'][0]))),
        ('invalid actor PID', set_field('stale', 'root_pid', -1)),
        ('foreign gate PID', set_field('stale', 'gate_pid', 1)),
        ('prompt already published', set_field('stale', 'post_command_prompt_seen', True)),
        ('gate timed out', set_field('stale', 'gate_timeout', True)),
        ('failed bridge', set_field('stale', 'driver_exit', 124)),
        ('child unreaped', set_field('stale', 'reaped', False)),
        ('cleanup failure', set_field('stale', 'cleanup_error', 'failed')),
        ('changed proposal', set_field('stale', 'proposal', [1, 2, 0, 0])),
        ('no actual resize', lambda d: case(d).__setitem__('requested', case(d)['before'])),
        ('wrong stale outcome', lambda d: case(d).__setitem__('final', case(d)['requested'])),
        ('wrong safe outcome', lambda d: case(d, 'after').__setitem__('final', case(d, 'after')['before'])),
        ('foreign writer PID', set_write('pid', 1)),
        ('failed actor ioctl', set_write('rc', -1)),
        ('wrong actor value', set_write('size', [1, 2, 0, 0])),
        ('unexecuted stale write', set_write('op', 'skip')),
        ('missing gated write', lambda d: case(d)['records'].remove(actor_write(case(d)))),
        ('duplicate gated write', lambda d: case(d)['records'].append(copy.deepcopy(actor_write(case(d))))),
        ('missing parent write', lambda d: case(d)['records'].remove(parent_write(case(d)))),
        ('failed parent ioctl', lambda d: parent_write(case(d)).__setitem__('rc', -1)),
        ('wrong parent value', lambda d: parent_write(case(d)).__setitem__('size', [1, 2, 0, 0])),
        ('foreign controller', lambda d: parent_write(case(d)).__setitem__('pid', 1)),
        ('same parent and actor', lambda d: parent_write(case(d)).__setitem__('pid', case(d)['root_pid'])),
        ('wrong native order', reverse_parent),
        ('negative native size', set_field('stale', 'final', [-1, 91, 0, 0])),
        ('boolean masquerades as size', set_field('stale', 'final', [True, 91, 0, 0])),
    )
    results = []
    for name, mutation in mutations:
        candidate = copy.deepcopy(data)
        mutation(candidate)
        try:
            verify(candidate)
        except (ValueError, KeyError, TypeError):
            results.append({'hypothesis': name, 'rejected': True})
        else:
            raise RuntimeError('corrupted evidence was accepted: ' + name)
    equivalent = copy.deepcopy(data)
    equivalent['cases'].reverse()
    verify(equivalent)  # schedule serialization order does not determine syscall order
    verify(data)
    return {'rejected': results, 'equivalent_order_accepted': True, 'original_still_valid': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--study', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('output must be new; preserve existing evidence')
    raw = args.study.read_bytes()
    result = review(json.loads(raw))
    if hashlib.sha256(raw).digest() != hashlib.sha256(args.study.read_bytes()).digest():
        raise RuntimeError('original study changed')
    result['source_sha256'] = hashlib.sha256(raw).hexdigest()
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Rejected {len(result['rejected'])} independent corruptions; equivalent and original accepted.")


if __name__ == '__main__':
    main()
