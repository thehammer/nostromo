//! The framing on a satellite's uplink socket.
//!
//! A satellite's WebSocket carries both its own verbs (`ClientMsg`) and the
//! frames it publishes (`ServerMsg`), and the primary sends back both what its
//! handler writes and the reads it routes down. Both enums are internally
//! tagged on `type` in one namespace, so a bare frame could not say which one
//! it is, and letting the satellite pick the decoder would hand it a lever. A
//! tagged envelope, on the uplink socket only, makes the direction explicit.
//! Phones and iPads never see it.
//!
//! This is transport framing, not a `ClientMsg`: it adds no ordinal.

use serde::{Deserialize, Serialize};

use super::protocol::{ClientMsg, ServerMsg};

/// One frame on an uplink socket.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "uplink", rename_all = "snake_case")]
pub enum UplinkFrame {
    /// Satellite to primary: the satellite's own verb (`Hello`, `Subscribe`,
    /// `Ping`, a device-admin verb).
    Client { msg: ClientMsg },
    /// Satellite to primary: a broadcast it publishes.
    Publish { msg: ServerMsg },
    /// Satellite to primary: the answer to a routed request.
    Reply { id: String, msg: ServerMsg },
    /// Primary to satellite: anything the primary's handler writes.
    Server { msg: ServerMsg },
    /// Primary to satellite: a routed read.
    Request { id: String, msg: ClientMsg },
}

impl UplinkFrame {
    /// May a satellite send this frame? Only the first three tags.
    pub fn is_from_satellite(&self) -> bool {
        matches!(
            self,
            UplinkFrame::Client { .. } | UplinkFrame::Publish { .. } | UplinkFrame::Reply { .. }
        )
    }
}

/// Wrap an already-serialised `ServerMsg` as `server` without decoding it.
pub fn wrap_server_bytes(body: &str) -> String {
    format!(r#"{{"uplink":"server","msg":{body}}}"#)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_envelope_round_trips_and_names_its_direction() {
        let f = UplinkFrame::Client {
            msg: ClientMsg::Ping,
        };
        let json = serde_json::to_string(&f).unwrap();
        assert!(json.contains(r#""uplink":"client""#), "{json}");
        let back: UplinkFrame = serde_json::from_str(&json).unwrap();
        assert!(back.is_from_satellite());

        let down = UplinkFrame::Request {
            id: "x".into(),
            msg: ClientMsg::Ping,
        };
        assert!(!down.is_from_satellite());
        let down = UplinkFrame::Server {
            msg: ServerMsg::Pong,
        };
        assert!(!down.is_from_satellite());
    }

    #[test]
    fn a_bare_frame_is_not_an_envelope() {
        assert!(serde_json::from_str::<UplinkFrame>(r#"{"type":"pong"}"#).is_err());
        assert!(serde_json::from_str::<UplinkFrame>(r#"{"type":"ping"}"#).is_err());
    }

    #[test]
    fn wrapped_bytes_decode_as_a_server_frame() {
        let body = serde_json::to_string(&ServerMsg::Pong).unwrap();
        let wrapped = wrap_server_bytes(&body);
        match serde_json::from_str::<UplinkFrame>(&wrapped).unwrap() {
            UplinkFrame::Server { msg: ServerMsg::Pong } => {}
            other => panic!("{other:?}"),
        }
    }
}
