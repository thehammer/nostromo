//! Who may touch a terminal.
//!
//! [`OperatorCap`] is the proof that a request came from the verified Mac app
//! (AP1's [`PeerTrust::OperatorApp`]). Every `TerminalManager` method that
//! writes input, resizes, attaches (reads output), closes or restarts takes
//! one, and the only way to get one is [`mint`], which `src/ipc/server.rs`
//! calls once per connection after `Hello`. The MCP side never holds a
//! `PeerTrust`, so it can never obtain a cap.

use crate::ipc::peer::PeerTrust;

/// Zero-sized proof of an operator-app connection. Its field is private, so
/// it can only be built by [`mint`].
#[derive(Debug)]
pub struct OperatorCap {
    _private: (),
}

/// A cap for a connection of this trust: `Some` only for the verified app.
pub(crate) fn mint(trust: PeerTrust) -> Option<OperatorCap> {
    match trust {
        PeerTrust::OperatorApp => Some(OperatorCap { _private: () }),
        PeerTrust::LocalOther | PeerTrust::Tcp => None,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::{mint, OperatorCap};
    use crate::ipc::peer::PeerTrust;

    /// A cap for crate tests that drive a `TerminalManager` directly (the
    /// verified-peer path itself is covered over real sockets).
    pub(crate) fn cap() -> OperatorCap {
        mint(PeerTrust::OperatorApp).expect("the operator app gets a cap")
    }

    #[test]
    fn the_operator_app_gets_a_cap() {
        assert!(mint(PeerTrust::OperatorApp).is_some());
    }

    #[test]
    fn another_local_process_gets_no_cap() {
        assert!(mint(PeerTrust::LocalOther).is_none());
    }

    #[test]
    fn a_tcp_peer_gets_no_cap() {
        assert!(mint(PeerTrust::Tcp).is_none());
    }
}
