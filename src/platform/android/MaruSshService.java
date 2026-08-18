// **SSH 소켓을 드는 포그라운드 서비스.**
//
// 왜 서비스인가 — Android 는 앱이 배경으로 가면 프로세스를 언제든 거둔다. 터미널 세션이 그때
// 끊기면 사용자는 "잠깐 다른 앱 봤더니 접속이 끊겼다" 를 매번 겪는다. 포그라운드 서비스는
// 알림 하나를 대가로 그 회수 대상에서 빠진다(docs/mobile-platform.md §3.0).
//
// **소켓 자체는 여기서 안 만든다.** 붙고 읽고 쓰는 일은 두 host 가 함께 쓰는 C 펌프
// (`src/platform/mobile_host/ssh_pump.c`)가 하고, 이 파일은 **살아 있는 자리**를 만들어 줄
// 뿐이다 — 그래야 iOS 와 같은 코드가 돈다.
//
// `android.*` 만 쓴다(AndroidX 없음 — §1).
package dev.maru;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

public class MaruSshService extends Service {

    static {
        System.loadLibrary("maruchrome");
    }

    private static final String CHANNEL_ID = "maru-ssh";
    private static final int NOTIFICATION_ID = 1;

    /** 접속을 시작한다. 문자열은 네이티브가 복사해 간다. */
    private static native void nativeSshStart(
            String host, int port, String user, byte[] keyPem, String fingerprint);

    /** 끊는다. 스레드가 끝날 때까지 기다린다. */
    private static native void nativeSshStop();

    @Override
    public IBinder onBind(Intent intent) {
        return null; // 붙어서 부를 일이 없다 — 시작·정지뿐이다
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // **알림을 먼저 올린다.** `startForeground` 를 늦게 부르면 OS 가 서비스를 죽인다
        // (ANR 이 아니라 즉사라 로그도 짧다).
        startForeground(NOTIFICATION_ID, buildNotification());
        if (intent != null) {
            String host = intent.getStringExtra("host");
            int port = intent.getIntExtra("port", 22);
            String user = intent.getStringExtra("user");
            byte[] key = intent.getByteArrayExtra("key");
            String fingerprint = intent.getStringExtra("fingerprint");
            if (host != null && user != null && key != null && fingerprint != null) {
                nativeSshStart(host, port, user, key, fingerprint);
                // **키 바이트를 곧바로 지운다.** JVM 배열이라 GC 가 언제 거둘지 모른다 —
                // 그 사이 힙 덤프에 개인키가 남는다.
                java.util.Arrays.fill(key, (byte) 0);
            }
        }
        // 죽으면 다시 띄우되 **인텐트는 다시 안 준다** — 키를 담은 인텐트를 OS 가 들고 있으면
        // 그만큼 오래 남는다. 재접속은 앱이 다시 시작한다.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        nativeSshStop();
        super.onDestroy();
    }

    private Notification buildNotification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "SSH 세션", NotificationManager.IMPORTANCE_LOW);
        // 소리·진동 없이 "살아 있다" 만 알린다.
        channel.setShowBadge(false);
        manager.createNotificationChannel(channel);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("maru")
                .setContentText("SSH 세션 유지 중")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .build();
    }
}
