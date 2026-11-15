//! The wire types of the hand-off verbs (preview, notify, start a session,
//! link). Answers carry a code and never a message: the Mac words each code.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Who a preview is for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PreviewTarget {
    /// An open focus.
    Focus { tag: String },
    /// A session that does not exist yet (Start a session…).
    NewSession { new_session: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastTold {
    pub name: String,
    pub at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewOk {
    /// The message, exactly as it will be sent.
    pub text: String,
    /// Lowercase hex SHA-256 of `text`.
    pub digest: String,
    /// The focus it goes to (`""` for a new session).
    pub target_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_told: Option<LastTold>,
    /// For a new session: the folder the closed owner worked in, when it is
    /// still a checkout of this PR's repo (or an open focus's checkout is).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_folder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_agent: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartOk {
    pub tag: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredPrError {
    pub code: String,
}

/// `{"status":"ok","value":…}` or `{"status":"err","value":{"code":…}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", content = "value", rename_all = "snake_case")]
pub enum AuthoredPrResult<T> {
    Ok(T),
    Err(AuthoredPrError),
}

impl<T> AuthoredPrResult<T> {
    pub fn err(code: &str) -> Self {
        AuthoredPrResult::Err(AuthoredPrError { code: code.into() })
    }
}

/// An answer with nothing to report but success.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Done {}
