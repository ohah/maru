// 두 host 가 함께 쓰는 SSH 소켓 펌프 — 계약은 `ssh_pump.h` 머리에.

// **POSIX 를 명시적으로 켠다 — 어떤 표준 모드로 불려도.**
//
// `-std=c11` 로 부르면 glibc 는 ISO 만 노출해 `getaddrinfo`·`struct addrinfo` 가 통째로
// 사라진다(실측: CI 리눅스에서 컴파일 오류 9개. macOS 는 기본이 관대해 안 걸렸고, Android NDK
// 빌드는 `-std` 를 안 줘서 역시 안 걸렸다 — **세 빌드 경로 중 하나에서만 깨졌다**).
// 컴파일 방식이 셋이므로 플래그에 기대지 않고 소스에서 못박는다.
//
// **Darwin 에는 안 건다.** 거기서 `_POSIX_C_SOURCE` 를 좁게 걸면 반대로 `arc4random_buf` 와
// `SO_NOSIGPIPE` 같은 확장이 사라진다.
#if defined(__linux__)
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200112L
#endif
#endif

#include "ssh_pump.h"

#include "../mobile/mobile_host_abi.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <stdlib.h> // arc4random_buf
#else
#include <sys/random.h> // getrandom
#endif

/// 한 번에 소켓에서 읽는 양. 화면 버퍼(64KiB)를 한 번에 채우지 않게 잡는다 — 넘치면 `feed` 가
/// 배압으로 멈추고, 그러면 같은 바이트를 들고 다시 돌아야 한다.
#define PUMP_READ_CHUNK 8192
/// 덜 온 패킷을 모아 두는 자리. **패킷 상한(256KiB)보다 커야 한다** — 코어는 패킷이 다 오기
/// 전까지 한 바이트도 안 먹으므로(`consumed == 0`), 그보다 작으면 큰 패킷에서 영영 못 나간다.
#define PUMP_IN_CAP (264 * 1024)
/// 답(DSR·DA)은 짧다. 넉넉히 잡아도 이 크기다.
#define PUMP_RESPONSE_CAP 256
/// 소켓 읽기 타임아웃(초). **멈춤을 알아채는 주기**이기도 하다 — 이 값마다 정지 표시를 본다.
#define PUMP_READ_TIMEOUT_S 2
/// 펌프 스레드 스택. **기본값으로는 죽는다 — 실측이다.**
///
/// 코어는 패킷 상한(256KiB)짜리 버퍼를 **스택에** 잡는다(`client.emit` 의 `max_packet + 64`,
/// `stepPacket` 의 `max_packet`, `write` 의 `max_packet`). 한 번의 `feed` 에서 그것이 겹쳐
/// 500KiB 를 넘는데, 새 스레드의 기본 스택은 macOS 512KiB · iOS 512KiB · Android(bionic) 1MiB 다.
/// 데스크톱 스모크는 **main 스레드**(8MiB)에서 돌아 안 걸렸고, 펌프를 스레드로 옮기자마자
/// `SIGILL`(스택 가드) 로 죽었다 — 기기에서는 앱이 통째로 사라졌을 자리다.
#define PUMP_STACK_BYTES (2 * 1024 * 1024)
/// 붙는 데 이만큼 넘게 걸리면 실패로 본다. **기본값에 맡기면 안 된다** — 닿지 않는 주소에서
/// 커널 재시도는 1분을 넘고, 그동안 `stop` 이 스레드를 못 거둬 화면은 "접속 중" 에 붙어 있다.
#define PUMP_CONNECT_TIMEOUT_MS 15000
/// **사용자가 비밀번호를 칠 시간.** 무한히 기다리면 앱을 닫아도 스레드가 남고, 짧으면 폰에서
/// 비밀번호 앱을 열었다 돌아오는 사이에 끊긴다 — 2분으로 둔다.
#define PUMP_PASSWORD_TIMEOUT_MS 120000
/// 그 기다림의 폴링 간격.
#define PUMP_PASSWORD_POLL_MS 100
/// 그 기다림을 쪼개는 단위. 이 주기마다 **정지 표시를 본다** — 사용자가 취소하면 곧 멈춘다.
#define PUMP_CONNECT_POLL_MS 100

static pthread_t g_thread;
/// 스레드를 **거둘 것이 남았나**. `g_running` 은 스레드가 스스로 끄므로, 그것만 보면 이미 끝난
/// 스레드를 영영 `join` 하지 않고 흘린다(모바일에서 재접속을 반복하면 그만큼 샌다).
static volatile int g_joinable;
static volatile int g_running;
static volatile int g_stop;
static volatile unsigned int g_state = MARU_SSH_STATE_INVALID;
/// **`volatile` 인 이유는 옆의 `g_running` 과 같다** — 펌프 스레드가 세우고(`ssh_open` 의 out 인자)
/// UI·렌더 스레드가 `open_control` 같은 자리에서 **자물쇠 밖으로** 읽는다. 한때 이것만 빠져 있었다.
static volatile unsigned int g_handle;
static int g_fd = -1;
/// **쓸 것이 생겼다고 읽기 대기를 깨우는 관.**
///
/// 친 글자를 소켓에 내보내는 것은 루프 머리의 `flush_out` 이고, 거기 닿으려면 아래 `poll` 이
/// 리턴해야 한다. 깨울 방법이 없던 시절에는 그 조건이 **서버가 먼저 뭔가 보내거나 2초가 지나는
/// 것** 뿐이었다 — 셸이 조용한 프롬프트에서 한 글자를 치면 **최대 2초 뒤에야** 나갔다(기기 실측:
/// 연타하면 에코가 대신 깨워 줘서 빨라지고, 잠깐 멈췄다 치면 다시 굳는다).
///
/// 타임아웃을 줄이는 것으로는 못 고친다 — 그 값은 **정지 표시를 보는 주기**라 짧게 하면 초당
/// 수십 번 깨어나고, 모바일이 30Hz 를 고른 이유(배터리·발열)와 정면으로 부딪힌다. 쓸 것이 생긴
/// 순간에만 깨우면 조용할 때는 여전히 안 깨어난다.
static volatile int g_wake_r = -1;
static volatile int g_wake_w = -1;
/// **터미널 축의 실패 이름.** 화면의 연결 배너가 이것으로 말한다(`maru_mobile_set_ssh_status`).
static char g_error[64];
/// **컨트롤 축의 실패 이름 — 슬롯이 따로인 것이 계약이다.** 컨트롤 채널의 사고는 터미널로
/// 번지지 않는다(docs/control-plane.md §4a · docs/ssh-client.md §3.4.1). 한 슬롯을 같이 쓰던
/// 시절에는 세션 목록을 열려다 난 `not_running` 이 배너에 박혀, **셸이 멀쩡히 떠 있는데
/// "붙지 못했다" 가 세션 내내 남았다**(기기 실측). 로그도 같은 슬롯을 찍어 그 뒤의 컨트롤
/// 실패가 전부 첫 이름으로 보였다 — 진짜 원인이 자기 로그에 가렸다.
static char g_control_error[64];
/// 세션이 끝난 뒤에도 남는 재키잉 횟수. **핸들을 닫으면 값이 사라지므로** 닫기 직전에 챙긴다 —
/// 검증과 로그는 세션이 끝난 다음에 읽는다.
static unsigned int g_last_rekeys;
static MaruSshPumpConfig g_cfg;
/// **문자열은 우리가 복사해 든다.** 호출자에게 "start 가 도는 동안 살려 두라" 고 요구하면
/// 언젠가 안 지켜진다 — 서비스가 다시 시작되면서 같은 자리를 덮어쓰는 것이 가장 흔한 모양이고,
/// 그때 세션은 이미 그 포인터를 보고 있다.
static char g_host[256];
static char g_user[128];
static char g_fingerprint[128];
static MaruSshPumpHooks g_hooks;
static unsigned char g_secret[MARU_SSH_SECRET_KEY_BYTES];
/// 키를 받았나. **없을 수 있다** — 키가 아직 없는 기기도 비밀번호만 여는 서버에는 붙는다.
static int g_has_secret;
/// `write`·`resize` 는 **다른 스레드에서** 온다(IME·회전). 세션 슬롯을 두 스레드가 만지므로
/// 여기서 직렬화한다 — 브리지 자물쇠(host 것)와는 다른 자물쇠다: 이건 세션용이다.
static pthread_mutex_t g_session_lock = PTHREAD_MUTEX_INITIALIZER;

/// 상대가 끊었을 때의 이름을 정한다(정의는 아래 — `flush_out` 이 먼저 부른다).
static void set_closed_error(void);

static void set_error(const char *name) {
    // **먼저 난 실패를 남긴다** — 뒤에 난 것으로 덮으면 원인이 결과에 가린다.
    if (g_error[0] != 0) return;
    snprintf(g_error, sizeof g_error, "%s", name);
}

/// 컨트롤 축의 실패를 적는다. **터미널 축과 규율이 반대로, 최신이 이긴다.**
///
/// 터미널은 세션이 한 번 무너지는 이야기라 "먼저 난 것" 이 원인이다. 컨트롤은 다르다 —
/// 목록 화면에 들어갈 때마다 여는 **독립 사건**이고(계약 §4a: 재시도는 사용자가 그 화면에
/// 다시 올 때다), 첫 실패를 붙들면 그 뒤 시도의 이유를 영영 못 본다. 그래서 여는 자리에서
/// 지우고 그 회차의 결과만 남긴다.
static void set_control_error(const char *name) {
    snprintf(g_control_error, sizeof g_control_error, "%s", name);
}

/// 읽기 대기를 깨운다. **다른 스레드에서 부른다**(UI·IME·회전).
///
/// 관이 가득 차 있어도 그냥 둔다 — 그것은 "이미 깨울 신호가 밀려 있다" 는 뜻이라 한 번 더 쓸
/// 이유가 없다. 그래서 실패를 오류로 세지 않는다(§5 의 "조용한 실패" 와 다르다: 여기서는
/// **아무것도 잃지 않는다**).
static void pump_wake(void) {
    int fd = g_wake_w;
    if (fd < 0) return;
    const unsigned char one = 1;
    ssize_t w = write(fd, &one, 1);
    (void)w;
}

/// 관에 쌓인 신호를 비운다. 몇 개가 왔든 할 일은 하나다 — 루프를 한 바퀴 도는 것.
static void pump_wake_drain(void) {
    int fd = g_wake_r;
    if (fd < 0) return;
    unsigned char buf[64];
    while (read(fd, buf, sizeof buf) > 0) {
    }
}

static void set_state(unsigned int state) {
    if (g_state == state) return;
    g_state = state;
    if (g_hooks.state_changed) g_hooks.state_changed(g_hooks.ctx, state);
}

static void host_lock(void) {
    if (g_hooks.lock) g_hooks.lock(g_hooks.ctx);
}

static void host_unlock(void) {
    if (g_hooks.unlock) g_hooks.unlock(g_hooks.ctx);
}

static int fill_entropy(unsigned char *out, unsigned long len) {
#if defined(__APPLE__)
    arc4random_buf(out, len);
    return 0;
#else
    unsigned long off = 0;
    while (off < len) {
        long n = getrandom(out + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (unsigned long)n;
    }
    return 0;
#endif
}

/// 이름을 풀어 붙는다. **host 이름을 그대로 받는다** — 기기에서는 사용자가 이름을 적는다.
static int connect_to(const char *host, unsigned short port) {
    char port_text[16];
    snprintf(port_text, sizeof port_text, "%u", (unsigned)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC; // v4·v6 둘 다
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *list = NULL;
    if (getaddrinfo(host, port_text, &hints, &list) != 0 || list == NULL) {
        set_error("resolve_failed");
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *it = list; it != NULL; it = it->ai_next) {
        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) continue;
        // **논블로킹으로 걸고 기다린다.** 그래야 시한도 두고 취소도 본다.
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, it->ai_addr, it->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            int waited = 0;
            rc = -1;
            while (waited < PUMP_CONNECT_TIMEOUT_MS && !g_stop) {
                struct pollfd pfd;
                pfd.fd = fd;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                int pr = poll(&pfd, 1, PUMP_CONNECT_POLL_MS);
                if (pr < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                if (pr == 0) {
                    waited += PUMP_CONNECT_POLL_MS;
                    continue;
                }
                int err = 0;
                socklen_t len = sizeof err;
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) rc = 0;
                break;
            }
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags); // 붙었으면 다시 블로킹으로(읽기는 타임아웃이 든다)
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(list);
    if (fd < 0) {
        set_error("connect_failed");
        return -1;
    }
    // **읽기를 영원히 막지 않는다** — 이 주기마다 정지 표시를 본다.
    struct timeval tv;
    tv.tv_sec = PUMP_READ_TIMEOUT_S;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
#if defined(SO_NOSIGPIPE)
    // **`SIGPIPE` 로 죽지 않는다.** 상대가 먼저 끊은 뒤 쓰면 기본 동작이 프로세스 종료다 —
    // 모바일에서 그것은 앱이 통째로 사라지는 것이다.
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    return fd;
}

/// 쌓인 선 바이트를 보낸다. **부분 전송이 정상이다** — 받은 만큼만 `consume` 한다.
static int flush_out(void) {
    while (maru_mobile_ssh_out_len(g_handle) > 0) {
        if (g_stop) return -1;
        unsigned int len = maru_mobile_ssh_out_len(g_handle);
        const unsigned char *ptr = maru_mobile_ssh_out_ptr(g_handle);
#if defined(MSG_NOSIGNAL)
        long n = send(g_fd, ptr, len, MSG_NOSIGNAL);
#else
        long n = write(g_fd, ptr, len);
#endif
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            // **끊긴 것은 쓰기에서도 드러난다.** 상대가 먼저 닫으면 우리 쓰기가 `EPIPE`·
            // `ECONNRESET` 으로 실패하는데, 그것을 `write_failed` 로 부르면 **같은 사실이
            // 세 가지 이름으로 보고된다**(EOF·읽기 리셋·쓰기 실패 — 어느 쪽이 먼저 걸리는지는
            // 타이밍이다. 테스트가 그 셋 사이를 오갔다).
            if (n < 0 && (errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN)) {
                set_closed_error();
                return -1;
            }
            set_error("write_failed");
            return -1;
        }
        if (maru_mobile_ssh_out_consume(g_handle, (unsigned int)n) != MARU_SSH_OK) {
            set_error("consume_failed");
            return -1;
        }
    }
    return 0;
}

/// 컨트롤 채널이 받은 바이트를 host 에 넘긴다.
///
/// **가져가야 코어가 계속 돈다** — 안 가져가면 배압으로 `feed` 가 멈춘다(계약 §3.4.1). 훅이
/// 없으면 채널을 열 일도 없으므로 그때는 들어올 바이트도 없다.
static void drain_control(void) {
    // 훅이 없으면 채널도 안 열렸다(`maru_ssh_pump_open_control` 이 막는다) — 올 바이트가 없다.
    if (!g_hooks.control) return;
    pthread_mutex_lock(&g_session_lock);
    unsigned int len = maru_mobile_ssh_control_len(g_handle);
    const unsigned char *ptr = maru_mobile_ssh_control_ptr(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    if (len == 0) return;

    host_lock();
    g_hooks.control(g_hooks.ctx, ptr, len);
    host_unlock();

    pthread_mutex_lock(&g_session_lock);
    maru_mobile_ssh_control_consume(g_handle, len);
    pthread_mutex_unlock(&g_session_lock);
}

/// 화면 바이트를 host 에 넘기고, 코어가 만든 답을 원격으로 돌려보낸다.
static void drain_screen(void) {
    // **세션 슬롯은 한 자물쇠가 지킨다.** 화면 쪽과 선 쪽이 다른 배열이라 지금은 부딪히지
    // 않지만, "어느 것은 잠그고 어느 것은 안 잠근다" 는 규칙은 다음 사람이 못 지킨다.
    pthread_mutex_lock(&g_session_lock);
    unsigned int len = maru_mobile_ssh_screen_len(g_handle);
    const unsigned char *ptr = maru_mobile_ssh_screen_ptr(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    if (len == 0) return;

    host_lock();
    if (g_hooks.screen) g_hooks.screen(g_hooks.ctx, ptr, len);
    unsigned char response[PUMP_RESPONSE_CAP];
    unsigned long got = 0;
    if (g_hooks.take_response) got = g_hooks.take_response(g_hooks.ctx, response, sizeof response);
    host_unlock();

    pthread_mutex_lock(&g_session_lock);
    maru_mobile_ssh_screen_consume(g_handle, len);
    pthread_mutex_unlock(&g_session_lock);

    // **원격이 물었으면 답한다** — 안 하면 커서 위치를 묻는 프로그램이 기다리며 멈춘다.
    if (got > 0) {
        unsigned long off = 0;
        while (off < got) {
            unsigned int sent = 0;
            pthread_mutex_lock(&g_session_lock);
            int st = maru_mobile_ssh_write(g_handle, response + off, (unsigned int)(got - off), &sent);
            pthread_mutex_unlock(&g_session_lock);
            if (st != MARU_SSH_OK && st != MARU_SSH_ERR_BUFFER) {
                set_error("response_write_failed");
                return;
            }
            if (sent == 0) break; // 창이 닫혔다 — 다음 바퀴에 다시
            off += sent;
        }
    }
}

/// 상대가 끊었을 때의 이름. **끊긴 시점을 함께 본다** — "상대가 끊었다" 만 남기면 SSH 가 아닌
/// 상자(캡티브 포털·프록시)에 붙었을 때도 같은 말이 나오고, 사용자는 주소를 고쳐야 하는지
/// 기다려야 하는지 모른다. 상태는 추측이 아니라 우리가 아는 사실이다.
static void set_closed_error(void) {
    unsigned int at = maru_mobile_ssh_state(g_handle);
    if (at == MARU_SSH_STATE_VERSION_EXCHANGE) {
        set_error("no_ssh_version"); // 버전 줄을 끝내 안 줬다
    } else if (at != MARU_SSH_STATE_READY && at != MARU_SSH_STATE_CLOSED) {
        set_error("closed_before_ready"); // 붙는 중에 끊겼다(인증·채널 단계)
    } else {
        set_error("closed_by_peer");
    }
}

/// **입력 없이 한 발 민다.** 진행은 "먹었나" 만이 아니라 "상태가 옮겨졌나" 도 포함한다
/// (SSH 계약 §3.5) — 호스트키 승인은 바이트를 안 먹고 상태만 옮기는 걸음이라, 승인 뒤 소켓만
/// 기다리면 **서버는 우리 `NEWKEYS` 를, 우리는 서버 바이트를 서로 기다리며 멈춘다**(실측:
/// 상태 4 에서 더 안 나갔다).
static int step_idle(void) {
    static const unsigned char none = 0;
    unsigned int consumed = 0;
    pthread_mutex_lock(&g_session_lock);
    int st = maru_mobile_ssh_feed(g_handle, &none, 0, &consumed);
    pthread_mutex_unlock(&g_session_lock);
    if (st != MARU_SSH_OK && st != MARU_SSH_ERR_BUFFER) {
        set_error(maru_mobile_ssh_last_error(g_handle));
        set_error("idle_feed_failed");
        return -1;
    }
    set_state(maru_mobile_ssh_state(g_handle));
    drain_screen();
    drain_control();
    pthread_mutex_lock(&g_session_lock);
    int bad = flush_out();
    pthread_mutex_unlock(&g_session_lock);
    return bad;
}

/// 호스트키를 판정한다. **자동 승인은 없다**(SSH 계약 §4) — 미리 받은 지문과 같아야 한다.
/// 호스트키 판정 결과. **"아직" 이 값이다** — 사람에게 물어야 할 때가 있어서다.
enum { HOST_KEY_OK = 0, HOST_KEY_FAIL = -1, HOST_KEY_ASK = 1 };

static int decide_host_key(void) {
    const char *fp = maru_mobile_ssh_host_key_fingerprint(g_handle);
    if (fp == NULL || fp[0] == 0) {
        set_error("fingerprint_missing");
        return HOST_KEY_FAIL;
    }
    // **핀이 있으면 그것만 본다.** 다르면 붙지 않는다 — 사용자에게 묻지도 않는다: 아는 서버가
    // 다른 키를 내미는 것은 중간자일 수 있고, 그 자리에서 "그래도 붙을까요" 를 띄우면 사람은
    // 대개 누른다(SSH 계약 §4).
    if (g_cfg.expect_fingerprint != NULL && g_cfg.expect_fingerprint[0] != 0) {
        if (strcmp(fp, g_cfg.expect_fingerprint) != 0) {
            set_error("host_key_mismatch");
            return HOST_KEY_FAIL;
        }
        if (maru_mobile_ssh_accept_host_key(g_handle) != MARU_SSH_OK) {
            set_error("accept_failed");
            return HOST_KEY_FAIL;
        }
        return HOST_KEY_OK;
    }
    // **핀이 없다 — 처음 보는 서버다.** 예전에는 여기서 `fingerprint_not_pinned` 로 끝냈는데,
    // 그러면 지문을 미리 아는 사람만 붙을 수 있다(폰에서 그것을 알아낼 길이 없다). 자동 승인은
    // 여전히 안 한다(§4) — **사람에게 보여 주고 묻는다.**
    return HOST_KEY_ASK;
}

/// 사용자의 답(0=아직, 1=승인, 2=거절). 화면이 정하고 host 가 넣는다.
static int g_host_key_answer;

/// 지금 상대가 내민 호스트키의 지문(없으면 빈 문자열). **host 가 화면에 띄우려면 필요하다** —
/// 세션 핸들은 펌프가 들고 있어 밖에서 못 묻는다.
const char *maru_ssh_pump_host_key_fingerprint(void) {
    pthread_mutex_lock(&g_session_lock);
    const char *fp = g_handle ? maru_mobile_ssh_host_key_fingerprint(g_handle) : "";
    pthread_mutex_unlock(&g_session_lock);
    return fp ? fp : "";
}

int maru_ssh_pump_accept_host_key(int accept) {
    pthread_mutex_lock(&g_session_lock);
    g_host_key_answer = accept ? 1 : 2;
    pthread_mutex_unlock(&g_session_lock);
    return 0;
}

/// **사용자가 친 비밀번호를 기다리는 자리.** 호스트키 승인은 미리 받은 지문으로 그 자리에서
/// 판정하지만(위), 비밀번호는 **사람이 쳐야** 나온다 — 펌프 스레드는 UI 를 못 여니 상태만
/// 알리고 기다린다. 계약 §3.4 가 "저장하지 않는다" 로 정했으므로 쓰고 바로 지운다.
static char g_password[256];
static unsigned int g_password_len;
static int g_password_ready;

/// host 가 사용자에게 받은 비밀번호를 넣는다. **한 번 쓰고 지운다.**
int maru_ssh_pump_password(const char *password, unsigned int len) {
    if (password == NULL || len == 0 || len >= sizeof g_password) return -1;
    pthread_mutex_lock(&g_session_lock);
    memcpy(g_password, password, len);
    g_password_len = len;
    g_password_ready = 1;
    pthread_mutex_unlock(&g_session_lock);
    return 0;
}

/// 선에서 읽은 바이트를 모아 두는 자리(스택이 아니라 정적 — 2MiB 스택에 256KiB 를 또 얹지 않는다).
static unsigned char g_in[PUMP_IN_CAP];
static unsigned long g_in_len;

/// 모아 둔 바이트를 코어에 먹인다. **먹다 남은 것은 앞으로 당겨 다음 읽기와 이어 붙인다** —
/// SSH 패킷은 읽기 경계에 걸쳐 오고, 남은 조각을 버리면 그 세션은 거기서 끝난다(실측: 버리는
/// 판을 만들었더니 `NEWKEYS` 를 못 받고 멈췄다).
static int feed_buffered(void) {
    while (g_in_len > 0 && !g_stop) {
        unsigned int consumed = 0;
        pthread_mutex_lock(&g_session_lock);
        int st = maru_mobile_ssh_feed(g_handle, g_in, (unsigned int)g_in_len, &consumed);
        pthread_mutex_unlock(&g_session_lock);
        if (st == MARU_SSH_ERR_BUFFER) {
            // 배압 — 비우고 다시 준다.
            drain_screen();
            drain_control();
            pthread_mutex_lock(&g_session_lock);
            int bad = flush_out();
            pthread_mutex_unlock(&g_session_lock);
            if (bad) return -1;
            continue;
        }
        if (st != MARU_SSH_OK) {
            // **버전 줄을 읽는 중의 실패는 "SSH 가 아니다" 다.** 그 단계에서 코어가 거절했다는
            // 것은 상대가 SSH 로 말하지 않았다는 뜻이고(HTTP 응답·프록시 인사말 따위), 그것을
            // 일반 오류로 접으면 사용자는 주소를 고쳐야 하는지 기다려야 하는지 모른다.
            // 끊김 경로(EOF)와 **같은 이름**을 쓰는 것이 요점이다 — 어느 쪽이 먼저 오느냐는
            // 타이밍이라, 이름이 갈리면 같은 상황이 두 가지로 보고된다(테스트가 흔들렸다).
            if (maru_mobile_ssh_state(g_handle) == MARU_SSH_STATE_VERSION_EXCHANGE) {
                set_error("no_ssh_version");
            } else {
                set_error(maru_mobile_ssh_last_error(g_handle));
                set_error("feed_failed");
            }
            return -1;
        }
        // 상태는 **먹일 때마다** 본다 — 바깥에서 한 번만 보면 한 번의 `feed` 안에서 지나간
        // 상태를 통째로 놓친다(셸이 뜬 자리를 못 보고 끝나는 것이 실측이다).
        set_state(maru_mobile_ssh_state(g_handle));
        drain_screen();
        drain_control();
        pthread_mutex_lock(&g_session_lock);
        int bad = flush_out();
        pthread_mutex_unlock(&g_session_lock);
        if (bad) return -1;
        if (consumed == 0) return 0; // 덜 왔다 — 더 읽어서 이어 붙인다
        memmove(g_in, g_in + consumed, g_in_len - consumed);
        g_in_len -= consumed;
    }
    return 0;
}

static void *pump_main(void *unused) {
    (void)unused;
    g_in_len = 0;

    g_fd = connect_to(g_cfg.host, g_cfg.port);
    if (g_fd < 0) goto done;

    unsigned char entropy[MARU_SSH_ENTROPY_BYTES];
    if (fill_entropy(entropy, sizeof entropy) != 0) {
        set_error("entropy_failed");
        goto done;
    }
    int st = maru_mobile_ssh_open((const unsigned char *)g_cfg.user, (unsigned int)strlen(g_cfg.user),
                                  g_has_secret ? g_secret : NULL, entropy, (const unsigned char *)"xterm-256color", 14,
                                  g_cfg.cols, g_cfg.rows, 0, 1, &g_handle);
    memset(entropy, 0, sizeof entropy);
    // **키 사본은 여기서 끝난다.** 코어가 자기 몫을 챙겼으므로(그쪽은 `close` 가 지운다) 이
    // 사본을 세션 내내 들고 있을 이유가 없다 — 남는 시간이 짧을수록 덤프·크래시 리포트에
    // 실릴 확률이 낮다.
    memset(g_secret, 0, sizeof g_secret);
    if (st != MARU_SSH_OK) {
        set_error(maru_mobile_ssh_last_error(g_handle));
        set_error("open_failed");
        goto done;
    }
    set_state(maru_mobile_ssh_state(g_handle));

    unsigned int password_waited_ms = 0;
    unsigned int host_key_waited_ms = 0;
    while (!g_stop) {
        pthread_mutex_lock(&g_session_lock);
        int bad = flush_out();
        pthread_mutex_unlock(&g_session_lock);
        if (bad) break;

        unsigned int state = maru_mobile_ssh_state(g_handle);
        set_state(state);
        if (state == MARU_SSH_STATE_HOST_KEY_DECISION) {
            pthread_mutex_lock(&g_session_lock);
            int rc = decide_host_key();
            int answer = g_host_key_answer;
            pthread_mutex_unlock(&g_session_lock);
            if (rc == HOST_KEY_FAIL) break;
            if (rc == HOST_KEY_ASK) {
                // **사람을 기다린다**(비밀번호와 같은 자리). 상태는 이미 host 가 보고 있고,
                // 지문은 `maru_mobile_ssh_host_key_fingerprint` 로 읽어 화면에 띄운다.
                if (answer == 0) {
                    host_key_waited_ms += PUMP_PASSWORD_POLL_MS;
                    if (host_key_waited_ms >= PUMP_PASSWORD_TIMEOUT_MS) {
                        set_error("host_key_timeout");
                        break;
                    }
                    struct timespec ts;
                    ts.tv_sec = 0;
                    ts.tv_nsec = (long)PUMP_PASSWORD_POLL_MS * 1000000L;
                    nanosleep(&ts, NULL);
                    continue;
                }
                if (answer == 2) {
                    set_error("host_key_rejected");
                    break;
                }
                pthread_mutex_lock(&g_session_lock);
                int ok = maru_mobile_ssh_accept_host_key(g_handle);
                pthread_mutex_unlock(&g_session_lock);
                if (ok != MARU_SSH_OK) {
                    set_error("accept_failed");
                    break;
                }
            }
            if (step_idle() != 0) break; // 승인은 상태만 옮긴다 — 밀어 줘야 `NEWKEYS` 가 나간다
            continue;
        }
        // **비밀번호는 사람이 쳐야 온다.** 상태만 알리고(host 가 그것으로 화면을 연다) 기다린다.
        // 무한히는 아니다 — 앱이 배경으로 가거나 사용자가 잊으면 스레드가 영영 남는다.
        if (state == MARU_SSH_STATE_PASSWORD_NEEDED) {
            if (!g_password_ready) {
                password_waited_ms += PUMP_PASSWORD_POLL_MS;
                if (password_waited_ms >= PUMP_PASSWORD_TIMEOUT_MS) {
                    set_error("password_timeout");
                    break;
                }
                struct timespec ts;
                ts.tv_sec = 0;
                ts.tv_nsec = (long)PUMP_PASSWORD_POLL_MS * 1000000L;
                nanosleep(&ts, NULL);
                continue;
            }
            pthread_mutex_lock(&g_session_lock);
            int rc = maru_mobile_ssh_password(g_handle, (const unsigned char *)g_password, g_password_len);
            // **쓰자마자 지운다**(계약 §3.4) — 실패했더라도 남길 이유가 없다.
            memset(g_password, 0, sizeof g_password);
            g_password_len = 0;
            g_password_ready = 0;
            pthread_mutex_unlock(&g_session_lock);
            if (rc != MARU_SSH_OK) {
                set_error(maru_mobile_ssh_last_error(g_handle));
                break;
            }
            if (step_idle() != 0) break; // 보낸 것을 밀어 준다(호스트키 승인과 같은 자리)
            continue;
        }
        if (state == MARU_SSH_STATE_CLOSED) {
            unsigned int reason = maru_mobile_ssh_disconnect_reason(g_handle);
            if (reason != 0) set_error("disconnected");
            break;
        }

        // **모아 둔 것부터 다시 먹인다.** 상태가 바뀌면(예: 호스트키 승인) 아까 못 먹은 바이트를
        // 이제 먹을 수 있다 — 그것을 안 하고 소켓만 기다리면 **이미 도착한 `NEWKEYS` 를 우리
        // 버퍼에 둔 채로 영영 기다린다**(실측: 상태 5 에서 멈췄고 서버 로그에는 NEWKEYS 를
        // 주고받은 기록이 남아 있었다).
        if (g_in_len > 0 && feed_buffered() != 0) break;

        if (g_in_len >= sizeof g_in) {
            // 상한만큼 모았는데도 코어가 한 바이트도 안 먹었다 — 규약을 어긴 상대다.
            set_error("packet_too_large");
            break;
        }
        // **소켓과 깨우기 관을 함께 기다린다.** 예전에는 `read` 하나로 기다려서, 보낼 글자가
        // 쌓여 있어도 **서버가 먼저 말하거나 2초가 지날 때까지** 못 나갔다 — 루프 머리의
        // `flush_out` 에 닿질 못했기 때문이다. 두 fd 를 함께 보면 친 순간 깨어나 그 자리에서 보낸다.
        struct pollfd pfds[2];
        pfds[0].fd = g_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = g_wake_r;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;
        // 관이 없으면(만들기에 실패했다) 소켓만 본다 — 예전 동작으로 떨어질 뿐 세션은 산다.
        int pr = poll(pfds, g_wake_r >= 0 ? 2 : 1, PUMP_READ_TIMEOUT_S * 1000);
        if (pr < 0) {
            if (errno == EINTR) continue;
            set_error("read_failed");
            break;
        }
        // 타임아웃은 실패가 아니다 — 머리로 돌아가 정지 표시를 보고, 쌓인 것이 있으면 민다.
        if (pr == 0) continue;
        if (g_wake_r >= 0 && (pfds[1].revents & POLLIN)) pump_wake_drain();
        // **깨우기만 왔으면 읽지 않는다.** 소켓은 조용한데 `read` 를 부르면 타임아웃만큼 다시
        // 붙들려, 정작 보내려던 글자가 그만큼 또 늦는다.
        if (!(pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;
        long n = read(g_fd, g_in + g_in_len, sizeof g_in - g_in_len);
        if (n < 0) {
            if (errno == EINTR) continue;
            // 타임아웃은 실패가 아니다 — 정지 표시를 보라는 신호다.
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            // **상대가 끊은 것은 하나의 사실이다.** 그것이 EOF 로 오는지 `ECONNRESET` 으로
            // 오는지는 타이밍이라, 이름을 갈라 두면 **같은 상황이 두 가지로 보고된다**
            // (테스트가 그 때문에 흔들렸다 — 실측).
            if (errno == ECONNRESET || errno == ENOTCONN || errno == EPIPE) {
                set_closed_error();
                break;
            }
            set_error("read_failed");
            break;
        }
        if (n == 0) {
            set_closed_error();
            break;
        }
        g_in_len += (unsigned long)n;
        if (feed_buffered() != 0) break;
    }

done:
    if (g_handle != 0) {
        pthread_mutex_lock(&g_session_lock);
        g_last_rekeys = maru_mobile_ssh_rekeys(g_handle);
        maru_mobile_ssh_close(g_handle);
        g_handle = 0;
        pthread_mutex_unlock(&g_session_lock);
    }
    // **펌프가 끝났으면 세션은 끝났다 — 그것을 반드시 알린다.**
    //
    // 코어 상태를 그대로 올리면 안 된다: 선이 끊겼을 때(모바일에서 가장 흔한 끝이다) 코어는
    // 여전히 `ready` 다 — 끊긴 것은 소켓이지 프로토콜이 아니기 때문이다. 그대로 두면 host 는
    // "붙어 있다" 고 믿고 알림도 "유지 중" 인 채로 남는다(실측: 서버를 죽여도 아무 일도 안
    // 났고 서비스가 그대로 살아 있었다).
    set_state(MARU_SSH_STATE_CLOSED);
    if (g_fd >= 0) {
        close(g_fd);
        g_fd = -1;
    }
    // **관을 닫는 것은 `g_running` 을 내리기 전이다.** 쓰는 쪽은 그 표시를 보고 들어오므로,
    // 순서가 반대면 이미 닫은 fd 에 쓰는 창이 생긴다(그래도 EBADF 로 조용히 지나가지만,
    // 순서를 지키면 그 창 자체가 없다).
    {
        int r = g_wake_r, w = g_wake_w;
        g_wake_r = -1;
        g_wake_w = -1;
        if (r >= 0) close(r);
        if (w >= 0) close(w);
    }
    // **비밀은 안 남긴다.**
    memset(g_secret, 0, sizeof g_secret);
    g_running = 0;
    return NULL;
}

int maru_ssh_pump_start(const MaruSshPumpConfig *cfg, const MaruSshPumpHooks *hooks) {
    // **스스로 끝난 스레드를 여기서 거둔다.** 세션은 사용자가 안 멈춰도 끝난다(서버가 끊거나
    // 오류로). 그때 `stop` 을 안 부르면 joinable 스레드가 그대로 남고, 재접속을 반복하는
    // 모바일에서 그만큼 샌다. **이 누수는 테스트로 못 본다** — 프로세스 밖에서 안 보이는
    // 자원이라, 여기서 규칙으로 막는다.
    if (g_joinable && !g_running) {
        pthread_join(g_thread, NULL);
        g_joinable = 0;
    }
    if (g_running) return -1;
    if (cfg == NULL || cfg->host == NULL || cfg->user == NULL) return -2;
    if (cfg->port == 0 || cfg->cols == 0 || cfg->rows == 0) return -2;

    g_cfg = *cfg;
    snprintf(g_host, sizeof g_host, "%s", cfg->host);
    snprintf(g_user, sizeof g_user, "%s", cfg->user);
    snprintf(g_fingerprint, sizeof g_fingerprint, "%s",
             cfg->expect_fingerprint ? cfg->expect_fingerprint : "");
    g_cfg.host = g_host;
    g_cfg.user = g_user;
    g_cfg.expect_fingerprint = g_fingerprint;
    g_hooks = hooks ? *hooks : (MaruSshPumpHooks){0};
    g_host_key_answer = 0; // 지난 세션의 답을 물려주지 않는다
    g_has_secret = cfg->secret != NULL;
    if (g_has_secret) memcpy(g_secret, cfg->secret, sizeof g_secret);
    else memset(g_secret, 0, sizeof g_secret);
    g_error[0] = 0;
    // 컨트롤 축도 새 세션에서 깨끗하게 시작한다 — 지난 세션의 이름이 남으면 목록 화면이
    // 이번 세션에서 있지도 않은 일을 말한다.
    g_control_error[0] = 0;
    g_last_rekeys = 0;
    g_handle = 0;
    // **깨우기 관을 스레드보다 먼저 연다.** 뒤에 열면 그 사이에 친 글자가 깨울 곳을 못 찾는다.
    // **양쪽 다 non-blocking 이다**: 쓰는 쪽은 관이 차도 안 막혀야 하고(UI 스레드다), 읽는 쪽은
    // 비울 때 마지막 `read` 가 안 막혀야 한다. `pipe2` 는 리눅스 전용이라 `fcntl` 로 세운다 —
    // 이 파일은 iOS·Android·데스크톱 스모크가 함께 쓴다.
    if (g_wake_r >= 0) close(g_wake_r);
    if (g_wake_w >= 0) close(g_wake_w);
    g_wake_r = -1;
    g_wake_w = -1;
    {
        int wp[2];
        if (pipe(wp) == 0) {
            fcntl(wp[0], F_SETFL, fcntl(wp[0], F_GETFL, 0) | O_NONBLOCK);
            fcntl(wp[1], F_SETFL, fcntl(wp[1], F_GETFL, 0) | O_NONBLOCK);
            g_wake_r = wp[0];
            g_wake_w = wp[1];
        }
        // 실패해도 세션은 연다 — 그때는 예전처럼 타임아웃으로만 돈다(느릴 뿐 안 죽는다).
    }
    g_stop = 0;
    g_state = MARU_SSH_STATE_INVALID;
    g_running = 1;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) {
        g_running = 0;
        memset(g_secret, 0, sizeof g_secret);
        set_error("thread_attr_failed");
        return -3;
    }
    // **스택 크기를 명시한다**(위 상수 주석). 기본값이면 첫 `feed` 에서 죽는다.
    pthread_attr_setstacksize(&attr, PUMP_STACK_BYTES);
    int rc = pthread_create(&g_thread, &attr, pump_main, NULL);
    pthread_attr_destroy(&attr);
    if (rc == 0) g_joinable = 1;
    if (rc != 0) {
        g_running = 0;
        memset(g_secret, 0, sizeof g_secret);
        set_error("thread_failed");
        return -3;
    }
    return 0;
}

void maru_ssh_pump_stop(void) {
    if (!g_joinable) return;
    g_stop = 1;
    // **정지도 깨워서 알린다.** 표시만 세우면 펌프는 `poll` 타임아웃까지 그대로 있어, 앱을 끄거나
    // 세션을 내릴 때 그만큼 붙들린다(그 값이 곧 종료 지연이 된다).
    pump_wake();
    // **자기 자신은 안 거둔다.** 끝을 알리는 훅(`state_changed`) 안에서 host 가 `stop` 을 부르는
    // 것은 자연스러운 흐름인데(서비스를 내린다), 거기서 자기 스레드를 `join` 하면 그 자리에서
    // 교착한다 — 앱이 멈춘 채로 남는다.
    if (pthread_equal(pthread_self(), g_thread)) return;
    pthread_join(g_thread, NULL);
    g_joinable = 0;
    g_running = 0;
}

unsigned int maru_ssh_pump_state(void) { return g_state; }

int maru_ssh_pump_is_running(void) { return g_running ? 1 : 0; }

unsigned int maru_ssh_pump_rekeys(void) {
    if (g_handle == 0) return g_last_rekeys;
    pthread_mutex_lock(&g_session_lock);
    unsigned int n = maru_mobile_ssh_rekeys(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    return n;
}

const char *maru_ssh_pump_error(void) { return g_error; }

const char *maru_ssh_pump_control_error(void) { return g_control_error; }

unsigned long maru_ssh_pump_write(const unsigned char *bytes, unsigned long len) {
    if (!g_running || g_handle == 0) return 0;
    unsigned long off = 0;
    while (off < len) {
        unsigned int sent = 0;
        pthread_mutex_lock(&g_session_lock);
        int st = maru_mobile_ssh_write(g_handle, bytes + off, (unsigned int)(len - off), &sent);
        pthread_mutex_unlock(&g_session_lock);
        if (st != MARU_SSH_OK) break;
        if (sent == 0) break; // 창이 닫혔다 — 나머지는 호출자가 다시 준다
        off += sent;
    }
    // **여기서 깨운다.** 코어 버퍼에 넣는 것과 소켓으로 나가는 것은 다른 일이고, 내보내는 쪽은
    // 펌프 스레드다 — 안 깨우면 그 스레드가 `poll` 에 붙들린 동안 글자가 버퍼에 앉아 있는다.
    if (off > 0) pump_wake();
    return off;
}

int maru_ssh_pump_open_control(const char *command, unsigned int len) {
    // **훅 검사가 먼저다.** 훅 유무는 펌프가 도는지와 무관한 정적 조건이고, 뒤에 두면 붙는
    // 중에는 "안 돈다" 로만 답해 **host 가 진짜 이유를 못 본다**(그 상태로 붙고 나서 다시 부르면
    // 그때야 진짜 이유가 나온다 — 두 번 걸리는 실수다).
    //
    // **받을 사람이 없으면 열지 않는다.** 처음에는 "훅이 없으면 안 가져간다" 로 뒀는데, 그러면
    // 컨트롤 버퍼가 차서 코어가 배압으로 멈추고 **터미널까지 함께 멈춘다** — 채널 둘을 독립으로
    // 만든 이유를 그 자리에서 잃는다(적대적 검증이 잡았다). 여는 자리에서 거절하면 그 상황이
    // 아예 생기지 않는다.
    // **이 회차의 결과만 남긴다** — 지난 시도의 이름이 남아 있으면 화면이 옛 이유를 말한다.
    g_control_error[0] = 0;
    if (!g_hooks.control) {
        set_control_error("no_control_hook");
        return -1;
    }
    if (!g_running || g_handle == 0) {
        set_control_error("not_running");
        return -1;
    }
    pthread_mutex_lock(&g_session_lock);
    int st = maru_mobile_ssh_open_control(g_handle, (const unsigned char *)command, len);
    pthread_mutex_unlock(&g_session_lock);
    if (st != MARU_SSH_OK) {
        // **왜 못 열었는지를 남긴다** — 재키잉 중이면 다시 부르면 되고, 그 밖이면 축을 접어야 한다.
        set_control_error(maru_mobile_ssh_last_error(g_handle));
        // **코어 슬롯도 비운다.** 슬롯의 `err_name` 은 선착순이라(mobile_ssh.zig 의 `setError`),
        // 여기서 안 비우면 컨트롤이 박은 이름을 **터미널 경로가 집어 든다** — `step_idle`·
        // `feed_buffered` 가 같은 슬롯을 읽는다. 헤더가 "읽은 쪽이 비운다" 고 정해 둔 규율인데
        // (mobile_host_abi.h) 펌프가 한 번도 안 지키고 있었다: 축이 새는 두 번째 경로다.
        maru_mobile_ssh_clear_error(g_handle);
        return st;
    }
    return 0;
}

unsigned long maru_ssh_pump_write_control(const unsigned char *bytes, unsigned long len) {
    if (!g_running || g_handle == 0) return 0;
    unsigned long off = 0;
    while (off < len) {
        unsigned int sent = 0;
        pthread_mutex_lock(&g_session_lock);
        int st = maru_mobile_ssh_write_control(g_handle, bytes + off, (unsigned int)(len - off), &sent);
        pthread_mutex_unlock(&g_session_lock);
        if (st != MARU_SSH_OK) break;
        if (sent == 0) break; // 창이 닫혔다 — 나머지는 호출자가 다시 준다
        off += sent;
    }
    // 컨트롤 요청도 같은 이유로 깨운다 — 목록을 부르고 답을 기다리는 축이라 지연이 그대로 보인다.
    if (off > 0) pump_wake();
    return off;
}

int maru_ssh_pump_close_control(void) {
    /* **결과를 돌려준다.** 예전에는 `void` 라 코어가 낸 오류를 아무도 안 읽었고, 그래서 닫기가
       실패해도 host 는 「닫았다」로 넘어갔다 — 원격 명령이 고아로 남아 세션 전환이 통째로
       막혔는데 화면에도 로그에도 아무 말이 없었다(실기 2026-09-04). */
    if (!g_running || g_handle == 0) return -1;
    pthread_mutex_lock(&g_session_lock);
    int rc = maru_mobile_ssh_close_control(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    return rc;
}

unsigned int maru_ssh_pump_control_state(void) {
    if (!g_running || g_handle == 0) return MARU_SSH_CONTROL_NONE;
    pthread_mutex_lock(&g_session_lock);
    unsigned int st = maru_mobile_ssh_control_state(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    return st;
}

int maru_ssh_pump_control_exit_status(unsigned int *code) {
    if (!g_running || g_handle == 0) return -1;
    pthread_mutex_lock(&g_session_lock);
    int st = maru_mobile_ssh_control_exit_status(g_handle, code);
    pthread_mutex_unlock(&g_session_lock);
    return st;
}

const char *maru_ssh_pump_control_stderr(void) {
    if (!g_running || g_handle == 0) return "";
    pthread_mutex_lock(&g_session_lock);
    const char *msg = maru_mobile_ssh_control_stderr(g_handle);
    pthread_mutex_unlock(&g_session_lock);
    return msg;
}

void maru_ssh_pump_resize(unsigned int cols, unsigned int rows) {
    if (!g_running || g_handle == 0) return;
    pthread_mutex_lock(&g_session_lock);
    maru_mobile_ssh_resize(g_handle, cols, rows);
    pthread_mutex_unlock(&g_session_lock);
    // 회전·키보드 오르내림이 만드는 크기 변경도 **즉시** 나가야 원격 격자가 화면과 안 어긋난다.
    pump_wake();
}
