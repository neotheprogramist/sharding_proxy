//! Re-export StorageCommitment from katana-tee.
//!
//! This module re-exports the StorageCommitment contract so that snforge
//! can find and deploy it in tests.

pub use storage_commitment::{
    IStorageCommitment, IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait,
    StorageCommitment,
};
