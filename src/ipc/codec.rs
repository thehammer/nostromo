//! Length-prefixed JSON frame codec.
//!
//! Wire format: `[4 bytes big-endian u32 length][JSON body]`
//!
//! Maximum frame body is [`crate::ipc::protocol::MAX_FRAME_LEN`] (4 MiB).

use anyhow::{bail, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use super::protocol::MAX_FRAME_LEN;

/// Read one length-prefixed frame from `r`.
///
/// Returns the raw JSON bytes or an error if the frame is oversized or the
/// stream ended prematurely.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;

    if len > MAX_FRAME_LEN {
        bail!("frame too large: {len} bytes (max {MAX_FRAME_LEN})");
    }

    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    Ok(body)
}

/// Write one length-prefixed frame to `w`.
pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> Result<()> {
    if body.len() > MAX_FRAME_LEN {
        bail!("frame too large: {} bytes (max {MAX_FRAME_LEN})", body.len());
    }
    let len = (body.len() as u32).to_be_bytes();
    w.write_all(&len).await?;
    w.write_all(body).await?;
    w.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip_single_frame() {
        let payload = b"hello world";
        let (mut reader, mut writer) = tokio::io::duplex(64);
        write_frame(&mut writer, payload).await.unwrap();
        drop(writer);
        let received = read_frame(&mut reader).await.unwrap();
        assert_eq!(received, payload);
    }

    #[tokio::test]
    async fn round_trip_multiple_frames() {
        let frames: &[&[u8]] = &[b"frame1", b"frame2", b"{\"key\":\"value\"}"];
        let (mut reader, mut writer) = tokio::io::duplex(256);
        for f in frames {
            write_frame(&mut writer, f).await.unwrap();
        }
        drop(writer);
        for expected in frames {
            let got = read_frame(&mut reader).await.unwrap();
            assert_eq!(&got, expected);
        }
    }

    #[tokio::test]
    async fn rejects_oversized_frame() {
        // Manually write a header claiming MAX_FRAME_LEN + 1 bytes.
        let (mut reader, mut writer) = tokio::io::duplex(64);
        let bad_len = ((MAX_FRAME_LEN + 1) as u32).to_be_bytes();
        writer.write_all(&bad_len).await.unwrap();
        drop(writer);
        let result = read_frame(&mut reader).await;
        assert!(result.is_err(), "should reject oversized frame");
    }

    #[tokio::test]
    async fn write_rejects_oversized_payload() {
        let big = vec![0u8; MAX_FRAME_LEN + 1];
        let (_, mut writer) = tokio::io::duplex(64);
        let result = write_frame(&mut writer, &big).await;
        assert!(result.is_err(), "should reject oversized write");
    }
}
