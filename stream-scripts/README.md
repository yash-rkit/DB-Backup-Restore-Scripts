# Streaming Physical Backup and Restore (XtraBackup xbstream + zstd, SMB/CIFS)

Reference for the three scripts in [stream-scripts/physical/](./).

| Script              | Role                                                       | Run by                |
| ------------------- | ---------------------------------------------------------- | --------------------- |
| `backup.sh`         | full backup streamed to one compressed `.xbstream`, then collects the first binlogs | crontab, daily |
| `binlog_collect.sh` | copies binlogs forward from the last backup                | crontab, every 15 min |
| `restore.sh`        | verify → wipe → extract → decompress → **prepare** → start → apply binlogs | by hand |

A variant of [server/physical/](../../server/physical/), not a replacement. Same
storage model, same CIFS assumptions, same lock interlock, same file+position
recovery. Shared behaviour is documented in
[server/physical/README.md](../../server/physical/README.md); this document
covers what is different and everything that follows from it.

---

## Contents

| §   | Section                                                                 |
| --- | ----------------------------------------------------------------------- |
| 1   | [What changed, and what it costs](#1-what-changed-and-what-it-costs)    |
| 2   | [Where `--prepare` moved](#2-where---prepare-moved)                     |
| 3   | [Published layout](#3-published-layout)                                 |
| 4   | [Log structure](#4-log-structure)                                       |
| 5   | [Script structure: the PART layout](#5-script-structure-the-part-layout) |
| 6   | [Failure handling](#6-failure-handling)                                 |
| 7   | [`backup.sh` walkthrough](#7-backupsh-walkthrough)                      |
| 8   | [`binlog_collect.sh` walkthrough](#8-binlog_collectsh-walkthrough)      |
| 9   | [`restore.sh`](#9-restoresh)                                            |
| 10  | [Disk space](#10-disk-space)                                            |
| 11  | [Configuration reference](#11-configuration-reference)                  |
| 12  | [Operating and troubleshooting](#12-operating-and-troubleshooting)      |

---

## 1. What changed, and what it costs

The tar chain writes the datadir out three times: xtrabackup copies it to a
directory, `--prepare` rewrites it in place, then `tar -czf` reads all of it back
to produce the archive. The streaming chain does one pass.

```
tar chain     datadir ──copy──> target dir ──prepare──> ──tar+gzip──> 20260809.tar.gz
                        (1x disk)          (rewrite)     (read all)

stream chain  datadir ──xtrabackup --stream=xbstream --compress──> 20260820.xbstream
                        (compressed on the fly, straight to one file)
```

| | tar chain | stream chain |
| --- | --- | --- |
| Backup command | `--backup --target-dir`, then `--prepare`, then `tar` | one `--backup --stream=xbstream --compress` |
| Compression | gzip, single-threaded, after the fact | zstd level 1, `--compress-threads=8`, inline |
| Staging needed | ~1.5x datadir | ~60% of datadir (the compressed stream only) |
| Published archive | `.tar.gz`, **prepared** | `.xbstream`, **unprepared** |
| Prepare happens | at backup time | at restore time |
| Restore work | extract | extract → decompress → prepare |
| Backup window | long | short |
| Restore window | short | longer, by the prepare |

**The trade is deliberate: time moves off the backup window and onto the restore
window.** The backup runs against a live production database, so shortening it
reduces the period of extra I/O load and reduces the chance of MySQL purging a
binlog before the collector reaches it. The restore runs on a server nobody is
using yet.

The cost: **restores are slower, and the prepare is a step that can fail.** On
the tar chain a broken prepare is discovered at backup time, while you still have
a healthy database. Here it is discovered during recovery. See
[§12](#test-the-prepare-before-you-need-it) for how to test for that in advance.

---

## 2. Where `--prepare` moved

`xtrabackup --backup` produces a datadir that is **crash-inconsistent**: a
physical copy taken while pages were being written, plus a redo log covering the
difference. `--prepare` replays that redo and makes it consistent.

> **Starting mysqld on an unprepared datadir does not fail with an error. It
> rewrites pages on top of an inconsistent redo state and corrupts the data.**

The tar chain prepared at backup time, so its guard was "refuse to restore
anything whose manifest does not say `prepared=yes`". Here that guard **inverts**,
and there are three of them in sequence:

| Where | Check | On failure |
| --- | --- | --- |
| `backup.sh` PART 9 | `backup_type` from `--extra-lsndir` must be `full-backuped` | refuse to publish |
| `restore.sh` pre-flight 7 | manifest `prepared` must **not** be `yes`; `archive_format` must be `xbstream` | refuse to start |
| `restore.sh` after prepare | `backup_type` read off the **restored datadir** must be `full-prepared` | leave MySQL stopped |

The last one is what actually protects the data: it reads the file on disk rather
than trusting anything the backup recorded. MySQL is only started after it
passes.

### Streaming has no target directory, so metadata comes from elsewhere

With `--stream=xbstream` nothing lands on a filesystem — the datadir goes to
stdout. `xtrabackup_checkpoints`, `xtrabackup_info` and the binlog position are
therefore not available as files in a backup directory. Two mechanisms replace
them:

- **`--extra-lsndir=/Data/xb-tmp/<id>`** — the one place xtrabackup still writes
  `xtrabackup_checkpoints` and `xtrabackup_info` to disk. `backup.sh` treats this
  as required output, not scratch: a run that produces no metadata there is
  refused, because the manifest could not be written and `restore.sh` would have
  nothing to pre-check.
- **The binlog position** is parsed from the log line
  `MySQL binlog position: filename 'binlog.000018', position '157'`, with the
  `binlog_pos` line of `xtrabackup_info` as the fallback. It is written to
  `<id>_binlog_info` in the same `<file>\t<position>` format the tar chain's
  `xtrabackup_binlog_info` had — which is why `binlog_collect.sh` anchors on it
  unchanged.

Both parsed values are validated before publication: the filename must match
`<prefix>.NNNNNN` and the position must be all digits. A backup taken with
binary logging off publishes the placeholder `unknown 0` and warns that PITR is
not possible.

---

## 3. Published layout

```
<SECONDARY_STORAGE_DIR>/
├── 20260820.xbstream       ← the archive: zstd-compressed, UNPREPARED
├── 20260820.sha256         ← checksum, ABSOLUTE path to the archive
├── 20260820.manifest       ← sidecar read before extraction
├── 20260820_binlog_info    ← PITR anchor: <binlog file> <position>
├── 20260821.xbstream
│   …
├── meta/
│   └── 20260820/           ← the --extra-lsndir output, as published
│       ├── xtrabackup_checkpoints
│       └── xtrabackup_info
├── binlog/
│   └── 20260820/           ← binlogs belonging to that backup
│       ├── binlog.000018
│       ├── binlog.000019
│       ├── binlog.sha256          ← append-only, bare filenames
│       └── last_copied_binlog     ← resume state
└── logs/
    └── 20260820/
        ├── backup.log
        ├── xtrabackup.log
        ├── errors.log
        ├── collect/                     ← every collection run, appended
        └── restore_20260822_091500/     ← one folder per restore attempt
```

Two additions over the tar layout:

- **`meta/<id>/`** holds the `--extra-lsndir` files. On the tar chain this
  metadata lived inside the tarball; here the archive is a compressed stream, so
  the LSN range and source topology would be unreadable without a full restore.
  It is a few hundred bytes.
- **`logs/<id>/restore_<timestamp>/`** is per-attempt rather than a single
  `restore/`. A recovery is often more than one attempt, and each attempt's
  prepare log is exactly what you need to compare.

### Naming: bare date, timestamped only on a rerun

```
20260820.xbstream            first (or only) run that day
20260820_175047.xbstream     a second run on the same day
```

The daily cron run gets a clean, predictable ID. A time is appended **only** when
that day's archive already exists:

```bash
NAME="$(date +%Y%m%d)"
if [[ -e "${SECONDARY_STORAGE_DIR}/${NAME}.xbstream" ]]; then
  NAME="${NAME}_$(date +%H%M%S)"
fi
```

The **share** is the authoritative test, not local staging: staging is emptied
after every run, so only a published archive proves the day is taken. The header
says which happened:

```
 backup id       : 20260820_175047  (same-day rerun — a bare-date archive already exists)
```

Pre-flight check 15 is the second-level guard. Since PART 5 already appends a
time when the day is taken, a collision there means either two runs starting in
the same second, or that **the share was unreachable when the name was chosen**
and the day is in fact taken — worth distinguishing, so the check says both.

`restore.sh` accepts either form; its `backup_id` pattern is
`^[0-9]{8}(_[0-9]{6})?$`.

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
> agree.

### The manifest

```
backup_id=20260820
created_at=2026-08-20 15:32:46
archive_path=/livestorage/YK/Restore-VM/20260820.xbstream
archive_sha256=<sha>
archive_format=xbstream          ← restore.sh refuses a non-xbstream archive
archive_bytes=148615495680
compression=zstd
compress_zstd_level=1
prepared=no                      ← EXPECTED here; yes would be refused
backup_type=full-backuped
from_lsn=0
to_lsn=21474836480
datadir_bytes=443012234752       ← restore.sh sizes its space check off this
mysql_version=8.0.35
xtrabackup_version=xtrabackup version 8.0.35-30 based on …
binlog_format=ROW
gtid_mode=OFF
binlog_file=binlog.000018
binlog_pos=157
recovery_method=file_position
datadir=/Data/mysql
```

`datadir_bytes` is the measured size of the source datadir. It is the difference
between the restore knowing how much space it needs and guessing a multiple of
the compressed archive — see [§10](#10-disk-space).

---

## 4. Log structure

`backup.sh` and `binlog_collect.sh` share one log engine (PART 2 of each). Every
line has the same shape:

```
HH:MM:SS LEVEL [phase     nn/nn] message
```

- **`HH:MM:SS`** — wall clock. Time-of-day only; the date is in the run header
  and in the folder name, so it is not repeated on every line.
- **`LEVEL`** — `INFO`, `WARN`, `ERROR`, padded to 5 so the tag column aligns.
- **`[phase nn/nn]`** — the phase name padded to 9, the step right-aligned in 5.
  Fixed width, so the message column lines up down the whole file.
- **`message`** — either free text, or a dotted-leader result.

### A real run

```
==============================================================
 BACKUP RUN 20260820
==============================================================
 started         : 2026-08-20 14:30:05 IST
 host            : Live-DB-Server-4
 datadir         : /Data/mysql
 destination     : /livestorage/YK/Restore-VM
 staging         : /Data/dbvault-stage
 compression     : zstd level 1
 threads         : 8 read / 8 compress
 prepare         : NOT done here — restore.sh runs --prepare
--------------------------------------------------------------
14:30:05 INFO  [preflight 01/15] user privileges ....................... OK
14:30:05 INFO  [preflight 02/15] required binaries ..................... OK
14:30:05 INFO  [preflight 03/15] xtrabackup version ................ 8.0.35
14:30:05 INFO  [preflight 04/15] mysql running ......................... OK
14:30:05 INFO  [preflight 05/15] datadir readable ..................... OK
14:30:06 INFO  [preflight 06/15] mysql connection ..................... OK
14:30:06 INFO  [preflight 07/15] staging writable ..................... OK
14:30:06 INFO  [preflight 08/15] smb share ............................ OK
14:30:31 INFO  [preflight 09/15] disk space ... need 248GB / stage 501GB / share 900GB
                                 datadir 412.6GiB, estimate is 60% of it
14:30:31 INFO  [preflight 10/15] no concurrent backup ................. OK
14:30:31 WARN  [preflight 11/15] binary logging .................. DISABLED
                                 point-in-time recovery from this backup will NOT be possible
14:30:31 INFO  [preflight 12/15] metadata dir empty ................... OK
14:30:31 INFO  [preflight 13/15] thread settings ....... 8+8 on 16 cores
14:30:31 INFO  [preflight 14/15] sha256 utility ....................... OK
14:30:31 INFO  [preflight 15/15] archive name free .................... OK
14:30:31 INFO  [preflight -]     15 checks passed, 1 warning(s)   (26s)
--------------------------------------------------------------
14:30:31 INFO  [stream 1/5]      starting xtrabackup, progress in 20260820_xtrabackup.log
14:30:31 INFO  [stream 1/5]      lock held for binlog_collect.sh: /var/lock/dbvault/dbvault-stage_20260820_lock (pid 21877)
14:53:56 INFO  [stream 1/5]      done  138.4GiB  (23m25s)
14:53:56 INFO  [verify 2/5]      completed OK! x1 ...................... OK
14:53:56 INFO  [verify 2/5]      stream non-empty ..................... OK
14:53:56 INFO  [verify 2/5]      extra-lsndir metadata ................ OK
14:53:56 INFO  [verify 2/5]      backup_type ... full-backuped (unprepared, expected)
14:53:56 INFO  [verify 2/5]      lsn range ........ 0 -> 21474836480
14:53:56 INFO  [binlog 3/5]      binlog position ........ binlog.000018:157
                                 source: xtrabackup log
14:55:24 INFO  [sha256 4/5]      sha256 ... a3f9c1e04b7d…
14:55:24 INFO  [sha256 4/5]      verified locally  138.4GiB = 33.5% of datadir  (1m28s)
15:32:44 INFO  [publish 5/5]     copying 138.4GiB to the share
15:32:44 INFO  [publish 5/5]     archive verified on share ............ OK
15:32:44 INFO  [publish 5/5]     transferred in 37m20s
15:32:45 INFO  [publish 5/5]     checksum published ................... OK
15:32:45 INFO  [publish 5/5]     binlog anchor published .............. OK
15:32:45 INFO  [publish 5/5]     metadata published ................... OK
15:32:46 INFO  [publish 5/5]     manifest published ................... OK
15:32:46 INFO  [publish 5/5]     final integrity check ................ OK

==============================================================
 BACKUP OK  20260820
==============================================================
 duration        : 62m41s
 datadir size    : 412.6GiB
 archive size    : 138.4GiB  (33.5% of datadir)
 archive         : /livestorage/YK/Restore-VM/20260820.xbstream
 sha256          : a3f9c1e04b7d…
 binlog position : binlog.000018:157
 backup_type     : full-backuped  (NOT prepared — restore.sh prepares)
 lsn range       : 0 -> 21474836480
 manifest        : /livestorage/YK/Restore-VM/20260820.manifest
 metadata        : /livestorage/YK/Restore-VM/meta/20260820
 warnings        : 1
--------------------------------------------------------------
 restore with    : ./restore.sh 20260820 --dry-run
                   ./restore.sh 20260820
--------------------------------------------------------------
 logs            : /livestorage/YK/Restore-VM/logs/20260820/
--------------------------------------------------------------
15:32:47 INFO  [collect -]       inline collection .................... OK
==============================================================
 RESULT ok id=20260820 dur_s=3761 bytes=148615495680 warn=1
==============================================================
```

### The four line kinds

| Kind | Produced by | Looks like |
| --- | --- | --- |
| Banner | `banner` | `====` rule, title, `====` rule |
| Header / summary field | `kv` | ` datadir         : /Data/mysql` |
| Timestamped entry | `info` `warn` `erro` | `14:30:05 INFO  [preflight 04/15] mysql running … OK` |
| Continuation | `cont` `cerr` | indented to the message column, no timestamp |

Results use a dotted leader so the outcome sits in one column regardless of label
length:

```
ok  "mysql running"                 →  mysql running ......................... OK
val "xtrabackup version" "8.0.35"   →  xtrabackup version ................ 8.0.35
nok "binary logging" "DISABLED"     →  binary logging .................. DISABLED
```

`leader()` targets width 40 and collapses to a minimum of three dots when the
label plus value is longer, so a long value degrades gracefully instead of
wrapping.

### Phases

`backup.sh`: `preflight` → `stream` → `verify` → `binlog` → `sha256` →
`publish` → `collect` → `done`

`binlog_collect.sh`: `preflight` → `start` → `flush` → `copy` → `verify` →
`done`

`phase <name> [step]` sets both globals and resets the phase timer, so every
`(23m25s)` in the log is that phase's own elapsed time, not the run's.

### Step numbers cannot drift

The pre-flight counter is derived, not written by hand:

```bash
CHECK_N=0
CHECK_TOTAL=15
check() { PHASE="preflight"; CHECK_N=$((CHECK_N + 1))
          STEP="$(printf '%02d/%02d' "$CHECK_N" "$CHECK_TOTAL")"; }
```

Each check starts with a bare `check`. Inserting or removing one renumbers the
rest automatically — the old `log_msg "Check 7/14: ..."` strings had to be
renumbered by hand and drifted the moment anyone added a check. Only
`CHECK_TOTAL` needs updating, and a mismatch is visible immediately because the
last check does not read `15/15`.

### The RESULT line

Every run ends with exactly one greppable line:

```
 RESULT ok     id=20260820 dur_s=3761 bytes=148615495680 warn=1
 RESULT failed id=20260820 phase=stream step=1/5 dur_s=1405 warn=0
```

```bash
grep '^ RESULT' /livestorage/YK/Restore-VM/logs/*/backup.log
```

`binlog_collect.sh` emits the same shape with its own fields:

```
 RESULT ok     anchor=20260820 copied=3 archived=57 dur_s=12 warn=0
 RESULT failed anchor=20260820 copied=1 errors=2 gaps=1 dur_s=9
```

### Where the log goes

| File | Content |
| --- | --- |
| `backup.log` | everything above |
| `xtrabackup.log` | xtrabackup's own stderr, untouched |
| `errors.log` | only `ERROR` lines, plus the full xtrabackup log on a stream failure |

All three are written to **local staging** during the run and moved to
`SECONDARY/logs/<id>/` at the end, on success and on failure. A log living on the
share is useless when that mount is the thing failing.

`emit()` writes with `printf` to stdout and appends to the run log directly.
The tar chain piped every line through `tee`, forking a process per line; a
backup run logs several hundred lines.

### Where each script's logs live, and what stays on the VM

| Script | During the run | At the end |
| --- | --- | --- |
| `backup.sh` | `/Data/dbvault-stage/<id>_*.log` | **moved** to `logs/<id>/` — nothing kept locally |
| `restore.sh` | `/Data/dbvault-stage/<id>_restore_<attempt>*.log` | **moved** to `logs/<id>/restore_<attempt>/` — nothing kept locally |
| `binlog_collect.sh` | written straight to `logs/<anchor>/collect/` on the share | already there; appended across runs |

`backup.sh` and `restore.sh` share one publishing contract — **move semantics
behind a mount check**:

1. `mountpoint -q "$SMB_MOUNT_POINT"`, or stop and say where the logs stayed.
2. `cp` to the share.
3. Confirm the destination is non-empty.
4. Only then delete the local file.

A local copy therefore survives in exactly one situation — the share was
unreachable at the end of the run — and the script says so rather than exiting
quietly:

```
 [WARN] share not mounted — logs kept in /Data/dbvault-stage:
        /Data/dbvault-stage/20260820_backup.log
```

`binlog_collect.sh` needs none of this: its run log **is** on the share, and it
cannot even start without passing the hard mount check in its PART 5.

> **Two defects lived here, both found on a live host.**
>
> `restore.sh` published with `cp`, leaving a full second copy of every attempt's
> logs on the VM forever — including `xtrabackup.log`, which is **30MB+** per
> attempt because `--decompress` and `--prepare` both write to it.
>
> `backup.sh` had no mount check in `publish_logs` at all. On an unmounted share,
> `mkdir -p /livestorage/YK/Restore-VM/logs/<id>` **succeeds** — it creates a
> plain local directory under the mount point — so the logs were moved onto the
> **root filesystem**, invisible, and the staging copies deleted. Exactly the
> failure mode the rest of the script guards against everywhere else.
>
> Note also that before `die()`/`fail_run()`, a **failed** run never published at
> all, because `exit 1` does not fire the `ERR` trap
> ([§6](#6-failure-handling)) — so for any failed attempt from that version the
> logs exist *only* on the VM. Worth collecting before they are pruned.

### A successful run leaves nothing on the VM

`LOCAL_STAGE` is scratch, not storage. After a successful `restore.sh` it is
**empty**:

| Artifact | Fate |
| --- | --- |
| `restore.log`, `restore_errors.log`, `xtrabackup.log` | moved to `logs/<id>/restore_<attempt>/` |
| `binlog_preview.sql` (dry run) | moved to the same folder |
| staged binlog copies under `binlog_<id>/` | deleted on both the success and failure paths |

The dry-run preview is published rather than kept locally: it can be large,
it is still readable on the share, and the share is the permanent home for
everything else about the run. The dry-run summary reports its size and says
where it goes:

```
 preview         : 902B — published below as binlog_preview.sql
```

### Retention is a safety net, not a policy

Because nothing is intentionally kept, `prune_local` exists purely to clear what
an **earlier** run left behind when the share was unreachable. Both `backup.sh`
and `restore.sh` run it just after their run header, over their own artifacts in
`/Data/dbvault-stage`, older than `KEEP_LOCAL_DAYS` (default **14**):

| Script | Patterns pruned |
| --- | --- |
| `backup.sh` | `*_backup.log`, `*_errors.log`, `*_xtrabackup.log` |
| `restore.sh` | `*_restore_*.log`, `*_binlog_preview.sql` |

It reports what it removed:

```
13:05:09 INFO  [preflight -]     pruned 3 local log/preview file(s) older than 14 days
```

`-mtime` is in whole days, so the current run's own files can never match.

---

## 5. Script structure: the PART layout

Each script opens with an index and is divided into numbered `PART` regions in
execution order:

```
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   identity and paths
#   PART 6   bootstrap
#   PART 7   pre-flight            15 checks
#   PART 8   stream                step 1/5
...
```

Parts 1–4 are definitions only — nothing executes. Parts 5 onward run top to
bottom with no jumps back, so reading the file in order is reading the run in
order. The phase names in the log match the PART names, so a log line points at
a region of the file:

```
14:53:56 INFO  [verify 2/5]      backup_type ...     →  PART 9  VERIFY
```

Comments in the scripts are deliberately minimal. A comment survives only where
the code would otherwise look wrong or accidental — for example `derived, not a
second du`, or `exactly one: there is no --prepare appending to this log`. The
reasoning lives here instead.

### Small helpers, used everywhere

| Helper | Purpose |
| --- | --- |
| `free_gb <path>` | free space in GB |
| `mysql_q <sql>` | one query, batch mode, silent |
| `writable <dir>` | actually writes a probe file — `[[ -w ]]` lies on CIFS |
| `mysql_up` | systemd unit or `pgrep mysqld` |
| `smb_ready` | `mountpoint -q` **plus** a write probe |
| `binlog_field <key> <line>` | pulls `filename '…'` / `position '…'` out of a log line |
| `is_binlog <name>` | matches `<prefix>.NNNNNN` only |
| `seq_of <name>` | binlog sequence as a decimal integer |
| `hsize <bytes>` | `138.4GiB` |
| `elapsed <epoch>` | `45s` or `23m25s` |

Two of these encode CIFS lessons:

- **`writable`** writes and removes a probe file. `[[ -w ]]` consults permission
  bits, which a mounted-but-dead CIFS share still reports happily.
- **`smb_ready`** checks `mountpoint -q` *and* writes. A dropped CIFS mount
  reverts to a plain empty local directory that passes every `[[ -d ]]` test —
  writing there fills the root filesystem instead of the NAS. It is called in
  pre-flight and **again** before the transfer, because the share can drop during
  a backup that runs for an hour.

- **`seq_of`** strips leading zeros before arithmetic. Bash reads `000042` as
  octal, and `000008` is an invalid octal literal that aborts the script outright.

---

## 6. Failure handling

### `exit 1` does not fire an `ERR` trap

This is worth stating plainly because the tar chain gets it wrong:

```bash
set -euo pipefail
trap cleanup ERR
log_error "compression failed"
exit 1                 # ← cleanup does NOT run
```

The `ERR` trap fires when a *command* returns non-zero. `exit` is not such a
command. In `server/physical/backup.sh` every post-pre-flight failure is written
as `log_error …; exit 1`, so on those paths `cleanup_on_error` never runs and the
lock file, the partial archive and any half-written sidecars are all left behind
— with the lock in place, `binlog_collect.sh` then skips every run for up to
`LOCK_STALE_SECONDS` (6 hours).

These scripts route every failure through one function instead:

```bash
die() {                       # die <message> [detail...]
  erro "$1"; shift
  local l; for l in "$@"; do cerr "$l"; done
  fail_run
}

fail_run() {                  # also the ERR/INT/TERM trap
  trap - ERR INT TERM         # no re-entry
  ...cleanup...
  exit 1
}
```

`fail_run` is both the trap handler and the explicit exit path, so an unexpected
non-zero command and a deliberate `die` produce identical cleanup and identical
output. It disarms the trap first so a failure inside the cleanup cannot
re-enter it.

### What a failure looks like

```
14:34:12 ERROR [stream 1/5]      xtrabackup --backup exited 1 after 3m41s
                                 last 40 lines of /Data/dbvault-stage/…_xtrabackup.log:
                                   [ERROR] InnoDB: Operating system error 28

==============================================================
 BACKUP FAILED  20260820
==============================================================
 failed in       : stream 1/5
 duration        : 3m47s
--------------------------------------------------------------
14:34:12 INFO  [cleanup -]       removing /var/lock/dbvault/dbvault-stage_20260820_lock
14:34:12 INFO  [cleanup -]       removing /Data/dbvault-stage/20260820.xbstream
14:34:13 INFO  [cleanup -]       removing /Data/xb-tmp/20260820
--------------------------------------------------------------
 error log       : /Data/dbvault-stage/20260820_errors.log
 xtrabackup log  : /Data/dbvault-stage/20260820_xtrabackup.log
==============================================================
 RESULT failed id=20260820 phase=stream step=1/5 dur_s=227 warn=0
==============================================================
 logs published to /livestorage/YK/Restore-VM/logs/20260820
```

`PHASE` and `STEP` are globals, so **`failed in` is reported without any call
site having to pass it along.** That is the whole reason they are globals rather
than parameters.

### What cleanup will and will not delete

`fail_run` removes the lock file, the local stream, a `.part` transfer, the
sidecars, and the metadata scratch — but:

```bash
if [[ "$TRANSFER_OK" == "yes" ]]; then
  warn "archive already verified on the share — KEEPING ${SECONDARY_FILE:-?}"
```

Once the archive is copied to the share **and its checksum verified there**,
`TRANSFER_OK=yes` and no failure afterwards deletes it. A later step failing
(manifest write, final re-read) does not justify discarding a good archive.

Everything is removed through `drop()`, which no-ops on an unset or missing path.
That is why `fail_run` is safe to call from pre-flight, when almost nothing
exists yet, and why there is only one failure path instead of one per phase.

### The collector's failure rules

`binlog_collect.sh` differs in two ways:

- **A per-file problem warns and continues; it does not abort.** A single corrupt
  binlog increments `ERRORS` and the loop moves on, so one bad file does not stop
  the other 50 from being archived.
- **Any error still exits non-zero.** A monitored job that cannot fail is worse
  than no monitoring. Validated binlogs stay archived and the state file still
  points at the last good one, so the next run resumes correctly — this is a
  partial-success exit, not a rollback.

The state file is the one thing cleanup is careful with:

```bash
if [[ "$STATE_PRE_EXISTED" == false && -f "$STATE_FILE" ]]; then
```

`STATE_PRE_EXISTED` is read before anything can create the file. Deleting a
pre-existing state file would reset the resume point and re-collect everything
from the anchor.

---

## 7. `backup.sh` walkthrough

### PART 6 — bootstrap

Config sanity, then local directories, then the error log, then the run header.
Two refusals happen here, before anything else:

- `SECONDARY_STORAGE_DIR` empty — the backup has nowhere to go.
- `SECONDARY_STORAGE_DIR` inside `BACKUP_BASE` — "publish, then empty scratch"
  would delete the only copy.

The share directory is deliberately **not** created here. The tar chain created
it up front and therefore needed a duplicate mount check before the numbered
pre-flight. Here nothing touches the share until check 8, which does the mount
test, the `mkdir -p` and the write probe in that order — one check instead of
two, same guarantee.

### PART 7 — pre-flight, 15 checks

| # | Check | Fails or warns |
| --- | --- | --- |
| 1 | user privileges | **warns** if not root |
| 2 | required binaries | fails |
| 3 | xtrabackup version | fails below 8.0.30; **warns** if unparseable |
| 4 | mysql running | fails |
| 5 | datadir readable | fails |
| 6 | mysql connection | fails |
| 7 | staging writable | fails — checks `BACKUP_BASE` and the `--extra-lsndir` |
| 8 | smb share | fails — mountpoint, mkdir, write probe |
| 9 | disk space | fails — `STREAM_SPACE_PCT`% of the datadir, on staging **and** the share |
| 10 | no concurrent backup | fails |
| 11 | binary logging | **warns** — a backup without PITR is still a backup |
| 12 | metadata dir empty | fails — stale `--extra-lsndir` content would read as this run's |
| 13 | thread settings | fails on a non-integer; **warns** on oversubscription |
| 14 | sha256 utility | fails |
| 15 | archive name free | fails — second-level guard; PART 5 already appends a time when the day is taken |

Compared with the tar chain: `tar` and `gzip` are gone from check 2 and the
tar/gzip round-trip test is gone entirely, since nothing compresses with them.
Checks 3, 12, 13 and 15 are new.

**Check 3** deserves a note, because it is the one that has actually bitten.
`--compress-zstd-level` requires XtraBackup 8.0.30. Detecting that up front is
better than a mid-run unknown-option error, but the detection itself must never
be able to fail a healthy backup:

```bash
set +e
XB_RAW="$("$XTRABACKUP_BIN" --version 2>&1)"
set -e
XB_BANNER="$(grep -m1 'xtrabackup version' <<< "$XB_RAW" || true)"
[[ -n "$XB_BANNER" ]] || XB_BANNER="$(head -1 <<< "$XB_RAW")"

if [[ "$XB_BANNER" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
```

Three things are deliberate:

- **No pipe on `--version`.** `xtrabackup --version | head -1` races with
  SIGPIPE; under `pipefail` a 141 fails the assignment and trips the trap.
- **The banner is found by content.** On 8.0.30+ builds the *first* line of
  `--version` output is a timestamped `[Note] … recognized server arguments` log
  line, not the version banner. `head -1` captures the wrong line.
- **`BASH_REMATCH`, not `grep -oE | head -1`.** `grep` exits 1 when it finds no
  match; under `pipefail` that failed the assignment and aborted the run with a
  bare `Backup failed` and no explanation. The regex match takes the leftmost
  triple with no subprocess, so an unparseable banner can only warn.

**Check 9** derives the datadir size once:

```bash
DATADIR_BYTES=$(du -sb "$MYSQL_DATADIR" | awk '{print $1}')
DATADIR_GB=$(( DATADIR_BYTES / 1073741824 + 1 ))     # derived, not a second du
```

The tar chain called `du -sb` on the datadir and then immediately called a helper
that ran `du -sb` on it again. On a 400GB+ datadir that is a full second metadata
walk for a number already in hand.

### PART 8 — stream, 1/5

The lock file is written, then the tested command runs unchanged:

```bash
"$XTRABACKUP_BIN" --backup --user=… --password=… --datadir=… \
  --stream=xbstream --compress --compress-zstd-level="$ZSTD_LEVEL" \
  --parallel="$PARALLEL_THREADS" --compress-threads="$COMPRESS_THREADS" \
  --extra-lsndir="$LSN_DIR" --tmpdir="$XB_TMPDIR" \
  > "$STREAM_FILE" 2> "$XTRABACKUP_LOG"
XB_STATUS=$?
```

stdout is the archive, stderr is the log, **nothing is piped** — a pipe would
hide xtrabackup's exit code behind `tee`'s. On failure the last 40 lines of the
xtrabackup log are echoed into the run log as continuation lines and the whole
file is appended to `errors.log`, so the cause is in the published logs without
needing the scratch directory.

### PART 9 — verify, 2/5

```bash
COMPLETED_OK=$(grep -c 'completed OK!' "$XTRABACKUP_LOG" || true)
[[ "${COMPLETED_OK:-0}" -eq 1 ]]
```

**Exactly one**, where the tar chain wanted at least two. There is no `--prepare`
phase appending to this log. Zero means the backup did not finish; more than one
means the log was reused across runs, and nothing else read from it can be
trusted either. `|| true` because `grep -c` exits 1 on zero matches.

Then: stream non-empty, both `--extra-lsndir` files present and non-empty, and
`backup_type == full-backuped`. That last one is the correct state here and the
whole reason `restore.sh` must prepare.

### PART 10 — binlog position, 3/5

The log line first, `xtrabackup_info` as the fallback, both parsed with
`binlog_field`. Validated, then written in the tar chain's two-field format so
the collector needs no changes. If nothing is found the run **warns and
continues**, publishing `unknown 0` — a full backup without PITR is still worth
having, and the warning plus the manifest's `binlog_file=unknown` make the
limitation visible at restore time.

### PART 11 — checksum, 4/5

Generated and verified **locally**, before the transfer. This catches a stream
corrupted on the way to local disk, separately from the post-transfer check.

### PART 12 — publish, 5/5

Order matters throughout:

1. `smb_ready` re-asserted — pre-flight may have passed an hour ago.
2. Archive copied to `<name>.xbstream.part`, so an interrupted copy never matches
   a `*.xbstream` glob.
3. `sync`, then SHA-256 the `.part` **at the destination**. Without the flush the
   checksum can be served from page cache and prove nothing.
4. `mv` into place, `TRANSFER_OK=yes`.
5. Local copy removed.
6. Checksum file written **directly at its published path**, containing the
   archive's absolute path, so `sha256sum -c` resolves from any working directory.
   The tar chain assigned this through two intermediate variables; here the
   destination path is assigned once.
7. Binlog anchor, `meta/`, then the manifest as `.part` + `mv`.
8. Every published artifact re-checked for readability, then a **final
   `sha256sum -c` that re-reads the whole archive off the share**.

Step 8 is not redundant with step 3: step 3 verifies what was just written, step 8
verifies what a restore will actually read back later.

### PART 14 — inline collection

`binlog_collect.sh` runs once, inline, so PITR coverage starts immediately
instead of at the next cron fire. Strictly best-effort: the archive is already
complete and verified, so a binlog problem here warns and the run still exits 0.
Its output is appended to the same run log.

---

## 8. `binlog_collect.sh` walkthrough

Anchors on the newest `*_binlog_info` on the share and copies every **closed**
binlog from that position forward. The logic is the proven collector's; the
structure and logging are new.

### PART 5 — share reachability, before anything else

Deliberately ahead of the anchor lookup. On an unreachable mount that lookup
finds nothing and exits 0 — reporting a healthy run that collected nothing, which
is the worst possible outcome for a PITR chain. Mount, directory, and an actual
write probe, because `ls` can be served from the attribute cache.

### PART 6 — the lock interlock

```
/var/lock/dbvault/dbvault-stage_<YYYYMMDD>_lock
```

Written by `backup.sh` while it runs. If present and younger than
`LOCK_STALE_SECONDS` (6h), this run exits 0 immediately — the backup is holding
the binlogs it needs. Older than that, the backup probably crashed, so the run
**warns and proceeds** rather than blocking PITR indefinitely.

The lock is local by design. On a network mount a dropped mount would read as "no
backup running", and the interlock would fail exactly when it matters. `/var/lock`
is tmpfs, so a reboot clears a lock left by a hard kill.

`LOCK_DIR` and the `BACKUP_BASE` basename **must match** `backup.sh`.

### PART 7 — anchor discovery

The newest `*_binlog_info`, chosen by **filename**, never mtime: SMB mtime is the
server's clock and is attribute-cached, so a skew would silently pick an older
backup. Date and time sort as separate keys:

```
plain lexical sort:   20260820  <  20260820      ← rerun ignored
date + time keys:     20260820 000000  <  20260820 143005   ← correct
```

No anchor at all is a clean exit 0 — the backup has not completed yet, there is
genuinely nothing to collect.

### PART 10 — start point

The state file if we have collected before, otherwise the backup anchor. If the
start binlog is **gone from the server** (MySQL purged it), the run falls back to
the earliest available and logs the gap loudly:

```
14:45:02 WARN  [start -]         start binlog ................... PURGED
                                binlog.000018 is gone from /Data/mysql — MySQL purged it
                                falling back to the earliest available: binlog.000021
                                COVERAGE GAP between binlog.000018 and binlog.000021 — PITR in that range is LOST
                                prevent it: binlog_expire_logs_seconds >= 3x the backup duration
```

Partial coverage beats none, but the gap is real and permanent.

### PART 11 — flush and rotate

`FLUSH BINARY LOGS` closes the active binlog so it becomes copyable. The new
active one is then identified and **skipped** — it is still being written to.
`SHOW BINARY LOG STATUS` is 8.4+, with `SHOW MASTER STATUS` as the fallback.

### PART 12 — copy

Each file must survive four gates before the resume point advances:

| Gate | Catches |
| --- | --- |
| byte size match | a truncated copy |
| `mysqlbinlog` parse | a corrupt **source** — a truncated binlog copies perfectly and fails during recovery |
| `sha256sum >> binlog.sha256` | nothing yet; this records the checksum `restore.sh` verifies against later |
| `echo > last_copied_binlog` | — advances the resume point only after all of the above |

`cp` runs **without `-p`**: CIFS cannot preserve ownership, so `-p` returns
non-zero on copies whose data landed fine, and good binlogs would count as
errors. The size and parse checks are the real integrity guarantee.

Checksums are recorded with **bare filenames** so `restore.sh` can verify them
from its own local staging directory.

### PART 13 — continuity

A sequence gap does **not** error during replay. The database comes up looking
perfectly healthy while every transaction in the hole is silently missing.
Nothing downstream can detect it, so it is detected here, while the missing file
may still exist on the source server.

---

## 9. `restore.sh`

Same PART layout, same log engine and the same single `die()` → `fail_run()`
failure path as the other two.

```bash
./restore.sh <backup_id> [--dry-run] [--skip-binlog] [--binlog-only] [--from <binlog>]
```

| Phase | Steps | Destructive? |
| --- | --- | --- |
| 1 verify | SHA-256 the `.xbstream` on the share | no |
| 2 restore | stop mysqld → wipe datadir → `xbstream -x` → `--decompress` → `--prepare` → chown → start | **yes, from the wipe onward** |
| 3 apply | stage binlogs locally → verify checksums → gap check → replay from the anchor | yes |

| Flag | Effect |
| --- | --- |
| *(none)* | all three phases |
| `--dry-run` | verify the archive, decode the binlogs to a preview `.sql`, report destructive statements. Modifies nothing. Exits non-zero only on a checksum mismatch |
| `--skip-binlog` | phases 1–2 only |
| `--binlog-only` | phase 3 only; requires a marker from a previous run |
| `--from <binlog>` | start the apply at that binlog instead of the anchor |

Extract, decompress and prepare happen **in place in the datadir** — no staging
copy, no `--copy-back`, so ~1x the data size rather than 2x. `--decompress` runs
with `--remove-original`, and any leftover `.zst`/`.qp`/`.lz4` afterwards aborts
the restore: `--prepare` skips such a file silently and it becomes an unreadable
tablespace at runtime.

### PART layout

```
PART 1   configuration          PART 8   pre-flight       14 checks
PART 2   log engine             PART 9   start point
PART 3   failure handling       PART 10  dry run          exits
PART 4   probes                 PART 11  verify           phase 1/3
PART 5   usage and arguments    PART 12  restore          phase 2/3
PART 6   single-instance lock   PART 13  binlog apply     phase 3/3
PART 7   identity and paths     PART 14  summary
```

### Which phases run

The flags are reduced to two booleans immediately after parsing, and every check
and phase tests those rather than the raw flags:

```bash
DO_RESTORE=1; DO_APPLY=1
[[ $BINLOG_ONLY -eq 1 ]] && DO_RESTORE=0
[[ $SKIP_BINLOG -eq 1 ]] && DO_APPLY=0
```

A check that does not apply reports itself rather than vanishing, so the count
always reads `14/14` and the log shows *why* something was not verified:

```
16:04:12 INFO  [preflight 03/14] wipe switch .......... n/a (--binlog-only)
16:04:12 INFO  [preflight 05/14] archive present ...... n/a (--binlog-only)
16:04:12 INFO  [preflight 12/14] collected binlogs .... 57 files
                                 anchor binlog.000018:157 (from manifest)
```

`--skip-binlog` with `--binlog-only`, and `--from` with `--skip-binlog`, are
rejected during argument parsing.

### The start point is resolved once

PART 9 resolves `START_BINLOG` / `START_POS` **before** the dry-run branch, so a
dry run and the real apply can never disagree about what would be replayed:

| Case | Start |
| --- | --- |
| no `--from` | anchor file at the anchor position — no gap, no duplicate |
| `--from`, different file | that file at position 4 (whole file) |
| `--from`, **same** file as the anchor | that file at the **anchor** position, not 4 — otherwise the transactions already inside the full backup replay a second time |

The third case logs a `WARN` naming itself an edge case, because silently using
`157` where the operator typed a file expecting `4` is worth saying out loud.

### Failure advice is selected by state, not by call site

`fail_run` picks its guidance from two flags, so no `die()` call has to describe
the situation:

| State | Message |
| --- | --- |
| `APPLY_STARTED=true` | **partially applied** — do not let applications connect; the apply cannot be resumed; roll back with a full re-run |
| `DATADIR_WIPED=true` | datadir empty or partial, mysqld deliberately left stopped, re-run to start over from a clean wipe |
| MySQL was running, now stopped, datadir untouched | safe to `systemctl start` again |
| otherwise | nothing was modified, retry |

`DATADIR_WIPED` is set immediately before the delete and cleared once MySQL is up
and serving. `APPLY_STARTED` brackets the replay loop. Between them they cover
every point the run can die at, which the previous version could only approximate
with a single generic message.

### The double-apply guard

GTID is off, so the apply is one-shot: re-applying binlogs over a database that
already contains them corrupts it. `binlogs_applied=yes` in
`/var/lib/dbvault/<id>_restore_state` prevents that.

It is a **hard refusal for `--binlog-only`, and irrelevant for a full run** — a
full run wipes and re-restores first, so the binlogs always land on a fresh
baseline. That is why re-running the full command is the correct rollback after a
failed or unwanted apply, and why the marker simply resets.

---

## 10. Disk space

### Backup host

| What | Needs | Config |
| --- | --- | --- |
| `BACKUP_BASE` | the compressed stream, ~25–40% of the datadir for zstd-1 on InnoDB | `STREAM_SPACE_PCT=60` |
| `XB_TMPDIR` | `--tmpdir` plus a few metadata files | negligible |
| the share | same as `BACKUP_BASE`, per retained backup | same figure |

Raise `STREAM_SPACE_PCT` if the data compresses poorly; the failure mode
otherwise is ENOSPC partway through the run.

### Restore host

Sized off `datadir_bytes` from the manifest times `DATADIR_SPACE_PCT` (120%),
which covers the decompressed pages plus the redo the prepare writes. Without
`datadir_bytes` the fallback is the compressed archive times
`ARCHIVE_EXPANSION_FACTOR` (5), deliberately conservative.

The check counts the datadir's **current** contents as available, since they are
about to be deleted. Without that, restoring onto a nearly-full datadir would
fail a check it actually passes.

---

## 11. Configuration reference

### Must match across scripts

| Setting | Why |
| --- | --- |
| `SECONDARY_STORAGE_DIR` | the collector and the restore find nothing if it differs |
| `SMB_MOUNT_POINT` | `mountpoint -q` only returns true for the exact mount point |
| `LOCK_DIR` + `BACKUP_BASE` basename | `backup.sh` writes the lock, `binlog_collect.sh` polls it |
| `BACKUP_BASE` / `LOCAL_STAGE` | the same local staging path under two names |
| `BINLOG_PREFIX` / `BINLOG_BASE` | must match MySQL's `log_bin` basename |
| `STATE_DIR` | the restore marker; `restore.sh` writes and reads it |

> The two chains share the anchor filename, the lock name and the `binlog/`
> layout, so **do not point both at the same `SECONDARY_STORAGE_DIR`.** The
> collector would anchor on whichever backup ran last and mix both chains' PITR
> state in one tree. One share directory per chain.

### Stream-specific

| Setting | Default | Notes |
| --- | --- | --- |
| `ZSTD_LEVEL` | `1` | the network copy, not the CPU, is the bottleneck |
| `PARALLEL_THREADS` | `8` | read threads on backup, decompress threads on restore |
| `COMPRESS_THREADS` | `8` | backup only |
| `STREAM_SPACE_PCT` | `60` | staging requirement, % of datadir |
| `XB_TMPDIR` | `/Data/xb-tmp` | `--tmpdir` and the parent of `--extra-lsndir` |
| `LOCK_STALE_SECONDS` | `21600` | 6h; past this the collector assumes backup.sh crashed |
| `DATADIR_SPACE_PCT` | `120` | restore requirement, % of source datadir |
| `ARCHIVE_EXPANSION_FACTOR` | `5` | fallback when the manifest has no `datadir_bytes` |
| `PREPARE_USE_MEMORY` | `1G` | xtrabackup's default is 100MB, which makes the redo apply crawl |
| `CONFIRM_WIPE` | `1` | set to `0` to disable restores on this host entirely |

`PARALLEL_THREADS=8` and `COMPRESS_THREADS=8` assume a host with cores to spare.
Lower them on a busy user-facing primary; check 13 warns if their sum exceeds
twice the core count.

---

## 12. Operating and troubleshooting

### Deployment

```bash
install -m 700 backup.sh binlog_collect.sh restore.sh /Data/script/
mkdir -p /Data/dbvault-stage /Data/xb-tmp
```

`backup.sh` runs `binlog_collect.sh` inline via `BINLOG_SCRIPT`, so that path
must point at the deployed copy. Crontab:

```cron
15 1 * * *   /Data/script/backup.sh
*/15 * * * * /Data/script/binlog_collect.sh
```

Mode 700 because the scripts hold credentials. They must be **LF, not CRLF** — a
`#!/usr/bin/env bash\r` shebang fails with a confusing "no such file or
directory".

### Reading a log

```bash
# outcome of every backup, one line each
grep '^ RESULT' /livestorage/YK/Restore-VM/logs/*/backup.log

# what went wrong, and in which phase
grep -E '^[0-9:]+ (WARN|ERROR)' logs/20260820/backup.log

# how long each phase took
grep -oE '\[[a-z]+ +[0-9/]+\].*\([0-9]+m?[0-9]*s\)' logs/20260820/backup.log

# the collector, newest run last (the file is appended to every 15 min)
tail -40 logs/20260820/collect/collect.log
```

### Verify a backup without restoring

```bash
./restore.sh <id> --dry-run
```

Reads the whole archive off the share, confirms the SHA-256, and decodes the
binlogs that would be replayed. Nothing is modified.

### Test the prepare before you need it

The one thing this chain asks that the tar chain did not. Because the prepare
happens at restore time, a problem with it surfaces during recovery. On a spare
host, once per MySQL or XtraBackup upgrade:

```bash
./restore.sh <id> --skip-binlog
```

If MySQL comes up and the row counts look right, the prepare path is sound.

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
| --- | --- |
| `xtrabackup version … 8.0.29` then refusal | below 8.0.30, no `--compress-zstd-level`. Upgrade, or use the tar chain |
| `xtrabackup version … UNPARSED` (warning) | the `--version` banner format changed. Harmless; the stream still runs |
| `completed OK! count … 0, want 1` | the backup did not finish; read the tail of `xtrabackup.log` |
| `completed OK! count … 2, want 1` | the log was reused across runs; nothing read from it is trustworthy |
| `extra-lsndir metadata … MISSING` | `XB_TMPDIR` not writable, or the run died before writing metadata |
| `binlog position … NOT FOUND` | binary logging is off on the source. No PITR from that backup |
| `metadata dir empty … NO` | stale `/Data/xb-tmp/<id>` from a killed run. Remove it |
| `archive name free … NO` | two runs started in the same second, or the share was unreachable when the name was chosen and that day is already taken |
| `disk space … INSUFFICIENT` | see [§10](#10-disk-space); raise `STREAM_SPACE_PCT` |
| `smb share … NOT WRITABLE` | stale handle or expired credentials. Remount |
| `start binlog … PURGED` | MySQL purged a binlog before collection. Raise `binlog_expire_logs_seconds` |
| `SEQUENCE GAP` | same cause; that PITR range is permanently lost |
| `Manifest says archive_format='tar.gz'` | a tar-chain archive. Use `server/physical/restore_full.sh` |
| `Manifest says prepared='yes'` | likewise — a prepared archive from the other chain |
| `Compressed files remain after --decompress` | this xtrabackup build lacks the compression used; compare the manifest's `compression=` |
| `THE DATADIR IS NOT PREPARED` | the prepare did not complete. **Do not start mysqld.** Read `xtrabackup.log`, re-run |
| `BINLOGS HAVE ALREADY BEEN APPLIED` | `--binlog-only` twice. Roll back with a full re-run |

### Not implemented

Retention and pruning, incremental backups, automated restore verification. Same
as the tar chain — archives accumulate until something else removes them.
