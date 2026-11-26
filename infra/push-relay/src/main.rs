//! The Lambda entry point: a function URL (auth `NONE`; the bearer is checked in
//! code) in front of [`push_relay::Relay`].

use std::collections::BTreeMap;
use std::sync::Arc;

use lambda_http::{service_fn, Body, Error, Request, RequestExt, Response};
use push_relay::aws::{DynamoStore, SecretsManager};
use push_relay::{Relay, SystemClock};

fn env(name: &str) -> Result<String, Error> {
    std::env::var(name).map_err(|_| format!("{name} is not set").into())
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    // Structured logs; the handler logs only the kind, a 6-hex device prefix and
    // the APNs status, never a title, body, host, reference or repository.
    tracing_subscriber::fmt()
        .json()
        .with_ansi(false)
        .without_time()
        .with_max_level(tracing::Level::INFO)
        .init();

    let config = aws_config::load_from_env().await;
    let relay = Arc::new(Relay::new(
        Arc::new(DynamoStore::new(
            aws_sdk_dynamodb::Client::new(&config),
            env("TABLE_NAME")?,
        )),
        Arc::new(SecretsManager::new(
            aws_sdk_secretsmanager::Client::new(&config),
            env("DAEMON_TOKEN_SECRET")?,
            env("APNS_SECRET")?,
        )),
        Arc::new(SystemClock),
    ));

    lambda_http::run(service_fn(move |request: Request| {
        let relay = Arc::clone(&relay);
        async move {
            let query: BTreeMap<String, String> = request
                .query_string_parameters()
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            let body = match request.body() {
                Body::Empty => Vec::new(),
                Body::Text(t) => t.clone().into_bytes(),
                Body::Binary(b) => b.clone(),
            };
            let reply = relay
                .handle(push_relay::Request {
                    method: request.method().as_str().to_string(),
                    path: request.uri().path().to_string(),
                    query,
                    authorization: request
                        .headers()
                        .get("authorization")
                        .and_then(|v| v.to_str().ok())
                        .map(str::to_string),
                    body,
                })
                .await;
            Ok::<_, Error>(
                Response::builder()
                    .status(reply.status)
                    .header("content-type", "application/json")
                    .body(Body::Text(reply.body))?,
            )
        }
    }))
    .await
}
