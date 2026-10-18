//! A shallow scan of a `control_request` line that `serde_json` cannot parse.
//!
//! The CLI serialises with `JSON.stringify` (no depth limit) and then waits
//! forever for an answer to a `can_use_tool` request. `serde_json` refuses
//! anything nested deeper than 128 levels, and a 100,000-deep value would
//! overflow the stack when built, cloned or dropped. So a line that does not
//! parse is never turned into a value: this scanner walks the bytes with a
//! counter instead of recursion and picks out only what is needed to answer it:
//!
//! - the top-level `type` (is it a `control_request`?),
//! - the top-level `request_id` (a string or a number, as the same JSON value),
//! - `request.subtype` and `request.tool_name`.
//!
//! It is linear in the line's length, allocates nothing proportional to it, and
//! is best effort: on anything it cannot follow (a cut-off line, malformed JSON)
//! it stops and reports what it had already seen. A string is only ever reported
//! whole, and a number only once something follows it, so a truncated line never
//! yields a guessed id.

use serde_json::Value;

/// Longest `request_id` (raw bytes) that is recovered; a longer one is not an id we would echo.
const MAX_ID_BYTES: usize = 4096;
/// Longest `subtype` or `tool_name` (raw bytes) that is recovered.
const MAX_NAME_BYTES: usize = 256;
/// Longest object key (raw bytes) that is compared at all.
const MAX_KEY_BYTES: usize = 64;

/// What a scan of an unreadable `control_request` recovered.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ControlRequestHint {
    /// The top-level `request_id`, a JSON string or number.
    pub request_id: Option<Value>,
    /// `request.subtype`.
    pub subtype: Option<String>,
    /// `request.tool_name`, if it is short enough to be a name.
    pub tool_name: Option<String>,
}

/// Scan `line`. `Some` if its top-level `type` is `control_request`, with whatever was recovered.
pub fn scan_control_request(line: &str) -> Option<ControlRequestHint> {
    let mut scan = Scanner {
        b: line.as_bytes(),
        i: 0,
    };
    let mut kind: Option<String> = None;
    let mut hint = ControlRequestHint::default();
    scan.top_level(&mut kind, &mut hint);
    (kind.as_deref() == Some("control_request")).then_some(hint)
}

struct Scanner<'a> {
    b: &'a [u8],
    i: usize,
}

/// The scanner could not follow the line any further (end of line or malformed JSON).
struct Stop;

type Step<T> = Result<T, Stop>;

impl<'a> Scanner<'a> {
    /// The members of the top-level object. Whatever stops the scan, `kind` and
    /// `hint` keep what was seen.
    fn top_level(&mut self, kind: &mut Option<String>, hint: &mut ControlRequestHint) {
        let _ = self.top_level_members(kind, hint);
    }

    fn top_level_members(
        &mut self,
        kind: &mut Option<String>,
        hint: &mut ControlRequestHint,
    ) -> Step<()> {
        self.skip_ws();
        self.expect(b'{')?;
        loop {
            self.skip_ws();
            if self.peek()? == b'}' {
                return Ok(());
            }
            let key = self.key()?;
            match key.as_deref() {
                Some("type") => *kind = self.string_value(MAX_NAME_BYTES)?,
                Some("request_id") => hint.request_id = self.id_value()?,
                Some("request") => {
                    self.skip_ws();
                    if self.peek()? == b'{' {
                        self.request_members(hint)?;
                    } else {
                        self.skip_value()?;
                    }
                }
                _ => self.skip_value()?,
            }
            if !self.next_member()? {
                return Ok(());
            }
        }
    }

    /// The members of `request`: only `subtype` and `tool_name` are read.
    fn request_members(&mut self, hint: &mut ControlRequestHint) -> Step<()> {
        self.expect(b'{')?;
        // Whatever an earlier duplicate said, the last one wins (as in a full parse).
        loop {
            self.skip_ws();
            if self.peek()? == b'}' {
                self.i += 1;
                return Ok(());
            }
            let key = self.key()?;
            match key.as_deref() {
                Some("subtype") => hint.subtype = self.string_value(MAX_NAME_BYTES)?,
                Some("tool_name") => hint.tool_name = self.string_value(MAX_NAME_BYTES)?,
                _ => self.skip_value()?,
            }
            if !self.next_member()? {
                self.i += 1; // the closing brace
                return Ok(());
            }
        }
    }

    /// After a member's value: `true` at a comma (another member follows), `false` at
    /// the closing brace (not consumed). Anything else stops the scan.
    fn next_member(&mut self) -> Step<bool> {
        self.skip_ws();
        match self.peek()? {
            b',' => {
                self.i += 1;
                Ok(true)
            }
            b'}' => Ok(false),
            _ => Err(Stop),
        }
    }

    /// An object key and its colon. `None` for a key too long to be one we look for.
    fn key(&mut self) -> Step<Option<String>> {
        let raw = self.string_raw()?;
        self.skip_ws();
        self.expect(b':')?;
        self.skip_ws();
        Ok(decode(raw, MAX_KEY_BYTES))
    }

    /// A string value, decoded; `None` for a value that is not a string (skipped),
    /// is too long, or does not decode.
    fn string_value(&mut self, max: usize) -> Step<Option<String>> {
        if self.peek()? != b'"' {
            self.skip_value()?;
            return Ok(None);
        }
        Ok(decode(self.string_raw()?, max))
    }

    /// A `request_id` value: a string or a number; anything else is skipped and is no id.
    fn id_value(&mut self) -> Step<Option<Value>> {
        match self.peek()? {
            b'"' => Ok(decode(self.string_raw()?, MAX_ID_BYTES).map(Value::String)),
            b'-' | b'0'..=b'9' => {
                let start = self.i;
                self.skip_scalar()?;
                Ok(serde_json::from_slice::<Value>(&self.b[start..self.i])
                    .ok()
                    .filter(Value::is_number))
            }
            _ => {
                self.skip_value()?;
                Ok(None)
            }
        }
    }

    /// The raw bytes between a string's quotes (escapes undecoded). The scan stops
    /// if the string is not closed.
    fn string_raw(&mut self) -> Step<&'a [u8]> {
        self.expect(b'"')?;
        let start = self.i;
        loop {
            match self.b.get(self.i).ok_or(Stop)? {
                b'"' => {
                    let raw = &self.b[start..self.i];
                    self.i += 1;
                    return Ok(raw);
                }
                b'\\' => self.i += 2,
                _ => self.i += 1,
            }
        }
    }

    /// Step over one value of any kind, however deeply it nests, without recursion.
    fn skip_value(&mut self) -> Step<()> {
        match self.peek()? {
            b'"' => self.string_raw().map(|_| ()),
            b'{' | b'[' => {
                let mut depth = 0usize;
                loop {
                    match self.b.get(self.i).ok_or(Stop)? {
                        b'"' => {
                            self.string_raw()?;
                            continue;
                        }
                        b'{' | b'[' => depth += 1,
                        b'}' | b']' => depth -= 1,
                        _ => {}
                    }
                    self.i += 1;
                    if depth == 0 {
                        return Ok(());
                    }
                }
            }
            _ => self.skip_scalar(),
        }
    }

    /// Step over a number, `true`, `false` or `null`. It must be followed by a
    /// delimiter: a number cut off mid-digits is not a number we know.
    fn skip_scalar(&mut self) -> Step<()> {
        loop {
            match self.b.get(self.i).ok_or(Stop)? {
                b',' | b'}' | b']' | b' ' | b'\t' | b'\r' | b'\n' => return Ok(()),
                _ => self.i += 1,
            }
        }
    }

    fn skip_ws(&mut self) {
        while matches!(self.b.get(self.i), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.i += 1;
        }
    }

    fn peek(&self) -> Step<u8> {
        self.b.get(self.i).copied().ok_or(Stop)
    }

    fn expect(&mut self, c: u8) -> Step<()> {
        if self.peek()? == c {
            self.i += 1;
            Ok(())
        } else {
            Err(Stop)
        }
    }
}

/// The text of a string whose raw (still escaped) bytes are `raw`; `None` if it is
/// longer than `max` or not valid JSON string content.
fn decode(raw: &[u8], max: usize) -> Option<String> {
    if raw.len() > max {
        return None;
    }
    if !raw.contains(&b'\\') {
        return std::str::from_utf8(raw).ok().map(str::to_owned);
    }
    let mut quoted = Vec::with_capacity(raw.len() + 2);
    quoted.push(b'"');
    quoted.extend_from_slice(raw);
    quoted.push(b'"');
    serde_json::from_slice(&quoted).ok()
}
