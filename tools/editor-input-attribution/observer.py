"""입력 전에 Time Profiler의 실제 시작 통지를 기다린다. 로그 문구나 고정 sleep은 근거로 쓰지 않는다."""
import ctypes
import os
import select
import signal
import subprocess
import time
import uuid


def diagnostic_environment(environment):
    # Instruments TOC는 대상의 환경을 저장한다. 비밀값의 이름을 추측해 거르는 대신 허용 목록을 쓴다.
    allowed={'PATH','HOME','CODEX_HOME','CLAUDE_CONFIG_DIR','SHELL','USER','LOGNAME','TMPDIR','LANG','LC_ALL','__CF_USER_TEXT_ENCODING'}
    return {k:v for k,v in environment.items() if k in allowed}


def notification_token(data, token):
    if len(data)!=4 or int.from_bytes(data,'big')!=token:
        raise ValueError('unexpected recording notification token')


class Notification:
    def __init__(self,name):
        self.library=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.library.notify_register_file_descriptor.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_int),ctypes.c_int,ctypes.POINTER(ctypes.c_int)]
        self.library.notify_cancel.argtypes=[ctypes.c_int]
        descriptor,token=ctypes.c_int(-1),ctypes.c_int(-1)
        if self.library.notify_register_file_descriptor(name.encode(),ctypes.byref(descriptor),0,ctypes.byref(token))!=0:
            raise RuntimeError('recording notification registration failed')
        self.descriptor,self.token=descriptor.value,token.value

    def wait(self,recorder,timeout):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            if recorder.poll() is not None: raise RuntimeError('recorder exited before start notification')
            if select.select([self.descriptor],[],[],.05)[0]:
                notification_token(os.read(self.descriptor,4),self.token)
                return time.monotonic_ns()
        raise TimeoutError('recording start notification timeout')

    def close(self):
        # notify_cancel은 해당 등록의 fd도 닫는다(SDK notify.h). 두 번 close하지 않는다.
        if self.token is not None:
            token,self.token=self.token,None
            if self.library.notify_cancel(token)!=0: raise RuntimeError('notification cancellation failed')


class Profiler:
    def __init__(self):
        self.process=None
        self.log=None

    def environment(self,environment):
        return diagnostic_environment(environment)

    def start(self,pid,folder):
        name='maru.input-attribution.'+uuid.uuid4().hex
        notification=Notification(name)
        command=['xcrun','xctrace','record','--template','Time Profiler','--attach',str(pid),
                 '--output',str(folder/'profile.trace'),'--notify-tracing-started',name,'--no-prompt']
        try:
            self.log=(folder/'recorder.log').open('xb')
            self.process=subprocess.Popen(command,stdout=self.log,stderr=subprocess.STDOUT,start_new_session=True,env=diagnostic_environment(os.environ))
            started=notification.wait(self.process,20)
            return dict(command=command,recorder_pid=self.process.pid,target_pid=pid,notification_received_ns=started)
        finally: notification.close()

    def stop(self):
        try:
            if self.process is None:return dict(started=False)
            interrupted=False
            try: code=self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                # 호출자는 대상과 생산자의 종료 뒤에만 온다. 실행 중인 편집을 잘라 내지 않는다.
                self.process.send_signal(signal.SIGINT);interrupted=True
                try:code=self.process.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    self.process.kill();self.process.wait();raise RuntimeError('recorder did not stop')
            if code!=0: raise RuntimeError('recorder failed: '+str(code))
            return dict(started=True,exit=code,interrupted_after_target_exit=interrupted,finished_ns=time.monotonic_ns())
        finally:
            if self.log is not None:self.log.close()
