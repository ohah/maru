#!/usr/bin/env python3
"""Published-tree picker E2E: live CLI coordinates -> native NSEvent -> Metal PNG.
Uses isolated HOME. Native callback evidence, not physical HID/WindowServer proof.
"""
import argparse, hashlib, json, os, pathlib, signal, subprocess, tempfile, time


def contains(r, x, y):
    return r['width'] > 0 and r['height'] > 0 and r['x'] <= x < r['x']+r['width'] and r['y'] <= y < r['y']+r['height']


def key(n):
    return None if n is None else (n['source'], n['id'])


def run(app, output, n, sidebar=False):
    dest=output/f'round-{n:02d}';dest.mkdir()
    root=pathlib.Path(tempfile.mkdtemp(prefix='mip-',dir='/tmp'));(root/'home').mkdir();(root/'work').mkdir()
    for directory in ('cache','state','host','backups'):(root/directory).mkdir()
    (root/'demo.sh').write_text(f'cd "{root}/work"\nexec /bin/sh -i\n')
    (root/'work'/'sample.txt').write_text('picker fixture\n')
    config=root/'config';config.write_text(f'session.keep-alive-after-quit=false\nworkspace.restore=false\nworkspace.root={root}/work\nshell.command=/bin/sh\nshell.args={root}/demo.sh\nui.language={"en" if n%2 else "ko"}\n')
    fixture=dest/'point.json';gate=dest/'hover-ok';end=dest/'selected-ok'
    placement=(n-1)%5
    lines=['sleep 1000',f'inspect-click {40+placement}','sleep 500',f'inspect-main-capture {dest}/baseline.ppm','inspect-report ready',f'waitfile {fixture}']
    if n==13:lines+=['inspect-click 13','sleep 200']
    lines+=['inspect-click 48','sleep 350',f'inspect-owner-pointer {fixture} hover','sleep 400',f'inspect-main-capture {dest}/hover.ppm','inspect-report hovered',f'waitfile {gate}']
    if n==11:lines+=['inspect-key 53 U+001B']
    elif n==12:lines+=['inspect-click 48']
    elif n==14:lines+=['inspect-click 13']
    elif n==17:lines+=['inspect-hover 48 tool']
    else:lines+=[f'inspect-owner-pointer {fixture} click']
    if n==19:lines += ['hover 0 0 -10 -10']
    if n==20:lines += ['inspect-click 17','action toggle_inspector']
    if placement==4:lines += [f'inspect-capture {dest}/detached.ppm']
    lines+=['sleep 500',f'inspect-main-capture {dest}/selected.ppm','inspect-report selected',f'waitfile {end}','inspect-finish']
    if sidebar and n<=3:
        lines[-1:-1]=[f'inspect-owner-pointer {fixture} click','sleep 500','inspect-report control',f'waitfile {dest}/control-ok']
    script=dest/'input.txt';script.write_text('\n'.join(lines)+'\n');report=dest/'report.txt'
    env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
    env.update(HOME=str(root/'home'),CFFIXED_USER_HOME=str(root/'home'),MARU_CONFIG=str(config),XDG_CONFIG_HOME=str(root/'home/.config'),XDG_CACHE_HOME=str(root/'cache'),XDG_STATE_HOME=str(root/'state'),MARU_SESSION_HOST_ROOT=str(root/'host'),MARU_EDITOR_BACKUP_ROOT=str(root/'backups'),MARU_NO_WORKSPACE_RESTORE='1',MARU_OPEN_INSPECTOR='1',MARU_INSPECTOR_WITH_DOCK='1',MARU_INSPECTOR_APP_TEST='1',MARU_WEB_OSR_TEST_INPUT=str(script),MARU_WEB_OSR_TEST_REPORT=str(report))
    if 6<=n<=10 or (sidebar and n==5):env.update(MARU_SCREENSHOT=str(dest/'auto.ppm'),MARU_SCREENSHOT_DELAY_MS='60000',MARU_SCREENSHOT_TIMEOUT_MS='70000',MARU_SCREENSHOT_RENDER_SCALE_MILLI='2000')
    if sidebar:
        env.update(MARU_FORCE_SR5_NESTED_TOP="1", MARU_FORCE_GROUP_COLOR="1", MARU_INSPECTOR_TAB="elements")
    observations=[];errors=[];expected=None;hover=None;selected=None;sidebar_before=None;control=None
    with (dest/'app.log').open('w') as log:
        process=subprocess.Popen([str(app)],env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            deadline=time.monotonic()+30
            while time.monotonic()<deadline and process.poll() is None:
                text=report.read_text() if report.exists() else ''
                inventory=subprocess.run([str(app.parent/'maru'),'sessions','list'],env=env,capture_output=True,text=True,timeout=3)
                (dest/'cli-last.txt').write_text(inventory.stdout+inventory.stderr)
                result=subprocess.run([str(app.parent/'maru'),'session','inspect','1','--json'],env=env,capture_output=True,text=True,timeout=3)
                (dest/'inspect-last.txt').write_text(result.stdout+result.stderr)
                if result.returncode==0:
                    data=json.loads(result.stdout);observations.append(data);e=data['elements']
                    if 'label=ready' in text and not fixture.exists():
                        all_nodes=e['nodes'];candidates=[v for v in all_nodes if v['visible_rect']['width']>=4 and v['visible_rect']['height']>=4]
                        if not candidates:raise RuntimeError('no published UI candidates')
                        if sidebar:
                            sidebar_before=[v for v in all_nodes if v['source']=='sidebar']
                            role={1:'tab',2:'tree_item',3:'tree_item',4:'button',5:'button'}[n]
                            preferred=[v for v in candidates if v['source']=='sidebar' and v['role']==role]
                            if n==3:preferred=preferred[1:]
                            if not preferred:raise RuntimeError('missing real sidebar candidate')
                        else:
                            preferred=[v for v in candidates if v['source']==('file_tree' if n%2==0 else 'status_bar')]
                        node=next((v for v in (preferred if sidebar else reversed(preferred or candidates)) if v['action_id'] is not None),(preferred or candidates)[-1]);r=node['visible_rect'];x=r['x']+r['width']/2;y=r['y']+r['height']/2
                        if n==15 or (sidebar and n==4):x=r['x']+.25;y=r['y']+.25
                        if n==16:x=-10;y=-10
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
                        elif n==17:
                            if not e['picking']:errors.append('inspector toolbar hover cancelled picking')
                            if e['hovered'] is not None:errors.append('owner highlight remained over inspector')
                        else:
                            if e['picking']:errors.append('click retained picking')
                            if key(e['selected'])!=key(expected):errors.append('selection mismatch')
                        if sidebar and sidebar_before != [v for v in e['nodes'] if v['source']=='sidebar']:
                            errors.append('Pick changed workspace/group publication (activation, collapse or close)')
                        end.touch()
                    if sidebar and n<=3 and 'label=control' in text and not (dest/'control-ok').exists():
                        control=e
                        if sidebar_before == [v for v in e['nodes'] if v['source']=='sidebar']:
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
    (dest/'observations.json').write_text(json.dumps(observations,indent=2))
    result={'control':control,'sidebar_before':sidebar_before,'mode':'sidebar' if sidebar else 'picker','round':n,'placement':placement,'expected':expected,'hover':hover,'selected':selected,'passed':not errors,'errors':errors,'root':str(root),'transport':'native NSEvent callbacks; CLI session.inspect; Metal readback'}
    (dest/'result.json').write_text(json.dumps(result,indent=2));return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--sidebar',action='store_true');p.add_argument('--start',type=int,default=1);p.add_argument('--rounds',type=int,default=20);args=p.parse_args()
    if args.sidebar and (args.start != 1 or args.rounds != 5):p.error("--sidebar requires --start 1 --rounds 5")
    args.output.mkdir(parents=True,exist_ok=False);results=[]
    for n in range(args.start,args.start+args.rounds):
        r=run(args.app.resolve(),args.output.resolve(),n,args.sidebar);results.append(r);print(n,'PASS' if r['passed'] else 'FAIL',r['errors'],flush=True)
        (args.output/'manifest.json').write_text(json.dumps({'binary_sha256':hashlib.sha256(args.app.read_bytes()).hexdigest(),'rounds':results,'passed':all(v['passed'] for v in results)},indent=2))
        if not r['passed']:raise SystemExit(1)

if __name__=='__main__':main()
