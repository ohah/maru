"""실제 Darwin 알림 자원의 소유권과 취소 후 FD 재사용을 확인한다."""
import os
import subprocess
import sys
import types
import unittest
import external_display_trace as trace


@unittest.skipUnless(sys.platform=='darwin','Darwin notification API')
class ExternalNotification(unittest.TestCase):
    def test_actual_notification_delivery_and_idempotent_cancel(self):
        notice=trace.Notification()
        try:
            subprocess.run(['/usr/bin/notifyutil','-p',notice.name],check=True,stdout=subprocess.DEVNULL)
            notice.wait(1)
        finally:notice.close()
        notice.close()

    def test_cancel_does_not_close_a_reused_descriptor(self):
        notice=trace.Notification();original=notice.lib;old=notice.fd.value;opened=[]
        def cancel(token):
            result=original.notify_cancel(token)
            self.assertEqual(result,0)
            # 취소 직후 같은 번호를 다른 파일에 재사용시킨다. 추가 close는 이 파일을 닫는다.
            for _ in range(32):
                fd=os.open('/dev/null',os.O_RDONLY);opened.append(fd)
                if fd==old:break
            self.assertIn(old,opened)
            return result
        notice.lib=types.SimpleNamespace(notify_cancel=cancel)
        try:
            notice.close()
            os.fstat(old)
            notice.close()
        finally:
            for fd in opened:
                try:os.close(fd)
                except OSError:pass
