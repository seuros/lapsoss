//! Ruby conversion and runtime ownership only. Tokio tasks never retain Ruby
//! values or call into the Ruby VM.
use std::sync::{Arc, Mutex, MutexGuard};
use std::{thread::JoinHandle, time::Duration};

use lapsoss::{
    Adapter, AdapterConfig, Config, Dispatcher, Event, HttpAdapter, LoggerAdapter, TransportConfig,
};
use magnus::{Error, Module, Object, Ruby, function, method};
use serde::de::DeserializeOwned;
use tokio::runtime::Runtime;

struct State {
    dispatcher: Dispatcher,
    runtime: Option<Runtime>,
}

impl Drop for State {
    fn drop(&mut self) {
        self.dispatcher.cancel();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

#[magnus::wrap(class = "Lapsoss::Native::Engine", free_immediately, size)]
struct Engine {
    pid: u32,
    state: Mutex<Option<Box<State>>>,
    retired: Mutex<Option<JoinHandle<()>>>,
}

impl Drop for Engine {
    fn drop(&mut self) {
        if self.pid != std::process::id()
            && let Ok(state) = self.state.get_mut()
            && let Some(state) = state.take()
        {
            // Do not destroy inherited Tokio state in a forked child. This is
            // process-local leaked memory, not a recoverable live dispatcher.
            std::mem::forget(state);
        }
    }
}

fn error(message: impl Into<String>) -> Error {
    // Every entry point invoking this helper is called by Ruby with the GVL.
    let ruby = Ruby::get()
        .unwrap_or_else(|_| unreachable!("native errors are only constructed on Ruby threads"));
    Error::new(ruby.exception_runtime_error(), message.into())
}

fn decode<T: DeserializeOwned>(value: &str) -> Result<T, Error> {
    // serde errors can contain source data, so don't expose their text.
    serde_json::from_str(value).map_err(|_| error("Invalid Lapsoss native input"))
}

fn adapters(
    configs: Vec<AdapterConfig>,
    transport: &TransportConfig,
) -> Result<Vec<Arc<dyn Adapter>>, Error> {
    configs
        .into_iter()
        .map(|config| {
            if config.adapter_type == "logger" {
                Ok(Arc::new(LoggerAdapter::deferred(config.name)) as Arc<dyn Adapter>)
            } else {
                HttpAdapter::new(config, transport.clone())
                    .map(|a| Arc::new(a) as Arc<dyn Adapter>)
                    .map_err(|e| error(e.to_string()))
            }
        })
        .collect()
}

#[expect(
    clippy::needless_pass_by_value,
    reason = "Magnus owns strings copied from Ruby under the GVL"
)]
fn validate(configs: String, transport: String) -> Result<bool, Error> {
    let transport: TransportConfig = decode(&transport)?;
    transport.validate().map_err(|e| error(e.to_string()))?;
    drop(adapters(decode(&configs)?, &transport)?);
    Ok(true)
}

impl Engine {
    #[expect(
        clippy::needless_pass_by_value,
        reason = "Magnus owns strings copied from Ruby under the GVL"
    )]
    fn new(config: String, configs: String, transport: String) -> Result<Self, Error> {
        let mut config: Config = decode(&config)?;
        config.acknowledge_completions = true;
        let transport: TransportConfig = decode(&transport)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("lapsoss-delivery")
            .enable_all()
            .build()
            .map_err(|_| error("Could not start Lapsoss runtime"))?;
        let destinations = {
            let _entered = runtime.enter();
            adapters(decode(&configs)?, &transport)?
        };
        let dispatcher = Dispatcher::new(runtime.handle().clone(), config, destinations)
            .map_err(|e| error(e.to_string()))?;
        Ok(Self {
            pid: std::process::id(),
            state: Mutex::new(Some(Box::new(State {
                dispatcher,
                runtime: Some(runtime),
            }))),
            retired: Mutex::new(None),
        })
    }

    fn state(&self) -> Result<MutexGuard<'_, Option<Box<State>>>, Error> {
        if self.pid != std::process::id() {
            return Err(error(
                "Lapsoss dispatcher inherited across fork; shutdown before fork and configure again in the child",
            ));
        }
        self.state
            .lock()
            .map_err(|_| error("Lapsoss native state poisoned"))
    }

    fn with<T>(&self, action: impl FnOnce(&Dispatcher) -> T) -> Result<T, Error> {
        // Snapshot the dispatcher, then release the FFI mutex before invoking
        // core code. Core synchronization is independent of Ruby ownership.
        let dispatcher = self
            .state()?
            .as_ref()
            .ok_or_else(|| error("Lapsoss dispatcher is disposed"))?
            .dispatcher
            .clone();
        Ok(action(&dispatcher))
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "Magnus owns strings copied from Ruby under the GVL"
    )]
    fn submit(&self, event: String, names: String) -> Result<Option<u64>, Error> {
        let event: Event = decode(&event)?;
        let names: Vec<String> = decode(&names)?;
        self.with(|dispatcher| dispatcher.submit_to(event, &names))?
            .map(|receipt| Some(receipt.sequence))
            .or_else(|error_value| match error_value {
                lapsoss::SubmitError::Closed | lapsoss::SubmitError::Full => Ok(None),
                other => Err(error(other.to_string())),
            })
    }

    fn poll(&self) -> Result<String, Error> {
        let completions = self.with(Dispatcher::take_completions)?;
        serde_json::to_string(&completions).map_err(|_| error("Could not encode completions"))
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "Magnus owns strings copied from Ruby under the GVL"
    )]
    fn replace_adapters(&self, configs: String, transport: String) -> Result<(), Error> {
        let destinations = adapters(decode(&configs)?, &decode(&transport)?)?;
        self.with(|d| d.replace_adapters(destinations))?
            .map_err(|e| error(e.to_string()))
    }

    fn acknowledge(&self, sequence: u64) -> Result<(), Error> {
        self.with(|d| d.acknowledge(sequence))
    }

    fn watermark(&self) -> Result<u64, Error> {
        self.with(Dispatcher::watermark)
    }
    fn settled(&self, sequence: u64) -> Result<bool, Error> {
        self.with(|d| d.is_settled(sequence))
    }
    fn close(&self) -> Result<(), Error> {
        self.with(Dispatcher::close)
    }
    fn cancel(&self) -> Result<(), Error> {
        self.with(Dispatcher::cancel)
    }
    fn statistics(&self) -> Result<String, Error> {
        serde_json::to_string(&self.with(Dispatcher::statistics)?)
            .map_err(|_| error("Could not encode statistics"))
    }
    fn dispose(&self) -> Result<(), Error> {
        let state = self.state()?.take();
        if let Some(mut state) = state {
            // Join Tokio workers on a native retirement thread. Ruby polls
            // disposed? with sleep, so no runtime teardown holds the GVL.
            let task = std::thread::spawn(move || {
                state.dispatcher.cancel();
                if let Some(runtime) = state.runtime.take() {
                    runtime.shutdown_timeout(Duration::from_secs(1));
                }
            });
            *self
                .retired
                .lock()
                .map_err(|_| error("Lapsoss retirement state poisoned"))? = Some(task);
        }
        Ok(())
    }

    fn disposed(&self) -> Result<bool, Error> {
        drop(self.state()?); // Includes the fork guard before any mutex access.
        Ok(self
            .retired
            .lock()
            .map_err(|_| error("Lapsoss retirement state poisoned"))?
            .as_ref()
            .is_some_and(JoinHandle::is_finished))
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let lapsoss = ruby.define_module("Lapsoss")?;
    let native = lapsoss.define_module("Native")?;
    native.define_singleton_method("validate", function!(validate, 2))?;
    let engine = native.define_class("Engine", ruby.class_object())?;
    engine.define_singleton_method("new", function!(Engine::new, 3))?;
    engine.define_method("submit", method!(Engine::submit, 2))?;
    engine.define_method("poll", method!(Engine::poll, 0))?;
    engine.define_method("replace_adapters", method!(Engine::replace_adapters, 2))?;
    engine.define_method("acknowledge", method!(Engine::acknowledge, 1))?;
    engine.define_method("watermark", method!(Engine::watermark, 0))?;
    engine.define_method("settled?", method!(Engine::settled, 1))?;
    engine.define_method("close", method!(Engine::close, 0))?;
    engine.define_method("cancel", method!(Engine::cancel, 0))?;
    engine.define_method("statistics", method!(Engine::statistics, 0))?;
    engine.define_method("dispose", method!(Engine::dispose, 0))?;
    engine.define_method("disposed?", method!(Engine::disposed, 0))?;
    Ok(())
}
