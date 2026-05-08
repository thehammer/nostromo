//! Embedded PTY support — `PtyHost` owns the process + vt100 parser;
//! `PtyWidget` renders the parsed screen into a Ratatui buffer.

pub mod host;
pub mod widget;

pub use host::PtyHost;
pub use widget::PtyWidget;
