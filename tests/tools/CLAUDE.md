## tests/tools

Shared test tooling. The library exposes the compilation-database comparison
and normalization logic; the binary `cdb-compare` wraps it.

## Why a separate crate

`tests/integration` depends on this library so there is one comparison
implementation, not two. `CompilationEntryMatcher` lives here and is
re-exported by the integration fixtures. Future test binaries (the dogfooding
harness) layer on the same library.

## Constraints

- ASCII only; SPDX header on every `.rs` file (see `.claude/rules/rust.md`).
- Keep dependencies minimal; prefer crates already in the workspace.
- Tests are host-independent: they operate on in-memory or small fixture CDB
  JSON, never a live build or container.

## cdb-compare

- `compare [--substitute-compiler V] [--relativize-paths ROOT] [--format human|json] A B`
  decides multiset equivalence (order-independent) and exits non-zero on
  non-equivalence.
- `normalize [--sort] [--substitute-compiler V] [--relativize-paths ROOT] IN [-o OUT]`
  emits a canonical database (how a golden manifest is produced).

Normalization operations are individually toggleable and off by default.
