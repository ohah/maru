#!/usr/bin/env python3
"""Published-tree picker E2E: live CLI coordinates -> native NSEvent -> Metal PNG.
Uses isolated HOME. Native callback evidence, not physical HID/WindowServer proof.
"""
import argparse, hashlib, json, os, pathlib, signal, subprocess, tempfile, time


def contains(r, x, y):
    return r['width'] > 0 and r['height'] > 0 and r['x'] <= x < r['x']+r['width'] and r['y'] <= y < r['y']+r['height']


def key(n):
    return None if n is None else (n['source'], n['id'])


def pane_feature(n):
    if n == 15:return 'close'
    if n in (18,20):return 'plus'
    return ('tab','close','plus','left','right')[(n-1)%5]


def pane_candidate(node, feature):
    if node['source'] != 'pane_tabs':return False
    if feature == 'tab':return node['role'] == 'tab'
    if node['role'] != 'button':return False
    low = node['id'] & 0xffffffff
    if feature == 'close':return 0 < low < 0xfffffffc
    return low == {'plus':0xfffffffc,'left':0xfffffffd,'right':0xfffffffe}[feature]


def file_mode(n):
    return (1,2,0,1,0,0,1,2,1,0,0,1,2,0,2,1,2,1,0,1)[n-1]


def run(app, output, n, sidebar=False, pane_tabs=False, dock_header=False, file_header=False, file_details=False, sidebar_header=False, sidebar_sessions=False):
    dest=output/f'round-{n:02d}';dest.mkdir()
    root=pathlib.Path(tempfile.mkdtemp(prefix='mip-',dir='/tmp'));(root/'home').mkdir();(root/'work').mkdir()
    for directory in ('cache','state','host','backups'):(root/directory).mkdir()
    (root/'demo.sh').write_text(f'cd "{root}/work"\nexec /bin/sh -i\n')
    (root/'work'/'sample.txt').write_text('picker fixture\n')
    file_path=root/'work'/('sample.svg' if n in (4,5,9,10,18) else 'sample.md')
    file_bytes=(b'<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><rect width="80" height="80" fill="#579"/></svg>' if file_path.suffix=='.svg' else b'# Inspector fixture\n\nRead only mode control.\n')
    if file_details:
        file_path=root/'work'/'sample.zig'
        file_bytes=b'<<<<<<< ours\nconst a = 1;\n=======\nconst b = 2;\n>>>>>>> theirs\n'
    if file_header or file_details:file_path.write_bytes(file_bytes)
    config=root/'config';config.write_text(f'session.keep-alive-after-quit=false\nworkspace.restore=false\nworkspace.root={root}/work\nshell.command=/bin/sh\nshell.args={root}/demo.sh\nui.language={"en" if n%2 else "ko"}\n')
    fixture=dest/'point.json';gate=dest/'hover-ok';end=dest/'selected-ok'
    placement=(n-1)%5
    lines=['sleep 1000',f'inspect-click {40+placement}','sleep 500',f'inspect-main-capture {dest}/baseline.ppm','inspect-report ready',f'waitfile {fixture}']
    if file_details:
        lines[:1]=['sleep 1500','inspect-focus-owner','mouse 1 0 0 500 300 0','mouse 3 0 0 500 300 0','key 0 U+0078','sleep 400','inspect-report staged',f'waitfile {dest}/stage-ok','sleep 1800']
    if n==13:lines+=['inspect-click 13','sleep 200','inspect-report pre-pick']
    lines+=['inspect-click 48','sleep 350',f'inspect-owner-pointer {fixture} hover','sleep 400',f'inspect-main-capture {dest}/hover.ppm','inspect-report hovered',f'waitfile {gate}']
    if n==11:lines+=['inspect-key 53 U+001B']
    elif n==12:lines+=['inspect-click 48']
    elif n==14:lines+=['inspect-click 13']
    elif n==17:lines+=['inspect-hover 48 tool']
    else:lines+=[f'inspect-owner-pointer {fixture} click']
    if n==19:lines += ['hover 0 0 -10 -10']
    if n==20:
        if pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions:lines += [f'inspect-capture {dest}/detached.ppm']
        lines += ['inspect-click 17','action toggle_inspector']
        if pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions:lines += ['sleep 350','inspect-click 40','sleep 500']
    if placement==4 and not ((pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions) and n==20):lines += [f'inspect-capture {dest}/detached.ppm']
    lines+=['sleep 500',f'inspect-main-capture {dest}/selected.ppm','inspect-report selected',f'waitfile {end}','inspect-finish']
    if (sidebar and n<=3) or (pane_tabs and n in (1,3)) or ((dock_header or file_header or file_details or sidebar_header) and n==1) or (sidebar_sessions and n in (1,2,3)):
        lines[-1:-1]=[f'inspect-owner-pointer {fixture} click','sleep 500','inspect-report control',f'waitfile {dest}/control-ok']
    if file_details or sidebar_header or sidebar_sessions:
        i=lines.index('inspect-click 48')
        lines[i:i]=[f'inspect-owner-pointer {fixture} hover','inspect-report normal-pointer']
    if (sidebar_header or sidebar_sessions) and n==20:
        i=lines.index('action toggle_inspector')
        lines[i:i]=[f'inspect-owner-pointer {fixture} click','sleep 500']
    script=dest/'input.txt';script.write_text('\n'.join(lines)+'\n');report=dest/'report.txt'
    env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
    env.update(HOME=str(root/'home'),CFFIXED_USER_HOME=str(root/'home'),MARU_CONFIG=str(config),XDG_CONFIG_HOME=str(root/'home/.config'),XDG_CACHE_HOME=str(root/'cache'),XDG_STATE_HOME=str(root/'state'),MARU_SESSION_HOST_ROOT=str(root/'host'),MARU_EDITOR_BACKUP_ROOT=str(root/'backups'),MARU_NO_WORKSPACE_RESTORE='1',MARU_OPEN_INSPECTOR='1',MARU_INSPECTOR_WITH_DOCK='1',MARU_INSPECTOR_APP_TEST='1',MARU_WEB_OSR_TEST_INPUT=str(script),MARU_WEB_OSR_TEST_REPORT=str(report))
    if 6<=n<=10 or (sidebar and n in (5,13)):env.update(MARU_SCREENSHOT=str(dest/'auto.ppm'),MARU_SCREENSHOT_DELAY_MS='60000',MARU_SCREENSHOT_TIMEOUT_MS='70000',MARU_SCREENSHOT_RENDER_SCALE_MILLI='2000')
    if sidebar:
        env.update(MARU_FORCE_SR5_NESTED_TOP="1", MARU_FORCE_GROUP_COLOR="1", MARU_INSPECTOR_TAB="elements")
    if pane_tabs:
        env.pop("MARU_INSPECTOR_WITH_DOCK",None)
        feature=pane_feature(n)
        env.update(MARU_FORCE_TAB_COUNT='12' if feature in ('left','right') else '3',MARU_INSPECTOR_TAB='elements')
        if 6<=n<=10:env['MARU_FORCE_SPLIT']='1'
        if n==13:env.update(MARU_SCREENSHOT=str(dest/'auto.ppm'),MARU_SCREENSHOT_DELAY_MS='60000',MARU_SCREENSHOT_TIMEOUT_MS='70000',MARU_SCREENSHOT_RENDER_SCALE_MILLI='2000')
    if dock_header:env.update(MARU_INSPECTOR_TAB="elements",MARU_INSPECTOR_WITH_DOCK="header-wide",MARU_FT_WINDOW_SIZE="1400x900")
    if file_header or file_details:
        env.pop('MARU_INSPECTOR_WITH_DOCK',None)
        env.update(MARU_INSPECTOR_TAB='elements',MARU_FILE_PANEL=str(file_path),MARU_FT_WINDOW_SIZE='1400x900')
        if 6<=n<=10:env['MARU_FORCE_SPLIT']='1'
    if sidebar_header:
        env.pop('MARU_INSPECTOR_WITH_DOCK',None)
        env.update(MARU_INSPECTOR_TAB='elements',MARU_FT_WINDOW_SIZE='1400x900')
        config.write_text(config.read_text()+'sidebar.width=240\n')
        if 6<=n<=10:env.update(MARU_COLLAPSE_SIDEBAR=str((1,9,10,20,3)[n-6]),MARU_FORCE_SPLIT='1')
    if sidebar_sessions:
        env.pop('MARU_INSPECTOR_WITH_DOCK',None)
        env.update(MARU_INSPECTOR_TAB='elements',MARU_FT_WINDOW_SIZE='1400x900',MARU_FORCE_TAB_COUNT='3')
        config.write_text(config.read_text()+'sidebar.width=240\n')
        if 6<=n<=10:env['MARU_FORCE_SPLIT']='1'
    observations=[];errors=[];expected=None;hover=None;selected=None;sidebar_before=None;control=None;target=None
    with (dest/'app.log').open('w') as log:
        process=subprocess.Popen([str(app)],env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            deadline=time.monotonic()+(60 if dock_header or file_header or file_details or sidebar_header or sidebar_sessions else 30)
            while time.monotonic()<deadline and process.poll() is None:
                text=report.read_text() if report.exists() else ''
                inventory=subprocess.run([str(app.parent/'maru'),'sessions','list'],env=env,capture_output=True,text=True,timeout=10 if dock_header or file_header or file_details or sidebar_header or sidebar_sessions else 3)
                (dest/'cli-last.txt').write_text(inventory.stdout+inventory.stderr)
                result=subprocess.run([str(app.parent/'maru'),'session','inspect','1','--json'],env=env,capture_output=True,text=True,timeout=10 if dock_header or file_header or file_details or sidebar_header or sidebar_sessions else 3)
                (dest/'inspect-last.txt').write_text(result.stdout+result.stderr)
                if result.returncode==0:
                    data=json.loads(result.stdout);observations.append(data);e=data['elements']
                    if file_details and 'label=staged' in text and not (dest/'stage-ok').exists():
                        file_bytes+=b'// external update\n'
                        file_path.write_bytes(file_bytes)
                        (dest/'stage-ok').touch()
                    if 'label=ready' in text and not fixture.exists():
                        all_nodes=e['nodes'];candidates=[v for v in all_nodes if v['visible_rect']['width']>=4 and v['visible_rect']['height']>=4]
                        if not candidates:raise RuntimeError('no published UI candidates')
                        if sidebar_sessions:
                            sidebar_before=[v for v in all_nodes if v['source']=='sidebar']
                            slot=1 if n in (1,4,6,9,11,14,17,20) else 3 if n in (3,8,10,12,18) else 2
                            preferred=[v for v in candidates if v['source']=='sidebar' and v['id']==0x5342000000000000+1+slot*2]
                            if not preferred:raise RuntimeError('missing canonical sidebar session row '+str(slot))
                        elif sidebar_header:
                            sidebar_before=[v for v in all_nodes if v['source']=='sidebar_header']
                            part=(3,1,2,4,0,3,4,3,4,4,2,4,0,1,2,0,3,0,4,3)[n-1]
                            preferred=[v for v in candidates if v['source']=='sidebar_header' and v['id']==0x5348000000000000+1+part]
                            if not preferred:raise RuntimeError('missing real sidebar header part '+str(part)+' nodes='+str(sidebar_before))
                        elif sidebar:
                            sidebar_before=[v for v in all_nodes if v['source']=='sidebar']
                            role={1:'tab',2:'tree_item',3:'tree_item',4:'button',5:'button'}[n-10 if n>=11 else n]
                            preferred=[v for v in candidates if v['source']=='sidebar' and v['role']==role]
                            if n in (3,13):preferred=preferred[1:]
                            if not preferred:raise RuntimeError('missing real sidebar candidate')
                        elif file_details:
                            sidebar_before=[v for v in all_nodes if v['source']=='file_header_details']
                            part=(4,0,4,3,0,0,3,4,3,4,4,3,0,4,3,0,4,3,0,4)[n-1]
                            preferred=[v for v in candidates if v['source']=='file_header_details' and v['id']==0x4644000000000000+1+part]
                            if not preferred:raise RuntimeError('missing real file header detail '+str(part)+' nodes='+str(sidebar_before))
                        elif file_header:
                            sidebar_before=[v for v in all_nodes if v['source']=='file_header']
                            preferred=[v for v in candidates if v['source']=='file_header' and v['id']==0x4648000000000000+1+file_mode(n)]
                            if not preferred:raise RuntimeError('missing real file mode candidate '+str(file_mode(n)))
                        elif dock_header:
                            sidebar_before=[v for v in all_nodes if v['source']=='dock_header']
                            wanted=0x444f434b00000000+(0x100+(n-2) if n in (2,3) else 1+(1 if n==1 else (n-1)%6))
                            preferred=[v for v in candidates if v['source']=='dock_header' and v['id']==wanted]
                            if not preferred:raise RuntimeError('missing real dock header candidate '+str(wanted))
                        elif pane_tabs:
                            sidebar_before=[v for v in all_nodes if v['source']=='pane_tabs']
                            preferred=[v for v in candidates if pane_candidate(v,pane_feature(n))]
                            if not preferred:raise RuntimeError('missing real pane tab candidate '+pane_feature(n))
                        else:
                            preferred=[v for v in candidates if v['source']==('file_tree' if n%2==0 else 'status_bar')]
                        node=next((v for v in (preferred if sidebar or pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions else reversed(preferred or candidates)) if v['action_id'] is not None),(preferred or candidates)[-1]);r=node['visible_rect'];x=r['x']+r['width']/2;y=r['y']+r['height']/2
                        if n==15 or (sidebar and n==4):x=r['x']+.25;y=r['y']+.25
                        if n==16:x=-10;y=-10
                        target=node
                        if (sidebar or pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions) and n==15:x=r['x']+r['width'];y=r['y']+r['height']/2
                        expected=next((v for v in reversed(all_nodes) if contains(v['visible_rect'],x,y)),None)
                        fixture.write_text(json.dumps({'x':x,'y':y}))
                    if 'label=hovered' in text and not gate.exists():
                        hover=e
                        expected_cursor='arrow' if n==16 else 'crosshair'
                        if f'phase=hover cursor={expected_cursor}' not in text:errors.append(f'native picker cursor was not {expected_cursor}')
                        if f'placement={placement+1}' not in text:errors.append('native dock placement mismatch')
                        if key(e['hovered'])!=key(expected):errors.append(f'hover mismatch: {key(e["hovered"])} != {key(expected)}')
                        if not e['picking']:errors.append('pick did not activate/resume')
                        gate.touch()
                    if 'label=selected' in text and not end.exists():
                        selected=e
                        if n in (11,12,14):
                            if e['picking']:errors.append('cancel/pause retained picking')
                            if e['selected'] is not None:errors.append('cancel selected a target')
                        elif (pane_tabs or dock_header or file_header or file_details or sidebar_header or sidebar_sessions) and n==20:
                            if e['picking'] or e['selected'] is not None:errors.append('reopened geometry reused a stale pane tab selection')
                        elif n==17:
                            if not e['picking']:errors.append('inspector toolbar hover cancelled picking')
                            if e['hovered'] is not None:errors.append('owner highlight remained over inspector')
                        else:
                            if e['picking']:errors.append('click retained picking')
                            if key(e['selected'])!=key(expected):errors.append('selection mismatch')
                        if sidebar and sidebar_before != [v for v in e['nodes'] if v['source']=='sidebar']:
                            errors.append('Pick changed workspace/group publication (activation, collapse or close)')
                        if (file_header or file_details) and n!=20 and sidebar_before!=[v for v in e['nodes'] if v['source']==('file_header_details' if file_details else 'file_header')]:
                            errors.append('Pick changed actual file mode publication')
                        if sidebar_sessions and n!=20 and sidebar_before!=[v for v in e['nodes'] if v['source']=='sidebar']:errors.append('Pick executed a session row action')
                        if sidebar_header and n!=20 and sidebar_before!=[v for v in e['nodes'] if v['source']=='sidebar_header']:errors.append('Pick executed a sidebar header action')
                        if dock_header and n!=20 and sidebar_before!=[v for v in e['nodes'] if v['source']=='dock_header']:
                            errors.append('Pick changed dock view/action publication')
                        if pane_tabs:
                            after=[v for v in e['nodes'] if v['source']=='pane_tabs']
                            normalize=lambda rows:[{k:v for k,v in row.items() if k not in ('generation','rect','visible_rect')} for row in rows]
                            if (normalize(sidebar_before)!=normalize(after) if n==20 else sidebar_before!=after):
                                errors.append('Pick changed pane tab publication (activation, close, plus or scroll)')
                        end.touch()
                    if ((sidebar and n<=3) or (pane_tabs and n in (1,3)) or ((dock_header or file_header or file_details or sidebar_header) and n==1) or (sidebar_sessions and n in (1,2,3))) and 'label=control' in text and not (dest/'control-ok').exists():
                        control=e
                        if sidebar_before == [v for v in e['nodes'] if v['source']==('sidebar_header' if sidebar_header else 'file_header_details' if file_details else 'file_header' if file_header else 'dock_header' if dock_header else 'pane_tabs' if pane_tabs else 'sidebar')]:
                            errors.append('normal pointer control did not activate/collapse product row')
                        (dest/'control-ok').touch()
                if 'inspector finished' in text:break
                time.sleep(.12)
            if hover is None or selected is None:errors.append('missing live hover/selection observations')
        except Exception as exc:errors.append(str(exc))
        finally:
            if process.poll() is None:
                try:process.wait(timeout=2)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=4)
    for name in ('baseline','hover','selected') + (('detached',) if placement==4 else ()):
        ppm=dest/f'{name}.ppm'
        if not ppm.exists():errors.append(f'missing Metal capture {name}')
        else:subprocess.run(['sips','-s','format','png',str(ppm),'--out',str(ppm.with_suffix('.png'))],stdout=subprocess.DEVNULL,check=True)
    if expected is not None and (dest/'baseline.ppm').exists() and (dest/'hover.ppm').exists():
        before=(dest/'baseline.ppm').read_bytes().split(b'\n',3);after=(dest/'hover.ppm').read_bytes().split(b'\n',3)
        width,height=map(int,before[1].split());r=expected['visible_rect'];x=int(r['x']);y=int(r['y']);w=int(r['width']);h=int(r['height'])
        if before[1]!=after[1] or not (0<=x<x+w<=width and 0<=y<y+h<=height):errors.append('outline ROI outside Metal capture')
        else:
            edge=[(xx,yy) for yy in range(y,y+h) for xx in range(x,x+w) if xx-x<2 or x+w-xx<=2 or yy-y<2 or y+h-yy<=2]
            changed=sum(before[3][(yy*width+xx)*3:(yy*width+xx)*3+3]!=after[3][(yy*width+xx)*3:(yy*width+xx)*3+3] for xx,yy in edge)
            (dest/'pixels.json').write_text(json.dumps({'outline_edge_changed_pixels':changed,'roi':[x,y,w,h]}))
            if changed==0:errors.append('hover did not paint the inspected boundary')
    file_unchanged=not (file_header or file_details) or file_path.read_bytes()==file_bytes
    if not file_unchanged:errors.append('inspection or mode control changed file bytes')
    (dest/'observations.json').write_text(json.dumps(observations,indent=2))
    result={'file_unchanged':file_unchanged,'target':target,'control':control,'sidebar_before':sidebar_before,'fixture_bytes':file_bytes.hex() if file_details else None,'mode':'sidebar_sessions' if sidebar_sessions else 'sidebar_header' if sidebar_header else 'file_header_details' if file_details else 'file_header' if file_header else 'dock_header' if dock_header else 'pane_tabs' if pane_tabs else 'sidebar' if sidebar else 'picker','round':n,'placement':placement,'expected':expected,'hover':hover,'selected':selected,'passed':not errors,'errors':errors,'root':str(root),'transport':'native NSEvent callbacks; CLI session.inspect; Metal readback'}
    (dest/'result.json').write_text(json.dumps(result,indent=2));return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--sidebar',action='store_true');p.add_argument('--pane-tabs',action='store_true');p.add_argument('--dock-header',action='store_true');p.add_argument('--file-header',action='store_true');p.add_argument('--file-details',action='store_true');p.add_argument('--sidebar-header',action='store_true');p.add_argument('--sidebar-sessions',action='store_true');p.add_argument('--start',type=int,default=1);p.add_argument('--rounds',type=int,default=20);args=p.parse_args()
    if args.sidebar and (args.start not in (1,11) or args.rounds != 5):p.error("--sidebar requires --start 1 or 11 and --rounds 5")
    if sum((args.sidebar,args.pane_tabs,args.dock_header,args.file_header,args.file_details,args.sidebar_header,args.sidebar_sessions))>1:p.error("choose one product scope")
    if args.pane_tabs and (args.start != 1 or args.rounds != 20):p.error("--pane-tabs requires --start 1 --rounds 20")
    if args.dock_header and (args.start != 1 or args.rounds != 20):p.error("--dock-header requires all 20 rounds")
    if args.sidebar_sessions and (args.start != 1 or args.rounds != 20):p.error("--sidebar-sessions requires all 20 rounds")
    if args.sidebar_header and (args.start != 1 or args.rounds != 20):p.error("--sidebar-header requires all 20 rounds")
    if args.file_details and (args.start != 1 or args.rounds != 20):p.error("--file-details requires all 20 rounds")
    if args.file_header and (args.start != 1 or args.rounds != 20):p.error("--file-header requires all 20 rounds")
    args.output.mkdir(parents=True,exist_ok=False);results=[]
    for n in range(args.start,args.start+args.rounds):
        r=run(args.app.resolve(),args.output.resolve(),n,args.sidebar,args.pane_tabs,args.dock_header,args.file_header,args.file_details,args.sidebar_header,args.sidebar_sessions);results.append(r);print(n,'PASS' if r['passed'] else 'FAIL',r['errors'],flush=True)
        (args.output/'manifest.json').write_text(json.dumps({'binary_sha256':hashlib.sha256(args.app.read_bytes()).hexdigest(),'rounds':results,'passed':all(v['passed'] for v in results)},indent=2))
        if not r['passed']:raise SystemExit(1)

if __name__=='__main__':main()
