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
The switch is a pre-flight check, in the same spirit as `CONFIRM_WIPE`: it exists
so that a deployment copied onto the wrong machine refuses to run.

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
├── final/_pipeline_logs/<stamp>/           ← final.sh publishes here
└── final/_cleanup_logs/<stamp>/            ← db_cleanup.sh publishes here

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
final.sh --config=/Data/script/servers.json
         [--backup_date=YYYYMMDD] [--skip-binlog]
         [--skip-sync] [--skip-cleanup] [--no-shutdown] [--dry-run]
```

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
| `retention`   | no       | `db_cleanup.sh`: `"smart"` or `"days:N"`                       |

**This one file drives all four steps.** `final.sh` reads the first eight
fields; `backup_sync.sh` reads `base_dir` and `sync_dest`; `db_cleanup.sh` reads
`base_dir` and `retention`. No script carries its own server list, so adding a
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
| no `retention` on an entry    | —                            | that server is never expired  |
| no `retention` on any entry   | —                            | **does not run** (skipped)    |

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
(wipe → extract → decompress → prepare → start), apply — with the same 14
substantive checks, the same one-shot binlog apply, the same
state-selected failure advice, and one addition: the source server is an
argument. Read [README.md](./README.md) §9 for the phase logic; only the
differences are below.

| `restore.sh`                                | `restore_vm.sh`                                   |
| ------------------------------------------- | ------------------------------------------------- |
| `SECONDARY_STORAGE_DIR` is a constant       | `--backup_base`, validated to be under the mount  |
| backup id is a positional argument          | `--backup_id`, or the latest archive of `--backup_date` (default today) |
| marker `${BACKUP_ID}_restore_state`          | marker `${SERVER_NAME}_${BACKUP_ID}_restore_state` |
| 14 pre-flight checks                        | 15 — the extra one is `backup base` under the mount |
| next step: take a fresh backup              | next step: `logical.sh` — this datadir is temporary |

`restore.sh` is unchanged and stays the tool for restoring a server onto itself.

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

`MYSQL_HOST` in PART 1, `--mysql_host=` to override, empty for the local socket.
On the restore VM this must be the instance `restore_vm.sh` just rebuilt. It is
not a production host: pointing it at one turns a DR drill into load on live
data.

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

- **No retention for the physical archives or the collected binlogs.**
  `db_cleanup.sh` touches the logical dumps only. The `.xbstream` archives,
  `binlog/`, and `meta/` under each `backup_base` still grow without limit —
  the same gap [CLAUDE.md](../CLAUDE.md) records for `stream-scripts/`. Whatever
  prunes them has to reason about which archive is still the newest usable
  baseline for a server, and about the binlog tail that belongs to it; that is a
  different job from expiring a dump.
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

Then, in this order:

```bash
# 1. Prove the pipeline can read everything, without touching a datadir.
#    Verifies each archive's checksum, previews the binlogs, skips the dumps,
#    and runs sync and cleanup in their own dry-run modes.
/Data/script/final.sh --config=/Data/script/servers.json --dry-run

# 2. One server, by hand, no binlogs, no shutdown. This is the run that first
#    executes the destructive path.
/Data/script/restore_vm.sh --server_name=Cloud-Live-DB-Default \
  --backup_base=/livestorage/Backup/Cloud-Live-DB-Default --skip-binlog
/Data/script/logical.sh --server_name=Cloud-Live-DB-Default \
  --base_dir=/livestorage/Logical/Cloud-Live-DB-Default

# 3. Retention, previewed, before it is ever allowed to delete.
/Data/script/db_cleanup.sh --dry-run

# 4. The whole thing, still without the shutdown.
/Data/script/final.sh --config=/Data/script/servers.json --no-shutdown

# 5. Nightly.
#    30 2 * * *  /Data/script/final.sh --config=/Data/script/servers.json >/dev/null 2>&1
```

`restore.sh` in this directory has still never been run end to end, and
`restore_vm.sh` is derived from it — step 2 above is where that changes. Take a
VM snapshot of the restore VM first.

### Reading a run afterwards

Every script's log ends with one greppable line:

```bash
grep -h ' RESULT ' /livestorage/final/_pipeline_logs/*/pipeline.log | tail -20
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
