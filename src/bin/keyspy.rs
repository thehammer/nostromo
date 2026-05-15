//! keyspy — print raw crossterm KeyEvent structs.
//! Run with: cargo run --bin keyspy
//! Press keys to see what crossterm reports. Ctrl-C to quit.

use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    terminal::{disable_raw_mode, enable_raw_mode},
};

fn main() {
    enable_raw_mode().unwrap();
    eprintln!("keyspy ready — press keys (Ctrl-C to quit)\r");

    loop {
        if let Ok(Event::Key(k)) = event::read() {
            // Quit on Ctrl-C
            if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) {
                break;
            }
            println!(
                "code={:?}  modifiers={:?}  kind={:?}\r",
                k.code, k.modifiers, k.kind
            );
        }
    }

    disable_raw_mode().unwrap();
}
