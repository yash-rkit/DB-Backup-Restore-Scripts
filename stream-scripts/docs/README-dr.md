# The Restore-VM Pipeline (restore → dump → sync → retention)

Reference for the five scripts in [stream-scripts/](./) that run on the **restore
VM**, not on a database host.

| Script           | Role                                                                    | Run by                    |
| ---------------- | ----------------------------------------------------------------------- | ------------------------- |
| `final.sh`       | the pipeline: per server restore + dump, then sync and retention, then shut down | crontab, nightly  |
| `restore_vm.sh`  | argument-driven restore of one named server's `.xbstream` onto this host | `final.sh`, or by hand    |
| `logical.sh`     | per-database `mysqldump` of the rebuilt instance, published to the share | `final.sh`, or by hand    |
| `backup_sync.sh` | copies the newest dump of each database to the second share             | `final.sh`, or by hand    |
| `db_cleanup.sh`  | retention over the dumps on the first share                             | `final.sh`, or by hand    |

These consume what [`backup.sh`](./backup.sh) and
[`binlog_collect.sh`](./binlog_collect.sh) publish. The log engine, the PART
layout, the `RESULT` line, the `die()`/`fail_run()` discipline and the CIFS rules
are all the same — [README.md](./README.md) §4–§6 documents them once and this
document does not repeat them. Read that first.

---

## Contents

| §   | Section                                                       |
| --- | ------------------------------------------------------------- |
| 1   | [What the pipeline is for](#1-what-the-pipeline-is-for)       |
| 2   | [The two dangers it is built around](#2-the-two-dangers-it-is-built-around) |
| 3   | [Published layout](#3-published-layout)                       |
| 4   | [`final.sh`](#4-finalsh)                                      |
| 5   | [`restore_vm.sh`](#5-restore_vmsh)                            |
| 6   | [`logical.sh`](#6-logicalsh)                                  |
| 7   | [`backup_sync.sh`](#7-backup_syncsh)                          |
| 8   | [`db_cleanup.sh`](#8-db_cleanupsh)                            |
| 9   | [What is deliberately not here](#9-what-is-deliberately-not-here)   |
| 10  | [Deploying and first run](#10-deploying-and-first-run)        |
| 11  | [Configuration reference](#11-configuration-reference)        |

---

## 1. What the pipeline is for

A physical `.xbstream` archive is the fastest way to get a whole server back, and
the worst way to get one table back: it restores a datadir, not a database. The
pipeline turns the physical archives into per-database logical dumps, on a
machine where wiping the datadir costs nothing.

Nightly, for each production server in turn:

```
backup.sh on prod  ──►  <backup_base>/20260821.xbstream        (physical, one file)
                                    │
restore_vm.sh      ──────────────────┘   erases /Data/mysql, rebuilds it,
                                         prepares it, starts MySQL, applies binlogs
                                    │
logical.sh         ──────────────────┘   mysqldump per database
                                    ▼
                        <base_dir>/<db>/<db>_20260821.tar.gz   (logical, one per db)
                                    │
backup_sync.sh     ──────────────────┘   newest per database ──► second share
db_cleanup.sh      ──────────────────┘   retention on the first share
```

Two products come out of it. The dumps, which give per-table and per-database
recovery and can be restored anywhere. And the answer to the question the
physical chain cannot answer on its own: *does that archive actually restore?*
Every night, for every server, the pipeline proves it or reports that it did not.

The restored datadir itself is disposable. Only the last server of the night is
still on disk when the run ends, and the next run erases that too.

---

## 2. The two dangers it is built around

Everything unusual in these five scripts traces back to one of these.

### 2.1 One datadir, many servers

`final.sh` restores every configured server onto the same `MYSQL_DATADIR`, one
after another. That has three consequences the scripts have to handle
explicitly:

**A wrong-server dump is invisible.** If server B's restore fails and the dump
runs anyway, it dumps server A's data — still mounted from the previous
iteration — and publishes it, checksummed and verified, under B's name. Nothing
downstream can tell. Two independent guards stop it:

- `final.sh` does not dump a server whose restore failed. It records the failure
  and moves on.
- `logical.sh` refuses to run at all unless the newest restore marker in
  `STATE_DIR` belongs to the server it was told to dump. That check is the one
  that would catch a hand-run in the wrong order, and `--no-source-check` is the
  documented way out when the operator knows better.

**Markers and logs must be keyed by server, not by backup id.** Every server's
daily archive is called `20260821`. `restore.sh` keys its marker on the id alone,
which is correct when one host restores one server; on the restore VM it would
have the second server of the night reading the first one's binlog anchor. So
`restore_vm.sh` writes `${SERVER_NAME}_${BACKUP_ID}_restore_state`, and names its
logs, its staged binlog directory and its dry-run preview the same way.

**`CONFIRM_RESTORE_VM`.** `final.sh` erases the datadir once per configured
server. On a production host that is a self-inflicted outage repeated N times.
The switch exists so that a deployment copied onto the wrong machine refuses to
run — which only works while it ships unset, so it is a PART 1A value: it
arrives as `__SET_ME__` and the run stops until somebody decides, on that host,
which answer is true. See §11.

### 2.2 The destination is CIFS, and CIFS lies

[README.md](./README.md) §1 in the parent document, and unchanged here: an
unmounted share is an ordinary empty directory that passes `-d`, `-w`, `ls` and
`mkdir -p`, and writes land on the root filesystem.

What is new is that the paths are now **arguments**, so a typo is a plausible
daily event rather than a one-off edit. Every script that takes a path argument
therefore checks two separate things:

| Check                                  | Catches                                                  |
| -------------------------------------- | -------------------------------------------------------- |
| `mountpoint -q "$SMB_MOUNT_POINT"`     | the share is not mounted at all                          |
| `[[ "$PATH_ARG" == "$SMB_MOUNT_POINT"/* ]]` | a path that is spelled wrong, or points off the share entirely |

`mountpoint` is only ever true for the mount point itself, never for a
subdirectory, which is why the prefix test has to be a separate string
comparison. Without it, `--base_dir=/livestorge/Logical/X` (one letter missing)
is a perfectly writable local directory that fills the root filesystem while
every step reports success.

`db_cleanup.sh` inverts the same reasoning: unmounted, it would find nothing to
delete and report a clean run, hiding the fact that retention has silently
stopped. It refuses to walk a path that is not under the mount.

---

## 3. Published layout

Two trees on the primary share. `backup_base` is written by the production host;
`base_dir` is written by the restore VM.

```
/livestorage/
├── Backup/<server>/                       ← backup_base, one per prod server
│   │   the seven parts below share one backup id and expire together under
│   │   physical_retention; deleting the archive alone would strand binlog/<id>
│   ├── 20260821.xbstream                     physical archive
│   ├── 20260821.sha256
│   ├── 20260821.manifest
│   ├── 20260821_binlog_info
│   ├── binlog/20260821/                      collected binlogs
│   ├── meta/20260821/
│   └── logs/20260821/restore_<stamp>/        ← restore_vm.sh publishes here
│
├── Logical/<server>/                      ← base_dir, one per prod server
│   ├── <database>/
│   │   ├── <database>_20260821.tar.gz         the dump
│   │   └── <database>_20260821.tar.gz.sha256
│   ├── manifests/20260821.manifest
│   └── logs/20260821/                         ← logical.sh publishes here
│
├── final/pipeline_logs/<stamp>/           ← final.sh publishes here
└── final/cleanup_logs/<stamp>/            ← db_cleanup.sh publishes here

/southstorage/                             ← the second share
├── <sync_dest>/<database>/<database>_20260821.tar.gz(+.sha256)
└── backup_latest/_sync_logs/<stamp>/       ← backup_sync.sh publishes here

/Data/dbvault-stage/                        ← LOCAL, holds nothing after a run
├── <script>_<stamp>.log                       logs, until they are published
└── .logical_<server>_<stamp>/build/            one .sql + .tar.gz per slot
```

`sync_dest` is per server, from the config file; it defaults to
`/southstorage/backup_latest/<server_name>`.

### Naming

Dumps follow the same rule as the physical archives: **bare date, with a time
appended only when that day's archives already exist on the share**
(`db_20260821.tar.gz`, then `db_20260821_175047.tar.gz`). The share is the
authoritative collision test: local staging is emptied as each database
finishes, so a published archive is the only proof the day is taken. The test
sits after the lock, or two runs starting together would both decide they were
first.

A `.tar.gz` contains exactly one file, `<database>_<run id>.sql`, which is what
[`server/logical/restore_logical.sh`](../server/logical/restore_logical.sh)
expects.

### Directories that are not databases

`logical.sh` writes `logs/` and `manifests/` inside `base_dir`, beside the
per-database directories. `backup_sync.sh` and `db_cleanup.sh` both skip them by
name (`NON_DB_DIRS`) and skip anything beginning with `.` or `_`. Without that,
`logs/` reads as a database with no archives in it.

---

## 4. `final.sh`

```
final.sh [--config=PATH] [--backup_date=YYYYMMDD] [--skip-binlog]
         [--skip-sync] [--skip-cleanup] [--no-shutdown] [--dry-run]
```

No arguments in normal use. The server list comes from `CONFIG_FILE` in PART
1C, default `/Data/script/servers.json`; `--config=PATH` overrides it.

### PART layout

```
PART 1   configuration
PART 2   log engine
PART 3   failure handling
PART 4   probes
PART 5   usage and arguments
PART 6   single-instance lock
PART 7   identity and paths
PART 8   pre-flight            12 checks
PART 9   servers               step 1/3
PART 10  sync                  step 2/3
PART 11  cleanup               step 3/3
PART 12  summary
PART 13  shutdown
```

### The config file

A JSON array, processed in order:

```json
[
  {
    "server_name": "Cloud-Live-DB-Default",
    "backup_base": "/livestorage/Backup/Cloud-Live-DB-Default",
    "base_dir":    "/livestorage/Logical/Cloud-Live-DB-Default"
  },
  {
    "server_name": "GSP-Cloud-Live-DB",
    "backup_base": "/livestorage/Backup/GSP-Cloud-Live-DB",
    "base_dir":    "/livestorage/Logical/GSP-Cloud-Live-DB",
    "skip_binlog": true,
    "mode":        "SELECTED",
    "db_list_dir": "/Data/script/dblist"
  }
]
```

| Key           | Required | Meaning                                                        |
| ------------- | -------- | -------------------------------------------------------------- |
| `server_name` | yes      | identity: names the dump tree, the marker, the logs            |
| `backup_base` | yes      | where that server's `backup.sh` publishes its `.xbstream`      |
| `base_dir`    | yes      | where this run's logical dumps are published                   |
| `backup_id`   | no       | an exact archive id, instead of the date's latest              |
| `skip_binlog` | no       | `true` restores that one server to the backup point only       |
| `mysql_host`  | no       | overrides the dump connection for that server                  |
| `mode`        | no       | `ALL` (default) or `SELECTED`                                  |
| `db_list_dir` | no       | required by `mode: "SELECTED"`                                 |
| `sync_dest`   | no       | `backup_sync.sh`: destination on the second share              |
| `retention`   | no       | `db_cleanup.sh`: `"smart"` or `"days:N"`, over `base_dir`      |
| `physical_retention` | no | `db_cleanup.sh`: `"smart"` or `"days:N"`, over `backup_base` |

**This one file drives all four steps.** `final.sh` reads the first eight
fields; `backup_sync.sh` reads `base_dir` and `sync_dest`; `db_cleanup.sh` reads
`base_dir` and `retention` for the dumps, and `backup_base` and
`physical_retention` for the physical backups. No script carries its own server list, so adding a
server is one JSON entry and removing one cannot leave a stale array behind that
keeps expiring a tree nothing writes to any more.

`final.sh` validates `sync_dest` and `retention` even though it never uses them
— a typo surfaces in pre-flight instead of three hours later, in the step that
does consume it.

### The last two steps are opt-in

| Config state                  | Step 2 sync                  | Step 3 cleanup                |
| ----------------------------- | ---------------------------- | ----------------------------- |
| no `sync_dest` on an entry    | that server is not copied    | —                             |
| no `sync_dest` on any entry   | **does not run** (skipped)   | —                             |
| no `retention` on an entry    | —                            | that server's dumps never expire |
| no `retention` on any entry   | —                            | the dump pass deletes nothing |
| no `physical_retention` on an entry | —                      | that server's `.xbstream` sets never expire |
| neither retention field anywhere | —                          | **does not run** (skipped)    |

With neither field anywhere, the pipeline restores and dumps and stops: the
dumps stay on the primary share, nothing is copied, nothing is deleted, and the
run still reports `RESULT ok`. A skipped step is a deliberate outcome, not a
failure — only a step that was asked for and then broke sets the exit status.

Because of that, a host that never syncs need not deploy `backup_sync.sh` at
all. Pre-flight notes a missing child script but does not refuse; if the config
*does* ask for that step and the script is absent, the step itself fails with
`SCRIPT MISSING` and the run exits non-zero.

[`servers.example.json`](./servers.example.json) is a working starting point.

### The whole config is validated before the first datadir is erased

Pre-flight reads every entry, checks that the three required keys are present,
that `server_name` is a safe single path component, that both paths are under the
mount, that a `SELECTED` entry has a list directory, and that no `server_name`
appears twice. Every problem is printed; then the run stops with a count.

Discovering a typo in entry four *after* entries one to three have been restored
and dumped costs hours and leaves the night half finished, which is why this is
one pass up front rather than a per-iteration check. The entries are read into
arrays once, so editing the config while the pipeline is running cannot change
what the running pipeline does.

### A failed server is data, not an abort

`fail_run` is for the pipeline: bad config, a missing child script, an
unreachable share. A **server** failing is recorded in `FAILED_SERVERS` and the
loop continues to the next one, because the other sixteen dumps are still worth
having. A restore failure skips that server's dump; a dump failure is reported
against the server that had already restored.

Sync and cleanup still run afterwards. Sync copies the newest dump of each
database, so a server that failed tonight still has yesterday's copied forward;
cleanup never deletes the newest archive of a database, so that copy survives the
gap. The exit status is non-zero if any server, the sync, or the cleanup failed.

### Child output

Children use the same log engine, so their lines land in the pipeline log
already formatted. `run_child` tees each child's output to the terminal and to
the run log, and reads the child's own `RESULT` line back out to quote it in the
summary. `PIPESTATUS[0]` is what decides success — `tee`'s status is always 0.

### Order: sync before cleanup

Retention deletes from the primary share. An archive that has not been copied to
the second share yet must not be a candidate for deletion in the same run, so
cleanup is last.

### Shutdown

`shutdown -h +10`, after `publish_logs`, always in that order — a VM that powers
off with its only log on local disk has thrown the run away. `--no-shutdown`
skips it, `--dry-run` implies it, and `SHUTDOWN_ON_FAILURE=0` in PART 1 keeps the
machine up when the run was incomplete. A pipeline that dies in `fail_run` never
schedules a shutdown at all.

---

## 5. `restore_vm.sh`

```
restore_vm.sh --server_name=NAME --backup_base=PATH
              [--backup_id=ID | --backup_date=YYYYMMDD]
              [--from=<binlog>] [--dry-run] [--skip-binlog] [--binlog-only]
```

The same three phases as [`restore.sh`](./restore.sh) — verify, restore
(**copy → wipe → extract → decompress → prepare → start**), apply — with the
same one-shot binlog apply, the same state-selected failure advice, and one
addition: the source server is an argument. Read [README.md](./README.md) §9 for
the phase logic; only the differences are below.

| `restore.sh`                                | `restore_vm.sh`                                   |
| ------------------------------------------- | ------------------------------------------------- |
| `SECONDARY_STORAGE_DIR` is a constant       | `--backup_base`, validated to be under the mount  |
| backup id is a positional argument          | `--backup_id`, or the latest archive of `--backup_date` (default today) |
| marker `${BACKUP_ID}_restore_state`          | marker `${SERVER_NAME}_${BACKUP_ID}_restore_state` |
| 14 pre-flight checks                        | 16 — `backup base` under the mount, and `archive staging space` |
| extracts straight off the share             | copies the archive to local disk first (`STAGE_ARCHIVE=1`) |
| next step: take a fresh backup              | next step: `logical.sh` — this datadir is temporary |

`restore.sh` is unchanged and stays the tool for restoring a server onto itself.

### Staging the archive on local disk

`STAGE_ARCHIVE=1` (the default) copies the `.xbstream` from the share to
`ARCHIVE_STAGE_DIR` **before** MySQL is stopped, checksums the local copy, and
extracts from there. Set it to `0` to get the old behaviour of extracting
straight off the share.

Two reasons, in order of importance:

**The network leaves the destructive window.** The wipe happens only once a
verified local copy exists, so a share that drops costs a retry instead of
leaving a half-populated datadir with the old data already gone.

**It is much faster.** `xbstream` reads its stdin serially in small chunks and
interleaves thousands of file creations; over SMB every one of those pays link
latency. Measured on the same 14GiB archive, same share, same run:

| | over the network | throughput |
| --- | --- | --- |
| flat read (`sha256sum` of the archive) | 14 GiB | 71 MiB/s |
| `xbstream -x` reading the same file    | 14 GiB | 17 MiB/s |

The old flow paid that second, slower read *and* read the archive twice —
once to verify, once to extract. Staging reads it once, at the faster rate.

Checksumming the local copy is also a stronger guarantee than checksumming the
share: it certifies the exact bytes the extract will consume, where the old
order left a window in which the two separate reads could disagree.

On success the staged file is deleted. On failure it is **kept**
(`KEEP_STAGED_ON_FAILURE=1`) — it is already verified, so a re-run checksums it
and skips the copy, turning a ~25-minute redo into roughly 8 minutes.

`archive staging space` is a pre-flight check of its own because the stage and
the datadir may share a filesystem, in which case they compete for one budget.
It compares `stat -c %d` on both paths and sizes the requirement accordingly.
Getting this wrong means ENOSPC *after* the wipe.

### One-pass extract (`XBSTREAM_DECOMPRESS`)

Off by default. When set to `1`, `xbstream -x --decompress` writes the datadir
already expanded, so the `.zst` files are never created and never read back —
saving a 1x-compressed write plus a 1x-compressed read (~2 minutes on a 14GiB
archive, since the 94GiB write dominates either way and that write remains).

The real gain is not speed. The two-pass flow has a silent-corruption path:
`--prepare` skips a leftover compressed file without complaint and it becomes an
unreadable tablespace at runtime. The script guards it with a `find` for
`*.zst *.qp *.lz4`, but one-pass extraction removes the intermediate compressed
state altogether, so there is nothing to leave behind.

Verify support before enabling — not every build has it:

```bash
xbstream --help | grep -i decompress
```

### Waiting for MySQL after the restore

Readiness and authentication are checked **separately**, and this matters more
than it sounds.

A physical restore overwrites `mysql.user` with the **source** server's
accounts. After restoring server A onto host B, `MYSQL_USER`'s password is
whatever it is on A — so a credential-based readiness probe can be rejected by a
server that restored perfectly and is serving normally.

The probe is therefore `mysqladmin ping`, and an `Access denied` reply counts as
**up**: the server parsed the handshake in order to refuse it. Three states are
now distinguished where the old loop reported all of them as
`MySQL did not accept connections within 120s`:

| state | client error | what happens |
| --- | --- | --- |
| still starting | 2002 / 2003 | keep waiting, up to `MYSQL_READY_TIMEOUT` |
| process gone | any, and `mysql_up` false | **fail immediately**, with the mysqld error log |
| up, password rejected | 1045 | readiness passes; the credential is reported separately |

Three related settings and behaviours:

- `MYSQL_READY_TIMEOUT` (default `900`) replaces a hardcoded 60 × 2s. A large
  datadir can spend well over two minutes opening tablespaces, and waiting is
  far cheaper than repeating the restore.
- A dead mysqld is detected on the next poll rather than at the timeout, so a
  genuine startup failure surfaces in seconds instead of minutes.
- Every failure here prints the tail of **mysqld's own error log** into the run
  log, located from `my_print_defaults` rather than from the server. The old
  message said "check the MySQL error log" without saying where it was.

If the credentials are rejected, the restore is already complete and the marker
is already written, so recovery does not repeat it:

```bash
systemctl stop mysql
# start with --skip-grant-tables, reset the account, restart
restore_vm.sh --server_name=NAME --backup_base=PATH --binlog-only
```

`fail_run` reports this accurately. Its `DATADIR_WIPED` branch used to state
"MySQL is stopped" as fixed text, which was false whenever the failure came
*after* the start — precisely when it misleads. It now observes `mysql_up`, and
a failure after a completed restore says so instead of sending the operator to
redo work that is intact.
### Resolving "today's latest"

With no `--backup_id`, the id is the newest archive whose name starts with the
date. Both naming forms coexist on the share, so date and time are **separate
sort keys**, with a bare date read as time `000000`:

```
20260821          → 20260821 000000
20260821_143005   → 20260821 143005
```

A plain lexical sort puts `20260821_143005` *before* `20260821` (`_` sorts before
end-of-string) and would quietly anchor on the day's *first* backup. This is the
same rule `binlog_collect.sh` uses for anchor discovery, for the same reason, and
it is load-bearing — do not reduce it to `sort | tail -1`.

Resolution happens in PART 7, **before** the log exists, because the log is named
after the id. Failures there print plainly and exit; they are the one class of
failure in these scripts with no formatted output. The mount is checked first, so
"the share is gone" and "there is no archive for that date" are different
messages.

`--binlog-only` resolves against the restore markers in `STATE_DIR` instead of
the archives: it needs an id that was restored *here*, and the archive may since
have been pruned.

---

## 6. `logical.sh`

```
logical.sh --server_name=NAME --base_dir=PATH [--mysql_host=HOST]
           [--mode=ALL|SELECTED] [--db_list_dir=PATH] [--no-source-check]
```

Four steps: `list` → `dump` → `verify` → `manifest`, 15 pre-flight checks.
Derived from [`server/logical/logical.sh`](../server/logical/logical.sh) — same
`mysqldump` options, same per-database `.tar.gz`, same bare-filename checksum
sidecar — restructured onto the stream-scripts log engine, with the buffer-pool
machinery (commented out in the original) dropped.

### The connection

`MYSQL_HOST` in PART 1A, `--mysql_host=` to override, empty for the local
socket. On the restore VM this must be the instance `restore_vm.sh` just
rebuilt. It is not a production host: pointing it at one turns a DR drill into
load on live data.

### The source check

The guard described in §2.1. The newest `*_restore_state` in `STATE_DIR` must
belong to `--server_name`; otherwise the run dies before dumping anything. It
also gives the manifest something useful: `restored_from_backup_id` ties every
dump back to the physical archive it came out of.

`--no-source-check` downgrades it to a skipped check, for an instance that holds
the right data by some other route.

### Built locally, published once

The archive is built on **local disk** and only the finished file crosses the
network. Dumping straight onto the share costs three passes over the same data:

| Where the work happens | Network passes over one database                              |
| ---------------------- | ------------------------------------------------------------- |
| On the share           | write the `.sql`, read it back for `tar`, write the `.tar.gz`, read that back for `sha256sum` — plus the verify read |
| Locally (this script)   | write the finished `.tar.gz` once — plus the verify read       |

`PARALLEL` databases at a time, and each one goes all the way through before its
slot is reused:

1. `mysqldump` to `<build>/<db>_<run id>.sql` — local
2. `tar -czf --remove-files` to `<build>/<db>_<run id>.tar.gz` — local; the
   `.sql` is dropped as the archive is written, so the slot holds both copies
   for the shortest time it can
3. `tar -tzf` — local, so reading the archive back costs nothing
4. `sha256sum` into `<archive>.sha256` — local. This hash is the reference the
   copy on the share is verified against in step 3 of the run; hashing *after*
   the transfer instead would only prove the share agrees with itself
5. `cp` to `<dest>.tar.gz.part`, `sync`, rename, copy the sidecar across, then
   delete both local files

A failure at any step is recorded and the run continues: one unreadable schema
must not cost the other sixteen. `.part` matters because `backup_sync.sh` and
`db_cleanup.sh` both glob `*.tar.gz` — a half-written archive must not be
visible to either.

Because the archive is staged locally, `LOCAL_STAGE` needs room for the
`PARALLEL` largest databases at once — the uncompressed `.sql` plus its archive,
which is what `LOCAL_SPACE_PCT` (130%) sizes. Pre-flight measures the largest
`PARALLEL` schemas from `information_schema` and refuses to start if the staging
filesystem cannot hold them. Getting this wrong fills the root filesystem of the
host that is also running MySQL, so it is a hard failure, not a warning.

Workers run under `xargs` in their own subshells, so a variable a worker sets
dies with it. Each writes a status file into `WORK_DIR` — pessimistically, before
it starts, so a worker killed outright still reads as a failure rather than as a
database nobody looked at — and the parent tallies those files.

### The verify step

The one deliberate re-read. Every published archive is read back off the share
and checked against the checksum computed locally before the transfer, so it
proves the file on CIFS matches the file that was built — the only check that
catches an archive which reached the share wrong. A mismatch fails the run and
the file is **left in place**: its sidecar already fails, so nothing downstream
will trust it, and it is evidence.

### Partial success is failure

`RESULT failed` and exit 1 whenever any database failed, even though the archives
that did publish are complete and restorable. A partial dump set that reports
success is how a missing database goes unnoticed for a month.

---

## 7. `backup_sync.sh`

```
backup_sync.sh [--config=PATH] [--retention_days=N] [--dry-run]
```

Four steps: `discover` → `copy` → `retention` → `prune`, 9 pre-flight checks.

Both the source and the destination come from the config file, per server:
`base_dir` is the source, `sync_dest` is the destination. There is no server
array in the script and no `--source_base`/`--dest_base` — one server, one entry,
one place.

**`sync_dest` is opt-in and has no default.** An entry without it is not copied
anywhere, and is named in the log as skipped rather than silently omitted. A
config where no entry has one means there is nothing to do: the script prints
`BACKUP SYNC NOT CONFIGURED`, exits 0, and `final.sh` records the step as
*skipped*, not failed. Inventing a default destination would start copying data
somewhere nobody asked for — on a share that may not even be mounted.

Two different mounts, so both get the full treatment: `mountpoint` on each, plus
a prefix test on every `base_dir` against `SOURCE_MOUNT_POINT` and every
`sync_dest` against `DEST_MOUNT_POINT`. An entry whose source and destination are
the same path is refused outright — copying a tree onto itself and then expiring
it deletes backups.

### Discover first

The whole copy set — the newest archive of every database of every configured
server — is resolved before anything is written, so the destination is sized once
instead of being discovered full halfway through. A tight fit warns rather than
dies: most of the set is usually already there and will be skipped, and the
retention pass has not run yet.

### Copy, verify, then rename

`cp` to `<name>.part`, verify at the destination, `mv` into place. Verification
prefers the producer's `.sha256`, because that proves the copy matches what was
*dumped*, not merely what the source file currently reads as; size is the
fallback for archives that predate the sidecars. A mismatch deletes the copy and
records the failure. The sidecar travels with the archive, so the second share
can be verified on its own later without reaching back to the first.

An archive already at the destination with the same name and size is skipped —
the name embeds the run id, so a same-name archive is the same archive.

### Retention, destination only

Nothing on the source is ever deleted by this script; that is
`db_cleanup.sh`'s job. On the destination, `*.tar.gz` older than
`DEST_RETENTION_DAYS` goes, **except the newest archive in the directory**,
however old it is: a server that has stopped producing dumps must not have its
last copy aged out, because that is precisely when the copy matters.
`DEST_RETENTION_DAYS=0` is refused in pre-flight — it would delete a copy the day
it was made.

The stray `shutdown -h +5` at the end of the `vm-scripts/` original is gone.
Shutting the VM down is `final.sh`'s decision, and a sync run by hand should not
take the machine with it.

---

## 8. `db_cleanup.sh`

```
db_cleanup.sh [--config=PATH] [--dry-run]
```

Two steps: `retention` → `prune`, 7 pre-flight checks. Retention over the dumps
on the **primary** share. The tree and the pattern both come from the config
file, per server — `base_dir` and `retention`:

```json
{ "server_name": "Cloud-Live-DB-Default",
  "base_dir":    "/livestorage/Logical/Cloud-Live-DB-Default",
  "retention":   "smart" }
```

**`retention` is opt-in and has no default.** An entry without it is never
expired — every dump of that server is kept — and is named in the log as skipped.
A config where no entry has one prints `DB CLEANUP NOT CONFIGURED`, exits 0, and
`final.sh` records the step as *skipped*, not failed. A script whose only job is
`rm` deletes exactly what it was told to and nothing by assumption.

There is no `SERVERS` array either: a server removed from the pipeline stops
being expired at the same moment it stops being dumped, instead of leaving an
orphaned array entry that keeps deleting from a tree nothing writes to.

| Pattern  | Keeps                                                                       |
| -------- | --------------------------------------------------------------------------- |
| `days:N` | every archive from the last N days                                          |
| `smart`  | every archive from the last `SMART_DAILY_DAYS` (7), plus the newest archive of each of the `SMART_WEEKLY_KEEP` (3) most recent weeks beyond that |

`smart` walks newest-first, so the archive kept for a week is that week's most
recent, and weeks are ISO weeks (`%G-W%V`) so a run on a Monday does not merge
two calendar weeks into one slot.

Three things constrain the implementation:

- **Every entry — path and pattern — is validated in pre-flight**, before
  anything is deleted. A typo in entry four must not be discovered after entries
  one to three have been pruned.
- **`ALWAYS_KEEP_NEWEST=1`.** The newest archive of a database is never deleted
  under either pattern. Without it, a database that stopped being dumped loses
  its last backup on a quiet Tuesday.
- **The `.sha256` sidecar goes with the archive.** An orphan checksum is a file
  that looks like a backup record and refers to nothing.

`fail_run` reports the count of deletions already made: they are permanent, and
a run that aborted mid-pass left retention partly applied.

---

## 9. What is deliberately not here

- **No retention for anything an entry did not ask for.** `db_cleanup.sh`
  expires the logical dumps under `base_dir` when an entry carries `retention`,
  and the physical sets under `backup_base` when it carries
  `physical_retention`. An entry with neither keeps everything, for ever. There
  is deliberately no default: a script whose only job is `rm` deletes what it
  was told to and nothing by assumption.
- **No cross-database consistency in the dumps.** `--single-transaction` gives
  each database an internally consistent snapshot at its own moment. The
  physical archive underneath is a single point in time; the dump set taken from
  it is not.
- **No PITR from the dumps.** `--source-data=2` records a binlog coordinate as a
  comment, and the pre-flight drops the option rather than failing every database
  when the user lacks `REPLICATION CLIENT`. Point-in-time recovery is the
  physical chain's job.
- **No parallel servers.** One datadir means one restore at a time. `final.sh`
  holds a lock for the whole run and each child takes its own.

---

## 10. Deploying and first run

```bash
# on the restore VM
install -m 755 restore_vm.sh logical.sh backup_sync.sh db_cleanup.sh final.sh /Data/script/
install -m 644 servers.example.json /Data/script/servers.json   # then edit it

# LF line endings and the exec bit both matter — see CLAUDE.md
bash -n /Data/script/final.sh
```

### Then fill in PART 1A

Each script ships with its per-VM settings set to `__SET_ME__` and **refuses to
start** until they are replaced. Run one and it names the lines to edit:

```
[ERROR] final.sh has not been configured for this host.
        Open it, find PART 1A, and replace __SET_ME__ in:
          CONFIRM_RESTORE_VM
          SMB_MOUNT_POINT
        Nothing has been read, written or deleted.
```

Twelve lines in total across the five scripts. On this fleet:

| Script           | PART 1A                                                      |
| ---------------- | ------------------------------------------------------------ |
| `final.sh`       | `CONFIRM_RESTORE_VM=1`, `SMB_MOUNT_POINT="/livestorage"`      |
| `restore_vm.sh`  | `MYSQL_USER`, `MYSQL_PASSWORD`, `SMB_MOUNT_POINT="/livestorage"` |
| `logical.sh`     | `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST=""`, `SMB_MOUNT_POINT="/livestorage"` |
| `backup_sync.sh` | `SOURCE_MOUNT_POINT="/livestorage"`, `DEST_MOUNT_POINT="/southstorage"` |
| `db_cleanup.sh`  | `SMB_MOUNT_POINT="/livestorage"`                              |

Nothing else in PART 1 has to be touched to deploy. §11 covers the rest.

### First run

In this order:

```bash
# 1. Prove the pipeline can read everything, without touching a datadir.
#    Verifies each archive's checksum, previews the binlogs, skips the dumps,
#    and runs sync and cleanup in their own dry-run modes.
/Data/script/final.sh --dry-run

# 2. One server, by hand, no binlogs, no shutdown. This is the run that first
#    executes the destructive path.
/Data/script/restore_vm.sh --server_name=Cloud-Live-DB-Default \
  --backup_base=/livestorage/Backup/Cloud-Live-DB-Default --skip-binlog
/Data/script/logical.sh --server_name=Cloud-Live-DB-Default \
  --base_dir=/livestorage/Logical/Cloud-Live-DB-Default

# 3. Retention, previewed, before it is ever allowed to delete.
/Data/script/db_cleanup.sh --dry-run

# 4. The whole thing, still without the shutdown.
/Data/script/final.sh --no-shutdown

# 5. Nightly.
#    30 2 * * *  /Data/script/final.sh >/dev/null 2>&1
```

`final.sh` takes no arguments in normal use: the server list comes from
`CONFIG_FILE` in its PART 1C, which defaults to `/Data/script/servers.json`.
`--config=PATH` still overrides it, for a second list or a test run.

`restore.sh` in this directory has still never been run end to end, and
`restore_vm.sh` is derived from it — step 2 above is where that changes. Take a
VM snapshot of the restore VM first.

### Reading a run afterwards

Every script's log ends with one greppable line:

```bash
grep -h ' RESULT ' /livestorage/final/pipeline_logs/*/pipeline.log | tail -20
```

```
 RESULT ok server=Cloud-Live-DB-Default id=20260821 applied=6 gaps=0 dur_s=1841 warn=0
 RESULT ok server=Cloud-Live-DB-Default run=20260821 dbs=17 ok=17 failed=0 bytes=41231089664 dur_s=2260 warn=0
 RESULT ok servers=5 copied=17 skipped=0 failed=0 deleted=12 bytes=41231089664 dur_s=612 warn=0
 RESULT ok servers=5 deleted=9 kept=131 errors=0 freed=31889063936 dur_s=44 warn=0
 RESULT ok run=20260821_023001 servers=5 ok=5 failed=0 sync=ok cleanup=ok dur_s=14022 warn=0
```

The pipeline log contains every child's output as well, so it is the only file
that has to be read after a failure. Per-step logs stay where the child put
them: `<backup_base>/logs/<id>/restore_<stamp>/` and `<base_dir>/logs/<run id>/`.

---

## 11. Configuration reference

Settings live in three places, and the split is deliberate:

| Where               | What                                                   | Changes when |
| ------------------- | ------------------------------------------------------ | ------------ |
| `servers.json`      | per **server**: which trees, which retention           | a server is added or removed |
| PART 1A of a script | per **VM**: credentials, mount points, the wipe switch | the deployment moves to a new host |
| PART 1B / 1C        | tuning, and constants shared between the scripts       | rarely, and deliberately |

Nothing else is configuration. Binaries, the datadir and the systemd unit are
asked for at run time, and per-run choices arrive as arguments.

### The PART 1 tiers

Every script's PART 1 is split into the same blocks:

| Tier | Heading      | Rule |
| ---- | ------------ | ---- |
| 1A   | SET PER VM   | Ships as `__SET_ME__`. The script refuses to start while any is untouched. |
| 1B   | TUNING       | Working defaults. Change for a measured reason. |
| 1C   | SHARED       | The other scripts on this host assume these values. Change in all of them, or none. |
| 1D   | NOT SET HERE | Detected at run time, or passed as arguments. Nothing to fill in. |
| 1E   | GUARD        | The check itself. |

The guard runs before the log engine starts, before the lock is taken and
before the share is touched, so a misconfigured copy costs a second and changes
nothing. That matters because the alternative is silent: a script carrying
another host's values runs perfectly and does the wrong thing, and on this
pipeline the wrong thing is a wiped datadir.

### 1A — the per-VM values

| Setting | In | What it is | What a copied value does |
| --- | --- | --- | --- |
| `CONFIRM_RESTORE_VM` | `final.sh` | `1` on the dedicated restore VM, `0` everywhere else | `1` on a production host erases that host's datadir once per server in `servers.json`, nightly, unattended |
| `MYSQL_USER`, `MYSQL_PASSWORD` | `restore_vm.sh`, `logical.sh` | the local account | fails loudly at the connection check |
| `MYSQL_HOST` | `logical.sh` | the instance to dump — the LOCAL restored one. `""` selects the local socket | an address copied from another VM turns the dump into read load on live production data, which is the one thing this VM exists to avoid |
| `SMB_MOUNT_POINT` | `final.sh`, `restore_vm.sh`, `logical.sh`, `db_cleanup.sh` | the CIFS mount point itself, not a directory beneath it | `mountpoint -q` is true only for the exact mount path. Wrong here and the "is the share really mounted" check never fires, so a dropped share reads as an empty local directory and the run writes to the root filesystem |
| `SOURCE_MOUNT_POINT`, `DEST_MOUNT_POINT` | `backup_sync.sh` | the two shares | as above, once per share. They should be different filers — the script verifies each is mounted and that the JSON paths sit under the right one, but it cannot tell two mounts of one filer apart |

`CONFIRM_RESTORE_VM` is why the guard exists. Every other mistake in this table
is recoverable; that one is an outage repeated until somebody notices.

### 1B — tuning

| Setting | Script | Default | Notes |
| --- | --- | --- | --- |
| `CONFIRM_WIPE` | `restore_vm.sh` | `1` | `0` disables restores on this host entirely |
| `PARALLEL_THREADS` | `restore_vm.sh` | blank | xbstream extract and `--decompress`. Left blank it is half the cores of whatever VM it lands on; fill in a number to pin it |
| `PREPARE_USE_MEMORY` | `restore_vm.sh` | `1G` | xtrabackup's own default is 100MB, which makes the redo apply crawl |
| `DATADIR_SPACE_PCT` | `restore_vm.sh` | `120` | space requirement, % of the source datadir |
| `ARCHIVE_EXPANSION_FACTOR` | `restore_vm.sh` | `5` | fallback when the manifest carries no `datadir_bytes` |
| `STAGE_ARCHIVE` | `restore_vm.sh` | `1` | copy the archive to local disk before the wipe; `0` extracts straight off the share |
| `ARCHIVE_STAGE_DIR` | `restore_vm.sh` | `/Data/dbvault-stage` | where the staged `.xbstream` lives |
| `KEEP_STAGED_ON_FAILURE` | `restore_vm.sh` | `1` | a retry then skips the copy |
| `XBSTREAM_DECOMPRESS` | `restore_vm.sh` | `0` | one-pass extract. Verify the build first: `xbstream --help` and look for `decompress` |
| `MYSQL_READY_TIMEOUT`, `MYSQL_READY_INTERVAL` | `restore_vm.sh` | `900`, `2` | how long to wait for the restored server to accept a connection |
| `PARALLEL` | `logical.sh` | `3` | databases dumped at once. NOT derived from the core count — this is load on the MySQL instance, not CPU work on this box |
| `BACKUP_MODE`, `DB_LIST_DIR` | `logical.sh` | `ALL`, empty | `--mode=` and `--db_list_dir=` override per run |
| `SOURCE_CHECK` | `logical.sh` | `1` | refuse to dump when the newest restore marker names a different server |
| `DUMP_OPTS` | `logical.sh` | — | `--hex-blob` is deliberately absent: no binary columns in these schemas |
| `SYNC_LOG_BASE`, `DEST_LOG_DAYS` | `backup_sync.sh` | — | keep the log base under `DEST_MOUNT_POINT`; the point is that the logs survive losing the source |
| `DEST_RETENTION_DAYS` | `backup_sync.sh` | `3` | destination retention. `0` would delete a copy the moment it was made, so pre-flight refuses it |
| `SMART_DAILY_DAYS`, `SMART_WEEKLY_KEEP` | `db_cleanup.sh` | `7`, `3` | what `"smart"` means: full daily coverage, then one archive per week |
| `ALWAYS_KEEP_NEWEST` | `db_cleanup.sh` | `1` | never delete a database's last archive or a server's last physical set, however old |
| `CLEANUP_LOG_BASE`, `KEEP_CLEANUP_LOG_DAYS` | `db_cleanup.sh` | — | this script's own logs |
| `PIPELINE_LOG_BASE` | `final.sh` | — | one directory per pipeline run |
| `SHUTDOWN_DELAY_MIN`, `SHUTDOWN_ON_FAILURE` | `final.sh` | `10`, `1` | shut down even after a failure: every log is on the share by then, so nothing on the VM is left to read |
| `KEEP_LOCAL_DAYS` | all five | `14` | prunes logs stranded on the VM by a dead share |

### 1C — shared between the scripts

| Setting | Value | Why it has to match |
| --- | --- | --- |
| `CONFIG_FILE` | `/Data/script/servers.json` | `final.sh`, `backup_sync.sh` and `db_cleanup.sh` each default to it. `final.sh` passes its own value down with `--config=`, so a pipeline run stays consistent even if a child's default was edited |
| `LOCAL_STAGE` | `/Data/dbvault-stage` | logs and staging during a run |
| `LOCK_DIR` | `/var/lock/dbvault` | `final.sh` holds the pipeline lock; each child takes its own beside it |
| `STATE_DIR` | `/var/lib/dbvault` | the restore marker. `restore_vm.sh` writes it, `logical.sh` reads it for the source check — different values there and the check silently never matches |
| `NON_DB_DIRS` | `logs manifests cleanup_logs` | directories in a dump tree that are not databases. `backup_sync.sh` and `db_cleanup.sh` must agree, or one copies what the other expires |
| `ARCHIVE_GLOB` | `*.tar.gz` | what a logical archive looks like |
| `PHYSICAL_GLOB`, `PHYS_SET_SUFFIXES`, `PHYS_SET_DIRS` | — | `db_cleanup.sh` only: what a complete physical set is, so expiring one takes the archive, its checksum, its manifest, its binlogs and its logs together |
| `BINLOG_PREFIX` | `binlog` | the **producing** host's `log_bin` basename, which is what names the binlog files sitting on the share. Not this host's — this host's datadir is about to be erased, and its own naming is irrelevant to the chain being applied |

### 1D — not set anywhere

Resolved at run time. Each still honours an environment variable, for the rare
host where the detected answer is wrong.

| Value | How it is found | Override |
| --- | --- | --- |
| `MYSQL_DATADIR` | `SELECT @@datadir` from the running server, then `my_print_defaults mysqld` when it is down | `MYSQL_DATADIR=/srv/mysql ./restore_vm.sh ...` |
| `MYSQL_SERVICE` | the first of `mysql`, `mysqld`, `mariadb` that `systemctl cat` knows | `MYSQL_SERVICE=mysqld ./restore_vm.sh ...` |
| `MYSQL_BIN`, `MYSQLDUMP_BIN`, `XTRABACKUP_BIN`, `XBSTREAM_BIN`, `MYSQLADMIN_BIN`, `MYSQLBINLOG_BIN` | `command -v` | `MYSQLDUMP_BIN=/opt/mysql/bin/mysqldump ./logical.sh ...` |
| `RESTORE_SCRIPT`, `LOGICAL_SCRIPT`, `SYNC_SCRIPT`, `CLEANUP_SCRIPT` | beside `final.sh`, via `SCRIPT_DIR` | `RESTORE_SCRIPT=/Data/script/restore_vm.sh.known-good ./final.sh` |
| `SERVER_NAME`, `SECONDARY_STORAGE_DIR` | `--server_name=`, `--backup_base=` | — |
| `BASE_DIR` | `--base_dir=` | — |

The datadir is the one worth understanding. `restore_vm.sh` **erases** it, on
every run. Asking the server where it is beats a path typed into a file that was
copied from another host; and when the server is down, `my_print_defaults` reads
the same `my.cnf` that `mysqld` itself would read, so a VM whose MySQL has never
started still resolves correctly. If neither answers, the script stops rather
than guessing at a directory it is about to delete.

Both the value and where it came from are printed in the run header:

```
 datadir         : /Data/mysql  (@@datadir)
```

### Checking a deployment

`--dry-run` resolves everything, prints the header and the full pre-flight, and
touches nothing. It is the fastest way to see what a host will actually use:

```bash
/Data/script/final.sh --dry-run
```
