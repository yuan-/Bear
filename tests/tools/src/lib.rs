// SPDX-License-Identifier: GPL-3.0-or-later

//! Shared test tooling for the Bear project.
//!
//! This crate exposes the compilation-database comparison and normalization
//! logic as a library, and produces the `cdb-compare` binary on top of it. The
//! integration suite (`tests/integration`) depends on this library so there is
//! a single comparison implementation, not two.

pub mod cdb;
pub mod compare;
pub mod invariants;
pub mod matcher;
pub mod sample;

pub use cdb::{CdbError, CompilationDatabase, Entry, Normalization};
pub use compare::{DiffReport, DifferingEntry, compare};
pub use invariants::{Check, CountExpectation, InvariantsReport, Offender, Status};
pub use matcher::CompilationEntryMatcher;
