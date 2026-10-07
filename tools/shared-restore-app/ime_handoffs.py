"""Analyze opt-in product arrival logs without assigning an OS callback an invented owner."""
import re


def analyze(transcript):
    handoffs = []
    active = None
    for line in transcript.splitlines():
        if line.startswith('[IME_FOCUS] post '):
            if active is not None:
                raise ValueError('handoff ended without a following observed owner and key')
            fields = dict(re.findall(r'(\w+)=(\S+)', line))
            active = dict(source=int(fields['owner']), key=int(fields['code']), posted=float(fields['t']),
                          target=None, observed=None, callbacks=[])
            handoffs.append(active)
        elif line.startswith('[IME_FOCUS] observed '):
            if active is None or active['observed'] is not None:
                raise ValueError('observed owner without exactly one pending handoff')
            fields = dict(re.findall(r'(\w+)=(\S+)', line))
            active['target'] = int(fields['owner'])
            active['observed'] = float(fields['t'])
            if active['source'] == active['target'] or active['observed'] < active['posted']:
                raise ValueError('owner did not change or time moved backwards')
        elif active is not None and line.startswith('[IME] callback_arrival '):
            fields = dict(re.findall(r'(\w+)=(\S+)', line))
            record = dict(owner=int(fields['owner']), captured=fields['captured'],
                          time=float(fields['t']), accepted=fields['accepted'], line=line)
            if record['time'] < active['posted']:
                raise ValueError('callback preceded handoff post')
            active['callbacks'].append(record)
        elif active is not None and active['observed'] is not None and line.startswith('[IME] keyDown '):
            active = None
    for handoff in handoffs:
        if handoff['observed'] is None:
            raise ValueError('handoff has no observed target')
        # This counts arrival on the newly active owner, even before the driver's next tick.
        # AppKit carries no originating transaction id; a candidate is not proof of stale origin.
        handoff['new_owner_arrivals'] = [r for r in handoff['callbacks'] if r['owner'] == handoff['target']]
        handoff['after_observed_arrivals'] = [r for r in handoff['callbacks'] if r['time'] >= handoff['observed']]
    return handoffs
