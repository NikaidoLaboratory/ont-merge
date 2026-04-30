#!/usr/bin/env bash
# Generate dummy fastq.gz chunks for smoke testing ont-merge.sh.
#   native_barcoding/fastq_pass/{barcode01,barcode02}/  (2 chunks each)
#   ligation/fastq_pass/                                (4 chunks, no subdir)
# Reproducible: fixed awk srand() seed per chunk.

set -euo pipefail

DUMMYDIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_RUN="${DUMMYDIR}/native_barcoding"
LIGATION_RUN="${DUMMYDIR}/ligation"
NATIVE="${NATIVE_RUN}/fastq_pass"
LIGATION="${LIGATION_RUN}/fastq_pass"

rm -rf "${NATIVE_RUN}" "${LIGATION_RUN}"
mkdir -p "${NATIVE}/barcode01" "${NATIVE}/barcode02" "${LIGATION}"

emit_fastq() {
    # $1 = output path, $2 = read id prefix, $3 = read count, $4 = awk seed
    local out="$1" prefix="$2" n="$3" seed="$4"
    awk -v prefix="${prefix}" -v n="${n}" -v seed="${seed}" 'BEGIN{
        srand(seed)
        bases = "ACGT"
        for (i = 1; i <= n; i++) {
            seq = ""; qual = ""
            len = 50 + int(rand() * 50)
            for (j = 1; j <= len; j++) {
                seq = seq substr(bases, 1 + int(rand() * 4), 1)
                qual = qual "I"
            }
            printf("@%s_read%d\n%s\n+\n%s\n", prefix, i, seq, qual)
        }
    }' | gzip -c > "${out}"
}

emit_fastq "${NATIVE}/barcode01/PBC_pass_barcode01_chunk0.fastq.gz" "barcode01_chunk0" 5 1
emit_fastq "${NATIVE}/barcode01/PBC_pass_barcode01_chunk1.fastq.gz" "barcode01_chunk1" 5 2
emit_fastq "${NATIVE}/barcode02/PBC_pass_barcode02_chunk0.fastq.gz" "barcode02_chunk0" 5 3
emit_fastq "${NATIVE}/barcode02/PBC_pass_barcode02_chunk1.fastq.gz" "barcode02_chunk1" 5 4

emit_fastq "${LIGATION}/PBK_pass_chunk0.fastq.gz" "ligation_chunk0" 5 5
emit_fastq "${LIGATION}/PBK_pass_chunk1.fastq.gz" "ligation_chunk1" 5 6
emit_fastq "${LIGATION}/PBK_pass_chunk2.fastq.gz" "ligation_chunk2" 5 7
emit_fastq "${LIGATION}/PBK_pass_chunk3.fastq.gz" "ligation_chunk3" 5 8

# Fake MinKNOW-style report_* files at run-dir level (parent of fastq_pass)
for ext in html json md; do
    printf '<dummy native report %s>\n' "${ext}" > "${NATIVE_RUN}/report_dummy_native.${ext}"
    printf '<dummy ligation report %s>\n' "${ext}" > "${LIGATION_RUN}/report_dummy_ligation.${ext}"
done

echo "Generated dummy fastq.gz + report_*:" >&2
echo "  ${NATIVE}/barcode01 (2 chunks, 10 reads total)" >&2
echo "  ${NATIVE}/barcode02 (2 chunks, 10 reads total)" >&2
echo "  ${LIGATION}        (4 chunks, 20 reads total)" >&2
echo "  ${NATIVE_RUN}/report_dummy_native.{html,json,md}" >&2
echo "  ${LIGATION_RUN}/report_dummy_ligation.{html,json,md}" >&2
