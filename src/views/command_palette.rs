//! Ctrl-P command palette — fuzzy-filtered list of actions.
//!
//! The palette renders as a centered overlay (60%-wide, 40%-tall) on top of
//! the current layout.  A single-line query bar at the top filters the item
//! list via subsequence-match scoring.
//!
//! ## Fuzzy matching
//!
//! We use a simple inline subsequence scorer: match each query character in
//! order within `label`.  Score = Σ (1.0 / gap) where `gap` is the distance
//! between consecutive matched characters (starting from the match position of
//! the previous character).  Shorter labels break ties.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph},
    Frame,
};

use crate::ui::theme;

// ── public types ──────────────────────────────────────────────────────────────

/// Actions the palette can produce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaletteAction {
    SwitchView(&'static str),
    SpawnFredRepl,
    SpawnAgentRepl(&'static str), // "cody", "claudia", "kennedy"
    OpenPrDiff(String),
    ApproveMotherJob(String),
    CancelMotherJob(String),
    SplitHorizontal,
    SplitVertical,
    ClosePane,
    ToggleRightPanel,
    ToggleSplitMode,
}

/// Category tag shown in the palette list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaletteCategory {
    Navigation,
    Agent,
    Layout,
    Mother,
    Pr,
}

impl PaletteCategory {
    fn label(self) -> &'static str {
        match self {
            Self::Navigation => "nav",
            Self::Agent => "agent",
            Self::Layout => "layout",
            Self::Mother => "mother",
            Self::Pr => "pr",
        }
    }
}

/// A single item in the palette.
#[derive(Debug, Clone)]
pub struct PaletteItem {
    pub id: &'static str,
    pub label: String,
    pub category: PaletteCategory,
    pub action: PaletteAction,
}

/// What the palette returns after handling a key.
#[derive(Debug, Clone)]
pub enum PaletteOutcome {
    /// Key consumed; palette still open.
    Consumed,
    /// User dismissed (Esc / Ctrl-C).
    Dismiss,
    /// User confirmed selection; execute this action.
    Execute(PaletteAction),
}

// ── CommandPalette ────────────────────────────────────────────────────────────

pub struct CommandPalette {
    query: String,
    items: Vec<PaletteItem>,
    /// Indices into `items`, sorted by match score (best first).
    filtered: Vec<usize>,
    selected: usize,
}

impl CommandPalette {
    pub fn new(items: Vec<PaletteItem>) -> Self {
        let filtered: Vec<usize> = (0..items.len()).collect();
        Self { query: String::new(), items, filtered, selected: 0 }
    }

    pub fn on_key(&mut self, k: &KeyEvent) -> PaletteOutcome {
        match k.code {
            // Dismiss
            KeyCode::Esc => return PaletteOutcome::Dismiss,
            KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => {
                return PaletteOutcome::Dismiss;
            }

            // Confirm selection
            KeyCode::Enter => {
                if let Some(&idx) = self.filtered.get(self.selected) {
                    return PaletteOutcome::Execute(self.items[idx].action.clone());
                }
                return PaletteOutcome::Dismiss;
            }

            // Navigation
            KeyCode::Up | KeyCode::BackTab => {
                if self.selected > 0 {
                    self.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Tab => {
                if self.selected + 1 < self.filtered.len() {
                    self.selected += 1;
                }
            }

            // Query editing
            KeyCode::Char(c) => {
                self.query.push(c);
                self.refilter();
            }
            KeyCode::Backspace => {
                self.query.pop();
                self.refilter();
            }

            _ => {}
        }
        PaletteOutcome::Consumed
    }

    pub fn render(&self, f: &mut Frame, area: Rect) {
        // Centred overlay: 60% wide, 40% tall.
        let overlay = centered_rect(60, 40, area);

        // Clear the background.
        f.render_widget(Clear, overlay);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(theme::BORDER_ACTIVE))
            .title(Span::styled(" Command Palette ", Style::default().fg(theme::FG_MUTED)));

        let inner = block.inner(overlay);
        f.render_widget(block, overlay);

        // Split inner into query bar (1 row) + list (rest).
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Min(0)])
            .split(inner);

        // Query bar.
        let query_text = format!("> {}", self.query);
        let query_widget = Paragraph::new(Span::styled(query_text, Style::default().fg(theme::FG)));
        f.render_widget(query_widget, chunks[0]);

        // Filtered list.
        let items: Vec<ListItem> = self
            .filtered
            .iter()
            .map(|&idx| {
                let item = &self.items[idx];
                let cat_span = Span::styled(
                    format!("[{}] ", item.category.label()),
                    Style::default().fg(theme::FG_MUTED),
                );
                let label_span = Span::styled(item.label.clone(), Style::default().fg(theme::FG));
                ListItem::new(Line::from(vec![cat_span, label_span]))
            })
            .collect();

        let mut list_state = ListState::default();
        if !self.filtered.is_empty() {
            list_state.select(Some(self.selected));
        }

        let list = List::new(items)
            .highlight_style(
                Style::default()
                    .fg(theme::FG)
                    .bg(theme::BORDER_ACTIVE)
                    .add_modifier(Modifier::BOLD),
            )
            .highlight_symbol("▶ ");

        f.render_stateful_widget(list, chunks[1], &mut list_state);
    }

    // ── private ───────────────────────────────────────────────────────────────

    fn refilter(&mut self) {
        self.selected = 0;
        let q = self.query.to_lowercase();

        if q.is_empty() {
            self.filtered = (0..self.items.len()).collect();
            return;
        }

        // Score each item; keep only those that match.
        let mut scored: Vec<(usize, f64)> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(i, item)| {
                let label = item.label.to_lowercase();
                subsequence_score(&q, &label).map(|s| (i, s))
            })
            .collect();

        // Best score first; tie-break by shorter label.
        scored.sort_by(|(ai, as_), (bi, bs)| {
            bs.partial_cmp(as_)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| self.items[*ai].label.len().cmp(&self.items[*bi].label.len()))
        });

        self.filtered = scored.into_iter().map(|(i, _)| i).collect();
    }
}

// ── fuzzy scoring ─────────────────────────────────────────────────────────────

/// Compute a subsequence-match score of `query` against `text`.
///
/// Returns `None` when `query` is not a subsequence of `text`.
/// Score = Σ (1.0 / position_gap) where gap is the character-distance between
/// consecutive matched positions.  Higher is better.
pub fn subsequence_score(query: &str, text: &str) -> Option<f64> {
    let q_chars: Vec<char> = query.chars().collect();
    let t_chars: Vec<char> = text.chars().collect();

    let mut q_idx = 0;
    let mut prev_pos: Option<usize> = None;
    let mut score = 0.0f64;

    for (t_pos, &tc) in t_chars.iter().enumerate() {
        if q_idx < q_chars.len() && tc == q_chars[q_idx] {
            let gap = match prev_pos {
                None => 1,
                Some(p) => t_pos - p,
            };
            score += 1.0 / gap as f64;
            prev_pos = Some(t_pos);
            q_idx += 1;
        }
    }

    if q_idx == q_chars.len() { Some(score) } else { None }
}

// ── build_items ───────────────────────────────────────────────────────────────

use crate::{app::AppState, mother::MotherJob};

/// Construct the full palette item list from current application state.
///
/// Called once when the palette is opened.
pub fn build_items(state: &AppState, jobs: &[MotherJob]) -> Vec<PaletteItem> {
    let mut items: Vec<PaletteItem> = Vec::new();

    // Navigation — switch to a named view.
    const VIEWS: &[(&str, &str)] = &[
        ("fred", "Switch to Fred"),
        ("perri", "Switch to Perri"),
        ("claudia", "Switch to Claudia"),
        ("cody", "Switch to Cody"),
        ("kennedy", "Switch to Kennedy"),
        ("mother", "Switch to Mother"),
    ];
    for &(id, label) in VIEWS {
        items.push(PaletteItem {
            id,
            label: label.to_string(),
            category: PaletteCategory::Navigation,
            action: PaletteAction::SwitchView(id),
        });
    }

    // Agent REPLs.
    items.push(PaletteItem {
        id: "spawn-fred-repl",
        label: "Spawn Fred REPL".to_string(),
        category: PaletteCategory::Agent,
        action: PaletteAction::SpawnFredRepl,
    });
    for &agent in &["cody", "claudia", "kennedy"] {
        items.push(PaletteItem {
            id: agent,
            label: format!("Spawn {agent} REPL"),
            category: PaletteCategory::Agent,
            action: PaletteAction::SpawnAgentRepl(agent),
        });
    }

    // Layout actions.
    let layout_actions: &[(&str, &str, PaletteAction)] = &[
        ("split-h", "Split Horizontal (Ctrl-W s)", PaletteAction::SplitHorizontal),
        ("split-v", "Split Vertical (Ctrl-W v)", PaletteAction::SplitVertical),
        ("close-pane", "Close Pane (Ctrl-W q)", PaletteAction::ClosePane),
        ("toggle-split", "Toggle Split Mode (Ctrl-W t)", PaletteAction::ToggleSplitMode),
        ("toggle-right", "Toggle Right Panel (Ctrl-R)", PaletteAction::ToggleRightPanel),
    ];
    for &(id, label, ref action) in layout_actions {
        items.push(PaletteItem {
            id,
            label: label.to_string(),
            category: PaletteCategory::Layout,
            action: action.clone(),
        });
    }

    // Mother jobs.
    for job in jobs {
        if job.is_awaiting() {
            items.push(PaletteItem {
                id: "approve-job",
                label: format!("Approve job: {}", truncate_label(&job.title, 40)),
                category: PaletteCategory::Mother,
                action: PaletteAction::ApproveMotherJob(job.id.clone()),
            });
        }
        if job.state == "running" || job.is_awaiting() || job.is_failed() {
            items.push(PaletteItem {
                id: "cancel-job",
                label: format!("Cancel job: {}", truncate_label(&job.title, 40)),
                category: PaletteCategory::Mother,
                action: PaletteAction::CancelMotherJob(job.id.clone()),
            });
        }
    }

    // Open PR diffs from Perri state (if any PRs known from state).
    for (pr_url, pr_title) in &state.open_pr_list {
        items.push(PaletteItem {
            id: "pr-diff",
            label: format!("Open diff: {}", truncate_label(pr_title, 40)),
            category: PaletteCategory::Pr,
            action: PaletteAction::OpenPrDiff(pr_url.clone()),
        });
    }

    items
}

fn truncate_label(s: &str, max: usize) -> &str {
    let end = s
        .char_indices()
        .nth(max)
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    &s[..end]
}

// ── layout helpers ────────────────────────────────────────────────────────────

/// Return a centred rect `pct_w`% wide and `pct_h`% tall within `area`.
pub fn centered_rect(pct_w: u16, pct_h: u16, area: Rect) -> Rect {
    let w = area.width * pct_w / 100;
    let h = area.height * pct_h / 100;
    let x = area.x + (area.width.saturating_sub(w)) / 2;
    let y = area.y + (area.height.saturating_sub(h)) / 2;
    Rect { x, y, width: w, height: h }
}
