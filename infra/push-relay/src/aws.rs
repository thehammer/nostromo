//! The AWS side: delivery records in DynamoDB and the two secrets in Secrets
//! Manager. The table has partition key `pk` (the anonymous device reference)
//! and sort key `sk`, with TTL on `expires_at`:
//!
//! - `sk = rec#<ts>#<random>`: a delivery record (`kind`, `outcome`, `ts`);
//! - `sk = rate#<window>`: the safety-ceiling counter for one 10-minute window.

use async_trait::async_trait;
use aws_sdk_dynamodb::types::AttributeValue;

use crate::apns::ApnsCredentials;
use crate::model::Record;
use crate::{Secrets, Store};

pub struct DynamoStore {
    client: aws_sdk_dynamodb::Client,
    table: String,
}

impl DynamoStore {
    pub fn new(client: aws_sdk_dynamodb::Client, table: impl Into<String>) -> Self {
        Self {
            client,
            table: table.into(),
        }
    }
}

fn s(v: &str) -> AttributeValue {
    AttributeValue::S(v.to_string())
}

fn n(v: i64) -> AttributeValue {
    AttributeValue::N(v.to_string())
}

fn text(item: &std::collections::HashMap<String, AttributeValue>, key: &str) -> Option<String> {
    item.get(key)?.as_s().ok().cloned()
}

fn number(item: &std::collections::HashMap<String, AttributeValue>, key: &str) -> Option<i64> {
    item.get(key)?.as_n().ok()?.parse().ok()
}

#[async_trait]
impl Store for DynamoStore {
    async fn put_record(&self, r: &Record) -> Result<(), String> {
        let suffix: u32 = r.ts.rem_euclid(1_000_000) as u32 ^ std::process::id();
        self.client
            .put_item()
            .table_name(&self.table)
            .item("pk", s(&r.push_id))
            .item("sk", s(&format!("rec#{:012}#{suffix:08x}", r.ts)))
            .item("ts", n(r.ts))
            .item("kind", s(&r.kind))
            .item("outcome", s(&r.outcome))
            .item("expires_at", n(r.expires_at))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn records(&self, push_id: &str) -> Result<Vec<Record>, String> {
        let mut out = Vec::new();
        let mut start = None;
        loop {
            let page = self
                .client
                .query()
                .table_name(&self.table)
                .key_condition_expression("pk = :p AND begins_with(sk, :r)")
                .expression_attribute_values(":p", s(push_id))
                .expression_attribute_values(":r", s("rec#"))
                .set_exclusive_start_key(start.take())
                .send()
                .await
                .map_err(|e| e.to_string())?;
            for item in page.items() {
                if let (Some(ts), Some(kind), Some(outcome), Some(expires_at)) = (
                    number(item, "ts"),
                    text(item, "kind"),
                    text(item, "outcome"),
                    number(item, "expires_at"),
                ) {
                    out.push(Record {
                        push_id: push_id.to_string(),
                        ts,
                        kind,
                        outcome,
                        expires_at,
                    });
                }
            }
            match page.last_evaluated_key() {
                Some(key) if !key.is_empty() => start = Some(key.clone()),
                _ => break,
            }
        }
        Ok(out)
    }

    async fn bump_rate(&self, push_id: &str, window: i64, expires_at: i64) -> Result<u32, String> {
        let out = self
            .client
            .update_item()
            .table_name(&self.table)
            .key("pk", s(push_id))
            .key("sk", s(&format!("rate#{window}")))
            .update_expression("ADD cnt :one SET expires_at = :e")
            .expression_attribute_values(":one", n(1))
            .expression_attribute_values(":e", n(expires_at))
            .return_values(aws_sdk_dynamodb::types::ReturnValue::UpdatedNew)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        out.attributes()
            .and_then(|a| number(a, "cnt"))
            .map(|c| c.clamp(0, i64::from(u32::MAX)) as u32)
            .ok_or_else(|| "no counter returned".to_string())
    }
}

/// The two secrets, by name or ARN. The daemon token is a bare string; the APNs
/// secret is JSON: `{"key_pem": "...", "key_id": "...", "team_id": "...", "topic": "..."}`.
pub struct SecretsManager {
    client: aws_sdk_secretsmanager::Client,
    daemon_token_secret: String,
    apns_secret: String,
}

impl SecretsManager {
    pub fn new(
        client: aws_sdk_secretsmanager::Client,
        daemon_token_secret: impl Into<String>,
        apns_secret: impl Into<String>,
    ) -> Self {
        Self {
            client,
            daemon_token_secret: daemon_token_secret.into(),
            apns_secret: apns_secret.into(),
        }
    }

    async fn read(&self, id: &str) -> Result<String, String> {
        self.client
            .get_secret_value()
            .secret_id(id)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .secret_string()
            .map(str::to_string)
            .ok_or_else(|| "secret has no string value".to_string())
    }
}

#[async_trait]
impl Secrets for SecretsManager {
    async fn daemon_token(&self) -> Result<String, String> {
        Ok(self.read(&self.daemon_token_secret).await?.trim().to_string())
    }

    async fn apns(&self) -> Result<ApnsCredentials, String> {
        serde_json::from_str(&self.read(&self.apns_secret).await?)
            .map_err(|_| "the APNs secret is not the expected JSON".to_string())
    }
}
