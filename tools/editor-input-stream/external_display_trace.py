"""입력 생산 전 Instruments 연결을 확인하고 앱 밖에서 기록한다."""
import ctypes
import json
import os
from pathlib import Path
import select
import subprocess
import time
import uuid
import submit_display_study
import verify

SCHEMAS=('time-info','metal-application-command-buffer-submissions','metal-command-buffer-completed',
         'ca-client-present-request','ca-client-presented-handler','display-surface-swap',
         'display-compositor-events-interval','display-vsyncs-interval','device-display-info')


class Notification:
    def __init__(self):
        self.name='org.maru.trace.'+uuid.uuid4().hex
        self.lib=ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib')
        self.lib.notify_register_file_descriptor.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_int),ctypes.c_int,ctypes.POINTER(ctypes.c_int)]
        self.lib.notify_cancel.argtypes=[ctypes.c_int]
        self.fd=ctypes.c_int(-1);self.token=ctypes.c_int(-1)
        status=self.lib.notify_register_file_descriptor(self.name.encode(),ctypes.byref(self.fd),0,ctypes.byref(self.token))
        verify.require(status==0 and self.fd.value>=0,'trace notification registration failed')

    def wait(self,seconds):
        verify.require(bool(select.select([self.fd.value],[],[],seconds)[0]),'trace start notification timeout')
        verify.require(len(os.read(self.fd.value,4))==4,'trace start notification malformed')

    def close(self):
        if self.token.value>=0:
            self.lib.notify_cancel(self.token.value);self.token.value=-1
        if self.fd.value>=0:
            try:os.close(self.fd.value)
            except OSError:pass
            self.fd.value=-1


class Marker(submit_display_study.Marker):
    def __init__(self,mode):
        super().__init__('enabled')
        verify.require(mode in ('disabled','enabled'),'external trace mode')
        self.trace_mode=mode;self.child=None;self.notice=None;self.log=None;self.target=None

    def start(self,pid,target):
        self.target=Path(target);begin=time.monotonic_ns()
        if self.trace_mode=='enabled':
            self.notice=Notification();self.log=(self.target/'trace-record.log').open('w')
            command=['xcrun','xctrace','record','--template','Metal System Trace','--time-limit','30s',
                '--output',str(self.target/'recording.trace'),'--attach',str(pid),'--notify-tracing-started',self.notice.name]
            self.child=subprocess.Popen(command,stdout=self.log,stderr=subprocess.STDOUT,start_new_session=True)
            self.notice.wait(10)
            verify.require(self.child.poll() is None,'trace exited before producer')
        connected=time.monotonic_ns()
        # 두 조건의 ready→게시 대기시간을 맞춘다. 연결이 늦으면 실험을 중단한다.
        verify.require(connected-begin<10_000_000_000,'trace missed fixed settling window')
        time.sleep(max(0,10-(time.monotonic_ns()-begin)/1e9))
        return dict(**super().start(pid,target),external_trace_mode=self.trace_mode,trace_start_wait_ns=connected-begin,settle_ns=time.monotonic_ns()-begin)

    def stop(self):
        try:
            if self.child is None:return dict(mode=self.trace_mode)
            try:code=self.child.wait(timeout=35)
            except subprocess.TimeoutExpired:
                self.child.terminate()
                try:self.child.wait(timeout=5)
                except subprocess.TimeoutExpired:self.child.kill();self.child.wait()
                raise ValueError('external trace did not stop after target exit')
            verify.require(code==0,'external trace recording failed')
            exports={}
            for name in SCHEMAS:
                path=self.target/(name+'.xml')
                command=['xcrun','xctrace','export','--input',str(self.target/'recording.trace'),'--xpath',
                    f'/trace-toc/run[@number="1"]/data/table[@schema="{name}"]','--output',str(path)]
                result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
                (self.target/(name+'.export.log')).write_text(result.stdout)
                verify.require(result.returncode==0 and path.is_file(),'trace export failed: '+name)
                exports[name]=verify.sha(path)
            return dict(mode=self.trace_mode,exit=code,exports=exports)
        finally:
            if self.notice:self.notice.close()
            if self.log:self.log.close()
