use std::{
    collections::BTreeMap,
    future::Future,
    io::Write,
    pin::Pin,
    time::{Duration, SystemTime},
};

use chrono_machines::{BackoffStrategy, ExponentialBackoff, rand};
use flate2::{Compression, write::GzEncoder};
use rama::http::{client::DefaultHttpWebClient, service::client::HttpClientExt};
use rama::tls::client::{ServerVerifyMode, TlsServerVerify};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Event, protocols};

/// An independently named destination. Settings may contain credentials; this
/// type deliberately does not implement Debug.
#[derive(Clone, Serialize, Deserialize)]
pub struct AdapterConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub adapter_type: String,
    #[serde(default)]
    pub settings: BTreeMap<String, Value>,
}

impl AdapterConfig {
    pub fn new(name: impl Into<String>, adapter_type: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            adapter_type: adapter_type.into(),
            settings: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn setting(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.settings.insert(key.into(), value.into());
        self
    }

    pub(crate) fn string(&self, key: &str) -> Option<&str> {
        self.settings
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct TransportConfig {
    pub timeout: f64,
    /// Additional attempts after the first request, up to 254.
    pub max_retries: u32,
    pub initial_backoff: f64,
    pub max_backoff: f64,
    pub backoff_multiplier: f64,
    pub jitter: bool,
    pub ssl_verify: bool,
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            timeout: 5.0,
            max_retries: 3,
            initial_backoff: 1.0,
            max_backoff: 64.0,
            backoff_multiplier: 2.0,
            jitter: true,
            ssl_verify: true,
        }
    }
}

impl TransportConfig {
    /// # Errors
    /// Rejects nonfinite durations, invalid backoff parameters and retry
    /// budgets beyond 254 retries (255 total attempts).
    pub fn validate(&self) -> Result<(), AdapterError> {
        if !self.timeout.is_finite()
            || self.timeout <= 0.0
            || !self.initial_backoff.is_finite()
            || self.initial_backoff < 0.0
            || !self.max_backoff.is_finite()
            || self.max_backoff < self.initial_backoff
            || !self.backoff_multiplier.is_finite()
            || self.backoff_multiplier < 1.0
            || self.max_retries >= u32::from(u8::MAX)
            || Duration::try_from_secs_f64(self.timeout).is_err()
            || Duration::try_from_secs_f64(self.initial_backoff).is_err()
            || Duration::try_from_secs_f64(self.max_backoff).is_err()
            || Duration::try_from_secs_f64(self.max_backoff)
                .is_ok_and(|delay| u64::try_from(delay.as_millis()).is_err())
        {
            return Err(AdapterError::new("Invalid transport configuration"));
        }
        Ok(())
    }
}

/// Terminal delivery error; never include request URLs, headers or bodies.
#[derive(Clone, Debug, thiserror::Error)]
#[error("{message}")]
pub struct AdapterError {
    pub message: String,
    pub status: Option<u16>,
}

impl AdapterError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            status: None,
        }
    }
}

/// A sendable delivery future borrowing its adapter and event.
pub type CaptureFuture<'a> = Pin<Box<dyn Future<Output = Result<(), AdapterError>> + Send + 'a>>;

/// A dynamically dispatched destination, implemented without async macros.
///
/// ```
/// use lapsoss::{Adapter, CaptureFuture, Event};
///
/// struct CustomLogger;
///
/// impl Adapter for CustomLogger {
///     fn name(&self) -> &str {
///         "custom"
///     }
///
///     fn capture<'a>(&'a self, event: &'a Event) -> CaptureFuture<'a> {
///         Box::pin(async move {
///             tracing::info!(destination = self.name(), event_id = %event.id);
///             Ok(())
///         })
///     }
/// }
/// ```
pub trait Adapter: Send + Sync {
    fn name(&self) -> &str;
    fn capture<'a>(&'a self, event: &'a Event) -> CaptureFuture<'a>;
    /// Language bridges can deliver formatted log output on their own thread.
    fn log_output(&self, _event: &Event) -> Option<String> {
        None
    }
}

pub struct LoggerAdapter {
    name: String,
    emit: bool,
}

impl LoggerAdapter {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            emit: true,
        }
    }
    pub fn deferred(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            emit: false,
        }
    }
}

impl Adapter for LoggerAdapter {
    fn name(&self) -> &str {
        &self.name
    }

    fn capture<'a>(&'a self, event: &'a Event) -> CaptureFuture<'a> {
        Box::pin(async move {
            if self.emit {
                tracing::info!(destination = %self.name, message = %format_log(event));
            }
            Ok(())
        })
    }

    fn log_output(&self, event: &Event) -> Option<String> {
        (!self.emit).then(|| format_log(event))
    }
}

#[expect(clippy::expect_used, reason = "formatting into String cannot fail")]
fn format_log(event: &Event) -> String {
    use std::fmt::Write as _;
    let mut output = if event.event_type == "exception" {
        format!(
            "[LAPSOSS] Exception: {}: {}",
            event.exception_type(),
            event.exception_message()
        )
    } else {
        format!("[LAPSOSS] {}", event.message.as_deref().unwrap_or(""))
    };
    if let Some(exception) = &event.exception {
        for line in exception.backtrace.iter().take(10) {
            output.push('\n');
            output.push_str(line);
        }
    }
    if event.context.as_object().is_some_and(|c| !c.is_empty()) {
        write!(output, "\nContext: {}", event.context).expect("String formatting is infallible");
    }
    for crumb in event.breadcrumbs() {
        write!(
            output,
            "\n[BREADCRUMB] [{}] {} | {}",
            crumb["type"].as_str().unwrap_or("default").to_uppercase(),
            crumb["message"].as_str().unwrap_or(""),
            crumb["metadata"]
        )
        .expect("String formatting is infallible");
    }
    output
}

/// A payload before HTTP delivery; useful for offline protocol validation.
pub struct PreparedRequest {
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Clone)]
pub struct HttpAdapter {
    pub(crate) config: AdapterConfig,
    client: DefaultHttpWebClient,
    transport: TransportConfig,
}

impl HttpAdapter {
    /// # Errors
    /// Returns an error for invalid transport or destination settings.
    pub fn new(config: AdapterConfig, transport: TransportConfig) -> Result<Self, AdapterError> {
        transport.validate()?;
        protocols::validate(&config)?;
        Ok(Self {
            config,
            // Rama does not follow redirects unless explicitly layered to do so.
            client: DefaultHttpWebClient::default(),
            transport,
        })
    }

    /// Serialize and optionally compress a payload without making a request.
    ///
    /// # Errors
    /// Returns a redacted error if URL construction, encoding or gzip fails.
    pub fn prepare(&self, event: &Event) -> Result<Option<PreparedRequest>, AdapterError> {
        let Some(mut request) = protocols::prepare(&self.config, event)? else {
            return Ok(None);
        };
        let threshold = self
            .config
            .settings
            .get("compress_threshold")
            .and_then(Value::as_u64)
            .unwrap_or(if self.config.adapter_type == "openobserve" {
                1024
            } else {
                30 * 1024
            });
        if request.body.len() as u64 >= threshold {
            let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
            encoder
                .write_all(&request.body)
                .map_err(|_| AdapterError::new("Compression failed"))?;
            request.body = encoder
                .finish()
                .map_err(|_| AdapterError::new("Compression failed"))?;
            request
                .headers
                .insert("Content-Encoding".into(), "gzip".into());
        }
        Ok(Some(request))
    }

    async fn send(&self, request: PreparedRequest) -> Result<(), AdapterError> {
        let retries = u8::try_from(self.transport.max_retries)
            .map_err(|_| AdapterError::new("Invalid retry budget"))?;
        let milliseconds = |seconds| {
            u64::try_from(Duration::from_secs_f64(seconds).as_millis())
                .map_err(|_| AdapterError::new("Invalid backoff duration"))
        };
        let backoff = ExponentialBackoff::new()
            .base_delay_ms(milliseconds(self.transport.initial_backoff)?)
            .max_delay_ms(milliseconds(self.transport.max_backoff)?)
            .multiplier(self.transport.backoff_multiplier)
            .max_attempts(retries.strict_add(1))
            .jitter_factor(if self.transport.jitter { 1.0 } else { 0.0 });
        for attempt in 1..=BackoffStrategy::max_attempts(&backoff) {
            let response = {
                let mut builder = self.client.post(&request.url).body(request.body.clone());
                if !self.transport.ssl_verify {
                    builder = builder.extension(TlsServerVerify(ServerVerifyMode::Disable));
                }
                for (key, value) in &request.headers {
                    builder = builder.header(key.as_str(), value.as_str());
                }
                builder
                    .send_with_timeout(Duration::from_secs_f64(self.transport.timeout))
                    .await
            };
            let (error, retry, retry_after) = match response {
                Ok(response) if response.status().is_success() => return Ok(()),
                Ok(response) => {
                    let status = response.status().as_u16();
                    let retry_after = response
                        .headers()
                        .get("Retry-After")
                        // Malformed Retry-After is ignored, not a delivery failure.
                        .and_then(|h| h.to_str().ok())
                        .and_then(parse_retry_after);
                    (
                        AdapterError {
                            message: format!("HTTP {status}"),
                            status: Some(status),
                        },
                        status == 429 || status >= 500,
                        retry_after,
                    )
                }
                Err(_) => (AdapterError::new("HTTP transport failure"), true, None),
            };
            if !retry {
                return Err(error);
            }
            let Some(delay) = backoff.delay(attempt, &mut rand::rng()) else {
                return Err(error);
            };
            let wait = Duration::from_millis(delay);
            tokio::time::sleep(retry_after.map_or(wait, |server| server.max(wait))).await;
        }
        Err(AdapterError::new("Retry budget exhausted"))
    }
}

fn parse_retry_after(value: &str) -> Option<Duration> {
    // Invalid headers are explicitly advisory: fall back to local backoff.
    value
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
        .or_else(|| {
            httpdate::parse_http_date(value).ok().map(|date| {
                date.duration_since(SystemTime::now())
                    .unwrap_or(Duration::ZERO)
            })
        })
        .filter(|duration| std::time::Instant::now().checked_add(*duration).is_some())
}

impl Adapter for HttpAdapter {
    fn name(&self) -> &str {
        &self.config.name
    }

    fn capture<'a>(&'a self, event: &'a Event) -> CaptureFuture<'a> {
        Box::pin(async move {
            // Serialization and gzip must not monopolize an async worker.
            let adapter = self.clone();
            let event = event.clone();
            let request = tokio::task::spawn_blocking(move || adapter.prepare(&event))
                .await
                .map_err(|_| AdapterError::new("Payload preparation failed"))??;
            if let Some(request) = request {
                self.send(request).await?;
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests;
