//! Which built-in agents this daemon runs (`[agents.<name>]` in config.toml).
/// The agents that can be switched off. Mother is not one of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Agent {
    Fred,
    Perri,
    Teri,
}

impl Agent {
    pub const ALL: [Agent; 3] = [Agent::Fred, Agent::Perri, Agent::Teri];

    pub fn name(self) -> &'static str {
        match self {
            Agent::Fred => "fred",
            Agent::Perri => "perri",
            Agent::Teri => "teri",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|a| a.name().eq_ignore_ascii_case(s))
    }

    /// The MCP tool-name / pane-source prefix this agent owns ("fred." ...).
    pub fn tool_prefix(self) -> &'static str {
        match self {
            Agent::Fred => "fred.",
            Agent::Perri => "perri.",
            Agent::Teri => "teri.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnabledAgents {
    pub fred: bool,
    pub perri: bool,
    pub teri: bool,
}

impl Default for EnabledAgents {
    fn default() -> Self {
        Self::all()
    }
}

impl EnabledAgents {
    pub const fn all() -> Self {
        Self {
            fred: true,
            perri: true,
            teri: true,
        }
    }

    pub fn is_enabled(&self, a: Agent) -> bool {
        match a {
            Agent::Fred => self.fred,
            Agent::Perri => self.perri,
            Agent::Teri => self.teri,
        }
    }

    /// False only for a tool whose name starts with a disabled agent's prefix.
    pub fn allows_tool(&self, tool: &str) -> bool {
        !Agent::ALL
            .into_iter()
            .any(|a| !self.is_enabled(a) && tool.starts_with(a.tool_prefix()))
    }

    /// Same rule for pane-source names (`perri.list_pr_queue`, ...).
    pub fn allows_source(&self, source: &str) -> bool {
        self.allows_tool(source)
    }

    /// Sorted lowercase names of every running built-in, "mother" always included.
    pub fn wire_names(&self) -> Vec<String> {
        let mut names: Vec<String> = Agent::ALL
            .into_iter()
            .filter(|a| self.is_enabled(*a))
            .map(|a| a.name().to_string())
            .collect();
        names.push("mother".to_string());
        names.sort();
        names
    }

    /// Sorted lowercase names of the switchable built-ins that are off (`mother`
    /// never is). The complement of [`Self::wire_names`] over the switchable agents:
    /// a client that knows an agent this daemon does not still learns what is off.
    pub fn disabled_names(&self) -> Vec<String> {
        let mut names: Vec<String> = Agent::ALL
            .into_iter()
            .filter(|a| !self.is_enabled(*a))
            .map(|a| a.name().to_string())
            .collect();
        names.sort();
        names
    }

    fn set(&mut self, a: Agent, on: bool) {
        match a {
            Agent::Fred => self.fred = on,
            Agent::Perri => self.perri = on,
            Agent::Teri => self.teri = on,
        }
    }
}

/// Keeps the `watch` senders of disabled agents alive for the daemon's
/// lifetime. A disabled agent still hands its consumers a live receiver: a
/// dropped sender makes `changed()` fail at once, and
/// `run_pane_source_broadcaster` exits on that error, which would also kill
/// the staleness ticker for file and ticket panes.
#[derive(Default)]
pub struct ParkedSenders(Vec<Box<dyn std::any::Any + Send>>);

impl ParkedSenders {
    /// A receiver whose sender is parked here (so it never reports closed and
    /// never produces a value) for as long as `self` lives.
    pub fn channel<T: Send + Sync + 'static>(
        &mut self,
        initial: T,
    ) -> tokio::sync::watch::Receiver<T> {
        let (tx, rx) = tokio::sync::watch::channel(initial);
        self.0.push(Box::new(tx));
        rx
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// `key` as it may be logged: control characters (newlines, escape sequences)
/// written out as `\u{..}` escapes, so a config key cannot forge a log line or
/// drive a terminal.
fn escape_key(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_control() {
                c.escape_default().to_string()
            } else {
                c.to_string()
            }
        })
        .collect()
}

/// Resolve the `[agents]` value from config.toml. Returns warnings to log,
/// never an error: anything unreadable (a non-table `agents`, a non-table
/// entry, a non-bool `enabled`) is warned about and ignored, so it can never
/// disable an agent it did not clearly say to disable and never stop the
/// daemon. Warnings carry key names only, never config values.
///
/// If two keys differ only by case (`[agents.Fred]` and `[agents.fred]`), a
/// warning is logged and the key that sorts last in byte order wins, so the
/// lowercase key beats a capitalised one.
pub fn resolve(agents: Option<&toml::Value>) -> (EnabledAgents, Vec<String>) {
    let mut enabled = EnabledAgents::all();
    let mut warnings = Vec::new();
    let Some(value) = agents else {
        return (enabled, warnings);
    };
    let Some(tables) = value.as_table() else {
        warnings
            .push("[agents] must be a table of [agents.<name>] tables; ignoring it".to_string());
        return (enabled, warnings);
    };
    let mut seen: Vec<Agent> = Vec::new();
    for (key, entry) in tables {
        let name = escape_key(key);
        let name = name.as_str();
        let Some(entry) = entry.as_table() else {
            warnings.push(format!("agents.{name} must be a table; ignoring it"));
            continue;
        };
        let on = match entry.get("enabled") {
            None => true,
            Some(toml::Value::Boolean(b)) => *b,
            Some(_) => {
                warnings.push(format!(
                    "agents.{name}.enabled must be true or false; ignoring it"
                ));
                continue;
            }
        };
        if key.eq_ignore_ascii_case("mother") {
            if !on {
                warnings
                    .push("agents.mother cannot be disabled; ignoring enabled = false".to_string());
            }
        } else if let Some(a) = Agent::from_name(key) {
            if seen.contains(&a) {
                warnings.push(format!(
                    "agents.{name} duplicates another {} key that differs only by case; the key sorting last wins",
                    a.name()
                ));
            }
            seen.push(a);
            enabled.set(a, on);
        } else {
            warnings.push(format!(
                "unknown agent `{name}` in [agents]; ignoring (known: fred, perri, teri)"
            ));
        }
    }
    (enabled, warnings)
}

use std::sync::Arc;
use tokio::sync::{mpsc, watch};

use crate::data::{
    fred_calendar::CalendarSnapshot, fred_mailbox::MailboxSnapshot, perri_pr::PrSnapshots,
    perri_queue::PrQueueSnapshot, relay_client::QueueSignal, teri_todos::TeriTodosSnapshot,
    work::hub::WorkHub,
};

pub type PerriQueueRx = watch::Receiver<Option<PrQueueSnapshot>>;
pub type PerriPrRx = watch::Receiver<PrSnapshots>;
pub type MailboxRx = watch::Receiver<Option<MailboxSnapshot>>;
pub type CalendarRx = watch::Receiver<Option<CalendarSnapshot>>;
pub type TodosRx = watch::Receiver<Option<TeriTodosSnapshot>>;

/// What starting Perri's sources produced.
pub struct PerriSources {
    pub queue_rx: PerriQueueRx,
    pub queue_refresh_tx: mpsc::UnboundedSender<()>,
    pub queue_relay_tx: mpsc::UnboundedSender<QueueSignal>,
    pub pr_rx: PerriPrRx,
    pub pr_refresh_tx: crate::data::perri_pr_native::RefreshTx,
}

/// What starting Teri's source produced. `work_hub` is installed as the
/// process-wide work service by [`wire_agents`].
pub struct TeriSources {
    pub todos_rx: TodosRx,
    pub work_hub: Option<Arc<WorkHub>>,
}

/// The side-effecting half of the daemon's agent wiring: starting pollers and
/// broadcasters. `nostromd` implements it with the real sources; tests
/// implement it with a recorder. [`wire_agents`] calls a method only for an
/// enabled agent.
pub trait AgentSpawner {
    fn start_perri(&mut self) -> PerriSources;
    fn start_fred(&mut self) -> (MailboxRx, CalendarRx);
    fn start_teri(&mut self) -> TeriSources;
    fn start_perri_broadcaster(&mut self, queue_rx: PerriQueueRx, pr_rx: PerriPrRx);
    fn start_fred_broadcaster(&mut self, mailbox_rx: MailboxRx, calendar_rx: CalendarRx);
    fn start_teri_broadcaster(&mut self, todos_rx: TodosRx);
}

/// The receivers (live for enabled agents, parked and never-firing for
/// disabled ones) and handles the rest of the daemon is built on. `parked`
/// must be kept alive for the daemon's lifetime.
pub struct WiredAgents {
    pub perri_queue_rx: PerriQueueRx,
    pub perri_queue_refresh_tx: Option<mpsc::UnboundedSender<()>>,
    pub perri_queue_relay_tx: Option<mpsc::UnboundedSender<QueueSignal>>,
    pub perri_pr_rx: PerriPrRx,
    pub perri_pr_refresh_tx: Option<crate::data::perri_pr_native::RefreshTx>,
    pub fred_mailbox_rx: MailboxRx,
    pub fred_calendar_rx: CalendarRx,
    pub teri_todos_rx: TodosRx,
    pub work_hub: Option<Arc<WorkHub>>,
    pub parked: ParkedSenders,
}

/// Start sources and broadcasters for enabled agents only; a disabled agent
/// gets receivers whose senders are parked in the result. Installs the work
/// hub as the process-wide work service only when Teri is enabled, so a
/// disabled Teri leaves the Null service in place.
pub fn wire_agents(enabled: EnabledAgents, spawner: &mut dyn AgentSpawner) -> WiredAgents {
    let mut parked = ParkedSenders::default();

    let (
        perri_queue_rx,
        perri_queue_refresh_tx,
        perri_queue_relay_tx,
        perri_pr_rx,
        perri_pr_refresh_tx,
    ) = if enabled.perri {
        let p = spawner.start_perri();
        spawner.start_perri_broadcaster(p.queue_rx.clone(), p.pr_rx.clone());
        (
            p.queue_rx,
            Some(p.queue_refresh_tx),
            Some(p.queue_relay_tx),
            p.pr_rx,
            Some(p.pr_refresh_tx),
        )
    } else {
        let q = parked.channel::<Option<PrQueueSnapshot>>(None);
        let p = parked.channel(crate::data::perri_pr::no_prs());
        (q, None, None, p, None)
    };

    let (fred_mailbox_rx, fred_calendar_rx) = if enabled.fred {
        let (m, c) = spawner.start_fred();
        spawner.start_fred_broadcaster(m.clone(), c.clone());
        (m, c)
    } else {
        (
            parked.channel::<Option<MailboxSnapshot>>(None),
            parked.channel::<Option<CalendarSnapshot>>(None),
        )
    };

    let (teri_todos_rx, work_hub) = if enabled.teri {
        let t = spawner.start_teri();
        if let Some(hub) = &t.work_hub {
            crate::data::work::install_work_service(hub.clone());
        }
        spawner.start_teri_broadcaster(t.todos_rx.clone());
        (t.todos_rx, t.work_hub)
    } else {
        (parked.channel::<Option<TeriTodosSnapshot>>(None), None)
    };

    WiredAgents {
        perri_queue_rx,
        perri_queue_refresh_tx,
        perri_queue_relay_tx,
        perri_pr_rx,
        perri_pr_refresh_tx,
        fred_mailbox_rx,
        fred_calendar_rx,
        teri_todos_rx,
        work_hub,
        parked,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(toml_src: &str) -> (EnabledAgents, Vec<String>) {
        let v: toml::Value = toml::from_str(toml_src).unwrap();
        resolve(v.get("agents"))
    }

    #[test]
    fn empty_tables_enable_everything() {
        let (e, w) = resolve(None);
        assert_eq!(e, EnabledAgents::all());
        assert!(w.is_empty());
    }

    #[test]
    fn a_disabled_table_disables_only_that_agent() {
        let (e, w) = r("[agents.fred]\nenabled = false\n");
        assert_eq!(
            e,
            EnabledAgents {
                fred: false,
                perri: true,
                teri: true
            }
        );
        assert!(w.is_empty());
    }

    #[test]
    fn warnings_write_control_characters_in_a_key_as_escapes() {
        // An unknown key, a non-table key and a bad `enabled`, each with a newline or escape in its name.
        let (_, w) = r("[agents.\"bob\\nERROR forged line\"]\nenabled = false\n");
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("bob\\nERROR forged line"), "{w:?}");
        assert!(!w[0].contains('\n'));

        let (_, w) = r("[agents]\n\"a\\u001b[31mb\" = 3\n");
        assert_eq!(w.len(), 1);
        assert!(
            w[0].contains("a\\u{1b}[31mb") && !w[0].contains('\u{1b}'),
            "{w:?}"
        );

        let (_, w) = r("[agents.\"c\\rd\"]\nenabled = \"no\"\n");
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("c\\rd") && !w[0].contains('\r'), "{w:?}");
    }

    #[test]
    fn mother_cannot_be_disabled_and_warns() {
        let (e, w) = r("[agents.mother]\nenabled = false\n");
        assert_eq!(e, EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("mother"));
    }

    #[test]
    fn mother_enabled_true_is_silent() {
        assert!(r("[agents.mother]\nenabled = true\n").1.is_empty());
    }

    #[test]
    fn unknown_agents_warn() {
        let (e, w) = r("[agents.bob]\nenabled = false\n");
        assert_eq!(e, EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("bob"));
    }

    #[test]
    fn malformed_shapes_warn_and_disable_nothing() {
        for src in [
            "agents = 3\n",
            "agents = \"fred\"\n",
            "agents = [1, 2]\n",
            "[agents]\nfred = false\n",
            "[agents]\nperri = \"off\"\n",
            "[agents.fred]\nenabled = \"no\"\n",
            "[agents.fred]\nenabled = 0\n",
            "[agents.teri]\nenabled = [false]\n",
        ] {
            let (e, w) = r(src);
            assert_eq!(e, EnabledAgents::all(), "{src}");
            assert_eq!(w.len(), 1, "{src}: {w:?}");
        }
    }

    #[test]
    fn warnings_never_echo_config_values() {
        let (_, w) = r("[agents.fred]\nenabled = \"hunter2-secret\"\n");
        assert!(!w.join(" ").contains("hunter2"));
    }

    #[test]
    fn a_bad_entry_does_not_stop_a_good_one() {
        let (e, w) = r("[agents]\nfred = false\n[agents.perri]\nenabled = false\n");
        assert_eq!(
            e,
            EnabledAgents {
                fred: true,
                perri: false,
                teri: true
            }
        );
        assert_eq!(w.len(), 1);
    }

    #[test]
    fn mother_with_a_bad_enabled_is_just_a_warning() {
        let (e, w) = r("[agents.mother]\nenabled = \"no\"\n");
        assert_eq!(e, EnabledAgents::all());
        assert_eq!(w.len(), 1);
    }

    #[test]
    fn case_variant_duplicates_warn_once_and_lowercase_wins() {
        let (e, w) = r("[agents.Fred]\nenabled = false\n[agents.fred]\nenabled = true\n");
        assert!(e.fred);
        assert_eq!(w.len(), 1);
        let (e, w) = r("[agents.Fred]\nenabled = true\n[agents.fred]\nenabled = false\n");
        assert!(!e.fred);
        assert_eq!(w.len(), 1);
    }

    /// Written with the lowercase key FIRST: if the toml table kept file order
    /// (the `preserve_order` feature), `Fred` would win here instead. These
    /// pass only while keys iterate in sorted byte order, which is what the
    /// docs promise.
    #[test]
    fn duplicate_winner_follows_sorted_key_order_not_file_order() {
        let (e, w) = r("[agents.fred]\nenabled = false\n[agents.Fred]\nenabled = true\n");
        assert!(
            !e.fred,
            "`fred` sorts after `Fred`, so it wins even though it is written first"
        );
        assert_eq!(w.len(), 1);
        let (e, w) = r("[agents.fred]\nenabled = true\n[agents.Fred]\nenabled = false\n");
        assert!(e.fred);
        assert_eq!(w.len(), 1);
    }

    #[tokio::test]
    async fn parked_receivers_stay_open_until_the_parking_lot_is_dropped() {
        let mut parked = ParkedSenders::default();
        let mut rx = parked.channel(0u8);
        assert_eq!(parked.len(), 1);
        // Alive sender: `changed()` stays pending instead of erroring.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.changed())
                .await
                .is_err(),
            "a parked sender must keep changed() pending"
        );
        drop(parked);
        assert!(
            rx.changed().await.is_err(),
            "control: dropping the senders closes the channel"
        );
    }

    #[test]
    fn allows_tool_denies_only_disabled_prefixes() {
        let e = EnabledAgents {
            fred: false,
            perri: true,
            teri: true,
        };
        assert!(!e.allows_tool("fred.get_state"));
        assert!(e.allows_tool("nostromo.list_views"));
        assert!(e.allows_tool("mother.list_jobs"));
        assert!(e.allows_tool("fredx.foo"));
        assert!(e.allows_tool("perri.list_pr_queue"));
    }

    #[test]
    fn wire_names_always_has_mother_and_is_sorted() {
        let e = EnabledAgents {
            fred: false,
            perri: true,
            teri: false,
        };
        assert_eq!(e.wire_names(), vec!["mother", "perri"]);
        assert_eq!(
            EnabledAgents::all().wire_names(),
            vec!["fred", "mother", "perri", "teri"]
        );
    }

    #[test]
    fn disabled_names_lists_exactly_the_switchable_agents_that_are_off() {
        assert!(EnabledAgents::all().disabled_names().is_empty());
        let e = EnabledAgents {
            fred: false,
            perri: true,
            teri: false,
        };
        assert_eq!(e.disabled_names(), vec!["fred", "teri"]);
        assert!(!e.disabled_names().contains(&"mother".to_string()));
    }

    #[test]
    fn from_name_is_case_insensitive() {
        assert_eq!(Agent::from_name("FrEd"), Some(Agent::Fred));
        assert_eq!(Agent::from_name("nope"), None);
    }
}
