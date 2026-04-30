# ont-merge

**Languages**: [English](./README.md) | [日本語](./README.ja.md)

Merge per-sample MinKNOW Oxford Nanopore Technologies (ONT) `fastq.gz` chunks into one file
per sample named `<run-name>_<sample-name>.fastq.gz`, copy MinKNOW's `report_*` artifacts
alongside, and record full provenance — all driven by a single Illumina-style sample sheet.

## Background

On Oxford Nanopore Technologies (ONT) sequencers (PromethION / GridION / MinION), when
basecalling runs concurrently with sequencing, MinKNOW emits **time-sliced `fastq.gz` chunks**
into `fastq_pass/`. With **native_barcoding** kits the chunks are further split into per-barcode
subdirectories (`barcode01/`, `barcode02/`, ...). With **ligation** kits there is no per-barcode
split and chunks land directly under `fastq_pass/`.

For downstream analysis, per sample, we almost always want:

1. **One merged `.fastq.gz`** instead of dozens of time-sliced chunks
2. **A human-readable, sample-specific filename** so that visibility and traceability across
   the rest of the analysis are preserved

ONT does not ship a tool that does both in one step.

The Illumina ecosystem effectively solved this years ago: the wet lab fills in a single sample
sheet, `bcl2fastq` (or `bcl-convert`) reads it, and the output is one sample-named FASTQ per
sample. The same sample sheet doubles as a hub for linking each FASTQ to its experimental and
run-condition metadata. We wanted that exact pattern on the ONT side, ending in a merged FASTQ
that already carries the sample name.

`ont-merge` is **intentionally minimal**: a CSV sample sheet plus a single bash script. No
conda environment, no Nextflow runtime, no Python interpreter — just what ships with a stock
Linux toolchain, so any wet researcher (and any future you) can read both the sheet and the
script end to end.

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
    └── toydata/                                         # real-size reference (fastq + matched sheet)
        ├── 20260225_P_N11424_conditionAB_t/   # MinKNOW run dir copy (~93 MB)
        └── conditionAB_t.samplesheet.csv      # paired sample sheet (points into toydata)
```

## Usage

```bash
# 1. Smoke test with bundled dummy fixtures
bash tests/dummydata/make_dummy.sh
bash ont-merge.sh -s tests/dummydata/native.samplesheet.csv   -o output/_smoke_native
bash ont-merge.sh -s tests/dummydata/ligation.samplesheet.csv -o output/_smoke_ligation

# 1b. (Optional) End-to-end check against the real-size toydata copy
bash ont-merge.sh -s tests/toydata/conditionAB_t.samplesheet.csv \
                  -o output/_toydata_flashseq

# 2. Real run: build a sample sheet from the template, then merge.
#    The script snapshots the input sheet to <out_dir>/_used_<basename>.csv,
#    so there is no need to keep the original sheet under any specific dir;
#    the per-run output directory is self-describing.
cp samplesheet.example.csv my_run.samplesheet.csv
$EDITOR my_run.samplesheet.csv
OUT="output/$(date +%Y%m%d_%H%M%S)_my_run"
bash ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -n   # dry-run
bash ont-merge.sh -s my_run.samplesheet.csv -o "$OUT"      # real

# 3. Re-run on the same out_dir (must use -f to overwrite)
bash ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -f
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

TBD.
