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
import android.app.PendingIntent;
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

    /// **권한을 방금 받았다 — 지금 도는 세션의 알림을 다시 올린다**(M16c).
    ///
    /// 안 하면 그 세션은 **끝날 때까지 안 보인다.** 알림은 권한이 없을 때 올라가면 OS 가 버리고,
    /// 나중에 허용해도 **되살려 주지 않는다**(실측: 허용 직후·5초 뒤·홈으로 나간 뒤 모두 알림
    /// 목록이 비어 있었다). 그런데 사용자가 허용을 누른 이유가 바로 **이 세션**이고, 알림이
    /// 필요해지는 순간은 그 직후 홈으로 나갈 때다.
    ///
    /// **도는 세션이 없으면 아무것도 안 한다** — 알림만 띄우면 없는 세션을 있다고 말하게 된다.
    public static void onNotificationsAllowed() {
        MaruSshService s = current;
        if (s == null) return;
        s.startForeground(NOTIFICATION_ID, s.buildNotification());
        android.util.Log.i("MaruChrome", "MARU_NOTIFY reposted");
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

    /// 알림을 눌렀을 때 앱을 앞으로 가져오는 인텐트.
    ///
    /// **런처를 누른 것과 같은 인텐트다**(`ACTION_MAIN` + `CATEGORY_LAUNCHER`). 그래서 이미 떠
    /// 있는 태스크가 있으면 **그것이 앞으로 온다** — 세션 화면이 둘이 되지 않는다.
    ///
    /// ⚠️ **`FLAG_ACTIVITY_CLEAR_TOP` 을 쓰지 않는다.** 그 플래그는 액티비티를 **재생성**할 수
    /// 있는데, 여기 host 는 `NativeActivity` 라 재생성이 곧 창·Vulkan 스왑체인·글리프 아틀라스를
    /// 다시 세우는 일이다(매니페스트가 `configChanges` 로 피해 둔 바로 그 비용). 살아 있는
    /// 세션으로 돌아가려고 누른 것이 화면을 한 번 끊는 결과가 되면 안 된다.
    ///
    /// `FLAG_IMMUTABLE` 은 API 23+ 이고 우리 최소는 29 다. 이 인텐트는 우리 액티비티를 여는 것
    /// 뿐이라 받는 쪽이 고칠 여지를 줄 이유가 없다.
    private PendingIntent openAppIntent() {
        Intent open = new Intent(this, MaruActivity.class);
        open.setAction(Intent.ACTION_MAIN);
        open.addCategory(Intent.CATEGORY_LAUNCHER);
        open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE);
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
                // **누르면 앱으로 돌아온다**(사용자 요청). 이 알림이 말하는 것은 「세션이 살아
                // 있다」이고, 그것을 본 사람이 하려는 일은 **그 세션으로 가는 것**이다 — 누를
                // 곳이 없으면 런처를 다시 찾아야 한다.
                .setContentIntent(openAppIntent())
                // **우리 심볼을 단다**(사용자 요청 2026-09-16). 그전에는 시스템
                // `stat_notify_sync`(새로고침 화살표)를 빌려 썼다 — 앱 리소스가 없던 때의
                // 선택인데, 지금은 `res/` 가 있고 런처 아이콘도 거기서 온다. 뜻도 어긋났다:
                // 이 알림은 「무언가를 동기화한다」가 아니라 「세션을 들고 있다」다.
                //
                // ⚠️ **런처 아이콘을 그대로 쓸 수 없다.** 상태바는 small icon 의 **알파만 읽어**
                // 자기 색으로 칠하므로(API 21+), 바탕이 있는 통짜 PNG 를 주면 **흰 네모**가 뜬다.
                // 그래서 `assets/icon/render.py` 가 같은 모티프를 **흰 잉크 · 투명 배경**으로 따로
                // 뽑고(`NOTIFICATION`), 24 px 에서도 두 덩이가 붙지 않는지 그 파일의 selftest 가
                // 잰다 — 붙으면 실루엣만 남는 상태바에서 그냥 얼룩이 된다.
                .setSmallIcon(dev.maru.chrome.R.drawable.ic_notification)
                .setOngoing(true)
                .build();
    }
}
