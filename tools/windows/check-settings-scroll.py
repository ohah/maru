"""Windows settings wheel E2E for an isolated copied cache executable.

Requires the default-font, English fixture with sidebar.width.windows=300.
Uses owned HWND messages and guarded screenshots of a 1000x700 window. The
system wheel policy is read without changing it. Config and clipboard remain
untouched. --old-control expects the known ignored-wheel failure, not success.
--stale-context-control expects the older filter-scroll residue bug.
No physical keyboard, mouse or IME behavior is claimed.
"""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,time
from ctypes import wintypes as w
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--state',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--old-control',action='store_true');p.add_argument('--stale-context-control',action='store_true');p.add_argument('--inline-caret',action='store_true');p.add_argument('--double-caret-control',action='store_true');p.add_argument('--scrollbar',action='store_true');p.add_argument('--scrollbar-control',action='store_true');p.add_argument('--gutter-control',action='store_true');args=p.parse_args()
if args.old_control and args.stale_context_control:p.error('Control modes are mutually exclusive')
if args.double_caret_control and (not args.inline_caret or args.old_control or args.stale_context_control):p.error('Double-caret control requires only inline-caret mode')
if args.scrollbar_control and (not args.scrollbar or args.old_control or args.stale_context_control):p.error('Scrollbar control requires scrollbar mode')
if args.gutter_control and (not args.scrollbar or args.scrollbar_control or args.old_control or args.stale_context_control):p.error('Gutter control requires normal scrollbar mode')
if not __debug__:p.error('Run without Python optimization so fixture and clipboard guards remain active')
if os.name!='nt':p.error('Windows is required')
s=json.loads(args.state.read_text(encoding='utf-8-sig'));binary=json.loads(args.binary.read_text());root=Path(s['root']).resolve();assert '.zig-cache' in root.parts
assert Path(s['local']).resolve().is_relative_to(root),'local data must belong to the private fixture'
exe=Path(binary['exe']).resolve();assert hashlib.sha256(exe.read_bytes()).hexdigest()==binary['sha256']
assert '.zig-cache' in exe.parts,'executable must be a private cache copy'
u=c.WinDLL('user32',use_last_error=True);k=c.WinDLL('kernel32',use_last_error=True);g=c.WinDLL('gdi32',use_last_error=True)
u.SetProcessDPIAware();h=s['hwnd']
k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD];k.OpenProcess.restype=w.HANDLE
k.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]
k.CloseHandle.argtypes=[w.HANDLE];k.WaitForSingleObject.argtypes=[w.HANDLE,w.DWORD];k.WaitForSingleObject.restype=w.DWORD
k.GetExitCodeProcess.argtypes=[w.HANDLE,c.POINTER(w.DWORD)];k.GetCurrentThreadId.restype=w.DWORD
u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)];u.GetWindowThreadProcessId.restype=w.DWORD
u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int]
u.SendMessageTimeoutW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t,w.UINT,w.UINT,c.POINTER(c.c_size_t)];u.SendMessageTimeoutW.restype=c.c_ssize_t
u.GetClientRect.argtypes=[w.HWND,c.POINTER(w.RECT)];u.GetWindowRect.argtypes=[w.HWND,c.POINTER(w.RECT)];u.ClientToScreen.argtypes=[w.HWND,c.POINTER(w.POINT)]
u.ShowWindow.argtypes=[w.HWND,c.c_int];u.SetWindowPos.argtypes=[w.HWND,w.HWND,c.c_int,c.c_int,c.c_int,c.c_int,w.UINT]
u.SetForegroundWindow.argtypes=[w.HWND];u.GetForegroundWindow.restype=w.HWND
u.WindowFromPoint.argtypes=[w.POINT];u.WindowFromPoint.restype=w.HWND
u.AttachThreadInput.argtypes=[w.DWORD,w.DWORD,w.BOOL];u.GetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)];u.SetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)]
u.GetDC.argtypes=[w.HWND];u.GetDC.restype=w.HANDLE;u.ReleaseDC.argtypes=[w.HWND,w.HANDLE]
g.CreateCompatibleDC.argtypes=[w.HANDLE];g.CreateCompatibleDC.restype=w.HANDLE
g.CreateCompatibleBitmap.argtypes=[w.HANDLE,c.c_int,c.c_int];g.CreateCompatibleBitmap.restype=w.HANDLE
g.SelectObject.argtypes=[w.HANDLE,w.HANDLE];g.SelectObject.restype=w.HANDLE
g.BitBlt.argtypes=[w.HANDLE,c.c_int,c.c_int,c.c_int,c.c_int,w.HANDLE,c.c_int,c.c_int,w.DWORD]
g.GetDIBits.argtypes=[w.HANDLE,w.HANDLE,w.UINT,w.UINT,c.c_void_p,c.c_void_p,w.UINT]
g.DeleteObject.argtypes=[w.HANDLE];g.DeleteDC.argtypes=[w.HANDLE]
process=k.OpenProcess(0x101000,False,s['pid']);assert process
name=c.create_unicode_buffer(32768);length=w.DWORD(len(name));assert k.QueryFullProcessImageNameW(process,0,name,c.byref(length));assert os.path.normcase(name.value)==os.path.normcase(str(exe))
checks=[];captures=[]

def check_owner():
    pid=w.DWORD();tid=u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==s['pid'],'fixture owner changed'
    cls=c.create_unicode_buffer(128);assert u.GetClassNameW(h,cls,len(cls));assert cls.value=='MaruWindowClass'
    return tid

def send(message,wp=0,lp=0):
    check_owner();result=c.c_size_t();assert u.SendMessageTimeoutW(h,message,wp,lp,2,3000,c.byref(result)),(hex(message),c.get_last_error())
    return result.value

def mouse(message,x,y):return send(message,1 if message==0x201 else 0,((y&65535)<<16)|(x&65535))

@contextlib.contextmanager
def neutral_keyboard():
    tid=check_owner();own=k.GetCurrentThreadId();msg=w.MSG();u.PeekMessageW(c.byref(msg),None,0,0,0)
    assert u.AttachThreadInput(own,tid,True);old=(c.c_ubyte*256)()
    try:
        assert u.GetKeyboardState(old);state=(c.c_ubyte*256)(*old)
        for key in (0x10,0x11,0x12,0x5b,0x5c):state[key]=0
        assert u.SetKeyboardState(state);yield
    finally:u.SetKeyboardState(old);u.AttachThreadInput(own,tid,False)

def key(value):
    with neutral_keyboard():send(0x100,value,1);send(0x101,value,0xc0000001)
    time.sleep(.12)

def probe_caption():
    point=w.POINT(500,16);assert u.ClientToScreen(h,c.byref(point))
    return send(0x84,0,((point.y&65535)<<16)|(point.x&65535))

def wait_caption(expected):
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        if probe_caption()==expected:return
        time.sleep(.03)
    raise AssertionError('popup/native caption state did not settle to '+str(expected))
def opened():wait_caption(1)
def closed():wait_caption(2)
def record(name):checks.append(name);print(name+' passed',flush=True)

def open_menu():
    mouse(0x204,520,220);mouse(0x205,520,220);time.sleep(.3);opened()

def capture(name):
    check_owner();rect=w.RECT();point=w.POINT();assert u.GetClientRect(h,c.byref(rect));assert u.ClientToScreen(h,c.byref(point))
    width,height=rect.right,rect.bottom;assert width==1000 and height==700
    for y in (3,height//2,height-4):
        for x in (3,width//2,width-4):
            under=u.WindowFromPoint(w.POINT(point.x+x,point.y+y));pid=w.DWORD();u.GetWindowThreadProcessId(under,c.byref(pid));assert pid.value==s['pid'],'capture is occluded'
    assert c.WinDLL('dwmapi').DwmFlush()==0
    screen=u.GetDC(None);dc=g.CreateCompatibleDC(screen);bitmap=g.CreateCompatibleBitmap(screen,width,height);assert screen and dc and bitmap
    old=g.SelectObject(dc,bitmap)
    try:
        assert g.BitBlt(dc,0,0,width,height,screen,point.x,point.y,0x40CC0020)
        g.SelectObject(dc,old)
        info=struct.pack('<IiiHHIIiiII',40,width,-height,1,32,0,width*height*4,0,0,0,0);header=c.create_string_buffer(info);data=c.create_string_buffer(width*height*4)
        assert g.GetDIBits(dc,bitmap,0,height,data,header,0)==height
        target=root/(name+'.bmp');target.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data.raw),0,0,54)+info+data.raw);captures.append(str(target));return target
    finally:g.DeleteObject(bitmap);g.DeleteDC(dc);u.ReleaseDC(None,screen)


def ctrl_comma():
    with neutral_keyboard():
        state=(c.c_ubyte*256)();assert u.GetKeyboardState(state);state[0x11]=0x80;assert u.SetKeyboardState(state)
        send(0x100,0xbc,1);send(0x101,0xbc,0xc0000001)
    time.sleep(.25)
def wheel(delta,horizontal=False):
    assert -32768<=delta<=32767
    point=w.POINT(700,150);assert u.ClientToScreen(h,c.byref(point))
    send(0x20e if horizontal else 0x20a,(delta&65535)<<16,((point.y&65535)<<16)|(point.x&65535));time.sleep(.18)
def crop(path):
    raw=path.read_bytes();return b''.join(raw[54+(y*1000+500)*4:54+(y*1000+900)*4] for y in range(100,220))
def search_cursor_block(path):
    # A 6x12 solid bright patch identifies the 8x16 fixture cursor, excluding
    # thin glyph strokes. Restrict this oracle to the stable title-row region.
    raw=path.read_bytes()
    return any(all(min(raw[54+((y+dy)*1000+x+dx)*4:54+((y+dy)*1000+x+dx)*4+3])>=240 for dy in range(12) for dx in range(6)) for y in range(50,70) for x in range(400,650))

def top_thumb(path):
    raw=path.read_bytes()
    # Default-font fixture: published 8px thumb at x=957..965, first row y=95.
    # The old binary's empty gutter is the negative control for this solid patch.
    return all(min(raw[54+(y*1000+x)*4:54+(y*1000+x)*4+3])>80 for y in range(105,125) for x in range(959,963))

def scrollbar_cases():
    initial=capture('scrollbar-initial');baseline=crop(initial)
    if args.scrollbar_control:
        assert not top_thumb(initial),'old binary unexpectedly paints the new scrollbar'
        record('old binary reproduces missing settings scrollbar')
        return
    assert top_thumb(initial),'published scrollbar thumb is not visible'
    record('overflow scrollbar is visible in its reserved gutter')
    mouse(0x201,960,600);time.sleep(.2)
    assert crop(capture('scrollbar-track-jump'))!=baseline,'track press did not scroll'
    mouse(0x202,960,100);time.sleep(.25)
    assert crop(capture('scrollbar-final-release'))==baseline,'release without move did not reach the top'
    record('track jump and no-move final release reach the requested rows')
    mouse(0x201,954,110);mouse(0x205,954,110);mouse(0x200,960,600);mouse(0x202,960,600);time.sleep(.25)
    dragged=crop(capture('scrollbar-foreign-release'))
    if args.gutter_control:
        assert dragged==baseline,'old binary did not reproduce missing gutter capture'
        record('old binary reproduces missing gutter-edge capture')
    else:
        assert dragged!=baseline,'gutter capture or unrelated release broke the thumb drag'
    mouse(0x201,960,600);mouse(0x202,960,100);time.sleep(.25)
    assert crop(capture('scrollbar-restored-top'))==baseline
    record('track release restores rows after gutter control' if args.gutter_control else 'gutter-edge drag survives unrelated button release')
    mouse(0x201,960,110)
    with neutral_keyboard():send(0x102,ord('x'),1)
    time.sleep(.2);mouse(0x200,960,600);mouse(0x202,960,600);key(8);time.sleep(.25)
    assert crop(capture('scrollbar-filter-cancel'))==baseline,'filter change retained the old drag'
    record('filter changes retire captured scrollbar movement')
    mouse(0x201,960,110)
    assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,720,0x40);time.sleep(.25)
    mouse(0x200,960,600);mouse(0x202,960,600)
    assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);time.sleep(.35)
    assert crop(capture('scrollbar-resize-cancel'))==baseline,'resizing retained the old drag geometry'
    record('window resize cancels the old captured geometry')

def search_all():
    # Cross-section search guarantees overflowing rows without resizing the app.
    with neutral_keyboard():send(0x102,ord('/'),1);send(0x102,ord('.'),1)
    time.sleep(.25)
def close_settings():key(0x1b);key(0x1b);closed()
try:
    lines=w.UINT();u.SystemParametersInfoW.argtypes=[w.UINT,w.UINT,c.c_void_p,w.UINT];assert u.SystemParametersInfoW(0x68,0,c.byref(lines),0);assert lines.value>0,'system wheel scrolling disabled; do not modify user settings'
    check_owner();u.ShowWindow(h,5);assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);u.SetForegroundWindow(h);time.sleep(.8)
    config=Path(s['local'])/'maru'/'config';before_config=config.read_bytes()
    closed();ctrl_comma();opened();search_all();baseline=crop(capture('wheel-top'))
    wheel(-40);wheel(-40);assert crop(capture('wheel-fractional'))==baseline;record('fractional deltas wait for a complete notch')
    wheel(-120,True);assert crop(capture('wheel-horizontal'))==baseline;record('horizontal wheel preserves vertical position')
    wheel(-40);down=crop(capture('wheel-down'))
    if args.old_control:
        assert down==baseline;record('old binary reproduces ignored settings wheel')
    else:
        assert down!=baseline,'complete vertical notch did not change actual form pixels';record('completed notch scrolls actual form pixels')
        wheel(120);assert crop(capture('wheel-up'))==baseline;record('opposite notch returns to the original rows')
        wheel(-40);close_settings();ctrl_comma();opened();search_all()
        reopened=crop(capture('wheel-reopened'));wheel(-80);assert crop(capture('wheel-reset-fraction'))==reopened;record('reopened settings do not inherit a partial gesture')
        wheel(-40);assert crop(capture('wheel-reopened-down'))!=reopened;record('new partial gesture completes after reopen')
        with neutral_keyboard():send(0x102,ord('x'),1)
        key(8);time.sleep(.2);filtered=crop(capture('wheel-filter-reset'))
        if args.stale_context_control:
            assert filtered!=reopened;record('old wheel binary reproduces stale filter scroll')
        else:
            assert filtered==reopened;record('filter changes discard the previous scroll position')
    if args.scrollbar:scrollbar_cases()
    if args.inline_caret:
        key(0x1b)
        with neutral_keyboard():
            for cp in '/font.size':send(0x102,ord(cp),1)
        time.sleep(.25)
        assert search_cursor_block(capture('inline-search-owner')),'search cursor oracle has no positive control'
        key(0x0d)
        edit_capture=capture('inline-number-caret')
        if args.double_caret_control:
            assert search_cursor_block(edit_capture),'old binary did not reproduce the double caret'
            record('old binary reproduces inactive search cursor during inline edit')
        else:
            assert not search_cursor_block(edit_capture),'inactive search cursor remains during inline edit'
            record('inactive search cursor disappears while inline edit owns input')
        key(0x1b) # cancel edit, retaining the filter
        record('filtered numeric edit opened and canceled without persisting')
    close_settings();send(0x10)
    if k.WaitForSingleObject(process,12000)!=0:key(0x0d)
    assert k.WaitForSingleObject(process,12000)==0;code=w.DWORD();assert k.GetExitCodeProcess(process,c.byref(code));assert code.value==0
    assert config.read_bytes()==before_config,'scrolling modified config'
    log=(root/'app.log').read_text(encoding='utf-8',errors='replace')
    for name in ['keys_to_shell','bytes_to_shell','grid_mismatches','dock_rebuild_failures']:
        found=re.search(r'\b'+name+r'=(\d+)',log);assert found and int(found[1])==0,(name,found)
    if not args.old_control:
        for name in ['settings_scroll_moves','settings_scroll_peak']:
            found=re.search(r'\b'+name+r'=(\d+)',log);assert found and int(found[1])>0,(name,found)
    # New binaries report request routing, not physical OS candidate placement.
    ime=re.search(r'\bime_settings_caret_updates=(\d+)',log)
    if ime:
        total=re.search(r'\bime_caret_updates=(\d+)',log)
        assert total and 0<int(ime[1])<int(total[1]),'search/terminal IMM caret request routing was not observed'
        record('search and terminal IMM caret requests observed; no physical candidate claim')
    if args.inline_caret:
        inline=re.search(r'\bime_settings_edit_caret_updates=(\d+)',log)
        assert inline and int(inline[1])>0,'inline edit never owned IMM caret requests'
        record('inline editor overrides retained search IMM request owner')
    record('normal exit, config preserved and no shell input')
    args.output.write_text(json.dumps({'binary':binary,'checks':checks,'captures':captures,'exit':code.value,'old_control':args.old_control,'stale_context_control':args.stale_context_control,'inline_caret':args.inline_caret,'double_caret_control':args.double_caret_control,'scrollbar':args.scrollbar,'scrollbar_control':args.scrollbar_control,'gutter_control':args.gutter_control,'system_wheel_lines':lines.value,'input':'synthetic owned HWND; pixels and native wheel messages; no physical input claim'},indent=2))
finally:
    if k.WaitForSingleObject(process,0)!=0:
        try:check_owner();u.SetWindowPos(h,w.HWND(-2),0,0,0,0,0x13);u.ShowWindow(h,0)
        except AssertionError:pass
    k.CloseHandle(process)
