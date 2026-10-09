//! Who is on the other end of an IPC connection, and what they may see.
//!
//! `nostromd` serves the Mac app over a Unix socket and iOS/LAN clients over an
//! **unauthenticated** TCP listener. The server tags every connection with its
//! [`Transport`] and derives a [`PeerTrust`]; Teri/Fred data (mail subjects and
//! senders, todos, work items) is *sensitive* and is withheld from network
//! peers, and sensitive requests from network peers are refused.
//!
//! The classification functions below are deliberately exhaustive `match`es
//! with no wildcard arm: adding a `ServerMsg` or `ClientMsg` variant breaks
//! this module's build until the author decides whether it is sensitive.

use super::protocol::{ClientMsg, FocusMeta, ServerMsg, Topic};

/// Wire transport a connection arrived on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Unix,
    Tcp,
}

/// How far a peer is trusted.
///
/// `OperatorApp` is reserved for a verified Nostromo Mac app (terminal-pane
/// 1a adds the bundle verifier); nothing here assigns it yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerTrust {
    /// A Unix-socket peer verified to be the Nostromo app. Not yet assigned.
    OperatorApp,
    /// Any other local (Unix-socket) peer.
    LocalOther,
    /// A TCP peer: unauthenticated, possibly anywhere on the LAN.
    Tcp,
}

impl PeerTrust {
    pub fn from_transport(transport: Transport) -> Self {
        match transport {
            Transport::Unix => PeerTrust::LocalOther,
            Transport::Tcp => PeerTrust::Tcp,
        }
    }

    /// True for peers reached over the network.
    pub fn is_network(&self) -> bool {
        match self {
            PeerTrust::Tcp => true,
            PeerTrust::OperatorApp | PeerTrust::LocalOther => false,
        }
    }
}

/// Whether a message carries Teri/Fred data (or requests it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitiveClass {
    Sensitive,
    NotSensitive,
}

impl SensitiveClass {
    pub fn is_sensitive(self) -> bool {
        self == SensitiveClass::Sensitive
    }
}

/// Classify a daemon-to-client message.
pub fn is_sensitive_server_msg(msg: &ServerMsg) -> SensitiveClass {
    use SensitiveClass::{NotSensitive, Sensitive};
    match msg {
        ServerMsg::TeriState { .. }
        | ServerMsg::FredState { .. }
        | ServerMsg::WorkSourceStatus { .. }
        | ServerMsg::WorkSnapshot { .. }
        | ServerMsg::TeriPicks { .. }
        | ServerMsg::WorkDetail { .. }
        | ServerMsg::WorkSendPreview { .. }
        | ServerMsg::WorkSendResult { .. } => Sensitive,

        ServerMsg::Welcome { .. }
        | ServerMsg::Activity(_)
        | ServerMsg::MotherJobs { .. }
        | ServerMsg::MotherStatusline(_)
        | ServerMsg::MotherAwaitDetected(_)
        | ServerMsg::PerriState { .. }
        | ServerMsg::Pong
        | ServerMsg::Error { .. }
        | ServerMsg::PtySpawned { .. }
        | ServerMsg::PtyOutput { .. }
        | ServerMsg::PtyExited { .. }
        | ServerMsg::PtyScrollback { .. }
        | ServerMsg::PtyAttached { .. }
        | ServerMsg::PtyDetach { .. }
        | ServerMsg::PtyListResp { .. }
        | ServerMsg::PtyIdentity { .. }
        | ServerMsg::SessionSpawned { .. }
        | ServerMsg::SessionTurns { .. }
        | ServerMsg::SessionTurnDelta { .. }
        | ServerMsg::SessionState { .. }
        | ServerMsg::SessionPermissionRequest { .. }
        | ServerMsg::SessionExited { .. }
        | ServerMsg::SessionDown { .. }
        | ServerMsg::SessionListResp { .. }
        | ServerMsg::SessionSummaryUpdate { .. }
        | ServerMsg::FocusListResp { .. }
        | ServerMsg::FocusRegistryUpdated { .. }
        | ServerMsg::MotherPeek { .. }
        | ServerMsg::FocusLayout { .. }
        | ServerMsg::PaneContent { .. }
        | ServerMsg::FocusCreated { .. }
        | ServerMsg::DecisionRequest { .. }
        | ServerMsg::DecisionResolved { .. }
        | ServerMsg::Notification { .. }
        | ServerMsg::ActivitySnapshot { .. }
        | ServerMsg::ActivityHealth { .. }
        | ServerMsg::Withheld { .. }
        | ServerMsg::DaemonReconnected => NotSensitive,
    }
}

/// Classify a client-to-daemon message. `true` means a network peer must be
/// refused with `requires_secure_connection`.
pub fn is_sensitive_client_msg(msg: &ClientMsg) -> bool {
    match msg {
        ClientMsg::WorkDetailRequest { .. }
        | ClientMsg::WorkRefresh { .. }
        | ClientMsg::PicksRefresh { .. }
        | ClientMsg::WorkSendPreviewRequest { .. }
        | ClientMsg::WorkSend { .. }
        | ClientMsg::FredSeed { .. } => true,

        ClientMsg::Hello { .. }
        | ClientMsg::Subscribe { .. }
        | ClientMsg::Ping
        | ClientMsg::PtySpawn { .. }
        | ClientMsg::PtyAttach { .. }
        | ClientMsg::PtyDetach { .. }
        | ClientMsg::PtyInput { .. }
        | ClientMsg::PtyResize { .. }
        | ClientMsg::PtyKill { .. }
        | ClientMsg::PtyList
        | ClientMsg::SessionSpawn { .. }
        | ClientMsg::SessionAttach { .. }
        | ClientMsg::SessionDetach { .. }
        | ClientMsg::SessionSend { .. }
        | ClientMsg::ClosePane { .. }
        | ClientMsg::SessionInterrupt { .. }
        | ClientMsg::SessionControl { .. }
        | ClientMsg::SessionAnswerPermission { .. }
        | ClientMsg::SessionList
        | ClientMsg::FocusRegistryPush { .. }
        | ClientMsg::FocusList
        | ClientMsg::MotherAction { .. }
        | ClientMsg::MotherResume { .. }
        | ClientMsg::PerriAction { .. }
        | ClientMsg::DecisionAnswer { .. }
        | ClientMsg::ActivitySnapshotRequest { .. }
        | ClientMsg::RenderedShape { .. } => false,
    }
}

/// May `msg` be written to a peer of this trust on the **broadcast** path?
///
/// A network peer never receives a sensitive broadcast, whatever topics it
/// subscribed to (an empty list means "everything", which must not include
/// Teri/Fred data). This runs before topic matching.
pub fn may_receive_broadcast(trust: PeerTrust, msg: &ServerMsg) -> bool {
    !(trust.is_network() && is_sensitive_server_msg(msg).is_sensitive())
}

/// Strip fields a network peer must not see from an otherwise-deliverable
/// frame. `FocusMeta::project_path` is an absolute filesystem path; the
/// `FocusMeta` contract promises none reach mobile, so it is dropped here.
pub fn redact_for_network(msg: ServerMsg) -> ServerMsg {
    fn strip(metas: &mut [FocusMeta]) {
        for m in metas {
            m.project_path = None;
        }
    }
    match msg {
        ServerMsg::FocusListResp { mut focuses } => {
            strip(&mut focuses);
            ServerMsg::FocusListResp { focuses }
        }
        ServerMsg::FocusRegistryUpdated { mut focuses } => {
            strip(&mut focuses);
            ServerMsg::FocusRegistryUpdated { focuses }
        }
        ServerMsg::FocusCreated { mut meta } => {
            meta.project_path = None;
            ServerMsg::FocusCreated { meta }
        }
        other => other,
    }
}

/// The topics withheld from network peers, as announced in `Withheld`.
pub fn withheld_topics() -> Vec<Topic> {
    vec![Topic::Fred, Topic::Teri, Topic::Work]
}

/// The `Withheld` notice sent once to a network peer after it subscribes.
pub fn withheld_msg() -> ServerMsg {
    ServerMsg::Withheld {
        topics: withheld_topics(),
        reason: "requires_secure_connection".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::work::{
        PicksSnapshot, SourceState, SourceStatus, WorkResult, WorkSource,
    };

    #[test]
    fn unix_peers_are_local_and_tcp_peers_are_network() {
        assert_eq!(PeerTrust::from_transport(Transport::Unix), PeerTrust::LocalOther);
        assert_eq!(PeerTrust::from_transport(Transport::Tcp), PeerTrust::Tcp);
        assert!(!PeerTrust::LocalOther.is_network());
        assert!(!PeerTrust::OperatorApp.is_network());
        assert!(PeerTrust::Tcp.is_network());
    }

    #[test]
    fn teri_fred_and_work_broadcasts_are_sensitive() {
        let status = SourceStatus {
            source: WorkSource::Jira,
            state: SourceState::Fresh,
            updated_at: None,
            reason: None,
            retry_at: None,
            count: 0,
            group_errors: vec![],
        };
        let sensitive = [
            ServerMsg::TeriState { todos: Default::default() },
            ServerMsg::FredState { mailbox: Default::default(), calendar: Default::default() },
            ServerMsg::WorkSourceStatus { status },
            ServerMsg::WorkSnapshot { source: WorkSource::Todos, group: None, items: vec![] },
            ServerMsg::TeriPicks { picks: PicksSnapshot::default() },
            ServerMsg::WorkDetail { request_id: "r".into(), result: WorkResult::err("x", "y") },
            ServerMsg::WorkSendPreview { request_id: "r".into(), result: WorkResult::err("x", "y") },
            ServerMsg::WorkSendResult { request_id: "r".into(), result: WorkResult::err("x", "y") },
        ];
        for msg in &sensitive {
            assert!(is_sensitive_server_msg(msg).is_sensitive(), "{msg:?}");
            assert!(!may_receive_broadcast(PeerTrust::Tcp, msg), "{msg:?}");
            assert!(may_receive_broadcast(PeerTrust::LocalOther, msg), "{msg:?}");
        }
    }

    #[test]
    fn non_sensitive_broadcasts_still_reach_network_peers() {
        let msg = ServerMsg::FocusRegistryUpdated { focuses: vec![] };
        assert!(!is_sensitive_server_msg(&msg).is_sensitive());
        assert!(may_receive_broadcast(PeerTrust::Tcp, &msg));
        assert!(may_receive_broadcast(PeerTrust::Tcp, &withheld_msg()));
    }

    #[test]
    fn the_new_client_requests_are_all_sensitive() {
        let sensitive = [
            ClientMsg::WorkDetailRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkRefresh { source: None, fred: false },
            ClientMsg::PicksRefresh { reason: "manual".into() },
            ClientMsg::WorkSendPreviewRequest { request_id: "r".into(), item_id: "i".into() },
            ClientMsg::WorkSend {
                request_id: "r".into(),
                item_id: "i".into(),
                destination: "focus".into(),
                agent: "cody".into(),
                working_directory: None,
                label: "l".into(),
                context: "c".into(),
                allow_duplicate: false,
            },
            ClientMsg::FredSeed { request_id: "r".into(), text: "t".into() },
        ];
        for msg in &sensitive {
            assert!(is_sensitive_client_msg(msg), "{msg:?}");
        }
        assert!(!is_sensitive_client_msg(&ClientMsg::Ping));
        assert!(!is_sensitive_client_msg(&ClientMsg::SessionList));
    }

    #[test]
    fn withheld_names_fred_teri_and_work() {
        match withheld_msg() {
            ServerMsg::Withheld { topics, reason } => {
                assert_eq!(topics, vec![Topic::Fred, Topic::Teri, Topic::Work]);
                assert_eq!(reason, "requires_secure_connection");
            }
            other => panic!("expected Withheld, got {other:?}"),
        }
    }
    #[test]
    fn network_peers_never_see_a_focus_project_path() {
        let meta = FocusMeta {
            tag: "t".into(),
            display_name: "T".into(),
            agent_name: "cody".into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: None,
            label: Some("L".into()),
            project_path: Some("/Users/x/repo".into()),
            select_for_client: None,
        };
        for msg in [
            ServerMsg::FocusCreated { meta: meta.clone() },
            ServerMsg::FocusRegistryUpdated { focuses: vec![meta.clone()] },
            ServerMsg::FocusListResp { focuses: vec![meta.clone()] },
        ] {
            let json = serde_json::to_string(&redact_for_network(msg)).unwrap();
            assert!(!json.contains("/Users/x/repo"), "path leaked: {json}");
            // The label is withheld from network peers too (it can be a Jira
            // key or doc title); an ordinary focus's identity is kept.
            assert!(!json.contains("\"label\""), "label leaked: {json}");
            assert!(json.contains("\"tag\":\"t\""), "other fields kept: {json}");
        }
    }
}
