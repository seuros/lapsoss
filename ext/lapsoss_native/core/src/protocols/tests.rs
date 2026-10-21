#![allow(clippy::unwrap_used)]

use super::*;
use crate::{HttpAdapter, TransportConfig};

fn event() -> Event {
    serde_json::from_str(include_str!("../../fixtures/event.json")).unwrap()
}

fn http_adapter(config: AdapterConfig) -> HttpAdapter {
    HttpAdapter::new(config, TransportConfig::default()).unwrap()
}

#[test]
fn sentry_identity_is_not_fingerprint() {
    let adapter = http_adapter(
        AdapterConfig::new("eu", "sentry").setting("dsn", "https://public:secret@localhost/123"),
    );
    let mut e = event();
    e.fingerprint = json!("grouping-key");
    let request = adapter.prepare(&e).unwrap().unwrap();
    drop(adapter);
    assert_eq!(request.url, "https://localhost/api/123/envelope/");
    let body = String::from_utf8(request.body).unwrap();
    let values = body
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(values[0]["event_id"], values[2]["event_id"]);
    assert_eq!(values[2]["fingerprint"], json!(["grouping-key"]));
    assert_eq!(values[2]["tags"]["region"], "eu");
    assert!(!request.url.contains("secret"));
}

#[test]
fn telebugs_path_and_authentication() {
    let adapter = http_adapter(
        AdapterConfig::new("selfhost", "telebugs")
            .setting("dsn", "http://key@localhost:3000/api/v1/sentry_errors/42"),
    );
    let request = adapter.prepare(&event()).unwrap().unwrap();
    drop(adapter);
    assert_eq!(
        request.url,
        "http://localhost:3000/api/v1/sentry_errors/api/42/envelope/"
    );
    assert!(request.headers.contains_key("X-Telebugs-Client"));
}

#[test]
fn all_vendor_payloads_are_json_and_preserve_context() {
    for (kind, settings) in [
        ("rollbar", vec![("access_token", "abc")]),
        ("appsignal", vec![("frontend_api_key", "abc")]),
        ("bugsnag", vec![("api_key", "abc")]),
        ("insight_hub", vec![("api_key", "abc")]),
        (
            "openobserve",
            vec![
                ("endpoint", "http://localhost:5080"),
                ("username", "u"),
                ("password", "p"),
            ],
        ),
        ("otlp", vec![]),
    ] {
        let mut config = AdapterConfig::new(kind, kind);
        for (key, value) in settings {
            config = config.setting(key, value);
        }
        let adapter = http_adapter(config);
        let request = adapter.prepare(&event()).unwrap().unwrap();
        drop(adapter);
        let payload: Value = serde_json::from_slice(&request.body).unwrap();
        assert!(!payload.is_null(), "{kind}");
        assert!(payload.is_object() || payload.is_array(), "{kind}");
    }
}

#[test]
fn compression_and_basic_auth() {
    let adapter = http_adapter(
        AdapterConfig::new("logs", "openobserve")
            .setting("endpoint", "http://localhost:5080")
            .setting("username", "u")
            .setting("password", "p")
            .setting("compress_threshold", 0),
    );
    let request = adapter.prepare(&event()).unwrap().unwrap();
    drop(adapter);
    assert_eq!(request.headers["Authorization"], "Basic dTpw");
    assert_eq!(request.headers["Content-Encoding"], "gzip");
    assert_eq!(&request.body[..2], &[31, 139]);
}

#[test]
fn appsignal_drops_informational_messages() {
    let adapter =
        http_adapter(AdapterConfig::new("errors", "appsignal").setting("frontend_api_key", "key"));
    let request = adapter.prepare(&Event::message("hello", "info")).unwrap();
    drop(adapter);
    assert!(request.is_none());
}

fn payload(kind: &str) -> Value {
    let config = AdapterConfig::new(kind, kind)
        .setting("access_token", "token")
        .setting("frontend_api_key", "key")
        .setting("api_key", "key")
        .setting("endpoint", "http://localhost:5080")
        .setting("username", "user")
        .setting("password", "pass");
    let request = http_adapter(config).prepare(&event()).unwrap().unwrap();
    serde_json::from_slice(&request.body).unwrap()
}

#[test]
fn rollbar_preserves_exception_person_request_and_release_fields() {
    let value = payload("rollbar");
    assert_eq!(value["access_token"], "token");
    let data = &value["data"];
    assert_eq!(data["body"]["trace"]["exception"]["class"], "RuntimeError");
    assert_eq!(data["body"]["trace"]["frames"][0]["lineno"], 42);
    assert_eq!(data["person"]["id"], "42");
    assert_eq!(data["custom"]["amount"], 7);
    assert_eq!(data["request"]["method"], "POST");
    assert_eq!(data["code_version"], "release-123");
}

#[test]
fn appsignal_preserves_error_breadcrumbs_and_stringifies_tags_and_params() {
    let value = payload("appsignal");
    assert_eq!(value["error"]["name"], "RuntimeError");
    assert_eq!(
        value["error"]["backtrace"][0],
        "/app/payment.rb:42:in `charge'"
    );
    assert_eq!(value["namespace"], "backend");
    assert_eq!(value["tags"]["region"], "eu");
    assert_eq!(value["params"]["cart"], "5");
    assert_eq!(value["breadcrumbs"][0]["message"], "checkout");
}

#[test]
fn bugsnag_alias_preserves_frames_and_line_number_keyed_code() {
    let value = payload("bugsnag");
    assert_eq!(value, payload("insight_hub"));
    assert_eq!(value["payloadVersion"], "5");
    let event = &value["events"][0];
    assert_eq!(event["exceptions"][0]["errorClass"], "RuntimeError");
    assert_eq!(
        event["exceptions"][0]["stacktrace"][0]["code"]["42"],
        "raise 'payment failed'"
    );
    assert_eq!(event["user"]["id"], "42");
    assert_eq!(event["breadcrumbs"][0]["metaData"]["cart"], 5);
    assert_eq!(event["app"]["releaseStage"], "test");
}

#[test]
fn openobserve_and_otlp_preserve_typed_values_and_time_units() {
    let observe = payload("openobserve");
    assert_eq!(observe[0]["_timestamp"], event().timestamp.as_microsecond());
    assert_eq!(observe[0]["level"], "ERROR");
    assert_eq!(observe[0]["tags"]["region"], "eu");
    assert_eq!(
        observe[0]["stacktrace"][0]["context_line"],
        "raise 'payment failed'"
    );
    let otlp = payload("otlp");
    let span = &otlp["resourceSpans"][0]["scopeSpans"][0]["spans"][0];
    assert_eq!(
        span["startTimeUnixNano"],
        event().timestamp.as_nanosecond().to_string()
    );
    assert_eq!(span["status"]["code"], 2);
    let amount = span["attributes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["key"] == "extra.amount")
        .unwrap();
    assert_eq!(amount["value"]["intValue"], "7");
    assert_eq!(
        span["events"][0]["attributes"][0]["value"]["stringValue"],
        "RuntimeError"
    );
}

#[test]
fn timestamp_normalizes_offsets_and_preserves_subsecond_wire_units() {
    let mut e = event();
    for (input, expected) in [
        ("2026-10-21T12:34:56Z", "2026-10-21T12:34:56.000000Z"),
        (
            "2026-10-21T13:34:56.123456789+01:00",
            "2026-10-21T12:34:56.123456Z",
        ),
    ] {
        e.timestamp = input.parse().unwrap();
        assert_eq!(timestamp(&e), expected, "{input}");
        let encoded = serde_json::to_value(&e).unwrap();
        let decoded: Event = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded.timestamp, e.timestamp, "{input}");
    }
}
