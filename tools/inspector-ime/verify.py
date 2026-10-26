"""Independent fixed-buffer Inspector semantics and shared candidate/pixel proof."""
from pathlib import Path
from prepare import load
common=load('inspector_shared_windows',Path(__file__).resolve().parents[1]/'address-ime/verify.py')
anchors=load('inspector_shared_anchors',Path(__file__).resolve().parents[1]/'project-search-ime/verify.py')
h,require=common.h,common.require
validate_anchors=anchors.validate_anchors


def semantics(report):
    require(report['schema']=='maru.inspector-search-ime.v1' and report['passed'] and not report['failures'],'producer')
    require(type(report['detached']) is bool and report['candidate_count']==5,'scene')
    states=report['observations']
    expected=sum(([f'selected_fixture_{i}',f'han_{i}',f'opened_{i}',f'cancel_{i}'] for i in range(5)),[])+['selected_fixture_5','han_5','opened_5','selected','terminal_restored']
    require([r['name'] for r in states]==expected,'states')
    require([r['name'] for r in report['composition']]==['ㅎ','하','한']*6,'composition')
    input_window=report['input_window_id'];owner_window=report['owner_window_id']
    require(type(input_window) is int and type(owner_window) is int and input_window>0 and owner_window>0,'window identity')
    require((input_window!=owner_window)==report['detached'],'scene window identity')
    base=states[0]['terminal_bytes']; surface=states[0]['active_surface']; owners=set()
    def text(row,key,value):
        require(row[key+'_hash']==h(value) and row[key+'_bytes']==len(value.encode()),key)
    for row in states+report['composition']:
        require(row['label_hash']==h('한') and row['tabs_count']==1 and row['active_workspace']==0 and row['active_surface']==surface,'fixture identity')
        require(row['navigate_pending']==0,'unexpected Inspector action')
    for i in range(6):
        group=states[4*i:4*i+4];owner=int(group[0]['owner_generation'])
        require(1<<55<owner<1<<56 and owner not in owners,'owner');owners.add(owner)
        for row in group+report['composition'][3*i:3*i+3]:
            require(row['window_id']==input_window and int(row['owner_generation'])==owner and row['first_responder'] and row['open']==row['palette_owner']==1 and row['terminal_bytes']==base,'source owner')
        require(all(group[j]['window_key'] for j in (0,1,3)), 'input window key authority')
        text(group[0],'query','');text(group[0],'document','')
        for row,letter in zip(report['composition'][3*i:3*i+3],('ㅎ','하','한')):
            text(row,'document',letter)
            committed=row['query_hash']==h(letter) and row['query_bytes']==len(letter.encode()) and row['preedit_bytes']==0
            marked=row['query_hash']==h('') and row['query_bytes']==0 and row['preedit_hash']==h(letter) and row['preedit_bytes']==len(letter.encode())
            require(committed or marked,'composition publication')
        text(group[1],'query','한');text(group[1],'document','한')
        text(group[2],'query','한');text(group[2],'document','韓');text(group[2],'preedit','韓')
        require(group[1]['title_row']==1 and group[1]['filter_key_hash']==h('overview.title'),'canonical title row')
        require(group[2]['title_row']==0 and group[2]['filter_key_hash']==h(''),'live preview filter')
        word='한' if i<5 else '韓';text(group[3],'query',word);text(group[3],'document',word)
        require(group[3]['title_row']==(1 if i<5 else 0),'settled title row')
        require(not group[3]['has_marked'] and group[3]['committed_callbacks']==group[2]['committed_callbacks']+1,'candidate settlement')
    end=states[-1];require(end['window_id']==owner_window and end['window_key'],'terminal window');text(end,'query','韓' if report['detached'] else '')
    require(end['open']==end['palette_owner']==0 and int(end['owner_generation'])==0 and end['terminal_bytes']==base+1 and not end['has_marked'] and end['first_responder'],'terminal return')
    require(len(report['geometry'])==12,'geometry')
    for empty,composed in zip(report['geometry'][::2],report['geometry'][1::2]):
        require(abs(composed['x']-empty['x']-report['glyph_advances']['한'])<=.01,'caret advance')
        for g in (empty,composed):
            require(g['w']>0 and g['h']>0 and g['x']>=g['field_x']-1 and g['x']+g['w']<=g['field_x']+g['field_w']+1 and g['y']>=g['field_y']-1 and g['y']+g['h']<=g['field_y']+g['field_h']+1,'anchor bounds')
    return states,base


def validate(report,candidate,artifact_root=None):
    states,base=semantics(report)
    if artifact_root is not None:
        raw=__import__('json').loads((Path(artifact_root)/'window-transcript.json').read_text())
        validate_anchors(report,raw)
        validate_windows(report,raw,candidate)
    return common.validate_window_evidence(report,candidate,states,base,artifact_root,scene='inspector-search')


def validate_diagnostic(report):
    require(report['mode']=='diagnostic' and report['window_inventory_validated'] is False,'diagnostic separation')
    semantics(report)


def validate_windows(report,raw,candidate=None):
    pid=None
    for i,row in enumerate(raw):
        for phase in ('before','opened','closed'):
            windows={w['id']:w for w in row[phase]['windows']}
            for key in ('input_window_id','owner_window_id'):
                require(report[key] in windows,'missing owner window')
                w=windows[report[key]]
                require(w['layer']==0 and w['on_screen'] and w['owner']['bundle_id']=='dev.maru.apphost' and w['owner']['signing_id']=='dev.maru.apphost','owner window authority')
                if pid is None:pid=w['owner']['pid']
                require(w['owner']['pid']==pid and pid>0,'stable app owner')
            if candidate is not None:
                require(candidate['rows'][i]['owner_pid']==pid,'candidate and input window owner')
