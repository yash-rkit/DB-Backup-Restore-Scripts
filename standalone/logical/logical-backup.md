# Logical Backup and Restore (mysqldump)

| Script | Role |
|---|---|
| `logical.sh` | one `mysqldump` per database → compress → checksum → manifest |
| `restore_logical.sh` | drop one database and import it back from an archive |

The per-database counterpart to the physical chain in
[../physical/physical-backup.md](../physical/physical-backup.md). Same
conventions: no arguments, all settings in `REGION 1`, non-zero exit on failure
so cron cannot report a broken run as green.

## 1. What this gives you, and what it does not

**Per-database restore.** Each database is dumped in its own
`--single-transaction`, so any one database restores to a consistent point. That
is why this chain exists alongside XtraBackup: that restores the *instance*, this
restores *one tenant*.

**No cross-database consistency.** `PARALLEL` databases dump at a time, each at a
different moment. Two databases from one run do not share a point in time. The
manifest records `consistency=per_database_only` so nobody assumes otherwise
mid-incident.

**No point-in-time recovery.** `restore_logical.sh` never applies binlogs. The
database returns to the moment its dump was taken; everything since is lost, and
the script prints the size of that window before and after. The dumps do carry a
binlog coordinate (`--source-data=2` writes it as a comment at the top of each
`.sql`), so a manual PITR could start there. Nothing here automates it.

**No retention.** Nothing in `logical.sh` deletes anything — archives, logs and
`PRE-RESTORE_*.sql.gz` files accumulate one set per run, indefinitely. Run
retention as a separate scheduled job.

## 2. Published layout

```
<BASE_DIR>/
├── <db>/
│   ├── <db>_2026-08-10.tar.gz             the dump (one .sql inside)
│   ├── <db>_2026-08-10.tar.gz.sha256      checksum, BARE filename inside
│   └── PRE-RESTORE_<db>_<ts>.sql.gz       safety dump, written by a restore
├── manifests/2026-08-10.manifest          one per run
└── logs/
    ├── backup_20260810.log                one per day
    └── restore_<db>_<ts>.log              one per restore
```

The `.sha256` records the **bare filename**, not the absolute path `sha256sum`
emits by default, so `sha256sum -c` still works after the tree is moved or
mounted elsewhere. Run it from inside the database folder.

## 3. Run IDs and same-day re-runs

The run ID is the date alone — `2026-08-10` — shared by every database in the
run, so a run stays identifiable as one unit.

If any archive from today already exists under `BASE_DIR`, the whole run switches
to `2026-08-10_14-30-11`. This is not optional: `tar -czf` overwrites its target
silently, so on a plain date name a manual backup taken before a risky change
would destroy that same morning scheduled run, leaving one copy from the worse
moment instead of two.

The check runs **after** the lock is taken. Before it, two runs starting together
would both conclude they were first.

Both forms coexist and sort correctly — the plain date sorts first (`.` is `0x2E`,
`_` is `0x5F`), so the later re-run is picked as newest. `restore_logical.sh`
forces `LC_ALL=C` for exactly this: locale collation can ignore punctuation and
make the order unpredictable.

## 4. Backup

### Pre-flight

| Check | Failure mode it prevents |
|---|---|
| `mysqldump`, `mysql`, `tar`, `sha256sum` present | failing an hour in |
| MySQL reachable | every dump failing one by one |
| `--source-data` vs `--master-data` resolved | unknown-option failure on every dump |
| `REPLICATION CLIENT` privilege | the same, but only visible per database |
| Database list non-empty | a run that backs up nothing and reports success |
| Free space ≥ `SPACE_REQUIRED_PCT` of data size | truncated dumps |

Three are worth the detail:

**The privilege check.** `--source-data=2` needs `REPLICATION CLIENT` (or
`BINLOG MONITOR` on MariaDB). Without it `mysqldump` fails outright, once per
database, deep into the run. The script tests it once up front via
`SHOW BINARY LOG STATUS` / `SHOW MASTER STATUS` and refuses to start otherwise.
Grant the privilege, or clear `SOURCE_DATA_OPT` and accept dumps with no recovery
coordinate.

**The empty-list check.** `wc -l` on an empty string returns 1, not 0. Before this
was caught, a run that backed up nothing passed every check and logged "All
databases dumped successfully". Non-blank lines are counted instead, and an empty
list is a **failure**, not a no-op.

**The space check** measures *all* user databases even in `SELECTED` mode. An
over-estimate refuses a run that would have fitted, which is recoverable; an
under-estimate fills the volume and truncates dumps, which is not. 60% of the
logical data size is a safe floor for typical InnoDB — SQL text plus the gzip
working set.

MySQL helper queries send stderr to the log rather than `/dev/null`, so an empty
result stays distinguishable from a failed connection.

### Per-database stages

`PARALLEL` databases run at a time via `xargs -P`.

| # | Stage | Notes |
|---|---|---|
| 1 | `mysqldump` → `.sql` | `nice`/`ionice`; stderr captured, password warning filtered |
| 2 | Empty-dump check | a zero-byte dump is a failure, not an archive |
| 3 | `sync` | prevents "file changed as we read it" on network storage |
| 4 | `tar -czf` | |
| 5 | `tar -tzf` read-back | proves the archive before the raw SQL is deleted |
| 6 | Delete the `.sql` | only after step 5 passes |
| 7 | SHA-256 | bare filename inside the `.sha256` |

If step 5 fails the archive is removed and the **raw SQL is kept** — finding a
corrupt `.tar.gz` at restore time is finding it far too late, and this way there
is still something to fall back on.

A failed database is recorded and the run continues. The manifest is written
either way and the script exits **1** if any database failed: an incomplete backup
set must not look green in cron.

### Modes and buffer pool

| `BACKUP_MODE` | Databases |
|---|---|
| `ALL` | everything except `information_schema`, `performance_schema`, `mysql`, `sys` |
| `SELECTED` | newest `.txt`/`.csv`/`.lst` in `DB_LIST_DIR`, one name per line; blanks and `#` ignored |

`REGION 4` holds shrink/expand/warm-page helpers for releasing the pages a full
dump pulls into the InnoDB buffer pool. **They are commented out** in `REGION 8`
and in the save step. Uncomment only where a dump measurably pollutes the working
set: each resize blocks for up to `BP_RESIZE_TIMEOUT` seconds and the sizes are
hardcoded for one specific machine.

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
| `--routines --events --triggers` | without these a restore silently loses stored programs |
| `--source-data=2` | writes the binlog file and position as a comment — the only recovery coordinate the dump carries |
| `--default-character-set=utf8mb4` | `mysqldump` otherwise defaults to `utf8` and mangles 4-byte characters (emoji, some CJK) on the round-trip |
| `--set-gtid-purged=OFF` | emits nothing while GTID is off; prevents import failures into a non-empty server if GTID is ever enabled |

**`--hex-blob` is deliberately not set.** These schemas hold no
`BLOB`/`BINARY`/`VARBINARY`/`BIT` columns, so it would only inflate the dump. Add
it back the moment binary columns appear: without it, binary bytes pass through
the escaping and charset layers as text and can be altered in transit, and the
damage is invisible until the data is read back.

`DUMP_OPTS` in `logical.sh` and the safety-dump options in `restore_logical.sh`
must stay in step. Change one, change the other.

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

`character_set` and `mysql_version` matter at restore time: importing into a
server with a different default collation is where silent corruption creeps in.

## 7. Restore

```bash
./restore_logical.sh <database>                  # newest restore point
./restore_logical.sh <database> 2026-08-10       # a specific one
```

It **drops the database and imports the archive in its place**. Nothing is merged
and nothing is kept.

`CONFIRM_RESTORE` in `REGION 1` is the only gate:

| Value | Behaviour |
|---|---|
| `0` | **report only** — lists restore points, prints the plan and the data-loss window, changes nothing |
| `1` | **execute** |

Keep it at `0` between incidents. At `0` this is a safe read-only tool for seeing
what is recoverable. Set it back afterwards.

**Pre-flight, 8 checks** — tools, lock, MySQL reachable, backup directory, restore
point resolved, archive age, **checksum verified**, target state inspected. All
before anything is dropped, so a failure here costs nothing. Available restore
points are listed on every run with size, age and whether a checksum exists.

| # | Stage | Detail |
|---|---|---|
| 1 | Extract and validate | unpack to `STAGE_DIR`, then grep the `.sql` for a `CREATE DATABASE` / `USE` naming this database. A renamed archive, or a name mistyped under pressure, would otherwise drop and overwrite the wrong database silently |
| 2 | Safety dump | current contents → `<db>/PRE-RESTORE_<db>_<ts>.sql.gz`, before anything is dropped |
| 3 | Drop and import | `DROP DATABASE`, then pipe the dump in |
| 4 | Verify | schema exists, table count > 0, routine/trigger counts and size vs before |
| 5 | Record state | marker at `STATE_DIR/logical_<db>_<ts>`: restore point, archive, safety dump, before/after counts, `binlogs_applied=no` |

**There is no switch to skip the safety dump.** A restore you cannot undo is not
worth the few minutes it takes, and a switch whose only sane value is "on" is not
a real choice.

**A failed safety dump does not stop the restore.** The usual reason current data
cannot be dumped is that it is damaged — exactly when the restore needs to
proceed. Refusing would turn "no rollback" into "no recovery". The script logs a
loud block saying rollback is now impossible and gives you a chance to Ctrl+C.

**The import has no `--force`.** It halts at the first error rather than leaving a
schema that is part imported, part missing, with no record of which. If it fails,
the log says the database is in a partial state and prints the rollback command.

### Rolling back

```bash
zcat <BASE_DIR>/<db>/PRE-RESTORE_<db>_<ts>.sql.gz | mysql -u<user> -p -h<host>
```

Printed in the log when the safety dump is written, and again if the import fails.

## 8. Safety invariants

1. **Verify before destroying** — checksum checked, archive unpacked, dump
   confirmed to name the right database, all before the `DROP`.
2. **Read the archive back before deleting the source** — the raw `.sql` goes only
   after `tar -tzf` succeeds.
3. **Every restore takes a safety dump, unconditionally.**
4. **A partial import is announced, never hidden** — no `--force`; exit 1 and a
   statement that the database must not be given to applications.
5. **An empty database list is a failure** — reporting success while backing up
   nothing is the worst outcome available.
6. **Any failed database fails the run** — exit 1, so cron cannot report health
   while a tenant has no recoverable backup.
7. **Locks are per-destination** — `dbbackup_<basename BASE_DIR>.lock`, so two
   `BASE_DIR` targets on one host do not block each other.

## 9. Configuration

Both scripts must agree on `BASE_DIR` (or the restore finds no archives, or
restores from the wrong tree) and on their dump options (or the safety dump is not
comparable to the backups beside it).

### `logical.sh`

| Setting | Meaning |
|---|---|
| `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_HOST` | connection; needs `REPLICATION CLIENT` |
| `SERVER_NAME` | identity, recorded in the manifest and used in `BASE_DIR` |
| `BASE_DIR` | destination root — one server, one location |
| `BACKUP_MODE` | `ALL` or `SELECTED` |
| `DB_LIST_DIR` | `SELECTED` only: folder of list files, newest wins |
| `PARALLEL` | concurrent `mysqldump` processes |
| `DUMP_OPTS` | see §5 |
| `SPACE_REQUIRED_PCT` | free space needed, as a % of live data size (default 60) |
| `BP_*` | buffer pool sizes and timeout — only used if `REGION 8` is uncommented |

There are deliberately **no arguments**. This backs up one server to one location;
for several destinations from one host, give each its own copy of the script. A
mistyped argument must never be able to send a backup to the wrong tree.

### `restore_logical.sh`

| Setting | Meaning |
|---|---|
| `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_HOST` | connection |
| `BASE_DIR` | **must match `logical.sh`** |
| `CONFIRM_RESTORE` | `0` report only, `1` execute |
| `STAGE_DIR` | extraction work area; needs room for the uncompressed `.sql` |
| `STATE_DIR` | restore markers, `/var/lib/dbvault` — same convention as the physical chain |

## 10. Operating and troubleshooting

```cron
30 1 * * *  /Data/script/logical.sh >> /var/log/dblogical-backup.log 2>&1
```

Run as a user that can reach MySQL and write `BASE_DIR` and `/var/run`.
`restore_logical.sh` is run by hand, never scheduled.

### Verifying a backup

```bash
cd <BASE_DIR>/<db> && sha256sum -c <db>_2026-08-10.tar.gz.sha256
cat  <BASE_DIR>/manifests/2026-08-10.manifest     # read failed_count first
tar -tzf <BASE_DIR>/<db>/<db>_2026-08-10.tar.gz
```

### Symptom → cause

| Symptom | Likely cause |
|---|---|
| Exits 1, "Database list is EMPTY" | MySQL unreachable, or `SELECTED` pointed at an empty or comment-only list |
| Exits 1 on `REPLICATION CLIENT` | `MYSQL_USER` lacks the privilege `--source-data=2` needs; grant it, or clear `SOURCE_DATA_OPT` |
| Run ID has a time suffix | an archive from today existed — the earlier run was left untouched, as intended |
| A `.sql` left in a database folder | its archive failed the `tar -tzf` read-back; the raw dump was kept on purpose |
| "Insufficient space" | needs `SPACE_REQUIRED_PCT`% of *total* user data size, measured even in `SELECTED` mode |
| Restore prints a plan and stops | `CONFIRM_RESTORE=0` — the default and the safe state |
| "Dump does not reference database" | wrong archive for that name; the guard did its job |
| "CHECKSUM MISMATCH" | archive is corrupt; nothing was changed, pick an older restore point |
| "SAFETY DUMP FAILED" | current data cannot be read; the restore continues with **no rollback** |
| "IMPORT FAILED … PARTIAL state" | keep applications off and roll back from the `PRE-RESTORE_*.sql.gz` |
| Restore leaves the database empty | the verify step catches it and exits 1; the archive held no tables |

### Not implemented

**Retention** (§1) · **binlog application** — no PITR on a logical restore; use the
physical chain `apply_binlog.sh` · **cross-database consistency** — not achievable
with this approach at all.
