//! Integration tests for the IPC length-prefixed frame codec.
//!
//! Uses `tokio::io::duplex` for in-memory async I/O pairs — no real sockets
//! or file descriptors required.

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::protocol::{
    ClientMsg, ServerMsg, Topic, PROTOCOL_VERSION,
};
use tokio::io::AsyncWriteExt;

// ── Frame codec round-trips ───────────────────────────────────────────────────

#[tokio::test]
async fn codec_round_trip_empty_body() {
    let (mut reader, mut writer) = tokio::io::duplex(64);
    write_frame(&mut writer, b"").await.unwrap();
    drop(writer);
    let got = read_frame(&mut reader).await.unwrap();
    assert!(got.is_empty());
}

#[tokio::test]
async fn codec_round_trip_single_frame() {
    let payload = br#"{"hello":"world"}"#;
    let (mut reader, mut writer) = tokio::io::duplex(256);
    write_frame(&mut writer, payload).await.unwrap();
    drop(writer);
    let got = read_frame(&mut reader).await.unwrap();
    assert_eq!(got, payload);
}

#[tokio::test]
async fn codec_round_trip_multiple_frames() {
    let payloads: &[&[u8]] = &[b"frame1", b"frame2", b"frame3"];
    let (mut reader, mut writer) = tokio::io::duplex(512);
    for p in payloads {
        write_frame(&mut writer, p).await.unwrap();
    }
    drop(writer);
    for expected in payloads {
        let got = read_frame(&mut reader).await.unwrap();
        assert_eq!(&got, expected);
    }
}

#[tokio::test]
async fn codec_rejects_oversized_frame_read() {
    use nostromo::ipc::protocol::MAX_FRAME_LEN;
    let (mut reader, mut writer) = tokio::io::duplex(64);
    // Write a length header that claims more than MAX_FRAME_LEN bytes.
    let bad_len = ((MAX_FRAME_LEN + 1) as u32).to_be_bytes();
    writer.write_all(&bad_len).await.unwrap();
    drop(writer);
    let result = read_frame(&mut reader).await;
    assert!(result.is_err(), "expected error for oversized frame header");
}

// ── JSON message round-trips over codec ───────────────────────────────────────

#[tokio::test]
async fn codec_client_msg_hello_round_trip() {
    let msg = ClientMsg::Hello {
        client_id: "test-client".to_string(),
        protocol_version: PROTOCOL_VERSION,
    };
    let bytes = serde_json::to_vec(&msg).unwrap();
    let (mut reader, mut writer) = tokio::io::duplex(256);
    write_frame(&mut writer, &bytes).await.unwrap();
    drop(writer);
    let got_bytes = read_frame(&mut reader).await.unwrap();
    let got: ClientMsg = serde_json::from_slice(&got_bytes).unwrap();
    assert!(
        matches!(got, ClientMsg::Hello { protocol_version: v, .. } if v == PROTOCOL_VERSION)
    );
}

#[tokio::test]
async fn codec_client_msg_subscribe_round_trip() {
    let msg = ClientMsg::Subscribe {
        topics: vec![Topic::Activity, Topic::MotherJobs, Topic::MotherStatusline],
    };
    let bytes = serde_json::to_vec(&msg).unwrap();
    let (mut reader, mut writer) = tokio::io::duplex(256);
    write_frame(&mut writer, &bytes).await.unwrap();
    drop(writer);
    let got_bytes = read_frame(&mut reader).await.unwrap();
    let got: ClientMsg = serde_json::from_slice(&got_bytes).unwrap();
    assert!(matches!(got, ClientMsg::Subscribe { topics } if topics.len() == 3));
}

#[tokio::test]
async fn codec_server_msg_welcome_round_trip() {
    let msg = ServerMsg::Welcome {
        protocol_version: PROTOCOL_VERSION,
        daemon_pid: 12345,
    };
    let bytes = serde_json::to_vec(&msg).unwrap();
    let (mut reader, mut writer) = tokio::io::duplex(256);
    write_frame(&mut writer, &bytes).await.unwrap();
    drop(writer);
    let got_bytes = read_frame(&mut reader).await.unwrap();
    let got: ServerMsg = serde_json::from_slice(&got_bytes).unwrap();
    assert!(
        matches!(got, ServerMsg::Welcome { daemon_pid: 12345, .. })
    );
}

#[tokio::test]
async fn codec_server_msg_pong_round_trip() {
    let msg = ServerMsg::Pong;
    let bytes = serde_json::to_vec(&msg).unwrap();
    let (mut reader, mut writer) = tokio::io::duplex(256);
    write_frame(&mut writer, &bytes).await.unwrap();
    drop(writer);
    let got_bytes = read_frame(&mut reader).await.unwrap();
    let got: ServerMsg = serde_json::from_slice(&got_bytes).unwrap();
    assert!(matches!(got, ServerMsg::Pong));
}
