// 두 모바일 host(iOS·Android)가 **함께 쓰는 SSH 소켓 펌프**.
//
// **왜 여기 있나.** `platform/mobile` 은 OS 호출이 0인 층이라(docs/mobile-platform.md §2) 소켓을
// 들 수 없고, 두 host 에 같은 루프를 두 벌 쓰면 갈린다 — 갈리면 한쪽에서만 나는 결함이 생긴다.
// 그래서 **OS 를 부르는 공용 C** 를 이 층에 둔다: 소켓·스레드·난수만 하고, 화면에 넣는 일과
// 자물쇠는 host 가 훅으로 준다(그쪽은 플랫폼마다 다르다).
//
// **데스크톱에서 먼저 증명된다** — `tools/ssh/pump_smoke.zig` 가 이 파일을 그대로 링크해 진짜
// sshd 와 왕복한다. 기기에서 "안 된다" 가 났을 때 프로토콜·펌프는 이미 초록이므로 남은 것은
// host 배선뿐이다.
#ifndef MARU_SSH_PUMP_H
#define MARU_SSH_PUMP_H

#ifdef __cplusplus
extern "C" {
#endif

/// 접속에 필요한 것. **문자열은 호출자가 소유**하고 `start` 가 도는 동안 살아 있어야 한다.
typedef struct {
    const char *host; /// 이름 또는 주소(getaddrinfo 가 푼다)
    unsigned short port;
    const char *user;
    /// `seed(32) ‖ public(32)` — `maru_mobile_ssh_load_key` 가 만든 값.
    ///
    /// **NULL 일 수 있다**: 키가 아직 없는 기기다. 그때는 코어가 `none` 으로 방법 목록만 물어
    /// (RFC 4252 §5.2) 비밀번호만 여는 서버에 붙는다 — 키가 없다고 시작조차 안 하면 그 서버에는
    /// 영영 못 붙는다(iOS 가 그랬다).
    const unsigned char *secret;
    unsigned int cols;
    unsigned int rows;
    /// **기대하는 호스트키 지문**(`SHA256:...`). 다르면 붙지 않는다.
    ///
    /// 자동 승인은 없다(SSH 계약 §4). 아직 물어볼 화면이 없어서, 지금은 **핀 고정**으로 그
    /// 약속을 지킨다 — 사용자가 미리 넣은 지문과 서버 것이 같아야 한다. 목록 화면(S9b)이
    /// 생기면 그때 물어보고 `known_hosts` 로 옮긴다.
    const char *expect_fingerprint;
} MaruSshPumpConfig;

/// host 가 주는 것. **펌프는 화면도 자물쇠도 모른다.**
typedef struct {
    /// 브리지 호출을 직렬화한다(Android 는 그리기 스레드가 따로다). 없으면 안 부른다.
    void (*lock)(void *ctx);
    void (*unlock)(void *ctx);
    /// 원격 출력. host 는 이것을 `maru_mobile_term_write` 로 넣는다.
    void (*screen)(void *ctx, const unsigned char *bytes, unsigned long len);
    /// 코어가 만든 답을 가져간다(`maru_mobile_take_response`). 없으면 답을 안 보낸다.
    unsigned long (*take_response)(void *ctx, unsigned char *out, unsigned long cap);
    /// 상태가 바뀌면 알린다(`MARU_SSH_STATE_*`).
    ///
    /// **끝은 반드시 온다** — 어떻게 끝나든(정상 종료·선 끊김·오류) 마지막으로
    /// `MARU_SSH_STATE_CLOSED` 가 한 번 온다. host 는 그때 알림을 내리고 서비스를 접는다.
    /// 이 훅 **안에서** `maru_ssh_pump_stop` 을 불러도 된다(자기 자신은 안 거둔다).
    void (*state_changed)(void *ctx, unsigned int state);
    /// **컨트롤 채널이 받은 바이트**(ndjson). 화면과 **다른 훅**이다 — 한 훅으로 합치면 파서가
    /// 사람 화면을 읽게 된다(계약 docs/control-plane.md §4a).
    ///
    /// **줄 경계가 아니다.** 패킷이 실어 온 만큼이라 host 가 줄 단위로 이어 붙인다.
    /// **이 훅이 없으면 채널을 못 연다**(`maru_ssh_pump_open_control` 이 거절한다). 받을 사람이
    /// 없으면 컨트롤 버퍼가 차서 코어가 배압으로 멈추고 **터미널까지 함께 멈춘다** — 채널 둘을
    /// 독립으로 만든 이유를 그 자리에서 잃는다.
    void (*control)(void *ctx, const unsigned char *bytes, unsigned long len);
    void *ctx;
} MaruSshPumpHooks;

/// 붙는다. **스레드를 하나 띄우고 즉시 돌아온다** — 호출자를 막지 않는다.
/// 0=시작함, 음수=시작도 못 함(이미 돌고 있거나 인자가 이상하다).
int maru_ssh_pump_start(const MaruSshPumpConfig *cfg, const MaruSshPumpHooks *hooks);
/// 멈추라고 표시하고 스레드가 끝날 때까지 기다린다. 안 돌고 있으면 아무 일도 안 한다.
void maru_ssh_pump_stop(void);
/// 지금 상태(`MARU_SSH_STATE_*`). 안 돌고 있으면 `MARU_SSH_STATE_INVALID`.
unsigned int maru_ssh_pump_state(void);
/// **지금 돌고 있나.** 상태(`state`)로는 이것을 못 판단한다 — 끝난 세션도 `CLOSED` 를 들고
/// 있어야 host 가 알림을 내릴 수 있기 때문이다. "다시 붙어도 되나" 는 이 함수가 답한다.
int maru_ssh_pump_is_running(void);
/// **사용자가 친 비밀번호를 넣는다**(상태가 `MARU_SSH_STATE_PASSWORD_NEEDED` 일 때). 펌프가
/// 그 자리에서 기다리고 있다가 코어에 넘기고 **바로 지운다**(계약 §3.4 — 저장하지 않는다).
/// 넣지 않으면 2분 뒤 `password_timeout` 으로 끝난다.
int maru_ssh_pump_password(const char *password, unsigned int len);
/// **처음 보는 서버의 호스트키를 승인하거나 거절한다**(상태가 `MARU_SSH_STATE_HOST_KEY_DECISION`
/// 이고 config 에 지문이 없을 때). 지문이 이미 있으면 펌프가 그것만 보고 판정하므로 이 함수를
/// 부를 일이 없다 — **아는 서버가 다른 키를 내밀면 묻지 않고 끊는다**(SSH 계약 §4).
/// 안 넣으면 2분 뒤 `host_key_timeout` 으로 끝난다.
int maru_ssh_pump_accept_host_key(int accept);
/// 지금 상대가 내민 호스트키의 지문(없으면 빈 문자열). 세션 핸들은 펌프가 들고 있으므로
/// host 는 이것으로 읽어 화면에 띄운다.
const char *maru_ssh_pump_host_key_fingerprint(void);
/// 지금 세션이 키를 몇 번 갈았나. 안 돌고 있으면 0.
unsigned int maru_ssh_pump_rekeys(void);
/// **터미널 축의** 마지막 실패 이름. 없으면 빈 문자열. 먼저 난 것이 남는다(원인이 결과에
/// 가리지 않게). 컨트롤 채널의 실패는 여기 안 온다 — `maru_ssh_pump_control_error` 를 쓴다.
const char *maru_ssh_pump_error(void);
/// **컨트롤 축의** 마지막 실패 이름. 없으면 빈 문자열. 터미널과 달리 **최신이 이긴다** —
/// 목록 화면에 들어갈 때마다 여는 독립 사건이라 첫 실패를 붙들면 그 뒤 이유를 못 본다.
///
/// **슬롯이 따로인 것이 계약이다**(docs/control-plane.md §4a): 컨트롤 축이 안 서는 것은
/// "세션 목록이 안 보이는 것" 이지 "접속이 안 되는 것" 이 아니다.
const char *maru_ssh_pump_control_error(void);
/// 키 입력을 원격으로 보낸다(host 의 IME·키바가 부른다). 보낸 바이트 수.
unsigned long maru_ssh_pump_write(const unsigned char *bytes, unsigned long len);
/// 창 크기가 바뀌었다.
void maru_ssh_pump_resize(unsigned int cols, unsigned int rows);

/// **두 번째 채널을 연다** — 원격에서 명령 하나를 돌린다(계약 docs/control-plane.md §4a).
/// 0=열기 시작함, 음수=못 열었다(`maru_ssh_pump_control_error` 에 이름이 남는다 — **터미널
/// 축의 `maru_ssh_pump_error` 가 아니다**).
///
/// **셸이 뜬 뒤에 부른다**(`MARU_SSH_STATE_READY`). 재키잉 중이면 실패로 돌아오고 **아무것도
/// 안 나갔으므로 다시 부르면 된다**.
int maru_ssh_pump_open_control(const char *command, unsigned int len);
/// 컨트롤 채널로 보낸다. 돌려주는 값은 **실제로 보낸 바이트 수**다(터미널 `write` 와 같은 규약).
unsigned long maru_ssh_pump_write_control(const unsigned char *bytes, unsigned long len);
/// 컨트롤 채널을 닫는다. **터미널은 그대로 산다.**
/* 컨트롤 채널을 닫는다. **결과를 돌려준다** — 0 이 성공이고, 그 밖은 코어가 낸 상태다.
   호출자는 이 값을 봐야 한다: 예전에는 `void` 라 닫기 실패가 조용히 지나갔고, 원격 명령이
   고아로 남아 세션 전환이 통째로 막혔다(실기 2026-09-04). */
int maru_ssh_pump_close_control(void);
/// 컨트롤 채널 상태(`MARU_SSH_CONTROL_*`). 안 돌고 있으면 `MARU_SSH_CONTROL_NONE`.
unsigned int maru_ssh_pump_control_state(void);
/// 컨트롤 명령의 종료 코드를 `*code` 에 넣는다. 아직 안 끝났으면 0 이 아닌 값을 돌려준다.
/// **`127` 이면 그 서버에 `maru` 가 없다**(계약 §4a).
int maru_ssh_pump_control_exit_status(unsigned int *code);
/// 컨트롤 명령이 stderr 로 낸 첫 조각(진단용). 화면에도 wire 에도 안 섞인 것이다.
///
/// **들고 있으려면 복사한다** — 다음 호출이 그 자리를 덮는다(`maru_ssh_pump_error` 와 같은 규칙).
const char *maru_ssh_pump_control_stderr(void);

#ifdef __cplusplus
}
#endif
#endif
