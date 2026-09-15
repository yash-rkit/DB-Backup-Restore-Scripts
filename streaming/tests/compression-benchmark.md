# Logical Backup Compression — gzip vs zstd

Benchmark of compression levels for `logical.sh`, measured on real production
data. **762 databases, 60 GB of SQL, zero failures.**

**Conclusion: switch from `gzip -6` to `zstd -9`.**

| Measured on | Databases | Raw SQL | Run date |
| ----------- | --------- | ------- | -------- |
| Cloud-Live-DB-Default    | 286 | 20.23 GB | 2026-09-10 |
| Cloud-Live-DB-4th-Server | 476 | 39.50 GB | 2026-09-11 |
| Cloud-Live-DB-4th-Server (CPU) | 476 | 39.50 GB | 2026-09-14 |

---

## 1. Space

| Compression | Cloud-Live-DB-Default | Cloud-Live-DB-4th-Server |
| ----------- | --------------------- | ------------------------ |
| **gzip -6** *(today)* | **7.12 GB** | **16.91 GB** |
| zstd -1  | 5.15 GB *(−28%)* | 13.45 GB *(−21%)* |
| zstd -3  | 3.79 GB *(−47%)* | 8.67 GB *(−49%)* |
| zstd -6  | 3.53 GB *(−50%)* | 8.26 GB *(−51%)* |
| **zstd -9**  | **3.08 GB** *(−57%)* | **6.35 GB** *(−62%)* |
| zstd -12 | 3.06 GB *(−57%)* | 6.32 GB *(−63%)* |
| zstd -15 | 3.02 GB *(−58%)* | 6.25 GB *(−63%)* |
| zstd -19 | 2.60 GB *(−63%)* | 5.32 GB *(−69%)* |

---

## 2. Time

Backup window is `(dump + compress) / PARALLEL`, with `PARALLEL=3`. The dump
itself is unavoidable and identical for every case, so only the compress column
changes with the level.

### Cloud-Live-DB-Default — 286 databases

| Compression | Compress | Restore | Backup window | vs today |
| ----------- | -------- | ------- | ------------- | -------- |
| **gzip -6** *(today)* | 8m 02s | 1m 41s | **8m 15s** | — |
| zstd -1  | 36s     | 34s | 5m 47s  | 2m 28s faster |
| zstd -3  | 40s     | 31s | 5m 48s  | 2m 27s faster |
| zstd -6  | 2m 03s  | 29s | 6m 16s  | 1m 59s faster |
| **zstd -9**  | **3m 00s** | **28s** | **6m 35s** | **1m 40s faster** |
| zstd -12 | 5m 55s  | 29s | 7m 33s  | 42s faster |
| zstd -15 | 39m 12s | 25s | 18m 39s | 10m 24s slower |
| zstd -19 | 2h 04m  | 25s | 47m 04s | 38m 49s slower |

### Cloud-Live-DB-4th-Server — 476 databases

| Compression | Compress | Restore | Backup window | vs today |
| ----------- | -------- | ------- | ------------- | -------- |
| **gzip -6** *(today)* | 17m 28s | 3m 29s | **31m 26s** | — |
| zstd -1  | 1m 19s  | 1m 37s | 26m 02s | 5m 24s faster |
| zstd -3  | 1m 26s  | 1m 25s | 26m 05s | 5m 21s faster |
| zstd -6  | 3m 51s  | 1m 23s | 26m 53s | 4m 33s faster |
| **zstd -9**  | **4m 44s** | **1m 17s** | **27m 11s** | **4m 15s faster** |
| zstd -12 | 9m 09s  | 1m 18s | 28m 39s | 2m 47s faster |
| zstd -15 | 59m 55s | 1m 06s | 45m 35s | 14m 09s slower |
| zstd -19 | 2h 53m  | 1m 04s | 1h 23m  | 51m 34s slower |

Every level up to **-12 is faster than today**. The line is between -12 and -15.

---

## 3. CPU

4 cores, 3 compressions in parallel. Measured with GNU `time` rusage, per
compressor process — not sampled, so MySQL's own load cannot pollute it.

| | gzip -6 | zstd -6 | **zstd -9** |
| --- | ------- | ------- | ----------- |
| **Cloud-Live-DB-4th-Server** | | | |
| CPU used            | 1,043 sec | 245 sec | **298 sec** |
| vs gzip             | —         | 77% less | **71% less** |
| Speed               | 39 MB/s   | 165 MB/s | **136 MB/s** |
| Peak CPU            | 74%       | 80%      | **79%** |
| Time at peak        | 5m 50s    | 1m 17s   | **1m 35s** |
| Average over run    | 11%       | 3%       | **3%** |
| Memory (1 process)  | 2 MB      | 45 MB    | **85 MB** |
| Memory (3 parallel) | 6 MB      | 135 MB   | **255 MB** |
| **Cloud-Live-DB-Default** | not measured | not measured | not measured |

CPU was measured on 4th-Server only, because that is the data the VM held at
the time. CPU per GB is a property of the algorithm and the schema shape, and
both servers hold the same kind of schema, so Default would land within a few
percent.

### Reading the CPU numbers

**CPU seconds** = one core running flat out for that many seconds. It is the
only measure that captures cost, because it combines intensity and duration.

Peak CPU is the same for every compressor — they are all single-threaded, so
they all pin one core at ~100% while running, and `htop` would show them as
identical. What differs is **how long they stay there**: gzip holds the machine
at 74% for 5m 50s; zstd -9 holds it at 79% for 1m 35s.

*(zstd reads slightly over 100% of one core because it runs a small separate
I/O thread even at `-T1`.)*

---

## Recommendation: zstd -9

| | Cloud-Live-DB-Default | Cloud-Live-DB-4th-Server |
| --- | --------------------- | ------------------------ |
| Size today          | 7.12 GB | 16.91 GB |
| Size with zstd -9   | **3.08 GB** | **6.35 GB** |
| Space saved         | **57%** | **62%** |
| Window today        | 8m 15s | 31m 26s |
| Window with zstd -9 | **6m 35s** | **27m 11s** |
| Time saved          | **1m 40s** | **4m 15s** |
| Restore             | 1m 41s → **28s** | 3m 29s → **1m 17s** |
| CPU                 | not measured | **71% less** |
| Memory cost         | +249 MB | +249 MB |

At 30-day retention that is **121 GB freed on Default and 317 GB on
4th-Server** — doubled again once `backup_sync.sh` mirrors the tree to the
second share.

**The entire cost is 249 MB of RAM.** zstd -9 is better on size, backup time,
restore time and CPU.

### Why not the others

| Level | Why not |
| ----- | ------- |
| -1, -3   | Weaker compression, no meaningful speed gain over -9 |
| -6       | 2.35 GB bigger every run, saves only 53 CPU seconds |
| -12, -15 | Same size as -9, slower |
| -19      | 1.5 GB smaller, but the window jumps from 34 min to 2h 10m |

---

## Findings worth acting on separately

**Large databases compress worst.** Databases over 100 MiB hold ~73% of the raw
SQL but compress at 5.8x, against 8.5x for the 1-100 MiB band. The estate ratio
therefore tracks the large schemas, which is why the benchmark was run against
every database rather than a sample — a sample weighted toward small and medium
databases would have predicted ~8.5x and been wrong by a third.

**Eight databases barely compress at all** — 2.2x to 2.8x against an estate
average of 6.3x, the worst being `cmcy000105`, `cmcy001950`, `cmcy002253`,
`cmcy000645` and `cmcy000967`. That pattern usually means high-entropy content:
base64 blobs, encrypted fields, hashes, or already-compressed data held in text
columns.

This is worth checking, because `logical.sh` currently asserts:

> `--hex-blob is deliberately NOT set: no binary columns in these schemas.`

If any of those schemas do hold binary columns then that assumption is wrong and
those dumps may not restore cleanly. A low compression ratio is not proof, but
it is a reason to look. This is a correctness question, independent of which
compressor is chosen.

---

## Method

Measured with [`zstd_level_bench.sh`](./zstd_level_bench.sh), a copy of
`logical.sh`'s dump path that is instrumented instead of publishing. It never
writes to the share and never publishes an archive.

Each database is dumped **once**, then that same `.sql` is compressed at every
level in turn, so every level is compared on identical bytes for a single dump
pass. Runs are serial, because parallel dumps would contend for CPU and make
the timings meaningless; `PARALLEL=3` is applied to the projection instead.

Every measurement is verified: the output is decompressed and checked against
the input's sha256. A level that does not round-trip is reported, not scored.
All 6,858 measurements round-tripped cleanly.

The two 4th-Server runs, taken three days apart, produced **byte-identical**
output sizes — confirming the measurements are deterministic and repeatable.

Reports generated with [`zstd_level_report.sh`](./zstd_level_report.sh).

### Reproducing

```bash
sudo apt install zstd time

# space and time, every level
./zstd_level_bench.sh --server_name=NAME --levels=1,3,6,9,12,15,19

# CPU and memory, the three cases that matter
./zstd_level_bench.sh --server_name=NAME --levels=6,9 --cpu

# combine the runs into tables and Excel-ready CSVs
./zstd_level_report.sh --out=results *.csv
```

Both servers must be run with the same `--levels` or the results are not
comparable.

### Raw data

| File | Contents |
| ---- | -------- |
| `Cloud-Live-DB-Default_bench_20260910_162956.csv`   | 286 databases, 7 levels |
| `Cloud-Live-DB-4th-Server_bench_20260911_103217.csv` | 476 databases, 7 levels |
| `Cloud-Live-DB-4th-Server_bench_20260914_123132.csv` | 476 databases, CPU and memory |

One row per database per level: raw bytes, compressed bytes, compress and
decompress milliseconds, round-trip result, and — in the CPU run — user
seconds, system seconds and peak RSS.

---

## Next steps

This benchmark settles the compression question only. The remaining work on
`logical.sh`:

1. Replace `tar -czf` with `zstd -9`, and record the level in the manifest
2. Add age encryption after compression (compress first — ciphertext does not compress)
3. Update `ARCHIVE_GLOB` in `backup_sync.sh` and `db_cleanup.sh`, which both
   hardcode `*.tar.gz`; leaving them would stop retention silently
4. Write an encryption-aware restore script — there is currently no logical
   restore in `streaming/`
