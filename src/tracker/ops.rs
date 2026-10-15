//! Item operations and atomic batches (contract §4).

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::diff::diff;
use super::format::{
    is_reserved_tail_token, LINKS_PREFIX, MAX_OWNER_CHARS, parse, serialise_item, splice, validate_command_text, Malformed,
};
use super::model::{
    generate_id, is_valid_id, Author, Board, Change, Env, Item, Kind, Link, LogLine, Stamp, Status,
};

/// Size caps: a batch that grows a board past either is refused.
pub const MAX_BOARD_BYTES: usize = 256 * 1024;
pub const MAX_ITEMS: usize = 500;

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
pub fn apply_batch(
    board: &Board,
    ops: &[Op],
    author: &Author,
    at: Stamp,
) -> Result<(Board, Vec<Change>), OpError> {
    let mut next = board.clone();
    for (index, op) in ops.iter().enumerate() {
        Apply {
            board: &mut next,
            index,
            at,
        }
        .op(op)?;
    }
    check_size(board, &next, at)?;
    let changes = diff(board, &next, author, at.now);
    Ok((next, changes))
}

/// Refuses a batch that grows the board past a cap. The new size is
/// estimated from the old file size plus the size difference of every
/// changed item and Log line as it would be written.
fn check_size(old: &Board, new: &Board, at: Stamp) -> Result<(), OpError> {
    let item_len = |item: &Item| serialise_item(item, at, "\n").len() as i64;
    let mut size = old.byte_len as i64;
    let old_items: HashMap<&str, &Item> = old.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let new_ids: HashSet<&str> = new.items.iter().map(|i| i.id.as_str()).collect();
    for item in &new.items {
        match old_items.get(item.id.as_str()) {
            Some(prev) if *prev == item => {}
            Some(prev) => size += item_len(item) - item_len(prev),
            None => size += item_len(item),
        }
    }
    for item in old.items.iter().filter(|i| !new_ids.contains(i.id.as_str())) {
        size -= item_len(item);
    }
    for line in new.log.iter().skip(old.log.len()) {
        size += (line.time.len() + line.text.len() + 4) as i64;
    }
    let size = size.max(0) as usize;
    let grows = new.items.len() > old.items.len() || size > old.byte_len;
    if grows && (size > MAX_BOARD_BYTES || new.items.len() > MAX_ITEMS) {
        return Err(OpError::BoardTooLarge {
            bytes: size,
            items: new.items.len(),
        });
    }
    Ok(())
}

/// One op applied to the working copy.
struct Apply<'a> {
    board: &'a mut Board,
    index: usize,
    at: Stamp,
}

impl Apply<'_> {
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
                self.board.items.remove(pos);
                Ok(())
            }
            Op::Move {
                id,
                section,
                before,
                after,
            } => self.move_item(id, section, before.as_deref(), after.as_deref()),
            Op::Log { text } => {
                let text = self.single_line("text", text)?;
                self.board.log.push(LogLine {
                    time: self.at.hhmm(self.at.now),
                    text,
                });
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
    fn update(&mut self, pos: usize, fields: &Fields, section: Option<&str>) -> Result<(), OpError> {
        self.edit(pos, |item| fields.apply(item));
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
                let taken: HashSet<String> = self.board.items.iter().map(|i| i.id.clone()).collect();
                generate_id(text, &taken)
            }
        };
        let mut item = Item::new(&id, &section, text);
        fields.apply(&mut item);
        item.updated_at = Some(self.at.now);
        let at = self.end_of_section(&section);
        self.board.items.insert(at, item);
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
        let moved = old_section != section
            || self.board.items.iter().map(|i| &i.id).ne(old_order.iter());
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
        let item = &mut self.board.items[pos];
        if change(item) {
            item.updated_at = Some(self.at.now);
        }
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

    /// Trimmed, non-empty, one line, no control characters, no `<!--`.
    fn single_line(&self, field: &str, value: &str) -> Result<String, OpError> {
        let value = value.trim();
        if value.is_empty() {
            return Err(self.invalid(format!("{field} is empty")));
        }
        if value.chars().any(char::is_control) {
            return Err(self.invalid(format!("{field} must be one line with no control characters")));
        }
        if value.contains("<!--") {
            return Err(self.invalid(format!("{field} must not contain <!--")));
        }
        Ok(value.to_string())
    }

    /// Validates every given upsert field up front.
    fn fields(&self, u: &Upsert) -> Result<Fields, OpError> {
        let mut f = Fields {
            text: u.text.as_deref().map(|t| self.single_line("text", t)).transpose()?,
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
            f.links = Some(links.iter().map(|l| self.link(l)).collect::<Result<_, _>>()?);
        }
        if let Some(kind) = &u.kind {
            f.kind = Some(Kind::from_wire(kind).ok_or_else(|| self.invalid(format!("invalid kind {kind:?}")))?);
        }
        if let Some(command) = &u.command {
            if let Err(e) = validate_command_text(command) {
                return Err(self.invalid(format!("command: {e}")));
            }
            let command = command.trim_matches('\n');
            f.command = Some((!command.trim().is_empty()).then(|| command.to_string()));
        }
        if let Some(env) = &u.env {
            f.env = Some(match env.trim() {
                "" => None,
                e => Some(Env::from_wire(e).ok_or_else(|| self.invalid(format!("invalid env {e:?}")))?),
            });
        }
        Ok(f)
    }

    fn owner(&self, owner: &str) -> Result<Option<String>, OpError> {
        if owner.trim().is_empty() {
            return Ok(None);
        }
        let owner = self.single_line("owner", owner)?;
        if owner.chars().count() > MAX_OWNER_CHARS
            || owner.contains(" · ")
            || owner.contains(" — ")
            || is_reserved_tail_token(&owner)
        {
            return Err(self.invalid(format!("owner {owner:?} can't be written in the file's tail")));
        }
        Ok(Some(owner))
    }

    fn note(&self, note: &str) -> Result<Option<String>, OpError> {
        if note.chars().any(|c| c.is_control() && c != '\n' && c != '\t') {
            return Err(self.invalid("note has control characters".to_string()));
        }
        let note = note.trim_matches('\n');
        if note.trim().is_empty() {
            return Ok(None);
        }
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
        let text = self.single_line("link text", text)?;
        if text.contains(" · ") || text.contains(['[', ']']) {
            return Err(self.invalid(format!("link text {text:?} can't contain \" · \", [ or ]")));
        }
        if let Some(url) = url {
            if url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '(' || c == ')') {
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
    /// Sets the given fields; `true` if anything changed. A command implies
    /// kind `command` unless a kind is given.
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
            if command.is_some() && self.kind.is_none() {
                changed |= set(&mut item.kind, Kind::Command);
            }
        }
        if let Some(kind) = self.kind {
            changed |= set(&mut item.kind, kind);
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
    /// The board the ops produced (re-parse `bytes` for spans).
    pub board: Board,
    pub changes: Vec<Change>,
}

/// The whole write path over bytes: parse, apply the batch, splice with
/// marker assignment. An empty batch only assigns markers to human lines.
pub fn apply_to_file(
    bytes: &[u8],
    ops: &[Op],
    author: &Author,
    at: Stamp,
) -> Result<Applied, WriteError> {
    let parsed = parse(bytes)?;
    let (board, changes) = apply_batch(&parsed.board, ops, author, at)?;
    let bytes = splice(&parsed, &board, at, true);
    Ok(Applied {
        bytes,
        board,
        changes,
    })
}
