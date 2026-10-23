//! `AskUserQuestion` (AP2c): reading the tool's questions and building the reply
//! the CLI accepts for them.
//!
//! **The reply shape** (read from the CLI's own tool code, 2.1.308; the PR body
//! says what is and is not verified against a live run): an allow reply whose
//! `updatedInput` is the original input plus `answers`, an object keyed by the
//! question's exact text. The value is a string: the chosen option's label; for
//! a multi-select question the labels joined with `", "`; for the free-text
//! "Other" answer (which the CLI always offers and never lists among the
//! options) the typed text.
//!
//! The reply drops any `annotations`, `response`, `afkTimeoutMs` or `followUp` the agent put in its
//! own call (the CLI reads those as the person's words), and sets `answers` itself.
//!
//! The daemon builds that input itself from the *held* request's input, so a
//! caller can only choose among what the agent asked: an unknown question, a
//! label that is not an option, a missing question or an oversize text is
//! refused ([`AnswerError`]) and nothing is sent.

use serde_json::{Map, Value};

use super::wire::{QuestionAnswer, MAX_OPTIONS, MAX_OTHER_CHARS, MAX_QUESTIONS};
use crate::data::work::is_invisible;

/// Input fields the CLI's `AskUserQuestion` reads as the person's own words or state (answers, notes
/// on an answer, a free-form reply, an away-from-keyboard timeout, a request for more questions).
/// An agent can write them into its call; the reply never carries them through.
const HUMAN_OWNED_FIELDS: [&str; 5] = ["answers", "annotations", "response", "afkTimeoutMs", "followUp"];

/// One option of a question.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskOption {
    pub label: String,
    pub description: String,
}

/// One question of an `AskUserQuestion` request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskQuestion {
    pub question: String,
    pub header: String,
    pub multi_select: bool,
    pub options: Vec<AskOption>,
}

/// Why an answer does not fit the request. Nothing is sent for any of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnswerError {
    /// The input is not an `AskUserQuestion` input this build can answer.
    NotAnswerable,
    /// An answer names a question the request does not contain.
    UnknownQuestion,
    /// A question was answered more than once.
    DuplicateAnswer,
    /// A question was not answered.
    MissingAnswer,
    /// A selected label is not one of the question's options.
    UnknownLabel,
    /// A label was selected twice for one question.
    DuplicateLabel,
    /// Nothing was chosen for a question.
    NoSelection,
    /// More was chosen than the question allows.
    TooManySelections,
    /// The free-text answer is longer than [`MAX_OTHER_CHARS`].
    OtherTooLong,
    /// The free-text answer is empty once cleaned.
    EmptyOther,
}

/// The questions of an answerable `AskUserQuestion` input, or `None` when the
/// input is not one this build can answer (so the card offers Deny only).
///
/// Answerable: 1 to 4 questions; each a non-empty, request-unique `question`
/// text with 2 to 4 options that carry non-empty, question-unique labels. A
/// `kind` other than `"choice"` (the CLI's text and number questions) makes
/// the whole input not answerable.
pub fn parse_questions(input: &Value) -> Option<Vec<AskQuestion>> {
    let raw = input.get("questions")?.as_array()?;
    if raw.is_empty() || raw.len() > MAX_QUESTIONS {
        return None;
    }
    let mut questions: Vec<AskQuestion> = Vec::with_capacity(raw.len());
    for q in raw {
        let q = q.as_object()?;
        if q.get("kind").is_some_and(|k| k.as_str() != Some("choice")) {
            return None;
        }
        let question = q.get("question")?.as_str()?.to_owned();
        if question.is_empty() || questions.iter().any(|seen| seen.question == question) {
            return None;
        }
        let raw_options = q.get("options")?.as_array()?;
        if raw_options.len() < 2 || raw_options.len() > MAX_OPTIONS {
            return None;
        }
        let mut options: Vec<AskOption> = Vec::with_capacity(raw_options.len());
        for o in raw_options {
            let o = o.as_object()?;
            let label = o.get("label")?.as_str()?.to_owned();
            if label.is_empty() || options.iter().any(|seen| seen.label == label) {
                return None;
            }
            let description = o.get("description").and_then(Value::as_str).unwrap_or("").to_owned();
            options.push(AskOption { label, description });
        }
        questions.push(AskQuestion {
            question,
            header: q.get("header").and_then(Value::as_str).unwrap_or("").to_owned(),
            multi_select: q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
            options,
        });
    }
    Some(questions)
}

/// The `updatedInput` for an allow reply: the original `input` plus `answers`.
///
/// Every question must be answered exactly once, from its own options (or free
/// text); see [`AnswerError`] for what is refused.
pub fn updated_input(input: &Value, answers: &[QuestionAnswer]) -> Result<Value, AnswerError> {
    let questions = parse_questions(input).ok_or(AnswerError::NotAnswerable)?;
    let mut values: Vec<Option<String>> = vec![None; questions.len()];
    for answer in answers {
        let index = questions
            .iter()
            .position(|q| q.question == answer.question)
            .ok_or(AnswerError::UnknownQuestion)?;
        if values[index].is_some() {
            return Err(AnswerError::DuplicateAnswer);
        }
        values[index] = Some(answer_value(&questions[index], answer)?);
    }
    let mut map = Map::new();
    for (question, value) in questions.iter().zip(values) {
        map.insert(question.question.clone(), Value::String(value.ok_or(AnswerError::MissingAnswer)?));
    }
    let mut updated = input.clone();
    let fields = updated.as_object_mut().ok_or(AnswerError::NotAnswerable)?;
    // The fields the CLI treats as the person's own words are the person's alone: whatever the
    // agent put there is dropped, so it can't pass its text off as something the user wrote.
    for key in HUMAN_OWNED_FIELDS {
        fields.remove(key);
    }
    fields.insert("answers".to_owned(), Value::Object(map));
    Ok(updated)
}

/// The string the CLI stores for one question: the chosen labels in the
/// question's option order, then the free text, joined with `", "`.
fn answer_value(question: &AskQuestion, answer: &QuestionAnswer) -> Result<String, AnswerError> {
    if answer.selected.len() > question.options.len() {
        return Err(AnswerError::TooManySelections);
    }
    let mut chosen = vec![false; question.options.len()];
    for label in &answer.selected {
        let index = question
            .options
            .iter()
            .position(|o| &o.label == label)
            .ok_or(AnswerError::UnknownLabel)?;
        if chosen[index] {
            return Err(AnswerError::DuplicateLabel);
        }
        chosen[index] = true;
    }
    let other = match &answer.other {
        None => None,
        Some(raw) => {
            if raw.chars().count() > MAX_OTHER_CHARS {
                return Err(AnswerError::OtherTooLong);
            }
            let cleaned = clean_free_text(raw);
            if cleaned.is_empty() {
                return Err(AnswerError::EmptyOther);
            }
            Some(cleaned)
        }
    };
    let total = answer.selected.len() + usize::from(other.is_some());
    if total == 0 {
        return Err(AnswerError::NoSelection);
    }
    if !question.multi_select && total > 1 {
        return Err(AnswerError::TooManySelections);
    }
    let mut parts: Vec<String> = question
        .options
        .iter()
        .zip(&chosen)
        .filter(|(_, chosen)| **chosen)
        .map(|(option, _)| option.label.clone())
        .collect();
    parts.extend(other);
    Ok(parts.join(", "))
}

/// Free text for the agent: line breaks become spaces, invisible characters are
/// removed, the ends are trimmed.
fn clean_free_text(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        // Line breaks first: `is_invisible` counts them as control characters.
        .map(|c| if matches!(c, '\n' | '\r') { ' ' } else { c })
        .filter(|c| !is_invisible(*c))
        .collect();
    cleaned.trim().to_owned()
}
