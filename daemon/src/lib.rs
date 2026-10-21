//! Local, bounded aggregation with transactional admission and recovery.

pub mod policy;
pub mod server;
pub mod service;
mod store;

#[cfg(test)]
mod test_support;
