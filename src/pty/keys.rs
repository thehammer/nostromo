//! Key-event → byte-string encoding shared by `PtyHost` and `DaemonPtyClient`.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// Encode a crossterm [`KeyEvent`] as the byte sequence a terminal application
/// expects to receive on stdin.
///
/// Returns `None` for key codes that have no standard encoding (e.g.
/// unrecognised `F(n)` numbers, modifier-only keys).
pub fn key_to_bytes(key: &KeyEvent) -> Option<Vec<u8>> {
    let bytes = match key.code {
        KeyCode::Char(c) => {
            if key.modifiers.contains(KeyModifiers::CONTROL) {
                let byte = (c as u8) & 0x1f;
                vec![byte]
            } else {
                let mut buf = [0u8; 4];
                c.encode_utf8(&mut buf).as_bytes().to_vec()
            }
        }
        KeyCode::Enter => b"\r".to_vec(),
        KeyCode::Backspace => b"\x7f".to_vec(),
        KeyCode::Tab => b"\t".to_vec(),
        KeyCode::Esc => b"\x1b".to_vec(),
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::F(n) => match n {
            // F1-F4 use SS3, F5+ use CSI.
            1 => b"\x1bOP".to_vec(),
            2 => b"\x1bOQ".to_vec(),
            3 => b"\x1bOR".to_vec(),
            4 => b"\x1bOS".to_vec(),
            5 => b"\x1b[15~".to_vec(),
            6 => b"\x1b[17~".to_vec(),
            7 => b"\x1b[18~".to_vec(),
            8 => b"\x1b[19~".to_vec(),
            9 => b"\x1b[20~".to_vec(),
            10 => b"\x1b[21~".to_vec(),
            11 => b"\x1b[23~".to_vec(),
            12 => b"\x1b[24~".to_vec(),
            _ => return None,
        },
        _ => return None,
    };

    Some(bytes)
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::CONTROL)
    }

    #[test]
    fn enter() {
        assert_eq!(key_to_bytes(&key(KeyCode::Enter)), Some(b"\r".to_vec()));
    }

    #[test]
    fn backspace() {
        assert_eq!(
            key_to_bytes(&key(KeyCode::Backspace)),
            Some(b"\x7f".to_vec())
        );
    }

    #[test]
    fn ctrl_c() {
        // Ctrl-C → ETX (0x03)
        assert_eq!(key_to_bytes(&ctrl(KeyCode::Char('c'))), Some(vec![0x03]));
    }

    #[test]
    fn ctrl_l() {
        // Ctrl-L → FF (0x0c)
        assert_eq!(key_to_bytes(&ctrl(KeyCode::Char('l'))), Some(vec![0x0c]));
    }

    #[test]
    fn arrow_up() {
        assert_eq!(key_to_bytes(&key(KeyCode::Up)), Some(b"\x1b[A".to_vec()));
    }

    #[test]
    fn f1_to_f4_use_ss3() {
        assert_eq!(key_to_bytes(&key(KeyCode::F(1))), Some(b"\x1bOP".to_vec()));
        assert_eq!(key_to_bytes(&key(KeyCode::F(4))), Some(b"\x1bOS".to_vec()));
    }

    #[test]
    fn f5_uses_csi() {
        assert_eq!(
            key_to_bytes(&key(KeyCode::F(5))),
            Some(b"\x1b[15~".to_vec())
        );
    }

    #[test]
    fn unknown_f_key_returns_none() {
        assert_eq!(key_to_bytes(&key(KeyCode::F(99))), None);
    }

    #[test]
    fn regular_char() {
        assert_eq!(key_to_bytes(&key(KeyCode::Char('a'))), Some(b"a".to_vec()));
    }
}
