use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

/// An owned, language-independent snapshot. No capture-time processing is run
/// by the dispatcher, so producers can safely apply their own policies once.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub id: Uuid,
    #[serde(rename = "type")]
    pub event_type: String,
    pub level: String,
    pub timestamp: Timestamp,
    pub message: Option<String>,
    #[serde(default)]
    pub exception: Option<Exception>,
    #[serde(default)]
    pub frames: Vec<Frame>,
    #[serde(default = "empty_object")]
    pub context: Value,
    pub environment: Option<String>,
    pub release: Option<String>,
    #[serde(default)]
    pub fingerprint: Value,
    pub transaction: Option<String>,
    #[serde(default)]
    pub runtime: RuntimeContext,
}

fn empty_object() -> Value {
    json!({})
}

impl Event {
    pub fn message(message: impl Into<String>, level: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            event_type: "message".into(),
            level: level.into(),
            timestamp: Timestamp::now(),
            message: Some(message.into()),
            exception: None,
            frames: Vec::new(),
            context: empty_object(),
            environment: None,
            release: None,
            fingerprint: Value::Null,
            transaction: None,
            runtime: RuntimeContext::default(),
        }
    }

    #[must_use]
    pub fn tags(&self) -> &Value {
        &self.context["tags"]
    }

    #[must_use]
    pub fn extra(&self) -> &Value {
        &self.context["extra"]
    }

    #[must_use]
    pub fn user(&self) -> &Value {
        &self.context["user"]
    }

    pub fn breadcrumbs(&self) -> &[Value] {
        self.context["breadcrumbs"]
            .as_array()
            .map_or(&[], Vec::as_slice)
    }

    #[must_use]
    pub fn request(&self) -> &Value {
        self.context["extra"].get("request").unwrap_or(&Value::Null)
    }

    #[must_use]
    pub fn exception_type(&self) -> &str {
        self.exception
            .as_ref()
            .map_or("Error", |e| e.class.as_str())
    }

    #[must_use]
    pub fn exception_message(&self) -> &str {
        self.exception
            .as_ref()
            .map_or_else(|| self.message.as_deref().unwrap_or(""), |e| &e.message)
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Exception {
    pub class: String,
    pub message: String,
    #[serde(default)]
    pub backtrace: Vec<String>,
    #[serde(default)]
    pub cause: Option<Box<Self>>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Frame {
    pub filename: Option<String>,
    pub absolute_path: Option<String>,
    pub line_number: Option<u64>,
    #[serde(rename = "method")]
    pub method_name: Option<String>,
    pub function: Option<String>,
    #[serde(default)]
    pub in_app: bool,
    #[serde(default)]
    pub code_context: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RuntimeContext {
    pub language: String,
    pub sdk_version: String,
    pub server_name: Option<String>,
    #[serde(default = "empty_object")]
    pub contexts: Value,
    #[serde(default = "empty_object")]
    pub modules: Value,
    pub root: Option<String>,
    pub framework: Option<String>,
}

impl Default for RuntimeContext {
    fn default() -> Self {
        Self {
            language: "rust".into(),
            sdk_version: env!("CARGO_PKG_VERSION").into(),
            server_name: None,
            contexts: empty_object(),
            modules: empty_object(),
            root: None,
            framework: None,
        }
    }
}
