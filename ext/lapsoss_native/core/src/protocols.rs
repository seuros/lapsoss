//! Vendor wire formats. Event identity is distinct from grouping fingerprints.
use std::collections::BTreeMap;

use base64::{Engine as _, prelude::BASE64_STANDARD};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{AdapterConfig, AdapterError, Event, PreparedRequest};

pub fn validate(config: &AdapterConfig) -> Result<(), AdapterError> {
    let required: &[&str] = match config.adapter_type.as_str() {
        "sentry" | "telebugs" => &["dsn"],
        "rollbar" => &["access_token"],
        "insight_hub" | "bugsnag" => &["api_key"],
        "openobserve" => &["endpoint", "username", "password"],
        "appsignal" | "otlp" => &[],
        _ => return Err(AdapterError::new("Unknown built-in adapter type")),
    };
    for key in required {
        if config.string(key).is_none() {
            return Err(AdapterError::new(format!("Missing adapter setting: {key}")));
        }
    }
    if config.adapter_type == "appsignal"
        && config.string("frontend_api_key").is_none()
        && config.string("push_api_key").is_none()
    {
        return Err(AdapterError::new("AppSignal requires an API key"));
    }
    if let Some(dsn) = config.string("dsn") {
        let url = parse_url(dsn)?;
        if url.username().is_empty() || url.path().trim_matches('/').is_empty() {
            return Err(AdapterError::new("DSN requires a public key and project"));
        }
    }
    if let Some(endpoint) = config.string("endpoint") {
        drop(parse_url(endpoint)?);
    }
    Ok(())
}

fn parse_url(url: &str) -> Result<url::Url, AdapterError> {
    let url = url::Url::parse(url).map_err(|_| AdapterError::new("Invalid adapter URL"))?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(AdapterError::new("Adapter URL must use HTTP or HTTPS"));
    }
    Ok(url)
}

pub fn prepare(config: &AdapterConfig, e: &Event) -> Result<Option<PreparedRequest>, AdapterError> {
    let mut headers = BTreeMap::from([
        (
            "User-Agent".into(),
            format!("lapsoss/{}", e.runtime.sdk_version),
        ),
        ("X-Lapsoss-Version".into(), e.runtime.sdk_version.clone()),
        (
            "Content-Type".into(),
            "application/json; charset=UTF-8".into(),
        ),
    ]);
    let (url, body) = match config.adapter_type.as_str() {
        "sentry" | "telebugs" => sentry_envelope(config, e, &mut headers)?,
        "rollbar" => {
            let token = config.string("access_token").unwrap_or("");
            headers.insert("X-Rollbar-Access-Token".into(), token.into());
            (
                endpoint(config, "https://api.rollbar.com", "/api/1/item/")?,
                encode(&rollbar(config, e))?,
            )
        }
        "appsignal" => {
            if config.string("frontend_api_key").is_none() {
                return Ok(None);
            }
            if e.event_type == "message"
                && !matches!(e.level.as_str(), "error" | "fatal" | "critical")
            {
                return Ok(None);
            }
            let mut url = parse_url(&endpoint(
                config,
                "https://appsignal-endpoint.net",
                "/errors",
            )?)?;
            url.query_pairs_mut()
                .append_pair("api_key", config.string("frontend_api_key").unwrap_or(""));
            (url.to_string(), encode(&appsignal(config, e))?)
        }
        "insight_hub" | "bugsnag" => {
            headers.insert(
                "Bugsnag-Api-Key".into(),
                config.string("api_key").unwrap_or("").into(),
            );
            headers.insert("Bugsnag-Payload-Version".into(), "5".into());
            (
                endpoint(config, "https://notify.bugsnag.com", "/")?,
                encode(&bugsnag(config, e))?,
            )
        }
        "openobserve" => {
            // Construct via URL path segments to prevent org/stream injection.
            let mut url = parse_url(config.string("endpoint").unwrap_or(""))?;
            url.path_segments_mut()
                .map_err(|()| AdapterError::new("Invalid endpoint"))?
                .clear()
                .push("api")
                .push(config.string("org").unwrap_or("default"))
                .push(config.string("stream").unwrap_or("errors"))
                .push("_json");
            headers.insert(
                "Authorization".into(),
                format!(
                    "Basic {}",
                    BASE64_STANDARD.encode(format!(
                        "{}:{}",
                        config.string("username").unwrap_or(""),
                        config.string("password").unwrap_or("")
                    ))
                ),
            );
            (url.to_string(), encode(&json!([openobserve(config, e)]))?)
        }
        "otlp" => {
            if let Some(values) = config.settings.get("headers").and_then(Value::as_object) {
                for (key, value) in values {
                    if let Some(value) = value.as_str() {
                        headers.insert(key.clone(), value.into());
                    }
                }
            }
            if let Some(key) = config.string("api_key") {
                headers.insert("Authorization".into(), format!("Bearer {key}"));
            }
            if let Some(key) = config.string("signoz_api_key") {
                headers.insert("signoz-access-token".into(), key.into());
            }
            (
                endpoint(config, "http://localhost:4318", "/v1/traces")?,
                encode(&otlp(config, e))?,
            )
        }
        _ => return Err(AdapterError::new("Unknown adapter")),
    };
    Ok(Some(PreparedRequest { url, headers, body }))
}

fn sentry_envelope(
    config: &AdapterConfig,
    e: &Event,
    headers: &mut BTreeMap<String, String>,
) -> Result<(String, Vec<u8>), AdapterError> {
    let mut url = parse_url(config.string("dsn").unwrap_or(""))?;
    let key = url.username().to_owned();
    let path = url.path().trim_end_matches('/');
    let (base, project) = path
        .rsplit_once('/')
        .ok_or_else(|| AdapterError::new("Invalid DSN path"))?;
    let path = if config.adapter_type == "telebugs" {
        format!("{base}/api/{project}/envelope/")
    } else {
        format!("/api/{project}/envelope/")
    };
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    url.set_username("")
        .map_err(|()| AdapterError::new("Invalid DSN"))?;
    url.set_password(None)
        .map_err(|()| AdapterError::new("Invalid DSN"))?;
    headers.insert(
        "Content-Type".into(),
        "application/x-sentry-envelope".into(),
    );
    headers.insert("X-Sentry-Auth".into(), format!(
        "Sentry sentry_version=7, sentry_client=lapsoss/{}, sentry_timestamp={}, sentry_key={key}",
        e.runtime.sdk_version, jiff::Timestamp::now().as_second()));
    if config.adapter_type == "telebugs" {
        headers.insert(
            "X-Telebugs-Client".into(),
            format!("lapsoss/{}", e.runtime.sdk_version),
        );
    }
    let payload = serde_json::to_string(&sentry(e))
        .map_err(|_| AdapterError::new("Payload serialization failed"))?;
    let envelope =
        json!({"event_id": e.id.simple().to_string(), "sent_at": timestamp(e), "sdk": sdk(e)});
    let item = json!({"type": if e.event_type == "transaction" { "transaction" } else { "event" },
        "content_type": "application/json", "length": payload.len()});
    Ok((
        url.to_string(),
        format!("{envelope}\n{item}\n{payload}\n").into_bytes(),
    ))
}

fn endpoint(config: &AdapterConfig, default: &str, path: &str) -> Result<String, AdapterError> {
    let mut url = parse_url(config.string("endpoint").unwrap_or(default))?;
    url.set_path(path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.to_string())
}

fn encode(value: &Value) -> Result<Vec<u8>, AdapterError> {
    serde_json::to_vec(value).map_err(|_| AdapterError::new("Payload serialization failed"))
}

fn timestamp(e: &Event) -> String {
    format!("{:.6}", e.timestamp)
}
fn environment(e: &Event) -> &str {
    e.environment.as_deref().unwrap_or("production")
}
fn sdk(e: &Event) -> Value {
    json!({"name": format!("lapsoss.{}", e.runtime.language), "version": e.runtime.sdk_version})
}

fn sentry_frame(frame: &crate::Frame) -> Value {
    compact(json!({
        "filename": frame.filename, "abs_path": frame.absolute_path.as_ref().or(frame.filename.as_ref()),
        "function": frame.method_name.as_ref().or(frame.function.as_ref()),
        "lineno": frame.line_number, "in_app": frame.in_app,
        "pre_context": frame.code_context["pre_context"], "context_line": frame.code_context["context_line"],
        "post_context": frame.code_context["post_context"],
    }))
}

fn sentry(e: &Event) -> Value {
    let breadcrumbs = e
        .breadcrumbs()
        .iter()
        .map(|c| {
            compact(json!({
                "timestamp": c["timestamp"], "type": c["type"], "message": c["message"],
                "data": {"metadata": c["metadata"]},
            }))
        })
        .collect::<Vec<_>>();
    let mut payload = compact(json!({
        "event_id": e.id.simple().to_string(), "timestamp": timestamp(e), "platform": e.runtime.language,
        "level": if e.level == "warn" { "warning" } else { &e.level },
        "environment": environment(e), "release": e.release, "server_name": e.runtime.server_name,
        "modules": e.runtime.modules, "contexts": e.runtime.contexts, "tags": e.tags(), "user": e.user(),
        "extra": e.extra(), "breadcrumbs": breadcrumbs, "transaction": e.transaction, "sdk": sdk(e),
    }));
    if !e.fingerprint.is_null() {
        payload["fingerprint"] = if e.fingerprint.is_array() {
            e.fingerprint.clone()
        } else {
            json!([e.fingerprint])
        };
    }
    if e.event_type == "exception" {
        let mut values = Vec::new();
        if let Some(exception) = &e.exception {
            append_sentry_exception(exception, &e.frames, &mut values);
        }
        payload["exception"] = json!({"values": values});
    } else if e.event_type == "message" {
        payload["message"] = json!(e.message);
    }
    payload
}

fn append_sentry_exception(
    exception: &crate::Exception,
    frames: &[crate::Frame],
    values: &mut Vec<Value>,
) {
    if let Some(cause) = &exception.cause {
        append_sentry_exception(cause, &[], values);
    }
    values.push(compact(json!({
        "type": exception.class, "value": exception.message,
        "stacktrace": if frames.is_empty() { Value::Null } else {
            json!({"frames": frames.iter().rev().map(sentry_frame).collect::<Vec<_>>()})
        },
        "mechanism": {"type": "generic", "handled": true}
    })));
}

fn rollbar(config: &AdapterConfig, e: &Event) -> Value {
    let body = if e.event_type == "exception" {
        json!({"trace": {
            "frames": e.frames.iter().rev().map(|f| compact(json!({
                "filename": f.filename, "lineno": f.line_number,
                "method": f.method_name, "code": f.code_context["context_line"]
            }))).collect::<Vec<_>>(),
            "exception": {"class": e.exception_type(), "message": e.exception_message(), "description": e.exception_message()}
        }})
    } else {
        json!({"message": {"body": e.message}})
    };
    compact(
        json!({"access_token": config.string("access_token"), "data": {
            "environment": environment(e), "body": body,
            "level": if e.level == "fatal" { "critical" } else { &e.level },
            "timestamp": e.timestamp.as_second(), "code_version": config.string("release").or(e.release.as_deref()),
            "platform": e.runtime.language, "language": e.runtime.language,
            "framework": e.runtime.framework.as_deref().unwrap_or(&e.runtime.language),
            "server": {"host": e.runtime.server_name, "root": e.runtime.root, "code_version": e.release},
            "person": person(e, false), "request": e.request(), "custom": e.extra()
        }}),
    )
}

fn stringify(value: &Value) -> Value {
    value.as_object().map_or_else(
        || json!({}),
        |values| {
            Value::Object(
                values
                    .iter()
                    .map(|(key, value)| {
                        (
                            key.clone(),
                            json!(
                                value
                                    .as_str()
                                    .map_or_else(|| value.to_string(), str::to_owned)
                            ),
                        )
                    })
                    .collect(),
            )
        },
    )
}

fn appsignal(config: &AdapterConfig, e: &Event) -> Value {
    let mut env = json!({"hostname": e.runtime.server_name, "app_name": config.string("app_name"), "environment": e.environment});
    if let Some(extra) = e.context["environment"].as_object() {
        for (key, value) in extra {
            env[key] = json!(
                value
                    .as_str()
                    .map_or_else(|| value.to_string(), str::to_owned)
            );
        }
    }
    let mut value = json!({
        "tags": stringify(e.tags()), "params": stringify(&e.context["params"]),
        "environment": env, "breadcrumbs": e.context["breadcrumbs"]
    });
    if e.event_type == "exception" {
        value["timestamp"] = json!(e.timestamp.as_second());
        value["namespace"] = e
            .context
            .get("namespace")
            .cloned()
            .unwrap_or_else(|| json!("backend"));
        value["error"] = json!({"name": e.exception_type(), "message": e.exception_message(),
            "backtrace": e.exception.as_ref().map(|ex| &ex.backtrace)});
    } else {
        value["action"] = e
            .context
            .get("action")
            .cloned()
            .unwrap_or_else(|| json!("log_message"));
        value["path"] = e.context.get("path").cloned().unwrap_or_else(|| json!("/"));
        value["exception"] = json!({"name": "LogMessage", "message": e.message, "backtrace": []});
    }
    value
}

fn person(e: &Event, bugsnag: bool) -> Value {
    if e.user().is_null() {
        return Value::Null;
    }
    let id = e
        .user()
        .get("id")
        .filter(|v| !v.is_null())
        .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_owned));
    let mut person = compact(json!({"id": id, "email": e.user()["email"]}));
    person[if bugsnag { "name" } else { "username" }] = e
        .user()
        .get("username")
        .or_else(|| e.user().get("name"))
        .cloned()
        .unwrap_or(Value::Null);
    compact(person)
}

fn bugsnag(config: &AdapterConfig, e: &Event) -> Value {
    let exceptions = if e.event_type == "exception" {
        vec![
            json!({"errorClass": e.exception_type(), "message": e.message, "type": e.runtime.language,
            "stacktrace": e.frames.iter().map(|f| compact(json!({
                "file": f.filename, "lineNumber": f.line_number, "method": f.method_name,
                "inProject": f.in_app, "code": bugsnag_code(f)
            }))).collect::<Vec<_>>()}),
        ]
    } else {
        Vec::new()
    };
    let severity = match e.level.as_str() {
        "info" | "debug" => "info",
        "warning" | "warn" => "warning",
        _ => "error",
    };
    json!({
        "apiKey": config.string("api_key"), "payloadVersion": "5",
        "notifier": {"name": format!("Lapsoss {}", e.runtime.language), "version": e.runtime.sdk_version,
            "url": "https://github.com/seuros/lapsoss"},
        "events": [compact(json!({
            "app": {"id": e.context["app"]["id"], "version": e.release,
                "releaseStage": environment(e), "type": e.runtime.framework.as_deref().unwrap_or(&e.runtime.language)},
            "device": {"hostname": e.runtime.server_name, "osName": e.runtime.contexts["os"]["name"],
                "runtimeVersions": {e.runtime.language.clone(): e.runtime.contexts["runtime"]["version"]}},
            "exceptions": exceptions,
            "breadcrumbs": e.breadcrumbs().iter().map(|c| json!({
                "timestamp": c["timestamp"], "name": c["message"], "type": c["type"], "metaData": c["metadata"]
            })).collect::<Vec<_>>(),
            "request": e.request(), "user": person(e, true), "severity": severity,
            "context": e.context["custom"].get("context").cloned().unwrap_or_else(|| json!("production")),
            "unhandled": e.context["unhandled"].as_bool().unwrap_or(false),
            "metaData": e.context.get("custom").cloned().unwrap_or_else(|| json!({}))
        }))]
    })
}

fn bugsnag_code(frame: &crate::Frame) -> Value {
    match (frame.line_number, frame.code_context.get("context_line")) {
        (Some(line), Some(code)) if code.is_string() => json!({line.to_string(): code}),
        _ => Value::Null,
    }
}

fn raw_stacktrace(e: &Event) -> Vec<String> {
    e.frames
        .iter()
        .map(|f| {
            format!(
                "{}:{} in `{}`",
                f.absolute_path
                    .as_deref()
                    .or(f.filename.as_deref())
                    .unwrap_or(""),
                f.line_number.map_or_else(String::new, |n| n.to_string()),
                f.method_name
                    .as_deref()
                    .or(f.function.as_deref())
                    .unwrap_or("")
            )
        })
        .collect()
}

fn openobserve(config: &AdapterConfig, e: &Event) -> Value {
    let level = match e.level.as_str() {
        "debug" => "DEBUG",
        "warning" | "warn" => "WARN",
        "error" => "ERROR",
        "fatal" | "critical" => "FATAL",
        _ => "INFO",
    };
    let mut value = compact(json!({
        "_timestamp": e.timestamp.as_microsecond(), "level": level, "logger": "lapsoss",
        "environment": environment(e), "service": config.string("service_name").unwrap_or("rails"),
        "user": e.user(), "tags": e.tags(), "extra": e.extra(), "request": e.request(),
        "transaction": e.transaction, "fingerprint": e.fingerprint,
        "message": e.message,
    }));
    if e.event_type == "exception" {
        value["message"] = json!(format!("{}: {}", e.exception_type(), e.exception_message()));
        value["exception_type"] = json!(e.exception_type());
        value["exception_message"] = json!(e.exception_message());
        if !e.frames.is_empty() {
            value["stacktrace"] = json!(e.frames.iter().map(sentry_frame).collect::<Vec<_>>());
            value["stacktrace_raw"] = json!(raw_stacktrace(e));
        }
    }
    value
}

fn attribute_value(value: &Value) -> Value {
    match value {
        Value::String(s) => json!({"stringValue": s}),
        Value::Bool(b) => json!({"boolValue": b}),
        Value::Number(n) if n.is_i64() || n.is_u64() => json!({"intValue": n.to_string()}),
        Value::Number(n) => json!({"doubleValue": n}),
        Value::Array(values) => {
            json!({"arrayValue": {"values": values.iter().map(attribute_value).collect::<Vec<_>>()}})
        }
        _ => json!({"stringValue": value.to_string()}),
    }
}

fn attr(key: &str, value: &Value) -> Value {
    json!({"key": key, "value": attribute_value(value)})
}

fn otlp(config: &AdapterConfig, e: &Event) -> Value {
    let mut resources = vec![
        attr(
            "service.name",
            &json!(config.string("service_name").unwrap_or("rails")),
        ),
        attr(
            "deployment.environment",
            &json!(
                e.environment
                    .as_deref()
                    .or_else(|| config.string("environment"))
                    .unwrap_or("production")
            ),
        ),
        attr("telemetry.sdk.name", &json!("lapsoss")),
        attr("telemetry.sdk.version", &json!(e.runtime.sdk_version)),
        attr("telemetry.sdk.language", &json!(e.runtime.language)),
    ];
    if let Some(user) = e.user().as_object() {
        resources.extend(user.iter().map(|(k, v)| attr(&format!("user.{k}"), v)));
    }
    let mut attributes = Vec::new();
    for (prefix, values) in [
        ("", e.tags()),
        ("extra.", e.extra()),
        ("http.", e.request()),
    ] {
        if let Some(values) = values.as_object() {
            attributes.extend(values.iter().map(|(k, v)| attr(&format!("{prefix}{k}"), v)));
        }
    }
    if let Some(transaction) = &e.transaction {
        attributes.push(attr("transaction.name", &json!(transaction)));
    }
    if !e.fingerprint.is_null() {
        attributes.push(attr("error.fingerprint", &e.fingerprint));
    }
    if e.event_type == "message" {
        attributes.push(attr("message", &json!(e.message)));
    }
    let nanos = e.timestamp.as_nanosecond().to_string();
    let mut span = json!({
        "traceId": e.id.simple().to_string(), "spanId": &Uuid::new_v4().simple().to_string()[..16],
        "name": if e.event_type == "exception" { e.exception_type() } else { "message" },
        "kind": 1, "startTimeUnixNano": nanos, "endTimeUnixNano": nanos,
        "status": if e.event_type == "exception" || matches!(e.level.as_str(), "error" | "fatal") {
            json!({"code": 2, "message": e.exception_message()})
        } else { json!({"code": 1}) }, "attributes": attributes,
    });
    if e.event_type == "exception" {
        let mut attributes = vec![
            attr("exception.type", &json!(e.exception_type())),
            attr("exception.message", &json!(e.exception_message())),
        ];
        if !e.frames.is_empty() {
            attributes.push(attr(
                "exception.stacktrace",
                &json!(raw_stacktrace(e).join("\n")),
            ));
        }
        span["events"] =
            json!([{"name": "exception", "timeUnixNano": nanos, "attributes": attributes}]);
    }
    json!({"resourceSpans": [{"resource": {"attributes": resources},
        "scopeSpans": [{"scope": {"name": "lapsoss", "version": e.runtime.sdk_version}, "spans": [span]}]}]})
}

/// Omit absent/empty optional fields but preserve false and zero.
fn compact(mut value: Value) -> Value {
    if let Some(map) = value.as_object_mut() {
        map.retain(|_, v| {
            !v.is_null()
                && !matches!(v, Value::String(s) if s.is_empty())
                && !matches!(v, Value::Array(a) if a.is_empty())
                && !matches!(v, Value::Object(o) if o.is_empty())
        });
    }
    value
}

#[cfg(test)]
mod tests;
