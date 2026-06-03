---
title: Events file as external interchange format
status: proposed
---

## Intent

Bear's `intercept` mode writes a JSON Lines file of captured executions
(default `events.json`), and Bear's `semantic --input <file>` mode reads
the same file to produce a compilation database. The two modes already
ship and work today. What is missing is a written contract: users and
third-party tooling cannot tell which fields are stable, what guarantees
the format makes, or how to produce a synthetic events file (for example,
to convert an existing build log into a compilation database without
re-running the build).

The user expects the events file to be a documented interchange format:
schema, encoding rules, and stability promise written down so external
tools can produce or consume it without reverse-engineering Bear's
sources.

## Acceptance criteria

- One line of the events file is one JSON object describing a single
  execution event. Lines are newline-terminated (`\n`); no comments;
  no trailing comma; UTF-8 encoded.
- The schema for an event object is documented in this requirement and
  pinned to the source-of-truth type in `bear` (link or filename).
- A non-empty subset of fields is marked stable: changes to stable
  fields require a major-version bump of the format. Optional/internal
  fields are marked as such.
- `bear semantic --input <file>` accepts any file conforming to the
  documented schema. The producer of the file does not need to be Bear.
- `bear semantic --input <file>` is order-independent across lines: the
  same set of events in any order yields a `compile_commands.json` with
  the same set of entries (modulo append-order semantics defined by
  `output-append`).
- A non-conforming line (invalid JSON, missing required field, wrong
  type) is reported with line number and reason, and processing
  continues with subsequent lines. The exit code is unchanged unless
  every line is rejected.
- `bear intercept --output -` and `bear semantic --input -` read/write
  the events stream from stdout/stdin respectively, enabling pipelines
  of the form `bear intercept --output - -- make | bear semantic --input -`.
  (Optional; in scope as a stability requirement once implemented.)

## Non-functional constraints

- The format must round-trip: events produced by `bear intercept` must
  always be accepted by `bear semantic --input`. A regression in either
  direction is a bug.
- The format must remain JSON Lines, not a single JSON array. This
  matters for streaming producers and for fault-tolerant readers
  (a truncated file still yields N-1 valid events).
- The schema documentation lives in this requirement file. The Rust
  types in `bear` are authoritative for field names; the documentation
  must be kept in sync (this is checked by reading the types from the
  source on review).

## Testing

Given a synthetic events file produced by a third-party tool that
conforms to the schema:

> When the user runs `bear semantic --input synthetic.json -o cdb.json`,
> then `cdb.json` contains one compilation entry per recognizable
> compiler invocation in the synthetic file.

Given a Bear-produced events file from a successful `bear intercept`
run:

> When the user runs `bear semantic --input events.json` against it,
> then the resulting compilation database is identical to the one
> produced by an equivalent `bear -- <build>` run.

Given an events file with one malformed line in the middle:

> When the user runs `bear semantic --input broken.json`,
> then Bear reports the line number and parse reason,
> processes the surrounding valid lines,
> and writes a compilation database from the valid subset.

Given an events file produced by Bear vN and consumed by Bear vN+1
within the same major-version line:

> When the user runs `bear semantic --input old-events.json` with the
> newer Bear,
> then the run succeeds and produces an equivalent compilation database.

## Notes

- GitHub issue #644 requested a post-processing mode that turns an
  existing build log into a compilation database. The maintainer
  declined to ship a build-log parser (build-system-specific, out of
  scope), but `bear semantic --input` already provides the consumer
  half. This requirement documents the contract so users can build
  their own log-to-events converters.
- Out of scope: a build-log parser. Out of scope: backward compatibility
  guarantees across major versions; those are explicitly allowed to
  break.
- The current event schema is defined by the Rust types in
  `bear/src/intercept/`. Before promoting status to `accepted`, the
  field list and stable-field subset must be enumerated explicitly in
  this requirement (currently a forward reference).
