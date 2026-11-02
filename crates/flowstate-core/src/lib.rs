//! Flowstate core: the platform-independent dictation pipeline.

pub mod cleanup;
pub mod context;
pub mod filter;
pub mod history;
pub mod notes;
pub mod pipeline;
pub mod stt;
pub mod tier;
pub mod vocab;

pub use cleanup::CleanupMode;
pub use context::DictationContext;
pub use pipeline::{DictationResult, Pipeline};
