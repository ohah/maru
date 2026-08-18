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

    /** 접속을 시작한다. 문자열은 네이티브가 복사해 간다.
     *
     *  **키는 경로로 넘긴다 — 바이트가 아니다.** 서비스를 시작하는 `Intent` 의 extra 는
     *  `system_server` 를 지나므로, 거기 개인키를 실으면 우리 프로세스 밖으로 나간다.
     *  경로만 넘기고 파일은 네이티브가 우리 프로세스 안에서 읽는다. */
    private static native void nativeSshStart(
            String host, int port, String user, String keyPath, String fingerprint);

    /** 끊는다. 스레드가 끝날 때까지 기다린다. */
    private static native void nativeSshStop();

    @Override
    public IBinder onBind(Intent intent) {
        return null; // 붙어서 부를 일이 없다 — 시작·정지뿐이다
    }

    /** 지금 떠 있는 서비스. 네이티브가 "세션이 끝났다" 고 알릴 때 이것으로 내린다. */
    private static MaruSshService current;

    /** **네이티브가 부른다 — 세션이 끝났다.** 안 내리면 알림이 "유지 중" 인 채로 영원히 남고,
     *  사용자는 끊긴 줄도 모른 채 그 줄을 본다(실측: 서버를 죽여도 서비스가 그대로 있었다). */
    public static void onSessionEnded() {
        MaruSshService s = current;
        if (s == null) return;
        s.stopForeground(STOP_FOREGROUND_REMOVE);
        s.stopSelf();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        current = this;
        // **알림을 먼저 올린다.** `startForeground` 를 늦게 부르면 OS 가 서비스를 죽인다
        // (ANR 이 아니라 즉사라 로그도 짧다).
        startForeground(NOTIFICATION_ID, buildNotification());
        if (intent != null) {
            String host = intent.getStringExtra("host");
            int port = intent.getIntExtra("port", 22);
            String user = intent.getStringExtra("user");
            String keyPath = intent.getStringExtra("identity");
            String fingerprint = intent.getStringExtra("fingerprint");
            if (host != null && user != null && keyPath != null && fingerprint != null) {
                nativeSshStart(host, port, user, keyPath, fingerprint);
            }
        }
        // 죽으면 **다시 안 띄운다.** 재접속은 앱이 정하는 일이고, OS 가 임의로 되살리면
        // 사용자가 안 시킨 접속이 생긴다.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        if (current == this) current = null;
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
