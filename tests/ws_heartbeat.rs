//! W12-7: WebSocket heartbeat. An authenticated socket is sent a WebSocket ping
//! every `WsLimits.ping_every` (20 s by default) and is closed with 1001 once
//! `WsLimits.pong_timeout` (60 s) has passed without a *pong*. Nothing else
//! counts as life: a peer that keeps writing text frames but never answers a
//! ping is closed too. A pairing-only socket (no token) is not pinged and keeps
//! the lifetime it always had.
//!
//! The clients here are raw: after the JSON handshake the socket is taken out
//! of the WebSocket library and read, and written, as bytes. A library client
//! answers every ping it reads on its own, which is the one thing these tests
//! need a client *not* to do. All timing is paused tokio time, advanced a
//! second at a time, so a 60 s timeout costs no wall-clock time and the moment
//! a frame arrived is known to the second. The clock is paused only *after* the
//! JSON handshake (`Device::take_over`): with the clock paused, tokio moves it
//! on whenever the runtime is idle, which includes the moments a loopback
//! socket's data is still on its way, so a read with a timeout would expire
//! early. After the handshake nothing here reads with a timeout.
//!
//! One more consequence of running a minute of daemon time in milliseconds: the
//! kernel's own timers are real. The daemon's sockets do not set TCP_NODELAY,
//! so a small write (a ping) waits for the ACK of the write before it, and a
//! client kernel delays that ACK by about 40 ms of *real* time, which is longer
//! than the whole test. `Device::elapse` therefore asks the client kernel for
//! its pending ACK at the end of every step (`TCP_QUICKACK`), so a ping goes
//! out, and arrives, in the step in which the daemon sent it. (The client's own
//! socket has TCP_NODELAY, for the same reason in the other direction.)
//!
//! The Unix and TCP transports have no heartbeat (they are local): not
//! covered here.

use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic};
use nostromo::ipc::ws::WsLimits;
use nostromo::mother::MotherJob;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf, ReadHalf, WriteHalf};
use tokio::net::TcpStream;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// How finely the clock is advanced: events are timestamped to this.
const STEP: Duration = Duration::from_secs(1);

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

// ── the JSON handshake, with the WebSocket library ────────────────────────────

async fn open_ws(rig: &Rig, token: Option<&str>) -> Ws {
    let mut req = format!("ws://127.0.0.1:{}/", rig.ws_port)
        .into_client_request()
        .expect("a request");
    if let Some(token) = token {
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
    }
    let (ws, _) = connect_async(req).await.expect("the upgrade completes");
    ws
}

async fn say(ws: &mut Ws, msg: &ClientMsg) {
    ws.send(Message::Text(serde_json::to_string(msg).unwrap()))
        .await
        .expect("send a frame");
}

async fn read_until(ws: &mut Ws, what: &str, is: impl Fn(&ServerMsg) -> bool) {
    loop {
        match tokio::time::timeout(READ_TIMEOUT, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                let msg: ServerMsg = serde_json::from_str(&text)
                    .unwrap_or_else(|e| panic!("an undecodable frame ({e}): {text}"));
                if is(&msg) {
                    return;
                }
            }
            Ok(Some(Ok(_))) => continue,
            other => panic!("waiting for {what}: {other:?}"),
        }
    }
}

/// Hello, Welcome, Subscribe, and one answered `Ping`: the socket is attached
/// and idle.
async fn authenticate(ws: &mut Ws, topics: Vec<Topic>) {
    say(ws, &Conn::hello(&[], false)).await;
    read_until(ws, "the Welcome", |m| {
        matches!(m, ServerMsg::Welcome { .. })
    })
    .await;
    say(ws, &Conn::subscribe(topics)).await;
    say(ws, &ClientMsg::Ping).await;
    read_until(ws, "the Pong", |m| matches!(m, ServerMsg::Pong)).await;
}

// ── the raw client ────────────────────────────────────────────────────────────

/// The WebSocket library's socket, read and written as plain bytes: the
/// library is used for the HTTP upgrade and the JSON handshake and then left
/// out of it (it would answer every ping it reads on its own).
struct Raw(Ws);

impl AsyncRead for Raw {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(self.get_mut().0.get_mut()).poll_read(cx, buf)
    }
}

impl AsyncWrite for Raw {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(self.get_mut().0.get_mut()).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(self.get_mut().0.get_mut()).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(self.get_mut().0.get_mut()).poll_shutdown(cx)
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Seen {
    Ping,
    Pong,
    Text(String),
    Close(Option<u16>),
    /// The server closed the TCP connection.
    Eof,
}

type Events = Arc<Mutex<Vec<(Duration, Seen)>>>;

/// What the raw client does with the frames it is sent.
#[derive(Clone, Copy)]
enum Reading {
    /// Read every frame, answer none of them.
    Silently,
    /// Read every frame and answer each ping with a pong at once.
    AnsweringPings,
    /// Never read: the frames pile up in the kernel's buffers.
    Never,
}

struct Device {
    /// The client socket, for `quickack`.
    fd: std::os::fd::RawFd,
    writer: Arc<tokio::sync::Mutex<WriteHalf<Raw>>>,
    events: Events,
    reader: Option<JoinHandle<()>>,
    /// Held so the connection stays open when nobody reads.
    _unread: Option<ReadHalf<Raw>>,
}

impl Drop for Device {
    fn drop(&mut self) {
        if let Some(reader) = &self.reader {
            reader.abort();
        }
    }
}

/// One frame the server wrote: its opcode and payload. (Server frames are not
/// masked; the ones here are text, ping, pong and close.)
async fn read_frame_raw(rd: &mut ReadHalf<Raw>) -> Option<(u8, Vec<u8>)> {
    let mut head = [0u8; 2];
    rd.read_exact(&mut head).await.ok()?;
    let opcode = head[0] & 0x0f;
    let mut len = u64::from(head[1] & 0x7f);
    if len == 126 {
        let mut b = [0u8; 2];
        rd.read_exact(&mut b).await.ok()?;
        len = u64::from(u16::from_be_bytes(b));
    } else if len == 127 {
        let mut b = [0u8; 8];
        rd.read_exact(&mut b).await.ok()?;
        len = u64::from_be_bytes(b);
    }
    let mut payload = vec![0u8; usize::try_from(len).ok()?];
    rd.read_exact(&mut payload).await.ok()?;
    Some((opcode, payload))
}

/// One client frame. The mask key is four zero bytes (any key is allowed, and
/// masking with zeros leaves the payload as it is).
async fn write_frame_raw(
    writer: &tokio::sync::Mutex<WriteHalf<Raw>>,
    opcode: u8,
    payload: &[u8],
) -> std::io::Result<()> {
    assert!(payload.len() < 126, "short frames only");
    let mut frame = vec![0x80 | opcode, 0x80 | payload.len() as u8, 0, 0, 0, 0];
    frame.extend_from_slice(payload);
    writer.lock().await.write_all(&frame).await
}

impl Device {
    /// Take the socket over as bytes (nothing is buffered in the library: the
    /// handshake has read the last frame the server wrote) and read it raw.
    fn take_over(ws: Ws, reading: Reading) -> Device {
        // From here the clock moves only when `Device::elapse` moves it.
        tokio::time::pause();
        let fd = match ws.get_ref() {
            MaybeTlsStream::Plain(tcp) => {
                // The client's own small writes (a pong, a text frame) must not
                // wait for the daemon's kernel to ACK the one before.
                tcp.set_nodelay(true).expect("TCP_NODELAY");
                std::os::fd::AsRawFd::as_raw_fd(tcp)
            }
            _ => panic!("a plain TCP socket"),
        };
        let (rd, wr) = tokio::io::split(Raw(ws));
        let writer = Arc::new(tokio::sync::Mutex::new(wr));
        let events: Events = Arc::new(Mutex::new(Vec::new()));
        if matches!(reading, Reading::Never) {
            return Device {
                fd,
                writer,
                events,
                reader: None,
                _unread: Some(rd),
            };
        }
        let start = Instant::now();
        let reader = tokio::spawn({
            let (writer, events) = (Arc::clone(&writer), Arc::clone(&events));
            async move {
                let mut rd = rd;
                let note = |seen: Seen| events.lock().unwrap().push((start.elapsed(), seen));
                while let Some((opcode, payload)) = read_frame_raw(&mut rd).await {
                    match opcode {
                        0x9 => {
                            note(Seen::Ping);
                            if matches!(reading, Reading::AnsweringPings) {
                                let _ = write_frame_raw(&writer, 0xA, &payload).await;
                            }
                        }
                        0xA => note(Seen::Pong),
                        0x1 => note(Seen::Text(String::from_utf8_lossy(&payload).into_owned())),
                        0x8 => note(Seen::Close(
                            payload.get(..2).map(|b| u16::from_be_bytes([b[0], b[1]])),
                        )),
                        _ => {}
                    }
                }
                note(Seen::Eof);
            }
        });
        Device {
            fd,
            writer,
            events,
            reader: Some(reader),
            _unread: None,
        }
    }

    /// Send the ACK the client kernel is holding back (Linux; see the module
    /// comment). Harmless on a closed socket.
    fn quickack(&self) {
        #[cfg(target_os = "linux")]
        {
            let one: libc::c_int = 1;
            // SAFETY: a plain setsockopt on a descriptor this struct's halves
            // keep open, with a pointer to a live c_int of the size passed.
            unsafe {
                libc::setsockopt(
                    self.fd,
                    libc::IPPROTO_TCP,
                    libc::TCP_QUICKACK,
                    std::ptr::addr_of!(one).cast(),
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
            }
        }
        #[cfg(not(target_os = "linux"))]
        let _ = self.fd;
    }

    /// Let `total` pass, a step at a time. The runtime is never idle while
    /// this runs (the test task keeps yielding), so the clock moves only by
    /// what is advanced here, and every task, timer and loopback event gets its
    /// turns before the next step.
    async fn elapse(&self, total: Duration) {
        let mut left = total;
        while !left.is_zero() {
            let this = left.min(STEP);
            tokio::time::advance(this).await;
            for _ in 0..50 {
                tokio::task::yield_now().await;
            }
            self.quickack();
            for _ in 0..50 {
                tokio::task::yield_now().await;
            }
            left -= this;
        }
    }

    /// A pong nobody asked for, or the answer to a ping, sent now.
    async fn pong(&self) {
        let _ = write_frame_raw(&self.writer, 0xA, &[]).await;
    }

    /// A text frame (the socket may be closed by now; that is not an error).
    async fn text(&self, msg: &ClientMsg) {
        let _ = write_frame_raw(
            &self.writer,
            0x1,
            serde_json::to_string(msg).unwrap().as_bytes(),
        )
        .await;
    }

    fn events(&self) -> Vec<(Duration, Seen)> {
        self.events.lock().unwrap().clone()
    }

    /// When each ping arrived.
    fn pings(&self) -> Vec<Duration> {
        self.events()
            .into_iter()
            .filter(|(_, s)| *s == Seen::Ping)
            .map(|(at, _)| at)
            .collect()
    }

    /// When the close frame arrived, and its code.
    fn close(&self) -> Option<(Duration, Option<u16>)> {
        self.events().into_iter().find_map(|(at, s)| match s {
            Seen::Close(code) => Some((at, code)),
            _ => None,
        })
    }

    fn texts(&self) -> Vec<String> {
        self.events()
            .into_iter()
            .filter_map(|(_, s)| match s {
                Seen::Text(t) => Some(t),
                _ => None,
            })
            .collect()
    }
}

fn close_to(at: Duration, expected: Duration) -> bool {
    at.abs_diff(expected) <= STEP
}

async fn attached_device(rig: &Rig, reading: Reading) -> (Minted, Device) {
    let phone = rig.mint_device("phone");
    let mut ws = open_ws(rig, Some(&phone.token)).await;
    authenticate(&mut ws, vec![Topic::MotherJobs]).await;
    (phone, Device::take_over(ws, reading))
}

fn limits(ping_every: Duration, pong_timeout: Duration) -> WsLimits {
    WsLimits {
        ping_every,
        pong_timeout,
        ..Default::default()
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// The defaults, as documented: a ping every 20 s, closed with 1001 once 60 s
/// have passed without a pong.
#[tokio::test]
async fn a_device_that_swallows_pings_is_pinged_every_20s_and_closed_with_1001_by_60s() {
    let rig = Rig::new().await;
    let (phone, device) = attached_device(&rig, Reading::Silently).await;

    device.elapse(secs(55)).await;
    assert!(
        rig.hub.is_connected(&phone.device_id),
        "still connected before the timeout"
    );
    assert!(device.close().is_none());

    device.elapse(secs(30)).await;
    let pings = device.pings();
    assert!(
        (2..=3).contains(&pings.len()),
        "pings every 20 s until the close (at 20 s, at 40 s, and at most one more): {pings:?}"
    );
    assert!(close_to(pings[0], secs(20)), "first ping at {:?}", pings[0]);
    assert!(
        close_to(pings[1], secs(40)),
        "second ping at {:?}",
        pings[1]
    );

    let (at, code) = device.close().expect("the server closed the socket");
    assert_eq!(code, Some(1001), "going away");
    assert!(
        at + STEP >= secs(60) && at <= secs(60) + secs(20),
        "closed at {at:?}: after the 60 s without a pong, and no later than the next check"
    );
    assert!(
        !rig.hub.is_connected(&phone.device_id),
        "and the daemon let go of the device's slot"
    );
}

/// The two knobs are the ones the daemon honours (the defaults are not
/// hard-wired).
#[tokio::test]
async fn the_ping_interval_and_the_pong_timeout_are_the_configured_ones() {
    let rig = Rig::with_limits(limits(secs(2), secs(7))).await;
    let (phone, device) = attached_device(&rig, Reading::Silently).await;

    device.elapse(secs(6)).await;
    assert!(rig.hub.is_connected(&phone.device_id));
    assert!(device.close().is_none(), "not before the timeout");
    device.elapse(secs(6)).await;

    let pings = device.pings();
    assert!(
        (3..=4).contains(&pings.len()),
        "pings at 2, 4 and 6 s, and at most one more: {pings:?}"
    );
    for (ping, expected) in pings.iter().zip([2, 4, 6]) {
        assert!(close_to(*ping, secs(expected)), "{pings:?}");
    }
    let (at, code) = device.close().expect("closed");
    assert_eq!(code, Some(1001));
    assert!(
        at + STEP >= secs(7) && at <= secs(7) + secs(2),
        "closed at {at:?}"
    );
    assert!(!rig.hub.is_connected(&phone.device_id));
}

#[tokio::test]
async fn a_device_that_answers_its_pings_stays_connected_far_past_the_pong_timeout() {
    let rig = Rig::new().await;
    let (phone, device) = attached_device(&rig, Reading::AnsweringPings).await;

    // Five times the 60 s timeout.
    device.elapse(secs(300)).await;
    assert!(
        rig.hub.is_connected(&phone.device_id),
        "an answering device is never timed out"
    );
    assert!(device.close().is_none(), "{:?}", device.events());
    let pings = device.pings();
    assert!(
        pings.len() >= 14,
        "the pings kept coming, every 20 s: {pings:?}"
    );
    for pair in pings.windows(2) {
        assert!(
            close_to(pair[1] - pair[0], secs(20)),
            "the cadence holds: {pings:?}"
        );
    }

    // And it is really alive, not just unclosed.
    device.text(&ClientMsg::Ping).await;
    device.elapse(secs(1)).await;
    assert!(
        device.texts().iter().any(|t| t.contains("\"pong\"")),
        "the daemon still answers: {:?}",
        device.texts()
    );
}

/// Only a pong is a sign of life: a peer that keeps sending its own frames
/// (and is answered) but never pongs is closed all the same.
#[tokio::test]
async fn a_device_that_writes_text_frames_but_never_pongs_is_still_closed() {
    let rig = Rig::new().await;
    let (phone, device) = attached_device(&rig, Reading::Silently).await;

    for _ in 0..14 {
        device.text(&ClientMsg::Ping).await;
        device.elapse(secs(5)).await;
    }
    device.elapse(secs(15)).await;

    let answers = device
        .texts()
        .iter()
        .filter(|t| t.contains("\"pong\""))
        .count();
    assert!(
        answers >= 10,
        "the daemon was answering its text frames the whole time ({answers})"
    );
    let (at, code) = device.close().expect("closed");
    assert_eq!(code, Some(1001));
    assert!(
        at + STEP >= secs(60) && at <= secs(80),
        "closed at {at:?}, in spite of the traffic"
    );
    assert!(!rig.hub.is_connected(&phone.device_id));
}

/// The timeout runs from the last pong, not from the connection: a pong at
/// 50 s buys another 60.
#[tokio::test]
async fn a_pong_pushes_the_deadline_out_to_pong_timeout_after_it() {
    let rig = Rig::new().await;
    let (phone, device) = attached_device(&rig, Reading::Silently).await;

    device.elapse(secs(50)).await;
    device.pong().await;
    device.elapse(secs(55)).await; // 105 s
    assert!(
        rig.hub.is_connected(&phone.device_id),
        "105 s in, 55 s after its last pong: still inside the timeout"
    );
    assert!(device.close().is_none(), "{:?}", device.events());

    device.elapse(secs(35)).await; // 140 s
    let (at, code) = device.close().expect("closed once the new deadline passed");
    assert_eq!(code, Some(1001));
    assert!(
        at + STEP >= secs(110) && at <= secs(50) + secs(60) + secs(20),
        "closed at {at:?}: 60 s after the pong at 50 s, at the next check"
    );
    assert!(
        device.pings().len() >= 5,
        "and it was pinged all along: {:?}",
        device.pings()
    );
}

/// A pairing-only socket (no token) has none of this: no pings, and the
/// lifetime it had before: closed with 1000 when its 60 s pairing window ends.
#[tokio::test]
async fn a_pairing_only_socket_is_never_pinged_and_keeps_its_own_lifetime() {
    let rig = Rig::new().await;
    let mut ws = open_ws(&rig, None).await;
    say(&mut ws, &Conn::hello(&[], false)).await;
    read_until(&mut ws, "the Welcome", |m| {
        matches!(m, ServerMsg::Welcome { .. })
    })
    .await;
    let device = Device::take_over(ws, Reading::Silently);

    device.elapse(secs(75)).await;
    assert!(
        device.pings().is_empty(),
        "a pairing socket is not pinged: {:?}",
        device.events()
    );
    let (at, code) = device.close().expect("the pairing window ended");
    assert_eq!(
        code,
        Some(1000),
        "closed as it always was, not as a dead peer"
    );
    assert!(close_to(at, secs(60)), "at {at:?}");
}

/// The control for the next test: the same device that reads nothing, with
/// nothing to send it but pings, is dropped on time.
#[tokio::test]
async fn a_device_that_reads_nothing_is_dropped_within_the_pong_timeout_when_the_daemon_has_little_to_send(
) {
    let rig = Rig::with_limits(limits(secs(1), secs(3))).await;
    let (phone, device) = attached_device(&rig, Reading::Never).await;

    device.elapse(secs(10)).await;
    assert!(
        !rig.hub.is_connected(&phone.device_id),
        "10 s after the device went quiet (timeout 3 s) the daemon still holds its socket"
    );
}

/// The heartbeat is for the case it exists for: a phone that vanished (no
/// close, no pong). When the daemon has plenty to send, the write that cannot
/// complete must not keep the socket, and its queue, for ever.
///
/// Beyond the stated criteria. The device here connects, then reads nothing at
/// all while the daemon publishes 25 MiB: the socket's buffers fill, the
/// daemon's write to it waits for room. Within the pong timeout (3 s here) the
/// daemon must drop it all the same.
#[tokio::test]
async fn a_device_that_stopped_reading_while_the_daemon_keeps_publishing_is_still_dropped() {
    let rig = Rig::with_limits(limits(secs(1), secs(3))).await;
    let (phone, device) = attached_device(&rig, Reading::Never).await;

    let big = |i: usize| ServerMsg::MotherJobs {
        jobs: vec![MotherJob {
            id: format!("job-{i}"),
            state: "running".into(),
            title: "x".repeat(64 * 1024),
            ..Default::default()
        }],
        host: None,
    };
    // Fifty frames at a time, so the daemon's tasks keep up with the producer.
    for batch in 0..8 {
        for i in 0..50 {
            rig.server.broadcast(big(batch * 50 + i));
        }
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
    }
    assert!(
        rig.hub.is_connected(&phone.device_id),
        "still attached: the timeout has not passed"
    );

    device.elapse(secs(10)).await;
    assert!(
        !rig.hub.is_connected(&phone.device_id),
        "10 s after the device went quiet (timeout 3 s) the daemon still holds its socket"
    );
}
