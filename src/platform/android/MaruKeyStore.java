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

    /** 네이티브가 ABI 로 키를 만든다(씨앗은 OS 난수). 공개키 한 줄은 네이티브가 로그·파일로 낸다. */
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
