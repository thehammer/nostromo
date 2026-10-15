//! Item operations and atomic batches (contract §4).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::diff::diff;
use super::format::{
    is_reserved_tail_token, parse, reread, serialise_item, splice, validate_command_text,
    Malformed, ParsedBoard, LINKS_PREFIX, MAX_OWNER_CHARS, TAIL_CHARS,
};
use super::model::{
    generate_id, is_valid_id, Author, Board, Change, Env, Item, Kind, Link, LogLine, Stamp, Status,
};

/// Size caps: a batch that grows a board past either is refused.
pub const MAX_BOARD_BYTES: usize = 256 * 1024;
pub const MAX_ITEMS: usize = 500;
/// Ops in one batch; a longer batch is refused `invalid_args` before any op runs.
pub const MAX_BATCH_OPS: usize = 200;
/// Longest item text, link text and Log line, in characters.
pub const MAX_LINE_CHARS: usize = 500;
/// Longest note, in characters.
pub const MAX_NOTE_CHARS: usize = 8_000;
/// Longest command, in characters.
pub const MAX_COMMAND_CHARS: usize = 4_000;

/// A link given to `upsert`: bare text (`"PR #253"`) or `{text, url}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LinkInput {
    Text(String),
    Full {
        text: String,
        #[serde(default)]
        url: Option<String>,
    },
}

/// `upsert` fields. Only given fields change. For `owner`, `note`, `command`
/// and `env`, an empty string clears the field; `links: []` clears links.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Upsert {
    /// Omitted: a new item with a generated id.
    #[serde(default)]
    pub id: Option<String>,
    /// Section id or title. Required to create (else the first section);
    /// on an existing item, moves it to the end of that section.
    #[serde(default)]
    pub section: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub links: Option<Vec<LinkInput>>,
    /// `item` or `command`.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    /// `prod|canada|demo|staging|local|unset`.
    #[serde(default)]
    pub env: Option<String>,
}

/// One operation. Deserialises from the tool's `{"op": "status", ...}` shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    Upsert(Upsert),
    Status {
        id: String,
        status: String,
    },
    Remove {
        id: String,
    },
    Move {
        id: String,
        section: String,
        #[serde(default)]
        before: Option<String>,
        #[serde(default)]
        after: Option<String>,
    },
    Log {
        text: String,
    },
}

/// A refused batch. `index` is the failing op's position in the batch.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum OpError {
    #[error("op {index}: unknown item {id}")]
    UnknownItem { index: usize, id: String },
    #[error("op {index}: invalid status {value:?}")]
    InvalidStatus { index: usize, value: String },
    #[error("op {index}: invalid arguments: {reason}")]
    InvalidArgs { index: usize, reason: String },
    #[error("board too large: {bytes} bytes, {items} items")]
    BoardTooLarge { bytes: usize, items: usize },
}

impl OpError {
    /// The stable error code (`unknown_item`, `invalid_status`,
    /// `invalid_args`, `board_too_large`).
    pub fn code(&self) -> &'static str {
        match self {
            OpError::UnknownItem { .. } => "unknown_item",
            OpError::InvalidStatus { .. } => "invalid_status",
            OpError::InvalidArgs { .. } => "invalid_args",
            OpError::BoardTooLarge { .. } => "board_too_large",
        }
    }
}

/// Applies `ops` in order to a copy of `board`, all or none. Returns the new
/// board and its changes (attributed to `author`, at `at.now`, `seq` 0).
/// More than [`MAX_BATCH_OPS`] ops is refused before any runs; the size and
/// item caps are checked after every op, so an oversized batch stops at the
/// op that crosses them.
pub fn apply_batch(
    board: &Board,
    ops: &[Op],
    author: &Author,
    at: Stamp,
) -> Result<(Board, Vec<Change>), OpError> {
    if ops.len() > MAX_BATCH_OPS {
        return Err(OpError::InvalidArgs {
            index: MAX_BATCH_OPS,
            reason: format!(
                "a batch holds at most {MAX_BATCH_OPS} ops, got {}",
                ops.len()
            ),
        });
    }
    let mut next = board.clone();
    let mut apply = Apply {
        board: &mut next,
        index: 0,
        at,
        size: board.byte_len as i64,
        start_bytes: board.byte_len,
        start_items: board.items.len(),
    };
    for (index, op) in ops.iter().enumerate() {
        apply.index = index;
        apply.op(op)?;
        apply.check_size()?;
    }
    let changes = diff(board, &next, author, at.now);
    Ok((next, changes))
}

/// One op applied to the working copy.
struct Apply<'a> {
    board: &'a mut Board,
    index: usize,
    at: Stamp,
    /// The file size as the board would be written now: the original size
    /// plus every op's change to an item's or Log line's written size.
    size: i64,
    start_bytes: usize,
    start_items: usize,
}

impl Apply<'_> {
    /// Refuses a batch that has grown the board past a cap; a board already
    /// over a cap can still shrink or change in place.
    fn check_size(&self) -> Result<(), OpError> {
        let size = self.size.max(0) as usize;
        let items = self.board.items.len();
        let grows = items > self.start_items || size > self.start_bytes;
        if grows && (size > MAX_BOARD_BYTES || items > MAX_ITEMS) {
            return Err(OpError::BoardTooLarge { bytes: size, items });
        }
        Ok(())
    }

    fn item_len(&self, item: &Item) -> i64 {
        serialise_item(item, self.at, "\n").len() as i64
    }

    fn op(&mut self, op: &Op) -> Result<(), OpError> {
        match op {
            Op::Upsert(upsert) => self.upsert(upsert),
            Op::Status { id, status } => {
                let status = self.status(status)?;
                let pos = self.find(id)?;
                self.edit(pos, |item| set(&mut item.status, status));
                Ok(())
            }
            Op::Remove { id } => {
                let pos = self.find(id)?;
                let item = self.board.items.remove(pos);
                self.size -= self.item_len(&item);
                Ok(())
            }
            Op::Move {
                id,
                section,
                before,
                after,
            } => self.move_item(id, section, before.as_deref(), after.as_deref()),
            Op::Log { text } => {
                let text = self.single_line("log text", text, MAX_LINE_CHARS)?;
                let time = self.at.hhmm(self.at.now);
                self.size += (time.len() + text.len() + 4) as i64;
                self.board.log.push(LogLine { time, text });
                Ok(())
            }
        }
    }

    fn upsert(&mut self, u: &Upsert) -> Result<(), OpError> {
        let fields = self.fields(u)?;
        let existing = match &u.id {
            Some(id) if !is_valid_id(id) => return Err(self.invalid(format!("invalid id {id:?}"))),
            Some(id) => self.board.items.iter().position(|i| &i.id == id),
            None => None,
        };
        match existing {
            Some(pos) => self.update(pos, &fields, u.section.as_deref()),
            None => self.create(u, &fields),
        }
    }

    /// Edits the item at `pos`; a given `section` moves it to that section's end.
    fn update(
        &mut self,
        pos: usize,
        fields: &Fields,
        section: Option<&str>,
    ) -> Result<(), OpError> {
        self.edit(pos, |item| fields.apply(item));
        self.check_command(fields, &self.board.items[pos])?;
        if let Some(section) = section {
            let section = self.section(section)?;
            if self.board.items[pos].section != section {
                let mut item = self.board.items.remove(pos);
                item.section = section;
                item.updated_at = Some(self.at.now);
                let at = self.end_of_section(&item.section);
                self.board.items.insert(at, item);
            }
        }
        Ok(())
    }

    /// Adds a new item (generated id unless `u.id` is given) at the end of its section.
    fn create(&mut self, u: &Upsert, fields: &Fields) -> Result<(), OpError> {
        let section = match &u.section {
            Some(section) => self.section(section)?,
            None => match self.board.sections.first() {
                Some(first) => first.id.clone(),
                None => return Err(self.invalid("the board has no sections".to_string())),
            },
        };
        let Some(text) = &fields.text else {
            return Err(self.invalid("text is required to create an item".to_string()));
        };
        let id = match &u.id {
            Some(id) => id.clone(),
            None => {
                let taken: HashSet<String> =
                    self.board.items.iter().map(|i| i.id.clone()).collect();
                generate_id(text, &taken)
            }
        };
        let mut item = Item::new(&id, &section, text);
        fields.apply(&mut item);
        self.check_command(fields, &item)?;
        item.updated_at = Some(self.at.now);
        self.size += self.item_len(&item);
        let at = self.end_of_section(&section);
        self.board.items.insert(at, item);
        Ok(())
    }

    /// A command item needs a command (else its note could read back as one).
    fn check_command(&self, fields: &Fields, item: &Item) -> Result<(), OpError> {
        let touched = fields.kind.is_some() || fields.command.is_some();
        if touched && item.kind == Kind::Command && item.command.is_none() {
            return Err(self.invalid("a command item needs a command".to_string()));
        }
        Ok(())
    }

    fn move_item(
        &mut self,
        id: &str,
        section: &str,
        before: Option<&str>,
        after: Option<&str>,
    ) -> Result<(), OpError> {
        let pos = self.find(id)?;
        let section = self.section(section)?;
        if before.is_some() && after.is_some() {
            return Err(self.invalid("give before or after, not both".to_string()));
        }
        let old_order: Vec<String> = self.board.items.iter().map(|i| i.id.clone()).collect();
        let old_section = self.board.items[pos].section.clone();
        let mut item = self.board.items.remove(pos);
        item.section = section.clone();
        let insert_at = match before.or(after) {
            Some(neighbour) => {
                let n = self.neighbour(neighbour, id, &section)?;
                if before.is_some() {
                    n
                } else {
                    n + 1
                }
            }
            None => self.end_of_section(&section),
        };
        self.board.items.insert(insert_at, item);
        let moved =
            old_section != section || self.board.items.iter().map(|i| &i.id).ne(old_order.iter());
        if moved {
            self.board.items[insert_at].updated_at = Some(self.at.now);
        }
        Ok(())
    }

    /// Position of the `before`/`after` neighbour of a move (the item being
    /// moved is already removed); it must exist and be in `section`.
    fn neighbour(&self, neighbour: &str, moving: &str, section: &str) -> Result<usize, OpError> {
        let Some(n) = self.board.items.iter().position(|i| i.id == neighbour) else {
            return Err(if neighbour == moving {
                self.invalid("an item can't move relative to itself".to_string())
            } else {
                OpError::UnknownItem {
                    index: self.index,
                    id: neighbour.to_string(),
                }
            });
        };
        if self.board.items[n].section != section {
            return Err(self.invalid(format!("{neighbour} is not in section {section}")));
        }
        Ok(n)
    }

    /// Applies `change` to the item at `pos`; bumps `updated_at` if it changed
    /// anything.
    fn edit(&mut self, pos: usize, change: impl FnOnce(&mut Item) -> bool) {
        let before = self.item_len(&self.board.items[pos]);
        let item = &mut self.board.items[pos];
        if change(item) {
            item.updated_at = Some(self.at.now);
        }
        let after = self.item_len(&self.board.items[pos]);
        self.size += after - before;
    }

    /// Index where a new item of `section` goes: after the section's last
    /// item, else before the first item of a later section.
    fn end_of_section(&self, section: &str) -> usize {
        if let Some(last) = self.board.items.iter().rposition(|i| i.section == section) {
            return last + 1;
        }
        let order = |id: &str| self.board.sections.iter().position(|s| s.id == id);
        let mine = order(section);
        self.board
            .items
            .iter()
            .position(|i| order(&i.section) > mine)
            .unwrap_or(self.board.items.len())
    }

    fn find(&self, id: &str) -> Result<usize, OpError> {
        self.board
            .items
            .iter()
            .position(|i| i.id == id)
            .ok_or_else(|| OpError::UnknownItem {
                index: self.index,
                id: id.to_string(),
            })
    }

    fn section(&self, reference: &str) -> Result<String, OpError> {
        self.board
            .resolve_section(reference)
            .map(|s| s.id.clone())
            .ok_or_else(|| self.invalid(format!("unknown section {reference:?}")))
    }

    fn status(&self, value: &str) -> Result<Status, OpError> {
        Status::from_wire(value).ok_or_else(|| OpError::InvalidStatus {
            index: self.index,
            value: value.to_string(),
        })
    }

    fn invalid(&self, reason: String) -> OpError {
        OpError::InvalidArgs {
            index: self.index,
            reason,
        }
    }

    /// Trimmed, non-empty, at most `max` characters, one line, no control
    /// characters, no `<!--`.
    fn single_line(&self, field: &str, value: &str, max: usize) -> Result<String, OpError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(self.invalid(format!("{field} is empty")));
        }
        if value.chars().any(char::is_control) {
            return Err(self.invalid(format!(
                "{field} must be one line with no control characters"
            )));
        }
        if value.contains("<!--") {
            return Err(self.invalid(format!("{field} must not contain <!--")));
        }
        self.within(field, value, max)?;
        Ok(value.to_string())
    }

    /// `value` is at most `max` characters.
    fn within(&self, field: &str, value: &str, max: usize) -> Result<(), OpError> {
        let len = value.chars().count();
        if len > max {
            return Err(self.invalid(format!(
                "{field} is {len} characters, over the {max}-character limit"
            )));
        }
        Ok(())
    }

    /// Validates every given upsert field up front.
    fn fields(&self, u: &Upsert) -> Result<Fields, OpError> {
        let mut f = Fields {
            text: u
                .text
                .as_deref()
                .map(|t| self.single_line("text", t, MAX_LINE_CHARS))
                .transpose()?,
            status: u.status.as_deref().map(|s| self.status(s)).transpose()?,
            ..Fields::default()
        };
        if let Some(owner) = &u.owner {
            f.owner = Some(self.owner(owner)?);
        }
        if let Some(note) = &u.note {
            f.note = Some(self.note(note)?);
        }
        if let Some(links) = &u.links {
            f.links = Some(
                links
                    .iter()
                    .map(|l| self.link(l))
                    .collect::<Result<_, _>>()?,
            );
        }
        if let Some(kind) = &u.kind {
            f.kind = Some(
                Kind::from_wire(kind)
                    .ok_or_else(|| self.invalid(format!("invalid kind {kind:?}")))?,
            );
        }
        if let Some(command) = &u.command {
            if let Err(e) = validate_command_text(command) {
                return Err(self.invalid(format!("command: {e}")));
            }
            let command = command.trim_matches('\n');
            self.within("command", command, MAX_COMMAND_CHARS)?;
            f.command = Some((!command.trim().is_empty()).then(|| command.to_string()));
        }
        if let Some(env) = &u.env {
            f.env = Some(match env.trim() {
                "" => None,
                e => Some(
                    Env::from_wire(e).ok_or_else(|| self.invalid(format!("invalid env {e:?}")))?,
                ),
            });
        }
        Ok(f)
    }

    fn owner(&self, owner: &str) -> Result<Option<String>, OpError> {
        if owner.trim().is_empty() {
            return Ok(None);
        }
        let owner = self.single_line("owner", owner, MAX_OWNER_CHARS)?;
        if owner.chars().count() > MAX_OWNER_CHARS
            || owner.contains(TAIL_CHARS)
            || is_reserved_tail_token(&owner)
        {
            return Err(self.invalid(format!(
                "owner {owner:?} can't be written in the file's tail"
            )));
        }
        Ok(Some(owner))
    }

    fn note(&self, note: &str) -> Result<Option<String>, OpError> {
        if note
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
        {
            return Err(self.invalid("note has control characters".to_string()));
        }
        // As the file stores it: no trailing whitespace, no blank edges.
        let lines: Vec<&str> = note.split('\n').map(str::trim_end).collect();
        let note = lines.join("\n");
        let note = note.trim_matches('\n');
        if note.is_empty() {
            return Ok(None);
        }
        self.within("note", note, MAX_NOTE_CHARS)?;
        if note.lines().any(|l| l.starts_with(LINKS_PREFIX)) {
            return Err(self.invalid("a note line can't start with \"Links: \"".to_string()));
        }
        Ok(Some(note.to_string()))
    }

    fn link(&self, input: &LinkInput) -> Result<Link, OpError> {
        let (text, url) = match input {
            LinkInput::Text(text) => (text.as_str(), None),
            LinkInput::Full { text, url } => (text.as_str(), url.as_deref()),
        };
        let text = self.single_line("link text", text, MAX_LINE_CHARS)?;
        if text.contains(TAIL_CHARS) || text.contains(['[', ']']) {
            return Err(self.invalid(format!("link text {text:?} can't contain —, ·, [ or ]")));
        }
        if let Some(url) = url {
            if url
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || c == '(' || c == ')')
            {
                return Err(self.invalid(format!("link url {url:?} is not a plain url")));
            }
        }
        Ok(Link::new(&text, url))
    }
}

/// Validated upsert fields; `None` = not given. Inner `None` clears.
#[derive(Default)]
struct Fields {
    text: Option<String>,
    status: Option<Status>,
    owner: Option<Option<String>>,
    note: Option<Option<String>>,
    links: Option<Vec<Link>>,
    kind: Option<Kind>,
    command: Option<Option<String>>,
    env: Option<Option<Env>>,
}

impl Fields {
    /// Sets the given fields; `true` if anything changed. Kind and command
    /// follow each other: setting a command makes the item a command,
    /// clearing it (or setting kind `item`) makes it a plain item.
    fn apply(&self, item: &mut Item) -> bool {
        let mut changed = false;
        if let Some(text) = &self.text {
            changed |= set(&mut item.text, text.clone());
        }
        if let Some(status) = self.status {
            changed |= set(&mut item.status, status);
        }
        if let Some(owner) = &self.owner {
            changed |= set(&mut item.owner, owner.clone());
        }
        if let Some(note) = &self.note {
            changed |= set(&mut item.note, note.clone());
        }
        if let Some(links) = &self.links {
            changed |= set(&mut item.links, links.clone());
        }
        if let Some(command) = &self.command {
            changed |= set(&mut item.command, command.clone());
            if self.kind.is_none() {
                let kind = if command.is_some() {
                    Kind::Command
                } else {
                    Kind::Item
                };
                changed |= set(&mut item.kind, kind);
            }
        }
        if let Some(kind) = self.kind {
            changed |= set(&mut item.kind, kind);
            if kind == Kind::Item {
                changed |= set(&mut item.command, None);
            }
        }
        if let Some(env) = self.env {
            changed |= set(&mut item.env, env);
        }
        changed
    }
}

/// Assigns `value`; `true` if it differed.
fn set<T: PartialEq>(slot: &mut T, value: T) -> bool {
    if *slot == value {
        return false;
    }
    *slot = value;
    true
}

/// A write that failed: the file is unreadable, or the batch was refused.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WriteError {
    #[error(transparent)]
    Malformed(#[from] Malformed),
    #[error(transparent)]
    Op(#[from] OpError),
}

/// The result of [`apply_to_file`].
#[derive(Debug, Clone, PartialEq)]
pub struct Applied {
    /// The new file bytes.
    pub bytes: Vec<u8>,
    /// `bytes` parsed: the board as written (human lines that just got a
    /// marker carry its time).
    pub parsed: ParsedBoard,
    /// `parsed.board`.
    pub board: Board,
    pub changes: Vec<Change>,
}

/// The whole write path over bytes: parse, apply the batch, splice with
/// marker assignment, and check the new bytes read back as the batch's
/// board. An empty batch only assigns markers to human lines. A batch whose
/// result can't be written faithfully (say, an item placed inside a prose
/// section's unclosed code fence) is refused `invalid_args`.
pub fn apply_to_file(
    bytes: &[u8],
    ops: &[Op],
    author: &Author,
    at: Stamp,
) -> Result<Applied, WriteError> {
    let parsed = parse(bytes)?;
    let (board, changes) = apply_batch(&parsed.board, ops, author, at)?;
    let bytes = splice(&parsed, &board, at, true);
    let reparsed = reread(&bytes, &board).map_err(|bad| {
        let index = ops
            .iter()
            .rposition(|op| bad.item_id.is_some() && op_item_id(op) == bad.item_id.as_deref())
            .unwrap_or(ops.len().saturating_sub(1));
        OpError::InvalidArgs {
            index,
            reason: format!("{bad}"),
        }
    })?;
    Ok(Applied {
        bytes,
        board: reparsed.board.clone(),
        parsed: reparsed,
        changes,
    })
}

/// The item an op names, if any.
fn op_item_id(op: &Op) -> Option<&str> {
    match op {
        Op::Upsert(u) => u.id.as_deref(),
        Op::Status { id, .. } | Op::Remove { id } | Op::Move { id, .. } => Some(id),
        Op::Log { .. } => None,
    }
}
