//! An embeddable, bounded delivery dispatcher. The caller owns the Tokio runtime.
//!
//! Language capture, sampling, filtering and scrubbing happen before submission.
//! Ruby bindings are deliberately confined to a separate, unpublished crate.

mod adapter;
mod dispatcher;
mod event;
mod protocols;

pub use adapter::{
    Adapter, AdapterConfig, AdapterError, CaptureFuture, HttpAdapter, LoggerAdapter,
    PreparedRequest, TransportConfig,
};
pub use dispatcher::{
    Completion, Config, DeliveryOutcome, Dispatcher, Receipt, Statistics, SubmitError,
};
pub use event::{Event, Exception, Frame, RuntimeContext};
