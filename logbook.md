# logbook — ont-merge

判断・気づき・トラブルシュートの選別ログ (append-only)。ルーチンな作業は書かない。
カバー層 (README / docs/workflow.md) が「現在地」、本ファイルが「そこに至った経緯」。

## 2026-09-30 — `fastq_dir` の「どの workstation の path か」を docs で解決 (tool は変更せず)

- **何が起きたか**: sample sheet の `fastq_dir` 例が `/var/lib/minknow/data/...` で、MinKNOW を動かした workstation 上でしか有効でない。別 workstation で作業しながら他機の run を merge したいときの手順が README に無かった。
- **どう判断したか**: `ont-merge.sh` はリモートホストの概念を持たない (実行ホスト上で存在確認 → `cat`) ので、tool ではなく docs で解く。`fastq_dir` は「実行ホストから見える path」であり、ラボ標準は全 workstation で同じ path に ro mount される NAS backup copy `/opt/mnt/fs000/raw/P2S-01086/<run>/<sample-id>/<flowcell>/fastq_pass` を指す、と README 両言語と `samplesheet.example.csv` に明記。`[Header]` に `sequencing-host` 行を推奨。ssh を tool に組み込む案 (`ssh host cat` で stream merge) は YAGNI として見送り: dry-run の一覧・report copy・エラー処理が二重化するのに対し、fs000 経路で既に解けている。当日中に必要なら run した workstation 上で実行するか sshfs で mount、と代替を併記。
- **なぜ**: `/opt/share/merged_data/` 配下の `_provenance.txt` を全件読んだところ、2026-07 以降の他 workstation 由来 run はすべて fs000 copy を入力にしており、運用として既に定着していた。fs000 到達も実測: run 直下 8 件すべて到達 (manual §4-1 の `comm` が空)、最新 run の barcode dir でファイル数・バイト数が元と一致。
- **副作用として気づいた点**: (1) fs000 path にすると「どの workstation で取ったか」が `fastq_dir` から消える (機体 `P2S-01086` は 3 台共通) → `sequencing-host` 行で補う。(2) 夜間 copy が途中の run を merge すると不完全な FASTQ になる (tool は chunk の欠落を検出できない) → `final_summary_*` / `report_*` の存在確認を README に明記。
- **関連**: ラボの backup 体制の正本は private repo `NikaidoLaboratory/seq-data-backup` (`docs/backup_manual.md`)。変更ファイル: `README.md`, `README.ja.md`, `samplesheet.example.csv`, `ont-merge.sh` (help 文のみ)。旧 README は `docs/20260930_140315_README.md` / `docs/20260930_140315_README.ja.md` に退避。
- **検証** (claude-fable-5-1): `bash -n` OK。改訂後の `samplesheet.example.csv` の placeholder を toydata path に置換した sheet で dry-run が exit 0 (comment 行が `[Run]` 内にあっても、`[Header]` の追加行があっても parser が通る)。toydata の本実行 smoke test も exit 0 (8 sample + report 3 + provenance + snapshot = 13 file)。
