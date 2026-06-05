//! keyspy — print raw crossterm Key and Mouse events.
//! Run with: cargo run --bin keyspy
//! Press keys or scroll/click to see what crossterm reports. Ctrl-C to quit.

use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode},
};

fn main() {
    enable_raw_mode().unwrap();
    execute!(std::io::stderr(), EnableMouseCapture).unwrap();
    eprintln!("keyspy ready — press keys or use mouse (Ctrl-C to quit)\r");

    loop {
        match event::read().unwrap() {
            Event::Key(k) => {
                if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    break;
                }
                println!(
                    "KEY   code={:?}  modifiers={:?}  kind={:?}\r",
                    k.code, k.modifiers, k.kind
                );
            }
            Event::Mouse(m) => {
                println!(
                    "MOUSE kind={:?}  col={}  row={}  modifiers={:?}\r",
                    m.kind, m.column, m.row, m.modifiers
                );
            }
            _ => {}
        }
    }

    execute!(std::io::stderr(), DisableMouseCapture).unwrap();
    disable_raw_mode().unwrap();
}
