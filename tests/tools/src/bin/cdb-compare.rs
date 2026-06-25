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
use bear_test_tools::compare::compare;

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
}

impl NormalizationArgs {
    fn into_normalization(self, sort: bool) -> Normalization {
        Normalization {
            sort,
            substitute_compiler: self.substitute_compiler,
            relativize_paths: self.relativize_paths,
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

fn run_compare(args: CompareArgs) -> Result<ExitCode> {
    let norm = args.normalization.into_normalization(false);
    let mut a = load(&args.a)?;
    let mut b = load(&args.b)?;
    a.normalize(&norm);
    b.normalize(&norm);

    let report = compare(&a, &b);
    match args.format {
        Format::Human => print!("{}", report.to_human()),
        Format::Json => {
            println!("{}", serde_json::to_string_pretty(&report).context("failed to serialize report")?)
        }
    }

    Ok(if report.is_equivalent() { ExitCode::SUCCESS } else { ExitCode::FAILURE })
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
