# Logical Backup and Restore (mysqldump)

Reference for the two standalone scripts in [server/logical/](../../../server/logical/):

| Script | Role |
|---|---|
| `logical.sh` | takes one `mysqldump` per database, compresses, checksums, writes a run manifest |
| `restore_logical.sh` | drops one database and imports it back from an archive |

They are the logical counterpart to the physical (XtraBackup) chain documented in
[instructions/README.md](../../README.md). Same conventions: no command-line
configuration, everything in `REGION 1`, non-zero exit on failure so cron cannot
report a broken run as green.

---

## Contents

| § | Section |
|---|---|
| 1 | [What logical backup can and cannot give you](#1-what-logical-backup-can-and-cannot-give-you) |
| 2 | [Published layout](#2-published-layout) |
| 3 | [Run IDs and same-day re-runs](#3-run-ids-and-same-day-re-runs) |
| 4 | [Backup lifecycle](#4-backup-lifecycle) |
| 5 | [Dump options](#5-dump-options) |
| 6 | [The manifest](#6-the-manifest) |
| 7 | [Restore lifecycle](#7-restore-lifecycle) |
| 8 | [Safety invariants](#8-safety-invariants) |
| 9 | [Configuration reference](#9-configuration-reference) |
| 10 | [Operating and troubleshooting](#10-operating-and-troubleshooting) |

---

## 1. What logical backup can and cannot give you

**Per-database restore.** Each database is dumped inside its own
`--single-transaction`, so any single database restores to a consistent point.
This is the whole reason the logical chain exists alongside the physical one:
XtraBackup restores the *instance*, this restores *one tenant*.

**No cross-database consistency.** `PARALLEL` databases are dumped at a time, each
at a different moment. Two databases from the same run do **not** share a point in
time. The manifest records this as `consistency=per_database_only` so nobody
assumes otherwise mid-incident.

**No point-in-time recovery.** `restore_logical.sh` never applies binlogs. The
database goes back to the moment its dump was taken and everything written since
is lost; the script prints the size of that window before and after so the loss is
stated, not discovered.

The dumps *do* carry a binlog coordinate (`--source-data=2` writes it as a comment
at the top of each `.sql`), so a PITR is possible by hand — that coordinate is
where it would start. Nothing in these scripts automates it.

> **Retention is not implemented here.** Nothing in `logical.sh` deletes anything.
> Archives and logs accumulate one set per run indefinitely. Run retention as a
> separate scheduled job.

---

## 2. Published layout

Everything lives under `BASE_DIR`:

```
<BASE_DIR>/
├── <db>/
│   ├── <db>_2026-08-10.tar.gz             ← the dump (one .sql inside)
│   ├── <db>_2026-08-10.tar.gz.sha256      ← checksum, BARE filename inside
│   └── PRE-RESTORE_<db>_<ts>.sql.gz       ← safety dump, written by a restore
├── manifests/
│   └── 2026-08-10.manifest                ← one per run
└── logs/
    ├── backup_20260810.log                ← one per day
    └── restore_<db>_<ts>.log              ← one per restore
```

The checksum file records the **bare filename**, not the absolute path
`sha256sum` emits by default, so `sha256sum -c` still works after the tree is
moved or mounted somewhere else. Run it from inside the database's folder.

---

## 3. Run IDs and same-day re-runs

The run ID is the date alone — `2026-08-10` — and every database in the run
shares it, so a run stays identifiable as one unit.

If a run finds any archive from today already present under `BASE_DIR`, the whole
run switches to a timestamped ID: `2026-08-10_14-30-11`.

**Why that check is not optional.** `tar -czf` overwrites its target silently. On
a plain date name, a manual backup taken before a risky change would destroy that
morning's scheduled one, leaving a single copy from the worse moment instead of
two.

The check runs **after** the lock is taken. Before it, two runs starting together
could both conclude they were the first.

Both naming forms coexist, and lexical sort orders them correctly: the plain date
sorts first (`.` is `0x2E`, `_` is `0x5F`), so the later re-run is chosen as
newest. `restore_logical.sh` forces `LC_ALL=C` for exactly this — locale collation
can ignore punctuation entirely and make the ordering unpredictable.

---

## 4. Backup lifecycle

### Pre-flight

Everything knowable up front is checked before any expensive work:

| Check | Failure mode it prevents |
|---|---|
| `mysqldump`, `mysql`, `tar`, `sha256sum` present | failing an hour in |
| MySQL reachable | every dump failing one by one |
| `--source-data` vs `--master-data` | unknown-option failure on every dump |
| `REPLICATION CLIENT` privilege | same, but only visible per database |
| Database list non-empty | a run that backs up nothing and reports success |
| Free space ≥ `SPACE_REQUIRED_PCT` of data size | truncated dumps |

**The privilege check.** `--source-data=2` requires `REPLICATION CLIENT` (or
`BINLOG MONITOR` on MariaDB). Without it `mysqldump` fails outright — once per
database, deep into the run. The script tests the privilege once, up front, by
running `SHOW BINARY LOG STATUS` / `SHOW MASTER STATUS`, and refuses to start
otherwise. Grant the privilege, or clear `SOURCE_DATA_OPT` and accept dumps with
no recovery coordinate.

**The empty-list check.** `wc -l` on an empty string returns 1, not 0. Before this
was caught, a run that backed up nothing sailed past every check and logged "All
databases dumped successfully". The script counts non-blank lines instead, and an
empty list is a **failure**, not a no-op.

**The space check** deliberately measures *all* user databases even in `SELECTED`
mode. An over-estimate refuses a run that would have fitted, which is recoverable.
An under-estimate fills the volume and produces truncated dumps, which is not.
60% of the logical data size is a safe floor for typical InnoDB data — SQL text
plus the gzip working set.

### Per-database stages

`PARALLEL` databases run at a time via `xargs -P`.

| # | Stage | Notes |
|---|---|---|
| 1 | `mysqldump` → `.sql` | `nice`/`ionice`; stderr captured, password warning filtered out |
| 2 | Empty-dump check | a zero-byte dump is a failure, not an archive |
| 3 | `sync` | prevents "file changed as we read it" on network storage |
| 4 | `tar -czf` | |
| 5 | `tar -tzf` read-back | proves the archive before the raw SQL is deleted |
| 6 | Delete the `.sql` | only after step 5 passes |
| 7 | SHA-256 | bare filename inside the `.sha256` |

If step 5 fails, the archive is removed and the **raw SQL is kept**. Discovering a
corrupt `.tar.gz` at restore time is discovering it far too late; here there is
still something to fall back on.

A failed database is recorded and the run continues to the others. The manifest is
written either way, and the script exits **1** if any database failed — an
incomplete backup set must not look green in cron.

### Backup modes

| `BACKUP_MODE` | Databases |
|---|---|
| `ALL` | every database except `information_schema`, `performance_schema`, `mysql`, `sys` |
| `SELECTED` | the newest `.txt` / `.csv` / `.lst` file in `DB_LIST_DIR`, one name per line; blank lines and `#` comments ignored |

### Buffer pool handling

`REGION 4` holds shrink/expand/warm-page helpers for releasing the pages a full
dump pulls into the InnoDB buffer pool. **They are commented out** in `REGION 8`
and in the save step. Uncomment them only on a server where the dump measurably
pollutes the working set; each resize blocks for up to `BP_RESIZE_TIMEOUT`
seconds and the sizes are hardcoded for one specific machine.

---

## 5. Dump options

```
--single-transaction --quick --routines --events --triggers
--set-gtid-purged=OFF --default-character-set=utf8mb4 --net-buffer-length=1M
--source-data=2
```

| Option | Why |
|---|---|
| `--single-transaction` | consistent snapshot of one database without locking it |
| `--quick` | streams rows instead of buffering a whole table in memory |
| `--routines --events --triggers` | without these the restore silently loses stored programs |
| `--source-data=2` | writes the binlog file and position as a comment — the only recovery coordinate the dump carries |
| `--default-character-set=utf8mb4` | `mysqldump` otherwise defaults to `utf8` and mangles 4-byte characters (emoji, some CJK) on the round-trip |
| `--set-gtid-purged=OFF` | emits nothing while GTID is off; prevents import failures into a non-empty server if GTID is ever enabled |

**`--hex-blob` is deliberately not set.** These schemas hold no
`BLOB`/`BINARY`/`VARBINARY`/`BIT` columns, so it would only inflate the dump. Add
it back the moment binary columns are introduced: without it, binary bytes pass
through the escaping and charset layers as text and can be altered in transit —
and the damage is invisible until the data is read back.

`DUMP_OPTS` in `logical.sh` and the safety-dump options in `restore_logical.sh`
must stay in step. Change one, change the other.

---

## 6. The manifest

One per run at `manifests/<run_id>.manifest`, written on **both** the success and
failure paths. It is the only ground truth about how a dump was produced.

```
run_id, server_name, started_at, finished_at, backup_mode
mysql_host, mysql_version, character_set
db_count, ok_count, failed_count, failed_list
dump_opts
recovery_method=logical_per_database
consistency=per_database_only
```

`character_set` and `mysql_version` matter at restore time: importing a dump into
a server with a different default collation is where silent corruption creeps in.

---

## 7. Restore lifecycle

```bash
./restore_logical.sh <database>                  # newest restore point
./restore_logical.sh <database> 2026-08-10       # a specific one
```

The restore **drops the database and imports the archive in its place**. Nothing
is merged and nothing is kept.

### The safety switch

`CONFIRM_RESTORE` in `REGION 1` is the only gate, and it behaves exactly like
`CONFIRM_WIPE` in the physical `restore_full.sh`:

| Value | Behaviour |
|---|---|
| `0` | **report only** — lists restore points, prints the plan and the data-loss window, changes nothing |
| `1` | **execute** |

Keep it at `0` between incidents. At `0` this is a safe read-only tool you can run
any time to see what is recoverable. Set it back to `0` afterwards.

### Stages

**Pre-flight (8 checks)** — tools, lock, MySQL reachable, backup directory,
restore point resolved, archive age, **checksum verified**, target state
inspected. All of it happens before anything is dropped, so a failure here costs
nothing: the database is still running and untouched.

Available restore points are listed on *every* run, with size, age and whether a
checksum file exists.

**1. Extract and validate.** The archive is unpacked to `STAGE_DIR`, then the
`.sql` is grepped for `CREATE DATABASE \`<db>\`` / `USE \`<db>\``. A renamed
archive, or a name mistyped under pressure, would otherwise drop and overwrite the
wrong database with no warning at all.

**2. Safety dump.** The current contents of the target are dumped to
`<db>/PRE-RESTORE_<db>_<ts>.sql.gz` before anything is dropped. There is **no
switch to turn this off** — a restore you cannot undo is not worth the few minutes
it takes, and a switch whose only sane value is "on" is not a real choice.

A failure here does **not** stop the restore. The usual reason current data cannot
be dumped is that it is damaged, which is exactly when the restore needs to
proceed; refusing would turn "no rollback" into "no recovery". The script logs a
loud block saying rollback is now impossible and gives you a chance to Ctrl+C.

**3. Drop and import.** `DROP DATABASE`, then the dump is piped in. There is no
`--force`: the import halts at the first error rather than ploughing on and
leaving a schema that is part imported, part missing, with no record of which. If
it does fail, the log states plainly that the database is in a partial state and
prints the rollback command.

**4. Verify.** Schema exists, table count > 0, plus routine/trigger counts and
size, each compared against the before state.

**5. Record state.** A marker at `STATE_DIR/logical_<db>_<ts>` records the restore
point, archive, safety dump, before/after table counts and `binlogs_applied=no`.

### Rolling back

```bash
zcat <BASE_DIR>/<db>/PRE-RESTORE_<db>_<ts>.sql.gz | mysql -u<user> -p -h<host>
```

The exact command is printed in the log at the moment the safety dump is written,
and again if the import fails.

---

## 8. Safety invariants

**1. Verify before destroying.** The checksum is checked, the archive is unpacked,
and the dump is confirmed to name the right database — all before the `DROP`.

**2. Read the archive back before deleting the source.** The backup only removes
the raw `.sql` after `tar -tzf` succeeds.

**3. Every restore takes a safety dump, unconditionally.**

**4. A partial import is announced, never hidden.** No `--force`; a failed import
exits 1 and says the database must not be given to applications.

**5. An empty database list is a failure.** Reporting success while backing up
nothing is the worst outcome available.

**6. Any failed database fails the run.** Exit 1, so cron cannot report a healthy
run while a tenant has no recoverable backup.

**7. Locks are per-destination.** `dbbackup_<basename BASE_DIR>.lock`, not one
global lock — two different `BASE_DIR` targets on one host must not block each
other.

---

## 9. Configuration reference

### Must match between the two scripts

| Setting | Consequence of a mismatch |
|---|---|
| `BASE_DIR` | the restore finds no archives, or restores from the wrong tree |
| dump options | the safety dump is not comparable to the backups it sits beside |

### `logical.sh`

| Setting | Meaning |
|---|---|
| `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_HOST` | connection; the user needs `REPLICATION CLIENT` |
| `SERVER_NAME` | identity, recorded in the manifest and used in `BASE_DIR` |
| `BASE_DIR` | destination root — one server, one location |
| `BACKUP_MODE` | `ALL` or `SELECTED` |
| `DB_LIST_DIR` | `SELECTED` only: folder of list files, newest wins |
| `PARALLEL` | concurrent `mysqldump` processes |
| `DUMP_OPTS` | see [§5](#5-dump-options) |
| `SPACE_REQUIRED_PCT` | free space needed, as a % of live data size (default 60) |
| `BP_*` | buffer pool sizes and timeout — only used if you uncomment `REGION 8` |

There are deliberately **no arguments**. This script backs up one server to one
location. If you need several destinations from one host, give each its own copy
of the script rather than passing a path in — a mistyped argument must never be
able to send a backup to the wrong tree.

### `restore_logical.sh`

| Setting | Meaning |
|---|---|
| `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_HOST` | connection |
| `BASE_DIR` | **must match `logical.sh`** |
| `CONFIRM_RESTORE` | `0` report only, `1` execute |
| `STAGE_DIR` | extraction work area, needs room for the uncompressed `.sql` |
| `STATE_DIR` | restore markers, `/var/lib/dbvault` — same convention as the physical chain |

---

## 10. Operating and troubleshooting

### Deployment

```cron
30 1 * * *  /Data/script/logical.sh >> /var/log/dblogical-backup.log 2>&1
```

Run as a user that can reach MySQL and write `BASE_DIR` and `/var/run`.
`restore_logical.sh` is run by hand, never scheduled.

### Verifying a backup

```bash
cd <BASE_DIR>/<db> && sha256sum -c <db>_2026-08-10.tar.gz.sha256
cat  <BASE_DIR>/manifests/2026-08-10.manifest
tar -tzf <BASE_DIR>/<db>/<db>_2026-08-10.tar.gz
```

Read `failed_count` in the manifest before trusting a run.

### Symptom → cause

| Symptom | Likely cause |
|---|---|
| Exits 1, "Database list is EMPTY" | MySQL unreachable, or `SELECTED` mode pointed at an empty/comment-only list file |
| Exits 1 on `REPLICATION CLIENT` | `MYSQL_USER` lacks the privilege `--source-data=2` needs; grant it, or clear `SOURCE_DATA_OPT` |
| Run ID has a time suffix | an archive from today already existed — the earlier run was left untouched, as intended |
| A `.sql` left in a database folder | its archive failed the `tar -tzf` read-back; the raw dump was kept on purpose |
| "Insufficient space" | needs `SPACE_REQUIRED_PCT`% of the *total* user data size, measured even in `SELECTED` mode |
| Restore prints a plan and stops | `CONFIRM_RESTORE=0` — that is the default and the safe state |
| "Dump does not reference database" | wrong archive for that database name; the guard did its job |
| "CHECKSUM MISMATCH" | archive is corrupt — nothing was changed, pick an older restore point |
| "SAFETY DUMP FAILED" | current data cannot be read; the restore continues with **no rollback** |
| "IMPORT FAILED … PARTIAL state" | keep applications off the database and roll back from the `PRE-RESTORE_*.sql.gz` |
| Restore leaves the database empty | verify step catches this and exits 1; the archive contained no tables |

### Not implemented

- **Retention** — see [§1](#1-what-logical-backup-can-and-cannot-give-you).
  `PRE-RESTORE_*.sql.gz` files accumulate too, and they sit in the same folder as
  the archives.
- **Binlog application** — no PITR on top of a logical restore. Use the physical
  chain's `apply_binlog.sh` for that.
- **Cross-database consistency** — not achievable with this approach at all.
