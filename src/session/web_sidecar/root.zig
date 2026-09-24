//! 웹 OSR sidecar 제어 채널 codec 의 입구(W1a). maru 는 `session.web_sidecar` 로, sidecar 실행 파일은 빌드가 만든
//! `web_sidecar_protocol` 모듈(build/web_sidecar.zig)로 **같은 파일**을 쓴다 — 두 쪽이 frame 을 따로 정의하지 않는다.

/// frame 머리(길이 접두·`MWEB`·버전)·상한·오류 집합·바이트 커서.
pub const wire = @import("wire.zig");
/// tag·방향(0~31 은 maru → sidecar, 32~ 는 sidecar → maru)·메시지 구조체.
pub const message = @import("message.zig");
/// 닫힌 필드 규칙 — browser id·view 크기·bool·URL·글.
pub const fields = @import("fields.zig");
/// encode / decodeExact.
pub const codec = @import("codec.zig");
/// StreamingDecoder — 받는 쪽이 방향까지 확인한다.
pub const stream = @import("stream.zig");
/// clampUtf8 — sidecar 가 제목을 글자 중간에서 자르지 않고 줄인다.
pub const text = @import("text.zig");
/// 픽셀 링의 mailbox 규칙(W2) — 원자 워드 하나에 세대·슬롯·dirty.
pub const mailbox = @import("mailbox.zig");
