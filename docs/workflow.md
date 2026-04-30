# ont-merge workflow

`ont-merge.sh` のデータフローと、各 step を担う関数の所在を 1 枚で俯瞰するための文書。

## 1. 全体俯瞰

```
                     ┌──────────────────────────┐
                     │  samplesheet.csv (1 run) │  Illumina-style sections
                     │   [Header]               │  - free-form (ignored)
                     │   [Run]                  │  - fastq_dir / kit / run-name
                     │   [Samples]              │  - barcode-number,sample-name
                     └────────────┬─────────────┘
                                  │ awk-based parser
                ┌─────────────────┴─────────────────┐
                ▼                                   ▼
   ┌──────────────────────────┐     ┌──────────────────────────┐
   │   parse_run_section()    │     │  parse_samples_section() │
   │   -> fastq_dir, kit,     │     │   -> filtered rows by    │
   │      run-name            │     │      kit (TSV stream)    │
   └────────────┬─────────────┘     └────────────┬─────────────┘
                │                                │
                └────────────┬───────────────────┘
                             │ kit dispatch
              ┌──────────────┼──────────────────┐
              ▼              ▼                  ▼
   ┌─────────────────┐ ┌─────────────────┐ ┌──────────────────┐
   │ merge_chunks()  │ │ copy_reports()  │ │ write_provenance │
   │  cat *.fastq.gz │ │  run_dir/       │ │  + samplesheet   │
   │  -> dest        │ │   report_* -> p │ │    snapshot      │
   └────────┬────────┘ └────────┬────────┘ └────────┬─────────┘
            │                   │                   │
            └─────────┬─────────┴─────────┬─────────┘
                      ▼                   ▼
        ┌────────────────────────────────────────────────┐
        │                   out_dir/                     │
        │   <run>_<sample>.fastq.gz                      │
        │   <run>__report_*.{html,json,md}               │
        │   _provenance.txt                              │
        │   _used_<samplesheet_basename>                 │
        └────────────────────────────────────────────────┘
```

## 2. Per-kit data flow

### 2-1. Native barcoding kit

```
fastq_pass/
├── barcode01/                          ┐
│   ├── PBC_*_barcode01_chunk0.fastq.gz │  cat *.fastq.gz
│   └── PBC_*_barcode01_chunk1.fastq.gz │  > <run>_<sampleA>.fastq.gz
│   ...                                 ┘
├── barcode02/                          ┐  cat *.fastq.gz
│   └── ...                             ┘  > <run>_<sampleB>.fastq.gz
└── unclassified/                       (ignored unless listed in [Samples])

run_dir/                                ┐  cp report_*
├── report_PBC_*.html                   │  -> <run>__report_PBC_*.html
├── report_PBC_*.json                   │  -> <run>__report_PBC_*.json
└── report_PBC_*.md                     ┘  -> <run>__report_PBC_*.md
```

### 2-2. Ligation kit

```
fastq_pass/
├── PBK_*_chunk0.fastq.gz               ┐
├── PBK_*_chunk1.fastq.gz               │  cat *.fastq.gz
├── PBK_*_chunk2.fastq.gz               │  > <run>_<sampleC>.fastq.gz
└── PBK_*_chunk3.fastq.gz               ┘  (single sample row in [Samples])

run_dir/                                ┐  cp report_*
├── report_PBK_*.html                   │  -> <run>__report_PBK_*.html
├── report_PBK_*.json                   │  -> <run>__report_PBK_*.json
└── report_PBK_*.md                     ┘  -> <run>__report_PBK_*.md
```

## 3. Source map

| Step                              | Function in `ont-merge.sh`         | Notes |
|-----------------------------------|--------------------------------------|-------|
| CLI parsing                       | top-level `while` loop               | `-s`, `-o`, `-n`, `-f`, `-h` |
| Parse `[Run]` section             | `parse_run_section()` (awk)          | yields TSV `<key>\t<value>` for fastq_dir / kit / run-name |
| Parse `[Samples]` section         | `parse_samples_section()` (awk)      | header skip, kit-aware row filter, yields TSV `<barcode>\t<sample>` |
| Validate `[Run]` keys             | inline, after parsing                | required: fastq_dir, kit, run-name; existence and value checks |
| Ligation row-count check          | inline, after parsing samples        | ligation must yield exactly 1 sample row |
| Provenance + samplesheet snapshot | `write_provenance()` + `cp`          | runs only when not in dry-run |
| Chunk merge                       | `merge_chunks()`                     | `cat`-based concat; honors dry-run + overwrite |
| Report copy                       | `copy_reports()`                     | `report_*` glob in `dirname(fastq_dir)` |
| Destination existence check       | `check_dest()`                       | shared by merge, report, snapshot paths |
| Logging                           | `log()`                              | timestamped, stderr only |

## 4. Side-effect contract

| Side effect                                    | When                       |
|------------------------------------------------|----------------------------|
| Create `out_dir`                               | only if not in `--dry-run` |
| Write `<run>_<sample>.fastq.gz`                | only if not in `--dry-run` |
| Copy `<run>__report_*`                         | only if not in `--dry-run` |
| Write `_provenance.txt`                        | only if not in `--dry-run` |
| Copy samplesheet -> `_used_<original_samplesheet_filename>`    | only if not in `--dry-run` |
| Read source `fastq_dir`                        | always                     |
| Modify source `fastq_dir`                      | **never**                  |
| Exit non-zero on first error                   | always (`set -euo pipefail`) |

## 5. Failure modes (intentional)

| Condition                                       | Behavior                                                       |
|-------------------------------------------------|----------------------------------------------------------------|
| `[Run].fastq_dir` missing                       | `exit 2`                                                        |
| `[Run].kit` missing                             | `exit 2`                                                        |
| `[Run].run-name` missing                        | `exit 2`                                                        |
| `fastq_dir` does not exist                      | `exit 1`                                                        |
| Unknown `kit` value                             | `exit 1`                                                        |
| `[Samples]` yields no rows for the kit          | `exit 1`                                                        |
| Ligation `[Samples]` has !=1 rows               | `exit 1`                                                        |
| Output destination already exists, no `-f`      | `exit 1` (run leaves whatever was already written)              |
| No `report_*` in run dir                        | warning only (continues). Expected during in-progress runs;     |
|                                                 | re-run with `-f` after the run finishes to pick up the reports. |
