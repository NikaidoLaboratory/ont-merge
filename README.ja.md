# ont-merge

**Languages**: [English](./README.md) | [日本語](./README.ja.md)

MinKNOW (Oxford Nanopore Technologies, ONT) が出力する分割された `fastq.gz` chunk を
sample 単位で 1 ファイルに merge し、`<run-name>_<sample-name>.fastq.gz` という規約名で
保存する。同時に MinKNOW の `report_*` ファイル群もコピーし、出力 dir には実行来歴
(provenance) を必ず残す。すべて **1 枚の Illumina-style sample sheet** で駆動する。

## 背景 (Background)

Oxford Nanopore Technologies (ONT) のシーケンサー (PromethION / GridION / MinION) では、
basecall を sequencing と同時に走らせると、MinKNOW が **時間刻みで `fastq.gz` chunk を
`fastq_pass/` に書き出していく**。 **native_barcoding kit** で barcode 配列により sample を
分離した場合は、`barcode01/`、`barcode02/`、… のような **barcode 別 subdir** が作られ、その
下に時間ごとの chunk が格納される。一方 **ligation kit** のように barcode 分離がない場合は、
subdir なしで `fastq_pass/` 直下に chunk が直接置かれる。

実際にこれらの fastq を後続解析で使うときは、sample ごとに:

1. **chunk を merge して 1 ファイルに**したい (時間スライスのまま扱いたくない)
2. **sample 固有の human readable な名前**が付いている方が、後の解析における可視性・追跡性が
   高い

この 2 つを **一括で行う仕組みが ONT 側からは提供されていない**。

一方 Illumina 側ではこの問題は実質的に解決済みで、wet 研究者が sample sheet を 1 枚埋めれば、
`bcl2fastq` (or `bcl-convert`) がそれを読んで sample 名つきの fastq を直接出力する。さらに
Illumina の sample sheet は、各 fastq とその sample の **実験条件・run 条件などの metadata
との紐付けハブ** としても機能する。同じ流儀を ONT 側にも持ち込んで、sample 名がついた
merged fastq を 1 枚の sample sheet から得たい — それが `ont-merge` の出発点。

実装は **意図的にミニマム**: CSV (sample sheet) + bash (本体 script) だけで動く。conda
環境も Nextflow runtime も Python interpreter も追加で必要ない。Linux 標準の toolchain
だけで完結するので、wet 研究者が sheet と script を端から端まで読み解ける。

## 目的 (Purpose)

- **sample sheet 1 枚 = single source of truth**: ウェットが記入 → ドライがそのまま実行
- sample ごとに 1 つの `.fastq.gz` を、metadata 由来の規約名で出力
- MinKNOW の `report_*.{html,json,md}` も同じ出力 dir にコピー
- 実行来歴 (provenance) を必ず出力 dir に記録 (手動ロギング不要)

## 仕様 (Specifications)

### 対応 kit

| `kit` の値           | `fastq_pass/` 直下の構造                          |
|----------------------|---------------------------------------------------|
| `native_barcoding`   | barcode 別 subdir: `barcode01/`, `barcode02/`, … |
| `ligation`           | `.fastq.gz` を直接配置 (subdir なし)              |

### Sample sheet (Illumina 風、CSV)

**1 シート = 1 sequencing run**。`#` 始まりと空行は skip。

**例: native_barcoding kit** (1 run につき複数 barcode)

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

**例: ligation kit** (1 run = 1 sample。`fastq_pass/` 直下に barcode 別 subdir なし)

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

ligation の場合は MinKNOW 側で barcode demultiplex が走らないので、`barcode-number` は
`none` (または空)、`[Samples]` の data 行は **必ず 1 行のみ**。

| Section     | parser が読む? | 内容                                                                |
|-------------|----------------|---------------------------------------------------------------------|
| `[Header]`  | ❌             | 人間向け free-form metadata                                          |
| `[Run]`     | ✅             | 必須 key: `fastq_dir`, `kit`, `run-name`                             |
| `[Samples]` | ✅             | header 固定: `barcode-number,sample-name`。kit に応じて行が自動 filter:  |
|             |                | `native_barcoding` → `barcodeNN` 形式の行                            |
|             |                | `ligation`         → `none` または空の行 (1 行のみ)                  |

### ウェット側 metadata 列の追加

`[Samples]` セクションは、必須の `barcode-number,sample-name` に加えて **任意の列を追加**
できる。parser は 1 列目と 2 列目しか参照しないため、3 列目以降は merge 処理に一切影響
しない。一方で、追加した列もそのまま `_used_<original_samplesheet_filename>` snapshot に
保存されるので、wet 研究者が condition / replicate / note などの metadata を 1 枚のシート
に集約しても情報は失われない。

```csv
[Samples]
barcode-number,sample-name,note,replicate,condition
barcode11,sampleA_75sec_1,baseline buffer,rep1,75sec
barcode12,sampleA_75sec_2,"buffer X, treated",rep2,75sec
```

- 列名 (`note`, `replicate`, `condition` 等) は自由に決めて良い
- 値に `,` を含めたい場合は **ダブルクォートで囲む** (Excel で CSV 保存すれば自動処理される)
- 下流解析では `_used_*.csv` を読めば追加列も含めた完全な metadata を復元できる
- 現状 script 自体はこれらの列を消費しない。将来的に解析側で参照したくなれば (e.g. condition で group 化)、シート形式を変えずに parser 拡張で対応できる

### 出力 (`out_dir` 内)

| File                                                  | 由来                                    |
|-------------------------------------------------------|-----------------------------------------|
| `<run-name>_<sample-name>.fastq.gz`                   | chunk を `cat` で merge                 |
| `<run-name>__<original_report_filename>`              | run dir 内の `report_*` ファイル        |
| `_provenance.txt`                                     | 実行 metadata + parse 済み [Run]/[Samples] |
| `_used_<original_samplesheet_filename>`                               | 入力 sample sheet の snapshot           |

Report ファイル名に `__` (アンダースコア 2 個) を挟むのは、複数 run で `out_dir` を共有した
ときに同名衝突を避けるため。

## プログラム構成 (Components)

```
ont-merge/
├── ont-merge.sh                                       # 本体 (bash)
├── samplesheet.example.csv                              # template
├── docs/workflow.md                                     # データフロー図
└── tests/                                               # smoke-test fixture
    ├── dummydata/                                       # 擬似生成データ
    │   ├── make_dummy.sh                                # 生成 script
    │   ├── native.samplesheet.csv                       # smoke (native_barcoding)
    │   ├── ligation.samplesheet.csv                     # smoke (ligation)
    │   ├── native_barcoding/                            # 生成 fastq ツリー
    │   └── ligation/                                    # 生成 fastq ツリー
    └── toydata/                                         # 実サイズの参照 (FASTQ + 対応 sheet ペア、track 分は約 3 MB)
        ├── 20260225_P_N11424_conditionAB_t/   # MinKNOW run dir copy: FASTQ tree のみ (pod5 / MinKNOW metadata は .gitignore で除外)
        └── conditionAB_t.samplesheet.csv      # 対応 sample sheet (toydata 内を指す)
```

## 使い方 (Usage)

```bash
git clone git@github.com:NikaidoLaboratory/ont-merge.git
cd ont-merge

# 同梱 toydata (実サイズ fixture、約 3 MB) で smoke test
./ont-merge.sh -s tests/toydata/conditionAB_t.samplesheet.csv \
               -o output/_smoke_toydata

# 実 run
cp samplesheet.example.csv my_run.samplesheet.csv
$EDITOR my_run.samplesheet.csv
OUT="output/$(date +%Y%m%d_%H%M%S)_my_run"
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -n   # dry-run で確認
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT"      # 本実行

# 同じ out_dir に再実行 (-f で上書き)
./ont-merge.sh -s my_run.samplesheet.csv -o "$OUT" -f
```

### 任意: 擬似データの smoke test (tiny synthetic fixture を再生成)

```bash
bash tests/dummydata/make_dummy.sh
./ont-merge.sh -s tests/dummydata/native.samplesheet.csv   -o output/_smoke_native
./ont-merge.sh -s tests/dummydata/ligation.samplesheet.csv -o output/_smoke_ligation
```

### CLI オプション

| Flag | Long             | 必須  | 説明                                          |
|------|------------------|-------|-----------------------------------------------|
| `-s` | `--samplesheet`  | yes   | Sample sheet CSV の path                      |
| `-o` | `--out-dir`      | yes   | Output directory (なければ作成)               |
| `-n` | `--dry-run`      | no    | 実行内容を表示するだけで書き込まない          |
| `-f` | `--overwrite`    | no    | 既存 output を上書きする                      |
| `-h` | `--help`         | no    | 使い方を表示して終了                          |

## 補足 (Notes)

- Merge は `cat a.gz b.gz > c.gz` 方式。gzip stream は concatenable なので、結果は
  `zcat` / `gunzip` および任意の FASTQ tool で読める valid な gzip になる。再圧縮しない
- 入力側の `fastq_dir` には一切書き込まない (source は read-only として扱う)
- `other_reports/` 等、run dir の subdirectory は default ではコピー対象外。`report_` で
  始まるファイルだけが対象
- chunk の read 順は chunk filename の lexicographic 順 (これは `cat *.fastq.gz` の挙動と一致)
- **`report_*` が見つからない場合**: MinKNOW は `report_*.{html,json,md}` を sequencing
  run の **終了時**にまとめて書き出す。run 進行中に本 script を実行すると、これらは
  まだ存在しないため warning だけ出して report の copy は skip される (FASTQ の merge
  には影響しない)。run 完了後に `-f` 付きで再実行すれば report もコピーされる
- **Provenance**: 本実行 (dry-run でない) のたびに `_provenance.txt` (timestamp、
  user@host、script の path + mtime、parse 済み `[Run]` と kit-filter 済み `[Samples]`) を
  必ず書き出し、入力 sample sheet を `_used_<original_samplesheet_filename>` として snapshot する。
  出力 dir それ自体が自己記述的になり、後から (or 他人が) 出力 dir を見るだけで
  「どこから来たデータを、いつ、どう処理したか」が完全に追える

## License

MIT — see [LICENSE](./LICENSE).
