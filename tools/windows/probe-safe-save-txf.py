"""Windows-only, opt-in native save investigation; not a production backend.

Run from any directory with Python 3. Uses only disposable files beneath the
repository's .zig-cache. The assigned audit privilege is enabled exclusively on
a duplicate thread token for fixture setup/inspection, never during save.
Microsoft recommends alternatives to TxF; this probe establishes no permission
to adopt it as the editor's default or to weaken pinned-path save contracts.
https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createfiletransactedw
"""
import ctypes as c, tempfile
from ctypes import wintypes as w
from pathlib import Path
k=c.WinDLL('kernel32',use_last_error=True);t=c.WinDLL('ktmw32',use_last_error=True)
t.CreateTransaction.argtypes=[c.c_void_p,c.c_void_p,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.LPWSTR];t.CreateTransaction.restype=w.HANDLE
for name in ('CommitTransaction','RollbackTransaction'):
 getattr(t,name).argtypes=[w.HANDLE];getattr(t,name).restype=w.BOOL
k.CreateFileTransactedW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,c.c_void_p,w.DWORD,w.DWORD,w.HANDLE,w.HANDLE,c.c_void_p,c.c_void_p];k.CreateFileTransactedW.restype=w.HANDLE
k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,c.c_void_p,w.DWORD,w.DWORD,w.HANDLE];k.CreateFileW.restype=w.HANDLE
k.CloseHandle.argtypes=[w.HANDLE]
k.WriteFile.argtypes=[w.HANDLE,c.c_void_p,w.DWORD,c.POINTER(w.DWORD),c.c_void_p];k.WriteFile.restype=w.BOOL
k.SetFilePointerEx.argtypes=[w.HANDLE,c.c_int64,c.POINTER(c.c_int64),w.DWORD];k.SetFilePointerEx.restype=w.BOOL
k.SetEndOfFile.argtypes=[w.HANDLE];k.SetEndOfFile.restype=w.BOOL
k.FlushFileBuffers.argtypes=[w.HANDLE];k.FlushFileBuffers.restype=w.BOOL
k.MoveFileW.argtypes=[w.LPCWSTR,w.LPCWSTR];k.MoveFileW.restype=w.BOOL
k.DeleteFileW.argtypes=[w.LPCWSTR];k.DeleteFileW.restype=w.BOOL
k.GetFileInformationByHandleEx.argtypes=[w.HANDLE,c.c_int,c.c_void_p,w.DWORD];k.GetFileInformationByHandleEx.restype=w.BOOL
invalid=c.c_void_p(-1).value
def checked(ok):
 if not ok:raise c.WinError(c.get_last_error())
def identity(h):
 data=c.create_string_buffer(24);checked(k.GetFileInformationByHandleEx(h,18,data,24));return data.raw

a=c.WinDLL('advapi32',use_last_error=True)
k.GetCurrentProcess.restype=w.HANDLE
a.OpenProcessToken.argtypes=[w.HANDLE,w.DWORD,c.POINTER(w.HANDLE)]
a.DuplicateTokenEx.argtypes=[w.HANDLE,w.DWORD,c.c_void_p,w.DWORD,w.DWORD,c.POINTER(w.HANDLE)]
a.LookupPrivilegeValueW.argtypes=[w.LPCWSTR,w.LPCWSTR,c.c_void_p]
a.AdjustTokenPrivileges.argtypes=[w.HANDLE,w.BOOL,c.c_void_p,w.DWORD,c.c_void_p,c.c_void_p]
a.SetThreadToken.argtypes=[c.c_void_p,w.HANDLE]
a.GetFileSecurityW.argtypes=[w.LPCWSTR,w.DWORD,c.c_void_p,w.DWORD,c.POINTER(w.DWORD)]
a.SetFileSecurityW.argtypes=[w.LPCWSTR,w.DWORD,c.c_void_p]
class Luid(c.Structure):
 _fields_=[('low',w.DWORD),('high',w.LONG)]
class Priv(c.Structure):
 _fields_=[('count',w.DWORD),('luid',Luid),('attributes',w.DWORD)]
base=w.HANDLE();duplicate=w.HANDLE()
checked(a.OpenProcessToken(k.GetCurrentProcess(),10,c.byref(base)))
checked(a.DuplicateTokenEx(base,44,None,2,2,c.byref(duplicate)))
k.CloseHandle(base)
priv=Priv();priv.count=1;priv.attributes=2
checked(a.LookupPrivilegeValueW(None,'SeSecurityPrivilege',c.byref(priv.luid)))
checked(a.AdjustTokenPrivileges(duplicate,False,c.byref(priv),0,None,None))
assert c.get_last_error()==0
def scope(enabled):checked(a.SetThreadToken(None,duplicate if enabled else None))
def snapshot(p):
 needed=w.DWORD();buffer=c.create_string_buffer(65536)
 checked(a.GetFileSecurityW(str(p),15,buffer,len(buffer),c.byref(needed)))
 return buffer.raw[:needed.value]
sd=bytearray(48);sd[0]=1;sd[2:4]=(0xa010).to_bytes(2,'little');sd[12:16]=(20).to_bytes(4,'little')
sd[20]=2;sd[22:24]=(28).to_bytes(2,'little');sd[24:26]=(1).to_bytes(2,'little')
sd[28]=2;sd[29]=0xc0;sd[30:32]=(20).to_bytes(2,'little');sd[32:36]=(1).to_bytes(4,'little')
sd[36]=sd[37]=sd[43]=1
cache=Path(__file__).resolve().parents[2]/'.zig-cache'
cache.mkdir(exist_ok=True)
root=Path(tempfile.mkdtemp(prefix='txf-audit-',dir=cache)).resolve()
try:
 for case in ('commit','rollback','outside-write','outside-rename','outside-delete'):
  p=root/(case+'.txt');p.write_bytes(b'original-long-text');Path(str(p)+':keep').write_bytes(b'named-stream')
  scope(True)
  checked(a.SetFileSecurityW(str(p),0x40000008,c.create_string_buffer(bytes(sd))))
  before=snapshot(p);scope(False)
  denied=c.create_string_buffer(65536);needed=w.DWORD()
  assert not a.GetFileSecurityW(str(p),8,denied,len(denied),c.byref(needed)), 'audit query unexpectedly allowed'
  assert c.get_last_error() in (5,1314)
  tx=t.CreateTransaction(None,None,0,0,0,0,None);assert tx!=invalid
  file=None;done=False
  try:
   file=k.CreateFileTransactedW(str(p),0xc0000000,7,None,3,0x80200000,None,tx,None,None);assert file!=invalid,c.get_last_error()
   before_id=identity(file)
   # The ID guard precedes writes: name replacement must already be fenced here.
   assert not k.MoveFileW(str(p),str(root/'before-write-renamed.txt'))
   assert c.get_last_error()==32
   count=w.DWORD();checked(k.WriteFile(file,c.create_string_buffer(b'new'),3,c.byref(count),None));assert count.value==3
   checked(k.SetEndOfFile(file));checked(k.FlushFileBuffers(file));assert p.read_bytes()==b'original-long-text'
   if case=='outside-write':
    other=k.CreateFileW(str(p),0x40000000,7,None,3,0,None)
    if other!=invalid:k.CloseHandle(other);raise AssertionError('outside writer succeeded')
    assert c.get_last_error()==32
   elif case=='outside-rename':
    assert not k.MoveFileW(str(p),str(root/'moved.txt'));assert c.get_last_error()==32
   elif case=='outside-delete':
    assert not k.DeleteFileW(str(p));assert c.get_last_error()==32
   checked((t.RollbackTransaction if case=='rollback' else t.CommitTransaction)(tx));done=True
   assert p.read_bytes()==(b'original-long-text' if case=='rollback' else b'new')
  finally:
   if not done:t.RollbackTransaction(tx)
   if file not in (None,invalid):k.CloseHandle(file)
   k.CloseHandle(tx)
  scope(True);after=snapshot(p);scope(False)
  assert before==after,'security descriptor changed'
  ordinary=k.CreateFileW(str(p),0x80,7,None,3,0,None)
  if ordinary==invalid:raise c.WinError(c.get_last_error())
  try:assert identity(ordinary)==before_id,'file identity changed'
  finally:k.CloseHandle(ordinary)
  assert Path(str(p)+':keep').read_bytes()==b'named-stream'
  print(case,'PASS: audit read denied during write; full security descriptor and ADS preserved',flush=True)
finally:
 scope(False);k.CloseHandle(duplicate)
 for p in root.iterdir():p.unlink()
 root.rmdir()
