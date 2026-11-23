//! The primary daemon's in-memory table of open pairings.
//!
//! A pairing lives only in daemon memory. It is owned by the connection that
//! started it and reported back to that connection when it ends. Nothing here
//! touches a clock or a socket: every operation takes `now`, and outcomes go
//! to the issuer's targeted channel.

use std::time::{Duration, Instant};

use rand::Rng;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc::UnboundedSender;

use super::devices::{
    ct_eq, random_token, DeviceKind, PairOutcomeKind, PairRefusedReason, SatelliteAdmin,
};
use super::protocol::ServerMsg;

/// How long a code works.
pub const PAIRING_TTL: Duration = Duration::from_secs(5 * 60);
/// How long an expired code is remembered, so a late attempt hears `expired`.
const TOMBSTONE_TTL: Duration = Duration::from_secs(60 * 60);
/// Wrong attempts a pairing survives.
pub const MAX_WRONG_ATTEMPTS: u32 = 5;

struct Open {
    id: String,
    code_hash: [u8; 32],
    name_hint: Option<String>,
    kind: DeviceKind,
    admin: Option<SatelliteAdmin>,
    expires_at: Instant,
    /// The issuing connection's key.
    issuer: String,
    /// For one relayed by a satellite (W10): the satellite's own key.
    origin: Option<String>,
    outcome_tx: UnboundedSender<ServerMsg>,
    challenge: String,
    proof_answered: bool,
    matched_device: Option<String>,
    wrong: u32,
}

impl Open {
    fn finish(&self, outcome: PairOutcomeKind, paired: Option<(&str, DeviceKind, bool)>) {
        let (name, kind, replaced) = match paired {
            Some((n, k, r)) => (Some(n.to_string()), Some(k), r),
            None => (None, None, false),
        };
        let _ = self.outcome_tx.send(ServerMsg::DevicePairOutcome {
            pairing_id: self.id.clone(),
            outcome,
            name,
            kind,
            replaced,
        });
    }
}

/// What a `PairCheck` answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckAnswer {
    Offer {
        name_hint: Option<String>,
        challenge: String,
        /// Present only in the answer to the first proof on a code.
        knows_device: Option<bool>,
    },
    Refused(PairRefusedReason),
}

/// A pairing taken by a successful `Pair`; it has already left the table.
pub struct Taken {
    pairing: Open,
    pub kind: DeviceKind,
    pub admin: Option<SatelliteAdmin>,
    pub name_hint: Option<String>,
    /// The active record the phone proved it holds, for `replace: true`.
    pub matched_device: Option<String>,
}

impl Taken {
    /// Tell the issuer the device paired.
    pub fn notify_paired(&self, final_name: &str, replaced: bool) {
        self.pairing.finish(
            PairOutcomeKind::Paired,
            Some((final_name, self.kind, replaced)),
        );
    }
}

/// An open pairing's identity, for the reply to `DevicePairStart`.
#[derive(Debug, Clone)]
pub struct Started {
    pub pairing_id: String,
    /// Digits only (`123456`).
    pub code: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

pub struct PairingTable {
    ttl: Duration,
    open: Vec<Open>,
    tombstones: Vec<([u8; 32], Instant)>,
}

impl Default for PairingTable {
    fn default() -> Self {
        Self::new(PAIRING_TTL)
    }
}

fn hash_code(code: &str) -> [u8; 32] {
    Sha256::digest(normalize_code(code).as_bytes()).into()
}

/// Digits only: `123 456` is `123456`.
pub fn normalize_code(code: &str) -> String {
    code.chars().filter(|c| c.is_ascii_digit()).collect()
}

impl PairingTable {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            open: Vec::new(),
            tombstones: Vec::new(),
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn open_count(&self) -> usize {
        self.open.len()
    }

    /// Open a pairing owned by `issuer`. The code is six digits, distinct from
    /// every code open or remembered.
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        &mut self,
        issuer: &str,
        origin: Option<String>,
        outcome_tx: UnboundedSender<ServerMsg>,
        name_hint: Option<String>,
        kind: DeviceKind,
        admin: Option<SatelliteAdmin>,
        now: Instant,
    ) -> Started {
        self.prune(now);
        let mut rng = rand::thread_rng();
        let (code, code_hash) = loop {
            let code = format!("{:06}", rng.gen_range(0..1_000_000u32));
            let hash = hash_code(&code);
            let clash = self.open.iter().any(|o| ct_eq(&o.code_hash, &hash))
                || self.tombstones.iter().any(|(h, _)| ct_eq(h, &hash));
            if !clash {
                break (code, hash);
            }
        };
        let id = format!("pair_{}", &random_token()[..10]);
        self.open.push(Open {
            id: id.clone(),
            code_hash,
            name_hint,
            kind,
            admin,
            expires_at: now + self.ttl,
            issuer: issuer.to_string(),
            origin,
            outcome_tx,
            challenge: random_token(),
            proof_answered: false,
            matched_device: None,
            wrong: 0,
        });
        Started {
            pairing_id: id,
            code,
            expires_at: chrono::Utc::now()
                + chrono::Duration::from_std(self.ttl).unwrap_or(chrono::Duration::minutes(5)),
        }
    }

    /// Cancel a pairing; honoured only for the connection that owns it.
    pub fn cancel(&mut self, pairing_id: &str, caller: &str) -> bool {
        let Some(i) = self
            .open
            .iter()
            .position(|o| o.id == pairing_id && o.issuer == caller)
        else {
            return false;
        };
        let gone = self.open.remove(i);
        gone.finish(PairOutcomeKind::Cancelled, None);
        true
    }

    /// The connection `key` went away: cancel every pairing it owns, or that a
    /// satellite relayed with it as origin.
    pub fn drop_connection(&mut self, key: &str) {
        let (gone, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.open)
            .into_iter()
            .partition(|o| o.issuer == key || o.origin.as_deref() == Some(key));
        self.open = kept;
        for o in gone {
            o.finish(PairOutcomeKind::ConnectionLost, None);
        }
    }

    /// Expire what is due; forget old tombstones.
    pub fn sweep(&mut self, now: Instant) {
        let (due, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.open)
            .into_iter()
            .partition(|o| o.expires_at <= now);
        self.open = kept;
        for o in due {
            self.tombstones.push((o.code_hash, now));
            o.finish(PairOutcomeKind::Expired, None);
        }
        self.prune(now);
    }

    fn prune(&mut self, now: Instant) {
        self.tombstones
            .retain(|(_, at)| now.duration_since(*at) < TOMBSTONE_TTL);
    }

    /// A `PairCheck`. A correct code never uses the pairing up; a wrong one
    /// counts toward the lockout. `proof_matcher(challenge, code)` is asked at
    /// most once per pairing, and only when a proof arrived.
    pub fn check(
        &mut self,
        code: &str,
        proof: Option<&str>,
        proof_matcher: impl FnOnce(&str, &str, &str) -> Option<String>,
        now: Instant,
    ) -> CheckAnswer {
        self.sweep(now);
        let Some(i) = self.find(code) else {
            return self.wrong_code(code);
        };
        let o = &mut self.open[i];
        let mut knows_device = None;
        if let Some(proof) = proof {
            if !o.proof_answered {
                o.proof_answered = true;
                o.matched_device = proof_matcher(&o.challenge, &normalize_code(code), proof);
                knows_device = Some(o.matched_device.is_some());
            }
        }
        CheckAnswer::Offer {
            name_hint: o.name_hint.clone(),
            challenge: o.challenge.clone(),
            knows_device,
        }
    }

    /// A `Pair`: take the pairing out of the table. The caller redeems it in
    /// the registry and then calls [`Taken::notify_paired`].
    pub fn take(
        &mut self,
        code: &str,
        kind: DeviceKind,
        replace: bool,
        now: Instant,
    ) -> Result<Taken, PairRefusedReason> {
        self.sweep(now);
        let Some(i) = self.find(code) else {
            return Err(match self.wrong_code(code) {
                CheckAnswer::Refused(r) => r,
                CheckAnswer::Offer { .. } => PairRefusedReason::Invalid,
            });
        };
        // A phone cannot redeem a satellite's code, nor the reverse: that is a
        // wrong code as far as the redeemer can tell.
        if self.open[i].kind.is_satellite() != kind.is_satellite() {
            self.count_wrong();
            return Err(PairRefusedReason::Invalid);
        }
        let o = self.open.remove(i);
        let matched = if replace {
            o.matched_device.clone()
        } else {
            None
        };
        Ok(Taken {
            kind,
            admin: o.admin,
            name_hint: o.name_hint.clone(),
            matched_device: matched,
            pairing: o,
        })
    }

    fn find(&self, code: &str) -> Option<usize> {
        let hash = hash_code(code);
        let mut found = None;
        for (i, o) in self.open.iter().enumerate() {
            if ct_eq(&o.code_hash, &hash) {
                found = Some(i);
            }
        }
        found
    }

    /// A code that matches no open pairing: `expired` when a tombstone matches,
    /// otherwise `invalid`, and it counts against every open pairing.
    fn wrong_code(&mut self, code: &str) -> CheckAnswer {
        let hash = hash_code(code);
        let expired = self.tombstones.iter().any(|(h, _)| ct_eq(h, &hash));
        self.count_wrong();
        CheckAnswer::Refused(if expired {
            PairRefusedReason::Expired
        } else {
            PairRefusedReason::Invalid
        })
    }

    /// A wrong code cannot be pinned on one pairing, so it counts against every
    /// pairing open now; the ones that reach the limit are removed.
    fn count_wrong(&mut self) {
        for o in &mut self.open {
            o.wrong += 1;
        }
        let (locked, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.open)
            .into_iter()
            .partition(|o| o.wrong >= MAX_WRONG_ATTEMPTS);
        self.open = kept;
        for o in locked {
            o.finish(PairOutcomeKind::LockedOut, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    fn never(_: &str, _: &str, _: &str) -> Option<String> {
        None
    }

    struct Fixture {
        table: PairingTable,
        rx: mpsc::UnboundedReceiver<ServerMsg>,
        now: Instant,
        started: Started,
    }

    fn fixture() -> Fixture {
        let mut table = PairingTable::new(Duration::from_secs(300));
        let (tx, rx) = mpsc::unbounded_channel();
        let now = Instant::now();
        let started = table.start(
            "conn-a",
            None,
            tx,
            Some("Kitchen".into()),
            DeviceKind::Iphone,
            None,
            now,
        );
        Fixture {
            table,
            rx,
            now,
            started,
        }
    }

    fn outcome(rx: &mut mpsc::UnboundedReceiver<ServerMsg>) -> PairOutcomeKind {
        match rx.try_recv() {
            Ok(ServerMsg::DevicePairOutcome { outcome, .. }) => outcome,
            other => panic!("expected an outcome, got {other:?}"),
        }
    }

    #[test]
    fn a_code_is_six_digits_and_accepts_a_spaced_form() {
        let f = fixture();
        assert_eq!(f.started.code.len(), 6);
        assert!(f.started.code.chars().all(|c| c.is_ascii_digit()));
        let spaced = format!("{} {}", &f.started.code[..3], &f.started.code[3..]);
        let mut f = f;
        let a = f.table.check(&spaced, None, never, f.now);
        assert!(matches!(a, CheckAnswer::Offer { .. }));
    }

    #[test]
    fn a_correct_check_never_uses_the_code_up() {
        let mut f = fixture();
        for _ in 0..3 {
            let a = f.table.check(&f.started.code.clone(), None, never, f.now);
            assert!(matches!(a, CheckAnswer::Offer { name_hint: Some(ref n), .. } if n == "Kitchen"));
        }
        assert!(f
            .table
            .take(&f.started.code.clone(), DeviceKind::Iphone, false, f.now)
            .is_ok());
    }

    #[test]
    fn a_code_is_single_use() {
        let mut f = fixture();
        let code = f.started.code.clone();
        let taken = f
            .table
            .take(&code, DeviceKind::Iphone, false, f.now)
            .expect("first redemption");
        taken.notify_paired("Kitchen", false);
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::Paired);
        assert_eq!(
            f.table
                .take(&code, DeviceKind::Iphone, false, f.now)
                .err(),
            Some(PairRefusedReason::Invalid)
        );
    }

    #[test]
    fn expiry_reports_to_the_issuer_and_leaves_a_tombstone() {
        let mut f = fixture();
        let code = f.started.code.clone();
        f.table.sweep(f.now + Duration::from_secs(301));
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::Expired);
        let late = f.now + Duration::from_secs(400);
        assert_eq!(
            f.table.check(&code, None, never, late),
            CheckAnswer::Refused(PairRefusedReason::Expired)
        );
        // The tombstone goes after an hour.
        let much_later = f.now + Duration::from_secs(301 + 3601);
        assert_eq!(
            f.table.check(&code, None, never, much_later),
            CheckAnswer::Refused(PairRefusedReason::Invalid)
        );
    }

    #[test]
    fn cancel_is_for_the_owner_only_and_leaves_no_tombstone() {
        let mut f = fixture();
        let id = f.started.pairing_id.clone();
        let code = f.started.code.clone();
        assert!(!f.table.cancel(&id, "someone-else"));
        assert_eq!(f.table.open_count(), 1);
        assert!(f.table.cancel(&id, "conn-a"));
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::Cancelled);
        assert_eq!(
            f.table.take(&code, DeviceKind::Iphone, false, f.now).err(),
            Some(PairRefusedReason::Invalid)
        );
    }

    #[test]
    fn losing_the_issuing_connection_cancels_its_pairings() {
        let mut f = fixture();
        f.table.drop_connection("conn-a");
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::ConnectionLost);
        assert_eq!(f.table.open_count(), 0);
    }

    #[test]
    fn five_wrong_codes_lock_out_and_the_right_code_is_then_invalid() {
        let mut f = fixture();
        let code = f.started.code.clone();
        let wrong = if code == "000000" { "000001" } else { "000000" };
        for _ in 0..4 {
            f.table.check(wrong, None, never, f.now);
        }
        assert_eq!(f.table.open_count(), 1);
        // The fifth is a wrong `Pair`: wrong checks and wrong pairs count alike.
        assert_eq!(
            f.table.take(wrong, DeviceKind::Iphone, false, f.now).err(),
            Some(PairRefusedReason::Invalid)
        );
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::LockedOut);
        assert_eq!(
            f.table.take(&code, DeviceKind::Iphone, false, f.now).err(),
            Some(PairRefusedReason::Invalid)
        );
    }

    #[test]
    fn a_wrong_code_counts_against_every_open_pairing() {
        let mut f = fixture();
        let (tx2, mut rx2) = mpsc::unbounded_channel();
        f.table
            .start("conn-b", None, tx2, None, DeviceKind::Ipad, None, f.now);
        for _ in 0..5 {
            f.table.check("not-a-code", None, never, f.now);
        }
        assert_eq!(outcome(&mut f.rx), PairOutcomeKind::LockedOut);
        assert_eq!(outcome(&mut rx2), PairOutcomeKind::LockedOut);
    }

    #[test]
    fn a_phone_cannot_redeem_a_satellite_code() {
        let mut f = fixture();
        let (tx, _rx) = mpsc::unbounded_channel();
        let s = f.table.start(
            "conn-a",
            None,
            tx,
            Some("Tokyo".into()),
            DeviceKind::Satellite,
            Some(SatelliteAdmin::Full),
            f.now,
        );
        assert_eq!(
            f.table.take(&s.code, DeviceKind::Iphone, false, f.now).err(),
            Some(PairRefusedReason::Invalid)
        );
        let t = f
            .table
            .take(&s.code, DeviceKind::Satellite, false, f.now)
            .unwrap();
        assert_eq!(t.admin, Some(SatelliteAdmin::Full));
    }

    #[test]
    fn a_proof_is_answered_once_per_code() {
        let mut f = fixture();
        let code = f.started.code.clone();
        let first = f.table.check(
            &code,
            Some("p"),
            |_, _, _| Some("dev_1".to_string()),
            f.now,
        );
        assert!(matches!(
            first,
            CheckAnswer::Offer {
                knows_device: Some(true),
                ..
            }
        ));
        let second = f.table.check(
            &code,
            Some("p2"),
            |_, _, _| panic!("a second proof is never evaluated"),
            f.now,
        );
        assert!(matches!(
            second,
            CheckAnswer::Offer {
                knows_device: None,
                ..
            }
        ));
        let taken = f
            .table
            .take(&code, DeviceKind::Iphone, true, f.now)
            .unwrap();
        assert_eq!(taken.matched_device.as_deref(), Some("dev_1"));
    }

    #[test]
    fn replace_without_a_match_matches_nothing() {
        let mut f = fixture();
        let code = f.started.code.clone();
        f.table.check(&code, Some("p"), never, f.now);
        let taken = f
            .table
            .take(&code, DeviceKind::Iphone, true, f.now)
            .unwrap();
        assert_eq!(taken.matched_device, None);
    }

    #[test]
    fn the_challenge_differs_per_code() {
        let mut f = fixture();
        let (tx, _rx) = mpsc::unbounded_channel();
        let other = f
            .table
            .start("c", None, tx, None, DeviceKind::Iphone, None, f.now);
        let ch = |t: &mut PairingTable, code: &str, now| match t.check(code, None, never, now) {
            CheckAnswer::Offer { challenge, .. } => challenge,
            other => panic!("{other:?}"),
        };
        let a = ch(&mut f.table, &f.started.code.clone(), f.now);
        let b = ch(&mut f.table, &other.code, f.now);
        assert_ne!(a, b);
    }
}
