"""Windows terminal clipboard popup E2E for an explicitly owned cache fixture.

The caller must launch a copied executable under .zig-cache with isolated
HOME/USERPROFILE/LOCALAPPDATA/MARU_CONFIG. State has root/local/pid/hwnd; binary
JSON has head/exe/sha256. The fixture uses sidebar.width.windows=300, English UI,
input.right-click=menu, paste protection=true, bracketed-paste-is-safe=false and
PowerShell's version banner in the first terminal row. No existing clipboard
content is replaced: an empty clipboard is required before any popup input, and
later external clipboard changes are preserved. The fixture is resized to
1000x700. All input is synthetic and PID/path guarded; the focus test transfers
native keyboard focus between owned queues, not global foreground activation.
"""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,time
from ctypes import wintypes as w
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--state',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
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
u.OpenClipboard.argtypes=[w.HWND];u.GetClipboardData.argtypes=[w.UINT];u.GetClipboardData.restype=w.HANDLE
u.SetClipboardData.argtypes=[w.UINT,w.HANDLE];u.SetClipboardData.restype=w.HANDLE
u.GetClipboardOwner.restype=w.HWND;u.GetClipboardSequenceNumber.restype=w.DWORD
k.GlobalAlloc.argtypes=[w.UINT,c.c_size_t];k.GlobalAlloc.restype=w.HANDLE;k.GlobalLock.argtypes=[w.HANDLE];k.GlobalLock.restype=c.c_void_p
k.GlobalUnlock.argtypes=[w.HANDLE];k.GlobalFree.argtypes=[w.HANDLE]
u.GetDC.argtypes=[w.HWND];u.GetDC.restype=w.HANDLE;u.ReleaseDC.argtypes=[w.HWND,w.HANDLE]
g.CreateCompatibleDC.argtypes=[w.HANDLE];g.CreateCompatibleDC.restype=w.HANDLE
g.CreateCompatibleBitmap.argtypes=[w.HANDLE,c.c_int,c.c_int];g.CreateCompatibleBitmap.restype=w.HANDLE
g.SelectObject.argtypes=[w.HANDLE,w.HANDLE];g.SelectObject.restype=w.HANDLE
g.BitBlt.argtypes=[w.HANDLE,c.c_int,c.c_int,c.c_int,c.c_int,w.HANDLE,c.c_int,c.c_int,w.DWORD]
g.GetDIBits.argtypes=[w.HANDLE,w.HANDLE,w.UINT,w.UINT,c.c_void_p,c.c_void_p,w.UINT]
g.DeleteObject.argtypes=[w.HANDLE];g.DeleteDC.argtypes=[w.HANDLE]
u.CreateWindowExW.argtypes=[w.DWORD,w.LPCWSTR,w.LPCWSTR,w.DWORD,c.c_int,c.c_int,c.c_int,c.c_int,w.HWND,w.HANDLE,w.HINSTANCE,c.c_void_p];u.CreateWindowExW.restype=w.HWND
u.DestroyWindow.argtypes=[w.HWND]
u.SetFocus.argtypes=[w.HWND];u.SetFocus.restype=w.HWND;u.GetFocus.restype=w.HWND
k.GetModuleHandleW.argtypes=[w.LPCWSTR];k.GetModuleHandleW.restype=w.HINSTANCE
WNDPROC=c.WINFUNCTYPE(c.c_ssize_t,w.HWND,w.UINT,c.c_size_t,c.c_ssize_t)
u.DefWindowProcW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t];u.DefWindowProcW.restype=c.c_ssize_t
class WNDCLASS(c.Structure):
    _fields_=[('style',w.UINT),('procedure',WNDPROC),('class_extra',c.c_int),('window_extra',c.c_int),('instance',w.HINSTANCE),('icon',w.HICON),('cursor',w.HANDLE),('background',w.HANDLE),('menu',w.LPCWSTR),('name',w.LPCWSTR)]
u.RegisterClassW.argtypes=[c.POINTER(WNDCLASS)];u.RegisterClassW.restype=w.WORD
u.UnregisterClassW.argtypes=[w.LPCWSTR,w.HINSTANCE]
process=k.OpenProcess(0x101000,False,s['pid']);assert process
name=c.create_unicode_buffer(32768);length=w.DWORD(len(name));assert k.QueryFullProcessImageNameW(process,0,name,c.byref(length));assert os.path.normcase(name.value)==os.path.normcase(str(exe))
checks=[];captures=[];clip_touched=False;owned_sequence=None;restored=None

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

@contextlib.contextmanager
def clipboard():
    for _ in range(60):
        if u.OpenClipboard(h):break
        time.sleep(.05)
    else:raise AssertionError('clipboard remained busy; no clipboard action performed')
    try:yield
    finally:u.CloseClipboard()

def write_clipboard(text):
    global clip_touched,owned_sequence
    encoded=text.encode('utf-16-le')+b'\0\0';allocation=k.GlobalAlloc(2,len(encoded));assert allocation
    try:
        pointer=k.GlobalLock(allocation);assert pointer;c.memmove(pointer,encoded,len(encoded));k.GlobalUnlock(allocation)
        with clipboard():
            if not clip_touched:assert u.CountClipboardFormats()==0,'clipboard no longer empty; no content overwritten'
            else:assert u.GetClipboardSequenceNumber()==owned_sequence,'external clipboard change detected; no content overwritten'
            assert u.EmptyClipboard();clip_touched=True
            assert u.SetClipboardData(13,allocation);allocation=None
        owned_sequence=u.GetClipboardSequenceNumber()
    finally:
        if allocation:k.GlobalFree(allocation)

def read_clipboard():
    global owned_sequence
    with clipboard():
        handle=u.GetClipboardData(13);assert handle;pointer=k.GlobalLock(handle);assert pointer
        try:text=c.wstring_at(pointer)
        finally:k.GlobalUnlock(handle)
    if u.GetClipboardOwner()==h and text in ('MARU_POPUP_COPY_PENDING','PowerShell','MENU_PASTE_CANARY','# menu guard A\n# menu guard B'):owned_sequence=u.GetClipboardSequenceNumber()
    return text

def restore_clipboard():
    global clip_touched,restored
    if not clip_touched:return
    with clipboard():
        if u.GetClipboardSequenceNumber()==owned_sequence:
            assert u.EmptyClipboard();restored='original empty clipboard restored'
        else:restored='external clipboard change preserved'
    clip_touched=False

try:
    check_owner();u.ShowWindow(h,5);assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);u.SetForegroundWindow(h);time.sleep(1.5)
    closed()
    write_clipboard('MARU_POPUP_COPY_PENDING')
    open_menu();capture('terminal-popup-open');record('actual popup and native caption ownership')
    key(0x1b);closed();record('Escape consumes and dismisses')
    open_menu();before=w.RECT();assert u.GetWindowRect(h,c.byref(before));mouse(0x201,500,16);mouse(0x202,500,16);time.sleep(.2);closed()
    after=w.RECT();assert u.GetWindowRect(h,c.byref(after));assert bytes(before)==bytes(after);record('outside caption gesture only dismisses')
    open_menu();mouse(0x202,540,225);time.sleep(.2);opened();assert read_clipboard()=='MARU_POPUP_COPY_PENDING';key(0x1b);closed();record('unowned release cannot choose an item')
    open_menu();mouse(0x201,540,225);mouse(0x202,540,250);time.sleep(.2);opened();assert read_clipboard()=='MARU_POPUP_COPY_PENDING';key(0x1b);closed();record('release away from pressed row cannot act')
    # The private PowerShell fixture's first line is its public version banner.
    for _ in range(2):mouse(0x201,315,50);mouse(0x202,315,50);time.sleep(.04)
    time.sleep(.3);open_menu();before_copy=u.GetClipboardSequenceNumber();mouse(0x201,540,225);mouse(0x202,540,225);time.sleep(.4);closed()
    deadline=time.monotonic()+3
    while u.GetClipboardSequenceNumber()==before_copy and time.monotonic()<deadline:time.sleep(.03)
    assert u.GetClipboardSequenceNumber()!=before_copy,'Copy never updated the clipboard'
    assert read_clipboard()=='PowerShell','copy did not match the known fixture word';record('matching pointer selects Copy through OS clipboard')
    open_menu()
    with neutral_keyboard():send(0x102,ord('Z'),1)
    time.sleep(.2);closed();record('typing dismisses without reaching shell')
    write_clipboard('MENU_PASTE_CANARY')
    open_menu();key(0x28);key(0x0d);time.sleep(.6);closed();capture('terminal-popup-paste');record('keyboard Paste reaches the visible terminal')
    write_clipboard('# menu guard A\n# menu guard B')
    open_menu();key(0x28);key(0x0d);time.sleep(.3);closed();record('risky multiline paste follows existing protection')
    open_menu();key(0x1b);closed();record('reopened popup resets selection and dismisses')
    @WNDPROC
    def actor_proc(hwnd,message,wp,lp):return u.DefWindowProcW(hwnd,message,wp,lp)
    actor_class='MaruPrivateFocusProbe'+str(os.getpid());instance=k.GetModuleHandleW(None)
    wc=WNDCLASS(0,actor_proc,0,0,instance,None,None,w.HANDLE(6),None,actor_class);assert u.RegisterClassW(c.byref(wc))
    actor=u.CreateWindowExW(0x08000000,actor_class,'Maru private focus probe',0x80000000,1200,20,160,80,None,None,instance,None);assert actor
    own=k.GetCurrentThreadId();tid=check_owner();attached=False
    try:
        u.ShowWindow(actor,4)
        assert u.AttachThreadInput(own,tid,True);attached=True
        u.SetFocus(h);assert u.GetFocus()==h;time.sleep(.1);closed()
        open_menu();u.SetFocus(actor);assert u.GetFocus()==actor
        u.SetFocus(h);assert u.GetFocus()==h;time.sleep(.5);closed()
    finally:
        if attached:u.AttachThreadInput(own,tid,False)
        u.DestroyWindow(actor);u.UnregisterClassW(actor_class,instance)
    record('native keyboard focus transfer revokes popup')
    capture('terminal-popup-final')
    restore_clipboard()
    send(0x10)
    assert k.WaitForSingleObject(process,12000)==0,'fixture did not exit normally'
    code=w.DWORD();assert k.GetExitCodeProcess(process,c.byref(code));assert code.value==0,code.value
    log=(root/'app.log').read_text(encoding='utf-8',errors='replace')
    def number(name):
        found=re.search(r'\b'+re.escape(name)+r'=(\d+)',log);assert found,name;return int(found[1])
    assert number('copies')==1 and number('copy_bytes')==10
    assert number('pastes')==1 and number('blocked')==1 and number('paste_errors')==0
    assert number('keys_to_shell')==0 and number('bytes_to_shell')==0,'popup input leaked to terminal'
    assert number('right_click_menus')>=10 and number('menu_actions')==3 and number('menu_cells_peak')>0 and number('menu_draw_failures')==0
    assert number('grid_mismatches')==0 and number('dock_rebuild_failures')==0 and number('caption_clicks')==0
    record('normal exit and exact action counters')
finally:
    restore_clipboard()
    if k.WaitForSingleObject(process,0)!=0:
        try:
            check_owner();u.SetWindowPos(h,w.HWND(-2),0,0,0,0,0x13);u.ShowWindow(h,0)
        except AssertionError:pass
    k.CloseHandle(process)
receipt={'head':binary['head'],'exe_sha256':binary['sha256'],'pid':s['pid'],'root':str(root),'input':'synthetic owned HWND; native keyboard focus transfer within attached owned queues; no foreground activation, physical keyboard or IME proof','checks':checks,'captures':captures,'exit':code.value,'clipboard':restored}
args.output.write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt),flush=True)
