// **SSH 개인키를 이 기기에 봉인해 둔다.**
//
// Android Keystore 는 **임의 바이트를 담지 못한다** — 키(AES·EC·RSA)만 든다. 우리 개인키는
// ed25519 씨앗 32바이트이고 서명은 코어가 직접 하므로(Keystore 가 대신 서명해 줄 수 없다),
// 표준적인 방법은 **Keystore 의 AES 키로 감싸는 것**이다: 그 AES 키는 기기 밖으로 못 나가고
// (가능하면 하드웨어가 든다), 감싼 결과만 앱 저장소에 둔다.
//
// 그러면 파일을 통째로 꺼내 가도 다른 기기에서는 못 푼다 — 계약 §3.4 의 "개인키가 기기 밖으로
// 나갈 일이 없다" 를 이 플랫폼에서 지키는 방식이다.
//
// `android.*` 만 쓴다(AndroidX 없음 — docs/mobile-platform.md §1).
package dev.maru;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

public final class MaruKeyStore {

    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String ALIAS = "maru-ssh-wrap";
    private static final String FILE = "ssh_key.bin";
    /// GCM 논스 길이(바이트). 파일 앞에 그대로 붙인다 — 비밀이 아니다.
    private static final int IV_LEN = 12;
    private static final int TAG_BITS = 128;

    private MaruKeyStore() {}

    /** 공개키 한 줄을 담아 두는 파일. **개인키를 안 열고** 그 줄을 보여 주려고 둔다 —
     *  다시 켤 때마다 Keystore 를 열어 봉인을 풀 이유가 없다(계약 §3.4). */
    private static final String PUB_FILE = "id_ed25519.pub";

    /** **이 기기의 키를 첫 실행에 세운다**(M16b). `.pub` 가 없으면 키를 열고(없으면 만들고)
     *  그 한 줄을 남긴다 — 그 줄이 있어야 서버 `authorized_keys` 에 넣을 수 있고, 그래야
     *  **등록보다 먼저** 붙을 준비가 끝난다.
     *
     *  **여기가 Java 인 이유**: 네이티브 스레드에서 `FindClass` 로 이 클래스를 찾으면 시스템
     *  클래스로더를 보아 조용히 못 찾는다(실측 `cls=0x0`). 그래서 예전에는 이 일이 아예 안
     *  일어났고, 사용자는 서버를 등록하는 화면에서 「아직 키가 없습니다」만 봤다. Java 에서
     *  시작한 호출은 올바른 클래스로더 위에 있다.
     *
     *  **이미 있으면 아무것도 안 한다** — 여는 일도 쓰는 일도 없다. */
    public static void ensureKey(Context ctx) {
        File pub = new File(ctx.getFilesDir(), PUB_FILE);
        if (pub.exists()) return;
        byte[] secret = loadOrCreate(ctx);
        if (secret == null) return; // 이유는 loadOrCreate 가 이미 남겼다
        String line = nativeKeyLine(secret);
        java.util.Arrays.fill(secret, (byte) 0); // 개인키 사본은 바로 지운다
        if (line == null || line.isEmpty()) {
            android.util.Log.i("MaruChrome", "MARU_SSH public_key_line_failed");
            return;
        }
        // **임시 파일에 쓰고 바꿔치기한다**(봉인 파일과 같은 규율). 반쪽 파일이 남으면 그 뒤로
        // 이 함수는 "있다" 고 보고 넘어가, 잘린 공개키를 화면이 보여 준다.
        File tmp = new File(pub.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write((line + "\n").getBytes("UTF-8"));
        } catch (Exception e) {
            android.util.Log.i("MaruChrome", "MARU_SSH pub_write_failed " + e);
            return;
        }
        if (!tmp.renameTo(pub)) {
            android.util.Log.i("MaruChrome", "MARU_SSH pub_rename_failed");
            return;
        }
        android.util.Log.i("MaruChrome", "MARU_SSH public_key_ready");
    }

    /** 봉인된 키에서 `authorized_keys` 한 줄을 만든다. **형식은 코어가 소유한다**
     *  (`maru_mobile_ssh_public_key_line`) — Java 가 조립하면 두 벌이 된다. */
    private static native String nativeKeyLine(byte[] secret);

    /** 봉인된 키를 열거나, 없으면 **새로 만들어 봉인**한다. 실패하면 null. */
    public static byte[] loadOrCreate(Context ctx) {
        File file = new File(ctx.getFilesDir(), FILE);
        if (file.exists()) {
            byte[] opened = open(file);
            if (opened != null) return opened;
            // **못 열면 새로 만들지 않는다.** 새로 만들면 서버에 등록해 둔 공개키가 하루아침에
            // 안 맞게 되고, 사용자는 "어제까지 되던 것이 안 된다" 를 겪는다 — 왜인지도 모른다.
            android.util.Log.i("MaruChrome", "MARU_SSH sealed_key_unreadable — 새로 만들지 않는다");
            return null;
        }
        byte[] secret = nativeGenerateKey();
        if (secret == null) return null;
        if (!seal(file, secret)) {
            java.util.Arrays.fill(secret, (byte) 0);
            return null;
        }
        return secret;
    }

    /** 네이티브가 ABI 로 키를 만든다(씨앗은 OS 난수). **바이트만 준다** — 그 줄을 남기는 것은
     *  위 `ensureKey` 다(경로를 아는 쪽이 쓴다). */
    private static native byte[] nativeGenerateKey();

    private static SecretKey wrapKey() throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE);
        ks.load(null);
        KeyStore.Entry entry = ks.getEntry(ALIAS, null);
        if (entry instanceof KeyStore.SecretKeyEntry) {
            return ((KeyStore.SecretKeyEntry) entry).getSecretKey();
        }
        KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
        gen.init(new KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // **잠금 화면을 요구하지 않는다.** 요구하면 배경에서 세션을 되살릴 때 풀 수
                // 없어 접속이 끊긴다 — 그 정책은 화면(S9b)이 생긴 뒤 사용자가 고를 일이다.
                .build());
        return gen.generateKey();
    }

    private static boolean seal(File file, byte[] secret) {
        try {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, wrapKey());
            byte[] iv = c.getIV();
            byte[] body = c.doFinal(secret);
            // **임시 파일에 쓰고 바꿔치기한다.** 덮어쓰다 죽으면 반쪽 파일이 남고, 그 뒤로는
            // 영영 못 연다(위 "못 열면 새로 만들지 않는다" 와 겹쳐 접속 불가가 된다).
            File tmp = new File(file.getPath() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(iv);
                out.write(body);
            }
            if (!tmp.renameTo(file)) {
                android.util.Log.i("MaruChrome", "MARU_SSH seal_rename_failed");
                return false;
            }
            return true;
        } catch (Exception e) {
            android.util.Log.i("MaruChrome", "MARU_SSH seal_failed " + e);
            return false;
        }
    }

    private static byte[] open(File file) {
        try {
            byte[] all = new byte[(int) file.length()];
            try (FileInputStream in = new FileInputStream(file)) {
                int off = 0;
                while (off < all.length) {
                    int n = in.read(all, off, all.length - off);
                    if (n <= 0) break;
                    off += n;
                }
            }
            if (all.length <= IV_LEN) return null;
            byte[] iv = new byte[IV_LEN];
            System.arraycopy(all, 0, iv, 0, IV_LEN);
            byte[] body = new byte[all.length - IV_LEN];
            System.arraycopy(all, IV_LEN, body, 0, body.length);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, wrapKey(), new GCMParameterSpec(TAG_BITS, iv));
            return c.doFinal(body);
        } catch (Exception e) {
            android.util.Log.i("MaruChrome", "MARU_SSH open_failed " + e);
            return null;
        }
    }
}
