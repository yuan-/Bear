// SPDX-License-Identifier: GPL-3.0-or-later

//! `cdb-compare`: compare or normalize Clang JSON compilation databases.
//!
//! `compare` decides equivalence as an order-independent multiset comparison
//! over normalized entries and prints a three-set diff report; it exits
//! non-zero on non-equivalence so it composes as a shell gate. `normalize`
//! emits a canonical database, the way a golden manifest is produced.

use std::fs::File;
use std::io::{self, BufWriter};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};

use bear_test_tools::cdb::{CompilationDatabase, Normalization};
use bear_test_tools::compare::{DiffReport, compare};

#[derive(Debug, Parser)]
#[command(name = "cdb-compare", about = "Compare or normalize JSON compilation databases")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Compare two databases for multiset equivalence (order-independent).
    Compare(CompareArgs),
    /// Emit a canonical compilation database (for golden manifests).
    Normalize(NormalizeArgs),
}

/// Normalization flags shared by both subcommands. Every operation is off by
/// default; pass the corresponding flag to enable it.
#[derive(Debug, Args)]
struct NormalizationArgs {
    /// Replace the first argument (compiler driver) with this value.
    #[arg(long, value_name = "VALUE")]
    substitute_compiler: Option<String>,
    /// Rebase absolute paths against this root.
    #[arg(long, value_name = "ROOT")]
    relativize_paths: Option<PathBuf>,
    /// Rewrite each entry's `output` to the absolute object path derived from
    /// its `-o` argument resolved against `directory`.
    #[arg(long)]
    output_from_o: bool,
    /// Strip the dependency-file flags (`-MD`/`-MMD`/`-MP` and the
    /// argument-consuming `-MF`/`-MT`/`-MQ`/`-MJ`) from `arguments`.
    #[arg(long)]
    drop_dependency_flags: bool,
}

impl NormalizationArgs {
    fn into_normalization(self, sort: bool) -> Normalization {
        Normalization {
            sort,
            substitute_compiler: self.substitute_compiler,
            relativize_paths: self.relativize_paths,
            output_from_o: self.output_from_o,
            drop_dependency_flags: self.drop_dependency_flags,
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Format {
    Human,
    Json,
}

#[derive(Debug, Args)]
struct CompareArgs {
    #[command(flatten)]
    normalization: NormalizationArgs,
    /// Report format.
    #[arg(long, value_enum, default_value_t = Format::Human)]
    format: Format,
    /// Gate the exit code on the `differing` set only: entries present on just
    /// one side are reported as advisory extras but do not fail the comparison.
    #[arg(long)]
    intersection: bool,
    /// First database.
    a: PathBuf,
    /// Second database.
    b: PathBuf,
}

#[derive(Debug, Args)]
struct NormalizeArgs {
    /// Emit entries in a canonical order.
    #[arg(long)]
    sort: bool,
    #[command(flatten)]
    normalization: NormalizationArgs,
    /// Input database.
    input: PathBuf,
    /// Output file; defaults to stdout.
    #[arg(short = 'o', long, value_name = "FILE")]
    output: Option<PathBuf>,
}

fn load(path: &Path) -> Result<CompilationDatabase> {
    let file = File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    CompilationDatabase::from_reader(file).with_context(|| format!("failed to read {}", path.display()))
}

/// A four-number tally of a comparison, computed at the CLI layer from the
/// report plus the side-A length (the report itself carries no matched total,
/// since fully-equal matched entries cancel during comparison).
struct Summary {
    matched: usize,
    only_in_a: usize,
    only_in_b: usize,
    differing: usize,
}

impl Summary {
    /// `matched` (matched-equal plus differing) is everything in A that did not
    /// fall into `only_in_a`.
    fn from_report(report: &DiffReport, a_len: usize) -> Self {
        Summary {
            matched: a_len - report.only_in_a.len(),
            only_in_a: report.only_in_a.len(),
            only_in_b: report.only_in_b.len(),
            differing: report.differing.len(),
        }
    }

    /// One-line tally for the human report. `only_in_a`/`only_in_b` are labelled
    /// Bear-only/CMake-only after the oracle invocation order `bear.json cmake.json`.
    fn to_line(&self) -> String {
        format!(
            "summary: matched={} differing={} Bear-only={} CMake-only={}\n",
            self.matched, self.differing, self.only_in_a, self.only_in_b
        )
    }
}

/// Decide the exit code from a report. Without `intersection` (the default) any
/// non-empty set fails; with it the gate is the `differing` set alone, so
/// only-on-one-side extras are advisory. Intersection additionally requires
/// non-vacuity: at least one TU must have matched, otherwise a comparison that
/// paired nothing (e.g. a missing normalization that breaks matching) has an
/// empty `differing` set and would pass green having compared nothing.
fn gate_succeeds(report: &DiffReport, intersection: bool, matched: usize) -> bool {
    if intersection { report.differing.is_empty() && matched > 0 } else { report.is_equivalent() }
}

fn run_compare(args: CompareArgs) -> Result<ExitCode> {
    let norm = args.normalization.into_normalization(false);
    let mut a = load(&args.a)?;
    let mut b = load(&args.b)?;
    a.normalize(&norm);
    b.normalize(&norm);

    let report = compare(&a, &b);
    let summary = Summary::from_report(&report, a.entries.len());
    match args.format {
        Format::Human => {
            print!("{}", report.to_human());
            if args.intersection {
                print!("{}", summary.to_line());
            }
        }
        Format::Json => {
            println!("{}", serde_json::to_string_pretty(&report).context("failed to serialize report")?)
        }
    }

    // Diagnose the vacuous intersection on stderr so it never corrupts the
    // stdout report (which may be JSON the caller archives).
    if args.intersection && summary.matched == 0 {
        eprintln!("no translation units matched; the intersection is empty - nothing was compared");
    }

    Ok(if gate_succeeds(&report, args.intersection, summary.matched) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

fn run_normalize(args: NormalizeArgs) -> Result<ExitCode> {
    let sort = args.sort;
    let norm = args.normalization.into_normalization(sort);
    let mut db = load(&args.input)?;
    db.normalize(&norm);

    match args.output {
        Some(path) => {
            let file = File::create(&path).with_context(|| format!("failed to create {}", path.display()))?;
            db.to_writer(BufWriter::new(file))
                .with_context(|| format!("failed to write {}", path.display()))?;
        }
        None => db.to_writer(io::stdout().lock()).context("failed to write to stdout")?,
    }

    Ok(ExitCode::SUCCESS)
}

fn main() -> Result<ExitCode> {
    let cli = Cli::parse();
    match cli.command {
        Command::Compare(args) => run_compare(args),
        Command::Normalize(args) => run_normalize(args),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bear_test_tools::cdb::Entry;

    fn entry(file: &str) -> Entry {
        Entry {
            directory: "/w".to_string(),
            file: file.to_string(),
            arguments: vec!["cc".to_string(), "-c".to_string(), file.to_string()],
            output: Some("a.o".to_string()),
        }
    }

    /// A report with extras on both sides but no matched-but-differing entries -
    /// the discriminating case between the default gate and `--intersection`.
    fn report_with_extras_only() -> DiffReport {
        DiffReport {
            only_in_a: vec![entry("/w/a.c")],
            only_in_b: vec![entry("/w/b.c")],
            differing: Vec::new(),
        }
    }

    /// A report whose only divergence is a matched-but-differing entry - the
    /// case the intersection gate must still fail on.
    fn report_with_differing_only() -> DiffReport {
        use bear_test_tools::compare::DifferingEntry;
        DiffReport {
            only_in_a: Vec::new(),
            only_in_b: Vec::new(),
            differing: vec![DifferingEntry {
                file: "/w/a.c".to_string(),
                output: Some("a.o".to_string()),
                a_directory: "/w".to_string(),
                b_directory: "/w".to_string(),
                a_arguments: vec!["cc".to_string(), "-O0".to_string()],
                b_arguments: vec!["cc".to_string(), "-O2".to_string()],
            }],
        }
    }

    #[test]
    fn intersection_gate_passes_when_only_extras_differ() {
        // Empty `differing` and a non-empty match set (matched > 0): the extras
        // are advisory under intersection, but still fail the default gate.
        let sut = report_with_extras_only();

        assert!(gate_succeeds(&sut, true, 2));
        assert!(!gate_succeeds(&sut, false, 2));
    }

    #[test]
    fn intersection_gate_fails_when_differing_is_non_empty() {
        let sut = report_with_differing_only();

        assert!(!gate_succeeds(&sut, true, 1));
        assert!(!gate_succeeds(&sut, false, 1));
    }

    #[test]
    fn intersection_gate_fails_when_nothing_matched() {
        // The same extras-only report, but with zero matched TUs (everything in
        // A is exclusive to A): the intersection is vacuous, so the gate must
        // not pass despite an empty `differing` set.
        let sut = report_with_extras_only();

        assert!(!gate_succeeds(&sut, true, 0));
    }

    #[test]
    fn summary_counts_matched_as_a_len_minus_only_in_a() {
        // Side A had three entries; one fell into only_in_a, so two matched.
        let report = report_with_extras_only();

        let sut = Summary::from_report(&report, 3);

        assert_eq!(sut.matched, 2);
        assert_eq!(sut.only_in_a, 1);
        assert_eq!(sut.only_in_b, 1);
        assert_eq!(sut.differing, 0);
    }
}
