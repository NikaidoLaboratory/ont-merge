# ont-merge

**Languages**: [English](./README.md) | [日本語](./README.ja.md)

Merge per-sample MinKNOW Oxford Nanopore Technologies (ONT) `fastq.gz` chunks into one file
per sample named `<run-name>_<sample-name>.fastq.gz`, copy MinKNOW's `report_*` artifacts
alongside, and record full provenance — all driven by a single Illumina-style sample sheet.

## Background

On Oxford Nanopore Technologies (ONT) sequencers (PromethION / GridION / MinION),
when basecalling is performed concurrently with sequencing, MinKNOW writes
**time-sliced `fastq.gz` chunks** into `fastq_pass/`. Under **native_barcoding**
chemistries the chunks are further partitioned into per-barcode subdirectories
(`barcode01/`, `barcode02/`, ...), whereas under **ligation** chemistries no
per-barcode subdirectory is created and chunks are written directly under
`fastq_pass/`.

For downstream analysis, the typical per-sample requirements are as follows:

1. **A single merged `.fastq.gz`**, in place of the time-sliced chunks
2. **A human-readable, sample-specific filename**, so that visibility and
   traceability are preserved across the rest of the analysis

The official ONT ecosystem already provides most of the constituent
capabilities needed to satisfy these requirements. MinKNOW supports sample-sheet
ingestion at run start, propagating the `alias` field into folder names, FASTQ
headers, and the `sequencing_summary` file. Dorado offers a `--sample-sheet`
option for sample-aware basecall output. The EPI2ME Labs `fastcat` tool
sanitises and concatenates per-sample chunks. The EPI2ME / `wf-*` Nextflow
workflows orchestrate the full pipeline given a `barcode,alias` CSV. These
components, however, operate at slightly different layers from the niche
addressed in this work: a MinKNOW samplesheet must be configured **before** a
run begins and cannot be applied retroactively; `dorado --sample-sheet` performs
basecalling from POD5, which is computationally redundant when concurrent
basecalling has already produced the corresponding FASTQ output; `fastcat` is
invoked once per sample rather than consuming a multi-sample sheet directly;
and the EPI2ME workflows require a Nextflow plus Docker/Singularity runtime.

In practice, combining these components leaves a usability gap. The wet-lab
side is required to prepare separate metadata at each stage — a MinKNOW
samplesheet at run start, basecaller arguments, demultiplexing parameters, and
a workflow-specific samplesheet downstream — and the dry-lab side, in turn,
must orchestrate several discrete steps before a per-sample, sample-named
FASTQ is in hand. Holding the metadata in this fragmented form also complicates
its reuse in subsequent analyses. From the experimenter's perspective, the
preferable arrangement is straightforward: a single metadata sheet, populated
once, from which a ready-to-use per-sample `<run-name>_<sample-name>.fastq.gz`
follows directly — the same pattern that the Illumina ecosystem already
realises, where `bcl2fastq` / `bcl-convert` consumes a single `SampleSheet.csv`
and emits per-sample FASTQ in a single step.

`ont-merge` is intended to fill exactly this gap on the ONT side: a single
Illumina-style sample sheet drives both chunk merging and sample-aware renaming
for already-basecalled MinKNOW output, without additional runtime or per-stage
configuration. It is positioned as a complement to, not a replacement for, the
official ONT tooling described above.

The implementation is deliberately minimal: a CSV sample sheet together with a
single bash script. No conda environment, Nextflow runtime, or Python
interpreter is required — only the standard Linux toolchain — so that both the
sample sheet and the script can be inspected end-to-end by wet-lab investigators
as well as by future maintainers.

## Purpose

- One sample sheet = one source of truth: wet-lab fills it in, dry-lab runs it
- Emit one merged `.fastq.gz` per sample with a canonical, metadata-driven name
- Carry over `report_*.{html,json,md}` from MinKNOW into the same output folder
- Always record provenance into the output directory (no manual logging needed)

## Specifications

### Supported kits

| `kit` value         | Layout under `fastq_pass/`                          |
|---------------------|-----------------------------------------------------|
| `native_barcoding`  | per-barcode subdirs: `barcode01/`, `barcode02/`, ...|
| `ligation`          | `.fastq.gz` placed directly (no subdir)             |

### Sample sheet (Illumina-style, CSV)

One sheet = one sequencing run. Lines starting with `#` and blank lines are ignored.

**Example: native_barcoding kit** (multiple barcodes per run)

```csv
[Header]
project,Condition AB trial 1
date,2026-02-25
operator,
description,Native barcoding run with two conditions, first trial

[Run]
fastq_dir,/var/lib/minknow/data/.../fastq_pass
kit,native_barcoding
run-name,20260225-conditionAB-trial1

[Samples]
barcode-number,sample-name
barcode11,sampleA
barcode12,sampleB
```

**Example: ligation kit** (single sample per run, no barcode subdir under `fastq_pass/`)

```csv
[Header]
project,Single-sample ligation run
date,2026-04-28
operator,
description,Ligation kit - single sample run

[Run]
fastq_dir,/var/lib/minknow/data/.../fastq_pass
kit,ligation
run-name,20260428-ligation-run

[Samples]
barcode-number,sample-name
none,kawa-curio-rep2
```

For ligation runs, `barcode-number` is `none` (or empty) and `[Samples]` must contain
exactly one data row — there is no per-barcode demultiplexing on the MinKNOW side.

| Section     | Parsed? | Notes                                                              |
|-------------|---------|--------------------------------------------------------------------|
| `[Header]`  | no      | Free-form metadata for humans                                      |
| `[Run]`     | yes     | Required keys: `fastq_dir`, `kit`, `run-name`                      |
| `[Samples]` | yes     | Fixed header `barcode-number,sample-name`. Rows are kit-filtered:  |
|             |         | `native_barcoding` -> rows like `barcodeNN`                        |
|             |         | `ligation`         -> rows with `none` or empty (exactly 1 row)    |

### Adding wet-lab metadata columns

The `[Samples]` section accepts **extra columns beyond the required `barcode-number,sample-name`**.
The parser only reads columns 1 and 2; everything from column 3 onward is ignored at run time but
preserved verbatim in the snapshot `_used_<original_samplesheet_filename>`. This lets the wet lab
record condition / replicate / note / anything in the same single sheet without affecting the merge.

```csv
[Samples]
barcode-number,sample-name,note,replicate,condition
barcode11,sampleA_75sec_1,baseline buffer,rep1,75sec
barcode12,sampleA_75sec_2,"buffer X, treated",rep2,75sec
```

- Column names (`note`, `replicate`, `condition`, ...) are free-form
- If a value contains a comma, wrap it in double quotes (Excel handles quoting automatically when you save as CSV)
- Downstream analyses can read the snapshot `_used_*.csv` to recover the full metadata
- The script itself does not consume these columns today; if a future analysis step needs them (e.g. group-by condition), the parser can be extended without touching the sheet format

### Outputs (in `out_dir`)

| File                                                  | Source                                  |
|-------------------------------------------------------|-----------------------------------------|
| `<run-name>_<sample-name>.fastq.gz`                   | `cat`-merged chunks                     |
| `<run-name>__<original_report_filename>`              | `report_*` files in run dir             |
| `_provenance.txt`                                     | execution metadata + parsed [Run]       |
| `_used_<original_samplesheet_filename>`                               | snapshot of the input sample sheet      |

The `__` (double underscore) on report names prevents collisions when several runs share the
same `out_dir`.

## Components

```
ont-merge/
├── ont-merge.sh                                       # main script (bash)
├── samplesheet.example.csv                              # sample sheet template
├── docs/workflow.md                                     # data flow diagram
└── tests/                                               # smoke-test fixtures
    ├── dummydata/                                       # generated dummy data
    │   ├── make_dummy.sh                                # generator
    │   ├── native.samplesheet.csv                       # smoke (native_barcoding)
    │   ├── ligation.samplesheet.csv                     # smoke (ligation)
    │   ├── native_barcoding/                            # generated fastq tree
    │   └── ligation/                                    # generated fastq tree
    └── toydata/                                         # real-size reference (FASTQ + matched sheet, ~3 MB tracked)
        ├── 20260225_P_N11424_conditionAB_t/   # MinKNOW run dir copy: FASTQ trees only (pod5 / MinKNOW metadata excluded via .gitignore)
        └── conditionAB_t.samplesheet.csv      # paired sample sheet (points into toydata)
```

## Usage

```bash
git clone git@github.com:NikaidoLaboratory/ont-merge.git
cd ont-merge

# Smoke test against the bundled toydata (real-size fixture, ~3 MB)
./ont-merge.sh -s tests/toydata/conditionAB_t.samplesheet.csv \
               -o output/_smoke_toydata

# Real run
cp samplesheet.example.csv my_run.samplesheet.csv
$EDITOR my_run.samplesheet.csv
OUT="output/$(date +%Y%m%d_%H%M%S)_my_run"
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -n   # dry-run preview
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT"      # real

# Re-run on the same out_dir (use -f to overwrite)
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -f
```

### Optional: tiny synthetic fixture (regenerates dummy data)

```bash
bash tests/dummydata/make_dummy.sh
./ont-merge.sh -s tests/dummydata/native.samplesheet.csv   -o output/_smoke_native
./ont-merge.sh -s tests/dummydata/ligation.samplesheet.csv -o output/_smoke_ligation
```

### CLI options

| Flag | Long             | Required | Description                                 |
|------|------------------|----------|---------------------------------------------|
| `-s` | `--samplesheet`  | yes      | Path to the sample sheet CSV                |
| `-o` | `--out-dir`      | yes      | Output directory (created if missing)       |
| `-n` | `--dry-run`      | no       | Print planned actions; do not write         |
| `-f` | `--overwrite`    | no       | Overwrite existing output files             |
| `-h` | `--help`         | no       | Show usage and exit                         |

## Notes

- Merging uses `cat a.gz b.gz > c.gz` — gzip streams are concatenable, so the result is a valid
  gzip readable by `zcat`/`gunzip` and any FASTQ tool. No re-compression cost.
- The script never writes under the source `fastq_dir`; source data is treated as read-only.
- `other_reports/` (and other subdirectories of the run dir) are *not* copied by default — only
  files whose names start with `report_`.
- The chunk read order in the merged output follows the lexicographic order of the chunk
  filenames, which is what `cat *.fastq.gz` resolves to.
- **Why `report_*` may be absent**: MinKNOW writes `report_*.{html,json,md}` only at the end
  of a sequencing run. If you invoke this script while a run is still in progress, those files
  do not yet exist; the script logs a warning and skips the report-copy step (the FASTQ merge
  is unaffected). After the run finishes, re-run with `-f` to overwrite and pick up the
  reports.
- **Provenance**: every real (non-dry-run) execution writes `_provenance.txt` (timestamp,
  user@host, script path + mtime, parsed `[Run]` and kit-filtered `[Samples]`) and snapshots
  the input sheet to `_used_<original_samplesheet_filename>`. The output directory is therefore self-describing
  — anyone (or future you) can inspect it and know exactly where the data came from and how it
  was produced.

## License

MIT — see [LICENSE](./LICENSE).
