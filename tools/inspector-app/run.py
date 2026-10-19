#!/usr/bin/env python3
"""Independent Inspector AppKit/Metal E2E; isolated HOME and one fresh app per adversarial round.

No HID/real IME claim: NSEvent reaches the product NSView -> controller -> ABI -> Zig path.
The manifest records every assertion and keeps native Metal captures and CLI responses.
"""
import argparse, json, os, pathlib, re, signal, subprocess, tempfile, time


def scenario(n, out):
    lines = ['sleep 900', 'inspect-report start']
    expected = [('start', 2, 0)]
    captures = []
    def place(index, name=None):
        tag = name or f'p{len(expected)}'
        lines.extend([f'inspect-click {40+index}', 'sleep 450', f'inspect-report {tag}'])
        expected.append((tag, index+1, int(index==4)))
    def capture(name, detached=False):
        path = out / (name+'.ppm')
        lines.extend([f'{"inspect-capture" if detached else "inspect-main-capture"} {path}', 'sleep 220'])
        captures.append(path)
    def hover(control, cursor):
        label=f'c{sum(l.startswith("inspect-hover") for l in lines)}_{cursor}'
        lines.append(f'inspect-hover {control} {label}')
    if n == 1:
        for index, name in [(3,'left'), (0,'top'), (2,'bottom'), (1,'right')]:
            place(index, name); capture(name)
    elif n == 2:
        place(4,'detached'); capture('detached',True)
        for index in [3,4,0,4,2,4,1]: place(index)
    elif n == 3:
        place(4,'detached')
        for w,h in [(360,280),(1100,700),(500,400)]:
            lines.extend([f'inspect-resize {w} {h}', 'sleep 350', f'inspect-report resize{w}'])
            expected.append((f'resize{w}',5,1))
            capture(f'resize-{w}',True)
        place(1,'redocked')
    elif n == 4:
        place(4,'detached')
        lines.extend(['inspect-click 6','inspect-key 7 U+0078','sleep 200','inspect-report typed'])
        expected.append(('typed',5,1))
        lines.extend(['inspect-ime 한','sleep 100','inspect-focus-owner','sleep 150','key 123 -','sleep 150','inspect-report owner'])
        expected.append(('owner',5,1))
        place(1,'redocked')
    elif n == 5:
        place(4,'detached')
        lines.extend(['inspect-key 53 U+001B','inspect-key 13 U+0077 32','sleep 400','inspect-report keyboardClosed','action toggle_inspector','sleep 500','inspect-report keyboardReopened','inspect-close','sleep 400','inspect-report closed','action toggle_inspector','sleep 500','inspect-report reopened'])
        expected.extend([('keyboardClosed',0,0),('keyboardReopened',5,1),('closed',0,0),('reopened',5,1)])
        place(2,'redocked')
    elif n == 6:
        lines.extend(['inspect-click 12','inspect-click 13','inspect-click 6','inspect-key 7 U+0078','sleep 150','inspect-report pinned'])
        expected.append(('pinned',2,0))
        lines.extend(['inspect-key 1 U+0073 32','sleep 200','action new_term','sleep 500'])
        for index in [4,0,3,2,1]: place(index)
        lines.extend(['inspect-click 6','inspect-key 1 U+0073 32','sleep 200'])
    elif n == 7:
        for index,dx,dy in [(1,-160,0),(3,150,0),(0,0,100),(2,0,120)]:
            place(index)
            tag=f'drag{index}'
            lines.extend([f'inspect-drag {dx} {dy}','sleep 300',f'inspect-report {tag}'])
            expected.append((tag,index+1,0))
        capture('resized')
    elif n == 8:
        place(4,'detached')
        lines.extend(['inspect-click 6','action toggle_settings','sleep 200','inspect-key 7 U+0078','inspect-report modal','inspect-key 53 U+001B','sleep 300','inspect-report restored'])
        expected.extend([('modal',5,1),('restored',5,1)])
        place(1,'redocked')
    elif n == 9:
        # The second real owner has its own inspector. Closing that owner must reclaim its tool.
        lines.extend(['newwindow','sleep 900','inspect-open','sleep 400','inspect-click 44','sleep 450','inspect-report second','inspect-destroy-owner','sleep 1300','inspect-report survivor'])
        expected.extend([('second',5,1),('survivor',2,0)])
    elif n == 10:
        for index in [4,1,4,3,4,0,4,2,4,1]*2: place(index)
        capture('after-stress')
    elif n in (11, 20):
        for index in [3,0,2,1]:
            place(index)
            hover(6,'ibeam'); hover(40,'hand'); hover(2,'arrow')
            hover(0,'resize-h' if index in (1,3) else 'resize-v')
            hover('outside','arrow')
        capture('cursor-layout')
    elif n == 12:
        place(4,'detached')
        for width,height in [(400,400),(1200,700),(600,500)]:
            lines.extend([f'inspect-resize {width} {height}','sleep 200'])
            hover(6,'ibeam'); hover(20,'hand'); hover(2,'arrow'); hover('outside','arrow')
        lines.extend(['action toggle_settings','sleep 200']);hover(6,'arrow')
        lines.extend(['inspect-key 53 U+001B','sleep 200']);hover(6,'ibeam')
        capture('detached-cursors',True)
        place(1,'redocked'); hover(0,'resize-h'); hover(6,'ibeam'); hover('outside','arrow')
    elif n == 13:
        lines.extend(['inspect-click 6','inspect-text x'])
        for index in [4,3,0,2,1]:
            place(index)
            lines.append('inspect-click 6')
            for code,scalar,mods in [(48,'U+0009',0),(48,'U+0009',4),(125,'-',0),(121,'-',0)]:
                lines.append(f'inspect-key {code} {scalar} {mods}')
        lines.append('inspect-report filtered');expected.append(('filtered',2,0))
    elif n == 14:
        place(4,'detached');lines.extend(['inspect-click 6','inspect-text '+('한'*43),'inspect-report hangul','inspect-key 53 U+001B','inspect-text '+('😀'*33),'inspect-report emoji','inspect-key 51 U+007F','inspect-report backspace'])
        expected.extend([('hangul',5,1),('emoji',5,1),('backspace',5,1)])
        place(3,'redocked')
    elif n == 15:
        for index in [4,3,0,2,1]:
            lines.extend(['inspect-click 6','inspect-ime 한']);place(index)
    elif n == 16:
        lines.extend(['action new_term','sleep 700','inspect-report following','inspect-click 10','sleep 400','inspect-report previous','inspect-click 11','sleep 400','inspect-report next'])
        expected.extend([('following',2,0),('previous',2,0),('next',2,0)])
        for index in [4,0,3,2,1]:place(index)
        lines.extend(['inspect-click 12','sleep 400','inspect-report followAgain']);expected.append(('followAgain',2,0))
    elif n == 17:
        lines.extend(['inspect-click 13','inspect-click 16','sleep 350','inspect-click 14','inspect-click 16','sleep 350'])
        for index in [4,3,0,2,1]:place(index)
        lines.append('inspect-click 16')
    elif n == 18:
        place(4,'detached')
        lines.extend(['inspect-click 6','inspect-text x','inspect-click 12','inspect-click 13','inspect-close','sleep 300','inspect-report closed','action toggle_inspector','sleep 400','inspect-report reopened'])
        expected.extend([('closed',0,0),('reopened',5,1)])
        hover(6,'ibeam');place(1,'redocked')
    elif n == 19:
        for index in [4,3,0,2,1]:
            lines.extend(['action toggle_file_panel_dock_side','sleep 200']);place(index)
        capture('ordinary-dock-coexistence')
    elif n == 21:
        for index in [0,3,2,1,4]:
            place(index)
            lines.extend(['inspect-click 17','sleep 250',f'inspect-report closed{index}','action toggle_inspector','sleep 400',f'inspect-report reopened{index}'])
            expected.extend([(f'closed{index}',0,0),(f'reopened{index}',index+1,int(index==4))])
    elif n == 22:
        lines.extend(['inspect-click 6','inspect-text x','inspect-key 53 U+001B','inspect-report cleared','inspect-key 53 U+001B','inspect-report blurred','key 123 -','sleep 100','inspect-report terminal'])
        expected.extend([('cleared',2,0),('blurred',2,0),('terminal',2,0)])
        place(4,'detached')
        lines.extend(['inspect-key 53 U+001B','inspect-report windowBlurred','inspect-key 123 -','sleep 100','inspect-report guarded','inspect-key 13 U+0077 32','sleep 350','inspect-report closed'])
        expected.extend([('windowBlurred',5,1),('guarded',5,1),('closed',0,0)])
    elif n == 23:
        lines.extend(['inspect-click 13','inspect-click 16','sleep 250','inspect-click 6','inspect-text '+('x'*128)])
        for tab in [20,21,22,23]:lines.append(f'inspect-click {tab}')
        for index in [4,0,3,2,1]:place(index)
        lines.append('inspect-click 16')
    elif n == 24:
        lines.extend(['inspect-click 13','inspect-click 16','sleep 250','inspect-click 7','inspect-click 16'])
        place(4,'detached');capture('export-privacy',True);place(1,'redocked')
    elif n == 25:
        lines.extend(['inspect-click 16','sleep 200'])
        for index in [4,0,3,2,1]:place(index)
        lines.extend(['inspect-click 6','inspect-text survived','inspect-report alive']);expected.append(('alive',2,0))
        capture('save-error')
    elif n == 26:
        lines.extend(['inspect-click 6','inspect-key 34 U+0069 40','inspect-report defaultUnbound']);expected.append(('defaultUnbound',2,0))
        place(4,'detached')
        lines.extend(['inspect-click 6','inspect-key 34 U+0069 40','inspect-report windowUnbound','inspect-click 17','sleep 300','inspect-report closed']);expected.extend([('windowUnbound',5,1),('closed',0,0)])
    elif n == 27:
        lines.extend(['inspect-click 6','inspect-key 2 U+0064 24','sleep 300','inspect-report customClosed','action toggle_inspector','sleep 350'])
        expected.append(('customClosed',0,0));place(4,'detached')
        lines.extend(['inspect-click 6','inspect-key 2 U+0064 24','sleep 350','inspect-report customWindowClosed']);expected.append(('customWindowClosed',0,0))
    elif n == 28:
        place(4,'detached')
        lines.extend(['inspect-click 6','inspect-text '+('a'*256),'inspect-report saturated','inspect-text 한','inspect-report unchanged'])
        lines.extend(['inspect-key 51 U+007F']*4)
        lines.extend(['inspect-text 한','inspect-report mixed','inspect-text 😀','inspect-report overflow','inspect-key 51 U+007F','inspect-report removed'])
        expected.extend([(tag,5,1) for tag in ['saturated','unchanged','mixed','overflow','removed']]);place(1,'redocked')
    elif n == 29:
        lines.extend(['inspect-drag -110 0','inspect-report widthSaved']);expected.append(('widthSaved',2,0))
        place(2,'bottom');lines.extend(['inspect-drag 0 60','inspect-report heightSaved']);expected.append(('heightSaved',3,0))
        place(3,'left');place(0,'top');place(4,'detached');place(1,'rightAgain');place(2,'bottomAgain')
        capture('independent-axis-sizes')
    elif n == 30:
        for index in [4,3,0,2,1]:place(index)
        capture('cli-errors-survivor')
    else:
        raise ValueError(f'unknown adversarial scenario {n}')
    lines.extend(['inspect-report done','mark finished','sleep 400','inspect-finish'])
    return '\n'.join(lines)+'\n', expected, captures


def run_round(app, output, n):
    root = pathlib.Path(tempfile.mkdtemp(prefix='mie-',dir='/tmp'))
    for name in ['home','cache','state','host','backups','work']: (root/name).mkdir()
    if n==24:(root/'home/work').mkdir()
    work=root/('home/work' if n==24 else 'work')
    (work/'README.md').write_text('# Inspector independent dock fixture\n')
    (root/'demo.sh').write_text(f'cd "{work}"\nprintf "\\033]0;Inspector E2E {n}\\007\\033]7;file://{work}\\007\\033]133;A\\007Inspector E2E ready\\n"\nexec /bin/sh -i\n')
    config=root/'config'
    config.write_text(f'session.keep-alive-after-quit=false\nworkspace.restore=false\nworkspace.root={work}\nshell.command=/bin/sh\nshell.args={root}/demo.sh\n')
    if n in (26,27):
        with config.open('a') as f:
            f.write('keybind = Cmd+Alt+I = unbind\n')
            if n==27:f.write('keybind = Ctrl+Alt+D = toggle_inspector\n')
    if n==25:
        collision=root/'home/.cache/maru/inspector';collision.parent.mkdir(parents=True)
        collision.write_text('occupied')
    dest=output/f'round-{n:02d}';dest.mkdir()
    script,expected,captures=scenario(n,dest)
    (dest/'input.txt').write_text(script)
    (dest/'fixture-root.txt').write_text(str(root))
    report=dest/'report.txt'
    env=os.environ.copy()
    for key in list(env):
        if key.startswith('MARU_'): env.pop(key)
    env.update(HOME=str(root/'home'),CFFIXED_USER_HOME=str(root/'home'),MARU_CONFIG=str(config),XDG_CONFIG_HOME=str(root/'home/.config'),XDG_CACHE_HOME=str(root/'cache'),XDG_STATE_HOME=str(root/'state'),MARU_SESSION_HOST_ROOT=str(root/'host'),MARU_EDITOR_BACKUP_ROOT=str(root/'backups'),MARU_NO_WORKSPACE_RESTORE='1',MARU_OPEN_INSPECTOR='1',MARU_INSPECTOR_WITH_DOCK='1',MARU_INSPECTOR_APP_TEST='1',MARU_WEB_OSR_TEST_INPUT=str(dest/'input.txt'),MARU_WEB_OSR_TEST_REPORT=str(report))
    if n in (3,20):
        env.update(MARU_SCREENSHOT=str(dest/'automatic.ppm'),MARU_SCREENSHOT_DELAY_MS='60000',MARU_SCREENSHOT_TIMEOUT_MS='70000',MARU_SCREENSHOT_RENDER_SCALE_MILLI='2000')
    cli=app.parent/'maru'; observations=[];errors=[]
    with (dest/'app.log').open('w') as log:
        process=subprocess.Popen([str(app)],env=env,stdout=log,stderr=log,start_new_session=True)
        deadline=time.monotonic()+max(22, 3+len(expected)*.65)
        last_query=0
        while time.monotonic()<deadline and process.poll() is None:
            if time.monotonic()-last_query>.7:
                q=subprocess.run([str(cli),'sessions','list'],env=env,capture_output=True,text=True,timeout=3)
                observation={'code':q.returncode,'output':q.stdout,'stderr':q.stderr}
                if q.returncode==0:
                    inspection=subprocess.run([str(cli),'session','inspect','1','--json'],env=env,capture_output=True,text=True,timeout=3)
                    observation.update(inspect_code=inspection.returncode,inspection=inspection.stdout,inspect_stderr=inspection.stderr)
                if q.returncode==0 and n==24:
                    anon=subprocess.run([str(cli),'session','inspect','1','--json','--anonymize'],env=env,capture_output=True,text=True,timeout=3)
                    observation.update(anonymized_code=anon.returncode,anonymized=anon.stdout)
                if q.returncode==0 and n==30:
                    invalid=[]
                    for selector in ['0','18446744073709551616','invalid']:
                        rejected=subprocess.run([str(cli),'session','inspect',selector,'--json'],env=env,capture_output=True,text=True,timeout=3)
                        invalid.append({'selector':selector,'code':rejected.returncode,'stdout':rejected.stdout,'stderr':rejected.stderr})
                    observation['invalid']=invalid
                observations.append(observation)
                last_query=time.monotonic()
            if report.exists() and 'inspector finished' in report.read_text():break
            time.sleep(.1)
        try: code=process.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGTERM)
            try: code=process.wait(timeout=3)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);code=process.wait()
            if not (report.exists() and 'inspector finished' in report.read_text()): errors.append('app did not finish the scripted actions')
    text=report.read_text() if report.exists() else ''
    if n in (26,27) and 'warning(config)' in (dest/'app.log').read_text():errors.append('keybinding fixture was rejected by the config parser')
    states={}
    for match in re.finditer(r'inspector label=(\S+) placement=(\d+) target=(\d+) owners=(\d+) tools=(\d+) flags=(\d+) keys=(\d+)(?: width=(\d+) height=(\d+))?',text):
        v=[int(x) if x is not None else 0 for x in match.groups()[1:]];states[match[1]]=dict(zip(['placement','target','owners','tools','flags','keys','width','height'],v))
    for tag,placement,tools in expected:
        state=states.get(tag)
        if not state: errors.append(f'missing state {tag}');continue
        if state['placement']!=placement or state['tools']!=tools:errors.append(f'{tag}: expected placement/tools {placement}/{tools}, got {state}')
        if placement and n!=16 and tag!='second' and state['target']!=1:errors.append(f'{tag}: inspection target changed: {state}')
        if tag!='second' and state['owners']!=1:errors.append(f'{tag}: detached presentation created/retained an owner: {state}')
        if not state['flags'] & 8 or state['flags'] & 16 or state['flags'] & 0xff00:errors.append(f'{tag}: ordinary explorer dock changed: {state}')
        if state['flags'] & 32:errors.append(f'{tag}: resize capture did not end')
    if n==3:
        for tag,state in states.items():
            if tag.startswith('resize') and (state['width'] < 800 or state['height'] < 800):errors.append(f'{tag}: 2x minimum viewport was not honored')
    if n==7:
        previous=None
        for tag,state in states.items():
            if tag.startswith('drag') and previous and (state['width'],state['height'])==(previous['width'],previous['height']):errors.append(f'{tag}: divider drag did not resize the inspector')
            previous=state
    if n==4 and 'typed' in states:
        if states['typed']['flags']>>16 != 1:errors.append('detached filter did not accept exactly one character')
        if states['typed']['keys']!=states['detached']['keys']:errors.append('filter key leaked to terminal routing')
        if states.get('owner',{}).get('flags',0)>>16 !=4:errors.append('owner focus changed filter text')
    if n==6:
        exports=sorted((root/'home/.cache/maru/inspector').glob('*.json'))
        if len(exports)!=2:errors.append(f'expected two paused JSON exports, found {len(exports)}')
        elif exports[0].read_bytes()!=exports[1].read_bytes():errors.append('moving the paused inspector changed its frozen snapshot')
        for export in exports:
            if export.stat().st_mode & 0o777 != 0o600:errors.append('export permissions are not owner-only')
            if json.loads(export.read_text()).get('schema')!='maru.inspector.v1':errors.append('invalid exported snapshot schema')
        for tag,state in states.items():
            if tag not in ['start'] and (state['flags'] & 6)!=6:errors.append(f'{tag}: Pin/Paused state lost')
    if n==8 and 'modal' in states and states['modal']['flags']>>16:errors.append('modal key leaked to inspector filter')
    # Assert the native cursor selected by the product NSView, independently of Zig's desired kind.
    expected_cursors={line.split()[2]:line.split()[2].split('_',1)[1] for line in script.splitlines() if line.startswith('inspect-hover ')}
    actual_cursors=dict(re.findall(r'inspector-cursor label=(\S+) actual=(\S+)',text))
    for label,wanted in expected_cursors.items():
        if actual_cursors.get(label)!=wanted:errors.append(f'{label}: native cursor expected {wanted}, got {actual_cursors.get(label)}')
    if 'hover-missing' in text:errors.append('cursor control geometry missing')
    if n==13:
        for tag,state in states.items():
            if tag!='start' and state['flags']>>16!=1:errors.append(f'{tag}: navigation changed filter text')
        if states.get('done',{}).get('keys')!=states.get('start',{}).get('keys'):errors.append('inspector navigation keys leaked to PTY')
    if n in (14,15) and states.get('done',{}).get('keys')!=states.get('start',{}).get('keys'):errors.append('native text/composition input leaked to PTY')
    if n==14:
        for tag,wanted in [('hangul',126),('emoji',128),('backspace',124)]:
            if states.get(tag,{}).get('flags',0)>>16!=wanted:errors.append(f'{tag}: UTF8 query bound/backspace is not {wanted} bytes')
    if n==15:
        for i in range(1,6):
            if states.get(f'p{i}',{}).get('flags',0)>>16!=3*i:errors.append(f'p{i}: composition was lost or committed twice on move')
    if n==16:
        for tag,state in states.items():
            if tag=='start':continue
            wanted=1 if tag=='previous' else 2
            if state['target']!=wanted:errors.append(f'{tag}: expected target {wanted}')
            pinned=tag not in ('following','followAgain','done')
            if bool(state['flags']&2)!=pinned:errors.append(f'{tag}: incorrect Pin/Follow state')
    if n==17:
        exports=sorted((root/'home/.cache/maru/inspector').glob('*.json'))
        if len(exports)!=3:errors.append(f'expected three refresh exports, got {len(exports)}')
        elif exports[0].read_bytes()==exports[1].read_bytes() or exports[1].read_bytes()!=exports[2].read_bytes():errors.append('Paused refresh did not advance exactly once across subsequent placement changes')
    if n==18 and 'reopened' in states:
        if states['reopened']['flags']&6:errors.append('reopening did not restore Live/Follow')
        if states['reopened']['flags']>>16!=1:errors.append('reopening lost the filter')
    if n==21:
        for index in range(5):
            before=next((state for tag,state in states.items() if tag.startswith('p') and state['placement']==index+1),None)
            after=states.get(f'reopened{index}')
            if not before or not after or (before['width'],before['height'])!=(after['width'],after['height']):errors.append(f'placement {index}: close/reopen lost remembered geometry')
    if n==22:
        if not states.get('cleared',{}).get('flags',0)&64 or states['cleared']['flags']>>16:errors.append('first Escape did not clear text while keeping filter focus')
        if states.get('blurred',{}).get('flags',0)&64:errors.append('second Escape did not release attached focus')
        if states.get('terminal',{}).get('keys')!=states['start']['keys']+1:errors.append('attached blur did not restore terminal input')
        if not states.get('windowBlurred',{}).get('flags',0)&64:errors.append('detached Escape released window input ownership')
        if states.get('guarded',{}).get('keys')!=states.get('terminal',{}).get('keys'):errors.append('detached navigation leaked to PTY')
    if n==23:
        exports=sorted((root/'home/.cache/maru/inspector').glob('*.json'))
        if len(exports)!=2 or exports[0].read_bytes()!=exports[1].read_bytes():errors.append('filter/tab/placement mutated the paused diagnostic JSON')
    if n==24:
        exports=sorted((root/'home/.cache/maru/inspector').glob('*.json'))
        if len(exports)!=2:errors.append('privacy toggle did not produce exactly two exports')
        else:
            anon,raw=[json.loads(p.read_text()) for p in exports]
            if str(root/'home') in anon['path']['selected_cwd'] or raw['path']['selected_cwd']!=str(work):errors.append('GUI export redaction/raw contract failed')
            if set(anon)!=set(raw) or anon['schema']!=raw['schema']:errors.append('redaction changed JSON structure')
            if any(p.stat().st_mode&0o777!=0o600 for p in exports):errors.append('privacy export permissions are not0600')
    if n==25:
        if (root/'home/.cache/maru/inspector').read_text()!='occupied':errors.append('save failure overwrote the colliding path')
        if states.get('alive',{}).get('flags',0)>>16!=8:errors.append('save error prevented later input')
    if n==28:
        for tag,wanted in [('saturated',128),('unchanged',128),('mixed',127),('overflow',127),('removed',124)]:
            if states.get(tag,{}).get('flags',0)>>16!=wanted:errors.append(f'{tag}: saturated mixed UTF8 filter expected {wanted} bytes')
    if n in (26,27,28) and states.get('done',{}).get('keys')!=states['start']['keys']:errors.append('filter binding/text key reached terminal routing')
    if n==29:
        for tag in ['left','rightAgain']:
            if states.get(tag,{}).get('width')!=states['widthSaved']['width']:errors.append(f'{tag}: horizontal size was not retained')
        for tag in ['top','bottomAgain']:
            if states.get(tag,{}).get('height')!=states['heightSaved']['height']:errors.append(f'{tag}: vertical size was not retained')
    if 'click-missing' in text: errors.append('a control was missing from the shared product geometry')
    if 'inspector finished' not in text:errors.append('test script did not finish')
    if code not in (0,-signal.SIGTERM): errors.append(f'app exit {code}')
    for path in captures:
        if not path.exists():errors.append(f'missing native Metal capture {path.name}')
        else:subprocess.run(['sips','-s','format','png',str(path),'--out',str(path.with_suffix('.png'))],check=True,stdout=subprocess.DEVNULL)
    successful=[o for o in observations if o['code']==0]
    if not successful:errors.append('no live CLI session round trip')
    for observation in successful:
        if observation.get('inspect_code')!=0:errors.append('live CLI inspect request failed');break
        if json.loads(observation['inspection']).get('schema')!='maru.inspector.v1':errors.append('CLI inspect schema changed');break
    if n==24:
        for observation in successful:
            if observation.get('anonymized_code')!=0:errors.append('CLI anonymized inspection failed');continue
            raw=json.loads(observation['inspection']);anon=json.loads(observation['anonymized'])
            if str(root/'home') in anon['path']['selected_cwd'] or raw['path']['selected_cwd']!=str(work):errors.append('CLI raw/anonymized cwd contract failed')
    if n==30:
        for observation in successful:
            if len(observation.get('invalid',[]))!=3 or any(x['code']==0 for x in observation.get('invalid',[])):errors.append('invalid inspect selector was accepted')
    counts=[len(re.findall(r'^\[\d+\] terminal',o['output'],re.M)) for o in successful]
    if n not in (6,9,16) and any(count!=1 for count in counts):errors.append('detached window changed CLI terminal inventory')
    if n in (6,9,16) and (not counts or max(counts)!=2 or any(count not in (1,2) for count in counts)):errors.append('intentional second source was not represented exactly once')
    if n==9 and counts and counts[-1]!=1:errors.append('closing the second owner retained a terminal')
    result={'round':n,'root':str(root),'passed':not errors,'errors':errors,'states':states,'cli':observations,'captures':[str(p.with_suffix('.png')) for p in captures],'focus_transports':re.findall(r'inspector focus-(?:owner|input) transport=(\S+)',text),'cursors':actual_cursors,'app_exit':code,'harness_cleanup_signal':code==-signal.SIGTERM}
    (dest/'result.json').write_text(json.dumps(result,indent=2))
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,default=pathlib.Path('zig-out/Maru.app/Contents/MacOS/maru-macos-app'));p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--rounds',type=int,default=10);p.add_argument('--start',type=int,default=1)
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=False)
    results=[]
    for n in range(args.start,args.start+args.rounds):
        result=run_round(args.app.resolve(),args.output.resolve(),n);results.append(result)
        print(f'round {n}: {"PASS" if result["passed"] else "FAIL"} {result["errors"]}',flush=True)
        (args.output/'manifest.json').write_text(json.dumps(results,indent=2))
        if not result['passed']:raise SystemExit(1)
    print(f'{len(results)} adversarial AppKit/Metal E2E rounds passed',flush=True)

if __name__=='__main__':main()
