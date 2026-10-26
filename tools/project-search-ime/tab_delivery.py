"""Independent evidence for the first physical Tab; no candidate/pixel claim."""
import json
import math
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(rows, request, ack, final):
    require(all(type(request.get(k)) is int for k in ('id','pid','keycode','flags')), 'request types')
    require(all(type(ack.get(k)) is int for k in ('id','pid','keycode','flags','events')), 'ack types')
    require(type(request.get('time')) in (int,float) and math.isfinite(request['time']), 'request time')
    require(type(request.get('id')) is int and request['id'] > 0, 'request id')
    require(request.get('keycode') == 48 and request.get('flags') == 0 and request.get('korean') is True, 'physical Tab request')
    require(ack.get('passed') is True and ack.get('id') == request['id'] and ack.get('pid') == request.get('pid') and ack.get('keycode') == 48 and ack.get('flags') == 0 and ack.get('events') == 2 and ack.get('generation') == request.get('generation'), 'posted acknowledgement')
    require(len(rows) == 6, 'missing or duplicate receipt')
    phases = ['app_dispatch', 'view_received', 'view_handled', 'app_dispatch', 'view_release_received', 'view_release_handled']
    require([r.get('phase') for r in rows] == phases, 'receipt order')
    before = int(request['generation'])
    require(1 << 58 < before < 1 << 59, 'owner domain')
    after = int(rows[2]['owner'])
    require(before < after < 1 << 59, 'new owner')
    previous = request['time']
    for i, row in enumerate(rows):
        require(all(type(row.get(k)) is int for k in ('id','pid','foreground_pid','event_type','field','committed')), 'receipt types')
        require(row.get('id') == request['id'] and row.get('pid') == request['pid'] and row.get('foreground_pid') == request['pid'], 'receipt identity')
        require(row.get('active') is True and row.get('key_window') is True, 'receipt focus')
        require(row.get('event_type') == (10 if i < 3 else 11), 'key phase')
        require(row.get('field') == (0 if i < 2 else 3), 'field transition')
        require(int(row['owner']) == (before if i < 2 else after), 'owner transition')
        require(row.get('committed') == 0, 'Tab committed text')
        now, event_time = row['time'], row['event_timestamp']
        require(all(type(t) in (int, float) and math.isfinite(t) for t in (now, event_time)), 'finite timing')
        require(previous <= now <= request['time'] + 3 and request['time'] <= event_time <= now, 'receipt timing')
        require(event_time == rows[0 if i < 3 else 3]['event_timestamp'], 'same OS event')
        previous = now
    require(rows[0]['event_timestamp'] <= rows[3]['event_timestamp'], 'key down/up order')
    require(all(type(final.get(k)) is int for k in ('pid','field','committed','marked')), 'final types')
    require(type(final.get('time')) in (int,float) and math.isfinite(final['time']), 'final time')
    require(final.get('pid') == request['pid'] and final.get('field') == 3 and int(final['owner']) == after and final.get('committed') == final.get('marked') == 0, 'final state')
    require(previous <= final['time'] <= request['time'] + 3, 'final timing')
    return dict(schema='maru.project-tab-delivery.v1', passed=True, scope='first_tab_only', received=True, handled=True, field_moved=True, dispatch_latency=rows[0]['time']-rows[0]['event_timestamp'])


def validate_root(root):
    root = Path(root)
    rows = [json.loads(line) for line in (root/'tab-trace.jsonl').read_text().splitlines()]
    return validate(rows, *(json.loads((root/name).read_text()) for name in ('hid-request.json','hid-ack.json','tab-final.json')))
