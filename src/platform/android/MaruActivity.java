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
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import android.graphics.Rect;
import java.util.List;
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
    /** 키를 **인코딩 전** 상태로 넘긴다 — 바이트는 코어의 encodeKey 가 만든다(수정자 포함).
     *
     *  `unicodeChar` 는 **수정자를 뺀** 글자다(`getUnicodeChar(0)`). 이름 붙은 키 표에 없는
     *  키에 Ctrl·Alt 가 붙었을 때 이것이 없으면 네이티브가 어느 글자인지 알 수 없어 그냥
     *  버렸다 — 하드웨어 키보드에서 Ctrl+C 가 무동작이었다. iOS 의 `charactersIgnoringModifiers`
     *  와 같은 자리다. */
    private static native void nativeKey(int keyCode, int metaState, int unicodeChar);

    /** OS 가 정한 **길게 누름 지연**(ms). 사용자가 접근성 설정("길게 누르기 지연")으로 바꿀 수
     *  있어서 코어가 박아 두면 그 설정을 무시하게 된다 — 손이 느린 사용자가 길게 눌러도
     *  선택이 안 잡힌다. */
    private static native void nativeLongPressMs(int ms);

    /** 시스템 외관이 다크인지(`theme.follow-system` 이 켜졌을 때만 코어가 쓴다). */
    private static native void nativeSystemAppearance(int isDark);

    /** 소프트 키보드가 덮는 높이(px). 레이아웃 가용 높이에서 뺀다.
     *
     *  manifest 의 `windowSoftInputMode=adjustResize` 로는 부족하다 — targetSdk 35(Android 15)
     *  부터 edge-to-edge 가 강제되어 그 값이 **무시된다**. 안 빼면 키보드가 화면 절반을 덮는데
     *  레이아웃은 그대로라 하단이 통째로 가려진다(iOS 에서 보조 키바가 그렇게 사라졌다). */
    private static native void nativeKeyboardHeight(int px);
    private static native void nativeBottomInset(int px);

    /** 밀린 화면을 하나 뺀다. 1=뺐다, 0=뺄 것이 없다(그러면 앱을 내린다). */
    private static native int nativePopScreen();

    /** 지금 무엇을 입력받는가 — 0=글자, 1=숫자. 키보드 종류를 이 값으로 고른다. */
    private static native int nativeInputKind();

    /** 눌러 둔 보조 키바 수정자(Ctrl·Alt). 0 이면 없다. */
    private static native int nativeArmedMods();

    // ── 접근성 (M9) — 브리지의 서술자를 가상 뷰 계층으로 옮긴다 ──────────────────
    /** 이번 프레임 서술자 수. **읽는 순서로** 나온다(순서는 브리지가 정한다). */
    private static native int nativeA11yCount();
    /** 자리 — **뷰 픽셀**로 (x<<48)|(y<<32)|(w<<16)|h. 네이티브가 이미 scale·inset 을 되돌렸다. */
    private static native long nativeA11yRect(int index);
    private static native int nativeA11yRole(int index);
    private static native int nativeA11yState(int index);
    private static native String nativeA11yLabel(int index);
    /** 두 번 두드리기 — **누르는 경로 그대로** 누른다. */
    private static native boolean nativeA11yClick(int index);

    /** **하드웨어 뒤로가기는 스택 pop 이다**(docs/mobile-ux.md §3). `NativeActivity` 는 이 키를
     *  네이티브 입력 큐로 안 넘겨 주므로(실측 — `nativeKey` 로도 안 온다) Java 쪽에서 받는다.
     *  뺄 화면이 없을 때만 기본 동작(앱 내리기)으로 넘긴다. */
    @Override
    public void onBackPressed() {
        if (nativePopScreen() != 0) return;
        super.onBackPressed();
    }

    /// IME 가 입력 대상으로 인정할 View. `NativeActivity` 의 SurfaceView 는 텍스트 편집기가
    /// 아니라서 키보드가 이 View 를 봐야 한다. 그리지 않으므로 화면에는 영향이 없다.
    private static final class InputView extends View {
        InputView(Context ctx) {
            super(ctx);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        /// **가상 뷰 계층**(M9). 이 뷰는 화면 전체를 덮는 투명한 판이라, 그리는 것은 GPU 가
        /// 하고 **읽히는 것은 여기서** 만든다. TalkBack 은 이 provider 로 자식들을 묻는다.
        ///
        /// **노드를 질의마다 새로 만드는 것이 이 플랫폼의 방식이다**(iOS 와 반대다 — 거기서는
        /// 들고 있어야 한다). `AccessibilityNodeInfo` 는 프레임워크가 회수하는 값이다.
        private AccessibilityNodeProvider provider;
        /// 접근성 커서가 지금 어느 가상 노드에 있나. `-1` 은 없다.
        private int a11yFocus = -1;

        @Override
        public AccessibilityNodeProvider getAccessibilityNodeProvider() {
            if (provider == null) provider = new Provider(this);
            return provider;
        }

        /// **`static` 이어야 한다.** 이중 중첩된 «비정적» 내부 클래스가 라이브러리 추상 클래스를
        /// 상속하면 d8 8.2.2 가 내부 오류로 죽는다(실측 — "Cannot invoke String.length()" NPE,
        /// 최소 재현까지 좁혔다). 바깥 참조가 필요 없기도 하다 — 뷰는 생성자로 받는다.
        private static final class Provider extends AccessibilityNodeProvider {
            private final InputView view;

            Provider(InputView v) { this.view = v; }

            @Override
            public AccessibilityNodeInfo createAccessibilityNodeInfo(int virtualViewId) {
                int n = nativeA11yCount();
                if (virtualViewId == AccessibilityNodeProvider.HOST_VIEW_ID) {
                    AccessibilityNodeInfo host = AccessibilityNodeInfo.obtain(view);
                    view.onInitializeAccessibilityNodeInfo(host);
                    // **자식을 붙이지 않으면 아무것도 못 찾는다.** 순서는 브리지가 정한
                    // 읽는 순서 그대로다 — 여기서 다시 세우지 않는다.
                    for (int i = 0; i < n; i++) host.addChild(view, i);
                    return host;
                }
                if (virtualViewId < 0 || virtualViewId >= n) return null;

                long r = nativeA11yRect(virtualViewId);
                int x = (int) ((r >> 48) & 0xFFFF);
                int y = (int) ((r >> 32) & 0xFFFF);
                int w = (int) ((r >> 16) & 0xFFFF);
                int h = (int) (r & 0xFFFF);
                int state = nativeA11yState(virtualViewId);

                AccessibilityNodeInfo node = AccessibilityNodeInfo.obtain(view, virtualViewId);
                node.setPackageName(view.getContext().getPackageName());
                node.setClassName(a11yClassName(nativeA11yRole(virtualViewId)));
                // **이름은 contentDescription 이다** — `setText` 로 넣으면 편집 가능한 글자처럼 읽힌다.
                node.setContentDescription(nativeA11yLabel(virtualViewId));
                node.setParent(view);
                node.setEnabled((state & 1) != 0);
                node.setSelected((state & 2) != 0);
                node.setVisibleToUser(true);
                node.setFocusable(true);
                // 두 번 두드리기가 여기로 온다. **`setClickable` 만으로는 안 온다** — 동작도 붙인다.
                node.setClickable(true);
                node.addAction(AccessibilityNodeInfo.ACTION_CLICK);
                node.addAction(view.a11yFocus == virtualViewId
                        ? AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS
                        : AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS);
                node.setAccessibilityFocused(view.a11yFocus == virtualViewId);

                Rect bounds = new Rect(x, y, x + w, y + h);
                node.setBoundsInParent(bounds);
                int[] origin = new int[2];
                view.getLocationOnScreen(origin);
                node.setBoundsInScreen(new Rect(origin[0] + x, origin[1] + y,
                        origin[0] + x + w, origin[1] + y + h));
                return node;
            }

            @Override
            public boolean performAction(int virtualViewId, int action, Bundle arguments) {
                if (virtualViewId == AccessibilityNodeProvider.HOST_VIEW_ID) {
                    return view.performAccessibilityAction(action, arguments);
                }
                if (virtualViewId < 0 || virtualViewId >= nativeA11yCount()) return false;
                switch (action) {
                    case AccessibilityNodeInfo.ACTION_CLICK:
                        return nativeA11yClick(virtualViewId);
                    case AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS:
                        view.a11yFocus = virtualViewId;
                        sendA11yEvent(virtualViewId, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED);
                        return true;
                    case AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS:
                        if (view.a11yFocus == virtualViewId) view.a11yFocus = -1;
                        sendA11yEvent(virtualViewId,
                                AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED);
                        return true;
                    default:
                        return false;
                }
            }

            @Override
            public AccessibilityNodeInfo findFocus(int focusType) {
                if (focusType == AccessibilityNodeInfo.FOCUS_ACCESSIBILITY && view.a11yFocus >= 0) {
                    return createAccessibilityNodeInfo(view.a11yFocus);
                }
                return super.findFocus(focusType);
            }

            private void sendA11yEvent(int virtualViewId, int type) {
                AccessibilityEvent ev = AccessibilityEvent.obtain(type);
                ev.setPackageName(view.getContext().getPackageName());
                ev.setClassName(a11yClassName(nativeA11yRole(virtualViewId)));
                ev.setSource(view, virtualViewId);
                view.getParent().requestSendAccessibilityEvent(view, ev);
            }
        }

        /// 뜻 → Android 어휘. **번역은 여기 한 곳에서만 한다** — 번호의 단일 출처는
        /// `mobile_host_abi.h` 의 `MARU_MOBILE_A11Y_ROLE_*` 다.
        private static String a11yClassName(int role) {
            switch (role) {
                case 0: return "android.widget.Button";        // button
                case 3: return "android.widget.Button";        // tab — 탭 바는 컨테이너가 말한다
                case 5: return "android.widget.TextView";      // text
                case 1: case 2: return "android.widget.TextView";  // 트리·목록 줄
                case 4: return "android.widget.ScrollView";    // scroll_view
                default: return "android.view.View";           // group·모르는 것
            }
        }

        @Override
        public boolean onCheckIsTextEditor() {
            return true;   // 이 한 줄이 없으면 IME 가 이 View 를 무시한다
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo out) {
            // 터미널이라 자동완성·자동대문자를 끈다. 그것들이 켜져 있으면 IME 가
            // 앞 문맥을 조회해 멋대로 고쳐 넣는다.
            // **숫자 칸이면 숫자 패드를 띄운다.** 터미널은 계속 글자다 — 거기서 ASCII 배열을
            // 요구하면 한글이 불편해진다. 숫자 패드는 조합이 없어 IME 위험도 없다.
            out.inputType = nativeInputKind() == 1
                    ? EditorInfo.TYPE_CLASS_NUMBER
                    : (EditorInfo.TYPE_CLASS_TEXT | EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
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
        /// **지금 조합 중인 글자.** `finishComposingText` 는 "조합 중인 것을 확정하라" 는 뜻인데
        /// 그 콜백에는 **글자가 실려 오지 않는다** — 무엇을 확정할지는 받는 쪽이 기억하고 있어야
        /// 한다. 안 들고 있으면 확정된 글자가 통째로 사라진다.
        private String composing = "";
        /// **이번 조합에서 이미 내보낸 앞부분.** 조합 문자열은 자랄 때마다 **처음부터 통째로**
        /// 다시 온다(`가` → `가나` → `가나다`). 앞부분을 보낸 뒤 그 사실을 안 들고 있으면 다음
        /// 호출에서 같은 글자를 또 보내 **`가가나`** 가 된다.
        private String sent = "";

        /// 원격이 들고 있는 이번 조합의 앞부분을 `target` 과 **같게 맞춘다.**
        ///
        /// 조합은 자라기만 하지 않는다 — 백스페이스나 후보 선택으로 **줄고 갈아치워진다.** 늘어난
        /// 것만 보내고 줄어든 것을 안 지우면, 이미 나간 글자가 원격에 남은 채 다음 입력에서 처음부터
        /// 다시 나가 **지울수록 늘어난다**(기기 실측: `가나다` 를 지우니 `가나다아 가나다 가나당`).
        ///
        /// 공통 접두사까지는 그대로 두고, **넘치는 만큼 지우고 모자라는 만큼 보낸다.** 지우는 것은
        /// 백스페이스 키다 — 터미널에는 "앞의 n글자를 지워라" 가 없고 그 자리를 셸·TUI 가 해석한다.
        private void reconcileSent(String target) {
            int common = 0;
            final int lim = Math.min(sent.length(), target.length());
            while (common < lim && sent.charAt(common) == target.charAt(common)) common++;
            // **코드포인트 경계로 되돌린다** — 서로게이트 쌍 가운데서 끊으면 반쪽 글자가 남는다.
            if (common > 0 && common < sent.length()
                    && Character.isLowSurrogate(sent.charAt(common))) common--;
            if (common < sent.length()) {
                final int del = sent.codePointCount(common, sent.length());
                for (int i = 0; i < del; i++) nativeKey(android.view.KeyEvent.KEYCODE_DEL, 0, 0);
            }
            if (common < target.length()) nativeCommit(target.substring(common));
            sent = target;
        }

        /// **ASCII 만으로 된 조합인가.** 터미널에서 영문 예측 입력은 방해다 — 누른 글자는 그
        /// 자리에서 나가야 하고, 확정을 기다릴 이유가 없다. 조합이 필요한 것은 자모가 모여
        /// 글자가 되는 한글뿐이고 그것은 항상 ASCII 밖이다.
        ///
        /// 이 구분이 없으면 **tmux prefix 다음 키가 영영 안 나간다** — `Ctrl+B` 는 수정자가
        /// 걸려 있어 아래에서 바로 확정되지만, 이어지는 `m` 은 수정자가 없어 조합에 갇히고
        /// tmux 는 오지 않는 키를 기다린다(기기 실측: `02` 뒤로 `6d` 가 안 나갔다).
        private static boolean isAsciiOnly(String s) {
            for (int i = 0; i < s.length(); i++) {
                if (s.charAt(i) > 0x7F) return false;
            }
            return true;
        }

        TerminalInputConnection(View target) {
            super(target, true);
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            final String next = text == null ? "" : text.toString();
            // **수정자가 걸려 있으면 조합하지 않는다.** `Ctrl+B` 는 조합할 글자가 아니라 **지금
            // 나가야 하는 시퀀스**다(tmux prefix 가 그렇다).
            //
            // 삼성 키보드는 영문도 조합으로 넘긴다 — 그러면 글자가 preedit 으로 화면에만 떠 있고
            // `commitText` 는 확정할 때까지 안 온다. 눌러 둔 수정자는 그 `commitText` 자리에서
            // 소비되므로, **그 시점이 영영 안 와서** Ctrl 이 켜진 채 글자만 나갔다(기기 실측).
            //
            // 여기서 바로 확정으로 넘기면 브리지가 키 경로로 보내며 수정자를 소비한다.
            // **`sendKeyEvent` 를 대신 통과시키는 방법은 안 된다** — 그 글자가 키로 한 번 나가고,
            // 나중에 조합이 확정되며 `commitText` 로 **또** 나가 중복이 된다.
            if (!next.isEmpty() && (nativeArmedMods() != 0 || isAsciiOnly(next))) {
                // **이미 내보낸 앞부분은 빼고 넘긴다** — 안 빼면 그 글자가 두 번 나간다.
                String t = next;
                if (!sent.isEmpty() && t.startsWith(sent)) t = t.substring(sent.length());
                composing = "";
                sent = ""; // 아래 `restartInput` 이 조합을 끊는다 — 접두사도 함께 버린다
                nativeComposing("");
                if (!t.isEmpty()) nativeCommit(t);
                // **IME 의 조합도 끊는다.** 우리가 가로채 커밋해도 프레임워크의 Editable 은 여전히
                // 조합 중이라, 다음 글자가 **이어붙는다** — `Ctrl+B` 뒤에 `m` 을 치면 tmux 로
                // 가야 할 `m` 이 `bm` 조합으로 쌓여 한 덩어리로 왔다(기기 실측: `commit_bytes=3`).
                // 수정자가 걸린 입력은 한 번에 하나씩 나가야 하므로 여기서 상태를 비운다.
                restartInput();
                return true;
            }
            // **완성된 글자는 조합이 끝나기를 기다리지 않는다.**
            //
            // 한글은 **한 음절씩** 조합된다 — 조합 문자열이 두 글자가 됐다는 것은 앞 글자가 더는
            // 안 바뀐다는 뜻이다(`가나` 의 `가` 에는 받침이 붙을 수 없다). 그런데 지금까지는
            // `commitText`·`finishComposingText` 가 올 때까지 **한 글자도 안 내보냈다**.
            //
            // 터미널에서 그 기다림은 그냥 늦는 것이 아니다. 원격의 TUI(claude·codex)는 **자기가
            // 받은 글자로** 자동완성과 선입력을 계산하는데, preedit 은 우리 화면에만 있어 그쪽은
            // 아무것도 못 본다 — 다 치고 확정한 뒤에야 한꺼번에 도착한다(사용자 보고: "자동완성이나
            // 선입력이 망가진다"). macOS 터미널이 그렇듯 **완성되는 대로** 보낸다.
            //
            // **마지막 한 글자만 조합으로 남긴다** — 그것만이 아직 바뀔 수 있다. 나머지는 원격의
            // 것이고, 그 상태를 맞추는 일은 `reconcileSent` 가 한다(줄어드는 경우까지 거기서 본다).
            final int n = next.length();
            final int last = n > 0 ? next.offsetByCodePoints(n, -1) : 0;
            reconcileSent(next.substring(0, last));
            composing = next.substring(last);
            nativeComposing(composing);
            return true;
        }

        @Override
        public boolean finishComposingText() {
            // **조합을 확정으로 넘긴다.** 겉치레만 지우면 그 글자가 사라진다 — 한글은 조합이
            // 끝나는 순간을 `commitText` 가 아니라 이 콜백으로 알리는 IME 가 있고(삼성 키보드에서
            // 스페이스로 확정할 때 실측: `commitText` 로는 공백 한 바이트만 왔고 '마' 는 유실됐다),
            // 그때 친 글자가 통째로 없어졌다.
            final String done = composing;
            composing = "";
            sent = "";             // 조합이 끝났다 — 다음 조합은 처음부터 센다
            nativeComposing("");   // 겉치레를 지운다
            if (!done.isEmpty()) nativeCommit(done);
            return true;
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            // **조합을 먼저 비운다.** 이 호출 자체가 확정이므로, 안 비우면 뒤따라오는
            // `finishComposingText` 가 같은 글자를 **한 번 더** 넣는다(IME 마다 순서가 다르다).
            String t = text == null ? "" : text.toString();
            // **이미 내보낸 앞부분은 빼고 넘긴다.** 확정 문자열은 조합 전체로 오는데, 그중 앞부분은
            // `setComposingText` 에서 이미 나갔다 — 안 빼면 그 글자들이 두 번 나간다.
            if (!sent.isEmpty() && t.startsWith(sent)) t = t.substring(sent.length());
            composing = "";
            sent = "";
            nativeComposing("");
            nativeCommit(t);
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            // 조합이 없는 상태의 백스페이스가 이리로 온다. 터미널은 화면 버퍼를 편집하지
            // 않으므로 삭제를 흉내 내지 않고 **키 자체를 코어로** 넘긴다.
            for (int i = 0; i < beforeLength; i++) nativeKey(android.view.KeyEvent.KEYCODE_DEL, 0, 0);
            return true;
        }

        @Override
        public boolean sendKeyEvent(android.view.KeyEvent event) {
            if (event.getAction() != android.view.KeyEvent.ACTION_DOWN) return true;
            final int uch = event.getUnicodeChar(0);
            // **소프트 키보드의 글자는 여기서 안 보낸다 — `commitText` 가 이미 보냈다.**
            //
            // IME 는 글자 하나에 두 콜백을 다 부른다(실측: 삼성 키보드). 둘 다 넘기면 **같은
            // 글자가 두 번** 원격으로 나간다 — `ㅈ` 한 번에 `ww` 가 찍혔다. 한글에서는 더 나쁘다:
            // 물리 배열이 QWERTY 라 `getUnicodeChar` 가 자모가 아니라 **그 자리의 라틴 글자**를
            // 준다. 그래서 "가" 를 치면 조합 결과와 **별개로** `rk` 가 나가 `zsh: command not
            // found: rkr` 이 됐다. 로컬 화면에서는 `commitText` 만 반영하면 맞아 보여 안 드러나고,
            // **원격이 나간 바이트를 에코하면서** 비로소 보였다.
            //
            // **하드웨어 키보드는 그대로 통과한다.** 물리 키보드는 IME 를 안 거쳐 이 경로로만
            // 오므로, 여기서 글자를 막으면 그쪽 타이핑이 통째로 죽는다.
            //
            // **수정자가 걸린 것도 통과한다.** `Ctrl+C` 는 글자가 아니라 시퀀스이고, 그 판정은
            // 코어가 한다(`maru_mobile_key`). 여기서 글자로 보고 막으면 제어문자가 사라진다.
            final boolean from_soft =
                    (event.getFlags() & android.view.KeyEvent.FLAG_SOFT_KEYBOARD) != 0
                    || event.getDeviceId() == android.view.KeyCharacterMap.VIRTUAL_KEYBOARD;
            final boolean modified = (event.getMetaState()
                    & (android.view.KeyEvent.META_CTRL_ON
                       | android.view.KeyEvent.META_ALT_ON
                       | android.view.KeyEvent.META_META_ON)) != 0;
            // **막는 것은 "글자" 뿐이다 — 제어문자는 통과시킨다.**
            //
            // `getUnicodeChar` 는 엔터에 `\n`(0x0A), 탭에 `\t`(0x09) 를 준다. "0 이 아니면 글자"
            // 로 보면 **그 둘이 함께 막힌다**, 그런데 IME 는 엔터·탭을 `commitText` 로 보내지
            // 않고 키 이벤트로만 보낸다 — 막으면 대신 보내 줄 사람이 없어 **통째로 사라진다**
            // (실측: 이 필터를 넣은 회차에서 원격 셸에 엔터가 안 먹었다).
            //
            // 판별은 **인쇄 가능한가**로 한다. 브리지가 눌러 둔 수정자를 실을 때 쓰는 기준과
            // 같은 자리다(`ptr[0] >= 0x20 && ptr[0] != 0x7F` — "제어문자는 타이핑이 아니라
            // 시퀀스다"). 두 층이 같은 말을 쓰면 어느 한쪽만 낡지 않는다.
            //
            // **경계는 스페이스 하나다.** 표준 키맵에서 엔터·탭·백스페이스·ESC 는 전부 0x20 아래
            // (`\n`·`\t`·`\b`·0x1B)이고 방향키·F1~F12·Home/End·PgUp/PgDn 은 0 이라 자연히 통과한다.
            // 스페이스만 `' '`(0x20)이라 **막는 쪽**에 떨어지는데, 그것이 맞다 — 스페이스는 글자라
            // `commitText` 로 온다(위 `finishComposingText` 의 실측: 삼성 키보드에서 스페이스로
            // 확정할 때 `commitText` 로 공백이 왔다). 안 막으면 다른 글자와 똑같이 **두 칸**이 된다.
            final boolean printable = uch >= 0x20 && uch != 0x7F;
            // **숫자 패드는 이 필터를 안 건다.** `TYPE_CLASS_NUMBER` 키보드는 숫자를
            // `commitText` 로 보내지 않고 **키 이벤트로만** 보낸다(mobile-platform.md §3.1 이
            // 이미 적어 둔 사실이다). 그러니 여기서 막으면 **대신 보내 줄 사람이 없어 통째로
            // 사라진다** — 엔터가 사라졌던 것과 같은 모양이고, 그때 좁힌 기준("인쇄 가능한가")은
            // 제어문자만 갈랐지 이 자리까지는 못 갈랐다.
            //
            // 기기 실측: 설정의 글자 크기 줄을 눌러 숫자 패드가 떴는데 **숫자가 하나도 안
            // 들어갔다**. 키보드는 보이는데 아무것도 안 써지는, 이 앱이 이미 두 번 겪은 상태다.
            //
            // 중복 걱정이 없는 이유: 숫자 패드에는 **조합이 없다**(`setComposingText` 도 안 온다).
            // 두 콜백이 같은 글자를 나르는 것은 조합하는 키보드의 일이다.
            final boolean numeric_pad = nativeInputKind() == 1;
            if (from_soft && printable && !modified && !numeric_pad) return true;
            nativeKey(event.getKeyCode(), event.getMetaState(), uch);
            return true;
        }
    }

    private InputView input;

    /** **클립보드는 OS 것이라 코어가 못 쓴다**(브리지엔 OS 호출이 없다). 네이티브가 코어에서
     *  꺼낸 텍스트를 여기로 넘기면 이 자리가 시스템 클립보드에 넣는다. */
    private static MaruActivity current;

    /** 네이티브가 부른다 — 입력 종류가 바뀌었으니 키보드를 다시 세운다(`onCreateInputConnection`
     *  이 새 `inputType` 으로 다시 불린다). UI 스레드에서 해야 한다. */
    /** 네이티브가 부른다 — 키보드를 **다시** 올린다(사용자가 내렸을 수 있다). 아래 인스턴스
     *  `showKeyboard` 는 시작 때 한 번 부르는 것이고, 이쪽은 편집이 시작될 때마다다. */
    public static void raiseKeyboard() {
        final MaruActivity a = current;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                android.view.inputmethod.InputMethodManager imm =
                        (android.view.inputmethod.InputMethodManager)
                                a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
                if (imm != null && a.input != null) {
                    a.input.requestFocus();
                    imm.showSoftInput(a.input, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT);
                }
            }
        });
    }

    /** 네이티브가 부른다 — 키보드를 **내린다**. 앱은 터미널을 위해 늘 띄워 두는데, 그대로 다른
     *  화면에 가면 쓸 데가 없는 자판이 화면 절반을 먹는다. 올리는 쪽과 같은 자리에 둔다. */
    public static void hideKeyboard() {
        final MaruActivity a = current;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                android.view.inputmethod.InputMethodManager imm =
                        (android.view.inputmethod.InputMethodManager)
                                a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
                if (imm != null && a.input != null) {
                    imm.hideSoftInputFromWindow(a.input.getWindowToken(), 0);
                }
            }
        });
    }

    public static void restartInput() {
        final MaruActivity a = current;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                android.view.inputmethod.InputMethodManager imm =
                        (android.view.inputmethod.InputMethodManager)
                                a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
                if (imm != null && a.input != null) imm.restartInput(a.input);
            }
        });
    }

    /** **서술자 묶음의 «생김새»가 바뀌었다**고 네이티브가 알린다(M9).
     *
     *  안 알리면 화면을 옮겨도 TalkBack 이 옛 버튼을 계속 들고 있다 — 짚어도 아무 일이 없다.
     *  상태만 바뀌었을 때는 안 부른다: 그때 알리면 읽던 것을 끊고 커서를 되돌려, 키바에서
     *  수정자를 켜자마자 다음 키까지 처음부터 다시 훑게 된다(iOS 어댑터와 같은 규율). */
    public static void a11yChanged() {
        final MaruActivity a = current;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (a.input != null) {
                    a.input.sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
                }
            }
        });
    }

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

    /** 시스템 다크/라이트를 코어에 알린다. **재개할 때마다**도 다시 읽는다 — 사용자가 설정 앱에서
     *  바꾸고 돌아오면 `onConfigurationChanged` 가 아니라 재개로 오는 경우가 있다. */
    private void applySystemAppearance() {
        int mode = getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK;
        nativeSystemAppearance(mode == android.content.res.Configuration.UI_MODE_NIGHT_YES ? 1 : 0);
    }

    @Override
    public void onConfigurationChanged(android.content.res.Configuration cfg) {
        super.onConfigurationChanged(cfg);
        // 액티비티가 `configChanges` 로 회전·야간 모드를 직접 받는다(재생성 없음) — 그래서 여기서
        // 다시 알려야 한다. 안 그러면 앱이 떠 있는 채로 다크를 켰을 때 그대로다.
        applySystemAppearance();
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyLongPressTimeout();
        applySystemAppearance();
        // **재접속은 여기서 안 정한다.** 돌아오면 창이 다시 서면서 config 를 다시 읽고
        // (docs/mobile-config.md §7), 브리지가 "원격 세션이 없으면" 붙어 달라고 요청한다 —
        // 그 판단이 여기 또 있으면 두 자리가 갈린다(SSH 에는 재개가 없어 되살리기는 없다).
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

    /// **네이티브가 부른다 — 이 서버에 붙어라.** 어느 서버인지는 브리지가 정하고(config 가
    /// 단일 출처, docs/mobile-config.md §4.3) 여기서는 소켓을 들 자리를 만든다.
    ///
    /// **키는 여기서 안 만진다** — 서비스가 Keystore 에서 풀어 쓰고 지운다. 그래서 개인키가
    /// `Intent` 를 타지 않는다(`system_server` 를 지나게 된다).
    public static void startSsh(String host, int port, String user, String fingerprint) {
        MaruActivity a = current;
        if (a == null) return;
        Intent intent = new Intent(a, MaruSshService.class);
        intent.putExtra("host", host);
        intent.putExtra("port", port);
        intent.putExtra("user", user);
        intent.putExtra("fingerprint", fingerprint);
        // **`startForegroundService` 여야 한다.** 배경에서 `startService` 는 API 26+ 에서 막힌다.
        a.startForegroundService(intent);
    }

    /// IME inset 을 native 로 넘긴다. **익명 클래스를 안 쓴다**(위 `ShowKeyboard` 와 같은 이유 —
    /// `d8` 이 익명 내부 클래스에서 죽는다).
    ///
    /// `WindowInsets.Type.ime()` 를 직접 읽는다. `adjustResize` 는 Android 15 에서 무시되고,
    /// `getSystemWindowInsetBottom` 은 navigation bar 와 IME 를 섞어 준다.
    private static final class ImeInsets implements View.OnApplyWindowInsetsListener {
        @Override
        public android.view.WindowInsets onApplyWindowInsets(View v, android.view.WindowInsets insets) {
            // **잰 값을 그대로 넘긴다.** 키보드가 navigation bar 를 덮는 겹침은 코어가 접는다
            // (`maru_mobile_available_logical`) — 여기서 미리 빼면 그 규칙이 iOS 의 ObjC 와
            // **두 자리**에 살게 되고, 그러면 한쪽만 고쳐진다.
            nativeKeyboardHeight(insets.getInsets(android.view.WindowInsets.Type.ime()).bottom);
            // **레이아웃이 쓰는 하단 inset 도 여기서 갱신한다.** native 쪽 `queryInsets` 는
            // 창이 생기거나 크기가 바뀔 때만 도는데, 하필 키보드가 떠 있는 프레임에 걸리면
            // 시스템이 0 을 돌려줘 그 값이 굳는다 — 키보드를 내려도 하단 키바가 3버튼 위에
            // 겹쳐 남았다(기기 실측). 0 은 native 가 걸러 내므로 그대로 넘긴다.
            nativeBottomInset(insets.getInsets(
                    android.view.WindowInsets.Type.systemBars()
                    | android.view.WindowInsets.Type.displayCutout()).bottom);
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
