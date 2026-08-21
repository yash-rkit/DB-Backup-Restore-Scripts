# Physical Backup and Restore (Percona XtraBackup, SMB/CIFS)

Reference for the five standalone scripts in [server/physical/](../../../server/physical/).

| Script              | Role                                                          | Run by                |
| ------------------- | ------------------------------------------------------------- | --------------------- |
| `backup.sh`         | full XtraBackup, prepared, compressed, checksummed, published | crontab, daily        |
| `binlog_collect.sh` | copies binlogs forward from the last backup                   | crontab, every 15 min |
| `restore_full.sh`   | wipes the datadir and restores one archive                    | by hand               |
| `apply_binlog.sh`   | replays collected binlogs on top of that restore              | by hand               |
| `restore.sh`        | wrapper: runs the two restore phases in order                 | by hand               |

These are the **standalone** variants: no portal, no positional arguments, no
`CMC27` tokens, nothing written to `BLS02`/`BLS03`/`BLS04`. Everything is
configured in each script's `CONFIGURATION` block, and all state lives on disk
and in the log files. The portal variants under [db-vault/](../../../db-vault/)
are documented in [instructions/README.md](../../README.md).

The logical (mysqldump) counterpart is documented in
[instructions/server/logical/README.md](../logical/README.md).

---

## Contents

| §   | Section                                                                           |
| --- | --------------------------------------------------------------------------------- |
| 1   | [The two facts everything follows from](#1-the-two-facts-everything-follows-from) |
| 2   | [Published layout](#2-published-layout)                                           |
| 3   | [Naming and anchors](#3-naming-and-anchors)                                       |
| 4   | [backup.sh](#4-backupsh)                                                          |
| 5   | [binlog_collect.sh](#5-binlog_collectsh)                                          |
| 6   | [The lock interlock](#6-the-lock-interlock)                                       |
| 7   | [restore_full.sh](#7-restore_fullsh)                                              |
| 8   | [apply_binlog.sh](#8-apply_binlogsh)                                              |
| 9   | [restore.sh](#9-restoresh)                                                        |
| 10  | [Safety invariants](#10-safety-invariants)                                        |
| 11  | [Configuration reference](#11-configuration-reference)                            |
| 12  | [Operating and troubleshooting](#12-operating-and-troubleshooting)                |

---

## 1. The two facts everything follows from

Almost every non-obvious decision in these five scripts traces back to one of
two constraints. Read this section before changing anything.

### Fact 1: the destination is CIFS, and CIFS lies

**`--prepare` must never run on the share.** It rewrites InnoDB pages in place
and needs three things CIFS does not reliably provide: POSIX **ownership** (CIFS
fixes it at mount time via `uid=`/`gid=`, so `chown` returns `EPERM`),
**byte-range locking**, and **coherent attribute caching**. The failure mode is
the dangerous kind — `--prepare` reports success and the archive is silently
corrupt. You find out at restore time. Hence: stage on local disk, prepare
there, publish the finished archive.

**A dropped mount looks exactly like an empty directory.** When CIFS drops, the
mount point reverts to a plain local directory. `[[ -d ]]` passes, `[[ -w ]]`
passes, `ls` passes — and writes land on the root filesystem and fill it. That
is why every script calls `mountpoint -q` on the **exact mount point**, never a
`-d` test, and why `SMB_MOUNT_POINT` is configured separately from
`SECONDARY_STORAGE_DIR`: `mountpoint -q` only ever returns true for the exact
mount point, so pointing it at a subdirectory would make every run fail.

**Mounted is not the same as alive.** A NAS reboot or expired credentials leaves
the mount listed while every write fails with `EIO`, and `ls` can be served
entirely from the attribute cache. Only an actual write proves otherwise — hence
the `.probe_$$` touch in `require_smb`.

**mtime is not trustworthy.** It comes from the server's clock and is
attribute-cached, so `binlog_collect.sh` picks its anchor by **filename**, never
by "newest by mtime" — a clock skew would silently reset collection to an older
backup and break PITR coverage.

**`cp -p` fails on copies that worked.** CIFS cannot preserve ownership, so `-p`
returns non-zero even when the data copied perfectly, which would count good
binlogs as errors. Plain `cp` plus a size check and a parse check is the real
integrity guarantee.

### Fact 2: GTID is off

Recovery here is by binlog **file + position** only. Everything in
`apply_binlog.sh` follows from this:

- **There is no duplicate detection.** Applying the same transaction twice
  applies it twice. MySQL will not notice and will not complain. `INSERT`s
  duplicate; a non-idempotent `UPDATE balance = balance - 50` runs twice.
- **Apply is one-shot.** If it fails partway it cannot be resumed: restarting
  from the failed file duplicates data, and starting from the next file loses
  data. Neither is acceptable, so the only correct response is to restore the
  full backup again and retry.
- **Therefore** the script halts on the _first_ error rather than continuing to
  the next file, and _hard-refuses_ a second apply rather than warning.
- **A sequence gap is silent.** Replay does not error on a missing binlog — it
  applies what it is given and carries on, and the database comes up looking
  perfectly healthy with every transaction in the hole simply gone.

With GTID on, `--skip-gtids` would make re-runs self-correcting and most of this
would be belt-and-braces. It is off, so the script _is_ the safety net.
`--skip-gtids` is deliberately not passed: it would be a no-op that implies a
protection this setup does not have.

---

## 2. Published layout

Everything permanent lives on the share. Local staging is emptied after every
backup run.

```
<SECONDARY_STORAGE_DIR>/
├── 20260809.tar.gz             ← the prepared, compressed datadir
├── 20260809.sha256             ← checksum, ABSOLUTE path to the archive
├── 20260809.manifest           ← sidecar read before extraction
├── 20260809_binlog_info        ← PITR anchor: <binlog file> <position>
├── 20260810.tar.gz
│   …
├── binlog/
│   └── 20260809/               ← binlogs belonging to that backup
│       ├── binlog.000007
│       ├── binlog.000008
│       ├── binlog.sha256       ← append-only, bare filenames
│       └── last_copied_binlog  ← resume state
└── logs/
    └── 20260809/
        ├── backup.log
        ├── xtrabackup.log
        ├── errors.log
        ├── collect/            ← every collection run against this backup
        ├── restore/            ← restore_full.sh
        └── apply/              ← apply_binlog.sh
```

Three deliberate properties:

- **Restorable artifacts stay flat at the top level**, so `*.tar.gz` and
  `*_binlog_info` globs stay simple and clean.
- **`logs/` is a separate subtree**, so retention can prune logs on its own
  schedule without touching archives.
- **`binlog/<date>/` is pure data** — binlogs and resume state, no logs mixed in.

Filenames inside `logs/<date>/` carry no date prefix; the folder already does.

Local state that is deliberately **not** on the share:

| Path                 | Why                                                                                                                                                                                                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/var/lock/dbvault/` | a lock is only meaningful to processes on this host, and on a network mount a dropped mount makes `[[ -f ]]` read as "no backup running" — the interlock would fail exactly when it matters. `/var/lock` is tmpfs, so a reboot clears a lock left by a hard kill                    |
| `/var/lib/dbvault/`  | the restore marker records what **this server** did, not a property of the backup. Two servers restoring the same archive would overwrite each other's marker, and the double-apply guard would read the wrong server's state. `/var/lib`, not `/var/lock`, so it survives a reboot |

---

## 3. Naming and anchors

Every artifact of a run shares one base name: **the run date**.

```
20260809.tar.gz   20260809.sha256   20260809.manifest   20260809_binlog_info
```

No job prefix — one destination folder holds exactly one backup job's output.

> **Consequence:** two backup jobs must never share a destination folder.
> Without a prefix their same-day archives collide on identical names.

**Same-day reruns** append a time: `20260809_143005`. The backup detects this by
checking the **destination**, because local staging is wiped after every run —
only the published archive proves a same-day backup already exists.

### How the collector picks its anchor

The collector finds the latest `*_binlog_info` on the share. That backup is what
it collects against, and its name becomes the `binlog/<name>/` and
`logs/<name>/` folder.

Selection sorts on **date and time as separate keys**, not a plain lexical sort:

```
plain sort:            20260809_143005  <  20260809     ← rerun ignored!
                       ('_' sorts before end-of-string)

date + time as keys:   20260809 000000  <  20260809 143005   ← correct
                       (a bare date is treated as time 000000)
```

There is no fixed lookback window, so a backup older than _N_ days is still
found rather than the collector reporting "nothing to collect".

---

## 4. `backup.sh`

Pre-flight, seven stages, then inline binlog collection.

### The early mount check

Before the numbered checks, and duplicated by Check 8, because two things below
that point go silently wrong on a dropped mount:

- the same-day collision test reads `<share>/<date>.tar.gz`; on an unmounted
  path that test is false, so a rerun reuses a name already taken on the NAS
- `mkdir -p` on the share tree would **create** those directories locally under
  the bare mount point, and the run would fill the root filesystem

`mountpoint` itself is checked here rather than in Check 2's binary sweep — a
missing binary would otherwise surface as a confusing "share is not mounted"
(exit 127 satisfying the negation).

### Pre-flight (14 checks)

| #   | Check                     | #   | Check                               |
| --- | ------------------------- | --- | ----------------------------------- |
| 1   | user privileges           | 8   | SMB share mounted **and** writable  |
| 2   | required binaries present | 9   | disk space (staging 1.5x, share 1x) |
| 3   | xtrabackup version        | 10  | no concurrent xtrabackup            |
| 4   | MySQL running             | 11  | binary logging enabled              |
| 5   | datadir exists + readable | 12  | target directory empty              |
| 6   | MySQL connection          | 13  | tar/gzip working                    |
| 7   | staging writable          | 14  | sha256sum working                   |

Check 9 rounds the staging requirement **up**: an off-by-one GB here becomes
`ENOSPC` hours into the run. Staging needs ~1.5x the data size — the raw backup
(~1x) plus the `.tar.gz` written beside it before the raw directory is removed.
Raise `LOCAL_SPACE_PCT` if the data compresses poorly (already-compressed BLOBs,
encrypted tablespaces).

### The seven stages

| #   | Stage               | Notes                                                             |
| --- | ------------------- | ----------------------------------------------------------------- |
| 1   | Create backup       | `xtrabackup --backup` to **local** staging, `PARALLEL_THREADS`    |
| 2   | Validate integrity  | `xtrabackup_checkpoints` and friends present                      |
| 3   | Prepare             | `chown mysql` then `--prepare`, both on local disk                |
| 4   | Extract binlog info | `xtrabackup_binlog_info` → the PITR anchor                        |
| 5   | Compress            | `tar -czf`, records size and ratio                                |
| 6   | Checksum            | SHA-256, generated **and verified** in staging                    |
| 7   | Publish             | copy → verify at the destination → finalise → drop the local copy |
| 8   | Collect binlogs     | inline, best-effort, never fails the backup                       |

The raw backup directory is removed **before** stage 7, so staging reclaims that
space while the slow network copy runs.

**Two independent prepare checks in stage 3.** First the count of
`completed OK!` lines must be **2** — a bare `grep -q` is not enough, because
`--backup` and `--prepare` append to the same log, so the line left by the
successful backup phase satisfies the grep even when prepare failed outright.
Then the authoritative test: `--prepare` rewrites `backup_type` in
`xtrabackup_checkpoints` from `full-backuped` to `full-prepared`. Nothing
downstream re-runs `--prepare`, so publishing an unprepared backup means
publishing one that cannot be restored — and you would not find out until a real
recovery.

**Stage 7 re-asserts the mount** before copying. Pre-flight may have passed
hours ago on a large dataset, and a share that dropped since would look like an
empty local directory: the copy would "succeed" onto the root filesystem and
even pass its own checksum re-read, publishing a backup that is not on the NAS
at all.

**Stage 8 is deliberately best-effort.** By then the archive is complete and
verified, so a binlog problem must not fail the run. It exists only to start
PITR coverage immediately rather than waiting up to 15 minutes for the next
collector fire.

### The manifest

A plain-text sidecar written **outside** the tarball on purpose: `restore_full.sh`
needs the checksum, the source MySQL version and the prepared flag _before_ it
commits to extracting, and reading them from inside the archive would mean
unpacking hundreds of GB first. Written via `.part` + `mv`, so a restore never
reads a half-written one.

```
backup_id, created_at, archive_path, archive_sha256
prepared=yes, backup_type=full-prepared
mysql_version, xtrabackup_version, binlog_format, gtid_mode
binlog_file, binlog_pos
recovery_method=file_position
datadir
```

`recovery_method=file_position` is recorded deliberately. Whoever reads this file
in two years needs the one-shot constraint stated, not inferred from the absence
of a GTID field.

---

## 5. `binlog_collect.sh`

The archive alone restores you to the instant the backup ran. Binlogs carry you
forward from there, and that only works if collection is unbroken.

Each run:

1. **Check the share is reachable** — unreachable → **exit 1 loudly** (below).
2. **Check the lock** — backup running → exit 0 immediately ([§6](#6-the-lock-interlock)).
3. **Find the anchor** — latest `*_binlog_info` ([§3](#3-naming-and-anchors)).
4. **Determine the start point** — `last_copied_binlog` if present (resume),
   else the anchor's own position (first run after a backup).
5. **`FLUSH BINARY LOGS`**, so the binlog that was active becomes closed and
   safe to copy.
6. **Copy** every binlog from the start point onward, **skipping the currently
   active one**.
7. **Check sequence continuity** across everything archived so far.

**Why an unreachable share is a hard failure.** If the mount is down, the anchor
lookup finds nothing, and the natural response — "no backup yet, nothing to do,
exit 0" — is indistinguishable from a healthy idle run. The job goes green while
collecting nothing and PITR coverage disappears without anyone noticing. The
reachability check therefore runs _before_ the anchor lookup and fails loudly.

### What each copied binlog must survive

| Check                | Catches                                                                                                                                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| size match           | an interrupted or short copy                                                                                                                                                                                                         |
| `mysqlbinlog` parse  | a **truncated or corrupt source** — a VM that died mid-write leaves a binlog that copies perfectly and then fails during recovery. Validated against the destination, so it covers both a bad original and a copy mangled in transit |
| `sha256sum` recorded | lets `apply_binlog.sh` detect a binlog that rotted on the share between collection and recovery — the window where nothing else is watching them                                                                                     |

A binlog that fails any of these is **deleted rather than archived**, and the
resume state only advances after a fully validated copy.

`binlog.sha256` is append-only and stores **bare** filenames, so verification
works from whatever directory the binlogs are staged into later.

### Purged binlogs and gaps

If the start binlog is gone from disk (MySQL expired it), the collector falls
back to the earliest available one and logs a `CRITICAL` warning naming the gap.
Partial coverage beats none, but the gap is real and unrecoverable. Prevent it by
setting `binlog_expire_logs_seconds` to at least **3× your longest backup
duration**.

The sequence check catches the other shape of the same problem — a hole in the
middle of the archived run. It has to be caught here, while the missing file may
still be sitting on the source server.

### Exit code

Any error means the PITR chain is not intact, so the run exits **non-zero**. An
earlier version logged a warning and exited 0: cron saw a green run every 15
minutes while recovery coverage was quietly broken — a monitored job that cannot
fail is worse than no monitoring.

This is a _partial-success_ exit. Binlogs that copied and validated stay
archived, and the state file still points at the last good one, so the next run
resumes correctly rather than starting over.

---

## 6. The lock interlock

A backup and a collection run must not overlap: the collector would copy binlogs
while `xtrabackup` is establishing its position, producing an inconsistent set.

`backup.sh` writes a date-stamped lock at the start and removes it at the end —
on success _and_ on failure, via the trap. `binlog_collect.sh` checks for it and
exits 0 if present.

The lock is **local to the VM** and per-staging-directory
(`/var/lock/dbvault/<basename BACKUP_BASE>_<date>_lock`). The collector rebuilds
that exact path from `LOCK_DIR` + `BACKUP_BASE_NAME`, so **`BACKUP_BASE_NAME`
must be updated if `BACKUP_BASE` changes** — a mismatch is silent and means the
collector runs _during_ backups.

**Stale locks.** A lock older than `LOCK_STALE_SECONDS` (default 6h) means the
backup probably crashed without cleanup. The collector warns and proceeds rather
than blocking collection forever.

Both scripts must run as the **same user**, or the interlock will not work.

---

## 7. `restore_full.sh`

```bash
./restore_full.sh 20260810
./restore_full.sh 20260810_143005
```

Restores one archive. Does **not** apply binlogs.

The archive is **never staged locally** — it is read directly from the share.
That keeps the local requirement to just the extracted datadir, at two costs
worth knowing:

- The archive is read over the network **twice**: once to verify, once to
  extract. Verification is not skipped to save that read — extracting an
  unverified archive over a wiped datadir is how a corrupt backup becomes a
  corrupt database.
- The network sits in the middle of the **destructive** phase. If the share
  stalls during extraction the datadir is already wiped and is left partially
  populated; the fix is to wait for the share and re-run from the start, with
  the database down until then. Verification happens _before_ the wipe, so a
  corrupt or unreachable archive still costs nothing.

### `CONFIRM_WIPE`

| Value | Behaviour                                                  |
| ----- | ---------------------------------------------------------- |
| `1`   | normal: the script runs and erases `MYSQL_DATADIR`         |
| `0`   | the script refuses to run at all, before touching anything |

This is an **off switch, not a safe mode** — a restore that cannot wipe cannot
restore, so `0` does nothing useful. Leave it at `0` on a server where nobody
should be able to trigger a restore by mistake (a shared box, or between drills).
It is Check 3, deliberately before any long-running work: there is no point
spending an hour reading an archive only to refuse at the wipe step.

### Pre-flight (11 checks)

Root · binaries · `CONFIRM_WIPE` · SMB share · archive exists · **expected
SHA-256 resolved** · manifest sane · MySQL versions compared · datadir space ·
MySQL status · existing restore state.

**Checksum resolution** takes the manifest first and `<id>.sha256` as a fallback
for backups that predate manifests. If neither exists the script **refuses** —
that is the whole point.

**The version comparison is informational only.** The classic Recovery Services
Vault trap: a VM restored from an image often carries an _older_ MySQL than the
backup came from. InnoDB upgrades its data dictionary forward and refuses to go
backward, so an older server started on a newer datadir fails, sometimes only
after partial writes. It is a warning and not an abort because the comparison is
a crude string match, and a false positive that blocked the restore would leave
you unable to recover at all. If MySQL will not start at the end, this is the
first thing to check.

**Datadir space** is estimated at 4x the compressed size — gzip on InnoDB pages
typically lands around 3–4x, and 4x is the conservative end.

### Stages

1. **Verify the archive on the share** — before MySQL is stopped and before
   anything is erased. Failing here is free.
2. **Stop MySQL** — refuses to continue if the server is still up after the stop
   command, rather than wiping a datadir with a live server attached.
3. **Wipe and extract** — the datadir path is re-asserted immediately before
   `rm -rf`; cheap, and the one place where a mistake is unrecoverable.
4. **Validate the extracted datadir** — core artifacts present, and
   `backup_type=full-prepared` re-asserted against **what actually reached the
   disk**. Re-hashing the tarball here would prove only that the file just read
   is the file just read.

Then MySQL is started, waited on for up to 120s, and the restore marker is
written.

**When this finishes the database is UP but not current** — it holds data as of
the backup, not as of the failure. Managing application access during that
window is left to the operator.

---

## 8. `apply_binlog.sh`

```bash
./apply_binlog.sh 20260810 --dry-run     # ALWAYS do this first
./apply_binlog.sh 20260810
./apply_binlog.sh 20260810 --from binlog.000123
```

Read [§1, Fact 2](#fact-2-gtid-is-off) before changing anything here.

### The two guards that matter

**Check 3 — a restore marker must exist.** Applying binlogs to a database that
was not restored from _this exact_ backup applies transactions against the wrong
starting state. The result is silent, unrecoverable divergence, not an error
message.

**Check 4 — a second apply is hard-refused.** The single most important guard in
the script. Re-running would re-execute every transaction on top of a database
that already contains them, with no duplicate detection anywhere. To genuinely
redo an apply, restore the full backup first.

### Staging

Binlogs are copied from the share to local disk before being applied.
`mysqlbinlog <path> | mysql` is a live pipe held open for the whole file; if that
path is on CIFS and the share stalls, the pipe breaks mid-transaction-stream —
the exact failure a one-shot apply cannot absorb.

`rsync` is preferred but **optional**, with a `cp` fallback: a missing
convenience tool must not block recovery during an incident. The checksum
verification afterwards is what establishes integrity, and it runs identically
either way.

Staged binlogs are then verified against `binlog.sha256` from collection time. A
mismatch is a hard stop — applying a corrupted binlog injects corrupt data.

### Start position

| Case                                  | Start file        | Start position                             |
| ------------------------------------- | ----------------- | ------------------------------------------ |
| no `--from`                           | the backup anchor | the anchor position — no gap, no duplicate |
| `--from`, different file              | that file         | 4 (whole file)                             |
| `--from`, **same file as the anchor** | that file         | the **anchor** position, not 4             |

The third case is the edge case worth knowing: the full backup already contains
that file up to the anchor position, so starting at 4 would re-apply those
transactions. It is detected and corrected automatically, with a warning.

Position 4 is the first real event in a binlog, past the 4-byte magic header.

### Dry run

Decodes exactly what _would_ be applied into
`<LOCAL_STAGE>/<id>_binlog_preview.sql`, touches nothing, and greps the result
for `DROP`/`TRUNCATE`/`ALTER`. With a one-shot apply this is the cheapest risk
reduction available, and the only chance to notice that the incident you are
recovering _from_ is itself sitting in the binlogs about to be replayed.

### The apply, and what happens if it fails

`--disable-log-bin` is passed so replayed events are not written back into this
server's own binlog — otherwise the next backup's chain would contain them twice.

On the first failure the script **halts**: later binlogs are not applied, the
instance is declared partially applied, and the log states the only correct
recovery — do not let applications near it, inspect the cause, roll back with
`restore_full.sh`, fix, retry. Rolling back re-reads the full archive from the
share, so budget for the same transfer time as the original restore.

On success the marker is updated to `binlogs_applied=yes` **immediately**, before
anything else can be attempted. If that write fails the script exits 1 and tells
you to fix it by hand — the apply succeeded, but a second run would no longer be
refused.

### After a successful apply

1. Verify: row counts on the busiest tables, application smoke tests.
2. **Take a fresh full backup immediately.** The binlog chain restarts at this
   recovery point; until a new full backup exists, the server has no usable
   recovery baseline.

---

## 9. `restore.sh`

A wrapper that runs `restore_full.sh` then `apply_binlog.sh`, and nothing else.

It contains **no restore logic of its own, deliberately**. The previous
generation of these scripts duplicated the logic in a third place and the copies
drifted — a different MySQL user, a different base path — so the wrapper silently
stopped matching the scripts it was meant to mirror. Every fix would otherwise
have to be made three times, and one copy always gets missed.

**`--dry-run` is rejected, not forwarded.** Forwarding it would run the
destructive Phase 1 in full and only then preview Phase 2 — the opposite of what
anyone typing "dry run" expects, and unrecoverable by the time they find out.

**Its lock is a different file** (`restore_wrapper.lock`) from the
`restore.lock` its children take. Using the same one would deadlock: each child
opens its own file description and would block on the lock the wrapper already
holds.

For anything non-routine, run the phases by hand. The staged flow gives you a
checkpoint between "data restored" and "binlogs applied", which is the last point
at which a mistake is still cheap:

```bash
./restore_full.sh 20260810
./apply_binlog.sh 20260810 --dry-run
./apply_binlog.sh 20260810
```

---

## 10. Safety invariants

Rules these scripts hold to. Each exists because violating it can lose data.

**1. Copy-verify-then-delete — never a bare move.** The archive is copied to the
share, its SHA-256 is verified _there_, and only then is the staged copy removed.
A move that fails midway across a network boundary can leave zero good copies.

**2. Partial transfers are named `.part`.** An interrupted copy never matches a
`*.tar.gz` glob, so retention and restore tooling cannot mistake it for a
finished archive.

**3. A verified archive is never deleted by cleanup.** Once the copy is confirmed
good at the destination, a later-stage failure will not remove it.

**4. The checksum file always points at the archive's current location.** It
records an absolute path, so `sha256sum -c` resolves from any working directory.
When the archive moves, the checksum file is rewritten to match.

**5. Logs are published on failure too.** A failure is when logs matter most.
They are written locally during the run — a log on the share is useless when the
share is the thing that failed — and moved to `logs/<date>/` on both paths.

**6. The destination is mandatory,** validated at startup and again in pre-flight,
and it must not live inside the staging area that gets wiped after every run.

**7. Nothing unprepared is ever published or started.** Asserted at publish time
and again against the extracted datadir.

**8. Verify before destroying.** The archive's checksum is confirmed before MySQL
is stopped; the binlogs' checksums are confirmed before any is applied.

**9. Halt, never limp on.** A failed binlog apply stops at the failed file. A
failed collection exits non-zero. Partial success is reported as failure.

---

## 11. Configuration reference

### Must match across scripts

Get these wrong and the scripts silently stop finding each other.

| Setting                         | Shared by              | Consequence of a mismatch                                            |
| ------------------------------- | ---------------------- | -------------------------------------------------------------------- |
| `SECONDARY_STORAGE_DIR`         | all five               | collector never finds the anchor → collects nothing, reports success |
| `SMB_MOUNT_POINT`               | all five               | mount checks fail, or pass when they should not                      |
| `LOCK_DIR` + `BACKUP_BASE_NAME` | backup, collect        | collector never sees the lock → runs _during_ a backup               |
| `LOCAL_STAGE` / `BACKUP_BASE`   | backup, restore, apply | binlogs staged where nothing looks for them                          |
| `STATE_DIR`                     | restore_full, apply    | the double-apply guard reads nothing                                 |
| `BINLOG_PREFIX` / `BINLOG_BASE` | collect, apply         | binlogs not enumerated                                               |

> The first two failure modes are **silent**. After editing any script, verify
> the set still agrees.

### Per-script

| Setting                                          | Meaning                                                              |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| `BACKUP_BASE` / `LOCAL_STAGE`                    | local staging; ~1.5x data size for the backup, logs only for restore |
| `LOCAL_SPACE_PCT`                                | staging space required as a % of data size (default 150)             |
| `SECONDARY_STORAGE_DIR`                          | the share — permanent home, **required**                             |
| `SMB_MOUNT_POINT`                                | the exact CIFS mount point, usually a parent of the above            |
| `MYSQL_DATADIR`                                  | MySQL data directory (erased by `restore_full.sh`)                   |
| `BINLOG_BASE`                                    | binlog directory + basename, e.g. `/Data/mysql/binlog`               |
| `PARALLEL_THREADS`                               | xtrabackup parallelism                                               |
| `XTRABACKUP_BIN`, `MYSQL_BIN`, `MYSQLBINLOG_BIN` | binary paths                                                         |
| `LOCK_STALE_SECONDS`                             | stale-lock threshold, default `21600` (6h)                           |
| `BINLOG_SCRIPT`                                  | collector path, run inline after the backup                          |
| `CONFIRM_WIPE`                                   | `restore_full.sh` off switch — see [§7](#7-restore_fullsh)           |
| `MYSQL_SERVICE`                                  | systemd unit name                                                    |

---

## 12. Operating and troubleshooting

### Deployment

```cron
30 1  * * *  /opt/dbvault/backup.sh          >> /var/log/dbvault-backup.log 2>&1
*/15  * * * *  /opt/dbvault/binlog_collect.sh >> /var/log/dbvault-binlog.log 2>&1
```

Run as `root`, or as a user that can read the datadir, write `/var/lock/dbvault`,
and write both storage locations. Both scheduled scripts must run as the **same**
user. The three restore scripts require root and are run by hand.

### Verifying a backup

```bash
sha256sum -c <share>/20260809.sha256      # resolves from any directory
cat        <share>/20260809.manifest      # prepared flag, versions, anchor
cat        <share>/20260809_binlog_info   # <binlog file> <position>
ls         <share>/binlog/20260809/       # PITR coverage
```

### Recovery, start to finish

```bash
./restore_full.sh 20260810                # verify → wipe → extract → start
./apply_binlog.sh 20260810 --dry-run      # inspect before committing
./apply_binlog.sh 20260810                # one-shot
./backup.sh                               # immediately — new baseline
```

### Symptom → cause

| Symptom                                                 | Likely cause                                                                                         |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Collector exits 0, collects nothing, no anchor found    | No backup has completed yet — or `SECONDARY_STORAGE_DIR` differs between the scripts                 |
| Collector runs _during_ a backup                        | `LOCK_DIR` or `BACKUP_BASE_NAME` mismatch                                                            |
| Collector exits 1, "not mounted" / "not writable"       | Share is down or the handle is stale — deliberate loud failure                                       |
| `--prepare` fails, or the archive is corrupt at restore | Staging is on the CIFS mount; it must be local disk ([§1](#1-the-two-facts-everything-follows-from)) |
| "Not writable" on the share                             | Mount's `uid=`/`gid=`/`file_mode=`/`dir_mode=` options                                               |
| "Insufficient space" during backup                      | Staging needs ~1.5x data size; raise `LOCAL_SPACE_PCT` if compression is poor                        |
| Same-day rerun overwrote a backup                       | Two jobs sharing one destination folder ([§3](#3-naming-and-anchors))                                |
| `CRITICAL: coverage gap` in the collector log           | MySQL purged binlogs before collection; raise `binlog_expire_logs_seconds`                           |
| `SEQUENCE GAP` reported                                 | Same cause; PITR across that range is not possible                                                   |
| `.part` file left on the share                          | Interrupted transfer; safe to delete, it is not a valid archive                                      |
| Restore refuses: "No checksum available"                | Neither manifest nor `.sha256` present — restoring unverified is not offered                         |
| Restore refuses: "NOT PREPARED"                         | The archive was published unprepared; MySQL is left stopped on purpose                               |
| MySQL will not start after a restore                    | Check the version warning in the restore log first ([§7](#7-restore_fullsh))                         |
| Apply refuses: "NO RESTORE MARKER"                      | `restore_full.sh` was not run for this backup ID **on this server**                                  |
| Apply refuses: "ALREADY BEEN APPLIED"                   | Working as designed; restore the full backup first to redo it                                        |
| Apply halted partway                                    | Do not let applications use the server; roll back with `restore_full.sh`                             |

### Not yet implemented

- **Retention.** Nothing here deletes anything. Archives, `binlog/<date>/` and
  `logs/<date>/` accumulate one entry per backup indefinitely, so the share grows
  without bound. Retention belongs in a separate scheduled job — deliberately not
  invoked from the backup, since it is independent of whether a backup ran and
  should not extend the lock window.
  When writing one, prune a backup and its `binlog/<date>/` and `logs/<date>/`
  folders **together**: removing an archive while leaving its binlogs behind
  leaves collected logs anchored to a backup that no longer exists.
- **Partial / incremental backups.** Every run is a full backup.
- **Restoring a single database.** XtraBackup restores the whole instance; use
  the [logical chain](../logical/README.md) for per-database recovery.
