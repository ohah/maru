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
    else:
        raise ValueError(f'unknown adversarial scenario {n}')
    lines.extend(['inspect-report done','mark finished','sleep 400','inspect-finish'])
    return '\n'.join(lines)+'\n', expected, captures


def run_round(app, output, n):
    root = pathlib.Path(tempfile.mkdtemp(prefix='mie-',dir='/tmp'))
    for name in ['home','cache','state','host','backups','work']: (root/name).mkdir()
    (root/'work/README.md').write_text('# Inspector independent dock fixture\n')
    (root/'demo.sh').write_text(f'cd "{root}/work"\nprintf "\\033]0;Inspector E2E {n}\\007\\033]7;file://{root}/work\\007\\033]133;A\\007Inspector E2E ready\\n"\nexec /bin/sh -i\n')
    config=root/'config'
    config.write_text(f'session.keep-alive-after-quit=false\nworkspace.restore=false\nworkspace.root={root}/work\nshell.command=/bin/sh\nshell.args={root}/demo.sh\n')
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
