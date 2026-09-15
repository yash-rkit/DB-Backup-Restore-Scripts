# Streaming Physical Backup and Restore (XtraBackup xbstream + zstd, SMB/CIFS)

| Script | Role | Pre-flight | Run by |
|---|---|---|---|
| `backup.sh` | one streamed, compressed `.xbstream`, published to the share | 15 checks | crontab, daily |
| `binlog_collect.sh` | copies binlogs forward from the last backup | 10 checks | crontab, every 15 min |
| `restore.sh` | verify → wipe → extract → decompress → **prepare** → start → apply | 16 checks | by hand |

A variant of [../../standalone/physical/physical-backup.md](../../standalone/physical/physical-backup.md),
**not a replacement**. Same storage model, same CIFS assumptions, same lock
interlock, same file+position recovery. That document covers the shared
behaviour; this one covers what differs and everything that follows from it.

Comments in these scripts are deliberately minimal — a comment survives only
where the code would otherwise look wrong or accidental. The reasoning lives
here. The `PART` banners in each file are its map, and the phase names in the log
match them, so a log line points at a region of the file.

## 1. What changed, and what it costs

The tar chain writes the datadir out three times: xtrabackup copies it to a
directory, `--prepare` rewrites it in place, then `tar -czf` reads all of it back.
The streaming chain does one pass.

```
tar chain     datadir ──copy──> target dir ──prepare──> ──tar+gzip──> 20260809.tar.gz
                        (1x disk)          (rewrite)     (read all)

stream chain  datadir ──xtrabackup --stream=xbstream --compress──> 20260820.xbstream
                        (compressed on the fly, straight to one file)
```

| | tar chain | stream chain |
|---|---|---|
| Backup command | `--backup --target-dir`, then `--prepare`, then `tar` | one `--backup --stream=xbstream --compress` |
| Compression | gzip, single-threaded, after the fact | zstd level 1, `--compress-threads`, inline |
| Staging needed | ~1.5x datadir | ~40% of datadir (the compressed stream only) |
| Published archive | `.tar.gz`, **prepared** | `.xbstream`, **unprepared** |
| Prepare happens | at backup time | at restore time |
| Restore work | extract | extract → decompress → prepare |

**The trade is deliberate: time moves off the backup window and onto the restore
window.** The backup runs against a live production database, so shortening it
reduces the extra I/O load and the chance of MySQL purging a binlog before the
collector reaches it. The restore runs on a server nobody is using yet.

The cost: **restores are slower, and the prepare is a step that can fail.** On the
tar chain a broken prepare is discovered at backup time, while you still have a
healthy database. Here it is discovered during recovery — see §9 for how to test
it in advance.

## 2. Where `--prepare` moved

`xtrabackup --backup` produces a datadir that is **crash-inconsistent**: a physical
copy taken while pages were being written, plus a redo log covering the
difference. `--prepare` replays that redo and makes it consistent.

> **Starting mysqld on an unprepared datadir does not fail with an error. It
> rewrites pages on top of an inconsistent redo state and corrupts the data.**

The tar chain prepared at backup time, so its guard was "refuse to restore
anything whose manifest does not say `prepared=yes`". Here that guard **inverts**,
and there are three in sequence:

| Where | Check | On failure |
|---|---|---|
| `backup.sh` PART 9 | `backup_type` from `--extra-lsndir` must be `full-backuped` | refuse to publish |
| `restore.sh` pre-flight | manifest `prepared` must **not** be `yes`; `archive_format` must be `xbstream` | refuse to start |
| `restore.sh` after prepare | `backup_type` read off the **restored datadir** must be `full-prepared` | leave MySQL stopped |

The last one is what actually protects the data: it reads the file on disk rather
than trusting anything the backup recorded. MySQL is only started after it passes.

### Streaming has no target directory, so metadata comes from elsewhere

With `--stream=xbstream` nothing lands on a filesystem — the datadir goes to
stdout — so `xtrabackup_checkpoints`, `xtrabackup_info` and the binlog position
are not available as files. Two mechanisms replace them:

- **`--extra-lsndir=<XB_TMPDIR>/<id>`** — the one place xtrabackup still writes
  `xtrabackup_checkpoints` and `xtrabackup_info` to disk. `backup.sh` treats this
  as required output, not scratch: a run that produces no metadata there is
  refused, because the manifest could not be written and `restore.sh` would have
  nothing to pre-check.
- **The binlog position** is parsed from the log line
  `MySQL binlog position: filename 'binlog.000018', position '157'`, with the
  `binlog_pos` line of `xtrabackup_info` as the fallback. It is written to
  `<id>_binlog_info` in the same `<file>\t<position>` format the tar chain used,
  which is why `binlog_collect.sh` anchors on it unchanged.

Both parsed values are validated before publication: the filename must match
`<prefix>.NNNNNN` and the position must be all digits. A backup taken with binary
logging off publishes the placeholder `unknown 0` and warns that PITR is not
possible.

## 3. Published layout

```
<SECONDARY_STORAGE_DIR>/
├── 20260820.xbstream       the archive: zstd-compressed, UNPREPARED
├── 20260820.sha256         checksum, ABSOLUTE path to the archive
├── 20260820.manifest       sidecar read before extraction
├── 20260820_binlog_info    PITR anchor: <binlog file> <position>
├── meta/20260820/          the --extra-lsndir output, as published
│   ├── xtrabackup_checkpoints
│   └── xtrabackup_info
├── binlog/20260820/        binlogs belonging to that backup
│   ├── binlog.000018
│   ├── binlog.sha256           append-only, bare filenames
│   └── last_copied_binlog      resume state
└── logs/20260820/
    ├── backup.log, xtrabackup.log, errors.log
    ├── collect/                     every collection run, appended
    └── restore_20260822_091500/     one folder per restore attempt
```

Two additions over the tar layout. **`meta/<id>/`** holds the `--extra-lsndir`
files: on the tar chain that metadata lived inside the tarball, but here the
archive is a compressed stream, so the LSN range and source topology would be
unreadable without a full restore. It is a few hundred bytes.
**`logs/<id>/restore_<timestamp>/`** is per-attempt rather than a single
`restore/` — a recovery is often more than one attempt, and each attempt's prepare
log is exactly what you need to compare.

### Naming: bare date, timestamped only on a rerun

```
20260820.xbstream            first (or only) run that day
20260820_175047.xbstream     a second run on the same day
```

The **share** is the authoritative test, not local staging: staging is emptied
after every run, so only a published archive proves the day is taken. The header
says which happened. Pre-flight check 15 is a second-level guard — since PART 5
already appends a time when the day is taken, a collision there means either two
runs starting in the same second, or that **the share was unreachable when the
name was chosen** and the day is in fact taken. The check says both.

`restore.sh` accepts either form; its `backup_id` pattern is `^[0-9]{8}(_[0-9]{6})?$`.

> **This is why the collector's anchor sort matters.** `binlog_collect.sh` sorts
> the date and the time as **separate keys**, because a plain lexical sort puts
> `20260820_175047` *before* `20260820` — `_` sorts before end-of-string. With
> both forms in play that would silently anchor on the older of the day's two
> backups:
>
> ```
> candidates:  20260819  20260819_143005  20260820  20260820_090000  20260820_175047
> two-key sort (correct):  20260820_175047
> plain lexical sort:      20260820          ← the day's FIRST backup, not its last
> ```
>
> A bare date is treated as time `000000`, which is what makes the two orderings
> agree. Do not reduce it to `sort | tail -1`.

### The manifest

```
backup_id, created_at, archive_path, archive_sha256
archive_format=xbstream          ← restore.sh refuses a non-xbstream archive
archive_bytes, compression=zstd, compress_zstd_level=1
prepared=no                      ← EXPECTED here; yes would be refused
backup_type=full-backuped
from_lsn, to_lsn
datadir_bytes                    ← restore.sh sizes its space check off this
dump_secs, local_hash_mibps, upload_secs, upload_mibps,
readback_secs, readback_mibps    ← diagnostic only, never read back
mysql_version, xtrabackup_version, binlog_format, gtid_mode
binlog_file, binlog_pos
recovery_method=file_position
datadir
```

`datadir_bytes` is the measured size of the source datadir — the difference
between the restore knowing how much space it needs and guessing a multiple of the
compressed archive (§8).

The throughput fields are recorded, never read back. Nothing branches on them;
they exist so `grep upload_mibps= <share>/*.manifest` gives the link's history
across every run, which is the only way to tell a link that has always been slow
from one that degraded last Tuesday. `local_hash_mibps` is the same archive read
off local disk, so the pair is a like-for-like comparison of the box against the
link (§9).

## 4. Logs

All three scripts share one log engine. Every line has the same shape:

```
HH:MM:SS LEVEL [phase     nn/nn] message
```

Time-of-day only — the date is in the run header and the folder name. `LEVEL` is
padded to 5 and the phase block is fixed width, so the message column lines up
down the whole file. Results use a dotted leader so the outcome sits in one
column regardless of label length:

```
14:30:06 INFO  [preflight 06/15] mysql connection ..................... OK
14:30:31 INFO  [preflight 09/15] disk space ... need 248GB / stage 501GB / share 900GB
                                 datadir 412.6GiB, estimate is 40% of it
14:30:31 WARN  [preflight 11/15] binary logging .................. DISABLED
                                 point-in-time recovery from this backup will NOT be possible
14:53:56 INFO  [stream 1/5]      done  138.4GiB  (23m25s)
14:53:56 INFO  [stream 1/5]      archive write ... 100.9 MiB/s (846 Mbit/s)
                                 local disk and CPU only — nothing has crossed the link yet
16:42:16 INFO  [publish 5/5]     share total ... 106m50s for 415.2GiB  66.3 MiB/s
                                 the archive crosses the link three times: one write, two reads
```

Four line kinds: a `banner` rule, a `kv` header field, a timestamped
`info`/`warn`/`erro` entry, and a `cont`/`cerr` continuation indented to the
message column with no timestamp. `leader()` targets width 40 and collapses to a
minimum of three dots when the label plus value is longer, so a long value
degrades gracefully instead of wrapping.

**Step numbers cannot drift.** The pre-flight counter is derived, not written by
hand: each check starts with a bare `check`, which increments `CHECK_N` and
formats `CHECK_N/CHECK_TOTAL`. Inserting or removing a check renumbers the rest
automatically — the old hand-written `Check 7/14:` strings drifted the moment
anyone added one. Only `CHECK_TOTAL` needs updating, and a mismatch is visible
immediately because the last check does not read `15/15`.

**The RESULT line.** Every run ends with exactly one greppable line:

```
 RESULT ok     id=20260820 dur_s=7932 bytes=148615495680 up_mibps=63.3 down_mibps=67.2 share_s=6410 warn=1
 RESULT failed id=20260820 phase=stream step=1/5 dur_s=1405 warn=0
```

`up_mibps`, `down_mibps` and `share_s` appear on the `ok` line only — a failed run
has no complete transfer to measure. One `grep` over every log on the share plots
the link's speed over time without opening a manifest. The collector emits the
same shape with its own fields (`anchor=`, `copied=`, `archived=`, `gaps=`).

### Where the logs go

| Script | During the run | At the end |
|---|---|---|
| `backup.sh` | `<LOCAL_STAGE>/<id>_*.log` | **moved** to `logs/<id>/` — nothing kept locally |
| `restore.sh` | `<LOCAL_STAGE>/<id>_restore_<attempt>*.log` | **moved** to `logs/<id>/restore_<attempt>/` |
| `binlog_collect.sh` | straight to `logs/<anchor>/collect/` on the share | already there; appended across runs |

`backup.sh` and `restore.sh` share one publishing contract — **move semantics
behind a mount check**: `mountpoint -q`, then `cp`, then confirm the destination
is non-empty, and only then delete the local file. A log living on the share is
useless when that mount is the thing failing, which is why they are written
locally first. A local copy therefore survives in exactly one situation — the
share was unreachable at the end of the run — and the script says so:

```
 [WARN] share not mounted — logs kept in /Data/dbvault-stage:
        /Data/dbvault-stage/20260820_backup.log
```

`binlog_collect.sh` needs none of this: its run log **is** on the share, and it
cannot start without passing the hard mount check in its PART 5.

> **Two defects lived here, both found on a live host.** `restore.sh` published
> with `cp`, leaving a full second copy of every attempt's logs on the VM forever —
> including `xtrabackup.log`, which is 30MB+ per attempt because `--decompress`
> and `--prepare` both write to it. And `backup.sh` had no mount check in
> `publish_logs` at all: on an unmounted share `mkdir -p <share>/logs/<id>`
> **succeeds**, creating a plain local directory under the mount point, so the
> logs were moved onto the root filesystem, invisible, and the staging copies
> deleted.
>
> Note also that before `die()`/`fail_run()`, a **failed** run never published at
> all, because `exit 1` does not fire the `ERR` trap (§5) — so for any failed
> attempt from that version the logs exist *only* on the VM.

### A successful run leaves nothing on the VM

`LOCAL_STAGE` is scratch, not storage. Logs and the dry-run preview are moved to
the share; staged binlog copies are deleted on both the success and failure paths.
The preview is published rather than kept locally: it can be large, it is still
readable on the share, and the share is the permanent home for everything else
about the run.

Because nothing is intentionally kept, `prune_local` is a safety net, not a
policy: it clears what an **earlier** run left behind when the share was
unreachable, over each script's own artifacts, older than `KEEP_LOCAL_DAYS` (14).
`-mtime` is in whole days, so the current run's own files can never match.

## 5. Failure handling

### `exit 1` does not fire an `ERR` trap

Worth stating plainly, because the tar chain gets it wrong:

```bash
set -euo pipefail
trap cleanup ERR
log_error "compression failed"
exit 1                 # ← cleanup does NOT run
```

The `ERR` trap fires when a *command* returns non-zero. `exit` is not such a
command. In `standalone/physical/backup.sh` every post-pre-flight failure is
written as `log_error …; exit 1`, so on those paths `cleanup_on_error` never runs
and the lock file, the partial archive and any half-written sidecars are all left
behind — and with the lock in place, `binlog_collect.sh` then skips every run for
up to `LOCK_STALE_SECONDS` (6 hours).

These scripts route every failure through one function: `die()` logs and calls
`fail_run()`, which is **also** the `ERR`/`INT`/`TERM` trap handler. An unexpected
non-zero command and a deliberate `die` therefore produce identical cleanup and
identical output. It disarms the trap first so a failure inside the cleanup cannot
re-enter it.

`PHASE` and `STEP` are globals, so `failed in : stream 1/5` is reported without
any call site having to pass it along. That is the whole reason they are globals
rather than parameters.

### What cleanup will and will not delete

`fail_run` removes the lock file, the local stream, a `.part` transfer, the
sidecars and the metadata scratch — but once the archive is copied to the share
**and its checksum verified there**, `TRANSFER_OK=yes` and no later failure
deletes it. A manifest write or a final re-read failing does not justify
discarding a good archive.

Everything is removed through `drop()`, which no-ops on an unset or missing path.
That is why `fail_run` is safe to call from pre-flight, when almost nothing exists
yet, and why there is one failure path instead of one per phase.

### The collector's failure rules

`binlog_collect.sh` differs in two ways. **A per-file problem warns and
continues**: a single corrupt binlog increments `ERRORS` and the loop moves on, so
one bad file does not stop the other 50 from being archived. But **any error still
exits non-zero** — a monitored job that cannot fail is worse than no monitoring.
Validated binlogs stay archived and the state file still points at the last good
one, so the next run resumes correctly. That is a partial-success exit, not a
rollback.

The state file is the one thing cleanup is careful with: `STATE_PRE_EXISTED` is
read before anything can create the file, because deleting a pre-existing state
file would reset the resume point and re-collect everything from the anchor.

## 6. `backup.sh`

### Bootstrap

Two refusals happen before anything else: `SECONDARY_STORAGE_DIR` empty (the
backup has nowhere to go), and `SECONDARY_STORAGE_DIR` inside `BACKUP_BASE`
("publish, then empty scratch" would delete the only copy).

The share directory is deliberately **not** created here. The tar chain created it
up front and therefore needed a duplicate mount check before the numbered
pre-flight. Here nothing touches the share until check 8, which does the mount
test, the `mkdir -p` and the write probe in that order — one check instead of two,
same guarantee.

### Pre-flight, 15 checks

| # | Check | Fails or warns |
|---|---|---|
| 1 | user privileges | **warns** if not root |
| 2 | required binaries | fails |
| 3 | xtrabackup version | fails below 8.0.30; **warns** if unparseable |
| 4 | mysql running | fails |
| 5 | mysql connection | fails |
| 6 | datadir readable | fails — and this is where `MYSQL_DATADIR` is resolved from `@@datadir`, which is why it runs after the connection |
| 7 | staging writable | fails — checks `BACKUP_BASE` and the `--extra-lsndir` |
| 8 | smb share | fails — mountpoint, mkdir, write probe |
| 9 | disk space | fails — `STREAM_SPACE_PCT`% of the datadir, on staging **and** the share |
| 10 | no concurrent backup | fails |
| 11 | binary logging | **warns** — a backup without PITR is still a backup |
| 12 | metadata dir empty | fails — stale `--extra-lsndir` content would read as this run's |
| 13 | thread settings | fails on a non-integer; **warns** on oversubscription |
| 14 | sha256 utility | fails |
| 15 | archive name free | fails — second-level guard, see §3 |

Compared with the tar chain: `tar` and `gzip` are gone from check 2 and the
tar/gzip round-trip test is gone entirely. Checks 3, 12, 13 and 15 are new.
Checks 5 and 6 swapped places when the datadir stopped being a setting: the server
has to answer before it can be asked where its datadir is.

**Check 3** is the one that has actually bitten. `--compress-zstd-level` requires
XtraBackup 8.0.30, and detecting that up front beats a mid-run unknown-option
error — but the detection itself must never be able to fail a healthy backup.
Three things are deliberate:

- **No pipe on `--version`.** `xtrabackup --version | head -1` races with SIGPIPE;
  under `pipefail` a 141 fails the assignment and trips the trap. The output is
  captured whole with `set +e` around it.
- **The banner is found by content.** On 8.0.30+ builds the *first* line of
  `--version` output is a timestamped `[Note] … recognized server arguments` log
  line, not the version banner, so `head -1` captures the wrong line.
- **`BASH_REMATCH`, not `grep -oE | head -1`.** `grep` exits 1 when it finds no
  match; under `pipefail` that failed the assignment and aborted the run with a
  bare `Backup failed` and no explanation. The regex match takes the leftmost
  triple with no subprocess, so an unparseable banner can only warn.

**Check 9** derives the datadir size once. The tar chain called `du -sb` on the
datadir and then immediately called a helper that ran `du -sb` on it again — on a
400GB+ datadir, a full second metadata walk for a number already in hand.

### The five steps

**1 stream.** The lock file is written, then xtrabackup runs with stdout as the
archive and stderr as the log. **Nothing is piped** — a pipe would hide
xtrabackup's exit code behind `tee`'s. On failure the last 40 lines of the
xtrabackup log are echoed into the run log as continuation lines and the whole
file is appended to `errors.log`, so the cause is in the published logs without
needing the scratch directory.

Two rates are reported: `datadir read` (`DATADIR_BYTES / seconds`, how fast the
datadir came off the source disk) and `archive write` (`STREAM_BYTES / seconds`,
how fast the compressed result landed on staging). Both are local — this phase
never touches the share, so a slow number here is the disk, the CPU or a busy
mysqld, and nothing to do with the network.

**2 verify.** `completed OK!` must appear **exactly once**, where the tar chain
wanted at least two: there is no `--prepare` phase appending to this log. Zero
means the backup did not finish; more than one means the log was reused across
runs, and nothing else read from it can be trusted either. Then: stream non-empty,
both `--extra-lsndir` files present and non-empty, and `backup_type ==
full-backuped` — the correct state here, and the whole reason `restore.sh` must
prepare.

**3 binlog position.** The log line first, `xtrabackup_info` as the fallback, both
validated. If nothing is found the run **warns and continues**, publishing
`unknown 0` — a full backup without PITR is still worth having, and the warning
plus the manifest's `binlog_file=unknown` make the limitation visible at restore
time.

**4 checksum.** Generated and verified **locally**, before the transfer, which
catches a stream corrupted on the way to local disk separately from the
post-transfer check. The generating pass is timed and reported as `local hash
rate` — the baseline every share rate in step 5 is judged against. Only the first
pass is timed; the `sha256sum -c` immediately after reads the same bytes again,
usually out of page cache, and would flatter the number.

**5 publish.** Order matters throughout:

1. `smb_ready` re-asserted — pre-flight may have passed an hour ago.
2. Archive copied to `<name>.xbstream.part`, so an interrupted copy never matches
   a `*.xbstream` glob.
3. `sync`, then SHA-256 the `.part` **at the destination**. Without the flush the
   checksum can be served from page cache and prove nothing.
4. `mv` into place, `TRANSFER_OK=yes`.
5. Local copy removed.
6. Checksum file written directly at its published path, containing the archive's
   absolute path, so `sha256sum -c` resolves from any working directory.
7. Binlog anchor, `meta/`, then the manifest as `.part` + `mv`.
8. Every published artifact re-checked for readability, then a **final
   `sha256sum -c` that re-reads the whole archive off the share**.

Step 8 is not redundant with step 3: step 3 verifies what was just written, step 8
verifies what a restore will actually read back later.

**Where the time goes.** The archive crosses the link **three times** — written
once in step 2, read back in step 3, read back again in step 8. Each crossing is
timed separately, because a link that writes fast and reads slow is a different
fault from one that is slow both ways. Both units are printed for a reason: MiB/s
is the file (divide the archive size by it and you have the wall time), Mbit/s is
the link — the unit the provider sells, the NIC reports and the firewall
rate-limits in. `share total` is the sum of all three legs over three times the
archive size; if that figure is most of the run's duration, the link is the run.

**The floor.** `MIN_TRANSFER_MIBPS` defaults to `0`, which measures and prints and
nothing else. Set it, and any leg below it raises one warning naming the legs that
fell short. It is a warning, never a failure: a backup that arrived slowly is
still a backup, and failing the run would destroy a verified archive over a
performance complaint. It counts toward `warn=` on the RESULT line. Pick the floor
from a known-good run rather than the link's rated speed — CIFS over a WAN rarely
reaches half the brochure figure, and a floor set there warns on every run and is
then ignored.

**Inline collection.** `binlog_collect.sh` runs once at the end, via
`BINLOG_SCRIPT`, so PITR coverage starts immediately instead of at the next cron
fire. Strictly best-effort: the archive is already complete and verified, so a
binlog problem here warns and the run still exits 0.

## 7. `binlog_collect.sh`

Anchors on the newest `*_binlog_info` on the share and copies every **closed**
binlog from that position forward.

**Share reachability comes first,** deliberately ahead of the anchor lookup. On an
unreachable mount that lookup finds nothing and exits 0 — reporting a healthy run
that collected nothing, the worst possible outcome for a PITR chain. Mount,
directory, and an actual write probe, because `ls` can be served from the
attribute cache.

**The lock interlock.** `backup.sh` writes
`<LOCK_DIR>/<BACKUP_BASE basename>_<YYYYMMDD>_lock` while it runs. If present and
younger than `LOCK_STALE_SECONDS` (6h), this run exits 0 immediately — the backup
is holding the binlogs it needs. Older than that, the backup probably crashed, so
the run **warns and proceeds** rather than blocking PITR indefinitely. The lock is
local by design: on a network mount a dropped mount would read as "no backup
running", and the interlock would fail exactly when it matters. `/var/lock` is
tmpfs, so a reboot clears a lock left by a hard kill. `LOCK_DIR` and the
`BACKUP_BASE` basename **must match** `backup.sh`.

**Anchor discovery** picks the newest `*_binlog_info` by **filename**, never
mtime: SMB mtime is the server's clock and is attribute-cached, so a skew would
silently pick an older backup. Date and time sort as separate keys (§3). No anchor
at all is a clean exit 0 — the backup has not completed yet, so there is genuinely
nothing to collect.

**`BINLOG_BASE` is not configured** — PART 8 asks the server for
`@@log_bin_basename`. A hardcoded path that no longer matches the server's
`log_bin` finds an empty directory, copies nothing, detects no gap (there is no
sequence to be discontinuous) and writes `RESULT ok`. For the one script the whole
PITR chain depends on, a silent clean run is the worst failure available, so the
value comes from the only source that cannot go stale. It is printed in the header
with its origin, and `BINLOG_BASE=` in the environment overrides it.

**Start point** is the state file if we have collected before, otherwise the
backup anchor. If the start binlog is **gone from the server** (MySQL purged it),
the run falls back to the earliest available and logs the gap loudly:

```
14:45:02 WARN  [start -]  start binlog ................... PURGED
                          COVERAGE GAP between binlog.000018 and binlog.000021 — PITR in that range is LOST
                          prevent it: binlog_expire_logs_seconds >= 3x the backup duration
```

Partial coverage beats none, but the gap is real and permanent.

**Flush and rotate.** `FLUSH BINARY LOGS` closes the active binlog so it becomes
copyable. The new active one is then identified and **skipped** — it is still being
written to. `SHOW BINARY LOG STATUS` is 8.4+, with `SHOW MASTER STATUS` as the
fallback.

**Copy.** Each file must survive four gates before the resume point advances:

| Gate | Catches |
|---|---|
| byte size match | a truncated copy |
| `mysqlbinlog` parse | a corrupt **source** — a truncated binlog copies perfectly and fails during recovery |
| `sha256sum >> binlog.sha256` | records the checksum `restore.sh` verifies against later |
| `echo > last_copied_binlog` | advances the resume point only after all of the above |

`cp` runs **without `-p`**: CIFS cannot preserve ownership, so `-p` returns
non-zero on copies whose data landed fine, and good binlogs would count as errors.
The size and parse checks are the real integrity guarantee. Checksums are recorded
with **bare filenames** so `restore.sh` can verify them from its own staging
directory.

**Continuity.** A sequence gap does **not** error during replay — the database
comes up looking perfectly healthy while every transaction in the hole is silently
missing. Nothing downstream can detect it, so it is detected here, while the
missing file may still exist on the source server.

## 8. `restore.sh`

| Phase | Steps | Destructive? |
|---|---|---|
| 1 verify | SHA-256 the `.xbstream` | no |
| 2 restore | stop mysqld → wipe datadir → `xbstream -x` → `--decompress` → `--prepare` → chown → start | **yes, from the wipe onward** |
| 3 apply | stage binlogs locally → verify checksums → gap check → replay from the anchor | yes |

| Flag | Effect |
|---|---|
| *(none)* | all three phases |
| `--dry-run` | verify the archive, decode the binlogs to a preview `.sql`, report destructive statements. Modifies nothing. Exits non-zero only on a checksum mismatch |
| `--skip-binlog` | phases 1–2 only |
| `--binlog-only` | phase 3 only; requires a marker from a previous run |
| `--from <binlog>` | start the apply at that binlog instead of the anchor |

`--skip-binlog` with `--binlog-only`, and `--from` with `--skip-binlog`, are
rejected during argument parsing.

Extract, decompress and prepare happen **in place in the datadir** — no staging
copy, no `--copy-back`, so ~1x the data size rather than 2x. `--decompress` runs
with `--remove-original`, and any leftover `.zst`/`.qp`/`.lz4` afterwards aborts
the restore: `--prepare` skips such a file silently and it becomes an unreadable
tablespace at runtime.

**Which phases run.** The flags are reduced to two booleans immediately after
parsing (`DO_RESTORE`, `DO_APPLY`), and every check and phase tests those rather
than the raw flags. A check that does not apply reports itself rather than
vanishing, so the count always reads `16/16` and the log shows *why* something was
not verified:

```
16:04:12 INFO  [preflight 03/16] wipe switch .......... n/a (--binlog-only)
16:04:12 INFO  [preflight 05/16] archive present ...... n/a (--binlog-only)
```

**The start point is resolved once,** before the dry-run branch, so a dry run and
the real apply can never disagree about what would be replayed:

| Case | Start |
|---|---|
| no `--from` | anchor file at the anchor position — no gap, no duplicate |
| `--from`, different file | that file at position 4 (whole file) |
| `--from`, **same** file as the anchor | that file at the **anchor** position, not 4 — otherwise the transactions already inside the full backup replay a second time |

The third case logs a `WARN` naming itself an edge case, because silently using
`157` where the operator typed a file expecting `4` is worth saying out loud.
Position 4 is the first real event in a binlog, past the 4-byte magic header.

**Staging the archive.** `STAGE_ARCHIVE=1` (the default) copies the `.xbstream` to
`ARCHIVE_STAGE_DIR` before MySQL is stopped, checksums the local copy and extracts
from there, so the network leaves the destructive window: the wipe happens only
once a verified local copy exists. It is also much faster — `xbstream` reads stdin
serially in small chunks and interleaves thousands of file creations, and over SMB
every one pays link latency. On failure the staged file is **kept**
(`KEEP_STAGED_ON_FAILURE=1`), already verified, so a re-run checksums it and skips
the copy.

**Failure advice is selected by state, not by call site.** `fail_run` picks its
guidance from two flags, so no `die()` call has to describe the situation:

| State | Message |
|---|---|
| `APPLY_STARTED=true` | **partially applied** — do not let applications connect; the apply cannot be resumed; roll back with a full re-run |
| `DATADIR_WIPED=true` | datadir empty or partial, mysqld deliberately left stopped, re-run to start over from a clean wipe |
| MySQL was running, now stopped, datadir untouched | safe to `systemctl start` again |
| otherwise | nothing was modified, retry |

`DATADIR_WIPED` is set immediately before the delete and cleared once MySQL is up
and serving; `APPLY_STARTED` brackets the replay loop. Between them they cover
every point the run can die at.

**Waiting for MySQL.** Readiness and authentication are checked separately,
because a physical restore overwrites `mysql.user` with the **source** server's
accounts — so after restoring server A onto host B, `MYSQL_USER`'s password is
whatever it is on A, and a credential-based probe can be rejected by a server that
restored perfectly. The probe is `mysqladmin ping`, and an `Access denied` reply
counts as **up**: the server parsed the handshake in order to refuse it.

| State | Client error | What happens |
|---|---|---|
| still starting | 2002 / 2003 | keep waiting, up to `MYSQL_READY_TIMEOUT` |
| process gone | any, and `mysql_up` false | **fail immediately**, with the mysqld error log |
| up, password rejected | 1045 | readiness passes; the credential is reported separately |

Every failure here prints the tail of mysqld's own error log, located from
`my_print_defaults` rather than from the server.

**The double-apply guard.** GTID is off, so the apply is one-shot: re-applying
binlogs over a database that already contains them corrupts it.
`binlogs_applied=yes` in `<STATE_DIR>/<id>_restore_state` prevents that. It is a
**hard refusal for `--binlog-only`, and irrelevant for a full run** — a full run
wipes and re-restores first, so the binlogs always land on a fresh baseline. That
is why re-running the full command is the correct rollback after a failed or
unwanted apply, and why the marker simply resets.

**Test the prepare before you need it.** The one thing this chain asks that the tar
chain did not. On a spare host, once per MySQL or XtraBackup upgrade:

```bash
./restore.sh <id> --skip-binlog
```

If MySQL comes up and the row counts look right, the prepare path is sound.

## 9. Disk space and throughput

### Backup host

| What | Needs | Config |
|---|---|---|
| `BACKUP_BASE` | the compressed stream, ~25–40% of the datadir for zstd-1 on InnoDB | `STREAM_SPACE_PCT=40` |
| `XB_TMPDIR` | `--tmpdir` plus a few metadata files | negligible |
| the share | same as `BACKUP_BASE`, per retained backup | same figure |

Raise `STREAM_SPACE_PCT` if the data compresses poorly; the failure mode otherwise
is ENOSPC partway through the run.

### Restore host

Sized off `datadir_bytes` from the manifest times `DATADIR_SPACE_PCT` (120%),
which covers the decompressed pages plus the redo the prepare writes. Without
`datadir_bytes` the fallback is the compressed archive times
`ARCHIVE_EXPANSION_FACTOR` (5), deliberately conservative. The check counts the
datadir's **current** contents as available, since they are about to be deleted —
without that, restoring onto a nearly-full datadir would fail a check it actually
passes.

### Is it the link or the box?

A run where the transfer takes an hour and the integrity check takes another is the
normal shape of a VM in one cloud writing to an SMB share in another. The rates say
whether that hour is the link or something fixable locally:

| What the numbers show | What it means |
|---|---|
| local baseline high, all three share legs low and close together | the link. Nothing on the VM will fix it |
| share legs at or near the local baseline | the link is not the constraint; look at the dump rate and the disk |
| upload fast, reads slow | asymmetric path, or CIFS read-ahead. Try `rsize=`/`cache=` mount options before blaming the pipe |
| local baseline itself low | the box is the constraint — CPU contention or a slow staging disk. The share numbers cannot exceed it |
| dump rate low, share legs fine | mysqld contention or source-disk I/O, not the transfer at all |

The archive crosses the link three times, so a 300 GiB archive on a link that
sustains 85 MiB/s is about three hours of wire time no matter how the box is
configured. Halving that means a faster link, a smaller archive (a higher
`ZSTD_LEVEL` trades CPU for bytes, and the CPU is idle while the link works), or
accepting one less verification pass.

To confirm the link independently of MySQL, time a plain copy of a large file to
the share and back:

```bash
dd if=/dev/urandom of=<LOCAL_STAGE>/.probe bs=1M count=4096 status=none
time cp <LOCAL_STAGE>/.probe "$SECONDARY_STORAGE_DIR/.probe" ; sync
time sha256sum "$SECONDARY_STORAGE_DIR/.probe"
rm -f <LOCAL_STAGE>/.probe "$SECONDARY_STORAGE_DIR/.probe"
```

If the probe matches what the backup reported, the script is not the problem.

## 10. Configuration reference

Every script's PART 1 is split into the same blocks, by who touches it:

| Tier | Heading | Rule |
|---|---|---|
| 1A | SET PER VM | Ships as `__SET_ME__`. The script refuses to start while any is untouched. |
| 1B | TUNING | Working defaults. Change for a measured reason. |
| 1C | SHARED | The other scripts on this host assume these values. Change in all of them, or none. |
| 1D | NOT SET HERE | Detected at run time, or passed as arguments. Nothing to fill in. |
| 1E | GUARD | The check itself. |

The guard runs before the log engine, before any directory is created and before
the share is touched, so a misconfigured copy costs a second and changes nothing:

```
[ERROR] backup.sh has not been configured for this host.
        Open it, find PART 1A, and replace __SET_ME__ in:
          MYSQL_USER
          MYSQL_PASSWORD
          SECONDARY_STORAGE_DIR
          SMB_MOUNT_POINT
        Nothing has been read, written or deleted.
```

That exists because the alternative is silent. A `backup.sh` copied to a second
host with its `SECONDARY_STORAGE_DIR` left alone runs perfectly and publishes into
the first host's directory; `binlog_collect.sh` then anchors on whichever backup
finished last and interleaves two PITR chains in one tree. Nothing fails, nothing
warns, and it is discovered during a restore.

### 1A — the per-VM values

| Setting | In | What it is |
|---|---|---|
| `MYSQL_USER`, `MYSQL_PASSWORD` | all three | the account. `backup.sh` needs `BACKUP_ADMIN`, `RELOAD`, `PROCESS`, `LOCK TABLES`, `REPLICATION CLIENT` |
| `SECONDARY_STORAGE_DIR` | all three | this server's permanent directory on the share. **One per server** |
| `SMB_MOUNT_POINT` | all three | the CIFS mount point itself, not a directory beneath it. `mountpoint -q` is true only for the exact mount path, and that check is what stops a dropped share from being written to as a plain local directory |

`SECONDARY_STORAGE_DIR` and `SMB_MOUNT_POINT` must be **byte-for-byte identical**
in all three scripts on the same host. The collector finds the anchor `backup.sh`
published and the restore reads the same tree; a value differing by a trailing
slash finds nothing and reports an empty chain rather than an error.

> The two chains share the anchor filename, the lock name and the `binlog/`
> layout, so **do not point two hosts at the same `SECONDARY_STORAGE_DIR`.** One
> share directory per chain.

### 1B — tuning

| Setting | Script | Default | Notes |
|---|---|---|---|
| `PARALLEL_THREADS` | `backup.sh` | blank | xtrabackup read threads. Blank = half the cores of whatever host it lands on; fill in a number to pin it |
| `COMPRESS_THREADS` | `backup.sh` | blank | zstd threads, same rule. Half plus half is about one core count, which leaves the box able to serve queries — check 13 warns if the pair exceeds twice the cores |
| `ZSTD_LEVEL` | `backup.sh` | `1` | the link is the bottleneck, not the CPU |
| `MIN_TRANSFER_MIBPS` | `backup.sh` | `0` | floor for the share legs, in MiB/s. `0` measures and reports without warning. Any other value warns — never fails |
| `STREAM_SPACE_PCT` | `backup.sh` | `40` | staging requirement, % of the datadir |
| `XB_TMPDIR` | `backup.sh` | `/Data/xb-tmp` | `--tmpdir`, and the parent of `--extra-lsndir` |
| `BINLOG_SCRIPT` | `backup.sh` | empty | collector to run inline once the archive is published. Empty leaves it to its own cron entry |
| `LOCK_STALE_SECONDS` | `binlog_collect.sh` | `21600` | 6h; past that the collector assumes `backup.sh` crashed |
| `PARALLEL_THREADS` | `restore.sh` | blank | xbstream and `--decompress`, same rule as above |
| `PREPARE_USE_MEMORY` | `restore.sh` | `1G` | xtrabackup's own default is 100MB, which makes the redo apply crawl |
| `DATADIR_SPACE_PCT` | `restore.sh` | `120` | restore requirement, % of the source datadir |
| `ARCHIVE_EXPANSION_FACTOR` | `restore.sh` | `5` | fallback when the manifest carries no `datadir_bytes` |
| `STAGE_ARCHIVE`, `ARCHIVE_STAGE_DIR`, `KEEP_STAGED_ON_FAILURE` | `restore.sh` | `1` | copy the archive local before the wipe; a retry then skips the copy |
| `XBSTREAM_DECOMPRESS` | `restore.sh` | `0` | one-pass extract. Verify the build first: `xbstream --help | grep -i decompress` |
| `MYSQL_READY_TIMEOUT`, `MYSQL_READY_INTERVAL` | `restore.sh` | `900`, `2` | how long to wait for the restored server to accept a connection |
| `CONFIRM_WIPE` | `restore.sh` | `1` | `0` disables restores on this host entirely |
| `KEEP_LOCAL_DAYS` | all three | `14` | prunes logs stranded locally by a dead share |

### 1C — shared between the scripts

| Setting | Why it has to match |
|---|---|
| `BACKUP_BASE` / `BACKUP_BASE_NAME` | local staging, never CIFS. `backup.sh` builds its lock name from this path's basename and `binlog_collect.sh` polls for that exact name, so `BACKUP_BASE_NAME` is that basename |
| `LOCK_DIR` | `backup.sh` writes the lock, `binlog_collect.sh` polls it |
| `LOCAL_STAGE` | the same local staging path, under the name `restore.sh` uses |
| `STATE_DIR` | the restore marker; `restore.sh` writes and reads it |
| `BINLOG_PREFIX` | in `restore.sh`: the **producing** host's `log_bin` basename, which is what names the binlog files on the share — not this host's. `binlog_collect.sh` does not have this setting at all; it asks the server |

### 1D — not set anywhere

Resolved at run time. Each honours an environment variable, for the rare host
where the detected answer is wrong.

| Value | How it is found | Override |
|---|---|---|
| `MYSQL_DATADIR` | `backup.sh`: `SELECT @@datadir`, in pre-flight, right after the connection check. `restore.sh`: the same, then `my_print_defaults mysqld` when the server is down | `MYSQL_DATADIR=/srv/mysql ./backup.sh` |
| `BINLOG_BASE` | `binlog_collect.sh`: `SELECT @@log_bin_basename` | `BINLOG_BASE=/srv/mysql/binlog ./binlog_collect.sh` |
| `MYSQL_SERVICE` | `restore.sh`: the first of `mysql`, `mysqld`, `mariadb` that `systemctl cat` knows | `MYSQL_SERVICE=mysqld ./restore.sh 20260820` |
| `XTRABACKUP_BIN`, `XBSTREAM_BIN`, `MYSQL_BIN`, `MYSQLADMIN_BIN`, `MYSQLBINLOG_BIN` | `command -v` | `XTRABACKUP_BIN=/opt/pxb/bin/xtrabackup ./backup.sh` |

Two are worth understanding. **The datadir**: `backup.sh` reads it, `restore.sh`
erases it. A path typed into a file that was later copied to another host is the
expensive kind of wrong, and the running server always knows the answer.
`restore.sh` needs a second source because it also runs when MySQL is down —
`my_print_defaults` reads the same `my.cnf` `mysqld` itself would read. If neither
answers, it stops rather than guessing at a directory it is about to delete.

**The binlog path**: a stale `BINLOG_BASE` points the collector at a directory
that does not exist or is empty. It copies nothing, finds no gap, and writes a
clean run — the worst failure available to the one script PITR depends on.
`@@log_bin_basename` cannot go stale.

Both print their source in the run header, so a log records what was used rather
than what the file says today:

```
 datadir         : /Data/mysql  (@@datadir)
 source          : /Data/mysql/binlog  (@@log_bin_basename)
```

## 11. Operating and troubleshooting

### Deployment

```bash
install -m 700 backup.sh binlog_collect.sh restore.sh /Data/script/
mkdir -p /Data/dbvault-stage /Data/xb-tmp
```

Then fill in PART 1A of each — four values per script, twelve in all, with
`SECONDARY_STORAGE_DIR` and `SMB_MOUNT_POINT` identical across the three. Nothing
else in PART 1 has to change to deploy on a new host: the datadir, the binlog path
and every binary are asked for at run time (§10, 1D). Confirm what a host resolved
to without running a backup:

```bash
/Data/script/restore.sh 20260820 --dry-run | head -20
```

`backup.sh` runs `binlog_collect.sh` inline via `BINLOG_SCRIPT`, so that path must
point at the deployed copy.

```cron
15 1 * * *   /Data/script/backup.sh
*/15 * * * * /Data/script/binlog_collect.sh
```

Mode 700 because the scripts hold credentials. They must be **LF, not CRLF** — a
`#!/usr/bin/env bash\r` shebang fails with a confusing "no such file or directory".

### Reading a log

```bash
# outcome of every backup, one line each
grep '^ RESULT' <share>/logs/*/backup.log

# what went wrong, and in which phase
grep -E '^[0-9:]+ (WARN|ERROR)' <share>/logs/20260820/backup.log

# the collector, newest run last (appended every 15 min)
tail -40 <share>/logs/20260820/collect/collect.log
```

### Recovery, start to finish

```bash
# 1. Snapshot the VM. If the current data is damaged, it is still evidence.
# 2. Inspect what would happen.
./restore.sh 20260820 --dry-run
# 3. Run it.
./restore.sh 20260820
# 4. Verify row counts and run application smoke tests.
# 5. Take a fresh full backup — the binlog chain restarts here.
./backup.sh
```

Until step 5 completes, the server has no usable recovery baseline.

### Symptom → cause

| Symptom | Cause |
|---|---|
| `xtrabackup version … 8.0.29` then refusal | below 8.0.30, no `--compress-zstd-level`. Upgrade, or use the tar chain |
| `xtrabackup version … UNPARSED` (warning) | the `--version` banner format changed. Harmless; the stream still runs |
| `completed OK! count … 0, want 1` | the backup did not finish; read the tail of `xtrabackup.log` |
| `completed OK! count … 2, want 1` | the log was reused across runs; nothing read from it is trustworthy |
| `extra-lsndir metadata … MISSING` | `XB_TMPDIR` not writable, or the run died before writing metadata |
| `binlog position … NOT FOUND` | binary logging is off on the source. No PITR from that backup |
| `metadata dir empty … NO` | stale `<XB_TMPDIR>/<id>` from a killed run. Remove it |
| `archive name free … NO` | two runs started in the same second, or the share was unreachable when the name was chosen and that day is already taken |
| `disk space … INSUFFICIENT` | see §9; raise `STREAM_SPACE_PCT` |
| `smb share … NOT WRITABLE` | stale handle or expired credentials. Remount |
| `share throughput … BELOW n MiB/s` | the share legs ran under `MIN_TRANSFER_MIBPS`. The archive is fine; see §9 |
| `start binlog … PURGED` | MySQL purged a binlog before collection. Raise `binlog_expire_logs_seconds` |
| `SEQUENCE GAP` | same cause; that PITR range is permanently lost |
| `Manifest says archive_format='tar.gz'` | a tar-chain archive. Use `standalone/physical/restore_full.sh` |
| `Manifest says prepared='yes'` | likewise — a prepared archive from the other chain |
| `Compressed files remain after --decompress` | this xtrabackup build lacks the compression used; compare the manifest's `compression=` |
| `THE DATADIR IS NOT PREPARED` | the prepare did not complete. **Do not start mysqld.** Read `xtrabackup.log`, re-run |
| `BINLOGS HAVE ALREADY BEEN APPLIED` | `--binlog-only` twice. Roll back with a full re-run |

### Not implemented

Retention and pruning, incremental backups, automated restore verification. Same
as the tar chain — archives accumulate until something else removes them.
