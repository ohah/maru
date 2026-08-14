// Android IME shim. **이 파일이 저장소의 유일한 Java 다.**
//
// `NativeActivity` 만으로는 소프트 키보드가 ASCII 물리 키 이벤트를 줄 때만 입력이 되고
// IME 를 못 받는다 — 한글 조합이 필수인 터미널에서는 쓸 수 없다. 구글의 `GameActivity`
// 가 그 자리를 채우지만 `AppCompatActivity` 를 상속해 AndroidX 의존 트리와 Gradle 을
// 끌고 온다(실측). 그래서 `InputConnection` 만 직접 받는다(docs/mobile-platform.md §1).
//
// **한글 조합 알고리즘은 여기 없다.** IME 가 `ㅎ`→`하`→`한` 을 계산해 완성된 문자열로
// 주고, 이 파일은 그것을 JNI 로 넘기기만 한다.
//
// `android.*` 만 쓴다 — AndroidX 도 kotlin-stdlib 도 안 들어간다. 그래서 빌드가
// `javac` + `d8` 로 끝난다.
package dev.maru;

import android.content.Context;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

public class MaruActivity extends android.app.NativeActivity {

    // **JVM 에게도 라이브러리를 알려야 한다.** `NativeActivity` 는 `android.app.lib_name` 을
    // 보고 직접 `dlopen` 하지만 그건 클래스로더 밖이라, JNI 이름 해석이 안 돼
    // `UnsatisfiedLinkError` 로 죽는다(실측). 같은 .so 를 여기서 한 번 더 연다 —
    // dlopen 은 refcount 라 두 번 열려도 인스턴스는 하나다.
    static {
        System.loadLibrary("maruchrome");
    }

    /// 조합 중 문자열. **셸로 보내지 않는다** — 화면에만 흐리게 그린다. 확정되기 전에
    /// PTY 로 흘리면 셸이 `ㅎ` 같은 자모를 명령어 일부로 받아버린다.
    private static native void nativeComposing(String text);

    /// 확정 문자열. 이때만 코어(→PTY)로 간다.
    private static native void nativeCommit(String text);

    /// IME 가 문자로 주지 않는 키(백스페이스 등). 코어가 바이트로 받는다.
    /** 키를 **인코딩 전** 상태로 넘긴다 — 바이트는 코어의 encodeKey 가 만든다(수정자 포함). */
    private static native void nativeKey(int keyCode, int metaState);

    /** OS 가 정한 **길게 누름 지연**(ms). 사용자가 접근성 설정("길게 누르기 지연")으로 바꿀 수
     *  있어서 코어가 박아 두면 그 설정을 무시하게 된다 — 손이 느린 사용자가 길게 눌러도
     *  선택이 안 잡힌다. */
    private static native void nativeLongPressMs(int ms);

    /** 소프트 키보드가 덮는 높이(px). 레이아웃 가용 높이에서 뺀다.
     *
     *  manifest 의 `windowSoftInputMode=adjustResize` 로는 부족하다 — targetSdk 35(Android 15)
     *  부터 edge-to-edge 가 강제되어 그 값이 **무시된다**. 안 빼면 키보드가 화면 절반을 덮는데
     *  레이아웃은 그대로라 하단이 통째로 가려진다(iOS 에서 보조 키바가 그렇게 사라졌다). */
    private static native void nativeKeyboardHeight(int px);

    /// IME 가 입력 대상으로 인정할 View. `NativeActivity` 의 SurfaceView 는 텍스트 편집기가
    /// 아니라서 키보드가 이 View 를 봐야 한다. 그리지 않으므로 화면에는 영향이 없다.
    private static final class InputView extends View {
        InputView(Context ctx) {
            super(ctx);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        @Override
        public boolean onCheckIsTextEditor() {
            return true;   // 이 한 줄이 없으면 IME 가 이 View 를 무시한다
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo out) {
            // 터미널이라 자동완성·자동대문자를 끈다. 그것들이 켜져 있으면 IME 가
            // 앞 문맥을 조회해 멋대로 고쳐 넣는다.
            out.inputType = EditorInfo.TYPE_CLASS_TEXT | EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
                    | EditorInfo.IME_FLAG_NO_FULLSCREEN
                    | EditorInfo.IME_ACTION_NONE;
            return new TerminalInputConnection(this);
        }
    }

    /// IME 가 부르는 콜백을 코어로 넘긴다.
    ///
    /// **`fullEditor=true` 여야 조합이 온다.** false 로 두면 IME 가 "편집기가 아니다" 로 보고
    /// `setComposingText` 없이 바로 `commitText` 를 부른다(실측). 그러면 한글이 조립되는
    /// 과정이 화면에 안 나온다. true 면 프레임워크가 Editable 버퍼를 두지만 우리는 콜백만
    /// 가로채 쓰므로 그 버퍼는 안 읽는다.
    private static final class TerminalInputConnection extends BaseInputConnection {
        TerminalInputConnection(View target) {
            super(target, true);
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            nativeComposing(text == null ? "" : text.toString());
            return true;
        }

        @Override
        public boolean finishComposingText() {
            nativeComposing("");   // 조합이 끝났다 — 겉치레를 지운다
            return true;
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            nativeComposing("");
            nativeCommit(text == null ? "" : text.toString());
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            // 조합이 없는 상태의 백스페이스가 이리로 온다. 터미널은 화면 버퍼를 편집하지
            // 않으므로 삭제를 흉내 내지 않고 **키 자체를 코어로** 넘긴다.
            for (int i = 0; i < beforeLength; i++) nativeKey(android.view.KeyEvent.KEYCODE_DEL, 0);
            return true;
        }

        @Override
        public boolean sendKeyEvent(android.view.KeyEvent event) {
            if (event.getAction() == android.view.KeyEvent.ACTION_DOWN)
                nativeKey(event.getKeyCode(), event.getMetaState());
            return true;
        }
    }

    private InputView input;

    /** **클립보드는 OS 것이라 코어가 못 쓴다**(브리지엔 OS 호출이 없다). 네이티브가 코어에서
     *  꺼낸 텍스트를 여기로 넘기면 이 자리가 시스템 클립보드에 넣는다. */
    private static MaruActivity current;

    /** 네이티브가 JNI 로 부른다. Context 가 필요해서 액티비티 참조를 통해 간다. */
    public static void setClipboard(String text) {
        MaruActivity a = current;
        if (a == null || text == null) return;
        android.content.ClipboardManager cm =
                (android.content.ClipboardManager) a.getSystemService(android.content.Context.CLIPBOARD_SERVICE);
        if (cm == null) return;
        cm.setPrimaryClip(android.content.ClipData.newPlainText("maru", text));
        android.util.Log.i("MaruChrome", "MARU_COPY len=" + text.length());
    }

    /** OS 값을 코어에 알린다. **재개할 때마다** 다시 읽는다 — 사용자가 설정을 바꾸고
     *  돌아올 수 있고, 그때 옛 값을 쓰면 접근성 설정이 무시된다. */
    private void applyLongPressTimeout() {
        nativeLongPressMs(android.view.ViewConfiguration.get(this).getLongPressTimeout());
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyLongPressTimeout();
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        current = this;
        input = new InputView(this);
        // NativeActivity 가 만든 content view 위에 얹는다. 0x0 이면 포커스를 못 받는 기기가
        // 있어 전체 크기로 두고, 그리지 않아 화면에는 안 보인다.
        addContentView(input, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        input.requestFocus();
        // **OS 값을 코어에 알린다.** 이 값은 기기·설정마다 다르다(실측: 에뮬레이터 400ms).
        applyLongPressTimeout();
        // **decorView 에 붙인다.** `addContentView` 로 얹은 뷰는 insets dispatch 를 못 받는다
        // (실측: 리스너가 한 번도 안 불렸다). decorView 는 창의 뿌리라 항상 받는다.
        getWindow().getDecorView().setOnApplyWindowInsetsListener(new ImeInsets());
    }

    /// IME inset 을 native 로 넘긴다. **익명 클래스를 안 쓴다**(위 `ShowKeyboard` 와 같은 이유 —
    /// `d8` 이 익명 내부 클래스에서 죽는다).
    ///
    /// `WindowInsets.Type.ime()` 를 직접 읽는다. `adjustResize` 는 Android 15 에서 무시되고,
    /// `getSystemWindowInsetBottom` 은 navigation bar 와 IME 를 섞어 준다.
    private static final class ImeInsets implements View.OnApplyWindowInsetsListener {
        @Override
        public android.view.WindowInsets onApplyWindowInsets(View v, android.view.WindowInsets insets) {
            int ime = insets.getInsets(android.view.WindowInsets.Type.ime()).bottom;
            int nav = insets.getInsets(android.view.WindowInsets.Type.navigationBars()).bottom;
            // 키보드는 navigation bar 를 덮는다 — 두 번 빼지 않는다(iOS 의 safe area 처리와 같다).
            nativeKeyboardHeight(ime > nav ? ime - nav : 0);
            // **기본 처리를 대체하지 않는다.** decorView 리스너는 시스템 경로를 가로채므로
            // 원래 동작을 그대로 돌려줘야 한다(안 그러면 다른 inset 처리가 통째로 죽는다).
            return v.onApplyWindowInsets(insets);
        }
    }

    /// **익명 클래스를 안 쓴다.** `d8` 8.2.2 가 익명 내부 클래스(`MaruActivity$1`)에서
    /// 내부 오류로 죽는다(실측). 이름 있는 중첩 클래스는 정상이라 그것만 쓴다.
    private static final class ShowKeyboard implements Runnable {
        private final MaruActivity activity;

        ShowKeyboard(MaruActivity a) {
            this.activity = a;
        }

        @Override
        public void run() {
            activity.input.requestFocus();
            InputMethodManager imm = (InputMethodManager)
                    activity.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.showSoftInput(activity.input, InputMethodManager.SHOW_IMPLICIT);
        }
    }

    /// 네이티브에서 부른다 — 터미널은 켜지면 바로 입력을 받는다.
    @SuppressWarnings("unused")
    public void showKeyboard() {
        runOnUiThread(new ShowKeyboard(this));
    }
}
