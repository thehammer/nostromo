//! Smoke test: render the right-panel widget into a TestBackend and verify
//! it renders without panicking and contains expected sections.

use chrono::Utc;
use ratatui::{Terminal, backend::TestBackend};

use nostromo::{
    data::right_panel_source::RightPanelSnapshot,
    ui::widgets::right_panel,
};

fn make_snapshot() -> RightPanelSnapshot {
    RightPanelSnapshot {
        task_title: "Implement auth middleware".to_string(),
        recent_tools: vec![
            "Read".to_string(),
            "Edit".to_string(),
            "Bash".to_string(),
        ],
        open_files: vec![
            "src/middleware.rs".to_string(),
            "src/main.rs".to_string(),
        ],
        total_tokens: 42_000,
        last_activity: Utc::now(),
    }
}

#[test]
fn right_panel_renders_without_panic() {
    let snap = make_snapshot();
    let backend = TestBackend::new(30, 20);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|f| {
            right_panel::render(f, f.area(), &snap);
        })
        .unwrap();
}

#[test]
fn right_panel_contains_task_title() {
    let snap = make_snapshot();
    let backend = TestBackend::new(40, 24);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|f| {
            right_panel::render(f, f.area(), &snap);
        })
        .unwrap();

    let buf = terminal.backend().buffer().clone();
    let output: String = (0..24_u16)
        .flat_map(|row| {
            let buf = &buf;
            (0..40_u16).map(move |col| buf[(col, row)].symbol().to_string())
        })
        .collect();
    assert!(
        output.contains("Implement") || output.contains("auth"),
        "right panel should contain task title; got:\n{output}"
    );
}

#[test]
fn right_panel_empty_snapshot_renders() {
    let snap = RightPanelSnapshot {
        task_title: String::new(),
        recent_tools: Vec::new(),
        open_files: Vec::new(),
        total_tokens: 0,
        last_activity: Utc::now(),
    };
    let backend = TestBackend::new(30, 20);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|f| {
            right_panel::render(f, f.area(), &snap);
        })
        .unwrap();
}
