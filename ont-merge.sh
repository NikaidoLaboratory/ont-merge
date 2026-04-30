#!/usr/bin/env bash
# ont-merge.sh
# Merge MinKNOW Oxford Nanopore fastq.gz chunks per sample using an
# Illumina-style sample sheet, rename to <run-name>_<sample-name>.fastq.gz,
# and copy report_* files from the run directory. Always writes provenance
# and snapshots the input sample sheet into the output directory.
#
# Sections expected in the sample sheet:
#   [Header]    free-form metadata, ignored by the parser
#   [Run]       key,value rows: fastq_dir, kit, run-name
#   [Samples]   header line "barcode-number,sample-name", then data rows
#
# Note: gzip files are concatenable; `cat a.gz b.gz > c.gz` yields a valid
# gzip stream readable by zcat / gunzip / downstream FASTQ tools.

set -euo pipefail

# ---------- usage ----------
print_usage() {
    cat <<'EOF' >&2
Usage: ont-merge.sh -s <samplesheet.csv> -o <out_dir> [-n] [-f]

  -s, --samplesheet  Illumina-style sample sheet (CSV; sections [Header] [Run] [Samples])
  -o, --out-dir      Output directory (created if missing)
  -n, --dry-run      Print planned actions; do not write
  -f, --overwrite    Overwrite existing output files
  -h, --help         Show this help

One sample sheet = one sequencing run.

[Run] keys (required):
  fastq_dir : absolute path to MinKNOW's fastq_pass directory
  kit       : native_barcoding | ligation
  run-name  : prefix for output filenames

[Samples] header (fixed): barcode-number,sample-name
  native_barcoding -> rows where barcode-number matches /^barcode[0-9]+$/
  ligation         -> rows where barcode-number == "none" or empty (exactly 1 row)

Outputs in <out_dir>:
  <run-name>_<sample-name>.fastq.gz
  <run-name>__<original_report_filename>
  _provenance.txt
  _used_<original_samplesheet_filename>
EOF
}

# ---------- CLI parsing ----------
samplesheet=""
out_dir=""
dry_run=0
overwrite=0

while (( $# > 0 )); do
    case "$1" in
        -s|--samplesheet) samplesheet="${2:?missing value for $1}"; shift 2 ;;
        -o|--out-dir)     out_dir="${2:?missing value for $1}"; shift 2 ;;
        -n|--dry-run)     dry_run=1; shift ;;
        -f|--overwrite)   overwrite=1; shift ;;
        -h|--help)        print_usage; exit 0 ;;
        *) echo "[error] unknown option: $1" >&2; print_usage; exit 2 ;;
    esac
done

[[ -z "${samplesheet}"   ]] && { echo "[error] -s/--samplesheet required" >&2; exit 2; }
[[ -z "${out_dir}"       ]] && { echo "[error] -o/--out-dir required"     >&2; exit 2; }
[[ ! -f "${samplesheet}" ]] && { echo "[error] samplesheet not found: ${samplesheet}" >&2; exit 2; }

# ---------- helpers ----------
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

check_dest() {
    local dest="$1"
    if [[ -e "${dest}" && "${overwrite}" != "1" ]]; then
        echo "[error] destination exists (use -f to overwrite): ${dest}" >&2
        exit 1
    fi
}

merge_chunks() {
    local pattern="$1" dest="$2"
    shopt -s nullglob
    # shellcheck disable=SC2206
    local files=( ${pattern} )
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        echo "[error] no fastq.gz matched: ${pattern}" >&2
        exit 1
    fi
    check_dest "${dest}"
    if (( dry_run )); then
        log "[dry-run] cat ${#files[@]} chunk(s) -> ${dest}"
    else
        cat "${files[@]}" > "${dest}"
        log "merged ${#files[@]} chunk(s) -> ${dest}"
    fi
}

copy_reports() {
    local run_dir="$1" run_name="$2"
    shopt -s nullglob
    local files=( "${run_dir}"/report_* )
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        log "[warn] no report_* in ${run_dir}"
        return 0
    fi
    local src dest
    for src in "${files[@]}"; do
        [[ -f "${src}" ]] || continue
        dest="${out_dir}/${run_name}__$(basename "${src}")"
        check_dest "${dest}"
        if (( dry_run )); then
            log "[dry-run] cp ${src} -> ${dest}"
        else
            cp "${src}" "${dest}"
            log "copied report -> ${dest}"
        fi
    done
}

# Extract [Run] section as TSV: <key>\t<value>
parse_run_section() {
    awk -F',' '
        function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
        /^[[:space:]]*$/  { next }
        /^[[:space:]]*#/  { next }
        /^[[:space:]]*\[/ { in_run = (tolower($0) ~ /^[[:space:]]*\[run\]/); next }
        in_run {
            k = trim($1); v = trim($2)
            if (k != "") print k "\t" v
        }
    ' "$1"
}

# Extract [Samples] data rows as TSV: <barcode>\t<sample>, kit-filtered.
parse_samples_section() {
    awk -F',' -v kit="$2" '
        function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
        /^[[:space:]]*$/  { next }
        /^[[:space:]]*#/  { next }
        /^[[:space:]]*\[/ {
            in_samples  = (tolower($0) ~ /^[[:space:]]*\[samples\]/)
            header_seen = 0
            next
        }
        in_samples && header_seen == 0 { header_seen = 1; next }
        in_samples {
            bc = trim($1); sn = trim($2)
            if (kit == "native_barcoding") {
                if (bc ~ /^barcode[0-9]+$/) print bc "\t" sn
            } else if (kit == "ligation") {
                if (bc == "none" || bc == "") print bc "\t" sn
            }
        }
    ' "$1"
}

# ---------- parse [Run] into bash variables ----------
fastq_dir=""
kit=""
run_name=""
while IFS=$'\t' read -r key value; do
    case "${key}" in
        fastq_dir) fastq_dir="${value}" ;;
        kit)       kit="${value}" ;;
        run-name)  run_name="${value}" ;;
        *) ;;
    esac
done < <(parse_run_section "${samplesheet}")

[[ -z "${fastq_dir}" ]] && { echo "[error] [Run].fastq_dir missing in ${samplesheet}" >&2; exit 2; }
[[ -z "${kit}"       ]] && { echo "[error] [Run].kit missing in ${samplesheet}"       >&2; exit 2; }
[[ -z "${run_name}"  ]] && { echo "[error] [Run].run-name missing in ${samplesheet}"  >&2; exit 2; }
[[ ! -d "${fastq_dir}" ]] && { echo "[error] fastq_dir not found: ${fastq_dir}" >&2; exit 1; }

case "${kit}" in
    native_barcoding|ligation) ;;
    *) echo "[error] unknown kit: ${kit} (expected native_barcoding|ligation)" >&2; exit 1 ;;
esac

run_dir="$(dirname "${fastq_dir}")"

# ---------- parse [Samples] ----------
sample_rows="$(parse_samples_section "${samplesheet}" "${kit}")"
if [[ -z "${sample_rows}" ]]; then
    echo "[error] [Samples] yielded no rows for kit=${kit} in ${samplesheet}" >&2
    exit 1
fi

if [[ "${kit}" == "ligation" ]]; then
    n_rows="$(echo "${sample_rows}" | wc -l)"
    if (( n_rows != 1 )); then
        echo "[error] ligation expects exactly 1 sample row, got ${n_rows}" >&2
        exit 1
    fi
fi

# ---------- provenance ----------
write_provenance() {
    local prov="${out_dir}/_provenance.txt"
    {
        echo "# ont-merge.sh provenance"
        echo "generated_utc  : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "generated_local: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "user_at_host   : $(whoami)@$(hostname)"
        echo "script         : $(readlink -f "$0")"
        if command -v stat >/dev/null 2>&1; then
            echo "script_mtime   : $(stat -c '%y' "$0" 2>/dev/null || echo 'n/a')"
        fi
        echo "samplesheet    : $(readlink -f "${samplesheet}")"
        echo "out_dir        : $(readlink -f "${out_dir}")"
        echo "dry_run        : ${dry_run}"
        echo "overwrite      : ${overwrite}"
        echo
        echo "[Run] (parsed)"
        echo "  fastq_dir : ${fastq_dir}"
        echo "  run_dir   : ${run_dir}"
        echo "  kit       : ${kit}"
        echo "  run-name  : ${run_name}"
        echo
        echo "[Samples] (parsed, kit-filtered)"
        echo "${sample_rows}" | awk -F'\t' '{ printf("  %-20s -> %s\n", $1, $2) }'
    } > "${prov}"
    log "wrote provenance -> ${prov}"
}

if (( ! dry_run )); then
    mkdir -p "${out_dir}"
    write_provenance
    snap="${out_dir}/_used_$(basename "${samplesheet}")"
    check_dest "${snap}"
    cp "${samplesheet}" "${snap}"
    log "snapshotted samplesheet -> ${snap}"
else
    log "[dry-run] would write _provenance.txt and _used_$(basename "${samplesheet}") into ${out_dir}"
fi

# ---------- merge + report copy ----------
log "=== run: kit=${kit}  fastq_dir=${fastq_dir}  run-name=${run_name}"

while IFS=$'\t' read -r bc sn; do
    dest="${out_dir}/${run_name}_${sn}.fastq.gz"
    if [[ "${kit}" == "native_barcoding" ]]; then
        merge_chunks "${fastq_dir}/${bc}/*.fastq.gz" "${dest}"
    else
        merge_chunks "${fastq_dir}/*.fastq.gz" "${dest}"
    fi
done <<< "${sample_rows}"

copy_reports "${run_dir}" "${run_name}"

log "done."
