"""Native Korean IME composition UI check for the isolated default-font fixture.

Uses guarded SendInput mouse/scan codes. This proves OS routing and visible
composition ownership. --candidates also checks Hanja opening and one wide
character commit. Physical keyboard input is not covered.
The prior copied binary is the --native-ui-control negative control.
"""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,time

from ctypes import wintypes as w

from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--state',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--native-ui-control',action='store_true');p.add_argument('--candidates',action='store_true');args=p.parse_args()

if not __debug__:p.error('Run without Python optimization so fixture and clipboard guards remain active')

if os.name!='nt':p.error('Windows is required')

s=json.loads(args.state.read_text(encoding='utf-8-sig'))

binary=json.loads(args.binary.read_text())

root=Path(s['root']).resolve()

assert '.zig-cache' in root.parts

assert Path(s['local']).resolve().is_relative_to(root),'local data must belong to the private fixture'

exe=Path(binary['exe']).resolve()

assert hashlib.sha256(exe.read_bytes()).hexdigest()==binary['sha256']

assert '.zig-cache' in exe.parts,'executable must be a private cache copy'

u=c.WinDLL('user32',use_last_error=True)

k=c.WinDLL('kernel32',use_last_error=True)

g=c.WinDLL('gdi32',use_last_error=True)

u.SetProcessDPIAware()

h=s['hwnd']

k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD]

k.OpenProcess.restype=w.HANDLE

k.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]

k.CloseHandle.argtypes=[w.HANDLE]

k.WaitForSingleObject.argtypes=[w.HANDLE,w.DWORD]

k.WaitForSingleObject.restype=w.DWORD

k.GetExitCodeProcess.argtypes=[w.HANDLE,c.POINTER(w.DWORD)]

k.GetCurrentThreadId.restype=w.DWORD

u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)]

u.GetWindowThreadProcessId.restype=w.DWORD

u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int]

u.SendMessageTimeoutW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t,w.UINT,w.UINT,c.POINTER(c.c_size_t)]

u.SendMessageTimeoutW.restype=c.c_ssize_t

u.GetClientRect.argtypes=[w.HWND,c.POINTER(w.RECT)]

u.GetWindowRect.argtypes=[w.HWND,c.POINTER(w.RECT)]

u.ClientToScreen.argtypes=[w.HWND,c.POINTER(w.POINT)]

u.ShowWindow.argtypes=[w.HWND,c.c_int]

u.SetWindowPos.argtypes=[w.HWND,w.HWND,c.c_int,c.c_int,c.c_int,c.c_int,w.UINT]

u.SetForegroundWindow.argtypes=[w.HWND]

u.GetForegroundWindow.restype=w.HWND

u.WindowFromPoint.argtypes=[w.POINT]

u.WindowFromPoint.restype=w.HWND

u.AttachThreadInput.argtypes=[w.DWORD,w.DWORD,w.BOOL]

u.GetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)]

u.SetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)]

u.GetDC.argtypes=[w.HWND]

u.GetDC.restype=w.HANDLE

u.ReleaseDC.argtypes=[w.HWND,w.HANDLE]

g.CreateCompatibleDC.argtypes=[w.HANDLE]

g.CreateCompatibleDC.restype=w.HANDLE

g.CreateCompatibleBitmap.argtypes=[w.HANDLE,c.c_int,c.c_int]

g.CreateCompatibleBitmap.restype=w.HANDLE

g.SelectObject.argtypes=[w.HANDLE,w.HANDLE]

g.SelectObject.restype=w.HANDLE

g.BitBlt.argtypes=[w.HANDLE,c.c_int,c.c_int,c.c_int,c.c_int,w.HANDLE,c.c_int,c.c_int,w.DWORD]

g.GetDIBits.argtypes=[w.HANDLE,w.HANDLE,w.UINT,w.UINT,c.c_void_p,c.c_void_p,w.UINT]

g.DeleteObject.argtypes=[w.HANDLE]

g.DeleteDC.argtypes=[w.HANDLE]

process=k.OpenProcess(0x101000,False,s['pid'])

assert process

name=c.create_unicode_buffer(32768)

length=w.DWORD(len(name))

assert k.QueryFullProcessImageNameW(process,0,name,c.byref(length))

assert os.path.normcase(name.value)==os.path.normcase(str(exe))

checks=[]

captures=[]

def check_owner():
    pid=w.DWORD();tid=u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==s['pid'],'fixture owner changed'
    cls=c.create_unicode_buffer(128);assert u.GetClassNameW(h,cls,len(cls));assert cls.value=='MaruWindowClass'
    return tid

def send(message,wp=0,lp=0):
    check_owner();result=c.c_size_t();assert u.SendMessageTimeoutW(h,message,wp,lp,2,3000,c.byref(result)),(hex(message),c.get_last_error())
    return result.value

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

imm=c.WinDLL('imm32',use_last_error=True)

imm.ImmGetDefaultIMEWnd.argtypes=[w.HWND]

imm.ImmGetDefaultIMEWnd.restype=w.HWND






u.GetKeyboardLayout.argtypes=[w.DWORD]

u.GetKeyboardLayout.restype=w.HANDLE

u.GetAsyncKeyState.argtypes=[c.c_int]

u.GetAsyncKeyState.restype=c.c_short

class KEY(c.Structure):_fields_=[('vk',w.WORD),('scan',w.WORD),('flags',w.DWORD),('time',w.DWORD),('extra',c.c_size_t)]

class MOUSE(c.Structure):_fields_=[('dx',w.LONG),('dy',w.LONG),('data',w.DWORD),('flags',w.DWORD),('time',w.DWORD),('extra',c.c_size_t)]

class UNION(c.Union):_fields_=[('key',KEY),('mouse',MOUSE)]

class INPUT(c.Structure):_fields_=[('type',w.DWORD),('value',UNION)]

u.SendInput.argtypes=[w.UINT,c.POINTER(INPUT),c.c_int]

u.SendInput.restype=w.UINT

assert c.sizeof(INPUT)==40

observations=[]

ime_window=None

old_open=None

old_conv=None

failure=None

config=Path(s['local'])/'maru'/'config'

before_config=config.read_bytes()

u.GetCursorPos.argtypes=[c.POINTER(w.POINT)]

u.SetCursorPos.argtypes=[c.c_int,c.c_int]

original_cursor=w.POINT()

assert u.GetCursorPos(c.byref(original_cursor))

click_point=None

class GUIINFO(c.Structure):
    _fields_=[('size',w.DWORD),('flags',w.DWORD),('active',w.HWND),('focus',w.HWND),('capture',w.HWND),('menu',w.HWND),('move',w.HWND),('caret',w.HWND),('rect',w.RECT)]
u.GetGUIThreadInfo.argtypes=[w.DWORD,c.POINTER(GUIINFO)]

def foreground():
    tid=check_owner();assert u.GetForegroundWindow()==h,'fixture lost foreground; refuse global input'
    info=GUIINFO();info.size=c.sizeof(GUIINFO);assert u.GetGUIThreadInfo(tid,c.byref(info));assert info.focus==h,'fixture lost keyboard focus; refuse global input'

def os_key(vk=0,scan=0):
    foreground()
    for modifier in (0x10,0x11,0x12,0x5b,0x5c):assert not (u.GetAsyncKeyState(modifier)&0x8000),'modifier held'
    pair=(INPUT*2)();flags=8 if scan else 0
    for i in range(2):pair[i].type=1;pair[i].value.key=KEY(vk,scan,flags|(2 if i else 0),0,0)
    assert u.SendInput(2,pair,c.sizeof(INPUT))==2,'partial native input'
    time.sleep(.35);foreground()

def ime_control(command,value=0):
    foreground();pid=w.DWORD();u.GetWindowThreadProcessId(ime_window,c.byref(pid));assert pid.value==s['pid'],'IME window belongs to another process'
    result=c.c_size_t();assert u.SendMessageTimeoutW(ime_window,0x283,command,value,2,3000,c.byref(result));return result.value

def ime_ui_observation():
    foreground()
    callback_type=c.WINFUNCTYPE(w.BOOL,w.HWND,c.c_ssize_t)
    owned=set();visible=[]
    u.IsWindowVisible.argtypes=[w.HWND];u.IsWindowVisible.restype=w.BOOL
    def visit(window,unused):
        pid=w.DWORD();u.GetWindowThreadProcessId(window,c.byref(pid))
        if pid.value!=s['pid']:return True
        owned.add(window)
        if window==h or not u.IsWindowVisible(window):return True
        cls=c.create_unicode_buffer(128);rect=w.RECT()
        if u.GetClassNameW(window,cls,len(cls)) and u.GetWindowRect(window,c.byref(rect)):
            visible.append({'class':cls.value,'rect':[rect.left,rect.top,rect.right,rect.bottom]})
        return True
    callback=callback_type(visit)
    u.EnumWindows.argtypes=[callback_type,c.c_ssize_t];u.EnumChildWindows.argtypes=[w.HWND,callback_type,c.c_ssize_t]
    u.EnumWindows(callback,0)
    for window in set(owned)|{h,ime_window}:u.EnumChildWindows(window,callback,0)
    point=w.POINT(842,102);assert u.ClientToScreen(h,c.byref(point));under=u.WindowFromPoint(point)
    cls=c.create_unicode_buffer(128);pid=w.DWORD();u.GetClassNameW(under,cls,len(cls));u.GetWindowThreadProcessId(under,c.byref(pid))
    return {'visible_owned_windows':visible,'caret_point_class':cls.value,'caret_point_owned':pid.value==s['pid']}

def activate_by_owned_click():
    global click_point
    check_owner()
    for keycode in (1,2,4,0x10,0x11,0x12,0x5b,0x5c):assert not (u.GetAsyncKeyState(keycode)&0x8000),'user input is active'
    point=w.POINT(450,20);assert u.ClientToScreen(h,c.byref(point))
    assert u.WindowFromPoint(point)==h,'activation point is not owned by fixture'
    left,top,width,height=(u.GetSystemMetrics(n) for n in (76,77,78,79));assert width>1 and height>1
    assert left<=point.x<left+width and top<=point.y<top+height
    x=round((point.x-left)*65535/(width-1));y=round((point.y-top)*65535/(height-1))
    pair=(INPUT*2)()
    for i in range(2):pair[i].type=0;pair[i].value.mouse=MOUSE(x,y,0,0xc001|(4 if i else 2),0,0)
    assert u.WindowFromPoint(point)==h
    assert u.SendInput(2,pair,c.sizeof(INPUT))==2,'activation click injection failed'
    click_point=w.POINT();assert u.GetCursorPos(c.byref(click_point));assert u.WindowFromPoint(click_point)==h;time.sleep(.3)
    observations.append({'activation_click':True,'foreground_is_fixture':u.GetForegroundWindow()==h})
    foreground()

try:
    check_owner();u.ShowWindow(h,5);assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);u.SetForegroundWindow(h);time.sleep(.3);activate_by_owned_click()
    config=Path(s['local'])/'maru'/'config';before_config=config.read_bytes()
    closed();ctrl_comma();opened()
    with neutral_keyboard():
        for cp in '/font.family':send(0x102,ord(cp),1)
    time.sleep(.25);key(0x0d);baseline=capture('os-ime-before')
    ime_window=imm.ImmGetDefaultIMEWnd(h);assert ime_window
    layout=u.GetKeyboardLayout(check_owner());assert (layout&65535)==0x412,hex(layout)
    old_open=ime_control(5);old_conv=ime_control(1)
    observations.append({'layout':hex(layout),'old_open':old_open,'old_conversion':old_conv,'initial':'external IMM context is not used'})
    ime_control(6,1);ime_control(2,old_conv|1)
    observations.append({'open':ime_control(5),'conversion':ime_control(1)})
    os_key(scan=0x13);observations.append({'ui_r':ime_ui_observation()});r_capture=capture('os-ime-r')
    os_key(scan=0x25);observations.append({'ui_rk':ime_ui_observation()});rk_capture=capture('os-ime-rk')
    assert ime_control(5)==1 and ime_control(1)&1,'Korean native conversion is not active'
    record('foreground and native Korean conversion are established')
    def field_pixels(path):
        raw=path.read_bytes()
        return b''.join(raw[54+(y*1000+830)*4:54+(y*1000+875)*4] for y in range(92,115))
    assert field_pixels(baseline)!=field_pixels(r_capture),'native key did not paint a composition preview'
    assert field_pixels(r_capture)!=field_pixels(rk_capture),'second native key did not update composition pixels'
    record('native scan codes update actual composition preview pixels')
    for stage in ('ui_r','ui_rk'):
        sample=next(item[stage] for item in observations if stage in item)
        point_is_app=sample['caret_point_class']=='MaruWindowClass'
        if args.native_ui_control:
            assert not point_is_app and sample['visible_owned_windows'],'old native composition UI was not reproduced'
        else:
            assert point_is_app and not sample['visible_owned_windows'],'default composition popup still covers app paint'
    record('old binary reproduces default composition popup' if args.native_ui_control else 'app paint owns composition while default popup stays hidden')
    if args.candidates:
        def candidates_present():
            sample=ime_ui_observation()
            return [item for item in sample['visible_owned_windows'] if 'candidate' in item['class'].lower()]
        def wait_candidates(wanted):
            deadline=time.monotonic()+1.5
            while time.monotonic()<deadline:
                items=candidates_present()
                if bool(items)==wanted:return items
                time.sleep(.03)
            raise AssertionError('native candidate visibility did not settle to '+str(wanted))
        os_key(vk=0x19)
        candidates=wait_candidates(True)
        assert any(120<=item['rect'][1]<=160 for item in candidates),'candidate popup is not below the fixture field caret'
        observations.append({'native_candidates':candidates})
        capture('os-ime-candidate')
        record('native Hanja candidates open below the field caret')
        os_key(vk=0x31)
        wait_candidates(False)
        selected=capture('os-ime-selected')
        def cursor_starts(path):
            raw=path.read_bytes()
            return [x for x in range(700,940) if all(min(raw[54+(y*1000+xx)*4:54+(y*1000+xx)*4+3])>=240 for y in range(96,108) for xx in range(x,x+6))]
        before_cursor=cursor_starts(baseline);after_cursor=cursor_starts(selected)
        assert before_cursor and after_cursor,'field cursor pixel oracle has no positive control'
        cell_width=before_cursor[-1]-before_cursor[0]+6
        assert after_cursor[-1]-after_cursor[0]+6==cell_width,'cursor width changed during candidate selection'
        assert after_cursor[0]-before_cursor[0]==2*cell_width,'candidate did not commit exactly one wide character'
        observations.append({'candidate_cursor_advance':after_cursor[0]-before_cursor[0],'cell_width':cell_width})
        record('candidate selection commits one wide character without duplicate delivery')

except Exception as error:
    failure=repr(error)
    print('IME UI check failed: '+failure,flush=True)
finally:
    args.output.write_text(json.dumps({'observations':observations,'failure':failure,'stage':'before cleanup','valid':False},indent=2))
    if k.WaitForSingleObject(process,0)!=0:
        try:
            if u.GetForegroundWindow()==h:
                os_key(vk=0x1b)
                if ime_window and old_open is not None:ime_control(2,old_conv);ime_control(6,old_open)
        except Exception as restore_error:
            if failure is None:failure=repr(restore_error)
        try:
            send(0x10)
            if k.WaitForSingleObject(process,12000)!=0:key(0x0d)
            assert k.WaitForSingleObject(process,12000)==0
        except Exception as cleanup_error:
            if failure is None:failure=repr(cleanup_error)
    code=w.DWORD();assert k.GetExitCodeProcess(process,c.byref(code));assert code.value==0,code.value
    assert config.read_bytes()==before_config
    log=(root/'app.log').read_text(encoding='utf-8',errors='replace')
    for counter in ['keys_to_shell','bytes_to_shell']:
        value=re.search(r'\b'+counter+r'=(\d+)',log);assert value and int(value[1])==0,(counter,value)
    record('normal native exit, config preserved and no shell input')
    args.output.write_text(json.dumps({'valid':failure is None,'full_ime_validation':False,'scope':('Native OS composition and Hanja candidate selection in one settings field' if args.candidates else 'Native OS composition UI ownership only'),'native_ui_control':args.native_ui_control,'candidates':args.candidates,'checks':checks,'binary':binary,'observations':observations,'captures':captures,'failure':failure,'exit':code.value,'input':'SendInput scan codes into foreground-owned fixture; native IMM observation; no physical keyboard claim'},indent=2))
    current_cursor=w.POINT()
    if click_point is not None and u.GetCursorPos(c.byref(current_cursor)) and (current_cursor.x,current_cursor.y)==(click_point.x,click_point.y):u.SetCursorPos(original_cursor.x,original_cursor.y)
    k.CloseHandle(process)

print(json.dumps({'observations':observations,'failure':failure},ensure_ascii=False))

if failure:raise SystemExit(1)
