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
     *  **키는 이 프로세스 안에서만 오간다.** Keystore 가 푼 64바이트를 JNI 로 바로 넘기고
     *  (`Intent` extra 로 넣으면 `system_server` 를 지난다) 넘긴 뒤 배열을 지운다. */
    private static native void nativeSshStart(
            String host, int port, String user, byte[] secret, String fingerprint);

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
            String fingerprint = intent.getStringExtra("fingerprint");
            if (host != null && user != null && fingerprint != null) {
                // **키는 여기서 연다** — Keystore 가 봉인해 둔 것을 풀어 바로 넘기고 지운다.
                //
                // **공개키 한 줄이 먼저 서 있는지도 여기서 본다**(M16b). 정상 흐름에서는
                // `MaruActivity.onCreate` 가 이미 세워 두어 이 줄은 파일이 있는지만 보고 지나간다.
                // 그런데 그때 Keystore 가 실패했다면 키가 **여기서 처음** 만들어지는데, 그러면
                // 봉인된 키는 있는데 화면은 「아직 키가 없습니다」라고 하는 상태가 남는다 —
                // 사용자는 붙지도 못하고 무엇을 서버에 넣어야 할지도 모른다. **같은 함수를
                // 부른다**: 자리가 둘이어도 하는 일은 하나여야 한다.
                MaruKeyStore.ensureKey(this);
                byte[] secret = MaruKeyStore.loadOrCreate(this);
                if (secret == null) {
                    android.util.Log.i("MaruChrome", "MARU_SSH no_key — 접속하지 않는다");
                    stopSelf();
                    return START_NOT_STICKY;
                }
                nativeSshStart(host, port, user, secret, fingerprint);
                java.util.Arrays.fill(secret, (byte) 0);
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
